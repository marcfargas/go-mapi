$ErrorActionPreference='Stop'
function Read-OwnerAssignmentSource([string]$Name){
 $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name),[ref]$t,[ref]$e)
 if($e.Count){throw "Owner assignment source parse failed: $Name"};$a
}
$supervisor=Read-OwnerAssignmentSource 'hosted-capability-supervisor.ps1'
$fixture=Read-OwnerAssignmentSource 'hosted-capability-framework-tests.ps1'
$launcherAst=Read-OwnerAssignmentSource 'hosted-capability-recovery.ps1'
$worker=Read-OwnerAssignmentSource 'hosted-capability-recovery-worker.ps1'
$native=Read-OwnerAssignmentSource 'hosted-capability-native.psm1'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force -ErrorAction Stop
$blocks=@($supervisor.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains("'assign-exact-recovery-launcher-job'") -and $n.Body.Extent.Text.Contains("'release-exact-recovery-launch-gate'")},$true)|Where-Object {$_.Body.Extent.Text.Length -lt 4000})
if($blocks.Count -ne 1){throw 'Actual owner assignment/release boundary is not unique'}
$ownerBlock=[scriptblock]::Create($blocks[0].Extent.Text)
$fixtureBlocks=@($fixture.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains('Add-HostedCapabilityRetainedProcessToJob') -and $n.Body.Extent.Text.Contains('$gate.Release()')},$true)|Where-Object {$_.Body.Extent.Text.Length -lt 1000})
if($fixtureBlocks.Count -ne 1){throw 'Actual fixture owner assignment/release boundary is not unique'}
$fixtureBlock=[scriptblock]::Create($fixtureBlocks[0].Extent.Text)
$runId='a'*32;$expectedSha='b'*40;$recoveryJobName="Global\Ticket569-$runId-recovery";$recoveryGateName=$recoveryJobName+'-gate';$taskName='fixture-task';$targetSID='S-1-5-21-1';$targetSession=2;$recoveryScriptHash='c'*64;$recoveryWorkerScriptHash='d'*64
$taskProcess=[pscustomobject]@{Handle=[IntPtr]123};$taskProcessIdentity=@{pid=42;creationFileTimeUtc=456;sid=$targetSID;sessionId=$targetSession;sourceSHA=$expectedSha}
$ledger=@{};$frequency=1000L;$deadlines=@{cleanup=100000L}
function Get-HostedCapabilityWaitBudget {param($DeadlineCounter,$CounterFrequency,$MaximumMilliseconds)if($MaximumMilliseconds -ne 5000){throw 'Failure cleanup lost its wait bound'};5000}
function Write-HostedCapabilityFailure {param($Ledger,$Code,$Evidence)$script:events.Add('cleanup-exit-unproven')}
function Add-HostedCapabilityRetainedProcessToJob {param($Job,[IntPtr]$ProcessHandle,[long]$CreationFileTimeUtc)
 if($ProcessHandle -ne [IntPtr]123 -or $CreationFileTimeUtc -ne 456){throw 'Owner assignment did not use the exact retained handle/creation'}
 $script:events.Add('assign-retained')
 if($script:case -ceq 'assign-failed'){throw 'Injected assign failure'}
 $Job.ActiveProcesses=1
 if($script:case -in @('membership-failed','count-failed','killclose-failed','creation-failed')){throw 'Injected post-assignment validation failure'}
}
function Stop-HostedCapabilityRetainedProcess {param([IntPtr]$ProcessHandle,[long]$CreationFileTimeUtc,[int]$WaitMilliseconds)
 if($ProcessHandle -ne [IntPtr]123 -or $CreationFileTimeUtc -ne 456 -or $WaitMilliseconds -ne 5000){throw 'Failure cleanup did not use the same retained handle/creation and bounded wait'}
 $script:events.Add('terminate-wait-retained');$script:case -cne 'stop-unproven'
}
function Invoke-SupervisorRecoveryMutation {param($Operation,$ResourceIdentity,$Precondition,[scriptblock]$Action)
 $script:events.Add('intent-'+$Operation)
 if($script:case -ceq 'intent-failed'){throw 'Injected durable-intent failure'}
 if($Operation -ceq 'assign-exact-recovery-launcher-job' -and ($ResourceIdentity.jobName -cne $recoveryJobName -or $ResourceIdentity.sourceSHA -cne $expectedSha -or $ResourceIdentity.launcher.creationFileTimeUtc -ne 456 -or !$Precondition.launcherIdentityDurablyRecorded -or !$Precondition.gateUnsignaled)){throw 'Owner intent omitted exact authority bindings'}
 & $Action|Out-Null
 $script:events.Add('observation-'+$Operation)
}
foreach($boundary in @('owner','fixture')){
 foreach($script:case in @('success','assign-failed','membership-failed','count-failed','killclose-failed','creation-failed','intent-failed','stop-unproven')){
  if($boundary -ceq 'fixture' -and $script:case -ceq 'intent-failed'){continue}
  $script:events=[Collections.Generic.List[string]]::new();$script:failure=$false
  $script:recoveryGate=[pscustomobject]@{Released=$false};$script:recoveryGate|Add-Member ScriptMethod Release {$this.Released=$true;$script:events.Add('release-gate')}
  $script:failureEvent=[pscustomobject]@{Released=$false};$script:failureEvent|Add-Member ScriptMethod Release {$this.Released=$true;$script:events.Add('set-failure')}
  $recoveryJob=[pscustomobject]@{ActiveProcesses=0;LimitFlags=0x2000}
  $gate=$script:recoveryGate;$event=$script:failureEvent;if($boundary -ceq 'fixture'){$failure=$event};$job=$recoveryJob;$launcher=$taskProcess;$launcherCreation=456
  # The stop-unproven case starts with an actual assignment failure.
  if($script:case -ceq 'stop-unproven'){
   $original=(Get-Item Function:\Add-HostedCapabilityRetainedProcessToJob).ScriptBlock
   function Add-HostedCapabilityRetainedProcessToJob {param($Job,$ProcessHandle,$CreationFileTimeUtc)$script:events.Add('assign-retained');throw 'Injected assign failure'}
  }
  $caught=$null
  try{if($boundary -ceq 'owner'){. $ownerBlock}else{. $fixtureBlock}}catch{$caught=$_}
  if($script:case -ceq 'stop-unproven'){Set-Item Function:\Add-HostedCapabilityRetainedProcessToJob $original}
  if($script:case -ceq 'success'){
   if($caught -or !$gate.Released -or $event.Released -or $script:events.IndexOf('assign-retained') -ge $script:events.IndexOf('release-gate') -or $job.ActiveProcesses -ne 1){throw 'Successful owner boundary did not assign/verify before release'}
   if($boundary -ceq 'owner' -and $script:events[0] -cne 'intent-assign-exact-recovery-launcher-job'){throw 'Assignment preceded durable owner intent'}
  }else{
   if(!$caught -or $gate.Released -or !$event.Released -or !$script:events.Contains('terminate-wait-retained')){throw "Failed owner boundary released or failed to stop exact launcher: $boundary/$script:case"}
   if($boundary -ceq 'owner' -and !$script:failure){throw 'Owner assignment failure was not irreversibly latched'}
  }
  Write-Output "RECOVERY_OWNER_ASSIGNMENT_BOUNDARY boundary=$boundary case=$script:case gateReleased=$($gate.Released);KERNEL_API_ADAPTER_WINDOWS_UNRUN"
 }
}
function Test-CurrentProcessInHostedCapabilityJob {param($Job)$script:member}
function Open-HostedCapabilityJob {param($Name,$Access)if($Access -ne 4){throw 'Recovery participant requested assignment rights'};$script:participantJob}
foreach($a in @($launcherAst,$worker)){
 $opens=@($a.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$job' -and $n.Right.Extent.Text.Contains('Open-HostedCapabilityJob')},$true))
 if($opens.Count -ne 1){throw 'Recovery Job open is missing/ambiguous'}
 $script:participantJob=@{ActiveProcesses=1;LimitFlags=0x2000};. ([scriptblock]::Create($opens[0].Extent.Text))
}
$guards=@($launcherAst.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains('sole contained process in the supervisor kill-on-close')},$true))
if($guards.Count -ne 1){throw 'Actual launcher membership/count guard is missing'}
$guard=[scriptblock]::Create($guards[0].Extent.Text)
foreach($case in @('valid','not-member','count-zero','count-two','no-killclose','breakaway')){
 $job=@{ActiveProcesses=1;LimitFlags=0x2000};$script:member=$true
 switch($case){not-member {$script:member=$false};count-zero {$job.ActiveProcesses=0};count-two {$job.ActiveProcesses=2};no-killclose {$job.LimitFlags=0};breakaway {$job.LimitFlags=0x2800}}
 $caught=$false;try{. $guard}catch{$caught=$true}
 if($caught -ne ($case -cne 'valid')){throw "Actual launcher containment guard returned wrong outcome: $case"}
 Write-Output "RECOVERY_LAUNCHER_CONTAINMENT_GUARD case=$case rejected=$caught;JOB_ADAPTER"
}
# Check the actual native authority split, not a separately implemented model.
$csharp=@($native.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.StartsWith('using System;')},$true))[0].Value
$assign=$csharp.Substring($csharp.IndexOf('public static void AssignRetainedProcess('));$assign=$assign.Substring(0,$assign.IndexOf('public static bool StopRetainedProcess('))
if($assign.Contains('OpenProcess(') -or $assign.Contains('GetCurrentProcess(') -or $assign -notmatch 'ValidateRetainedProcessCreation\(process,expectedCreation\);[\s\S]*AssignProcessToJobObject\(job.Handle,process\)[\s\S]*ValidateRetainedProcessCreation\(process,expectedCreation\);[\s\S]*IsProcessInJob\(process,job.Handle' -or !$assign.Contains('job.ActiveProcesses!=1')){throw 'Native owner assignment lost same-handle creation/membership/count authority checks'}
$start=$csharp.Substring($csharp.IndexOf('public static Ticket569CapabilityProcess StartSuspendedInJob(', $csharp.IndexOf('public static Ticket569CapabilityProcess StartSuspendedInJob(')+1));$start=$start.Substring(0,$start.IndexOf('public static void AssignCurrentProcess('))
if(!$start.Contains('if(!inheritExistingJob && !AssignProcessToJobObject(job.Handle,pi.hProcess))') -or !$start.Contains('IsCurrentProcessInJob(job)') -or !$start.Contains('(flags&0x1800)!=0') -or !$start.Contains('CREATE_SUSPENDED|CREATE_NO_WINDOW|CREATE_UNICODE_ENVIRONMENT') -or !$start.Contains('!inJob||(inheritExistingJob && job.ActiveProcesses!=2)') -or $start.IndexOf('!inJob') -ge $start.IndexOf('if(!leaveSuspended)child.Resume()')){throw 'Inherited query-only child path lost atomic inheritance, no-assign or pre-resume verification'}
$launcherText=$launcherAst.Extent.Text
if(!$launcherText.Contains('-LeaveSuspended -InheritExistingJob') -or $launcherText.IndexOf('recordedBeforeResumeQpc') -ge $launcherText.IndexOf('$child.Resume()') -or !$launcherText.Contains('if($job.ActiveProcesses -ne 1)')){throw 'Launcher lost inherited suspended child/record-before-resume or final count1'}
if($supervisor.Extent.Text.Contains('did not self-assign') -or !$supervisor.Extent.Text.Contains('(A;;0x4;;;$targetSID)') -or !$fixture.Extent.Text.Contains('(A;;0x4;;;$target)')){throw 'Owner/query-only DACL contract remains stale'}
# Exercise the actual suspended-child guard with no module-derived Process.Path.
# The retained-handle image must be enough for image proof; every other guard stays required.
$imageGuards=@($launcherAst.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains('Recovery worker failed exact PID/creation/SID/session/image/script/hash/run/Job Object verification while suspended')},$true))
if($imageGuards.Count -ne 1){throw 'Actual suspended child identity guard is missing/ambiguous'}
$imageGuard=[scriptblock]::Create($imageGuards[0].Extent.Text)
$oldImageGuard=[scriptblock]::Create($imageGuards[0].Extent.Text.Replace('$child.ImagePath','$childProcess.Path'))
function Test-HostedCapabilityProcessIdentity {param($ProcessId,$CreationFileTimeUtc)@{matches=$script:creationMatches}}
$ExpectedSID='S-1-5-21-1';$ExpectedSessionId=2;$powershell=Join-Path ([IO.Path]::GetTempPath()) 'retained-exact-powershell.exe'
foreach($case in @('valid','empty-image','wrong-image','wrong-sid','wrong-session','wrong-count','wrong-creation','wrong-argv')){
 $child=[pscustomobject]@{ProcessId=42;CreationFileTimeUtc=456;ImagePath=$powershell}
 $childProcess=[pscustomobject]@{Path='';SessionId=2};$childSID=$ExpectedSID;$job=@{ActiveProcesses=2};$script:creationMatches=$true;$childArgumentsProven=$true
 switch($case){empty-image {$child.ImagePath=''};wrong-image {$child.ImagePath=$powershell+'.wrong'};wrong-sid {$childSID='S-1-5-21-2'};wrong-session {$childProcess.SessionId=3};wrong-count {$job.ActiveProcesses=1};wrong-creation {$script:creationMatches=$false};wrong-argv {$childArgumentsProven=$false}}
 if($case -ceq 'valid'){
  $oldFailure=$null;try{. $oldImageGuard}catch{$oldFailure=$_}
  if(!$oldFailure -or $oldFailure.Exception -isnot [Management.Automation.MethodInvocationException] -or $oldFailure.Exception.InnerException -isnot [ArgumentException]){throw 'Empty module-derived Path did not reproduce the original composite-guard exception pair'}
 }
 $caught=$null;$afterGuard=$false;try{. $imageGuard;$afterGuard=$true}catch{$caught=$_}
 if(($case -ceq 'valid' -and ($caught -or !$afterGuard)) -or ($case -cne 'valid' -and (!$caught -or $afterGuard))){throw "Suspended exact identity guard accepted/rejected incorrectly: $case"}
 Write-Output "RECOVERY_SUSPENDED_IMAGE_GUARD case=$case proceeded=$afterGuard;PROCESS_IDENTITY_ADAPTER_WINDOWS_UNRUN"
}
# Execute the actual retained-image reader and creation checks against bounded kernel seams.
$creationMethod=$csharp.Substring($csharp.IndexOf('static void ValidateRetainedProcessCreation('));$creationMethod=$creationMethod.Substring(0,$creationMethod.IndexOf('public static string ReadRetainedProcessImage('))
$imageMethod=$csharp.Substring($csharp.IndexOf('public static string ReadRetainedProcessImage('));$imageMethod=$imageMethod.Substring(0,$imageMethod.IndexOf('public static void AssignRetainedProcess('))
if($imageMethod.Contains('OpenProcess(') -or !$csharp.Contains('CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)] static extern bool QueryFullProcessImageNameW') -or !$csharp.Contains('ReadRetainedProcessImage(Handle,CreationFileTimeUtc)')){throw 'Retained image source lost same-handle authority or Unicode marshaling'}
$kernelAdapter=@'
using System;
using System.Text;
using System.ComponentModel;
public static class Ticket569RetainedImageTest {
 public static string Mode; public static int TimesCalls,WaitCalls,QueryCalls;
 struct FILETIME {public long Value;public long ToLong(){return Value;}}
 static class Marshal {public static int GetLastWin32Error(){return 5;}}
 static void ExactHandle(IntPtr process){if(process!=new IntPtr(123))throw new Exception("Image proof did not use retained handle");}
 static bool GetProcessTimes(IntPtr process,out FILETIME created,out FILETIME exited,out FILETIME kernel,out FILETIME user){
  ExactHandle(process);TimesCalls++;created=new FILETIME{Value=456};exited=kernel=user=new FILETIME();
  if((Mode=="created-before"&&TimesCalls==1)||(Mode=="created-after"&&TimesCalls==2))created.Value=457;
  return Mode!="times-failed";
 }
 static uint WaitForSingleObject(IntPtr process,uint milliseconds){
  ExactHandle(process);if(milliseconds!=0)throw new Exception("Image query blocked");WaitCalls++;
  return (Mode=="exited-before"&&WaitCalls==1)||(Mode=="exited-after"&&WaitCalls==2)?0u:0x102u;
 }
 static bool QueryFullProcessImageNameW(IntPtr process,uint flags,StringBuilder image,ref uint size){
  ExactHandle(process);QueryCalls++;if(flags!=0||size!=32768||image.Capacity!=32768)throw new Exception("Image query lost Win32 format/bounded Unicode buffer");
  image.Append("C:\\\u5de5\u5177\\powershell.exe");size=(uint)image.Length;
  if(Mode=="empty"){image.Clear();size=0;}
  if(Mode=="truncated")size=32768;
  if(Mode=="length-mismatch")size++;
  return Mode!="query-failed";
 }
 ACTUAL_METHODS
}
'@
Add-Type -TypeDefinition $kernelAdapter.Replace('ACTUAL_METHODS',$creationMethod+$imageMethod)
$expectedImage='C:\'+[char]0x5de5+[char]0x5177+'\powershell.exe'
foreach($case in @('valid','created-before','created-after','times-failed','exited-before','exited-after','query-failed','empty','truncated','length-mismatch')){
 [Ticket569RetainedImageTest]::Mode=$case;[Ticket569RetainedImageTest]::TimesCalls=0;[Ticket569RetainedImageTest]::WaitCalls=0;[Ticket569RetainedImageTest]::QueryCalls=0
 $caught=$null;$image=$null;try{$image=[Ticket569RetainedImageTest]::ReadRetainedProcessImage([IntPtr]123,456)}catch{$caught=$_}
 if($case -ceq 'valid'){
  if($caught -or $image -cne $expectedImage -or [Ticket569RetainedImageTest]::TimesCalls -ne 2 -or [Ticket569RetainedImageTest]::WaitCalls -ne 2 -or [Ticket569RetainedImageTest]::QueryCalls -ne 1){throw 'Actual retained image reader did not verify creation/liveness around exact Unicode query'}
 }elseif(!$caught -or $image){throw "Actual retained image reader accepted failed/incomplete proof: $case"}
 if($case -in @('times-failed','query-failed') -and ($caught.Exception.InnerException -isnot [ComponentModel.Win32Exception] -or $caught.Exception.InnerException.NativeErrorCode -ne 5)){throw 'Retained image query lost native exception/code'}
 Write-Output "RECOVERY_RETAINED_IMAGE_READER case=$case rejected=$([bool]$caught);KERNEL_API_ADAPTER_WINDOWS_UNRUN"
}
Write-Output 'RECOVERY_RETAINED_OWNER_ASSIGNMENT_AND_INHERITED_CHILD_GUARDS_PASSED;WINDOWS_ASSIGNMENT_INHERITANCE_RUNTIME_UNRUN'
