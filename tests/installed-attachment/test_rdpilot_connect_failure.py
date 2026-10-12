"""A failed rdpilot connect must keep rdpilot's own diagnostic and still fail the run."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import host_backend  # noqa: E402
from evidence import RunFault  # noqa: E402
from host_backend import Handoff  # noqa: E402

BUNDLE_ERROR = (
    "error: bundle-unavailable: cua-driver cua-driver-rs-v0.34.1 windows x86_64: checksum entry missing; "
    "fixes: -o CuaVersion=<tag>, bundle_path, network access\n"
)


class RdpilotConnectFailureTests(unittest.TestCase):
    def test_exit_9_keeps_stderr_in_evidence_and_fault(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            tmp = Path(temp)
            handoff = Handoff(tmp / "status.json", "guest", 22, "u", tmp / "key", tmp / "kh", "crabbox-user",
                              tmp / "pw", "cbx_fixture00")
            evidence = tmp / "cua-session-1"
            failed = subprocess.CompletedProcess(["rdpilot"], 9, "", BUNDLE_ERROR)
            with patch.object(host_backend.subprocess, "run", return_value=failed) as run:
                with self.assertRaises(RunFault) as caught:
                    handoff.rdpilot_connect("ticket569-test", 57301, evidence)
            self.assertEqual(run.call_args.args[0][:2], ["rdpilot", "connect"])
            self.assertEqual(caught.exception.kind, "rdp-reconnect")
            self.assertEqual(caught.exception.returncode, 9)
            self.assertIn("bundle-unavailable", str(caught.exception))
            log = evidence / "rdpilot-connect-ticket569-test.log"
            self.assertEqual(log.read_text(encoding="utf-8"), BUNDLE_ERROR)

    def test_success_still_writes_connect_log(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            tmp = Path(temp)
            handoff = Handoff(tmp / "status.json", "guest", 22, "u", tmp / "key", tmp / "kh", "crabbox-user",
                              tmp / "pw", "cbx_fixture00")
            ok = subprocess.CompletedProcess(["rdpilot"], 0, "connected\n", "")
            with patch.object(host_backend.subprocess, "run", return_value=ok):
                handoff.rdpilot_connect("ticket569-test", 57301, tmp / "s")
            self.assertEqual((tmp / "s" / "rdpilot-connect-ticket569-test.log").read_text(encoding="utf-8"), "connected\n")

    def test_timeout_keeps_partial_output_without_inventing_exit(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            tmp = Path(temp)
            handoff = Handoff(tmp / "status.json", "guest", 22, "u", tmp / "key", tmp / "kh", "crabbox-user",
                              tmp / "pw", "cbx_fixture00")
            evidence = tmp / "cua-session-1"
            # subprocess.run's TimeoutExpired carries bytes even in text mode.
            expired = subprocess.TimeoutExpired(["rdpilot"], 120, output=b"session ticket569-test live\n",
                                                stderr=b"bootstrapping Cua bridge...\n")
            with patch.object(host_backend.subprocess, "run", side_effect=expired):
                with self.assertRaises(RunFault) as caught:
                    handoff.rdpilot_connect("ticket569-test", 57301, evidence)
            self.assertEqual(caught.exception.kind, "rdp-reconnect")
            self.assertIsNone(caught.exception.returncode)
            self.assertIn("TimeoutExpired", str(caught.exception))
            self.assertIn("bootstrapping Cua bridge", str(caught.exception))
            self.assertEqual((evidence / "rdpilot-connect-ticket569-test.log").read_text(encoding="utf-8"),
                             "session ticket569-test live\nbootstrapping Cua bridge...\n")

    def test_timeout_without_output_still_raises(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            tmp = Path(temp)
            handoff = Handoff(tmp / "status.json", "guest", 22, "u", tmp / "key", tmp / "kh", "crabbox-user",
                              tmp / "pw", "cbx_fixture00")
            with patch.object(host_backend.subprocess, "run", side_effect=subprocess.TimeoutExpired(["rdpilot"], 120)):
                with self.assertRaises(RunFault) as caught:
                    handoff.rdpilot_connect("ticket569-test", 57301, tmp / "s")
            self.assertEqual(caught.exception.kind, "rdp-reconnect")
            self.assertIsNone(caught.exception.returncode)
            self.assertEqual((tmp / "s" / "rdpilot-connect-ticket569-test.log").read_text(encoding="utf-8"), "")

    def test_slow_healthy_bootstrap_within_budget_succeeds(self) -> None:
        # An observed healthy cold Cua bootstrap took about 136 s; the default budget must cover it.
        with tempfile.TemporaryDirectory() as temp:
            tmp = Path(temp)
            handoff = Handoff(tmp / "status.json", "guest", 22, "u", tmp / "key", tmp / "kh", "crabbox-user",
                              tmp / "pw", "cbx_fixture00")
            seen: list[float] = []

            def slow_connect(command, **kwargs):
                seen.append(kwargs["timeout"])
                if 136 > kwargs["timeout"]:
                    raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                return subprocess.CompletedProcess(command, 0, "connected ticket569-test; bridge live\n", "")

            with patch.object(host_backend.subprocess, "run", side_effect=slow_connect):
                handoff.rdpilot_connect("ticket569-test", 57301, tmp / "s")
            self.assertEqual(len(seen), 1)
            self.assertEqual((tmp / "s" / "rdpilot-connect-ticket569-test.log").read_text(encoding="utf-8"),
                             "connected ticket569-test; bridge live\n")

    def test_budget_exhaustion_still_raises_timeout_fault(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            tmp = Path(temp)
            handoff = Handoff(tmp / "status.json", "guest", 22, "u", tmp / "key", tmp / "kh", "crabbox-user",
                              tmp / "pw", "cbx_fixture00")

            def hung_connect(command, **kwargs):
                raise subprocess.TimeoutExpired(command, kwargs["timeout"], output=b"", stderr=b"")

            with patch.object(host_backend.subprocess, "run", side_effect=hung_connect) as run:
                with self.assertRaises(RunFault) as caught:
                    handoff.rdpilot_connect("ticket569-test", 57301, tmp / "s")
            self.assertTrue(0 < run.call_args.kwargs["timeout"] <= 300)
            self.assertEqual(caught.exception.kind, "rdp-reconnect")
            self.assertIsNone(caught.exception.returncode)
            self.assertIn("TimeoutExpired", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
