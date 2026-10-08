#!/usr/bin/env python3
"""Run one installed-suite case from an actual interactive standard-user session."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import uuid
from pathlib import Path

from evidence import RunFault, read_final_snapshot, run_bounded
from host_backend import (
    Handoff,
    collect_guest_run,
    direct_exit_fields,
    launch_interactive_script,
    start_guest_process_observer,
    wait_for_guest_process_exit,
    wait_for_guest_result,
)
from rdpilot_session import RdpilotSession


FIXTURES = {
    "report.txt": b"exact attachment\r\nwith bytes\x00",
    "image.bin": bytes((0, 1, 2, 253, 254, 255)),
}
SUBJECT = "Ticket569 installed Windows seam"
RECIPIENT = "test@example.invalid"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    temp.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    os.replace(temp, path)


def build_fake(source_root: Path, destination: Path) -> None:
    env = os.environ.copy()
    env.update({"GOOS": "windows", "GOARCH": "amd64", "GOWORK": "off"})
    result = subprocess.run(
        ["go", "build", "-trimpath", "-o", str(destination), "."],
        cwd=source_root / "tests" / "installed-attachment" / "fake-gmail",
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise RunFault("build-failure", f"fake helper build failed ({result.returncode})")
    if not destination.is_file():
        raise RunFault("build-failure", "Go returned success but did not create fake helper")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-sha", required=True, help="exact clean checkout commit being exercised")
    parser.add_argument("--source-archive", type=Path, help="staged git-archive file when the guest checkout has no .git")
    parser.add_argument("--source-archive-sha256", help="SHA-256 bound to the staged source archive")
    parser.add_argument("--run-root", type=Path, help="fresh, empty per-case output directory")
    parser.add_argument("--profile-kind", choices=("normal", "mount-point"))
    parser.add_argument("--expected-profile-path")
    parser.add_argument("--expected-vhd-path")
    parser.add_argument("--app-path", default=r"C:\Program Files\go-mapi\user\go-mapi.exe", help="suite-installed user app path")
    parser.add_argument("--x64-dll-path", default=r"C:\Program Files\go-mapi\interceptor\AMD64\go-mapi.dll", help="suite-installed x64 interceptor path")
    parser.add_argument("--expected-app-sha256")
    parser.add_argument("--expected-dll-sha256")
    parser.add_argument("--fake-binary", type=Path, help="Windows fake helper built from this source")
    parser.add_argument("--historical-alpha7", action="store_true", help="accept only the specific historical attachment-path rejection")
    parser.add_argument("--timeout-seconds", type=float, default=240)
    parser.add_argument("--verify-matrix", nargs=3, type=Path, metavar=("ALPHA7_MOUNT", "CANDIDATE_MOUNT", "CANDIDATE_NORMAL"), help="verify and combine the three complete case directories")
    parser.add_argument("--matrix-report", type=Path, help="fresh aggregate output path for --verify-matrix")
    parser.add_argument("--backend", choices=("interactive-local", "crabbox-matrix"), default="interactive-local")
    parser.add_argument("--evidence-dir", type=Path, help="fresh host-side output directory for the full CrabBox matrix")
    parser.add_argument("--handoff-status", type=Path, help="active CrabBox ready-handoff status file")
    parser.add_argument("--cua-session", help="owned persistent rdpilot session name")
    parser.add_argument("--rdp-port", type=int, help="loopback RDP tunnel port exposed by this handoff")
    parser.add_argument("--baseline-msi", type=Path, help="published immutable suite alpha.7 MSI")
    parser.add_argument("--baseline-msi-sha256")
    parser.add_argument("--baseline-app-sha256")
    parser.add_argument("--baseline-dll-sha256")
    parser.add_argument("--candidate-msi", type=Path, help="published immutable fixed prerelease MSI")
    parser.add_argument("--candidate-msi-sha256")
    parser.add_argument("--candidate-app-sha256")
    parser.add_argument("--candidate-dll-sha256")
    parser.add_argument("--webview-bootstrapper", type=Path)
    parser.add_argument("--webview-sha256")
    parser.add_argument("--remote-work-root", default=r"C:\crabbox\work\ticket569")
    parser.add_argument("--case-timeout-seconds", type=float, default=240)
    return parser.parse_args()


def current_commit(source_root: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(source_root), "rev-parse", "HEAD"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise RunFault("source-identity", "could not resolve source commit")
    return result.stdout.strip()


def validate_source(
    source_root: Path,
    expected_sha: str,
    archive_path: Path | None = None,
    archive_sha256: str | None = None,
) -> str | None:
    if not re.fullmatch(r"[0-9a-fA-F]{40,64}", expected_sha):
        raise RunFault("source-identity", "--source-sha must be a full Git commit object ID")
    git_dir = source_root / ".git"
    if git_dir.exists():
        if current_commit(source_root) != expected_sha:
            raise RunFault("source-identity", "working checkout HEAD differs from --source-sha")
        status = subprocess.run(
            ["git", "-C", str(source_root), "status", "--porcelain", "--untracked-files=all"],
            text=True,
            capture_output=True,
            check=False,
        )
        if status.returncode or status.stdout.strip():
            raise RunFault("source-identity", "source checkout must be clean before a test run")
    else:
        if archive_path is None or archive_sha256 is None:
            raise RunFault("source-identity", "a staged checkout without .git requires --source-archive and its digest")
    if archive_path is not None or archive_sha256 is not None:
        if archive_path is None or archive_sha256 is None or not re.fullmatch(r"[0-9a-fA-F]{64}", archive_sha256):
            raise RunFault("source-identity", "source archive path and 64-character SHA-256 must be supplied together")
        try:
            digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        except OSError as exc:
            raise RunFault("source-identity", "source archive cannot be read") from exc
        if digest != archive_sha256.lower():
            raise RunFault("source-identity", "source archive digest differs from its explicit identity")
        return digest
    return None


def candidate_pass(run_root: Path, run_id: str, app_sha: str, dll_sha: str, profile_kind: str) -> dict:
    try:
        snapshot = read_final_snapshot(run_root / "fake-final.json", run_id)
    except RunFault as exc:
        raise exc
    app = json.loads((run_root / "installed-app.json").read_text(encoding="utf-8"))
    mapi = json.loads((run_root / "mapi-result.json").read_text(encoding="utf-8"))
    launcher = json.loads((run_root / "launcher-result.json").read_text(encoding="utf-8"))
    cleanup = json.loads((run_root / "cleanup.json").read_text(encoding="utf-8"))
    profile = json.loads((run_root / "profile-before.json").read_text(encoding="utf-8"))
    if app["SHA256"] != app_sha.lower() or app["DLLSHA256"] != dll_sha.lower():
        raise RunFault("installed-bytes", "running app or interceptor bytes differ from package manifest")
    if mapi["Return"] != 0 or launcher["ChildExitCode"] != 0:
        raise RunFault("native-or-child-exit", "native MAPI or waited transaction child did not exit successfully")
    if profile["Admin"] or profile["SessionId"] == 0 or not profile["Loaded"]:
        raise RunFault("profile-identity", "transaction did not run in the actual non-admin interactive profile")
    if profile_kind == "mount-point":
        if profile["ProfileKind"] != "mount-point" or profile["ReparseTag"] != "0xA0000003" or not profile["Vhd"]:
            raise RunFault("profile-identity", "actual profile lacks VHD volume mount-point evidence")
    elif profile["ProfileKind"] != "normal" or profile["ReparseTag"] is not None:
        raise RunFault("profile-identity", "normal profile unexpectedly reports a mount point")
    if not cleanup["Completed"] or not cleanup["CredentialAbsent"] or not cleanup["SyntheticRootAbsent"]:
        raise RunFault("cleanup-failure", "synthetic credential or trust cleanup failed")
    if snapshot["userInfoRequests"] != 1 or snapshot["draftRequests"] != 1:
        raise RunFault("fake-count", "fake endpoint request counts differ from exactly one userinfo and draft")
    queue_before_stop = json.loads((run_root / "queue-before-stop.json").read_text(encoding="utf-8"))
    if not terminal_queue_acknowledged(queue_before_stop):
        raise RunFault("queue-ack", "accepted draft lacks a terminal queue entry acknowledgement before app stop")
    queue = json.loads((run_root / "queue-after-stop.json").read_text(encoding="utf-8"))
    if queue.get("inspected") is not True or queue_files(queue):
        raise RunFault("queue", "isolated queue contains files after the installed app stopped")
    draft = snapshot["drafts"][0]
    if draft["subject"] != SUBJECT or RECIPIENT not in draft["recipient"]:
        raise RunFault("draft-envelope", "final fake draft envelope differs from the expected message")
    actual = {item["name"]: item["sha256"] for item in draft["attachments"]}
    expected = {name: sha256(data) for name, data in FIXTURES.items()}
    if actual != expected:
        raise RunFault("draft-attachments", "final fake attachment names or exact byte hashes differ")
    return {"snapshot": snapshot, "app": app, "mapi": mapi, "launcher": launcher, "cleanup": cleanup, "profile": profile}


def historical_rejection(run_root: Path, run_id: str, app_sha: str, dll_sha: str, profile_kind: str) -> dict:
    app = json.loads((run_root / "installed-app.json").read_text(encoding="utf-8"))
    mapi = json.loads((run_root / "mapi-result.json").read_text(encoding="utf-8"))
    launcher = json.loads((run_root / "launcher-result.json").read_text(encoding="utf-8"))
    cleanup = json.loads((run_root / "cleanup.json").read_text(encoding="utf-8"))
    profile = json.loads((run_root / "profile-before.json").read_text(encoding="utf-8"))
    errors = json.loads((run_root / "queue-archive.json").read_text(encoding="utf-8"))
    fake = json.loads((run_root / "fake-final.json").read_text(encoding="utf-8"))
    if app["SHA256"] != app_sha.lower() or app["DLLSHA256"] != dll_sha.lower():
        raise RunFault("historical-bytes", "alpha.7 app or interceptor bytes differ from its published package")
    if mapi["Return"] != 0 or launcher["ChildExitCode"] == 0:
        raise RunFault("historical-oracle", "the candidate-success transaction did not fail after native MAPI publication")
    if profile_kind != "mount-point" or profile["ProfileKind"] != "mount-point" or profile["ReparseTag"] != "0xA0000003" or not profile["Vhd"] or not profile["Loaded"] or profile["Admin"] or profile["SessionId"] == 0:
        raise RunFault("historical-profile", "failure did not run in the actual non-admin VHD mount-point profile")
    if fake["runId"] != run_id or fake["final"] is not True or fake["failed"] or fake["draftAttempts"] != 0 or fake["acceptedDrafts"] != 0:
        raise RunFault("historical-fake", "alpha.7 did not fail the same exact one-draft assertion with zero fake drafts")
    if fake.get("userInfoRequests") != 1 or fake.get("draftRequests") != 0:
        raise RunFault("historical-fake", "alpha.7 did not reach the fake and fail before a draft request")
    if not errors["InitiallyEmpty"] or not errors["ArchivedFiles"]:
        raise RunFault("historical-queue", "alpha.7 failed descriptor/error evidence was not retained from a clean queue")
    archived = run_root / "queue-final" / "errors"
    if not archived.exists() or not any(path.is_file() for path in archived.rglob("*")):
        raise RunFault("historical-queue", "the archived alpha.7 queue has no failed message")
    texts = []
    app_log = run_root / "app.log"
    if app_log.is_file():
        texts.append(app_log.read_text(encoding="utf-8", errors="replace"))
    for path in archived.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".json", ".txt", ".log"}:
            texts.append(path.read_text(encoding="utf-8", errors="replace"))
    joined = "\n".join(texts).lower()
    if not re.search(r"resolve attachment directory", joined):
        raise RunFault("historical-cause", "archived app/queue evidence lacks the attachment-directory resolution failure")
    if not cleanup["Completed"]:
        raise RunFault("cleanup-failure", "historical expected-failure run did not clean its synthetic state")
    return {"candidateAssertion": "failed", "historicalOutcome": "expected-alpha7-attachment-directory-rejection", "app": app, "mapi": mapi, "launcher": launcher, "cleanup": cleanup, "profile": profile, "fake": fake}


def verify_matrix(paths: tuple[Path, Path, Path], source_sha: str) -> dict:
    reports = []
    for path in paths:
        report_path = path / "execution-final.json"
        try:
            report = json.loads(report_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RunFault("matrix-evidence", f"missing or invalid case result: {report_path}") from exc
        if report.get("sourceSHA") != source_sha or report.get("runId") != path.name:
            raise RunFault("matrix-identity", f"case source/run identity mismatch: {path}")
        reports.append(report)
    historical, candidate_mount, candidate_normal = reports
    if historical.get("outcome") != "expected-alpha7-attachment-directory-rejection" or historical.get("candidateOracle") != "failed":
        raise RunFault("matrix-alpha7", "fresh alpha.7 case did not prove the expected candidate-oracle failure")
    if candidate_mount.get("outcome") != "passed" or candidate_normal.get("outcome") != "passed":
        raise RunFault("matrix-candidate", "both fixed installed candidate profile cases must pass")
    if candidate_mount["appSHA256"] != candidate_normal["appSHA256"] or candidate_mount["x64DllSHA256"] != candidate_normal["x64DllSHA256"]:
        raise RunFault("matrix-package", "fixed candidate app/DLL hashes differ between normal and mounted cases")
    archive_hashes = {report.get("sourceArchiveSHA256") for report in reports}
    if len(archive_hashes) != 1:
        raise RunFault("matrix-source", "matrix cases do not share one staged source archive identity")
    profiles = [report["result"]["profile"] for report in reports]
    sids = {profile["SID"] for profile in profiles}
    profile_paths = {profile["UserProfile"] for profile in profiles}
    if len(sids) != 1 or len(profile_paths) != 1 or any(profile["Admin"] or profile["SessionId"] == 0 or not profile["Loaded"] for profile in profiles):
        raise RunFault("matrix-user", "all three cases must use the same loaded non-admin user profile in real interactive sessions")
    if profiles[0]["ProfileKind"] != "mount-point" or profiles[0]["ReparseTag"] != "0xA0000003" or not profiles[0]["Vhd"]:
        raise RunFault("matrix-alpha7-profile", "alpha.7 rejection did not use an actual VHD volume mount point")
    if profiles[1]["ProfileKind"] != "mount-point" or profiles[1]["ReparseTag"] != "0xA0000003" or not profiles[1]["Vhd"]:
        raise RunFault("matrix-candidate-profile", "candidate mounted-profile pass lacks actual VHD mount-point evidence")
    if profiles[2]["ProfileKind"] != "normal" or profiles[2]["ReparseTag"] is not None:
        raise RunFault("matrix-normal-profile", "candidate normal-profile pass used a reparse profile")
    for report in reports:
        if not report["result"]["cleanup"]["Completed"]:
            raise RunFault("matrix-cleanup", "a case lacks verified synthetic cleanup")
    return {
        "schemaVersion": 1,
        "passed": True,
        "sourceSHA": source_sha,
        "sourceArchiveSHA256": next(iter(archive_hashes)),
        "matrix": [str(path) for path in paths],
        "userSID": next(iter(sids)),
        "actualProfilePath": next(iter(profile_paths)),
        "historicalAlpha7": "expected attachment-directory resolution rejection",
        "candidateVHD": "pass",
        "candidateNormal": "pass",
        "candidateAppSHA256": candidate_mount["appSHA256"],
        "candidateX64DllSHA256": candidate_mount["x64DllSHA256"],
    }


def powershell_quote(value: str | Path) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def archive_source(source_root: Path, source_sha: str, destination: Path) -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["git", "-C", str(source_root), "archive", "--format=zip", "--output", str(destination), source_sha],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode or not destination.is_file():
        raise RunFault("source-archive", f"git archive failed with exit {result.returncode}", result.returncode)
    return hashlib.sha256(destination.read_bytes()).hexdigest()


def remote_file_json(handoff: Handoff, path: str, timeout_seconds: float = 20) -> dict | None:
    script = f"$p={powershell_quote(path)}; if (Test-Path -LiteralPath $p -PathType Leaf) {{ Get-Content -LiteralPath $p -Raw }} else {{ 'TICKET569_PENDING' }}"
    result = handoff.ssh(script, timeout_seconds=timeout_seconds)
    value = result.stdout.strip()
    if value == "TICKET569_PENDING":
        return None
    try:
        return json.loads(value)
    except json.JSONDecodeError as exc:
        raise RunFault("guest-result", f"guest JSON file is malformed: {Path(path).name}") from exc


def wait_interactive_json(
    handoff: Handoff,
    cua: RdpilotSession,
    remote_path: str,
    output_path: Path,
    timeout_seconds: float = 60,
) -> dict:
    started = time.monotonic()
    deadline = started + timeout_seconds
    while time.monotonic() < deadline:
        value = remote_file_json(handoff, remote_path)
        if value is not None:
            atomic_json(output_path, value)
            return value
        time.sleep(0.5)
    raise RunFault("interactive-timeout", f"interactive identity did not write {Path(remote_path).name}")


def queue_files(value: dict) -> list:
    """Read the lower-case queue inventory field emitted by PowerShell."""
    files = value.get("files")
    if not isinstance(files, list):
        raise RunFault("queue-protocol", "queue inventory must contain a files array")
    return files


def terminal_queue_acknowledged(value: dict) -> bool:
    """Require the same queue entry to be observed entering and leaving the queue."""
    events = value.get("events")
    if not isinstance(events, list):
        return False
    created: set[str] = set()
    deleted: set[str] = set()
    for event in events:
        if not isinstance(event, str) or "|" not in event:
            continue
        change, path = event.split("|", 1)
        path = path.casefold()
        if change in {"Created", "Renamed"}:
            created.add(path)
        elif change == "Deleted":
            deleted.add(path)
    return value.get("terminalAcknowledgement") is True and not queue_files(value) and bool(created & deleted)


def run_launcher_with_archived_logs(
    argv: list[str], *, cwd: Path, run_root: Path, timeout_seconds: float, require_success: bool
):
    """Keep host-side captures beside RunRoot until the interactive child exits."""
    log_root = run_root.parent / f".{run_root.name}.host-{uuid.uuid4().hex}"
    log_root.mkdir(mode=0o700, parents=False, exist_ok=False)
    stdout = log_root / "host.stdout.txt"
    stderr = log_root / "host.stderr.txt"
    try:
        return run_bounded(
            argv,
            cwd=cwd,
            timeout_seconds=timeout_seconds,
            stdout_path=stdout,
            stderr_path=stderr,
            require_success=require_success,
        )
    finally:
        if stdout.exists():
            os.replace(stdout, run_root / "host.stdout.txt")
        if stderr.exists():
            os.replace(stderr, run_root / "host.stderr.txt")
        log_root.rmdir()


def remote_script(handoff: Handoff, path: str, parameters: dict[str, str], timeout: float = 300) -> None:
    invocation = "& " + powershell_quote(path)
    for key, value in parameters.items():
        invocation += f" -{key} {powershell_quote(value)}"
    handoff.ssh("$ErrorActionPreference='Stop'; " + invocation, timeout_seconds=timeout)


def prepare_crabbox_inputs(args: argparse.Namespace, source_root: Path) -> tuple[Path, str, Path]:
    assert args.evidence_dir
    evidence = args.evidence_dir
    if evidence.exists() and any(evidence.iterdir()):
        raise RunFault("evidence-path", "the full matrix evidence directory must be fresh and empty")
    evidence.mkdir(parents=True, exist_ok=True)
    if args.source_archive:
        if not args.source_archive_sha256:
            raise RunFault("source-archive", "a caller-provided source archive requires its explicit SHA-256")
        archive = args.source_archive
        archive_hash = validate_source(source_root, args.source_sha, archive, args.source_archive_sha256)
        assert archive_hash
        expected_archive = evidence / f"source-{args.source_sha[:12]}.verified.zip"
        expected_hash = archive_source(source_root, args.source_sha, expected_archive)
        if archive_hash != expected_hash:
            raise RunFault("source-archive", "provided archive does not contain the exact requested Git commit")
        expected_archive.unlink()
    else:
        validate_source(source_root, args.source_sha)
        archive = evidence / f"source-{args.source_sha[:12]}.zip"
        archive_hash = archive_source(source_root, args.source_sha, archive)
    return archive, archive_hash, evidence


def latch_matrix_cleanup(
    evidence: Path, errors: list[str], profile_state: str, guest_evidence_collected: bool
) -> None:
    cleanup = {
        "Completed": not errors and profile_state == "normal",
        "ProfileRestored": profile_state == "normal",
        "GuestEvidenceCollected": guest_evidence_collected,
        "Errors": list(errors),
    }
    try:
        atomic_json(evidence / "cleanup.json", cleanup)
    except Exception as exc:
        errors.append(f"cleanup result write failed: {type(exc).__name__}: {exc}")
    if errors or profile_state != "normal":
        matrix_report = evidence / "matrix-final.json"
        if matrix_report.is_file():
            try:
                prior = json.loads(matrix_report.read_text(encoding="utf-8"))
                prior.update({"passed": False, "cleanup": {"Completed": False, "Errors": list(errors)}})
                atomic_json(matrix_report, prior)
            except (OSError, json.JSONDecodeError) as exc:
                errors.append(f"matrix success report could not be failure-latched: {type(exc).__name__}")
    if errors or profile_state != "normal":
        raise RunFault("matrix-cleanup", "; ".join(errors) or "profile did not return to normal state")


def run_crabbox_matrix(args: argparse.Namespace, source_root: Path) -> int:
    required = (
        args.evidence_dir, args.handoff_status, args.cua_session, args.rdp_port,
        args.baseline_msi, args.baseline_msi_sha256, args.baseline_app_sha256, args.baseline_dll_sha256,
        args.candidate_msi, args.candidate_msi_sha256, args.candidate_app_sha256, args.candidate_dll_sha256,
        args.webview_bootstrapper, args.webview_sha256,
    )
    if any(value is None for value in required):
        raise RunFault("arguments", "crabbox-matrix requires handoff, CUA/RDP session, both immutable MSI inputs and all package hashes")
    for digest in (args.baseline_msi_sha256, args.baseline_app_sha256, args.baseline_dll_sha256, args.candidate_msi_sha256, args.candidate_app_sha256, args.candidate_dll_sha256):
        if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            raise RunFault("package-identity", "all package identities must be SHA-256 digests")
    archive, archive_hash, evidence = prepare_crabbox_inputs(args, source_root)
    handoff = Handoff.load(args.handoff_status)
    work_root = args.remote_work_root.rstrip("\\")
    if not re.fullmatch(r"C:\\crabbox\\work\\ticket569", work_root, re.IGNORECASE):
        raise RunFault("remote-path", "remote work root must be C:\\crabbox\\work\\ticket569")
    source_dir = work_root + r"\source-" + args.source_sha[:12]
    staging = work_root + r"\staging"
    fake_path = staging + r"\fake-gmail.exe"
    source_zip = work_root + r"\source-" + args.source_sha[:12] + ".zip"
    baseline_msi_guest = staging + r"\baseline.msi"
    candidate_msi_guest = staging + r"\candidate.msi"
    webview_guest = staging + r"\webview-bootstrapper.exe"
    handoff.ssh(
        f"$ErrorActionPreference='Stop'; "
        f"$root={powershell_quote(work_root)}; $staging={powershell_quote(staging)}; $source={powershell_quote(source_dir)}; $cases={powershell_quote(work_root + r'\cases')}; "
        "foreach ($path in @($staging,$source,$cases)) { if (Test-Path -LiteralPath $path) { throw 'Ticket569 guest work path already exists; refusing to reuse stale state' } }; "
        "New-Item -ItemType Directory -Path $root -Force | Out-Null; "
        "New-Item -ItemType Directory -Path $staging,$source,$cases | Out-Null"
    )
    handoff.push(archive, source_zip)
    handoff.push(args.baseline_msi, baseline_msi_guest)
    handoff.push(args.candidate_msi, candidate_msi_guest)
    handoff.push(args.webview_bootstrapper, webview_guest)
    fake_local = evidence / "fake-gmail.exe"
    build_fake(source_root, fake_local)
    fake_hash = hashlib.sha256(fake_local.read_bytes()).hexdigest()
    handoff.push(fake_local, fake_path)
    atomic_json(evidence / "staged-inputs.json", {
        "sourceSHA": args.source_sha, "sourceArchiveSHA256": archive_hash,
        "baselineMSISHA256": args.baseline_msi_sha256.lower(),
        "candidateMSISHA256": args.candidate_msi_sha256.lower(),
        "fakeSourceSHA": args.source_sha, "fakeBinarySHA256": fake_hash,
        "webviewBootstrapperSHA256": args.webview_sha256.lower(),
        "leaseId": handoff.lease_id,
    })
    handoff.ssh(
        f"$ErrorActionPreference='Stop'; Expand-Archive -LiteralPath {powershell_quote(source_zip)} -DestinationPath {powershell_quote(source_dir)} -Force; "
        f"if ((Get-FileHash -LiteralPath {powershell_quote(source_zip)} -Algorithm SHA256).Hash.ToLowerInvariant() -ne '{archive_hash}') {{ throw 'staged source archive hash mismatch' }}"
    )
    scripts = source_dir + r"\tests\installed-attachment"
    run_root = work_root + r"\cases"

    def record_event(name: str, value: dict) -> None:
        atomic_json(evidence / f"{name}.json", value)

    cua_number = 0

    def connect() -> RdpilotSession:
        nonlocal cua_number
        cua_number += 1
        session_evidence = evidence / f"cua-session-{cua_number}"
        handoff.rdpilot_connect(args.cua_session, args.rdp_port, session_evidence)
        client = RdpilotSession(args.cua_session, session_evidence)
        client.start()
        record_event(f"cua-session-{cua_number}-connected", {"session": args.cua_session, "leaseId": handoff.lease_id, "tools": sorted(client.tools)})
        return client

    def close_cua(client: RdpilotSession, label: str) -> None:
        exit_code = client.close()
        record_event(f"{label}-mcp-exit", {"ExitCode": exit_code, "Session": args.cua_session})

    def get_identity(client: RdpilotSession, tag: str) -> dict:
        identity_file = run_root + rf"\{tag}-identity.json"
        launch = launch_interactive_script(
            client, script_path=scripts + r"\identity.ps1", arguments=["-OutputPath", identity_file]
        )
        record_event(f"{tag}-identity-launch", launch)
        return wait_interactive_json(handoff, client, identity_file, evidence / f"{tag}-identity.json")

    def run_case(client: RdpilotSession, profile: dict, case: str, profile_kind: str, historical: bool, app_hash: str, dll_hash: str) -> dict:
        run_id = f"{case}-{uuid.uuid4().hex[:16]}"
        guest_root = run_root + "\\" + run_id
        guest_expected = run_root + "\\" + run_id + ".expected.json"
        local_root = evidence / run_id
        local_root.mkdir(parents=True, exist_ok=False)
        spec = {"runId": run_id, "subject": SUBJECT, "recipient": RECIPIENT, "attachments": {name: sha256(data) for name, data in FIXTURES.items()}}
        local_expected = local_root / "expected.json"
        atomic_json(local_expected, spec)
        handoff.ssh(f"$ErrorActionPreference='Stop'; New-Item -ItemType Directory -Path {powershell_quote(guest_root)} | Out-Null")
        handoff.push(local_expected, guest_expected)
        launcher = scripts + r"\launch-user.ps1"
        parameters = [
            "-RunRoot", guest_root, "-ExpectedJson", guest_expected,
            "-AppPath", args.app_path, "-X64DllPath", args.x64_dll_path,
            "-FakeBinary", fake_path, "-ProfileKind", profile_kind,
            "-ExpectedProfilePath", profile["UserProfile"],
        ]
        if profile_kind == "mount-point":
            parameters.extend(["-ExpectedVhdPath", vhd_path])
        launch = launch_interactive_script(client, script_path=launcher, arguments=parameters)
        record_event(f"{case}-launch", {"runId": run_id, "pid": launch.get("pid"), "profileKind": profile_kind})
        if not launch.get("pid"):
            raise RunFault("cua-launch", f"CUA did not return a process ID for case {case}")
        observer_attached = start_guest_process_observer(
            handoff,
            int(launch["pid"]),
            launcher,
            scripts + r"\process-observer.ps1",
            guest_root,
            attach_timeout_seconds=30,
            process_timeout_seconds=int(args.case_timeout_seconds + 30),
        )
        record_event(f"{case}-launcher-observer-attached", observer_attached)
        trust_subject = f"CN=Ticket 569 synthetic CA {run_id}"
        child = wait_for_guest_result(
            handoff, client, guest_root + r"\launcher-result.json", run_id, trust_subject,
            evidence / f"{case}-trust-prompt", timeout_seconds=args.case_timeout_seconds,
        )
        record_event(f"{case}-launcher-result", child)
        launcher_process_exit = wait_for_guest_process_exit(
            handoff,
            int(launch["pid"]),
            guest_root,
            int(observer_attached["CreationFileTimeUtc"]),
            timeout_seconds=args.case_timeout_seconds + 40,
        )
        if launcher_process_exit.get("CreationFileTimeUtc") != observer_attached.get("CreationFileTimeUtc"):
            raise RunFault("launcher-process", "retained handle exited a process with a different creation identity than the attached launcher")
        if int(launcher_process_exit["ExitCode"]) != int(child["ChildExitCode"]):
            raise RunFault("launcher-process", "retained-handle outer launcher exit differs from its waited transaction child exit")
        record_event(f"{case}-launcher-process-exit", launcher_process_exit)
        zip_digest = collect_guest_run(handoff, guest_root, run_root + "\\" + run_id + ".zip", local_root / "downloaded")
        record_event(f"{case}-archive", {"GuestArchiveSHA256": zip_digest})
        run_dir = local_root / "downloaded"
        if historical:
            if child.get("ChildExitCode") == 0:
                raise RunFault("historical-oracle", "fresh alpha.7 candidate-success assertion unexpectedly passed")
            outcome = historical_rejection(run_dir, run_id, app_hash, dll_hash, profile_kind)
        else:
            if child.get("ChildExitCode") != 0:
                raise RunFault("candidate-oracle", f"candidate installed transaction exited {child.get('ChildExitCode')}", child.get("ChildExitCode"))
            outcome = candidate_pass(run_dir, run_id, app_hash, dll_hash, profile_kind)
        report = {
            "schemaVersion": 1, "runId": run_id, "sourceSHA": args.source_sha,
            "sourceArchiveSHA256": archive_hash, "profileKind": profile_kind,
            "appSHA256": app_hash.lower(), "x64DllSHA256": dll_hash.lower(),
            "transactionChildExit": int(child["ChildExitCode"]),
            "cuaLaunchedLauncherProcessExit": launcher_process_exit,
            "candidateOracle": outcome.get("candidateAssertion", "passed"),
            "outcome": outcome.get("historicalOutcome", "passed"), "result": outcome,
        }
        atomic_json(local_root / "execution-final.json", report)
        return report

    cua: RdpilotSession | None = None
    rdp_connected = False
    active_identity: dict | None = None
    profile_state = "normal"
    cleanup_errors: list[str] = []
    matrix_archive_collected = False
    try:
        cua = connect()
        rdp_connected = True
        # Install and verify the unchanged historical package before converting the real profile.
        setup_args = {
            "PackageKind": "baseline", "MsiPath": baseline_msi_guest,
            "ExpectedMsiSHA256": args.baseline_msi_sha256,
            "InstalledAppPath": args.app_path, "InstalledDllPath": args.x64_dll_path,
            "ExpectedAppSHA256": args.baseline_app_sha256, "ExpectedDllSHA256": args.baseline_dll_sha256,
            "EvidenceDirectory": run_root + r"\setup-alpha7",
        }
        setup_args["WebViewBootstrapper"] = webview_guest
        setup_args["ExpectedWebViewSHA256"] = args.webview_sha256
        remote_script(handoff, scripts + r"\setup.ps1", setup_args)
        identity = get_identity(cua, "before-vhd")
        active_identity = identity
        profile_path, sid = identity["UserProfile"], identity["SID"]
        if identity["Admin"] or identity["SessionId"] == 0 or not identity["ProfileLoaded"]:
            raise RunFault("profile-identity", "initial CUA session is not the loaded standard-user interactive profile")
        close_cua(cua, "normal-before-vhd")
        cua = None
        handoff.rdpilot_disconnect(args.cua_session, evidence)
        rdp_connected = False
        logoff = handoff.logoff_user_session(int(identity["SessionId"]), sid)
        record_event("profile-unloaded-before-vhd", logoff)
        vhd_path = work_root + rf"\profile-{sid[-8:]}.vhdx"
        backup_path = profile_path + ".normal-backup"
        profile_state = "preparing"
        remote_script(handoff, scripts + r"\profile.ps1", {
            "Action": "prepare-vhd", "SID": sid, "ProfilePath": profile_path,
            "VhdPath": vhd_path, "BackupPath": backup_path, "EvidenceDirectory": run_root + r"\profile-vhd-prepare",
        })
        profile_state = "mounted"
        cua = connect()
        rdp_connected = True
        vhd_identity = get_identity(cua, "alpha7-vhd")
        active_identity = vhd_identity
        if vhd_identity["SID"] != sid or vhd_identity["UserProfile"] != profile_path or not vhd_identity["IsReparsePoint"]:
            raise RunFault("profile-vhd", "reconnected standard user does not use the same actual VHD-mounted profile")
        alpha7 = run_case(cua, vhd_identity, "alpha7-vhd", "mount-point", True, args.baseline_app_sha256, args.baseline_dll_sha256)
        setup_args = {
            "PackageKind": "candidate", "MsiPath": candidate_msi_guest,
            "ExpectedMsiSHA256": args.candidate_msi_sha256,
            "InstalledAppPath": args.app_path, "InstalledDllPath": args.x64_dll_path,
            "ExpectedAppSHA256": args.candidate_app_sha256, "ExpectedDllSHA256": args.candidate_dll_sha256,
            "ExpectedPriorAppSHA256": args.baseline_app_sha256, "ExpectedPriorDllSHA256": args.baseline_dll_sha256,
            "EvidenceDirectory": run_root + r"\setup-candidate",
        }
        remote_script(handoff, scripts + r"\setup.ps1", setup_args)
        candidate_vhd_identity = get_identity(cua, "candidate-vhd")
        active_identity = candidate_vhd_identity
        candidate_vhd = run_case(cua, candidate_vhd_identity, "candidate-vhd", "mount-point", False, args.candidate_app_sha256, args.candidate_dll_sha256)
        close_cua(cua, "candidate-vhd-before-restore")
        cua = None
        handoff.rdpilot_disconnect(args.cua_session, evidence)
        rdp_connected = False
        logoff = handoff.logoff_user_session(int(candidate_vhd_identity["SessionId"]), sid)
        record_event("profile-unloaded-before-restore", logoff)
        remote_script(handoff, scripts + r"\profile.ps1", {
            "Action": "restore-normal", "SID": sid, "ProfilePath": profile_path,
            "VhdPath": vhd_path, "BackupPath": backup_path, "EvidenceDirectory": run_root + r"\profile-restore",
        })
        profile_state = "normal"
        cua = connect()
        rdp_connected = True
        normal_identity = get_identity(cua, "candidate-normal")
        active_identity = normal_identity
        if normal_identity["SID"] != sid or normal_identity["UserProfile"] != profile_path or normal_identity["IsReparsePoint"]:
            raise RunFault("profile-normal", "restored standard user does not use the original normal profile")
        candidate_normal = run_case(cua, normal_identity, "candidate-normal", "normal", False, args.candidate_app_sha256, args.candidate_dll_sha256)
        reports = []
        for report in (alpha7, candidate_vhd, candidate_normal):
            path = evidence / report["runId"] / "execution-final.json"
            reports.append(json.loads(path.read_text(encoding="utf-8")))
        aggregate = verify_matrix(tuple(evidence / report["runId"] for report in reports), args.source_sha)
        aggregate["sourceArchiveSHA256"] = archive_hash
        aggregate["leaseId"] = handoff.lease_id
        aggregate["hostedCapability"] = "not-exercised-by-crabbox-backend"
        atomic_json(evidence / "matrix-final.json", aggregate)
        return 0
    finally:
        if cua is not None:
            try:
                close_cua(cua, "matrix-finally")
            except Exception as exc:
                cleanup_errors.append(f"CUA client close failed: {type(exc).__name__}: {exc}")
        if rdp_connected:
            try:
                handoff.rdpilot_disconnect(args.cua_session, evidence)
            except Exception as exc:
                cleanup_errors.append(f"rdpilot disconnect failed: {type(exc).__name__}: {exc}")
        if profile_state in {"preparing", "mounted"} and active_identity:
            try:
                observed_session = handoff.observed_user_session(str(active_identity["SID"]))
                logoff = handoff.logoff_user_session(observed_session, str(active_identity["SID"]))
                record_event("profile-unloaded-during-finally", logoff)
                remote_script(handoff, scripts + r"\profile.ps1", {
                    "Action": "restore-normal", "SID": str(active_identity["SID"]),
                    "ProfilePath": str(active_identity["UserProfile"]), "VhdPath": vhd_path,
                    "BackupPath": str(active_identity["UserProfile"]) + ".normal-backup",
                    "EvidenceDirectory": run_root + r"\profile-failure-restore",
                })
                profile_state = "normal"
            except Exception as exc:
                cleanup_errors.append(f"normal profile restoration failed: {type(exc).__name__}: {exc}")
        try:
            if evidence.exists() and not (evidence / "guest-matrix" / "evidence-index.json").exists():
                collect_guest_run(handoff, run_root, work_root + r"\cases.zip", evidence / "guest-matrix")
                matrix_archive_collected = True
            else:
                matrix_archive_collected = (evidence / "guest-matrix" / "evidence-index.json").is_file()
        except Exception as exc:
            cleanup_errors.append(f"guest evidence collection failed: {type(exc).__name__}: {exc}")
        latch_matrix_cleanup(evidence, cleanup_errors, profile_state, matrix_archive_collected)


def main() -> int:
    args = parse_args()
    source_root = Path(__file__).resolve().parents[2]
    run_id = args.run_root.name if args.run_root else "matrix"
    try:
        if args.backend == "crabbox-matrix":
            return run_crabbox_matrix(args, source_root)
        source_archive_sha256 = validate_source(
            source_root, args.source_sha, args.source_archive, args.source_archive_sha256
        )
        if args.verify_matrix:
            if not args.matrix_report:
                raise RunFault("matrix-report", "--matrix-report is required with --verify-matrix")
            if args.matrix_report.exists():
                raise RunFault("matrix-report", "aggregate report path already exists")
            if len({path.resolve() for path in args.verify_matrix}) != 3:
                raise RunFault("matrix-identity", "the matrix must reference three distinct case directories")
            matrix = verify_matrix(tuple(args.verify_matrix), args.source_sha)
            atomic_json(args.matrix_report, matrix)
            return 0
        required = (args.run_root, args.profile_kind, args.expected_profile_path, args.app_path, args.x64_dll_path, args.expected_app_sha256, args.expected_dll_sha256, args.fake_binary)
        if any(value is None for value in required):
            raise RunFault("arguments", "case mode requires run root, profile, installed paths/hashes and fake helper")
        if not re.fullmatch(r"[A-Za-z0-9_-]{12,80}", run_id):
            raise RunFault("run-id", "run output directory basename must be a unique safe run ID")
        if args.run_root.exists() and any(args.run_root.iterdir()):
            raise RunFault("output-directory", "run output directory must be fresh and empty")
        args.run_root.mkdir(parents=True, exist_ok=True)
        if not args.fake_binary.is_file():
            raise RunFault("fake-helper", "a Windows fake-gmail helper binary is required")
        expected_path = args.run_root.parent / (run_id + ".expected.json")
        spec = {
            "runId": run_id,
            "subject": SUBJECT,
            "recipient": RECIPIENT,
            "attachments": {name: sha256(data) for name, data in FIXTURES.items()},
        }
        atomic_json(expected_path, spec)
        if os.name != "nt":
            raise RunFault("wrong-host", "the transaction must be launched in a real Windows interactive session")
        repo = source_root
        script = repo / "tests" / "installed-attachment" / "launch-user.ps1"
        argv = [
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script),
            "-RunRoot", str(args.run_root), "-ExpectedJson", str(expected_path),
            "-AppPath", args.app_path, "-X64DllPath", args.x64_dll_path,
            "-FakeBinary", str(args.fake_binary), "-ProfileKind", args.profile_kind,
            "-ExpectedProfilePath", args.expected_profile_path,
        ]
        if args.profile_kind == "mount-point":
            if not args.expected_vhd_path:
                raise RunFault("profile-identity", "mounted profile mode requires --expected-vhd-path")
            argv.extend(["-ExpectedVhdPath", args.expected_vhd_path])
        result = run_launcher_with_archived_logs(
            argv,
            cwd=repo,
            run_root=args.run_root,
            timeout_seconds=args.timeout_seconds,
            require_success=not args.historical_alpha7,
        )
        transaction_child_exit = json.loads((args.run_root / "launcher-result.json").read_text(encoding="utf-8"))["ChildExitCode"]
        if int(transaction_child_exit) != int(result.returncode):
            raise RunFault("launcher-exit", "observed launcher process exit differs from the waited transaction child exit")
        if args.historical_alpha7:
            if result.returncode == 0:
                raise RunFault("historical-oracle", "alpha.7 unexpectedly passed candidate-success assertions")
            outcome = historical_rejection(
                args.run_root, run_id, args.expected_app_sha256, args.expected_dll_sha256, args.profile_kind
            )
        else:
            outcome = candidate_pass(
                args.run_root, run_id, args.expected_app_sha256, args.expected_dll_sha256, args.profile_kind
            )
        report = {
            "schemaVersion": 1,
            "runId": run_id,
            "sourceSHA": args.source_sha,
            "sourceArchiveSHA256": source_archive_sha256,
            "profileKind": args.profile_kind,
            "appSHA256": args.expected_app_sha256.lower(),
            "x64DllSHA256": args.expected_dll_sha256.lower(),
            **direct_exit_fields(result.returncode, transaction_child_exit),
            "candidateOracle": outcome.get("candidateAssertion", "passed"),
            "outcome": outcome.get("historicalOutcome", "passed"),
            "result": outcome,
        }
        atomic_json(args.run_root / "execution-final.json", report)
        return 0
    except RunFault as exc:
        failure_path = args.run_root or args.evidence_dir
        if failure_path is not None:
            atomic_json(failure_path / "execution-final.json", {"schemaVersion": 1, "runId": run_id, "sourceSHA": args.source_sha, "passed": False, "fault": exc.kind, "message": str(exc), "childExit": exc.returncode})
        print(f"FAIL {exc.kind}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
