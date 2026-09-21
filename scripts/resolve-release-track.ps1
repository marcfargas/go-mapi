[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('development', 'stable')][string]$ExpectedTrack
)

$ErrorActionPreference = 'Stop'
$pattern = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
if ($Version -notmatch $pattern -or $Version -eq '0.0.0-dev') {
    throw "Version is not canonical release SemVer: $Version"
}

$major = [uint64]$Matches[1]
$minor = [uint64]$Matches[2]
$patch = [uint64]$Matches[3]
$prerelease = [string]$Matches[4]
if ($prerelease) {
    foreach ($identifier in $prerelease.Split('.')) {
        if ($identifier -match '^[0-9]+$' -and $identifier.Length -gt 1 -and $identifier.StartsWith('0')) {
            throw "Version has a non-canonical numeric prerelease identifier: $Version"
        }
    }
}

$legacyStable = $major -eq 3 -and $minor -eq 0
$track = $null
if (-not $prerelease -and (($major % 2) -eq 0 -or $legacyStable)) {
    $track = 'stable'
} elseif ($prerelease -and (($major % 2) -eq 1) -and -not $legacyStable) {
    $label = $prerelease.Split('.')[0]
    if ($label -in @('alpha', 'beta', 'nightly')) { $track = 'development' }
}
if (-not $track) { throw "Version does not belong to a go-mapi release line: $Version" }
if ($ExpectedTrack -and $track -ne $ExpectedTrack) {
    throw "Version $Version is $track, expected $ExpectedTrack"
}

$promotionVersion = if ($track -eq 'development') { '{0}.{1}.{2}' -f ($major + 1), $minor, $patch } else { $Version.Split('+')[0] }
[pscustomobject]@{ version = $Version; track = $track; promotionVersion = $promotionVersion }

if ($env:GITHUB_OUTPUT) {
    "track=$track" | Out-File $env:GITHUB_OUTPUT -Encoding ascii -Append
    "promotion_version=$promotionVersion" | Out-File $env:GITHUB_OUTPUT -Encoding ascii -Append
}
