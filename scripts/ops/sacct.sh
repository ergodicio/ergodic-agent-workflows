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
# Fields follow NERSC's documented debugging format
# (https://docs.nersc.gov/development/coding-agents/) plus NodeList. AllocTRES is the one
# that earns its width: it shows the GRES actually bound per job *and* per step, which is
# how you tell a real GPU allocation from a job that reserved nodes but whose srun step got
# no devices (CUDA_ERROR_NO_DEVICE).
ssh "$EC_SSH_HOST" "sacct -j $JOB_IDS --format=JobID%20,JobName%20,Partition,Account,AllocTRES%42,State,ExitCode,Elapsed,NodeList"
