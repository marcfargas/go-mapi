"""Host-side CrabBox transport and interactive case control."""

from __future__ import annotations

import base64
import hashlib
from datetime import datetime, timezone
import json
import os
import re
import subprocess
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from evidence import RunFault
from rdpilot_session import RdpilotSession


def ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


@dataclass(frozen=True)
class Handoff:
    status_file: Path
    host: str
    port: int
    ssh_user: str
    key: Path
    known_hosts: Path
    remote_user: str
    password_file: Path
    lease_id: str

    @classmethod
    def load(cls, status_file: Path) -> "Handoff":
        try:
            status = json.loads(status_file.read_text(encoding="utf-8"))
            attempts = status["attempts"]
            attempt = attempts[-1]
            ssh = attempt["ssh"]
            user_step = next(step for step in attempt["steps"] if step.get("name") == "interactive_user")
            remote_user = user_step["user"]
            password_file = Path(user_step["password_file"])
            known_hosts = Path(attempt["known_hosts"])
            key = Path(ssh["key_path"])
            host = str(ssh["host"])
            port = int(ssh["port"])
            ssh_user = str(ssh["user"])
            lease_id = str(attempt["lease_id"])
            expiry = datetime.fromisoformat(str(attempt["expires_at"]).replace("Z", "+00:00"))
            cleanup_status = str(attempt.get("cleanup", {}).get("status", "active")).casefold()
        except (OSError, KeyError, IndexError, StopIteration, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise RunFault("handoff-status", "handoff status lacks a complete interactive SSH lease") from exc
        if not re.fullmatch(r"cbx_[a-z0-9]{8,32}", lease_id):
            raise RunFault("handoff-status", "handoff lease identity has an unexpected format")
        if cleanup_status in {"released", "complete", "completed", "expired"} or expiry <= datetime.now(timezone.utc):
            raise RunFault("handoff-status", "handoff lease is released or expired")
        for path in (known_hosts, key, password_file):
            if not path.is_file():
                raise RunFault("handoff-credentials", f"owned transport file is absent: {path.name}")
            if path == password_file and path.stat().st_mode & 0o077:
                raise RunFault("handoff-credentials", "interactive user password file permissions are broader than 0600")
        return cls(status_file, host, port, ssh_user, key, known_hosts, remote_user, password_file, lease_id)

    def ssh(self, script: str, *, timeout_seconds: float = 120) -> subprocess.CompletedProcess[str]:
        encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
        remote_command = f"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {encoded}"
        command = [
            "ssh", "-i", str(self.key), "-p", str(self.port),
            "-o", f"UserKnownHostsFile={self.known_hosts}",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "BatchMode=yes",
            f"{self.ssh_user}@{self.host}", remote_command,
        ]
        try:
            result = subprocess.run(command, text=True, capture_output=True, timeout=timeout_seconds, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RunFault("ssh-transport", f"bounded SSH command failed: {type(exc).__name__}") from exc
        if result.returncode:
            raise RunFault("ssh-child", f"SSH/PowerShell child exited {result.returncode}", result.returncode)
        return result

    def logoff_user_session(self, session_id: int, sid: str, *, timeout_seconds: float = 120) -> dict[str, Any]:
        if session_id <= 0 or not re.fullmatch(r"S-1-5-21-(?:\d+-){2,}\d+", sid):
            raise RunFault("profile-logoff", "refusing to log off a malformed session/SID")
        script = f"""
$ErrorActionPreference='Stop'
$sid = '{sid}'
$profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $sid
if (!$profile -or !$profile.Loaded) {{ throw 'Expected user profile is absent or already unloaded' }}
$owners = @(Get-Process -IncludeUserName | Where-Object SessionId -eq {session_id} | ForEach-Object {{ try {{ ([Security.Principal.NTAccount]$_.UserName).Translate([Security.Principal.SecurityIdentifier]).Value }} catch {{ $null }} }})
if ($sid -notin $owners) {{ throw 'No process in the requested session belongs to the loaded profile SID' }}
& logoff.exe {session_id}
if ($LASTEXITCODE -ne 0) {{ throw 'Windows logoff command failed' }}
$deadline = [DateTime]::UtcNow.AddSeconds(90)
do {{ Start-Sleep -Seconds 2; $profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $sid }} while ($profile.Loaded -and [DateTime]::UtcNow -lt $deadline)
if ($profile.Loaded -or (Test-Path ('Registry::HKEY_USERS\\' + $sid))) {{ throw 'Profile or SID hive remained loaded after logoff' }}
@{{ SID=$sid; SessionId={session_id}; Loaded=$false; HiveAbsent=$true; At=[DateTime]::UtcNow.ToString('o') }} | ConvertTo-Json -Compress
"""
        result = self.ssh(script, timeout_seconds=timeout_seconds)
        try:
            value = json.loads(result.stdout.strip().splitlines()[-1])
        except (IndexError, json.JSONDecodeError) as exc:
            raise RunFault("profile-logoff", "logoff did not return machine-readable unloaded-profile proof") from exc
        if value.get("SID") != sid or value.get("SessionId") != session_id or value.get("Loaded") or not value.get("HiveAbsent"):
            raise RunFault("profile-logoff", "Windows did not prove the requested user profile was unloaded")
        return value

    def observed_user_session(self, sid: str, *, timeout_seconds: float = 30) -> int:
        """Return the sole positive session currently hosting the loaded SID profile."""
        if not re.fullmatch(r"S-1-5-21-(?:\d+-){2,}\d+", sid):
            raise RunFault("profile-session", "refusing to inspect a malformed profile SID")
        script = f"""
$ErrorActionPreference='Stop'
$sid='{sid}'
$profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $sid
if (!$profile -or !$profile.Loaded) {{ throw 'Expected user profile is not loaded' }}
$sessions = @(Get-Process -IncludeUserName | Where-Object SessionId -gt 0 | ForEach-Object {{
  try {{ if (([Security.Principal.NTAccount]$_.UserName).Translate([Security.Principal.SecurityIdentifier]).Value -eq $sid) {{ [int]$_.SessionId }} }} catch {{ }}
}} | Sort-Object -Unique)
if ($sessions.Count -ne 1) {{ throw 'Could not identify exactly one active interactive session for the loaded SID' }}
@{{ SID=$sid; SessionId=$sessions[0]; Loaded=$true }} | ConvertTo-Json -Compress
"""
        result = self.ssh(script, timeout_seconds=timeout_seconds)
        try:
            value = json.loads(result.stdout.strip().splitlines()[-1])
            session_id = int(value["SessionId"])
        except (IndexError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            raise RunFault("profile-session", "guest did not return observed SID/session evidence") from exc
        if value.get("SID") != sid or not value.get("Loaded") or session_id <= 0:
            raise RunFault("profile-session", "guest session evidence does not match the loaded profile")
        return session_id

    def profile_action(
        self,
        script_path: str,
        action: str,
        sid: str,
        profile_path: str,
        vhd_path: str,
        backup_path: str,
        evidence_path: str,
    ) -> None:
        if action not in {"prepare-vhd", "restore-normal"}:
            raise RunFault("profile-action", "unsupported profile lifecycle action")
        quoted = ps_quote
        script = (
            "$ErrorActionPreference='Stop'; & " + quoted(script_path)
            + " -Action " + quoted(action)
            + " -SID " + quoted(sid)
            + " -ProfilePath " + quoted(profile_path)
            + " -VhdPath " + quoted(vhd_path)
            + " -BackupPath " + quoted(backup_path)
            + " -EvidenceDirectory " + quoted(evidence_path)
            + "; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }"
        )
        self.ssh(script, timeout_seconds=300)

    def push(self, source: Path, remote_path: str, *, timeout_seconds: float = 300) -> None:
        command = ["crabbox-handoff", "push", "--status-file", str(self.status_file), str(source), remote_path]
        try:
            result = subprocess.run(command, text=True, capture_output=True, timeout=timeout_seconds, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RunFault("stage-failure", f"bounded handoff push failed: {type(exc).__name__}") from exc
        if result.returncode:
            raise RunFault("stage-failure", f"handoff push exited {result.returncode}", result.returncode)

    def pull(self, remote_path: str, destination: Path, *, timeout_seconds: float = 300) -> None:
        destination.mkdir(parents=True, exist_ok=True)
        command = ["crabbox-handoff", "pull", "--status-file", str(self.status_file), remote_path, str(destination)]
        try:
            result = subprocess.run(command, text=True, capture_output=True, timeout=timeout_seconds, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RunFault("collect-failure", f"bounded handoff pull failed: {type(exc).__name__}") from exc
        if result.returncode:
            raise RunFault("collect-failure", f"handoff pull exited {result.returncode}", result.returncode)

    def rdpilot_connect(self, session: str, rdp_port: int, evidence_dir: Path, *, timeout_seconds: float = 120) -> None:
        if not 1 <= rdp_port <= 65535:
            raise RunFault("rdp-target", "RDP tunnel port is outside the TCP port range")
        target = f"rdp://{self.remote_user}@127.0.0.1:{rdp_port}"
        command = [
            "rdpilot", "connect", target, "--name", session,
            "-o", f"PasswordCommand=cat {self.password_file}",
            "-o", "AcceptInvalidCerts=yes",
        ]
        try:
            result = subprocess.run(command, text=True, capture_output=True, timeout=timeout_seconds, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RunFault("rdp-reconnect", f"rdpilot reconnect failed: {type(exc).__name__}") from exc
        if result.returncode:
            raise RunFault("rdp-reconnect", f"rdpilot connect exited {result.returncode}", result.returncode)
        evidence_dir.mkdir(parents=True, exist_ok=True)
        (evidence_dir / f"rdpilot-connect-{session}.log").write_text(
            result.stdout + result.stderr, encoding="utf-8"
        )

    def rdpilot_disconnect(self, session: str, evidence_dir: Path, *, timeout_seconds: float = 30) -> None:
        try:
            result = subprocess.run(
                ["rdpilot", "disconnect", "--session", session],
                text=True,
                capture_output=True,
                timeout=timeout_seconds,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise RunFault("rdp-disconnect", f"rdpilot disconnect failed: {type(exc).__name__}") from exc
        if result.returncode:
            raise RunFault("rdp-disconnect", f"rdpilot disconnect exited {result.returncode}", result.returncode)
        evidence_dir.mkdir(parents=True, exist_ok=True)
        (evidence_dir / f"rdpilot-disconnect-{session}.log").write_text(
            result.stdout + result.stderr, encoding="utf-8"
        )


def launch_interactive_script(
    cua: RdpilotSession,
    *,
    script_path: str,
    arguments: list[str],
    timeout_seconds: float = 20,
) -> dict[str, Any]:
    powershell = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    response = cua.call(
        "launch_app",
        {
            "path": powershell,
            "additional_arguments": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path, *arguments],
        },
        timeout_seconds=timeout_seconds,
    )
    return RdpilotSession.structured(response)


def wait_for_guest_result(
    handoff: Handoff,
    cua: RdpilotSession,
    remote_result: str,
    run_id: str,
    expected_subject: str,
    evidence_prefix: Path,
    *,
    timeout_seconds: float,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    trust_acknowledged = False
    while time.monotonic() < deadline:
        if not trust_acknowledged:
            trust_acknowledged = cua.acknowledge_certificate_prompt(
                expected_subject, evidence_prefix, timeout_seconds=2
            )
        script = f"$p={ps_quote(remote_result)}; if (Test-Path -LiteralPath $p -PathType Leaf) {{ Get-Content -LiteralPath $p -Raw }} else {{ 'TICKET569_PENDING' }}"
        remote = handoff.ssh(script, timeout_seconds=20)
        text = remote.stdout.strip()
        if text and text != "TICKET569_PENDING":
            try:
                result = json.loads(text)
            except json.JSONDecodeError as exc:
                raise RunFault("guest-result", "guest result file was truncated or polluted by command output") from exc
            if result.get("RunId") != run_id:
                raise RunFault("guest-result", "guest result belongs to a different case")
            if not trust_acknowledged:
                raise RunFault("cua-prompt-missing", "transaction completed without a screenshot/UIA-confirmed run-specific CA prompt")
            result["TrustPromptConfirmed"] = True
            return result
        time.sleep(0.5)
    raise RunFault("transaction-timeout", f"guest transaction did not publish {Path(remote_result).name} within the deadline")


def start_guest_process_observer(
    handoff: Handoff,
    pid: int,
    launcher_script: str,
    observer_script: str,
    guest_root: str,
    *,
    attach_timeout_seconds: float = 30,
    process_timeout_seconds: float = 300,
) -> dict[str, Any]:
    """Attach a guest-owned wait handle to the live CUA launcher before it exits."""
    if pid <= 0:
        raise RunFault("launcher-process", "CUA launcher PID must be positive")
    observer_root = guest_root + ".process-observer"
    run_id = Path(guest_root.replace("\\", "/")).name
    attached_path = observer_root + r"\launcher-process-attached.json"
    exit_path = observer_root + r"\launcher-process-exit.json"
    failure_path = observer_root + r"\launcher-process-observer-failure.json"
    observer = (
        f"& {ps_quote(observer_script)} -TargetProcessId {pid} -ExpectedCommand {ps_quote(launcher_script)} "
        f"-AttachedPath {ps_quote(attached_path)} -ExitPath {ps_quote(exit_path)} "
        f"-FailurePath {ps_quote(failure_path)} -ExpectedRunId {ps_quote(run_id)} "
        f"-TimeoutSeconds {int(process_timeout_seconds)}"
    )
    encoded = base64.b64encode(observer.encode("utf-16le")).decode("ascii")
    launch = (
        f"New-Item -ItemType Directory -Path {ps_quote(observer_root)} -Force | Out-Null; "
        "$observer=Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-NonInteractive',"
        "'-ExecutionPolicy','Bypass','-EncodedCommand','" + encoded + "') -PassThru -WindowStyle Hidden; "
        f"$deadline=[DateTime]::UtcNow.AddSeconds({attach_timeout_seconds}); while ([DateTime]::UtcNow -lt $deadline) {{ "
        f"if (Test-Path -LiteralPath {ps_quote(attached_path)}) {{ Get-Content -LiteralPath {ps_quote(attached_path)} -Raw; exit 0 }}; "
        f"if (Test-Path -LiteralPath {ps_quote(failure_path)}) {{ Get-Content -LiteralPath {ps_quote(failure_path)} -Raw; exit 1 }}; "
        "Start-Sleep -Milliseconds 100 }; throw 'Observer did not attach while launcher was alive'"
    )
    result = handoff.ssh(launch, timeout_seconds=attach_timeout_seconds + 10)
    try:
        value = json.loads(result.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError) as exc:
        raise RunFault("launcher-process", "observer did not return its retained-handle attachment proof") from exc
    command_line = value.get("CommandLine", "")
    if (
        value.get("PID") != pid
        or value.get("HandleRetained") is not True
        or value.get("ProcessName", "").casefold() != "powershell.exe"
        or not isinstance(command_line, str)
        or launcher_script.casefold() not in command_line.casefold()
        or run_id.casefold() not in command_line.casefold()
        or not value.get("CreationDateFromHandle")
        or not isinstance(value.get("CreationFileTimeUtc"), int)
        or not isinstance(value.get("CimCreationFileTimeUtc"), int)
        or abs(value["CreationFileTimeUtc"] - value["CimCreationFileTimeUtc"]) > 10000
    ):
        handoff.ssh(f"Remove-Item -LiteralPath {ps_quote(observer_root)} -Recurse -Force -ErrorAction SilentlyContinue")
        raise RunFault("launcher-process", "observer attached to a different process or did not retain its handle")
    return value


def wait_for_guest_process_exit(
    handoff: Handoff,
    pid: int,
    guest_root: str,
    expected_creation_filetime: int,
    *,
    timeout_seconds: float = 310,
) -> dict[str, Any]:
    """Read the exit code from the observer that owned a process handle."""
    if pid <= 0:
        raise RunFault("launcher-process", "CUA launcher PID must be positive")
    observer_root = guest_root + ".process-observer"
    exit_path = observer_root + r"\launcher-process-exit.json"
    failure_path = observer_root + r"\launcher-process-observer-failure.json"
    attached_guest_path = guest_root + r"\launcher-process-attached.json"
    exit_guest_path = guest_root + r"\launcher-process-exit.json"
    failure_guest_path = guest_root + r"\launcher-process-observer-failure.json"
    attached_observer_path = observer_root + r"\launcher-process-attached.json"
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        script = f"if (Test-Path -LiteralPath {ps_quote(exit_path)}) {{ Get-Content -LiteralPath {ps_quote(exit_path)} -Raw }} elseif (Test-Path -LiteralPath {ps_quote(failure_path)}) {{ Get-Content -LiteralPath {ps_quote(failure_path)} -Raw }} else {{ 'TICKET569_PENDING' }}"
        result = handoff.ssh(script, timeout_seconds=min(20, max(1, timeout_seconds)))
        text = result.stdout.strip()
        if text and text != "TICKET569_PENDING":
            try:
                value = json.loads(text.splitlines()[-1])
            except json.JSONDecodeError as exc:
                raise RunFault("launcher-process", "observer result is malformed") from exc
            if (
                value.get("PID") != pid
                or value.get("HandleRetained") is not True
                or "ExitCode" not in value
                or value.get("CreationFileTimeUtc") != expected_creation_filetime
            ):
                handoff.ssh(
                    f"if (Test-Path -LiteralPath {ps_quote(attached_observer_path)}) {{ Copy-Item -LiteralPath {ps_quote(attached_observer_path)} -Destination {ps_quote(attached_guest_path)} -Force }}; "
                    f"if (Test-Path -LiteralPath {ps_quote(failure_path)}) {{ Copy-Item -LiteralPath {ps_quote(failure_path)} -Destination {ps_quote(failure_guest_path)} -Force }}; "
                    f"Remove-Item -LiteralPath {ps_quote(observer_root)} -Recurse -Force -ErrorAction SilentlyContinue"
                )
                raise RunFault("launcher-process", f"observer did not prove the requested process exit: {value.get('Error', 'invalid exit result')}")
            handoff.ssh(
                f"Copy-Item -LiteralPath {ps_quote(attached_observer_path)} -Destination {ps_quote(attached_guest_path)} -Force; "
                f"Copy-Item -LiteralPath {ps_quote(exit_path)} -Destination {ps_quote(exit_guest_path)} -Force; "
                f"Remove-Item -LiteralPath {ps_quote(observer_root)} -Recurse -Force"
            )
            return value
        time.sleep(0.5)
    raise RunFault("launcher-process-timeout", f"retained-handle observer did not record exit for process {pid}")


def direct_exit_fields(interactive_launcher_exit: int, transaction_child_exit: int) -> dict[str, int]:
    """Name the waited PowerShell process separately from run.py's caller receipt."""
    return {
        "interactiveLauncherExit": interactive_launcher_exit,
        "transactionChildExit": transaction_child_exit,
    }


def extract_evidence_zip(archive: Path, destination: Path) -> None:
    """Extract guest evidence with Windows-separator traversal checks."""
    if destination.exists() and any(destination.iterdir()):
        raise RunFault("evidence-path", "evidence extraction destination must be empty")
    destination.mkdir(parents=True, exist_ok=True)
    try:
        with zipfile.ZipFile(archive) as bundle:
            for item in bundle.infolist():
                normalized = item.filename.replace("\\", "/")
                parts = Path(normalized).parts
                if (
                    normalized.startswith("/")
                    or re.match(r"^[A-Za-z]:/", normalized)
                    or any(part in ("", ".", "..") for part in parts)
                ):
                    raise RunFault("evidence-archive", f"unsafe evidence member path: {item.filename!r}")
                mode = item.external_attr >> 16
                if mode & 0o170000 == 0o120000:
                    raise RunFault("evidence-archive", f"symbolic links are not allowed in evidence archive: {item.filename!r}")
                target = destination.joinpath(*parts)
                if not target.resolve().is_relative_to(destination.resolve()):
                    raise RunFault("evidence-archive", "evidence archive member escapes the extraction destination")
                if item.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.open(item) as source, target.open("xb") as output:
                        while chunk := source.read(1024 * 1024):
                            output.write(chunk)
    except (OSError, zipfile.BadZipFile, RuntimeError) as exc:
        raise RunFault("evidence-archive", "guest evidence archive is invalid or incomplete") from exc


def collect_guest_run(
    handoff: Handoff, remote_root: str, remote_zip: str, local_root: Path
) -> str:
    if not (
        re.fullmatch(r"C:\\crabbox\\work\\ticket569\\cases", remote_root, re.IGNORECASE)
        or re.fullmatch(r"C:\\crabbox\\work\\ticket569\\cases\\[A-Za-z0-9_-]+", remote_root, re.IGNORECASE)
    ):
        raise RunFault("collect-path", "guest evidence path is outside the isolated Ticket 569 work root")
    root_path = Path(remote_root.replace("\\", "/"))
    zip_path = Path(remote_zip.replace("\\", "/"))
    if zip_path.parent != root_path.parent or zip_path.suffix.lower() != ".zip" or zip_path.stem != root_path.name:
        raise RunFault("collect-path", "guest archive must be a sibling named after the owned run directory")
    remote_script = f"""
$ErrorActionPreference='Stop'
$root='{remote_root}'
$zip='{remote_zip}'
if (!(Test-Path -LiteralPath $root -PathType Container)) {{ throw 'Owned case output directory is absent' }}
if (Test-Path -LiteralPath $zip) {{ throw 'Owned evidence archive path already exists' }}
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {{
  [pscustomobject]@{{ Path=$_.FullName.Substring($root.Length).TrimStart('\\'); Length=$_.Length; SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }}
}})
if ($files | Where-Object Path -eq 'evidence-index.json') {{ throw 'Guest output already contains a stale evidence index' }}
$index = @{{ SchemaVersion=1; Files=$files }} | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $root 'evidence-index.json'), $index + "`n", [Text.UTF8Encoding]::new($false))
Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip -CompressionLevel Optimal
(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"""
    result = handoff.ssh(remote_script, timeout_seconds=300)
    digest = result.stdout.strip().splitlines()[-1].lower()
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise RunFault("collect-hash", "guest did not return a valid archive SHA-256")
    download_dir = local_root.parent / (local_root.name + ".download")
    if download_dir.exists():
        raise RunFault("collect-path", "fresh local evidence download path already exists")
    handoff.pull(remote_zip, download_dir, timeout_seconds=300)
    archives = [path for path in download_dir.rglob("*") if path.is_file()]
    if len(archives) != 1:
        raise RunFault("collect-file", "handoff pull did not return exactly one guest evidence archive")
    local_digest = hashlib.sha256(archives[0].read_bytes()).hexdigest()
    if local_digest != digest:
        raise RunFault("collect-hash", "downloaded evidence archive differs from the guest hash")
    extract_evidence_zip(archives[0], local_root)
    verify_evidence_index(local_root)
    return digest


def verify_evidence_index(root: Path) -> None:
    try:
        index = json.loads((root / "evidence-index.json").read_text(encoding="utf-8"))
        records = index["Files"]
    except (OSError, UnicodeError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise RunFault("evidence-index", "guest evidence index is absent or malformed") from exc
    if index.get("SchemaVersion") != 1 or not isinstance(records, list):
        raise RunFault("evidence-index", "guest evidence index schema is unsupported")
    expected = {}
    for record in records:
        try:
            relative = Path(str(record["Path"]).replace("\\", "/"))
            length = int(record["Length"])
            digest = str(record["SHA256"]).lower()
        except (KeyError, TypeError, ValueError) as exc:
            raise RunFault("evidence-index", "guest evidence index contains an invalid record") from exc
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or relative.as_posix().casefold() in {key.casefold() for key in expected}
            or length < 0
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
        ):
            raise RunFault("evidence-index", "guest evidence index has unsafe or duplicate paths")
        expected[relative.as_posix()] = (length, digest)
    actual = {
        path.relative_to(root).as_posix(): (path.stat().st_size, hashlib.sha256(path.read_bytes()).hexdigest())
        for path in root.rglob("*") if path.is_file() and path.name != "evidence-index.json"
    }
    if actual != expected:
        raise RunFault("evidence-index", "guest file lengths or hashes differ from the downloaded evidence")
