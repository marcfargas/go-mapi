from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

from evidence import RunFault, finalize_result, read_final_snapshot, run_bounded
from run import latch_matrix_cleanup


class EvidenceContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_child_nonzero_propagates_actual_exit(self) -> None:
        with self.assertRaises(RunFault) as caught:
            run_bounded(
                [sys.executable, "-c", "raise SystemExit(7)"],
                cwd=self.root,
                timeout_seconds=3,
                stdout_path=self.root / "child.out",
                stderr_path=self.root / "child.err",
            )
        self.assertEqual(caught.exception.kind, "child-failure")
        self.assertEqual(caught.exception.returncode, 7)

    def test_child_timeout_kills_and_records_exit(self) -> None:
        with self.assertRaises(RunFault) as caught:
            run_bounded(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                cwd=self.root,
                timeout_seconds=0.1,
                stdout_path=self.root / "timeout.out",
                stderr_path=self.root / "timeout.err",
            )
        self.assertEqual(caught.exception.kind, "timeout")
        self.assertIsNotNone(caught.exception.returncode)

    def test_cleanup_failure_overrides_success(self) -> None:
        result = finalize_result(
            primary_error=None,
            cleanup=lambda: (_ for _ in ()).throw(OSError("owned resource remains")),
        )
        self.assertIsNotNone(result)
        self.assertEqual(result.kind, "cleanup-failure")

    def test_missing_and_truncated_results_fail_closed(self) -> None:
        with self.assertRaises(RunFault) as missing:
            read_final_snapshot(self.root / "missing.json", "run-1")
        self.assertEqual(missing.exception.kind, "missing-result")
        path = self.root / "truncated.json"
        path.write_text("{", encoding="utf-8")
        with self.assertRaises(RunFault) as truncated:
            read_final_snapshot(path, "run-1")
        self.assertEqual(truncated.exception.kind, "invalid-result")

    def test_final_result_rejects_late_duplicate_and_rejection(self) -> None:
        value = {
            "schemaVersion": 1,
            "runId": "run-1",
            "final": True,
            "requests": 3,
            "draftAttempts": 2,
            "acceptedDrafts": 1,
            "rejectedRequests": 1,
            "failed": True,
            "errors": ["late duplicate"],
            "drafts": [{"attachments": []}],
        }
        path = self.root / "late.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        with self.assertRaises(RunFault) as caught:
            read_final_snapshot(path, "run-1")
        self.assertEqual(caught.exception.kind, "fake-failure")

    def test_profile_restore_failure_overrides_matrix_pass(self) -> None:
        report = self.root / "matrix-final.json"
        report.write_text(json.dumps({"passed": True, "candidateVHD": "pass"}), encoding="utf-8")
        with self.assertRaisesRegex(RunFault, "normal profile restoration failed"):
            latch_matrix_cleanup(
                self.root,
                ["normal profile restoration failed"],
                "mounted",
                guest_evidence_collected=True,
            )
        self.assertFalse(json.loads(report.read_text(encoding="utf-8"))["passed"])
        cleanup = json.loads((self.root / "cleanup.json").read_text(encoding="utf-8"))
        self.assertFalse(cleanup["Completed"])
        self.assertTrue(cleanup["GuestEvidenceCollected"])


if __name__ == "__main__":
    unittest.main()
