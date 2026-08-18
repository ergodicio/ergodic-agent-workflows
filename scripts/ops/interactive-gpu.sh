#!/usr/bin/env bash
# Allocate an interactive GPU node on the cluster, named after the current repo.
#
# Usage: interactive-gpu.sh [hours] [nodes]
#        interactive-gpu.sh --hours <h> --nodes <n>
#   hours: walltime hours (default 1; gpu_interactive allows up to 4 — measured 2026-08-11)
#   nodes: number of nodes (default $EC_NODES from config.sh)
#
# Hours is the first positional in every interactive-*.sh script — see _alloc_args.sh.
# No 1-4 range check here, unlike the other node scripts: the default comes from
# $EC_NODES, which the user may deliberately have set for a non-interactive QOS.
#
# Job name is the basename of $PWD so it's identifiable in squeue.
# Account / QOS / constraint / GPUs-per-node come from config.sh (overridable via env).
# --gpus-per-node is REQUIRED: without it the srun step sees no GPUs
# (CUDA_ERROR_NO_DEVICE) even on exclusive nodes that already hold them.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_alloc_args.sh
. "$SCRIPT_DIR/_alloc_args.sh"

# Parse before the ssh preflight so --help and a typo'd argument answer instantly,
# without needing a live connection to the cluster.
_ec_tool=interactive-gpu
_ec_size_name=nodes
_ec_size_desc="number of nodes"
_ec_size_default="$EC_NODES"
_ec_size_max=0
ec_parse_alloc_args "$@"

# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

ec_require_account

HOURS="$EC_HOURS"
NODES="$EC_SIZE"
REPO="$(basename "$PWD")"

echo "[interactive-gpu] requesting ${NODES} node(s) x ${EC_GPUS_PER_NODE} GPU / ${HOURS}h on the ${EC_QOS} QOS (job-name ${REPO})" >&2

ssh "$EC_SSH_HOST" "salloc --no-shell \
  --job-name ${REPO} \
  --nodes ${NODES} \
  --gpus-per-node ${EC_GPUS_PER_NODE} \
  --qos ${EC_QOS} \
  --time ${HOURS}:00:00 \
  --constraint ${EC_CONSTRAINT} \
  --account ${EC_ACCOUNT_GPU}
squeue -u \$USER --name ${REPO}"
