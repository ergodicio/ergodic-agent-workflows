# ergodic-claude

The Ergodic flavor of [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) — a small set of skills, scripts, and an example that wires Claude Code up to the team's NERSC (Perlmutter) compute and MLflow tracking server.

After installing this once, you can run Claude Code from any project repo on your laptop and ask things like:

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
| `scripts/bootstrap-local.sh` | Installs `uv`, links the skills into `~/.claude/skills/`, checks ssh |
| `scripts/bootstrap-nersc.sh` | Installs `uv` on Perlmutter, creates the venv and scratch directories the skill expects |
| `examples/first-run/` | A ~30-second torch training job that exercises the entire loop |

---

## Prerequisites

You need three things before installing:

1. **A NERSC account on project `m4490`.** If you don't have one, talk to your project PI to be added. Then enroll in MFA.
2. **`sshproxy` set up locally** so you can `ssh perlmutter` without typing OTP every time. Follow the [NERSC sshproxy docs](https://docs.nersc.gov/connect/mfa/#sshproxy). At the end you should have a `perlmutter` Host alias in `~/.ssh/config`. Test with `ssh perlmutter true`.
3. **MLflow credentials** for `https://continuum.ergodic.io/experiments/`. Ask in the team Slack if you don't have a token yet.
4. **Claude Code installed.** See https://docs.claude.com/en/docs/claude-code/setup.

---

## Install

```bash
git clone https://github.com/ergodicio/ergodic-claude.git
cd ergodic-claude
./scripts/bootstrap-local.sh    # uv + skills + ssh check
./scripts/bootstrap-nersc.sh    # uv + dirs on Perlmutter
```

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

Open a new shell to pick those up, then prove it all works with the demo:

```bash
cd examples/first-run
# follow examples/first-run/README.md
```

---

## How the skills work together

When you ask Claude something like "launch training on NERSC", Claude reads `nersc-workflow/SKILL.md`, derives paths from `$(basename $PWD)`, and runs the right rsync + salloc + srun for you. Output is teed to `/tmp/nersc_<repo>.log` and the ssh is backgrounded so you can keep working.

When you ask "how's the run going", Claude reads `mlflow-query/SKILL.md`, uses `uv run python3` to hit the tracking server, and summarizes recent runs + loss history.

The two skills don't know about each other directly — Claude composes them.

---

## Path conventions on NERSC

The `nersc-workflow` skill assumes:

| Thing | Where |
| --- | --- |
| Code (synced from your laptop) | `$PSCRATCH/<repo>/` |
| Run outputs (checkpoints, plots, logs) | inside that same `$PSCRATCH/<repo>/` |
| uv venv | `/global/common/software/m4490/$USER/venvs/<repo>` |
| uv-managed Pythons | `/global/common/software/m4490/$USER/uv-python/` |
| uv cache | `$PSCRATCH/uv-cache/` |
| MLflow credentials | `~/.mlflow_credentials` (mode 600 — fill in after running `bootstrap-nersc.sh`) |
| Account | `m4490` |
| Default QOS / constraint / time | `interactive` / `gpu` / `01:00:00` |

`$PSCRATCH` is fast but [purges after 8 weeks of no access](https://docs.nersc.gov/filesystems/perlmutter-scratch/) — that's fine for run outputs and the uv download cache (pull what you need back to your laptop), but it's why the venv and uv-managed Pythons live in `/global/common/software/m4490/` instead.

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
- **Job won't start, queue says `(QOSGrpCPURunMinutesLimit)` or similar.** The `m4490` interactive pool is shared — wait a few minutes or switch to `--qos=regular`.
- **Venv missing on NERSC.** The `nersc-workflow` skill auto-creates the venv on the login node before launch. If creation fails, it's almost always: (a) `uv` not on PATH (re-run `bootstrap-nersc.sh`, or `source ~/.bash_profile` in a fresh shell), or (b) trying to mutate the venv from inside `salloc` (compute nodes are read-only on global common — exit, do it on the login node, re-allocate).

---

## Updating

```bash
cd path/to/ergodic-claude
git pull
./scripts/bootstrap-local.sh    # safe to re-run, just refreshes the symlinks
```
