#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_link() {
  [ -L "$1" ] || fail "expected symlink: $1"
}

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
}

assert_missing() {
  [ ! -e "$1" ] && [ ! -L "$1" ] || fail "expected path to be absent: $1"
}

STUBS="${TEST_ROOT}/bin"
mkdir -p "$STUBS"

cat >"${STUBS}/uv" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && printf 'uv test\n'
EOF

cat >"${STUBS}/ssh" <<'EOF'
#!/usr/bin/env bash
[ -z "${BOOTSTRAP_TEST_SSH_LOG:-}" ] || printf '%s\n' "$*" >> "$BOOTSTRAP_TEST_SSH_LOG"
case "$*" in
  *"mktemp -d"*) printf '/home/test/.ec-install-test\n' ;;
  *"bash -s"*) cat >/dev/null ;;
esac
EOF

cat >"${STUBS}/scp" <<'EOF'
#!/usr/bin/env bash
[ -z "${BOOTSTRAP_TEST_SSH_LOG:-}" ] || printf 'scp %s\n' "$*" >> "$BOOTSTRAP_TEST_SSH_LOG"
EOF

chmod +x "${STUBS}/uv" "${STUBS}/ssh" "${STUBS}/scp"

run_local_case() {
  local agent="$1"
  local home="${TEST_ROOT}/local-${agent}"
  mkdir -p "$home"

  HOME="$home" PATH="${STUBS}:$PATH" \
    "${REPO_ROOT}/scripts/bootstrap-local.sh" --agent "$agent" >/dev/null

  assert_link "${home}/.ergodic-claude/ops"

  case "$agent" in
    claude|both)
      assert_link "${home}/.claude/skills/nersc-workflow"
      assert_link "${home}/.claude/skills/mlflow-query"
      assert_link "${home}/.claude/skills/adept-run"
      assert_link "${home}/.claude/scripts/ergodic"
      assert_file "${home}/.claude/CLAUDE.md"
      ;;
    *)
      assert_missing "${home}/.claude"
      ;;
  esac

  case "$agent" in
    codex|both)
      assert_link "${home}/.codex/skills/nersc-workflow"
      assert_link "${home}/.codex/skills/mlflow-query"
      assert_link "${home}/.codex/skills/adept-run"
      assert_link "${home}/.codex/scripts/ergodic"
      assert_file "${home}/.codex/AGENTS.md"
      ;;
    *)
      assert_missing "${home}/.codex"
      ;;
  esac
}

for agent in claude codex both; do
  run_local_case "$agent"
done

DEFAULT_HOME="${TEST_ROOT}/local-default"
mkdir -p "$DEFAULT_HOME"
HOME="$DEFAULT_HOME" PATH="${STUBS}:$PATH" \
  "${REPO_ROOT}/scripts/bootstrap-local.sh" >/dev/null
assert_file "${DEFAULT_HOME}/.claude/CLAUDE.md"
assert_file "${DEFAULT_HOME}/.codex/AGENTS.md"

for script in bootstrap-local.sh bootstrap-nersc.sh; do
  INVALID_HOME="${TEST_ROOT}/invalid-${script}"
  mkdir -p "$INVALID_HOME"
  if HOME="$INVALID_HOME" PATH="${STUBS}:$PATH" \
      "${REPO_ROOT}/scripts/${script}" --agent gemini >/dev/null 2>&1; then
    fail "${script} accepted an invalid agent"
  fi
  assert_missing "${INVALID_HOME}/.ergodic-claude"
  "${REPO_ROOT}/scripts/${script}" --help | grep -q -- '--agent claude|codex|both' \
    || fail "${script} help does not document the agent choices"
done

"${REPO_ROOT}/scripts/uninstall.sh" --help | grep -q -- '--agent claude|codex|both' \
  || fail "uninstall.sh help does not document the agent choices"
INVALID_UNINSTALL_HOME="${TEST_ROOT}/invalid-uninstall"
mkdir -p "$INVALID_UNINSTALL_HOME"
if HOME="$INVALID_UNINSTALL_HOME" PATH="${STUBS}:$PATH" \
    "${REPO_ROOT}/scripts/uninstall.sh" --agent gemini >/dev/null 2>&1; then
  fail "uninstall.sh accepted an invalid agent"
fi

BOTH_HOME="${TEST_ROOT}/uninstall-from-both"
mkdir -p "$BOTH_HOME"
HOME="$BOTH_HOME" PATH="${STUBS}:$PATH" \
  "${REPO_ROOT}/scripts/bootstrap-local.sh" --agent both >/dev/null
HOME="$BOTH_HOME" PATH="${STUBS}:$PATH" \
  "${REPO_ROOT}/scripts/uninstall.sh" --agent claude >/dev/null
assert_missing "${BOTH_HOME}/.claude/skills/nersc-workflow"
assert_missing "${BOTH_HOME}/.claude/skills/mlflow-query"
assert_missing "${BOTH_HOME}/.claude/skills/adept-run"
assert_missing "${BOTH_HOME}/.claude/scripts/ergodic"
grep -Fq 'ergodic-claude nersc-agent-rules' "${BOTH_HOME}/.claude/CLAUDE.md" \
  && fail "Claude rules block remained after uninstall"
assert_link "${BOTH_HOME}/.codex/skills/nersc-workflow"
assert_link "${BOTH_HOME}/.codex/scripts/ergodic"
assert_file "${BOTH_HOME}/.codex/AGENTS.md"
assert_link "${BOTH_HOME}/.ergodic-claude/ops"

CLAUDE_HOME="${TEST_ROOT}/uninstall-claude-only"
mkdir -p "$CLAUDE_HOME"
HOME="$CLAUDE_HOME" PATH="${STUBS}:$PATH" \
  "${REPO_ROOT}/scripts/bootstrap-local.sh" --agent claude >/dev/null
HOME="$CLAUDE_HOME" PATH="${STUBS}:$PATH" \
  "${REPO_ROOT}/scripts/uninstall.sh" --agent claude >/dev/null
assert_missing "${CLAUDE_HOME}/.claude/skills/nersc-workflow"
assert_missing "${CLAUDE_HOME}/.claude/scripts/ergodic"
assert_missing "${CLAUDE_HOME}/.ergodic-claude/ops"
HOME="$CLAUDE_HOME" PATH="${STUBS}:$PATH" \
  "${REPO_ROOT}/scripts/uninstall.sh" --agent claude >/dev/null

RULES_TARGET="${TEST_ROOT}/rules-target.md"
printf 'user content before\n' > "$RULES_TARGET"
"${REPO_ROOT}/scripts/install-agent-rules.sh" --target "$RULES_TARGET" >/dev/null
printf 'user content after\n' >> "$RULES_TARGET"
"${REPO_ROOT}/scripts/install-agent-rules.sh" --remove --target "$RULES_TARGET" >/dev/null
grep -Fq 'user content before' "$RULES_TARGET" || fail "rules removal lost preceding user content"
grep -Fq 'user content after' "$RULES_TARGET" || fail "rules removal lost following user content"
grep -Fq 'ergodic-claude nersc-agent-rules' "$RULES_TARGET" \
  && fail "direct rules removal left the managed block behind"
assert_file "${RULES_TARGET}.bak"

UNEXPECTED_HOME="${TEST_ROOT}/uninstall-unexpected-link"
mkdir -p "${UNEXPECTED_HOME}/.claude/skills" "${TEST_ROOT}/user-owned-skill"
ln -s "${TEST_ROOT}/user-owned-skill" "${UNEXPECTED_HOME}/.claude/skills/adept-run"
HOME="$UNEXPECTED_HOME" PATH="${STUBS}:$PATH" \
  "${REPO_ROOT}/scripts/uninstall.sh" --agent claude >/dev/null
assert_link "${UNEXPECTED_HOME}/.claude/skills/adept-run"
[ "$(readlink "${UNEXPECTED_HOME}/.claude/skills/adept-run")" = "${TEST_ROOT}/user-owned-skill" ] \
  || fail "uninstall.sh changed an unexpected symlink target"

for agent in claude codex both; do
  NERSC_HOME="${TEST_ROOT}/nersc-${agent}"
  NERSC_LOG="${TEST_ROOT}/nersc-${agent}.log"
  mkdir -p "$NERSC_HOME"
  HOME="$NERSC_HOME" PATH="${STUBS}:$PATH" EC_ACCOUNT=m4490 \
    BOOTSTRAP_TEST_SSH_LOG="$NERSC_LOG" \
    "${REPO_ROOT}/scripts/bootstrap-nersc.sh" --agent="$agent" >/dev/null
  grep -Fq -- "--agent '${agent}'" "$NERSC_LOG" \
    || fail "bootstrap-nersc.sh did not forward agent selection: ${agent}"
done

UNINSTALL_NERSC_HOME="${TEST_ROOT}/uninstall-nersc"
UNINSTALL_NERSC_LOG="${TEST_ROOT}/uninstall-nersc.log"
mkdir -p "$UNINSTALL_NERSC_HOME"
HOME="$UNINSTALL_NERSC_HOME" PATH="${STUBS}:$PATH" \
  BOOTSTRAP_TEST_SSH_LOG="$UNINSTALL_NERSC_LOG" \
  "${REPO_ROOT}/scripts/uninstall.sh" --agent claude --nersc >/dev/null
grep -Fq -- "--remove --agent 'claude'" "$UNINSTALL_NERSC_LOG" \
  || fail "uninstall.sh did not forward remote Claude rules removal"

printf 'bootstrap agent selection tests passed\n'
