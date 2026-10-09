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

Export-ModuleMember -Function Get-HostedRootImportCleanupDecision
