#!/usr/bin/env bash
# bootstrap-local.sh — set up the local side of the ergodic-claude workflow.
#
# What this does:
#   1. Installs uv if it's missing (per-user, no sudo)
#   2. Copies the two skills into ~/.claude/skills/ so Claude Code picks them up globally
#   3. Verifies you can ssh to perlmutter
#   4. Prints what to do next
#
# Idempotent — safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_SKILLS_DIR="${HOME}/.claude/skills"

say() { printf "\n\033[1;36m[ergodic-claude]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[ergodic-claude]\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31m[ergodic-claude]\033[0m %s\n" "$*" >&2; exit 1; }

# 1. uv
if ! command -v uv >/dev/null 2>&1; then
  say "Installing uv (per-user, no sudo)…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # shellcheck disable=SC1090
  source "${HOME}/.local/bin/env" 2>/dev/null || true
else
  say "uv already installed ($(uv --version))"
fi

# 2. Skills
mkdir -p "${CLAUDE_SKILLS_DIR}"
for skill in nersc-workflow mlflow-query adept-run; do
  src="${REPO_ROOT}/skills/${skill}"
  dst="${CLAUDE_SKILLS_DIR}/${skill}"
  if [[ -e "${dst}" && ! -L "${dst}" ]]; then
    warn "${dst} exists and is not a symlink — backing up to ${dst}.bak"
    mv "${dst}" "${dst}.bak"
  fi
  rm -f "${dst}"
  ln -s "${src}" "${dst}"
  say "Linked skill: ${dst} -> ${src}"
done

# 3. SSH check (best-effort, non-fatal)
say "Checking ssh to perlmutter…"
if ssh -o ConnectTimeout=5 -o BatchMode=yes perlmutter true 2>/dev/null; then
  say "ssh perlmutter works."
else
  warn "Couldn't ssh to perlmutter non-interactively."
  warn "If you haven't yet, set up sshproxy and add a 'perlmutter' alias to ~/.ssh/config."
  warn "See: https://docs.nersc.gov/connect/mfa/#sshproxy and the repo README."
fi

# 4. MLflow env var hint
say "Make sure these env vars are set in your shell profile (~/.zshrc or ~/.bashrc):"
cat <<'EOF'
  export MLFLOW_TRACKING_URI=https://continuum.ergodic.io/experiments/
  export MLFLOW_TRACKING_USERNAME=<your-username>
  export MLFLOW_TRACKING_PASSWORD=<your-token>
EOF

say "Local bootstrap done. Next: run scripts/bootstrap-nersc.sh to set up Perlmutter."
