#!/usr/bin/env bash
# Allocate an interactive GPU node on the cluster, named after the current repo.
# Usage: interactive-gpu.sh [hours] [nodes]
#   hours: walltime hours (default 1; gpu_interactive allows up to 4 — measured 2026-08-11)
#   nodes: number of nodes (default 1)
#
# Job name is the basename of $PWD so it's identifiable in squeue.
# Account / QOS / constraint / GPUs-per-node come from config.sh (overridable via env).
# --gpus-per-node is REQUIRED: without it the srun step sees no GPUs
# (CUDA_ERROR_NO_DEVICE) even on exclusive nodes that already hold them.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

ec_require_account

HOURS="${1:-1}"
NODES="${2:-$EC_NODES}"
REPO="$(basename "$PWD")"

ssh "$EC_SSH_HOST" "salloc --no-shell \
  --job-name ${REPO} \
  --nodes ${NODES} \
  --gpus-per-node ${EC_GPUS_PER_NODE} \
  --qos ${EC_QOS} \
  --time ${HOURS}:00:00 \
  --constraint ${EC_CONSTRAINT} \
  --account ${EC_ACCOUNT_GPU}
squeue -u \$USER --name ${REPO}"
