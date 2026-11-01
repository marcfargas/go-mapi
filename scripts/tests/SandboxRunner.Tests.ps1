# No Sandbox launch, package install, or changes to shared processes.
# Run: just test-windows-tooling
#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../SandboxRunner.ps1')
$fixture = Join-Path $env:LOCALAPPDATA ('agent-work/cache/go-mapi/sandbox-contracts/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$inputPath = Join-Path $fixture 'selected input'
New-Item -ItemType Directory -Path $inputPath | Out-Null
'param($InputDirectory, $OutputDirectory)' | Set-Content -LiteralPath (Join-Path $inputPath "guest's probe.ps1")
$options = @{ InputDirectory = $inputPath; ScriptPath = "guest's probe.ps1"; EvidenceRoot = (Join-Path $fixture 'evidence') }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        Assert ($_.Exception.Message -match $Pattern) "Expected '$Pattern', got '$($_.Exception.Message)'"
        return
    }
    throw "Expected failure matching '$Pattern'"
}

try {
    # Exercise real native process handling, with a harmless child PowerShell in place of wsb.
    $pwsh = (Get-Command pwsh -CommandType Application).Source
    $invokeNative = ${function:Invoke-WsbProcess}
    $result = Invoke-WsbProcess -FilePath $pwsh -Arguments @('-NoProfile', '-Command', '[Console]::Out.Write(''json stdout''); [Console]::Error.Write(''separate diagnostic''); exit 9') -TimeoutMilliseconds 10000
    Assert ($result.ExitCode -eq 9 -and $result.Stdout -eq 'json stdout' -and $result.Stderr -eq 'separate diagnostic') 'Native exit/stream separation failed'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $timeoutCapture = @{}
    Reject { Invoke-WsbProcess -FilePath $pwsh -Arguments @('-NoProfile', '-Command', '[Console]::Out.Write(''before timeout''); [Console]::Out.Flush(); Start-Sleep -Seconds 30') -Capture $timeoutCapture -TimeoutMilliseconds 3000 } 'timed out'
    Assert ($timer.Elapsed.TotalSeconds -lt 10) 'Native timeout was not bounded'
    Assert ($timeoutCapture.Stdout -match 'before timeout' -and $timeoutCapture.Timeout -match 'timed out') 'Timeout discarded partial diagnostics'

    $state = @{}
    function Reset-Scenario {
        $state.SessionId = 2
        $state.List = '{"WindowsSandboxEnvironments":[]}'
        $state.Start = '{"Id":"owned-sandbox"}'
        $state.Exec = '{"ExitCode":0}'
        $state.FailCommand = ''
        $state.TimeoutCommand = ''
        $state.FailEvidencePatterns = @()
        $state.EvidenceWrites = [Collections.Generic.List[string]]::new()
        $state.Calls = [Collections.Generic.List[object]]::new()
        $state.ProbeResults = @('{"ExitCode":0}')
        $state.ProbeEvidence = '{"ProbeSessionId":2,"ProbeOwnerSid":"S-1-5-21-123","ExplorerSessionId":2,"ExplorerOwnerSid":"S-1-5-21-123"}'
        $state.Probes = 0
        $state.Journeys = 0
        $state.ConnectExit = $false
        $state.ConnectCode = 0
        $state.ConnectFail = $false
        $state.KillFail = $false
        $state.DisposeFail = $false
        $state.Killed = $false
        $state.Disposed = $false
        $state.Connected = $false
    }
    function Start-Process {
        param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru, $RedirectStandardOutput, $RedirectStandardError, $ErrorAction)
        Assert ((Commands) -eq 'list,start,share,share') 'Connect started before owned start/shares'
        Assert ($FilePath -eq 'not-a-real-wsb' -and ($ArgumentList -join ',') -eq 'connect,--id,"owned-sandbox"') 'Connect did not select exact owned ID'
        Assert ($WindowStyle -eq 'Hidden' -and $PassThru) 'Connect not hidden/asynchronous with retained handle'
        Assert ($RedirectStandardOutput -match 'connect.stdout.txt$' -and $RedirectStandardError -match 'connect.stderr.txt$') 'Connect diagnostics not retained'
        $state.Connected = $true
        if ($state.ConnectFail) { throw 'fixture connect launch failed' }
        $client = [pscustomobject]@{ HasExited = $state.ConnectExit; ExitCode = $state.ConnectCode; Handle = [IntPtr]1 }
        $client | Add-Member ScriptMethod Kill { $state.Killed = $true; if ($state.KillFail) { throw 'fixture kill failed' }; $this.HasExited = $true }
        $client | Add-Member ScriptMethod WaitForExit { param($Timeout); Assert ($Timeout -eq 5000) 'Unbounded connect cleanup'; return $true }
        $client | Add-Member ScriptMethod Dispose { $state.Disposed = $true; if ($state.DisposeFail) { throw 'fixture dispose failed' } }
        $client
    }
    # Fault the actual persistence boundary, rather than making the native stub throw for logging.
    function Set-Content {
        [CmdletBinding()]
        param([string]$LiteralPath, [Parameter(ValueFromPipeline)]$Value)
        process {
            $state.EvidenceWrites.Add($LiteralPath)
            foreach ($pattern in $state.FailEvidencePatterns) {
                if ($LiteralPath -match $pattern) { throw "fixture evidence write failure: $LiteralPath" }
            }
            Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Value $Value -ErrorAction Stop
        }
    }
    function Get-SandboxHostSessionId { $state.SessionId }
    # All orchestrator commands are intercepted here, regardless of host CLI availability.
    function Get-Command { param($Name, $CommandType, $ErrorAction); [pscustomobject]@{ Source = 'not-a-real-wsb' } }
    function Invoke-WsbProcess {
        param($FilePath, [string[]]$Arguments, $TimeoutMilliseconds, [hashtable]$Capture)
        $state.Calls.Add(@($Arguments))
        Assert ($FilePath -eq 'not-a-real-wsb') 'Attempted to use real sandbox CLI'
        Assert ($TimeoutMilliseconds -gt 0) 'Missing bounded timeout'
        if ($Arguments[0] -eq 'share' -and $Arguments -contains '--allow-write') { $state.OutputPath = $Arguments[4] }
        if ($Arguments[0] -eq 'stop') {
            Assert ($Arguments[2] -eq 'owned-sandbox') 'Stopped an unowned sandbox ID'
            Assert ($TimeoutMilliseconds -eq 30000) 'Cleanup does not have an independent timeout'
        }
        $stdout = switch ($Arguments[0]) {
            list { $state.List }
            start { $state.Start }
            exec { $state.Exec }
            default { '{}' }
        }
        if ($Arguments[0] -eq 'exec') {
            $decodedExec = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($Arguments[4] -split ' ')[-1]))
            if ($decodedExec -match 'ProbeSessionId') {
                $state.ProbeCommand = $decodedExec
                Assert ($TimeoutMilliseconds -le 5000) 'Readiness attempt was not bounded'
                Assert ($Arguments -contains 'ExistingLogin') 'Probe identity changed'
                $stdout = $state.ProbeResults[[Math]::Min($state.Probes, $state.ProbeResults.Count - 1)]
                $state.Probes++
                if ($null -ne $state.ProbeEvidence) {
                    $probeFile = [regex]::Match($decodedExec, 'readiness-\d+\.json').Value
                    Microsoft.PowerShell.Management\Set-Content -LiteralPath (Join-Path $state.OutputPath $probeFile) -Value $state.ProbeEvidence
                }
            } else { $state.Journeys++ }
        }
        $Capture.ExitCode = if ($Arguments[0] -eq $state.FailCommand) { 13 } else { 0 }
        $Capture.Stdout = $stdout
        $Capture.Stderr = 'fixture diagnostic'
        $Capture.Timeout = $null
        if ($Arguments[0] -eq $state.TimeoutCommand) { throw 'fixture timed out' }
        [pscustomobject]$Capture
    }
    function Commands { @($state.Calls | ForEach-Object { $_[0] }) -join ',' }
    function Last-Summary {
        $file = Get-ChildItem -LiteralPath $options.EvidenceRoot -Filter result.json -Recurse | Sort-Object LastWriteTimeUtc | Select-Object -Last 1
        Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    }

    Reset-Scenario
    $state.SessionId = 0
    Reject { Invoke-GoMapiSandboxTest @options } 'interactive desktop.*session 0'
    Assert ($state.Calls.Count -eq 0) 'Session 0 reached CLI'
    Reject { Invoke-GoMapiSandboxTest -InputDirectory (Join-Path $PSScriptRoot '../..') -ScriptPath 'test.ps1' } 'not the repository'
    Reject { Invoke-GoMapiSandboxTest @options -Smoke } 'cannot be combined'
    $escape = $options.Clone(); $escape.ScriptPath = '../outside.ps1'
    Reject { Invoke-GoMapiSandboxTest @escape } 'inside InputDirectory'
    $nestedEvidence = $options.Clone(); $nestedEvidence.EvidenceRoot = Join-Path $inputPath 'logs'
    Reject { Invoke-GoMapiSandboxTest @nestedEvidence } 'outside InputDirectory'
    '.env secret fixture' | Set-Content -LiteralPath (Join-Path $inputPath '.env')
    Reject { Invoke-GoMapiSandboxTest @options } 'private repository/environment'
    Remove-Item -LiteralPath (Join-Path $inputPath '.env')

    Reset-Scenario
    $state.List = '{"WindowsSandboxEnvironments":[{"Id":"someone-else"}]}'
    Reject { Invoke-GoMapiSandboxTest @options } 'Existing sandbox found'
    Assert ((Commands) -eq 'list') 'Existing sandbox was mutated'
    foreach ($list in @('not json', '{}', '{"WindowsSandboxEnvironments":null}')) {
        Reset-Scenario; $state.List = $list
        Reject { Invoke-GoMapiSandboxTest @options } 'Sandbox run failed'
        Assert ((Commands) -eq 'list') 'Invalid list response did not fail closed'
    }
    Reset-Scenario; $state.FailCommand = 'list'
    Reject { Invoke-GoMapiSandboxTest @options } 'host exit 13'
    Assert ((Commands) -eq 'list') 'Failed list did not fail closed'
    foreach ($start in @('{}', 'not json')) {
        Reset-Scenario; $state.Start = $start
        Reject { Invoke-GoMapiSandboxTest @options } 'Sandbox run failed'
        Assert ((Commands) -eq 'list,start') 'Unknown ownership led to cleanup'
    }
    Reset-Scenario; $state.TimeoutCommand = 'start'
    Reject { Invoke-GoMapiSandboxTest @options } 'timed out'
    Assert ((Commands) -eq 'list,start') 'Unknown ownership after timeout led to cleanup'
    Reset-Scenario; $state.FailCommand = 'start'
    Reject { Invoke-GoMapiSandboxTest @options } 'host exit 13'
    Assert ((Commands) -eq 'list,start') 'Failed start led to unowned cleanup'

    foreach ($failedCommand in @('share', 'exec')) {
        Reset-Scenario; $state.FailCommand = $failedCommand
        Reject { Invoke-GoMapiSandboxTest @options } 'host exit 13'
        Assert ((Commands).EndsWith(',stop')) "Failed $failedCommand skipped owned cleanup"
        $summary = Last-Summary
        Assert ($summary.Status -eq 'FAIL' -and $summary.Cleanup -eq 'stopped') 'Failure summary or cleanup missing'
    }
    foreach ($guestResult in @('{"ExitCode":7}', '{"ExitCode":"0"}', '{}')) {
        Reset-Scenario; $state.Exec = $guestResult
        Reject { Invoke-GoMapiSandboxTest @options } 'Guest script failed|integer guest'
        Assert ((Commands).EndsWith(',stop')) 'Guest failure skipped cleanup'
    }
    Reset-Scenario; $state.TimeoutCommand = 'exec'
    Reject { Invoke-GoMapiSandboxTest @options } 'timed out'
    Assert ((Commands).EndsWith(',stop')) 'Timeout skipped owned cleanup'
    Reset-Scenario; $state.FailCommand = 'stop'
    Reject { Invoke-GoMapiSandboxTest @options } 'cleanup failed for owned ID'
    Assert ((Last-Summary).Status -eq 'FAIL') 'Failed cleanup reported pass'
    Reset-Scenario; $state.Exec = '{"ExitCode":8}'; $state.FailCommand = 'stop'
    Reject { Invoke-GoMapiSandboxTest @options } 'Guest script failed.*Cleanup: failed.*host exit 13'

    foreach ($suffix in @('exit-code.txt', 'stdout.txt', 'stderr.txt')) {
        Reset-Scenario; $state.FailEvidencePatterns = @('02-start\.' + [regex]::Escape($suffix) + '$')
        Reject { Invoke-GoMapiSandboxTest @options } 'evidence could not be written.*Cleanup: stopped.*fixture evidence write failure'
        Assert ((Commands) -eq 'list,start,stop') "Post-start $suffix failure lost ownership or continued guest work"
        $summary = Last-Summary
        Assert ($summary.SandboxId -eq 'owned-sandbox' -and $summary.Cleanup -eq 'stopped' -and $summary.Status -eq 'FAIL') 'Post-start evidence failure lost owned cleanup status'
        Assert ($summary.EvidenceErrors.Count -eq 1 -and $summary.EvidenceErrors[0] -match [regex]::Escape($suffix)) 'Evidence failure was not retained'
        Assert (@($state.EvidenceWrites | Where-Object { $_ -match '02-start\.(exit-code|stdout|stderr)\.txt$' }).Count -eq 3) 'One evidence failure skipped other diagnostics'
    }
    Reset-Scenario; $state.FailEvidencePatterns = @('-stop\.arguments\.json$')
    Reject { Invoke-GoMapiSandboxTest @options } 'evidence could not be written.*Cleanup: stopped.*fixture evidence write failure'
    Assert ((Commands) -eq 'list,start,share,share,exec,stop') 'Pre-stop arguments logging failure prevented stop'
    Assert ((Last-Summary).Cleanup -eq 'stopped' -and (Last-Summary).Status -eq 'FAIL') 'Logging failure misreported native cleanup'

    Reset-Scenario; $state.FailEvidencePatterns = @('sandbox-id\.txt$')
    Reject { Invoke-GoMapiSandboxTest @options } 'evidence could not be written.*Cleanup: stopped.*sandbox-id.txt'
    Assert ((Commands) -eq 'list,start,stop') 'Owned-ID evidence failure lost cleanup ownership'

    Reset-Scenario; $state.FailCommand = 'share'
    $state.FailEvidencePatterns = @('-share\.stderr\.txt$', '-stop\.arguments\.json$', 'result\.json$')
    Reject { Invoke-GoMapiSandboxTest @options } 'Sandbox run failed: wsb share failed \(host exit 13\).*Cleanup: stopped.*Evidence write failures:.*share.stderr.txt.*stop.arguments.json.*result.json'
    Assert ((Commands) -eq 'list,start,share,stop') 'Diagnostic failures masked primary failure or skipped cleanup'
    Reset-Scenario; $state.FailCommand = 'stop'; $state.FailEvidencePatterns = @('-stop\.stderr\.txt$', 'result\.json$')
    Reject { Invoke-GoMapiSandboxTest @options } 'Sandbox cleanup failed for owned ID owned-sandbox: wsb stop failed \(host exit 13\).*Evidence write failures:'
    Assert ((Commands).EndsWith(',stop')) 'Cleanup evidence failure skipped native stop'
    foreach ($unknownStart in @('timeout', 'invalid', 'failed')) {
        Reset-Scenario; $state.FailEvidencePatterns = @('02-start\.stdout\.txt$')
        switch ($unknownStart) {
            timeout { $state.TimeoutCommand = 'start' }
            invalid { $state.Start = 'not json' }
            failed { $state.FailCommand = 'start' }
        }
        Reject { Invoke-GoMapiSandboxTest @options } 'Sandbox run failed:.*Cleanup: not-started.*fixture evidence write failure'
        Assert ((Commands) -eq 'list,start') 'Diagnostic failure caused stop without a valid owned ID'
    }

    Reset-Scenario
    $first = Invoke-GoMapiSandboxTest @options
    Assert ((Commands) -eq 'list,start,share,share,exec,stop') 'Unexpected success command sequence'
    Assert ($first.Status -eq 'PASS' -and $first.Cleanup -eq 'stopped') 'Success result incorrect'
    Assert (-not ($state.Calls[2] -contains '--allow-write')) 'Input was writable'
    Assert ($state.Calls[3] -contains '--allow-write') 'Output was not writable'
    Assert ($state.Calls[4] -contains 'System') 'Guest did not default to SYSTEM'
    $manifest = @(Get-Content -LiteralPath (Join-Path $first.EvidenceDirectory 'inputs.json') -Raw | ConvertFrom-Json)
    Assert ($manifest.Count -eq 1 -and $manifest[0].Path -eq $options.ScriptPath -and $manifest[0].SHA256.Length -eq 64) 'Input identity missing'
    $execArgs = $state.Calls[4]
    $command = $execArgs[4]
    $encoded = ($command -split ' ')[-1]
    $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
    # Execute the generated wrapper against harmless local fixtures under the
    # guest's actual engine. Only the fixed share locations are remapped.
    $probeOutput = Join-Path $fixture 'wrapper output'
    New-Item -ItemType Directory -Path $probeOutput | Out-Null
    $transcript = Join-Path $probeOutput 'guest.log'
    $localCommand = $decoded.Replace('C:\output\guest.log', "'$transcript'").Replace('C:\input', $inputPath).Replace('C:\output', $probeOutput)
    $localEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($localCommand))
    $engine = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $probePath = Join-Path $inputPath $options.ScriptPath
    @'
param($InputDirectory, $OutputDirectory)
@{ InputDirectory = $InputDirectory; OutputDirectory = $OutputDirectory } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'arguments.json')
Write-Host 'harmless wrapper probe'
'@ | Microsoft.PowerShell.Management\Set-Content -LiteralPath $probePath
    $wrapped = & $invokeNative -FilePath $engine -Arguments @('-NoProfile', '-EncodedCommand', $localEncoded) -TimeoutMilliseconds 10000
    Assert ($wrapped.ExitCode -eq 0) 'Generated wrapper failed a harmless script with a quoted filename'
    $received = Get-Content -LiteralPath (Join-Path $probeOutput 'arguments.json') -Raw | ConvertFrom-Json
    Assert ($received.InputDirectory -eq $inputPath -and $received.OutputDirectory -eq $probeOutput) 'Wrapper lost input/output argument boundaries'
    Assert ((Get-Content -LiteralPath $transcript -Raw) -match 'harmless wrapper probe') 'Wrapper did not retain a transcript'
    foreach ($failure in @(@{ Body = 'throw "harmless wrapper failure"'; ExitCode = 1 },
            @{ Body = '& $env:ComSpec /d /c exit 17'; ExitCode = 17 })) {
        ('param($InputDirectory, $OutputDirectory)' + [Environment]::NewLine + $failure.Body) |
            Microsoft.PowerShell.Management\Set-Content -LiteralPath $probePath
        $wrapped = & $invokeNative -FilePath $engine -Arguments @('-NoProfile', '-EncodedCommand', $localEncoded) -TimeoutMilliseconds 10000
        Assert ($wrapped.ExitCode -eq $failure.ExitCode) 'Wrapper lost a script exception or native failure exit'
    }
    Reset-Scenario
    $second = Invoke-GoMapiSandboxTest @options -RunAs ExistingLogin
    Assert ($first.EvidenceDirectory -ne $second.EvidenceDirectory) 'Evidence reused across runs'
    Assert ($state.Calls[4] -contains 'ExistingLogin') 'ExistingLogin not forwarded'
    Assert ($state.Probes -eq 1 -and $state.Journeys -eq 1) 'ExistingLogin did not gate the single journey on readiness'
    # Exercise the generated probe in Windows PowerShell 5.1 with harmless CIM fixtures.
    # Identity is the real current token; process/session discovery is stubbed locally.
    foreach ($shellCase in @('matching', 'session', 'owner', 'lookup-error', 'missing')) {
        $probeFile = Join-Path $probeOutput ('shell-' + $shellCase + '.json')
        $localProbe = $state.ProbeCommand -replace 'C:\\output\\readiness-\d+\.json', $probeFile
        $shellFixture = @'
function Get-Process { param($Id); [pscustomobject]@{ SessionId = 2 } }
function Get-CimInstance {
    param($ClassName, $Filter)
    if ('SHELL_CASE' -ne 'missing') { [pscustomobject]@{ SessionId = $(if ('SHELL_CASE' -eq 'session') { 3 } else { 2 }) } }
}
function Invoke-CimMethod {
    param($InputObject, $MethodName, $ErrorAction)
    if ('SHELL_CASE' -eq 'lookup-error') { throw 'harmless owner lookup failure' }
    [pscustomobject]@{ ReturnValue = 0; Sid = $(if ('SHELL_CASE' -eq 'owner') { 'S-1-5-21-999' } else { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }) }
}
'@
        $probeEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($shellFixture.Replace('SHELL_CASE', $shellCase) + [Environment]::NewLine + $localProbe))
        $observed = & $invokeNative -FilePath $engine -Arguments @('-NoProfile', '-EncodedCommand', $probeEncoded) -TimeoutMilliseconds 10000
        $expected = if ($shellCase -eq 'matching') { 0 } else { 1 }
        Assert ($observed.ExitCode -eq $expected) "Generated readiness probe failed shell case $shellCase"
        Assert ((Test-Path -LiteralPath $probeFile) -eq ($expected -eq 0)) 'Failed readiness probe wrote successful evidence'
    }

    Reset-Scenario
    Reject { Invoke-GoMapiSandboxTest @options -Connect } 'Connect requires'
    Assert ($state.Calls.Count -eq 0) 'Invalid Connect mode reached CLI'
    Reset-Scenario
    $state.ProbeResults = @('{"ExitCode":1}', 'not json', '{}', '{"ExitCode":0}')
    $connected = Invoke-GoMapiSandboxTest @options -RunAsExistingLogin -Connect
    Assert ($state.Connected -and $state.Killed -and $state.Disposed) 'Retained connect client was not cleaned up'
    Assert ($state.Probes -eq 4 -and $state.Journeys -eq 1) 'Probe retry retried or skipped the actual journey'
    Assert (@(Get-ChildItem $connected.EvidenceDirectory -Filter 'readiness-*.error.txt').Count -eq 3) 'Readiness failures were discarded'
    Assert ((Commands).EndsWith(',stop')) 'Connected run skipped exact guest stop'

    foreach ($badProbe in @($null, 'not json', '{}', '{"ExitCode":"0"}', '{"ExitCode":9}')) {
        Reset-Scenario; $state.ProbeResults = @($badProbe)
        Reject { Invoke-GoMapiSandboxTest @options -RunAsExistingLogin -Connect -TimeoutSeconds 1 } 'readiness timed out'
        Assert ($state.Journeys -eq 0 -and (Commands).EndsWith(',stop') -and $state.Disposed) 'Bad exec readiness false-passed or skipped cleanup'
    }
    Reset-Scenario; $state.TimeoutCommand = 'exec'
    Reject { Invoke-GoMapiSandboxTest @options -RunAsExistingLogin -Connect -TimeoutSeconds 1 } 'readiness timed out'
    Assert ($state.Journeys -eq 0 -and (Commands).EndsWith(',stop') -and $state.Disposed) 'Readiness client timeout skipped cleanup or executed journey'
    Reset-Scenario; $state.ProbeResults = @('{}'); $state.FailEvidencePatterns = @('readiness-1\.error\.txt$')
    Reject { Invoke-GoMapiSandboxTest @options -RunAsExistingLogin -Connect } 'evidence could not be written'
    Assert ($state.Probes -eq 1 -and $state.Journeys -eq 0 -and $state.Disposed) 'Readiness evidence failure retried or skipped cleanup'
    foreach ($badEvidence in @($null, 'not json', '{}', '{"ProbeSessionId":2,"ProbeOwnerSid":"S-1-5-21-123","ExplorerSessionId":3,"ExplorerOwnerSid":"S-1-5-21-123"}', '{"ProbeSessionId":2,"ProbeOwnerSid":"S-1-5-21-123","ExplorerSessionId":2,"ExplorerOwnerSid":"S-1-5-21-456"}')) {
        Reset-Scenario; $state.ProbeEvidence = $badEvidence
        Reject { Invoke-GoMapiSandboxTest @options -RunAsExistingLogin -TimeoutSeconds 1 } 'readiness timed out'
        Assert ($state.Journeys -eq 0 -and (Commands).EndsWith(',stop')) 'Bad shell evidence false-passed or skipped cleanup'
    }
    Reset-Scenario; $state.FailCommand = 'stop'; $state.KillFail = $true
    Reject { Invoke-GoMapiSandboxTest @options -RunAsExistingLogin -Connect } 'host exit 13'
    Assert ($state.Killed -and $state.Disposed -and (Last-Summary).Cleanup -eq 'failed' -and (Last-Summary).ConnectError -match 'kill failed') 'Guest stop failure skipped client cleanup or lost diagnostics'
    foreach ($connectFailure in @('launch', 'exit', 'kill', 'dispose')) {
        Reset-Scenario
        switch ($connectFailure) {
            launch { $state.ConnectFail = $true }
            exit { $state.ConnectExit = $true; $state.ConnectCode = 7 }
            kill { $state.KillFail = $true }
            dispose { $state.DisposeFail = $true }
        }
        Reject { Invoke-GoMapiSandboxTest @options -RunAsExistingLogin -Connect } 'connect|kill|dispose'
        Assert ((Commands).EndsWith(',stop') -and (Last-Summary).Status -eq 'FAIL') 'Connect failure skipped guest stop or reported pass'
        if ($connectFailure -ne 'launch') { Assert $state.Disposed 'Connect failure skipped disposal' }
    }
    Reset-Scenario; $state.Exec = '{"ExitCode":8}'
    Reject { Invoke-GoMapiSandboxTest @options -RunAsExistingLogin -Connect } 'Guest script failed'
    Assert ($state.Journeys -eq 1 -and $state.Probes -eq 1 -and $state.Disposed) 'Actual journey was retried after failure'
    $entry = Get-Content (Join-Path $PSScriptRoot '../run-sandbox-test.ps1') -Raw
    Assert ($entry -match '\[switch\]\$Connect' -and $entry -match '\[switch\]\$RunAsExistingLogin' -and $entry -match 'Invoke-GoMapiSandboxTest @PSBoundParameters') 'Entry script does not forward Connect/ExistingLogin'
    Reset-Scenario
    $smoke = Invoke-GoMapiSandboxTest -Smoke -EvidenceRoot $options.EvidenceRoot
    $smokeInput = $state.Calls[2][4]
    Assert ($smokeInput -eq [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../tests/sandbox/smoke'))) 'Smoke shared more than its bundled input directory'
    Assert ($smoke.Status -eq 'PASS') 'Default smoke contract failed'
    Write-Host 'Sandbox runner contracts passed (native subprocess checks + stubbed Sandbox CLI; no Sandbox launched).'
} finally {
    # Exact, generated fixture tree only; guard before recursive deletion.
    $cacheRoot = Join-Path $env:LOCALAPPDATA 'agent-work/cache/go-mapi/sandbox-contracts'
    if (-not (Test-SandboxPathWithin $fixture $cacheRoot) -or $fixture -eq $cacheRoot) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
