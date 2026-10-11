"""The alpha.7 TEST root helper's exact identity pin must accept the actual pinned public certificate."""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts" / "azure-alpha7-test-trust.ps1"
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "microsoft-identity-verification-test-only-root-2020.crt"
POWERSHELL = shutil.which("pwsh") or shutil.which("powershell")


def pinned(name: str) -> str:
    match = re.search(rf"^\${name} = '([^']*)'$", HELPER.read_text(encoding="utf-8"), re.MULTILINE)
    assert match, name
    return match.group(1)


class Alpha7TrustPinTests(unittest.TestCase):
    def test_fixture_is_the_pinned_root_bytes(self) -> None:
        self.assertEqual(hashlib.sha256(FIXTURE.read_bytes()).hexdigest(), pinned("sha256Pinned"))

    @unittest.skipUnless(POWERSHELL, "PowerShell is required to read X509 identity fields")
    def test_helper_identity_predicate_accepts_actual_pinned_certificate(self) -> None:
        # The same fields and case-sensitive comparisons as the helper's Prepare identity check.
        quoted = "'" + str(FIXTURE).replace("'", "''") + "'"
        script = (
            f"$c=[Security.Cryptography.X509Certificates.X509Certificate2]::new({quoted});"
            "[ordered]@{Thumbprint=$c.Thumbprint;Subject=$c.Subject;Issuer=$c.Issuer} | ConvertTo-Json -Compress"
        )
        assert POWERSHELL
        result = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", script],
                                text=True, capture_output=True, timeout=60, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        fields = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(fields["Thumbprint"], pinned("sha1Pinned"))
        self.assertEqual(fields["Subject"], pinned("subjectPinned"))
        self.assertEqual(fields["Subject"], fields["Issuer"])


if __name__ == "__main__":
    unittest.main()
