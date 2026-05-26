#!/usr/bin/env bash
# Show the current git HEAD SHA of a checkout on the cluster.
# Usage: remote-sha.sh [subdir]
#   subdir: path relative to $PSCRATCH/<repo>/. Defaults to "" (the repo root).
#
# Useful when you depend on an external checkout (e.g. adept) inside the synced
# repo and want to log its commit for reproducibility.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

REPO="$(basename "$PWD")"
SUBDIR="${1:-}"

if [ -n "$SUBDIR" ]; then
    REMOTE_PATH="\$PSCRATCH/${REPO}/${SUBDIR}"
else
    REMOTE_PATH="\$PSCRATCH/${REPO}"
fi

ssh "$EC_SSH_HOST" "cd ${REMOTE_PATH} && git rev-parse HEAD"
