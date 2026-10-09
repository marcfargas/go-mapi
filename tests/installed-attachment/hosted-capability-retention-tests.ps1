$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-retention.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force
$run='a'*32;$sha='b'*40;$temp=Join-Path ([IO.Path]::GetTempPath()) ('t569-retention-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp|Out-Null
try{
 $secret=[guid]::NewGuid().ToString('N');$canary=New-HostedSecretCanary (ConvertTo-SecureString $secret -AsPlainText -Force)
 $identity=@{schema='ticket569-secret-canary-v1';runId=$run;sourceSHA=$sha;hashes=@($canary)}
 $identity|ConvertTo-Json -Depth 8|Set-Content (Join-Path $temp 'secret-canary-identity.json')
 @{status='cleanup-failed';reason='watchdog-result-missing'}|ConvertTo-Json|Set-Content (Join-Path $temp 'watchdog-result.json')
 Assert-HostedCapabilityRetentionCanaries $temp $run $sha
 [IO.File]::WriteAllText((Join-Path $temp 'leak'),$secret)
 $denied=$false;try{Assert-HostedCapabilityRetentionCanaries $temp $run $sha}catch{$denied=$true};if(!$denied){throw 'Leaking failure evidence was accepted'}
 Remove-Item (Join-Path $temp 'leak')
 foreach($checked in @($false,$true)){
  @{runId=$run;sourceSHA=$sha;secretCanary=@{checked=$checked;leakDetected=$false;hashes=@($canary)}}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $temp 'hosted-capability-final.json')
  $denied=$false;try{Assert-HostedCapabilityRetentionCanaries $temp $run $sha}catch{$denied=$true}
  if($denied -eq $checked){throw 'Failed/unknown final scan was bypassed or clean scan rejected'}
 }
 Write-Output 'FAILURE_EVIDENCE_CANARY_SAFE_RETENTION_PASSED;FAILED_OR_UNKNOWN_FINAL_SCAN_BLOCKED'
}finally{Remove-Item $temp -Recurse -Force}
