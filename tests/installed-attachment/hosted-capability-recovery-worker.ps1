[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceSHA,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string] $ExpectedWorkerSHA256,
    [Parameter(Mandatory)][ValidatePattern('^S-1-5-21-')][string] $ExpectedSID,
    [Parameter(Mandatory)][ValidateRange(1,65535)][int] $ExpectedSessionId,
    [Parameter(Mandatory)][string] $ExpectedProfilePath,
    [Parameter(Mandatory)][string] $RecoveryJobName,
    [Parameter(Mandatory)][ValidatePattern('^Ticket569-[a-f0-9]{32}-helper$')][string] $HelperPipeName,
    [Parameter(Mandatory)][ValidatePattern('^Global\\Ticket569-[a-f0-9]{32}-failure$')][string] $FailureEventName,
    [Parameter(Mandatory)][string] $SourceRoot,
    [Parameter(Mandatory)][long] $JobStartCounter,
    [Parameter(Mandatory)][ValidateRange(1,10000000000)][long] $CounterFrequency
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-protocol.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
Set-HostedCapabilityProtocolDeadline -DeadlineCounter ($JobStartCounter+24L*60L*$CounterFrequency) -CounterFrequency $CounterFrequency
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-credential.psm1') -Force
Import-Module -Name ([IO.Path]::Combine($PSHOME,'Modules','Microsoft.PowerShell.Utility','Microsoft.PowerShell.Utility.psd1')) -ErrorAction Stop
$actualWorkerSHA256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
if($actualWorkerSHA256 -cne $ExpectedWorkerSHA256){throw 'Recovery worker script SHA-256 did not match the supervisor authorization'}
$job=$null
$supervisor=$null
$resultPath=Join-Path $ExpectedProfilePath ".ticket569-$RunId-recovery.json"
function Write-RecoveryResult([object] $Value){
    $temporary=$resultPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $Value -Depth 16 -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$resultPath)
}
try {
    if([Diagnostics.Stopwatch]::Frequency -ne $CounterFrequency -or [Diagnostics.Stopwatch]::GetTimestamp() -lt $JobStartCounter){throw 'Recovery refused invalid or reversed job QPC markers'}
    $recoveryDeadline=$JobStartCounter+24L*60L*$CounterFrequency
    if([Diagnostics.Stopwatch]::GetTimestamp() -ge $recoveryDeadline){throw 'Recovery launcher reached the hard J+24 cleanup cutoff'}
    # The supervisor and suspended recovery launcher already bound this worker
    # to the clean source SHA and its exact script digest. The disposable user
    # must not rely on Git safe.directory access to the runner-owned checkout.
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$process=Get-Process -Id $PID
    $profile=Get-CimInstance Win32_UserProfile -Filter "SID='$ExpectedSID'" -ErrorAction Stop
    $admin=([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if($identity.User.Value -cne $ExpectedSID -or $process.SessionId -ne $ExpectedSessionId -or $process.SessionId -eq 0 -or $admin -or
       !$profile -or !$profile.Loaded -or $profile.LocalPath -cne $ExpectedProfilePath -or $env:USERPROFILE -cne $ExpectedProfilePath -or
       !(Test-Path -LiteralPath "Registry::HKEY_USERS\$ExpectedSID")){throw 'Recovery process is not the exact loaded non-admin SID/session/profile'}
    if(Test-Path -LiteralPath $resultPath){throw 'Run-scoped recovery result already exists; refusing to overwrite evidence'}
    $job=Open-HostedCapabilityJob -Name $RecoveryJobName -Access 0x0005
    if(($job.LimitFlags -band 0x2000) -eq 0){throw 'Recovery Job Object lacks kill-on-close'}
    if(!(Test-CurrentProcessInHostedCapabilityJob -Job $job) -or $job.ActiveProcesses -lt 1){throw 'Recovery process was not contained in its supervisor-created Job Object before resource authorization'}
    $process=Get-Process -Id $PID
    $recoveryIdentity=@{pid=$PID;creationFileTimeUtc=$process.StartTime.ToUniversalTime().ToFileTimeUtc();sid=$identity.User.Value;sessionId=$process.SessionId;sourceSHA=$SourceSHA.ToLowerInvariant();recoveryJob=$RecoveryJobName;jobActiveProcesses=$job.ActiveProcesses}
    $supervisor=Connect-HostedCapabilityHelper -PipeName $HelperPipeName

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class Ticket569RecoveryCredential {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct CREDENTIAL { public uint Flags,Type; public string TargetName,Comment; public long LastWritten; public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist,AttributeCount; public IntPtr Attributes; public string TargetAlias,UserName; }
 [DllImport("advapi32.dll",EntryPoint="CredReadW",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CredRead(string target,uint type,uint flags,out IntPtr credential);
 [DllImport("advapi32.dll",EntryPoint="CredDeleteW",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CredDelete(string target,uint type,uint flags);
 [DllImport("advapi32.dll")] static extern void CredFree(IntPtr credential);
 public static int DeleteIfPresent(string target){IntPtr p;if(!CredRead(target,1,0,out p)){int missing=Marshal.GetLastWin32Error();if(missing==1168)return 1168;throw new Win32Exception(missing,"Recovery CredRead failed");}CredFree(p);if(!CredDelete(target,1,0)){int deletion=Marshal.GetLastWin32Error();if(deletion!=1168)throw new Win32Exception(deletion,"Recovery CredDelete failed");return deletion;}return 0;}
 public static int ReadError(string target){IntPtr p;if(CredRead(target,1,0,out p)){CredFree(p);return 0;}return Marshal.GetLastWin32Error();}
}
'@ -ErrorAction Stop
    $credentialTarget="ticket569-hosted-capability-$RunId"
    $credentialBeforeError=[Ticket569RecoveryCredential]::ReadError($credentialTarget)
    $credentialOwnership=Get-HostedCapabilityHelperFact -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA.ToLowerInvariant() `
        -Name 'recovery-run-credential-state' -ResourceIdentity @{target=$credentialTarget;sid=$ExpectedSID;sessionId=$ExpectedSessionId} `
        -Observed @{credReadErrorCode=$credentialBeforeError;atUtc=[DateTime]::UtcNow.ToString('o')}
    $credentialWriteOwned=[bool]$credentialOwnership.credentialWriteOwned
    $credentialRecoveryAction=Get-HostedCapabilityCredentialRecoveryAction -WriteIntentOwned $credentialWriteOwned -FinalReadErrorCode $credentialBeforeError
    $credentialDeleteError=1168
    if($credentialRecoveryAction -eq 'remove-owned-if-present' -and $credentialBeforeError -ne 1168){
        $delete=Invoke-HostedHelperMutation -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA.ToLowerInvariant() -Operation 'recovery-delete-exact-currentuser-synthetic-credential' `
            -ResourceIdentity @{target=$credentialTarget;sid=$ExpectedSID;sessionId=$ExpectedSessionId} -Precondition @{targetRunScoped=$true;writeIntentSupervisorOwned=$true;recoveryJob=$RecoveryJobName} -Action {
                @{errorCode=[Ticket569RecoveryCredential]::DeleteIfPresent($credentialTarget);target=$credentialTarget}
            }
        $credentialDeleteError=[int]$delete.result.errorCode
    }
    $credentialFinalError=[Ticket569RecoveryCredential]::ReadError($credentialTarget)
    if($credentialFinalError -ne 1168){throw "Run-scoped synthetic credential was not absent after recovery (CredRead=$credentialFinalError)"}
    $sessionHostHealthBefore=Get-HostedCapabilityHelperFact -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA.ToLowerInvariant() `
        -Name 'session-host-health' -ResourceIdentity @{sid=$ExpectedSID;sessionId=$ExpectedSessionId} `
        -Observed @{phase='recovery-before-root-cleanup';atUtc=[DateTime]::UtcNow.ToString('o')}
    $sessionHostHealthBefore=$sessionHostHealthBefore.sessionHostHealth
    $subject="CN=Ticket569-Root-Prompt-$RunId"
    $root=Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Subject -CEQ $subject
    $removed=[Collections.Generic.List[string]]::new()
    foreach($cert in @($root)){
        $current=Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $cert.Thumbprint
        if(@($current).Count -ne 1 -or $current[0].Subject -cne $subject){throw 'Recovery refused an ambiguous or subject-mismatched CurrentUser Root certificate'}
        $thumb=$cert.Thumbprint.ToUpperInvariant()
        $ownership=Get-HostedCapabilityHelperFact -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA.ToLowerInvariant() `
            -Name 'recovery-root-removal-ownership' -ResourceIdentity @{store='CurrentUser/Root';thumbprint=$thumb;subject=$subject;sid=$ExpectedSID;sessionId=$ExpectedSessionId} `
            -Observed @{exactThumbprintObserved=$true;subject=$subject;atUtc=[DateTime]::UtcNow.ToString('o')}
        if(!$ownership.rootOwnership -or $ownership.rootOwnership.preexisting -or !$ownership.rootOwnership.importAttempted -or
           [long]$ownership.rootOwnership.preabsenceSequence -le 0 -or [long]$ownership.rootOwnership.importAttemptSequence -le 0){
            throw 'CurrentUser Root recovery did not receive supervisor-ledger ownership facts for RemoveOwned'
        }
        Close-HostedCapabilitySupervisorConnection -Connection $supervisor;$supervisor=$null
        $removeScript=Join-Path $PSScriptRoot 'hosted-root-import.ps1'
        $removeEvidence=Join-Path $ExpectedProfilePath ".ticket569-$RunId-root-remove-$($thumb.ToLowerInvariant()).json"
        if(Test-Path -LiteralPath $removeEvidence){throw 'RemoveOwned evidence path already exists; refusing to overwrite'}
        $powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $removeArgs=@('-NoLogo','-NoProfile','-NonInteractive','-File',"`"$removeScript`"",'-Mode','RemoveOwned','-JobStartCounter',[string]$JobStartCounter,'-CounterFrequency',[string]$CounterFrequency,
            '-RunId',$RunId,'-SourceSHA',$SourceSHA.ToLowerInvariant(),'-SupervisorPipeName',$HelperPipeName,
            '-ExpectedSID',$ExpectedSID,'-ExpectedSessionId',[string]$ExpectedSessionId,'-Thumbprint',$thumb,
            '-ExpectedSubject',"`"$subject`"",'-OwnershipPreexisting','false','-OwnershipImportAttempted','true',
            '-OwnershipPreabsenceSequence',[string]$ownership.rootOwnership.preabsenceSequence,
            '-OwnershipImportSequence',[string]$ownership.rootOwnership.importAttemptSequence,'-OutputPath',"`"$removeEvidence`"")
        $removeProcess=Start-Process -FilePath $powershell -ArgumentList $removeArgs -PassThru
        $removeIdentity=@{pid=$removeProcess.Id;creationFileTimeUtc=$removeProcess.StartTime.ToUniversalTime().ToFileTimeUtc();executable=[IO.Path]::GetFullPath($removeProcess.MainModule.FileName);sid=$ExpectedSID;sessionId=$ExpectedSessionId;mode='RemoveOwned';thumbprint=$thumb;script=$removeScript}
        if($removeIdentity.executable -cne [IO.Path]::GetFullPath($powershell) -or $removeProcess.SessionId -ne $ExpectedSessionId){try{$removeProcess.Kill();$null=$removeProcess.WaitForExit((Get-HostedCapabilityWaitBudget $recoveryDeadline $CounterFrequency 5000))}catch{};throw 'RemoveOwned importer process image or session identity was unexpected'}
        $removeUntil=[long]$JobStartCounter+24L*60L*$CounterFrequency
        while(!$removeProcess.WaitForExit(100) -and [Diagnostics.Stopwatch]::GetTimestamp() -lt $removeUntil){}
        if(!$removeProcess.HasExited){try{$removeProcess.Kill();$null=$removeProcess.WaitForExit((Get-HostedCapabilityWaitBudget $recoveryDeadline $CounterFrequency 5000))}catch{};throw 'RemoveOwned importer exceeded the absolute J+24 recovery cutoff'}
        $removeProcess.Refresh();$removeExit=[int]$removeProcess.ExitCode;$removeProcess.Dispose()
        if($removeExit -ne 0 -or !(Test-Path -LiteralPath $removeEvidence)){throw 'Ledger-authorized RemoveOwned importer did not complete with exact readback evidence'}
        $removeResult=Get-Content -LiteralPath $removeEvidence -Raw | ConvertFrom-Json -ErrorAction Stop
        if(!$removeResult.passed -or !$removeResult.removedObserved -or $removeResult.thumbprint -cne $thumb -or $removeResult.subject -cne $subject){throw 'RemoveOwned result did not prove exact ledger-owned certificate absence'}
        $supervisor=Connect-HostedCapabilityHelper -PipeName $HelperPipeName
        $removed.Add($cert.Thumbprint)
    }
    $sessionHostHealthAfter=Get-HostedCapabilityHelperFact -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA.ToLowerInvariant() `
        -Name 'session-host-health' -ResourceIdentity @{sid=$ExpectedSID;sessionId=$ExpectedSessionId} `
        -Observed @{phase='recovery-after-root-cleanup';atUtc=[DateTime]::UtcNow.ToString('o')}
    $sessionHostHealthAfter=$sessionHostHealthAfter.sessionHostHealth
    $rootStatus=if($sessionHostHealthBefore.healthy -and $sessionHostHealthAfter.healthy){'verified'}else{'unverified'}
    Write-RecoveryResult @{schema='ticket569-capability-recovery-v1';runId=$RunId;sourceSHA=$SourceSHA.ToLowerInvariant();process=$recoveryIdentity;sid=$ExpectedSID;sessionId=$ExpectedSessionId;profilePath=$ExpectedProfilePath;profileLoaded=$true;admin=$false;credentialTarget=$credentialTarget;credentialWriteOwned=$credentialWriteOwned;credentialRecoveryAction=$credentialRecoveryAction;credentialDeleteError=$credentialDeleteError;credentialFinalCredReadError=$credentialFinalError;ownedRootCertificateSubject=$subject;removedRootThumbprints=@($removed);rootSubjectRemaining=(@(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Subject -CEQ $subject).Count -gt 0);rootStatus=$rootStatus;sessionHostHealthBefore=$sessionHostHealthBefore;sessionHostHealthAfter=$sessionHostHealthAfter;failed=($rootStatus -ne 'verified');sessionLeftActiveForSupervisorLogoff=$true;atUtc=[DateTime]::UtcNow.ToString('o')}
    if($rootStatus -ne 'verified'){throw 'CurrentUser Root recovery result is unverified because the retained session-host UIA channel was lost'}
    if(@(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Subject -CEQ $subject).Count -gt 0){throw 'Run-scoped root certificate remains after recovery'}
    exit 0
} catch {
    try { Set-HostedCapabilityFailureEvent -Name $FailureEventName } catch {}
    try {Write-RecoveryResult @{schema='ticket569-capability-recovery-v1';runId=$RunId;sourceSHA=$SourceSHA.ToLowerInvariant();failed=$true;errorType=$_.Exception.GetType().FullName;atUtc=[DateTime]::UtcNow.ToString('o')}}catch{}
    [Console]::Error.WriteLine(('TICKET569_RECOVERY_FAILED '+$_.Exception.GetType().FullName))
    exit 2
} finally {if($supervisor){Close-HostedCapabilitySupervisorConnection -Connection $supervisor};if($job){$job.Dispose()}}
