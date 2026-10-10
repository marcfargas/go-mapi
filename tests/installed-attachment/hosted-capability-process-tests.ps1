$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
if (-not $IsWindows) {
    Write-Output 'HOSTED_CAPABILITY_PROCESS_TESTS_SKIPPED_NON_WINDOWS'
    exit 0
}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$run=[guid]::NewGuid().ToString('N')
$name="Global\Ticket569-Test-$run"
$sddl="D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
$job=$null
$watchdogView=$null
$child=$null
$grandchild=$null
$failureSignaler=$null
$suspendedChild=$null
$gate=$null
$failureEvent=$null
$temp=Join-Path ([IO.Path]::GetTempPath()) "ticket569-$run"
New-Item -ItemType Directory -Path $temp | Out-Null
$grandchildPath=Join-Path $temp 'grandchild.pid'
$suspendedMarker=Join-Path $temp 'suspended-child-started'
try {
    $job=New-HostedCapabilityJob -Name $name -DaclSddl $sddl
    if ($job.LimitFlags -ne 0x2000) { throw 'job did not retain kill-on-close without breakaway flags' }
    $pwsh=(Join-Path $PSHOME 'pwsh.exe')
    $suspendedChild=Start-HostedCapabilityProcess -Job $job -Executable $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-Command',"[IO.File]::WriteAllText('$suspendedMarker','started')") -LeaveSuspended
    if (Test-Path -LiteralPath $suspendedMarker) { throw 'suspended assigned process executed before explicit resume' }
    if ([IO.Path]::GetFullPath($suspendedChild.ImagePath) -cne [IO.Path]::GetFullPath($pwsh)) { throw 'retained suspended child image did not match its exact executable before resume' }
    if ($job.ActiveProcesses -lt 1 -or -not (Test-HostedCapabilityProcessIdentity -ProcessId $suspendedChild.ProcessId -CreationFileTimeUtc $suspendedChild.CreationFileTimeUtc).matches) { throw 'suspended child was not identity-observed inside its Job Object before release' }
    if (-not (Test-HostedCapabilityProcessInJob -ProcessId $suspendedChild.ProcessId -JobName $name)) { throw 'separately opened process handle did not prove exact Job Object membership' }
    $suspendedChild.Resume()
    if (-not $suspendedChild.Wait(10000) -or -not (Test-Path -LiteralPath $suspendedMarker)) { throw 'explicitly resumed suspended child did not execute and exit' }
    $suspendedChild.Dispose();$suspendedChild=$null
    $gateName="Global\Ticket569-$run-recovery-gate"
    $gate=New-HostedCapabilityGate -Name $gateName -DaclSddl $sddl
    if ($gate.Wait(0)) { throw 'recovery gate must begin unsignaled' }
    $gate.Release()
    if (-not $gate.Wait(0)) { throw 'one-way recovery gate release was not visible to its creator' }
    $failureName="Global\Ticket569-$run-failure"
    $failureEvent=New-HostedCapabilityGate -Name $failureName -DaclSddl $sddl
    $nativeModule=Join-Path $PSScriptRoot 'hosted-capability-native.psm1'
    $signalCode="Import-Module '$nativeModule' -Force; Set-HostedCapabilityFailureEvent -Name '$failureName'"
    $encodedSignal=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($signalCode))
    $failureSignaler=Start-HostedCapabilityProcess -Job $job -Executable $pwsh -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$encodedSignal)
    if(-not $failureEvent.Wait(10000) -or -not $failureSignaler.Wait(10000)){throw 'separate process could not irreversibly signal the run-scoped Global failure event'}
    if($failureSignaler.ExitCode -ne 0){throw 'cross-process failure-event signaler exited unsuccessfully'}
    $failureSignaler.Dispose();$failureSignaler=$null
    # Two independent signalers must preserve the same manual-reset latch.
    $signals=@()
    try{
        1..2 | ForEach-Object {$signals+=Start-HostedCapabilityProcess -Job $job -Executable $pwsh -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',$encodedSignal)}
        foreach($signal in $signals){if(!$signal.Wait(10000) -or $signal.ExitCode -ne 0){throw 'Concurrent failure signaler did not exit'}}
        if(!$failureEvent.Wait(0)){throw 'A later process cleared the supervisor-visible irreversible latch'}
    }finally{foreach($signal in $signals){$signal.Dispose()}}
    # A caller with synchronize-only access cannot set the global event.
    Set-HostedCapabilityGateDacl -Gate $failureEvent -DaclSddl "D:P(A;;GA;;;SY)(A;;0x00100000;;;$sid)"
    $accessDenied=$false
    try{$unauthorized=Open-HostedCapabilityGate -Name $failureName -Access 0x0002;$unauthorized.Dispose()}catch{$accessDenied=$true}
    if(!$accessDenied -or !$failureEvent.Wait(0)){throw 'Restricted event DACL allowed modify-state or erased the retained latch'}
    $failureEvent.Dispose();$failureEvent=$null
    $grandchildCommand="Start-Process -FilePath '$pwsh' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -PassThru | ForEach-Object { [IO.File]::WriteAllText('$grandchildPath',[string]$_.Id) }; Start-Sleep -Seconds 120"
    $child=Start-HostedCapabilityProcess -Job $job -Executable $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-Command',$grandchildCommand)
    $watchdogView=Open-HostedCapabilityJob -Name $name
    if (($watchdogView.LimitFlags -band 0x2000) -eq 0) { throw 'independent watchdog handle could not query the named job limits' }
    $identity=Test-HostedCapabilityProcessIdentity -ProcessId $child.ProcessId -CreationFileTimeUtc $child.CreationFileTimeUtc
    if (-not $identity.matches) { throw 'opened process identity did not match its retained creation time' }
    $mismatch=Test-HostedCapabilityProcessIdentity -ProcessId $child.ProcessId -CreationFileTimeUtc ($child.CreationFileTimeUtc+1)
    if ($mismatch.matches) { throw 'PID/creation mismatch must refuse process identity validation' }
    $mismatchStop=Stop-HostedCapabilityProcessIdentity -ProcessId $child.ProcessId -CreationFileTimeUtc ($child.CreationFileTimeUtc+1)
    if ($mismatchStop.terminated) { throw 'PID/creation mismatch must refuse process termination' }
    if (-not (Test-HostedCapabilityProcessIdentity -ProcessId $child.ProcessId -CreationFileTimeUtc $child.CreationFileTimeUtc).matches) {
        throw 'mismatched identity termination attempt affected the live process'
    }
    $stopAt=[DateTime]::UtcNow.AddSeconds(10)
    while (!(Test-Path -LiteralPath $grandchildPath) -and [DateTime]::UtcNow -lt $stopAt) { Start-Sleep -Milliseconds 50 }
    if (!(Test-Path -LiteralPath $grandchildPath)) { throw 'real grandchild did not start inside the assigned Job Object' }
    $grandchildId=[uint32](Get-Content -LiteralPath $grandchildPath -Raw)
    $grandchildObservation=Get-Process -Id $grandchildId -ErrorAction Stop
    try{
        $grandchild=Open-HostedCapabilityProcessIdentity -ProcessId $grandchildId -CreationFileTimeUtc $grandchildObservation.StartTime.ToUniversalTime().ToFileTimeUtc()
    }finally{$grandchildObservation.Dispose()}
    if ($grandchild.Wait(0) -or
        -not (Test-HostedCapabilityProcessInJob -ProcessId $grandchild.ProcessId -JobName $name) -or
        -not (Test-HostedCapabilityProcessIdentity -ProcessId $grandchild.ProcessId -CreationFileTimeUtc $grandchild.CreationFileTimeUtc).matches -or
        $grandchild.Wait(0)) { throw 'grandchild was not the exact live retained process inside the assigned Job before termination' }
    if ($job.ActiveProcesses -lt 2) { throw 'job active-process count did not include the real grandchild' }
    $watchdogView.Terminate(91)
    $jobEmptyBy=[DateTime]::UtcNow.AddSeconds(10)
    while ($job.ActiveProcesses -ne 0 -and [DateTime]::UtcNow -lt $jobEmptyBy) { Start-Sleep -Milliseconds 25 }
    if ($job.ActiveProcesses -ne 0) { throw 'job active-process count was nonzero after bounded termination wait' }
    $retainedExitWait=[int][Math]::Max(0,[Math]::Min(10000,[Math]::Ceiling(($jobEmptyBy-[DateTime]::UtcNow).TotalMilliseconds)))
    if ($child.Wait($retainedExitWait) -ne $true) { throw 'retained process handle did not signal after job termination' }
    $grandchildExitWait=[int][Math]::Max(0,[Math]::Min(10000,[Math]::Ceiling(($jobEmptyBy-[DateTime]::UtcNow).TotalMilliseconds)))
    if ($grandchild.Wait($grandchildExitWait) -ne $true) { throw 'signal-ignoring grandchild did not prove retained-handle exit before the job termination deadline' }
    Write-Output 'HOSTED_CAPABILITY_PROCESS_TESTS_PASSED'
} finally {
    if ($suspendedChild) { $suspendedChild.Dispose() }
    if ($failureSignaler) { $failureSignaler.Dispose() }
    if ($gate) { $gate.Dispose() }
    if ($failureEvent) { $failureEvent.Dispose() }
    if ($child) { $child.Dispose() }
    if ($grandchild) { $grandchild.Dispose() }
    if ($watchdogView) { $watchdogView.Dispose() }
    if ($job) { $job.Dispose() }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
