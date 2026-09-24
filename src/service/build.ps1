param(
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$RequirePublisherPolicy
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
$policyNames = @('ADMIN_RELEASE_PUBLISHER', 'ADMIN_RELEASE_EKUS_JSON', 'ADMIN_RELEASE_POLICY_ID')
$present = @($policyNames | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
if ($RequirePublisherPolicy -and $present.Count -ne $policyNames.Count) {
    throw 'Signed service build requires complete publisher policy inputs'
}
if ($present.Count -ne 0 -and $present.Count -ne $policyNames.Count) {
    throw 'Partial publisher policy inputs are forbidden'
}
$policyB64 = ''
if ($present.Count -eq $policyNames.Count) {
    $ekus = $env:ADMIN_RELEASE_EKUS_JSON | ConvertFrom-Json
    if ($ekus -isnot [array] -or $ekus.Count -lt 2 -or $ekus -notcontains '1.3.6.1.5.5.7.3.3' -or
        @($ekus | Select-Object -Unique).Count -ne $ekus.Count -or
        @($ekus | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'Publisher EKU policy is invalid'
    }
    $policy = [ordered]@{
        publisher = $env:ADMIN_RELEASE_PUBLISHER.Trim()
        ekus = @($ekus)
        policyId = $env:ADMIN_RELEASE_POLICY_ID.Trim()
    }
    if (-not $policy.publisher -or -not $policy.policyId) { throw 'Publisher policy is invalid' }
    $policyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($policy | ConvertTo-Json -Compress -Depth 3)))
    if ($policyB64.Length -gt 8192) { throw 'Publisher policy exceeds bound' }
}

$resourceCompiler = Get-Command llvm-rc -ErrorAction Stop
$resourceConverter = Get-Command llvm-cvtres -ErrorAction Stop
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
    & $resourceConverter.Source /machine:x64 "/out:$syso" $compiled
    if ($LASTEXITCODE -ne 0) { throw 'Service COFF resource conversion failed' }
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    $env:CGO_ENABLED = '0'
    $destination = if ([IO.Path]::IsPathRooted($OutputPath)) { [IO.Path]::GetFullPath($OutputPath) } else { [IO.Path]::GetFullPath((Join-Path $root $OutputPath)) }
    New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
    $ldflags = "-X github.com/marcfargas/go-mapi/service.Version=$version"
    if ($policyB64) { $ldflags += " -X github.com/marcfargas/go-mapi/service.PublisherPolicyB64=$policyB64" }
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
