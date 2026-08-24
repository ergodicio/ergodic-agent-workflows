#!/usr/bin/env bash
# bootstrap-nersc.sh — set up the Perlmutter side of the workflow.
#
# What this does (over ssh, as your NERSC user — runs on a login node):
#   1. Installs uv on Perlmutter if missing
#   2. Creates the directories the nersc-workflow skill expects:
#        <project-space>/$USER/venvs/      (per-project venvs)
#        <project-space>/$USER/uv-python/  (uv-managed Pythons)
#        <project-space>/$USER/.cache/uv/  (uv download cache — MUST be on the same
#                                           filesystem as venvs/ or uv copies instead
#                                           of hardlinking; see the env-file note below)
#        $PSCRATCH/                                 (working area for synced repos)
#   3. Writes <project-space>/$USER/ergodic-agent-workflows.sh with PATH, env vars,
#      and a cd-hook that points uv at the right per-project venv
#   4. Prepends a marked block sourcing <project-space>/$USER/ergodic-agent-workflows.sh to
#      ~/.bashrc, ~/.zshenv, and ~/.bash_profile — at the TOP, so it runs before any
#      "return unless interactive" guard those files commonly start with
#      (Perlmutter does not source the Cori-era ~/.bash_profile.ext / ~/.zshrc.ext files)
#   5. Creates ~/.mlflow_credentials (mode 600) with placeholders, if missing
#   6. Installs NERSC's required agent rules into the selected agent's guidance *on
#      Perlmutter*, so that agent gets the same rules when started on a login node
#
# Run from your laptop. Requires that `ssh perlmutter` works (sshproxy set up).
#
# Idempotent — safe to re-run. Marker lines make re-runs replace the managed block
# instead of duplicating it.
#
# IMPORTANT: this script only installs/refreshes a clearly-marked block at the top of
# .bashrc, .zshenv, and .bash_profile. Existing customizations in those files are untouched.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf "\n\033[1;36m[ergodic-agent-workflows]\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31m[ergodic-agent-workflows]\033[0m %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./scripts/bootstrap-nersc.sh [--agent claude|codex|both]

Set up Perlmutter for Claude Code, Codex, or both. The default is both.
EOF
}

AGENT="both"
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)
      [ $# -ge 2 ] || die "--agent needs claude, codex, or both"
      AGENT="$2"
      shift 2
      ;;
    --agent=*) AGENT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$AGENT" in
  claude) AGENT_LABEL="Claude Code" ;;
  codex)  AGENT_LABEL="Codex" ;;
  both)   AGENT_LABEL="Claude Code and Codex" ;;
  *) die "unknown agent: ${AGENT} (expected claude, codex, or both)" ;;
esac

say "Setting up agent selection: ${AGENT}"

ssh -o ConnectTimeout=10 perlmutter true 2>/dev/null \
  || die "Can't ssh to perlmutter. Run sshproxy first (or fix your ~/.ssh/config alias)."

# 0. Which project are we setting up? Everything downstream — the SLURM account jobs are
#    billed to and the global-common dir that holds the venvs — derives from this one value,
#    so it gets resolved once, here, from SLURM's own associations rather than a default.
. "${REPO_ROOT}/scripts/ops/config.sh"

if [ -n "$EC_ACCOUNT" ]; then
  say "Using project ${EC_ACCOUNT} (from ${EC_CONFIG_SOURCE:-env})"
  if [ "${EC_CONFIG_SOURCE:-}" != "$EC_CONFIG" ] && [ ! -f "$EC_CONFIG" ]; then
    mkdir -p "$(dirname "$EC_CONFIG")"
    cp "$EC_CONFIG_SOURCE" "$EC_CONFIG"
    say "Migrated account config to ${EC_CONFIG}"
  fi
else
  say "Looking up your NERSC projects…"
  # while-read, not `mapfile`: macOS still ships bash 3.2 as /bin/bash.
  PROJECTS=()
  while IFS= read -r _line; do
    [ -n "$_line" ] && PROJECTS+=("$_line")
  done < <("${REPO_ROOT}/scripts/ops/list-accounts.sh")
  [ "${#PROJECTS[@]}" -gt 0 ] \
    || die "No chargeable projects found for your NERSC user. Ask your PI to add you to one."

  if [ "${#PROJECTS[@]}" -eq 1 ]; then
    EC_ACCOUNT="${PROJECTS[0]}"
    say "One project found: ${EC_ACCOUNT}"
  elif [ -t 0 ]; then
    printf '\nYou belong to several projects. Which one should jobs be billed to?\n\n'
    for i in "${!PROJECTS[@]}"; do printf '  %d) %s\n' "$((i+1))" "${PROJECTS[$i]}"; done
    printf '\nNumber [1]: '
    read -r pick
    pick="${pick:-1}"
    case "$pick" in
      ''|*[!0-9]*) die "not a number: $pick" ;;
    esac
    [ "$pick" -ge 1 ] && [ "$pick" -le "${#PROJECTS[@]}" ] || die "out of range: $pick"
    EC_ACCOUNT="${PROJECTS[$((pick-1))]}"
  else
    die "You belong to several projects (${PROJECTS[*]}) and stdin isn't a terminal.
Re-run interactively, or pick one now:
  mkdir -p \"$(dirname "$EC_CONFIG")\" && echo ': \"\${EC_ACCOUNT:=${PROJECTS[0]}}\"' >> \"$EC_CONFIG\""
  fi

  # Persist it outside the repo so `git pull` can't change which project you bill.
  mkdir -p "$(dirname "$EC_CONFIG")"
  {
    printf '# ergodic-agent-workflows user config — written by bootstrap-nersc.sh, safe to edit.\n'
    printf '# `: "${VAR:=value}"` form means an exported EC_* in your shell still wins.\n'
    printf '# Your projects: ~/.ergodic-agent-workflows/ops/list-accounts.sh\n'
    printf ': "${EC_ACCOUNT:=%s}"\n' "$EC_ACCOUNT"
  } > "$EC_CONFIG"
  say "Wrote ${EC_CONFIG} (EC_ACCOUNT=${EC_ACCOUNT})"
fi

# Re-resolve so EC_ACCOUNT_GPU / EC_SOFTWARE_ROOT derive from the account just chosen.
EC_ACCOUNT_GPU=""; EC_SOFTWARE_ROOT=""
. "${REPO_ROOT}/scripts/ops/config.sh"
say "Project ${EC_ACCOUNT} · GPU account ${EC_ACCOUNT_GPU} · project space ${EC_SOFTWARE_ROOT}"

say "Setting up Perlmutter for \$USER (login node)…"

ssh perlmutter "EC_SOFTWARE_ROOT='${EC_SOFTWARE_ROOT}' bash -s" <<'REMOTE'
set -euo pipefail

PROJECT_ROOT="${EC_SOFTWARE_ROOT}/${USER}"
ENV_FILE="${PROJECT_ROOT}/ergodic-agent-workflows.sh"
LEGACY_ENV_FILE="${PROJECT_ROOT}/ergodic-claude.sh"
MARKER="# >>> ergodic-agent-workflows managed >>>"
END_MARKER="# <<< ergodic-agent-workflows managed <<<"
LEGACY_MARKER="# >>> ergodic-claude managed >>>"
LEGACY_END_MARKER="# <<< ergodic-claude managed <<<"

echo "[remote] PROJECT_ROOT=${PROJECT_ROOT}"

# 1. Directories (login node can write to global common)
# The uv cache goes next to the venvs, on global common — see the note in the env
# file below. Anything left in the old $PSCRATCH location is dead weight; scratch
# purges it on its own, so we don't delete it here.
mkdir -p "${PROJECT_ROOT}/venvs" "${PROJECT_ROOT}/uv-python" \
         "${PROJECT_ROOT}/.cache/uv" "${PSCRATCH}"
echo "[remote] directories ready"

# 2. uv (per-user install via curl; lands in ~/.local/bin/uv by default)
if ! command -v uv >/dev/null 2>&1 && ! [ -x "${HOME}/.local/bin/uv" ]; then
  echo "[remote] installing uv…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
else
  echo "[remote] uv already present"
fi

# 3. Write the canonical env file (overwrite — this is fully managed by us)
cat >"${ENV_FILE}" <<EOF
#!/usr/bin/env bash
# Managed by ergodic-agent-workflows/scripts/bootstrap-nersc.sh — re-run that to update.
# Sourced from the managed blocks at the top of ~/.bashrc, ~/.zshenv, and ~/.bash_profile.

# A login shell can hit this twice — once from ~/.bash_profile, once more if the
# user's profile chains to ~/.bashrc. Make the second source a no-op.
[ -n "\${_ERGODIC_AGENT_WORKFLOWS_ENV_SOURCED:-}" ] && return 0
_ERGODIC_AGENT_WORKFLOWS_ENV_SOURCED=1

# uv: binary on PATH, Pythons and cache in global common (persistent).
#
# The cache MUST sit on the same filesystem as the venvs in \$ERGODIC_VENVS. uv
# hardlinks package files out of the cache into a venv, so N venvs sharing a
# dependency cost one copy — but only within one filesystem. Point the cache at
# \$PSCRATCH (Lustre) or \$HOME (/global/u2) and uv silently falls back to a full
# copy, with no warning. For jax GPU venvs that is 4.5 GB of site-packages/nvidia
# duplicated per venv; measured 2026-08-16, one user's seven venvs cost 38 GB
# instead of 7.8 GB, against a 100 GB quota shared by the whole project.
export PATH="\${HOME}/.local/bin:\${PATH}"
export UV_PYTHON_INSTALL_DIR="${PROJECT_ROOT}/uv-python"
export UV_CACHE_DIR="${PROJECT_ROOT}/.cache/uv"

# Where per-project venvs live (read-only from compute nodes — only mutate from login node)
export ERGODIC_VENVS="${PROJECT_ROOT}/venvs"
# Compatibility for scripts and running jobs created before the repository rename.
export ECLAUDE_VENVS="\${ERGODIC_VENVS}"

# MLflow tracking server (non-secret)
export MLFLOW_TRACKING_URI="https://continuum.ergodic.io/experiments/"

# MLflow credentials live in a separate 600-perms file. Source if present.
[ -f "\${HOME}/.mlflow_credentials" ] && . "\${HOME}/.mlflow_credentials"

# cd-hook: point uv at the per-project venv keyed off the repo basename. Works in
# bash and zsh because both honor a 'cd' function override. The hook also runs at
# shell startup so the first prompt already has UV_PROJECT_ENVIRONMENT set.
_ergodic_agent_workflows_uv_hook() {
  local root name
  root="\$(git rev-parse --show-toplevel 2>/dev/null || echo "\$PWD")"
  name="\$(basename "\$root")"
  export UV_PROJECT_ENVIRONMENT="\${ERGODIC_VENVS}/\${name}"
}
cd() { builtin cd "\$@" && _ergodic_agent_workflows_uv_hook; }
_ergodic_agent_workflows_uv_hook
EOF
chmod 644 "${ENV_FILE}"
echo "[remote] wrote ${ENV_FILE}"

# Keep old jobs and shell snippets working while making the new file canonical.
cat >"${LEGACY_ENV_FILE}" <<EOF
#!/usr/bin/env bash
# Compatibility shim managed by ergodic-agent-workflows/scripts/bootstrap-nersc.sh.
. "${ENV_FILE}"
EOF
chmod 644 "${LEGACY_ENV_FILE}"
echo "[remote] wrote compatibility shim ${LEGACY_ENV_FILE}"

strip_managed_env_blocks() {
  awk -v m="$MARKER" -v e="$END_MARKER" \
      -v lm="$LEGACY_MARKER" -v le="$LEGACY_END_MARKER" '
    index($0,m) || index($0,lm) {in_block=1; next}
    (index($0,e) || index($0,le)) && in_block {in_block=0; next}
    !in_block {print}
  ' "$1"
}

# 4. Wire into ~/.bashrc, ~/.zshenv, and ~/.bash_profile. Perlmutter does NOT use
#    the Cori-era ~/.bash_profile.ext / ~/.zshrc.ext convention — nothing sources
#    those files — so the env must go into the real dotfiles. The block is
#    PREPENDED: stock ~/.bashrc files often open with a "return unless interactive"
#    guard (`case $- in *i*) ;; *) return;; esac`), and an appended block would sit
#    unreachable below it for exactly the non-interactive shells the workflow
#    scripts run (`ssh perlmutter …`, `bash -lc`). Sourcing from ~/.bash_profile
#    too covers login shells whose profile never chains to ~/.bashrc;
#    ergodic-agent-workflows.sh makes the second source in a chained profile a no-op.
#    For zsh the file is ~/.zshenv — the one zsh reads in EVERY mode (login,
#    interactive, non-interactive, scripts); ~/.zshrc is interactive-only and
#    would leave `ssh perlmutter cmd` blind for zsh users.
#    Marker lines let re-runs replace the block wherever an old run left it.
for f in "${HOME}/.bashrc" "${HOME}/.zshenv" "${HOME}/.bash_profile"; do
  touch "$f"
  if grep -qF "$MARKER" "$f" || grep -qF "$LEGACY_MARKER" "$f"; then
    # Strip the old managed block (pre-2026-08-18 runs appended it at the bottom,
    # or chained ~/.bash_profile -> ~/.bashrc here) before prepending fresh.
    strip_managed_env_blocks "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  fi
  {
    printf "%s\n" "$MARKER"
    printf "# Stays at the top of this file: must run before any 'return unless interactive' guard.\n"
    printf ". \"%s\"\n" "$ENV_FILE"
    printf "%s\n\n" "$END_MARKER"
    cat "$f"
  } > "$f.tmp" && mv "$f.tmp" "$f"
  echo "[remote] wired $f (managed block at top)"
done

# Drop the stale managed block older bootstraps left elsewhere: the Cori-era .ext
# files (nothing sources them on Perlmutter) and ~/.zshrc (superseded by ~/.zshenv,
# which zsh reads in every mode instead of only interactively).
for f in "${HOME}/.bash_profile.ext" "${HOME}/.zshrc.ext" "${HOME}/.zshrc"; do
  if [ -f "$f" ] && { grep -qF "$MARKER" "$f" || grep -qF "$LEGACY_MARKER" "$f"; }; then
    strip_managed_env_blocks "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "[remote] removed stale block from $f"
  fi
done

# 5. ~/.mlflow_credentials placeholder (only if missing — never clobber real creds)
CREDS_FILE="${HOME}/.mlflow_credentials"
if [ ! -f "${CREDS_FILE}" ]; then
  cat >"${CREDS_FILE}" <<'CREDS'
# Fill in your MLflow credentials for https://continuum.ergodic.io/experiments/
# This file is mode 600. Do NOT commit it anywhere.
export MLFLOW_TRACKING_USERNAME="your-username"
export MLFLOW_TRACKING_PASSWORD="your-token"
CREDS
  chmod 600 "${CREDS_FILE}"
  echo "[remote] created ${CREDS_FILE} (placeholder — edit it with your creds)"
else
  chmod 600 "${CREDS_FILE}"
  echo "[remote] ${CREDS_FILE} already exists (kept as-is, ensured mode 600)"
fi

# 6. Sanity
echo
echo "[remote] sanity check:"
echo "  venvs dir:        ${PROJECT_ROOT}/venvs       $([ -d "${PROJECT_ROOT}/venvs" ] && echo OK)"
echo "  scratch workdir:  ${PSCRATCH}         $([ -d "${PSCRATCH}" ] && echo OK)"
echo "  uv cache:         ${PROJECT_ROOT}/.cache/uv  $([ -d "${PROJECT_ROOT}/.cache/uv" ] && echo OK)"
echo "  env file:         ${ENV_FILE}                $([ -f "${ENV_FILE}" ] && echo OK)"
REMOTE

# 6. NERSC's agent rules, on the Perlmutter side too. Someone running an agent from a login
#    node needs the filesystem-traversal rules in that machine's agent guidance.
#    Ship the installer + rules over rather than re-implementing the merge remotely: the
#    rules text is full of `$VARS` and backticks that would not survive a heredoc.
#    Stage under $HOME, not /tmp: `ssh perlmutter` round-robins across login nodes and /tmp
#    is node-local, so a /tmp staging dir created by one connection is invisible to the next.
say "Installing NERSC agent rules on Perlmutter…"
REMOTE_TMP="$(ssh perlmutter 'mktemp -d "${HOME}/.ec-install-XXXXXX"')"
[ -n "$REMOTE_TMP" ] || die "couldn't create a staging dir on Perlmutter"
scp -q "${REPO_ROOT}/scripts/install-agent-rules.sh" "${REPO_ROOT}/rules/nersc-agent-rules.md" \
        "perlmutter:${REMOTE_TMP}/" \
  || die "couldn't copy the agent rules to Perlmutter (staging dir ${REMOTE_TMP})"
ssh perlmutter "bash '${REMOTE_TMP}/install-agent-rules.sh' --rules '${REMOTE_TMP}/nersc-agent-rules.md' --agent '${AGENT}'; rm -rf '${REMOTE_TMP}'"

say "Perlmutter bootstrap done."
say "Next steps:"
say "  1. ssh perlmutter, then \`vim ~/.mlflow_credentials\` and fill in your username/token."
say "  2. Open a fresh shell on Perlmutter to pick up the new env (or \`source ~/.bash_profile\`)."
say "  3. From inside a project repo on your laptop, ask ${AGENT_LABEL} to 'sync and launch on NERSC'."
say "  4. See examples/first-run/ for an end-to-end demo."
