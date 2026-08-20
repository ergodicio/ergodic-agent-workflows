# Shared argument parsing for the interactive-*.sh allocators.
# Sourced after config.sh and _preflight.sh.
#
# ONE CONVENTION: hours is always the first positional. The second positional is
# whatever that allocator sizes with — `nodes` for the whole-node scripts, `gpus`
# for the shared slice. That is the only thing you have to remember, and the long
# flags (--hours / --nodes / --gpus) mean you don't have to remember even that.
#
# interactive-shared.sh took [gpus] [hours] until 2026-08-16. It is the reason this
# file exists: four scripts, four hand-rolled `${1:-1}` blocks, and one of them
# quietly transposed. Parse in one place and they can't drift again.
#
# Usage from a caller:
#     _ec_tool=interactive-cpu
#     _ec_size_name=nodes
#     _ec_size_desc="number of nodes"
#     _ec_size_default=1
#     _ec_size_max=4
#     ec_parse_alloc_args "$@"
#     # now: $EC_HOURS, $EC_SIZE, and $EC_NPOS (how many positionals were given —
#     #      interactive-shared.sh uses it to spot a legacy [gpus] [hours] call)
#
# Set _ec_size_max to 0 to skip the range check (interactive-gpu.sh takes its
# default from $EC_NODES, which the user may legitimately have set past 4).

ec_alloc_usage() {
    _ec_size_range=""
    [ "${_ec_size_max}" -gt 0 ] && _ec_size_range=", max ${_ec_size_max}"
    {
        echo
        echo "Usage: ${_ec_tool}.sh [hours] [${_ec_size_name}]"
        echo "       ${_ec_tool}.sh --hours <h> --${_ec_size_name} <n>"
        echo
        printf '  %-7s walltime in hours (default 1; the interactive QOS allows up to 4)\n' "hours"
        printf '  %-7s %s (default %s%s)\n' \
            "${_ec_size_name}" "${_ec_size_desc}" "${_ec_size_default}" "${_ec_size_range}"
        echo
        echo "Hours is the first positional in every interactive-*.sh script. The long flags"
        echo "work in any order, if you'd rather not rely on that."
    } >&2
}

_ec_alloc_die() {
    echo "[${_ec_tool}] $1" >&2
    ec_alloc_usage
    exit 2
}

# Positive integer, no leading zeros, no sign — Slurm won't take anything else here
# and a silent 0 or "-1" is worse than a refusal.
_ec_is_count() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        0) return 1 ;;
        *) return 0 ;;
    esac
}

_ec_set_hours() {
    [ "$_ec_seen_hours" = 0 ] || _ec_alloc_die "hours given twice (as '$EC_HOURS' and '$1')"
    _ec_seen_hours=1
    EC_HOURS="$1"
}

_ec_set_size() {
    [ "$_ec_seen_size" = 0 ] || _ec_alloc_die "${_ec_size_name} given twice (as '$EC_SIZE' and '$1')"
    _ec_seen_size=1
    EC_SIZE="$1"
}

ec_parse_alloc_args() {
    EC_HOURS=1
    EC_SIZE="$_ec_size_default"
    EC_NPOS=0
    _ec_seen_hours=0
    _ec_seen_size=0

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                ec_alloc_usage
                exit 0
                ;;
            --hours)
                [ $# -ge 2 ] || _ec_alloc_die "--hours needs a value"
                _ec_set_hours "$2"
                shift 2
                ;;
            --hours=*)
                _ec_set_hours "${1#*=}"
                shift
                ;;
            "--${_ec_size_name}")
                [ $# -ge 2 ] || _ec_alloc_die "--${_ec_size_name} needs a value"
                _ec_set_size "$2"
                shift 2
                ;;
            "--${_ec_size_name}="*)
                _ec_set_size "${1#*=}"
                shift
                ;;
            -*)
                _ec_alloc_die "unknown option: $1"
                ;;
            *)
                EC_NPOS=$(( EC_NPOS + 1 ))
                case "$EC_NPOS" in
                    1) _ec_set_hours "$1" ;;
                    2) _ec_set_size "$1" ;;
                    *) _ec_alloc_die "too many arguments (got '$1')" ;;
                esac
                shift
                ;;
        esac
    done

    _ec_is_count "$EC_HOURS" \
        || _ec_alloc_die "hours must be a positive integer (got: '$EC_HOURS')"
    _ec_is_count "$EC_SIZE" \
        || _ec_alloc_die "${_ec_size_name} must be a positive integer (got: '$EC_SIZE')"

    if [ "$_ec_size_max" -gt 0 ] && [ "$EC_SIZE" -gt "$_ec_size_max" ]; then
        _ec_alloc_die "${_ec_size_name} must be in 1..${_ec_size_max} (got: $EC_SIZE)"
    fi

    # A warning, not an error: EC_QOS is overridable, so a longer walltime is a
    # legitimate thing to ask for on a non-interactive QOS. salloc has the last word.
    if [ "$EC_HOURS" -gt 4 ]; then
        echo "[${_ec_tool}] warning: ${EC_HOURS}h exceeds the 4 h interactive-QOS cap;" \
             "salloc will reject this unless EC_QOS is set to something that allows it" >&2
    fi
}
