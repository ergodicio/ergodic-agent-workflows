#!/usr/bin/env bash
# Grep a file in the remote repo workdir (i.e. $PSCRATCH/<repo>/<path>).
# Usage: grep-log.sh <pattern> <relative-path>
# Example: grep-log.sh 'error\|fail' slurm-49966950.out
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <pattern> <relative-path>" >&2
    exit 1
fi

REPO="$(basename "$PWD")"
PATTERN="$1"
RELPATH="$2"
ssh "$EC_SSH_HOST" "grep -in '$PATTERN' \$PSCRATCH/${REPO}/${RELPATH}"
