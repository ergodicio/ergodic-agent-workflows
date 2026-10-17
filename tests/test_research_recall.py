"""Offline recall contracts. All research text here is synthetic test data."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "skills/research-notes/scripts/recall.py"
SPEC = importlib.util.spec_from_file_location("research_recall", SCRIPT)
RECALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECALL)


class RecallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.vault = Path(self.tmp.name) / "vault"
        (self.vault / "Notes/demo").mkdir(parents=True)

    def note(self, name, content, project="demo"):
        path = self.vault / "Notes" / project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def run_cli(self, query, *args, expected=0):
        command = [sys.executable, str(SCRIPT), "--vault", str(self.vault),
                   "--project", "demo", "--query", query, *args]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stderr)
        return json.loads(result.stdout) if expected == 0 else result

    def test_recovers_decision_with_exact_source_and_checkpoint(self):
        text = ("---\nproject: demo\nupdated: '2026-01-02'\n---\n"
                "# Solver choice\n\n### 2026-01-02 10:00:00 — COMPLETED\n"
                "- **Checkpoint ID:** 20260102T100000Z-aaaaaaaa\n"
                "- **Observation:** The adjoint failed the Taylor test.\n"
                "- **USER (verbatim):** Use derivative-free optimization.\n")
        self.note("decision.md", text)
        self.note("unrelated.md", "# Hardware\nThe network is offline.\n", "other")
        data = self.run_cli("Why did we choose derivative-free optimization?")
        self.assertEqual(data["status"], "ok")
        self.assertTrue(data["scope_complete"])
        item = data["matches"][0]
        self.assertEqual(item["path"], "Notes/demo/decision.md")
        self.assertEqual(item["checkpoint_id"], "20260102T100000Z-aaaaaaaa")
        self.assertEqual(item["recorded_at"], "2026-01-02 10:00:00")
        self.assertIn("Taylor test", item["excerpt"])
        self.assertEqual(item["excerpt"], "\n".join(
            text.splitlines()[item["line_start"] - 1:item["line_end"]]))
        self.assertTrue(data["requires_live_verification"])

    def test_old_claim_brings_its_keyword_free_correction_and_chain(self):
        self.note("original.md", "# Trial\n### 2026-01-01 — COMPLETED\n"
                  "- **Checkpoint ID:** 20260101T000000Z-aaaaaaaa\n"
                  "- **Observation:** Amber capsule wins the objective.\n")
        self.note("correction.md", "# Review\n### 2026-01-02 — CORRECTION\n"
                  "- **Checkpoint ID:** 20260102T000000Z-bbbbbbbb\n"
                  "- **Corrects:** [[original#20260101T000000Z-aaaaaaaa|earlier result]]\n"
                  "- **Observation:** The ranking was invalid; grids differed.\n")
        self.note("followup.md", "# Follow-up\n### 2026-01-03 — CORRECTION\n"
                  "- **Checkpoint ID:** 20260103T000000Z-cccccccc\n"
                  "- **Corrects:** 20260102T000000Z-bbbbbbbb\n"
                  "- **Observation:** A matched comparison is still needed.\n")
        data = self.run_cli("Amber capsule", "--limit", "1")
        self.assertTrue(data["relations_complete"])
        self.assertEqual([x["checkpoint_id"] for x in data["linked_evidence"]],
                         ["20260102T000000Z-bbbbbbbb", "20260103T000000Z-cccccccc"])
        self.assertIn("grids differed", data["linked_evidence"][0]["excerpt"])
        inverse = self.run_cli("ranking invalid", "--limit", "1")
        self.assertIn("20260101T000000Z-aaaaaaaa",
                      [x["checkpoint_id"] for x in inverse["linked_evidence"]])


    def test_checkpoint_subheadings_keep_keyword_free_corrections_connected(self):
        text = ("# Study\n## 2026-01-01 — COMPLETED\n"
                "- **Checkpoint ID:** 20260101T000000Z-aaaaaaaa\n"
                "### Observation\nAmber capsule wins.\n"
                "### Interpretation\nThis is still provisional.\n"
                "## Unrelated result\nSeparate marker.\n")
        self.note("original.md", text)
        self.note("correction.md", "# Review\n## 2026-01-02 — CORRECTION\n"
                  "- **Checkpoint ID:** 20260102T000000Z-bbbbbbbb\n"
                  "- **Corrects:** [[original#20260101T000000Z-aaaaaaaa]]\n"
                  "### Observation\nThe ranking was invalid; grids differed.\n")
        data = self.run_cli("Amber capsule", "--limit", "1")
        self.assertTrue(data["relations_complete"])
        self.assertEqual([item["checkpoint_id"] for item in data["linked_evidence"]],
                         ["20260102T000000Z-bbbbbbbb"])
        item = data["matches"][0]
        self.assertEqual(item["checkpoint_id"], "20260101T000000Z-aaaaaaaa")
        self.assertEqual(item["recorded_at"], "2026-01-01")
        self.assertEqual(item["excerpt"], "\n".join(text.splitlines()[1:7]))
        self.assertEqual((item["line_start"], item["line_end"]), (2, 7))
        self.assertIn("grids differed", data["linked_evidence"][0]["excerpt"])
        inverse = self.run_cli("ranking invalid", "--limit", "1")
        self.assertEqual(inverse["linked_evidence"][0]["checkpoint_id"],
                         "20260101T000000Z-aaaaaaaa")
        unrelated = self.run_cli("Separate marker", "--limit", "1")
        self.assertIsNone(unrelated["matches"][0]["checkpoint_id"])
        self.assertEqual(unrelated["linked_evidence"], [])

    def test_discovery_rejects_escape_and_reports_symlinks_and_depth(self):
        self.note("safe.md", "# Safe\nRecallmarker inside the project.\n")
        secret = self.note("secret.md", "# Secret\nRecallmarker outside.\n", "other")
        (self.vault / "Notes/demo/leak.md").symlink_to(secret)
        self.note("nested/deeper/hidden.md", "Recallmarker too deep.\n")
        data = self.run_cli("Recallmarker", "--max-depth", "1")
        self.assertFalse(data["scope_complete"])
        self.assertEqual(data["status"], "partial")
        self.assertEqual([x["path"] for x in data["matches"]], ["Notes/demo/safe.md"])
        self.assertTrue(data["warnings"])
        self.run_cli("Recallmarker", "--project", "../other", expected=2)
        self.run_cli("Recallmarker", "--project", "absent", expected=2)
        (self.vault / "Notes/alias").symlink_to(self.vault / "Notes/other", target_is_directory=True)
        self.run_cli("Recallmarker", "--project", "alias", expected=2)

    def test_directory_swap_before_scan_cannot_escape_project(self):
        nested = self.note("nested/inside.md", "Anchoredmarker inside.\n").parent
        outside = Path(self.tmp.name) / "outside"
        outside.mkdir()
        (outside / "secret.md").write_text("Escapemarker outside.\n")
        inode = nested.stat().st_ino
        real_scandir = os.scandir
        swapped = False

        def swap_before_scan(directory):
            nonlocal swapped
            info = os.fstat(directory) if isinstance(directory, int) else os.stat(directory)
            if not swapped and info.st_ino == inode:
                nested.rename(Path(self.tmp.name) / "original-nested")
                nested.symlink_to(outside, target_is_directory=True)
                swapped = True
            return real_scandir(directory)

        with mock.patch.object(RECALL.os, "scandir", swap_before_scan), mock.patch.object(
                RECALL.os, "supports_fd", os.supports_fd | {swap_before_scan}):
            data = RECALL.recall(self.vault, "demo", "Escapemarker Anchoredmarker", 5)
        self.assertTrue(swapped, "the directory replacement must actually occur")
        self.assertFalse(any("Escapemarker" in item["excerpt"] for item in data["matches"]))
        self.assertTrue(any("Anchoredmarker" in item["excerpt"] for item in data["matches"]))

    def test_descendant_swaps_at_open_are_rejected(self):
        real_open = os.open
        for component in ("Notes", "demo", "nested", "inside.md"):
            with self.subTest(component=component), tempfile.TemporaryDirectory(dir=self.tmp.name) as tmp:
                vault = Path(tmp) / "vault"
                inside = vault / "Notes/demo/nested/inside.md"
                inside.parent.mkdir(parents=True)
                inside.write_text("Inside marker.\n")
                outside = Path(tmp) / "outside"
                outside.mkdir()
                target = next(path for path in (inside, *inside.parents) if path.name == component)
                external_note = outside / ("secret.md" if component == "inside.md" else inside.relative_to(target))
                external_note.parent.mkdir(parents=True, exist_ok=True)
                external_note.write_text("Escapemarker outside.\n")
                swapped = False

                def swap_at_open(path, flags, *args, **kwargs):
                    nonlocal swapped
                    if not swapped and path == component and kwargs.get("dir_fd") is not None:
                        target.rename(Path(tmp) / "original")
                        target.symlink_to(external_note if component == "inside.md" else outside)
                        swapped = True
                    return real_open(path, flags, *args, **kwargs)

                with mock.patch.object(RECALL.os, "open", swap_at_open), mock.patch.object(
                        RECALL.os, "supports_dir_fd", os.supports_dir_fd | {swap_at_open}):
                    if component in ("Notes", "demo"):
                        with self.assertRaises(OSError):
                            RECALL.recall(vault, "demo", "Escapemarker", 5)
                    else:
                        data = RECALL.recall(vault, "demo", "Escapemarker", 5)
                        self.assertEqual(data["matches"], [])
                        self.assertFalse(data["scope_complete"])
                self.assertTrue(swapped)

    def test_descriptors_close_on_success_limits_and_io_errors(self):
        self.note("nested/a.md", "Inside marker.\n")
        self.note("nested/b.md", "Inside marker.\n")
        real_open, real_close = os.open, os.close
        for case in ("success", "note-limit", "file-error", "scan-error", "missing-project"):
            with self.subTest(case=case):
                active = set()

                def tracked_open(*args, **kwargs):
                    descriptor = real_open(*args, **kwargs)
                    active.add(descriptor)
                    return descriptor

                def tracked_close(descriptor):
                    real_close(descriptor)
                    active.remove(descriptor)

                with mock.patch.object(RECALL.os, "open", tracked_open), mock.patch.object(
                        RECALL.os, "close", tracked_close), mock.patch.object(
                        RECALL.os, "supports_dir_fd", os.supports_dir_fd | {tracked_open}):
                    if case == "file-error":
                        with mock.patch.object(RECALL.os, "fdopen", side_effect=OSError("injected file error")):
                            documents, warnings = RECALL.load_project(self.vault, "demo", 500, 4)
                        self.assertFalse(documents)
                        self.assertTrue(warnings)
                    elif case == "scan-error":
                        with mock.patch.object(RECALL.os, "scandir", side_effect=OSError("injected scan error")) as scan:
                            with mock.patch.object(RECALL.os, "supports_fd", os.supports_fd | {scan}):
                                documents, warnings = RECALL.load_project(self.vault, "demo", 500, 4)
                        self.assertFalse(documents)
                        self.assertTrue(warnings)
                    elif case == "missing-project":
                        with self.assertRaises(OSError):
                            RECALL.load_project(self.vault, "missing", 500, 4)
                    else:
                        documents, warnings = RECALL.load_project(
                            self.vault, "demo", 1 if case == "note-limit" else 500, 4)
                        self.assertEqual(len(documents), 1 if case == "note-limit" else 2)
                        self.assertEqual(bool(warnings), case == "note-limit")
                self.assertEqual(active, set(), "every opened descriptor must be closed")

    def test_configured_vault_symlink_is_the_trust_anchor(self):
        self.note("inside.md", "Recallmarker inside.\n")
        alias = Path(self.tmp.name) / "vault-alias"
        alias.symlink_to(self.vault, target_is_directory=True)
        data = RECALL.recall(alias, "demo", "Recallmarker", 5)
        self.assertEqual(data["status"], "ok")
        self.assertEqual(data["matches"][0]["path"], "Notes/demo/inside.md")

    def test_unsafe_platform_fails_closed(self):
        self.note("inside.md", "Recallmarker inside.\n")
        for attribute, value in (("supports_dir_fd", set()), ("supports_fd", set()),
                                 ("O_NOFOLLOW", 0), ("O_DIRECTORY", 0), ("O_NONBLOCK", 0)):
            with self.subTest(attribute=attribute), mock.patch.object(RECALL.os, attribute, value):
                with self.assertRaisesRegex(ValueError, "requires.*descriptor"):
                    RECALL.load_project(self.vault, "demo", 500, 4)

    def test_note_limit_is_explicit_and_non_markdown_is_ignored(self):
        self.note("a.md", "# Alpha\nRecallmarker first.\n")
        self.note("b.md", "# Beta\nRecallmarker second.\n")
        self.note("artifact.txt", "Recallmarker is not a note.\n")
        data = self.run_cli("Recallmarker", "--max-notes", "1")
        self.assertFalse(data["scope_complete"])
        self.assertEqual(data["notes_scanned"], 1)
        self.assertEqual(len(data["matches"]), 1)
        self.assertFalse(data["relations_complete"])

    def test_query_input_is_literal_and_empty_queries_abstain(self):
        self.note("a.md", "# Objective\nCapsule objective selection.\n")
        for query in ("zzquux987", "why did we", '" OR * : ()'):
            with self.subTest(query=query):
                data = self.run_cli(query)
                self.assertEqual(data["status"], "not_found")
                self.assertEqual(data["matches"], [])
        for args in (("--limit", "0"), ("--limit", "-1"), ("--max-depth", "-1"),
                     ("--max-notes", "0")):
            self.run_cli("objective", *args, expected=2)


    def test_note_level_supersession_reaches_body_and_flags_ambiguous_links(self):
        self.note("old.md", "---\nstatus: superseded\n---\n# Previous\n"
                  "## Result\nAmber capsule wins.\n")
        self.note("new.md", "---\nsupersedes:\n  - '[[old]]'\n---\n# Replacement\n"
                  "## Observation\nThe comparison used incompatible configurations.\n")
        data = self.run_cli("Amber capsule", "--limit", "1")
        self.assertTrue(data["relations_complete"])
        self.assertTrue(any("incompatible configurations" in x["excerpt"]
                            for x in data["linked_evidence"]))
        self.note("a/duplicate.md", "# Dup\nOne.\n")
        self.note("b/duplicate.md", "# Dup\nTwo.\n")
        self.note("ambiguous.md", "# Correction\n- **Corrects:** [[duplicate]]\n"
                  "- **Superseded-by:** [[Notes/other/not-here]]\n")
        data = self.run_cli("Amber capsule", "--limit", "1")
        self.assertFalse(data["relations_complete"])
        self.assertEqual(len(data["unresolved_links"]), 2)

    def test_same_note_correction_and_fenced_example_are_distinct(self):
        self.note("study.md", "# Study\n### 2026-01-01 — COMPLETED\n"
                  "- **Checkpoint ID:** 20260101T000000Z-aaaaaaaa\n"
                  "- **Observation:** Amber capsule wins.\n"
                  "```markdown\n### fake heading\n- **Corrects:** [[missing]]\n```\n"
                  "### 2026-01-02 — CORRECTION\n"
                  "- **Checkpoint ID:** 20260102T000000Z-bbbbbbbb\n"
                  "- **Corrects:** [[#^20260101T000000Z-aaaaaaaa]]\n"
                  "- **Observation:** Result withdrawn.\n")
        data = self.run_cli("Amber capsule", "--limit", "1")
        self.assertTrue(data["relations_complete"])
        self.assertEqual(data["linked_evidence"][0]["checkpoint_id"],
                         "20260102T000000Z-bbbbbbbb")


    def test_short_reads_recover_later_correction_before_reporting_complete(self):
        text = ("# Old\n- **Checkpoint ID:** 20260101T000000Z-aaaaaaaa\n"
                "Amber capsule wins.\n" + "Background.\n" * 10
                + "# Correction\n- **Checkpoint ID:** 20260102T000000Z-bbbbbbbb\n"
                "- **Corrects:** [[#20260101T000000Z-aaaaaaaa]]\n"
                "The ranking was invalid; grids differed.\n")
        self.note("study.md", text)
        real_fdopen = os.fdopen
        reads, handles = [], []

        def short_fdopen(*args, **kwargs):
            handle = real_fdopen(*args, **kwargs)
            handles.append(handle)
            original_read = handle.read

            def short_read(size):
                content = original_read(min(size, 81))
                reads.append(len(content))
                return content

            handle.read = short_read
            return handle

        with mock.patch.object(RECALL.os, "fdopen", short_fdopen):
            data = RECALL.recall(self.vault, "demo", "Amber capsule", 1)
        self.assertTrue(all(handle.closed for handle in handles))
        self.assertTrue(data["scope_complete"])
        self.assertTrue(data["relations_complete"])
        self.assertEqual(data["matches"][0]["checkpoint_id"], "20260101T000000Z-aaaaaaaa")
        self.assertEqual([item["checkpoint_id"] for item in data["linked_evidence"]],
                         ["20260102T000000Z-bbbbbbbb"])
        self.assertIn("grids differed", data["linked_evidence"][0]["excerpt"])
        self.assertEqual(sum(reads), len(text.encode("utf-8")))
        self.assertEqual(reads[-1], 0, "only an empty read establishes EOF")

    def test_excerpt_budget_keeps_the_match_and_reports_clipping(self):
        text = "# Long result\n" + "background\n" * 600 + "Needlequux decisive evidence.\n"
        self.note("long.md", text)
        data = self.run_cli("Needlequux", "--max-chars", "800")
        item = data["matches"][0]
        self.assertIn("Needlequux", item["excerpt"])
        self.assertLessEqual(len(item["excerpt"]), 800)
        self.assertTrue(item["excerpt_truncated"])
        lines = text.splitlines()[item["line_start"] - 1:item["line_end"]]
        lines[-1] = lines[-1][:item["column_end"] - 1]
        lines[0] = lines[0][item["column_start"] - 1:]
        self.assertEqual(item["excerpt"], "\n".join(lines))

    def test_stemmed_match_positions_excerpt_at_actual_source_token(self):
        text = ("# Long result\n" + "background\n" * 600
                + "Optimization improved the synthetic objective.\n" + "aftermath\n" * 600)
        self.note("long.md", text)
        data = self.run_cli("optimize", "--max-chars", "800")
        item = data["matches"][0]
        self.assertIn("Optimization", item["excerpt"])
        self.assertLessEqual(len(item["excerpt"]), 800)
        self.assertTrue(item["excerpt_truncated"])
        lines = text.splitlines()[item["line_start"] - 1:item["line_end"]]
        lines[-1] = lines[-1][:item["column_end"] - 1]
        lines[0] = lines[0][item["column_start"] - 1:]
        self.assertEqual(item["excerpt"], "\n".join(lines))

    def test_relation_cycles_and_output_limits_are_explicit(self):
        self.note("seed.md", "---\nsuperseded-by: '[[n0]]'\n---\n# Seed\nNeedlequux.\n")
        for i in range(45):
            target = f"n{i + 1}" if i < 44 else "seed"
            self.note(f"n{i}.md", f"---\nsuperseded-by: '[[{target}]]'\n---\n# Follow-up {i}\nEvidence.\n")
        data = self.run_cli("Needlequux", "--limit", "1", "--max-chars", "800")
        self.assertFalse(data["relations_complete"])
        self.assertEqual(data["status"], "partial")
        all_items = data["matches"] + data["linked_evidence"]
        self.assertLessEqual(len(all_items), 40)
        self.assertLessEqual(sum(len(x["excerpt"]) for x in all_items), 800)
        self.assertTrue(data["warnings"])

    def test_reads_fresh_files_and_never_writes_a_cache(self):
        path = self.note("mutable.md", "# Result\nNeedlequux first.\n")
        before = {p.relative_to(self.vault): p.read_bytes() for p in self.vault.rglob("*") if p.is_file()}
        self.assertEqual(self.run_cli("Needlequux")["status"], "ok")
        after = {p.relative_to(self.vault): p.read_bytes() for p in self.vault.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        path.write_text("# Result\nChanged subject.\n")
        self.assertEqual(self.run_cli("Needlequux")["status"], "not_found")
        path.unlink()
        self.assertEqual(self.run_cli("Needlequux")["status"], "not_found")

    def test_existing_resolver_and_installed_skill_symlinks(self):
        self.note("a.md", "# Result\nNeedlequux evidence.\n")
        for agent in ("claude", "codex"):
            installed = Path(self.tmp.name) / f".{agent}/skills/research-notes"
            installed.parent.mkdir(parents=True)
            installed.symlink_to(SCRIPT.parent.parent, target_is_directory=True)
            env = {**os.environ, "ERGODIC_RESEARCH_VAULT": str(self.vault)}
            result = subprocess.run([sys.executable, str(installed / "scripts/recall.py"),
                                     "--project", "demo", "--query", "Needlequux"],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["status"], "ok")

    def test_unreadable_and_oversized_notes_report_partial(self):
        self.note("good.md", "# Result\nNeedlequux evidence.\n")
        bad = self.note("bad.md", "unused")
        bad.write_bytes(b"\xff\xfe")
        self.note("big.md", "x" * (1024 * 1024 + 1))
        data = self.run_cli("Needlequux")
        self.assertEqual(data["status"], "partial")
        self.assertFalse(data["scope_complete"])
        self.assertEqual(data["notes_scanned"], 1)


    def test_rejected_oversized_notes_cannot_exceed_total_read_budget(self):
        for i in range(17):
            self.note(f"big-{i:02}.md", "x" * (1024 * 1024 + 1))
        real_fdopen = os.fdopen
        reads, handles = [], []

        def counted_fdopen(*args, **kwargs):
            handle = real_fdopen(*args, **kwargs)
            handles.append(handle)
            original_read = handle.read

            def counted_read(size):
                content = original_read(min(size, 81))
                reads.append((size, len(content)))
                return content

            handle.read = counted_read
            return handle

        with mock.patch.object(RECALL.os, "fdopen", counted_fdopen):
            data = RECALL.recall(self.vault, "demo", "x", 5)
        self.assertTrue(all(handle.closed for handle in handles))
        budget = 16 * 1024 * 1024
        self.assertEqual(sum(actual for _, actual in reads), budget)
        remaining = budget
        for requested, actual in reads:
            self.assertLessEqual(requested, remaining)
            remaining -= actual
        self.assertEqual(data["notes_scanned"], 0, "a budget-clipped note is not a complete note")
        self.assertFalse(data["scope_complete"])
        self.assertFalse(data["relations_complete"])
        self.assertTrue(any("read budget" in warning for warning in data["warnings"]))

    def test_section_budget_stops_parsing_before_building_excess_chunks(self):
        for name in ("a.md", "b.md"):
            self.note(name, "".join(f"## Section {i}\nBackground.\n" for i in range(6000)))
        self.note("c.md", "## Excluded\nNeedlequux outside the section budget.\n")
        real_sections = RECALL.sections
        produced = 0
        parsed = []

        def counted_sections(path, *args, **kwargs):
            nonlocal produced
            parsed.append(path.name)
            for chunk in real_sections(path, *args, **kwargs):
                produced += 1
                yield chunk

        with mock.patch.object(RECALL, "sections", counted_sections):
            data = RECALL.recall(self.vault, "demo", "Needlequux", 5)
        self.assertEqual(produced, 10000)
        self.assertEqual(parsed, ["a.md", "b.md"])
        self.assertEqual(data["matches"], [])
        self.assertFalse(data["scope_complete"])
        self.assertFalse(data["relations_complete"])
        self.assertIn("section limit reached", data["warnings"])

    def test_checkpoint_metadata_ignores_fenced_examples_and_keeps_note_date(self):
        self.note("meta.md", "---\nupdated: '2026-01-02'\nstatus: blocked\n---\n"
                  "# Metadata\n```md\n- **Checkpoint ID:** fake-id\n```\n"
                  "Needlequux is only a note-level observation.\n")
        data = self.run_cli("Needlequux")
        item = data["matches"][0]
        self.assertIsNone(item["checkpoint_id"])
        self.assertIsNone(item["recorded_at"])
        self.assertEqual(item["note_updated"], "2026-01-02")
        self.assertEqual(item["note_status"], "blocked")


if __name__ == "__main__":
    unittest.main()
