#!/usr/bin/env python3
"""Read-only, project-scoped lexical recall over canonical research notes."""
from __future__ import annotations

import argparse
from contextlib import closing, contextmanager
import json
import os
import stat
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
from uuid import uuid4


STOP_WORDS = frozenset("a an and are as at be by did do does for from had has have how i in is it of on or our that the their this to was we were what when where which who why with would you choose".split())
CHECKPOINT = re.compile(r"Checkpoint ID:\*\*\s*`?([\w-]+)", re.I)
MAX_RELATION_STEPS = 20000
MAX_EVIDENCE_SECTIONS = 40


@contextmanager
def open_directory(path, *, dir_fd=None):
    # Only the configured vault root may resolve symlinks. All descendants are
    # single-component opens relative to an already anchored directory.
    flags = os.O_RDONLY | os.O_DIRECTORY
    if dir_fd is not None:
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, dir_fd=dir_fd)
    try:
        yield descriptor
    finally:
        os.close(descriptor)


def load_project(vault: Path, project: str, max_notes: int, max_depth: int) -> tuple[list, list]:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", project):
        raise ValueError("project must be a single folder name, not a path")
    if (os.open not in os.supports_dir_fd or os.scandir not in os.supports_fd
            or not all(getattr(os, name, 0) for name in ("O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK"))):
        raise ValueError("recall requires no-follow descriptor-relative opens and directory descriptor scans")
    root = vault / "Notes" / project
    documents, warnings = [], []
    entries_seen = total_bytes = 0

    def scan(directory_fd, directory, depth):
        nonlocal entries_seen, total_bytes
        try:
            entries = []
            with os.scandir(directory_fd) as iterator:
                for entry in iterator:
                    entries_seen += 1
                    if entries_seen > 10000:
                        warnings.append("directory-entry limit reached")
                        return False
                    entries.append(entry)
            for entry in sorted(entries, key=lambda e: e.name):
                path = directory / entry.name  # Citation only; never used to open.
                if entry.name.startswith("."):
                    continue
                if entry.is_symlink():
                    warnings.append(f"skipped symlink: {path.relative_to(vault)}")
                elif entry.is_dir(follow_symlinks=False):
                    if depth < max_depth:
                        try:
                            with open_directory(entry.name, dir_fd=directory_fd) as child_fd:
                                if not scan(child_fd, path, depth + 1):
                                    return False
                        except OSError as exc:
                            warnings.append(f"cannot list {path.relative_to(vault)}: {exc}")
                    else:
                        warnings.append(f"depth limit: {path.relative_to(vault)}")
                elif entry.name.endswith(".md"):
                    if len(documents) >= max_notes:
                        warnings.append("note limit reached")
                        return False
                    if not stat.S_ISREG(entry.stat(follow_symlinks=False).st_mode):
                        warnings.append(f"skipped non-regular note: {path.relative_to(vault)}")
                        continue
                    try:
                        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                        descriptor = os.open(entry.name, flags, dir_fd=directory_fd)
                        try:
                            with os.fdopen(descriptor, "rb", buffering=0, closefd=False) as handle:
                                if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                                    raise ValueError("not a regular file")
                                content = bytearray()
                                while len(content) <= 1024 * 1024 and total_bytes < 16 * 1024 * 1024:
                                    remaining = min(1024 * 1024 + 1 - len(content),
                                                    16 * 1024 * 1024 - total_bytes)
                                    chunk = handle.read(remaining)
                                    if not chunk:
                                        break
                                    total_bytes += len(chunk)
                                    content.extend(chunk)
                        finally:
                            os.close(descriptor)
                        if total_bytes >= 16 * 1024 * 1024:
                            # No extra EOF probe is permitted once the budget is
                            # exhausted. Do not index a potentially partial note.
                            warnings.append("project reaches 16 MiB read budget; last note omitted")
                            return False
                        if len(content) > 1024 * 1024:
                            warnings.append(f"note exceeds 1 MiB: {path.relative_to(vault)}")
                            continue
                        documents.append((path, content.decode("utf-8")))
                    except (OSError, UnicodeError, ValueError) as exc:
                        warnings.append(f"cannot read {path.relative_to(vault)}: {exc}")
        except OSError as exc:
            warnings.append(f"cannot list {directory.relative_to(vault)}: {exc}")
        return True

    with open_directory(vault) as vault_fd:
        with open_directory("Notes", dir_fd=vault_fd) as notes_fd:
            with open_directory(project, dir_fd=notes_fd) as project_fd:
                scan(project_fd, root, 0)
    return documents, warnings


def structural_lines(text: str) -> list[str]:
    """Mask fenced examples for parsing, retaining exact original source positions."""
    result, fence = [], ""
    for line in text.splitlines():
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if marker and not fence:
            fence = marker.group(1)
            result.append("")
        elif fence:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + "{" + str(len(fence)) + r",}\s*", line):
                fence = ""
            result.append("")
        else:
            result.append(line)
    return result


def sections(path: Path, vault: Path, text: str, max_sections: int = 10000) -> list[dict]:
    lines = text.splitlines()
    if not lines or max_sections <= 0:
        return []
    structure = structural_lines(text)
    headings = [0] + [i for i, line in enumerate(structure) if i and re.match(r"^#{1,3} ", line)]
    starts, checkpoint_level = [], 0
    for start, end in zip(headings, headings[1:] + [len(lines)]):
        heading = re.match(r"^(#{1,3}) ", structure[start])
        level = len(heading.group(1)) if heading else 0
        checkpoint = CHECKPOINT.search("\n".join(structure[start:end]))
        if checkpoint_level and level > checkpoint_level and not checkpoint:
            continue
        starts.append(start)
        if len(starts) > max_sections:
            break  # One boundary lookahead, not an extra section dictionary.
        checkpoint_level = level if checkpoint else 0
    metadata = {}
    if lines[0] == "---" and "---" in lines[1:]:
        for line in lines[1:lines.index("---", 1)]:
            field = re.fullmatch(r"(updated|status):\s*(.*?)\s*", line)
            if field:
                metadata[field.group(1)] = field.group(2).strip("\"'")
    result = []
    for start, end in zip(starts, starts[1:] + [len(lines)]):
        if len(result) >= max_sections:
            break
        text = "\n".join(lines[start:end])
        checkpoint = CHECKPOINT.search("\n".join(structure[start:end]))
        date = re.search(r"\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2}:\d{2})?", lines[start])
        result.append({"path": path.relative_to(vault).as_posix(),
                       "line_start": start + 1, "line_end": end,
                       "heading": lines[start] if lines[start].startswith("#") else "",
                       "checkpoint_id": checkpoint.group(1) if checkpoint else None,
                       "recorded_at": date.group() if date else None,
                       "note_updated": metadata.get("updated"), "note_status": metadata.get("status"),
                       "excerpt": text})
    return result


def relation_fields(chunk: dict):
    lines = structural_lines(chunk["excerpt"])
    frontmatter_end = lines.index("---", 1) if lines and lines[0] == "---" and "---" in lines[1:] else -1
    for i, line in enumerate(lines):
        field = re.match(r"\s*-?\s*(Corrects|Supersedes|Superseded-by):\s*(.*)",
                         line.replace("**", ""), re.I)
        if not field:
            continue
        value = field.group(2)
        in_frontmatter = 0 < i < frontmatter_end and chunk["line_start"] == 1
        if in_frontmatter:
            for following in lines[i + 1:frontmatter_end]:
                if not following.startswith((" ", "\t", "- ")):
                    break
                value += " " + following
        wiki_pattern = r"\[\[([^\]]+)\]\]"
        links = re.findall(wiki_pattern, value)
        # Parse bare IDs outside wikilinks as well; anchors/aliases inside a
        # qualified link must not be reinterpreted as global checkpoint IDs.
        remainder = re.sub(wiki_pattern, " ", value)
        links.extend(re.findall(r"\b\d{8}T\d{6}Z-[\w-]+\b", remainder))
        if not links and value.strip().lower() not in {"", "none", "null", "[]", "n/a"}:
            links = [value.strip()]
        for link in dict.fromkeys(links):
            yield link, in_frontmatter


def relation_graph(chunks: list[dict]) -> tuple[dict, list[dict], bool]:
    """Expand explicit relations, not generic wikilinks or chronological guesses."""
    graph = {i: set() for i in range(len(chunks))}
    unresolved, by_file, aliases, checkpoints = [], {}, {}, {}
    for i, chunk in enumerate(chunks):
        path = chunk["path"]
        by_file.setdefault(path, []).append(i)
        for alias in {path.removesuffix(".md"),
                      str(Path(path).relative_to("Notes")).removesuffix(".md"),
                      "/".join(path.split("/")[2:]).removesuffix(".md"), Path(path).stem}:
            aliases.setdefault(alias, set()).add(path)
        if chunk["checkpoint_id"]:
            checkpoints.setdefault(chunk["checkpoint_id"], []).append(i)

    steps = 0

    def spend():
        nonlocal steps
        if steps >= MAX_RELATION_STEPS:
            return False
        steps += 1
        return True

    def connect(a, b):
        # Count attempted expansion, including duplicate edges, before allocation.
        if not spend():
            return False
        graph[a].add(b)
        graph[b].add(a)
        return True

    for i, chunk in enumerate(chunks):
        for link, whole_source_note in relation_fields(chunk):
            if not spend():
                return graph, unresolved, True
            target = link.split("|", 1)[0]
            if "#" in target:
                note, anchor = target.split("#", 1)
            elif re.fullmatch(r"\d{8}T\d{6}Z-[\w-]+", target):
                note, anchor = "", target
            else:
                note, anchor = target, ""
            if note:
                paths = aliases.get(note.removesuffix(".md"), set())
                candidates = by_file[next(iter(paths))] if len(paths) == 1 else []
            elif target.startswith("#"):
                candidates = by_file[chunk["path"]]
            else:
                candidates = checkpoints.get(anchor.lstrip("^"), [])
            if anchor:
                candidates = [j for j in candidates if anchor.lstrip("^") == chunks[j]["checkpoint_id"]
                              or anchor == chunks[j]["heading"].lstrip("# ")]
            if not candidates or len({chunks[j]["path"] for j in candidates}) != 1 or (anchor and len(candidates) != 1):
                unresolved.append({"path": chunk["path"], "target": link,
                                   "reason": "missing, outside project, unsupported, or ambiguous target"})
                continue
            if whole_source_note:
                for j in by_file[chunk["path"]]:
                    if not connect(i, j):
                        return graph, unresolved, True
            for j in candidates:
                if not connect(i, j):
                    return graph, unresolved, True
    return graph, unresolved, False


def excerpt(chunk: dict, terms: list[str], budget: int, focus=None) -> dict:
    text = chunk["excerpt"]
    if focus is None:
        locations = [text.lower().find(term) for term in terms if term in text.lower()]
        focus = min(locations, default=0)
    start = min(max(0, focus - budget // 3), max(0, len(text) - budget))
    end = min(len(text), start + budget)
    prefix = text[:start]
    last = text[:end]
    return {**chunk, "excerpt": text[start:end],
            "line_start": chunk["line_start"] + prefix.count("\n"),
            "line_end": chunk["line_start"] + last.count("\n"),
            "column_start": len(prefix.rsplit("\n", 1)[-1]) + 1,
            "column_end": len(last.rsplit("\n", 1)[-1]) + 1,
            "excerpt_truncated": start > 0 or end < len(text)}


def recall(vault: Path, project: str, query: str, limit: int,
           max_notes: int = 500, max_depth: int = 4, max_chars: int = 12000) -> dict:
    documents, warnings = load_project(vault, project, max_notes, max_depth)
    chunks = []
    for path, text in documents:
        chunks.extend(sections(path, vault, text, 10000 - len(chunks)))
        if len(chunks) >= 10000:
            warnings.append("section limit reached")
            break
    scope_complete = not warnings
    terms = list(dict.fromkeys(word for word in re.findall(r"[^\W_]+", query.lower()) if word not in STOP_WORDS))
    with closing(sqlite3.connect(":memory:")) as db:
        db.execute("CREATE VIRTUAL TABLE notes USING fts5(body, tokenize='porter unicode61')")
        db.executemany("INSERT INTO notes(rowid, body) VALUES (?, ?)",
                       [(i + 1, chunk["excerpt"]) for i, chunk in enumerate(chunks)])
        expression = " OR ".join('"' + term + '"' for term in terms)
        marker = uuid4().hex
        while any(marker in chunk["excerpt"] for chunk in chunks):
            marker = uuid4().hex
        # The first inserted marker's offset is an original-source offset, using
        # the same stemming/tokenization as retrieval (not substring guessing).
        rows = db.execute("SELECT rowid, instr(highlight(notes, 0, ?, ''), ?) - 1 "
                          "FROM notes WHERE notes MATCH ? ORDER BY rank, rowid LIMIT ?",
                          (marker, marker, expression, limit)).fetchall() if expression else []
    selected = [row[0] - 1 for row in rows]
    positions = {row[0] - 1: row[1] for row in rows}
    graph, unresolved, graph_limited = relation_graph(chunks)
    if graph_limited:
        warnings.append("relation construction budget reached; unprocessed targets may include corrections")
    seen = set(selected)
    queue = list(selected)
    linked = []
    closure_limited = False
    for i in queue:
        for j in sorted(graph[i]):
            if j not in seen:
                if len(queue) >= MAX_EVIDENCE_SECTIONS:
                    closure_limited = True
                    break
                seen.add(j)
                queue.append(j)
                linked.append(j)
        if closure_limited:
            break
    if closure_limited:
        warnings.append("evidence limit: additional linked sections omitted; inspect sources before reusing claims")
    budget = min(2000, max_chars // max(1, len(selected) + len(linked)))
    matches = [excerpt(chunks[i], terms, budget, positions[i]) for i in selected]
    evidence = [excerpt(chunks[i], terms, budget) for i in linked]
    clipped = any(item["excerpt_truncated"] for item in matches + evidence)
    if clipped:
        warnings.append("excerpts clipped; read source sections for complete qualifications")
    return {"status": "partial" if warnings or unresolved else ("ok" if matches else "not_found"),
            "project": project, "query": query, "scope_complete": scope_complete,
            "notes_scanned": len(documents), "warnings": [w[:300] for w in warnings[:50]],
            "warning_count": len(warnings), "requires_live_verification": True,
            "relations_complete": scope_complete and not (unresolved or graph_limited or closure_limited),
            "unresolved_links": [{**item, "target": item["target"][:300]} for item in unresolved[:50]],
            "unresolved_link_count": len(unresolved), "output_truncated": clipped or graph_limited or closure_limited,
            "matches": matches, "linked_evidence": evidence}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vault", type=Path, help="otherwise use the existing shared-vault resolver")
    parser.add_argument("--project", required=True)
    parser.add_argument("--query", required=True)
    parser.add_argument("--limit", default=5, type=int)
    parser.add_argument("--max-notes", default=500, type=int)
    parser.add_argument("--max-depth", default=4, type=int)
    parser.add_argument("--max-chars", default=12000, type=int, help="total excerpt character budget (not JSON metadata)")
    args = parser.parse_args()
    if not 1 <= args.limit <= 20 or not 1 <= args.max_notes <= 2000 or not 0 <= args.max_depth <= 8:
        parser.error("limit must be 1..20, max-notes 1..2000, max-depth 0..8")
    if not 1 <= len(args.query) <= 500:
        parser.error("query must contain 1..500 characters")
    if not 800 <= args.max_chars <= 32000:
        parser.error("max-chars must be 800..32000")
    try:
        vault = args.vault
        if vault is None:
            resolver = Path(__file__).resolve().with_name("resolve-shared-vault.py")
            process = subprocess.run([sys.executable, str(resolver)], capture_output=True,
                                     text=True, timeout=10)
            if process.returncode:
                raise ValueError(process.stderr.strip())
            vault = Path(process.stdout.strip())
        result = recall(vault.expanduser().resolve(), args.project, args.query, args.limit,
                        args.max_notes, args.max_depth, args.max_chars)
    except (OSError, ValueError, sqlite3.Error, subprocess.TimeoutExpired) as exc:
        parser.exit(2, f"error: {exc}\n")
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
