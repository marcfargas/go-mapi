"""Real-file admission controls; installed-app security and live readiness remain separate."""

import shutil
import subprocess
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
POWERSHELL = shutil.which("powershell.exe") or shutil.which("pwsh")


@unittest.skipUnless(POWERSHELL, "PowerShell is required for public admission file controls")
class PublicAdmissionTests(unittest.TestCase):
    def test_real_byte_readiness_and_bounded_failures(self):
        result = subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-File", str(HERE / "public-admission-tests.ps1")],
            text=True, capture_output=True, timeout=30, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "PUBLIC_ADMISSION_BYTE_CONTROL_PASSED;CLOCK_AND_SCM_ADAPTED_FULL_PRODUCTION_ADMISSION_UNRUN",
            result.stdout,
        )


if __name__ == "__main__":
    unittest.main()
