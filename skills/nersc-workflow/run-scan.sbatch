#!/bin/bash
# run-scan.sbatch — robust, no-detach multi-node launcher for parsl adept scans.
#
# Copy this into a campaign next to its scan.py (e.g. sims/<campaign>/run-scan.sbatch),
# set DRIVER below, then submit from your repo root with:
#     ~/.ergodic-agent-workflows/ops/submit-batch.sh sims/<campaign>/run-scan.sbatch
# (submit-batch.sh runs `cd $PSCRATCH/<repo> && mkdir -p workdir && sbatch <this>`.)
#
# This is the ALTERNATIVE to detaching the multi-node one-shot, not the default: for
# runs <= 4 h the detached one-shot (setsid + `srun --overlap -N1 -n1`-wrapped driver)
# is preferred — it gets nodes from the interactive QOS immediately. Reach for sbatch
# when a run may exceed the 4 h interactive cap. NOTE: sbatch CANNOT use the interactive
# QOS (rejected at submission: "Cannot submit batch jobs to gpu_interactive_ss11",
# tested 2026-07-03) — batch jobs ride the `regular` queue.
# Why it's robust: this script runs on a COMPUTE node under SLURM, independent of any
# ssh session — so an ssh drop, a login-node reboot, or login-node process policing
# can't kill the driver mid-run. No setsid/nohup needed.
#
# NOTE: the driver is deliberately NOT wrapped in an outer srun — parsl's SrunLauncher
# does its own internal srun to the allocated nodes; an outer srun would collide.
# (Parsl's internal srun is plain `srun --ntasks N -l <overrides>` — no --overlap;
# verified 2026-07-21 against archived runinfo submit scripts, parsl 2026.6.1.)
#
# WORKER-PLACEMENT TRAP (diagnosed 2026-07-21): parsl's srun takes its node count
# from the INHERITED SLURM env when not told explicitly. If the driver runs inside
# a 1-node step — e.g. launched with `srun --jobid=<id> --overlap -N1 -n1` into a
# parked (--no-shell) allocation — the step env carries SLURM_NNODES=1 and the
# worker srun packs ALL managers onto ONE node (4 runs/GPU, other nodes idle,
# ~4x slowdown; --ntasks-per-node is silently ignored). sbatch/salloc-one-shot
# drivers get the full job env and are safe, but make the placement explicit
# anyway: put the node count in the overrides —
#   SrunLauncher(overrides=f"--nodes {nodes} --ntasks-per-node 1 --gpus-per-node 4")
# and after ANY launcher/launch-style change, verify spread:
#   grep -ho "hostname.: .nid[0-9]*" runinfo/<latest>/*/interchange.log | sort | uniq -c
# must list as many distinct worker nodes as the allocation has.

# (no --job-name here: submit-batch.sh sets `-J <repo>` from your repo basename, so the
#  job + its workdir/%x-... log are named after whatever project you run this from.
#  If you `sbatch` this directly, SLURM names the job after the script filename.)
# (no --account here either: submit-batch.sh passes `-A $EC_ACCOUNT_GPU` from your
#  ergodic-agent-workflows config, which overrides any #SBATCH --account. If you sbatch this
#  directly you get your SLURM default account — check it with
#  `~/.ergodic-agent-workflows/ops/show-config.sh EC_ACCOUNT_GPU` and pass -A yourself.)
#SBATCH --qos=regular              # interactive QOS rejects sbatch (tested 2026-07-03); regular also lifts the 4 h cap
#SBATCH --constraint=gpu
#SBATCH --nodes=4
#SBATCH --gpus-per-node=4            # REQUIRED — without it the parsl srun step gets CUDA_ERROR_NO_DEVICE
#SBATCH --time=04:00:00
#SBATCH --output=workdir/%x-%j.out   # workdir/ is excluded from source sync, so logs persist

set -e   # not -u: sourcing ~/.bash_profile.ext / ergodic-agent-workflows.sh may reference unset vars

# --- edit per campaign: driver path, relative to the repo root ---
DRIVER="sims/<campaign>/scan.py"

REPO="$(basename "$SLURM_SUBMIT_DIR")"     # submit-batch.sh cd's to $PSCRATCH/<repo> before sbatch

source ~/.bash_profile.ext                 # MLflow env + creds (sources ergodic-agent-workflows.sh)

# $ERGODIC_VENVS comes from ergodic-agent-workflows.sh, so the project dir isn't hardcoded here
# and can't drift from the account this job is billed to.
: "${ERGODIC_VENVS:?not set — run bootstrap-nersc.sh, or source ergodic-agent-workflows.sh}"
VENV="$ERGODIC_VENVS/$REPO"
source "$VENV/bin/activate"
export PYTHONPATH="$SLURM_SUBMIT_DIR"
cd "$SLURM_SUBMIT_DIR"

echo "[run-scan.sbatch] job=$SLURM_JOB_ID host=$(hostname) nodes=$SLURM_NNODES driver=$DRIVER"
python -u "$DRIVER"                         # parsl does the internal srun (no --overlap); NO outer srun
