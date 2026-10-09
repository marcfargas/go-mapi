Import-Module (Join-Path $PSScriptRoot 'hosted-capability-canary.psm1') -Force
function Resolve-HostedCapabilityVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Conditions,
        [Parameter(Mandatory)][object] $Normal,
        [Parameter(Mandatory)][object] $Vhd,
        [Parameter(Mandatory)][object] $RootPrompt,
        [Parameter(Mandatory)][bool] $PositiveRoute,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $CleanupErrors,
        [Parameter(Mandatory)][string] $ProfileState,
        [Parameter(Mandatory)][bool] $UserCreated
    )
    if ($CleanupErrors.Count -gt 0 -or $ProfileState -notin @('normal','not-created') -or $UserCreated -or
        @($Conditions | Where-Object { $_.class -eq 'cleanup-failed' }).Count) { return 'cleanup-failed' }
    if (@($Conditions | Where-Object { $_.class -eq 'harness-defect' }).Count) { return 'harness-defect' }
    if (@($Conditions | Where-Object { $_.class -eq 'transient-setup' }).Count) { return 'transient-setup' }
    $unsupported = @($Conditions | Where-Object { $_.class -eq 'unavailable-supported-capability' })
    if ($unsupported.Count) {
        foreach ($condition in $unsupported) {
            $evidence = $condition.evidence
            $vhdUnavailableWithNormalControl = ($evidence.route -eq 'vhd' -and $Vhd.status -eq 'unavailable-supported-capability' -and
                $Normal.status -eq 'feasible-observed' -and $evidence.positiveControlObserved -eq $true)
            $normalUnavailableWithVhdControl = ($evidence.route -eq 'normal' -and $Normal.status -eq 'unavailable-supported-capability' -and
                $Vhd.status -eq 'feasible-observed' -and $evidence.positiveControlObserved -eq $true)
            if ($evidence.documentedSupportedLimitation -eq $true -and $evidence.actualError -and
                ($vhdUnavailableWithNormalControl -or $normalUnavailableWithVhdControl)) { return 'unavailable-supported-capability' }
        }
        return 'unknown'
    }
    if ($Normal.status -eq 'feasible-observed' -and $Vhd.status -eq 'feasible-observed' -and
        $RootPrompt.status -eq 'observed-and-answered' -and $PositiveRoute) { return 'feasible-observed' }
    return 'unknown'
}

function Invoke-HostedCapabilityFinalization {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Final, [Parameter(Mandatory)][scriptblock] $WriteEvidence)
    try {
        & $WriteEvidence $Final
        return [pscustomobject]@{ verdict=$Final.verdict; writeFailed=$false; failureClass=$null; message=$null }
    } catch {
        $verdict = if ($Final.verdict -eq 'cleanup-failed') { 'cleanup-failed' } else { 'harness-defect' }
        return [pscustomobject]@{ verdict=$verdict; writeFailed=$true; failureClass='harness-defect'; message=$_.Exception.Message }
    }
}

function Resolve-HostedCapabilitySupervisorVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('feasible-observed','unavailable-supported-capability','harness-defect','transient-setup','unknown','cleanup-failed')][string] $WorkerVerdict,
        [Parameter(Mandatory)][ValidateSet('complete','failed','unverified')][string] $CleanupStatus,
        [Parameter(Mandatory)][bool] $TerminationProven,
        [Parameter(Mandatory)][bool] $WorkerIdentityProven,
        [Parameter(Mandatory)][bool] $FailureLatched,
        [bool] $LocalFinalWriteProven=$false,
        [bool] $RecoveryContextProven=$false
    )
    if($CleanupStatus -ne 'complete' -or !$TerminationProven -or !$RecoveryContextProven){
        return [pscustomobject]@{verdict='cleanup-failed';primaryVerdict=$WorkerVerdict;cleanupStatus=$CleanupStatus;terminationProven=$TerminationProven;workerIdentityProven=$WorkerIdentityProven;failureLatched=$FailureLatched}
    }
    if(!$LocalFinalWriteProven){return [pscustomobject]@{verdict='harness-defect';primaryVerdict=$WorkerVerdict;cleanupStatus=$CleanupStatus;localFinalWriteProven=$false;recoveryContextProven=$RecoveryContextProven}}
    if(!$WorkerIdentityProven -or $FailureLatched){
        $verdict=if($WorkerVerdict -in @('cleanup-failed','harness-defect','transient-setup','unknown','unavailable-supported-capability')){$WorkerVerdict}else{'harness-defect'}
        return [pscustomobject]@{verdict=$verdict;primaryVerdict=$WorkerVerdict;cleanupStatus=$CleanupStatus;terminationProven=$TerminationProven;workerIdentityProven=$WorkerIdentityProven;failureLatched=$FailureLatched}
    }
    $verdict=if($WorkerVerdict -eq 'feasible-observed'){'feasible-observed'}else{$WorkerVerdict}
    [pscustomobject]@{verdict=$verdict;primaryVerdict=$WorkerVerdict;cleanupStatus=$CleanupStatus;terminationProven=$TerminationProven;workerIdentityProven=$WorkerIdentityProven;failureLatched=$FailureLatched}
}

function Test-HostedPhaseBudget([DateTime] $NowUtc, [DateTime] $WorkDeadlineUtc, [int] $RequiredSeconds) {
    $remaining = [Math]::Floor(($WorkDeadlineUtc.ToUniversalTime() - $NowUtc.ToUniversalTime()).TotalSeconds)
    return [pscustomobject]@{
        allowed=($remaining -ge $RequiredSeconds)
        remainingSeconds=[int]$remaining
        requiredSeconds=$RequiredSeconds
        workDeadlineUtc=$WorkDeadlineUtc.ToUniversalTime().ToString('o')
    }
}

function Invoke-HostedProfileRestoreIfRequired(
    [ValidateSet('not-created', 'normal', 'preparing', 'mounted')][string] $ProfileState,
    [Parameter(Mandatory)][scriptblock] $Restore
) {
    if ($ProfileState -notin @('preparing', 'mounted')) { return $false }
    & $Restore
    return $true
}

function New-HostedSecretCanary([Security.SecureString] $Secret) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secret)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringUni($pointer)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($plain)))).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
        return [pscustomobject]@{ sha256=$hash; length=$plain.Length; rollingFingerprint=[Ticket569SecretCanary]::Fingerprint($plain) }
    } finally {
        $plain = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)
    }
}

function Get-HostedPasswordRequiredCharacters {
    return [char[]]@('a','A','1','!')
}

function Test-HostedSecretCanary([string] $Directory,[string[]] $Directories,[string] $Sha256, [int] $Length,
                                [ValidateRange(100,30000)][int] $MaxElapsedMilliseconds=4000,
                                [ValidateRange(1048576,67108864)][long] $MaxBytes=16777216,[string]$RollingFingerprint) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $watch=[Diagnostics.Stopwatch]::StartNew()
    [long]$bytesRead=0
    try {
        $roots=[Collections.Generic.List[string]]::new()
        foreach($candidateRoot in @($Directory)+@($Directories)){
            if([string]::IsNullOrWhiteSpace($candidateRoot) -or !(Test-Path -LiteralPath $candidateRoot -PathType Container)){continue}
            $full=[IO.Path]::GetFullPath($candidateRoot)
            if(!$roots.Contains($full)){$roots.Add($full)}
        }
        foreach($root in $roots){
            foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction Stop) {
                if($watch.ElapsedMilliseconds -ge $MaxElapsedMilliseconds){throw 'Secret-canary scan exceeded its absolute elapsed-time bound'}
                if($file.Length -lt 0 -or $file.Length -gt $MaxBytes -or $bytesRead+$file.Length -gt $MaxBytes){throw 'Secret-canary scan encountered a file or run total beyond its byte bound'}
                [long]$fileBytes=0
                if([Ticket569SecretCanary]::Contains($file.FullName,$Sha256,$Length,$RollingFingerprint,($MaxBytes-$bytesRead),$watch,$MaxElapsedMilliseconds,[ref]$fileBytes)){
                    return [pscustomobject]@{leaked=$true;file=$file.FullName;root=$root}
                }
                $bytesRead+=$fileBytes

            }
        }
        return [pscustomobject]@{ leaked=$false; file=$null; root=$null; bytesRead=$bytesRead; elapsedMilliseconds=$watch.ElapsedMilliseconds; bounded=$true }
    } finally { $sha.Dispose();$watch.Stop() }
}

Export-ModuleMember -Function Resolve-HostedCapabilityVerdict, Resolve-HostedCapabilitySupervisorVerdict, Invoke-HostedCapabilityFinalization, Test-HostedPhaseBudget, Invoke-HostedProfileRestoreIfRequired, New-HostedSecretCanary, Test-HostedSecretCanary, Get-HostedPasswordRequiredCharacters

function Get-HostedVhdSupportedLimitation($Probe,$Normal) {
    # A narrowly evidenced producer: Windows explicitly reports ERROR_NOT_SUPPORTED
    # from CredWriteW in an otherwise verified real mounted-profile context. Other
    # API errors, identity/setup defects and unknown exceptions remain fail-closed.
    if(!$Probe -or !$Normal -or $Normal.status -cne 'feasible-observed' -or $Probe.profileKind -cne 'mount-point' -or
       $Probe.nativeRefusalAcknowledged -ne $true -or $Probe.nativeFailureFromApi -ne $true -or $Probe.nativeOperation -cne 'CredWriteW' -or $Probe.nativeWin32ErrorCode -ne 50 -or $Probe.credentialFinalCredReadError -ne 1168 -or
       $Probe.admin -ne $false -or !$Probe.userInteractive -or $Probe.windowStation -cne 'WinSta0' -or $Probe.desktop -cne 'Default' -or
       [int]$Probe.sessionId -le 0 -or !$Probe.profileLoaded -or !$Probe.profileHivePresent -or
       $Probe.profileSID -cne $Probe.sid -or $Probe.profileLocalPath -cne $Probe.userProfile -or $Probe.userProfileApi -cne $Probe.userProfile -or
       !$Probe.profileMount -or $Probe.profileMount.reparseTag -cne '0xA0000003' -or !$Probe.profileMount.attached -or !$Probe.profileMount.volumeMatchesVhd -or
       $Probe.cleanupErrors.Count -ne 0 -or @($Probe.conditions|Where-Object {$_ -notlike 'probe-exception:*'}).Count){return $null}
    [pscustomobject]@{route='vhd';documentedSupportedLimitation=$true;positiveControlObserved=$true;
        actualError=@{api='CredWriteW';win32Error=50;name='ERROR_NOT_SUPPORTED'};
        documentation='https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--0-499-';
        qualification='Observed API refusal in the verified VHD route; does not infer a general VHD or historical incident cause';probe=$Probe}
}
Export-ModuleMember -Function Get-HostedVhdSupportedLimitation
