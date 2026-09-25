[CmdletBinding()]
param(
    [ValidateSet('system','suite')][string]$SKU = 'system',
    [Parameter(Mandatory)][string]$SignedInputManifest,
    [string]$OutputDirectory,
    [switch]$RequireSignedInputs
)

$ErrorActionPreference = 'Stop'
if (-not $RequireSignedInputs) {
    Write-Warning 'Building with unsigned machine inputs for local validation only; this does not prove trusted update or release readiness.'
}
$msiRoot = $PSScriptRoot
$repoRoot = [IO.Path]::GetFullPath((Join-Path $msiRoot '..\..\..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'release\machine' }
function Fail([string]$Message) { throw "Machine MSI build failed: $Message" }
function Get-PeMachine([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 256 -or [BitConverter]::ToUInt16($bytes, 0) -ne 0x5A4D) { Fail "$Path is not a PE file" }
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    return [BitConverter]::ToUInt16($bytes, $offset + 4)
}
function Assert-Signed([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') { Fail "release input is not Authenticode signed: $Path ($($signature.Status))" }
}
function Get-ExactProperty($Object, [string[]]$Names, [string]$Label) {
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if (($actual -join ',') -ne ($expected -join ',')) { Fail "$Label fields are '$($actual -join ',')', expected '$($expected -join ',')'" }
}
$manifestPath = [IO.Path]::GetFullPath($SignedInputManifest)
if (-not (Test-Path -LiteralPath $manifestPath)) { Fail "missing signed-input manifest $manifestPath" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$expectedManifestFields = if ($SKU -eq 'suite') { @('schema','sku','packageRelease','commit','components','appBuild') } else { @('schema','sku','packageRelease','commit','components') }
Get-ExactProperty $manifest $expectedManifestFields 'manifest'
if ($manifest.schema -ne 'go-mapi-machine-signed-input-v1' -or $manifest.sku -ne $SKU) { Fail 'manifest schema or SKU does not match the explicit build' }
if ($manifest.commit -notmatch '^[0-9a-f]{40}$') { Fail 'manifest commit must be a full lowercase Git commit SHA' }

$identityJSON = & go run ./internal/mapi/cmd/machine-package -- $SKU ([string]$manifest.packageRelease) 2>&1
if ($LASTEXITCODE -ne 0) { Fail "production package identity rejected the release: $identityJSON" }
$identity = $identityJSON | ConvertFrom-Json
$componentMap = @{}
$manifestRoot = Split-Path -Parent $manifestPath
foreach ($component in @($manifest.components)) {
    $fields = if ($component.component -eq 'app') { @('component','version','artifacts','distribution') } else { @('component','version','artifacts') }
    Get-ExactProperty $component $fields "component $($component.component)"
    if ($component.component -notin @('service','interceptor','app') -or $componentMap.ContainsKey($component.component)) { Fail 'manifest contains an unknown or duplicate component' }
    if ($component.component -eq 'app' -and ($SKU -ne 'suite' -or $component.distribution -ne 'machine')) { Fail 'suite app input must be explicitly machine-distributed' }
    if ($component.version -notmatch '^\d+\.\d+\.\d+(?:-(?:alpha|beta|nightly)\.\d+)?$') { Fail "invalid contained version for $($component.component)" }
    $artifacts = @{}
    foreach ($artifact in @($component.artifacts)) {
        Get-ExactProperty $artifact @('architecture','filename','sha256') "$($component.component) artifact"
        if ($artifact.filename -ne [IO.Path]::GetFileName([string]$artifact.filename) -or $artifact.sha256 -notmatch '^[0-9a-f]{64}$') { Fail 'artifact filename or SHA-256 is invalid' }
        $path = Join-Path $manifestRoot $artifact.filename
        if (-not (Test-Path -LiteralPath $path)) { Fail "missing artifact $path" }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $artifact.sha256) { Fail "artifact hash mismatch: $path" }
        $expectedMachine = if ($artifact.architecture -eq 'x86') { 0x014c } elseif ($artifact.architecture -eq 'x64') { 0x8664 } else { Fail 'unsupported artifact architecture' }
        if ((Get-PeMachine $path) -ne $expectedMachine) { Fail "artifact PE machine mismatch: $path" }
        if ($RequireSignedInputs) { Assert-Signed $path }
        if ($artifacts.ContainsKey($artifact.architecture)) { Fail 'duplicate artifact architecture' }
        $artifacts[$artifact.architecture] = $path
    }
    $componentMap[$component.component] = @{ Version = [string]$component.version; Artifacts = $artifacts }
}
if ($componentMap.interceptor.Artifacts.Count -ne 2 -or -not $componentMap.interceptor.Artifacts.x86 -or -not $componentMap.interceptor.Artifacts.x64 -or $componentMap.service.Artifacts.Count -ne 1 -or -not $componentMap.service.Artifacts.x64) { Fail 'input requires x86/x64 interceptor DLLs and one x64 service executable' }
if ($SKU -eq 'system' -and $componentMap.Count -ne 2) { Fail 'system input must not contain a user app' }
if ($SKU -eq 'suite' -and ($componentMap.Count -ne 3 -or $componentMap.app.Artifacts.Count -ne 1 -or -not $componentMap.app.Artifacts.x64 -or $componentMap.app.Artifacts.x64 -notmatch 'go-mapi-machine\.exe$')) { Fail 'suite input requires a distinct machine-distributed x64 app executable' }

if ($SKU -eq 'suite') {
    Get-ExactProperty $manifest.appBuild @('manifest','sha256','unsignedSha256') 'suite app build evidence'
    if ($manifest.appBuild.manifest -ne 'app-artifacts.json' -or
        $manifest.appBuild.sha256 -notmatch '^[0-9a-f]{64}$' -or
        $manifest.appBuild.unsignedSha256 -notmatch '^[0-9a-f]{64}$') { Fail 'suite app build evidence fields are invalid' }
    $appManifestPath = Join-Path $manifestRoot 'app-artifacts.json'
    if (-not (Test-Path -LiteralPath $appManifestPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $appManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.appBuild.sha256) { Fail 'suite app build manifest is missing or its hash differs' }
    $appBuild = Get-Content -LiteralPath $appManifestPath -Raw | ConvertFrom-Json
    Get-ExactProperty $appBuild @('schema','component','version','queueProtocol','requires','artifact','source','build','distribution') 'suite app build manifest'
    Get-ExactProperty $appBuild.source @('commit') 'suite app source'
    Get-ExactProperty $appBuild.build @('command','go','wails','node','npm') 'suite app build command'
    Get-ExactProperty $appBuild.artifact @('filename','sha256','peProductVersion') 'suite unsigned app artifact'
    if ($appBuild.schema -ne 'go-mapi-app-artifacts-v2' -or $appBuild.component -ne 'app' -or
        $appBuild.distribution -ne 'machine' -or $appBuild.artifact.filename -ne 'go-mapi-machine.exe' -or
        $appBuild.artifact.sha256 -ne $manifest.appBuild.unsignedSha256 -or
        $appBuild.version -ne $componentMap.app.Version -or $appBuild.artifact.peProductVersion -ne $componentMap.app.Version -or
        $appBuild.source.commit -ne $manifest.commit -or
        $appBuild.build.command -ne 'scripts/build-wails.ps1 -Release -MachineDistribution -UseEnvironmentCredentials') {
        Fail 'suite app source, distribution, version, or unsigned hash provenance differs from signed inputs'
    }
    foreach ($tool in @('go','wails','node','npm')) {
        if ([string]::IsNullOrWhiteSpace($appBuild.build.$tool)) { Fail "suite app $tool build tool version is missing" }
    }
    $appContract = (Get-Content (Join-Path $repoRoot 'components.json') -Raw | ConvertFrom-Json).components.app
    if ($appBuild.queueProtocol -ne $appContract.queueProtocol -or
        $appBuild.requires.component -ne $appContract.requires.component -or
        $appBuild.requires.minInclusive -ne $appContract.requires.minInclusive -or
        [string]$appBuild.requires.maxExclusive -ne [string]$appContract.requires.maxExclusive) { Fail 'suite app compatibility declaration differs from source contract' }
    $signedVersion = (Get-Item -LiteralPath $componentMap.app.Artifacts.x64).VersionInfo
    if ([string]$signedVersion.ProductVersion -ne $componentMap.app.Version -or
        [string]$signedVersion.FileVersion -ne $componentMap.app.Version) { Fail 'signed suite app PE version differs from source build' }
}

$components = Get-Content (Join-Path $repoRoot 'components.json') -Raw | ConvertFrom-Json
$contract = $components.machinePackages.$SKU
$expectedUpgradeCode = if ($SKU -eq 'system') { 'B3C97B33-3F10-47CA-9FA7-24EE3B75E325' } else { '2E050A24-94A2-4FC9-B176-C5CCC1225FE6' }
$foreignSKU = if ($SKU -eq 'system') { 'suite' } else { 'system' }
$foreignContract = $components.machinePackages.$foreignSKU
$expectedForeignUpgradeCode = if ($SKU -eq 'system') { '2E050A24-94A2-4FC9-B176-C5CCC1225FE6' } else { 'B3C97B33-3F10-47CA-9FA7-24EE3B75E325' }
$expectedComponents = if ($SKU -eq 'system') { 'service,interceptor' } else { 'service,interceptor,app' }
if ($contract.upgradeCode -ne $expectedUpgradeCode -or ($contract.includedComponents -join ',') -ne $expectedComponents) { Fail "components.json $SKU package contract is invalid" }
if ($foreignContract.upgradeCode -ne $expectedForeignUpgradeCode) { Fail "components.json $foreignSKU package contract is invalid" }
$requiredAppMin = [string]$components.components.interceptor.requires.minInclusive
$requiredAppMax = [string]$components.components.interceptor.requires.maxExclusive

$customProject = Join-Path $msiRoot 'customaction\GoMapi.AdminCustomActions.csproj'
dotnet build $customProject --configuration Release
if ($LASTEXITCODE -ne 0) { Fail 'custom action build failed' }
$customBinary = Join-Path $msiRoot 'customaction\bin\x64\Release\net48\GoMapi.AdminCustomActions.CA.dll'
if (-not (Test-Path $customBinary)) { Fail "missing packaged DTF custom action $customBinary" }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$project = Join-Path $msiRoot $(if ($SKU -eq 'system') { 'GoMapi.AdminInstaller.wixproj' } else { 'GoMapi.SuiteInstaller.wixproj' })
$arguments = @('build', $project, '--configuration', 'Release',
    "-p:MsiProductVersion=$($identity.productVersion)", "-p:PackageRelease=$($identity.release)",
    "-p:ProductCode=$($identity.productCode)", "-p:UpgradeCode=$($contract.upgradeCode)",
    "-p:ForeignUpgradeCode=$($foreignContract.upgradeCode)",
    "-p:ServiceVersion=$($componentMap.service.Version)", "-p:InterceptorVersion=$($componentMap.interceptor.Version)",
    "-p:RequiredAppMin=$requiredAppMin", "-p:RequiredAppMax=$requiredAppMax", "-p:SourceService=$($componentMap.service.Artifacts.x64)",
    "-p:SourceX64=$($componentMap.interceptor.Artifacts.x64)", "-p:SourceX86=$($componentMap.interceptor.Artifacts.x86)",
    "-p:CustomActionBinary=$customBinary", "-p:OutputName=$([IO.Path]::GetFileNameWithoutExtension($identity.assetName))",
    "-p:OutputPath=$OutputDirectory")
if ($SKU -eq 'suite') {
    $arguments += "-p:AppVersion=$($componentMap.app.Version)"
    $arguments += "-p:SourceApp=$($componentMap.app.Artifacts.x64)"
}
dotnet @arguments
if ($LASTEXITCODE -ne 0) { Fail 'WiX MSI build failed' }
$msi = Get-ChildItem $OutputDirectory -Filter $identity.assetName -Recurse | Select-Object -First 1
if (-not $msi) { Fail "WiX build did not produce immutable asset $($identity.assetName)" }
Write-Host "Built $SKU MSI: $($msi.FullName)"
