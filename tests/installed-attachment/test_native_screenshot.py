"""The launcher-observer failure screenshot is best-effort and must never replace the original fault."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import host_backend  # noqa: E402


class NativeScreenshotTests(unittest.TestCase):
    def test_success_records_exit_and_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "frame.png"

            def shot(command, **kwargs):
                self.assertEqual(command, ["rdpilot", "screenshot", "--session", "s1", "--output", str(out)])
                out.write_bytes(b"png")
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch.object(host_backend.subprocess, "run", side_effect=shot):
                receipt = host_backend.capture_native_screenshot("s1", out)
            self.assertEqual((receipt["exit"], receipt["captured"]), (0, True))

    def test_failure_and_timeout_never_raise(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "frame.png"
            failed = subprocess.CompletedProcess(["rdpilot"], 2, "", "error: SessionNotFound")
            with patch.object(host_backend.subprocess, "run", return_value=failed):
                receipt = host_backend.capture_native_screenshot("s1", out)
            self.assertEqual((receipt["exit"], receipt["captured"]), (2, False))
            self.assertIn("SessionNotFound", receipt["stderr"])
            with patch.object(host_backend.subprocess, "run", side_effect=subprocess.TimeoutExpired(["rdpilot"], 30)):
                receipt = host_backend.capture_native_screenshot("s1", out)
            self.assertEqual((receipt["exit"], receipt["error"], receipt["captured"]), (None, "TimeoutExpired", False))


if __name__ == "__main__":
    unittest.main()
