# Sourced by all scripts/ops/*.sh helpers.
#
# Resolution order — first one to set a value wins:
#   1. EC_* exported in your shell    — one-off override for a single command
#   2. $EC_CONFIG                     — your persistent settings, outside the repo
#                                       (default: ~/.config/ergodic-claude/config.sh)
#   3. the defaults below             — team-wide, tracked in git
#
# There is deliberately NO default account. NERSC users commonly belong to several
# projects (`list-accounts.sh` shows yours), the SLURM account decides which
# allocation gets billed, and a stale default silently bills the wrong project —
# which is how this file ended up pointing at one project while the venv paths
# pointed at another. bootstrap-nersc.sh detects your projects and writes the user
# config; `show-config.sh` prints whatever resolved.
#
# Variables prefixed with a literal `\$` are expanded on the *remote* shell
# (e.g. \$PSCRATCH on the NERSC login node), not locally.

# ---- User config -----------------------------------------------------------
: "${EC_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/ergodic-claude/config.sh}"
if [ -f "$EC_CONFIG" ]; then
    # The generated file uses `: "${EC_X:=…}"` too, so anything already exported
    # in the environment still takes precedence over it.
    # shellcheck source=/dev/null
    . "$EC_CONFIG"
fi

# ---- SSH transport ---------------------------------------------------------
# ssh alias for the NERSC login node (configured via sshproxy / ~/.ssh/config).
: "${EC_SSH_HOST:=perlmutter}"

# ---- Remote layout ---------------------------------------------------------
# Repo name — derived from the current working directory at call time.
# Scripts compute REPO inline; this is just a note.

# Remote base for this repo (evaluated on the remote shell — note the \$).
# Scripts construct this as "\$PSCRATCH/<repo>" using the cwd basename.

# ---- Project / account -----------------------------------------------------
# Your NERSC project, bare (e.g. m4490). Required — see the note at the top.
: "${EC_ACCOUNT:=}"

# GPU jobs bill the `_g` half of the project (NERSC's convention); CPU jobs use
# the bare name. Derived unless you set it explicitly.
: "${EC_ACCOUNT_GPU:=}"
if [ -n "$EC_ACCOUNT" ] && [ -z "$EC_ACCOUNT_GPU" ]; then
    EC_ACCOUNT_GPU="${EC_ACCOUNT%_g}_g"
fi

# Project space on global common: venvs, uv-managed Pythons, ergodic-claude.sh.
# Read-only on compute nodes — mutate it from a login node only. The directory is
# named after the bare project, never the `_g` account.
: "${EC_SOFTWARE_ROOT:=}"
if [ -n "$EC_ACCOUNT" ] && [ -z "$EC_SOFTWARE_ROOT" ]; then
    EC_SOFTWARE_ROOT="/global/common/software/${EC_ACCOUNT%_g}"
fi

# ---- Scheduler -------------------------------------------------------------
: "${EC_QOS:=interactive}"
: "${EC_CONSTRAINT:=gpu}"
# Documented default only — the interactive-*.sh helpers take hours as their first argument
# and don't read this. gpu_interactive actually allows 4 h (measured 2026-08-11); check with
# `sacctmgr -nP show qos gpu_interactive format=MaxWall,MaxTRESPerJob,MaxSubmitJobsPU`.
: "${EC_TIME_LIMIT:=01:00:00}"
: "${EC_NODES:=1}"
# GPUs to bind per node. REQUIRED for the srun step to see the GPUs — without
# it, salloc reserves the (exclusive) nodes but the step gets CUDA_ERROR_NO_DEVICE
# even though AllocTRES shows gres/gpu=N. Perlmutter GPU nodes have 4 A100s.
: "${EC_GPUS_PER_NODE:=4}"

# ---- Guard -----------------------------------------------------------------
# Call from any script that submits work, before building the salloc/sbatch line.
# Nothing should ever guess an account: an unset one is a stop, not a default.
ec_require_account() {
    [ -n "${EC_ACCOUNT:-}" ] && return 0
    cat >&2 <<EOF

[ergodic-claude] No NERSC account configured — refusing to guess which project to bill.

Your projects:   ~/.claude/scripts/ergodic/list-accounts.sh
Set one:         mkdir -p "$(dirname "$EC_CONFIG")"
                 echo ': "\${EC_ACCOUNT:=m4490}"' >> "$EC_CONFIG"
Or per command:  EC_ACCOUNT=m4490 $0 ...
Or re-run:       ./scripts/bootstrap-nersc.sh   (detects and writes it for you)

Config file: $EC_CONFIG
EOF
    exit 1
}
