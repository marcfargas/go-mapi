$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
function Parse($Name){$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name),[ref]$t,[ref]$e);if($e){throw "Clock extraction parse $Name"};$ast}
$supervisor=Parse 'hosted-capability-supervisor.ps1';$worker=Parse 'hosted-capability.ps1'
$guards=@($supervisor.EndBlock.Statements|Where-Object {$_.Extent.Text.StartsWith("if(`$env:GITHUB_ACTIONS -eq 'true' -and")})
$branches=@($worker.EndBlock.Statements|Where-Object {$_.Extent.Text.StartsWith("if (`$env:GITHUB_ACTIONS -eq 'true' -or")})
if($guards.Count -ne 1 -or $branches.Count -ne 1){throw 'Exact guard/clock branch extraction not unique'}
$guard=[scriptblock]::Create($guards[0].Extent.Text);$branch=[scriptblock]::Create($branches[0].Extent.Text)
$names=@('GITHUB_ACTIONS','HOSTED_CAPABILITY_JOB_STARTED_QPC','HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY','HOSTED_CAPABILITY_JOB_STARTED_BOOT')
$original=@{};foreach($name in $names){$original[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try {
 foreach($github in @('true',$null)){foreach($mode in @('none','before-runtime-intent','after-user-create','present-root-recovery')){
  [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS',$(if($null -eq $github){[NullString]::Value}else{$github}),'Process');$TestFault=$mode;$refused=$false
  try{. $guard}catch{$refused=$true}
  if($refused -ne ($github -ceq 'true' -and $mode -ceq 'present-root-recovery')){throw "Supervisor early guard changed legacy behavior $github $mode"}
 }}
 [Environment]::SetEnvironmentVariable('GITHUB_ACTIONS',[NullString]::Value,'Process')
 $clockSample=@{counter=[Diagnostics.Stopwatch]::GetTimestamp();frequency=[Diagnostics.Stopwatch]::Frequency;bootMarker='source-adapter-boot'}
 $TestFault='present-root-recovery';$startedAt=[DateTime]::UtcNow;$JobStartedAtUtc=$startedAt.ToString('o');$parentStart=$clockSample.counter-10L*$clockSample.frequency
 $env:HOSTED_CAPABILITY_JOB_STARTED_QPC=[string]$parentStart;$env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY=[string]$clockSample.frequency;$env:HOSTED_CAPABILITY_JOB_STARTED_BOOT=$clockSample.bootMarker
 . $branch
 if($jobStartCounter -ne $parentStart -or $counterFrequency -ne $clockSample.frequency -or $bootMarker -cne $clockSample.bootMarker){throw 'Exercise worker did not preserve actual validated supervisor clock markers'}
 foreach($missing in @('HOSTED_CAPABILITY_JOB_STARTED_QPC','HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY','HOSTED_CAPABILITY_JOB_STARTED_BOOT')){
  $previous=[Environment]::GetEnvironmentVariable($missing,'Process');[Environment]::SetEnvironmentVariable($missing,[NullString]::Value,'Process');$refused=$false
  try{. $branch}catch{$refused=$true}
  [Environment]::SetEnvironmentVariable($missing,$previous,'Process');if(!$refused){throw "Exercise missing marker escaped $missing"}
 }
 foreach($fault in @('boot','frequency','future-counter')){
  $env:HOSTED_CAPABILITY_JOB_STARTED_QPC=[string]$parentStart;$env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY=[string]$clockSample.frequency;$env:HOSTED_CAPABILITY_JOB_STARTED_BOOT=$clockSample.bootMarker
  switch($fault){boot {$env:HOSTED_CAPABILITY_JOB_STARTED_BOOT='wrong'} frequency {$env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY='1'} future-counter {$env:HOSTED_CAPABILITY_JOB_STARTED_QPC=[string]($clockSample.counter+1)}}
  $refused=$false;try{. $branch}catch{$refused=$true};if(!$refused){throw "Invalid exercise clock escaped $fault"}
 }
 foreach($mode in @('none','before-runtime-intent','after-user-create')){
  foreach($name in $names){[Environment]::SetEnvironmentVariable($name,[NullString]::Value,'Process')}
  $TestFault=$mode;. $branch
  if($jobStartCounter -ne $clockSample.counter -or $counterFrequency -ne $clockSample.frequency -or $bootMarker -cne $clockSample.bootMarker){throw "Legacy local clock changed $mode"}
 }
 Write-Output 'PRESENT_ROOT_SSH_CONTAINMENT_SHARED_CLOCK_EXTRACTED_PASSED;CLOCK_SAMPLE_ADAPTER_NO_WINDOWS_RUNTIME'
}finally{foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$(if($null -eq $original[$name]){[NullString]::Value}else{$original[$name]}),'Process')}}
