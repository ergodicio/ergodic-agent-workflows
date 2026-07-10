#!/usr/bin/env bash
# Submit an sbatch script that lives inside the synced repo on the cluster.
# Usage: submit-batch.sh <sbatch-script>
#   <sbatch-script>: path relative to $PSCRATCH/<repo>/ on the remote side.
#
# Example: submit-batch.sh sims/scan-1/run.sbatch
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <sbatch-script>" >&2
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
ssh "$EC_SSH_HOST" "cd \$PSCRATCH/${REPO} && mkdir -p workdir && sbatch -J ${REPO} ${SBATCH_REL}"
