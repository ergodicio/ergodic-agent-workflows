#!/usr/bin/env bash
# launch-pinned.sh — commit-pinned, ISOLATED NERSC runs.
#
# Checks out a specific git SHA into a per-SHA directory on Perlmutter (via a
# per-repo read-only deploy key + a bare mirror + git worktree), then submits
# sbatch job(s) that import the code from THAT tree (PYTHONPATH) using the
# shared deps venv. There is no shared mutable working dir, so concurrent
# branches/campaigns can never clobber each other, and every run is pinned to
# an immutable commit.
#
# Prereq (one-time): a read-only deploy key at ~/.ssh/<repo>-deploy on Perlmutter,
# with its public half added as a deploy key on the GitHub repo.
#
# Usage: launch-pinned.sh [options] <cfg1> [cfg2 ...]
#   <cfgN>            config path relative to repo root, WITHOUT .yaml
#   --sha <sha>       commit to deploy (default: local HEAD; must be pushed)
#   --nodes <N>       nodes per job (default 1)
#   --time <HH:MM:SS> walltime (default 04:00:00)
#   --qos <qos>       SLURM QOS (default regular)
#   --account <acct>  SLURM account (default: $EC_ACCOUNT_GPU from config.sh)
#   --gpus <N>        GPUs per node (default 4)
#   --multinode       set PIC2D_MULTINODE=1 + one task PER GPU (jax.distributed)
#   --dry-run         print the generated sbatch, do not submit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"

# Account and project space both come from config.sh so they can't disagree — this
# script used to default to one project's `_g` account while pointing PYTHONPATH and
# the venv at a different project's global-common dir.
NODES=1; WALLTIME="04:00:00"; QOS="regular"; ACCOUNT=""
GPUS=4; MULTINODE=0; DRYRUN=0; SHA=""
CONFIGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) SHA="$2"; shift 2;;
    --nodes) NODES="$2"; shift 2;;
    --time) WALLTIME="$2"; shift 2;;
    --qos) QOS="$2"; shift 2;;
    --account) ACCOUNT="$2"; shift 2;;
    --gpus) GPUS="$2"; shift 2;;
    --multinode) MULTINODE=1; shift;;
    --dry-run) DRYRUN=1; shift;;
    -h|--help) grep '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) echo "unknown option: $1" >&2; exit 1;;
    *) CONFIGS+=("$1"); shift;;
  esac
done
[ ${#CONFIGS[@]} -ge 1 ] || { echo "error: need at least one config" >&2; exit 1; }

if [ -z "$ACCOUNT" ]; then
  ec_require_account
  ACCOUNT="$EC_ACCOUNT_GPU"
fi
SOFTWARE_ROOT="$EC_SOFTWARE_ROOT"
if [ -z "$SOFTWARE_ROOT" ]; then
  echo "error: EC_SOFTWARE_ROOT is unset — set EC_ACCOUNT (see show-config.sh)" >&2
  exit 1
fi

REPO="$(basename "$(git rev-parse --show-toplevel)")"
REMOTE_URL="$(git remote get-url origin)"
# normalize https -> ssh (deploy key is an ssh key)
case "$REMOTE_URL" in
  https://github.com/*) REMOTE_URL="git@github.com:${REMOTE_URL#https://github.com/}";;
esac
[ -n "$SHA" ] || SHA="$(git rev-parse HEAD)"
SHA="$(git rev-parse "$SHA")"   # expand to full 40-char
SHORT="${SHA:0:12}"

if ! git branch -r --contains "$SHA" >/dev/null 2>&1 || [ -z "$(git branch -r --contains "$SHA" 2>/dev/null)" ]; then
  echo "warning: $SHORT does not appear to be pushed to any origin branch; deploy will fail if the mirror can't fetch it." >&2
fi

NTPN=1; [ "$MULTINODE" = 1 ] && NTPN=$GPUS
echo "repo=$REPO sha=$SHORT nodes=$NODES gpus/node=$GPUS ntasks/node=$NTPN qos=$QOS time=$WALLTIME account=$ACCOUNT multinode=$MULTINODE dry-run=$DRYRUN"
echo "configs (${#CONFIGS[@]}): ${CONFIGS[*]}"

{
  # --- params preamble (expanded LOCALLY, baked into the remote script) ---
  cat <<PARAMS
REPO='$REPO'
REMOTE_URL='$REMOTE_URL'
SHA='$SHA'
SHORT='$SHORT'
NODES='$NODES'
WALLTIME='$WALLTIME'
QOS='$QOS'
ACCOUNT='$ACCOUNT'
SOFTWARE_ROOT='$SOFTWARE_ROOT'
GPUS='$GPUS'
NTPN='$NTPN'
MULTINODE='$MULTINODE'
DRYRUN='$DRYRUN'
CONFIGS='${CONFIGS[*]}'
PARAMS
  # --- body (quoted heredoc: NOTHING expands locally; runs on Perlmutter) ---
  cat <<'BODY'
set -euo pipefail
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/${REPO}-deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
MIRROR="$SCRATCH/${REPO}-mirror.git"
RUNDIR="$SCRATCH/${REPO}-runs/${SHA}"
VENV="${SOFTWARE_ROOT}/$USER/venvs/${REPO}"
ECSH="${SOFTWARE_ROOT}/$USER/ergodic-claude.sh"

# 1. bare mirror (clone once, then fetch to update)
if [ ! -d "$MIRROR" ]; then
  echo "[deploy] cloning bare mirror -> $MIRROR"
  git clone --quiet --bare "$REMOTE_URL" "$MIRROR"
fi
git -C "$MIRROR" fetch --quiet --prune origin '+refs/heads/*:refs/heads/*' || \
  git -C "$MIRROR" fetch --quiet --prune || true

# 2. isolated worktree checkout of the SHA (idempotent)
if [ ! -e "$RUNDIR/run.py" ]; then
  rm -rf "$RUNDIR"; mkdir -p "$(dirname "$RUNDIR")"
  git -C "$MIRROR" worktree prune
  git -C "$MIRROR" worktree add --quiet --detach "$RUNDIR" "$SHA"
fi
GOT="$(git -C "$RUNDIR" rev-parse HEAD)"
[ "$GOT" = "$SHA" ] || { echo "ERROR: checked-out $GOT != requested $SHA" >&2; exit 1; }
echo "[deploy] RUNDIR=$RUNDIR @ $(git -C "$RUNDIR" rev-parse --short HEAD)"
mkdir -p "$RUNDIR/logs"
[ -d "$VENV" ] || { echo "ERROR: shared venv missing: $VENV" >&2; exit 1; }

if [ "$MULTINODE" = 1 ]; then
  MN_EXPORT='export PIC2D_MULTINODE=1'
  MN_SRUN="--ntasks-per-node=$GPUS --gpus-per-node=$GPUS"
else
  MN_EXPORT='# single-node: jax sees all local GPUs in one process'
  MN_SRUN=""
fi

# 3. one sbatch per config, submitted from the isolated RUNDIR
for CFG in $CONFIGS; do
  JOB="$(basename "$CFG")"
  SB="$RUNDIR/logs/${JOB}.sbatch"
  cat > "$SB" <<SBATCH
#!/bin/bash
#SBATCH --nodes=${NODES}
#SBATCH --qos=${QOS}
#SBATCH --constraint=gpu
#SBATCH --gpus-per-node=${GPUS}
#SBATCH --ntasks-per-node=${NTPN}
#SBATCH --account=${ACCOUNT}
#SBATCH --time=${WALLTIME}
#SBATCH --job-name=${JOB}
#SBATCH --output=${RUNDIR}/logs/${JOB}-%j.out

source "${ECSH}"
source "${VENV}/bin/activate"
export PYTHONPATH="${RUNDIR}"
${MN_EXPORT}
cd "${RUNDIR}"
srun ${MN_SRUN} python -u run.py --cfg "${CFG}"
SBATCH
  if [ "$DRYRUN" = 1 ]; then
    echo "===== [dry-run] $SB ====="; cat "$SB"; echo "====="
  else
    (cd "$RUNDIR" && sbatch "$SB")
  fi
done
BODY
} | ssh perlmutter "bash -s"
