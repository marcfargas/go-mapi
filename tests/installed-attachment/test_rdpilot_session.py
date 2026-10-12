import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from evidence import RunFault
from rdpilot_session import RdpilotSession


class RdpilotSchemaTests(unittest.TestCase):
    def test_call_uses_advertised_schema_and_persistent_session(self):
        with tempfile.TemporaryDirectory() as directory:
            client = RdpilotSession("session-569", Path(directory))
            client.tools = {
                "list_windows": {
                    "inputSchema": {
                        "additionalProperties": False,
                        "properties": {"session": {"type": "string"}, "on_screen_only": {"type": "boolean"}},
                        "required": [],
                    }
                }
            }
            client._request = Mock(return_value={"result": {"structuredContent": {"windows": []}}})
            result = client.call("list_windows", {"on_screen_only": True})
            self.assertEqual(result["result"]["structuredContent"]["windows"], [])
            self.assertEqual(
                client._request.call_args.args[1],
                {"name": "list_windows", "arguments": {"on_screen_only": True, "session": "session-569"}},
            )

    def test_call_rejects_unadvertised_arguments_and_is_error_results(self):
        with tempfile.TemporaryDirectory() as directory:
            client = RdpilotSession("session-569", Path(directory))
            client.tools = {
                "click": {
                    "inputSchema": {
                        "additionalProperties": False,
                        "properties": {"pid": {"type": "integer"}, "element_token": {"type": "string"}},
                        "required": ["pid", "element_token"],
                    }
                }
            }
            with self.assertRaisesRegex(RunFault, "not in the advertised schema"):
                client.call("click", {"pid": 2, "element_token": "x", "session": "invented"})
            client.tools["click"]["inputSchema"]["properties"]["session"] = {"type": "string"}
            client._request = Mock(return_value={"result": {"isError": True}})
            with self.assertRaisesRegex(RunFault, "isError"):
                client.call("click", {"pid": 2, "element_token": "x"})


RECORDED = Path(__file__).resolve().parent / "fixtures" / "cert788-security-warning.json"


class CertificatePromptReplayTests(unittest.TestCase):
    """Replays the recorded native Security Warning (debug 788) through the production matcher."""

    def setUp(self):
        self.recorded = json.loads(RECORDED.read_text(encoding="utf-8"))
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.window = dict(self.recorded["window"])
        self.state = copy.deepcopy(self.recorded["response"])
        self.extra_windows = []
        self.clicks = []
        self.listed = 0

    def client(self):
        client = RdpilotSession("session-569", Path(self.directory.name))

        def call(name, arguments, timeout_seconds=30):
            if name == "list_windows":
                self.listed += 1
                windows = [self.window, *self.extra_windows] if self.listed == 1 else []
                return {"result": {"structuredContent": {"windows": windows}}}
            if name == "get_window_state":
                if (arguments["pid"], arguments["window_id"]) != (self.window["pid"], self.window["window_id"]):
                    other = copy.deepcopy(self.state)
                    other["result"]["structuredContent"].update(pid=arguments["pid"], window_id=arguments["window_id"])
                    return other
                return copy.deepcopy(self.state)
            if name == "click":
                self.clicks.append(arguments)
                return {"result": {"structuredContent": {"effect": "confirmed", "route": "accessibility"}}}
            raise AssertionError(name)

        client.call = call
        return client

    def acknowledge(self, name=None, sha1=None):
        return self.client().acknowledge_certificate_prompt(
            name or self.recorded["commonName"], sha1 or self.recorded["sha1"], Path(self.directory.name) / "trust-prompt", 2
        )

    def structured(self):
        return self.state["result"]["structuredContent"]

    def test_recorded_prompt_is_acknowledged_by_exact_name_and_thumbprint(self):
        self.assertIs(self.structured()["elements_complete"], False)
        self.assertTrue(self.acknowledge())
        self.assertEqual(self.clicks, [{"pid": 912, "element_token": "s00000001:0"}])
        proof = json.loads((Path(self.directory.name) / "trust-prompt.json").read_text(encoding="utf-8"))
        self.assertEqual(proof["matched"]["sha1"], "B19E69DFA2A866A649D7E07BE7FAC2EEE4767714")
        self.assertIs(proof["observedElementsComplete"], False)

    def test_full_distinguished_name_is_not_an_accepted_identity(self):
        with self.assertRaisesRegex(RunFault, "bare common name"):
            self.acknowledge(name="CN=" + self.recorded["commonName"])
        self.assertEqual(self.clicks, [])

    def test_other_run_name_is_refused(self):
        with self.assertRaisesRegex(RunFault, "not exactly this run CA"):
            self.acknowledge(name="Ticket 569 synthetic CA cert787-interactive-2f76cac21e2b548")
        self.assertEqual(self.clicks, [])

    def test_wrong_thumbprint_is_refused(self):
        with self.assertRaisesRegex(RunFault, "not exactly this run CA"):
            self.acknowledge(sha1="DA1EC660B5AA288571C45A5EA529D5B7F74020D7")
        self.assertEqual(self.clicks, [])

    def test_prompt_without_thumbprint_is_refused(self):
        state = self.structured()
        state["tree_markdown"] = state["tree_markdown"].replace("Thumbprint (sha1): B19E69DF A2A866A6 49D7E07B E7FAC2EE E4767714", "")
        with self.assertRaisesRegex(RunFault, "not exactly this run CA"):
            self.acknowledge()
        self.assertEqual(self.clicks, [])

    def test_truncated_or_pending_snapshot_is_refused(self):
        for change in ({"truncated": True}, {"nodes_pending": 2}, {"truncated": None}, {"returned_element_count": 2}):
            with self.subTest(change=change):
                self.state = copy.deepcopy(self.recorded["response"])
                self.structured().update(change)
                self.listed = 0
                with self.assertRaises(RunFault):
                    self.acknowledge()
        self.assertEqual(self.clicks, [])

    def test_second_exact_prompt_is_ambiguous(self):
        self.extra_windows = [dict(self.window, window_id=590227)]
        with self.assertRaisesRegex(RunFault, "ambiguous|2 on-screen"):
            self.acknowledge()
        self.assertEqual(self.clicks, [])

    def test_missing_or_disabled_yes_is_refused(self):
        self.structured()["elements"][0]["enabled"] = False
        with self.assertRaisesRegex(RunFault, "one enabled Yes"):
            self.acknowledge()
        self.assertEqual(self.clicks, [])

    def test_unrelated_security_warning_is_not_clicked(self):
        self.structured()["tree_markdown"] = '- Window "Security Warning"\n  - [0] Button "Yes"\n  - Text "Run this file?"\n'
        self.assertFalse(self.acknowledge())
        self.assertEqual(self.clicks, [])


class CertificateDeletePromptReplayTests(CertificatePromptReplayTests):
    """The recorded native DELETE prompt is replayed; this does not establish a native removal success."""

    def setUp(self):
        super().setUp()
        self.recorded = json.loads((RECORDED.parent / "cert799-root-delete.json").read_text(encoding="utf-8"))
        self.window = dict(self.recorded["window"])
        self.state = copy.deepcopy(self.recorded["response"])

    def acknowledge(self, name=None, sha1=None, pid=3448, operation="delete"):
        return self.client().acknowledge_certificate_prompt(
            name or self.recorded["commonName"], sha1 or self.recorded["sha1"],
            Path(self.directory.name) / "trust-prompt", 2, operation=operation, expected_pid=pid,
        )

    def test_recorded_prompt_is_acknowledged_by_exact_name_and_thumbprint(self):
        self.assertTrue(self.acknowledge())
        self.assertEqual(self.clicks, [{"pid": 3448, "element_token": "s00000044:0"}])
        proof = json.loads((Path(self.directory.name) / "trust-prompt.json").read_text(encoding="utf-8"))
        self.assertEqual(proof["matched"]["operation"], "delete")

    def test_other_run_name_is_refused(self):
        with self.assertRaisesRegex(RunFault, "not exactly this run CA"):
            self.acknowledge(name=self.recorded["commonName"] + "0")
        self.assertEqual(self.clicks, [])

    def test_prompt_without_thumbprint_is_refused(self):
        state = self.structured()
        state["tree_markdown"] = state["tree_markdown"].replace("Thumbprint (sha1) : D3E8167F 52D009FB 328426EE 81184B2B 2D456603", "")
        with self.assertRaisesRegex(RunFault, "not exactly this run CA"):
            self.acknowledge()
        self.assertEqual(self.clicks, [])

    def test_wrong_removal_child_pid_is_refused(self):
        with self.assertRaisesRegex(RunFault, "exact owned removal child"):
            self.acknowledge(pid=3449)
        self.assertEqual(self.clicks, [])

    def test_delete_verb_cannot_be_used_as_install_consent(self):
        with self.assertRaisesRegex(RunFault, "not exactly this run CA"):
            self.acknowledge(operation="install")
        self.assertEqual(self.clicks, [])

    def test_missing_delete_verb_is_refused(self):
        self.structured()["tree_markdown"] = self.structured()["tree_markdown"].replace("DELETE", "INSTALL")
        with self.assertRaisesRegex(RunFault, "not exactly this run CA"):
            self.acknowledge()
        self.assertEqual(self.clicks, [])


if __name__ == "__main__":
    unittest.main()
