[CmdletBinding()]
param(
    [ValidateSet('system')][string]$SKU = 'system',
    [Parameter(Mandatory)][string]$SignedInputManifest,
    [string]$OutputDirectory,
    [switch]$RequireSignedInputs
)

$ErrorActionPreference = 'Stop'
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
Get-ExactProperty $manifest @('schema','sku','packageRelease','commit','components') 'manifest'
if ($manifest.schema -ne 'go-mapi-machine-signed-input-v1' -or $manifest.sku -ne $SKU -or $SKU -ne 'system') { Fail 'manifest schema or SKU does not match the explicit system build' }
if ($manifest.commit -notmatch '^[0-9a-f]{40}$') { Fail 'manifest commit must be a full lowercase Git commit SHA' }

$identityJSON = & go run ./internal/mapi/cmd/machine-package -- $SKU ([string]$manifest.packageRelease) 2>&1
if ($LASTEXITCODE -ne 0) { Fail "production package identity rejected the release: $identityJSON" }
$identity = $identityJSON | ConvertFrom-Json
$componentMap = @{}
$manifestRoot = Split-Path -Parent $manifestPath
foreach ($component in @($manifest.components)) {
    Get-ExactProperty $component @('component','version','artifacts') "component $($component.component)"
    if ($component.component -notin @('service','interceptor') -or $componentMap.ContainsKey($component.component)) { Fail 'manifest must contain exactly one service and interceptor component' }
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
if ($componentMap.Count -ne 2 -or $componentMap.interceptor.Artifacts.Count -ne 2 -or -not $componentMap.interceptor.Artifacts.x86 -or -not $componentMap.interceptor.Artifacts.x64 -or $componentMap.service.Artifacts.Count -ne 1 -or -not $componentMap.service.Artifacts.x64) { Fail 'system input requires x86/x64 interceptor DLLs and one x64 service executable' }

$components = Get-Content (Join-Path $repoRoot 'components.json') -Raw | ConvertFrom-Json
$contract = $components.machinePackages.system
if ($contract.upgradeCode -ne 'B3C97B33-3F10-47CA-9FA7-24EE3B75E325' -or ($contract.includedComponents -join ',') -ne 'service,interceptor') { Fail 'components.json system package contract is invalid' }
$requiredAppMin = [string]$components.components.interceptor.requires.minInclusive

$customProject = Join-Path $msiRoot 'customaction\GoMapi.AdminCustomActions.csproj'
dotnet build $customProject --configuration Release
if ($LASTEXITCODE -ne 0) { Fail 'custom action build failed' }
$customBinary = Join-Path $msiRoot 'customaction\bin\x64\Release\net48\GoMapi.AdminCustomActions.CA.dll'
if (-not (Test-Path $customBinary)) { Fail "missing packaged DTF custom action $customBinary" }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$project = Join-Path $msiRoot 'GoMapi.AdminInstaller.wixproj'
$arguments = @('build', $project, '--configuration', 'Release',
    "-p:MsiProductVersion=$($identity.productVersion)", "-p:PackageRelease=$($identity.release)",
    "-p:ProductCode=$($identity.productCode)", "-p:UpgradeCode=$($contract.upgradeCode)",
    "-p:ServiceVersion=$($componentMap.service.Version)", "-p:InterceptorVersion=$($componentMap.interceptor.Version)",
    "-p:RequiredAppMin=$requiredAppMin", "-p:SourceService=$($componentMap.service.Artifacts.x64)",
    "-p:SourceX64=$($componentMap.interceptor.Artifacts.x64)", "-p:SourceX86=$($componentMap.interceptor.Artifacts.x86)",
    "-p:CustomActionBinary=$customBinary", "-p:OutputName=$([IO.Path]::GetFileNameWithoutExtension($identity.assetName))",
    "-p:OutputPath=$OutputDirectory")
dotnet @arguments
if ($LASTEXITCODE -ne 0) { Fail 'WiX MSI build failed' }
$msi = Get-ChildItem $OutputDirectory -Filter $identity.assetName -Recurse | Select-Object -First 1
if (-not $msi) { Fail "WiX build did not produce immutable asset $($identity.assetName)" }
Write-Host "Built system MSI: $($msi.FullName)"
