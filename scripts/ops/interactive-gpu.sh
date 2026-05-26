#!/usr/bin/env bash
# Allocate an interactive GPU node on the cluster, named after the current repo.
# Usage: interactive-gpu.sh [hours] [nodes]
#   hours: walltime hours (default 1, interactive QOS caps at 1)
#   nodes: number of nodes (default 1)
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
NODES="${2:-$EC_NODES}"
REPO="$(basename "$PWD")"

ssh "$EC_SSH_HOST" "salloc --no-shell \
  --job-name ${REPO} \
  --nodes ${NODES} \
  --qos ${EC_QOS} \
  --time ${HOURS}:00:00 \
  --constraint ${EC_CONSTRAINT} \
  --account ${EC_ACCOUNT}
squeue -u \$USER --name ${REPO}"
