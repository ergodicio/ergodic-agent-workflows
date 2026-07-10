---
name: adept-run
description: How to run ADEPT simulations the right way — defaults to the ergoExo class (full MLflow logging) for single runs, and parsl with LocalProvider for parameter scans. Use whenever the user asks to run a simulation, sweep a parameter, or launch an adept experiment, whether locally or on NERSC.
allowed-tools: Bash, Read, Write, Edit
---

# Running ADEPT simulations

This skill encodes the team's defaults for invoking the [adept](https://github.com/ergodicio/adept) solver. There are three ways to run adept; **two of them are wrong by default**. Pick correctly.

## TL;DR

| Task | Default approach |
| --- | --- |
| Run one simulation from a YAML config | `uv run run.py --cfg <path/without/.yaml>` |
| Run one simulation from Python (e.g. inside a script) | `from adept import ergoExo` |
| Parameter scan / sweep | `parsl` with `LocalProvider` |
| Train / optimize trainable modules through the solver | Hybrid parent/child loop — cached `filter_jit(mod.vg)` + periodic fresh-ergoExo child run |

Anything else (direct `diffrax` calls, importing `adept.pic1d.BasePIC1D` directly, hand-rolled `Stepper` loops) is **not the default** — see "When to deviate" below.

---

## Single simulation — ergoExo (preferred)

`ergoExo` wraps the solver lifecycle and **handles MLflow setup, run logging, artifact upload, and post-processing automatically**. This is the only path that gives the team's tracking workflow for free.

### From the CLI

```bash
uv run run.py --cfg configs/<solver>/<name>     # note: no .yaml extension
```

`run.py` in the adept repo root loads the YAML and hands it to `ergoExo`.

### From Python (when you're writing your own driver script)

```python
import yaml
from adept import ergoExo

with open("configs/my_config.yaml") as f:
    cfg = yaml.safe_load(f)

exo = ergoExo()
modules = exo.setup(cfg=cfg)
run_output, post_output, run_id = exo(modules)
```

The config must include at least:
```yaml
solver: vlasov-1d           # or whichever solver
mlflow:
  experiment: <name>
  run: <name>
```

If the user asks "run a simulation" / "launch adept" / similar, default to one of these two forms. Choose CLI if they have a config file ready; choose ergoExo-from-Python if they're embedding it in a larger script.

---

## Parameter scan — parsl with LocalProvider

For sweeping a parameter (or grid of parameters), use [parsl](https://parsl.readthedocs.io/) with `LocalProvider`. Reasons:

- `LocalProvider` launches workers within whatever resource you've already been given (your laptop, or a NERSC compute node inside `salloc`), so the same scan script runs both on a laptop CPU and on a Perlmutter GPU node without modification.
- It composes cleanly with `ergoExo` — each parsl task just calls `ergoExo`, so MLflow logging still happens per-run.
- It avoids the complexity of `SlurmProvider` / `KubernetesProvider` until the user explicitly needs multi-node scale-out.

### Starter template

When the user asks for a parameter scan, generate a script like this and adapt the parameter grid + config-mutation to their request:

```python
"""Parameter scan over <PARAM> using parsl + ergoExo."""

import copy
from pathlib import Path

import parsl
import yaml
from parsl.config import Config
from parsl.executors import HighThroughputExecutor
from parsl.providers import LocalProvider


def make_parsl_config(workers_per_node: int = 4) -> Config:
    return Config(
        executors=[
            HighThroughputExecutor(
                label="local",
                max_workers_per_node=workers_per_node,
                provider=LocalProvider(init_blocks=1, max_blocks=1),
            ),
        ],
    )


@parsl.python_app
def run_one(base_cfg: dict, override: dict, run_name: str) -> str:
    """One simulation. Returns the MLflow run id."""
    from adept import ergoExo

    cfg = copy.deepcopy(base_cfg)
    # Apply override — adjust this to the nested path of the param being scanned
    for key, value in override.items():
        cfg[key] = value
    cfg.setdefault("mlflow", {})["run"] = run_name

    exo = ergoExo()
    modules = exo.setup(cfg=cfg)
    _, _, run_id = exo(modules)
    return run_id


def ensure_experiment(cfg: dict) -> None:
    """Pre-create the MLflow experiment (single-threaded, BEFORE the concurrent workers)
    so they don't race on first-time creation. Without this, the first scan into a
    brand-new experiment can split its runs across the S3 artifact store and the tracking
    server's local default store (mlruns/0) — silently losing most artifacts and forcing a
    costly re-run. Idempotent; safe to call every time."""
    name = (cfg.get("mlflow") or {}).get("experiment")
    if not name:
        return
    # Patch mlflow's REST prefix for the continuum.ergodic.io proxy (/ajax-api/2.0) — same as
    # adept/adept/patched_mlflow.py, inlined so the driver needn't import adept (and jax).
    import mlflow.utils.rest_utils as _ru
    from mlflow.protos.service_pb2 import MlflowService
    from mlflow.store.tracking.rest_store import RestStore
    from mlflow.utils.rest_utils import extract_api_info_for_service

    _ru._REST_API_PATH_PREFIX = "/ajax-api/2.0"
    RestStore._METHOD_TO_INFO = extract_api_info_for_service(MlflowService, "/ajax-api/2.0")
    from mlflow.tracking import MlflowClient

    client = MlflowClient()
    if client.get_experiment_by_name(name) is None:
        client.create_experiment(name)
        print(f"[scan] pre-created MLflow experiment '{name}'", flush=True)


def main() -> None:
    base_cfg = yaml.safe_load(Path("configs/base.yaml").read_text())

    # Define the scan grid — replace with whatever the user is scanning
    scan_values = [0.1, 0.2, 0.4, 0.8]
    overrides = [{"some_param": v} for v in scan_values]

    ensure_experiment(base_cfg)   # avoid the concurrent first-creation race (see docstring)
    parsl.load(make_parsl_config(workers_per_node=4))
    futures = [
        run_one(base_cfg, ov, run_name=f"scan-{i:03d}")
        for i, ov in enumerate(overrides)
    ]
    run_ids = [f.result() for f in futures]

    print(f"Completed {len(run_ids)} runs. MLflow run ids:")
    for rid in run_ids:
        print(f"  {rid}")


if __name__ == "__main__":
    main()
```

Then point the user at `mlflow-query` to compare the resulting runs.

### Pre-create the experiment (avoid the artifact-loss race)

`main()` calls `ensure_experiment(base_cfg)` **before** dispatching the parsl futures. This is load-bearing, not decorative. If a scan's runs are the **first** ever logged to a given MLflow experiment, the concurrent workers race to create it on the tracking server: some runs land on the proper S3 artifact store while others fall back to the server's local default store (`mlruns/0`), and *their* `binary/*.nc` + `plots/` become unreachable — the only fix is a full re-run. (Hit for real on 2026-06-29: a 16-run scan into a new experiment landed 5/16 on S3 and 11/16 on the local store, 0/16 complete.) Pre-creating the experiment once, single-threaded, removes the race; it's idempotent, so it's a no-op when the experiment already exists. Keep the call in any scan that may target a not-yet-existing experiment. If your grid spans multiple experiment names, `ensure_experiment` each unique one.

### Picking `workers_per_node`

- **On a laptop**: 1–4 depending on cores and solver size.
- **On a NERSC GPU node**: bounded by GPU memory if each run needs its own JAX/CUDA process; usually 1–4 per node. Ask the user if unsure.
- **CPU node**: ~32–64 per node, but verify the solver isn't itself multi-threaded.

For scans larger than fits in one node, the user has moved beyond LocalProvider — tell them and ask before swapping to `SlurmProvider`.

---

## Differentiable training / optimization loops (hybrid parent/child)

When you're **optimizing** trainable modules end-to-end *through* the solver — fitting driver
parameters, a learned closure, an initial condition — by gradient descent, do **not** call a
fresh `ergoExo` (or re-`setup`) per optimizer step. Each fresh `ergoExo` builds a new
`ADEPTModule`, so `eqx.filter_jit` sees a new function identity and **recompiles the entire
solver graph every step**. For a cheap fluid solve that's tolerable; for a multi-ps Vlasov/PIC
solve a recompile per step dominates wall-clock and wastes the run.

The right shape is a **hybrid** with two MLflow tiers:

- **PARENT run** = the whole optimization campaign. Log per-step scalars (loss, grad-norm, the
  trainable params) and the **optimizer checkpoint** (model + opt_state + step, as an `.eqx`
  artifact) here, with `step=`.
- **FAST PATH (every step)** — call the **cached** `eqx.filter_jit(adept_module.vg)` *directly*.
  Compiled once, reused every step: no new `ergoExo`, no new run, no recompile. Update the
  optax state, log scalars to the parent.
- **SLOW PATH (every N steps)** — spin up a **fresh** `ergoExo(mlflow_nested=True,
  parent_run_id=parent)` and call `.val_and_grad(...)`. This logs a nested **child run** with
  the full solver artifacts (post-process plots, f(v), …) and a val/grad **cross-check** of the
  fast path. It recompiles (new module) — that's the price of the visibility run, so do it
  occasionally (every 10–50 steps), not every step.

The two paths share ONE objective: the `ADEPTModule` subclass implements
`vg(trainable_modules, args) -> ((val, run_output), grad)` (the base `vg` raises
NotImplementedError; see `_tf1d/modules.py`). `ergoExo.val_and_grad` internally calls
`filter_jit(self.adept_module.vg)`, so the same `vg` backs both the direct fast path and the
child-run slow path (DRY).

```python
import mlflow, optax, equinox as eqx, jax.numpy as jnp
from adept import ergoExo

mlflow.set_experiment(cfg["mlflow"]["experiment"])
parent_id = read_sidecar() if resuming else None          # persist to reopen the SAME parent
with mlflow.start_run(run_id=parent_id, run_name=f"{cfg['mlflow']['run']}-opt") as parent:
    parent_id = parent.info.run_id; write_sidecar(parent_id)
    exo = ergoExo(mlflow_nested=True, parent_run_id=parent_id)   # setup logs a nested child
    modules = exo.setup(cfg=cfg, adept_module=MyModule)
    vg_jit = eqx.filter_jit(exo.adept_module.vg)                 # COMPILE ONCE, reuse
    opt = optax.adam(lr); opt_state = opt.init(eqx.filter(modules, eqx.is_inexact_array))
    if resuming:                                                # restore (modules, opt_state, step)
        modules, opt_state, step0 = eqx.tree_deserialise_leaves(ckpt, (modules, opt_state, jnp.array(0)))
    for step in range(int(step0), nsteps):
        (val, _out), grad = vg_jit(modules, args)               # FAST PATH — no new run/compile
        mlflow.log_metrics({"loss": float(val), ...}, step=step)
        updates, opt_state = opt.update(grad, opt_state, modules)
        modules = eqx.apply_updates(modules, updates)
        eqx.tree_serialise_leaves(ckpt, (modules, opt_state, jnp.array(step + 1)))
        mlflow.log_artifact(ckpt)                               # durable opt ckpt on the PARENT
        if step % vis_every == 0:                               # SLOW PATH — fresh ergoExo child
            exo_v = ergoExo(mlflow_nested=True, parent_run_id=parent_id)
            exo_v.setup(cfg=cfg, adept_module=MyModule)
            exo_v.val_and_grad(modules, {**exo_v.adept_module.args, **extra})
```

**Checkpoint + resume across queued jobs.** Serialize `(modules, opt_state, step)` with
`eqx.tree_serialise_leaves` every step (it's tiny — KB). Keep a **local** copy for fast resume
*and* `mlflow.log_artifact` it onto the parent for durability/visibility (resume elsewhere via
`mlflow.artifacts.download_artifacts(run_id=parent, artifact_path=..., dst_path=...)` then
`tree_deserialise_leaves`). Persist the **parent run id** (a sidecar file, or an MLflow tag) so
a resumed/resubmitted job reopens the SAME parent with `mlflow.start_run(run_id=parent_id)` and
all steps stay under one campaign. Put local checkpoints in a `sync-up`-excluded dir
(`checkpoints/`) so `rsync --delete` doesn't wipe them.

Reference implementations: `adept/_tf1d/train_damping.py` (the original parent/child + grad
artifact pattern) and `kinetic-srs/sims/vlasov-coarsegrain-closure/train.py` (the hybrid
fast/slow loop above).

## When to deviate from these defaults

There are two ways to run adept that bypass ergoExo. **Only use them in these situations:**

### Direct module imports (e.g. `from adept.pic1d import BasePIC1D`)

Skip MLflow entirely; instantiate the solver class and step it yourself. **Use only when:**
- You (an agent) are debugging quickly and the MLflow logging is in the way (slow startup, noisy artifacts, polluting experiments). Prefer this over hacking ergoExo into a "no-log" mode.
- The user **explicitly** asks for this path ("just run it without logging", "use BasePIC1D directly", "skip ergoExo").

Pattern:
```python
import copy
from adept.pic1d import BasePIC1D  # or whichever solver module

m = BasePIC1D(copy.deepcopy(cfg))
m.write_units()
m.get_derived_quantities()
m.get_solver_quantities()
m.init_state_and_args()
m.init_diffeqsolve()
sol = m({})["solver result"]
```

### Direct diffrax + Stepper

Hand-roll the ODE solve. **Use only when:**
- The user is doing genuine research prototyping that needs solver internals exposed (custom vector field, custom step controller).
- The user explicitly asks for this path.

Otherwise, prefer ergoExo even if it feels heavier — the alternative is silent data loss when a "quick experiment" turns into something the team needs to reference later.

---

## Guidelines

- When the user says "run a simulation", "launch adept", or "sweep X", default to ergoExo / parsl-LocalProvider. Do not silently drop to the direct-module path.
- If you're debugging in an opaque way (small fast iterations where the user won't review MLflow), it's OK to use `BasePIC1D`-style direct calls — but say so explicitly in your message so the user can correct course if they wanted full logging.
- Compose with the other skills:
  - `nersc-workflow` for *where* to run (the launch command on Perlmutter should ultimately invoke `run.py` or a parsl scan script).
  - `mlflow-query` for *checking results* after the run.
- If a config field doesn't exist in the user's YAML (e.g. no `mlflow:` block), add it rather than dropping to a non-logging path.

$ARGUMENTS
