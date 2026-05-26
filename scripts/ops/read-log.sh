#!/usr/bin/env bash
# Cat a file from the remote repo workdir (i.e. $PSCRATCH/<repo>/<path>).
# Usage: read-log.sh <relative-path>
# Example: read-log.sh slurm-49966950.out
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <relative-path>" >&2
    exit 1
fi

REPO="$(basename "$PWD")"
ssh "$EC_SSH_HOST" "cat \$PSCRATCH/${REPO}/$1"
