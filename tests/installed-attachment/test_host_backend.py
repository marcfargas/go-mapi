import base64
import tempfile
import unittest
import zipfile
import hashlib
import json
from pathlib import Path

from evidence import RunFault
from host_backend import (
    extract_evidence_zip,
    start_guest_process_observer,
    verify_evidence_index,
    wait_for_guest_process_exit,
)


class EvidenceArchiveTests(unittest.TestCase):
    def test_windows_paths_extract_safely(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "evidence.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("normal-01\\fake-final.json", '{"final":true}')
            output = root / "extract"
            extract_evidence_zip(archive, output)
            self.assertEqual((output / "normal-01" / "fake-final.json").read_text(), '{"final":true}')

    def test_traversal_and_absolute_paths_fail(self):
        for name in ("..\\escape.txt", "C:\\escape.txt", "/escape.txt"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = root / "evidence.zip"
                with zipfile.ZipFile(archive, "w") as bundle:
                    bundle.writestr(name, "bad")
                with self.assertRaises(RunFault):
                    extract_evidence_zip(archive, root / "extract")

    def test_downloaded_file_index_detects_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = b"captured bytes"
            (root / "capture.bin").write_bytes(data)
            (root / "evidence-index.json").write_text(
                json.dumps({"SchemaVersion": 1, "Files": [{"Path": "capture.bin", "Length": len(data), "SHA256": hashlib.sha256(data).hexdigest()}]})
            )
            verify_evidence_index(root)
            (root / "capture.bin").write_bytes(b"changed")
            with self.assertRaisesRegex(RunFault, "differ from the downloaded evidence"):
                verify_evidence_index(root)


class GuestProcessObserverTests(unittest.TestCase):
    def test_observer_retains_handle_and_captures_actual_exit(self):
        from unittest.mock import Mock

        handoff = Mock()
        handoff.ssh.return_value = Mock(
            stdout=json.dumps({
                "PID": 123,
                "ProcessName": "powershell.exe",
                "CommandLine": r"powershell -File C:\work\launch-user.ps1 -RunRoot C:\work\case",
                "CreationDateFromHandle": "2026-10-09T00:00:00.0000000Z",
                "CreationFileTimeUtc": 134039520000000000,
                "CimCreationFileTimeUtc": 134039520000000000,
                "HandleRetained": True,
            })
        )
        attached = start_guest_process_observer(
            handoff,
            123,
            r"C:\work\launch-user.ps1",
            r"C:\work\process-observer.ps1",
            r"C:\work\case",
            attach_timeout_seconds=30,
            process_timeout_seconds=270,
        )
        command = handoff.ssh.call_args.args[0]
        self.assertIn("case.process-observer", command)
        self.assertIn("AddSeconds(30)", command)
        observer_command = base64.b64decode(command.split("'-EncodedCommand','", 1)[1].split("')", 1)[0]).decode("utf-16le")
        self.assertIn("-TimeoutSeconds 270", observer_command)
        self.assertIn("-ExpectedRunId 'case'", observer_command)
        self.assertTrue(attached["HandleRetained"])

        handoff.ssh.return_value = Mock(
            stdout=json.dumps({"PID": 123, "ExitCode": 7, "CreationFileTimeUtc": 134039520000000000, "HandleRetained": True})
        )
        exited = wait_for_guest_process_exit(handoff, 123, r"C:\work\case", 134039520000000000)
        self.assertEqual(exited["ExitCode"], 7)

    def test_observer_rejects_mismatch_and_unknown_exit(self):
        from unittest.mock import Mock

        handoff = Mock()
        handoff.ssh.return_value = Mock(
            stdout=json.dumps({"PID": 124, "ProcessName": "powershell.exe", "CommandLine": "launch-user.ps1 case", "CreationDateFromHandle": "x", "CreationFileTimeUtc": 5, "CimCreationFileTimeUtc": 5, "HandleRetained": True})
        )
        with self.assertRaisesRegex(RunFault, "different process"):
            start_guest_process_observer(handoff, 123, "launch-user.ps1", "process-observer.ps1", r"C:\work\case")
        handoff.ssh.return_value = Mock(stdout=json.dumps({"PID": 123, "Error": "observer failed"}))
        with self.assertRaisesRegex(RunFault, "did not prove"):
            wait_for_guest_process_exit(handoff, 123, r"C:\work\case", 5)

    def test_observer_rejects_creation_time_that_does_not_match_retained_handle(self):
        from unittest.mock import Mock

        handoff = Mock()
        handoff.ssh.return_value = Mock(
            stdout=json.dumps({
                "PID": 123,
                "ProcessName": "powershell.exe",
                "CommandLine": r"powershell -File C:\work\launch-user.ps1 -RunRoot C:\work\case",
                "CreationDateFromHandle": "handle-time",
                "CreationFileTimeUtc": 8,
                "CimCreationFileTimeUtc": 10009,
                "HandleRetained": True,
            })
        )
        with self.assertRaisesRegex(RunFault, "different process"):
            start_guest_process_observer(
                handoff, 123, r"C:\work\launch-user.ps1", r"C:\work\process-observer.ps1", r"C:\work\case"
            )

    def test_observer_exit_must_match_retained_handle_creation_identity(self):
        from unittest.mock import Mock

        handoff = Mock()
        handoff.ssh.return_value = Mock(
            stdout=json.dumps({"PID": 123, "ExitCode": 0, "CreationFileTimeUtc": 9, "HandleRetained": True})
        )
        with self.assertRaisesRegex(RunFault, "did not prove"):
            wait_for_guest_process_exit(handoff, 123, r"C:\work\case", 8)


if __name__ == "__main__":
    unittest.main()
