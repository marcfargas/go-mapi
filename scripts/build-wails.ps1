# scripts/build-wails.ps1 -- Wails production build with OAuth ldflags injection.
#
# QUICK-260423-olq.
#
# Reads GOMAPI_OAUTH_CLIENT_ID and GOMAPI_OAUTH_CLIENT_SECRET from the repo-root
# `.env.local` file (gitignored) and passes them to `wails build` via
# -ldflags "-X main.oauthClientID=... -X main.oauthClientSecret=...". Without
# this injection, the Wails binary's startup guard in src/app/credentials_check.go
# fatals with "OAuth client_id missing -- build was not wired correctly".
#
# Secret hygiene:
#   - The secret value is read into a local variable and passed to the child
#     process. It is NEVER printed, logged, or written to a file we commit.
#   - On failure, error messages reference the VARIABLE NAME (not the value).
#   - If you pipe this script's stdout/stderr to a log, no secret will leak.
#
# CC / CXX override (ARM64 host compatibility):
#   On Marc's ARM64 Windows dev machine, the plain `gcc` shim points at a
#   bare-metal aarch64-none-elf toolchain that cannot produce x86_64 Windows
#   binaries. Go's cgo must therefore be told to use the triple-prefixed
#   mstorsjo clang explicitly. We set CC / CXX in this script's environment
#   (child inherits); on x86_64 hosts this is a no-op because `gcc` there
#   would already produce x86_64.

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Platform = 'windows/amd64',
    [string]$EnvFile  = '',
    # Opt in only for an artifact that will be distributed. A normal Wails
    # production build remains a useful local-development command.
    [switch]$Release,
    # CI keeps OAuth credentials in the process environment. Opting into this
    # source avoids materialising the values in a runner file while keeping the
    # local .env.local workflow unchanged.
    [switch]$UseEnvironmentCredentials,
    # The installed application's explicit identity is a release concern. The
    # empty default preserves the existing local-development build behaviour.
    [string]$Aumid = '',
    [string]$StorePackageFamilyName = ''
    ,[string]$AdminReleaseRootB64 = ''
    ,[string]$AdminReleaseMetadataURL = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-CanonicalSemVer([string]$Value) {
    if ($Value -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') { return $false }
    if (-not [string]::IsNullOrWhiteSpace($Matches[4])) {
        foreach ($identifier in $Matches[4].Split('.')) {
            if ($identifier -match '^[0-9]+$' -and $identifier.Length -gt 1 -and $identifier.StartsWith('0')) { return $false }
        }
    }
    return $true
}

function Get-SHA256Hex([string]$Path) {
    # Do not depend on the optional Get-FileHash cmdlet. The app build is used
    # by both Windows PowerShell and PowerShell 7 in CI and on customer build
    # hosts, while this .NET API is available in both supported shells.
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($stream)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
    }
}

# Resolve script directory manually. $PSScriptRoot is unreliable inside param
# default expressions in PS 5.1; compute it here instead.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ([string]::IsNullOrEmpty($EnvFile)) {
    $EnvFile = Join-Path $ScriptDir '..\.env.local'
}

# 1) Load OAuth credentials from either the local env file or the explicitly
# requested process environment. The latter is for CI only and never writes
# secrets to disk.
$required = @('GOMAPI_OAUTH_CLIENT_ID', 'GOMAPI_OAUTH_CLIENT_SECRET')
$values   = @{}

if ($UseEnvironmentCredentials) {
    foreach ($key in $required) {
        $values[$key] = [Environment]::GetEnvironmentVariable($key)
    }
} else {
    $EnvFile = [System.IO.Path]::GetFullPath($EnvFile)
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        Write-Error "Missing env file: $EnvFile. Create it with GOMAPI_OAUTH_CLIENT_ID=... and GOMAPI_OAUTH_CLIENT_SECRET=... (gitignored)."
        exit 1
    }

    foreach ($line in [System.IO.File]::ReadAllLines($EnvFile)) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $eq = $trimmed.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $trimmed.Substring(0, $eq).Trim()
        $v = $trimmed.Substring($eq + 1)
        # Strip surrounding quotes if present -- tolerate both shapes
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or
            ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $values[$k] = $v
    }
}

$missing = $required | Where-Object { -not $values.ContainsKey($_) -or [string]::IsNullOrEmpty($values[$_]) }
if ($missing) {
    Write-Error "Missing required variable(s) in $EnvFile : $($missing -join ', ')"
    exit 1
}

# 2) Resolve the app solely through the checked-in component manifest. This
# prevents a release command from drifting to an independent npm version or a
# machine component input.
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..'))
$ManifestPath = Join-Path $RepoRoot 'components.json'
if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Missing component manifest: $ManifestPath" }
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$app = $manifest.components.app
if ($null -eq $app -or $app.path -ne 'src/app' -or $app.artifact -ne 'go-mapi.exe' -or $app.versionFile -ne 'src/app/VERSION') {
    throw 'components.json app record must declare src/app, go-mapi.exe, and src/app/VERSION'
}
if ($manifest.schemaVersion -ne 2 -or $app.requires.component -ne 'interceptor' -or [string]::IsNullOrWhiteSpace($app.requires.minInclusive)) {
    throw 'components.json app record must declare a strict interceptor requirement'
}
$maxExclusiveProperty = @($app.requires.PSObject.Properties | Where-Object { $_.Name -eq 'maxExclusive' })
$RequiredInterceptorMax = if ($maxExclusiveProperty.Count -eq 0 -or $null -eq $maxExclusiveProperty[0].Value) { '' } else { [string]$maxExclusiveProperty[0].Value }
$VersionFile = Join-Path $RepoRoot $app.versionFile
$AppVersion = '0.0.0-dev'
if (Test-Path -LiteralPath $VersionFile) { $AppVersion = ([System.IO.File]::ReadAllText($VersionFile)).Trim() }

# Do not infer "release" from Wails' production build mode: developers use
# that mode routinely to get a locally runnable executable. Release callers
# must say so explicitly, which makes the version gate both intentional and
# testable. A missing/empty VERSION takes the same fallback value and is thus
# rejected here as well.
if ($Release -and (-not (Test-CanonicalSemVer $AppVersion) -or $AppVersion -eq '0.0.0-dev')) {
    Write-Error "Release builds require a non-development src/app/VERSION; refusing to package $AppVersion."
    exit 1
}
if ([string]::IsNullOrWhiteSpace($AdminReleaseRootB64)) { $AdminReleaseRootB64 = [Environment]::GetEnvironmentVariable('GOMAPI_ADMIN_RELEASE_ROOT_B64') }
if ([string]::IsNullOrWhiteSpace($AdminReleaseMetadataURL)) { $AdminReleaseMetadataURL = [Environment]::GetEnvironmentVariable('GOMAPI_ADMIN_RELEASE_METADATA_URL') }
if ($Release -and ([string]::IsNullOrWhiteSpace($AdminReleaseRootB64) -or $AdminReleaseMetadataURL -notmatch '^https://')) { throw 'Release builds require protected admin release root and HTTPS metadata URL' }
if (-not (Test-CanonicalSemVer ([string]$app.requires.minInclusive)) -or
    (-not [string]::IsNullOrWhiteSpace($RequiredInterceptorMax) -and -not (Test-CanonicalSemVer $RequiredInterceptorMax))) {
    throw 'components.json app counterpart bounds must be canonical SemVer'
}

# 3) Build ldflags string. Values are passed to wails via the arg array so
# cmd.exe never re-parses them. We never echo OAuth values.
$ldflags = @(
    "-X `"main.Version=$AppVersion`"",
    "-X `"main.RequiredInterceptorMin=$($app.requires.minInclusive)`"",
    "-X `"main.RequiredInterceptorMax=$RequiredInterceptorMax`"",
    "-X `"main.oauthClientID=$($values['GOMAPI_OAUTH_CLIENT_ID'])`"",
    "-X `"main.oauthClientSecret=$($values['GOMAPI_OAUTH_CLIENT_SECRET'])`""
)
if ([string]::IsNullOrWhiteSpace($StorePackageFamilyName)) {
    $StorePackageFamilyName = [Environment]::GetEnvironmentVariable('GOMAPI_STORE_PACKAGE_FAMILY_NAME')
}
if (-not [string]::IsNullOrWhiteSpace($StorePackageFamilyName)) {
    if ($StorePackageFamilyName -notmatch '^[A-Za-z0-9._-]+$') { throw 'Invalid Store package family name' }
    $ldflags += "-X `"main.StorePackageFamilyName=$StorePackageFamilyName`""
}
if (-not [string]::IsNullOrWhiteSpace($Aumid)) {
    $ldflags += "-X `"main.aumidOverride=$Aumid`""
}
if (-not [string]::IsNullOrWhiteSpace($AdminReleaseRootB64)) { $ldflags += "-X `"main.AdminReleaseRootB64=$AdminReleaseRootB64`"" }
if (-not [string]::IsNullOrWhiteSpace($AdminReleaseMetadataURL)) { $ldflags += "-X `"main.AdminReleaseMetadataURL=$AdminReleaseMetadataURL`"" }
$ldflags = $ldflags -join ' '

# 4) CC / CXX override for ARM64 hosts. If the triple-prefixed binaries are on
# PATH we prefer them explicitly; otherwise leave the env alone (x86_64 hosts
# with a matching `gcc` in PATH will Just Work).
$ccCandidate  = Get-Command 'x86_64-w64-mingw32-clang'   -ErrorAction SilentlyContinue
$cxxCandidate = Get-Command 'x86_64-w64-mingw32-clang++' -ErrorAction SilentlyContinue
if ($ccCandidate)  { $env:CC  = $ccCandidate.Source }
if ($cxxCandidate) { $env:CXX = $cxxCandidate.Source }

# 5) Invoke wails build. cd into src/app for wails.json resolution.
$appDir = Join-Path $ScriptDir '..\src\app'
$appDir = [System.IO.Path]::GetFullPath($appDir)
$windowsBuildDir = Join-Path $appDir 'build\windows'
$versionInfoPath = Join-Path $windowsBuildDir 'info.json'
$hadVersionInfo = Test-Path -LiteralPath $versionInfoPath
$originalVersionInfo = if ($hadVersionInfo) { [System.IO.File]::ReadAllBytes($versionInfoPath) } else { $null }

# Wails embeds PE metadata from build/windows/info.json, rather than wails.json.
# Generate it from the component version input for this build so the executable
# has both FileVersion and ProductVersion resources even in a clean checkout.
# Windows fixed versions are numeric, whereas the string table may retain a
# release suffix such as 4.0.0-rc.1.
$fixedVersion = '0.0.0.0'
if ($AppVersion -match '^(\d+)\.(\d+)\.(\d+)(?:[.-].*)?$') {
    $fixedVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3]).0"
} elseif ($Release) {
    throw "Release app version must begin major.minor.patch: $AppVersion"
}
$versionInfo = [ordered]@{
    fixed = [ordered]@{ file_version = $fixedVersion; product_version = $fixedVersion }
    info = [ordered]@{
        '0000' = [ordered]@{
            ProductVersion = $AppVersion
            FileVersion = $AppVersion
            CompanyName = 'Marc Fargas'
            FileDescription = 'go-mapi'
            ProductName = 'go-mapi'
        }
    }
}
New-Item -ItemType Directory -Force -Path $windowsBuildDir | Out-Null
$versionInfo | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $versionInfoPath -NoNewline -Encoding ascii
Push-Location $appDir
try {
    Write-Host "[build-wails] Platform: $Platform"
    Write-Host "[build-wails] Version:  $AppVersion"
    Write-Host "[build-wails] CC:       $(if ($env:CC)  { $env:CC }  else { '(default)' })"
    Write-Host "[build-wails] CXX:      $(if ($env:CXX) { $env:CXX } else { '(default)' })"
    Write-Host "[build-wails] ldflags:  (oauth vars set -- values redacted)"
    # Wails emits benign binding-discovery diagnostics to stderr.  With the
    # caller's Stop preference that stream becomes a terminating PowerShell
    # error before we can inspect Wails' actual exit code.  Preserve strict
    # failure semantics based on $LASTEXITCODE instead.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & wails build -platform $Platform -ldflags $ldflags
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($rc -ne 0) {
        Write-Error "wails build exited with code $rc"
        exit $rc
    }
    $artifactPath = Join-Path $appDir 'build\bin\go-mapi.exe'
    if (-not (Test-Path -LiteralPath $artifactPath)) { throw "Wails did not produce $artifactPath" }
    $artifactManifest = [ordered]@{
        component = 'app'
        version = $AppVersion
        queueProtocol = $app.queueProtocol
        requires = [ordered]@{
            component = [string]$app.requires.component
            minInclusive = [string]$app.requires.minInclusive
        }
        artifact = [ordered]@{
            filename = [string]$app.artifact
            sha256 = Get-SHA256Hex $artifactPath
            peProductVersion = $AppVersion
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($RequiredInterceptorMax)) {
        $artifactManifest.requires['maxExclusive'] = $RequiredInterceptorMax
    }
    $artifactManifestJson = $artifactManifest | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText(
        (Join-Path $appDir 'build\bin\app-artifacts.json'),
        $artifactManifestJson,
        (New-Object System.Text.UTF8Encoding($false))
    )
} finally {
    if ($hadVersionInfo) {
        [System.IO.File]::WriteAllBytes($versionInfoPath, $originalVersionInfo)
    } elseif (Test-Path -LiteralPath $versionInfoPath) {
        Remove-Item -LiteralPath $versionInfoPath -Force
    }
    Pop-Location
}
