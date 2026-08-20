#!/usr/bin/env python3
"""Resolve the shared research vault without recursively searching the filesystem."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import NoReturn


VAULT_ENV = "ERGODIC_RESEARCH_VAULT"
VAULT_NAME_ENV = "ERGODIC_RESEARCH_VAULT_NAME"
DEFAULT_VAULT_NAME = "Ergodic Research"


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate_vault(raw_path: str, source: str) -> Path:
    path = Path(raw_path).expanduser()
    try:
        path = path.resolve()
    except OSError as exc:
        fail(f"cannot resolve vault from {source}: {exc}")

    if not path.is_dir():
        fail(f"vault from {source} is not a directory: {path}")
    if not (path / "Notes").is_dir():
        fail(f"vault from {source} does not contain Notes/: {path}")
    return path


def registry_paths() -> list[Path]:
    home = Path.home()
    candidates = [
        home / "Library" / "Application Support" / "obsidian" / "obsidian.json",
        Path(os.environ.get("XDG_CONFIG_HOME", home / ".config"))
        / "obsidian"
        / "obsidian.json",
    ]
    appdata = os.environ.get("APPDATA")
    if appdata:
        candidates.append(Path(appdata) / "obsidian" / "obsidian.json")

    unique: list[Path] = []
    seen: set[Path] = set()
    for path in candidates:
        if path not in seen:
            seen.add(path)
            unique.append(path)
    return unique


def registry_vaults(registry: Path, vault_name: str) -> list[Path]:
    if not registry.is_file():
        return []
    try:
        data = json.loads(registry.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read Obsidian registry {registry}: {exc}")

    vaults = data.get("vaults", {})
    if not isinstance(vaults, dict):
        fail(f"Obsidian registry has an invalid vaults object: {registry}")

    matches: list[Path] = []
    for entry in vaults.values():
        if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
            continue
        path = Path(entry["path"]).expanduser()
        if path.name == vault_name and path.is_dir() and (path / "Notes").is_dir():
            matches.append(path.resolve())
    return matches


def main() -> None:
    configured = os.environ.get(VAULT_ENV)
    if configured:
        print(validate_vault(configured, VAULT_ENV))
        return

    vault_name = os.environ.get(VAULT_NAME_ENV, DEFAULT_VAULT_NAME)
    matches: list[Path] = []
    for registry in registry_paths():
        matches.extend(registry_vaults(registry, vault_name))
    matches = list(dict.fromkeys(matches))

    if not matches:
        fail(
            f"no local Obsidian vault named {vault_name!r}; "
            f"set {VAULT_ENV} on headless or non-Obsidian hosts"
        )
    if len(matches) > 1:
        rendered = ", ".join(str(path) for path in matches)
        fail(f"multiple local vaults named {vault_name!r}: {rendered}; set {VAULT_ENV}")

    print(validate_vault(str(matches[0]), "Obsidian registry"))


if __name__ == "__main__":
    main()
