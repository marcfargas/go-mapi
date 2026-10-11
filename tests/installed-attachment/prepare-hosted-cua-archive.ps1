[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string] $SourceSHA
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-bundle.psm1') -Force
foreach($name in @('HOSTED_CAPABILITY_JOB_STARTED_QPC','HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY','HOSTED_CAPABILITY_JOB_STARTED_BOOT','GITHUB_SHA','GITHUB_ENV','RUNNER_TEMP')){
    if([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))){throw "Pre-J+2 CUA archive preparation requires $name"}
}
if($SourceSHA.ToLowerInvariant() -cne $env:GITHUB_SHA.ToLowerInvariant()) { throw 'Pinned CUA archive preparation source differs from the immutable workflow event SHA' }
$start=[long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC
$frequency=[long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY
$boot=[string]$env:HOSTED_CAPABILITY_JOB_STARTED_BOOT
$before=Get-HostedCapabilityClockSample
$clock=Test-HostedCapabilityClock -ExpectedBootMarker $boot -ObservedBootMarker $before.bootMarker -ExpectedFrequency $frequency -ObservedFrequency $before.frequency -JobStartCounter $start -CurrentCounter $before.counter
if(!$clock.valid){throw 'Pre-J+2 CUA archive preparation refused an invalid job clock'}
$j2=$start+2L*60L*$frequency
$secondsRemaining=[int][Math]::Floor(($j2-$before.counter)/[double]$frequency)
$downloadTimeout=[Math]::Min(60,$secondsRemaining)
if($downloadTimeout -lt 1 -or $before.counter -ge $j2){throw 'Pinned CUA archive download cannot fit before the shared J+2 preparation gate'}
$destination=Join-Path $env:RUNNER_TEMP ("ticket569-cua-input-"+$RunId)
$prepared=$null
try {
    $prepared=Initialize-HostedCapabilityCuaArchive -DestinationDirectory $destination -SourceSHA $SourceSHA -TimeoutSeconds $downloadTimeout
    $after=Get-HostedCapabilityClockSample
    $clock=Test-HostedCapabilityClock -ExpectedBootMarker $boot -ObservedBootMarker $after.bootMarker -ExpectedFrequency $frequency -ObservedFrequency $after.frequency -JobStartCounter $start -CurrentCounter $after.counter
    if(!$clock.valid -or $after.counter -ge $j2){throw 'Pinned CUA archive download did not complete inside the shared J+2 phase'}
    "HOSTED_CUA_ARCHIVE_PATH=$($prepared.ArchivePath)" | Add-Content -LiteralPath $env:GITHUB_ENV -Encoding utf8
    "HOSTED_CUA_ARCHIVE_RECEIPT_PATH=$($prepared.ReceiptPath)" | Add-Content -LiteralPath $env:GITHUB_ENV -Encoding utf8
    Write-Output ("PINNED_CUA_ARCHIVE_SHA256="+$prepared.Receipt.archiveSHA256)
    Write-Output ("PINNED_CUA_ARCHIVE_BYTES="+$prepared.Receipt.archiveBytes)
    Write-Output 'PINNED_CUA_ARCHIVE_PREPARATION_COMPLETED_BEFORE_J_PLUS_2=true'
} catch {
    Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
    throw
}
