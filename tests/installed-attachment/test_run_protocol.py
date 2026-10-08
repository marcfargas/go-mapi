from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from evidence import RunFault
from run import direct_exit_fields, queue_files, run_launcher_with_archived_logs, terminal_queue_acknowledged, wait_interactive_json


class RunProtocolTests(unittest.TestCase):
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
