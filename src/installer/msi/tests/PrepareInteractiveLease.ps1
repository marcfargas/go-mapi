param(
    [ValidateSet('Inspect', 'InstallRDSH', 'Verify')]
    [string]$Mode = 'Inspect'
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run lease preparation from an elevated disposable-guest session.'
}

$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -eq 1 -or $os.Version -notlike '10.0.20348*' -or -not [Environment]::Is64BitOperatingSystem) {
    throw "Expected x64 Windows Server 2022; observed $($os.Caption) $($os.Version)."
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
