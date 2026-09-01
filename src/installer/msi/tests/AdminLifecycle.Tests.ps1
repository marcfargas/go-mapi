[CmdletBinding()]
param([Parameter(Mandatory)][string]$MsiPath)

$ErrorActionPreference = 'Stop'
$msi = (Resolve-Path $MsiPath).Path
$productRoot = Join-Path $env:ProgramFiles 'go-mapi\interceptor'
$manifestPath = Join-Path $productRoot 'installed-component-v1.json'
$appDataSentinel = Join-Path $env:APPDATA 'go-mapi\admin-msi-must-preserve.txt'
$previousProvider = 'go-mapi-validation-previous-client'
$logRoot = Join-Path $env:ProgramData 'go-mapi\validation-logs'

function Invoke-Msi([string[]]$Arguments, [string]$Name, [int[]]$Expected = @(0)) {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $log = Join-Path $logRoot "$Name.log"
    $process = Start-Process msiexec.exe -ArgumentList (@($Arguments) + @('/l*v', $log)) -Wait -PassThru
    if ($process.ExitCode -notin $Expected) { throw "$Name failed with exit $($process.ExitCode); log=$log" }
    return $process.ExitCode
}

function Set-RegistryValue([Microsoft.Win32.RegistryView]$View, [string]$Path, [string]$Name, [string]$Value) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
    try {
        $key = $base.CreateSubKey($Path, $true)
        try { $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}

function Get-RegistryValue([Microsoft.Win32.RegistryView]$View, [string]$Path, [string]$Name) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
    try {
        $key = $base.OpenSubKey($Path, $false)
        if (-not $key) { return $null }
        try { return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}

function Seed-LegacyState {
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        Set-RegistryValue $view 'SOFTWARE\Clients\Mail' '' $previousProvider
        Set-RegistryValue $view "SOFTWARE\Clients\Mail\$previousProvider" '' $previousProvider
        Set-RegistryValue $view 'SOFTWARE\Clients\Mail\go-mapi' 'DLLPath' 'C:\legacy\go-mapi.dll'
        Set-RegistryValue $view 'SOFTWARE\Classes\go-mapi' '' 'legacy fixture'
        Set-RegistryValue $view 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\go-mapi.exe' '' 'C:\legacy\go-mapi.exe'
        Set-RegistryValue $view 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi' 'DisplayName' 'go-mapi'
        Set-RegistryValue $view 'SOFTWARE\RegisteredApplications' 'go-mapi' 'SOFTWARE\Clients\Mail\go-mapi\Capabilities'
    }
    New-Item -ItemType Directory -Path (Join-Path $env:ProgramFiles 'go-mapi') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $env:ProgramFiles 'go-mapi\go-mapi.exe.old.123') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path ${env:ProgramFiles(x86)} 'go-mapi') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path ${env:ProgramFiles(x86)} 'go-mapi\go-mapi.dll') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $env:ProgramData 'go-mapi\updates') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $env:ProgramData 'go-mapi\updates\legacy.bin') -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path $appDataSentinel) -Force | Out-Null
    Set-Content -LiteralPath $appDataSentinel -Value 'preserve me'
}

function Assert-Installed {
    $sharedDllPath = '%ProgramW6432%\go-mapi\interceptor\%PROCESSOR_ARCHITECTURE%\go-mapi.dll'
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        if ((Get-RegistryValue $view 'SOFTWARE\Clients\Mail' '') -ne 'go-mapi') { throw "$view active MAPI provider is not go-mapi" }
        $dll = Get-RegistryValue $view 'SOFTWARE\Clients\Mail\go-mapi' 'DLLPath'
        $arch = if ($view -eq [Microsoft.Win32.RegistryView]::Registry64) { 'x64' } else { 'x86' }
        if ($dll -ne $sharedDllPath) { throw "$view DLLPath is not caller-architecture aware: $dll" }
        $folder = if ($arch -eq 'x64') { 'AMD64' } else { 'x86' }
        $resolved = Join-Path $env:ProgramFiles "go-mapi\interceptor\$folder\go-mapi.dll"
        if (-not (Test-Path $resolved)) { throw "$view matching-bitness DLL is missing: $resolved" }
    }
    if (-not (Test-Path $manifestPath)) { throw 'installed component manifest is missing' }
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 'go-mapi-installed-interceptor-v1' -or $manifest.artifacts.Count -ne 2) { throw 'installed manifest has invalid shape' }
    if (-not (Test-Path $appDataSentinel)) { throw 'admin MSI removed per-user Wails data' }
}

Seed-LegacyState
Invoke-Msi @('/i', $msi, '/qn', '/norestart') 'install' | Out-Null
Assert-Installed

Invoke-Msi @('/fa', $msi, '/qn', '/norestart') 'repair' | Out-Null
Assert-Installed

Invoke-Msi @('/x', $msi, '/qn', '/norestart') 'uninstall' | Out-Null
foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
    if ((Get-RegistryValue $view 'SOFTWARE\Clients\Mail' '') -ne $previousProvider) { throw "$view previous active provider was not restored" }
}
if (Test-Path $manifestPath) { throw 'installed manifest remains after uninstall' }
if (-not (Test-Path $appDataSentinel)) { throw 'uninstall removed per-user Wails data' }

# Failure after destructive cleanup must roll back to the captured provider and leave no v4 manifest.
Seed-LegacyState
$exit = Invoke-Msi @('/i', $msi, '/qn', '/norestart', 'GOMAPI_TEST_FAILURE_POINT=after-cleanup') 'rollback-after-cleanup' @(1603)
foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
    if ((Get-RegistryValue $view 'SOFTWARE\Clients\Mail' '') -ne $previousProvider) { throw "$view rollback did not restore previous provider" }
}
if (Test-Path $manifestPath) { throw 'partial installed manifest remains after rollback' }

Write-Host "Admin MSI lifecycle validation passed. Durable logs: $logRoot"
