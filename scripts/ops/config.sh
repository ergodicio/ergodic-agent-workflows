# Sourced by all scripts/ops/*.sh helpers.
# Defaults are tuned for the ergodic-claude / Perlmutter / m4490 workflow.
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
: "${EC_ACCOUNT:=m4490}"
: "${EC_QOS:=interactive}"
: "${EC_CONSTRAINT:=gpu}"
: "${EC_TIME_LIMIT:=01:00:00}"   # interactive QOS caps at 1h
: "${EC_NODES:=1}"
