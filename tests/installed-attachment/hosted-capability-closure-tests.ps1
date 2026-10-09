$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-owner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force
function Extract([string]$File,[string]$Name){
 $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $File),[ref]$t,[ref]$e)
 $f=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true)
 if($e -or $f.Count -ne 1){throw "Invalid production extraction $Name"};$f[0].Extent.Text
}
. ([scriptblock]::Create((Extract 'hosted-capability-supervisor.ps1' 'Drain-HostedCapabilityFinishingHelpers')))
function Stop-HostedCapabilityProcessIdentity($ProcessId,$CreationFileTimeUtc,$WaitMilliseconds){
 $p=Get-Process -Id $ProcessId
 try{if($p.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $CreationFileTimeUtc){throw 'Fixture identity changed'};$p.Kill();$null=$p.WaitForExit(2000);@{terminated=$p.HasExited}}finally{$p.Dispose()}
}
$frequency=[Diagnostics.Stopwatch]::Frequency;$run='a'*32;$sha='b'*40
$temp=Join-Path ([IO.Path]::GetTempPath()) ('t569-closure-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
try{
 foreach($case in @(@{role='user-probe';hold=4;exit=0},@{role='root-import';hold=2;exit=0},@{role='root-remove';hold=2;exit=0},@{role='user-probe';hold=30;exit=0},@{role='root-import';hold=1;exit=7})){
  $scriptFile=Join-Path $temp 'participant.ps1';"Start-Sleep -Seconds $($case.hold);exit $($case.exit)"|Set-Content $scriptFile
  $exe=(Get-Process -Id $PID).Path;$p=Start-Process $exe -PassThru -ArgumentList @('-NoProfile','-File',$scriptFile)
  $ledger=New-HostedCapabilityLedger -Directory (Join-Path $temp ([guid]::NewGuid().ToString('N'))) -RunId $run -SourceSHA $sha -BootMarker 'fixture' -JobStartCounter ([Diagnostics.Stopwatch]::GetTimestamp()) -CounterFrequency $frequency
  try{
   $null=$p.Handle;$created=$p.StartTime.ToUniversalTime().ToFileTimeUtc();$script:failure=$false
   $script:finishingHelpers=[Collections.Generic.List[object]]::new()
   $script:finishingHelpers.Add(@{Process=$p;Identity=@{pid=$p.Id;creationFileTimeUtc=$created;role=$case.role};DeadlineCounter=[Diagnostics.Stopwatch]::GetTimestamp()+$(if($case.hold -gt 10){1L}else{10L})*$frequency})
   Drain-HostedCapabilityFinishingHelpers
   if($p.HasExited -or !$script:finishingHelpers.Count){throw 'Clean EOF equivalent dropped/terminated the retained finishing child'}
   while($script:finishingHelpers.Count){Drain-HostedCapabilityFinishingHelpers;Start-Sleep -Milliseconds 25}
   $replay=Read-HostedCapabilityLedger -Directory $ledger.Directory -RunId $run -SourceSHA $sha
   if(!$replay.valid -or ($script:failure -ne ($case.hold -gt 10 -or $case.exit -ne 0))){throw 'Finishing child actual exit/hang/nonzero proof differs'}
   Write-Output "PRODUCTION_FINISH_QUEUE_REAL_CHILD role=$($case.role) hold=$($case.hold) exit=$($case.exit) identity_stop=fixture"
  }finally{try{$left=Get-Process -Id $p.Id -ErrorAction SilentlyContinue;if($left){$left.Kill();$null=$left.WaitForExit(5000);$left.Dispose()}}catch{};$p.Dispose();Close-HostedCapabilityLedger $ledger}
 }
 # Exercise the production planned-disconnect handler with a real retained
 # command-stream service. The disconnect double closes any still-live stream.
 foreach($fn in @('Read-PromptServiceLine','Test-PromptServiceAlive','Stop-PromptService','Handle-Request')){
  . ([scriptblock]::Create((Extract 'hosted-session-owner.ps1' $fn)))
 }
 function Get-OwnerWait([int]$Milliseconds){Get-HostedCapabilityWaitBudget $script:ownerDeadline $frequency $Milliseconds}
 function Test-HostedCapabilityProcessIdentity($ProcessId,$CreationFileTimeUtc){$actual=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue;try{@{matches=[bool]($actual -and $actual.StartTime.ToUniversalTime().ToFileTimeUtc() -eq $CreationFileTimeUtc)}}finally{if($actual){$actual.Dispose()}}}
 function Test-Caller {param($ClientPID,$ClientSID,$ClientSession,$Creation,$Role)$Role -ceq 'worker'}
 function New-PrivateEnv {[Collections.Generic.Dictionary[string,string]]::new()}
 function Assert-BridgeHealth {$true}
 function Invoke-Rdpilot {param($Arguments,$Environment,$TimeoutSeconds)if($Arguments[0] -ceq 'disconnect' -and $script:promptProcess){throw 'Pinned disconnect double closed a live MCP stream'};@{ok=$true}}
 function Send-Reply {param($Value)$script:ownerReply=$Value}
 $serviceScript=Join-Path $temp 'stream-service.ps1'
 @'
while($line=[Console]::ReadLine()){$command=ConvertFrom-Json $line;if($command.op -eq 'stop'){[Console]::WriteLine('{"op":"stopped","result":true}');exit 0};[Console]::WriteLine('{"op":"status","mcpAlive":true}')}
exit 9
'@|Set-Content $serviceScript
 $RunId=$run;$sourceSHA=$sha;$SessionName='fixture';$script:ownerDeadline=[Diagnostics.Stopwatch]::GetTimestamp()+30L*$frequency
 foreach($ordinal in @(1,2)){
  $script:promptArguments=@('--expected-sid','fixture-sid')
  $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true
  foreach($arg in @('-NoProfile','-File',$serviceScript)){$psi.ArgumentList.Add($arg)}
  $service=[Diagnostics.Process]::Start($psi);$null=$service.Handle
  $script:promptProcess=$service;$script:promptIdentity=@{pid=$service.Id;creationFileTimeUtc=$service.StartTime.ToUniversalTime().ToFileTimeUtc()};$script:state='connected'
  try{
   $null=Handle-Request @{schema='ticket569-session-owner-v1';runId=$run;sourceSHA=$sha;command='disconnect'} 1 'fixture' 1 1
   if(!$script:ownerReply.ok -or !$script:ownerReply.result.promptService.stopped -or !$script:ownerReply.result.promptService.waitedHandle -or !$script:promptRecoveryAllowed -or $script:state -cne 'disconnected'){throw 'Planned owner disconnect lost its retained stream exit proof'}
   Write-Output "PRODUCTION_OWNER_DISCONNECT_STREAM_DOUBLE ordinal=$ordinal stop_before_stream_close=proved;LOGIN_ADAPTER_WINDOWS_MAIN_PATH_SEPARATE"
  }finally{try{$left=Get-Process -Id $script:promptIdentity.pid -ErrorAction SilentlyContinue;if($left){$left.Kill();$left.Dispose()}}catch{};$service.Dispose()}
 }
 $script:state='connected';$script:promptProcess=$null;$script:promptIdentity=$null;$lost=$false
 try{$null=Handle-Request @{schema='ticket569-session-owner-v1';runId=$run;sourceSHA=$sha;command='health';requirePromptService=$true} 1 'fixture' 1 1}catch{$lost=$true}
 if(!$lost -or $script:state -cne 'lost'){throw 'Unexpected MCP loss ceased to be fatal'}
 # Native call adapter executes the production refusal producer. An outer
 # protocol Win32 exception is deliberately not marked as an API refusal.
 . ([scriptblock]::Create((Extract 'hosted-user-capability.ps1' 'Invoke-HostedCredentialNativeWrite')))
 Add-Type 'using System; using System.ComponentModel; public static class Ticket569HostedCredentialV2 {public static int Error; public static bool Write(string target,string secret){if(Error!=0)throw new Win32Exception(Error);return true;}}'
 foreach($errorCode in @(50,5,0)){
  $record=@{nativeFailureFromApi=$false};[Ticket569HostedCredentialV2]::Error=$errorCode
  try{$null=Invoke-HostedCredentialNativeWrite 'synthetic-owned-target' 'synthetic-value'}catch{}
  $probe=@{nativeRefusalAcknowledged=$true;nativeFailureFromApi=$record.nativeFailureFromApi;nativeOperation=$record.nativeOperation;nativeWin32ErrorCode=$record.nativeWin32ErrorCode;profileKind='mount-point';credentialFinalCredReadError=1168;admin=$false;userInteractive=$true;windowStation='WinSta0';desktop='Default';sessionId=7;profileLoaded=$true;profileHivePresent=$true;profileSID='S-1-5-21-1';sid='S-1-5-21-1';profileLocalPath='C:\Users\fixture';userProfile='C:\Users\fixture';userProfileApi='C:\Users\fixture';profileMount=@{reparseTag='0xA0000003';attached=$true;volumeMatchesVhd=$true};cleanupErrors=@();conditions=@('probe-exception:fixture-native')}
  $limitation=Get-HostedVhdSupportedLimitation $probe @{status='feasible-observed'}
  if(($null -ne $limitation) -ne ($errorCode -eq 50)){throw 'Production native refusal was mistyped'}
  foreach($fault in @('identity','cleanup','no-positive-control','helper-error','unacknowledged-native')){
   $bad=$probe.Clone();$normal=@{status='feasible-observed'}
   switch($fault){'identity'{$bad.profileSID='S-1-5-21-2'};'cleanup'{$bad.cleanupErrors=@('failure')};'no-positive-control'{$normal.status='harness-defect'};'helper-error'{$bad.nativeFailureFromApi=$false;$bad.nativeWin32ErrorCode=50};'unacknowledged-native'{$bad.nativeRefusalAcknowledged=$false}}
   if(Get-HostedVhdSupportedLimitation $bad $normal){throw 'Unknown/helper/cleanup/identity failure became a supported limitation'}
  }
 }
 Write-Output 'PRODUCTION_NATIVE_REFUSAL_PRODUCER_ADAPTER_PASSED;ACTUAL_WINDOWS_CREDWRITE_REFUSAL_UNRUN'
 # The production recovery wrapper must select safe cleanup after an unavailable
 # sensitive context; adapters are explicit, never Windows kernel proof.
 . ([scriptblock]::Create((Extract 'hosted-capability-supervisor.ps1' 'Invoke-HostedSessionRecovery')))
 function Assert-BeforeRecoveryDeadline{}
 function Read-HostedCapabilityLedger {param($Directory,$RunId,$SourceSHA)@{valid=$true;sessionFact=$script:fact;pending=@(@{operation='fixture-pending'})}}
 function Get-CimInstance {param($ClassName,$Filter,$ErrorAction)if($ClassName -ceq 'Win32_UserProfile'){@{Loaded=$script:live;LocalPath=$script:fact.profilePath}}elseif($script:live){@{SessionId=7}}}
 function Test-Path {param($Path)$script:live}
 function Get-SupervisorProcessSID {$script:fact.sid}
 function Invoke-HostedSensitiveSessionRecovery {throw 'Selected boundary-sensitive failure'}
 function Invoke-OwnedPostSessionCleanup($Fact,$Live,$Proven){$script:cleanupCalled=$true;@{ownedCleanupAttempted=$true;sensitiveProof=$Proven}}
 function Write-HostedCapabilityFailure {param($Ledger,$Code,$Evidence)$script:recordedFailure=$Code}
 $fact=@{ledgerSequence=3;sid='S-1-5-21-1';sessionId=7;profilePath='C:\Users\t569fixture'};$script:authoritativeSessionFact=$fact;$recoveryJob=$null
 foreach($boundary in @('normal-logoff','rename','mount','vhd-login')){
  $script:live=$false;$script:cleanupCalled=$false;$script:failure=$false
  $r=Invoke-HostedSessionRecovery
  if(!$script:cleanupCalled -or $r.sensitiveContextProven -or !$script:failure -or $r.pendingMutationCount -ne 1){throw 'Recovery boundary skipped owned cleanup or fabricated same-context proof'}
  Write-Output "PRODUCTION_RECOVERY_WRAPPER_ADAPTER boundary=$boundary sensitive=unverified owned_cleanup=attempted pending=preserved;WINDOWS_KERNEL_UNRUN"
 }
}finally{Microsoft.PowerShell.Management\Remove-Item $temp -Recurse -Force}
