$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-credential.psm1') -Force
$writes=0
try {
    $null=Invoke-HostedCapabilityCredentialWrite -PrewriteReadErrorCode 0 -WriteAction {$script:writes++}
    throw 'preexisting credential did not block a write'
} catch {if($_.Exception.Message -notmatch 'proven absent'){throw}}
if($writes -ne 0){throw 'credential write action ran despite preexisting CredRead success'}
$result=Invoke-HostedCapabilityCredentialWrite -PrewriteReadErrorCode 1168 -WriteAction {$script:writes++;@{written=$true}}
if($writes -ne 1 -or !$result.written){throw 'credential write did not run after exact CredRead 1168 preabsence'}
if((Get-HostedCapabilityCredentialRecoveryAction -WriteIntentOwned $false -FinalReadErrorCode 1168) -cne 'verify-absent-before-mutation'){
    throw 'read-only recovery must accept exact final CredRead 1168 when no write intent was owned'
}
if((Get-HostedCapabilityCredentialRecoveryAction -WriteIntentOwned $true -FinalReadErrorCode 0) -cne 'remove-owned-if-present'){
    throw 'recovery may delete a present credential only after a run-owned write intent'
}
try {
    $null=Get-HostedCapabilityCredentialRecoveryAction -WriteIntentOwned $false -FinalReadErrorCode 0
    throw 'recovery accepted a present credential with no owned write intent'
} catch {if($_.Exception.Message -notmatch 'no run-owned write intent'){throw}}
Write-Output 'HOSTED_CAPABILITY_CREDENTIAL_TESTS_PASSED'
