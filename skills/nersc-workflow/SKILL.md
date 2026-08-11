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
| Commit-pinned isolated run (checkout SHA → own dir → sbatch) | `~/.claude/scripts/ergodic/launch-pinned.sh [opts] <cfg…>` |
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
LOCAL_DIR   = $(pwd)                     # the repo Claude was launched in
REPO        = $(basename "$PWD")         # repo name, used in remote paths
REMOTE_DIR  = $PSCRATCH/$REPO/           # rsynced code + run outputs on NERSC
VENV        = $SW/$USER/venvs/$REPO      # uv venv (persistent, fast on compute, read-only from compute nodes)
SSH_HOST    = perlmutter                 # ssh alias configured by sshproxy
QOS         = interactive
CONSTRAINT  = gpu
TIME_LIMIT  = 04:00:00                   # gpu_interactive MaxWall; verify with sacctmgr
```

`$USER`, `$PSCRATCH` are expanded by the remote shell. The user's local repo dir becomes the basename used for remote paths, so two different projects don't collide on NERSC.

> **`REPO = $(basename "$PWD")` breaks in a git worktree.** Claude launched from
> `.claude/worktrees/my-branch-a32198/` derives `REPO=my-branch-a32198`, so `sync-up.sh` and
> `submit-batch.sh` target `$PSCRATCH/my-branch-a32198/` — a directory that does not exist and,
> worse, is **not** where the venv's editable install points. Symptoms: `submit-batch.sh` dies
> with `cd: no such file or directory`, or a job runs against a stale tree. From a worktree,
> rsync and submit against `$PSCRATCH/<real-repo-name>/` explicitly, and confirm the venv's
> target first:
>
> ```bash
> ssh perlmutter 'cat $ECLAUDE_VENVS/<repo>/lib/python*/site-packages/__editable__*<repo>*.pth 2>/dev/null || \
>                 cat $ECLAUDE_VENVS/<repo>/lib/python*/site-packages/_editable_impl_*<repo>*.pth'
> ```

> **Requiring `hbm80g` can mean waiting forever.** The 80 GB pool is ~250 nodes against ~1500
> for plain `gpu`, and it is routinely fully allocated (measured 2026-08-11: `alloc 252,
> drain 126, idle 0` — a 4-node interactive request had no path to running, while plain `gpu`
> had idle nodes). Ask for it only when you have measured that the job needs >40 GB, and say
> which measurement. Check before committing:
>
> ```bash
> ssh perlmutter 'sinfo -h -o "%b|%t|%D" | grep hbm80g | awk -F"|" "{a[\$2]+=\$3} END{for(k in a) print k, a[k]}"'
> ```

### Never hardcode the account or the project space — read them from config

`ACCOUNT`, the GPU account, and `SW` (the project's global-common dir) are **per-user
config**, not constants: NERSC users typically belong to several projects, and the SLURM
account decides which allocation gets billed. Resolve them at the start of any command that
needs them:

```bash
ACCOUNT=$(~/.claude/scripts/ergodic/show-config.sh EC_ACCOUNT)          # e.g. m4490 — CPU jobs
ACCOUNT_GPU=$(~/.claude/scripts/ergodic/show-config.sh EC_ACCOUNT_GPU)  # e.g. m4490_g — GPU jobs
SW=$(~/.claude/scripts/ergodic/show-config.sh EC_SOFTWARE_ROOT)         # /global/common/software/<project>
```

- `show-config.sh` with no argument prints everything that resolved (and where from) — run it
  when a job is billed to a surprising project or a venv path looks wrong.
- The `interactive-*.sh`, `submit-batch.sh`, and `launch-pinned.sh` helpers already do this
  themselves and **refuse to run with no account configured** rather than guessing. You only
  need the lines above for free-form `ssh perlmutter "salloc … / srun …"` commands.
- If `EC_ACCOUNT` is empty: `~/.claude/scripts/ergodic/list-accounts.sh` prints the projects
  the user can actually charge (from SLURM's own associations), then the user picks one — via
  `./scripts/bootstrap-nersc.sh` or by writing `: "${EC_ACCOUNT:=<proj>}"` into
  `~/.config/ergodic-claude/config.sh`. **Ask; never pick a project for them.**
- GPU work bills the `_g` account, CPU work the bare one. The project *directory* on global
  common is always the bare name.

## CRITICAL: login nodes vs compute nodes

**`/global/common/software/` is mounted read-only on compute nodes.** This means:

| Operation | Must run on |
| --- | --- |
| `uv venv`, `uv pip install`, `uv sync`, `uv add`, `uv pip compile`, any env mutation | **Login node** (plain `ssh perlmutter "…"` — no `salloc`) |
| Reading the venv to run code (`python`, `uv run`) | Either, but typically compute node inside `srun` |

When this skill calls plain `ssh perlmutter "…"`, you land on a login node — that's where venv mutations belong.
When this skill calls `ssh -tt perlmutter "salloc … srun …"`, the `srun` body runs on a compute node — **only read the venv there, never mutate it**. Specifically: never run `uv sync` / `uv pip install` / `uv venv` inside a salloc'd shell. If you need to update deps, exit the allocation, run uv on the login node, then relaunch.

## Hard constraints from NERSC (not negotiable)

NERSC's [coding-agent guidance](https://docs.nersc.gov/development/coding-agents/) governs
anything an agent does on their systems, including through `ssh perlmutter "…"` from a
laptop. The full text ships in this repo at `rules/nersc-agent-rules.md` and is installed
into `~/.claude/CLAUDE.md` (both laptop and Perlmutter) by the bootstrap scripts, so it
binds whether or not this skill is loaded. The parts that bite hardest here:

**Never recursively traverse a shared filesystem** — `/`, `/global`, `/global/cfs`,
`/global/homes`, `/pscratch`, `/opt`, `/usr`. Not with `find`, `fd`, `tree`, recursive `du`,
`rg --files`, recursive `grep`/`ls`, globstar, or a Python walk; not on login nodes and not
on compute nodes. A login node is shared by hundreds of users and CFS/scratch are network
filesystems — one unbounded walk is a metadata storm that degrades the system for everyone,
which is why NERSC states the rule rather than suggesting it. A compute allocation is not
permission for an unbounded walk either.

Search a bounded root instead, with a depth cap. The roots that are almost always what you
actually wanted:

```bash
ssh perlmutter 'ls -la $PSCRATCH/<repo>/checkpoints'
ssh perlmutter 'find $PSCRATCH/<repo> -maxdepth 3 -name "*.h5"'
ssh perlmutter "ls ${SW}/\$USER/venvs"
```

To locate software, ask the system, don't crawl it: `command -v`, `type -a`,
`module spider <name>`, `module avail <name>`, `uv pip show <pkg>`. If you don't know a
bounded root, **ask the user** — don't widen the search, and don't reach for a different
command that scans the same ground.

**Secrets stay in files.** Never put a token, password, or private key in a prompt, a
command line, a commit, or a log. MLflow creds come from `~/.mlflow_credentials` (sourced by
`ergodic-claude.sh`); the pinned-run deploy key comes from `~/.ssh/<repo>-deploy`. Read a
credential file only when diagnosing an auth failure, and never echo its contents.

**You hold the user's own permissions**, and your project's allocation is shared with
teammates. Nothing here is sandboxed: a bad `scancel`, `rm -rf`, or overwriting rsync hits
real jobs and real data. Writes belong under `$PSCRATCH/<repo>/` (or `$HOME`) — if source
data lives on `$CFS`, copy what you need into the scratch working dir and work on the copy.

## Operations

### Ensure venv exists (idempotent — call before first launch and after dep changes)

Most projects need a Python venv on Perlmutter before `python -u` can run anything. The skill manages this so the user doesn't have to. Always call this **after** sync (so `pyproject.toml`/`requirements.txt` are present on the remote side) and **before** launch.

**Runs on login node** (plain `ssh perlmutter`) — the venv lives on global common, which is writable only from login nodes.

```bash
REPO=$(basename "$PWD")
SW=$(~/.claude/scripts/ergodic/show-config.sh EC_SOFTWARE_ROOT)
ssh perlmutter bash -lc "'
set -euo pipefail
VENV=\"${SW}/\$USER/venvs/${REPO}\"
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
SW=$(~/.claude/scripts/ergodic/show-config.sh EC_SOFTWARE_ROOT)
ssh perlmutter "rm -rf ${SW}/\$USER/venvs/${REPO}"
# then call "ensure venv exists" again
```

### Sync local to NERSC

```bash
~/.claude/scripts/ergodic/sync-up.sh
```

Stamps `.git_commit` (so the training script can log the SHA to MLflow) and rsyncs the cwd to `$PSCRATCH/<repo>/` with the standard exclusions (`__pycache__`, `.git`, `.venv`, `checkpoints/`, `runinfo/`, `plots/`, `*.ipynb_checkpoints`, `uv.lock`).

> **Shared-dir hazard.** `sync-up.sh` rsyncs into a *single* per-repo dir (`$PSCRATCH/<repo>/`), and the venv's editable install points there. Switch branches locally and re-sync and that dir is **overwritten** — silently breaking any job still queued or running against the old tree (its config/solver vanish → the job dies at startup). For anything that must survive concurrent branches or long queue waits (production batch jobs, multi-day runs), use **commit-pinned isolated runs** (`launch-pinned.sh`, below) instead.

## Choosing a run pattern

Three patterns; pick deliberately.

| Pattern | When to use | How |
| --- | --- | --- |
| **Persistent allocation + attach** (preferred for iterative dev) | Running a sim, looking at output, tweaking config, running again. Multiple commands in the same allocation. Live debugging. | `interactive-gpu.sh` → `ssh -tt perlmutter "srun --jobid=<JOBID> --pty bash"` → work on the compute node directly |
| **One-shot fire-and-forget** | Automated launches Claude is going to monitor by tailing a log. Allocation lifetime = command lifetime. | `ssh -tt perlmutter "salloc … srun bash -c '…'"` — see "Run on compute node" below |
| **Commit-pinned isolated run** (preferred for production / long-queue batch) | A run that must be reproducible and immune to later branch switches — production sweeps, multi-hour/day batch jobs, anything you'll queue then walk away from. | `launch-pinned.sh` — see below |

For **parameter scans / sweeps**, neither shell pattern is the right tool — use the parsl + LocalProvider pattern documented in the `adept-run` skill. parsl launches workers inside whichever allocation you've already got (laptop or NERSC), so the same script works in both. Do **not** loop a shell over configs.

**Wider than one node?** Still parsl + `LocalProvider` — see *"Multi-node GPU scan — 16 runs on 16 GPUs (canonical)"* in `adept-run`. That config (one block per node, `available_accelerators=4`, `SrunLauncher(overrides="-c 32 --gpus-per-node 4")`, `retries=2`) is the production one from `ml-for-lpi` and is what to use for a 4-node/16-GPU/16-run scan. `SlurmProvider` is not needed for this. This skill's job is only to hand it an N-node allocation and put the driver in the right place.

**Launching a parsl scan on a compute node — activate the venv; don't bypass it.** `source $VENV/bin/activate` then `python scan.py` (and put the same `source …/activate` in the parsl `worker_init`). Two ways to get this wrong, both seen in practice:
- `$VENV/bin/python scan.py` (bare interpreter path, no activation) → parsl's HighThroughputExecutor launches its `interchange.py` helper off `PATH`, and `$VENV/bin` isn't on `PATH`, so the run dies seconds in with `FileNotFoundError: 'interchange.py'`.
- `uv run … python scan.py` → `uv run` re-resolves against the (often stale) `uv.lock` and tries to sync the project env, but the venv lives on read-only `/global/common/...` on compute nodes and is shared with concurrent runs. Best case it errors; worst case it disturbs other jobs.

Activation is PATH-only (sets `PATH`/`VIRTUAL_ENV`, no install/sync), so it fixes the `interchange.py` lookup without touching the shared venv.

### Commit-pinned isolated runs (`launch-pinned.sh`) — production / long-queue jobs

`sync-up.sh` + attach is ideal for fast iteration, but every run shares one mutable dir (`$PSCRATCH/<repo>/`) and the venv's editable install points into it. Switch branches locally, re-sync, and that dir is overwritten — a job still queued or running against the old tree dies at startup (config/solver gone). This bites hardest for batch jobs that sit in the queue for hours while you move on to other work.

`launch-pinned.sh` removes the shared mutable state:

- checks out a **specific commit** into its own dir `$PSCRATCH/<repo>-runs/<sha>/` (bare mirror + `git worktree`, via a read-only deploy key) — immutable, never rsynced over;
- imports the project package from that tree via `PYTHONPATH`, so it neither depends on nor disturbs the shared venv's editable link (concurrent runs of different commits don't collide);
- generates + submits one sbatch per config from the isolated dir; logs land in `<sha>/logs/` and are never swept.

```bash
# from inside the repo on the laptop:
~/.claude/scripts/ergodic/launch-pinned.sh [options] <cfg1> [cfg2 ...]
#   <cfgN>       config path relative to repo root, WITHOUT .yaml
#   --sha <sha>  commit to deploy (default: local HEAD; must be pushed)
#   --nodes N    nodes per job (default 1)
#   --time T     walltime HH:MM:SS (default 04:00:00)
#   --qos Q      SLURM QOS (default regular)
#   --gpus N     GPUs per node (default 4)
#   --multinode  set PIC2D_MULTINODE=1 + one task PER GPU (jax.distributed)
#   --dry-run    print the generated sbatch without submitting
```

**One-time prereq — read-only deploy key.** Perlmutter can't clone a private GitHub repo out of the box (no `gh`, no SSH key). Generate a key on Perlmutter and add its public half as a repo deploy key (read-only):

```bash
ssh perlmutter "ssh-keygen -t ed25519 -f ~/.ssh/<repo>-deploy -N '' -C '<repo>-deploy@perlmutter'; cat ~/.ssh/<repo>-deploy.pub"
gh repo deploy-key add <pubkey-file> --title "perlmutter-<repo> (read-only)" --repo <owner>/<repo>
```

The launcher uses `GIT_SSH_COMMAND` with `~/.ssh/<repo>-deploy` for all git ops.

**Deps.** The shared venv still provides third-party deps (adept, jax, …); only the project package comes from the pinned tree (via `PYTHONPATH`). If a commit adds a dependency, install it into the shared venv on the login node once — that's additive and won't repoint the editable link. Do **not** `uv pip install -e` the pinned tree into the shared venv; that reintroduces the shared-state hazard.

**Sharding one run across multiple GPUs per node (vs. one run per GPU):** set the HTEX `available_accelerators` to *grouped* device lists — `["0,1,2,3"]` gives one worker that owns all 4 GPUs (so `jax.devices()==4` and the solver can shard across them), whereas `available_accelerators=4` gives four single-GPU workers. The sbatch/salloc body runs `python scan.py` directly — **not** wrapped in an outer `srun`, which would collide with parsl's internal srun.

For multi-node, use the **same** provider shape as the one-run-per-GPU scan —
`nodes_per_block=1, max_blocks=nodes`, `SrunLauncher(overrides="-c 32 --gpus-per-node 4")` —
and change only `available_accelerators`. Verified 2026-08-11 on 4 nodes: grouped
`["0,1,2,3"]` gave one manager per node reporting `Accelerators: 0,1,2,3` and one 4-GPU worker
each, no bind errors; the one-per-GPU form on the same provider gave `Accelerators: 0 1 2 3`
and 16 workers. **Do not add `--ntasks-per-node 1`** to the launcher overrides — that is what
the earlier version of this note prescribed, and it fails to bind CPUs (see the parsl driver
exception below).

**One block layout for both.** Use `nodes_per_block=1, max_blocks=N` (N sruns, one per node)
whether you want one run per GPU or one 4-GPU run per node — see `adept-run` for the canonical
config. An earlier version of these notes had the sharded form on `nodes_per_block=N,
max_blocks=1`, but the same 4-node test that validated the grouped accelerators above ran it on
one-block-per-node without trouble, so there is no need to keep two shapes in your head.

A previous note here warned that `nodes_per_block=1 + max_blocks=N` makes blocks share
`$SLURM_JOB_NAME` and clobber each other's cmd script. `ml-for-lpi` has run this layout in
production without it, and it did not reproduce in the 2026-08-11 test. Treat it as a symptom
to recognize, not a reason to avoid the config: if blocks die at launch with a missing or
truncated cmd script, this is what you're looking at.

### Attach to a persistent interactive allocation (preferred for dev iteration)

After allocating with `~/.claude/scripts/ergodic/interactive-gpu.sh <hrs>` (which uses `salloc --no-shell` and prints `<JOBID>`):

```bash
ssh -tt perlmutter "srun --jobid=<JOBID> --pty bash"
# now on the compute node:
cd $PSCRATCH/<repo>
source ~/.bash_profile.ext                        # ergodic-claude.sh: MLflow env + creds, $ECLAUDE_VENVS
source $ECLAUDE_VENVS/<repo>/bin/activate         # no hardcoded project dir — it comes from the env file
uv run run.py --cfg <config-path-no-yaml>         # or whatever the project's launch is
```

The allocation persists until its walltime expires or you `scancel` it — you can exit the tty and re-attach with the same `ssh -tt … srun --jobid=<JOBID> --pty bash` to run another command.

**Same compute-node rules apply:** no `uv sync` / `uv pip install` / `uv venv` inside the attached shell — global common is read-only here. Exit, mutate on the login node, re-attach.

### Run on compute node (one-shot, automated launches)

Allocate an interactive node and run training. Output is captured to a local log and backgrounded so the user can monitor it.

The launch sources `${SW}/$USER/ergodic-claude.sh` (installed by `bootstrap-nersc.sh`) to get MLflow env vars + credentials, then activates the project venv, then runs python. **No `uv` mutations happen here** — the venv was prepared on the login node by the previous step.

**`salloc` here must request `--gpus-per-node` explicitly — `--constraint=gpu` alone is not enough.** Slurm draws GPU device visibility at two different levels: the **job** (the `salloc` allocation itself) and the **step** (each `srun` invocation run inside it), and GRES bound to one isn't automatically bound to the other. A plain interactive `salloc` shell — run *without* `--no-shell` and with no `srun` wrapping your command — executes your commands at the job level and sees all 4 GPUs on an exclusive node with no extra flag, since there's no separate step boundary involved. But the one-shot `salloc ... srun bash -c '...'` commands below run your training command as an `srun` **job step** (every launch path in this skill goes through `srun`), and Slurm builds a step's GPU device cgroup from the GRES requested *for that step*, not from the node's exclusivity. `--constraint=gpu` only steers node *selection* — it requests no GRES at all — so without `--gpus-per-node`, the step gets `CUDA_ERROR_NO_DEVICE` even though `squeue`/`AllocTRES` shows the node's A100s allocated to the job. `interactive-gpu.sh`/`interactive-gpu-node.sh` already pass `--gpus-per-node ${EC_GPUS_PER_NODE}` for the same reason — the one-shot commands below build their own `salloc` call directly, so they need the flag too.

**Single node (default):**
```bash
REPO=$(basename "$PWD")
SW=$(~/.claude/scripts/ergodic/show-config.sh EC_SOFTWARE_ROOT)
ACCOUNT_GPU=$(~/.claude/scripts/ergodic/show-config.sh EC_ACCOUNT_GPU)
ssh -tt perlmutter "salloc --nodes=1 --gpus-per-node=4 --qos=interactive --time=01:00:00 --constraint=gpu --account=${ACCOUNT_GPU} --job-name=${REPO}-train srun bash -c 'source ${SW}/\$USER/ergodic-claude.sh && source ${SW}/\$USER/venvs/${REPO}/bin/activate && cd \$PSCRATCH/${REPO} && python -u train.py'" > /tmp/nersc_${REPO}.log 2>&1 &
```

**Multi-node (only if the workload genuinely needs >1 node):**
```bash
REPO=$(basename "$PWD")
SW=$(~/.claude/scripts/ergodic/show-config.sh EC_SOFTWARE_ROOT)
ACCOUNT_GPU=$(~/.claude/scripts/ergodic/show-config.sh EC_ACCOUNT_GPU)
ssh -tt perlmutter "salloc --nodes=4 --gpus-per-node=4 --qos=interactive --time=01:00:00 --constraint=gpu --account=${ACCOUNT_GPU} --job-name=${REPO}-train srun --overlap --nodes=1 --ntasks=1 bash -c 'source ${SW}/\$USER/ergodic-claude.sh && source ${SW}/\$USER/venvs/${REPO}/bin/activate && cd \$PSCRATCH/${REPO} && python -u train.py'" > /tmp/nersc_${REPO}.log 2>&1 &
```

**IMPORTANT: multi-node wraps the driver in exactly `srun --overlap --nodes=1 --ntasks=1` — not a plain `srun`.** A plain outer `srun` (no flags) runs the command as an N-node job step and conflicts with the internal `srun --overlap` that Parsl/torchrun use to place workers (interconnect errors). The `--overlap --nodes=1 --ntasks=1` form instead runs the *driver* as a 1-task step on the head compute node, and the framework's internal worker srun still lays out across all nodes with full GPU pinning. Verified 2026-07-03 (Perlmutter, parsl HTEX + SrunLauncher): driver step `.0` on the head node, worker step `.1` spanning all nodes, workers GPU-pinned on every node, and a 1.5 h 8-run production scan completed with results byte-identical to its login-driver baseline.

**Why the driver goes on a compute node (and why you still detach):** an unwrapped `bash -c '…'` body executes on the login/submit node, exposed to two independent killers: (a) **SIGHUP** when your ssh drops or the login node reboots — the ~20–30 min failure people hit on long scans; (b) **SIGTERM from NERSC login-node process policing**, which reaps busy login-resident processes at random (observed: a healthy 12-GPU scan torn down at 38 min while identical launches elsewhere survived 2.5 h+; `setsid` does not block SIGTERM). The `srun --overlap -N1 -n1` wrapper removes the policing target: the only login-resident piece left is the near-idle `salloc` client. **Still detach the launch** (`setsid …` / `nohup …`) — salloc itself dies with your ssh session otherwise (SIGHUP). For a run that may exceed the 4 h interactive cap, use **`sbatch`** instead (below).

> ### EXCEPTION — a multi-node *parsl* driver must NOT be inside an `srun` step
>
> Everything above is for a driver that places its own workers (torchrun) or none at all.
> **It does not apply to the canonical one-block-per-node parsl scan** (`adept-run`,
> *"Multi-node GPU scan — 16 runs on 16 GPUs"*). There, each block is its own `srun`, and a
> driver already occupying a job step makes those worker sruns fail to bind CPUs — on every
> node, within seconds of submission:
>
> ```
> srun: error: CPU binding outside of job step allocation,
>              allocated CPUs are: 0x000000000000FFFF000000000000FFFF
> srun: error: Unable to satisfy cpu bind request
> -> parsl marks the block MISSING; every task dies with BadStateException
> ```
>
> The CPU mask in that message is a red herring. Requesting CPUs in the `salloc`
> (`--cpus-per-task=128`) does **not** fix it, and neither does adding `--overlap` to the
> worker launcher — both tried. The cause is the driver's step, and `ml-for-lpi`'s
> `launch/launch_ign.sh` records the same lesson independently ("0 connected workers", NOTES
> Run 23).
>
> **Correct placement for multi-node parsl:**
>
> | how you're running | where the driver goes |
> |---|---|
> | interactive (`salloc --no-shell`) | **login node**, with `SLURM_JOB_ID=<jobid>` exported, backgrounded with `nohup` |
> | batch (`sbatch`) | the sbatch body **directly** — no `srun` wrapper |
>
> ```bash
> # interactive: allocate, then drive from the login node
> alloc=$(ssh perlmutter "salloc --nodes=4 --gpus-per-node=4 --qos=interactive \
>   --time=04:00:00 --constraint=gpu --account=${ACCOUNT_GPU} --no-shell" 2>&1)
> JOBID=$(printf '%s\n' "$alloc" | grep -oE 'Granted job allocation [0-9]+' | grep -oE '[0-9]+$')
> ssh perlmutter "cd \$PSCRATCH/${REPO} && \
>   SLURM_JOB_ID=${JOBID} nohup python -u scan.py --nodes 4 > \$PSCRATCH/${REPO}/workdir/scan.log 2>&1 &"
> ```
>
> parsl then sruns the per-node worker pools **into** that allocation and they connect back to
> the driver's interchange. The login node having no GPU driver is fine and expected — the
> driver does no compute, and its jax falls back to CPU cleanly (no `CUDA_ERROR_NO_DEVICE`).
> The policing risk from (b) above is much lower here than for a busy driver, because a parsl
> driver is almost entirely idle while it waits on futures; still `nohup` it.
>
> **Verify in the first ~60 s** rather than discovering this an hour in — one manager per
> node, each owning that node's GPUs, and no bind errors:
>
> ```bash
> ssh perlmutter 'R=$(ls -td $PSCRATCH/<repo>/runinfo/*/ | head -1)
>   ls -d $R/*/block-*/*/ | wc -l                      # want: one per node
>   grep -h "Accelerators:" $R/*/block-*/*/manager.log  # want: "0 1 2 3" per node
>   grep -rl "cpu bind" $R | wc -l'                     # want: 0
> ```
>
> Observed 2026-08-11 on Perlmutter (parsl 2026.02.16): srun-wrapped driver → 0 workers on
> 4 nodes; login-node driver, same provider config → 4 managers, 16 workers, 0 bind errors.

### Multi-node alternative: sbatch (no detach)

This is an **alternative** to detaching the multi-node one-shot, not a replacement: for runs **≤ 4 h, prefer the detached one-shot** (interactive, faster to schedule; with the `srun --overlap -N1 -n1` driver wrapper it is equally login-independent apart from the idle salloc client). Reach for `sbatch` when a run may exceed the 4 h interactive cap. **`sbatch` cannot use the interactive QOS** — Perlmutter rejects it at submission (`sbatch: error: Cannot submit batch jobs to gpu_interactive_ss11`, tested 2026-07-03) — so batch jobs ride the `regular` queue (slower to schedule). A batch job runs its script on a **compute node under SLURM**, with nothing tied to your terminal — so ssh drops and login reboots can't kill it, and no `setsid` / `nohup` is needed. The parsl part is unchanged: the script still runs `python -u scan.py` with **no outer srun** (the sbatch script already executes on the head compute node, so the driver needs no placement wrapper there; parsl's `SrunLauncher` does the internal `srun --overlap`).

Copy the template `skills/nersc-workflow/run-scan.sbatch` into the campaign next to its `scan.py`, set `DRIVER`, then submit + monitor:

```bash
~/.claude/scripts/ergodic/submit-batch.sh sims/<campaign>/run-scan.sbatch
~/.claude/scripts/ergodic/squeue.sh
~/.claude/scripts/ergodic/read-log.sh workdir/<repo>-<jobid>.out
```

The template hardcodes `--qos=regular` (the interactive QOS rejects sbatch — see above), `--nodes=4 --gpus-per-node=4`, and `--output=workdir/%x-%j.out` (`workdir/` survives `sync-up`'s `--delete`). `submit-batch.sh` does `mkdir -p workdir` first so the log can open. It deliberately carries **no** `--account` and **no** hardcoded venv path: `submit-batch.sh` passes `-A $EC_ACCOUNT_GPU` on the command line (which overrides any `#SBATCH --account`), and the script resolves the venv through `$ECLAUDE_VENVS`. Pass `submit-batch.sh --account <acct>` for a CPU-only job.

**Detach vs sbatch — both stay fully inspectable** (`squeue` / `sacct` / `read-log` / `srun --jobid=<id> --overlap` attach all work either way):

| | Detached salloc one-shot (srun-wrapped driver) | sbatch |
| --- | --- | --- |
| Pros | Interactive QOS, nodes now (no batch queue); fast dev iteration; driver on a compute node (policing/reboot-immune) | Compute-node driver — immune to ssh drops *and* login reboots; no detach ceremony; `regular` lifts the interactive walltime cap |
| Cons | Idle `salloc` client still lives on the login node (dies if the login node itself reboots); manual `setsid`/`disown` ceremony, easy to fumble | `regular` queue only (interactive QOS rejects sbatch) — not instant; less live/interactive |

Rule of thumb: **multi-node ≤ 4 h → detached one-shot with the `srun --overlap -N1 -n1` driver wrapper (preferred); a run that may exceed 4 h → `sbatch` on `regular`.** For a multi-node **parsl** scan, drop the `srun` wrapper — see the exception above.

**One more reason batch may be the only option: the interactive QOS caps SUBMITTED jobs at 2 per user.** A third `salloc` is refused at submit time, not queued:

```
salloc: error: QOSMaxSubmitJobPerUserLimit
salloc: error: Job submit/allocate failed: Job violates accounting/QOS policy
```

So a campaign of more than two concurrent allocations has to put the remainder on `regular`. Read the live limits rather than trusting this line — `MaxWall`, `MaxSubmitJobsPU` and the per-job node cap all live in the QOS:

```bash
ssh perlmutter 'sacctmgr -nP show qos gpu_interactive format=Name,MaxWall,MaxSubmitJobsPU,MaxTRESPerJob'
```

Measured 2026-08-11: `gpu_interactive` = 4 h wall, **4 nodes per job**, **2 submitted jobs per user**; `gpu_regular` = 48 h.

**Running on a parked allocation (e.g. an `interactive-shared.sh` slice):** the `interactive-*.sh` scripts use `salloc --no-shell`, which leaves the allocation sitting in the queue. To run on it, read its job id from `squeue` and `srun --jobid=<id> --overlap` into it — **do not** issue a fresh `salloc` (that allocates a *second* node and bypasses the shared slice you just reserved).
```bash
REPO=$(basename "$PWD")
SW=$(~/.claude/scripts/ergodic/show-config.sh EC_SOFTWARE_ROOT)
JOBID=<id from squeue>
ssh perlmutter "srun --jobid=${JOBID} --overlap bash -c 'source ${SW}/\$USER/ergodic-claude.sh && source ${SW}/\$USER/venvs/${REPO}/bin/activate && cd \$PSCRATCH/${REPO} && python -u train.py'"
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

## Verify before you trust it

NERSC's blunt version: a job that submitted is not a job that ran, and a job that ran is not
a job whose output means anything. Four gates, in order — **does it submit, does it run to
completion, do the tests pass, does the output make sense.** Report which gate you actually
reached, and never describe a run as working because the launch command returned 0.

Slurm and module advice is where models are least reliable, so check the specifics against
the machine rather than against plausibility:

| Claim to check | Command |
| --- | --- |
| The account/QOS is one the user may actually use | `ssh perlmutter 'sacctmgr -nP show assoc user=$USER format=Account,QOS'` |
| The QOS's walltime cap fits the run | `ssh perlmutter "sacctmgr -nP show qos format=Name,MaxWall,MaxTRES where name=interactive,regular,shared_interactive"` |
| That `sbatch`/`srun` flag exists (models invent flags) | `ssh perlmutter "srun --help \| grep -- --overlap"` |
| The module name/version exists here | `ssh perlmutter "module spider <name>"` |
| GPUs were actually bound to the step, not just the job | `~/.claude/scripts/ergodic/sacct.sh <jobid>` → `AllocTRES` shows `gres/gpu=N`; in-job, `nvidia-smi -L` or `python -c "import jax; print(jax.devices())"` |
| The job really finished | `sacct.sh <jobid>` → `State=COMPLETED`, `ExitCode=0:0` — a quiet log is not evidence |
| How many nodes the code thinks it has | see the `SLURM_*` trap below — do not read `$SLURM_NNODES` from inside a step |
| The QOS will even accept another job | `sacctmgr -nP show qos gpu_interactive format=MaxSubmitJobsPU` — interactive is 2 |

> **`SLURM_NNODES` lies inside a job step, and so does `SLURM_JOB_NODELIST`.** A driver run
> under `srun --overlap --nodes=1 --ntasks=1` sees the *step's* view, not the job's. Measured
> inside such a step on a 4-node allocation:
>
> ```
> SLURM_NNODES=1                                     <- step-scoped
> SLURM_STEP_NUM_NODES=1                             <- step-scoped
> SLURM_JOB_NODELIST=nid003892                       <- ALSO step-scoped, despite the name
> SLURM_NODELIST=nid[001164,003892,008261,008301]    <- the whole allocation
> ```
>
> The intuitive variables are all wrong and the survivor is the one whose name suggests
> otherwise. A scan driver that auto-detected nodes from `$SLURM_NNODES` got 1 instead of 4, so
> parsl built a single 4-worker manager with accelerator groups `0..15` on nodes that only have
> GPUs `0-3` — three of four workers pinned to devices that do not exist, with no error until
> the tasks failed. **Pass the node count explicitly from the launcher** (which knows it), and
> if you must autodetect, count `SLURM_NODELIST` and range-expand `nid[001-004]` forms.

The recurring HPC mistakes to stay suspicious of, all of which this skill has already been
bitten by and documented above: confusing login-node work with compute-node work
(`/global/common` is read-only on compute), assuming `pip install` is fine on a shared
system (use `uv`, on a login node), mixing up `$HOME` / `$PSCRATCH` / `$CFS`, mismatched
`srun` launch patterns (the `--overlap -N1 -n1` driver wrapper), and assuming GPU access
without the GRES flag (`--gpus-per-node`, or `CUDA_ERROR_NO_DEVICE`). **Prefer the patterns
written down in this skill over anything you generate fresh** — they encode failures already
paid for. If you do deviate, say so and verify it.

For multi-step work on this shared system — a new launch pattern, a migration, anything
touching several files or several jobs — use plan mode and get the plan agreed before
executing. Ask for the smallest useful next step, run it, look at the result, then continue.

## Running the agent on Perlmutter itself

This skill assumes the normal setup: Claude runs on the laptop, work happens on Perlmutter
over ssh. If instead an agent is started *on* Perlmutter (a login node), NERSC's rules for
that case:

- Start it from `$HOME` or `$SCRATCH`, never from `/global/cfs` or a shared project root,
  and keep it in workspace-write mode — reading widely is fine, writing is not.
- `bootstrap-nersc.sh` installs the same `rules/nersc-agent-rules.md` block into
  `~/.claude/CLAUDE.md` on Perlmutter. If it's missing there, run
  `scripts/install-agent-rules.sh` before working.
- Login nodes are shared and policed: no builds, no long jobs, no traversals. Anything
  computationally substantial goes through an allocation
  (`interactive-cpu.sh` / `interactive-gpu.sh`).

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
- Bounded roots and depth caps for every remote search; never a recursive walk of `/global`, `/pscratch`, `/global/cfs`, or another shared top-level dir. See "Hard constraints from NERSC" above.
- Report the verification gate you actually reached (submitted / ran / tests passed / output sane) instead of implying more than you checked.

$ARGUMENTS
