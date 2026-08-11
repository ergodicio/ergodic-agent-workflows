# first-run: end-to-end demo

A ~30-second training job that proves your NERSC + MLflow + Claude setup works.

## What it does

Trains a tiny MLP (`1 -> 64 -> 1`) for 200 steps on a synthetic regression task, logging loss to MLflow every 10 steps. Uses GPU if available.

## Run it

After you've run both bootstrap scripts (see the repo root [README](../../README.md)) and filled in `~/.mlflow_credentials` on Perlmutter, just ask Claude — from inside this directory:

> sync and launch first-run on NERSC

That's it. Claude will:
1. Stamp the git commit
2. rsync this directory to `$PSCRATCH/first-run/`
3. **On the login node**: ensure the venv exists at `$ECLAUDE_VENVS/first-run` (i.e. `<project-space>/$USER/venvs/first-run`), creating it and `uv pip install`-ing `pyproject.toml` if missing (takes ~3–5 minutes the first time; seconds after)
4. **On a compute node**: allocate an interactive GPU node, activate the venv, source MLflow credentials, run `python -u train.py`
5. Background the job and tee output to `/tmp/nersc_first-run.log`

Then ask:

> how's the run going

Claude will use the `mlflow-query` skill to fetch loss history from the tracking server.

## What to look for

- Local log: `tail -f /tmp/nersc_first-run.log` should show loss decreasing from ~1.0 to ~0.01
- MLflow UI: https://continuum.ergodic.io/experiments/ — experiment `ergodic-claude-first-run`

## Troubleshooting

- **`uv: command not found`** during venv setup: you haven't run `scripts/bootstrap-nersc.sh` yet, or you ran it but haven't opened a fresh shell on Perlmutter. Fix with `ssh perlmutter source ~/.bash_profile`.
- **MLflow auth error**: `~/.mlflow_credentials` on Perlmutter still has placeholder values. `vim` it.
- **Job sits in queue forever**: the `interactive` QOS pool is small. Wait a few minutes; if it persists ask Claude to switch to `--qos=regular`.
