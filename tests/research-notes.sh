#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_RESOLVER="${REPO_ROOT}/skills/research-notes/scripts/resolve-shared-vault.py"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

fake_home="${TEST_ROOT}/home"
registry_vault="${TEST_ROOT}/vaults/Ergodic Research"
override_vault="${TEST_ROOT}/vaults/Override Research"
mkdir -p \
  "${fake_home}/Library/Application Support/obsidian" \
  "${registry_vault}/Notes" \
  "${override_vault}/Notes"
registry_vault="$(cd "$registry_vault" && pwd -P)"
override_vault="$(cd "$override_vault" && pwd -P)"
printf '{"vaults":{"shared":{"path":"%s"}}}\n' "$registry_vault" \
  >"${fake_home}/Library/Application Support/obsidian/obsidian.json"

resolved="$(env -u ERGODIC_RESEARCH_VAULT \
  HOME="$fake_home" \
  XDG_CONFIG_HOME="${fake_home}/.config" \
  APPDATA="${fake_home}/AppData" \
  "$VAULT_RESOLVER")"
[ "$resolved" = "$registry_vault" ] \
  || fail "registry resolved $resolved, expected $registry_vault"

resolved="$(env \
  ERGODIC_RESEARCH_VAULT="$override_vault" \
  HOME="$fake_home" \
  "$VAULT_RESOLVER")"
[ "$resolved" = "$override_vault" ] \
  || fail "environment override resolved $resolved, expected $override_vault"

if ERGODIC_RESEARCH_VAULT="${TEST_ROOT}/missing" \
  HOME="$fake_home" \
  "$VAULT_RESOLVER" >/dev/null 2>&1; then
  fail 'invalid environment override unexpectedly fell back to the registry'
fi

printf 'research notes tests passed\n'
