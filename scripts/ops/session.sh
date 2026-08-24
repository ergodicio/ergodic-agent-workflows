#!/usr/bin/env bash
# Manage one isolated, persistent NERSC development allocation for the current repo.
#
# Usage:
#   session.sh start [--kind shared|gpu|cpu] [--hours N] [--gpus N | --nodes N]
#   session.sh sync
#   session.sh exec [--] <command> [args ...]
#   session.sh shell
#   session.sh status
#   session.sh stop
#
# The local worktree may be dirty. Source is synchronized into a disposable,
# session-specific directory while logs and outputs live beside it and survive
# later source syncs:
#
#   $PSCRATCH/<repo>-sessions/<session-id>/{src,workdir,outputs}
#
# `sync` removes stale synchronized source, including local deletions, but that
# deletion is constrained to the marked `src/` directory belonging to this
# session. It never targets the shared $PSCRATCH/<repo>/ tree or session outputs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

usage() {
    sed -n '2,20s/^# \{0,1\}//p' "$0"
}

die() {
    echo "[session] $*" >&2
    exit 2
}

is_count() {
    case "$1" in
        ''|*[!0-9]*|0) return 1 ;;
        *) return 0 ;;
    esac
}

is_safe_name() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*|-) return 1 ;;
        *) return 0 ;;
    esac
}

is_safe_absolute_path() {
    case "$1" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!A-Za-z0-9._/-]*|*/../*|*/..|*/./*|*/.) return 1 ;;
        *) return 0 ;;
    esac
}

sha256_stream() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        die "need shasum or sha256sum to fingerprint the workspace"
    fi
}

shell_quote() {
    printf -v REPLY '%q' "$1"
}

quote_argv() {
    local arg quoted result=""
    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        result="${result}${result:+ }${quoted}"
    done
    REPLY="$result"
}

remote_run() {
    quote_argv "$@"
    ssh "$EC_SSH_HOST" "$REPLY"
}

require_repo() {
    local origin_url common_dir
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
        || die "run this command from inside a Git worktree"
    git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1 \
        || die "the worktree needs an initial commit before starting a session"
    origin_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
    if [ -n "$origin_url" ]; then
        origin_url="${origin_url%/}"
        REPO="${origin_url##*/}"
        REPO="${REPO##*:}"
        REPO="${REPO%.git}"
    else
        common_dir="$(git -C "$REPO_ROOT" rev-parse --git-common-dir)"
        case "$common_dir" in
            /*) ;;
            *) common_dir="${REPO_ROOT}/${common_dir}" ;;
        esac
        REPO="$(basename "$(dirname "$common_dir")")"
    fi
    is_safe_name "$REPO" \
        || die "repo name must contain only letters, numbers, '.', '_', or '-' (got: $REPO)"

    STATE_KEY="$(printf '%s' "$REPO_ROOT" | sha256_stream | cut -c1-12)"
    STATE_DIR="${EC_SESSION_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ergodic-agent-workflows/sessions}"
    STATE_FILE="${STATE_DIR}/${REPO}-${STATE_KEY}.state"
    if [ -z "${EC_SESSION_STATE_DIR:-}" ] && [ ! -f "$STATE_FILE" ]; then
        LEGACY_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/ergodic-claude/sessions/${REPO}-${STATE_KEY}.state"
        if [ -f "$LEGACY_STATE_FILE" ]; then
            STATE_DIR="$(dirname "$LEGACY_STATE_FILE")"
            STATE_FILE="$LEGACY_STATE_FILE"
        fi
    fi
}

state_value() {
    local key="$1"
    awk -F '\t' -v key="$key" '$1 == key {sub(/^[^\t]*\t/, ""); print; exit}' "$STATE_FILE"
}

load_state() {
    [ -f "$STATE_FILE" ] || die "no active session for $REPO; run: $0 start"

    SESSION_ID="$(state_value session_id)"
    JOB_ID="$(state_value job_id)"
    REMOTE_SCRATCH="$(state_value remote_scratch)"
    REMOTE_USER="$(state_value remote_user)"
    KIND="$(state_value kind)"
    HOURS="$(state_value hours)"

    is_safe_name "$SESSION_ID" || die "invalid session id in $STATE_FILE"
    is_count "$JOB_ID" || die "invalid job id in $STATE_FILE"
    is_safe_absolute_path "$REMOTE_SCRATCH" || die "invalid remote scratch path in $STATE_FILE"
    is_safe_name "$REMOTE_USER" || die "invalid remote user in $STATE_FILE"
    case "$KIND" in shared|gpu|cpu) ;; *) die "invalid session kind in $STATE_FILE" ;; esac
    is_count "$HOURS" || die "invalid walltime in $STATE_FILE"

    REMOTE_ROOT="${REMOTE_SCRATCH}/${REPO}-sessions/${SESSION_ID}"
    REMOTE_SRC="${REMOTE_ROOT}/src"
    REMOTE_WORKDIR="${REMOTE_ROOT}/workdir"
    REMOTE_OUTPUTS="${REMOTE_ROOT}/outputs"
    REMOTE_MARKER="${REMOTE_ROOT}/.ergodic-session"
}

write_state() {
    local temp
    mkdir -p "$STATE_DIR"
    umask 077
    temp="${STATE_FILE}.tmp.$$"
    {
        printf 'version\t1\n'
        printf 'session_id\t%s\n' "$SESSION_ID"
        printf 'job_id\t%s\n' "$JOB_ID"
        printf 'remote_scratch\t%s\n' "$REMOTE_SCRATCH"
        printf 'remote_user\t%s\n' "$REMOTE_USER"
        printf 'kind\t%s\n' "$KIND"
        printf 'hours\t%s\n' "$HOURS"
        printf 'base_sha\t%s\n' "${BASE_SHA:-}"
        printf 'workspace_fingerprint\t%s\n' "${WORKSPACE_FINGERPRINT:-}"
        printf 'dirty\t%s\n' "${DIRTY:-}"
    } > "$temp"
    mv "$temp" "$STATE_FILE"
}

session_state() {
    remote_run squeue -h -j "$JOB_ID" -o %T 2>/dev/null | head -n 1
}

ensure_active() {
    local state
    state="$(session_state)"
    [ -n "$state" ] \
        || die "session job $JOB_ID is no longer active; run '$0 stop' to clear it"
    case "$state" in
        PENDING|RUNNING|CONFIGURING|COMPLETING) ;;
        *) die "session job $JOB_ID is $state" ;;
    esac
}

assert_remote_session() {
    local expected legacy_expected actual
    expected="ergodic-agent-workflows-session-v1
repo=${REPO}
session=${SESSION_ID}"
    legacy_expected="ergodic-claude-session-v1
repo=${REPO}
session=${SESSION_ID}"
    actual="$(remote_run cat "$REMOTE_MARKER" 2>/dev/null || true)"
    [ "$actual" = "$expected" ] || [ "$actual" = "$legacy_expected" ] \
        || die "refusing to sync: remote session marker is missing or does not match $SESSION_ID"
    remote_run test -d "$REMOTE_SRC" \
        || die "refusing to sync: session src is not a directory"
    remote_run test ! -L "$REMOTE_SRC" \
        || die "refusing to sync: session src must not be a symbolic link"
}

is_synced_path() {
    case "$1" in
        .git/*|*/.git/*|.venv/*|*/.venv/*|__pycache__/*|*/__pycache__/*|\
        checkpoints/*|*/checkpoints/*|runinfo/*|*/runinfo/*|workdir/*|*/workdir/*|\
        plots/*|*/plots/*|mlruns/*|*/mlruns/*|*.pyc|*.ipynb_checkpoints*|\
        uv.lock|*/uv.lock|mlflow.db|*/mlflow.db)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

workspace_fingerprint() {
    (
        cd "$REPO_ROOT"
        printf 'base\0%s\0' "$BASE_SHA"
        git diff --binary --no-ext-diff HEAD --
        git ls-files --others --exclude-standard -z |
            while IFS= read -r -d '' path; do
                is_synced_path "$path" || continue
                printf 'untracked\0%s\0' "$path"
                git hash-object "$path"
            done
    ) | sha256_stream
}

record_workspace() {
    local metadata
    BASE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    if [ -n "$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)" ]; then
        DIRTY=true
    else
        DIRTY=false
    fi
    WORKSPACE_FINGERPRINT="$(workspace_fingerprint)"
    metadata="version=1
base_sha=${BASE_SHA}
dirty=${DIRTY}
workspace_fingerprint=${WORKSPACE_FINGERPRINT}
synced_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    printf '%s\n' "$metadata" | remote_run tee "${REMOTE_ROOT}/source-state" >/dev/null
    git -C "$REPO_ROOT" diff --binary --no-ext-diff HEAD -- |
        remote_run tee "${REMOTE_WORKDIR}/source.patch" >/dev/null
    git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all |
        remote_run tee "${REMOTE_WORKDIR}/source-status" >/dev/null
    write_state
}

sync_session() {
    assert_remote_session
    echo "[session] syncing dirty or clean worktree -> ${EC_SSH_HOST}:${REMOTE_SRC}/" >&2

    # `--delete-delay` is intentionally scoped to a freshly marked session's
    # disposable src/ tree. workdir/ and outputs/ are siblings, never targets.
    rsync -avz --delete-delay \
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
        "${REPO_ROOT}/" \
        "${EC_SSH_HOST}:${REMOTE_SRC}/"

    record_workspace
    echo "[session] source ${BASE_SHA:0:12} dirty=${DIRTY} fingerprint=${WORKSPACE_FINGERPRINT:0:12}" >&2
}

start_session() {
    local nodes=1 gpus=1 nodes_seen=0 gpus_seen=0 account qos constraint cpus
    local job_name alloc_output fallback requested_kind requested_hours
    KIND=shared
    HOURS=1

    while [ $# -gt 0 ]; do
        case "$1" in
            --kind) [ $# -ge 2 ] || die "--kind needs shared, gpu, or cpu"; KIND="$2"; shift 2 ;;
            --kind=*) KIND="${1#*=}"; shift ;;
            --hours) [ $# -ge 2 ] || die "--hours needs a value"; HOURS="$2"; shift 2 ;;
            --hours=*) HOURS="${1#*=}"; shift ;;
            --nodes) [ $# -ge 2 ] || die "--nodes needs a value"; nodes="$2"; nodes_seen=1; shift 2 ;;
            --nodes=*) nodes="${1#*=}"; nodes_seen=1; shift ;;
            --gpus) [ $# -ge 2 ] || die "--gpus needs a value"; gpus="$2"; gpus_seen=1; shift 2 ;;
            --gpus=*) gpus="${1#*=}"; gpus_seen=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown start option: $1" ;;
        esac
    done

    case "$KIND" in shared|gpu|cpu) ;; *) die "--kind must be shared, gpu, or cpu" ;; esac
    is_count "$HOURS" || die "--hours must be a positive integer"
    [ "$HOURS" -le 4 ] || die "interactive sessions are limited to 4 hours"
    is_count "$nodes" || die "--nodes must be a positive integer"
    is_count "$gpus" || die "--gpus must be a positive integer"
    [ "$nodes" -le 4 ] || die "--nodes must be in 1..4"
    [ "$gpus" -le 2 ] || die "--gpus must be in 1..2"
    [ "$KIND" = shared ] || [ "$gpus_seen" = 0 ] \
        || die "--gpus is only valid with --kind shared"
    [ "$KIND" != shared ] || [ "$nodes_seen" = 0 ] \
        || die "--nodes is not valid with --kind shared"

    requested_kind="$KIND"
    requested_hours="$HOURS"
    if [ -f "$STATE_FILE" ]; then
        load_state
        if [ -n "$(session_state)" ]; then
            die "session $SESSION_ID already exists as job $JOB_ID; use sync, exec, shell, status, or stop"
        fi
        echo "[session] replacing expired local session record for job $JOB_ID" >&2
    fi
    KIND="$requested_kind"
    HOURS="$requested_hours"

    ec_require_account
    REMOTE_USER="$(remote_run id -un)"
    REMOTE_SCRATCH="$(remote_run printenv PSCRATCH)"
    is_safe_name "$REMOTE_USER" || die "remote username contains unsupported characters"
    is_safe_absolute_path "$REMOTE_SCRATCH" || die "remote PSCRATCH is not a safe absolute path"

    SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}"
    is_safe_name "$SESSION_ID" || die "generated an invalid session id"
    REMOTE_ROOT="${REMOTE_SCRATCH}/${REPO}-sessions/${SESSION_ID}"
    REMOTE_SRC="${REMOTE_ROOT}/src"
    REMOTE_WORKDIR="${REMOTE_ROOT}/workdir"
    REMOTE_OUTPUTS="${REMOTE_ROOT}/outputs"
    REMOTE_MARKER="${REMOTE_ROOT}/.ergodic-session"
    job_name="ec-${REPO:0:24}-${SESSION_ID}"

    remote_run mkdir -p "$REMOTE_SRC" "$REMOTE_WORKDIR" "$REMOTE_OUTPUTS"
    printf 'ergodic-agent-workflows-session-v1\nrepo=%s\nsession=%s\n' "$REPO" "$SESSION_ID" |
        remote_run tee "$REMOTE_MARKER" >/dev/null

    case "$KIND" in
        shared)
            account="$EC_ACCOUNT_GPU"; qos=shared_interactive; constraint=gpu
            cpus=$((gpus * 32))
            ALLOC_ARGS=(salloc --no-shell --job-name "$job_name" --nodes 1 \
                --gpus "$gpus" --cpus-per-task "$cpus" --qos "$qos" \
                --constraint "$constraint" --time "${HOURS}:00:00" --account "$account")
            ;;
        gpu)
            account="$EC_ACCOUNT_GPU"; qos="$EC_QOS"; constraint="$EC_CONSTRAINT"
            ALLOC_ARGS=(salloc --no-shell --job-name "$job_name" --nodes "$nodes" \
                --gpus-per-node "$EC_GPUS_PER_NODE" --qos "$qos" \
                --constraint "$constraint" --time "${HOURS}:00:00" --account "$account")
            ;;
        cpu)
            account="$EC_ACCOUNT"; qos="$EC_QOS"; constraint=cpu
            ALLOC_ARGS=(salloc --no-shell --job-name "$job_name" --nodes "$nodes" \
                --qos "$qos" --constraint "$constraint" \
                --time "${HOURS}:00:00" --account "$account")
            ;;
    esac

    is_safe_name "$account" || die "configured account contains unsupported characters"
    is_safe_name "$qos" || die "configured QOS contains unsupported characters"
    is_safe_name "$constraint" || die "configured constraint contains unsupported characters"

    echo "[session] requesting kind=$KIND hours=$HOURS job-name=$job_name" >&2
    alloc_output="$(remote_run "${ALLOC_ARGS[@]}" 2>&1)"
    printf '%s\n' "$alloc_output" >&2
    JOB_ID="$(printf '%s\n' "$alloc_output" | sed -n 's/.*Granted job allocation \([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    if ! is_count "$JOB_ID"; then
        fallback="$(remote_run squeue -h -u "$REMOTE_USER" --name "$job_name" -o %A)"
        JOB_ID="$(printf '%s\n' "$fallback" | head -n 1)"
    fi
    is_count "$JOB_ID" || die "allocation succeeded but its job id could not be determined"

    write_state
    sync_session
    echo "[session] ready: id=$SESSION_ID job=$JOB_ID root=$REMOTE_ROOT" >&2
    echo "[session] run: $0 exec -- python run.py --cfg <config>" >&2
}

exec_session() {
    [ "${1:-}" != "--" ] || shift
    [ $# -gt 0 ] || die "usage: $0 exec [--] <command> [args ...]"
    load_state
    ensure_active

    local command_q src_q ecsh_q legacy_ecsh_q venv_q root_q workdir_q outputs_q inner
    quote_argv "$@"; command_q="$REPLY"
    shell_quote "$REMOTE_SRC"; src_q="$REPLY"
    shell_quote "${EC_SOFTWARE_ROOT}/${REMOTE_USER}/ergodic-agent-workflows.sh"; ecsh_q="$REPLY"
    shell_quote "${EC_SOFTWARE_ROOT}/${REMOTE_USER}/ergodic-claude.sh"; legacy_ecsh_q="$REPLY"
    shell_quote "${EC_SOFTWARE_ROOT}/${REMOTE_USER}/venvs/${REPO}/bin/activate"; venv_q="$REPLY"
    shell_quote "$REMOTE_ROOT"; root_q="$REPLY"
    shell_quote "$REMOTE_WORKDIR"; workdir_q="$REPLY"
    shell_quote "$REMOTE_OUTPUTS"; outputs_q="$REPLY"
    inner="set -euo pipefail; cd ${src_q}; export EC_SESSION_ROOT=${root_q} EC_SESSION_WORKDIR=${workdir_q} EC_SESSION_OUTPUTS=${outputs_q}; export PYTHONPATH=${src_q}:${src_q}/src\${PYTHONPATH:+:\$PYTHONPATH}; if [ -f ${ecsh_q} ]; then source ${ecsh_q}; elif [ -f ${legacy_ecsh_q} ]; then source ${legacy_ecsh_q}; fi; [ ! -f ${venv_q} ] || source ${venv_q}; exec ${command_q}"
    remote_run srun --jobid "$JOB_ID" --overlap bash -lc "$inner"
}

shell_session() {
    load_state
    ensure_active

    local src_q ecsh_q legacy_ecsh_q venv_q root_q workdir_q outputs_q inner remote_command
    shell_quote "$REMOTE_SRC"; src_q="$REPLY"
    shell_quote "${EC_SOFTWARE_ROOT}/${REMOTE_USER}/ergodic-agent-workflows.sh"; ecsh_q="$REPLY"
    shell_quote "${EC_SOFTWARE_ROOT}/${REMOTE_USER}/ergodic-claude.sh"; legacy_ecsh_q="$REPLY"
    shell_quote "${EC_SOFTWARE_ROOT}/${REMOTE_USER}/venvs/${REPO}/bin/activate"; venv_q="$REPLY"
    shell_quote "$REMOTE_ROOT"; root_q="$REPLY"
    shell_quote "$REMOTE_WORKDIR"; workdir_q="$REPLY"
    shell_quote "$REMOTE_OUTPUTS"; outputs_q="$REPLY"
    inner="cd ${src_q}; export EC_SESSION_ROOT=${root_q} EC_SESSION_WORKDIR=${workdir_q} EC_SESSION_OUTPUTS=${outputs_q}; export PYTHONPATH=${src_q}:${src_q}/src\${PYTHONPATH:+:\$PYTHONPATH}; if [ -f ${ecsh_q} ]; then source ${ecsh_q}; elif [ -f ${legacy_ecsh_q} ]; then source ${legacy_ecsh_q}; fi; [ ! -f ${venv_q} ] || source ${venv_q}; exec bash -i"
    quote_argv srun --jobid "$JOB_ID" --overlap --pty bash -lc "$inner"
    remote_command="$REPLY"
    ssh -tt "$EC_SSH_HOST" "$remote_command"
}

status_session() {
    load_state
    printf 'session_id: %s\njob_id: %s\nkind: %s\nhours: %s\nremote_root: %s\n' \
        "$SESSION_ID" "$JOB_ID" "$KIND" "$HOURS" "$REMOTE_ROOT"
    remote_run squeue -j "$JOB_ID" --format=JobID,JobName,State,Elapsed,TimeLimit,NodeList
}

stop_session() {
    load_state
    if [ -n "$(session_state)" ]; then
        echo "[session] cancelling job $JOB_ID" >&2
        remote_run scancel "$JOB_ID"
    else
        echo "[session] job $JOB_ID is already inactive" >&2
    fi
    rm -f "$STATE_FILE"
    echo "[session] local lease cleared; remote files remain at $REMOTE_ROOT" >&2
}

main() {
    local command="${1:-}"
    case "$command" in
        -h|--help|'') usage; [ -n "$command" ] || exit 2; exit 0 ;;
        start|sync|exec|shell|status|stop) shift ;;
        *) die "unknown command: $command" ;;
    esac

    require_repo
    is_safe_name "$EC_SSH_HOST" || die "EC_SSH_HOST must be a simple SSH host alias"
    # shellcheck source=_preflight.sh
    . "$SCRIPT_DIR/_preflight.sh"

    case "$command" in
        start) start_session "$@" ;;
        sync) [ $# -eq 0 ] || die "sync takes no arguments"; load_state; ensure_active; sync_session ;;
        exec) exec_session "$@" ;;
        shell) [ $# -eq 0 ] || die "shell takes no arguments"; shell_session ;;
        status) [ $# -eq 0 ] || die "status takes no arguments"; status_session ;;
        stop) [ $# -eq 0 ] || die "stop takes no arguments"; stop_session ;;
    esac
}

main "$@"
