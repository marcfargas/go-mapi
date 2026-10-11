$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
function Extract([string]$File,[string]$Name){$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $File),[ref]$t,[ref]$e);$f=@($a.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true));if($e -or $f.Count -ne 1){throw 'Production extraction failed'};[scriptblock]::Create($f[0].Extent.Text)}
foreach($name in @('Start-RecoveryPromptService','Handle-Request','Read-PromptServiceLine','Test-PromptServiceAlive','Stop-PromptService','Get-PromptArgumentValue')){. (Extract 'hosted-session-owner.ps1' $name)}
$t=$null;$e=$null;$ownerAST=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-session-owner.ps1'),[ref]$t,[ref]$e)
$startAST=$ownerAST.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Start-PromptService'},$true)
$script:productionStartGuard=[scriptblock]::Create($startAST.Body.EndBlock.Statements[0].Extent.Text)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('t569-recovery-ui-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
$service=Join-Path $temp 'removal-stream.ps1'
@'
while($line=[Console]::ReadLine()){
 $op=(ConvertFrom-Json $line).op
 switch($op){
  'watch-removal'{[Console]::WriteLine('{"op":"watching-removal","importerLaunched":false}')}
  'status'{[Console]::WriteLine('{"op":"status","mcpAlive":true}')}
  'stop'{[Console]::WriteLine('{"op":"stopped","result":true}');exit 0}
  default{throw 'Removal-only fixture forbids importer/run/login'}
 }
}
exit 9
'@|Set-Content $service
$RunId='a'*32;$sourceSHA='b'*40;$SessionName='ticket569';$ownerDeadline=[Diagnostics.Stopwatch]::GetTimestamp()+60L*[Diagnostics.Stopwatch]::Frequency;$CounterFrequency=[Diagnostics.Stopwatch]::Frequency
$target='S-1-5-21-1';$profilePath='C:\Users\t569aaaaaaaaaa';$volume='owned-volume'
function Get-OwnerWait([int]$Milliseconds){Get-HostedCapabilityWaitBudget $ownerDeadline $CounterFrequency $Milliseconds}
function Test-Caller {param($ClientPID,$ClientSID,$ClientSession,$Creation,$Role)$Role -ceq 'supervisor'}
function New-PrivateEnv {[Collections.Generic.Dictionary[string,string]]::new()}
function Assert-BridgeHealth {$script:operations.Add('existing-bridge-health');if($script:bridgeFault){throw 'Fixture unexpected bridge loss'};@{ok=$true}}
function Invoke-Rdpilot {throw 'Recovery fixture forbids reconnect/new login/import'}
function Send-Reply {param($Value)$script:reply=$Value}
function Get-LocalUser {param($Name,$ErrorAction)@{SID=@{Value=$target}}}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction)if($ClassName -ceq 'Win32_UserProfile'){@{Loaded=$true;LocalPath=$profilePath}}elseif($Filter -ceq 'SessionId=7'){@{SessionId=7}}}
function Invoke-CimMethod {param($InputObject,$MethodName,$ErrorAction)@{Sid=$target}}
function Test-Path {param($Path)$Path -ceq "Registry::HKEY_USERS\$target"}
function Get-Volume {param($FilePath,$ErrorAction)@{UniqueId=$volume}}
function Get-Item {param($LiteralPath,$ErrorAction)@{Attributes=[IO.FileAttributes]::ReparsePoint}}
function Join-Path {param($Path,$ChildPath)if($Path -like 'C:*'){$Path+'\'+$ChildPath}else{Microsoft.PowerShell.Management\Join-Path $Path $ChildPath}}
function Test-HostedCapabilityProcessIdentity {param($ProcessId,$CreationFileTimeUtc)$p=Get-Process -Id $ProcessId;try{@{matches=($p.StartTime.ToUniversalTime().ToFileTimeUtc() -eq $CreationFileTimeUtc)}}finally{$p.Dispose()}}
function Start-PromptService {
 param($Request)
 . $script:productionStartGuard
 $script:operations.Add('attach-removal-service-adapter');$script:startedArguments=@($Request.promptArguments)
 $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true
 foreach($arg in @('-NoProfile','-File',$service)){$psi.ArgumentList.Add($arg)}
 $script:promptProcess=[Diagnostics.Process]::Start($psi);$null=$script:promptProcess.Handle
 $script:promptIdentity=@{pid=$script:promptProcess.Id;creationFileTimeUtc=$script:promptProcess.StartTime.ToUniversalTime().ToFileTimeUtc()}
 @{retained=$true;adapter='process-start-only-no-Windows-job-CUA'}
}
try{
 foreach($case in @('retained-vhd','wrong-sid','wrong-session','wrong-volume','wrong-kind','no-planned-stop','unexpected-drop')){
  $script:operations=[Collections.Generic.List[string]]::new();$script:bridgeFault=$case -eq 'unexpected-drop';$script:state='connected';$script:loginCount=2;$script:promptProcess=$null;$script:promptIdentity=$null;$script:promptCompleted=$true
  $script:promptRecoveryAllowed=$case -ne 'no-planned-stop';$script:promptArguments=@('--expected-sid',$target,'--expected-session-id','3','--thumbprint',('0'*40),'--run-id',$RunId)
  $r=@{schema='ticket569-session-owner-v1';runId=$RunId;sourceSHA=$sourceSHA;command='health';requirePromptService=$true;allowRecoveryWatcher=$true;expectedSID=$target;expectedSessionId=7;expectedProfilePath=$profilePath;expectedVolumeId=$volume;expectedProfileKind='mount-point'}
  switch($case){'wrong-sid'{$r.expectedSID='S-1-5-21-2'};'wrong-session'{$r.expectedSessionId=8};'wrong-volume'{$r.expectedVolumeId='different'};'wrong-kind'{$r.expectedProfileKind='normal'}}
  $failed=$false
  try{$null=Handle-Request $r 1 'fixture' 1 1}catch{$failed=$true}
  if($case -eq 'retained-vhd'){
   if($failed -or !$script:reply.ok -or !$script:reply.result.promptServiceAlive -or $script:loginCount -ne 2 -or !$script:promptCompleted -or (Get-PromptArgumentValue $script:startedArguments '--expected-session-id') -cne '7' -or $script:operations.IndexOf('existing-bridge-health') -ge $script:operations.IndexOf('attach-removal-service-adapter')){throw 'Production recovery owner failed retained-context removal-only attachment'}
   $null=Stop-PromptService
   # The consumed planned-stop authorization cannot repair an unexpected drop.
   $denied=$false;try{$null=Handle-Request $r 1 'fixture' 1 1}catch{$denied=$true}
   if(!$denied -or $script:state -cne 'lost'){throw 'Recovery UI absence triggered a repeated automatic attachment'}
  }elseif(!$failed -or $script:operations.Contains('attach-removal-service-adapter')){throw "Production recovery context $case permitted an attachment"}
  Write-Output "PRODUCTION_RECOVERY_OWNER_UI case=$case connectedLoginCount=$($script:loginCount) noReconnectOrImport=True;WINDOWS_IDENTITY_JOB_CUA_ADAPTERS"
 }
 # Execute the supervisor's production health branch and result wrapper too;
 # its ledger sink and OS profile API are explicit adapters here.
 foreach($fn in @('New-SessionOwnerRequest','Invoke-SupervisorRecoveryMutation')){. (Extract 'hosted-capability-supervisor.ps1' $fn)}
 $t=$null;$e=$null;$supervisorAST=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-capability-supervisor.ps1'),[ref]$t,[ref]$e)
 $healthTry=@($supervisorAST.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains("'ensure-exact-session-removal-only-cua'")},$true)|Sort-Object {$_.Extent.Text.Length})[0]
 $healthBody=[scriptblock]::Create($healthTry.Body.Extent.Text.TrimStart('{').TrimEnd('}'))
 function Get-HostedObservedProfileContext {param($ProfilePath,$StepName)@{kind='mount-point';volumeId=$volume}}
 function Write-HostedCapabilityLedgerEvent {param($Ledger,$Event)$script:operations.Add('ledger-'+$Event.phase);@{sequence=++$script:sequence}}
 function Invoke-SessionOwnerControl {param($Request,$TimeoutMilliseconds)$null=Handle-Request $Request 1 'fixture' 1 1;$script:reply}
 $expectedSha=$sourceSHA;$identity=@{sid=$target;sessionId=7};$ownerIdentity=@{fixture='retained'};$selfIdentity=@{};$ledger=@{};$script:sequence=0
 $script:state='connected';$script:bridgeFault=$false;$script:promptProcess=$null;$script:loginCount=2;$script:promptRecoveryAllowed=$true;$script:promptCompleted=$true;$script:operations=[Collections.Generic.List[string]]::new()
 $script:authoritativeSessionFact=@{sid=$target;sessionId=7;profilePath=$profilePath;stepName='vhd-active-user-wts-session';profileContext=@{kind='mount-point';volumeId=$volume}}
 . $healthBody
 if(!$healthReceipt.ok -or !$healthReceipt.result.promptServiceAlive -or $script:operations.IndexOf('ledger-intent') -ge $script:operations.IndexOf('attach-removal-service-adapter') -or !$script:operations.Contains('ledger-observation')){throw 'Supervisor health wrapper failed acknowledged no-reconnect attachment or result readback'}
 $null=Stop-PromptService
 Write-Output 'PRODUCTION_SUPERVISOR_RECOVERY_HEALTH_ACTION_RESULT_AND_INTENT_ORDER_PASSED;LEDGER_AND_OS_ADAPTERS_NO_WINDOWS_PROOF'
}finally{if($script:promptProcess){try{$script:promptProcess.Kill();$null=$script:promptProcess.WaitForExit(5000)}catch{};$script:promptProcess.Dispose()};Microsoft.PowerShell.Management\Remove-Item $temp -Recurse -Force}
