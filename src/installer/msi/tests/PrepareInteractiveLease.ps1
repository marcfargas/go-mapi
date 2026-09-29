param(
    [ValidateSet('Inspect', 'InstallRDSH', 'Verify', 'EnableLogging', 'RestoreLogging')]
    [string]$Mode = 'Inspect',
    # Holds the saved Windows Installer logging policy between EnableLogging and RestoreLogging.
    [string]$StateDirectory = (Join-Path $env:ProgramData 'go-mapi-interactive-lease')
)

$ErrorActionPreference = 'Stop'
$installerPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer'
$loggingState = Join-Path $StateDirectory 'installer-logging-policy.json'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run lease preparation from an elevated disposable-guest session.'
}

$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -eq 1 -or $os.Version -notlike '10.0.20348*' -or -not [Environment]::Is64BitOperatingSystem) {
    throw "Expected x64 Windows Server 2022; observed $($os.Caption) $($os.Version)."
}

if ($Mode -eq 'EnableLogging') {
    # Verbose per-attempt MSI logs also for launches that do not pass /l*vx (Explorer double-click).
    New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    if (-not (Test-Path -LiteralPath $loggingState)) {
        $previous = Get-ItemProperty -Path $installerPolicy -Name Logging -ErrorAction SilentlyContinue
        [ordered]@{ Exists = [bool]$previous; Value = if ($previous) { [string]$previous.Logging } else { '' } } |
            ConvertTo-Json | Set-Content -LiteralPath $loggingState -Encoding UTF8
    }
    New-Item -Path $installerPolicy -Force | Out-Null
    New-ItemProperty -Path $installerPolicy -Name Logging -PropertyType String -Value 'voicewarmupx' -Force | Out-Null
    Write-Output "INSTALLER_LOGGING_ENABLED saved=$loggingState"
    exit 0
}
if ($Mode -eq 'RestoreLogging') {
    if (-not (Test-Path -LiteralPath $loggingState)) {
        throw "No saved logging policy at $loggingState; refusing to guess the prior state."
    }
    $previous = Get-Content -LiteralPath $loggingState -Raw | ConvertFrom-Json
    if ($previous.Exists) {
        New-Item -Path $installerPolicy -Force | Out-Null
        New-ItemProperty -Path $installerPolicy -Name Logging -PropertyType String -Value $previous.Value -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $installerPolicy -Name Logging -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $loggingState -Force
    $now = Get-ItemProperty -Path $installerPolicy -Name Logging -ErrorAction SilentlyContinue
    Write-Output "INSTALLER_LOGGING_RESTORED exists=$([bool]$now) value=$(if ($now) { $now.Logging })"
    exit 0
}

$desktop = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -gt 0 })
if ($Mode -eq 'Verify' -and $desktop.Count -eq 0) {
    $deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 5
        $desktop = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -gt 0 })
    } while ($desktop.Count -eq 0 -and (Get-Date) -lt $deadline)
}
if ($desktop.Count -eq 0) {
    throw 'No interactive Desktop Experience Explorer session is active.'
}

$netRelease = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release
if ($netRelease -lt 528040) {
    throw ".NET Framework 4.8 is required; observed release $netRelease."
}

$feature = Get-WindowsFeature -Name RDS-RD-Server
if (-not $feature) {
    throw 'The RDS-RD-Server role is unavailable on this image.'
}

if ($Mode -eq 'InstallRDSH' -and -not $feature.Installed) {
    $installation = Install-WindowsFeature -Name RDS-RD-Server -IncludeManagementTools -Restart:$false
    if (-not $installation.Success) {
        throw 'RDS-RD-Server installation failed.'
    }
    Write-Output "RDSH_INSTALL_SUCCESS RestartNeeded=$($installation.RestartNeeded)"
    if ($installation.RestartNeeded -eq 'Yes') {
        & shutdown.exe /r /t 15 /f | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Windows rejected the RDSH reboot request.'
        }
        Write-Output 'RDSH_REBOOT_SCHEDULED'
        exit 0
    }
    $feature = Get-WindowsFeature -Name RDS-RD-Server
}

if ($Mode -eq 'Verify' -and -not $feature.Installed) {
    throw 'RDS-RD-Server is not installed.'
}

Write-Output "LEASE_OS=$($os.Caption) VERSION=$($os.Version) BUILD=$($os.BuildNumber)"
Write-Output "DOTNET_RELEASE=$netRelease RDSH_INSTALLED=$($feature.Installed) DESKTOP_SESSIONS=$($desktop.Count)"
$modeOutput = @(& change.exe user /query)
$modeOutput | Write-Output
$changeUserExit = $LASTEXITCODE
Write-Output "RDS_MODE_QUERY_EXIT=$changeUserExit"
if ($feature.Installed) {
    # Server 2022 can report a valid mode while change.exe exits 1.
    $recognizedMode = @($modeOutput | Where-Object { $_ -match '^Application (EXECUTE|INSTALL) mode is enabled\.' }).Count -eq 1
    if ($changeUserExit -notin @(0, 1) -or -not $recognizedMode) {
        throw 'RDS install/execute mode query did not report a recognized mode.'
    }
}
if ($Mode -eq 'Verify') {
    Write-Output 'RDSH_READY'
}
