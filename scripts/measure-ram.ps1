<#
.SYNOPSIS
    Phase 7 RAM gate -- on-VM benchmark orchestrator + per-session sampler.

.DESCRIPTION
    Three modes:
      -Orchestrate -N <int>  : Runs as VM admin. Starts all per-user scheduled tasks,
                               waits for per-user done flags, concatenates per-user CSV
                               fragments into the canonical CSV, drops measurement-complete.flag.
      -Worker -User <name>   : Runs inside each per-user scheduled task. Launches go-mapi.exe,
                               samples cold-start / idle-pre-webview / idle-post-webview
                               across 3 iterations, writes per-user CSV fragment.
      -Aggregate <path>      : Runs on dev machine after CSV pulled. Prints mean/max/stddev
                               on total_ws_mb across scenarios.

    Per-session metric (primary gate): SUM of go-mapi.exe Private WS + all
    msedgewebview2.exe child Private WS (correlated via Win32_Process.ParentProcessId).
    go-mapi.exe-only Private WS recorded separately as secondary diagnostic.

    Critical gotcha: each session user MUST be a member of the local `Performance Log Users`
    group, else Win32_PerfRawData_PerfProc_Process returns empty.
#>

[CmdletBinding(DefaultParameterSetName = 'Orchestrate')]
param(
    [Parameter(ParameterSetName = 'Orchestrate')]
    [switch] $Orchestrate,

    [Parameter(ParameterSetName = 'Orchestrate', Mandatory = $true)]
    [int]    $N,

    [Parameter(ParameterSetName = 'Worker')]
    [switch] $Worker,

    [Parameter(ParameterSetName = 'Worker', Mandatory = $true)]
    [string] $User,

    [Parameter(ParameterSetName = 'Aggregate', Mandatory = $true)]
    [string] $Aggregate,

    [string] $WorkDir = 'C:\gomapi',

    # Smoke mode: 1 iteration, 10s idles -- pipeline validation only, NOT real gate data.
    [switch] $Smoke
)

# FIRST THING: write a startup marker so we know powershell.exe at least loaded
# the script. Happens before StrictMode/ErrorAction so it can't be aborted.
try {
    $startupLog = 'C:\gomapi\startup-debug.log'
    $paramSet = if ($PSCmdlet -and $PSCmdlet.ParameterSetName) { $PSCmdlet.ParameterSetName } else { '(unresolved)' }
    "[$([DateTime]::UtcNow.ToString('o'))] ENTER PID=$PID User=$env:USERNAME ParamSet=$paramSet Worker=$Worker Orchestrate=$Orchestrate User-arg='$User' N=$N Smoke=$Smoke" |
        Out-File -FilePath $startupLog -Append -Encoding UTF8 -ErrorAction SilentlyContinue
} catch { }

$iterCount = if ($Smoke) { 1 } else { 3 }
$idlePre   = if ($Smoke) { 10 } else { 295 }
$idlePost  = if ($Smoke) { 10 } else { 285 }

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------------ helpers
function Sample-Session {
    param(
        [string] $SessionUser,
        [int]    $Iteration,
        [string] $Scenario,
        [string] $OutputCsv
    )

    # Find go-mapi.exe processes owned by this session user.
    $allGm = Get-CimInstance Win32_Process -Filter "Name='go-mapi.exe'"
    $gmForUser = foreach ($p in $allGm) {
        $owner = (Invoke-CimMethod -InputObject $p -MethodName GetOwner).User
        if ($owner -eq $SessionUser) { $p }
    }
    if (-not $gmForUser) { return }

    foreach ($gm in $gmForUser) {
        $gmPid = [int]$gm.ProcessId

        # Child msedgewebview2.exe processes by ParentProcessId
        $wvChildren = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe' AND ParentProcessId=$gmPid"

        # Private Working Set -- keyed by IDProcess for unambiguous per-PID resolution
        # (avoids Get-Counter instance-name collisions across multiple go-mapi processes).
        $gmPerf = Get-CimInstance Win32_PerfRawData_PerfProc_Process -Filter "IDProcess=$gmPid"
        $gmWsBytes = if ($gmPerf) { $gmPerf.WorkingSetPrivate } else { 0 }
        $gmWsMb    = [math]::Round($gmWsBytes / 1MB, 2)

        $wvWsBytes = 0
        foreach ($wv in $wvChildren) {
            $pid2 = [int]$wv.ProcessId
            $perf = Get-CimInstance Win32_PerfRawData_PerfProc_Process -Filter "IDProcess=$pid2"
            if ($perf) { $wvWsBytes += $perf.WorkingSetPrivate }
        }
        $wvWsMb    = [math]::Round($wvWsBytes / 1MB, 2)
        $totalWsMb = [math]::Round($gmWsMb + $wvWsMb, 2)

        $row = [PSCustomObject]@{
            iteration      = $Iteration
            session_user   = $SessionUser
            scenario       = $Scenario
            go_mapi_pid    = $gmPid
            go_mapi_ws_mb  = $gmWsMb
            webview2_ws_mb = $wvWsMb
            total_ws_mb    = $totalWsMb
            timestamp      = (Get-Date).ToString('o')
        }
        $row | Export-Csv -Path $OutputCsv -Append -NoTypeInformation -Encoding UTF8
    }
}

# ------------------------------------------------------------------ Worker
if ($PSCmdlet.ParameterSetName -eq 'Worker') {
    # Per-user log file -- captures any error before process exits so Task Scheduler
    # failures are diagnosable (stdout/stderr of the scheduled task are otherwise lost).
    $workerLog = Join-Path $WorkDir "worker-$User.log"
    Start-Transcript -Path $workerLog -Force | Out-Null
    trap {
        "[$(Get-Date -Format o)] FATAL: $_`n$($_.ScriptStackTrace)" |
            Out-File -FilePath $workerLog -Append -Encoding UTF8
        Stop-Transcript | Out-Null
        exit 1
    }

    "[$(Get-Date -Format o)] Worker start: User=$User Smoke=$Smoke iters=$iterCount" |
        Out-File -FilePath $workerLog -Append -Encoding UTF8

    $outCsv = Join-Path $WorkDir "phase-07-ram-gate-$User.csv"
    if (Test-Path $outCsv) { Remove-Item $outCsv -Force }

    # Canonical header so merge is simple (ensure present via one dummy write + overwrite)
    # Actually we rely on Export-Csv to emit header on first Append -- OK.

    $exePath = Join-Path $WorkDir 'go-mapi.exe'

    for ($iter = 1; $iter -le $iterCount; $iter++) {
        # Cold start
        $proc = Start-Process -FilePath $exePath -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 5
        Sample-Session -SessionUser $User -Iteration $iter -Scenario 'cold-start' -OutputCsv $outCsv

        # Idle pre-WebView2 (main window never toggled -> WebView2 not spawned)
        Start-Sleep -Seconds $idlePre
        Sample-Session -SessionUser $User -Iteration $iter -Scenario 'idle-pre-webview' -OutputCsv $outCsv

        # Trigger main window show -> WebView2 initialises.
        try {
            Start-Process -FilePath $exePath -ArgumentList '--show-window' -WindowStyle Hidden | Out-Null
        } catch {
            # non-fatal -- WebView2 may already have been triggered
        }
        Start-Sleep -Seconds 15  # give WebView2 time to spawn child processes

        Start-Sleep -Seconds $idlePost
        Sample-Session -SessionUser $User -Iteration $iter -Scenario 'idle-post-webview' -OutputCsv $outCsv

        # Close all go-mapi.exe + msedgewebview2.exe for this user before next iter
        Get-Process -Name go-mapi -ErrorAction SilentlyContinue |
            Where-Object { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" |
                ForEach-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner).User }) -eq $User } |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10
    }

    # Flag done for this user
    $flag = Join-Path $WorkDir "done-$User.flag"
    Set-Content -Path $flag -Value (Get-Date -Format o)
    "[$(Get-Date -Format o)] Worker done: $User" | Out-File -FilePath $workerLog -Append -Encoding UTF8
    Stop-Transcript | Out-Null
    return
}

# ------------------------------------------------------------------ Orchestrate
if ($PSCmdlet.ParameterSetName -eq 'Orchestrate') {
    $orchLog = Join-Path $WorkDir 'orchestrator.log'
    Start-Transcript -Path $orchLog -Force | Out-Null
    trap {
        "[$(Get-Date -Format o)] FATAL: $_`n$($_.ScriptStackTrace)" |
            Out-File -FilePath $orchLog -Append -Encoding UTF8
        Stop-Transcript | Out-Null
        exit 1
    }

    "[$(Get-Date -Format o)] Orchestrator start: N=$N Smoke=$Smoke" |
        Out-File -FilePath $orchLog -Append -Encoding UTF8

    $canonicalCsv = Join-Path $WorkDir 'phase-07-ram-gate.csv'
    if (Test-Path $canonicalCsv) { Remove-Item $canonicalCsv -Force }

    # Start all tasks near-simultaneously
    for ($i = 1; $i -le $N; $i++) {
        Start-ScheduledTask -TaskName "gomapi-ramtest-ramtest$i"
    }

    # Wait for all per-user flags
    $ceilingMin = if ($Smoke) { 7 } else { 55 }
    $deadline = (Get-Date).AddMinutes($ceilingMin)
    while ((Get-Date) -lt $deadline) {
        $flags = Get-ChildItem -Path $WorkDir -Filter 'done-ramtest*.flag' -ErrorAction SilentlyContinue
        if ($flags.Count -ge $N) { break }
        Start-Sleep -Seconds 30
    }

    # Collate per-user CSVs
    $fragments = Get-ChildItem -Path $WorkDir -Filter 'phase-07-ram-gate-ramtest*.csv' -ErrorAction SilentlyContinue
    $headerWritten = $false
    foreach ($f in $fragments) {
        $lines = Get-Content $f.FullName
        if (-not $headerWritten) {
            Set-Content -Path $canonicalCsv -Value $lines -Encoding UTF8
            $headerWritten = $true
        } else {
            # Skip header on subsequent fragments
            Add-Content -Path $canonicalCsv -Value ($lines | Select-Object -Skip 1) -Encoding UTF8
        }
    }

    Set-Content -Path (Join-Path $WorkDir 'measurement-complete.flag') -Value (Get-Date -Format o)
    "[$(Get-Date -Format o)] Orchestrator done: fragments=$($fragments.Count) canonical=$canonicalCsv" |
        Out-File -FilePath $orchLog -Append -Encoding UTF8
    Stop-Transcript | Out-Null
    return
}

# ------------------------------------------------------------------ Aggregate
if ($PSCmdlet.ParameterSetName -eq 'Aggregate') {
    if (-not (Test-Path $Aggregate)) { throw "CSV not found: $Aggregate" }
    $rows = Import-Csv $Aggregate
    if (-not $rows) { throw "CSV empty: $Aggregate" }

    $scenarios = $rows | Group-Object scenario
    Write-Host ""
    Write-Host "Phase 7 RAM gate -- aggregate over $($rows.Count) rows from $Aggregate"
    Write-Host ""
    Write-Host ("{0,-22} {1,8} {2,8} {3,8} {4,8} {5,8} {6,8}" -f 'scenario','n','mean','max','stddev','mean_gm','mean_wv')

    foreach ($sc in $scenarios) {
        $totals = $sc.Group | ForEach-Object { [double]$_.total_ws_mb }
        $gmOnly = $sc.Group | ForEach-Object { [double]$_.go_mapi_ws_mb }
        $wvOnly = $sc.Group | ForEach-Object { [double]$_.webview2_ws_mb }
        $mean = [math]::Round(($totals | Measure-Object -Average).Average, 2)
        $max  = [math]::Round(($totals | Measure-Object -Maximum).Maximum, 2)
        $stddev = if ($totals.Count -gt 1) {
            $avg = ($totals | Measure-Object -Average).Average
            $sq  = ($totals | ForEach-Object { ($_ - $avg) * ($_ - $avg) } | Measure-Object -Sum).Sum
            [math]::Round([math]::Sqrt($sq / ($totals.Count - 1)), 2)
        } else { 0 }
        $meanGm = [math]::Round(($gmOnly | Measure-Object -Average).Average, 2)
        $meanWv = [math]::Round(($wvOnly | Measure-Object -Average).Average, 2)

        Write-Host ("{0,-22} {1,8} {2,8} {3,8} {4,8} {5,8} {6,8}" -f $sc.Name, $totals.Count, $mean, $max, $stddev, $meanGm, $meanWv)

        if ($mean -gt 0 -and ($stddev / $mean) -gt 0.20) {
            Write-Warning "scenario='$($sc.Name)': stddev $stddev is > 20% of mean $mean -- investigate variance per RESEARCH Pitfalls sec 1"
        }
    }

    $idlePost = $rows | Where-Object { $_.scenario -eq 'idle-post-webview' } | ForEach-Object { [double]$_.total_ws_mb }
    if ($idlePost) {
        $gate = [math]::Round(($idlePost | Measure-Object -Average).Average, 2)
        Write-Host ""
        Write-Host "GATE METRIC (idle-post-webview mean total_ws_mb): $gate MB vs 80 MB threshold (D-04)"
        if ($gate -le 30) { Write-Host "  STRETCH: <= 30 MB -- exceptional result per D-04 stretch goal." -ForegroundColor Green }
        elseif ($gate -le 80) { Write-Host "  WITHIN THRESHOLD (<= 80 MB)." -ForegroundColor Green }
        else { Write-Host "  EXCEEDS THRESHOLD (> 80 MB) -- D-12 contingency applies." -ForegroundColor Red }
    }
    return
}
