# Exercise the native evidence observer without an installation or Windows host.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'UpdateSupport.ps1')
$SKU='system'; $DeadlineMinutes=1; $ExerciseSuiteShutdown=$false
$driver=Get-Content (Join-Path $PSScriptRoot 'update.ps1') -Raw
$operations=Get-Content (Join-Path $PSScriptRoot 'UpdateSupport.ps1') -Raw
$configuredTimers=(Get-Content (Join-Path $PSScriptRoot 'fixtures/machine.json') -Raw | ConvertFrom-Json).timers
$startupDelaySeconds=[int]$configuredTimers.startupDelaySeconds
$heartbeatSeconds=[int]$configuredTimers.heartbeatSeconds
$checkIntervalSeconds=[int]$configuredTimers.checkIntervalSeconds
$failureBaseSeconds=[int]$configuredTimers.failureDelayBaseSeconds
foreach ($setting in @(
    @('installWorkSeconds',$driver,'(?m)^\$installWorkSeconds = (\d+)'),
    @('waitMarginSeconds',$driver,'(?m)^\$waitMarginSeconds = (\d+)'))) {
    $match=[regex]::Match($setting[1],$setting[2])
    if (-not $match.Success) { throw "Missing configured timing: $($setting[0])" }
    Set-Variable -Scope Script -Name $setting[0] -Value ([int]$match.Groups[1].Value)
}
$timers=$true
# Execute the real helper with each driver's arguments, rather than duplicating
# its formula. These five sites retain the measured slow-runner safety margin.
$sites=[regex]::Matches($driver,'-Seconds \(WaitLimit((?:[^()\n]|\([^()\n]*\))*)\)')
$measured=@(5.6,41.3,7.3,99.7,4.9)
if ($sites.Count -ne $measured.Count) { throw 'Changed wait sites require a measured budget' }
for ($i=0; $i -lt $sites.Count; $i++) {
    $limit=& ([scriptblock]::Create('WaitLimit '+$sites[$i].Groups[1].Value))
    if ($limit -lt 3*$measured[$i] -or $limit -ge 360) { throw "Wait $i is too short for slow runners or fails to bound a stall: $limit" }
}
if ($waitMarginSeconds -lt 180 -or (WaitLimit) -ge 360 -or [regex]::IsMatch($driver,'-Seconds \d')) { throw 'Unbounded wait or insufficient runner margin' }
if ([regex]::Matches($operations,'AwaitHealthy \$caseB \| Out-Null').Count -ne 2 -or
    $operations -notmatch 'AssertRecoveryProcessHistory') { throw 'Readiness journey lost its health or process-history observation' }
$timers=$false
if ((WaitLimit -Install) -ne 0) { throw 'Production waits must use the phase deadline' }
$timers=$true
$manifest = [pscustomobject]@{packages=[pscustomobject]@{systemB=[pscustomobject]@{release='B'; serviceVersion='B'; serviceSha256='expected'}}}
function HealthySnapshot {
    [pscustomobject]@{
        marker=[pscustomobject]@{sku='system';packageRelease='B';serviceVersion='B'}
        service=[pscustomobject]@{state='Running';startName='LocalSystem';startMode='Auto';executableSha256='expected'}
        status=[pscustomobject]@{code='healthy';health='healthy'}
        legacyTaskCount=0
    }
}
$script:snapshots=[Collections.Generic.Queue[object]]::new()
$script:records=[Collections.Generic.List[string]]::new()
function Snapshot { if ($script:snapshots.Count -gt 1) { return $script:snapshots.Dequeue() }; return $script:snapshots.Peek() }
function Record([string]$Kind,$Value) { $script:records.Add($Kind) }
$pending=HealthySnapshot
$pending.status=[pscustomobject]@{schema='go-mapi-status-v2';code='pending'}
$script:snapshots.Enqueue($pending)
$script:snapshots.Enqueue((HealthySnapshot))
$script:overallDeadline=[DateTime]::UtcNow.AddSeconds(5)
$result=AwaitHealthy 'systemB'
if ($result.status.health -ne 'healthy' -or $script:records.Count -ne 1 -or $script:records[0] -ne 'poll-error') {
    throw 'Observer must await actual healthy publication after pending without health'
}
# A permanently unhealthy publication or wrong installed bytes must reach the
# existing phase deadline, never return a successful snapshot or extend the phase.
foreach ($mode in @('unpublished','wrong-bytes')) {
    $bad=HealthySnapshot
    if ($mode -eq 'unpublished') { $bad.status=$pending.status } else { $bad.service.executableSha256='wrong' }
    $script:snapshots.Clear(); $script:snapshots.Enqueue($bad)
    $script:overallDeadline=[DateTime]::UtcNow.AddMilliseconds(100)
    $before=[DateTime]::UtcNow
    $refused=$false
    try { AwaitHealthy 'systemB' | Out-Null } catch {
        if ($_.Exception.Message -like 'Deadline waiting for*') { $refused=$true } else { throw }
    }
    if (-not $refused -or ([DateTime]::UtcNow-$before).TotalSeconds -gt 3) { throw "Observer accepted $mode or extended the phase" }
}
# Invoke the actual CIM callback with the long-name start and truncated stop
# observed on Windows. The full-name filter previously dropped every runner stop.
$callback=GetReadinessProcessEventAction
$temp=Join-Path ([IO.Path]::GetTempPath()) ('readiness-evidence-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    # The phase finalizer is the only operational cleanup owner. A failed step
    # must preserve all failures and still attempt product and fixture cleanup.
    $script:actions=[Collections.Generic.List[string]]::new()
    $script:failStep=''
    function StopSuiteShutdownProof { $script:actions.Add('suite'); if ($script:failStep -eq 'suite') { throw 'suite failure' } }
    function RemoveInstalledTestProducts { $script:actions.Add('products'); if ($script:failStep -eq 'products') { throw 'MSI failure' } }
    function Cleanup { $script:actions.Add('fixture'); if ($script:failStep -eq 'products') { throw 'fixture failure' } }
    $Phase='Hosted'; $cleanupOnExit=$true; $cleanMachineConfirmed=$true; $processSubscriptions=@()
    $ExerciseSuiteShutdown=$true
    foreach ($mode in @('','suite','products')) {
        $script:actions.Clear(); $script:failStep=$mode; $script:cleanupError=$null; $script:passed=$true
        CompleteUpdateScenario
        if (($script:actions -join ',') -ne 'suite,products,fixture' -or $script:passed -ne ($mode -eq '')) { throw "Finalizer skipped cleanup or lost failure: $mode" }
        if ($mode -eq 'products' -and ($cleanupError -notmatch 'MSI failure' -or $cleanupError -notmatch 'fixture failure')) { throw 'Finalizer lost one of multiple cleanup failures' }
    }
    $script:actions.Clear(); $cleanMachineConfirmed=$false; $script:failStep=''
    CompleteUpdateScenario
    if (($script:actions -join ',') -ne 'suite,fixture') { throw 'Finalizer removed products without confirmed machine ownership' }
    $ExerciseSuiteShutdown=$false
    # Collect the actual diagnostic receipt through inert Windows API doubles.
    $evidence=$temp; $stateDir=Join-Path $temp 'diagnostic-state'
    $oldProgramData=$env:ProgramData; $env:ProgramData=$temp
    New-Item -ItemType Directory -Path $stateDir,(Join-Path $temp 'go-mapi/updates/logs/transaction') -Force | Out-Null
    Set-Content (Join-Path $stateDir 'pending-v2.json') '{"phase":"prepared"}'
    Set-Content (Join-Path $temp 'go-mapi/updates/logs/transaction/msiexec.log') 'installer log'
    function Get-CimInstance { }
    function Get-WinEvent { param($FilterHashtable,$MaxEvents,$ErrorAction)
        if ($MaxEvents -ne 100 -or -not $FilterHashtable.StartTime) { throw 'Unbounded event query' }
    }
    try {
        if (-not (CollectUpdateEvidence 'interruption' ([DateTime]::UtcNow) ([pscustomobject]@{transactionId='transaction'})) -or
            -not (Test-Path (Join-Path $temp 'interruption-diagnostics/logs/msiexec.log')) -or
            -not (Test-Path (Join-Path $temp 'interruption-diagnostics/pending-v2.json'))) { throw 'Collector failed to retain transaction evidence' }
        $receipt=Get-Content (Join-Path $temp 'interruption-diagnostics/evidence.json') -Raw | ConvertFrom-Json
        if ($receipt.pending.transactionId -ne 'transaction') { throw 'Collector lost transaction identity' }
        function Record { throw 'observation storage unavailable' }
        try { throw 'primary failure' } catch {
            if (CollectUpdateEvidence 'failed' ([DateTime]::UtcNow)) { throw 'Collector falsely reported success' }
            if ($_.Exception.Message -ne 'primary failure') { throw 'Diagnostic failure replaced primary failure' }
        }
    } finally {
        $env:ProgramData=$oldProgramData
        function Record([string]$Kind,$Value) { $script:records.Add($Kind) }
        Remove-Item function:Get-CimInstance,function:Get-WinEvent
    }
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        # The actual snapshot hash must coexist with DELETE access used by MSI.
        # A normal path-based Get-FileHash fails this test with Win32 error 32.
        Add-Type @'
using System; using System.Runtime.InteropServices;
public static class ReadinessHashFileAccess {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
}
'@
        $hashPath=Join-Path $temp 'hash-probe.bin'
        $stream=[IO.File]::Open($hashPath,'Create','ReadWrite','None')
        try { $stream.SetLength(64MB) } finally { $stream.Dispose() }
        $expectedHash=(Get-FileHash -LiteralPath $hashPath -Algorithm SHA256).Hash.ToLowerInvariant()

        $worker=[powershell]::Create()
        try {
            [void]$worker.AddScript({param($support,$path,$expected)
                . $support
                $timer=[Diagnostics.Stopwatch]::StartNew(); $count=0
                while ($timer.Elapsed.TotalSeconds -lt 2) {
                    if ((Hash $path) -cne $expected) { throw 'Snapshot hash bytes changed' }
                    $count++
                }
                $count
            }).AddArgument((Join-Path $PSScriptRoot 'UpdateSupport.ps1')).AddArgument($hashPath).AddArgument($expectedHash)
            $async=$worker.BeginInvoke(); $granted=0; $failures=@()
            while (-not $async.IsCompleted) {
                $handle=[ReadinessHashFileAccess]::CreateFileW($hashPath,0x10000,7,[IntPtr]::Zero,3,0,[IntPtr]::Zero)
                if ($handle -eq [IntPtr](-1)) { $failures += [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
                else { [void][ReadinessHashFileAccess]::CloseHandle($handle); $granted++ }
                Start-Sleep -Milliseconds 1
            }
            $hashes=@($worker.EndInvoke($async))
            if ($worker.HadErrors -or $hashes.Count -ne 1 -or $hashes[0] -lt 1 -or $granted -lt 1 -or $failures.Count -ne 0) {
                throw "Snapshot hashing interfered with DELETE access: $($failures -join ',')"
            }
        } finally { $worker.Dispose() }
    }
    foreach ($kind in @('Start','Stop')) {
        $path=Join-Path $temp "process-$kind.ndjson"
        $Event=[pscustomobject]@{
            MessageData=[pscustomobject]@{path=$path;kind=$kind}
            SourceEventArgs=[pscustomobject]@{NewEvent=[pscustomobject]@{
                ProcessName=if ($kind -eq 'Start') {'go-mapi-update-runner.exe'} else {'go-mapi-update'}
                ProcessID=9604;SessionID=0;TIME_CREATED=100;ParentProcessID=5332
            }}
        }
        & $callback
        if (-not (Test-Path -LiteralPath $path)) { throw "Observer dropped $kind event" }
        $row=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($row.pid -ne 9604 -or $row.timeCreated -ne 100 -or $row.sessionId -ne 0) { throw 'Observer lost identity' }
    }
    # Exercise the actual history audit: complete lifetimes pass, missing or
    # overlapping stops and unexpected installer starts must still fail.
    $evidence=$temp; $stateDir=Join-Path $temp 'state'
    $oldProgramData=$env:ProgramData; $env:ProgramData=$temp
    New-Item -ItemType Directory -Path $stateDir,(Join-Path $temp 'go-mapi/updates/logs/success') -Force | Out-Null
    $ready=[ordered]@{transactionId='success';runner=@{pid=2};installer=@{pid=90}}
    $ready | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $stateDir 'ready-success-attempt-1-v1.json')
    function ReadJson([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    $starts=@(1..5 | ForEach-Object { [ordered]@{name='go-mapi-update-runner.exe';pid=$_;sessionId=0;timeCreated=100*$_;parentPid=80} })
    $starts+= [ordered]@{name='msiexec.exe';pid=90;sessionId=0;timeCreated=220;parentPid=2}
    $stops=@(1..5 | ForEach-Object { [ordered]@{name='go-mapi-update';pid=$_;sessionId=0;timeCreated=100*$_+50;parentPid=0} })
    try {
        foreach($mode in @('complete','missing-start','missing-stop','overlap','wrong-session','extra-installer')) {
            $caseStarts=@($starts); $caseStops=@($stops | ForEach-Object { [ordered]@{} + $_ })
            switch($mode) {
                'missing-start' { $caseStarts=@($caseStarts | Where-Object pid -ne 5) }
                'missing-stop' { $caseStops=@($caseStops | Select-Object -Skip 1) }
                'overlap' { $caseStops[0].timeCreated=201 }
                'wrong-session' { $caseStops[0].sessionId=1 }
                'extra-installer' { $caseStarts += [ordered]@{name='msiexec.exe';pid=91;sessionId=0;timeCreated=320;parentPid=3} }
            }
            $caseStarts|ForEach-Object {$_|ConvertTo-Json -Compress}|Set-Content (Join-Path $temp 'process-start.ndjson')
            $caseStops|ForEach-Object {$_|ConvertTo-Json -Compress}|Set-Content (Join-Path $temp 'process-stop.ndjson')
            $failure=$null
            try { AssertRecoveryProcessHistory 'success' } catch { $failure=$_.Exception.Message }
            $expected=switch($mode) {
                'missing-start' {'Expected five physical runners (B2+C3), observed 4'}
                'missing-stop' {'Runner 1 has no observed stop'}
                'overlap' {'Managed runners overlapped'}
                'wrong-session' {'Runner 1 has no observed stop'}
                'extra-installer' {'Managed installer starts differ from the one recovered transaction'}
                default {$null}
            }
            if($failure -ne $expected) {throw "History audit $mode expected '$expected', got '$failure'"}
        }
    } finally { $env:ProgramData=$oldProgramData }
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
Write-Output 'Machine readiness evidence tests passed'
