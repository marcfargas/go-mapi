$ErrorActionPreference='Stop'
$sourceRoot=$PSScriptRoot;$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $sourceRoot 'hosted-capability-supervisor.ps1'),[ref]$t,[ref]$e)
$f=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-OwnedPostSessionCleanup'},$true)
if($f.Count -ne 1 -or $e){throw 'Production safe cleanup extraction failed'}
. ([scriptblock]::Create($f[0].Extent.Text))
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('t569-owned-cleanup-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $fixtureRoot|Out-Null
@'
param($Action,$SID,$ProfilePath,$VhdPath,$BackupPath,$EvidenceDirectory,$MutationMode,$DeadlineCounter,$CounterFrequency,$MutationHook)
if($Action -cne 'restore-normal' -or $MutationMode -cne 'Hosted' -or !$MutationHook){throw 'Unexpected production restore interface'}
$global:t569CleanupOperations.Add('profile-restore-adapter')
'@|Set-Content (Join-Path $fixtureRoot 'profile.ps1')
$PSScriptRoot=$fixtureRoot
$RunId='a'*32;$expectedSha='b'*40;$frequency=[Diagnostics.Stopwatch]::Frequency;$deadlines=@{cleanup=[Diagnostics.Stopwatch]::GetTimestamp()+20L*$frequency};$EvidenceDirectory=$fixtureRoot
$ownerProcess=@{fixture='retained-owner'};$recoveryJob=@{ActiveProcesses=0};$ledger=@{};$selfIdentity=@{}
$fact=@{sid='S-1-5-21-1';sessionId=7;profilePath='C:\Users\t569aaaaaaaaaa'}
function Join-Path {param($Path,$ChildPath)if(!$Path){Microsoft.PowerShell.Management\Join-Path $fixtureRoot $ChildPath}elseif($Path -like 'C:*'){$Path+'\'+$ChildPath}else{Microsoft.PowerShell.Management\Join-Path $Path $ChildPath}}
function Assert-BeforeRecoveryDeadline{}
function Get-LocalUser {param($Name,$ErrorAction)if(!$script:userRemoved){@{SID=@{Value=$fact.sid}}}}
function Remove-OwnedTerminatedOwnerRuntime {$global:t569CleanupOperations.Add('guarded-private-runtime-adapter')}
function Write-HostedCapabilityFailure {param($Ledger,$Code,$Evidence)}
function Stop-OwnedHostedProbeTasks {$global:t569CleanupOperations.Add('owned-task-cleanup-adapter')}
function Stop-HostedSessionOwnerPlanned {$script:ownerTerminationProven=$script:terminationAllowed;$script:failure=$true;$global:t569CleanupOperations.Add('failed-planned-shutdown');$false}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction)if($ClassName -ceq 'Win32_UserProfile' -and !$script:profileRemoved){@{Loaded=$false;LocalPath=$fact.profilePath}}}
function Get-SupervisorProcessSID {$fact.sid}
function Test-Path {param($Path)$false}
function Get-ChildItem {param($Path,$ErrorAction)@()}
function Get-LocalGroup {param($SID,$ErrorAction)@{SID=$SID}}
function Get-LocalGroupMember {param($Group,$ErrorAction)@()}
function Remove-CimInstance {param($InputObject,$ErrorAction)$script:profileRemoved=$true;$global:t569CleanupOperations.Add('remove-exact-profile-adapter')}
function Remove-LocalUser {param($Name,$ErrorAction)$script:userRemoved=$true;$global:t569CleanupOperations.Add('remove-exact-user-adapter')}
function Invoke-SupervisorRecoveryMutation {param($Operation,$Resource,$Precondition,$Action)$null=& $Action;@{completed=$true}}
try{
 foreach($boundary in @('normal-logoff','rename','mount','vhd-login')){
  $script:profileRemoved=$false;$script:userRemoved=$false;$script:failure=$false;$script:terminationAllowed=$true
  $global:t569CleanupOperations=[Collections.Generic.List[string]]::new()
  $result=Invoke-OwnedPostSessionCleanup $fact $false $false
  if(!$script:failure -or !$result.profileRemoved -or !$result.userRemoved -or $global:t569CleanupOperations.IndexOf('profile-restore-adapter') -ge $global:t569CleanupOperations.IndexOf('remove-exact-profile-adapter')){throw 'Production safe cleanup abandoned account/profile cleanup or lost the primary failure'}
  Write-Output "PRODUCTION_OWNED_CLEANUP_ADAPTER boundary=$boundary termination=proven primary_failure=latched profile_restore_before_remove=proved;WINDOWS_KERNEL_UNRUN"
 }
 $script:userRemoved=$false;$script:profileRemoved=$false;$script:terminationAllowed=$false;$denied=$false
 try{$null=Invoke-OwnedPostSessionCleanup $fact $false $false}catch{$denied=$true}
 if(!$denied -or $script:profileRemoved -or $script:userRemoved){throw 'Unproved participant termination allowed profile/account deletion'}
}finally{Microsoft.PowerShell.Management\Remove-Item $fixtureRoot -Recurse -Force;Remove-Variable t569CleanupOperations -Scope Global -ErrorAction SilentlyContinue}
