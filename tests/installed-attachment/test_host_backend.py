import base64
import tempfile
import unittest
import zipfile
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

from evidence import RunFault
from host_backend import (
    extract_evidence_zip,
    read_run_ca_identity,
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


class RunCaIdentityTests(unittest.TestCase):
    """The prompt identity comes from this run's published public CA, bound to its ready fake (debug 788)."""

    def setUp(self):
        from unittest.mock import Mock

        recorded = json.loads((Path(__file__).resolve().parent / "fixtures" / "cert788-security-warning.json").read_text(encoding="utf-8"))
        self.publication = dict(recorded["publication"])
        self.handoff = Mock()
        self.run_id = "cert787-interactive-2f76cac21e2b548d"
        self.sha1 = recorded["sha1"]

    def read(self, run_id=None):
        from unittest.mock import Mock

        self.handoff.ssh.return_value = Mock(stdout=json.dumps(self.publication))
        return read_run_ca_identity(self.handoff, r"C:\run\x", run_id or self.run_id)

    def test_recorded_public_ca_yields_the_thumbprint_windows_displayed(self):
        identity = self.read()
        self.assertEqual(identity["sha1"], self.sha1)
        self.assertEqual(identity["commonName"], "Ticket 569 synthetic CA " + self.run_id)

    def test_ca_not_published_by_this_runs_fake_is_refused(self):
        ready = json.loads(self.publication["ready"])
        ready["caThumbprintSHA256"] = "0" * 64
        self.publication["ready"] = json.dumps(ready)
        with self.assertRaisesRegex(RunFault, "not the CA published"):
            self.read()

    def test_other_run_is_refused(self):
        with self.assertRaisesRegex(RunFault, "not the CA published"):
            self.read(run_id="cert787-identical-5635c8a800f35edf")

    def test_private_key_or_extra_certificate_is_refused(self):
        for extra in ("-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----\n", self.publication["pem"]):
            with self.subTest(extra=extra[:20]):
                self.publication["pem"] = self.publication["pem"].split("-----END CERTIFICATE-----")[0] + "-----END CERTIFICATE-----\n" + extra
                with self.assertRaisesRegex(RunFault, "malformed"):
                    self.read()

    def test_pending_publication_is_none(self):
        from unittest.mock import Mock

        self.handoff.ssh.return_value = Mock(stdout="TICKET569_PENDING\n")
        self.assertIsNone(read_run_ca_identity(self.handoff, r"C:\run\x", self.run_id))

    @unittest.skipUnless(shutil.which("powershell.exe"), "Windows PowerShell 5.1 (powershell.exe) is absent")
    def test_real_windows_powershell_publishes_plain_strings(self):
        """Run the production read script under powershell.exe; Get-Content -Raw strings serialized as objects (debug 793)."""
        from unittest.mock import Mock

        def run_locally(script, *, timeout_seconds):
            encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
            command = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded]
            result = subprocess.run(command, text=True, capture_output=True, timeout=timeout_seconds, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result

        with tempfile.TemporaryDirectory() as root:
            for name, text in (("test-ca.pem", self.publication["pem"]), ("fake-ready.json", self.publication["ready"])):
                Path(root, name).write_text(text, encoding="utf-8", newline="")
            handoff = Mock()
            handoff.ssh.side_effect = run_locally
            identity = read_run_ca_identity(handoff, root, self.run_id)
        self.assertEqual(identity["sha1"], self.sha1)
        self.assertEqual(identity["commonName"], "Ticket 569 synthetic CA " + self.run_id)


if __name__ == "__main__":
    unittest.main()
