Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Invoke-HostedCapabilityCredentialWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(0,4294967295)][int] $PrewriteReadErrorCode,
        [Parameter(Mandatory)][scriptblock] $WriteAction
    )
    if($PrewriteReadErrorCode -ne 1168){throw 'Credential write refused because the exact run-scoped target was not proven absent by CredRead error 1168'}
    & $WriteAction
}

function Get-HostedCapabilityCredentialRecoveryAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $WriteIntentOwned,
        [Parameter(Mandatory)][ValidateRange(0,4294967295)][int] $FinalReadErrorCode
    )
    if($WriteIntentOwned){return 'remove-owned-if-present'}
    if($FinalReadErrorCode -eq 1168){return 'verify-absent-before-mutation'}
    throw 'Credential recovery refused because a present or unreadable target has no run-owned write intent'
}

Export-ModuleMember -Function Invoke-HostedCapabilityCredentialWrite, Get-HostedCapabilityCredentialRecoveryAction
