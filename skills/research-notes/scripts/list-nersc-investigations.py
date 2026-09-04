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
from typing import Any, Iterator


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


def directory_flags() -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return flags


def open_child_directory(parent_descriptor: int, name: str) -> int:
    before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
        raise OSError(f"not a real directory: {name}")
    descriptor = os.open(name, directory_flags(), dir_fd=parent_descriptor)
    opened = os.fstat(descriptor)
    if not stat.S_ISDIR(opened.st_mode) or (
        before.st_dev,
        before.st_ino,
    ) != (opened.st_dev, opened.st_ino):
        os.close(descriptor)
        raise OSError(f"directory changed while opening: {name}")
    return descriptor


def open_canonical_directory(path: Path) -> int:
    path = path.resolve(strict=True)
    if not path.is_absolute():
        raise OSError(f"expected an absolute path: {path}")
    descriptor = os.open(path.anchor, directory_flags())
    try:
        for component in path.parts[1:]:
            next_descriptor = open_child_directory(descriptor, component)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_envelope(lines: list[str]) -> dict[str, str] | None:
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

    try:
        data = json.loads(
            "\n".join(lines[start + 1 : end]),
            object_pairs_hook=reject_duplicate_keys,
        )
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


def read_envelope(directory_descriptor: int, name: str, display_path: Path):
    descriptor: int | None = None
    try:
        before = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            return None
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(name, flags, dir_fd=directory_descriptor)
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or (
            before.st_dev,
            before.st_ino,
        ) != (opened.st_dev, opened.st_ino):
            return None
        with os.fdopen(descriptor, encoding="utf-8") as stream:
            descriptor = None
            return parse_envelope(stream.read().splitlines())
    except (OSError, UnicodeDecodeError, NotImplementedError) as exc:
        print(f"warning: cannot read {display_path}: {exc}", file=sys.stderr)
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def validate_project(project: str) -> None:
    project_path = Path(project)
    if (
        not project
        or project in {".", ".."}
        or project_path.is_absolute()
        or len(project_path.parts) != 1
        or "/" in project
        or "\\" in project
    ):
        raise SystemExit("error: --project must be one exact Notes/<project> folder name")


def scan_handoffs(vault: Path, project: str | None) -> Iterator[tuple[Path, dict[str, str]]]:
    vault_descriptor: int | None = None
    notes_descriptor: int | None = None
    try:
        vault = vault.resolve(strict=True)
        vault_descriptor = open_canonical_directory(vault)
        notes_descriptor = open_child_directory(vault_descriptor, "Notes")
        if project is not None:
            validate_project(project)
            projects = [project]
        else:
            projects = sorted(os.listdir(notes_descriptor))

        for project_name in projects:
            project_descriptor: int | None = None
            try:
                validate_project(project_name)
                project_descriptor = open_child_directory(notes_descriptor, project_name)
                for name in sorted(os.listdir(project_descriptor)):
                    if Path(name).name != name or not name.endswith(".md"):
                        continue
                    display_path = vault / "Notes" / project_name / name
                    envelope = read_envelope(project_descriptor, name, display_path)
                    if envelope is not None:
                        yield display_path, envelope
            except (OSError, NotImplementedError):
                continue
            finally:
                if project_descriptor is not None:
                    os.close(project_descriptor)
    except (OSError, NotImplementedError) as exc:
        raise SystemExit(f"error: cannot scan vault Notes directory: {exc}") from exc
    finally:
        if notes_descriptor is not None:
            os.close(notes_descriptor)
        if vault_descriptor is not None:
            os.close(vault_descriptor)


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
    for path, envelope in scan_handoffs(vault, args.project):
        if envelope["execution_status"] != args.status:
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
