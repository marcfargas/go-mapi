Set-StrictMode -Version Latest

function Get-HostedCapabilityClockSample {
    [CmdletBinding()]
    param()
    $bootMarker = if ($IsWindows) { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o') } else { (Get-Content -LiteralPath '/proc/sys/kernel/random/boot_id' -Raw).Trim() }
    [pscustomobject]@{
        utc = [DateTime]::UtcNow.ToString('o')
        counter = [Diagnostics.Stopwatch]::GetTimestamp()
        frequency = [Diagnostics.Stopwatch]::Frequency
        bootMarker = $bootMarker
    }
}

function Get-HostedCapabilityDeadlines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long] $JobStartCounter,
        [Parameter(Mandatory)][long] $CounterFrequency
    )
    if ($JobStartCounter -lt 0 -or $CounterFrequency -le 0) {
        throw 'The job-start counter and QPC frequency must be valid positive values'
    }
    [pscustomobject]@{
        launch = $JobStartCounter + 9L * 60L * $CounterFrequency
        work = $JobStartCounter + 21L * 60L * $CounterFrequency
        cleanup = $JobStartCounter + 24L * 60L * $CounterFrequency
        final = $JobStartCounter + 25L * 60L * $CounterFrequency
        watchdog = $JobStartCounter + 25L * 60L * $CounterFrequency
        upload = $JobStartCounter + 27L * 60L * $CounterFrequency
        job = $JobStartCounter + 30L * 60L * $CounterFrequency
    }
}

function Test-HostedCapabilityClock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedBootMarker,
        [Parameter(Mandatory)][string] $ObservedBootMarker,
        [Parameter(Mandatory)][long] $ExpectedFrequency,
        [Parameter(Mandatory)][long] $ObservedFrequency,
        [Parameter(Mandatory)][long] $JobStartCounter,
        [Parameter(Mandatory)][long] $CurrentCounter
    )
    $reasons = [Collections.Generic.List[string]]::new()
    if (!$ExpectedBootMarker -or $ExpectedBootMarker -cne $ObservedBootMarker) { $reasons.Add('boot-marker-changed') }
    if ($ExpectedFrequency -le 0 -or $ExpectedFrequency -ne $ObservedFrequency) { $reasons.Add('qpc-frequency-changed') }
    if ($CurrentCounter -lt $JobStartCounter) { $reasons.Add('qpc-counter-went-backwards') }
    [pscustomobject]@{ valid=($reasons.Count -eq 0); reasons=@($reasons) }
}

function Get-HostedCapabilityBuildAllowance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long] $JobStartCounter,
        [Parameter(Mandatory)][long] $CounterFrequency,
        [Parameter(Mandatory)][long] $NonBuildCompleteCounter,
        [Parameter(Mandatory)][long] $NowCounter,
        [ValidateRange(1, 420)][int] $MaximumBuildSeconds = 420
    )
    if ($CounterFrequency -le 0) { throw 'QPC frequency must be positive' }
    $j2 = $JobStartCounter + 2L * 60L * $CounterFrequency
    $j9 = $JobStartCounter + 9L * 60L * $CounterFrequency
    if ($NonBuildCompleteCounter -gt $j2) {
        return [pscustomobject]@{ allowed=$false; remainingSeconds=0; reason='non-build-preparation-exceeded-j-plus-2' }
    }
    if ($NowCounter -ge $j9) {
        return [pscustomobject]@{ allowed=$false; remainingSeconds=0; reason='build-window-ended-at-j-plus-9' }
    }
    $remaining = [Math]::Floor(($j9 - $NowCounter) / [double]$CounterFrequency)
    $allowedSeconds = [int][Math]::Min($MaximumBuildSeconds, $remaining)
    [pscustomobject]@{
        allowed=($allowedSeconds -gt 0)
        remainingSeconds=$allowedSeconds
        reason=if ($allowedSeconds -gt 0) { $null } else { 'no-build-time-remains' }
    }
}

function Get-HostedProbeStepBackstop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long] $JobStartCounter,
        [Parameter(Mandatory)][long] $CounterFrequency,
        [Parameter(Mandatory)][long] $ActualStepStartCounter
    )
    if ($CounterFrequency -le 0) { throw 'QPC frequency must be positive' }
    $deadline = $JobStartCounter + 25L * 60L * $CounterFrequency
    $safeDeadline = $deadline
    $remainingSeconds = [Math]::Floor(($safeDeadline - $ActualStepStartCounter) / [double]$CounterFrequency)
    [pscustomobject]@{
        deadlineCounter=$safeDeadline
        watchdogDeadlineCounter=$deadline
        remainingSeconds=[int]$remainingSeconds
        timeoutMinutes=[int][Math]::Min(26,[Math]::Floor($remainingSeconds / 60))
        launchAllowed=($remainingSeconds -ge 60)
    }
}

function Get-HostedCapabilityWatchdogDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $ClockValid,
        [Parameter(Mandatory)][long] $CurrentCounter,
        [Parameter(Mandatory)][long] $DeadlineCounter,
        [Parameter(Mandatory)][bool] $CompletionVerified
    )
    if(!$ClockValid){return [pscustomobject]@{action='terminate';reason='clock-continuity-lost'}}
    if($CurrentCounter -ge $DeadlineCounter){return [pscustomobject]@{action='terminate';reason='absolute-j-plus-25-watchdog'}}
    if($CompletionVerified){return [pscustomobject]@{action='complete';reason='supervisor-completed'}}
    [pscustomobject]@{action='wait';reason='supervisor-not-finalized'}
}

function Get-HostedCapabilityUploadDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $ClockValid,
        [Parameter(Mandatory)][bool] $IndexVerified,
        [Parameter(Mandatory)][long] $ActualStepStartCounter,
        [Parameter(Mandatory)][long] $JobStartCounter,
        [Parameter(Mandatory)][long] $CounterFrequency,
        [ValidateRange(1,120)][int] $MaximumDurationSeconds=120
    )
    if($CounterFrequency -le 0){throw 'QPC frequency must be positive'}
    $finishDeadline=$JobStartCounter+27L*60L*$CounterFrequency
    $remainingSeconds=[int][Math]::Floor(($finishDeadline-$ActualStepStartCounter)/[double]$CounterFrequency)
    # A retained upload child enforces seconds; the GHA whole-minute timeout
    # remains only an outer backstop and never suppresses a subminute attempt.
    $duration=[int][Math]::Max(0,[Math]::Min($MaximumDurationSeconds,$remainingSeconds))
    $finishBound=$ActualStepStartCounter+[long]$duration*$CounterFrequency
    $allowed=[bool]($ClockValid -and $IndexVerified -and $duration -gt 0 -and $finishBound -le $finishDeadline)
    [pscustomobject]@{allowed=$allowed;reason=if(!$ClockValid){'clock-continuity-lost'}elseif(!$IndexVerified){'evidence-index-unverified'}elseif($duration -le 0){'no-upload-time-remains'}else{$null};startDeadlineCounter=$finishDeadline;finishDeadlineCounter=$finishDeadline;worstCaseFinishCounter=$finishBound;maximumDurationSeconds=$duration;timeoutMinutes=2}

}

Export-ModuleMember -Function Get-HostedCapabilityClockSample, Get-HostedCapabilityDeadlines, Test-HostedCapabilityClock, Get-HostedCapabilityBuildAllowance, Get-HostedProbeStepBackstop, Get-HostedCapabilityWatchdogDecision, Get-HostedCapabilityUploadDecision

function Get-HostedCapabilityWaitBudget([long]$DeadlineCounter,[long]$CounterFrequency,[int]$MaximumMilliseconds,[long]$NowCounter=[Diagnostics.Stopwatch]::GetTimestamp()) {
    if($CounterFrequency -le 0 -or $MaximumMilliseconds -lt 0){throw 'Invalid wait budget'}
    [int][Math]::Max(0,[Math]::Min($MaximumMilliseconds,[Math]::Floor(($DeadlineCounter-$NowCounter)*1000.0/$CounterFrequency)))
}
Export-ModuleMember -Function Get-HostedCapabilityWaitBudget
