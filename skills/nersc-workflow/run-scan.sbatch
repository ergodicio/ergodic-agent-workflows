#!/bin/bash
# run-scan.sbatch — robust, no-detach multi-node launcher for parsl adept scans.
#
# Copy this into a campaign next to its scan.py (e.g. sims/<campaign>/run-scan.sbatch),
# set DRIVER below, then submit from your repo root with:
#     ~/.claude/scripts/ergodic/submit-batch.sh sims/<campaign>/run-scan.sbatch
# (submit-batch.sh runs `cd $PSCRATCH/<repo> && mkdir -p workdir && sbatch <this>`.)
#
# This is the ALTERNATIVE to detaching the multi-node one-shot, not the default: for
# runs <= 4 h the detached one-shot (setsid/nohup) is usually preferred. Reach for sbatch
# when a run may exceed the 4 h interactive cap, or to keep the driver off the login node.
# Why it's more robust: this script runs on a COMPUTE node under SLURM, independent of any
# ssh session — so an ssh drop or a login-node reboot can't SIGHUP the driver mid-run (the
# ~20–30 min failure mode of the login-resident one-shot driver). No setsid/nohup needed.
#
# NOTE: the driver is deliberately NOT wrapped in an outer srun — parsl's SrunLauncher
# does its own `srun --overlap` to the allocated nodes; an outer srun would collide.

# (no --job-name here: submit-batch.sh sets `-J <repo>` from your repo basename, so the
#  job + its workdir/%x-... log are named after whatever project you run this from.
#  If you `sbatch` this directly, SLURM names the job after the script filename.)
#SBATCH --account=m4490_g
#SBATCH --qos=interactive            # matches config.sh EC_QOS; switch to `regular` to exceed the interactive walltime cap
#SBATCH --constraint=gpu
#SBATCH --nodes=4
#SBATCH --gpus-per-node=4            # REQUIRED — without it the parsl srun step gets CUDA_ERROR_NO_DEVICE
#SBATCH --time=04:00:00
#SBATCH --output=workdir/%x-%j.out   # workdir/ is excluded from sync --delete, so logs persist

set -e   # not -u: sourcing ~/.bash_profile.ext / ergodic-claude.sh may reference unset vars

# --- edit per campaign: driver path, relative to the repo root ---
DRIVER="sims/<campaign>/scan.py"

REPO="$(basename "$SLURM_SUBMIT_DIR")"     # submit-batch.sh cd's to $PSCRATCH/<repo> before sbatch
VENV="/global/common/software/m4490/$USER/venvs/$REPO"

source ~/.bash_profile.ext                 # MLflow env + creds (sources ergodic-claude.sh)
source "$VENV/bin/activate"
export PYTHONPATH="$SLURM_SUBMIT_DIR"
cd "$SLURM_SUBMIT_DIR"

echo "[run-scan.sbatch] job=$SLURM_JOB_ID host=$(hostname) nodes=$SLURM_NNODES driver=$DRIVER"
python -u "$DRIVER"                         # parsl does the internal srun --overlap; NO outer srun
