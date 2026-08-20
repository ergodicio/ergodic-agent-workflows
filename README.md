# ergodic-claude

The Ergodic workflow for [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) and [Codex](https://developers.openai.com/codex/) — a small set of shared skills, scripts, and an example that wires either coding agent up to the team's NERSC (Perlmutter) compute and MLflow tracking server.

After installing this once, you can run Claude Code or Codex from any project repo on your laptop and ask things like:

> sync and launch this on NERSC

> how is the run going

> cancel the current job and rerun with batch size 32

…and the right thing happens.

---

## What's in here

| Path | What it is |
| --- | --- |
| `skills/nersc-workflow/` | Skill that handles the sync / launch / monitor / pull / cancel cycle on Perlmutter |
| `skills/mlflow-query/` | Skill that queries the MLflow tracking server for experiments, runs, metrics, artifacts |
| `skills/adept-run/` | Skill that picks the right way to run an adept simulation (default: `ergoExo` for full MLflow logging; `parsl` + `LocalProvider` for parameter scans) |
| `scripts/ops/` | Thin wrappers around safe `ssh perlmutter "…"` invocations (squeue, sacct, scancel, interactive-gpu, sync-up, log read/grep, mlflow get-params/list/download-artifact, show-config, list-accounts). Bootstrap symlinks these to `~/.ergodic-claude/ops/`, an agent-neutral stable path |
| `rules/nersc-agent-rules.md` | NERSC's [required coding-agent rules](https://docs.nersc.gov/development/coding-agents/) — bounded filesystem search, secrets handling, agent conduct on shared systems |
| `scripts/install-agent-rules.sh` | Installs that block into `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, or both between managed markers (idempotent; backs up first) |
| `~/.config/ergodic-claude/config.sh` | **Your** settings — which NERSC project to bill. Written by `bootstrap-nersc.sh`, outside the repo. `scripts/ops/show-config.sh` prints what resolved; `list-accounts.sh` lists the projects you can charge |
| `scripts/bootstrap-local.sh` | Installs `uv`, links shared skills for the selected agent(s), links ops scripts into `~/.ergodic-claude/ops/`, installs the NERSC agent rules, checks ssh |
| `scripts/bootstrap-nersc.sh` | Installs `uv` on Perlmutter, creates the venv and scratch directories the skill expects, and installs rules for the selected agent(s) there too |
| `scripts/uninstall.sh` | Removes the selected agent's bootstrap-managed local links and rules; `--nersc` also removes its managed rules on Perlmutter |
| `examples/first-run/` | A ~30-second torch training job that exercises the entire loop |

---

## Prerequisites

You need three things before installing:

1. **A NERSC account on a project with a Perlmutter allocation** (the team's is `m4490`). If you don't have one, talk to your project PI to be added. Then enroll in MFA.
2. **`sshproxy` set up locally** so you can `ssh perlmutter` without typing OTP every time. Follow the [NERSC sshproxy docs](https://docs.nersc.gov/connect/mfa/#sshproxy). At the end you should have a `perlmutter` Host alias in `~/.ssh/config`. Test with `ssh perlmutter true`.
3. **MLflow credentials** for `https://continuum.ergodic.io/experiments/`. Ask in the team Slack if you don't have a token yet.
4. **Claude Code or Codex installed.** Claude Code setup: https://docs.claude.com/en/docs/claude-code/setup. Codex is available in the Codex app and CLI.

---

## Install

```bash
git clone https://github.com/ergodicio/ergodic-claude.git
cd ergodic-claude
agent=codex  # claude, codex, or both
./scripts/bootstrap-local.sh --agent "$agent"
./scripts/bootstrap-nersc.sh --agent "$agent"
```

Use `--agent claude`, `--agent codex`, or `--agent both` with both scripts. The default is
`both`, so existing no-argument installs keep working. A single-agent install only creates
that agent's skill, compatibility, and rules files; it does not delete files left by an
earlier install for the other agent.

### Uninstall

Remove only Claude Code's bootstrap-managed links and local rules with:

```bash
./scripts/uninstall.sh --agent claude
```

Add `--nersc` to also remove the managed Claude rules block from Perlmutter. Use
`--agent codex` or `--agent both` for the other selections; the default is `both`, as with
the bootstrap scripts.

The uninstaller only removes symlinks whose targets exactly match the checkout it is run
from and rules inside the managed markers. It leaves user-owned files, unexpected symlinks,
and backups untouched. The shared `~/.ergodic-claude/ops` link stays in place while another
installed agent still uses it.

`bootstrap-nersc.sh` will have created `~/.mlflow_credentials` on Perlmutter with placeholder values. Fill it in:

```bash
ssh perlmutter
vim ~/.mlflow_credentials      # set your username + token. Mode 600. Don't commit.
exit
```

Locally, add MLflow vars to your shell profile so `mlflow-query` works from your laptop too:

```bash
# ~/.zshrc or ~/.bashrc on your laptop
export MLFLOW_TRACKING_URI=https://continuum.ergodic.io/experiments/
export MLFLOW_TRACKING_USERNAME=<your-username>
export MLFLOW_TRACKING_PASSWORD=<your-token>
```

The scripts are intentionally narrow wrappers — each one runs a single known-safe ssh command. Claude Code users can allowlist `Bash(~/.ergodic-claude/ops/*)` in their settings. Codex users should approve these scoped scripts when prompted; free-form `ssh perlmutter "…"` calls (used for venv mutation and custom launches) remain separate approval decisions.

Open a new shell to pick those up, then prove it all works with the demo:

```bash
cd examples/first-run
# follow examples/first-run/README.md
```

---

## How the skills work together

When you ask either agent something like "launch training on NERSC", it reads `nersc-workflow/SKILL.md`, derives paths from `$(basename $PWD)`, and runs the right rsync + salloc + srun for you. Output is teed to `/tmp/nersc_<repo>.log` and the ssh is backgrounded so you can keep working.

When you ask "how's the run going", the agent reads `mlflow-query/SKILL.md`, uses `uv run python3` to hit the tracking server, and summarizes recent runs + loss history.

The two skills don't know about each other directly — the agent composes them.

---

## NERSC's coding-agent rules

NERSC publishes [guidance for coding agents on their systems](https://docs.nersc.gov/development/coding-agents/)
and asks that one part of it — the filesystem-discovery rules — live in your agent's config
file rather than in a skill, so it applies even when no skill is loaded. The bootstrap
scripts do that for you: `scripts/install-agent-rules.sh` copies the block from
`rules/nersc-agent-rules.md` into `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, or both
according to `--agent`, on your laptop **and** on Perlmutter, delimited by markers:

```
<!-- >>> ergodic-claude nersc-agent-rules >>> -->
…
<!-- <<< ergodic-claude nersc-agent-rules <<< -->
```

Nothing outside those markers is touched, the file is backed up to `CLAUDE.md.bak` before
any change, and re-running refreshes the block in place. To remove the managed block or
install it somewhere else:

```bash
./scripts/install-agent-rules.sh --remove --agent claude
./scripts/install-agent-rules.sh --target ~/.codex/AGENTS.md
```

The headline rule: **no recursive traversal of shared filesystems** — `/global`,
`/global/cfs`, `/pscratch`, `/usr`, `/opt`, `/` — with `find`, `fd`, `tree`, recursive
`du`/`grep`/`ls`, globstar, or a Python walk, on login *or* compute nodes. Login nodes are
shared by hundreds of users and CFS/scratch are network filesystems, so one unbounded walk
degrades the machine for everyone. Searches use a bounded root with a depth cap; software
gets located with `command -v` / `module spider`, not by crawling mounts. The
`nersc-workflow` skill carries the same constraints plus a verification checklist for
generated Slurm and module advice.

---

## Path conventions on NERSC

The `nersc-workflow` skill assumes:

| Thing | Where |
| --- | --- |
| Code (synced from your laptop) | `$PSCRATCH/<repo>/` |
| Run outputs (checkpoints, plots, logs) | inside that same `$PSCRATCH/<repo>/` |
| uv venv | `$SW/$USER/venvs/<repo>` (also `$ECLAUDE_VENVS/<repo>` on Perlmutter) |
| uv-managed Pythons | `$SW/$USER/uv-python/` |
| uv cache | `$PSCRATCH/uv-cache/` |
| MLflow credentials | `~/.mlflow_credentials` (mode 600 — fill in after running `bootstrap-nersc.sh`) |
| SLURM account | `$EC_ACCOUNT` for CPU, `$EC_ACCOUNT_GPU` (`<project>_g`) for GPU — from your config, never hardcoded |
| `$SW` (project space) | `$EC_SOFTWARE_ROOT` = `/global/common/software/<project>` |
| Default QOS / constraint / time | `interactive` / `gpu` / `01:00:00` (a polite default — `gpu_interactive` allows 4 h, 4 nodes, 2 submitted jobs) |

Run `scripts/ops/show-config.sh` to see what those resolve to for you.

The venv and uv-managed Pythons live under `/global/common/software/<project>/` because that's [what NERSC recommends for Python environments used by parallel applications](https://docs.nersc.gov/development/languages/python/nersc-python/) — faster imports, and it keeps a many-small-files stack off the filesystems whose metadata load slows the machine down for everyone else (their Python FAQ prescribes moving a stack there to fix mpi4py metadata timeouts at scale). It also survives: `$PSCRATCH` is fast but [purges after 8 weeks of no access](https://docs.nersc.gov/filesystems/perlmutter-scratch/), which is fine for run outputs and the uv download cache (pull what you need back to your laptop) but not for an environment.

Note this cuts against the "keep agent writes in `$HOME`/`$SCRATCH`" line on NERSC's coding-agent page — that advice is about an agent's blast radius on data, not about where a software stack belongs. `rules/nersc-agent-rules.md` records which one wins here and why, so an agent doesn't try to "fix" the venv location.

### Which project gets billed

NERSC users usually belong to several projects, so nothing in this repo defaults to one.
`bootstrap-nersc.sh` reads your SLURM associations, asks which project to use if there's more
than one, and writes `~/.config/ergodic-claude/config.sh`:

```bash
: "${EC_ACCOUNT:=m4490}"
```

Everything else derives from it: `EC_ACCOUNT_GPU=<project>_g` for GPU jobs, and
`EC_SOFTWARE_ROOT=/global/common/software/<project>` for venvs. An exported `EC_ACCOUNT` in
your shell overrides the file for one command. The submitting helpers **refuse to run** with
no account configured rather than guessing — that's deliberate: the old hardcoded default
billed a different project than the one whose venv directory the same scripts used.

```bash
scripts/ops/list-accounts.sh    # projects you can actually charge, per SLURM
```

**Important: `/global/common/software/` is mounted read-only on compute nodes.** All venv creation and `uv` installs happen on login nodes — `bootstrap-nersc.sh` and the `nersc-workflow` skill enforce this so you don't have to think about it. If you're debugging interactively inside an `salloc`, don't try to `uv sync` or `pip install` — exit, do it on the login node, then re-allocate.

Your laptop's repo is the source of truth. Edit locally, `rsync` to NERSC, run.

---

## Adding your own project

You don't need to put your project in this repo. Just:

1. `cd` into your project on your laptop
2. Create the venv on Perlmutter (one-time, see `examples/first-run/README.md` for the pattern)
3. Drop a `.env` with MLflow creds at `$PSCRATCH/<your-repo>/.env`
4. Ask Claude to run it

If your project has different conventions (multi-node, non-interactive QOS, different account), tell Claude in the prompt — the skill exposes those as variables.

---

## Troubleshooting

- **`ssh perlmutter` hangs or asks for a password.** Re-run `sshproxy`. The cert lifetime is short (~24h).
- **MLflow auth errors.** Check that all three `MLFLOW_TRACKING_*` env vars are exported in the *new* shell you're running Claude in.
- **Job won't start, queue says `(QOSGrpCPURunMinutesLimit)` or similar.** Your project's interactive pool is shared — wait a few minutes or switch to `--qos=regular`.
- **Venv missing on NERSC.** The `nersc-workflow` skill auto-creates the venv on the login node before launch. If creation fails, it's almost always: (a) `uv` not on PATH (re-run `bootstrap-nersc.sh`, or `source ~/.bash_profile` in a fresh shell), or (b) trying to mutate the venv from inside `salloc` (compute nodes are read-only on global common — exit, do it on the login node, re-allocate).

---

## Updating

```bash
cd path/to/ergodic-claude
git pull
./scripts/bootstrap-local.sh --agent codex    # safe to re-run; use your original selection
```
