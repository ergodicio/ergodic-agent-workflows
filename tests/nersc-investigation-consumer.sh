#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST_REQUESTS="${REPO_ROOT}/skills/nersc-investigation-consumer/scripts/list-requests.py"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

VAULT="${TEST_ROOT}/Ergodic Research"
mkdir -p "${VAULT}/Notes/tsadar" "${VAULT}/Notes/adept"

cat >"${VAULT}/Notes/tsadar/requested.md" <<'EOF'
---
type: investigation
id: tsadar-requested
project: TSADAR
status: active
execution: nersc
execution_status: requested
execution_owner:
execution_updated: 2026-09-04T12:00:00Z
---

# Requested
EOF

cat >"${VAULT}/Notes/tsadar/ready.md" <<'EOF'
---
type: investigation
id: tsadar-ready
project: TSADAR
status: active
execution: nersc
execution_status: results-ready
execution_owner: local-agent
---

# Ready
EOF

cat >"${VAULT}/Notes/adept/requested.md" <<'EOF'
---
type: investigation
id: adept-requested
project: adept
status: active
execution: nersc
execution_status: requested
execution_owner:
---

# Requested
EOF

cat >"${VAULT}/Notes/adept/ordinary.md" <<'EOF'
---
type: investigation
id: ordinary
project: adept
status: active
---

# Ordinary note
EOF

output="$(ERGODIC_RESEARCH_VAULT="$VAULT" python3 "$LIST_REQUESTS")"
printf '%s\n' "$output" | grep -Fq 'Notes/tsadar/requested.md' \
  || fail 'default listing omitted the TSADAR request'
printf '%s\n' "$output" | grep -Fq 'Notes/adept/requested.md' \
  || fail 'default listing omitted the adept request'
printf '%s\n' "$output" | grep -Fq 'ready.md' \
  && fail 'default listing included a results-ready note'
printf '%s\n' "$output" | grep -Fq 'ordinary.md' \
  && fail 'default listing included an ordinary investigation note'

project_output="$(ERGODIC_RESEARCH_VAULT="$VAULT" \
  python3 "$LIST_REQUESTS" --project tsadar)"
printf '%s\n' "$project_output" | grep -Fq 'Notes/tsadar/requested.md' \
  || fail 'project-filtered listing omitted its request'
printf '%s\n' "$project_output" | grep -Fq 'Notes/adept/requested.md' \
  && fail 'project-filtered listing crossed project folders'

ready_json="$(ERGODIC_RESEARCH_VAULT="$VAULT" \
  python3 "$LIST_REQUESTS" --status results-ready --json)"
python3 - "$ready_json" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
assert len(items) == 1, items
assert items[0]["id"] == "tsadar-ready", items
assert items[0]["execution_owner"] == "local-agent", items
PY

empty="$(ERGODIC_RESEARCH_VAULT="$VAULT" \
  python3 "$LIST_REQUESTS" --project missing)"
[ "$empty" = "No NERSC investigation requests with status 'requested'." ] \
  || fail "unexpected empty-list output: $empty"

printf 'NERSC investigation consumer tests passed\n'
