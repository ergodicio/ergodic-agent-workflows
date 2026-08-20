#!/usr/bin/env bash
# install-agent-rules.sh — install NERSC's agent rules into agent guidance files.
#
# NERSC asks every user running a coding agent to put its filesystem-discovery rules into
# their agent config file (https://docs.nersc.gov/development/coding-agents/). This script
# does that: it copies the block out of rules/nersc-agent-rules.md into
# ~/.claude/CLAUDE.md and/or ~/.codex/AGENTS.md, delimited by managed markers.
#
# Idempotent. Re-running refreshes the block in place. Nothing outside the markers is
# touched, and the file is backed up to <target>.bak before any modification.
#
#   ./scripts/install-agent-rules.sh                       # install into both agents' global guidance
#   ./scripts/install-agent-rules.sh --agent codex         # install into ~/.codex/AGENTS.md
#   ./scripts/install-agent-rules.sh --agent claude        # install into ~/.claude/CLAUDE.md
#   ./scripts/install-agent-rules.sh --target path/to.md   # somewhere else
#   ./scripts/install-agent-rules.sh --rules path/to.md    # alternate source (used remotely)
#   ./scripts/install-agent-rules.sh --remove --agent codex # remove the managed block
#   ./scripts/install-agent-rules.sh --print               # print the block, install nothing
#
# Run on your laptop by bootstrap-local.sh, and on Perlmutter by bootstrap-nersc.sh (which
# scp's this script + the rules file over, so an agent started on a login node gets the
# same rules).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES="${REPO_ROOT}/rules/nersc-agent-rules.md"
TARGET=""
AGENT="both"
PRINT_ONLY=0
REMOVE=0

MARKER="<!-- >>> ergodic-claude nersc-agent-rules >>> -->"
END_MARKER="<!-- <<< ergodic-claude nersc-agent-rules <<< -->"

say() { printf "\n\033[1;36m[ergodic-claude]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[ergodic-claude]\033[0m %s\n" "$*"; }
die() { printf "\n\033[1;31m[ergodic-claude]\033[0m %s\n" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rules)  RULES="${2:?--rules needs a path}"; shift 2 ;;
    --target) TARGET="${2:?--target needs a path}"; shift 2 ;;
    --agent)
      AGENT="${2:?--agent needs claude, codex, or both}"
      case "$AGENT" in claude|codex|both) ;; *) die "unknown agent: $AGENT" ;; esac
      shift 2
      ;;
    --remove) REMOVE=1; shift ;;
    --print)  PRINT_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$REMOVE" -eq 1 ] || [ -f "$RULES" ] || die "rules file not found: $RULES"
[ "$REMOVE" -eq 0 ] || [ "$PRINT_ONLY" -eq 0 ] || die "--remove and --print cannot be used together"

if [ -n "$TARGET" ]; then
  TARGETS=("$TARGET")
else
  case "$AGENT" in
    claude) TARGETS=("${HOME}/.claude/CLAUDE.md") ;;
    codex)  TARGETS=("${HOME}/.codex/AGENTS.md") ;;
    both)   TARGETS=("${HOME}/.claude/CLAUDE.md" "${HOME}/.codex/AGENTS.md") ;;
  esac
fi

TMPDIR_EC="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_EC"' EXIT

if [ "$REMOVE" -eq 1 ]; then
  for TARGET in "${TARGETS[@]}"; do
    if [ ! -f "$TARGET" ]; then
      say "No agent guidance file to clean at ${TARGET}"
      continue
    fi

    if ! grep -qF "$MARKER" "$TARGET"; then
      say "No managed NERSC agent rules in ${TARGET}"
      continue
    fi
    grep -qF "$END_MARKER" "$TARGET" \
      || die "$TARGET has the opening marker but not the closing one. Fix it by hand (restore or delete the block), then re-run."

    cp "$TARGET" "${TARGET}.bak"
    awk -v m="$MARKER" -v e="$END_MARKER" '
      index($0,m) {in_block=1; next}
      index($0,e) && in_block {in_block=0; next}
      !in_block {print}
    ' "$TARGET" > "${TMPDIR_EC}/without-managed-block.md"
    mv "${TMPDIR_EC}/without-managed-block.md" "$TARGET"
    say "Removed managed NERSC agent rules from ${TARGET} (previous copy: ${TARGET}.bak)"
  done
  exit 0
fi

BLOCK="${TMPDIR_EC}/block.md"

# Everything between the BLOCK START / BLOCK END comments in the rules file is what gets
# installed; the prose above it is for humans reading the repo.
{
  printf '%s\n' "$MARKER"
  printf '%s\n' "<!-- Managed by ergodic-claude/scripts/install-agent-rules.sh — re-run to refresh. -->"
  printf '%s\n' "<!-- Source: rules/nersc-agent-rules.md · https://docs.nersc.gov/development/coding-agents/ -->"
  awk '/<!-- BLOCK START/ {grab=1; next} /<!-- BLOCK END/ {grab=0; next} grab' "$RULES"
  printf '%s\n' "$END_MARKER"
} > "$BLOCK"

# 5 lines = markers + comments and no actual rules: the delimiters moved or vanished.
[ "$(wc -l <"$BLOCK")" -gt 5 ] || die "no rules found between the BLOCK START/END markers in $RULES"

if [ "$PRINT_ONLY" -eq 1 ]; then
  cat "$BLOCK"
  exit 0
fi

for TARGET in "${TARGETS[@]}"; do
  mkdir -p "$(dirname "$TARGET")"
  [ -f "$TARGET" ] || : > "$TARGET"

  if grep -qF "$MARKER" "$TARGET"; then
    grep -qF "$END_MARKER" "$TARGET" \
      || die "$TARGET has the opening marker but not the closing one. Fix it by hand (restore or delete the block), then re-run."

  # Already current? Leave the file completely alone.
  awk -v m="$MARKER" -v e="$END_MARKER" '
    index($0,m) {grab=1} grab {print} index($0,e) && grab {exit}
  ' "$TARGET" > "${TMPDIR_EC}/current.md"
    if cmp -s "${TMPDIR_EC}/current.md" "$BLOCK"; then
      say "NERSC agent rules already current in ${TARGET}"
      continue
    fi

    cp "$TARGET" "${TARGET}.bak"
    awk -v m="$MARKER" 'index($0,m) {exit} {print}'          "$TARGET" > "${TMPDIR_EC}/head.md"
    awk -v e="$END_MARKER" 'tail {print} index($0,e) {tail=1}' "$TARGET" > "${TMPDIR_EC}/tail.md"
    cat "${TMPDIR_EC}/head.md" "$BLOCK" "${TMPDIR_EC}/tail.md" > "${TMPDIR_EC}/new.md"
    mv "${TMPDIR_EC}/new.md" "$TARGET"
    say "Refreshed NERSC agent rules in ${TARGET} (previous copy: ${TARGET}.bak)"
  else
    if [ -s "$TARGET" ]; then
      cp "$TARGET" "${TARGET}.bak"
      # Command substitution strips a trailing newline, so a non-empty result means the file
      # doesn't end in one — add it so the appended block starts on its own line.
      [ -n "$(tail -c1 "$TARGET")" ] && printf '\n' >> "$TARGET"
      printf '\n' >> "$TARGET"
      cat "$BLOCK" >> "$TARGET"
      say "Appended NERSC agent rules to ${TARGET} (previous copy: ${TARGET}.bak)"
    else
      cat "$BLOCK" > "$TARGET"
      say "Wrote NERSC agent rules to ${TARGET}"
    fi
  fi
done
