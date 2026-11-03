# Exercise fixture service-control refusal paths without changing host services.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'UpdateSupport.ps1')
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch { Assert ($_.Exception.Message -match $Pattern) "Unexpected rejection: $_"; return }
    throw "Expected rejection: $Pattern"
}
function Reset {
    $script:timers=$true; $script:Phase='ReadinessRecovery'
    $script:pending=$false; $script:latePending=$false; $script:checks=0
    $script:mutexIdle=$true; $script:mode=''; $script:recorded=@(); $script:live=$false
    $script:server=[pscustomobject]@{Status='Running';CanStop=$true;DependentServices=@();stops=0;disposed=$false}
    $script:server | Add-Member ScriptMethod Refresh { }
    $script:server | Add-Member ScriptMethod Stop {
        $this.stops++
        if ($script:mode -eq 'refused') { throw 'SCM refused stop' }
        if ($script:mode -ne 'timeout') { $this.Status='Stopped' }
    }
    $script:server | Add-Member ScriptMethod WaitForStatus { param($Status,$Timeout)
        if ($script:mode -eq 'timeout') { throw 'stop timeout' }
    }
    $script:server | Add-Member ScriptMethod Dispose { $this.disposed=$true }
}
function Get-Service { param($Name,$ErrorAction) Assert ($Name -eq 'msiserver') 'Wrong service'; $script:server }
function AssertHealthy { param($Key)
    $script:checks++
    @{pending=($script:pending -or ($script:latePending -and $script:checks -gt 1))}
}
function TestFixtureInstallerMutexIdle { $script:mutexIdle }
function Record { param($Kind,$Value) $script:recorded+=@{kind=$Kind;value=$Value} }
function Until { param($Label,$Condition,$PollMilliseconds,$Seconds)
    Assert ($Seconds -eq 30) 'Process wait must be bounded'
    if (-not (& $Condition)) { throw 'completed process still alive' }
}
function Get-Process { param($Id,$ErrorAction)
    if ($script:mode -eq 'process-unknown') { throw 'process access denied' }
    if ($script:live) {
        $process=[pscustomobject]@{Id=if ($script:mode -eq 'wrong-pid') {3} else {$Id};StartTime=[DateTime]::new(621355968000000010L + $(if ($script:mode -eq 'reused') {100} else {0}),[DateTimeKind]::Utc)}
        $process | Add-Member ScriptMethod Dispose { }
        if ($script:mode -eq 'multiple') { return @($process,$process) }
        return $process
    }
    if ($script:mode -eq 'unproved-absence') { return }
    Microsoft.PowerShell.Management\Get-Process -Id $Id -ErrorAction Stop
}
$ready=[pscustomobject]@{runner=@{pid=2147483646;createdAtUnixNano=1000L};installer=@{pid=2147483647;createdAtUnixNano=1000L}}
Reset
StopIdleReadinessInstaller 'suiteB' $ready
Assert ($server.stops -eq 1 -and $server.disposed -and $recorded.Count -eq 1 -and $recorded[0].value.after -eq 'Stopped') 'Normal idle stop lacks proof'
foreach ($case in @('native-absent','reused')) {
    Reset; $mode=$case; $live=$case -eq 'reused'
    StopIdleReadinessInstaller 'suiteB' $ready
    Assert ($server.stops -eq 1) "Safe $case blocked fixture setup"
}
Reset; $server.Status='Stopped'
StopIdleReadinessInstaller 'suiteA'
Assert ($server.stops -eq 0 -and $server.disposed -and $recorded.Count -eq 1) 'Stopped service should be observed without control'
foreach ($case in @('production','interruption')) {
    Reset
    if ($case -eq 'production') { $timers=$false } else { $Phase='InterruptSameBoot' }
    StopIdleReadinessInstaller 'suiteA'
    Assert ($checks -eq 0 -and $server.stops -eq 0 -and $recorded.Count -eq 0) 'Helper escaped validation readiness scope'
}
foreach ($case in @('pending','late-pending','mutex','cannot-stop','transition','dependent','alive','process-unknown','missing-identity','float-nanos','string-nanos','wrong-pid','multiple','unproved-absence','refused','timeout')) {
    Reset; $inputReady=$ready
    switch ($case) {
        'pending' {$pending=$true}
        'late-pending' {$latePending=$true}
        'mutex' {$mutexIdle=$false}
        'cannot-stop' {$server.CanStop=$false}
        'transition' {$server.Status='StartPending'}
        'dependent' {$server.DependentServices=@(@{Status='Running'})}
        'alive' {$live=$true}
        'process-unknown' {$mode=$case}
        'missing-identity' {$inputReady=@{runner=$null;installer=$null}}
        'float-nanos' {$inputReady=@{runner=@{pid=1;createdAtUnixNano=1000.0};installer=$ready.installer}}
        'string-nanos' {$inputReady=@{runner=@{pid=1;createdAtUnixNano='1000'};installer=$ready.installer}}
        'wrong-pid' {$live=$true; $mode=$case}
        'multiple' {$live=$true; $mode=$case}
        default {$mode=$case}
    }
    Reject { StopIdleReadinessInstaller 'suiteB' $inputReady } 'pending|busy|dependent|alive|denied|identity|absence|refused|timeout'
    Assert ($recorded.Count -eq 0) "Failed $case published success"
    if ($case -notin @('refused','timeout')) { Assert ($server.stops -eq 0) "Unsafe $case sent stop" }
}
Write-Host 'Readiness installer fixture contracts passed.'
