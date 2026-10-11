$ErrorActionPreference='Stop'
Import-Module tests/installed-attachment/hosted-capability-clock.psm1 -Force
Import-Module tests/installed-attachment/hosted-capability-index.psm1 -Force
$closeSample=Get-HostedCapabilityClockSample
$closeClock=Test-HostedCapabilityClock -ExpectedBootMarker $env:HOSTED_CAPABILITY_JOB_STARTED_BOOT -ObservedBootMarker $closeSample.bootMarker -ExpectedFrequency ([long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY) -ObservedFrequency $closeSample.frequency -JobStartCounter ([long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC) -CurrentCounter $closeSample.counter
$j25=[long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC+25L*60L*[long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY
if(!$closeClock.valid){throw 'Evidence retention refused an invalid job clock'}
$closeFailures=[Collections.Generic.List[object]]::new()
if($closeSample.counter -ge $j25){$closeFailures.Add(@{reason='local-final-j25-deadline-missed';successfulLocalFinal=$false})}
$evidence = Join-Path $env:RUNNER_TEMP 'ticket569-hosted-capability'
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$resultPath = Join-Path $evidence 'watchdog-result.json'
try {
if ($env:HOSTED_CAPABILITY_WATCHDOG_PID) {
  Import-Module tests/installed-attachment/hosted-capability-native.psm1 -Force
  $wi=Get-Content (Join-Path $evidence 'watchdog-process-identity.json') -Raw|ConvertFrom-Json
  if($wi.runId -cne $env:HOSTED_CAPABILITY_RUN_ID -or $wi.sourceSHA -cne $env:GITHUB_SHA -or [int]$wi.pid -ne [int]$env:HOSTED_CAPABILITY_WATCHDOG_PID){throw 'Closeout watchdog identity mismatch'}
  $retainedWatcher=Open-HostedCapabilityProcessIdentity -ProcessId ([uint32]$wi.pid) -CreationFileTimeUtc ([long]$wi.creationFileTimeUtc)
  try {
    $closeGate=Open-HostedCapabilityGate -Name "Global\Ticket569-$env:HOSTED_CAPABILITY_RUN_ID-watchdog-close" -Access 0x0002
    try{$closeGate.Release()}finally{$closeGate.Dispose()}
    $remaining=[int][Math]::Max(0,[Math]::Min(20000,($j25-[Diagnostics.Stopwatch]::GetTimestamp())*1000/[Diagnostics.Stopwatch]::Frequency))
    if(!$retainedWatcher.Wait($remaining)){throw 'Retained watchdog exit did not complete before closeout deadline'}
    [IO.File]::WriteAllText((Join-Path $evidence 'watchdog-close-wait.json'),(ConvertTo-Json -Compress @{runId=$wi.runId;sourceSHA=$wi.sourceSHA;process=$wi;retainedHandle=$true;waitedExit=$true;exitCode=$retainedWatcher.ExitCode})+"`n",[Text.UTF8Encoding]::new($false))
  }finally{$retainedWatcher.Dispose()}
}
}catch{$closeFailures.Add(@{reason='watchdog-close-failed';errorType=$_.Exception.GetType().FullName})}
if ($env:HOSTED_CAPABILITY_WATCHDOG_PID -and !(Test-Path -LiteralPath $resultPath)) {
  Import-Module tests/installed-attachment/hosted-capability-clock.psm1 -Force
  Import-Module tests/installed-attachment/hosted-capability-native.psm1 -Force
  $identityPath=Join-Path $evidence 'supervisor-identity.json'
  $processIdentityPath=Join-Path $evidence 'watchdog-process-identity.json'
  $jobResults=[Collections.Generic.List[object]]::new()
  foreach($name in @("Global\Ticket569-$env:HOSTED_CAPABILITY_RUN_ID-build","Global\Ticket569-$env:HOSTED_CAPABILITY_RUN_ID-worker","Global\Ticket569-$env:HOSTED_CAPABILITY_RUN_ID-session-owner","Global\Ticket569-$env:HOSTED_CAPABILITY_RUN_ID-recovery")){
    try {
      $job=Open-HostedCapabilityJob -Name $name -Access 0x0010000C
      try { $before=[uint32]$job.ActiveProcesses;if($before){$job.Terminate(137)};$jobSignaled=[bool]$job.Wait((Get-HostedCapabilityWaitBudget $j25 $closeSample.frequency 5000));$after=[uint32]$job.ActiveProcesses;$jobResults.Add(@{name=$name;before=$before;activeAfter=$after;jobCompletionSignaled=$jobSignaled;terminated=($after -eq 0 -and $jobSignaled)}) } finally {$job.Dispose()}
    } catch { $jobResults.Add(@{name=$name;activeAfter=$null;terminated=$false;errorType=$_.Exception.GetType().FullName}) }
  }
  $supervisorStop=$null
  if(Test-Path -LiteralPath $identityPath){try{$si=Get-Content $identityPath -Raw|ConvertFrom-Json;$supervisorStop=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$si.supervisor.pid) -CreationFileTimeUtc ([long]$si.supervisor.creationFileTimeUtc) -WaitMilliseconds (Get-HostedCapabilityWaitBudget $j25 $closeSample.frequency 5000)}catch{$supervisorStop=@{terminated=$false;errorType=$_.Exception.GetType().FullName}}}
  $watcherStop=$null
  if(Test-Path -LiteralPath $processIdentityPath){try{$wi=Get-Content $processIdentityPath -Raw|ConvertFrom-Json;if($wi.runId -cne $env:HOSTED_CAPABILITY_RUN_ID -or $wi.sourceSHA -cne $env:GITHUB_SHA){throw 'watchdog process identity mismatch'};$watcherStop=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$wi.pid) -CreationFileTimeUtc ([long]$wi.creationFileTimeUtc) -WaitMilliseconds (Get-HostedCapabilityWaitBudget $j25 $closeSample.frequency 5000)}catch{$watcherStop=@{terminated=$false;errorType=$_.Exception.GetType().FullName}}}
  $record=@{schema='ticket569-watchdog-v1';runId=$env:HOSTED_CAPABILITY_RUN_ID;sourceSHA=$env:GITHUB_SHA;status='cleanup-failed';reason='watchdog-result-missing';recoverySkipped=$true;supervisor=$supervisorStop;watchdog=$watcherStop;jobs=@($jobResults);atUtc=[DateTime]::UtcNow.ToString('o')}
  [IO.File]::WriteAllText($resultPath,(ConvertTo-Json -InputObject $record -Depth 12 -Compress)+"`n",[Text.UTF8Encoding]::new($false))
} elseif (!(Test-Path -LiteralPath $resultPath)) {
  [IO.File]::WriteAllText($resultPath,(ConvertTo-Json -InputObject @{schema='ticket569-watchdog-v1';runId=$env:HOSTED_CAPABILITY_RUN_ID;sourceSHA=$env:GITHUB_SHA;status='preflight-not-started';recoverySkipped=$true} -Compress)+"`n",[Text.UTF8Encoding]::new($false))
}
if($closeFailures.Count){[IO.File]::WriteAllText((Join-Path $evidence 'closeout-failures.json'),(ConvertTo-Json -Depth 12 -InputObject @{schema='ticket569-closeout-failure-v1';runId=$env:HOSTED_CAPABILITY_RUN_ID;sourceSHA=$env:GITHUB_SHA;failures=@($closeFailures);retentionStatus='attempted-unverified'})+"`n",[Text.UTF8Encoding]::new($false))}
Import-Module tests/installed-attachment/hosted-capability-retention.psm1 -Force
Assert-HostedCapabilityRetentionCanaries -Directory $evidence -RunId $env:HOSTED_CAPABILITY_RUN_ID -SourceSHA $env:GITHUB_SHA.ToLowerInvariant()
try{
    $indexResult=New-HostedCapabilityEvidenceIndex -Directory $evidence -RunId $env:HOSTED_CAPABILITY_RUN_ID -SourceSHA $env:GITHUB_SHA.ToLowerInvariant()
    if(!$indexResult.valid){throw 'Evidence index first audit failed'}
}catch{
    [IO.File]::WriteAllText((Join-Path $evidence 'index-first-failure.json'),(ConvertTo-Json -Compress @{schema='ticket569-index-failure-v1';errorType=$_.Exception.GetType().FullName;retentionStatus='attempted-unverified'})+"`n",[Text.UTF8Encoding]::new($false))
    # Retry the complete-set index after retaining the failure. No bypass or
    # partial-set upload is permitted if the second audit remains invalid.
    $indexResult=New-HostedCapabilityEvidenceIndex -Directory $evidence -RunId $env:HOSTED_CAPABILITY_RUN_ID -SourceSHA $env:GITHUB_SHA.ToLowerInvariant()
    if(!$indexResult.valid){throw 'Evidence retention remains blocked by an invalid complete-set index'}
}
Assert-HostedCapabilityRetentionCanaries -Directory $evidence -RunId $env:HOSTED_CAPABILITY_RUN_ID -SourceSHA $env:GITHUB_SHA.ToLowerInvariant()
Write-Output "HOSTED_CAPABILITY_EVIDENCE_INDEX_SHA256=$($indexResult.indexSHA256)"
$uploadGateSample=Get-HostedCapabilityClockSample
$uploadGateClock=Test-HostedCapabilityClock -ExpectedBootMarker $env:HOSTED_CAPABILITY_JOB_STARTED_BOOT -ObservedBootMarker $uploadGateSample.bootMarker -ExpectedFrequency ([long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY) -ObservedFrequency $uploadGateSample.frequency -JobStartCounter ([long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC) -CurrentCounter $uploadGateSample.counter
$uploadDecision=Get-HostedCapabilityUploadDecision -ClockValid $uploadGateClock.valid -IndexVerified $indexResult.valid -ActualStepStartCounter $uploadGateSample.counter -JobStartCounter ([long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC) -CounterFrequency ([long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY) -MaximumDurationSeconds 120
"HOSTED_CAPABILITY_UPLOAD_TIMEOUT_MINUTES=$($uploadDecision.timeoutMinutes)" | Add-Content -LiteralPath $env:GITHUB_ENV -Encoding utf8
"HOSTED_CAPABILITY_UPLOAD_ALLOWED=$($uploadDecision.allowed.ToString().ToLowerInvariant())" | Add-Content -LiteralPath $env:GITHUB_ENV -Encoding utf8
if(!$uploadDecision.allowed){throw "Evidence upload does not fit the absolute J+27 finish gate: $($uploadDecision.reason)"}
