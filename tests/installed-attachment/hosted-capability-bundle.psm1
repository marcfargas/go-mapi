Set-StrictMode -Version Latest

$script:HostedCuaReleaseTag = 'nightly-cua-driver-rs-v0.30.5-nightly.20260929.36522098176'
$script:HostedCuaArchiveName = 'cua-driver-rs-0.30.5-nightly.20260929.36522098176-windows-x86_64-binary.zip'
$script:HostedCuaArchiveBytes = 30771274L
$script:HostedCuaArchiveSHA256 = '9b14d038b9c297dff8b53c063d5b60e09f96cc1c1b27eec37b14bc29deb1662a'
$script:HostedCuaReleaseBase = 'https://github.com/trycua/cua/releases/download/'

function Get-HostedCapabilityCuaBundleContract {
    [pscustomobject]@{
        ReleaseTag = $script:HostedCuaReleaseTag
        ArchiveName = $script:HostedCuaArchiveName
        ArchiveBytes = $script:HostedCuaArchiveBytes
        ArchiveSHA256 = $script:HostedCuaArchiveSHA256
        DownloadUri = "$($script:HostedCuaReleaseBase)$($script:HostedCuaReleaseTag)/$($script:HostedCuaArchiveName)"
    }
}

function Invoke-HostedCapabilityCuaDownload {
    param(
        [Parameter(Mandatory)][uri] $Uri,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][long] $ExpectedBytes,
        [ValidateRange(1, 180)][int] $TimeoutSeconds = 60
    )
    if ($Uri.Scheme -cne 'https') { throw 'Pinned CUA download requires HTTPS' }
    $client = [Net.Http.HttpClient]::new()
    $cancel = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    $response = $null
    $downloadStream = $null
    $output = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancel.Token).GetAwaiter().GetResult()
        if (!$response.IsSuccessStatusCode) { throw 'Pinned CUA release download returned a non-success status' }
        if ($null -eq $response.Content.Headers.ContentLength -or [long]$response.Content.Headers.ContentLength -ne $ExpectedBytes) {
            throw 'Pinned CUA release size header did not match the audited archive size'
        }
        $downloadStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] (1MB)
        $total = 0L
        while (($read = $downloadStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $cancel.Token.ThrowIfCancellationRequested()
            $total += $read
            if ($total -gt $ExpectedBytes -or $watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw 'Pinned CUA release download exceeded its byte or elapsed-time bound'
            }
            $output.Write($buffer, 0, $read)
        }
        $output.Flush($true)
        if ($total -ne $ExpectedBytes) { throw 'Pinned CUA release download was truncated' }
    } finally {
        if ($output) { $output.Dispose() }
        if ($downloadStream) { $downloadStream.Dispose() }
        if ($response) { $response.Dispose() }
        $cancel.Dispose()
        $client.Dispose()
    }
}

function Test-HostedCapabilityArchiveFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][long] $ExpectedBytes,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $ExpectedSHA256
    )
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -ne $ExpectedBytes) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.Equals($ExpectedSHA256, [StringComparison]::OrdinalIgnoreCase)
}

function Initialize-HostedCapabilityCuaArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $DestinationDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string] $SourceSHA,
        [ValidateRange(1, 60)][int] $TimeoutSeconds = 60,
        [scriptblock] $DownloadAction
    )
    $contract = Get-HostedCapabilityCuaBundleContract
    if (Test-Path -LiteralPath $DestinationDirectory) { throw 'Pinned CUA download destination already exists' }
    New-Item -ItemType Directory -Path $DestinationDirectory | Out-Null
    $partial = Join-Path $DestinationDirectory ($contract.ArchiveName + '.partial')
    $archive = Join-Path $DestinationDirectory $contract.ArchiveName
    $receiptPath = Join-Path $DestinationDirectory 'guest-cua-archive.json'
    try {
        if ($DownloadAction) {
            & $DownloadAction $contract.DownloadUri $partial $contract.ArchiveBytes
        } else {
            Invoke-HostedCapabilityCuaDownload -Uri $contract.DownloadUri -Destination $partial -ExpectedBytes $contract.ArchiveBytes -TimeoutSeconds $TimeoutSeconds
        }
        if (!(Test-HostedCapabilityArchiveFile -Path $partial -ExpectedBytes $contract.ArchiveBytes -ExpectedSHA256 $contract.ArchiveSHA256)) {
            throw 'Pinned CUA archive did not match the audited byte count and SHA-256'
        }
        Move-Item -LiteralPath $partial -Destination $archive
        $receipt = [ordered]@{
            schema = 'ticket569-cua-archive-input-v1'
            sourceSHA = $SourceSHA.ToLowerInvariant()
            releaseTag = $contract.ReleaseTag
            archiveName = $contract.ArchiveName
            archiveBytes = $contract.ArchiveBytes
            archiveSHA256 = $contract.ArchiveSHA256
        }
        [IO.File]::WriteAllText($receiptPath, (ConvertTo-Json -InputObject $receipt -Depth 4) + "`n", [Text.UTF8Encoding]::new($false))
        [pscustomobject]@{ ArchivePath = $archive; ReceiptPath = $receiptPath; Receipt = $receipt }
    } catch {
        Remove-Item -LiteralPath $DestinationDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Initialize-HostedCapabilityCuaBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $BinaryDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string] $SourceSHA,
        [Parameter(Mandatory)][string] $PreparedArchivePath,
        [Parameter(Mandatory)][string] $PreparedReceiptPath
    )
    $contract = Get-HostedCapabilityCuaBundleContract
    $bridge = Join-Path $BinaryDirectory 'rdpilot-bridge.exe'
    if (!(Test-Path -LiteralPath $bridge -PathType Leaf)) { throw 'Locally built pinned rdpilot bridge is missing' }
    $bundle = Join-Path $BinaryDirectory 'guest-bundle'
    if (Test-Path -LiteralPath $bundle) { throw 'Pinned CUA bundle destination already exists' }
    New-Item -ItemType Directory -Path $bundle | Out-Null
    $archive = Join-Path $bundle $contract.ArchiveName
    try {
        if (!(Test-Path -LiteralPath $PreparedReceiptPath -PathType Leaf)) { throw 'Pre-J+2 pinned CUA archive receipt is missing' }
        try { $inputReceipt = Get-Content -LiteralPath $PreparedReceiptPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Pre-J+2 pinned CUA archive receipt is malformed' }
        if ($inputReceipt.schema -cne 'ticket569-cua-archive-input-v1' -or
            $inputReceipt.sourceSHA -cne $SourceSHA.ToLowerInvariant() -or
            $inputReceipt.releaseTag -cne $contract.ReleaseTag -or
            $inputReceipt.archiveName -cne $contract.ArchiveName -or
            [long]$inputReceipt.archiveBytes -ne $contract.ArchiveBytes -or
            $inputReceipt.archiveSHA256 -cne $contract.ArchiveSHA256 -or
            !(Test-HostedCapabilityArchiveFile -Path $PreparedArchivePath -ExpectedBytes $contract.ArchiveBytes -ExpectedSHA256 $contract.ArchiveSHA256)) {
            throw 'Pre-J+2 pinned CUA archive input does not match the audited release contract'
        }
        Copy-Item -LiteralPath $PreparedArchivePath -Destination $archive
        $hash = $contract.ArchiveSHA256
        Copy-Item -LiteralPath $bridge -Destination (Join-Path $bundle 'rdpilot-bridge.exe')
        $bridgeHash = (Get-FileHash -LiteralPath (Join-Path $bundle 'rdpilot-bridge.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
        $receipt = [ordered]@{
            schema = 'ticket569-rdpilot-guest-bundle-v1'
            rdpilotSourceCommit = '8f799dd1e37422a8966833a08e4ec279f645ec58'
            sourceSHA = $SourceSHA.ToLowerInvariant()
            cuaReleaseTag = $contract.ReleaseTag
            cuaArchive = $contract.ArchiveName
            cuaArchiveBytes = $contract.ArchiveBytes
            cuaArchiveSHA256 = $hash
            bridgeRelativePath = 'rdpilot-bridge.exe'
            bridgeBytes = (Get-Item -LiteralPath (Join-Path $bundle 'rdpilot-bridge.exe')).Length
            bridgeSHA256 = $bridgeHash
        }
        $receiptPath = Join-Path $bundle 'guest-bundle.json'
        [IO.File]::WriteAllText($receiptPath, (ConvertTo-Json -InputObject $receipt -Depth 4) + "`n", [Text.UTF8Encoding]::new($false))
        [pscustomobject]@{ BundlePath = $bundle; ReceiptPath = $receiptPath; Receipt = $receipt }
    } catch {
        Remove-Item -LiteralPath $bundle -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

Export-ModuleMember -Function Get-HostedCapabilityCuaBundleContract, Invoke-HostedCapabilityCuaDownload, Test-HostedCapabilityArchiveFile, Initialize-HostedCapabilityCuaArchive, Initialize-HostedCapabilityCuaBundle
