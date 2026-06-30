---
name: nersc-workflow
description: Manage the NERSC Perlmutter interactive dev loop — sync code, run training on compute nodes, monitor jobs and logs, pull results, cancel jobs, and clean up. Use when the user wants to run code on NERSC, check job status, sync files to/from Perlmutter, or iterate on remote training.
allowed-tools: Bash
---

# NERSC Interactive Dev Loop

Manage the full cycle of syncing, running, monitoring, and iterating on Perlmutter GPU nodes.

## Helper scripts (prefer these)

These wrappers live at `~/.claude/scripts/ergodic/` (symlinked by `bootstrap-local.sh`). They each wrap one known-safe `ssh perlmutter` invocation, so the user can allowlist them in one rule (`Bash(~/.claude/scripts/ergodic/*)`) and skip per-command approval. **Always prefer the script over an inline `ssh perlmutter "…"` for these ops** — it's the same command but pre-approved.

| Need | Script |
| --- | --- |
| Sync cwd → `$PSCRATCH/<repo>/` | `~/.claude/scripts/ergodic/sync-up.sh` |
| Allocate interactive GPU (1 GPU) | `~/.claude/scripts/ergodic/interactive-gpu.sh [hours] [nodes]` |
| Allocate interactive GPU node (4 GPUs/node, 1-4 nodes) | `~/.claude/scripts/ergodic/interactive-gpu-node.sh [hours] [nodes]` |
| Allocate interactive shared GPU slice (1-2 GPUs, sub-node, shared_interactive QOS) | `~/.claude/scripts/ergodic/interactive-shared.sh [gpus] [hours]` |
| Allocate interactive CPU node (1-4 nodes) | `~/.claude/scripts/ergodic/interactive-cpu.sh [hours] [nodes]` |
| Submit a batch job | `~/.claude/scripts/ergodic/submit-batch.sh <sbatch-path>` |
| List your jobs | `~/.claude/scripts/ergodic/squeue.sh` |
| Job accounting | `~/.claude/scripts/ergodic/sacct.sh <jobid> [jobid2 ...]` |
| Cancel one job (by id) | `~/.claude/scripts/ergodic/scancel.sh <jobid>` |
| Cat a remote log | `~/.claude/scripts/ergodic/read-log.sh <relpath>` |
| Grep a remote log | `~/.claude/scripts/ergodic/grep-log.sh <pattern> <relpath>` |
| Remote git SHA | `~/.claude/scripts/ergodic/remote-sha.sh [subdir]` |

Operations not covered by the scripts (venv mutation, custom launch, pulling artifacts back, multi-node launch) still go through inline `ssh perlmutter "…"` as shown below — those need the user to see the full command before approving.

**Anti-pattern:** chaining a script with a free-form ssh — `Bash(scripts/sync-up.sh && ssh perlmutter "<something unsafe>")` defeats the allowlist. Invoke scripts standalone, then issue any free-form command as a separate `Bash` call.

## Conventions

The skill is project-agnostic. It assumes the user runs Claude from inside their working repo on their laptop. Derived paths:

```
LOCAL_DIR   = $(pwd)                                           # the repo Claude was launched in
REPO        = $(basename "$PWD")                               # repo name, used in remote paths
REMOTE_DIR  = $PSCRATCH/$REPO/                           # rsynced code + run outputs on NERSC
VENV        = /global/common/software/m4490/$USER/venvs/$REPO  # uv venv (persistent, fast on compute, read-only from compute nodes)
ACCOUNT     = m4490
SSH_HOST    = perlmutter                                       # ssh alias configured by sshproxy
QOS         = interactive
CONSTRAINT  = gpu
TIME_LIMIT  = 01:00:00                                         # interactive QOS cap is 1 hour
```

`$USER`, `$PSCRATCH` are expanded by the remote shell. The user's local repo dir becomes the basename used for remote paths, so two different projects don't collide on NERSC.

## CRITICAL: login nodes vs compute nodes

**`/global/common/software/` is mounted read-only on compute nodes.** This means:

| Operation | Must run on |
| --- | --- |
| `uv venv`, `uv pip install`, `uv sync`, `uv add`, `uv pip compile`, any env mutation | **Login node** (plain `ssh perlmutter "…"` — no `salloc`) |
| Reading the venv to run code (`python`, `uv run`) | Either, but typically compute node inside `srun` |

When this skill calls plain `ssh perlmutter "…"`, you land on a login node — that's where venv mutations belong.
When this skill calls `ssh -tt perlmutter "salloc … srun …"`, the `srun` body runs on a compute node — **only read the venv there, never mutate it**. Specifically: never run `uv sync` / `uv pip install` / `uv venv` inside a salloc'd shell. If you need to update deps, exit the allocation, run uv on the login node, then relaunch.

## Operations

### Ensure venv exists (idempotent — call before first launch and after dep changes)

Most projects need a Python venv on Perlmutter before `python -u` can run anything. The skill manages this so the user doesn't have to. Always call this **after** sync (so `pyproject.toml`/`requirements.txt` are present on the remote side) and **before** launch.

**Runs on login node** (plain `ssh perlmutter`) — the venv lives on global common, which is writable only from login nodes.

```bash
REPO=$(basename "$PWD")
ssh perlmutter bash -lc "'
set -euo pipefail
VENV=\"/global/common/software/m4490/\$USER/venvs/${REPO}\"
REMOTE_DIR=\"\$PSCRATCH/${REPO}\"

mkdir -p \"\$(dirname \"\$VENV\")\"
cd \"\$REMOTE_DIR\"

if [ ! -d \"\$VENV\" ]; then
  echo \"[venv] creating \$VENV\"
  uv venv \"\$VENV\" --python 3.11
fi

source \"\$VENV/bin/activate\"
export UV_PROJECT_ENVIRONMENT=\"\$VENV\"

if [ -f pyproject.toml ]; then
  echo \"[venv] uv pip install -e . (from pyproject.toml)\"
  uv pip install -e .
elif [ -f requirements.txt ]; then
  echo \"[venv] uv pip install -r requirements.txt\"
  uv pip install -r requirements.txt
else
  echo \"[venv] no pyproject.toml or requirements.txt — venv created empty\"
fi
'"
```

Notes for Claude:
- `bash -lc` is important: it sources the user's login profile so `uv` is on PATH and the cache/python-install env vars are set up correctly.
- This is idempotent — safe to run every time before launch. uv is fast on no-op installs.
- First-time venv creation + adept's deps takes ~3–10 minutes on the login node. Subsequent calls are seconds. Warn the user on first run so they don't think it's hung.
- If `uv` is not on PATH on the login node, the user hasn't run `bootstrap-nersc.sh` yet — say so and stop.
- Don't fall back to `pip` or `conda`. If uv fails, surface the error.
- **Never run this inside `salloc` / `srun`.** Global common is read-only on compute nodes.

### Rebuild venv from scratch (only if it's corrupted or the user asks)

Destructive — confirm with the user first. Runs on login node.
```bash
REPO=$(basename "$PWD")
ssh perlmutter "rm -rf /global/common/software/m4490/\$USER/venvs/${REPO}"
# then call "ensure venv exists" again
```

### Sync local to NERSC

```bash
~/.claude/scripts/ergodic/sync-up.sh
```

Stamps `.git_commit` (so the training script can log the SHA to MLflow) and rsyncs the cwd to `$PSCRATCH/<repo>/` with the standard exclusions (`__pycache__`, `.git`, `.venv`, `checkpoints/`, `runinfo/`, `plots/`, `*.ipynb_checkpoints`, `uv.lock`).

## Choosing a run pattern

Two patterns; pick deliberately.

| Pattern | When to use | How |
| --- | --- | --- |
| **Persistent allocation + attach** (preferred for iterative dev) | Running a sim, looking at output, tweaking config, running again. Multiple commands in the same allocation. Live debugging. | `interactive-gpu.sh` → `ssh -tt perlmutter "srun --jobid=<JOBID> --pty bash"` → work on the compute node directly |
| **One-shot fire-and-forget** | Automated launches Claude is going to monitor by tailing a log. Allocation lifetime = command lifetime. | `ssh -tt perlmutter "salloc … srun bash -c '…'"` — see "Run on compute node" below |

For **parameter scans / sweeps**, neither shell pattern is the right tool — use the parsl + LocalProvider pattern documented in the `adept-run` skill. parsl launches workers inside whichever allocation you've already got (laptop or NERSC), so the same script works in both. Do **not** loop a shell over configs.

**Launching a parsl scan on a compute node — activate the venv; don't bypass it.** `source $VENV/bin/activate` then `python scan.py` (and put the same `source …/activate` in the parsl `worker_init`). Two ways to get this wrong, both seen in practice:
- `$VENV/bin/python scan.py` (bare interpreter path, no activation) → parsl's HighThroughputExecutor launches its `interchange.py` helper off `PATH`, and `$VENV/bin` isn't on `PATH`, so the run dies seconds in with `FileNotFoundError: 'interchange.py'`.
- `uv run … python scan.py` → `uv run` re-resolves against the (often stale) `uv.lock` and tries to sync the project env, but the venv lives on read-only `/global/common/...` on compute nodes and is shared with concurrent runs. Best case it errors; worst case it disturbs other jobs.

Activation is PATH-only (sets `PATH`/`VIRTUAL_ENV`, no install/sync), so it fixes the `interchange.py` lookup without touching the shared venv.

**Sharding one run across multiple GPUs per node (vs. one run per GPU):** set the HTEX `available_accelerators` to *grouped* device lists — `["0,1,2,3"]` gives one worker that owns all 4 GPUs (so `jax.devices()==4` and the solver can shard across them), whereas `available_accelerators=4` gives four single-GPU workers. For multi-node, pair this with `LocalProvider(nodes_per_block=N, max_blocks=1, launcher=SrunLauncher(overrides="--ntasks-per-node 1 --gpus-per-node 4"))` so a single srun starts one worker pool per node (`nodes_per_block=1 + max_blocks=N` makes blocks share `$SLURM_JOB_NAME` and clobber each other's cmd script). The sbatch/salloc body runs `python scan.py` directly — **not** wrapped in an outer `srun`, which would collide with parsl's internal srun.

### Attach to a persistent interactive allocation (preferred for dev iteration)

After allocating with `~/.claude/scripts/ergodic/interactive-gpu.sh <hrs>` (which uses `salloc --no-shell` and prints `<JOBID>`):

```bash
ssh -tt perlmutter "srun --jobid=<JOBID> --pty bash"
# now on the compute node:
cd $PSCRATCH/<repo>
source /global/common/software/m4490/$USER/venvs/<repo>/bin/activate
source /global/common/software/m4490/$USER/ergodic-claude.sh
uv run run.py --cfg <config-path-no-yaml>     # or whatever the project's launch is
```

The allocation persists until its walltime expires or you `scancel` it — you can exit the tty and re-attach with the same `ssh -tt … srun --jobid=<JOBID> --pty bash` to run another command.

**Same compute-node rules apply:** no `uv sync` / `uv pip install` / `uv venv` inside the attached shell — global common is read-only here. Exit, mutate on the login node, re-attach.

### Run on compute node (one-shot, automated launches)

Allocate an interactive node and run training. Output is captured to a local log and backgrounded so the user can monitor it.

The launch sources `/global/common/software/m4490/$USER/ergodic-claude.sh` (installed by `bootstrap-nersc.sh`) to get MLflow env vars + credentials, then activates the project venv, then runs python. **No `uv` mutations happen here** — the venv was prepared on the login node by the previous step.

**`salloc` here must request `--gpus-per-node` explicitly — `--constraint=gpu` alone is not enough.** Slurm draws GPU device visibility at two different levels: the **job** (the `salloc` allocation itself) and the **step** (each `srun` invocation run inside it), and GRES bound to one isn't automatically bound to the other. A plain interactive `salloc` shell — run *without* `--no-shell` and with no `srun` wrapping your command — executes your commands at the job level and sees all 4 GPUs on an exclusive node with no extra flag, since there's no separate step boundary involved. But the one-shot `salloc ... srun bash -c '...'` commands below run your training command as an `srun` **job step** (every launch path in this skill goes through `srun`), and Slurm builds a step's GPU device cgroup from the GRES requested *for that step*, not from the node's exclusivity. `--constraint=gpu` only steers node *selection* — it requests no GRES at all — so without `--gpus-per-node`, the step gets `CUDA_ERROR_NO_DEVICE` even though `squeue`/`AllocTRES` shows the node's A100s allocated to the job. `interactive-gpu.sh`/`interactive-gpu-node.sh` already pass `--gpus-per-node ${EC_GPUS_PER_NODE}` for the same reason — the one-shot commands below build their own `salloc` call directly, so they need the flag too.

**Single node (default):**
```bash
REPO=$(basename "$PWD")
ssh -tt perlmutter "salloc --nodes=1 --gpus-per-node=4 --qos=interactive --time=01:00:00 --constraint=gpu --account=m4490 --job-name=${REPO}-train srun bash -c 'source /global/common/software/m4490/\$USER/ergodic-claude.sh && source /global/common/software/m4490/\$USER/venvs/${REPO}/bin/activate && cd \$PSCRATCH/${REPO} && python -u train.py'" > /tmp/nersc_${REPO}.log 2>&1 &
```

**Multi-node (only if the workload genuinely needs >1 node):**
```bash
REPO=$(basename "$PWD")
ssh -tt perlmutter "salloc --nodes=4 --gpus-per-node=4 --qos=interactive --time=01:00:00 --constraint=gpu --account=m4490 --job-name=${REPO}-train bash -c 'source /global/common/software/m4490/\$USER/ergodic-claude.sh && source /global/common/software/m4490/\$USER/venvs/${REPO}/bin/activate && cd \$PSCRATCH/${REPO} && python -u train.py'" > /tmp/nersc_${REPO}.log 2>&1 &
```

**IMPORTANT: multi-node must NOT wrap the user command in `srun`.** Frameworks like Parsl/torchrun internally launch workers via `srun --overlap`; an outer `srun` conflicts and produces interconnect errors. Use `srun` only for single-node; use `bash -c '...'` for multi-node.

**Caveat — the multi-node one-shot driver runs on the login node, tied to your ssh.** Because the `bash -c '…'` body isn't wrapped in `srun`, it executes on the login/submit node (parsl then `srun`s the workers onto the compute nodes). If that ssh drops or the login node reboots, the driver is SIGHUP'd and the whole run tears down — the ~20–30 min failure people hit on long scans. **For multi-node runs ≤ 4 h, detach the login driver** (`setsid …` / `nohup …`) — that's the default for unattended multi-node. For a run that may exceed the 4 h interactive cap, or to keep the driver off the login node entirely, use **`sbatch`** instead (below).

### Multi-node alternative: sbatch (no detach)

This is an **alternative** to detaching the multi-node one-shot, not a replacement: for runs **≤ 4 h, prefer the detached one-shot** (interactive, faster to schedule). Reach for `sbatch` when a run may exceed the 4 h interactive cap, or when you want the driver off the reboot-prone login node. A batch job runs its script on a **compute node under SLURM**, with nothing tied to your terminal — so ssh drops and login reboots can't kill it, and no `setsid` / `nohup` is needed. The parsl part is unchanged: the script still runs `python -u scan.py` with **no outer srun** (parsl's `SrunLauncher` does the internal `srun --overlap`).

Copy the template `skills/nersc-workflow/run-scan.sbatch` into the campaign next to its `scan.py`, set `DRIVER`, then submit + monitor:

```bash
~/.claude/scripts/ergodic/submit-batch.sh sims/<campaign>/run-scan.sbatch
~/.claude/scripts/ergodic/squeue.sh
~/.claude/scripts/ergodic/read-log.sh workdir/<repo>-<jobid>.out
```

The template hardcodes `--account=m4490_g`, `--qos=interactive` (switch to `regular` for longer than the interactive cap), `--nodes=4 --gpus-per-node=4`, and `--output=workdir/%x-%j.out` (`workdir/` survives `sync-up`'s `--delete`). `submit-batch.sh` does `mkdir -p workdir` first so the log can open.

**Detach vs sbatch — both stay fully inspectable** (`squeue` / `sacct` / `read-log` / `srun --jobid=<id> --overlap` attach all work either way):

| | Detached salloc one-shot | sbatch |
| --- | --- | --- |
| Pros | Interactive QOS, nodes now (no batch queue); fast dev iteration | Compute-node driver — immune to ssh drops *and* login reboots; no detach ceremony; `regular` lifts the interactive walltime cap |
| Cons | Driver lives on the shared, reboot-prone login node; manual `setsid`/`disown` ceremony, easy to fumble; un-SLURM-managed stray process | Queues (not instant); less live/interactive |

Rule of thumb: **multi-node ≤ 4 h → detached one-shot (preferred); a run that may exceed 4 h, or that you want fully SLURM-managed and login-independent → `sbatch`.**

**Running on a parked allocation (e.g. an `interactive-shared.sh` slice):** the `interactive-*.sh` scripts use `salloc --no-shell`, which leaves the allocation sitting in the queue. To run on it, read its job id from `squeue` and `srun --jobid=<id> --overlap` into it — **do not** issue a fresh `salloc` (that allocates a *second* node and bypasses the shared slice you just reserved).
```bash
REPO=$(basename "$PWD")
JOBID=<id from squeue>
ssh perlmutter "srun --jobid=${JOBID} --overlap bash -c 'source /global/common/software/m4490/\$USER/ergodic-claude.sh && source /global/common/software/m4490/\$USER/venvs/${REPO}/bin/activate && cd \$PSCRATCH/${REPO} && python -u train.py'"
```

Notes:
- `python -u` for unbuffered output (so `tail -f` of the log is responsive).
- `ergodic-claude.sh` provides `MLFLOW_TRACKING_URI` and (via `~/.mlflow_credentials`) `MLFLOW_TRACKING_USERNAME` / `MLFLOW_TRACKING_PASSWORD`. If those are empty, the user hasn't filled in their credentials yet — point them at `vim ~/.mlflow_credentials` on Perlmutter.
- For adept (the usual case), the entry point should be `uv run run.py --cfg <name>` (single run) or a parsl scan script — see the `adept-run` skill for which to use. Don't substitute the launch command without checking.
- The interactive QOS caps at 1 hour — for longer runs the user must switch to `--qos=regular` and a different time limit.

### Monitor

**Local log (training stdout):**
```bash
tail -50 /tmp/nersc_$(basename "$PWD").log
```

**SLURM queue:**
```bash
~/.claude/scripts/ergodic/squeue.sh
```

**Job accounting (state, exit code, elapsed):**
```bash
~/.claude/scripts/ergodic/sacct.sh <jobid>
```

**Remote outputs (free-form `ls` — not covered by a script):**
```bash
ssh perlmutter "ls -la \$PSCRATCH/$(basename "$PWD")/checkpoints/ 2>/dev/null"
```

**Read / grep a remote log file:**
```bash
~/.claude/scripts/ergodic/read-log.sh slurm-<jobid>.out
~/.claude/scripts/ergodic/grep-log.sh 'error\|fail' slurm-<jobid>.out
```

For MLflow metrics, switch to the `mlflow-query` skill.

### Pull results back

Resolve `$PSCRATCH` first, then rsync to/from the absolute path. Don't put a
literal `\$PSCRATCH` in an rsync remote arg expecting the remote shell to expand
it: rsync 3.2.4+ backslash-escapes shell metacharacters (incl. `$`) in remote
paths as injection hardening, so it's taken literally and rsync looks under
`~/$PSCRATCH/...`. (This is why `sync-up.sh` resolves the path up front too.)

```bash
REPO=$(basename "$PWD")
REMOTE_SCRATCH=$(ssh perlmutter 'echo $PSCRATCH')
rsync -avz "perlmutter:${REMOTE_SCRATCH}/${REPO}/checkpoints/" ./checkpoints/
rsync -avz "perlmutter:${REMOTE_SCRATCH}/${REPO}/plots/"       ./plots/
```

### Cancel job

Identify the job id first, then cancel by id. **Never blanket-cancel by name or by user** — teammates and other concurrent jobs share the account.

```bash
~/.claude/scripts/ergodic/squeue.sh
~/.claude/scripts/ergodic/scancel.sh <JOB_ID>
```

Kill the local backgrounded ssh:
```bash
kill $(pgrep -f "ssh -tt perlmutter.*salloc.*$(basename "$PWD")")
```

### Clean up remote artifacts

Destructive — confirm with the user first.
```bash
REPO=$(basename "$PWD")
ssh perlmutter "rm -rf \$PSCRATCH/${REPO}/checkpoints/* \$PSCRATCH/${REPO}/plots/*"
```

## Iteration workflow

The typical loop is: edit locally → sync → ensure venv → cancel old job → run → monitor → pull results → repeat.

The venv step is fast after the first time. Don't skip it just because "it probably exists" — the user may have switched projects, changed Python deps, or never run this repo on NERSC before.

## Guidelines

- The canonical order for a launch is: **sync → ensure venv → launch**. Never launch without checking the venv exists — undergrads and new joiners will not have run any setup manually.
- When the user says "run on NERSC" or "launch training", do all three in order.
- When iterating, cancel the old job first, then sync → ensure venv → relaunch. The venv check is cheap on the iteration path (just a pyproject hash check + no-op).
- For monitoring, check the local log first (fastest). Fall back to `squeue` if the log is stale.
- The `mlflow-query` skill is the right tool for checking metrics — use it alongside this one.
- The `adept-run` skill is the right tool for deciding *what command to run* (ergoExo vs. parsl scan vs. direct module). This skill handles only the NERSC infra.
- Destructive operations (cancel, cleanup) require explicit user confirmation.
- If the user hasn't run `bootstrap-nersc.sh` yet, the venv/scratch dirs won't exist — point them at the repo README.

$ARGUMENTS
