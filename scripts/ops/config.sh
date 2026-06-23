# Sourced by all scripts/ops/*.sh helpers.
# Defaults are tuned for the ergodic-claude / Perlmutter / m4546 workflow.
# Override any of these in your shell env, or edit this file in place.
# Variables prefixed with a literal `\$` are expanded on the *remote* shell
# (e.g. \$PSCRATCH on the NERSC login node), not locally.

# ---- SSH transport ---------------------------------------------------------
# ssh alias for the NERSC login node (configured via sshproxy / ~/.ssh/config).
: "${EC_SSH_HOST:=perlmutter}"

# ---- Remote layout ---------------------------------------------------------
# Repo name — derived from the current working directory at call time.
# Scripts compute REPO inline; this is just a note.

# Remote base for this repo (evaluated on the remote shell — note the \$).
# Scripts construct this as "\$PSCRATCH/<repo>" using the cwd basename.

# ---- Scheduler -------------------------------------------------------------
: "${EC_ACCOUNT:=m4546}"
: "${EC_QOS:=interactive}"
: "${EC_CONSTRAINT:=gpu}"
: "${EC_TIME_LIMIT:=01:00:00}"   # interactive QOS caps at 1h
: "${EC_NODES:=1}"
# GPUs to bind per node. REQUIRED for the srun step to see the GPUs — without
# it, salloc reserves the (exclusive) nodes but the step gets CUDA_ERROR_NO_DEVICE
# even though AllocTRES shows gres/gpu=N. Perlmutter GPU nodes have 4 A100s.
: "${EC_GPUS_PER_NODE:=4}"
