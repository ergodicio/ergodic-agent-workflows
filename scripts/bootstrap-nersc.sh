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
#   3. Writes <project-space>/$USER/ergodic-claude.sh with PATH, env vars,
#      and a cd-hook that points uv at the right per-project venv
#   4. Adds a single `. <project-space>/$USER/ergodic-claude.sh` line to
#      ~/.bashrc and ~/.zshrc, and chains ~/.bash_profile -> ~/.bashrc if needed
#      (Perlmutter does not source the Cori-era ~/.bash_profile.ext / ~/.zshrc.ext files)
#   5. Creates ~/.mlflow_credentials (mode 600) with placeholders, if missing
#   6. Installs NERSC's required agent rules into ~/.claude/CLAUDE.md *on Perlmutter*, so an
#      agent started on a login node gets the same filesystem-traversal rules
#
# Run from your laptop. Requires that `ssh perlmutter` works (sshproxy set up).
#
# Idempotent — safe to re-run. Uses a marker line in the .ext files to avoid duplicate appends.
#
# IMPORTANT: this script only appends/refreshes a clearly-marked block in .bashrc,
# .zshrc, and (if it doesn't already source .bashrc) .bash_profile. Existing
# customizations in those files are untouched.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf "\n\033[1;36m[ergodic-claude]\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31m[ergodic-claude]\033[0m %s\n" "$*" >&2; exit 1; }

ssh -o ConnectTimeout=10 perlmutter true 2>/dev/null \
  || die "Can't ssh to perlmutter. Run sshproxy first (or fix your ~/.ssh/config alias)."

# 0. Which project are we setting up? Everything downstream — the SLURM account jobs are
#    billed to and the global-common dir that holds the venvs — derives from this one value,
#    so it gets resolved once, here, from SLURM's own associations rather than a default.
. "${REPO_ROOT}/scripts/ops/config.sh"

if [ -n "$EC_ACCOUNT" ]; then
  say "Using project ${EC_ACCOUNT} (from ${EC_CONFIG:-env})"
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
    printf '# ergodic-claude user config — written by bootstrap-nersc.sh, safe to edit.\n'
    printf '# `: "${VAR:=value}"` form means an exported EC_* in your shell still wins.\n'
    printf '# Your projects: ~/.claude/scripts/ergodic/list-accounts.sh\n'
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
ENV_FILE="${PROJECT_ROOT}/ergodic-claude.sh"
MARKER="# >>> ergodic-claude managed >>>"
END_MARKER="# <<< ergodic-claude managed <<<"

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
# Managed by ergodic-claude/scripts/bootstrap-nersc.sh — re-run that to update.
# Sourced from ~/.bashrc and ~/.zshrc.

# uv: binary on PATH, Pythons and cache in global common (persistent).
#
# The cache MUST sit on the same filesystem as the venvs in \$ECLAUDE_VENVS. uv
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
export ECLAUDE_VENVS="${PROJECT_ROOT}/venvs"

# MLflow tracking server (non-secret)
export MLFLOW_TRACKING_URI="https://continuum.ergodic.io/experiments/"

# MLflow credentials live in a separate 600-perms file. Source if present.
[ -f "\${HOME}/.mlflow_credentials" ] && . "\${HOME}/.mlflow_credentials"

# cd-hook: point uv at the per-project venv keyed off the repo basename. Works in
# bash and zsh because both honor a 'cd' function override. The hook also runs at
# shell startup so the first prompt already has UV_PROJECT_ENVIRONMENT set.
_eclaude_uv_hook() {
  local root name
  root="\$(git rev-parse --show-toplevel 2>/dev/null || echo "\$PWD")"
  name="\$(basename "\$root")"
  export UV_PROJECT_ENVIRONMENT="\${ECLAUDE_VENVS}/\${name}"
}
cd() { builtin cd "\$@" && _eclaude_uv_hook; }
_eclaude_uv_hook
EOF
chmod 644 "${ENV_FILE}"
echo "[remote] wrote ${ENV_FILE}"

# 4. Wire into ~/.bashrc and ~/.zshrc. Perlmutter does NOT use the Cori-era
#    ~/.bash_profile.ext / ~/.zshrc.ext convention — nothing sources those files —
#    so the env must go into the real dotfiles. bash also reads ~/.bashrc for
#    non-interactive ssh commands, which is what the workflow scripts run.
#    Use a marker line so re-runs don't duplicate.
for f in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  touch "$f"
  if grep -qF "$MARKER" "$f"; then
    # Already wired; refresh the block between markers
    awk -v m="$MARKER" -v e="$END_MARKER" -v src=". \"${ENV_FILE}\"" '
      $0 ~ m       {print; print src; in_block=1; next}
      $0 ~ e       {print; in_block=0; next}
      !in_block    {print}
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    {
      printf "\n%s\n" "$MARKER"
      printf ". \"%s\"\n" "$ENV_FILE"
      printf "%s\n" "$END_MARKER"
    } >> "$f"
  fi
  echo "[remote] wired $f"
done

# Login shells read ~/.bash_profile, not ~/.bashrc — chain them if the profile
# doesn't already do so. Skip entirely if it mentions .bashrc anywhere.
PROFILE="${HOME}/.bash_profile"
touch "$PROFILE"
if ! grep -q '\.bashrc' "$PROFILE"; then
  {
    printf "\n%s\n" "$MARKER"
    printf '[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"\n'
    printf "%s\n" "$END_MARKER"
  } >> "$PROFILE"
  echo "[remote] wired $PROFILE -> ~/.bashrc"
fi

# Drop the stale managed block a pre-2026-08-17 bootstrap left in the .ext files
# (nothing sources them on Perlmutter, but dead wiring invites confusion).
for f in "${HOME}/.bash_profile.ext" "${HOME}/.zshrc.ext"; do
  if [ -f "$f" ] && grep -qF "$MARKER" "$f"; then
    awk -v m="$MARKER" -v e="$END_MARKER" '
      $0 ~ m   {in_block=1; next}
      $0 ~ e   {in_block=0; next}
      !in_block {print}
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
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
#    node needs the filesystem-traversal rules there, in that machine's ~/.claude/CLAUDE.md.
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
ssh perlmutter "bash '${REMOTE_TMP}/install-agent-rules.sh' --rules '${REMOTE_TMP}/nersc-agent-rules.md'; rm -rf '${REMOTE_TMP}'"

say "Perlmutter bootstrap done."
say "Next steps:"
say "  1. ssh perlmutter, then \`vim ~/.mlflow_credentials\` and fill in your username/token."
say "  2. Open a fresh shell on Perlmutter to pick up the new env (or \`source ~/.bash_profile\`)."
say "  3. From inside a project repo on your laptop, ask Claude to 'sync and launch on NERSC'."
say "  4. See examples/first-run/ for an end-to-end demo."
