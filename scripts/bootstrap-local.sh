#!/usr/bin/env bash
# bootstrap-local.sh — set up the local side of the ergodic-claude workflow.
#
# What this does:
#   1. Installs uv if it's missing (per-user, no sudo)
#   2. Symlinks the skills into both Claude Code and Codex global skill directories
#   3. Symlinks the ops scripts into ~/.ergodic-claude/ops/ (agent-neutral stable path)
#   4. Installs NERSC's required agent rules into both agents' global guidance files
#   5. Verifies you can ssh to perlmutter
#   6. Prints what to do next
#
# Idempotent — safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_SKILLS_DIR="${HOME}/.claude/skills"
CODEX_SKILLS_DIR="${HOME}/.codex/skills"
OPS_DIR="${HOME}/.ergodic-claude/ops"

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

# 2. Skills — the same SKILL.md files work with both agents.
for skills_dir in "${CLAUDE_SKILLS_DIR}" "${CODEX_SKILLS_DIR}"; do
  mkdir -p "${skills_dir}"
  for skill in nersc-workflow aws-batch-run mlflow-query adept-run; do
    src="${REPO_ROOT}/skills/${skill}"
    dst="${skills_dir}/${skill}"
    if [[ -e "${dst}" && ! -L "${dst}" ]]; then
      warn "${dst} exists and is not a symlink — backing up to ${dst}.bak"
      mv "${dst}" "${dst}.bak"
    fi
    rm -f "${dst}"
    ln -s "${src}" "${dst}"
    say "Linked skill: ${dst} -> ${src}"
  done
done

# 3. Ops scripts — use one stable, agent-neutral path. This avoids embedding a
#    Claude-specific path in skills that Codex also loads.
mkdir -p "$(dirname "${OPS_DIR}")"
if [[ -e "${OPS_DIR}" && ! -L "${OPS_DIR}" ]]; then
  warn "${OPS_DIR} exists and is not a symlink — backing up to ${OPS_DIR}.bak"
  mv "${OPS_DIR}" "${OPS_DIR}.bak"
fi
rm -f "${OPS_DIR}"
ln -s "${REPO_ROOT}/scripts/ops" "${OPS_DIR}"
say "Linked ops scripts: ${OPS_DIR} -> ${REPO_ROOT}/scripts/ops"

# Keep the former Claude path and an equivalent Codex path as compatibility
# links. Existing prompts and older skill copies can continue to invoke them,
# while new instructions use the neutral path above.
for ops_compat_dir in "${HOME}/.claude/scripts/ergodic" "${HOME}/.codex/scripts/ergodic"; do
  mkdir -p "$(dirname "${ops_compat_dir}")"
  if [[ -e "${ops_compat_dir}" && ! -L "${ops_compat_dir}" ]]; then
    warn "${ops_compat_dir} exists and is not a symlink — leaving it untouched"
    continue
  fi
  rm -f "${ops_compat_dir}"
  ln -s "${OPS_DIR}" "${ops_compat_dir}"
  say "Linked compatibility path: ${ops_compat_dir} -> ${OPS_DIR}"
done

# 4. Agent rules — NERSC requires the filesystem-traversal rules to live in the agent's
#    config file, not just in a skill (they must bind even when no skill is loaded).
#    https://docs.nersc.gov/development/coding-agents/
"${REPO_ROOT}/scripts/install-agent-rules.sh" --agent both

# 5. SSH check — fatal. The ops scripts and the nersc-workflow skill assume
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

# 6. MLflow env var hint
say "Make sure these env vars are set in your shell profile (~/.zshrc or ~/.bashrc):"
cat <<'EOF'
  export MLFLOW_TRACKING_URI=https://continuum.ergodic.io/experiments/
  export MLFLOW_TRACKING_USERNAME=<your-username>
  export MLFLOW_TRACKING_PASSWORD=<your-token>
EOF

say "Local bootstrap done. Next: run scripts/bootstrap-nersc.sh to set up Perlmutter."
