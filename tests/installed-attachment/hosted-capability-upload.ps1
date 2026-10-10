[CmdletBinding()]
param([Parameter(Mandatory)][string]$NodeExecutable)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-index.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force
$evidence=$env:INPUT_PATH;$start=[long]$env:INPUT_JOB_START_COUNTER;$frequency=[long]$env:INPUT_COUNTER_FREQUENCY
$sample=Get-HostedCapabilityClockSample
$clock=Test-HostedCapabilityClock -ExpectedBootMarker $env:INPUT_BOOT_MARKER -ObservedBootMarker $sample.bootMarker -ExpectedFrequency $frequency -ObservedFrequency $sample.frequency -JobStartCounter $start -CurrentCounter $sample.counter
if(!$clock.valid){throw 'Upload refused invalid job clock'}
$audit=Test-HostedCapabilityEvidenceIndex -Directory $evidence -RunId $env:HOSTED_CAPABILITY_RUN_ID -SourceSHA $env:GITHUB_SHA.ToLowerInvariant()
if(!$audit.valid){throw 'Upload refused an incomplete or changed indexed file set'}
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-retention.psm1') -Force
Assert-HostedCapabilityRetentionCanaries -Directory $evidence -RunId $env:HOSTED_CAPABILITY_RUN_ID -SourceSHA $env:GITHUB_SHA.ToLowerInvariant()
# Runner ActionManager prepares referenced actions before evaluating step if.
# RUNNER_TEMP is the runner work/_temp directory; sibling _actions is the cache.
$action=Join-Path (Split-Path $env:RUNNER_TEMP -Parent) '_actions/actions/upload-artifact/v4'
$manifest=Join-Path $action 'action.yml';$entry=Join-Path $action 'dist/upload/index.js'
if(!(Test-Path -LiteralPath $entry -PathType Leaf) -or !(Test-Path -LiteralPath $manifest -PathType Leaf) -or
   (Get-Content -LiteralPath $manifest -Raw) -notmatch 'using:\s*[''"]?node20[''"]?' -or
   (Get-Content -LiteralPath $manifest -Raw) -notmatch 'main:\s*[''"]?dist/upload/index\.js[''"]?'){
    throw 'Prepared upload-artifact v4 node20 entry point is unavailable or differs from the reviewed contract'
}
$sample=Get-HostedCapabilityClockSample
$decision=Get-HostedCapabilityUploadDecision -ClockValid $clock.valid -IndexVerified $audit.valid -ActualStepStartCounter $sample.counter -JobStartCounter $start -CounterFrequency $frequency
if(!$decision.allowed){throw "Actual upload start refused: $($decision.reason)"}
$deadline=[long][Math]::Min($decision.finishDeadlineCounter,$sample.counter+[long]$decision.maximumDurationSeconds*$frequency)
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$job=New-HostedCapabilityJob -Name ('Global\Ticket569-'+$env:HOSTED_CAPABILITY_RUN_ID+'-upload') -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
$child=$null;$failure=$null
try{
    $child=Start-HostedCapabilityProcess -Job $job -Executable $NodeExecutable -ArgumentList @($entry) -WorkingDirectory $action
    $identity=@{pid=$child.ProcessId;creationFileTimeUtc=$child.CreationFileTimeUtc;executable=$NodeExecutable;entry=$entry;entrySHA256=(Get-FileHash $entry).Hash.ToLowerInvariant()}
    if(!$child.Wait((Get-HostedCapabilityWaitBudget $deadline $frequency 120000))){
        $job.Terminate(137)
        $failure='attempted-failed-deadline'
    }elseif($child.ExitCode -ne 0){$failure='attempted-failed-nonzero'}
    $exitProven=$child.Wait(0);$jobEmpty=($job.ActiveProcesses -eq 0)
    $finished=[Diagnostics.Stopwatch]::GetTimestamp()
    Write-Output (ConvertTo-Json -Compress -Depth 8 @{schema='ticket569-upload-attempt-v1';status=if(!$failure -and $exitProven -and $jobEmpty -and $finished -lt $deadline){'attempted-unverified'}else{'attempted-failed'};reason=$failure;actualStartCounter=$sample.counter;actualFinishCounter=$finished;deadlineCounter=$deadline;retainedIdentity=$identity;exitProven=$exitProven;jobEmpty=$jobEmpty;exitCode=if($exitProven){$child.ExitCode}else{$null};remoteRetentionVerified=$false})
    if($failure -or !$exitProven -or !$jobEmpty -or $finished -ge $deadline){throw 'Bounded upload failed or its actual exit/finish remains unproved'}
}finally{if($job.ActiveProcesses){$job.Terminate(137)};if($child){$child.Dispose()};$job.Dispose()}
