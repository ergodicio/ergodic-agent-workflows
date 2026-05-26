#!/usr/bin/env bash
# Show job accounting info for one or more job IDs.
# Usage: sacct.sh <jobid> [jobid2] ...
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <jobid> [jobid2] ..." >&2
    exit 1
fi

JOB_IDS=$(IFS=,; echo "$*")
ssh "$EC_SSH_HOST" "sacct -j $JOB_IDS --format=JobID,JobName%24,State,ExitCode,Elapsed,NodeList"
