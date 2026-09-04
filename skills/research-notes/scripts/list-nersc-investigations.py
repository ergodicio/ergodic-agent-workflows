#!/usr/bin/env python3
"""List NERSC investigation handoffs with a bounded vault scan."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType


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


def frontmatter(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        print(f"warning: cannot read {path}: {exc}", file=sys.stderr)
        return {}
    if not lines or lines[0].strip() != "---":
        return {}

    values: dict[str, str] = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if not line or line[0].isspace() or ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def candidate_notes(notes_root: Path, project: str | None):
    if project:
        if project in {".", ".."} or "/" in project or "\\" in project:
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
        try:
            yield from sorted(
                path
                for path in root.iterdir()
                if path.is_file() and not path.is_symlink() and path.suffix == ".md"
            )
        except OSError as exc:
            print(f"warning: cannot list {root}: {exc}", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="List shared-vault NERSC investigation requests."
    )
    parser.add_argument("--project", help="exact Notes/<project> folder name")
    parser.add_argument("--status", default="requested", help="execution status")
    parser.add_argument("--json", action="store_true", help="emit a JSON array")
    args = parser.parse_args()

    vault = resolve_vault()
    notes_root = vault / "Notes"
    results = []
    for path in candidate_notes(notes_root, args.project):
        properties = frontmatter(path)
        if properties.get("execution") != "nersc":
            continue
        if properties.get("execution_status") != args.status:
            continue
        results.append(
            {
                "path": str(path.relative_to(vault)),
                "id": properties.get("id", path.stem),
                "project": properties.get("project", path.parent.name),
                "execution_status": properties.get("execution_status", ""),
                "execution_owner": properties.get("execution_owner", ""),
                "updated": properties.get("execution_updated", ""),
            }
        )

    if args.json:
        json.dump(results, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return

    if not results:
        print(f"No NERSC investigation requests with status {args.status!r}.")
        return
    for result in results:
        print(
            f"{result['path']}\t{result['id']}\t{result['project']}\t"
            f"{result['execution_status']}\t{result['execution_owner']}"
        )


if __name__ == "__main__":
    main()
