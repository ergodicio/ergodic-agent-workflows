#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$REPO_ROOT" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

repo = Path(sys.argv[1])
helper = repo / "skills/research-notes/scripts/list-nersc-investigations.py"
skill = repo / "skills/research-notes/SKILL.md"
reference = repo / "skills/research-notes/references/nersc-investigation-handoff.md"
assert "references/nersc-investigation-handoff.md" in skill.read_text()
assert reference.is_file()

root = Path(tempfile.mkdtemp())
vault = root / "Ergodic Research"
(vault / "Notes/tsadar").mkdir(parents=True)
(vault / "Notes/adept").mkdir(parents=True)
os.environ["ERGODIC_RESEARCH_VAULT"] = str(vault)


def envelope(status="requested", owner="", **updates):
    data = {
        "schema": "ergodic.nersc-investigation/v1",
        "research_status": "active",
        "execution": "nersc",
        "execution_status": status,
        "execution_owner": owner,
        "execution_updated": "2026-09-04T12:00:00Z",
    }
    data.update(updates)
    return data


def note(project, name, payload, marker=True, closing=True):
    path = vault / "Notes" / project / f"{name}.md"
    if isinstance(payload, dict):
        payload = json.dumps(payload, indent=2)
    parts = ["---", "type: investigation", "status: active", "---", "", f"# {name}"]
    if marker:
        parts += ["", "<!-- ergodic-nersc-investigation:v1", payload]
        if closing:
            parts.append("-->")
    path.write_text("\n".join(parts) + "\n")
    return path


requested_note = note("tsadar", "requested", envelope())
requested_note.write_text(
    requested_note.read_text() + "\n<!-- unrelated comment\nordinary text\n-->\n"
)
note("adept", "requested", envelope())
note("tsadar", "ready", envelope("results-ready", "local-agent"))
note("tsadar", "assigned-local", envelope("assigned", "local-agent-7"))
note("tsadar", "assigned-other", envelope("assigned", "other-agent"))

invalid = {
    "malformed-json": "{not json}",
    "wrong-schema": envelope(schema="other/v1"),
    "inactive": envelope(research_status="complete"),
    "wrong-execution": envelope(execution="local"),
    "unknown-status": envelope(execution_status="mystery"),
    "ownerless-assigned": envelope("assigned", ""),
    "unknown-key": {**envelope(), "extra": "value"},
    "non-string": envelope(execution_updated=7),
}
for name, payload in invalid.items():
    note("tsadar", name, payload)
note("tsadar", "unterminated", json.dumps(envelope()), closing=False)
note("tsadar", "no-marker", "", marker=False)

duplicate = json.dumps(envelope(), indent=2).replace(
    '  "execution": "nersc",',
    '  "execution": "other",\n  "execution": "nersc",',
)
note("tsadar", "duplicate-key", duplicate)

multiple = note("tsadar", "multiple", envelope())
multiple.write_text(
    multiple.read_text()
    + "\n<!-- ergodic-nersc-investigation:v1\n"
    + json.dumps(envelope())
    + "\n-->\n"
)

outside = vault / "Outside"
outside.mkdir()
external = outside / "external.md"
external.write_text("<!-- ergodic-nersc-investigation:v1\n{}\n-->\n")
(vault / "Notes/linked-project").symlink_to(outside, target_is_directory=True)
(vault / "Notes/tsadar/linked.md").symlink_to(external)


def run(*args, check=True):
    return subprocess.run(
        [sys.executable, str(helper), *args],
        check=check,
        text=True,
        capture_output=True,
        env=os.environ,
    )


requested = json.loads(run("--json").stdout)
assert {item["path"] for item in requested} == {
    "Notes/tsadar/requested.md",
    "Notes/adept/requested.md",
}

ready = json.loads(run("--status", "results-ready", "--json").stdout)
assert len(ready) == 1 and ready[0]["id"] == "ready"
assert ready[0]["execution_owner"] == "local-agent"

assigned = json.loads(
    run("--status", "assigned", "--owner", "local-agent-7", "--json").stdout
)
assert len(assigned) == 1 and assigned[0]["id"] == "assigned-local"

project = json.loads(run("--project", "tsadar", "--json").stdout)
assert [item["id"] for item in project] == ["requested"]

for value in ("", "..", "../tsadar", str(vault / "Notes/tsadar")):
    assert run("--project", value, check=False).returncode != 0, value

external_notes = root / "External Notes"
(external_notes / "escaped").mkdir(parents=True)
old_vault = vault
vault = root / "Symlinked Notes Vault"
vault.mkdir()
(vault / "Notes").symlink_to(external_notes, target_is_directory=True)
note("escaped", "outside", envelope())
os.environ["ERGODIC_RESEARCH_VAULT"] = str(vault)
assert run("--json", check=False).returncode != 0
vault = old_vault

print("NERSC investigation handoff tests passed")
PY
