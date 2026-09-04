#!/usr/bin/env python3
"""List NERSC investigation handoffs with a bounded vault scan."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import stat
import sys
from pathlib import Path
from types import ModuleType
from typing import Any


START_MARKER = "<!-- ergodic-nersc-investigation:v1"
END_MARKER = "-->"
SCHEMA = "ergodic.nersc-investigation/v1"
REQUIRED_KEYS = {
    "schema",
    "research_status",
    "execution",
    "execution_status",
    "execution_owner",
    "execution_updated",
}
EXECUTION_STATUSES = {
    "requested",
    "assigned",
    "running",
    "results-ready",
    "blocked",
    "cancelled",
}


def load_vault_resolver() -> ModuleType:
    resolver_path = Path(__file__).resolve().with_name("resolve-shared-vault.py")
    if not resolver_path.is_file():
        raise SystemExit(f"error: shared-vault resolver not found: {resolver_path}")
    spec = importlib.util.spec_from_file_location("resolve_shared_vault", resolver_path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"error: cannot load shared-vault resolver: {resolver_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resolve_vault() -> Path:
    resolver = load_vault_resolver()
    configured = resolver.os.environ.get(resolver.VAULT_ENV)
    if configured:
        return resolver.validate_vault(configured, resolver.VAULT_ENV)

    vault_name = resolver.os.environ.get(
        resolver.VAULT_NAME_ENV, resolver.DEFAULT_VAULT_NAME
    )
    matches: list[Path] = []
    for registry in resolver.registry_paths():
        matches.extend(resolver.registry_vaults(registry, vault_name))
    matches = list(dict.fromkeys(matches))
    if not matches:
        resolver.fail(
            f"no local Obsidian vault named {vault_name!r}; "
            f"set {resolver.VAULT_ENV} on headless or non-Obsidian hosts"
        )
    if len(matches) > 1:
        rendered = ", ".join(str(path) for path in matches)
        resolver.fail(
            f"multiple local vaults named {vault_name!r}: {rendered}; "
            f"set {resolver.VAULT_ENV}"
        )
    return resolver.validate_vault(str(matches[0]), "Obsidian registry")


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def handoff(path: Path) -> dict[str, str] | None:
    directory_descriptor: int | None = None
    file_descriptor: int | None = None
    try:
        directory_before = path.parent.lstat()
        if stat.S_ISLNK(directory_before.st_mode) or not stat.S_ISDIR(
            directory_before.st_mode
        ):
            return None
        directory_flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            directory_flags |= os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            directory_flags |= os.O_NOFOLLOW
        directory_descriptor = os.open(path.parent, directory_flags)
        directory_opened = os.fstat(directory_descriptor)
        if (directory_before.st_dev, directory_before.st_ino) != (
            directory_opened.st_dev,
            directory_opened.st_ino,
        ):
            return None

        before = os.stat(path.name, dir_fd=directory_descriptor, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            return None
        file_flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            file_flags |= os.O_NOFOLLOW
        file_descriptor = os.open(path.name, file_flags, dir_fd=directory_descriptor)
        opened = os.fstat(file_descriptor)
        if not stat.S_ISREG(opened.st_mode):
            return None
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            return None
        with os.fdopen(file_descriptor, encoding="utf-8") as stream:
            file_descriptor = None
            lines = stream.read().splitlines()
    except (OSError, UnicodeDecodeError, NotImplementedError) as exc:
        print(f"warning: cannot read {path}: {exc}", file=sys.stderr)
        return None
    finally:
        if file_descriptor is not None:
            os.close(file_descriptor)
        if directory_descriptor is not None:
            os.close(directory_descriptor)

    starts = [index for index, line in enumerate(lines) if line == START_MARKER]
    if len(starts) != 1:
        return None
    start = starts[0]
    end = next(
        (
            index
            for index, line in enumerate(lines[start + 1 :], start + 1)
            if line == END_MARKER
        ),
        None,
    )
    if end is None:
        return None

    payload = "\n".join(lines[start + 1 : end])
    try:
        data = json.loads(payload, object_pairs_hook=reject_duplicate_keys)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(data, dict) or set(data) != REQUIRED_KEYS:
        return None
    if any(not isinstance(value, str) for value in data.values()):
        return None
    if data["schema"] != SCHEMA:
        return None
    if data["research_status"] != "active" or data["execution"] != "nersc":
        return None
    if data["execution_status"] not in EXECUTION_STATUSES:
        return None
    if data["execution_status"] in {"assigned", "running", "results-ready"}:
        if not data["execution_owner"].strip():
            return None
    return data


def candidate_notes(notes_root: Path, project: str | None):
    if notes_root.is_symlink() or not notes_root.is_dir():
        raise SystemExit(f"error: vault Notes root is missing or symlinked: {notes_root}")
    notes_root = notes_root.resolve()
    if project is not None:
        project_path = Path(project)
        if (
            not project
            or project in {".", ".."}
            or project_path.is_absolute()
            or len(project_path.parts) != 1
            or "/" in project
            or "\\" in project
        ):
            raise SystemExit(
                "error: --project must be one exact Notes/<project> folder name"
            )
        roots = [notes_root / project]
    else:
        try:
            roots = sorted(
                path
                for path in notes_root.iterdir()
                if path.is_dir() and not path.is_symlink()
            )
        except OSError as exc:
            raise SystemExit(f"error: cannot list vault notes: {exc}") from exc

    for root in roots:
        if not root.is_dir() or root.is_symlink():
            continue
        if root.resolve().parent != notes_root:
            continue
        try:
            yield from sorted(
                path
                for path in root.iterdir()
                if path.is_file()
                and not path.is_symlink()
                and path.suffix == ".md"
                and path.resolve().parent == root.resolve()
            )
        except OSError as exc:
            print(f"warning: cannot list {root}: {exc}", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="List shared-vault NERSC investigation requests."
    )
    parser.add_argument("--project", help="exact Notes/<project> folder name")
    parser.add_argument("--status", default="requested", help="execution status")
    parser.add_argument("--owner", help="exact execution owner identity")
    parser.add_argument("--json", action="store_true", help="emit a JSON array")
    args = parser.parse_args()

    vault = resolve_vault()
    results = []
    for path in candidate_notes(vault / "Notes", args.project):
        envelope = handoff(path)
        if envelope is None or envelope["execution_status"] != args.status:
            continue
        if args.owner is not None and envelope["execution_owner"] != args.owner:
            continue
        results.append(
            {
                "path": str(path.relative_to(vault)),
                "id": path.stem,
                "project": path.parent.name,
                "execution_status": envelope["execution_status"],
                "execution_owner": envelope["execution_owner"],
                "updated": envelope["execution_updated"],
            }
        )

    if args.json:
        json.dump(results, sys.stdout, indent=2)
        sys.stdout.write("\n")
    elif not results:
        print(f"No NERSC investigation requests with status {args.status!r}.")
    else:
        for result in results:
            print(
                f"{result['path']}\t{result['id']}\t{result['project']}\t"
                f"{result['execution_status']}\t{result['execution_owner']}"
            )


if __name__ == "__main__":
    main()
