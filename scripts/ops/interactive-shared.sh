#!/usr/bin/env bash
# Allocate an interactive *shared* GPU slice on the cluster — a fraction of a
# node (1-2 GPUs) via the `shared_interactive` QOS, so you schedule quickly and are only
# charged for the slice you use. For a whole node use interactive-gpu-node.sh;
# for a single GPU on the interactive QOS use interactive-gpu.sh.
#
# Usage: interactive-shared.sh [hours] [gpus]
#        interactive-shared.sh --hours <h> --gpus <n>
#   hours: walltime hours (default 1; shared_interactive QOS allows up to 4)
#   gpus:  number of GPUs, 1-2 (default 1). Each GPU is paired with 32 logical
#          CPUs (16 physical cores) and proportional memory.
#
# ARGUMENT ORDER CHANGED 2026-08-16: this took [gpus] [hours] before, alone among the
# interactive-*.sh scripts. Hours is now first everywhere. The script warns when a call
# is ambiguous between the two readings; use the long flags to be certain.
#
# Unlike the interactive-*.sh scripts, this requests a sub-node slice
# (--gpus + --cpus-per-task) rather than whole nodes, and the `shared_interactive` QOS is
# baked in — there's no EC_QOS / shell state to manage.
#
# Job name is the basename of $PWD so it's identifiable in squeue.
# Account / ssh host come from config.sh (overridable via env); constraint is
# forced to 'gpu'.
#
# This uses `salloc --no-shell`, so the allocation parks in the queue. Read its
# job id from the squeue output below, then run on it with:
#   ssh perlmutter "srun --jobid=<id> --overlap <cmd>"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$SCRIPT_DIR/config.sh"
# shellcheck source=_alloc_args.sh
. "$SCRIPT_DIR/_alloc_args.sh"

# Parse before the ssh preflight so --help and a typo'd argument answer instantly,
# without needing a live connection to the cluster.
_ec_tool=interactive-shared
_ec_size_name=gpus
_ec_size_desc="number of GPUs"
_ec_size_default=1
_ec_size_max=2
ec_parse_alloc_args "$@"

HOURS="$EC_HOURS"
GPUS="$EC_SIZE"

# Both readings are in range and differ, so the call means one thing under the old
# order and another under the new one, and nothing in the arguments distinguishes
# them. Say which one is being used rather than allocating the wrong slice quietly.
if [ "$EC_NPOS" -eq 2 ] && [ "$HOURS" -le 2 ] && [ "$HOURS" -ne "$GPUS" ]; then
  echo "[interactive-shared] NOTE: argument order is now [hours] [gpus], as in every other" >&2
  echo "[interactive-shared]       interactive-*.sh — it used to be [gpus] [hours] here." >&2
  echo "[interactive-shared]       Reading '$HOURS $GPUS' as ${HOURS}h / ${GPUS} GPU." >&2
  echo "[interactive-shared]       For the old meaning: --gpus ${HOURS} --hours ${GPUS}" >&2
fi

# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

ec_require_account

REPO="$(basename "$PWD")"

# 32 logical CPUs (= 16 physical cores) per A100 on a Perlmutter GPU node.
CPUS_PER_GPU=32
CPUS=$(( GPUS * CPUS_PER_GPU ))

echo "[interactive-shared] requesting ${GPUS} GPU(s) / ${CPUS} CPUs / ${HOURS}h on the shared_interactive QOS (job-name ${REPO})" >&2

ssh "$EC_SSH_HOST" "salloc --no-shell \
  --job-name ${REPO} \
  --nodes 1 \
  --gpus ${GPUS} \
  --cpus-per-task ${CPUS} \
  --qos shared_interactive \
  --constraint gpu \
  --time ${HOURS}:00:00 \
  --account ${EC_ACCOUNT_GPU}
squeue -u \$USER --name ${REPO}"
