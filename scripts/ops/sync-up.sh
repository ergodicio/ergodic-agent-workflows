#!/usr/bin/env bash
# rsync the current local repo up to $PSCRATCH/<repo>/ on the cluster.
# Usage: sync-up.sh
#
# Stamps the current git commit SHA to .git_commit first so training scripts
# can log it to MLflow (since .git/ is excluded from the rsync).
# Excludes match the nersc-workflow skill: __pycache__, .git, .venv,
# checkpoints, runinfo, workdir, plots, *.ipynb_checkpoints, uv.lock,
# mlruns/, mlflow.db.
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

# Resolve $PSCRATCH on the remote and rsync to an absolute path.
# We can't let rsync's remote arg carry a literal "\$PSCRATCH" for the remote
# shell to expand: rsync 3.2.4+ backslash-escapes shell metacharacters (incl.
# `$`) in remote paths as injection hardening, so "\$PSCRATCH" is taken
# literally and rsync tries to mkdir "~/\$PSCRATCH/<repo>". (--old-args turns
# the escaping off, but that disables *all* the hardening.) Resolving the path
# up front via ssh is version-proof.
REMOTE_SCRATCH="$(ssh "${EC_SSH_HOST}" 'echo "$PSCRATCH"')"
if [ -z "$REMOTE_SCRATCH" ]; then
    echo "[sync-up] could not resolve \$PSCRATCH on ${EC_SSH_HOST}" >&2
    exit 1
fi

rsync -avz --delete \
    --exclude='__pycache__' \
    --exclude='.git/' \
    --exclude='.venv/' \
    --exclude='checkpoints/' \
    --exclude='runinfo/' \
    --exclude='workdir/' \
    --exclude='plots/' \
    --exclude='mlruns/' \
    --exclude='mlflow.db' \
    --exclude='*.ipynb_checkpoints' \
    --exclude='uv.lock' \
    ./ \
    "${EC_SSH_HOST}:${REMOTE_SCRATCH}/${REPO}/"
