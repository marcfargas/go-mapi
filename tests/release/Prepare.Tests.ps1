# Host-only staging checks. Inert files never enter Windows Installer.
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('go-mapi-reuse-staging-'+[guid]::NewGuid().ToString('N'))
function WriteJson([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false)) }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Refuses([scriptblock]$Action) {
    $refused = $false
    try { & $Action | Out-Null } catch { $refused = $true }
    if (!$refused) { throw 'Invalid staging input was accepted' }
}
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    foreach ($name in @('prior','current')) {
        $root = Join-Path $fixture $name
        New-Item -ItemType Directory -Path $root | Out-Null
        $version = if ($name -eq 'prior') {'3.2.0-beta.2'} else {'3.2.0-beta.3'}
        $package = Join-Path $root "go-mapi-suite-$version-x64.msi"
        [IO.File]::WriteAllText($package, "inert-$version")
        $manifest = "go-mapi-suite-$version.manifest.json"
        WriteJson (Join-Path $root $manifest) @{sku='suite'; packageRelease=$version}
        $release = @{schema='go-mapi-release-v1'; version=$version; commit=('a'*40); runId='123'; runAttempt='1'; system=@{version='3.2.0-beta.2'; commit=('b'*40); reused=($name -eq 'current')}; suite=@{sequence=$(if ($name -eq 'prior') {202} else {203}); upgradeCode='same-suite-family'; artifact=@{file=[IO.Path]::GetFileName($package); sha256=(Hash $package); size=(Get-Item $package).Length}}}
        if ($name -eq 'current') { $release.system.manifestSha256 = Hash (Join-Path $fixture 'prior/release.json') }
        WriteJson (Join-Path $root 'release.json') $release
        WriteJson (Join-Path $root "suite-$version.validation.json") @{commit=$release.commit; runId='123'; runAttempt='1'; msi=@{sha256=(Hash $package)}; signedInputManifest=@{file=$manifest; sha256=(Hash (Join-Path $root $manifest))}}
        [IO.File]::WriteAllText((Join-Path $root 'not-selected.secret'), 'inert but must not be shared')
    }
    $parameters = @{PriorBundleDirectory=(Join-Path $fixture 'prior'); BundleDirectory=(Join-Path $fixture 'current'); PriorMachineReceiptsDirectory=(Join-Path $fixture 'prior'); MachineReceiptsDirectory=(Join-Path $fixture 'current'); OutputDirectory=(Join-Path $fixture 'selected')}
    $result = & (Join-Path $PSScriptRoot 'Prepare-ReusedSuite.ps1') @parameters
    $selected = @(Get-ChildItem -LiteralPath $result.InputDirectory -File -Recurse)
    if ($result.ScriptPath -cne 'Test-ReusedSuite.ps1' -or $selected.Count -ne 9 -or @($selected | Where-Object Name -like '*.secret').Count) { throw 'Guest selected-input boundary differs' }
    Refuses { & (Join-Path $PSScriptRoot 'Prepare-ReusedSuite.ps1') @parameters }
    $parameters.OutputDirectory = Join-Path $fixture 'tampered'
    Add-Content -LiteralPath (Join-Path $fixture 'current/go-mapi-suite-3.2.0-beta.3-x64.msi') -Value 'tamper'
    Refuses { & (Join-Path $PSScriptRoot 'Prepare-ReusedSuite.ps1') @parameters }
    if (Test-Path -LiteralPath $parameters.OutputDirectory) { throw 'Invalid package created selected inputs' }
    [IO.File]::WriteAllText((Join-Path $fixture 'current/go-mapi-suite-3.2.0-beta.3-x64.msi'), 'inert-3.2.0-beta.3')
    Add-Content -LiteralPath (Join-Path $fixture 'prior/release.json') -Value ' '
    Refuses { & (Join-Path $PSScriptRoot 'Prepare-ReusedSuite.ps1') @parameters }
    if (Test-Path -LiteralPath $parameters.OutputDirectory) { throw 'Changed original manifest pin created selected inputs' }
    Write-Host 'Reused Suite selected-input contracts passed'
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (!$resolvedFixture.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedFixture) -notlike 'go-mapi-reuse-staging-*') { throw 'Refusing unexpected fixture cleanup path' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
