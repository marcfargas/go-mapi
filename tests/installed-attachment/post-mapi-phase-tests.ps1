param([string] $EvidenceRoot)
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'run-user.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Production run-user source did not parse' }
foreach ($name in @('Write-AtomicJson', 'Write-PostMapiPhase', 'Get-QueueInventory')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Invoke-Expression $node.Extent.Text
}
$text = [IO.File]::ReadAllText($source)
$watcherStart = $text.IndexOf('    $queueEventsPath =')
$watcherEnd = $text.IndexOf('    Import-Module', $watcherStart)
$watcherBlock = $text.Substring($watcherStart, $watcherEnd - $watcherStart)
$pollStart = $text.IndexOf('    $draftDeadline =')
$pollEnd = $text.IndexOf("`n} catch {", $pollStart)
$pollBlock = $text.Substring($pollStart, $pollEnd - $pollStart)
$mainTry = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[0]
$cleanupBlock = ($mainTry.Finally.Statements | Select-Object -First 3 | ForEach-Object { $_.Extent.Text }) -join "`n"
$temporary = !$EvidenceRoot
if ($temporary) { $EvidenceRoot = Join-Path ([IO.Path]::GetTempPath()) ('ticket569-trace-' + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
try {
    foreach ($case in @('accepted-third-poll', 'rejected-status', 'status-exception', 'inventory-exception')) {
        $RunRoot = Join-Path $EvidenceRoot $case
        New-Item -ItemType Directory -Path $RunRoot | Out-Null
        $queue = Join-Path $RunRoot 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $runId = $case; $queueWatcher = $null; $queueEventRegistrations = @()
        $app = [pscustomobject]@{ HasExited = $false }; $app | Add-Member ScriptMethod Refresh {}
        $control = [pscustomobject]@{ address = 'private-address-sentinel'; token = 'private-token-sentinel' }
        $script:polls = 0; $script:mode = $case
        function Invoke-RestMethod {
            param($Method, $Uri, $Headers, $TimeoutSec)
            $script:polls++
            if ($TimeoutSec -ne 3) { throw 'Production HTTP timeout changed' }
            if ($script:mode -eq 'status-exception') { throw [InvalidOperationException]::new('private-message-sentinel') }
            return [pscustomobject]@{
                acceptedDrafts = $(if ($script:mode -eq 'accepted-third-poll' -and $script:polls -lt 3) { 0 } else { 1 })
                failed = ($script:mode -eq 'rejected-status'); rawResponse = 'private-response-sentinel'
            }
        }
        # Refresh/HTTP are controlled; production watcher, queue/hash and cleanup run on real files.
        Invoke-Expression $watcherBlock
        $producerProcess = $null
        if ($case -eq 'accepted-third-poll') {
            $escapedQueue = $queue.Replace("'", "''")
            $producer = "`$q='$escapedQueue'; `$d=Join-Path `$q 'msg-controlled'; [IO.Directory]::CreateDirectory(`$d)|Out-Null; [IO.File]::WriteAllText((Join-Path `$d 'report.txt'),'public-synthetic'); [IO.File]::WriteAllBytes((Join-Path `$d 'image.bin'),[byte[]]@(0,1,2)); [IO.File]::WriteAllText((Join-Path `$q 'msg-controlled.json'),'{}'); Start-Sleep -Milliseconds 1000; [IO.File]::Delete((Join-Path `$q 'msg-controlled.json')); [IO.Directory]::Delete(`$d,`$true)"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($producer))
            $producerProcess = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -PassThru
        }
        if ($case -eq 'inventory-exception') {
            function Get-QueueInventory { param([string] $Path) throw [IO.IOException]::new('private-inventory-message-sentinel') }
        }
        $failure = $null
        try { Invoke-Expression $pollBlock } catch { $failure = $_.Exception.Message }
        finally { Invoke-Expression $cleanupBlock }
        if ($producerProcess) {
            $producerProcess.WaitForExit(5000) | Out-Null
            if (!$producerProcess.HasExited) { Stop-Process -Id $producerProcess.Id -Force; throw 'Controlled producer timed out' }
            if ($producerProcess.ExitCode -ne 0) { throw 'Controlled producer failed' }
        }
        $tracePath = Join-Path $RunRoot 'post-mapi-phases.jsonl'
        $traceText = [IO.File]::ReadAllText($tracePath)
        if ($traceText -match 'private-') { throw 'Trace leaked a controlled private operand/message/response' }
        $entries = @(Get-Content -LiteralPath $tracePath | ForEach-Object { ConvertFrom-Json $_ })
        foreach ($entry in $entries) {
            if (@($entry.PSObject.Properties.Name | Where-Object { $_ -notin @('At','Phase','AcceptedDrafts','Failed','ExceptionType') }).Count) { throw 'Trace has an unapproved field' }
        }
        $phases = @($entries | ForEach-Object { $_.Phase })
        foreach ($phase in @('finally.enter','event-unregister.before','event-unregister.after','watcher-disable.before','watcher-disable.after','watcher-dispose.before','watcher-dispose.after')) {
            if ($phases -notcontains $phase) { throw "Actual cleanup trace missing $phase" }
        }
        if (@(Get-EventSubscriber | Where-Object { $_.SourceIdentifier -like "Ticket569Queue$runId*" }).Count) { throw 'Actual event subscriptions remain' }
        if ($case -eq 'accepted-third-poll') {
            if ($failure -or $script:polls -ne 3) { throw 'Actual accepted draft polling did not complete' }
            $terminal = Get-Content -LiteralPath (Join-Path $RunRoot 'queue-before-stop.json') -Raw | ConvertFrom-Json
            if (!$terminal.terminalAcknowledgement -or $terminal.files.Count) { throw 'Actual queue terminal acknowledgement failed' }
            foreach ($phase in @('queue-after-draft.before','queue-after-draft.after','queue-drain.before','queue-drain.after','queue-before-stop.before','queue-before-stop.after')) {
                if ($phases -notcontains $phase) { throw "Actual inventory trace missing $phase" }
            }
            if (@($entries | Where-Object { $_.Phase -eq 'draft-status.after' -and $_.AcceptedDrafts -eq 1 -and !$_.Failed }).Count -ne 1) { throw 'Accepted sanitized status operand missing' }
        } elseif ($case -eq 'rejected-status') {
            if ($failure -ne 'Fake latched a failed or rejected request') { throw 'Rejected status failure changed' }
            if (@($entries | Where-Object { $_.Phase -eq 'draft-status.after' -and $_.Failed }).Count -ne 1) { throw 'Rejected status operand missing' }
        } elseif ($case -eq 'status-exception') {
            if ($failure -ne 'private-message-sentinel' -or @($entries | Where-Object { $_.Phase -eq 'draft-status.exception' -and $_.ExceptionType -eq 'System.InvalidOperationException' }).Count -ne 1) { throw 'Original HTTP exception or sanitized type changed' }
        } else {
            if ($failure -ne 'private-inventory-message-sentinel' -or @($entries | Where-Object { $_.Phase -eq 'queue-after-draft.exception' -and $_.ExceptionType -eq 'System.IO.IOException' }).Count -ne 1) { throw 'Original inventory exception or sanitized type changed' }
        }
        Write-AtomicJson (Join-Path $RunRoot 'control-result.json') @{ Case = $case; Passed = $true; Polls = $script:polls; RealProductionPollingAndEventCleanup = $true; NativeInstalledAppAndHTTPTransport = 'UNRUN'; PowerShell = $PSVersionTable.PSVersion.ToString() }
    }
    # A denied trace append must return without altering the accepted work/error path.
    $RunRoot = Join-Path $EvidenceRoot 'absent-parent'
    Write-PostMapiPhase 'controlled-denied-append'
    Write-Output 'POST_MAPI_SANITIZED_PHASE_CONTROL_PASSED;NATIVE_APP_AND_HTTP_TRANSPORT_UNRUN'
} finally {
    if ($temporary) { Remove-Item -LiteralPath $EvidenceRoot -Recurse -Force }
}
