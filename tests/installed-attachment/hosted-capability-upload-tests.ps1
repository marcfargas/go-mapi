$ErrorActionPreference='Stop'
if(!$IsWindows){Write-Output 'HOSTED_CAPABILITY_UPLOAD_KERNEL_TESTS_UNRUN: actual retained upload child/Job Object requires Windows;runner-cache/network-integration UNRUN';exit 0}
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-index.psm1') -Force
$temp=Join-Path $env:TEMP ('t569-upload-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
$cache=Join-Path $temp '_actions/actions/upload-artifact/v4';New-Item -ItemType Directory (Join-Path $cache 'dist/upload') -Force|Out-Null
"runs:`n  using: node20`n  main: dist/upload/index.js`n"|Set-Content (Join-Path $cache 'action.yml')
$node=(Get-Command node.exe -ErrorAction Stop).Source
try{
 foreach($case in @(@{name='subminute-success';budget=25;hold=250},@{name='subminute-hang';budget=20;hold=30000})){
  $run=[guid]::NewGuid().ToString('N');$sha='b'*40;$evidence=Join-Path $temp $case.name;New-Item -ItemType Directory $evidence|Out-Null
  [IO.File]::WriteAllText((Join-Path $evidence 'failure-evidence.json'),'{"status":"cleanup-failed","qualification":"synthetic upload fixture"}')
  $null=New-HostedCapabilityEvidenceIndex -Directory $evidence -RunId $run -SourceSHA $sha
  ("setTimeout(()=>process.exit(0),"+$case.hold+");")|Set-Content (Join-Path $cache 'dist/upload/index.js')
  $sample=Get-HostedCapabilityClockSample;$start=$sample.counter-(27L*60L-$case.budget)*$sample.frequency
  $psi=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'));$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  foreach($arg in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'hosted-capability-upload.ps1'),'-NodeExecutable',$node)){$psi.ArgumentList.Add($arg)}
  foreach($pair in @(@{key='INPUT_PATH';value=$evidence},@{key='INPUT_JOB_START_COUNTER';value=[string]$start},@{key='INPUT_COUNTER_FREQUENCY';value=[string]$sample.frequency},@{key='INPUT_BOOT_MARKER';value=$sample.bootMarker},@{key='HOSTED_CAPABILITY_RUN_ID';value=$run},@{key='GITHUB_SHA';value=$sha},@{key='RUNNER_TEMP';value=(Join-Path $temp '_temp')})){$psi.Environment[$pair.key]=$pair.value}
  $p=[Diagnostics.Process]::Start($psi);$output=$p.StandardOutput.ReadToEndAsync();$errorText=$p.StandardError.ReadToEndAsync()
  try{
   if(!$p.WaitForExit(40000)){throw 'Upload controller fixture exceeded its retained outer bound'}
   $receipt=@($output.Result -split '\r?\n'|Where-Object {$_ -like '*ticket569-upload-attempt-v1*'})
   if($receipt.Count -ne 1){Write-Output $errorText.Result;throw 'Actual upload controller omitted its qualified attempt receipt'}
   $r=ConvertFrom-Json $receipt[0]
   if($case.name -ceq 'subminute-success'){
    if($p.ExitCode -ne 0 -or $r.status -cne 'attempted-unverified' -or !$r.exitProven -or !$r.jobEmpty -or $r.remoteRetentionVerified){throw 'Subminute actual upload child success fabricated or omitted qualified exit proof'}
   }else{
    if($p.ExitCode -eq 0 -or $r.status -cne 'attempted-failed' -or $r.reason -cne 'attempted-failed-deadline'){throw 'Actual retained upload hang did not fail at its seconds deadline'}
   }
   Write-Output "ACTUAL_UPLOAD_CONTROLLER_JOB_FIXTURE case=$($case.name) seconds=$($case.budget) status=$($r.status);ACTION_ENTRY_ADAPTER_NO_NETWORK_OR_HOSTED_CACHE_PROOF"
  }finally{if(!$p.HasExited){$p.Kill($true);$null=$p.WaitForExit(5000)};$p.Dispose()}
 }
}finally{Remove-Item $temp -Recurse -Force}
