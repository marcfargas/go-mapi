# Installs the dependencies needed to exercise the go-mapi Wails app on a
# disposable CrabBox Server 2022 desktop lease.  Run elevated over the lease's
# brokered SSH connection; GUI proof is deliberately left to CUA Session 1.
[CmdletBinding()]
param([string]$Stage = 'C:\crabbox\go-mapi-customize')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force $Stage | Out-Null

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { throw 'An elevated administrator token is required.' }
$os = Get-CimInstance Win32_OperatingSystem
[pscustomobject]@{ Event='Preflight'; OS=$os.Caption; Version=$os.Version; Elevated=$elevated; FreeGB=[math]::Round((Get-PSDrive C).Free/1GB,2); WingetAvailable=[bool](Get-Command winget -ErrorAction SilentlyContinue) } | ConvertTo-Json -Compress

function Get-SignedInstaller([string]$Url, [string]$Path, [string]$Signer) {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path -PassThru
    $signature = Get-AuthenticodeSignature $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $Signer) {
        throw "Invalid or unexpected Authenticode signature: $Path"
    }
    [pscustomobject]@{Event='Installer'; Url=$Url; ResolvedUrl=$response.BaseResponse.ResponseUri.AbsoluteUri; SHA256=(Get-FileHash $Path -Algorithm SHA256).Hash; Signer=$signature.SignerCertificate.Subject; Signature=[string]$signature.Status} | ConvertTo-Json -Compress
}
function Wait-Installer([string]$File, [string]$Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
    [pscustomobject]@{Event='InstallerExit'; File=$File; Exit=$process.ExitCode} | ConvertTo-Json -Compress
    if ($process.ExitCode -eq 3010) { throw 'Installer succeeded but requires reboot. Reconnect to this lease, then rerun the recipe.' }
    if ($process.ExitCode -ne 0) { throw "Installer failed: $($process.ExitCode)" }
}
function Get-WebView2Version {
    $keys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    foreach ($key in $keys) {
        $version = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).pv
        if ($version -and $version -ne '0.0.0.0') { return $version }
    }
}

$webView2 = Get-WebView2Version
if (-not $webView2) {
    $bootstrap = Join-Path $Stage 'MicrosoftEdgeWebview2Setup.exe'
    Get-SignedInstaller 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' $bootstrap '(^|, )O=Microsoft Corporation(,|$)'
    Wait-Installer $bootstrap '/silent /install'
    $webView2 = Get-WebView2Version
}
if (-not $webView2) { throw 'WebView2 Evergreen Runtime is missing after installation.' }
Write-Output "WebView2Version=$webView2"

$chrome = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path $chrome)) {
    $msi = Join-Path $Stage 'chrome.msi'
    Get-SignedInstaller 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi' $msi '(^|, )O=Google LLC(,|$)'
    Wait-Installer 'msiexec.exe' "/i `"$msi`" /qn /norestart /L*v `"$Stage\chrome-install.log`""
}
if (-not (Test-Path $chrome)) { throw 'Chrome binary missing after install.' }
Write-Output "ChromeVersion=$((Get-Item $chrome).VersionInfo.ProductVersion)"

$components = @('Microsoft.VisualStudio.Workload.VCTools', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', 'Microsoft.VisualStudio.Component.Windows11SDK.26100')
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
function Find-BuildTools {
    if (Test-Path $vswhere) { & $vswhere -products Microsoft.VisualStudio.Product.BuildTools -version '[17.0,18.0)' -requires $components -property installationPath }
}
$installation = Find-BuildTools
if (-not $installation) {
    $bootstrap = Join-Path $Stage 'vs-buildtools.exe'
    Get-SignedInstaller 'https://aka.ms/vs/17/release/vs_buildtools.exe' $bootstrap '(^|, )O=Microsoft Corporation(,|$)'
    $arguments = '--quiet --wait --norestart --nocache --installPath C:\BuildTools'
    foreach ($component in $components) { $arguments += " --add $component" }
    Wait-Installer $bootstrap $arguments
    $installation = Find-BuildTools
}
if (-not $installation) { throw 'VS2022 Build Tools component inventory is incomplete.' }
& $vswhere -products Microsoft.VisualStudio.Product.BuildTools -version '[17.0,18.0)' -requires $components -format json

$smoke = Join-Path $Stage ('smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $smoke | Out-Null
@'
#include <windows.h>
#include <iostream>
int main() { std::cout << "CrabBoxDevTools OK pid=" << GetCurrentProcessId() << std::endl; return 0; }
'@ | Set-Content -Encoding Ascii (Join-Path $smoke 'smoke.cpp')
Push-Location $smoke
try {
    & cmd.exe /d /s /c "`"`"$installation\Common7\Tools\VsDevCmd.bat`" -arch=x64 -host_arch=x64 && cl /nologo /EHsc /W4 smoke.cpp /Fe:smoke.exe && smoke.exe && MSBuild.exe -nologo -version`""
    if ($LASTEXITCODE -ne 0) { throw "C++ smoke failed: $LASTEXITCODE" }
} finally { Pop-Location }
Write-Output "RecipeSucceeded=$smoke"
