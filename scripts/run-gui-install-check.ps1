# GUI reachability check. Uses cua-driver to send Win+E to the Explorer desktop
# window ("Program Manager") and verifies that a new Explorer window appears.
# Success proves that the desktop accepts driven input. It does not install,
# launch or verify any package or installer, despite the file name.
#
# Requires an interactive Windows desktop with cua-driver installed and its
# daemon running in that session. ci.yml does not run this script: hosted
# runners have no desktop.
#
# Assumed cua-driver CLI contract:
# - `cua-driver call <tool>` reads one JSON object on stdin and writes JSON on
#   stdout. JSON goes on stdin because Windows PowerShell 5.1 removes the
#   quotes from JSON field names in native argv.
# - A non-zero exit code is a failure.
# - The JSON can contain "isError": true with exit code 0; that is a failure.
# - stderr can contain non-fatal lines that start with `warning:`.
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Session,
    [string]$Driver,
    [switch]$SkipDelay
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($Driver)) {
    $Driver = (Get-Command cua-driver -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $Driver -and $env:LOCALAPPDATA) {
        $Driver = Join-Path $env:LOCALAPPDATA 'Programs\Cua\cua-driver\bin\cua-driver.exe'
    }
}
if (-not $Driver -or -not (Test-Path -LiteralPath $Driver)) { throw 'cua-driver not found' }

function Invoke-CuaCall([string]$Name, [hashtable]$Payload) {
    $json = ConvertTo-Json -InputObject $Payload -Compress -Depth 10
    # Under Stop, `2>&1` turns a native stderr line into a terminating
    # NativeCommandError before the exit code can be read.
    $ErrorActionPreference = 'Continue'
    $output = @($json | & $Driver call $Name 2>&1)
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    # `warning:` lines are not failures; other stderr only explains a failure.
    $stderr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" } | Where-Object { $_ -notlike 'warning:*' }) -join ' '
    if ($code -ne 0) { throw "cua-driver $Name exited $code. $stderr" }
    $value = $stdout | ConvertFrom-Json
    # StrictMode: a successful response usually has no isError property.
    if ($value.PSObject.Properties['isError'] -and $value.isError -eq $true) {
        throw "cua-driver $Name returned isError. $stderr"
    }
    return $value
}

function Get-ExplorerWindows($Response) {
    if (-not $Response.PSObject.Properties['windows']) { throw 'cua-driver list_windows returned no windows field.' }
    return @($Response.windows | Where-Object { $_.app_name -eq 'explorer.exe' })
}

$before = Get-ExplorerWindows (Invoke-CuaCall 'list_windows' @{})
$desktop = @($before | Where-Object { $_.title -eq 'Program Manager' })
if ($desktop.Count -ne 1) { throw "Expected one Explorer desktop window, found $($desktop.Count)." }
$beforeIds = @($before | ForEach-Object { [long]$_.window_id })

# An Explorer pid owns several top-level windows (Program Manager, Run, folders); CUA refuses a
# pid-only hotkey with ambiguous_window_target, so always name the desktop window explicitly.
$null = Invoke-CuaCall 'hotkey' @{ pid = [int]$desktop[0].pid; window_id = [long]$desktop[0].window_id; keys = @('win', 'e'); session = $Session }
if (-not $SkipDelay) { Start-Sleep -Seconds 3 }

$after = Get-ExplorerWindows (Invoke-CuaCall 'list_windows' @{})
$opened = @($after | Where-Object { $_.title -ne 'Program Manager' -and [long]$_.window_id -notin $beforeIds })
if ($opened.Count -eq 0) { throw 'No new Explorer window appeared after Win+E.' }
Write-Host ("Explorer window opened: '{0}' (window_id {1})" -f $opened[0].title, $opened[0].window_id)
exit 0
