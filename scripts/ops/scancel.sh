#!/usr/bin/env bash
# Cancel a specific SLURM job by ID.
# Usage: scancel.sh <jobid>
#
# NEVER cancels by user or by name — only by explicit job ID. Other teammates
# share the account; blanket cancels are destructive.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <jobid>" >&2
    exit 1
fi

ssh "$EC_SSH_HOST" "scancel $1"
