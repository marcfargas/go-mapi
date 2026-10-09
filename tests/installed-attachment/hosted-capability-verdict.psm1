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
        return [pscustomobject]@{ sha256=$hash; length=$plain.Length }
    } finally {
        $plain = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)
    }
}

function Get-HostedPasswordRequiredCharacters {
    return [char[]]@('a','A','1','!')
}

function Test-HostedSecretCanary([string] $Directory, [string] $Sha256, [int] $Length) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Recurse -ErrorAction Stop) {
            $text = [IO.File]::ReadAllText($file.FullName)
            for ($index = 0; $index -le ($text.Length - $Length); $index++) {
                $candidate = [Text.Encoding]::UTF8.GetBytes($text.Substring($index, $Length))
                $observed = ([BitConverter]::ToString($sha.ComputeHash($candidate))).Replace('-', '').ToLowerInvariant()
                if ($observed -ceq $Sha256) { return [pscustomobject]@{ leaked=$true; file=$file.Name } }
            }
        }
        return [pscustomobject]@{ leaked=$false; file=$null }
    } finally { $sha.Dispose() }
}

Export-ModuleMember -Function Resolve-HostedCapabilityVerdict, Invoke-HostedCapabilityFinalization, Test-HostedPhaseBudget, Invoke-HostedProfileRestoreIfRequired, New-HostedSecretCanary, Test-HostedSecretCanary, Get-HostedPasswordRequiredCharacters
