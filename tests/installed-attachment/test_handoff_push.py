"""Exact-file staging through the native crabbox-handoff directory push contract.

The native helper's ``push SOURCES... GUEST_DIR`` creates GUEST_DIR as a directory and copies each source into
it under its local basename. These tests emulate that contract on a local guest tree and run the adapter's
guest PowerShell with the local PowerShell, then assert the resulting guest layout.
"""

from __future__ import annotations

import base64
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import host_backend  # noqa: E402
from evidence import RunFault  # noqa: E402
from host_backend import Handoff  # noqa: E402

POWERSHELL = shutil.which("pwsh") or shutil.which("powershell")
REAL_RUN = subprocess.run
STAGING = "C:\\crabbox\\work\\ticket569\\staging"


@unittest.skipUnless(POWERSHELL, "PowerShell is required to execute the guest staging script")
class HandoffPushLayoutTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.guest = self.tmp / "guest"
        self.guest_path(STAGING).mkdir(parents=True)
        self.native_exit = 0
        self.corrupt = False
        self.native_calls: list[list[str]] = []
        status = self.tmp / "crabbox-handoff-status.json"
        status.write_text("{}", encoding="utf-8")
        self.handoff = Handoff(status, "guest", 22, "u", self.tmp / "key", self.tmp / "kh", "crabbox-user",
                               self.tmp / "pw", "cbx_fixture00")
        patcher = mock.patch.object(host_backend.subprocess, "run", side_effect=self.fake_run)
        patcher.start()
        self.addCleanup(patcher.stop)

    def guest_path(self, windows_path: str) -> Path:
        assert windows_path[:3].upper() == "C:\\"
        return self.guest.joinpath("C", *windows_path[3:].split("\\"))

    def map_script(self, script: str) -> str:
        root = self.guest.as_posix() + "/C/"
        return re.sub(r"(?i)C:\\", lambda _: root, script).replace("\\", "/")

    def fake_run(self, command, **kwargs):
        if command[0] == "crabbox-handoff":
            self.native_calls.append(list(command))
            assert command[1] == "push" and command[2] == "--status-file"
            *sources, guest_dir = command[4:]
            if self.native_exit:
                return subprocess.CompletedProcess(command, self.native_exit, "", "transfer_failed")
            target = self.guest_path(guest_dir)
            target.mkdir(parents=True, exist_ok=True)  # native mkdir_body: New-Item -ItemType Directory -Force
            for source in sources:
                copied = target / Path(source).name  # native scp into "GUEST_DIR/" keeps the local basename
                shutil.copyfile(source, copied)
                if self.corrupt:
                    with copied.open("ab") as handle:
                        handle.write(b"corrupt")
            return subprocess.CompletedProcess(command, 0, "CRABBOX_HANDOFF_PUSHED", "")
        if command[0] == "ssh":
            encoded = command[-1].split()[-1]
            script = self.map_script(base64.b64decode(encoded).decode("utf-16-le"))
            assert POWERSHELL
            return REAL_RUN([POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", script],
                            text=True, capture_output=True, timeout=kwargs.get("timeout"), check=False)
        raise AssertionError(f"unexpected subprocess: {command}")

    def local_file(self, name: str) -> tuple[Path, bytes]:
        data = os.urandom(2048)
        path = self.tmp / "local" / name
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(data)
        return path, data

    def staging_entries(self) -> set[str]:
        return {path.name for path in self.guest_path(STAGING).iterdir()}

    def test_renamed_file_lands_at_exact_guest_path(self) -> None:
        source, data = self.local_file("go-mapi-suite-3.2.0-alpha.10-x64.msi")
        self.handoff.push(source, STAGING + "\\candidate.msi")
        staged = self.guest_path(STAGING + "\\candidate.msi")
        self.assertTrue(staged.is_file())
        self.assertEqual(hashlib.sha256(staged.read_bytes()).digest(), hashlib.sha256(data).digest())
        self.assertEqual(self.staging_entries(), {"candidate.msi"})
        self.assertNotEqual(self.native_calls[0][-1], STAGING + "\\candidate.msi")

    def test_occupied_destination_is_refused_and_preserved(self) -> None:
        source, _ = self.local_file("candidate.msi")
        self.guest_path(STAGING + "\\candidate.msi").write_bytes(b"occupied")
        with self.assertRaises(RunFault) as caught:
            self.handoff.push(source, STAGING + "\\candidate.msi")
        self.assertEqual(caught.exception.kind, "stage-failure")
        self.assertEqual(self.guest_path(STAGING + "\\candidate.msi").read_bytes(), b"occupied")
        self.assertEqual(self.native_calls, [])

    def test_failed_native_transfer_leaves_no_destination(self) -> None:
        source, _ = self.local_file("x.msi")
        self.native_exit = 31
        with self.assertRaises(RunFault):
            self.handoff.push(source, STAGING + "\\candidate.msi")
        self.assertFalse(self.guest_path(STAGING + "\\candidate.msi").exists())

    def test_hash_mismatch_is_not_moved_into_place(self) -> None:
        source, _ = self.local_file("x.msi")
        self.corrupt = True
        with self.assertRaises(RunFault):
            self.handoff.push(source, STAGING + "\\candidate.msi")
        self.assertFalse(self.guest_path(STAGING + "\\candidate.msi").exists())


if __name__ == "__main__":
    unittest.main()
