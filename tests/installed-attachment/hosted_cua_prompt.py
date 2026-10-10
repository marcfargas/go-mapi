"""Bounded native-rdpilot adapter for the hosted CurrentUser Root prompt.

The caller owns the disposable RDP user and the one foreground certificate
import process. This module attaches to that user's loopback session, requires
one accessibility tree to identify the exact certificate and CurrentUser Root
consent text, then answers once and requires the prompt to disappear.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import threading
import time


class PromptFault(RuntimeError):
    pass


def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)


def structured(result):
    if "structuredContent" in result:
        return result["structuredContent"]
    for item in result.get("content", []):
        if item.get("type") == "text":
            try:
                return json.loads(item["text"])
            except (ValueError, KeyError):
                pass
    return result


def validate_schema(schema, value, path="$", depth=0):
    if depth > 32:
        raise PromptFault(f"advertised MCP schema is too deep at {path}")
    if not isinstance(schema, dict):
        raise PromptFault(f"advertised MCP schema is malformed at {path}")
    kind = schema.get("type")
    matches = {
        "object": lambda x: isinstance(x, dict),
        "array": lambda x: isinstance(x, list),
        "string": lambda x: isinstance(x, str),
        "integer": lambda x: isinstance(x, int) and not isinstance(x, bool),
        "number": lambda x: isinstance(x, (int, float)) and not isinstance(x, bool),
        "boolean": lambda x: isinstance(x, bool),
        "null": lambda x: x is None,
    }
    if kind in matches and not matches[kind](value):
        raise PromptFault(f"MCP arguments violate advertised {kind} type at {path}")
    if "const" in schema and value != schema["const"]:
        raise PromptFault(f"MCP arguments violate advertised const at {path}")
    if "enum" in schema and value not in schema["enum"]:
        raise PromptFault(f"MCP arguments violate advertised enum at {path}")
    if "oneOf" in schema:
        successes = 0
        for branch in schema["oneOf"]:
            try:
                validate_schema(branch, value, path, depth + 1)
                successes += 1
            except PromptFault:
                pass
        if successes != 1:
            raise PromptFault(f"MCP arguments must match exactly one advertised schema at {path}")
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        required = schema.get("required", [])
        if any(not isinstance(k, str) for k in required) or any(k not in value for k in required):
            raise PromptFault(f"MCP arguments omit an advertised required field at {path}")
        if schema.get("additionalProperties") is False and any(k not in properties for k in value):
            raise PromptFault(f"MCP arguments contain an unadvertised field at {path}")
        for key, item in value.items():
            if key in properties:
                validate_schema(properties[key], item, f"{path}.{key}", depth + 1)
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            validate_schema(schema["items"], item, f"{path}[{index}]", depth + 1)
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            raise PromptFault(f"MCP argument is shorter than advertised at {path}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            raise PromptFault(f"MCP argument does not match advertised pattern at {path}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            raise PromptFault(f"MCP argument is below advertised minimum at {path}")
        if "maximum" in schema and value > schema["maximum"]:
            raise PromptFault(f"MCP argument is above advertised maximum at {path}")


def prompt_button(state, expected_name, expected_thumbprint, action="import"):
    """Return the exact affirmative control in the observed consent window."""
    serialized = json.dumps(state, ensure_ascii=False).casefold()
    observed_thumbprints = re.sub(r"[^0-9a-f]", "", serialized)
    if expected_name.casefold() not in serialized or re.sub(r"[^0-9a-f]", "", expected_thumbprint.casefold()) not in observed_thumbprints:
        return None
    elements = state.get("elements") if isinstance(state, dict) else None
    if not isinstance(elements, list):
        return None
    affirmative = []
    for element in elements:
        if not isinstance(element, dict):
            continue
        role = str(element.get("role", "")).casefold()
        label = str(element.get("label", "")).strip().casefold()
        affirmative_labels = {"yes", "install", "allow"} if action == "import" else {"yes", "remove", "delete"}
        if role in {"button", "push button"} and label in affirmative_labels and element.get("enabled") is not False:
            token = element.get("element_token")
            if isinstance(token, str):
                affirmative.append(token)
    return affirmative[0] if len(affirmative) == 1 else None


def prompt_matches(value, expected_name, expected_thumbprint, action="import"):
    """Match visible root add/remove consent text and both certificate identities."""
    text = json.dumps(value, ensure_ascii=False).casefold()
    action_words = ("add", "install", "trust") if action == "import" else ("remove", "delete")
    root_consent = ("root" in text and any(token in text for token in action_words))
    observed_thumbprints = re.sub(r"[^0-9a-f]", "", text)
    wanted_thumbprint = re.sub(r"[^0-9a-f]", "", expected_thumbprint.casefold())
    return expected_name.casefold() in text and wanted_thumbprint in observed_thumbprints and root_consent


def prompt_click_arguments(observed):
    """Bind the click to the exact window identity returned by observation."""
    return {"pid": int(observed["pid"]), "window_id": int(observed["windowId"]),
            "element_token": str(observed["affirmativeElementToken"])}


class Mcp:
    def __init__(self, binary, session, env, evidence):
        self.binary, self.session, self.env, self.evidence = binary, session, env, evidence
        self.proc = None
        self.next_id = 0
        self.tools = {}

    async def start(self):
        self.proc = await asyncio.create_subprocess_exec(
            *(list(self.binary) if isinstance(self.binary, (list, tuple)) else [str(self.binary)]), "--session", self.session, env=self.env,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        result = await self.request("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "ticket569-hosted-prompt", "version": "1"},
        })
        if "serverInfo" not in result:
            raise PromptFault("native MCP initialize omitted server identity")
        await self.notify("notifications/initialized")
        listing = await self.request("tools/list", {})
        self.tools = {tool["name"]: tool.get("inputSchema") for tool in listing.get("tools", [])
                      if isinstance(tool, dict) and isinstance(tool.get("name"), str)}
        for name in ("list_windows", "get_window_state", "click", "launch_app"):
            if name not in self.tools:
                raise PromptFault(f"pinned Cua did not advertise required tool {name}")
        return {"serverInfo": result["serverInfo"], "toolCount": len(self.tools)}

    async def notify(self, method):
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "method": method}) + "\n").encode())
        await asyncio.wait_for(self.proc.stdin.drain(), 5)

    async def request(self, method, params, timeout=30):
        self.next_id += 1
        request_id = f"prompt-{self.next_id}"
        msg = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        self.proc.stdin.write((json.dumps(msg, separators=(",", ":")) + "\n").encode())
        await asyncio.wait_for(self.proc.stdin.drain(), 5)
        until = time.monotonic() + timeout
        while True:
            line = await asyncio.wait_for(self.proc.stdout.readline(), max(.1, until - time.monotonic()))
            if not line:
                raise PromptFault(f"native MCP closed during {method}")
            if len(line) > 16 * 1024 * 1024:
                raise PromptFault("native MCP response exceeded the bounded line size")
            response = json.loads(line)
            if response.get("id") == request_id:
                if "error" in response:
                    raise PromptFault(f"native MCP {method} failed: {response['error']}")
                return response["result"]

    async def tool(self, name, arguments=None):
        if name not in self.tools:
            raise PromptFault(f"native MCP tool is unavailable: {name}")
        args = dict(arguments or {})
        schema = self.tools[name]
        if schema is None:
            raise PromptFault(f"native MCP tool {name} omitted its advertised inputSchema")
        validate_schema(schema, args)
        result = await self.request("tools/call", {"name": name, "arguments": args})
        if result.get("isError"):
            raise PromptFault(f"native Cua tool {name} returned an error")
        return result

    async def stop(self):
        if self.proc and self.proc.returncode is None:
            self.proc.stdin.close()
            try:
                await asyncio.wait_for(self.proc.wait(), 5)
            except asyncio.TimeoutError:
                self.proc.kill()
                await asyncio.wait_for(self.proc.wait(), 5)


async def observe_once(mcp, expected_name, expected_thumbprint, evidence_path, action="import"):
    listed = structured(await mcp.tool("list_windows"))
    candidates = []
    enumerated = []
    for window in objects(listed):
        wid = window.get("window_id", window.get("hwnd"))
        pid = window.get("pid")
        if wid is None or pid is None:
            continue
        identity = (int(pid), int(wid))
        if identity in enumerated:
            continue
        enumerated.append(identity)
        if len(enumerated) > 48:
            return {"status": "window-inventory-over-limit", "windowCount": len(enumerated)}
        raw_state = await mcp.tool("get_window_state", {
            "pid": identity[0], "window_id": identity[1],
            "include_screenshot": True, "include_accessibility_tree": True,
        })
        state = structured(raw_state)
        visible = {"window": window, "state": state}
        if prompt_matches(visible, expected_name, expected_thumbprint, action):
            token = prompt_button(state, expected_name, expected_thumbprint, action)
            if token:
                screenshot = next((block for block in raw_state.get("content", []) if block.get("type") == "image"), None)
                screenshot_record = None
                if screenshot and screenshot.get("mimeType") == "image/png":
                    screenshot_bytes = base64.b64decode(screenshot.get("data", ""), validate=True)
                    digest = hashlib.sha256(screenshot_bytes).hexdigest()
                    screenshot_file = Path(evidence_path).with_name(f"current-user-root-{action}-{digest}.png")
                    # Content-addressed captures never overwrite earlier consent proof.
                    try:
                        with screenshot_file.open("xb") as retained:
                            retained.write(screenshot_bytes)
                    except FileExistsError:
                        if screenshot_file.read_bytes() != screenshot_bytes:
                            raise PromptFault("immutable prompt capture content changed")
                    screenshot_record = {"path": str(screenshot_file), "sha256": hashlib.sha256(screenshot_bytes).hexdigest(), "bytes": len(screenshot_bytes)}
                if not screenshot_record:
                    continue
                elements = state.get("elements", []) if isinstance(state, dict) else []
                ui_evidence = [{"role": e.get("role"), "label": e.get("label"), "enabled": e.get("enabled"), "elementToken": e.get("element_token")}
                               for e in elements if isinstance(e, dict) and e.get("element_token") == token]
                candidates.append((identity, state, token, screenshot_record, ui_evidence))
    if len(candidates) != 1:
        return {"status": "not-unique", "candidateCount": len(candidates), "windowCount": len(enumerated)}
    (pid, wid), state, token, screenshot_record, ui_evidence = candidates[0]
    serialized = json.dumps(state, ensure_ascii=False).casefold()
    if expected_name.casefold() not in serialized or re.sub(r"[^0-9a-f]", "", expected_thumbprint.casefold()) not in re.sub(r"[^0-9a-f]", "", serialized):
        return {"status": "window-state-mismatch", "windowId": wid, "pid": pid}
    # Retain the required synthetic-prompt screenshot plus structured UIA
    # metadata. Free-form MCP exception text is excluded from the proof.
    return {"status": "exact-prompt-observed", "windowId": wid, "pid": int(pid),
            "certificateNameMatched": True, "thumbprintMatched": True,
            "currentUserRootMatched": True, "affirmativeControlPresent": True,
            "affirmativeElementToken": token, "screenshotEvidence": screenshot_record,
            "uiaEvidence": ui_evidence}


async def launch_importer(args, mcp):
    import_script = Path(args.import_script).resolve()
    if not import_script.is_file():
        raise PromptFault("owned CurrentUser Root import script is missing")
    launch = await mcp.tool("launch_app", {
        "path": r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
        "start_minimized": True,
        "additional_arguments": [
            "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", str(import_script),
            "-Mode", "Import", "-LaunchGateName", getattr(args, "import_gate", ""), "-RunId", args.run_id, "-ExpectedSID", args.expected_sid,
            "-SourceSHA", args.source_sha, "-SupervisorPipeName", args.supervisor_pipe,
            "-ExpectedSessionId", str(args.expected_session_id),
            "-CertificatePath", str(Path(args.certificate_path).resolve()),
            "-Thumbprint", args.thumbprint, "-OutputPath", str(Path(args.import_result).resolve()),
            "-ObserverScriptPath", str(Path(args.observer_script).resolve()),
            "-ObserverAttachedPath", str(Path(args.observer_attached).resolve()),
            "-ObserverExitPath", str(Path(args.observer_exit).resolve()),
            "-ObserverFailurePath", str(Path(args.observer_failure).resolve()),
            "-HoldAfterWriteSeconds", "2",
            "-JobStartCounter", str(args.job_start_counter), "-CounterFrequency", str(args.counter_frequency),
        ],
    })
    receipt = structured(launch)
    if not isinstance(receipt, dict) or type(receipt.get("pid")) is not int or receipt["pid"] <= 0 or receipt.get("running") is not True:
        raise PromptFault("pinned launch_app omitted its exact live importer PID receipt")
    return receipt


async def run(args, mcp_override=None, retain_mcp=False, launch_receipt=None):
    bin_dir = Path(args.bin_dir).resolve()
    mcp_bin = bin_dir / ("rdpilot-mcp.exe" if os.name == "nt" else "rdpilot-mcp")
    if not mcp_bin.is_file():
        raise PromptFault("pinned native MCP binary is missing")
    if not args.runtime_root or mcp_override is None or not retain_mcp:
        raise PromptFault("root-prompt UIA must run through the retained session-owner MCP service")
    private = Path(args.runtime_root).resolve()
    if not private.is_dir():
        raise PromptFault("the persistent rdpilot session-owner runtime is unavailable")
    inherited = {"PATH", "SYSTEMROOT", "WINDIR", "TEMP", "TMP", "USERPROFILE", "USERNAME",
                 "COMPUTERNAME", "HOMEDRIVE", "HOMEPATH", "LOCALAPPDATA", "APPDATA",
                 "RDPILOT_BUNDLE_PATH", "RDPILOT_SOURCE_SHA"}
    env = {k: v for k, v in os.environ.items() if k.upper() in inherited}
    for directory in ("runtime", "config", "share", "cache"):
        (private / directory).mkdir(exist_ok=True)
    env.update({
        "APPDATA": str(private / "appdata"),
        "XDG_RUNTIME_DIR": str(private / "runtime"),
        "XDG_CONFIG_HOME": str(private / "config"),
        "XDG_CACHE_HOME": str(private / "cache"),
        "RDPILOT_SHARE_ROOT": str(private / "share"),
        "RDPILOT_DAEMON_SINK_PATH": str(private / "sessions.json"),
        "RDPILOT_DAEMON_IDLE_TIMEOUT_MS": "180000",
        "RDPILOT_DAEMON_EMPTY_GRACE_MS": "180000",
    })
    result = {"schema": "ticket569-hosted-cua-prompt-v1", "status": "unknown",
              "route": "pinned rdpilot CLI + native MCP over loopback RDP",
              "rdpilotSourceCommit": os.environ.get("RDPILOT_SOURCE_SHA"),
              "observation": None, "answerIssued": False, "promptClosed": False}
    mcp = mcp_override
    try:
        if mcp.proc is None or mcp.proc.returncode is not None:
            raise PromptFault("retained native MCP process is not live")
        if launch_receipt is None:
            launch_receipt = await launch_importer(args, mcp)
        result["importLaunchReceipt"] = launch_receipt
        result["importProcessLaunched"] = True
        deadline = time.monotonic() + args.prompt_timeout
        observed = None
        while time.monotonic() < deadline:
            observed = await observe_once(mcp, args.expected_name, args.thumbprint, args.evidence)
            if observed["status"] == "exact-prompt-observed":
                break
            await asyncio.sleep(.4)
        result["observation"] = observed
        if not observed or observed["status"] != "exact-prompt-observed":
            raise PromptFault("the exact CurrentUser Root consent prompt was not identified by native UIA")
        # The token came from the exact prompt window snapshot. A fresh
        # snapshot would invalidate it, so click before making another read.
        await mcp.tool("click", prompt_click_arguments(observed))
        result["answerIssued"] = True
        close_deadline = time.monotonic() + args.close_timeout
        while time.monotonic() < close_deadline:
            after = await observe_once(mcp, args.expected_name, args.thumbprint, args.evidence)
            if after["status"] == "not-unique" and after["candidateCount"] == 0:
                result["promptClosed"] = True
                break
            await asyncio.sleep(.4)
        if not result["promptClosed"]:
            raise PromptFault("the observed CurrentUser Root prompt did not close after the bounded answer")
        import_result_path = Path(args.import_result)
        observer_exit_path = Path(args.observer_exit)
        observer_attached_path = Path(args.observer_attached)
        observer_failure_path = Path(args.observer_failure)
        child_deadline = time.monotonic() + args.child_timeout
        child_result = None
        result["removalConsentObserved"] = False
        result["removalConsentAnswered"] = False
        while time.monotonic() < child_deadline:
            if observer_failure_path.is_file():
                raise PromptFault("retained process observer failed before the child result was read")
            if not result["removalConsentAnswered"]:
                removal = await observe_once(mcp, args.expected_name, args.thumbprint, args.evidence, action="remove")
                if removal.get("status") == "exact-prompt-observed":
                    result["removalConsentObserved"] = True
                    result["removalObservation"] = removal
                    await mcp.tool("click", prompt_click_arguments(removal))
                    result["removalConsentAnswered"] = True
                    removal_close_deadline = time.monotonic() + args.close_timeout
                    while time.monotonic() < removal_close_deadline:
                        after_remove = await observe_once(mcp, args.expected_name, args.thumbprint, args.evidence, action="remove")
                        if after_remove.get("status") == "not-unique" and after_remove.get("candidateCount") == 0:
                            result["removalPromptClosed"] = True
                            break
                        await asyncio.sleep(.4)
                    if not result.get("removalPromptClosed"):
                        raise PromptFault("the exact owned Root removal prompt did not close after the bounded answer")
            if observer_exit_path.is_file() and import_result_path.is_file() and observer_attached_path.is_file():
                try:
                    child_result = json.loads(import_result_path.read_text(encoding="utf-8"))
                    break
                except (ValueError, OSError):
                    pass
            await asyncio.sleep(.25)
        attached = json.loads(observer_attached_path.read_text(encoding="utf-8")) if observer_attached_path.is_file() else None
        exited = json.loads(observer_exit_path.read_text(encoding="utf-8")) if observer_exit_path.is_file() else None
        if (not child_result or child_result.get("schema") != "ticket569-currentuser-root-import-v1" or
                child_result.get("runId") != args.run_id or child_result.get("sid") != args.expected_sid or
                int(child_result.get("sessionId", -1)) != args.expected_session_id or
                not child_result.get("userFlag") or child_result.get("store") != "CurrentUser/Root" or
                child_result.get("thumbprint", "").casefold() != args.thumbprint.casefold() or
                not child_result.get("passed") or not child_result.get("addedObserved") or
                not child_result.get("removedObserved") or not child_result.get("processCreationFileTimeUtc") or
                not attached or not exited or not attached.get("HandleRetained") or not exited.get("HandleRetained") or
                int(attached.get("PID", -1)) != int(child_result.get("processId", -2)) or
                int(exited.get("PID", -1)) != int(child_result.get("processId", -2)) or
                int(exited.get("ExitCode", -1)) != 0 or
                attached.get("CreationFileTimeUtc") != exited.get("CreationFileTimeUtc") or
                abs(float(attached.get("CreationFileTimeUtc", -1)) - float(child_result.get("processCreationFileTimeUtc", -2))) > 10000):
            raise PromptFault("the exact user/session CurrentUser Root child did not publish a successful post-cleanup result")
        result["importChild"] = child_result
        result["processObservation"] = {"attached": attached, "exit": exited}
        result["status"] = "observed-and-answered"
    except Exception as exc:
        result["status"] = "harness-defect"
        result["faultType"] = type(exc).__name__
        result["fault"] = str(exc)[:500]
    finally:
        if mcp and not retain_mcp:
            await mcp.stop()
        result["disconnected"] = False
        result["sessionOwnerRetained"] = True
        result["daemonStopped"] = False
        # This process never receives the login secret. Only the session owner
        # can report a scan, and only after scanning its actual private runtime.
        result["privateRuntimeRemoved"] = False
    Path(args.evidence).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    common_success = (result["status"] == "observed-and-answered" and result.get("promptClosed"))
    return 0 if common_success and result.get("sessionOwnerRetained") else 1


async def run_service(args):
    """Serve one bounded prompt request while retaining the owner-bound MCP."""
    bin_dir = Path(args.bin_dir).resolve()
    mcp_bin = bin_dir / ("rdpilot-mcp.exe" if os.name == "nt" else "rdpilot-mcp")
    inherited = {"PATH", "SYSTEMROOT", "WINDIR", "TEMP", "TMP", "USERPROFILE", "USERNAME",
                 "COMPUTERNAME", "HOMEDRIVE", "HOMEPATH", "LOCALAPPDATA", "APPDATA",
                 "RDPILOT_BUNDLE_PATH", "RDPILOT_SOURCE_SHA"}
    env = {k: v for k, v in os.environ.items() if k.upper() in inherited}
    private = Path(args.runtime_root).resolve()
    if not private.is_dir():
        raise PromptFault("the persistent rdpilot session-owner runtime is unavailable")
    for directory in ("runtime", "config", "share", "cache"):
        (private / directory).mkdir(exist_ok=True)
    env.update({
        "APPDATA": str(private / "appdata"),
        "XDG_RUNTIME_DIR": str(private / "runtime"),
        "XDG_CONFIG_HOME": str(private / "config"),
        "XDG_CACHE_HOME": str(private / "cache"),
        "RDPILOT_SHARE_ROOT": str(private / "share"),
        "RDPILOT_DAEMON_SINK_PATH": str(private / "sessions.json"),
        "RDPILOT_DAEMON_IDLE_TIMEOUT_MS": "1800000",
        "RDPILOT_DAEMON_EMPTY_GRACE_MS": "1800000",
    })
    mcp = Mcp(mcp_bin, args.session_name, env, args.evidence)
    removal_watch = None
    command_reader = None
    try:
        native = await mcp.start()
        print(json.dumps({"op": "ready", "nativeMcp": native}, separators=(",", ":")), flush=True)
        completed = False
        importer_launch = None
        loop = asyncio.get_running_loop()
        command_lines = asyncio.Queue()

        def read_commands():
            # Keep blocking pipe reads off the asyncio loop so the persistent
            # UIA watcher can observe a removal prompt while the supervisor is
            # idle. Stop after the explicit stop command so no read is left
            # pending when this service exits.
            while True:
                line = sys.stdin.readline()
                try:
                    loop.call_soon_threadsafe(command_lines.put_nowait, line)
                except RuntimeError:
                    return
                if not line:
                    return
                try:
                    if json.loads(line).get("op") == "stop":
                        return
                except (ValueError, AttributeError):
                    pass

        command_reader = threading.Thread(
            target=read_commands, name="hosted-cua-command-reader", daemon=True
        )
        command_reader.start()

        async def watch_owned_removal():
            while True:
                observed = await observe_once(mcp, args.expected_name, args.thumbprint, args.evidence, action="remove")
                if observed.get("status") == "exact-prompt-observed":
                    await mcp.tool("click", prompt_click_arguments(observed))
                    close_deadline = time.monotonic() + args.close_timeout
                    while time.monotonic() < close_deadline:
                        after = await observe_once(mcp, args.expected_name, args.thumbprint, args.evidence, action="remove")
                        if after.get("status") == "not-unique" and after.get("candidateCount") == 0:
                            evidence = {"status": "observed-and-answered", "observation": observed,
                                        "promptClosed": True, "atUtc": time.time()}
                            Path(args.evidence).with_name("current-user-root-removal-consent.json").write_text(
                                json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
                            return evidence
                        await asyncio.sleep(.4)
                    raise PromptFault("the exact owned Root removal prompt did not close after the bounded answer")
                await asyncio.sleep(.5)

        while True:
            try:
                line = await asyncio.wait_for(command_lines.get(), timeout=.5)
            except asyncio.TimeoutError:
                if mcp.proc is None or mcp.proc.returncode is not None:
                    raise PromptFault("session-owner native MCP participant exited while awaiting a command")
                if removal_watch and removal_watch.done():
                    removal_watch.result()
                continue
            if not line:
                break
            if len(line) > 65536:
                raise PromptFault("session-owner UI command exceeded the bounded request size")
            command = json.loads(line)
            op = command.get("op") if isinstance(command, dict) else None
            if op == "watch-removal" and not completed and importer_launch is None:
                # New MCP attachment on the retained, already connected owner:
                # observe only the exact owned removal dialog, never import.
                completed = True
                removal_watch = asyncio.create_task(watch_owned_removal())
                print(json.dumps({"op": "watching-removal", "importerLaunched": False}, separators=(",", ":")), flush=True)
            elif op == "launch" and not completed and importer_launch is None:
                importer_launch = await launch_importer(args, mcp)
                print(json.dumps({"op": "importer-launched", "receipt": importer_launch}, separators=(",", ":")), flush=True)
            elif op == "run" and not completed:
                if getattr(args, "import_gate", "") and importer_launch is None:
                    raise PromptFault("gated importer must be launched and authorized before its prompt run")
                if importer_launch is None:
                    code = await run(args, mcp_override=mcp, retain_mcp=True)
                else:
                    code = await run(args, mcp_override=mcp, retain_mcp=True, launch_receipt=importer_launch)
                completed = True
                removal_watch = asyncio.create_task(watch_owned_removal())
                try:
                    value = json.loads(Path(args.evidence).read_text(encoding="utf-8"))
                except (ValueError, OSError):
                    value = {"status": "unknown", "fault": "prompt evidence could not be read"}
                print(json.dumps({"op": "result", "exitCode": code, "result": value}, separators=(",", ":")), flush=True)
            elif op == "status":
                live = mcp.proc is not None and mcp.proc.returncode is None
                print(json.dumps({"op": "status", "mcpAlive": live,
                                  "exitCode": mcp.proc.returncode if mcp.proc else None}, separators=(",", ":")), flush=True)
            elif op == "stop":
                if removal_watch:
                    removal_watch.cancel()
                    try:
                        await removal_watch
                    except asyncio.CancelledError:
                        pass
                await mcp.stop()
                print(json.dumps({"op": "stopped", "result": True}, separators=(",", ":")), flush=True)
                return 0
            else:
                raise PromptFault("session-owner UI command is unknown, repeated, or out of order")
        raise PromptFault("session-owner UI command channel closed before an explicit stop")
    finally:
        if removal_watch and not removal_watch.done():
            removal_watch.cancel()
            try:
                await removal_watch
            except asyncio.CancelledError:
                pass
        if command_reader:
            command_reader.join(timeout=1)
        reader_alive = command_reader is not None and command_reader.is_alive()
        await mcp.stop()
        if reader_alive:
            raise PromptFault("session-owner command reader did not stop after the bounded command channel ended")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", required=True)
    parser.add_argument("--expected-name", required=True)
    parser.add_argument("--expected-sid", required=True)
    parser.add_argument("--expected-session-id", type=int, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--supervisor-pipe", required=True)
    parser.add_argument("--thumbprint", required=True)
    parser.add_argument("--certificate-path", required=True)
    parser.add_argument("--import-script", required=True)
    parser.add_argument("--import-result", required=True)
    parser.add_argument("--import-gate", default="")
    parser.add_argument("--job-start-counter", required=True, type=int)
    parser.add_argument("--counter-frequency", required=True, type=int)
    parser.add_argument("--observer-script", required=True)
    parser.add_argument("--observer-attached", required=True)
    parser.add_argument("--observer-exit", required=True)
    parser.add_argument("--observer-failure", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--runtime-root", default="")
    parser.add_argument("--session-name", default="prompt")
    parser.add_argument("--prompt-timeout", type=int, default=30)
    parser.add_argument("--close-timeout", type=int, default=10)
    parser.add_argument("--child-timeout", type=int, default=30)
    parser.add_argument("--service", action="store_true")
    args = parser.parse_args(argv)
    try:
        return asyncio.run(run_service(args) if args.service else run(args))
    except Exception as exc:
        evidence_path = Path(args.evidence)
        failure_path = evidence_path.with_name(evidence_path.stem + "-service-failure.json") if evidence_path.exists() else evidence_path
        failure_path.write_text(json.dumps({
            "schema": "ticket569-hosted-cua-prompt-v1", "status": "harness-defect",
            "faultType": type(exc).__name__, "fault": str(exc)[:500],
        }, indent=2) + "\n", encoding="utf-8")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
