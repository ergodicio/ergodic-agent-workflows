#!/usr/bin/env bash
# bootstrap-nersc.sh — set up the Perlmutter side of the workflow.
#
# What this does (over ssh, as your NERSC user — runs on a login node):
#   1. Installs uv on Perlmutter if missing
#   2. Creates the directories the nersc-workflow skill expects:
#        /global/common/software/m4490/$USER/venvs/      (per-project venvs)
#        /global/common/software/m4490/$USER/uv-python/  (uv-managed Pythons)
#        $PSCRATCH/$USER/                                 (working area for synced repos)
#        $PSCRATCH/$USER/uv-cache/                        (uv download cache, on fast scratch)
#   3. Writes /global/common/software/m4490/$USER/ergodic-claude.sh with PATH, env vars,
#      and a cd-hook that points uv at the right per-project venv
#   4. Adds a single `. /global/common/software/m4490/$USER/ergodic-claude.sh` line to
#      ~/.bash_profile.ext and ~/.zshrc.ext (NERSC's documented user-customization files)
#   5. Creates ~/.mlflow_credentials (mode 600) with placeholders, if missing
#
# Run from your laptop. Requires that `ssh perlmutter` works (sshproxy set up).
#
# Idempotent — safe to re-run. Uses a marker line in the .ext files to avoid duplicate appends.
#
# IMPORTANT: this script touches only NERSC's documented .ext files. It does NOT modify
# .bashrc, .zshrc, or .bash_profile directly. If you already have customizations there,
# they're untouched.

set -euo pipefail

say() { printf "\n\033[1;36m[ergodic-claude]\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31m[ergodic-claude]\033[0m %s\n" "$*" >&2; exit 1; }

ssh -o ConnectTimeout=10 perlmutter true 2>/dev/null \
  || die "Can't ssh to perlmutter. Run sshproxy first (or fix your ~/.ssh/config alias)."

say "Setting up Perlmutter for \$USER (login node)…"

ssh perlmutter bash -s <<'REMOTE'
set -euo pipefail

PROJECT_ROOT="/global/common/software/m4490/${USER}"
ENV_FILE="${PROJECT_ROOT}/ergodic-claude.sh"
MARKER="# >>> ergodic-claude managed >>>"
END_MARKER="# <<< ergodic-claude managed <<<"

echo "[remote] PROJECT_ROOT=${PROJECT_ROOT}"

# 1. Directories (login node can write to global common)
mkdir -p "${PROJECT_ROOT}/venvs" "${PROJECT_ROOT}/uv-python" \
         "${PSCRATCH}/${USER}" "${PSCRATCH}/${USER}/uv-cache"
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
# Sourced from ~/.bash_profile.ext and ~/.zshrc.ext.

# uv: binary on PATH, Pythons in global common (persistent), cache on PSCRATCH (fast, OK to be purged)
export PATH="\${HOME}/.local/bin:\${PATH}"
export UV_PYTHON_INSTALL_DIR="${PROJECT_ROOT}/uv-python"
export UV_CACHE_DIR="\${PSCRATCH}/\${USER}/uv-cache"

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

# 4. Wire into .bash_profile.ext and .zshrc.ext (NERSC's customization files).
#    Use a marker line so re-runs don't duplicate.
for f in "${HOME}/.bash_profile.ext" "${HOME}/.zshrc.ext"; do
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
echo "  scratch workdir:  ${PSCRATCH}/${USER}         $([ -d "${PSCRATCH}/${USER}" ] && echo OK)"
echo "  uv cache:         ${PSCRATCH}/${USER}/uv-cache  $([ -d "${PSCRATCH}/${USER}/uv-cache" ] && echo OK)"
echo "  env file:         ${ENV_FILE}                $([ -f "${ENV_FILE}" ] && echo OK)"
REMOTE

say "Perlmutter bootstrap done."
say "Next steps:"
say "  1. ssh perlmutter, then \`vim ~/.mlflow_credentials\` and fill in your username/token."
say "  2. Open a fresh shell on Perlmutter to pick up the new env (or \`source ~/.bash_profile\`)."
say "  3. From inside a project repo on your laptop, ask Claude to 'sync and launch on NERSC'."
say "  4. See examples/first-run/ for an end-to-end demo."
