#!/usr/bin/env bash
# Allocate an interactive CPU node on the cluster, named after the current repo.
#
# Usage: interactive-cpu.sh [hours] [nodes]
#        interactive-cpu.sh --hours <h> --nodes <n>
#   hours: walltime hours (default 1; the interactive QOS allows up to 4 — verify with
#          `sacctmgr -nP show qos interactive format=MaxWall`)
#   nodes: number of nodes, 1-4 (default 1; interactive QOS caps at 4)
#
# Hours is the first positional in every interactive-*.sh script — see _alloc_args.sh.
#
# Job name is the basename of $PWD so it's identifiable in squeue.
# Account / QOS come from config.sh; constraint is forced to 'cpu'.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_alloc_args.sh
. "$SCRIPT_DIR/_alloc_args.sh"

# Parse before the ssh preflight so --help and a typo'd argument answer instantly,
# without needing a live connection to the cluster.
_ec_tool=interactive-cpu
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

echo "[interactive-cpu] requesting ${NODES} CPU node(s) / ${HOURS}h on the ${EC_QOS} QOS (job-name ${REPO})" >&2

ssh "$EC_SSH_HOST" "salloc --no-shell \
  --job-name ${REPO} \
  --nodes ${NODES} \
  --qos ${EC_QOS} \
  --time ${HOURS}:00:00 \
  --constraint cpu \
  --account ${EC_ACCOUNT}
squeue -u \$USER --name ${REPO}"
