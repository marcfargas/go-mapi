# scripts/unregister-dev-aumid.ps1
# Removes the HKCU Start Menu shortcut created by register-dev-aumid.ps1.
# Cleans up the "go-mapi (dev)" AUMID registration from Action Center.
#
# Idempotent: no-op if the shortcut does not exist.
#
# Usage:
#   .\scripts\unregister-dev-aumid.ps1
#   .\scripts\unregister-dev-aumid.ps1 -Name 'go-mapi (dev)'

[CmdletBinding()]
param(
    [string]$Name = 'go-mapi (dev)'
)

$ErrorActionPreference = 'Stop'

$startMenu = [Environment]::GetFolderPath('Programs')
$lnkPath   = Join-Path $startMenu "$Name.lnk"

if (-not (Test-Path -LiteralPath $lnkPath)) {
    Write-Host "Shortcut not found at $lnkPath — nothing to remove." -ForegroundColor Yellow
    return
}

Remove-Item -LiteralPath $lnkPath -Force
Write-Host "Removed AUMID shortcut '$lnkPath'" -ForegroundColor Green
Write-Host
Write-Host "NOTE: Windows may cache the AUMID registration in the notification platform."
Write-Host "      Toasts from previous dev sessions will remain in Action Center until"
Write-Host "      they expire or you clear them manually."
