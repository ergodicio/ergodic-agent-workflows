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

printf 'bootstrap agent selection tests passed\n'
