$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-bundle.psm1') -Force

$contract = Get-HostedCapabilityCuaBundleContract
if ($contract.ReleaseTag -cne 'nightly-cua-driver-rs-v0.30.5-nightly.20260929.36522098176' -or
    $contract.ArchiveName -cne 'cua-driver-rs-0.30.5-nightly.20260929.36522098176-windows-x86_64-binary.zip' -or
    $contract.ArchiveBytes -ne 30771274 -or
    $contract.ArchiveSHA256 -cne '9b14d038b9c297dff8b53c063d5b60e09f96cc1c1b27eec37b14bc29deb1662a' -or
    $contract.DownloadUri -cne ('https://github.com/trycua/cua/releases/download/' + $contract.ReleaseTag + '/' + $contract.ArchiveName)) {
    throw 'Pinned guest CUA release contract changed'
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ticket569-bundle-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $fixture = Join-Path $root 'fixture.zip'
    $bytes = [Text.Encoding]::UTF8.GetBytes('bounded archive fixture')
    [IO.File]::WriteAllBytes($fixture, $bytes)
    $validHash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
    if (!(Test-HostedCapabilityArchiveFile -Path $fixture -ExpectedBytes $bytes.Length -ExpectedSHA256 $validHash)) {
        throw 'Archive preflight rejected exact byte count and SHA-256'
    }
    if (Test-HostedCapabilityArchiveFile -Path $fixture -ExpectedBytes ($bytes.Length + 1) -ExpectedSHA256 $validHash) {
        throw 'Archive preflight accepted a mismatched byte count'
    }
    if (Test-HostedCapabilityArchiveFile -Path $fixture -ExpectedBytes $bytes.Length -ExpectedSHA256 ('0' * 64)) {
        throw 'Archive preflight accepted a mismatched SHA-256'
    }

    $binaryDirectory = Join-Path $root 'bin'
    New-Item -ItemType Directory -Path $binaryDirectory | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $binaryDirectory 'rdpilot-bridge.exe'), [byte[]](1,2,3))
    $archiveDestination = Join-Path $root 'pre-j2-archive'
    $failed = $false
    try {
        Initialize-HostedCapabilityCuaArchive -DestinationDirectory $archiveDestination -SourceSHA ('a' * 40) -DownloadAction {
            param($uri, $destination, $expectedBytes)
            [IO.File]::Copy($fixture, $destination)
        } | Out-Null
    } catch { $failed = $true }
    if (!$failed -or (Test-Path -LiteralPath $archiveDestination)) {
        throw 'Invalid pinned archive did not fail closed and remove the pre-J+2 archive directory'
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

$owner = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-session-owner.ps1') -Raw
$prompt = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted_cua_prompt.py') -Raw
$supervisor = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability-supervisor.ps1') -Raw
$workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\.github\workflows\hosted-capability.yml') -Raw
$build = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'build-hosted-cua.ps1') -Raw
if (!$owner.Contains('bundle_path = `"$escapedBundle`"') -or
    !$owner.Contains('CuaVersion "+$cuaContract.ReleaseTag') -or
    !$owner.Contains('CuaAutoDownload no') -or
    !$owner.Contains('$envMap[''RDPILOT_BUNDLE_PATH'']=[IO.Path]::GetFullPath($bundlePath)') -or
    !$prompt.Contains('"APPDATA": str(private / "appdata")') -or
    !$supervisor.Contains('Test-HostedCapabilityArchiveFile -Path $cuaArchivePath') -or
    !$supervisor.Contains("Write-HostedCapabilityLedgerEvent -Ledger `$ledger -Event @{phase='process';operation='pinned-rdpilot-guest-bundle-verified'") -or
    !$supervisor.Contains("Join-Path `$EvidenceDirectory 'rdpilot-guest-bundle.json'") -or
    $workflow.IndexOf('Fetch and verify exact CUA guest archive before J+2') -lt 0 -or
    $workflow.IndexOf('Fetch and verify exact CUA guest archive before J+2') -ge $workflow.IndexOf('Enforce the shared J+2 non-build preparation gate') -or
    !$build.Contains('Initialize-HostedCapabilityCuaBundle -BinaryDirectory $bin -SourceSHA $expectedSha -PreparedArchivePath')) {
    throw 'Session-owner and Python MCP clients must use the isolated pinned bundle/configuration paths'
}

Write-Output 'hosted capability pinned CUA bundle gates passed (runtime compatibility remains untested)'
