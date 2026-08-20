#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
SSH_HOST="test-perlmutter-$$"
PREFLIGHT_MARKER="/tmp/.ec-ssh-ok-${SSH_HOST}-$(id -u)"
trap 'rm -rf "$TEST_ROOT"; rm -f "$PREFLIGHT_MARKER"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    grep -Fq -- "$2" "$1" || fail "expected $1 to contain: $2"
}

STUBS="${TEST_ROOT}/bin"
SSH_LOG="${TEST_ROOT}/ssh.log"
RSYNC_LOG="${TEST_ROOT}/rsync.log"
MARKER_STORE="${TEST_ROOT}/remote-marker"
mkdir -p "$STUBS"

cat > "${STUBS}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
remote=""
{
    printf 'ssh'
    for arg in "$@"; do
        printf '\t%q' "$arg"
        remote="$arg"
    done
    printf '\n'
} >> "$SESSION_TEST_SSH_LOG"

case "$remote" in
    true) exit 0 ;;
    'id -un') printf 'testuser\n'; exit 0 ;;
    'printenv PSCRATCH') printf '/pscratch/sd/t/testuser\n'; exit 0 ;;
    *'tee '*'.ergodic-session'*) cat > "$SESSION_TEST_MARKER_STORE"; exit 0 ;;
    *'cat '*'.ergodic-session'*) cat "$SESSION_TEST_MARKER_STORE"; exit 0 ;;
    *'tee '*) cat >/dev/null; exit 0 ;;
    *'salloc '*) printf 'salloc: Granted job allocation 424242\n' >&2; exit 0 ;;
    *'squeue -h -j 424242 -o %T'*) printf 'RUNNING\n'; exit 0 ;;
    *'squeue -j 424242 '*) printf 'JOBID NAME STATE ELAPSED TIME_LIMIT NODELIST\n424242 test RUNNING 0:01 1:00 nid001\n'; exit 0 ;;
    *) exit 0 ;;
esac
EOF

cat > "${STUBS}/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'rsync'
    for arg in "$@"; do printf '\t%q' "$arg"; done
    printf '\n'
} >> "$SESSION_TEST_RSYNC_LOG"
EOF

chmod +x "${STUBS}/ssh" "${STUBS}/rsync"

WORKTREE="${TEST_ROOT}/agent-worktree-1234"
mkdir -p "$WORKTREE"
git -C "$WORKTREE" init -q
git -C "$WORKTREE" config user.email test@example.com
git -C "$WORKTREE" config user.name Test
git -C "$WORKTREE" remote add origin git@github.com:ergodicio/example-repo.git
printf 'committed\n' > "${WORKTREE}/calculation.py"
git -C "$WORKTREE" add calculation.py
git -C "$WORKTREE" commit -qm initial
printf 'dirty change\n' >> "${WORKTREE}/calculation.py"
printf 'untracked input\n' > "${WORKTREE}/new-config.yaml"

SESSION=(
    env
    "HOME=${TEST_ROOT}/home"
    "PATH=${STUBS}:$PATH"
    "EC_ACCOUNT=m1234"
    "EC_CONFIG=${TEST_ROOT}/missing-config"
    "EC_SESSION_STATE_DIR=${TEST_ROOT}/state"
    "EC_SSH_HOST=${SSH_HOST}"
    "SESSION_TEST_SSH_LOG=${SSH_LOG}"
    "SESSION_TEST_RSYNC_LOG=${RSYNC_LOG}"
    "SESSION_TEST_MARKER_STORE=${MARKER_STORE}"
    "${REPO_ROOT}/scripts/ops/session.sh"
)

(
    cd "$WORKTREE"
    "${SESSION[@]}" start --kind shared --hours 1 --gpus 1 >/dev/null
)

[ -s "$RSYNC_LOG" ] || fail "start did not perform an initial source sync"
assert_contains "$RSYNC_LOG" '--delete-delay'
assert_contains "$RSYNC_LOG" '/example-repo-sessions/'
assert_contains "$RSYNC_LOG" '/src/'
assert_contains "$MARKER_STORE" 'ergodic-claude-session-v1'
assert_contains "$MARKER_STORE" 'repo=example-repo'

STATE_FILE="$(find "${TEST_ROOT}/state" -type f -name '*.state' -print -quit)"
[ -n "$STATE_FILE" ] || fail "start did not create local session state"
assert_contains "$STATE_FILE" $'job_id\t424242'
assert_contains "$STATE_FILE" $'dirty\ttrue'
FINGERPRINT_BEFORE="$(awk -F '\t' '$1 == "workspace_fingerprint" {print $2}' "$STATE_FILE")"
printf 'second dirty change\n' >> "${WORKTREE}/new-config.yaml"

(
    cd "$WORKTREE"
    "${SESSION[@]}" exec -- python -c 'print("ok"); touch /tmp/not-executed-locally' >/dev/null
    "${SESSION[@]}" shell >/dev/null
    "${SESSION[@]}" status >/dev/null
    "${SESSION[@]}" sync >/dev/null
)

FINGERPRINT_AFTER="$(awk -F '\t' '$1 == "workspace_fingerprint" {print $2}' "$STATE_FILE")"
[ "$FINGERPRINT_BEFORE" != "$FINGERPRINT_AFTER" ] \
    || fail "workspace fingerprint did not change with untracked file contents"
assert_contains "$SSH_LOG" 'srun'
assert_contains "$SSH_LOG" 'python'
assert_contains "$SSH_LOG" '--pty'
assert_contains "$SSH_LOG" 'not-executed-locally'

(
    cd "$WORKTREE"
    "${SESSION[@]}" stop >/dev/null
)

[ ! -e "$STATE_FILE" ] || fail "stop did not clear local session state"
assert_contains "$SSH_LOG" 'scancel'
assert_contains "$SSH_LOG" '424242'

if (
    cd "$WORKTREE"
    "${SESSION[@]}" start --kind cpu --gpus 1 >/dev/null 2>&1
); then
    fail "CPU session accepted the shared-GPU --gpus option"
fi

(
    cd "$WORKTREE"
    "${SESSION[@]}" start --kind cpu --hours 1 --nodes 2 >/dev/null
    "${SESSION[@]}" stop >/dev/null
    "${SESSION[@]}" start --kind gpu --hours 1 --nodes 2 >/dev/null
    "${SESSION[@]}" stop >/dev/null
)

assert_contains "$SSH_LOG" '--constraint\ cpu'
assert_contains "$SSH_LOG" '--nodes\ 2'
assert_contains "$SSH_LOG" '--gpus-per-node\ 4'

printf 'interactive session tests passed\n'
