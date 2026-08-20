---
name: nersc-workflow
description: Manage the NERSC Perlmutter interactive dev loop — sync code, run training on compute nodes, monitor jobs and logs, pull results, cancel jobs, and clean up. Use when the user wants to run code on NERSC, check job status, sync files to/from Perlmutter, or iterate on remote training.
allowed-tools: Bash
---

# NERSC Interactive Dev Loop

Manage the full cycle of syncing, running, monitoring, and iterating on Perlmutter GPU nodes.

## Helper scripts (prefer these)

These wrappers live at `~/.ergodic-agent-workflows/ops/` (symlinked by `bootstrap-local.sh`). They each wrap one known-safe `ssh perlmutter` invocation. **Always prefer the script over an inline `ssh perlmutter "…"` for these ops** — it makes the reviewed operation explicit and gives each agent a clear approval boundary.

`~/.ergodic-agent-workflows/ops/` is the canonical spelling and the one to use when writing a command. `bootstrap-local.sh` also leaves the selected agent's compatibility path (`~/.claude/scripts/ergodic/`, `~/.codex/scripts/ergodic/`, or both) pointing at it, so older transcripts and prompts keep working — but those paths are agent-specific. Don't reintroduce them in shared instructions.

| Need | Script |
| --- | --- |
| Isolated interactive edit–run–debug lease | `~/.ergodic-agent-workflows/ops/session.sh start|sync|exec|shell|status|stop` |
| Sync cwd → `$PSCRATCH/<repo>/` | `~/.ergodic-agent-workflows/ops/sync-up.sh` |
| Allocate interactive GPU (1 GPU) | `~/.ergodic-agent-workflows/ops/interactive-gpu.sh [hours] [nodes]` |
| Allocate interactive GPU node (4 GPUs/node, 1-4 nodes) | `~/.ergodic-agent-workflows/ops/interactive-gpu-node.sh [hours] [nodes]` |
| Allocate interactive shared GPU slice (1-2 GPUs, sub-node, shared_interactive QOS) | `~/.ergodic-agent-workflows/ops/interactive-shared.sh [hours] [gpus]` |
| Allocate interactive CPU node (1-4 nodes) | `~/.ergodic-agent-workflows/ops/interactive-cpu.sh [hours] [nodes]` |
| Submit a batch job | `~/.ergodic-agent-workflows/ops/submit-batch.sh <sbatch-path>` |
| Commit-pinned isolated run (checkout SHA → own dir → sbatch) | `~/.ergodic-agent-workflows/ops/launch-pinned.sh [opts] <cfg…>` |
| List your jobs | `~/.ergodic-agent-workflows/ops/squeue.sh` |
| Job accounting | `~/.ergodic-agent-workflows/ops/sacct.sh <jobid> [jobid2 ...]` |
| Cancel one job (by id) | `~/.ergodic-agent-workflows/ops/scancel.sh <jobid>` |
| Cat a remote log | `~/.ergodic-agent-workflows/ops/read-log.sh <relpath>` |
| Grep a remote log | `~/.ergodic-agent-workflows/ops/grep-log.sh <pattern> <relpath>` |
| Remote git SHA | `~/.ergodic-agent-workflows/ops/remote-sha.sh [subdir]` |

**Every `interactive-*.sh` takes hours first.** The second positional is whatever that
allocator sizes with — nodes for the whole-node scripts, GPUs for the shared slice. All four
also accept `--hours` / `--nodes` / `--gpus` in any order, and `--help`; prefer the flags when
generating a command for the user, since they read back unambiguously in the transcript.
(`interactive-shared.sh` took `[gpus] [hours]` until 2026-08-16 — if you see that order in an
older note or script, it is stale.)

Operations not covered by the scripts (venv mutation, pulling artifacts back, unusual
multi-node launch arrangements) still go through inline `ssh perlmutter "…"` as shown below
— those need the user to see the full command before approving. For arbitrary calculations
inside an interactive allocation, use `session.sh exec` rather than generating a new SSH
launch command.

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
> ssh perlmutter 'cat $ERGODIC_VENVS/<repo>/lib/python*/site-packages/__editable__*<repo>*.pth 2>/dev/null || \
>                 cat $ERGODIC_VENVS/<repo>/lib/python*/site-packages/_editable_impl_*<repo>*.pth'
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
ACCOUNT=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_ACCOUNT)          # e.g. m4490 — CPU jobs
ACCOUNT_GPU=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_ACCOUNT_GPU)  # e.g. m4490_g — GPU jobs
SW=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_SOFTWARE_ROOT)         # /global/common/software/<project>
```

- `show-config.sh` with no argument prints everything that resolved (and where from) — run it
  when a job is billed to a surprising project or a venv path looks wrong.
- The `interactive-*.sh`, `submit-batch.sh`, and `launch-pinned.sh` helpers already do this
  themselves and **refuse to run with no account configured** rather than guessing. You only
  need the lines above for free-form `ssh perlmutter "salloc … / srun …"` commands.
- If `EC_ACCOUNT` is empty: `~/.ergodic-agent-workflows/ops/list-accounts.sh` prints the projects
  the user can actually charge (from SLURM's own associations), then the user picks one — via
  `./scripts/bootstrap-nersc.sh` or by writing `: "${EC_ACCOUNT:=<proj>}"` into
  `~/.config/ergodic-agent-workflows/config.sh`. **Ask; never pick a project for them.**
- GPU work bills the `_g` account, CPU work the bare one. The project *directory* on global
  common is always the bare name.

## CRITICAL: login nodes vs compute nodes

**`/global/common/software/` is mounted read-only on compute nodes.** This means:

| Operation | Must run on |
| --- | --- |
| `uv venv`, `uv pip install`, `uv sync`, `uv add`, `uv pip compile`, any env mutation | **Login node** (plain `ssh perlmutter "…"` — no `salloc`) |
| Reading the venv to run code (`python`, `uv run`) | Either, but typically compute node inside `srun` |

When this skill calls plain `ssh perlmutter "…"`, you land on a login node — that's where venv mutations belong.
When a command wraps the body in `salloc … srun …` (the one-shot launches) or attaches with `srun --jobid=…`, that body runs on a compute node — **only read the venv there, never mutate it**. Specifically: never run `uv sync` / `uv pip install` / `uv venv` inside a salloc'd shell. If you need to update deps, exit the allocation, run uv on the login node, then relaunch.

## Hard constraints from NERSC (not negotiable)

NERSC's [coding-agent guidance](https://docs.nersc.gov/development/coding-agents/) governs
anything an agent does on their systems, including through `ssh perlmutter "…"` from a
laptop. The full text ships in this repo at `rules/nersc-agent-rules.md` and is installed
into the selected agent guidance file(s) (on laptop and Perlmutter) by the bootstrap
scripts, so it binds whether or not this skill is loaded. The parts that bite
hardest here:

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
`ergodic-agent-workflows.sh`); the pinned-run deploy key comes from `~/.ssh/<repo>-deploy`. Read a
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
SW=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_SOFTWARE_ROOT)
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

### The uv cache must live on global common, next to the venvs

**Check this before diagnosing any "we're out of space on global common" report.** It is
the usual cause, and it is invisible until you look.

uv hardlinks package files from its cache into a venv, so ten venvs sharing a dependency
cost one copy on disk. It can only do that **within a single filesystem**. The venvs are on
`/global/common` (tlcommon); `$PSCRATCH` is Lustre and `$HOME` is `/global/u2` (tlhome2).
Point the cache at either of those and uv silently falls back to a full copy. No warning
reaches the user; the venvs just quietly cost 6× what they should.

`bootstrap-nersc.sh` used to do exactly that — it set `UV_CACHE_DIR="${PSCRATCH}/uv-cache"`,
reasoning that scratch is fast and purgeable. It is, but it is also the wrong filesystem,
and that one line is what inflated every jax venv in the project. Fixed 2026-08-16; anyone
whose `ergodic-agent-workflows.sh` predates that needs to re-run the bootstrap.

For jax GPU venvs this is brutal, because the CUDA wheels dominate: `site-packages/nvidia`
is **4.5 GB** of the ~6 GB (cudnn 1.3G, cublas 817M, cusolver 473M, cusparse 465M,
nccl 454M, nvshmem 335M, cufft 281M). Every venv carries its own identical copy. Measured
2026-08-16: seven venvs, one user, **38 GB**; after the fix below, **7.8 GB**.

This matters because `/global/common/software/<project>` is a **per-project quota shared by
every member** — m4490 is capped at 100 GB across all users. One person's duplicated CUDA
wheels exhaust the quota for the whole team. `showquota` does **not** report this
filesystem; the only signal is `Disk quota exceeded` on write.

Check where the cache is pointing. `UV_CACHE_DIR` is exported from `ergodic-agent-workflows.sh`,
sourced from a managed block **prepended** to `~/.bashrc` and `~/.bash_profile`
(since 2026-08-18). Older bootstraps wired it where non-interactive shells never saw
it — first the Cori-era `~/.bash_profile.ext`, which nothing on Perlmutter sources,
then appended below any "return unless interactive" guard in `~/.bashrc` — and uv
silently fell back to `~/.cache/uv`. The env var beats any `~/.config/uv/uv.toml`.
Verify with a login shell (`bash -lc`), which reads `~/.bash_profile` regardless of
how the user's `~/.bashrc` is guarded:

```bash
ssh perlmutter bash -lc 'uv cache dir'
```

If that is not under `$EC_SOFTWARE_ROOT/$USER/`, re-run the bootstrap — don't hand-edit
`ergodic-agent-workflows.sh`, it is overwritten wholesale on every run:

```bash
./scripts/bootstrap-nersc.sh
```

Don't "fix" this with a `cache-dir` in `~/.config/uv/uv.toml` either. The exported
`UV_CACHE_DIR` overrides it, so the file looks authoritative while doing nothing — one
source of truth, and it is the bootstrap.

Existing venvs stay bloated — hardlinking is decided at install time. Collapse the copies
that are already on disk with `hardlink` (util-linux, present on Perlmutter). `-c` compares
content only, which is required: the same wheel unpacked into different venvs has different
mtimes. Dry-run first, and expect ~6–12 min for ~165k files:

```bash
SW=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_SOFTWARE_ROOT)
ssh perlmutter "hardlink -c -n ${SW}/\$USER"   # dry run — prints "Saved: N GiB"
ssh perlmutter "hardlink -c ${SW}/\$USER"      # for real
```

**The cache now counts against the quota, and nothing purges it.** That is the one property
given up in the move off scratch: `$PSCRATCH` purged the cache for free, global common never
will, and uv keeps every version of every wheel it has ever downloaded. Prune it when the
project space gets tight — this only drops entries no venv is using, and venv files survive
regardless because they are hardlinks to those inodes, not copies of them:

```bash
ssh perlmutter bash -lc 'uv cache prune'
```

Notes for Claude:
- **Login node only.** Global common is read-only from compute, so both the config change
  and the `hardlink` pass must run outside `salloc`/`srun`. This is the documented
  exception to "substantial work belongs in an allocation" — no allocation can write here.
- Run it over `$USER/` (venvs *and* cache together), not just `venvs/`, so cache and venv
  copies collapse into each other too.
- Safe by construction: `hardlink` links only sha256-identical files, and uv replaces files
  on install rather than editing in place. Verify anyway — a real op, not just an import.
  That needs a GPU node, so use `interactive-shared.sh 1 1` (1 h, 1 GPU) and `scancel` when
  done:
  ```bash
  ssh perlmutter "srun --jobid=<JOBID> --overlap bash -lc '\
    source \$ERGODIC_VENVS/<repo>/bin/activate && \
    python -c \"import jax, jax.numpy as jnp; x=jnp.ones((256,256)); \
    print((x@x).sum(), jax.devices())\"'"
  ```
- **The cache is now read-only from compute, like the venvs.** It moved onto the same
  filesystem, so it inherits the same rule — on a compute node, activate the venv and run
  `python` directly rather than `uv run`, which may want to write the cache while resolving.
  The launch recipes below already do this; the interactive attach example is the one place
  `uv run` appears, and it is fine there only because the venv is already in sync.
- After deduping, per-venv `du` is meaningless: `du` credits each shared inode to whichever
  venv it walks first, so one venv shows 6 GB and the rest show tens of MB. Only the total
  for `$USER/` is real.
- If the quota is still tight afterwards, check the other members' directories
  (`du -h --max-depth=1 $EC_SOFTWARE_ROOT`) before asking NERSC for an increase — the same
  fix usually applies to them.

### Don't switch jax to `cuda12-local` to save space

It looks like the obvious fix for the 4.5 GB above. It is not, on Perlmutter:

| | |
| --- | --- |
| `cudatoolkit` modules | 11.7 → 13.2 — new enough |
| `cudnn` modules | 8.3.2 → **9.5.0** — newest available |
| what jax 0.10.2 wants | **cuDNN 9.24** |

You would still pip-install cuDNN — the single largest wheel — gaining perhaps 2.5 GB once,
in exchange for pinning every project to NERSC's module stack and re-breaking on every
module upgrade. Dedupe the wheels instead; that recovers more, and keeps jax upgradable.

### Rebuild venv from scratch (only if it's corrupted or the user asks)

Destructive — confirm with the user first. Runs on login node.
```bash
REPO=$(basename "$PWD")
SW=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_SOFTWARE_ROOT)
ssh perlmutter "rm -rf ${SW}/\$USER/venvs/${REPO}"
# then call "ensure venv exists" again
```

### Sync local to NERSC

```bash
~/.ergodic-agent-workflows/ops/sync-up.sh
```

Stamps `.git_commit` (so the training script can log the SHA to MLflow) and rsyncs the cwd to `$PSCRATCH/<repo>/` with the standard exclusions (`__pycache__`, `.git`, `.venv`, `checkpoints/`, `runinfo/`, `workdir/`, `plots/`, `*.ipynb_checkpoints`, `uv.lock`). It never deletes remote-only files; use an intentional remote cleanup when a fresh development tree is needed.

> **Shared-dir hazard.** `sync-up.sh` rsyncs into a *single* per-repo dir (`$PSCRATCH/<repo>/`), and the venv's editable install points there. Switch branches locally and re-sync and the common files are **overwritten**; deleted local files can also remain remotely, yielding a hybrid tree. Either case can break a job still queued or running against the old tree. For anything that must survive concurrent branches or long queue waits (production batch jobs, multi-day runs), use **commit-pinned isolated runs** (`launch-pinned.sh`, below) instead.

### Interactive development lease (preferred for edit–run–debug)

Use `session.sh` when the user wants to try calculations, inspect failures, edit locally,
and rerun without paying allocation startup latency each time. It owns one active session
per local repo worktree:

```bash
~/.ergodic-agent-workflows/ops/session.sh start --kind shared --hours 2 --gpus 1
~/.ergodic-agent-workflows/ops/session.sh exec -- python run.py --cfg example

# after editing locally — a clean worktree is not required
~/.ergodic-agent-workflows/ops/session.sh sync
~/.ergodic-agent-workflows/ops/session.sh exec -- pytest tests/test_solver.py

# a human or terminal-driven debugger can attach to the same allocation
~/.ergodic-agent-workflows/ops/session.sh shell
~/.ergodic-agent-workflows/ops/session.sh status
~/.ergodic-agent-workflows/ops/session.sh stop
```

Kinds map to the existing interactive resource shapes:

| Kind | Resource flags | Intended use |
| --- | --- | --- |
| `shared` (default) | `--gpus 1|2` | Fast sub-node GPU iteration |
| `gpu` | `--nodes 1..4` | Whole GPU nodes |
| `cpu` | `--nodes 1..4` | CPU-only calculations |

All sessions are capped at four hours. Each gets an isolated root:

```text
$PSCRATCH/<repo>-sessions/<session-id>/
├── src/       synchronized local worktree
├── workdir/   source-state records and temporary run data
└── outputs/   results that must survive later source syncs
```

The local worktree is the source of truth. `sync` accepts committed, modified, staged, and
untracked source. It records the base SHA, dirty state, binary diff, untracked-file status,
and a content fingerprint. It does **not** contact GitHub. To remove stale synchronized
source, it may delete paths only under the session's disposable `src/`, and only after a
repo/session marker matches. Standard run-output exclusions are protected even within
`src/`; `workdir/`, `outputs/`, the legacy `$PSCRATCH/<repo>/`, and all other sessions are
outside the sync target.

`exec` preserves the user's command as an argument vector; use an explicit
`bash -lc 'pipeline | ...'` only when shell syntax is needed. It sets `EC_SESSION_ROOT`,
`EC_SESSION_WORKDIR`, and `EC_SESSION_OUTPUTS`, activates the project venv if it exists, and
puts the session checkout ahead of the shared editable install on `PYTHONPATH`, then runs the
command through `srun --jobid=<validated-session-job> --overlap` on the allocated compute
resource. `shell` opens a PTY with the same environment.

This is deliberately a broad, time-bounded development capability: arbitrary code running
as the user's NERSC identity still has that identity's filesystem permissions. Do not
describe it as a filesystem sandbox, and do not blanket-allow every ops script. The smaller
blast radius comes from the unique workspace, exact job ID, resource cap, expiry, and the
separate approval boundary for login-node or destructive operations.

When a result matters beyond debugging, commit and push it, then launch the exact SHA with
`launch-pinned.sh`. A clean worktree is a **promotion gate**, not an interactive-session gate.

## Choosing a run pattern

Three patterns; pick deliberately.

| Pattern | When to use | How |
| --- | --- | --- |
| **Interactive development lease** (preferred for iterative dev) | Running a sim, looking at output, tweaking code/config, and running again, including a dirty worktree. | `session.sh start` → repeated `sync` / `exec` / `shell` → `stop` |
| **One-shot fire-and-forget** | Automated launches Claude is going to monitor by tailing a log. Allocation lifetime = command lifetime. | `ssh perlmutter "nohup setsid salloc … srun bash -c '…' > \$PSCRATCH/<repo>/workdir/….log &"` — see "Run on compute node" below |
| **Commit-pinned isolated run** (preferred for production / long-queue batch) | A run that must be reproducible and immune to later branch switches — production sweeps, multi-hour/day batch jobs, anything you'll queue then walk away from. | `launch-pinned.sh` — see below |

For **parameter scans / sweeps**, neither shell pattern is the right tool — use the parsl + LocalProvider pattern documented in the `adept-run` skill. parsl launches workers inside whichever allocation you've already got (laptop or NERSC), so the same script works in both. Do **not** loop a shell over configs.

**Wider than one node?** Still parsl + `LocalProvider` — see *"Multi-node GPU scan — 16 runs on 16 GPUs (canonical)"* in `adept-run`. That config (one block per node, `available_accelerators=4`, `SrunLauncher(overrides="-c 32 --gpus-per-node 4")`, `retries=2`) is the production one from `ml-for-lpi` and is what to use for a 4-node/16-GPU/16-run scan. `SlurmProvider` is not needed for this. This skill's job is only to hand it an N-node allocation and put the driver in the right place.

**Launching a parsl scan on a compute node — activate the venv; don't bypass it.** `source $VENV/bin/activate` then `python scan.py` (and put the same `source …/activate` in the parsl `worker_init`). Two ways to get this wrong, both seen in practice:
- `$VENV/bin/python scan.py` (bare interpreter path, no activation) → parsl's HighThroughputExecutor launches its `interchange.py` helper off `PATH`, and `$VENV/bin` isn't on `PATH`, so the run dies seconds in with `FileNotFoundError: 'interchange.py'`.
- `uv run … python scan.py` → `uv run` re-resolves against the (often stale) `uv.lock` and tries to sync the project env, but the venv lives on read-only `/global/common/...` on compute nodes and is shared with concurrent runs. Best case it errors; worst case it disturbs other jobs.

Activation is PATH-only (sets `PATH`/`VIRTUAL_ENV`, no install/sync), so it fixes the `interchange.py` lookup without touching the shared venv.

### Commit-pinned isolated runs (`launch-pinned.sh`) — production / long-queue jobs

`sync-up.sh` + attach is ideal for fast iteration, but every run shares one mutable dir (`$PSCRATCH/<repo>/`) and the venv's editable install points into it. Switch branches locally and re-sync and common files are overwritten while files deleted locally can remain, leaving a hybrid tree. This can break a job still queued or running against the old tree, and bites hardest for batch jobs that sit in the queue for hours while you move on to other work.

`launch-pinned.sh` removes the shared mutable state:

- checks out a **specific commit** into its own dir `$PSCRATCH/<repo>-runs/<sha>/` (bare mirror + `git worktree`, via a read-only deploy key) — immutable, never rsynced over;
- imports the project package from that tree via `PYTHONPATH`, so it neither depends on nor disturbs the shared venv's editable link (concurrent runs of different commits don't collide);
- generates + submits one sbatch per config from the isolated dir; logs land in `<sha>/logs/` and are never swept.

```bash
# from inside the repo on the laptop:
~/.ergodic-agent-workflows/ops/launch-pinned.sh [options] <cfg1> [cfg2 ...]
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

### Attach to a persistent interactive allocation manually (low-level fallback)

Prefer `session.sh` for the normal agent-driven development loop. Use the commands below
when attaching to an allocation that predates the session helper or when a human explicitly
wants to manage the allocation and remote working directory by hand.

After allocating with `~/.ergodic-agent-workflows/ops/interactive-gpu.sh <hrs>` (which uses `salloc --no-shell` and prints `<JOBID>`):

```bash
ssh -tt perlmutter "srun --jobid=<JOBID> --pty bash"
# now on the compute node:
cd $PSCRATCH/<repo>
source ~/.bash_profile.ext                        # ergodic-agent-workflows.sh: MLflow env + creds, $ERGODIC_VENVS
source $ERGODIC_VENVS/<repo>/bin/activate         # no hardcoded project dir — it comes from the env file
python run.py --cfg <config-path-no-yaml>         # or whatever the project's launch is
```

The allocation persists until its walltime expires or you `scancel` it — you can exit the tty and re-attach with the same `ssh -tt … srun --jobid=<JOBID> --pty bash` to run another command.

**Same compute-node rules apply:** no `uv sync` / `uv pip install` / `uv venv` inside the attached shell — global common is read-only here. Exit, mutate on the login node, re-attach.

**Note the plain `python`, not `uv run`.** Once the venv is activated `uv run` adds nothing but a resolve step, and that step wants to write both the venv and the uv cache — which now live on the same read-only-from-compute filesystem (see the uv-cache section above). If you have a reason to want `uv run` here, it must be `uv run --no-sync`.

### Run on compute node (one-shot, automated launches)

Allocate an interactive node and run training. Output is captured to a log on `$PSCRATCH/<repo>/workdir/` and the launch is detached on the login node so the user can monitor it (and so it survives the local session — see "Why the driver goes on a compute node" below).

The launch sources `${SW}/$USER/ergodic-agent-workflows.sh` (installed by `bootstrap-nersc.sh`) to get MLflow env vars + credentials, then activates the project venv, then runs python. **No `uv` mutations happen here** — the venv was prepared on the login node by the previous step.

**`salloc` here must request `--gpus-per-node` explicitly — `--constraint=gpu` alone is not enough.** Slurm draws GPU device visibility at two different levels: the **job** (the `salloc` allocation itself) and the **step** (each `srun` invocation run inside it), and GRES bound to one isn't automatically bound to the other. A plain interactive `salloc` shell — run *without* `--no-shell` and with no `srun` wrapping your command — executes your commands at the job level and sees all 4 GPUs on an exclusive node with no extra flag, since there's no separate step boundary involved. But the one-shot `salloc ... srun bash -c '...'` commands below run your training command as an `srun` **job step** (every launch path in this skill goes through `srun`), and Slurm builds a step's GPU device cgroup from the GRES requested *for that step*, not from the node's exclusivity. `--constraint=gpu` only steers node *selection* — it requests no GRES at all — so without `--gpus-per-node`, the step gets `CUDA_ERROR_NO_DEVICE` even though `squeue`/`AllocTRES` shows the node's A100s allocated to the job. `interactive-gpu.sh`/`interactive-gpu-node.sh` already pass `--gpus-per-node ${EC_GPUS_PER_NODE}` for the same reason — the one-shot commands below build their own `salloc` call directly, so they need the flag too.

**Single node (default):**
```bash
REPO=$(basename "$PWD")
SW=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_SOFTWARE_ROOT)
ACCOUNT_GPU=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_ACCOUNT_GPU)
ssh perlmutter "cd \$PSCRATCH/${REPO} && mkdir -p workdir && nohup setsid salloc --nodes=1 --gpus-per-node=4 --qos=interactive --time=01:00:00 --constraint=gpu --account=${ACCOUNT_GPU} --job-name=${REPO}-train srun bash -c 'source ${SW}/\$USER/ergodic-agent-workflows.sh && source ${SW}/\$USER/venvs/${REPO}/bin/activate && cd \$PSCRATCH/${REPO} && python -u train.py' > \$PSCRATCH/${REPO}/workdir/${REPO}-train.log 2>&1 < /dev/null &"
```

**Multi-node (only if the workload genuinely needs >1 node):**
```bash
REPO=$(basename "$PWD")
SW=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_SOFTWARE_ROOT)
ACCOUNT_GPU=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_ACCOUNT_GPU)
ssh perlmutter "cd \$PSCRATCH/${REPO} && mkdir -p workdir && nohup setsid salloc --nodes=4 --gpus-per-node=4 --qos=interactive --time=01:00:00 --constraint=gpu --account=${ACCOUNT_GPU} --job-name=${REPO}-train srun --overlap --nodes=1 --ntasks=1 bash -c 'source ${SW}/\$USER/ergodic-agent-workflows.sh && source ${SW}/\$USER/venvs/${REPO}/bin/activate && cd \$PSCRATCH/${REPO} && python -u train.py' > \$PSCRATCH/${REPO}/workdir/${REPO}-train.log 2>&1 < /dev/null &"
```

**IMPORTANT: multi-node wraps the driver in exactly `srun --overlap --nodes=1 --ntasks=1` — not a plain `srun`.** A plain outer `srun` (no flags) runs the command as an N-node job step and conflicts with the internal `srun --overlap` that torchrun-style frameworks use to place workers (interconnect errors). The `--overlap --nodes=1 --ntasks=1` form instead runs the *driver* as a 1-task step on the head compute node, and the framework's internal worker srun still lays out across all nodes with full GPU pinning. Verified 2026-07-03 (Perlmutter, parsl HTEX + SrunLauncher): driver step `.0` on the head node, worker step `.1` spanning all nodes, workers GPU-pinned on every node, and a 1.5 h 8-run production scan completed with results byte-identical to its login-driver baseline.

**Parsl's internal srun carries no `--overlap` of its own** (verified 2026-07-21 against archived runinfo submit scripts, parsl 2026.6.1: `srun --ntasks N -l <overrides>`) — don't add it to `SrunLauncher(overrides=…)`; it's unnecessary. Worker placement comes from the driver's inherited SLURM env, so make it explicit instead: `SrunLauncher(overrides=f"--nodes {nodes} --ntasks-per-node 1 --gpus-per-node 4")`. This one-shot (salloc-child) driver inherits the full job env and spreads correctly; launching the driver by **attaching to a parked allocation** (`srun --jobid … -N1 -n1`) scrambles the env and packs ALL workers onto one node unless the env is scrubbed — see the parked-allocation warning for multi-node parsl runs farther below. (Scope: this override set — and the driver-in-step pattern it supports — is for the block-spanning shape, `nodes_per_block=N, max_blocks=1`, verified end-to-end on production scans 2026-07/08. On the canonical one-block-per-node config a driver step is fatal and `--ntasks-per-node 1` must not be added — see the EXCEPTION below.)

**Why the driver goes on a compute node (and why you still detach):** an unwrapped `bash -c '…'` body executes on the login/submit node, exposed to two independent killers: (a) **SIGHUP** when your ssh drops or the login node reboots — the ~20–30 min failure people hit on long scans; (b) **SIGTERM from NERSC login-node process policing**, which reaps busy login-resident processes at random (observed: a healthy 12-GPU scan torn down at 38 min while identical launches elsewhere survived 2.5 h+; `setsid` does not block SIGTERM). The `srun --overlap -N1 -n1` wrapper removes the policing target: the only login-resident piece left is the near-idle `salloc` client. **Detach the launch ON THE LOGIN NODE, never locally** — the `nohup setsid salloc … &` above runs *inside* the ssh command so the salloc client survives anything that happens to your machine. A locally-detached `setsid ssh -tt … salloc …` is NOT safe: `-tt` allocates a remote tty that salloc binds to, so anything that kills the local ssh (closing the session, laptop sleep, local cleanup) SIGHUPs salloc and revokes the whole allocation mid-run (observed 2026-08-09: a healthy 2-wave scan torn down at 28 min, both steps SIGTERM'd together, when the local session closed; the remote-detached form was validated the same day by a run that completed through a deliberate session close AND a SIGTERM of its launching ssh). Send the log to `$PSCRATCH/<repo>/workdir/` (excluded from source sync and readable via `read-log.sh`) — never local `/tmp`, which dies with your session.

**Why that 2026-07-03 result and the 2026-08-11 failure below are both real** — worth knowing, because the two look contradictory: the July run's worker step was **`.1` spanning all nodes**, i.e. *one* srun for the whole allocation (`nodes_per_block=N, max_blocks=1`), which coexists with a driver step. The canonical config is one srun **per node** (`nodes_per_block=1, max_blocks=nodes`), and those are what fail to bind CPUs when a driver step already exists. So the discriminator is the provider shape, not the framework: with the canonical one-block-per-node config the wrapper is fatal. (Inference from the step layout each note recorded, not a third measurement.) Since the sharded layout also moved to one-block-per-node, **every parsl config in these skills now wants the driver off-step** — see the EXCEPTION below.

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
> **The login-node row assumes a `SrunLauncher` in the provider.** It is the launcher, not
> the allocation, that puts workers on compute nodes: a launcher-less `LocalProvider` forks
> its worker pool as a *child of the driver*, so from a login node every worker runs **on the
> login node** while your allocation sits idle — silently, with correct results (measured
> 2026-08-16: 64 JAX workers took `login28` from load ~6 to 122; the only tell was
> `'hostname': 'login28'` in `interchange.log`). See the `adept-run` skill for the full
> driver-placement × launcher table.
>
> ```bash
> # interactive: allocate, then drive from the login node
> REPO=$(basename "$PWD")            # from a worktree, set this to the real repo name — see Conventions
> ACCOUNT_GPU=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_ACCOUNT_GPU)
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

This is an **alternative** to detaching the multi-node one-shot, not a replacement: for runs **≤ 4 h, prefer the detached one-shot** (interactive, faster to schedule; with the `srun --overlap -N1 -n1` driver wrapper it is equally login-independent apart from the idle salloc client). Reach for `sbatch` when a run may exceed the 4 h interactive cap. **`sbatch` cannot use the interactive QOS** — Perlmutter rejects it at submission (`sbatch: error: Cannot submit batch jobs to gpu_interactive_ss11`, tested 2026-07-03) — so batch jobs ride the `regular` queue (slower to schedule). A batch job runs its script on a **compute node under SLURM**, with nothing tied to your terminal — so ssh drops and login reboots can't kill it, and no `setsid` / `nohup` is needed. The parsl part is unchanged: the script still runs `python -u scan.py` with **no outer srun** (the sbatch script already executes on the head compute node, so the driver needs no placement wrapper there; parsl's `SrunLauncher` does the internal srun — which has no `--overlap`; see the warning above about never adding it to the overrides).

Copy the template `skills/nersc-workflow/run-scan.sbatch` into the campaign next to its `scan.py`, set `DRIVER`, then submit + monitor:

```bash
~/.ergodic-agent-workflows/ops/submit-batch.sh sims/<campaign>/run-scan.sbatch
~/.ergodic-agent-workflows/ops/squeue.sh
~/.ergodic-agent-workflows/ops/read-log.sh workdir/<repo>-<jobid>.out
```

The template hardcodes `--qos=regular` (the interactive QOS rejects sbatch — see above), `--nodes=4 --gpus-per-node=4`, and `--output=workdir/%x-%j.out` (`workdir/` is excluded from `sync-up`). `submit-batch.sh` does `mkdir -p workdir` first so the log can open. It deliberately carries **no** `--account` and **no** hardcoded venv path: `submit-batch.sh` passes `-A $EC_ACCOUNT_GPU` on the command line (which overrides any `#SBATCH --account`), and the script resolves the venv through `$ERGODIC_VENVS`. Pass `submit-batch.sh --account <acct>` for a CPU-only job.

**Detach vs sbatch — both stay fully inspectable** (`squeue` / `sacct` / `read-log` / `srun --jobid=<id> --overlap` attach all work either way):

| | Detached salloc one-shot (srun-wrapped driver) | sbatch |
| --- | --- | --- |
| Pros | Interactive QOS, nodes now (no batch queue); fast dev iteration; driver on a compute node (policing/reboot-immune) | Compute-node driver — immune to ssh drops *and* login reboots; no detach ceremony; `regular` lifts the interactive walltime cap |
| Cons | Idle `salloc` client still lives on the login node (dies if the login node itself reboots); manual remote-detach ceremony (`nohup setsid` inside the ssh, no `-tt`, log on scratch), easy to fumble | `regular` queue only (interactive QOS rejects sbatch) — not instant; less live/interactive |

Rule of thumb: **multi-node ≤ 4 h → detached one-shot with the `srun --overlap -N1 -n1` driver wrapper (preferred); a run that may exceed 4 h → `sbatch` on `regular`.** For a multi-node **parsl** scan, drop the `srun` wrapper — see the exception above.

**The interactive QOS caps SUBMITTED jobs at 2 per user.** A third `salloc` is refused at submit time, not queued:

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
SW=$(~/.ergodic-agent-workflows/ops/show-config.sh EC_SOFTWARE_ROOT)
JOBID=<id from squeue>
ssh perlmutter "cd \$PSCRATCH/${REPO} && mkdir -p workdir && nohup setsid srun --jobid=${JOBID} --overlap bash -c 'source ${SW}/\$USER/ergodic-agent-workflows.sh && source ${SW}/\$USER/venvs/${REPO}/bin/activate && cd \$PSCRATCH/${REPO} && python -u train.py' > \$PSCRATCH/${REPO}/workdir/${REPO}-${JOBID}.log 2>&1 < /dev/null &"
```

Detach it the same way as the one-shot (remote `nohup setsid`, log on `workdir/`): a parked allocation is owned by SLURM with no client anywhere, so a dead attach client only costs the current *step* — the allocation survives and you re-attach (make the driver idempotent, e.g. a `--skip-done` flag, so a re-attach resumes instead of duplicating). To bill a different project than your configured one for a single launch, prefix the allocator with `EC_ACCOUNT=<account>` (e.g. `EC_ACCOUNT=m4490 interactive-gpu-node.sh 3 2`) — env vars override `~/.config/ergodic-agent-workflows/config.sh`, and salloc rejects on node-hour balance if the resolved account can't pay.

**MULTI-NODE parsl: do not launch the driver into a parked allocation this way at all.** With the canonical one-block-per-node config (`nodes_per_block=1, max_blocks=nodes` — what every parsl config in these skills now uses) the driver must not occupy a job step: drive it from the **login node** per the EXCEPTION above, and everything below never arises.

*If* you are on the block-spanning shape (`nodes_per_block=N, max_blocks=1`), where the driver legitimately sits in a job step, then the step env has to be scrubbed first. A driver started via `srun --jobid … -N1 -n1` runs inside a 1-node step whose SLURM env is scrambled (`SLURM_NNODES=1`, `SLURM_JOB_NUM_NODES` empty — probed 2026-07-21). Parsl's internal worker srun inherits it and packs ALL managers onto ONE node (4 runs/GPU, other nodes idle, ~4x slowdown — this silently ruined two 4-node campaign launches before diagnosis; with explicit `--nodes` in the overrides it instead fails loudly with "Only allocated 1 nodes asked for 4"). Fix, verified end-to-end: scrub the step env in the driver's shell before python, keeping only the job id and cluster name — and detach it the same way as every other launch here:

```bash
ssh perlmutter "cd \$PSCRATCH/${REPO} && mkdir -p workdir && nohup setsid srun --jobid=${JOBID} --overlap --nodes=1 --ntasks=1 bash -c 'for v in \$(env | grep -oE \"^SLURM_[A-Z_]+\"); do case \$v in SLURM_JOB_ID|SLURM_CLUSTER_NAME) ;; *) unset \$v;; esac; done; source … && python -u sims/<campaign>/scan.py' > \$PSCRATCH/${REPO}/workdir/scan-${JOBID}.log 2>&1 < /dev/null &"
```

plus explicit node count in the launcher overrides (`SrunLauncher(overrides=f"--nodes {nodes} --ntasks-per-node 1 --gpus-per-node 4")`). After ANY launcher or launch-style change, verify spread before walking away: `grep -ho "hostname.: .nid[0-9]*" runinfo/<latest>/*/interchange.log | sort | uniq -c` must show as many distinct worker nodes as the allocation has. (sbatch and salloc-one-shot drivers get the full job env and don't need the scrub — but the explicit `--nodes` override is cheap insurance everywhere.)

Notes:
- `python -u` for unbuffered output (so `tail -f` of the log is responsive).
- `ergodic-agent-workflows.sh` provides `MLFLOW_TRACKING_URI` and (via `~/.mlflow_credentials`) `MLFLOW_TRACKING_USERNAME` / `MLFLOW_TRACKING_PASSWORD`. If those are empty, the user hasn't filled in their credentials yet — point them at `vim ~/.mlflow_credentials` on Perlmutter.
- For adept (the usual case), the entry point should be `run.py --cfg <name>` (single run) or a parsl scan script — see the `adept-run` skill for which to use. Don't substitute the launch command without checking. On a compute node run it as `python run.py …` after activating the venv, not `uv run` — that is what the recipes above do, and why.
- The `--time=01:00:00` in the one-shot launches above is a polite default, **not** the cap: `gpu_interactive` allows 4 h (and 4 nodes, 2 submitted jobs — measured 2026-08-11, re-check with `sacctmgr -nP show qos gpu_interactive format=MaxWall,MaxTRESPerJob,MaxSubmitJobsPU`). Past 4 h, switch to `--qos=regular`.

### Monitor

**Run log (training stdout — lives on `$PSCRATCH/<repo>/workdir/`, not locally).** The name depends on which launch path you used: one-shot → `<repo>-train.log`, parked attach → `<repo>-<jobid>.log`, parsl scan → `scan.log` / `scan-<jobid>.log`, sbatch → `<repo>-<jobid>.out`. List first if you're not sure, then read:
```bash
ssh perlmutter 'ls -t $PSCRATCH/'"$(basename "$PWD")"'/workdir/'
~/.ergodic-agent-workflows/ops/read-log.sh workdir/$(basename "$PWD")-train.log
```

**SLURM queue:**
```bash
~/.ergodic-agent-workflows/ops/squeue.sh
```

**Job accounting (state, exit code, elapsed):**
```bash
~/.ergodic-agent-workflows/ops/sacct.sh <jobid>
```

**Remote outputs (free-form `ls` — not covered by a script):**
```bash
ssh perlmutter "ls -la \$PSCRATCH/$(basename "$PWD")/checkpoints/ 2>/dev/null"
```

**Read / grep a remote log file:**
```bash
~/.ergodic-agent-workflows/ops/read-log.sh slurm-<jobid>.out
~/.ergodic-agent-workflows/ops/grep-log.sh 'error\|fail' slurm-<jobid>.out
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
~/.ergodic-agent-workflows/ops/squeue.sh
~/.ergodic-agent-workflows/ops/scancel.sh <JOB_ID>
```

Under the remote-detached pattern there is no local process to clean up — `scancel` the job id and the login-node salloc client exits on its own. (Only if you used the legacy locally-detached form: `kill $(pgrep -f "ssh.*perlmutter.*salloc.*$(basename "$PWD")")`.)

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
| GPUs were actually bound to the step, not just the job | `~/.ergodic-agent-workflows/ops/sacct.sh <jobid>` → `AllocTRES` shows `gres/gpu=N`; in-job, `nvidia-smi -L` or `python -c "import jax; print(jax.devices())"` |
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

This skill assumes the normal setup: the coding agent runs on the laptop, work happens on Perlmutter
over ssh. If instead an agent is started *on* Perlmutter (a login node), NERSC's rules for
that case:

- Start it from `$HOME` or `$SCRATCH`, never from `/global/cfs` or a shared project root,
  and keep it in workspace-write mode — reading widely is fine, writing is not.
- `bootstrap-nersc.sh` installs the same `rules/nersc-agent-rules.md` block into the
  selected agent guidance file(s) on Perlmutter. If it is missing, run
  `scripts/install-agent-rules.sh --agent claude|codex|both` with the appropriate selection
  before working.
- Login nodes are shared and policed: no traversals, no long compute, nothing heavy left
  running unattended — busy login-resident processes get SIGTERM'd at random. Anything
  computationally substantial goes through an allocation
  (`interactive-cpu.sh` / `interactive-gpu.sh`).
- **Decided: the `uv` venv install runs on a login node.** It is the only place it can run —
  `/global/common/software/` is read-only from every compute node, so no job, step, or
  allocation can write the venv, and that's where NERSC wants Python environments (see
  "Never hardcode the account…" and `rules/nersc-agent-rules.md`). Don't try to route it
  through an allocation, and don't relocate the venv to make it routable. What keeps this
  defensible: it's 3–10 min once per project and seconds on every no-op re-run; it's
  IO/network-bound wheel unpacking, not a `make -j128`; and it's **attended** — you're
  watching it, not walking away. If policing ever does reap one mid-install, just re-run it:
  the step is idempotent and uv resumes from its cache. (An `xfer`-QOS job is the only other
  thing with write access to global common — untested here, and unnecessary at these
  durations.)
- A multi-node parsl driver is the other login-node resident, for a different reason: it
  must not hold a job step (see the EXCEPTION above). It's near-idle while waiting on
  futures, so it's a poor policing target — but `nohup` it and check on it.
- Everything else goes to a compute node.

## Iteration workflow

For interactive development, the typical loop is: ensure venv → `session start` → edit
locally → `session sync` → `session exec` → inspect → repeat → `session stop`. Reuse the
allocation instead of cancelling and reallocating for every code change.

For production, use: clean worktree → commit → push → `launch-pinned.sh` → monitor → pull
results. Do not require a clean worktree merely to debug interactively.

The venv step is fast after the first time. Don't skip it just because "it probably exists"
— the user may have switched projects, changed Python deps, or never run this repo on NERSC
before.

## Guidelines

- The canonical order for a new interactive lease is: **ensure venv → session start**.
  `start` performs the initial source sync. Never launch without checking the venv exists —
  undergrads and new joiners will not have run any setup manually.
- When the user asks to experiment, debug, fix a calculation, or iterate on an interactive
  node, prefer `session.sh`. Dirty worktrees are allowed and expected in this mode.
- During a lease, edit locally and call `session sync` before rerunning. Reuse the existing
  allocation until the user asks to stop it or the walltime expires.
- When the user asks for a production, reproducible, long-queue, or unattended run, require
  a clean pushed commit and use `launch-pinned.sh`.
- For monitoring, check the run log on `workdir/` first (`read-log.sh` — fastest). Fall back to `squeue` if the log is stale.
- The `mlflow-query` skill is the right tool for checking metrics — use it alongside this one.
- The `adept-run` skill is the right tool for deciding *what command to run* (ergoExo vs. parsl scan vs. direct module). This skill handles only the NERSC infra.
- Destructive operations (cancel, cleanup) require explicit user confirmation.
- If the user hasn't run `bootstrap-nersc.sh` yet, the venv/scratch dirs won't exist — point them at the repo README.
- Bounded roots and depth caps for every remote search; never a recursive walk of `/global`, `/pscratch`, `/global/cfs`, or another shared top-level dir. See "Hard constraints from NERSC" above.
- Report the verification gate you actually reached (submitted / ran / tests passed / output sane) instead of implying more than you checked.

$ARGUMENTS
