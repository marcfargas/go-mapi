[CmdletBinding()]
param(
    [ValidateSet('Import','RemoveOwned')][string] $Mode = 'Import',
    [string] $LaunchGateName,
    [Parameter(Mandatory)][long] $JobStartCounter,
    [Parameter(Mandatory)][long] $CounterFrequency,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceSHA,
    [Parameter(Mandatory)][ValidatePattern('^Ticket569-[a-f0-9]{32}-helper$')][string] $SupervisorPipeName,
    [Parameter(Mandatory)][string] $ExpectedSID,
    [Parameter(Mandatory)][int] $ExpectedSessionId,
    [string] $CertificatePath,
    [Parameter(Mandatory)][string] $Thumbprint,
    [string] $ExpectedSubject,
    [ValidateSet('true','false')][string] $OwnershipPreexisting = 'false',
    [ValidateSet('true','false')][string] $OwnershipImportAttempted = 'false',
    [long] $OwnershipPreabsenceSequence = 0,
    [long] $OwnershipImportSequence = 0,
    [Parameter(Mandatory)][string] $OutputPath,
    [string] $ObserverScriptPath,
    [string] $ObserverAttachedPath,
    [string] $ObserverExitPath,
    [string] $ObserverFailurePath,
    [ValidateRange(0,30)][int] $HoldAfterWriteSeconds = 2
)
$ErrorActionPreference = 'Stop'
# powershell.exe5.1 -File does not bind bool literals; normalize validated argv.
$ownershipPreexistingValue=[bool]($OwnershipPreexisting -ceq 'true')
$ownershipImportAttemptedValue=[bool]($OwnershipImportAttempted -ceq 'true')
$null = Import-Module (Join-Path $PSScriptRoot 'hosted-root-import-policy.psm1') -Force -PassThru
$null = Import-Module (Join-Path $PSScriptRoot 'hosted-capability-protocol.psm1') -Force -PassThru
$null = Import-Module (Join-Path $PSScriptRoot 'hosted-capability-credential.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
if($CounterFrequency -ne [Diagnostics.Stopwatch]::Frequency -or [Diagnostics.Stopwatch]::GetTimestamp() -lt $JobStartCounter){throw 'Importer refused invalid job clock'}
$importDeadline=$JobStartCounter+$(if($Mode -ceq 'RemoveOwned'){24L}else{21L})*60L*$CounterFrequency
Set-HostedCapabilityProtocolDeadline -DeadlineCounter $importDeadline -CounterFrequency $CounterFrequency
function Get-ImporterWait([int]$MaximumMilliseconds){Get-HostedCapabilityWaitBudget $importDeadline $CounterFrequency $MaximumMilliseconds}

$supervisor=$null
$credentialTarget="ticket569-hosted-capability-$RunId"
$credentialSecret=$null
$credentialSeeded=$false
$credentialRemoved=$false
$credentialAbsentErrorCode=$null
$credentialPreseedErrorCode=$null
$credentialNativeCompiled=$false
if (-not ('Ticket569HostedCredentialNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
public static class Ticket569HostedCredentialNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct CREDENTIAL {
        public uint Flags,Type; public string TargetName; public string Comment; public long LastWritten;
        public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist,AttributeCount;
        public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CredReadW(string target,uint type,uint flags,out IntPtr credential);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CredWriteW(ref CREDENTIAL credential,uint flags);
    [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CredDeleteW(string target,uint type,uint flags);
    [DllImport("advapi32.dll")] static extern void CredFree(IntPtr credential);
    public static bool Read(string target,out int errorCode) { IntPtr p;if(CredReadW(target,1,0,out p)){CredFree(p);errorCode=0;return true;}errorCode=Marshal.GetLastWin32Error();return false; }
    public static void WriteSynthetic(string target,out int errorCode) {
        byte[] bytes=new byte[48];using(RNGCryptoServiceProvider rng=new RNGCryptoServiceProvider())rng.GetBytes(bytes);
        string secret=Convert.ToBase64String(bytes);Array.Clear(bytes,0,bytes.Length);byte[] blob=Encoding.Unicode.GetBytes(secret);IntPtr ptr=Marshal.AllocHGlobal(blob.Length);
        try {Marshal.Copy(blob,0,ptr,blob.Length);CREDENTIAL c=new CREDENTIAL{Flags=0,Type=1,TargetName=target,Comment="Ticket 569 disposable credential cleanup canary",CredentialBlobSize=(uint)blob.Length,CredentialBlob=ptr,Persist=1,AttributeCount=0,Attributes=IntPtr.Zero,TargetAlias=null,UserName="ticket569"};if(!CredWriteW(ref c,0)){errorCode=Marshal.GetLastWin32Error();throw new Win32Exception(errorCode,"CredWriteW failed");}errorCode=0;}
        finally {for(int i=0;i<blob.Length;i++)Marshal.WriteByte(ptr,i,0);Marshal.FreeHGlobal(ptr);Array.Clear(blob,0,blob.Length);secret=null;}
    }
    public static bool Delete(string target,out int errorCode) {if(CredDeleteW(target,1,0)){errorCode=0;return true;}errorCode=Marshal.GetLastWin32Error();return false;}
}
'@ -ErrorAction Stop
}
$credentialNativeCompiled=$true
$result = [ordered]@{
    schema='ticket569-currentuser-root-import-v1'; runId=$RunId; sid=$null; sessionId=$null
    processId=$PID; processCreationFileTimeUtc=$null; store='CurrentUser/Root'; userFlag=$true
    subject=$null; thumbprint=$Thumbprint; certutilExitCode=$null; addedObserved=$false
    credentialTarget=$credentialTarget; credentialPreseedAbsent=$false; credentialSeeded=$false; credentialRemoved=$false; credentialFinalErrorCode=$null
    preexisting=$false; importAttempted=$false; removedObserved=$false; passed=$false; error=$null
}
function Write-Atomic([string] $Path, [object] $Value) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 24) + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
try {
    if ($RunId -notmatch '^[a-f0-9]{32}$' -or $ExpectedSID -notmatch '^S-1-5-21-' -or
        $Thumbprint -notmatch '^[a-fA-F0-9]{40}$' -or
        ($Mode -eq 'Import' -and (!(Test-Path -LiteralPath $CertificatePath -PathType Leaf) -or !$ObserverScriptPath -or !$ObserverAttachedPath -or !$ObserverExitPath -or !$ObserverFailurePath)) -or
        ($Mode -eq 'RemoveOwned' -and (!$ExpectedSubject -or $OwnershipPreabsenceSequence -le 0 -or $OwnershipImportSequence -le 0))) {
        throw 'Root import run identity, certificate or thumbprint is malformed'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $process = Get-Process -Id $PID -ErrorAction Stop
    $admin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $result.sid = $identity.User.Value
    $result.sessionId = [int]$process.SessionId
    $result.processCreationFileTimeUtc = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
    if ($result.sid -ne $ExpectedSID -or $result.sessionId -ne $ExpectedSessionId -or $admin -or
        !(Get-CimInstance Win32_UserProfile -Filter "SID='$ExpectedSID'" | Where-Object { $_.Loaded })) {
        throw 'Root import did not start in the exact loaded non-admin user session/profile'
    }
    if($Mode -eq 'Import'){
        if($LaunchGateName -cne "Global\Ticket569-$RunId-root-import"){throw 'Normal importer lacks the exact supervisor-owned identity gate'}
        Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
        $launchGate=Open-HostedCapabilityGate -Name $LaunchGateName -Access 0x00100000
        try{if(!$launchGate.Wait((Get-ImporterWait 30000))){throw 'Normal importer identity authorization did not arrive within 30 seconds'}}finally{$launchGate.Dispose()}
    }
    $supervisor=Connect-HostedCapabilityHelper -PipeName $SupervisorPipeName
    if($Mode -eq 'RemoveOwned'){
        $result.subject=$ExpectedSubject
        $result.preexisting=$ownershipPreexistingValue
        $result.importAttempted=$ownershipImportAttemptedValue
        $present=@(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant())
        $subjectMatches=($present.Count -eq 1 -and $present[0].Subject -ceq $ExpectedSubject)
        $decision=Get-HostedRootRemoveOwnedDecision -Preexisting $ownershipPreexistingValue -ImportAttempted $ownershipImportAttemptedValue `
            -PreabsenceSequence $OwnershipPreabsenceSequence -ImportAttemptSequence $OwnershipImportSequence -MatchCount $present.Count -SubjectMatches $subjectMatches
        if($decision -eq 'remove-owned'){
            $null=Invoke-HostedHelperMutation -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA -Operation 'recovery-remove-exact-owned-currentuser-root-certificate' `
                -ResourceIdentity @{store='CurrentUser/Root';thumbprint=$Thumbprint.ToUpperInvariant();subject=$ExpectedSubject;sid=$result.sid;sessionId=$result.sessionId} `
                -Precondition @{preabsenceSequence=$OwnershipPreabsenceSequence;importAttemptSequence=$OwnershipImportSequence;importAttempted=$ownershipImportAttemptedValue;exactSubjectMatch=$subjectMatches;uniqueThumbprintMatch=$true} -Action {
                    Remove-Item -LiteralPath "Cert:\CurrentUser\Root\$Thumbprint" -Confirm:$false -ErrorAction Stop
                    $remaining=@(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant())
                    if($remaining.Count){throw 'Ledger-owned exact CurrentUser Root certificate remains after RemoveOwned'}
                    @{absent=$true;thumbprint=$Thumbprint.ToUpperInvariant()}
                }
            $result.removedOwned=$true
        } elseif($decision -eq 'already-absent'){$result.removedOwned=$true}
        elseif($decision -eq 'preserve' -and $ownershipPreexistingValue){$result.preservedPreexisting=$true}
        else{throw 'RemoveOwned refused certificate state without matching ledger ownership facts'}
        $after=@(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant())
        $result.removedObserved=($result.removedOwned -and $after.Count -eq 0)
        $result.passed=($result.removedObserved -or ($result.preservedPreexisting -and $after.Count -eq 1 -and $after[0].Subject -ceq $ExpectedSubject))
    } else {
    $presentBefore=[Ticket569HostedCredentialNative]::Read($credentialTarget,[ref]$credentialPreseedErrorCode)
    $result.credentialPreseedErrorCode=$credentialPreseedErrorCode
    if ($presentBefore -or $credentialPreseedErrorCode -ne 1168) { throw 'Synthetic hosted capability credential was preexisting or CredRead did not return final-absent error 1168 before seeding' }
    $result.credentialPreseedAbsent=$true
    $null=Invoke-HostedHelperMutation -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA -Operation 'seed-exact-currentuser-synthetic-credential' `
        -ResourceIdentity @{target=$credentialTarget;sid=$result.sid;sessionId=$result.sessionId} `
        -Precondition @{credentialAbsent=$true;credReadError=$credentialPreseedErrorCode} -Action {
            Invoke-HostedCapabilityCredentialWrite -PrewriteReadErrorCode $credentialPreseedErrorCode -WriteAction {
                [Ticket569HostedCredentialNative]::WriteSynthetic($credentialTarget,[ref]$credentialPreseedErrorCode)
                @{written=$true;target=$credentialTarget}
            }
        }
    $credentialSeeded=$true;$result.credentialSeeded=$true
    $null=Invoke-HostedHelperMutation -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA -Operation 'delete-exact-currentuser-synthetic-credential' `
        -ResourceIdentity @{target=$credentialTarget;sid=$result.sid;sessionId=$result.sessionId} `
        -Precondition @{credentialSeeded=$true;targetExact=$true} -Action {
            if (-not [Ticket569HostedCredentialNative]::Delete($credentialTarget,[ref]$credentialPreseedErrorCode)) { throw "CredDelete failed for the exact run target ($credentialPreseedErrorCode)" }
            @{deleted=$true;target=$credentialTarget}
        }
    $credentialSeeded=$false;$credentialRemoved=$true;$result.credentialRemoved=$true
    $presentAfter=[Ticket569HostedCredentialNative]::Read($credentialTarget,[ref]$credentialAbsentErrorCode)
    $result.credentialFinalErrorCode=$credentialAbsentErrorCode
    if ($presentAfter -or $credentialAbsentErrorCode -ne 1168) { throw 'Synthetic hosted capability credential was not absent with CredRead error 1168 in the exact SID/session/profile' }
    $observerPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $observerArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',"`"$ObserverScriptPath`"",
        '-TargetProcessId',[string]$PID,'-ExpectedCommand',"`"$PSCommandPath`"",'-ExpectedRunId',$RunId,
        '-AttachedPath',"`"$ObserverAttachedPath`"",'-ExitPath',"`"$ObserverExitPath`"",
        '-FailurePath',"`"$ObserverFailurePath`"",'-TimeoutSeconds','120')
    $observer = Start-Process -FilePath $observerPowerShell -ArgumentList $observerArguments -PassThru
    $attachUntil = [DateTime]::UtcNow.AddSeconds(10)
    while (![IO.File]::Exists($ObserverAttachedPath) -and ![IO.File]::Exists($ObserverFailurePath) -and [DateTime]::UtcNow -lt $attachUntil -and [Diagnostics.Stopwatch]::GetTimestamp() -lt $importDeadline) { Start-Sleep -Milliseconds 100 }
    if (![IO.File]::Exists($ObserverAttachedPath) -or [IO.File]::Exists($ObserverFailurePath)) { throw 'Retained process observer did not attach before the consent prompt' }
    $result.observerProcessId = $observer.Id
    $result.observerAttachedPath = $ObserverAttachedPath
    $result.observerExitPath = $ObserverExitPath
    $result.observerFailurePath = $ObserverFailurePath
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath)
    try {
        $result.subject = $cert.Subject
        $sha1 = [Security.Cryptography.SHA1]::Create()
        try { $actualThumb = ([BitConverter]::ToString($sha1.ComputeHash($cert.RawData))).Replace('-', '') }
        finally { $sha1.Dispose() }
        if ($actualThumb -cne $Thumbprint.ToUpperInvariant()) { throw 'Public certificate thumbprint differs from its exact run identity' }
    } finally { $cert.Dispose() }
    $present = @(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant())
    if ($present.Count) {
        $result.preexisting = $true
        throw 'Unique prompt-test certificate already exists in CurrentUser Root; preserving its preexisting state'
    }
    $preabsenceSequence=Send-HostedCapabilityHelperFact -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA `
        -Name 'currentuser-root-exact-thumbprint-preabsence' `
        -ResourceIdentity @{store='CurrentUser/Root';thumbprint=$Thumbprint.ToUpperInvariant();subject=$result.subject;sid=$result.sid;sessionId=$result.sessionId} `
        -Observed @{matchCount=$present.Count;preexisting=$false}

    # No -f: certutil must ask its real CurrentUser Root consent question. It
    # shares the task's interactive console so native rdpilot CUA can observe it.
    $result.importAttempted = $true
    $import=Invoke-HostedHelperMutation -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA -Operation 'import-exact-currentuser-root-certificate' `
        -ResourceIdentity @{store='CurrentUser/Root';thumbprint=$Thumbprint.ToUpperInvariant();subject=$result.subject;sid=$result.sid;sessionId=$result.sessionId} `
        -Precondition @{preabsenceSequence=$preabsenceSequence;preexisting=$false;userConsentPromptRequired=$true} -Action {
            $certutilPath=[IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\certutil.exe'))
            $process=$null
            try{
                $process=Start-Process -FilePath $certutilPath -ArgumentList @('-user','-addstore','Root',$CertificatePath) -NoNewWindow -PassThru
                $processIdentity=@{pid=$process.Id;creationFileTimeUtc=$process.StartTime.ToUniversalTime().ToFileTimeUtc();executable=[IO.Path]::GetFullPath($process.MainModule.FileName);thumbprint=$Thumbprint.ToUpperInvariant();sid=$result.sid;sessionId=$result.sessionId}
                $imageMatches=($processIdentity.executable -ceq $certutilPath)
                $timedOut=$false;$terminationRequested=$false
                if(!$imageMatches){$terminationRequested=$true;try{$process.Kill()}catch{}}
                elseif(!$process.WaitForExit((Get-ImporterWait 240000))){$timedOut=$true;$terminationRequested=$true;try{$process.Kill()}catch{}}
                if($terminationRequested -and !$process.WaitForExit((Get-ImporterWait 5000))){throw 'Certutil process could not be waited after identity-bound termination'}
                if(!$terminationRequested -and !$process.HasExited){throw 'Bounded certutil CurrentUser Root prompt did not complete'}
                $process.Refresh()
                if(!$process.HasExited){throw 'Retained certutil handle did not signal after its bounded wait'}
                @{exitCode=[int]$process.ExitCode;thumbprint=$Thumbprint.ToUpperInvariant();process=$processIdentity;waited=$true;processExited=$process.HasExited;identityCreationRetained=$true;imageMatchesExpected=$imageMatches;timedOut=$timedOut;terminationRequested=$terminationRequested}
            }finally{
                if($process){
                    try{if(!$process.HasExited){$process.Kill();$null=$process.WaitForExit((Get-ImporterWait 5000))}}catch{}
                    $process.Dispose()
                }
            }
        }
    $result.certutilExitCode=[int]$import.result.exitCode
    $result.certutilProcess=$import.result.process
    if(!$import.result.imageMatchesExpected -or $import.result.timedOut -or $import.result.terminationRequested -or !$import.result.waited){throw 'Certutil image, timeout or termination evidence did not permit a successful CurrentUser Root import'}
    $present = @(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant())
    $result.addedObserved = ($result.certutilExitCode -eq 0 -and $present.Count -eq 1 -and $present[0].Subject -ceq $result.subject)
    if (!$result.addedObserved) { throw 'Exact test certificate was not observed in CurrentUser Root after consent' }
    }
} catch {
    $result.error = @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message }
} finally {
    if ($credentialSeeded -and $result.sid -eq $ExpectedSID -and $result.sessionId -eq $ExpectedSessionId) {
        try {
            $null=Invoke-HostedHelperMutation -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA -Operation 'recover-delete-exact-currentuser-synthetic-credential' `
                -ResourceIdentity @{target=$credentialTarget;sid=$result.sid;sessionId=$result.sessionId} -Precondition @{seededByThisProcess=$true} -Action {
                    [Ticket569HostedCredentialNative]::Delete($credentialTarget,[ref]$credentialAbsentErrorCode) | Out-Null
                    @{deleted=$true;target=$credentialTarget}
                }
        } catch {}
    }
    if($Mode -eq 'Import') { try {
        $match = @(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant())
        $subjectMatches = ($match.Count -eq 1 -and $match[0].Subject -ceq $result.subject)
        $decision = Get-HostedRootImportCleanupDecision -Preexisting $result.preexisting -ImportAttempted $result.importAttempted `
            -MatchCount $match.Count -SubjectMatches $subjectMatches
        if ($decision -eq 'remove-owned') {
            $null=Invoke-HostedHelperMutation -Connection $supervisor -RunId $RunId -SourceSHA $SourceSHA -Operation 'remove-exact-owned-currentuser-root-certificate' `
                -ResourceIdentity @{store='CurrentUser/Root';thumbprint=$Thumbprint.ToUpperInvariant();subject=$result.subject;sid=$result.sid;sessionId=$result.sessionId} `
                -Precondition @{preabsenceSequence=$preabsenceSequence;importAttempted=$result.importAttempted;exactMatch=$true} -Action {
                    Remove-Item -LiteralPath "Cert:\CurrentUser\Root\$Thumbprint" -Confirm:$false -ErrorAction Stop
                    @{absent=(@(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant()).Count -eq 0)}
                }
        } elseif ($decision -like 'refuse-*') {
            throw 'Refused cleanup because CurrentUser Root thumbprint is ambiguous or subject-mismatched'
        }
        $absent = @((Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant())).Count -eq 0
        $result.removedObserved = $absent
        if (!$absent -and !$result.preexisting) { throw 'Exact transient CurrentUser Root certificate remains after cleanup' }
    } catch {
        if (!$result.error) { $result.error = @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message } }
        else { $result.cleanupError = $_.Exception.Message }
        $result.removedObserved = $false
    }}
}
if($supervisor){Close-HostedCapabilitySupervisorConnection -Connection $supervisor}
$result.completedAtUtc = [DateTime]::UtcNow.ToString('o')
if($Mode -eq 'Import'){$result.passed = (!$result.error -and $result.addedObserved -and $result.removedObserved -and $result.certutilExitCode -eq 0 -and $result.credentialPreseedAbsent -and $result.credentialSeeded -and $result.credentialRemoved -and $result.credentialFinalErrorCode -eq 1168)}else{$result.passed=$result.passed -and !$result.error}
try { Write-Atomic $OutputPath $result } catch { [Console]::Error.WriteLine("final root-import evidence write failed: $($_.Exception.Message)"); exit 2 }
if ($HoldAfterWriteSeconds -gt 0) { Start-Sleep -Milliseconds (Get-ImporterWait ($HoldAfterWriteSeconds*1000)) }
if (!$result.passed) { exit 1 }
exit 0
