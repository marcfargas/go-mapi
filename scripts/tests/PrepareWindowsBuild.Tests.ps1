# Run the real preparer against isolated tool/package-manager doubles. No installs.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    Write-Host 'Windows preparer contracts skipped on non-Windows host'
    return
}
$preparer = Join-Path $PSScriptRoot '../prepare-windows-build.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('go-mapi-prepare-' + [guid]::NewGuid().ToString('N'))
$state = @{}
$saved = @{}
foreach ($name in @('PATH','USERPROFILE','SCOOP','GITHUB_PATH','ProgramFiles(x86)','TEMP')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$oldExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        Assert ($_.Exception.Message -match $Pattern) "Expected '$Pattern', got '$($_.Exception.Message)'"
        return
    }
    throw "Expected rejection matching '$Pattern'"
}
function Reset-Tools {
    $state.available = @{}
    $state.calls = [Collections.Generic.List[string]]::new()
    $state.installExit = 0
    $state.installPublishes = $true
    $state.versionExit = 0
    $state.nsisVersion = 'v3.11'
    $state.wailsVersion = 'v2.12.0'
    $state.goVersion = 'go version go1.25.3 windows/amd64'
    $state.nodeVersion = 'v20.20.2'
    $state.cmakeVersion = 'cmake version 3.31.0'
    $state.dotnetVersion = '8.0.413'
    $state.bootstrapEnabled = $false
    $state.bootstrapMode = 'return'
    $state.bootstrapBinding = $null
    $state.bootstrapPath = $null
    $state.bootstrapEffects = [Collections.Generic.List[string]]::new()
    $env:USERPROFILE = Join-Path $fixture ([guid]::NewGuid().ToString('N'))
    $env:SCOOP = Join-Path $env:USERPROFILE 'scoop'
    ${env:ProgramFiles(x86)} = Join-Path $env:USERPROFILE 'programs'
    $env:GITHUB_PATH = Join-Path $env:USERPROFILE 'github-path'
    $env:PATH = $saved.PATH
    $env:TEMP = $env:USERPROFILE
    New-Item -ItemType Directory -Force $env:USERPROFILE | Out-Null
}
function Add-Drivers {
    $dir = Join-Path $env:USERPROFILE 'scoop/apps/mingw-mstorsjo-llvm-ucrt/current/bin'
    New-Item -ItemType Directory -Force $dir | Out-Null
    foreach ($triple in @('x86_64','i686')) {
        foreach ($driver in @('clang','clang++','windres')) {
            New-Item -ItemType File -Force (Join-Path $dir "$triple-w64-mingw32-$driver.exe") | Out-Null
        }
    }
}
# Limit discovery to the scenario's tools, regardless of installed host tools.
function Get-Command {
    param([string]$Name, $ErrorAction)
    if ($Name -match '-w64-mingw32-(clang|clang\+\+|windres)\.exe$') {
        return Microsoft.PowerShell.Core\Get-Command Test-Compiler
    }
    if ($state.available.ContainsKey($Name)) { return Microsoft.PowerShell.Core\Get-Command $Name }
    return $null
}
function Test-Compiler { $global:LASTEXITCODE = $state.versionExit; 'clang/LLVM fixture version 20.1' }
function cmake { $global:LASTEXITCODE = $state.versionExit; $state.cmakeVersion }
function ninja { $global:LASTEXITCODE = $state.versionExit; '1.12.1' }
function node { $global:LASTEXITCODE = $state.versionExit; $state.nodeVersion }
function npm { $global:LASTEXITCODE = $state.versionExit; '11.0.0' }
function wails { $global:LASTEXITCODE = $state.versionExit; $state.wailsVersion }
function makensis.exe { $global:LASTEXITCODE = $state.versionExit; $state.nsisVersion }
function makeappx.exe { throw 'SDK tools must only be discovered' }
function signtool.exe { throw 'SDK tools must only be discovered' }
function dotnet { $global:LASTEXITCODE = $state.versionExit; $state.dotnetVersion }
function go {
    $global:LASTEXITCODE = $state.versionExit
    switch ($args[0]) {
        'version' { $state.goVersion }
        'env' { if ($args[1] -eq 'GOBIN') { Join-Path $env:USERPROFILE 'custom-go-bin' } else { Join-Path $env:USERPROFILE 'go' } }
        'install' {
            $state.calls.Add('go ' + ($args -join ' '))
            $global:LASTEXITCODE = $state.installExit
            if ($state.installExit -eq 0) {
                New-Item -ItemType Directory -Force (Join-Path $env:USERPROFILE 'custom-go-bin') | Out-Null
                $state.available.wails = $true; $state.wailsVersion = 'v2.12.0'
            }
        }
        default { throw 'Unexpected go command' }
    }
}
function scoop {
    $state.calls.Add('scoop ' + ($args -join ' '))
    $global:LASTEXITCODE = $state.installExit
    if ($state.installExit -ne 0 -or -not $state.installPublishes) { return }
    switch -Regex ($args[1]) {
        '^mingw-mstorsjo-llvm-ucrt$' { Add-Drivers }
        '^(cmake|ninja)$' { $state.available[$args[1]] = $true }
        'nsis\.json@3\.11$' { $state.available['makensis.exe'] = $true; $state.nsisVersion = 'v3.11' }
        default { throw "Unexpected Scoop package: $($args[1])" }
    }
}
function choco {
    $state.calls.Add('choco ' + ($args -join ' '))
    $global:LASTEXITCODE = $state.installExit
    if ($state.installExit -eq 0) { $state.available['makensis.exe'] = $true; $state.nsisVersion = 'v3.11' }
}
# All bootstrap effects stay in the fixture; unexpected attempts still fail closed.
function Invoke-WebRequest {
    param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile)
    if (-not $state.bootstrapEnabled) { throw 'Host bootstrap forbidden in preparer tests' }
    Assert ($UseBasicParsing -and $Uri -eq 'https://get.scoop.sh') 'Unexpected bootstrap download'
    Assert ((Split-Path -Parent $OutFile) -eq $env:TEMP) 'Bootstrap escaped the fixture'
    $state.bootstrapEffects.Add('download')
    $state.bootstrapPath = $OutFile
    @'
param([switch]$RunAsAdmin, [string]$ScoopDir)
$state.bootstrapBinding = @{ RunAsAdmin = $RunAsAdmin.IsPresent; ScoopDir = $ScoopDir }
switch ($state.bootstrapMode) {
    'throw' { throw 'Bootstrap fixture exception' }
    'nonzero' { exit 23 }
    'zero' { $state.available.scoop = $true; exit 0 }
    'return' { $state.available.scoop = $true; return }
    default { throw 'Unexpected bootstrap fixture mode' }
}
'@ | Set-Content -LiteralPath $OutFile
    # A normally returning script leaves LASTEXITCODE untouched: require a reset.
    $global:LASTEXITCODE = 31
}
function Set-ExecutionPolicy {
    param([string]$Scope, [string]$ExecutionPolicy, [switch]$Force)
    if (-not $state.bootstrapEnabled) { throw 'Host policy mutation forbidden in preparer tests' }
    Assert ($Scope -eq 'CurrentUser' -and $ExecutionPolicy -eq 'RemoteSigned' -and $Force) 'Unexpected bootstrap policy request'
    $state.bootstrapEffects.Add('policy')
}
try {
    Reset-Tools
    Reject { & $preparer -Native } 'Missing native tool: x86_64'
    Assert ($state.calls.Count -eq 0) 'Check-only invocation installed tools'

    Reset-Tools
    Add-Drivers
    Reject { & $preparer -Native } 'Missing required Windows build tool: cmake'
    Assert ($state.calls.Count -eq 0) 'Missing CMake caused installation without -Install'

    foreach ($mode in @('return','zero','nonzero','throw')) {
        Reset-Tools
        $state.bootstrapEnabled = $true; $state.bootstrapMode = $mode
        if ($mode -eq 'nonzero') {
            Reject { & $preparer -Native -Install } 'failed with exit code 23'
        } elseif ($mode -eq 'throw') {
            Reject { & $preparer -Native -Install } '^Bootstrap fixture exception$'
        } else {
            & $preparer -Native -Install
        }
        Assert ($null -ne $state.bootstrapBinding) "Bootstrap did not execute ($mode)"
        Assert ($state.bootstrapBinding.RunAsAdmin -and [string]::IsNullOrEmpty($state.bootstrapBinding.ScoopDir)) "Bootstrap did not bind RunAsAdmin as a named switch ($mode)"
        Assert (($state.bootstrapEffects -join '|') -eq 'policy|download') "Unexpected bootstrap effects ($mode)"
        Assert (-not (Test-Path -LiteralPath $state.bootstrapPath)) "Bootstrap file was not cleaned up ($mode)"
        if ($mode -in @('nonzero','throw')) {
            Assert ($state.calls.Count -eq 0) "Preparation continued after bootstrap failure ($mode)"
        } else {
            Assert (($state.calls -join '|') -eq 'scoop install mingw-mstorsjo-llvm-ucrt|scoop install cmake|scoop install ninja') "Bootstrap success did not continue native preparation ($mode)"
        }
    }

    Reset-Tools
    $state.available.scoop = $true
    & $preparer -Native -Install
    Assert (($state.calls -join '|') -eq 'scoop install mingw-mstorsjo-llvm-ucrt|scoop install cmake|scoop install ninja') 'Native install did not select all missing Scoop tools'
    Assert ((Get-Content $env:GITHUB_PATH) -contains (Join-Path $env:USERPROFILE 'scoop\apps\mingw-mstorsjo-llvm-ucrt\current\bin')) 'Native path not exported for later CI steps'
    $state.calls.Clear()
    & $preparer -Native -Install
    Assert ($state.calls.Count -eq 0) 'Already available native tools were reinstalled'

    Reset-Tools
    Add-Drivers
    $state.available.cmake = $true; $state.available.ninja = $true
    $state.cmakeVersion = 'cmake version 3.15.0'
    Reject { & $preparer -Native } 'CMake >= 3.16 required'
    $state.cmakeVersion = 'cmake version 3.31.0'; $state.versionExit = 9
    Reject { & $preparer -Native } 'version check failed with exit code 9'

    Reset-Tools
    Add-Drivers
    $state.available.scoop = $true; $state.installExit = 7
    Reject { & $preparer -Native -Install } 'scoop failed with exit code 7'
    Assert (($state.calls -join '|') -eq 'scoop install cmake') 'Preparation continued after install failure'

    Reset-Tools
    Add-Drivers
    $state.available.scoop = $true; $state.installPublishes = $false
    Reject { & $preparer -Native -Install } 'Missing required Windows build tool: cmake'
    Assert ($state.calls.Count -eq 1) 'Successful installer exit hid an unavailable tool'

    Reset-Tools
    $state.available.scoop = $true; $state.available.choco = $true
    $state.available['makeappx.exe'] = $true; $state.available['signtool.exe'] = $true
    & $preparer -Packages -Install
    Assert (($state.calls -join '|') -eq 'scoop install https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/nsis.json@3.11') 'NSIS did not prefer Scoop with exact version'

    Reset-Tools
    $state.available.choco = $true
    $state.available['makeappx.exe'] = $true; $state.available['signtool.exe'] = $true
    & $preparer -Packages -Install
    Assert (($state.calls -join '|') -eq 'choco install nsis --version=3.11 -y --no-progress') 'NSIS CI fallback changed'

    Reset-Tools
    $state.available.scoop = $true; $state.available.choco = $true; $state.installExit = 6
    Reject { & $preparer -Packages -Install } 'scoop failed with exit code 6'
    Assert ($state.calls.Count -eq 1) 'Failed Scoop installation fell back silently'

    Reset-Tools
    $state.available.scoop = $true; $state.installPublishes = $false
    $state.available['makensis.exe'] = $true; $state.nsisVersion = 'v3.13'
    Reject { & $preparer -Packages -Install } 'NSIS 3.11 required'

    Reset-Tools
    Reject { & $preparer -Packages -Install } 'NSIS 3.11 requires Scoop'
    $state.available['makensis.exe'] = $true; $state.nsisVersion = 'v3.11.1'
    Reject { & $preparer -Packages } 'NSIS 3.11 required'
    $state.nsisVersion = 'v3.11'
    Reject { & $preparer -Packages -Install } 'Windows SDK prerequisite unavailable: makeappx.exe'

    Reset-Tools
    Reject { & $preparer -Wails } 'Missing required Windows build tool: go'
    foreach ($tool in @('go','node','npm')) { $state.available[$tool] = $true }
    $state.goVersion = 'go version go1.24.0 windows/amd64'
    Reject { & $preparer -Wails -Install } 'Go 1.25.x required'
    Assert ($state.calls.Count -eq 0) 'Wails installed with unqualified Go'
    $state.goVersion = 'go version go1.25.3 windows/amd64'
    $state.nodeVersion = 'v26.12.1'
    Reject { & $preparer -Wails -Install } 'Node.js 20.x required'
    Assert ($state.calls.Count -eq 0) 'Wails installed with known incompatible Node'
    $state.nodeVersion = 'v20.20.2'
    & $preparer -Wails -Install
    Assert (($state.calls -join '|') -eq 'go install github.com/wailsapp/wails/v2/cmd/wails@v2.12.0') 'Wails install pin changed'
    Assert ((Get-Content $env:GITHUB_PATH) -contains (Join-Path $env:USERPROFILE 'custom-go-bin')) 'Explicit GOBIN not exported'
    $state.wailsVersion = "v2.12.0`n♥ If Wails is useful, please consider sponsoring the project"
    & $preparer -Wails
    $state.wailsVersion = 'v2.12.0-dev'
    Reject { & $preparer -Wails } 'Wails v2.12.0 required'
    $state.available.Remove('wails'); $state.installExit = 5
    Reject { & $preparer -Wails -Install } 'go failed with exit code 5'

    Reset-Tools
    Reject { & $preparer -Msi -Install } '.NET 8 SDK required'
    $state.available.dotnet = $true; $state.dotnetVersion = '9.0.100'
    Reject { & $preparer -Msi } '.NET 8 SDK required'
    $state.dotnetVersion = '8.0.413'
    & $preparer -Msi
    Assert ($state.calls.Count -eq 0) '.NET prerequisite check installed tools'
    Write-Host 'Windows preparer contracts passed'
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    if ($oldExitCode) { $global:LASTEXITCODE = $oldExitCode.Value } else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    if ([IO.Path]::GetFullPath($fixture).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}
