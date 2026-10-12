"""Execute production PowerShell cleanup/error paths; these checks do not consent to a native root deletion."""
import base64
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


POWERSHELL = shutil.which("powershell.exe") or shutil.which("pwsh")
SCRIPTS = Path(__file__).resolve().parent


@unittest.skipUnless(POWERSHELL, "PowerShell is absent")
class RunCleanupTests(unittest.TestCase):
    def invoke(self, script):
        encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
        return subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
                              text=True, capture_output=True, timeout=30, check=False)

    def test_actual_post_mapi_block_preserves_outcomes_and_sanitizes_trace(self):
        result = subprocess.run([
            POWERSHELL, "-NoProfile", "-NonInteractive", "-File", str(SCRIPTS / "post-mapi-phase-tests.ps1"),
        ], text=True, capture_output=True, timeout=30, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("POST_MAPI_SANITIZED_PHASE_CONTROL_PASSED", result.stdout)

    def test_actual_finally_retains_transaction_and_terminating_cleanup_errors(self):
        # Execute the actual production finally AST, with only the two failing external operations controlled.
        # This reproduces the terminating exception shape that escaped finally in native799.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script_path = str(SCRIPTS / "run-user.ps1").replace("'", "''")
            run_root = str(root).replace("'", "''")
            script = f"""$ErrorActionPreference='Stop'
$RunRoot='{run_root}'; $runId='cleanup-regression'; $certificateSubject="CN=Ticket 569 synthetic CA $runId"
$runError='original transaction failure'; $certificateThumbprint='0000000000000000000000000000000000000000'
$app=$null; $fake=$null; $control=$null; $queueWatcher=$null; $queueEventRegistrations=@()
$credentialAttempted=$false; $initialQueueKnown=$false; $queue=Join-Path $RunRoot 'missing-queue'
$ErrorFile=Join-Path $RunRoot 'transaction-error.json'
$env:APPDATA=$RunRoot
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile('{script_path}', [ref]$tokens, [ref]$errors)
if ($errors.Count) {{ throw 'Production source did not parse' }}
$write=$ast.Find({{param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-AtomicJson'}}, $true)
Invoke-Expression $write.Extent.Text
$trace=$ast.Find({{param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-PostMapiPhase'}}, $true)
Invoke-Expression $trace.Extent.Text
function Remove-RunScopedCertificate {{ throw [InvalidOperationException]::new('UI is not allowed in this operation') }}
function Get-ChildItem {{ throw 'controlled final root inventory failure' }}
$mainTry=@($ast.EndBlock.Statements | Where-Object {{$_ -is [Management.Automation.Language.TryStatementAst]}})[0]
& ([scriptblock]::Create($mainTry.Finally.Extent.Text.Trim().Substring(1).TrimEnd().TrimEnd('}}')))
"""
            result = self.invoke(script)
            self.assertEqual(result.returncode, 0, result.stderr)
            cleanup = json.loads((root / "cleanup.json").read_text())
            failure = json.loads((root / "transaction-error.json").read_text())
            self.assertFalse(cleanup["Completed"])
            self.assertFalse(cleanup["SyntheticRootAbsent"])
            self.assertEqual(cleanup["TransactionError"], "original transaction failure")
            self.assertEqual(failure["TransactionError"], "original transaction failure")
            self.assertEqual(len(failure["CleanupErrors"]), 2)
            self.assertIn("UI is not allowed", failure["Error"])
            self.assertIn("inventory failure", failure["Error"])

    def test_actual_removal_helper_refuses_another_subject_and_writes_failure_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = subprocess.run([
                POWERSHELL, "-NoProfile", "-NonInteractive", "-File", str(SCRIPTS / "remove-run-certificate.ps1"),
                "-RunRoot", str(root), "-RunId", root.name, "-Subject", "CN=unowned root",
                "-Thumbprint", "0000000000000000000000000000000000000000",
            ], text=True, capture_output=True, timeout=30, check=False)
            self.assertNotEqual(result.returncode, 0)
            receipt = json.loads((root / "trust-remove-child.json").read_text())
            self.assertFalse(receipt["Completed"])
            self.assertFalse(receipt["Requested"])
            self.assertIn("exact run-owned synthetic CA", receipt["Error"])
            self.assertFalse((root / "trust-remove-request.json").exists())
