[CmdletBinding()]
param(
    [string]$Version,
    [string]$ArtifactDirectory,
    [string]$OutputDirectory,
    [switch]$RequireSignedInputs
)

$ErrorActionPreference = 'Stop'
$msiRoot = $PSScriptRoot
$repoRoot = [IO.Path]::GetFullPath((Join-Path $msiRoot '..\..\..'))
if (-not $Version) { $Version = (Get-Content (Join-Path $repoRoot 'src\interceptor\interceptor-version.txt') -Raw).Trim() }
if (-not $ArtifactDirectory) { $ArtifactDirectory = Join-Path $repoRoot 'release\interceptor' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'release\admin' }

function Fail([string]$Message) { throw "Admin MSI build failed: $Message" }
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
function Get-ProductCode([string]$InputVersion) {
    # Stable ProductCode per semantic version. UpgradeCode remains stable across
    # versions; same-version rebuilds retain Windows Installer identity.
    $seed = [Text.Encoding]::UTF8.GetBytes("go-mapi-admin-msi:$InputVersion")
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($seed)
    $bytes = [byte[]]$hash[0..15]
    $bytes[7] = ($bytes[7] -band 0x0f) -bor 0x50
    $bytes[8] = ($bytes[8] -band 0x3f) -bor 0x80
    return ([Guid]::new($bytes)).ToString('D').ToUpperInvariant()
}

if ($Version -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$' -or $Version -eq '0.0.0-dev') { Fail "invalid release version '$Version'" }
$componentContract = (Get-Content (Join-Path $repoRoot 'components.json') -Raw | ConvertFrom-Json).components.interceptor
$requiredAppMin = [string]$componentContract.requires.minInclusive
if ($componentContract.requires.component -ne 'app' -or $requiredAppMin -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { Fail 'components.json has no valid interceptor -> app minimum requirement' }
$manifestPath = Join-Path $ArtifactDirectory 'interceptor-artifacts.json'
if (-not (Test-Path $manifestPath)) { Fail "missing $manifestPath" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
if ($manifest.component -ne 'interceptor' -or $manifest.version -ne $Version -or $manifest.queueProtocol -ne 'queue-v1') { Fail 'interceptor artifact manifest does not match requested component/version/protocol' }

$byArch = @{}
foreach ($artifact in @($manifest.artifacts)) {
    if ($artifact.architecture -notin @('x86','x64') -or $byArch.ContainsKey($artifact.architecture)) { Fail 'artifact manifest must contain exactly one x86 and x64 entry' }
    $path = Join-Path $ArtifactDirectory $artifact.filename
    if (-not (Test-Path $path)) { Fail "missing artifact $path" }
    $hash = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $artifact.sha256) { Fail "$($artifact.architecture) artifact hash mismatch" }
    $expectedMachine = if ($artifact.architecture -eq 'x86') { 0x014c } else { 0x8664 }
    if ((Get-PeMachine $path) -ne $expectedMachine) { Fail "$($artifact.architecture) PE machine mismatch" }
    $productVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductVersion
    if ($productVersion -ne $Version) { Fail "$($artifact.architecture) PE ProductVersion '$productVersion' does not equal '$Version'" }
    if ($RequireSignedInputs) { Assert-Signed $path }
    $byArch[$artifact.architecture] = $path
}
if ($byArch.Count -ne 2) { Fail 'artifact manifest must contain exactly x86 and x64' }

$customProject = Join-Path $msiRoot 'customaction\GoMapi.AdminCustomActions.csproj'
dotnet build $customProject --configuration Release
if ($LASTEXITCODE -ne 0) { Fail 'custom action build failed' }
$customBinary = Join-Path $msiRoot 'customaction\bin\x64\Release\net48\GoMapi.AdminCustomActions.CA.dll'
if (-not (Test-Path $customBinary)) { Fail "missing packaged DTF custom action $customBinary" }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$project = Join-Path $msiRoot 'GoMapi.AdminInstaller.wixproj'
$productCode = Get-ProductCode $Version
$arguments = @(
    'build', $project,
    '--configuration', 'Release',
    "-p:ProductVersion=$Version",
    "-p:ProductCode=$productCode",
    "-p:RequiredAppMin=$requiredAppMin",
    "-p:SourceX64=$($byArch.x64)",
    "-p:SourceX86=$($byArch.x86)",
    "-p:CustomActionBinary=$customBinary",
    "-p:OutputPath=$OutputDirectory"
)
dotnet @arguments
if ($LASTEXITCODE -ne 0) { Fail 'WiX MSI build failed' }

$msi = Get-ChildItem $OutputDirectory -Filter 'go-mapi-interceptor.msi' -Recurse | Select-Object -First 1
if (-not $msi) { Fail 'WiX build did not produce go-mapi-interceptor.msi' }
Write-Host "Built admin MSI: $($msi.FullName)"
