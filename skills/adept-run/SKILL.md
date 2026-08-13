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

### Multi-node GPU scan — 16 runs on 16 GPUs (canonical)

**This is the pattern to use for any GPU scan wider than one node.** It is the production
config from `ml-for-lpi` (`ml4tpd/parsl_utils.py`, multi-node GPU path), which has run
real campaigns on Perlmutter. `LocalProvider` still does the job at 4 nodes — you do **not**
need `SlurmProvider`. One worker per GPU, 4 GPUs per node, 4 nodes → 16 concurrent runs,
all inside the allocation you already hold.

The shape: **one block per node** (`nodes_per_block=1`, `max_blocks=nodes`), each block an
`srun` that starts a 4-worker pool pinned to that node's 4 GPUs.

```python
import os

from parsl.config import Config
from parsl.executors import HighThroughputExecutor
from parsl.launchers import SrunLauncher
from parsl.providers import LocalProvider

GPUS_PER_NODE = 4          # Perlmutter GPU node = 4 A100s
CPUS_PER_GPU = 32          # 128 logical CPUs / 4 GPUs


def worker_init(repo: str) -> str:
    """Shell that runs in each worker before any app.

    Note what is NOT here: the MLflow token. Sourcing ~/.bash_profile.ext pulls
    ergodic-claude.sh, which reads ~/.mlflow_credentials (mode 600) on the compute node
    and exports $ECLAUDE_VENVS. f-string'ing os.environ["MLFLOW_TRACKING_PASSWORD"] into
    worker_init instead — as older scan scripts do — writes your token in cleartext into
    parsl's generated block scripts under runinfo/ on scratch, where it persists and syncs.
    Source the credential file; never interpolate the secret.
    """
    return "; ".join(
        [
            "source $HOME/.bash_profile.ext",
            f'source "$ECLAUDE_VENVS/{repo}/bin/activate"',
            f'export PYTHONPATH="$PYTHONPATH:$PSCRATCH/{repo}"',
            "export BASE_TEMPDIR=$PSCRATCH/tmp/",
            "module unload cudatoolkit",             # jax ships its own CUDA; the module conflicts
            "export XLA_PYTHON_CLIENT_PREALLOCATE=false",  # don't let one worker grab the whole device
        ]
    )


def make_parsl_config(nodes: int = 4, repo: str | None = None) -> Config:
    repo = repo or os.path.basename(os.getcwd())
    return Config(
        executors=[
            HighThroughputExecutor(
                label="gpu-scan",
                available_accelerators=GPUS_PER_NODE,   # 4 workers, one bound per GPU
                max_workers_per_node=GPUS_PER_NODE,
                cpu_affinity="block",
                provider=LocalProvider(
                    nodes_per_block=1,                 # one block per node…
                    max_blocks=nodes,                  # …N of them
                    init_blocks=1,
                    launcher=SrunLauncher(
                        overrides=f"-c {CPUS_PER_GPU} --gpus-per-node {GPUS_PER_NODE}"
                    ),
                    worker_init=worker_init(repo),
                    cmd_timeout=120,
                ),
            )
        ],
        retries=2,
    )
```

Load it and dispatch exactly as the single-node template does — `ensure_experiment()` first
(the artifact-loss race above bites hardest at 16 concurrent workers), then the futures.

Why each piece is there — none of it is decoration:

| Setting | Why |
| --- | --- |
| `available_accelerators=4` | Hands each worker its own GPU via `CUDA_VISIBLE_DEVICES`. Without it, 4 workers land on device 0 and OOM. |
| `SrunLauncher(overrides="--gpus-per-node 4")` | The step's GRES. Same reason the `salloc` needs it — a step with no GRES request gets `CUDA_ERROR_NO_DEVICE` even on an exclusive node. |
| `-c 32` | 32 logical CPUs per worker = 128/4. Omit it and srun packs workers onto too few cores. |
| `cpu_affinity="block"` | Keeps each worker's threads on the cores nearest its GPU. |
| `retries=2` | **Load-bearing.** With `retries=0` a single worker death hangs the *whole* scan at the batch barrier (hit 2026-06-29). |
| `cmd_timeout=120` | Block launches on a busy node can exceed the 30 s default and get spuriously reaped. |

**Where the allocation comes from — and where the driver must NOT be.** This config expects an
existing allocation of `nodes` nodes (a 4-node `salloc`, or `sbatch`). Because every block is
its own `srun`, **the driver must not itself occupy a job step**:

| how you're running | where the driver goes |
| --- | --- |
| interactive (`salloc --no-shell`) | **login node**, `SLURM_JOB_ID=<jobid>` exported, `nohup`'d |
| batch (`sbatch`) | the sbatch body **directly** — no `srun` wrapper |

Wrapping this driver in `srun --overlap -N1 -n1` — which `nersc-workflow` prescribes for
*torchrun-style* multi-node drivers — kills the scan in seconds: the worker sruns can't bind
CPUs (`Unable to satisfy cpu bind request`), parsl marks every block MISSING, and all tasks die
with `BadStateException`. Measured 2026-08-11 on 4 nodes; `--cpus-per-task=128` and adding
`--overlap` to the worker launcher both fail to fix it. See the **EXCEPTION** box in
`nersc-workflow` for the launch snippet and the 60-second verification (one manager per node,
right accelerators, zero bind errors) — check that before walking away from a launch.

**One-run-per-GPU vs. one-run-across-4-GPUs — same provider, one setting apart.** The config
above gives one *independent* run per GPU, which is what a scan wants. For a single run
*sharded* across a node's 4 GPUs (`jax.devices() == 4`), keep the provider exactly as-is and
change only the accelerator spec to a grouped list, `available_accelerators=["0,1,2,3"]`
(verified 2026-08-11: one manager per node, `Accelerators: 0,1,2,3`, one 4-GPU worker each).
Both layouts run on `nodes_per_block=1, max_blocks=nodes` — there is no second provider shape
to remember, and **don't** add `--ntasks-per-node 1` to the launcher overrides. Within one
process, sharding buys throughput, not memory: see "Probe device memory" below. To actually
distribute memory, you need the multi-node sharded run below.

### Multi-node sharded run — ONE simulation across N nodes (jax.distributed)

The mechanism is **verified on Perlmutter** (2026-08-11, 4 nodes x 4 A100 = 16 GPUs):
after `jax.distributed.initialize()`, `jax.devices()` returns all 16 devices
node-contiguously, `Mesh(np.array(jax.devices()), ("device",))` + `shard_map` compile
unchanged, and GSPMD's cross-node all-to-all runs at the Slingshot NIC ceiling. Smoke
test + measured numbers live in vp-turbulence: `scripts/run/smoke_multinode.py` and
`workdir/smoke-multinode.sbatch`.

**Status: WORKING for vp-turbulence, adept untouched** (verified 2026-08-12 end to
end, including a production merger-scan member). The reference implementation is
`vp-turbulence/vp_turbulence/multinode.py` + `scripts/run/run_two_stream_multinode.py`
(same `--cfg`/`--test` interface as the single-node runner; without srun it runs
single-process) + `workdir/multinode.sbatch` (batch template, `CFG=...` via
`--export`). adept needs no changes because its pushers already build their mesh over
`jax.devices()` — global once distributed init runs. Everything multi-process actually
changes sits AROUND the solve, and porting it to another adept project means copying
`multinode.py` and swapping the module class.

**Requires jax >= 0.10.2, as a coherent set.** On jax 0.9.0.1 + Perlmutter's CUDA 13
driver, any sharded solve whose distribution function reaches ~1.5-2 GiB returns every
output with `.sharding = UnspecifiedValue` — structurally unreadable, the run's output
is lost at save time (root-caused in vp-turbulence, see its pyproject and
`scripts/analysis/repro_unspecified.py`). Keep jax/jaxlib/jax-cuda12-plugin/
jax-cuda12-pjrt at ONE version: sequential `uv pip install -U` calls can leave the
plugin a minor version ahead, which silently drops the cusparse FFI handler the
Fokker-Planck tridiagonal solve needs (`NOT_FOUND: cusparse_gtsv2_ffi`). A fresh venv
build from pyproject resolves coherently; piecemeal upgrades are where this bites.

**The three multi-process rules** (each one cost a failed run to learn):

1. *State must be built as global arrays, and never via device_put.* Multi-process
   `jax.device_put(host_array, <global sharding>)` VALIDATES the value is identical on
   every process by gathering one copy per process onto device — 16 x 2.1 GiB = 32 GiB
   OOM at the truth grid. `jax.make_array_from_callback(shape, sharding, lambda idx:
   host[idx])` does no such check and materializes only each process's own shards.
   `shard_state()` in multinode.py rebuilds the module's state this way after the
   normal `init_state_and_args` (which runs identically everywhere — it all derives
   from cfg, seeds included).
2. *Nothing global may be closed over.* Multi-process jax refuses jit closures over
   non-fully-addressable arrays ("Please pass such arrays as arguments"), and adept
   modules read `y0` off `self.state` — i.e. filter_jit would close over it. The
   runner swaps the state in as a traced argument with a three-line shim
   (`_solve(state, mods, args): m.state = state; return m(mods, args)`).
3. *Gathers are collectives; I/O is rank 0's.* `np.asarray` raises on
   non-fully-addressable outputs, so ys/ts leaves are gathered with
   `multihost_utils.process_allgather(x, tiled=True)` — by EVERY process, in the same
   deterministic tree order — and only then does process 0 alone run post_process,
   netcdf, plots, and MLflow (reusing adept's own `patched_mlflow`, `log_params`,
   `robust_log_artifacts`, so runs look identical to ergoExo's). A collective inside a
   rank-guarded branch hangs the job; keep the gather outside the guard.

**Production flow that worked** (merger member L8000-t1200, 32768x2048, 240k steps):
generate the member config with the scan's own `apply_member()` (never hand-copy the
save-tier plumbing), then — because there is NO checkpoint/restart — measure before
committing to a walltime: run ~1000 steps and ~2000 steps of the real config and
difference the wall times to cancel compile (44.4 ms/step for that member on 16 GPUs;
1000-step probe alone over-reads by ~35%). Only launch if steps x ms/step fits the
window with >= 30 min margin. Detach the srun with `nohup` and log to a file — an
expired sshproxy cert mid-run then costs only visibility, not the run.

**Launch (proven):** allocation with `--ntasks-per-node=4 --gpus-per-node=4
--cpus-per-task=32`; run `srun --ntasks-per-node=4 --gpus-per-node=4 python -u <script>`
— one task per GPU, each process calling
`jax.distributed.initialize(local_device_ids=[int(os.environ["SLURM_LOCALID"])])` before
any other JAX call. **Not `--gpus-per-task`**: its per-task cgroup hides the other GPUs
and breaks NVLink P2P between same-node ranks.

**NCCL over Slingshot — plugin dir only, no `module load nccl`.** The module would
shadow the venv's newer pip NCCL (2.29.3 vs 2.24.3) and drags in `cudatoolkit`, which
conflicts with jax's pip CUDA (see `worker_init` above). Take only the plugin and the
module's env (from `module show nccl/2.24.3`):

```bash
export LD_LIBRARY_PATH="/global/common/software/nersc9/nccl/2.24.3/plugin/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export NCCL_SOCKET_IFNAME=hsn
export NCCL_NET="AWS Libfabric"
export NCCL_NET_GDR_LEVEL=PHB
export FI_CXI_DISABLE_HOST_REGISTER=1
```

Verify in the log (`NCCL_DEBUG=INFO`, `NCCL_DEBUG_SUBSYS=INIT,NET`): "Loaded net plugin
AWS Libfabric" — a run that says "Using network Socket" is on TCP fallback and every
timing from it is garbage.

**The trap that costs a job:** `jax.device_put(host_array, <non-fully-addressable
sharding>)` silently *validates* the value is identical on every process by gathering it
— one copy per process stacked on device, so a 2.1 GB array x 16 processes attempted a
32 GiB allocation and OOM'd. Materialize global state with
`jax.make_array_from_callback(shape, sharding, lambda idx: host_array[idx])` (no
cross-host check, each process builds only its own shards). Same class of trap on the way
out: `np.asarray` on a non-fully-addressable array raises — gather small diagnostics via
on-device replication (`process_allgather(x, tiled=True)` on the *global* array is fine),
and write big arrays per-shard from `x.addressable_shards`.

**Measured (f64, 16 GPUs / 4 nodes):** the x<->v transpose pair — one Vlasov step's
communication load — costs 22.4 ms at 32768x8192 (2.15 GB state; bare all-to-all 7.2 ms,
281 GB/s aggregate ≈ 70 GB/s/node ≈ the 4x25 GB/s NIC ceiling) and 87.6 ms at
131072x8192 (8.6 GB — a state that cannot fit one 40 GB card with save buffers).
End-to-end full solver (jax 0.10.2): 32768x8192 runs at <= 179 ms/step on 16 GPUs vs
358 ms/step on one node — a >= 2x speedup — with the physics matching the single-node
result bit-for-bit; 32768x2048 (merger members) runs at 44.4 ms/step. Communication
does not dominate, and aggregate HBM (640 GB across 4 nodes) is the real prize.

### Picking `workers_per_node`

- **On a laptop**: 1–4 depending on cores and solver size.
- **On a NERSC GPU node**: one worker per GPU (`available_accelerators=4`) is the default — see the canonical multi-node config above. More than one run per GPU only if each is small enough to share VRAM.
- **CPU node**: ~32–64 per node, but verify the solver isn't itself multi-threaded.

Scaling past one node does **not** require `SlurmProvider` — use the multi-node
`LocalProvider` config above inside an N-node allocation. Reach for `SlurmProvider` only when
the scan itself should submit and own its jobs (and then don't hardcode the account: read it
from `~/.claude/scripts/ergodic/show-config.sh EC_ACCOUNT_GPU`).

### Sizing a scan: measure ms/step, don't read MLflow durations

**MLflow does not log how many GPUs a run used**, so an MLflow wall-clock duration cannot be
converted into a cost. Estimating a scan from one anyway came out **4x optimistic** — enough to
set a 6 h walltime on a member that needed 8.9 h and would have been killed mid-solve.

Measure instead: run a handful of steps and read the progress bar's rate, then scale by the
cells and steps you actually want. For a grid-based solver the scaling is linear in the state
size, so one measurement covers the whole scan:

```
gpu_h = (tmax/dt) / steps_per_sec * (nx/nx_ref) * (nv/nv_ref) / 3600
```

Record the reference point *with the hardware* (e.g. "25 steps/s at 4096x2048 on one A100"),
because that is the number the next person needs. Multi-GPU sharding is not free: measured
speedup on 4 A100s was **3.14x**, not 4x, and a doc figure implying 3.75x was optimistic — use
your own measurement to size walltimes.

### Probe device memory before spending an allocation

The save buffers (`diffrax` `SubSaveAt` outputs) accumulate in **device** memory during the
solve and are sized by each tier's `nt`, **not** by `tmax`. That gives a cheap exact test: set
`tmax` to a few hundred steps but **keep production `nt`**, and the run allocates the real
footprint in ~2 min.

A "smoke test" that shrinks `nt` as well as `tmax` tells you nothing about memory. That
distinction is not academic — it is the difference between learning `RESOURCE_EXHAUSTED: Out of
memory while trying to allocate 33.85GiB` in two minutes and learning it an hour into a 4 h
allocation.

Two traps worth stating plainly:

- **Sharding one run across 4 GPUs in a single process does not reduce its memory.** adept's
  `grid.parallel` is explicit: "one process, one node, no distributed memory… it does not let
  you run a bigger one." The full distribution function is allocated on the default device and
  the state `diffrax` carries stays a global array, so a 4-GPU run must still fit on **one**
  card. It buys throughput only. Distributing memory takes the multi-node jax.distributed
  path (see "Multi-node sharded run" above), which is working — via a wrapper around the
  solve in vp-turbulence, with adept itself unchanged.
- **A peak measured on a small case does not generalize.** 23.8 GB at `nx=8192` (55% of a 40 GB
  A100) does not license dropping `hbm80g` for `nx=32768` — those members needed 29–34 GiB
  single allocations and OOM'd. Measure the member you intend to run.

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
