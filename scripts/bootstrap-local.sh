#!/usr/bin/env bash
# bootstrap-local.sh — set up the local side of the ergodic-claude workflow.
#
# What this does:
#   1. Installs uv if it's missing (per-user, no sudo)
#   2. Symlinks the skills into ~/.claude/skills/ so Claude Code picks them up globally
#   3. Symlinks the ops scripts into ~/.claude/scripts/ergodic/ (one allowlist rule covers all)
#   4. Verifies you can ssh to perlmutter
#   5. Prints what to do next
#
# Idempotent — safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_SKILLS_DIR="${HOME}/.claude/skills"
CLAUDE_SCRIPTS_DIR="${HOME}/.claude/scripts"

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
for skill in nersc-workflow aws-batch-run mlflow-query adept-run zotero; do
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

# 3. Ops scripts — symlink scripts/ops/ to ~/.claude/scripts/ergodic/ so skills
#    can reference helpers at a stable absolute path. Allowlist target:
#    Bash(~/.claude/scripts/ergodic/*)
mkdir -p "${CLAUDE_SCRIPTS_DIR}"
ops_dst="${CLAUDE_SCRIPTS_DIR}/ergodic"
if [[ -e "${ops_dst}" && ! -L "${ops_dst}" ]]; then
  warn "${ops_dst} exists and is not a symlink — backing up to ${ops_dst}.bak"
  mv "${ops_dst}" "${ops_dst}.bak"
fi
rm -f "${ops_dst}"
ln -s "${REPO_ROOT}/scripts/ops" "${ops_dst}"
say "Linked ops scripts: ${ops_dst} -> ${REPO_ROOT}/scripts/ops"
say "  → Allow them in one rule: add 'Bash(~/.claude/scripts/ergodic/*)' to your settings."

# 4. SSH check — fatal. The ops scripts and the nersc-workflow skill assume
#    `ssh perlmutter true` works non-interactively. There's no useful state
#    past this point if it doesn't.
say "Checking ssh to perlmutter…"
if ssh -o ConnectTimeout=5 -o BatchMode=yes perlmutter true 2>/dev/null; then
  say "ssh perlmutter works."
else
  cat >&2 <<EOF

[ergodic-claude] ssh to 'perlmutter' is not working non-interactively.

Likely causes:
  1. The 'perlmutter' alias is missing from ~/.ssh/config.
  2. Your NERSC sshproxy cert is expired — run sshproxy again.
  3. You haven't set up sshproxy yet.

Docs:    https://docs.nersc.gov/connect/mfa/#sshproxy
Verify:  ssh perlmutter true

Fix the ssh setup, then re-run this script.
EOF
  exit 1
fi

# 5. MLflow env var hint
say "Make sure these env vars are set in your shell profile (~/.zshrc or ~/.bashrc):"
cat <<'EOF'
  export MLFLOW_TRACKING_URI=https://continuum.ergodic.io/experiments/
  export MLFLOW_TRACKING_USERNAME=<your-username>
  export MLFLOW_TRACKING_PASSWORD=<your-token>
EOF

say "Local bootstrap done. Next: run scripts/bootstrap-nersc.sh to set up Perlmutter."
