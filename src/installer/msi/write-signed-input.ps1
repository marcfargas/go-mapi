#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('system','suite')][string]$SKU,
    [Parameter(Mandatory)][string]$PackageRelease,
    [Parameter(Mandatory)][string]$SourceCommit,
    [Parameter(Mandatory)][string]$InputDirectory,
    [Parameter(Mandatory)][string]$ServiceVersion,
    [Parameter(Mandatory)][string]$InterceptorVersion,
    [string]$AppVersion,
    [string]$AppBuildManifest,
    [string]$UnsignedAppSha256,
    [switch]$RequireSignature,
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$semver = '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
foreach ($entry in @(@('package release',$PackageRelease),@('service',$ServiceVersion),@('interceptor',$InterceptorVersion))) {
    if ($entry[1] -notmatch $semver) { throw "Invalid $($entry[0]) version: $($entry[1])" }
}
if ($SourceCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'Source commit must be a lowercase full SHA' }
if ($SKU -eq 'suite') {
    if ($AppVersion -notmatch $semver -or -not $AppBuildManifest -or $UnsignedAppSha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Suite signed input requires a canonical app version, build manifest and unsigned app hash'
    }
} elseif ($AppVersion -or $AppBuildManifest -or $UnsignedAppSha256) { throw 'System signed input may not contain an app' }
$directory = [IO.Path]::GetFullPath($InputDirectory)
$files = @('go-mapi-service.exe','go-mapi-x86.dll','go-mapi-x64.dll')
if ($SKU -eq 'suite') { $files += 'go-mapi-machine.exe' }
$hashes = @{}
foreach ($name in $files) {
    $path = Join-Path $directory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing signed input: $path" }
    if ($RequireSignature) {
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne 'Valid' -or $signature.SignatureType -ne 'Authenticode' -or
            -not $signature.SignerCertificate -or -not $signature.TimeStamperCertificate) {
            throw "Incomplete or untrusted Azure signing proof: $path"
        }
    }
    $hashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}
$components = @(
    [ordered]@{ component='service'; version=$ServiceVersion; artifacts=@([ordered]@{ architecture='x64'; filename='go-mapi-service.exe'; sha256=$hashes['go-mapi-service.exe'] }) },
    [ordered]@{ component='interceptor'; version=$InterceptorVersion; artifacts=@(
        [ordered]@{ architecture='x86'; filename='go-mapi-x86.dll'; sha256=$hashes['go-mapi-x86.dll'] },
        [ordered]@{ architecture='x64'; filename='go-mapi-x64.dll'; sha256=$hashes['go-mapi-x64.dll'] }
    ) }
)
$result = [ordered]@{ schema='go-mapi-machine-signed-input-v1'; sku=$SKU; packageRelease=$PackageRelease; commit=$SourceCommit; components=$components }
if ($SKU -eq 'suite') {
    $buildPath = [IO.Path]::GetFullPath($AppBuildManifest)
    if (-not (Test-Path -LiteralPath $buildPath -PathType Leaf)) { throw "Missing app build manifest: $buildPath" }
    $build = Get-Content -LiteralPath $buildPath -Raw | ConvertFrom-Json
    if ($build.schema -cne 'go-mapi-app-artifacts-v2' -or $build.component -cne 'app' -or
        $build.version -cne $AppVersion -or $build.distribution -cne 'machine' -or
        $build.artifact.filename -cne 'go-mapi-machine.exe' -or $build.artifact.peProductVersion -cne $AppVersion -or
        $build.source.commit -cne $SourceCommit -or $build.artifact.sha256 -cne $UnsignedAppSha256) {
        throw 'App build manifest does not bind the requested unsigned machine app, version and source'
    }
    $result.components += [ordered]@{ component='app'; version=$AppVersion; distribution='machine'; artifacts=@(
        [ordered]@{ architecture='x64'; filename='go-mapi-machine.exe'; sha256=$hashes['go-mapi-machine.exe'] }) }
    $result.appBuild = [ordered]@{ manifest='app-artifacts.json'; sha256=(Get-FileHash -LiteralPath $buildPath -Algorithm SHA256).Hash.ToLowerInvariant(); unsignedSha256=$UnsignedAppSha256 }
}
$target = [IO.Path]::GetFullPath($OutputPath)
if ((Split-Path -Parent $target) -cne $directory) { throw 'Signed input manifest must be written beside its component files' }
[IO.File]::WriteAllText($target, ($result | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
