"""An early matrix failure must reach the matrix finally block, keep its primary fault and latch cleanup."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import run  # noqa: E402
from baseline_identity import ALPHA7  # noqa: E402
from evidence import RunFault  # noqa: E402

SOURCE_SHA = "d" * 40


class FakeHandoff:
    lease_id = "cbx_fixture00"

    def __init__(self) -> None:
        self.scripts: list[str] = []
        self.pushed: list[str] = []

    def ssh(self, script: str, *, timeout_seconds: float = 120) -> subprocess.CompletedProcess[str]:
        self.scripts.append(script)
        if "azure-alpha7-test-trust.ps1" in script and "-Mode 'Prepare'" in script:
            raise RunFault("ssh-child", "SSH/PowerShell child exited 1", 1)
        if "TICKET569_PENDING" in script:
            return subprocess.CompletedProcess(["ssh"], 0, "TICKET569_PENDING\n", "")
        return subprocess.CompletedProcess(["ssh"], 0, "", "")

    def push(self, source: Path, remote_path: str, *, timeout_seconds: float = 300) -> None:
        self.pushed.append(remote_path)


class MatrixEarlyFailureTests(unittest.TestCase):
    def test_alpha7_trust_prepare_failure_runs_finally_cleanup_and_latch(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            tmp = Path(temp)
            portable = tmp / "portable"
            portable.mkdir()
            (portable / "SHA256SUMS").write_text("x", encoding="utf-8")
            inputs = tmp / "input.bin"
            inputs.write_bytes(b"x")
            evidence = tmp / "evidence"
            evidence.mkdir()
            archive = evidence / "source.zip"
            archive.write_bytes(b"zip")
            digest = "a" * 64
            args = argparse.Namespace(
                source_sha=SOURCE_SHA, evidence_dir=evidence, handoff_status=tmp / "status.json",
                cua_session="ticket569-test", rdp_port=3389,
                baseline_msi=inputs, baseline_release_api=inputs, baseline_validation=inputs,
                baseline_manifest=inputs, baseline_targets=inputs, baseline_app_artifacts=inputs,
                baseline_portable_evidence=portable, baseline_msi_sha256=ALPHA7["msiSHA256"],
                baseline_app_sha256=digest, baseline_dll_sha256=digest,
                candidate_msi=inputs, candidate_msi_sha256=digest, candidate_app_sha256=digest,
                candidate_dll_sha256=digest, webview_bootstrapper=inputs, webview_sha256=digest,
                remote_work_root=r"C:\crabbox\work\ticket569", case_timeout_seconds=240,
            )
            handoff = FakeHandoff()
            collected: list[str] = []

            def fake_collect(_handoff, remote_root, _remote_zip, local_root):
                collected.append(remote_root)
                return "collected"

            with patch.object(run, "validate_alpha7_assets", return_value={"kind": "fixture"}), \
                 patch.object(run, "validate_alpha7_portable_evidence", return_value={"fixture": True}), \
                 patch.object(run, "prepare_crabbox_inputs", return_value=(archive, digest, evidence)), \
                 patch.object(run.Handoff, "load", return_value=handoff), \
                 patch.object(run, "build_fake", side_effect=lambda _root, dest: dest.write_bytes(b"fake")), \
                 patch.object(run, "collect_guest_run", side_effect=fake_collect):
                with self.assertRaises(RunFault) as caught:
                    run.run_crabbox_matrix(args, tmp)

            self.assertEqual(caught.exception.kind, "matrix-cleanup")
            self.assertIn("alpha7-trust-prepare", str(caught.exception))
            primary = json.loads((evidence / "matrix-primary-failure.json").read_text(encoding="utf-8"))
            self.assertEqual(primary["fault"], "alpha7-trust-prepare")
            cleanup = json.loads((evidence / "cleanup.json").read_text(encoding="utf-8"))
            self.assertFalse(cleanup["Completed"])
            self.assertEqual(cleanup["PrimaryFailure"]["fault"], "alpha7-trust-prepare")
            self.assertTrue(cleanup["ProfileRestored"])
            # The unattempted candidate trust is skipped; the attempted alpha.7 trust is inspected and fails closed.
            self.assertTrue(any("Alpha.7 TEST signing trust cleanup failed" in error for error in cleanup["Errors"]))
            self.assertFalse(any("Azure TEST signing trust cleanup" in error for error in cleanup["Errors"]))
            self.assertTrue((evidence / "alpha7-test-root-cleanup.json").is_file())
            self.assertFalse((evidence / "test-root-cleanup.json").exists())
            self.assertEqual(collected, [r"C:\crabbox\work\ticket569\cases"])


if __name__ == "__main__":
    unittest.main()
