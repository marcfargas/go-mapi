param([string]$InputDirectory, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath (Join-Path $InputDirectory 'Smoke.ps1'))) { throw 'Read-only input share is unavailable.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
@{ Status = 'PASS'; Identity = $identity; ComputerName = $env:COMPUTERNAME; ProcessId = $PID } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'smoke.json')
Write-Output "Sandbox smoke passed as $identity"
