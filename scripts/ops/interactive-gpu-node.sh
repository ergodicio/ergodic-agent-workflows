#!/usr/bin/env bash
# Allocate a full-node interactive GPU allocation (4 GPUs per node) on the
# cluster, named after the current repo. For the single-GPU case use
# interactive-gpu.sh instead.
#
# Usage: interactive-gpu-node.sh [hours] [nodes]
#        interactive-gpu-node.sh --hours <h> --nodes <n>
#   hours: walltime hours (default 1; gpu_interactive allows up to 4 — measured 2026-08-11)
#   nodes: number of nodes, 1-4 (default 1; interactive QOS caps at 4)
#
# Hours is the first positional in every interactive-*.sh script — see _alloc_args.sh.
#
# Job name is the basename of $PWD so it's identifiable in squeue.
# Account / QOS / constraint come from config.sh (overridable via env).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_alloc_args.sh
. "$SCRIPT_DIR/_alloc_args.sh"

# Parse before the ssh preflight so --help and a typo'd argument answer instantly,
# without needing a live connection to the cluster.
_ec_tool=interactive-gpu-node
_ec_size_name=nodes
_ec_size_desc="number of nodes"
_ec_size_default=1
_ec_size_max=4
ec_parse_alloc_args "$@"

# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

ec_require_account

HOURS="$EC_HOURS"
NODES="$EC_SIZE"
REPO="$(basename "$PWD")"

echo "[interactive-gpu-node] requesting ${NODES} node(s) x ${EC_GPUS_PER_NODE} GPU / ${HOURS}h on the ${EC_QOS} QOS (job-name ${REPO})" >&2

ssh "$EC_SSH_HOST" "salloc --no-shell \
  --job-name ${REPO} \
  --nodes ${NODES} \
  --gpus-per-node ${EC_GPUS_PER_NODE} \
  --qos ${EC_QOS} \
  --time ${HOURS}:00:00 \
  --constraint gpu \
  --account ${EC_ACCOUNT_GPU}
squeue -u \$USER --name ${REPO}"
