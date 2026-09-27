#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Native, [switch]$Wails, [switch]$Packages, [switch]$Install)

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
    return $command.Source
}
function Run-Native([string]$Name, [string[]]$Arguments) {
    & $Name @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
}
if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { throw 'Windows build preparation requires Windows' }
if ($Native) {
    $clangBin = Join-Path $env:USERPROFILE 'scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin'
    $drivers = @('x86_64-w64-mingw32-clang.exe','x86_64-w64-mingw32-clang++.exe','x86_64-w64-mingw32-windres.exe',
        'i686-w64-mingw32-clang.exe','i686-w64-mingw32-clang++.exe','i686-w64-mingw32-windres.exe')
    $missingDrivers = @($drivers | Where-Object { -not (Test-Path -LiteralPath (Join-Path $clangBin $_) -PathType Leaf) })
    if ($missingDrivers.Count -gt 0 -and $Install) {
        $scoop = Get-Command scoop -ErrorAction SilentlyContinue
        if (-not $scoop) {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
            $bootstrap = Join-Path $env:TEMP 'go-mapi-install-scoop.ps1'
            Invoke-WebRequest -UseBasicParsing https://get.scoop.sh -OutFile $bootstrap
            & $bootstrap -RunAsAdmin
            if ($LASTEXITCODE -ne 0) { throw 'Scoop installation failed' }
        }
        Add-ToolPath (Join-Path $env:USERPROFILE 'scoop\shims')
        Run-Native 'scoop' @('install','mingw-mstorsjo-llvm-ucrt')
    }
    foreach ($driver in $drivers) {
        if (-not (Test-Path -LiteralPath (Join-Path $clangBin $driver) -PathType Leaf)) { throw "Missing native tool: $driver in $clangBin" }
    }
    Add-ToolPath $clangBin
    foreach ($tool in @('cmake','ninja')) { Require-Command $tool | Out-Null }
}
if ($Wails) {
    $goBin = Join-Path ((& go env GOPATH) -join '').Trim() 'bin'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve Go tool directory' }
    Add-ToolPath $goBin
    $wailsCommand = Get-Command wails -ErrorAction SilentlyContinue
    $version = if ($wailsCommand) { ((& $wailsCommand.Source version) -join ' ').Trim() } else { '' }
    if ($wailsCommand -and $LASTEXITCODE -ne 0) { $version = '' }
    if ($version -notmatch 'v?2\.12\.0(?:\D|$)' -and $Install) {
        Run-Native 'go' @('install','github.com/wailsapp/wails/v2/cmd/wails@v2.12.0')
        $wailsCommand = Get-Command wails -ErrorAction SilentlyContinue
        $version = if ($wailsCommand) { ((& $wailsCommand.Source version) -join ' ').Trim() } else { '' }
    }
    if ($version -notmatch 'v?2\.12\.0(?:\D|$)') { throw "Wails v2.12.0 required; found '$version'" }
}
if ($Packages) {
    $nsis = Get-Command makensis.exe -ErrorAction SilentlyContinue
    if (-not $nsis) {
        $candidate = Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Add-ToolPath (Split-Path $candidate); $nsis = Get-Command makensis.exe -ErrorAction SilentlyContinue }
    }
    $version = if ($nsis) { ((& $nsis.Source /VERSION) -join ' ').Trim() } else { '' }
    if ($nsis -and $LASTEXITCODE -ne 0) { $version = '' }
    if ($version -notmatch '^v?3\.11(?:\D|$)' -and $Install) {
        Run-Native 'choco' @('install','nsis','--version=3.11','-y','--no-progress')
        $candidate = Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe'
        Add-ToolPath (Split-Path $candidate)
        $nsis = Get-Command makensis.exe -ErrorAction SilentlyContinue
        $version = if ($nsis) { ((& $nsis.Source /VERSION) -join ' ').Trim() } else { '' }
    }
    if ($version -notmatch '^v?3\.11(?:\D|$)') { throw "NSIS 3.11 required; found '$version'" }
    $sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $sdk = if (Test-Path -LiteralPath $sdkRoot) { Get-ChildItem -LiteralPath $sdkRoot -Directory | Sort-Object Name -Descending |
        Where-Object { (Test-Path (Join-Path $_.FullName 'x64\makeappx.exe')) -and (Test-Path (Join-Path $_.FullName 'x64\signtool.exe')) } | Select-Object -First 1 }
    if ($sdk) { Add-ToolPath (Join-Path $sdk.FullName 'x64') }
    Require-Command makeappx.exe | Out-Null
    Require-Command signtool.exe | Out-Null
}
