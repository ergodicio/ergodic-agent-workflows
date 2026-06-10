#!/usr/bin/env bash
# Allocate an interactive *shared* GPU slice on the cluster — a fraction of a
# node (1-2 GPUs) via the `shared_interactive` QOS, so you schedule quickly and are only
# charged for the slice you use. For a whole node use interactive-gpu-node.sh;
# for a single GPU on the interactive QOS use interactive-gpu.sh.
#
# Usage: interactive-shared.sh [gpus] [hours]
#   gpus:  number of GPUs, 1-2 (default 1). Each GPU is paired with 32 logical
#          CPUs (16 physical cores) and proportional memory.
#   hours: walltime hours (default 1; shared_interactive QOS allows up to 4). Matches the
#          [hours] convention of the other interactive-*.sh scripts.
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
# shellcheck source=_preflight.sh
. "$SCRIPT_DIR/_preflight.sh"

GPUS="${1:-1}"
HOURS="${2:-1}"
REPO="$(basename "$PWD")"

# 32 logical CPUs (= 16 physical cores) per A100 on a Perlmutter GPU node.
CPUS_PER_GPU=32

if ! [[ "$GPUS" =~ ^[1-2]$ ]]; then
  echo "[interactive-shared] gpus must be an integer in 1..2 (got: $GPUS)" >&2
  exit 2
fi

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
  --account ${EC_ACCOUNT}
squeue -u \$USER --name ${REPO}"
