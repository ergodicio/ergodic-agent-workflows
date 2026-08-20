#!/usr/bin/env bash
set -euo pipefail

repo_arg="${1:-.}"

if ! repo_root="$(git -C "$repo_arg" rev-parse --show-toplevel 2>/dev/null)"; then
  printf 'error: %s is not inside a Git worktree\n' "$repo_arg" >&2
  exit 1
fi

attributes="${repo_root}/.gitattributes"
root_rule='NOTES.md merge=union'
nested_rule='**/NOTES.md merge=union'

check_existing_driver() {
  local path="$1"
  local value

  value="$(git -C "$repo_root" check-attr merge -- "$path" | sed 's/^.*: //')"
  case "$value" in
    unspecified|union) ;;
    *)
      printf 'error: %s already uses merge driver %s; refusing to override it\n' \
        "$path" "$value" >&2
      exit 1
      ;;
  esac
}

check_existing_driver 'NOTES.md'
check_existing_driver '.research-notes-probe/NOTES.md'

missing_root=1
missing_nested=1
if [ -f "$attributes" ]; then
  grep -Fqx "$root_rule" "$attributes" && missing_root=0
  grep -Fqx "$nested_rule" "$attributes" && missing_nested=0
fi

if [ "$missing_root" -eq 0 ] && [ "$missing_nested" -eq 0 ]; then
  printf 'NOTES.md union merge is already configured in %s\n' "$attributes"
  exit 0
fi

if [ -s "$attributes" ]; then
  printf '\n' >>"$attributes"
fi
printf '%s\n' \
  '# Append-only research notebooks: preserve entries from concurrent branches.' \
  >>"$attributes"
[ "$missing_root" -eq 0 ] || printf '%s\n' "$root_rule" >>"$attributes"
[ "$missing_nested" -eq 0 ] || printf '%s\n' "$nested_rule" >>"$attributes"

check_effective_driver() {
  local path="$1"
  local value

  value="$(git -C "$repo_root" check-attr merge -- "$path" | sed 's/^.*: //')"
  if [ "$value" != union ]; then
    printf 'error: union merge is not effective for %s (got %s)\n' "$path" "$value" >&2
    exit 1
  fi
}

check_effective_driver 'NOTES.md'
check_effective_driver '.research-notes-probe/NOTES.md'
printf 'Configured append-only NOTES.md union merge in %s\n' "$attributes"
