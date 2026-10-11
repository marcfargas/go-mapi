[CmdletBinding()]
param([string]$WorkerSourcePath)
$ErrorActionPreference='Stop'
function Parse-Production([string]$Name){
 $tokens=$null;$errors=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name),[ref]$tokens,[ref]$errors)
 if($errors){throw "Production parse failed: $Name"};$a
}
function Production-Function($AST,[string]$Name){
 $f=@($AST.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
 if($f.Count -ne 1){throw "Production function not unique: $Name"};[scriptblock]::Create($f[0].Extent.Text)
}
$supervisor=Parse-Production 'hosted-capability-supervisor.ps1'
$native=Parse-Production 'hosted-capability-native.psm1'
$worker=if($WorkerSourcePath){$t=$null;$e=$null;[Management.Automation.Language.Parser]::ParseFile($WorkerSourcePath,[ref]$t,[ref]$e)}else{Parse-Production 'hosted-capability.ps1'}
$windowsRuntime=([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$RunId='a'*32;$sid='S-1-5-21-1';$expectedSID='S-1-5-21-2'
if($windowsRuntime){Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force;$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$expectedSID=$sid}
else{
 # Preserve the actual advanced-function declaration and invocation. Only the
 # static Windows CreateEvent implementation is an explicit portable adapter.
 Add-Type @'
public sealed class Ticket569MainpathGate {public string Name,Sddl;public bool Released;public void Release(){Released=true;}public bool Wait(int ms){return Released;}public void Dispose(){}}
public static class Ticket569CapabilityNative {public static Ticket569MainpathGate CreateGate(string name,string sddl){return new Ticket569MainpathGate{Name=name,Sddl=sddl};}}
'@
 . (Production-Function $native 'New-HostedCapabilityGate')
}
$gateIf=@($supervisor.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq "`$request.operation -ceq 'register-exact-run-scoped-interactive-user-task'"},$true))
if($gateIf.Count -ne 1){throw 'Production user gate intent branch not unique'}
$script:userProbeGates=@{};$request=@{operation='register-exact-run-scoped-interactive-user-task';precondition=@{profileKind='normal'};resourceIdentity=@{sid=$expectedSID}}
. ([scriptblock]::Create($gateIf[0].Extent.Text))
$gate=$script:userProbeGates.normal
try{
 if(!$gate -or $gate.Wait(0)){throw 'Production user gate did not start unsignaled'}
 # Release the exact production release statements after OS identity adoption.
 $releaseIf=@($supervisor.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and @($n.Clauses|Where-Object {$_.Item1.Extent.Text -match "request.event -eq 'user-probe-child-identity-observed'"}).Count},$true))[0]
 $clause=@($releaseIf.Clauses|Where-Object {$_.Item1.Extent.Text -match "request.event -eq 'user-probe-child-identity-observed'"})[0].Item2
 $child=@{taskName="Ticket569-$RunId-normal"}
 $statements=@($clause.Statements|Where-Object {$_.Extent.Text -like '$kind=if*' -or $_.Extent.Text -like 'if(!$script:userProbeGates*' -or $_.Extent.Text -ceq '$script:userProbeGates[$kind].Release()'})
 if($statements.Count -ne 3){throw 'Production identity gate release sequence differs'}
 . ([scriptblock]::Create(($statements.Extent.Text -join "`n")))
 if(!$gate.Wait(0)){throw 'Production adopted-identity release did not signal the actual created gate'}
 $denied=$false;try{. ([scriptblock]::Create($gateIf[0].Extent.Text))}catch{$denied=$true}
 if(!$denied){throw 'Duplicate production gate registration was accepted'}
 Write-Output "PRODUCTION_USER_GATE_INTENT_BINDING_RELEASE_PASSED windowsKernel=$windowsRuntime;OS_IDENTITY_ADOPTION_TESTED_SEPARATELY"
}finally{$gate.Dispose()}

Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force
. (Production-Function $worker 'Latch-Failure')
function Set-HostedCapabilityFailureEvent {param($Name)}
function Get-HostedCounter {[Diagnostics.Stopwatch]::GetTimestamp()}
function Send-RunLifecycle {param($Event,$Observed)if($script:cleanupFault -and $Event -eq 'session-owner-shutdown-before-outer-cleanup'){throw 'Fixture owner termination unproved'}}
function Disconnect-OwnedRdp {$script:cleanupCalls.Add('disconnect')}
function Invoke-RunMutation {
 param($Operation,$ResourceIdentity,$Precondition,$Action)
 $script:cleanupCalls.Add($Operation)
 if($Operation -eq 'remove-exact-unloaded-user-profile' -and $Precondition.profileState -cne 'normal'){throw 'Fixture supervisor refuses mounted-profile removal'}
 if($Operation -eq 'remove-owned-user-and-group-membership' -and !$script:profileRemoved){throw 'Fixture supervisor refuses removal before exact profile absence'}
 @{result=(& $Action)}
}
function Wait-ProfileUnloaded {param($SID,$SessionId,$TimeoutSeconds)$script:cleanupCalls.Add('unload')}
function Invoke-HostedProfileRestoreIfRequired {param($ProfileState,$Restore)$script:cleanupCalls.Add('restore');if($script:restoreFault){throw 'Fixture restore failed'};$true}
function Record-Step {param($Name,$Status,$Evidence)}
function Get-ProfileRecord {param($SID)if(!$script:profileRemoved){@{Loaded=$false;LocalPath=$profilePath}}}
function Test-Path {param($LiteralPath,$Path)if($LiteralPath -ceq $profilePath){!$script:profileRemoved}else{$false}}
function Remove-CimInstance {param($InputObject,$ErrorAction)$script:profileRemoved=$true}
function Get-LocalGroup {param($SID)@{SID=$SID}}
function Remove-LocalGroupMember {param($Group,$Member,$ErrorAction)}
function Remove-LocalUser {param($Name,$ErrorAction)$script:userRemoved=$true}
function Get-LocalUser {param($Name,$ErrorAction)if(!$script:userRemoved){@{Name=$Name}}}
$outer=@($worker.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text.Contains("Send-RunLifecycle -Event 'cleanup-started'")},$true))
if($outer.Count -ne 1){throw 'Production outer cleanup not unique'}
$cleanup=@($outer[0].Finally.Statements)
$stop=@($cleanup|Where-Object {$_.Extent.Text -like '$secretCanaryCheckFailed*'})[0]
$runCleanup=[scriptblock]::Create(($cleanup|Where-Object {$_.Extent.StartOffset -lt $stop.Extent.StartOffset}).Extent.Text -join "`n")
$limitation=@{route='vhd';documentedSupportedLimitation=$true;actualError='CredWriteW:50';positiveControlObserved=$true}
foreach($case in @('supported','ordinary-failure','unknown','identity','cleanup','restore')){
 $script:conditions=[Collections.Generic.List[object]]::new();$script:cleanupErrors=[Collections.Generic.List[string]]::new();$script:cleanupCalls=[Collections.Generic.List[string]]::new()
 $script:failureLatched=$false;$script:writeFailed=$false;$script:supervisorConnection=$null;$script:profileRemoved=$false;$script:userRemoved=$false;$script:userCreated=$true
 $script:cleanupFault=$case -eq 'cleanup';$script:restoreFault=$case -eq 'restore'
 $conditions.Add([pscustomobject]@{name='current-user-root-prompt-route';class='observed';evidence=@{status='observed-and-answered'}})
 Latch-Failure 'vhd-supported-native-api-refusal' 'unavailable-supported-capability' $limitation
 if($case -in @('ordinary-failure','identity')){Latch-Failure 'other' 'harness-defect' @{identityUnproved=$true}}
 if($case -eq 'unknown'){Latch-Failure 'other' 'unknown' @{}}
 $profileState='mounted';$activeSessionId=7;$user=@{SID=@{Value=$expectedSID}};$profilePath='C:\Users\t569aaaaaaaaaa';$testUserName='t569aaaaaaaaaa';$rdpGroupAdded=$true;$promptCertificate=$null
 $promptCertificatePath=$null;$promptImportResultPath=$null;$rootObserverAttachedPath=$null;$rootObserverExitPath=$null;$rootObserverFailurePath=$null
 $password=[Security.SecureString]::new();$password.AppendChar('x');$password.MakeReadOnly()
 . $runCleanup
 $v=Resolve-HostedCapabilityVerdict -Conditions @($conditions) -Normal @{status='feasible-observed'} -Vhd @{status='unavailable-supported-capability'} -RootPrompt @{status='observed-and-answered'} -PositiveRoute $true -CleanupErrors @($cleanupErrors) -ProfileState $profileState -UserCreated $userCreated
 if(!$failureLatched){throw 'Production cleanup cleared the irreversible primary failure'}
 Write-Output (ConvertTo-Json -Compress @{case=$case;verdict=$v;profileState=$profileState;userCreated=$userCreated;cleanupErrors=@($cleanupErrors);calls=@($script:cleanupCalls)})
 if($case -eq 'supported'){
  if($v -cne 'unavailable-supported-capability' -or $profileState -cne 'normal' -or $userCreated -or !$script:profileRemoved -or !$script:userRemoved -or !$script:cleanupCalls.Contains('restore')){throw 'Successful Root observation prevented production supported-limitation owned cleanup/classification'}
 }elseif($v -ceq 'unavailable-supported-capability'){throw "Production $case failure became supported incapability"}
 Write-Output "PRODUCTION_WORKER_OUTER_CLEANUP_CLASSIFICATION case=$case verdict=$v failureLatched=$failureLatched;WINDOWS_MUTATORS_ADAPTED"
}
