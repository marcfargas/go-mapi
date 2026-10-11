"""Debug 777 extractor separators and debug 776 owned-app fixture behavior."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from evidence import RunFault  # noqa: E402
from host_backend import extract_evidence_zip  # noqa: E402

POWERSHELL = shutil.which("pwsh") or shutil.which("powershell")


def build(path: Path, members: list[tuple[str, bytes]]) -> None:
    with zipfile.ZipFile(path, "w") as bundle:
        for name, data in members:
            bundle.writestr(zipfile.ZipInfo(name), data)


class EvidenceArchiveTests(unittest.TestCase):
    def extract(self, members: list[tuple[str, bytes]]) -> Path:
        temp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp, True)
        build(temp / "cases.zip", members)
        extract_evidence_zip(temp / "cases.zip", temp / "out")
        return temp / "out"

    def test_windows_backslash_empty_directory_tree_extracts(self) -> None:
        # Shape observed in 775: Compress-Archive empty queue directories with backslash separators.
        out = self.extract([
            ("case\\queue-final\\", b""), ("case\\cleanup.json", b"{}"),
            ("case\\queue-final\\errors\\", b""), ("case\\queue-final\\processed\\", b""),
        ])
        self.assertTrue((out / "case" / "queue-final" / "errors").is_dir())
        self.assertTrue((out / "case" / "queue-final" / "processed").is_dir())
        self.assertEqual((out / "case" / "cleanup.json").read_bytes(), b"{}")

    def rejected(self, members: list[tuple[str, bytes]]) -> None:
        with self.assertRaises(RunFault):
            self.extract(members)

    def test_directory_member_with_data_is_rejected(self) -> None:
        self.rejected([("case\\queue-final\\", b"x")])

    def test_unsafe_paths_and_overwrite_remain_rejected(self) -> None:
        self.rejected([("..\\escape.txt", b"x")])
        self.rejected([("C:\\Windows\\x.txt", b"x")])
        self.rejected([("\\abs.txt", b"x")])
        self.rejected([("case\\a.txt", b"1"), ("case\\a.txt", b"2")])
        self.rejected([("case\\a", b"1"), ("case\\a\\", b"")])


@unittest.skipUnless(POWERSHELL, "PowerShell is required for the owned-app fixture behavior checks")
class OwnedAppFixtureTests(unittest.TestCase):
    def test_owned_fixture_behavior(self) -> None:
        assert POWERSHELL
        result = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-File", str(HERE / "owned-app-fixture-tests.ps1")],
                                text=True, capture_output=True, timeout=120, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OWNED_APP_FIXTURE_TESTS_PASSED", result.stdout)


if __name__ == "__main__":
    unittest.main()
