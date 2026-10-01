# Shared by the legacy smoke runner and its focused observation checks.
function Test-ExplicitAffirmative([string]$Response) {
    return $Response -match '^(?i:y|yes)$'
}

function Get-SmokeVerdict {
    param([hashtable]$Results, [string[]]$RequiredSteps)
    $outcomes = @($RequiredSteps | ForEach-Object { [string]$Results[$_] })
    if (@($outcomes | Where-Object { $_ -match '^NOT RUN' -or -not $_ }).Count -gt 0) { return 'INCOMPLETE' }
    if (@($outcomes | Where-Object { $_ -notmatch '^PASS' }).Count -gt 0) { return 'FAIL' }
    return 'PASS'
}

function Find-MatchingQueueDescriptor {
    param(
        [string]$QueueDir,
        [string[]]$BeforeNames,
        [string]$ExpectedName,
        [string]$ExpectedContent
    )
    if (-not (Test-Path -LiteralPath $QueueDir)) { return $null }
    foreach ($descriptor in Get-ChildItem -LiteralPath $QueueDir -Filter '*.json' -File) {
        if ($descriptor.Name -in $BeforeNames) { continue }
        try { $message = Get-Content -LiteralPath $descriptor.FullName -Raw | ConvertFrom-Json } catch { continue }
        foreach ($attachment in @($message.attachments)) {
            if ($attachment.filename -cne $ExpectedName) { continue }
            $copy = [string]$attachment.path
            if (-not $copy -or -not (Test-Path -LiteralPath $copy -PathType Leaf)) { continue }
            if ((Get-Content -LiteralPath $copy -Raw) -cne $ExpectedContent) { continue }
            return $descriptor.FullName
        }
    }
    return $null
}
