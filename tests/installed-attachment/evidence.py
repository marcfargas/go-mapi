"""Fail-closed process and result handling shared by the installed-MSI runner."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence


class RunFault(RuntimeError):
    def __init__(self, kind: str, message: str, returncode: int | None = None):
        super().__init__(message)
        self.kind = kind
        self.returncode = returncode


@dataclass(frozen=True)
class ChildResult:
    argv: tuple[str, ...]
    returncode: int
    elapsed_seconds: float
    stdout_path: Path
    stderr_path: Path


def run_bounded(
    argv: Sequence[str],
    *,
    cwd: Path,
    timeout_seconds: float,
    stdout_path: Path,
    stderr_path: Path,
    env: dict[str, str] | None = None,
    require_success: bool = True,
) -> ChildResult:
    """Wait for the real child exit and kill its whole process group on timeout."""
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    stderr_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    creation: dict[str, object] = {}
    if os.name == "nt":
        creation["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        creation["start_new_session"] = True
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        process = subprocess.Popen(
            list(argv), cwd=cwd, env=env, stdout=stdout, stderr=stderr, **creation
        )
        try:
            returncode = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired as exc:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                    timeout=10,
                )
            else:
                os.killpg(process.pid, signal.SIGKILL)
            returncode = process.wait(timeout=10)
            raise RunFault(
                "timeout",
                f"child timed out after {timeout_seconds}s; actual exit {returncode}",
                returncode,
            ) from exc
    result = ChildResult(
        tuple(argv), returncode, time.monotonic() - started, stdout_path, stderr_path
    )
    if require_success and returncode != 0:
        raise RunFault("child-failure", f"child exited {returncode}", returncode)
    return result


def read_final_snapshot(path: Path, run_id: str) -> dict:
    """Reject absent, truncated, stale, intermediate, or contradictory fake results."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RunFault("missing-result", f"final fake snapshot is absent: {path}") from exc
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise RunFault("invalid-result", f"final fake snapshot cannot be read: {path}") from exc
    required = {
        "schemaVersion",
        "runId",
        "final",
        "requests",
        "draftAttempts",
        "acceptedDrafts",
        "rejectedRequests",
        "failed",
        "errors",
        "drafts",
    }
    if not isinstance(value, dict) or not required.issubset(value):
        raise RunFault("invalid-result", "final fake snapshot is missing required fields")
    if value["schemaVersion"] != 1 or value["runId"] != run_id or value["final"] is not True:
        raise RunFault("invalid-result", "final fake snapshot identity is stale or incomplete")
    counters = [
        value[key]
        for key in ("requests", "draftAttempts", "acceptedDrafts", "rejectedRequests")
    ]
    if any(not isinstance(number, int) or number < 0 for number in counters):
        raise RunFault("invalid-result", "final fake snapshot has invalid counters")
    if value["failed"] or value["errors"] or value["rejectedRequests"]:
        raise RunFault("fake-failure", "fake recorded an irreversible failed request")
    if value["draftAttempts"] != 1 or value["acceptedDrafts"] != 1 or len(value["drafts"]) != 1:
        raise RunFault("draft-count", "the exact one-draft oracle did not hold")
    return value


def finalize_result(
    *,
    primary_error: RunFault | None,
    cleanup: Callable[[], None],
) -> RunFault | None:
    """Cleanup failure overrides a prior success while preserving any earlier fault."""
    cleanup_error: BaseException | None = None
    try:
        cleanup()
    except BaseException as exc:  # cleanup must run even after KeyboardInterrupt
        cleanup_error = exc
    if cleanup_error is not None:
        return RunFault(
            "cleanup-failure",
            f"cleanup failed: {cleanup_error}; primary={primary_error or 'none'}",
        )
    return primary_error
