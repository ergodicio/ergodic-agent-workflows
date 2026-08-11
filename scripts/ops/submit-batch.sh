#!/usr/bin/env bash
# Submit an sbatch script that lives inside the synced repo on the cluster.
# Usage: submit-batch.sh [--account <acct>] <sbatch-script>
#   <sbatch-script>: path relative to $PSCRATCH/<repo>/ on the remote side.
#   --account:       SLURM account (default: $EC_ACCOUNT_GPU from config.sh)
#
# Example: submit-batch.sh sims/scan-1/run.sbatch
#
# The account is passed on the sbatch command line, which overrides any
# `#SBATCH --account` in the script — so templates don't hardcode a project and
# can't drift from your config. Pass --account for a CPU-only job ($EC_ACCOUNT).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

ec_require_account
ACCOUNT="$EC_ACCOUNT_GPU"
if [ "${1:-}" = "--account" ]; then
    ACCOUNT="${2:?--account needs a value}"
    shift 2
fi

if [ -z "${1:-}" ]; then
    echo "Usage: $0 [--account <acct>] <sbatch-script>" >&2
    echo "  path relative to \$PSCRATCH/<repo>/ on the remote side" >&2
    exit 1
fi

REPO="$(basename "$PWD")"
SBATCH_REL="$1"

# -J ${REPO}: name the job after the repo (matches the interactive-*.sh helpers and
#   keeps squeue identifiable), instead of the script's own --job-name — so this works
#   for any project, not just one. Overrides any --job-name in the sbatch script.
# mkdir -p workdir so an sbatch script using `--output=workdir/...` can open its log
#   (workdir/ is excluded from sync-up's rsync, so it may not exist yet on a fresh repo).
# -A ${ACCOUNT}: from config, overriding whatever the script says (see header).
ssh "$EC_SSH_HOST" "cd \$PSCRATCH/${REPO} && mkdir -p workdir && sbatch -J ${REPO} -A ${ACCOUNT} ${SBATCH_REL}"
