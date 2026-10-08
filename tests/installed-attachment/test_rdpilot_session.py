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


if __name__ == "__main__":
    unittest.main()
