#!/usr/bin/env bash
# Allocate an interactive CPU node on the cluster, named after the current repo.
# Usage: interactive-cpu.sh [hours] [nodes]
#   hours: walltime hours (default 1, interactive QOS caps at 1)
#   nodes: number of nodes, 1-4 (default 1; interactive QOS caps at 4)
#
# Job name is the basename of $PWD so it's identifiable in squeue.
# Account / QOS come from config.sh; constraint is forced to 'cpu'.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

ec_require_account

HOURS="${1:-1}"
NODES="${2:-1}"
REPO="$(basename "$PWD")"

if ! [[ "$NODES" =~ ^[1-4]$ ]]; then
  echo "[interactive-cpu] nodes must be an integer in 1..4 (got: $NODES)" >&2
  exit 2
fi

ssh "$EC_SSH_HOST" "salloc --no-shell \
  --job-name ${REPO} \
  --nodes ${NODES} \
  --qos ${EC_QOS} \
  --time ${HOURS}:00:00 \
  --constraint cpu \
  --account ${EC_ACCOUNT}
squeue -u \$USER --name ${REPO}"
