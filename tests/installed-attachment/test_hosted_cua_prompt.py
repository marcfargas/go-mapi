import asyncio
import base64
import contextlib
import io
import json
import os
import tempfile
import hashlib
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from hosted_cua_prompt import PromptFault, prompt_button, prompt_click_arguments, prompt_matches, run, run_service, validate_schema


class PromptMatchTests(unittest.TestCase):
    def test_requires_exact_certificate_identity_and_root_consent(self):
        window = {"accessibility_tree": {"text": "Add Certificate Ticket569 unique, thumbprint 0123 4567 89AB CDEF to Root store?"}}
        self.assertTrue(prompt_matches(window, "Ticket569 unique", "0123456789ABCDEF"))
        self.assertFalse(prompt_matches(window, "Ticket569 other", "0123456789ABCDEF"))
        self.assertFalse(prompt_matches(window, "Ticket569 unique", "FFFFFFFFFFFFFFFF"))
        self.assertFalse(prompt_matches({"text": "Install Ticket569 unique 0123456789ABCDEF certificate?"}, "Ticket569 unique", "0123456789ABCDEF"))
        removal = {"text": "Remove Ticket569 unique 0123 4567 89AB CDEF from CurrentUser Root?"}
        self.assertTrue(prompt_matches(removal, "Ticket569 unique", "0123456789ABCDEF", action="remove"))
        self.assertFalse(prompt_matches(removal, "Ticket569 unique", "0123456789ABCDEF", action="import"))

    def test_selects_only_unique_enabled_affirmative_button_from_snapshot(self):
        snapshot = {"text": "Add Certificate Ticket569 unique, thumbprint 0123 4567 89AB CDEF to Root store?", "elements": [
            {"role": "button", "label": "Yes", "enabled": True, "element_token": "s00000001:2"},
            {"role": "button", "label": "No", "enabled": True, "element_token": "s00000001:3"},
        ]}
        self.assertEqual(prompt_button(snapshot, "Ticket569 unique", "0123456789ABCDEF"), "s00000001:2")
        snapshot["elements"].append({"role": "button", "label": "Install", "enabled": True, "element_token": "s00000001:4"})
        self.assertIsNone(prompt_button(snapshot, "Ticket569 unique", "0123456789ABCDEF"))
        self.assertIsNone(prompt_button({"elements": [{"role": "button", "label": "Yes", "enabled": False, "element_token": "s00000001:2"}]}, "Ticket569 unique", "0123456789ABCDEF"))
        remove = {"text": "Remove Ticket569 unique 0123456789ABCDEF from CurrentUser Root?", "elements": [
            {"role": "button", "label": "Yes", "enabled": True, "element_token": "s00000001:5"},
            {"role": "button", "label": "No", "enabled": True, "element_token": "s00000001:6"},
        ]}
        self.assertEqual(prompt_button(remove, "Ticket569 unique", "0123456789ABCDEF", action="remove"), "s00000001:5")

    def test_main_parser_accepts_the_owner_importer_argument_contract(self):
        from hosted_cua_prompt import main

        argv = [
            "--service", "--bin-dir", "C:/rdpilot/bin", "--expected-name", "Ticket569 unique",
            "--expected-sid", "S-1-5-21-1", "--expected-session-id", "7", "--run-id", "a" * 32,
            "--source-sha", "b" * 40, "--supervisor-pipe", "Ticket569-" + "a" * 32 + "-helper",
            "--thumbprint", "0" * 40, "--certificate-path", "C:/cert.cer", "--import-script", "C:/import.ps1",
            "--import-result", "C:/result.json", "--observer-script", "C:/observer.ps1",
            "--observer-attached", "C:/attached.json", "--observer-exit", "C:/exit.json",
            "--observer-failure", "C:/failure.json", "--evidence", "C:/evidence.json",
            "--job-start-counter", "100", "--counter-frequency", "1000",
            "--runtime-root", "C:/runtime", "--session-name", "ticket569", "--prompt-timeout", "30",
            "--close-timeout", "10", "--child-timeout", "120",
        ]
        captured = []
        with patch("hosted_cua_prompt.asyncio.run", side_effect=lambda coroutine: (coroutine.close(), captured.append(coroutine), 0)[2]):
            self.assertEqual(main(argv), 0)
        self.assertEqual(len(captured), 1)

    def test_mcp_arguments_are_checked_against_advertised_schema(self):
        schema = {
            "type": "object", "additionalProperties": False,
            "required": ["target"], "properties": {
                "target": {"oneOf": [
                    {"type": "object", "required": ["kind", "pid", "window_id"], "properties": {"kind": {"const": "window"}, "pid": {"type": "integer"}, "window_id": {"type": "integer"}}},
                    {"type": "object", "required": ["kind", "display_id"], "properties": {"kind": {"const": "desktop"}, "display_id": {"type": "string"}}},
                ]}
            },
        }
        validate_schema(schema, {"target": {"kind": "window", "pid": 42, "window_id": 17}})
        for arguments in (
            {},
            {"target": {"kind": "window", "pid": 42}},
            {"target": {"kind": "desktop", "display_id": "primary"}, "unadvertised": True},
        ):
            with self.subTest(arguments=arguments), self.assertRaises(PromptFault):
                validate_schema(schema, arguments)

    def test_prompt_click_is_bound_to_observed_process_and_window(self):
        self.assertEqual(prompt_click_arguments({
            "pid": 42, "windowId": 17, "affirmativeElementToken": "s00000001:2",
        }), {"pid": 42, "window_id": 17, "element_token": "s00000001:2"})


class PromptServiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_run_observes_and_answers_exact_owned_removal_dialog(self):
        class FakeMcp:
            def __init__(self, states):
                self.proc = SimpleNamespace(returncode=None)
                self.states = iter(states)
                self.clicks = []

            async def tool(self, name, arguments=None):
                if name == "launch_app":
                    return {"structuredContent": {"pid": 123, "running": True}}
                if name == "list_windows":
                    return {"structuredContent": {"windows": [{"pid": 42, "window_id": 17}]}}
                if name == "get_window_state":
                    state = next(self.states)
                    return {"structuredContent": state, "content": [{"type": "image", "mimeType": "image/png",
                                                                       "data": base64.b64encode(b"png-fixture:" + json.dumps(state).encode()).decode()}]}
                if name == "click":
                    self.clicks.append(arguments)
                    return {"clicked": True}
                raise AssertionError(name)

        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            runtime = root_path / "runtime"
            runtime.mkdir()
            binary_dir = root_path / "bin"
            binary_dir.mkdir()
            (binary_dir / ("rdpilot-mcp.exe" if os.name == "nt" else "rdpilot-mcp")).write_bytes(b"fixture")
            for name in ("import.ps1", "observer.ps1", "cert.cer"):
                (root_path / name).write_text("fixture", encoding="utf-8")
            paths = {name: root_path / name for name in (
                "result.json", "attached.json", "exit.json", "failure.json", "evidence.json")}
            child_pid, creation = 501, 123456789
            child = {"schema": "ticket569-currentuser-root-import-v1", "runId": "a" * 32,
                     "sid": "S-1-5-21-1", "sessionId": 7, "userFlag": True,
                     "store": "CurrentUser/Root", "thumbprint": "0" * 40,
                     "passed": True, "addedObserved": True, "removedObserved": True,
                     "processCreationFileTimeUtc": creation, "processId": child_pid}
            paths["result.json"].write_text(json.dumps(child), encoding="utf-8")
            attached = {"HandleRetained": True, "PID": child_pid, "CreationFileTimeUtc": creation}
            exited = {"HandleRetained": True, "PID": child_pid, "CreationFileTimeUtc": creation, "ExitCode": 0}
            paths["attached.json"].write_text(json.dumps(attached), encoding="utf-8")
            paths["exit.json"].write_text(json.dumps(exited), encoding="utf-8")
            add = {"text": "Add certificate Ticket569 unique 0000000000000000000000000000000000000000 to CurrentUser Root?",
                   "elements": [{"role": "button", "label": "Yes", "enabled": True, "element_token": "add-yes"}]}
            closed = {"text": "Desktop", "elements": []}
            remove = {"text": "Remove certificate Ticket569 unique 0000000000000000000000000000000000000000 from CurrentUser Root?",
                      "elements": [{"role": "button", "label": "Yes", "enabled": True, "element_token": "remove-yes"}]}
            mcp = FakeMcp([add, closed, remove, closed])
            args = SimpleNamespace(
                bin_dir=str(binary_dir), runtime_root=str(runtime), session_name="ticket569",
                evidence=str(paths["evidence.json"]), import_script=str(root_path / "import.ps1"),
                run_id="a" * 32, expected_sid="S-1-5-21-1", source_sha="b" * 40,
                supervisor_pipe="Ticket569-" + "a" * 32 + "-helper", expected_session_id=7,
                certificate_path=str(root_path / "cert.cer"), thumbprint="0" * 40,
                expected_name="Ticket569 unique", import_result=str(paths["result.json"]),
                observer_script=str(root_path / "observer.ps1"), observer_attached=str(paths["attached.json"]),
                observer_exit=str(paths["exit.json"]), observer_failure=str(paths["failure.json"]),
                job_start_counter=100, counter_frequency=1000,
                prompt_timeout=2, close_timeout=2, child_timeout=2,
            )
            code = await run(args, mcp_override=mcp, retain_mcp=True)
            evidence = json.loads(paths["evidence.json"].read_text(encoding="utf-8"))
            self.assertEqual(code, 0, evidence)
            self.assertTrue(evidence["removalConsentObserved"])
            self.assertTrue(evidence["removalConsentAnswered"])
            self.assertTrue(evidence["removalPromptClosed"])
            self.assertEqual([click["element_token"] for click in mcp.clicks], ["add-yes", "remove-yes"])
            captures = [evidence["observation"]["screenshotEvidence"], evidence["removalObservation"]["screenshotEvidence"]]
            self.assertNotEqual(captures[0]["path"], captures[1]["path"])
            self.assertNotEqual(captures[0]["sha256"], captures[1]["sha256"])
            for capture in captures:
                self.assertEqual(hashlib.sha256(Path(capture["path"]).read_bytes()).hexdigest(), capture["sha256"])

            # Same real run() branch with a killed importer: no successful
            # post-cleanup result exists, while the retained observer exited137.
            paths["result.json"].unlink()
            exited["ExitCode"] = 137
            paths["exit.json"].write_text(json.dumps(exited), encoding="utf-8")
            args.child_timeout = 0
            killed_mcp = FakeMcp([add, closed])
            code = await run(args, mcp_override=killed_mcp, retain_mcp=True)
            killed = json.loads(paths["evidence.json"].read_text(encoding="utf-8"))
            self.assertEqual(code, 1)
            self.assertEqual(killed["status"], "harness-defect")
            self.assertEqual(killed["fault"], "the exact user/session CurrentUser Root child did not publish a successful post-cleanup result")
            self.assertTrue(killed["answerIssued"])
            self.assertTrue(killed["promptClosed"])
            self.assertFalse(killed["removalConsentObserved"])
            self.assertNotIn("importChild", killed)
            self.assertTrue(killed["sessionOwnerRetained"])

    async def test_service_keeps_one_mcp_session_between_bounded_commands(self):
        class FakeMcp:
            def __init__(self, binary, session, env, evidence):
                self.proc = SimpleNamespace(returncode=None)
                self.stopped = False

            async def start(self):
                return {"serverInfo": {"name": "test-cua"}}

            async def stop(self):
                self.stopped = True

            async def tool(self, name, arguments=None):
                if name == "list_windows":
                    return {"structuredContent": {"windows": []}}
                raise AssertionError(name)

        with tempfile.TemporaryDirectory() as root:
            runtime = Path(root) / "runtime-root"
            runtime.mkdir()
            evidence = Path(root) / "prompt.json"
            args = SimpleNamespace(bin_dir=root, runtime_root=str(runtime),
                                   session_name="ticket569", evidence=str(evidence), expected_name="fixture", thumbprint="0" * 40, close_timeout=1)
            commands = io.StringIO('{"op":"status"}\n{"op":"run"}\n{"op":"status"}\n{"op":"stop"}\n')
            output = io.StringIO()
            started = []

            async def fake_run(received_args, mcp_override=None, retain_mcp=False):
                started.append((received_args, mcp_override, retain_mcp))
                evidence.write_text(json.dumps({"status": "observed-and-answered"}), encoding="utf-8")
                return 0

            with patch("hosted_cua_prompt.Mcp", FakeMcp), \
                 patch("hosted_cua_prompt.run", fake_run), \
                 patch("hosted_cua_prompt.sys.stdin", commands), \
                 contextlib.redirect_stdout(output):
                self.assertEqual(await run_service(args), 0)

            messages = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual([message["op"] for message in messages], ["ready", "status", "result", "status", "stopped"])
            self.assertTrue(messages[1]["mcpAlive"])
            self.assertTrue(messages[3]["mcpAlive"])
            self.assertEqual(messages[2]["result"]["status"], "observed-and-answered")
            self.assertEqual(len(started), 1)
            self.assertIs(started[0][0], args)
            self.assertTrue(started[0][2], "the prompt operation must retain the owner-owned MCP child")

    async def test_failed_prompt_retains_removal_watcher_and_success_evidence(self):
        class FakeMcp:
            def __init__(self, *args):
                self.proc = SimpleNamespace(returncode=None)
            async def start(self):
                return {"serverInfo": {"name": "fixture"}}
            async def stop(self):
                pass
            async def tool(self, name, args=None):
                return {}
        class DelayedCommands:
            def __init__(self):
                self.count = 0
            def readline(self):
                import time
                self.count += 1
                if self.count == 1:
                    return '{"op":"run"}\n'
                time.sleep(.08)
                return '{"op":"stop"}\n'
        with tempfile.TemporaryDirectory() as root:
            runtime = Path(root) / "runtime"
            runtime.mkdir()
            evidence = Path(root) / "prompt.json"
            args = SimpleNamespace(bin_dir=root, runtime_root=str(runtime), session_name="fixture", evidence=str(evidence), expected_name="unique", thumbprint="0"*40, close_timeout=1)
            observed = []
            async def failed_run(*args, **kwargs):
                evidence.write_text(json.dumps({"status": "harness-defect", "observation": {"retained": True}}))
                return 1
            async def observe(*args, **kwargs):
                observed.append(kwargs.get("action"))
                return {"status": "not-unique", "candidateCount": 0}
            with patch("hosted_cua_prompt.Mcp", FakeMcp), patch("hosted_cua_prompt.run", failed_run), patch("hosted_cua_prompt.observe_once", observe), patch("hosted_cua_prompt.sys.stdin", DelayedCommands()), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(await run_service(args), 0)
            self.assertIn("remove", observed)
            self.assertTrue(json.loads(evidence.read_text())["observation"]["retained"])

    async def test_status_remains_responsive_while_watcher_runs_and_watcher_error_ends_service(self):
        import threading

        class FakeMcp:
            def __init__(self, *args):
                self.proc = SimpleNamespace(returncode=None)
                self.stopped = False
            async def start(self):
                return {"serverInfo": {"name": "fixture"}}
            async def stop(self):
                self.stopped = True

        class Commands:
            def __init__(self, fail):
                self.lines = iter(['{"op":"run"}\n', '{"op":"status"}\n'])
                self.fail = fail
            def readline(self):
                import time
                try:
                    line = next(self.lines)
                    if 'status' in line:
                        self.assert_watch_started()
                    return line
                except StopIteration:
                    time.sleep(.7 if self.fail else .05)
                    return '{"op":"stop"}\n'
            def assert_watch_started(self):
                if not watching.wait(2):
                    raise AssertionError("watcher did not begin after the prompt run")

        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as root:
                watching = threading.Event()
                runtime = Path(root) / "runtime"
                runtime.mkdir()
                evidence = Path(root) / "prompt.json"
                args = SimpleNamespace(bin_dir=root, runtime_root=str(runtime), session_name="fixture", evidence=str(evidence), expected_name="unique", thumbprint="0" * 40, close_timeout=1)
                order = []
                async def failed_run(*args, **kwargs):
                    order.append("run-returned")
                    evidence.write_text(json.dumps({"status": "harness-defect"}))
                    return 1
                async def observe(*args, **kwargs):
                    self.assertEqual(order[0], "run-returned")
                    watching.set()
                    if fail:
                        raise PromptFault("watcher fault adapter")
                    return {"status": "not-unique", "candidateCount": 0}
                output = io.StringIO()
                with patch("hosted_cua_prompt.Mcp", FakeMcp), patch("hosted_cua_prompt.run", failed_run), patch("hosted_cua_prompt.observe_once", observe), patch("hosted_cua_prompt.sys.stdin", Commands(fail)), contextlib.redirect_stdout(output):
                    if fail:
                        with self.assertRaisesRegex(PromptFault, "watcher fault adapter"):
                            await run_service(args)
                    else:
                        self.assertEqual(await run_service(args), 0)
                messages = [json.loads(line) for line in output.getvalue().splitlines()]
                self.assertEqual([m["op"] for m in messages[:2]], ["ready", "result"])
                if not fail:
                    self.assertEqual(messages[2]["op"], "status")
                    self.assertTrue(messages[2]["mcpAlive"])

    async def test_recovery_watch_only_never_launches_or_rewrites_import_evidence(self):
        class FakeMcp:
            def __init__(self, *args):
                self.proc = SimpleNamespace(returncode=None)
            async def start(self):
                return {"serverInfo": {"name": "fixture"}}
            async def stop(self):
                pass
            async def tool(self, name, args=None):
                if name == "launch_app":
                    raise AssertionError("removal-only service launched an importer")
                return {}
        class DelayedCommands:
            count = 0
            def readline(self):
                import time
                self.count += 1
                if self.count == 1:
                    return '{"op":"watch-removal"}\n'
                time.sleep(.08)
                return '{"op":"stop"}\n'
        with tempfile.TemporaryDirectory() as root:
            runtime = Path(root) / "runtime"
            runtime.mkdir()
            evidence = Path(root) / "prompt.json"
            original = b'{"status":"observed-and-answered","retainedImport":true}\n'
            evidence.write_bytes(original)
            args = SimpleNamespace(bin_dir=root, runtime_root=str(runtime), session_name="fixture",
                                   evidence=str(evidence), expected_name="unique", thumbprint="0"*40, close_timeout=1)
            observed = []
            async def observe(*args, **kwargs):
                observed.append(kwargs.get("action"))
                return {"status": "not-unique", "candidateCount": 0}
            output = io.StringIO()
            with patch("hosted_cua_prompt.Mcp", FakeMcp), patch("hosted_cua_prompt.observe_once", observe), \
                 patch("hosted_cua_prompt.run", side_effect=AssertionError("must not replay import")), \
                 patch("hosted_cua_prompt.sys.stdin", DelayedCommands()), contextlib.redirect_stdout(output):
                self.assertEqual(await run_service(args), 0)
            messages = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(messages[1], {"op": "watching-removal", "importerLaunched": False})
            self.assertIn("remove", observed)
            self.assertEqual(evidence.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
