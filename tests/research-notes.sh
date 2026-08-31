#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${REPO_ROOT}/skills/research-notes/scripts/enable-notes-merge.sh"
VAULT_RESOLVER="${REPO_ROOT}/skills/research-notes/scripts/resolve-shared-vault.py"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

git -C "$TEST_ROOT" init -q
git -C "$TEST_ROOT" config user.name 'Research Notes Test'
git -C "$TEST_ROOT" config user.email 'research-notes@example.invalid'
printf '# Existing attribute\n*.bin binary\n' >"${TEST_ROOT}/.gitattributes"
printf '# Notes\n' >"${TEST_ROOT}/NOTES.md"
mkdir -p "${TEST_ROOT}/sims/campaign"
printf '# Campaign notes\n' >"${TEST_ROOT}/sims/campaign/NOTES.md"

"$HELPER" "$TEST_ROOT" >/dev/null

[ "$(grep -Fxc 'NOTES.md merge=union' "${TEST_ROOT}/.gitattributes")" -eq 1 ] \
  || fail 'root NOTES.md rule was not added exactly once'
[ "$(grep -Fxc '**/NOTES.md merge=union' "${TEST_ROOT}/.gitattributes")" -eq 1 ] \
  || fail 'nested NOTES.md rule was not added exactly once'
grep -Fq '*.bin binary' "${TEST_ROOT}/.gitattributes" \
  || fail 'existing attributes were not preserved'

root_attr="$(git -C "$TEST_ROOT" check-attr merge -- NOTES.md | sed 's/^.*: //')"
nested_attr="$(git -C "$TEST_ROOT" check-attr merge -- sims/campaign/NOTES.md | sed 's/^.*: //')"
[ "$root_attr" = union ] || fail "root merge attribute is $root_attr, expected union"
[ "$nested_attr" = union ] || fail "nested merge attribute is $nested_attr, expected union"

"$HELPER" "$TEST_ROOT" >/dev/null
[ "$(grep -Fxc 'NOTES.md merge=union' "${TEST_ROOT}/.gitattributes")" -eq 1 ] \
  || fail 'root rule was duplicated on the second run'
[ "$(grep -Fxc '**/NOTES.md merge=union' "${TEST_ROOT}/.gitattributes")" -eq 1 ] \
  || fail 'nested rule was duplicated on the second run'

git -C "$TEST_ROOT" add .gitattributes NOTES.md sims/campaign/NOTES.md
git -C "$TEST_ROOT" commit -qm 'base notebook'
git -C "$TEST_ROOT" branch branch-a

printf '\n## 2026-08-27 10:00 PDT — main entry\n\nMain result.\n' \
  >>"${TEST_ROOT}/NOTES.md"
git -C "$TEST_ROOT" add NOTES.md
git -C "$TEST_ROOT" commit -qm 'append main entry'

git -C "$TEST_ROOT" switch -q branch-a
printf '\n## 2026-08-27 10:01 PDT — branch entry\n\nBranch result.\n' \
  >>"${TEST_ROOT}/NOTES.md"
git -C "$TEST_ROOT" add NOTES.md
git -C "$TEST_ROOT" commit -qm 'append branch entry'

git -C "$TEST_ROOT" switch -q master 2>/dev/null \
  || git -C "$TEST_ROOT" switch -q main
git -C "$TEST_ROOT" merge -q --no-edit branch-a
grep -Fq 'Main result.' "${TEST_ROOT}/NOTES.md" \
  || fail 'union merge lost the main entry'
grep -Fq 'Branch result.' "${TEST_ROOT}/NOTES.md" \
  || fail 'union merge lost the branch entry'

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
