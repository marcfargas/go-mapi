# Exercise the native evidence observer without an installation or Windows host.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptPath = Join-Path $PSScriptRoot '../run-machine-update-integration.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Integration script parse failed' }
foreach ($name in @('AssertHealthy','Until','WaitLimit','AwaitHealthy','AssertRecoveryProcessHistory')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if (-not $definition) { throw "Missing observer function $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$SKU='system'; $DeadlineMinutes=1
$timers=$true; $startupDelaySeconds=5; $heartbeatSeconds=2; $checkIntervalSeconds=5; $waitMarginSeconds=180
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
$observer=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'StartReadinessProcessEvidence'},$true)
$register=$observer.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Register-CimIndicationEvent'},$true)
$callback=[scriptblock]::Create($register.CommandElements[-1].ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}'))
$temp=Join-Path ([IO.Path]::GetTempPath()) ('readiness-evidence-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
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
        foreach($mode in @('complete','missing-stop','overlap','wrong-session','extra-installer')) {
            $caseStarts=@($starts); $caseStops=@($stops | ForEach-Object { [ordered]@{} + $_ })
            switch($mode) {
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
