[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FixtureSpecification,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$MetadataOrigin = 'https://localhost:18453',
    [string]$ArtifactOrigin = 'https://localhost:18453/releases/download/',
    [int]$CheckIntervalSeconds = 60,
    [switch]$ValidationTimers
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'ServiceBuilds.ps1')
$manifestPath=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) 'service-builds.json'
if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force -ErrorAction Stop }
$specification=ReadFixtureSpecification $FixtureSpecification
$settings=Get-ServiceBuildSettings $specification $MetadataOrigin $ArtifactOrigin $CheckIntervalSeconds ([bool]$ValidationTimers)
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
$commit=(& git -C $repo rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot identify service source commit' }
$result=New-ServiceBuilds $repo $OutputDirectory $specification $commit $settings
Write-Host "Built unsigned service fixtures: $($result.path)"
