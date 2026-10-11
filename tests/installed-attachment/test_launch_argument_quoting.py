"""CUA launch_app joins additional_arguments with spaces and no quoting (debug 769).

launch_interactive_script must pre-quote each argument so the observed join still yields the original argv
under Windows command-line rules (CommandLineToArgvW / MSVC argv parsing).
"""

from __future__ import annotations

import ctypes
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import host_backend  # noqa: E402

POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
SCRIPT = r"C:\crabbox\work\ticket569\source-010987240549\tests\installed-attachment\launch-user.ps1"
ARGUMENTS = [
    "-RunRoot", r"C:\crabbox\work\ticket569\cases\alpha7-vhd-a5def90b36504fd1",
    "-AppPath", r"C:\Program Files\go-mapi\user\go-mapi.exe",
    "-X64DllPath", r"C:\Program Files\go-mapi\interceptor\AMD64\go-mapi.dll",
    "-TrailingBackslash", "C:\\Program Files\\go-mapi\\",
    "-EmbeddedQuote", 'say "hi" now',
    "-Empty", "",
]


def windows_argv(command_line: str) -> list[str]:
    """Windows argv parsing: real CommandLineToArgvW on Windows, else the documented MSVC rules."""
    if sys.platform == "win32":
        from ctypes import wintypes

        shell32 = ctypes.WinDLL("shell32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        shell32.CommandLineToArgvW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_int)]
        shell32.CommandLineToArgvW.restype = ctypes.POINTER(wintypes.LPWSTR)
        kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
        kernel32.LocalFree.restype = wintypes.HLOCAL
        count = ctypes.c_int()
        argv = shell32.CommandLineToArgvW(command_line, ctypes.byref(count))
        if not argv:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            return [argv[i] for i in range(count.value)]
        finally:
            kernel32.LocalFree(ctypes.cast(argv, wintypes.HLOCAL))
    args: list[str] = []
    current: list[str] = []
    in_quotes = False
    started = False
    i = 0
    while i < len(command_line):
        char = command_line[i]
        if char == "\\":
            run = 0
            while i < len(command_line) and command_line[i] == "\\":
                run += 1
                i += 1
            if i < len(command_line) and command_line[i] == '"':
                current.append("\\" * (run // 2))
                if run % 2:
                    current.append('"')
                    i += 1
            else:
                current.append("\\" * run)
            started = True
            continue
        if char == '"':
            if in_quotes and i + 1 < len(command_line) and command_line[i + 1] == '"':
                current.append('"')
                i += 2
                continue
            in_quotes = not in_quotes
            started = True
        elif char in " \t" and not in_quotes:
            if started:
                args.append("".join(current))
                current, started = [], False
        else:
            current.append(char)
            started = True
        i += 1
    if started:
        args.append("".join(current))
    return args


def launched_arguments() -> list[str]:
    cua = MagicMock()
    cua.call.return_value = {"result": {"structuredContent": {"pid": 1}}}
    host_backend.launch_interactive_script(cua, script_path=SCRIPT, arguments=ARGUMENTS)
    name, payload = cua.call.call_args.args
    assert name == "launch_app" and payload["path"] == POWERSHELL
    return payload["additional_arguments"]


class LaunchArgumentQuotingTests(unittest.TestCase):
    def test_observed_unquoted_join_recovers_original_argv(self) -> None:
        # Observed CUA construction: "<path>" followed by the items joined with single spaces.
        command_line = f'"{POWERSHELL}" ' + " ".join(launched_arguments())
        self.assertEqual(windows_argv(command_line)[1:],
                         ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT, *ARGUMENTS])

    def test_unquoted_items_reproduce_the_769_split(self) -> None:
        # Control: the pre-fix raw items split C:\\Program Files at the space, as observed on Windows.
        raw = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT, *ARGUMENTS]
        split = windows_argv(f'"{POWERSHELL}" ' + " ".join(raw))[1:]
        self.assertIn("Files\\go-mapi\\user\\go-mapi.exe", split)

    def test_plain_arguments_are_unchanged(self) -> None:
        items = launched_arguments()
        self.assertEqual(items[:5], ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SCRIPT])


if __name__ == "__main__":
    unittest.main()
