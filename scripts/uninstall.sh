#!/usr/bin/env bash
# uninstall.sh — remove artifacts installed by the ergodic-agent-workflows bootstrap.
#
# Removes only managed rules blocks and symlinks whose targets exactly match this checkout.
# User-owned files, directories, backups, and symlinks to other targets are left untouched.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPS_DIR="${HOME}/.ergodic-agent-workflows/ops"
LEGACY_OPS_DIR="${HOME}/.ergodic-claude/ops"

say() { printf "\n\033[1;36m[ergodic-agent-workflows]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[ergodic-agent-workflows]\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31m[ergodic-agent-workflows]\033[0m %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./scripts/uninstall.sh [--agent claude|codex|both] [--nersc]

Remove bootstrap-managed artifacts for Claude Code, Codex, or both. The default is both.
By default this only changes the local machine. Add --nersc to also remove the selected
agent rules from Perlmutter.
EOF
}

AGENT="both"
REMOVE_NERSC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)
      [ $# -ge 2 ] || die "--agent needs claude, codex, or both"
      AGENT="$2"
      shift 2
      ;;
    --agent=*) AGENT="${1#*=}"; shift ;;
    --nersc) REMOVE_NERSC=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$AGENT" in
  claude) AGENTS=("claude") ;;
  codex)  AGENTS=("codex") ;;
  both)   AGENTS=("claude" "codex") ;;
  *) die "unknown agent: ${AGENT} (expected claude, codex, or both)" ;;
esac

remove_managed_link() {
  local link="$1"
  local actual expected matched=0
  shift

  if [ ! -L "$link" ]; then
    if [ -e "$link" ]; then
      warn "Leaving non-symlink untouched: ${link}"
    else
      say "Already absent: ${link}"
    fi
    return
  fi

  actual="$(readlink "$link")"
  for expected in "$@"; do
    [ "$actual" != "$expected" ] || matched=1
  done
  if [ "$matched" -ne 1 ]; then
    warn "Leaving symlink with an unexpected target untouched: ${link} -> ${actual}"
    return
  fi

  rm "$link"
  say "Removed link: ${link}"
}

for selected_agent in "${AGENTS[@]}"; do
  case "$selected_agent" in
    claude)
      skills_dir="${HOME}/.claude/skills"
      compat_link="${HOME}/.claude/scripts/ergodic"
      ;;
    codex)
      skills_dir="${HOME}/.codex/skills"
      compat_link="${HOME}/.codex/scripts/ergodic"
      ;;
  esac

  for skill in nersc-workflow mlflow-query adept-run research-notes nersc-investigation-consumer; do
    remove_managed_link "${skills_dir}/${skill}" "${REPO_ROOT}/skills/${skill}"
  done
  remove_managed_link "$compat_link" "$OPS_DIR" "$LEGACY_OPS_DIR"
done

"${REPO_ROOT}/scripts/install-agent-rules.sh" --remove --agent "$AGENT"

# The neutral ops link is shared. Remove it only when neither agent still has the
# compatibility link created by bootstrap-local.sh.
CLAUDE_COMPAT="${HOME}/.claude/scripts/ergodic"
CODEX_COMPAT="${HOME}/.codex/scripts/ergodic"
is_managed_compat_link() {
  local target
  [ -L "$1" ] || return 1
  target="$(readlink "$1")"
  [ "$target" = "$OPS_DIR" ] || [ "$target" = "$LEGACY_OPS_DIR" ]
}
if ! is_managed_compat_link "$CLAUDE_COMPAT" \
    && ! is_managed_compat_link "$CODEX_COMPAT"; then
  remove_managed_link "$OPS_DIR" "${REPO_ROOT}/scripts/ops"
  remove_managed_link "$LEGACY_OPS_DIR" "$OPS_DIR" "${REPO_ROOT}/scripts/ops"
else
  say "Keeping shared ops link because another agent still uses it: ${OPS_DIR}"
fi

if [ "$REMOVE_NERSC" -eq 1 ]; then
  say "Removing managed ${AGENT} agent rules on Perlmutter…"
  ssh -o ConnectTimeout=10 perlmutter true 2>/dev/null \
    || die "Can't ssh to perlmutter. Local uninstall is complete; run sshproxy, then retry with --nersc."
  REMOTE_TMP="$(ssh perlmutter 'mktemp -d "${HOME}/.ec-uninstall-XXXXXX"')"
  [ -n "$REMOTE_TMP" ] || die "couldn't create a staging dir on Perlmutter"
  scp -q "${REPO_ROOT}/scripts/install-agent-rules.sh" "perlmutter:${REMOTE_TMP}/" \
    || die "couldn't copy the rules installer to Perlmutter (staging dir ${REMOTE_TMP})"
  ssh perlmutter "bash '${REMOTE_TMP}/install-agent-rules.sh' --remove --agent '${AGENT}'; rm -rf '${REMOTE_TMP}'"
fi

say "Uninstall complete for agent selection: ${AGENT}"
