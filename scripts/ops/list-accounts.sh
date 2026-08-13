#!/usr/bin/env bash
# List the NERSC projects you can actually charge, straight from SLURM's associations.
# Usage: list-accounts.sh [--verbose]
#
# Prints one bare project per line (m4490, not m4490_g — the `_g` half is the same
# project's GPU allocation and is derived by config.sh). Projects whose association
# is `deleted` are filtered out: they still show up in your unix groups long after
# they stop being chargeable.
#
# This is the answer to "which account should this job use?" — ask SLURM, don't guess
# from a directory name or an old config.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

if [ "${1:-}" = "--verbose" ]; then
    ssh "$EC_SSH_HOST" 'sacctmgr -nP show assoc user=$USER format=Account,QOS' | sort -u
    exit 0
fi

ssh "$EC_SSH_HOST" 'sacctmgr -nP show assoc user=$USER format=Account,QOS' \
  | awk -F'|' '$1 != "" && $2 != "deleted" && $1 !~ /_g$/ { print $1 }' \
  | sort -u
