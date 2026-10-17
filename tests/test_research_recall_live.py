"""Opt-in, read-only retrieval checks against the team's existing vault.

These check source retrieval, NOT fresh-agent answer quality or current job status.
No vault contents are copied into the repository. Golden source paths are not query inputs.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "skills/research-notes/scripts/recall.py"
VAULT = os.environ.get("RECALL_EVAL_VAULT")


@unittest.skipUnless(VAULT, "set RECALL_EVAL_VAULT to opt into private-vault checks")
class LiveRecallTests(unittest.TestCase):
    def recall(self, query):
        result = subprocess.run([sys.executable, str(SCRIPT), "--vault", VAULT,
                                 "--project", "lagradept", "--query", query],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertTrue(data["scope_complete"], data["warnings"])
        self.assertTrue(data["requires_live_verification"])
        return data

    def test_derivative_free_decision_rationale(self):
        # Ground truth: this note's "Optimization protocol after the pilot" section.
        data = self.recall("Why did we choose derivative-free optimization?")
        path = "Notes/lagradept/2026-09-16-201009-ludwig-batch-optimization-pilot-560755f3.md"
        self.assertTrue(any(item["path"] == path and "gradient checks" in item["excerpt"]
                            and "did not pass" in item["excerpt"] for item in data["matches"]))

    def test_failed_attempt_is_not_reported_as_success(self):
        # Ground truth: this note's Outcome section (historical, not live status).
        data = self.recall("What blocked the execution-to-result path: undiagnosed container failure?")
        path = "Notes/lagradept/2026-09-16-212827-ludwig-batch-loop-resumption-fd56b58f.md"
        self.assertTrue(any(item["path"] == path and "No optimization improvement was measured"
                            in item["excerpt"] for item in data["matches"]))

    def test_unknown_identifier_returns_no_evidence(self):
        data = self.recall("What is zzunknowncalibration987xyz?")
        self.assertEqual(data["matches"], [])
        self.assertEqual(data["linked_evidence"], [])


if __name__ == "__main__":
    unittest.main()
