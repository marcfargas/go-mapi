"""Persistent, schema-checked rdpilot-mcp client for the live CUA session."""

from __future__ import annotations

import json
import base64
import re
import selectors
import subprocess
import time
from pathlib import Path
from typing import Any

from evidence import RunFault


class RdpilotSession:
    """Own one persistent MCP stdio process and use only its advertised schemas."""

    def __init__(self, session: str, evidence_dir: Path, command: str = "rdpilot-mcp"):
        if not session or any(ch.isspace() for ch in session):
            raise RunFault("cua-session", "CUA session name must be a nonempty token")
        self.session = session
        self.evidence_dir = evidence_dir
        self.command = command
        self.process: subprocess.Popen[bytes] | None = None
        self._next_id = 0
        self._selector: selectors.BaseSelector | None = None
        self._stderr_file: Any = None
        self._call_index = 0
        self.tools: dict[str, dict[str, Any]] = {}

    def start(self, timeout_seconds: float = 30) -> None:
        if self.process is not None:
            raise RunFault("cua-session", "persistent CUA session is already started")
        self.evidence_dir.mkdir(parents=True, exist_ok=True)
        self._stderr_file = (self.evidence_dir / "rdpilot-mcp.stderr.log").open("ab")
        try:
            self.process = subprocess.Popen(
                [self.command, "--session", self.session],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self._stderr_file,
                bufsize=0,
            )
            assert self.process.stdin and self.process.stdout
            self._selector = selectors.DefaultSelector()
            self._selector.register(self.process.stdout, selectors.EVENT_READ)
            initialized = self._request(
                "initialize",
                {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "go-mapi-installed-attachment", "version": "1"},
                },
                timeout_seconds,
            )
            self._raise_rpc_error(initialized, "MCP initialize")
            self._notify({"jsonrpc": "2.0", "method": "notifications/initialized"})
            listed = self._request("tools/list", {}, timeout_seconds)
            self._raise_rpc_error(listed, "MCP tools/list")
            tools = listed.get("result", {}).get("tools")
            if not isinstance(tools, list):
                raise RunFault("cua-schema", "rdpilot-mcp tools/list returned no tool array")
            self.tools = {tool["name"]: tool for tool in tools if isinstance(tool, dict) and isinstance(tool.get("name"), str)}
            required = {"list_windows", "get_window_state", "click"}
            if missing := required - self.tools.keys():
                raise RunFault("cua-schema", f"rdpilot-mcp lacks required tools: {sorted(missing)}")
            schema_file = self.evidence_dir / "rdpilot-tools.json"
            schema_file.write_text(json.dumps(listed, indent=2) + "\n", encoding="utf-8")
        except BaseException:
            self.close()
            raise

    def _notify(self, value: dict[str, Any]) -> None:
        if not self.process or not self.process.stdin:
            raise RunFault("cua-session", "rdpilot-mcp is not running")
        self.process.stdin.write((json.dumps(value, separators=(",", ":")) + "\n").encode())
        self.process.stdin.flush()

    def _request(self, method: str, params: dict[str, Any], timeout_seconds: float) -> dict[str, Any]:
        if not self.process or not self.process.stdin or not self.process.stdout or not self._selector:
            raise RunFault("cua-session", "rdpilot-mcp is not running")
        self._next_id += 1
        request_id = self._next_id
        self._notify({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout_seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RunFault("cua-timeout", f"rdpilot-mcp {method} exceeded {timeout_seconds}s")
            if not self._selector.select(remaining):
                continue
            line = self.process.stdout.readline()
            if not line:
                raise RunFault("cua-exit", f"rdpilot-mcp exited {self.process.poll()}")
            try:
                response = json.loads(line)
            except (UnicodeError, json.JSONDecodeError) as exc:
                raise RunFault("cua-protocol", "rdpilot-mcp emitted invalid JSON-RPC") from exc
            if response.get("id") == request_id:
                return response

    @staticmethod
    def _raise_rpc_error(response: dict[str, Any], operation: str) -> None:
        if "error" in response:
            raise RunFault("cua-rpc", f"{operation} failed: {response['error']}")

    def call(self, name: str, arguments: dict[str, Any], timeout_seconds: float = 30) -> dict[str, Any]:
        tool = self.tools.get(name)
        if not tool:
            raise RunFault("cua-schema", f"requested CUA tool was not advertised: {name}")
        schema = tool.get("inputSchema", {})
        properties = schema.get("properties", {})
        args = dict(arguments)
        if "session" in properties:
            args["session"] = self.session
        unknown = set(args) - set(properties)
        if unknown and schema.get("additionalProperties") is False:
            raise RunFault("cua-schema", f"{name} arguments are not in the advertised schema: {sorted(unknown)}")
        missing = set(schema.get("required", ())) - set(args)
        if missing:
            raise RunFault("cua-schema", f"{name} is missing required arguments: {sorted(missing)}")
        response = self._request(
            "tools/call", {"name": name, "arguments": args}, timeout_seconds
        )
        self._raise_rpc_error(response, f"CUA {name}")
        result = response.get("result")
        if not isinstance(result, dict):
            raise RunFault("cua-result", f"CUA {name} returned no result object")
        if result.get("isError"):
            raise RunFault("cua-result", f"CUA {name} returned isError")
        self._call_index += 1
        artifact = json.loads(json.dumps(response))
        for index, block in enumerate(artifact.get("result", {}).get("content", [])):
            if block.get("type") == "image" and isinstance(block.get("data"), str):
                image_path = self.evidence_dir / f"cua-{self._call_index:04d}-{name}-{index}.png"
                image_path.write_bytes(base64.b64decode(block.pop("data"), validate=True))
                block["saved"] = str(image_path)
        event = {"call": self._call_index, "name": name, "arguments": args, "response": artifact}
        event_path = self.evidence_dir / f"cua-{self._call_index:04d}-{name}.json"
        event_path.write_text(json.dumps(event, indent=2) + "\n", encoding="utf-8")
        return response

    @staticmethod
    def structured(response: dict[str, Any]) -> dict[str, Any]:
        result = response.get("result", {})
        value = result.get("structuredContent")
        if isinstance(value, dict):
            return value
        return result

    @staticmethod
    def certificate_prompt_identity(state: dict[str, Any], operation: str = "install") -> dict[str, Any] | None:
        """Read the CA identity and operation displayed by a Windows Root Store consent.

        Windows shows the CA common name without ``CN=`` and the SHA-1 thumbprint in a non-actionable Text node that
        appears only in ``tree_markdown`` (debug 788, recorded payload certificate787 probe-2 cua-0010).
        """
        tree = state.get("tree_markdown")
        if not isinstance(tree, str):
            return None
        if operation == "delete":
            names = re.findall(r"Subject\s*:\s*([^\r\n]*)\r?\n", tree)
            verb = "Do you want to DELETE the following certificate from the Root Store?"
        else:
            names = re.findall(r"claiming to represent:\r?\n\r?\n([^\r\n]*)\r?\n", tree)
            verb = "Do you want to install this certificate?"
        thumbprints = re.findall(r"Thumbprint \(sha1\)\s*:\s*([0-9A-Fa-f ]+?)\s*\r?\n", tree)
        if not names and not thumbprints and verb not in tree:
            return None
        return {
            "names": [name.strip() for name in names],
            "sha1": ["".join(value.split()).upper() for value in thumbprints],
            "synthetic_mentions": sorted(set(re.findall(r"Ticket 569 synthetic CA [A-Za-z0-9-]+", tree))),
            "operation_matches": verb in tree,
        }

    def acknowledge_certificate_prompt(
        self, expected_common_name: str, expected_sha1: str, evidence_prefix: Path, timeout_seconds: float = 20,
        *, operation: str = "install", expected_pid: int | None = None,
    ) -> bool:
        """Acknowledge only a fresh consent for this operation, exact run CA name and SHA-1 thumbprint.

        Returns False when no such prompt is on screen. A CA prompt with another, missing or ambiguous identity, an
        incomplete or projected snapshot, or no single enabled Yes button raises instead of clicking.
        DELETE also requires the exact owned removal child PID and powershell.exe application identity.
        """
        expected_sha1 = expected_sha1.replace(" ", "").upper()
        if operation not in ("install", "delete") or (operation == "delete" and (expected_pid is None or expected_pid <= 0)):
            raise RunFault("cua-prompt-identity", "DELETE consent requires the exact owned removal child PID")
        if not expected_common_name or expected_common_name.upper().startswith("CN=") or not re.fullmatch(r"[0-9A-F]{40}", expected_sha1):
            raise RunFault("cua-prompt-identity", "expected run CA identity must be a bare common name and a SHA-1 thumbprint")
        deadline = time.monotonic() + timeout_seconds
        windows_response = self.call("list_windows", {"on_screen_only": True}, timeout_seconds=10)
        windows = self.structured(windows_response).get("windows", [])
        matches: list[tuple[dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]] = []
        for window in windows:
            title = str(window.get("title") or window.get("window_title") or "")
            if not window.get("pid") or not window.get("window_id"):
                continue
            if not ("certificate" in title.lower() or "security warning" in title.lower() or "root certificate" in title.lower()):
                continue
            pid = int(window["pid"])
            window_id = int(window["window_id"])
            state_response = self.call(
                "get_window_state",
                {
                    "pid": pid,
                    "window_id": window_id,
                    "include_accessibility_tree": True,
                    "include_screenshot": True,
                    "timeout_ms": 10000,
                },
                timeout_seconds=15,
            )
            state = self.structured(state_response)
            if int(state.get("pid", -1)) != pid or int(state.get("window_id", -1)) != window_id:
                raise RunFault("cua-window-identity", "CUA state did not match the exact certificate prompt window")
            identity = self.certificate_prompt_identity(state, operation)
            if identity is None:
                continue
            if operation == "delete" and (pid != expected_pid or state.get("app_name", "").casefold() != "powershell.exe"):
                raise RunFault("cua-prompt-identity", "DELETE prompt does not belong to the exact owned removal child")
            # The documented walk-budget signal is truncated/nodes_pending (elements_complete false alone was observed
            # on a fully walked 3-element prompt, debug 788); required identity and action proof must be unprojected.
            if state.get("truncated") is not False or state.get("nodes_pending") != 0 or state.get("truncation_reason"):
                raise RunFault("cua-prompt-tree", "certificate prompt UIA snapshot is truncated or has pending nodes")
            if state.get("degraded") is True:
                raise RunFault("cua-prompt-tree", "certificate prompt UIA snapshot is degraded")
            elements = state.get("elements")
            if not isinstance(elements, list) or not (
                state.get("total_element_count") == state.get("returned_element_count") == len(elements)
            ):
                raise RunFault("cua-prompt-tree", "certificate prompt UIA snapshot is projected or missing elements")
            snapshot_id = state.get("snapshot_id")
            if not isinstance(snapshot_id, str) or not snapshot_id:
                raise RunFault("cua-prompt-tree", "certificate prompt has no fresh UIA snapshot id")
            images = [block for block in state_response.get("result", {}).get("content", []) if block.get("type") == "image"]
            if len(images) != 1 or not state.get("screenshot_width") or not state.get("screenshot_height"):
                raise RunFault("cua-prompt-screenshot", "certificate prompt lacks its grounding screenshot")
            if not identity["operation_matches"] or identity["names"] != [expected_common_name] or identity["sha1"] != [expected_sha1] or identity[
                "synthetic_mentions"
            ] != [expected_common_name]:
                raise RunFault(
                    "cua-prompt-identity",
                    f"certificate prompt identity is not exactly this run CA: names={identity['names']} sha1={identity['sha1']}",
                )
            buttons = [
                item
                for item in elements
                if str(item.get("role", "")).casefold() == "button"
                and str(item.get("label", "")).replace("&", "").strip().casefold() == "yes"
                and item.get("enabled") is True
                and str(item.get("element_token") or "").startswith(snapshot_id + ":")
            ]
            if len(buttons) != 1:
                raise RunFault("cua-prompt-action", f"expected one enabled Yes button in exact CA prompt, found {len(buttons)}")
            matches.append((window, state_response, identity, buttons[0]))
        if not matches:
            return False
        if len(matches) != 1:
            raise RunFault("cua-prompt-ambiguous", f"{len(matches)} on-screen prompts show this exact run CA")
        window, state_response, identity, button = matches[0]
        pid = int(window["pid"])
        window_id = int(window["window_id"])
        evidence_prefix.parent.mkdir(parents=True, exist_ok=True)
        metadata = json.loads(json.dumps(state_response))
        for index, block in enumerate(metadata.get("result", {}).get("content", [])):
            if block.get("type") == "image" and isinstance(block.get("data"), str):
                image_path = evidence_prefix.with_name(evidence_prefix.name + f"-{index}.png")
                image_path.write_bytes(base64.b64decode(block.pop("data"), validate=True))
                block["saved"] = str(image_path)
        state = self.structured(state_response)
        evidence_prefix.with_suffix(".json").write_text(
            json.dumps(
                {
                    "window": window,
                    "matched": {"commonName": expected_common_name, "sha1": expected_sha1, "operation": operation, "pid": pid, "displayed": identity},
                    "observedElementsComplete": state.get("elements_complete"),
                    "state": metadata,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        click = self.call("click", {"pid": pid, "element_token": str(button["element_token"])}, timeout_seconds=10)
        click_path = evidence_prefix.with_name(evidence_prefix.name + "-click.json")
        click_path.write_text(json.dumps(click, indent=2) + "\n", encoding="utf-8")
        while time.monotonic() < deadline:
            current = self.structured(
                self.call("list_windows", {"on_screen_only": True}, timeout_seconds=10)
            ).get("windows", [])
            if not any(int(item.get("pid", -1)) == pid and int(item.get("window_id", -1)) == window_id for item in current):
                return True
            time.sleep(0.2)
        raise RunFault("cua-prompt-stuck", "exact CA prompt remained after the UIA Yes action")

    def close(self) -> int | None:
        process = self.process
        if process is None:
            return None
        if process.stdin and process.poll() is None:
            try:
                process.stdin.close()
            except OSError:
                pass
        try:
            code = process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                code = process.wait(timeout=5)
        if self._selector:
            self._selector.close()
            self._selector = None
        if self._stderr_file:
            self._stderr_file.close()
            self._stderr_file = None
        self.process = None
        return code

    def __enter__(self) -> "RdpilotSession":
        self.start()
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.close()
