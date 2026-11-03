$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function RejectMessage([scriptblock]$Action, [string]$Pattern, [string]$What) {
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "$What failed for the wrong reason: $($_.Exception.Message)" }
        return
    }
    throw "Expected failure: $What"
}

$msiRoot = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([IO.Path]::GetTempPath()) ('go-mapi-msi-identity-' + [guid]::NewGuid().ToString('N'))
$pwsh = (Get-Process -Id $PID).Path
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $emitter = Join-Path $temp 'fake-go.ps1'
    # A native child is essential: its stderr must encounter the entrypoint's
    # redirection, just as cold-cache go run dependency progress does.
    @'
param([string]$SKU, [string]$Mode)
[Console]::Error.WriteLine('go: downloading example.invalid/dependency v1.0.0')
if ($Mode -eq 'malformed') {
    [Console]::Out.WriteLine('invalid identity JSON')
} else {
    [Console]::Out.WriteLine('{"assetName":"go-mapi-' + $SKU + '-5.0.1-alpha.4-x64.msi"}')
}
if ($Mode -eq 'nonzero') { exit 9 }
'@ | Set-Content -LiteralPath $emitter
    function go {
        # PowerShell consumes the function-call -- argument separator.
        if (($args[0..1] -join ' ') -cne 'run ./internal/mapi/cmd/machine-package' -or
            $args[3] -cne '5.0.1-alpha.4') { throw "unexpected package identity invocation: $($args -join ' | ')" }
        & $pwsh -NoProfile -File $emitter -SKU $args[2] -Mode $mode
        $global:LASTEXITCODE = $LASTEXITCODE
    }

    $manifestPath = Join-Path $temp 'signed-input.json'
    $dummyMsi = Join-Path $temp 'wrong-name.msi'
    Set-Content -LiteralPath $dummyMsi -Value 'not an MSI'
    foreach ($sku in @('system','suite')) {
        $manifest = [ordered]@{
            schema = 'go-mapi-machine-signed-input-v1'; sku = $sku
            packageRelease = '5.0.1-alpha.4'; commit = ('a' * 40)
            components = @(@{ component='unknown'; version='5.0.1-alpha.4'; artifacts=@() })
        }
        if ($sku -eq 'suite') { $manifest.appBuild = @{} }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath
        foreach ($mode in @('success','nonzero','malformed')) {
            $buildPattern = switch ($mode) {
                success { 'manifest contains an unknown or duplicate component' }
                nonzero { 'production package identity rejected the release' }
                malformed { 'Conversion from JSON failed' }
            }
            $verifyPattern = if ($mode -eq 'success') { "MSI filename is not the immutable $sku asset name go-mapi-$sku-5.0.1-alpha.4-x64.msi" } else { $buildPattern }
            # These intentional refusals prove JSON admission without reaching
            # PE inspection, signing, .NET, or Windows Installer COM.
            RejectMessage { & (Join-Path $msiRoot 'build.ps1') -SKU $sku -SignedInputManifest $manifestPath -RequireSignedInputs } $buildPattern "$sku build with $mode identity"
            RejectMessage { & (Join-Path $msiRoot 'verify.ps1') -SKU $sku -MsiPath $dummyMsi -PackageRelease '5.0.1-alpha.4' } $verifyPattern "$sku verification with $mode identity"
        }
    }
    Write-Host 'MSI identity stream and failure contracts passed'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
