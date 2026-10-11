function Get-HostedRootImportCleanupDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $Preexisting,
        [Parameter(Mandatory)][bool] $ImportAttempted,
        [Parameter(Mandatory)][int] $MatchCount,
        [Parameter(Mandatory)][bool] $SubjectMatches
    )
    if ($MatchCount -lt 0) { throw 'Certificate match count cannot be negative' }
    if ($Preexisting -or !$ImportAttempted) { return 'preserve' }
    if ($MatchCount -gt 1) { return 'refuse-ambiguous' }
    if ($MatchCount -eq 0) { return 'already-absent' }
    if (!$SubjectMatches) { return 'refuse-mismatch' }
    return 'remove-owned'
}

function Get-HostedRootRemoveOwnedDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $Preexisting,
        [Parameter(Mandatory)][bool] $ImportAttempted,
        [Parameter(Mandatory)][long] $PreabsenceSequence,
        [Parameter(Mandatory)][long] $ImportAttemptSequence,
        [Parameter(Mandatory)][int] $MatchCount,
        [Parameter(Mandatory)][bool] $SubjectMatches
    )
    if ($MatchCount -lt 0) { throw 'Certificate match count cannot be negative' }
    if ($Preexisting) { return 'preserve' }
    if (!$ImportAttempted -or $PreabsenceSequence -le 0 -or $ImportAttemptSequence -le $PreabsenceSequence) { return 'refuse-unowned' }
    Get-HostedRootImportCleanupDecision -Preexisting $false -ImportAttempted $true -MatchCount $MatchCount -SubjectMatches $SubjectMatches
}

Export-ModuleMember -Function Get-HostedRootImportCleanupDecision, Get-HostedRootRemoveOwnedDecision
