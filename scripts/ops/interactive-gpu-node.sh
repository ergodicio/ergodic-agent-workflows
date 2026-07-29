#!/usr/bin/env bash
# Allocate a full-node interactive GPU allocation (4 GPUs per node) on the
# cluster, named after the current repo. For the single-GPU case use
# interactive-gpu.sh instead.
#
# Usage: interactive-gpu-node.sh [hours] [nodes]
#   hours: walltime hours (default 1; interactive QOS max walltime is 4)
#   nodes: number of nodes, 1-4 (default 1; interactive QOS caps at 4)
#
# Job name is the basename of $PWD so it's identifiable in squeue.
# Account / QOS / constraint come from config.sh (overridable via env).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

HOURS="${1:-1}"
NODES="${2:-1}"
REPO="$(basename "$PWD")"

if ! [[ "$NODES" =~ ^[1-4]$ ]]; then
  echo "[interactive-gpu-node] nodes must be an integer in 1..4 (got: $NODES)" >&2
  exit 2
fi

ssh "$EC_SSH_HOST" "salloc --no-shell \
  --job-name ${REPO} \
  --nodes ${NODES} \
  --gpus-per-node ${EC_GPUS_PER_NODE} \
  --qos ${EC_QOS} \
  --time ${HOURS}:00:00 \
  --constraint gpu \
  --account ${EC_ACCOUNT}
squeue -u \$USER --name ${REPO}"
