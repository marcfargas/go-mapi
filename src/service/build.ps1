param(
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$RequireMachineReleaseTrust,
    [string]$ArtifactOrigin = 'https://github.com/marcfargas/go-mapi/releases/download/',
    [int]$CheckIntervalSeconds = 21600
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$version = (Get-Content (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
if ($version -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)(?:-[0-9A-Za-z.-]+)?$') {
    throw 'Canonical service VERSION is invalid'
}
$majorVersion = $Matches.major
$minorVersion = $Matches.minor
$patchVersion = $Matches.patch
$machineOrigin = [Environment]::GetEnvironmentVariable('MACHINE_RELEASE_METADATA_ORIGIN')
$canonicalArtifactOrigin = 'https://github.com/marcfargas/go-mapi/releases/download/'
if ($CheckIntervalSeconds -lt 60 -or $CheckIntervalSeconds -gt 86400) { throw 'Machine check interval is outside bounds' }
if ($RequireMachineReleaseTrust -and $CheckIntervalSeconds -ne 21600) { throw 'Release service requires the six-hour machine check interval' }
if ($RequireMachineReleaseTrust -and [string]::IsNullOrWhiteSpace($machineOrigin)) {
    throw 'Signed managed service build requires machine metadata origin'
}
if (-not [string]::IsNullOrWhiteSpace($machineOrigin)) {
    $originUri = $null
    if ($machineOrigin -notmatch '^https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?$' -or
        -not [Uri]::TryCreate($machineOrigin, [UriKind]::Absolute, [ref]$originUri) -or
        $originUri.UserInfo -or $originUri.Query -or $originUri.Fragment -or $originUri.AbsolutePath -ne '/') {
        throw 'Invalid machine metadata origin'
    }
    if ($RequireMachineReleaseTrust -and $originUri.AbsoluteUri -ne 'https://go-mapi.app/') {
        throw 'Release machine metadata authority must be https://go-mapi.app'
    }
}
$artifactUri = $null
if (-not [Uri]::TryCreate($ArtifactOrigin, [UriKind]::Absolute, [ref]$artifactUri) -or
    $artifactUri.Scheme -ne 'https' -or -not $artifactUri.Host -or $artifactUri.UserInfo -or
    $artifactUri.Query -or $artifactUri.Fragment -or -not $ArtifactOrigin.EndsWith('/')) {
    throw 'Invalid machine artifact origin'
}
if ($RequireMachineReleaseTrust -and $ArtifactOrigin -cne $canonicalArtifactOrigin) { throw 'Release machine artifact origin must be canonical GitHub' }

$resourceCompiler = Get-Command llvm-rc -ErrorAction Stop
$llvmConverter = Get-Command llvm-cvtres -ErrorAction SilentlyContinue
$resourceConverter = if ($llvmConverter) { $llvmConverter.Source } else { $null }
if (-not $resourceConverter) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw "MSVC resource converter discovery requires $vswhere" }
    $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'MSVC x64 tools installation not found' }
    $toolsetVersion = (Get-Content (Join-Path $installation 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
    $resourceConverter = Join-Path $installation "VC\Tools\MSVC\$toolsetVersion\bin\Hostx64\x64\cvtres.exe"
    if (-not (Test-Path -LiteralPath $resourceConverter -PathType Leaf)) { throw "MSVC resource converter not found at $resourceConverter" }
}
Write-Host "Service resource converter: $resourceConverter"
$temporary = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
$resource = "$temporary.rc"
$compiled = "$temporary.res"
$syso = Join-Path $PSScriptRoot 'cmd/go-mapi-service/zz_service_version_windows_amd64.syso'
if (Test-Path -LiteralPath $syso) { throw 'A generated service resource already exists' }
$originalGoos = $env:GOOS
$originalGoarch = $env:GOARCH
$originalCgo = $env:CGO_ENABLED
try {
    $template = Get-Content (Join-Path $PSScriptRoot 'version.rc.in') -Raw
    $template = $template.Replace('@MAJOR@', $majorVersion).Replace('@MINOR@', $minorVersion).Replace('@PATCH@', $patchVersion).Replace('@VERSION@', $version)
    [IO.File]::WriteAllText($resource, $template, [Text.Encoding]::UTF8)
    & $resourceCompiler.Source /fo $compiled $resource
    if ($LASTEXITCODE -ne 0) { throw 'Service resource compilation failed' }
    & $resourceConverter /machine:x64 "/out:$syso" $compiled
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $syso -PathType Leaf)) { throw 'Service COFF resource conversion failed' }
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $env:CGO_ENABLED = '0'
    $destination = if ([IO.Path]::IsPathRooted($OutputPath)) { [IO.Path]::GetFullPath($OutputPath) } else { [IO.Path]::GetFullPath((Join-Path $root $OutputPath)) }
    New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
    $ldflags = "-X github.com/marcfargas/go-mapi/service.Version=$version"
    $ldflags += " -X github.com/marcfargas/go-mapi/service.MachineCheckIntervalSeconds=$CheckIntervalSeconds"
    if ($machineOrigin) { $ldflags += " -X github.com/marcfargas/go-mapi/service.MachineReleaseMetadataOrigin=$machineOrigin" }
    $ldflags += " -X github.com/marcfargas/go-mapi/internal/mapi/update.MachineArtifactOrigin=$ArtifactOrigin"
    Push-Location $root
    try {
        & go build -trimpath -ldflags $ldflags -o $destination ./src/service/cmd/go-mapi-service
        if ($LASTEXITCODE -ne 0) { throw 'Service PE build failed' }
    } finally { Pop-Location }
    $actual = (Get-Item -LiteralPath $destination).VersionInfo.ProductVersion
    if ($actual -ne $version) { throw 'Built service PE ProductVersion disagrees with canonical VERSION' }
} finally {
    $env:GOOS = $originalGoos
    $env:GOARCH = $originalGoarch
    $env:CGO_ENABLED = $originalCgo
    Remove-Item -LiteralPath $resource, $compiled, $syso -ErrorAction SilentlyContinue
}
