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
    wait_for_guest_result,
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
    @unittest.skipUnless(shutil.which("powershell.exe"), "Windows PowerShell 5.1 (powershell.exe) is absent")
    def test_production_independent_observer_publishes_exit_after_launch_shell_returns(self):
        from unittest.mock import Mock

        def local_ssh(script, *, timeout_seconds):
            encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
            result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
                                    text=True, capture_output=True, timeout=timeout_seconds, check=False)
            if result.returncode:
                raise RunFault("ssh-child", result.stderr, result.returncode)
            return result

        with tempfile.TemporaryDirectory(prefix="ticket569 observer ") as directory:
            root = Path(directory)
            guest = root / "case"
            guest.mkdir()
            launcher = root / "launch-user.ps1"
            launcher.write_text("param([string] $RunRoot)\nStart-Sleep -Seconds 15\nexit 7\n")
            child = subprocess.Popen(["powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(launcher), "-RunRoot", str(guest)])
            handoff = Mock()
            handoff.ssh.side_effect = local_ssh
            try:
                attached = start_guest_process_observer(handoff, child.pid, str(launcher),
                    str(Path(__file__).resolve().parent / "process-observer.ps1"), str(guest), process_timeout_seconds=30)
                # The powershell.exe that performed Win32_Process.Create has returned before the target exits.
                exited = wait_for_guest_process_exit(handoff, child.pid, str(guest), attached["CreationFileTimeUtc"], timeout_seconds=40)
                self.assertEqual(exited["ExitCode"], 7)
                self.assertTrue((guest / "launcher-process-observer-launch.json").is_file())
                self.assertFalse(Path(str(guest) + ".process-observer").exists())
            finally:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)

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
        self.assertIn("Invoke-CimMethod -ClassName Win32_Process -MethodName Create", command)
        self.assertNotIn("Start-Process", command)
        self.assertIn("-File C:\\work\\process-observer.ps1", command)
        self.assertIn("-TimeoutSeconds 270", command)
        self.assertIn("-ExpectedRunId case", command)
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

    def test_timeout_archives_receipts_and_stops_only_the_owned_observer_identity(self):
        from unittest.mock import Mock

        handoff = Mock()
        with self.assertRaisesRegex(RunFault, "did not record exit"):
            wait_for_guest_process_exit(handoff, 123, r"C:\work\case", 8, timeout_seconds=0)
        cleanup = handoff.ssh.call_args.args[0]
        self.assertIn("launcher-process-observer-launch.json", cleanup)
        self.assertIn("$p.CommandLine -cne $owned.CommandLine", cleanup)
        self.assertIn("-ne $owned.CreationFileTimeUtc", cleanup)
        self.assertIn("Stop-Process -Id $owned.PID", cleanup)
        self.assertNotIn("Stop-Process -Id 123", cleanup)
        self.assertIn("Copy-Item", cleanup)


class GuestResultConsentTests(unittest.TestCase):
    def test_owned_removal_request_is_bound_to_ca_phase_and_live_child_before_consent(self):
        from unittest.mock import Mock, patch

        ca = {"commonName": "Ticket 569 synthetic CA case", "sha1": "A" * 40}
        request = {"RunId": "case", "Phase": "delete", "PID": 3448, "Subject": "CN=" + ca["commonName"],
                   "Thumbprint": ca["sha1"], "CreationFileTimeUtc": 134039520000000000}
        live = {"CommandLine": r"powershell.exe -File C:\work\remove-run-certificate.ps1 -RunRoot C:\work\case",
                "CreationFileTimeUtc": request["CreationFileTimeUtc"]}
        changes = ({}, {"RunId": "another"}, {"Phase": "install"}, {"Thumbprint": "B" * 40}, {"Subject": "CN=another"})
        for change in changes:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                handoff, cua = Mock(), Mock()
                cua.acknowledge_certificate_prompt.return_value = True
                handoff.ssh.side_effect = [Mock(stdout=json.dumps(dict(request, **change))),
                    Mock(stdout=json.dumps(live)), Mock(stdout=json.dumps({"RunId": "case", "ChildExitCode": 1}))]
                with patch("host_backend.read_run_ca_identity", return_value=ca):
                    if change:
                        with self.assertRaisesRegex(RunFault, "not bound"):
                            wait_for_guest_result(handoff, cua, r"C:\work\case", "case", Path(directory) / "trust", timeout_seconds=2)
                        self.assertEqual(cua.acknowledge_certificate_prompt.call_count, 1)  # Only import; DELETE refused.
                    else:
                        result = wait_for_guest_result(handoff, cua, r"C:\work\case", "case", Path(directory) / "trust", timeout_seconds=2)
                        self.assertTrue(result["TrustDeletePromptConfirmed"])
                        self.assertEqual(result["ChildExitCode"], 1)  # Consent cannot turn a failed transaction into success.
                        self.assertEqual(cua.acknowledge_certificate_prompt.call_args.kwargs["expected_pid"], 3448)
                        self.assertEqual(cua.acknowledge_certificate_prompt.call_args.kwargs["operation"], "delete")

    def test_removal_child_reused_pid_is_refused_before_delete_consent(self):
        from unittest.mock import Mock, patch

        ca = {"commonName": "Ticket 569 synthetic CA case", "sha1": "A" * 40}
        request = {"RunId": "case", "Phase": "delete", "PID": 3448, "Subject": "CN=" + ca["commonName"],
                   "Thumbprint": ca["sha1"], "CreationFileTimeUtc": 134039520000000000}
        for live in ({}, {"CommandLine": "another.exe", "CreationFileTimeUtc": request["CreationFileTimeUtc"]},
                     {"CommandLine": r"powershell.exe -File C:\work\remove-run-certificate.ps1 -RunRoot C:\work\case",
                      "CreationFileTimeUtc": request["CreationFileTimeUtc"] + 10001}):
            with self.subTest(live=live), tempfile.TemporaryDirectory() as directory:
                handoff, cua = Mock(), Mock()
                cua.acknowledge_certificate_prompt.return_value = True
                handoff.ssh.side_effect = [Mock(stdout=json.dumps(request)), Mock(stdout=json.dumps(live))]
                with patch("host_backend.read_run_ca_identity", return_value=ca), self.assertRaisesRegex(RunFault, "identity"):
                    wait_for_guest_result(handoff, cua, r"C:\work\case", "case", Path(directory) / "trust", timeout_seconds=2)
                self.assertEqual(cua.acknowledge_certificate_prompt.call_count, 1)


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
