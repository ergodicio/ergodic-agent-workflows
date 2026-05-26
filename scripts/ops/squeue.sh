#!/usr/bin/env bash
# List your jobs in the SLURM queue on the cluster.
# Usage: squeue.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

ssh "$EC_SSH_HOST" 'squeue -u $USER'
