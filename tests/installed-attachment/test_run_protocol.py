from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from evidence import RunFault
from run import (
    cleanup_test_signing_trust,
    direct_exit_fields,
    latch_matrix_cleanup,
    prepare_test_signing_trust,
    queue_files,
    run_launcher_with_archived_logs,
    terminal_queue_acknowledged,
    wait_interactive_json,
)


class RunProtocolTests(unittest.TestCase):
    def test_partial_test_root_prepare_cleans_persisted_owned_state(self) -> None:
        state = {
            "schema": "go-mapi-azure-test-root-fixture-v1",
            "certificateSha256": "41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e",
            "store": "LocalMachine/Root",
            "thumbprint": "0123456789ABCDEF",
            "preexisting": False,
            "importAttempted": True,
            "imported": False,
        }
        state_output = Mock(stdout=json.dumps(state))
        inventory_output = Mock(stdout=json.dumps({"StatePresent": True, "RootPresentAfterCleanup": False}))
        handoff = Mock()
        handoff.ssh.side_effect = [
            RunFault("ssh", "Prepare failed after persisting ownership"),
            state_output,
            state_output,
            Mock(stdout="owned root removed"),
            state_output,
            inventory_output,
        ]
        progress: dict[str, object] = {"stateExpected": False}

        with self.assertRaisesRegex(RunFault, "Prepare failed after persisting ownership"):
            prepare_test_signing_trust(
                handoff,
                r"C:\\source\\trust.ps1",
                r"C:\\work\\azure-test-root.json",
                [r"C:\\staging\\baseline.msi", r"C:\\staging\\candidate.msi"],
                progress,
            )
        self.assertTrue(progress["stateExpected"])
        cleaned, _ = cleanup_test_signing_trust(
            handoff,
            r"C:\\source\\trust.ps1",
            r"C:\\work\\azure-test-root.json",
            state_expected=bool(progress["stateExpected"]),
        )
        self.assertTrue(cleaned["cleanup"]["StatePresent"])
        self.assertFalse(cleaned["cleanup"]["RootPresentAfterCleanup"])
        self.assertIn("-Mode 'Cleanup'", handoff.ssh.call_args_list[3].args[0])

    def test_pre_mutation_test_root_prepare_failure_needs_no_cleanup(self) -> None:
        handoff = Mock()
        handoff.ssh.side_effect = [
            RunFault("ssh-child", "Prepare child exited before ownership state", returncode=1),
            Mock(stdout="TICKET569_PENDING"),
            Mock(stdout="TICKET569_PENDING"),
        ]
        progress: dict[str, object] = {"stateExpected": False}

        with self.assertRaisesRegex(RunFault, "Prepare child exited before ownership state"):
            prepare_test_signing_trust(
                handoff,
                r"C:\\source\\trust.ps1",
                r"C:\\work\\azure-test-root.json",
                [r"C:\\staging\\baseline.msi"],
                progress,
            )
        self.assertFalse(progress["stateExpected"])
        cleanup, _ = cleanup_test_signing_trust(
            handoff,
            r"C:\\source\\trust.ps1",
            r"C:\\work\\azure-test-root.json",
            state_expected=bool(progress["stateExpected"]),
        )
        self.assertFalse(cleanup["cleanup"]["CleanupNeeded"])
        self.assertEqual(handoff.ssh.call_count, 3)

    def test_transport_loss_with_absent_state_remains_uncertain_and_latches_failure(self) -> None:
        uncertain_faults = (
            RunFault("ssh-transport", "bounded SSH command failed: TimeoutExpired"),
            RunFault("ssh-child", "SSH child exited 255", returncode=255),
            RunFault("ssh-child", "SSH child terminated by signal", returncode=-9),
        )
        for primary in uncertain_faults:
            with self.subTest(kind=primary.kind, returncode=primary.returncode):
                handoff = Mock()
                handoff.ssh.side_effect = [
                    primary,
                    Mock(stdout="TICKET569_PENDING"),
                    Mock(stdout="TICKET569_PENDING"),
                    Mock(stdout=json.dumps({"StatePresent": False, "PinnedRootPresent": True, "MatchingThumbprints": ["0123"]})),
                ]
                progress: dict[str, object] = {"stateExpected": False}
                with self.assertRaises(RunFault):
                    prepare_test_signing_trust(
                        handoff,
                        r"C:\\source\\trust.ps1",
                        r"C:\\work\\azure-test-root.json",
                        [r"C:\\staging\\baseline.msi"],
                        progress,
                    )
                self.assertTrue(progress["stateExpected"])

                primary_failure = {
                    "fault": primary.kind,
                    "message": str(primary),
                    "returncode": primary.returncode,
                }
                with tempfile.TemporaryDirectory() as directory:
                    evidence = Path(directory)
                    primary_path = evidence / "matrix-primary-failure.json"
                    primary_path.write_text(json.dumps(primary_failure), encoding="utf-8")
                    with self.assertRaisesRegex(RunFault, "established test-root ownership state is missing") as cleanup_error:
                        cleanup_test_signing_trust(
                            handoff,
                            r"C:\\source\\trust.ps1",
                            r"C:\\work\\azure-test-root.json",
                            state_expected=bool(progress["stateExpected"]),
                        )
                    with self.assertRaises(RunFault) as completion:
                        latch_matrix_cleanup(
                            evidence,
                            [str(cleanup_error.exception)],
                            "normal",
                            True,
                            primary_failure=primary_failure,
                        )
                    self.assertEqual(completion.exception.kind, "matrix-cleanup")
                    self.assertIn(str(primary), str(completion.exception))
                    self.assertEqual(json.loads(primary_path.read_text(encoding="utf-8")), primary_failure)
                    cleanup = json.loads((evidence / "cleanup.json").read_text(encoding="utf-8"))
                    self.assertFalse(cleanup["Completed"])
                    self.assertEqual(cleanup["PrimaryFailure"], primary_failure)
                    self.assertIn('"PinnedRootPresent": true', cleanup["Errors"][0])

    def test_preexisting_test_root_survives_cleanup(self) -> None:
        state = {
            "schema": "go-mapi-azure-test-root-fixture-v1",
            "certificateSha256": "41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e",
            "store": "LocalMachine/Root",
            "thumbprint": "FEDCBA9876543210",
            "preexisting": True,
            "importAttempted": False,
            "imported": False,
        }
        state_output = Mock(stdout=json.dumps(state))
        handoff = Mock()
        handoff.ssh.side_effect = [
            state_output,
            Mock(stdout="preserved preexisting root"),
            state_output,
            Mock(stdout=json.dumps({"StatePresent": True, "RootPresentAfterCleanup": True})),
        ]

        cleaned, _ = cleanup_test_signing_trust(
            handoff, r"C:\\source\\trust.ps1", r"C:\\work\\azure-test-root.json", state_expected=True
        )
        self.assertTrue(cleaned["state"]["preexisting"])
        self.assertTrue(cleaned["cleanup"]["RootPresentAfterCleanup"])
        self.assertIn("-Mode 'Cleanup'", handoff.ssh.call_args_list[1].args[0])

    def test_lost_established_test_root_state_fails_and_inventories_store(self) -> None:
        handoff = Mock()
        handoff.ssh.side_effect = [
            Mock(stdout="Prepare completed"),
            Mock(stdout="TICKET569_PENDING"),
            Mock(stdout="TICKET569_PENDING"),
            Mock(stdout=json.dumps({"StatePresent": False, "PinnedRootPresent": True, "MatchingThumbprints": ["0123"]})),
        ]
        progress: dict[str, object] = {"stateExpected": False}
        _, state = prepare_test_signing_trust(
            handoff,
            r"C:\\source\\trust.ps1",
            r"C:\\work\\azure-test-root.json",
            [r"C:\\staging\\baseline.msi"],
            progress,
        )
        self.assertIsNone(state)
        self.assertTrue(progress["stateExpected"])

        with self.assertRaisesRegex(RunFault, "established test-root ownership state is missing") as caught:
            cleanup_test_signing_trust(
                handoff,
                r"C:\\source\\trust.ps1",
                r"C:\\work\\azure-test-root.json",
                state_expected=bool(progress["stateExpected"]),
            )
        self.assertIn('"PinnedRootPresent": true', str(caught.exception))
        self.assertIn("Get-ChildItem", handoff.ssh.call_args_list[3].args[0])
        self.assertNotIn("-Mode 'Cleanup'", handoff.ssh.call_args_list[3].args[0])

    def test_truncated_established_test_root_state_fails_closed(self) -> None:
        handoff = Mock()
        handoff.ssh.return_value = Mock(stdout='{"schema":')
        with self.assertRaisesRegex(RunFault, "guest JSON file is malformed"):
            cleanup_test_signing_trust(
                handoff,
                r"C:\\source\\trust.ps1",
                r"C:\\work\\azure-test-root.json",
                state_expected=True,
            )
        self.assertEqual(handoff.ssh.call_count, 1)
        self.assertNotIn("-Mode 'Cleanup'", handoff.ssh.call_args.args[0])

    def test_test_root_cleanup_failure_latches_aggregate_and_preserves_primary_evidence(self) -> None:
        state = {
            "schema": "go-mapi-azure-test-root-fixture-v1",
            "certificateSha256": "41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e",
            "store": "LocalMachine/Root",
            "thumbprint": "0123456789ABCDEF",
            "preexisting": False,
            "importAttempted": True,
            "imported": True,
        }
        state_output = Mock(stdout=json.dumps(state))
        handoff = Mock()
        handoff.ssh.side_effect = [
            state_output,
            RunFault("ssh", "certificate store cleanup access denied"),
            state_output,
            Mock(stdout=json.dumps({"StatePresent": True, "RootPresentAfterCleanup": True})),
        ]
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            primary_report = {
                "passed": True,
                "primaryError": {"fault": "candidate-setup", "message": "installer verification failed"},
                "primaryEvidence": "setup-candidate/install.json",
            }
            (evidence / "matrix-final.json").write_text(json.dumps(primary_report), encoding="utf-8")
            with self.assertRaisesRegex(RunFault, "test-root cleanup helper failed") as caught:
                cleanup_test_signing_trust(
                    handoff,
                    r"C:\\source\\trust.ps1",
                    r"C:\\work\\azure-test-root.json",
                    state_expected=True,
                )
            with self.assertRaises(RunFault) as cleanup_fault:
                latch_matrix_cleanup(
                    evidence,
                    [str(caught.exception)],
                    "normal",
                    True,
                    primary_failure={"fault": "candidate-setup", "message": "installer verification failed"},
                )
            self.assertEqual(cleanup_fault.exception.kind, "matrix-cleanup")
            self.assertIn("installer verification failed", str(cleanup_fault.exception))
            report = json.loads((evidence / "matrix-final.json").read_text(encoding="utf-8"))
            cleanup = json.loads((evidence / "cleanup.json").read_text(encoding="utf-8"))
            self.assertFalse(report["passed"])
            self.assertEqual(report["primaryError"], primary_report["primaryError"])
            self.assertEqual(report["primaryEvidence"], primary_report["primaryEvidence"])
            self.assertEqual(report["primaryFailure"]["message"], "installer verification failed")
            self.assertFalse(cleanup["Completed"])
            self.assertEqual(cleanup["PrimaryFailure"]["fault"], "candidate-setup")
            self.assertIn("certificate store cleanup access denied", cleanup["Errors"][0])

    def test_direct_exit_report_names_launcher_and_child_without_claiming_python_exit(self) -> None:
        exits = direct_exit_fields(interactive_launcher_exit=7, transaction_child_exit=9)
        self.assertEqual(exits, {"interactiveLauncherExit": 7, "transactionChildExit": 9})
        self.assertNotIn("hostEntrypointExit", exits)

    def test_wait_interactive_json_polls_until_result_is_written(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "identity.json"
            handoff = Mock()
            handoff.ssh.side_effect = [
                Mock(stdout="TICKET569_PENDING"),
                Mock(stdout=json.dumps({"SID": "S-1-5-21-1-2-3-4"})),
            ]
            with patch("run.time.sleep") as sleep:
                value = wait_interactive_json(handoff, Mock(), "C:\\identity.json", output)
            self.assertEqual(value["SID"], "S-1-5-21-1-2-3-4")
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), value)
            sleep.assert_called_once_with(0.5)

    def test_queue_protocol_requires_lowercase_files_array(self) -> None:
        self.assertEqual(queue_files({"files": []}), [])
        with self.assertRaisesRegex(RunFault, "files array"):
            queue_files({"Files": []})

    def test_terminal_queue_ack_requires_same_entry_created_and_deleted(self) -> None:
        self.assertTrue(
            terminal_queue_acknowledged(
                {
                    "files": [],
                    "terminalAcknowledgement": True,
                    "events": ["Created|message-1.json", "Deleted|message-1.json"],
                }
            )
        )
        self.assertFalse(
            terminal_queue_acknowledged(
                {
                    "files": [],
                    "terminalAcknowledgement": True,
                    "events": ["Created|message-1.json", "Deleted|message-2.json"],
                }
            )
        )

    def test_host_logs_stay_outside_fresh_run_root_until_child_exit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            run_root = parent / "candidate-123456789abc"
            run_root.mkdir()
            command = [
                sys.executable,
                "-c",
                "import pathlib,sys; root=pathlib.Path(sys.argv[1]); raise SystemExit(0 if not any(root.iterdir()) else 9)",
                str(run_root),
            ]
            result = run_launcher_with_archived_logs(
                command,
                cwd=parent,
                run_root=run_root,
                timeout_seconds=3,
                require_success=True,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual({path.name for path in run_root.iterdir()}, {"host.stdout.txt", "host.stderr.txt"})
            self.assertFalse(any(path.name.startswith(".candidate-123456789abc.host-") for path in parent.iterdir()))


if __name__ == "__main__":
    unittest.main()
