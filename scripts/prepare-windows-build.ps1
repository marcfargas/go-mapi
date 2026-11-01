#Requires -Version 5.1
<#
.SYNOPSIS
Checks Windows build prerequisites, optionally installing supported tools.
.DESCRIPTION
-Native checks LLVM-MinGW, CMake and Ninja; -Wails checks Go 1.25, Node 20/npm
and Wails 2.12.0; -Packages checks NSIS 3.11 and Windows SDK packaging tools.
-Msi additionally checks the selected .NET 8 SDK for machine MSI builds.
-Install uses Scoop for native tools and NSIS, with Chocolatey as the NSIS
fallback when Scoop is absent. Go, Node, Windows SDK and .NET need separate setup.
PATH changes apply to this process and later GITHUB_PATH steps, not the caller.
#>
[CmdletBinding()]
param([switch]$Native, [switch]$Wails, [switch]$Packages, [switch]$Install, [switch]$Msi)

$ErrorActionPreference = 'Stop'
function Add-ToolPath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (@($env:PATH.Split([IO.Path]::PathSeparator) | Where-Object { $_ -ieq $Path }).Count -eq 0) {
        $env:PATH = "$Path$([IO.Path]::PathSeparator)$env:PATH"
    }
    if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $Path }
}
function Require-Command([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) { throw "Missing required Windows build tool: $Name" }
    return $command
}
function Run-Native([string]$Name, [string[]]$Arguments) {
    $global:LASTEXITCODE = 0
    & $Name @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}
function Get-ToolVersion([string]$Name, [string[]]$Arguments) {
    $command = Require-Command $Name
    $global:LASTEXITCODE = 0
    $value = ((& $command @Arguments) -join ' ').Trim()
    if ($LASTEXITCODE -ne 0) { throw "$Name version check failed with exit code $LASTEXITCODE" }
    if (-not $value) { throw "$Name did not report a version" }
    Write-Host "$Name`: $value"
    return $value
}
function Require-Scoop {
    Add-ToolPath (Join-Path $scoopRoot 'shims')
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        # Retain the native CI bootstrap; other prerequisites are not bootstrapped.
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
        $bootstrap = Join-Path $env:TEMP ('go-mapi-install-scoop-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            Invoke-WebRequest -UseBasicParsing https://get.scoop.sh -OutFile $bootstrap
            # A string array splat binds script arguments positionally, not as named switches.
            $global:LASTEXITCODE = 0
            & $bootstrap -RunAsAdmin
            if ($LASTEXITCODE -ne 0) { throw "$bootstrap failed with exit code $LASTEXITCODE" }
        } finally { Remove-Item -LiteralPath $bootstrap -Force -ErrorAction SilentlyContinue }
        Add-ToolPath (Join-Path $scoopRoot 'shims')
    }
    Require-Command scoop | Out-Null
}
function Find-Nsis {
    # Prefer Scoop's actual binary over an unrelated older PATH entry.
    foreach ($directory in @((Join-Path $scoopRoot 'apps\nsis\current\Bin'),
        (Join-Path $scoopRoot 'apps\nsis\current'), (Join-Path ${env:ProgramFiles(x86)} 'NSIS'))) {
        if (Test-Path -LiteralPath (Join-Path $directory 'makensis.exe') -PathType Leaf) {
            Add-ToolPath $directory
            break
        }
    }
    return Get-Command makensis.exe -ErrorAction SilentlyContinue
}
if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { throw 'Windows build preparation requires Windows' }
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
Add-ToolPath (Join-Path $scoopRoot 'shims')
if ($Native) {
    # The interceptor build itself uses this default location.
    $clangBin = Join-Path $env:USERPROFILE 'scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin'
    $drivers = @('x86_64-w64-mingw32-clang.exe','x86_64-w64-mingw32-clang++.exe','x86_64-w64-mingw32-windres.exe',
        'i686-w64-mingw32-clang.exe','i686-w64-mingw32-clang++.exe','i686-w64-mingw32-windres.exe')
    $missingDrivers = @($drivers | Where-Object { -not (Test-Path -LiteralPath (Join-Path $clangBin $_) -PathType Leaf) })
    if ($missingDrivers.Count -gt 0 -and $Install) {
        Require-Scoop
        Run-Native 'scoop' @('install','mingw-mstorsjo-llvm-ucrt')
    }
    foreach ($driver in $drivers) {
        if (-not (Test-Path -LiteralPath (Join-Path $clangBin $driver) -PathType Leaf)) { throw "Missing native tool: $driver in $clangBin" }
    }
    Add-ToolPath $clangBin
    foreach ($tool in @('cmake','ninja')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue) -and $Install) {
            Require-Scoop
            Run-Native 'scoop' @('install', $tool)
        }
        $version = Get-ToolVersion $tool @('--version')
        if ($tool -eq 'cmake' -and ($version -notmatch '^cmake version (\d+\.\d+(?:\.\d+)?)' -or [version]$Matches[1] -lt [version]'3.16')) {
            throw "CMake >= 3.16 required; found '$version'"
        }
        if ($tool -eq 'ninja' -and $version -notmatch '^\d+\.\d+(?:\.\d+)?(?:\s|$)') { throw "Cannot identify Ninja version: '$version'" }
    }
    foreach ($driver in $drivers) { Get-ToolVersion (Join-Path $clangBin $driver) @('--version') | Out-Null }
}
if ($Wails) {
    $version = Get-ToolVersion 'go' @('version')
    if ($version -notmatch '^go version go1\.25(?:\.\d+)?\s') { throw "Go 1.25.x required for the qualified Wails build; found '$version'. Install Go separately." }
    $version = Get-ToolVersion 'node' @('--version')
    if ($version -notmatch '^v?20\.') { throw "Node.js 20.x required for qualified local checks; found '$version'. Install versions/nodejs20 with Scoop and open a fresh shell. Node 26 fails the current Vitest localStorage setup." }
    Get-ToolVersion 'npm' @('--version') | Out-Null
    $global:LASTEXITCODE = 0
    $goPath = ((& go env GOPATH) -join '').Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve Go tool directory' }
    $goBin = ((& go env GOBIN) -join '').Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve Go binary directory' }
    if (-not $goBin) { $goBin = Join-Path ($goPath.Split([IO.Path]::PathSeparator)[0]) 'bin' }
    Add-ToolPath $goBin
    $wailsCommand = Get-Command wails -ErrorAction SilentlyContinue
    $version = if ($wailsCommand) { Get-ToolVersion 'wails' @('version') } else { '' }
    if ($version -notmatch '(?:^|\s)v?2\.12\.0(?:\s|$)' -and $Install) {
        Run-Native 'go' @('install','github.com/wailsapp/wails/v2/cmd/wails@v2.12.0')
        Add-ToolPath $goBin
        $version = Get-ToolVersion 'wails' @('version')
    }
    if ($version -notmatch '(?:^|\s)v?2\.12\.0(?:\s|$)') { throw "Wails v2.12.0 required; found '$version'" }
}
if ($Packages) {
    $nsis = Find-Nsis
    $version = if ($nsis) { Get-ToolVersion 'makensis.exe' @('/VERSION') } else { '' }
    if ($version -notmatch '^v?3\.11$' -and $Install) {
        if (Get-Command scoop -ErrorAction SilentlyContinue) {
            # Explicit version and manifest URL avoid requiring the extras bucket.
            Run-Native 'scoop' @('install','https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/nsis.json@3.11')
        } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
            Run-Native 'choco' @('install','nsis','--version=3.11','-y','--no-progress')
        } else { throw 'NSIS 3.11 requires Scoop (preferred) or Chocolatey; install a package manager separately.' }
        $nsis = Find-Nsis
        $version = if ($nsis) { Get-ToolVersion 'makensis.exe' @('/VERSION') } else { '' }
    }
    if ($version -notmatch '^v?3\.11$') { throw "NSIS 3.11 required; found '$version'" }
    $sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $sdk = if (Test-Path -LiteralPath $sdkRoot) { Get-ChildItem -LiteralPath $sdkRoot -Directory | Sort-Object Name -Descending |
        Where-Object { (Test-Path (Join-Path $_.FullName 'x64\makeappx.exe')) -and (Test-Path (Join-Path $_.FullName 'x64\signtool.exe')) } | Select-Object -First 1 }
    if ($sdk) { Add-ToolPath (Join-Path $sdk.FullName 'x64') }
    foreach ($tool in @('makeappx.exe','signtool.exe')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Windows SDK prerequisite unavailable: $tool. Install the Windows 10/11 SDK with packaging/signing tools separately; -Install does not install the SDK."
        }
    }
}
if ($Msi) {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw '.NET 8 SDK required for machine MSI builds. Install it separately; -Install does not install .NET.'
    }
    $version = Get-ToolVersion 'dotnet' @('--version')
    if ($version -notmatch '^8\.0\.\d+$') { throw ".NET 8 SDK required for machine MSI builds; selected SDK: '$version'. Install/select a .NET 8 SDK separately." }
}
if ($Native -or $Wails -or $Packages -or $Msi) {
    Write-Host 'Preparation verified tools in this process. PATH additions are exported through GITHUB_PATH for later CI steps.'
    Write-Host 'A child PowerShell/just process cannot update its calling shell. For local builds, dot-source this script in the build shell or configure PATH, then verify tool versions in a fresh shell.'
}
