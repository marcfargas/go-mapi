$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SendToObservation.ps1')

function Assert([bool]$Condition, [string]$Description) {
    if (-not $Condition) { throw $Description }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) "send-to-observation-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $expectedName = 'owned-probe.txt'
    $expectedContent = "owned probe content`n"
    $copy = Join-Path $root $expectedName
    Set-Content -LiteralPath $copy -Value $expectedContent -NoNewline
    $old = Join-Path $root 'old.json'
    $unrelated = Join-Path $root 'unrelated.json'
    $matching = Join-Path $root 'matching.json'
    $payload = @{ attachments = @(@{ filename = $expectedName; path = $copy }) } | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $old -Value $payload
    Assert (-not (Find-MatchingQueueDescriptor -QueueDir $root -BeforeNames @('old.json') -ExpectedName $expectedName -ExpectedContent $expectedContent)) 'pre-existing descriptor matched'
    $otherPayload = @{ attachments = @(@{ filename = 'other.txt'; path = $copy }) } | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $unrelated -Value $otherPayload
    Assert (-not (Find-MatchingQueueDescriptor -QueueDir $root -BeforeNames @('old.json') -ExpectedName $expectedName -ExpectedContent $expectedContent)) 'unrelated descriptor matched'
    Set-Content -LiteralPath $matching -Value $payload
    Assert ((Find-MatchingQueueDescriptor -QueueDir $root -BeforeNames @('old.json') -ExpectedName $expectedName -ExpectedContent $expectedContent) -eq $matching) 'matching descriptor missed'
    Assert (Test-ExplicitAffirmative 'y') 'yes confirmation rejected'
    Assert (-not (Test-ExplicitAffirmative '')) 'blank confirmation accepted'
    Assert (-not (Test-ExplicitAffirmative 'n')) 'negative confirmation accepted'
    # NoHumanPrompts returns a blank response in the runner; dependent rows are NOT RUN.
    Assert (-not (Test-ExplicitAffirmative $null)) 'skipped confirmation accepted'
    Assert ((Get-SmokeVerdict -Results @{ mapi = 'NOT RUN'; queue = 'NOT RUN'; gmail = 'NOT RUN' } -RequiredSteps @('mapi','queue','gmail')) -eq 'INCOMPLETE') 'skipped observations passed'
    Assert ((Get-SmokeVerdict -Results @{ mapi = 'PASS'; queue = 'FAIL'; gmail = 'PASS' } -RequiredSteps @('mapi','queue','gmail')) -eq 'FAIL') 'failed queue passed'
    Assert ((Get-SmokeVerdict -Results @{ mapi = 'PASS'; queue = 'PASS'; gmail = 'PASS' } -RequiredSteps @('mapi','queue','gmail')) -eq 'PASS') 'complete observations failed'
    Write-Host 'Send-To observation checks passed'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
