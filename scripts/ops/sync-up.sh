#!/usr/bin/env bash
# rsync the current local repo up to $PSCRATCH/<repo>/ on the cluster.
# Usage: sync-up.sh
#
# Stamps the current git commit SHA to .git_commit first so training scripts
# can log it to MLflow (since .git/ is excluded from the rsync).
# Excludes match the nersc-workflow skill: __pycache__, .git, .venv,
# checkpoints, runinfo, workdir, plots, *.ipynb_checkpoints, uv.lock.
# workdir/ holds run outputs + detached-launch logs on scratch (see
# kinetic-srs CLAUDE.md) — without the exclude, --delete wipes it on every
# sync (it deleted remote launch logs on 2026-06-11).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

REPO="$(basename "$PWD")"

if git rev-parse HEAD >/dev/null 2>&1; then
    git rev-parse HEAD > .git_commit
fi

rsync -avz --delete \
    --exclude='__pycache__' \
    --exclude='.git/' \
    --exclude='.venv/' \
    --exclude='checkpoints/' \
    --exclude='runinfo/' \
    --exclude='workdir/' \
    --exclude='plots/' \
    --exclude='*.ipynb_checkpoints' \
    --exclude='uv.lock' \
    ./ \
    "${EC_SSH_HOST}:\$PSCRATCH/${REPO}/"
