param(
    [Parameter(Mandatory)][string]$HarnessPath
)

$ErrorActionPreference = 'Stop'
$dll = 'C:\Program Files\go-mapi\interceptor\AMD64\go-mapi.dll'
$app = 'C:\Program Files\go-mapi\user\go-mapi.exe'
$gate = 'C:\ProgramData\go-mapi\status\suite-admission-v1'

if (-not (Test-Path -LiteralPath $HarnessPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $dll -PathType Leaf) -or
    -not (Test-Path -LiteralPath $app -PathType Leaf) -or
    [IO.File]::ReadAllText($gate).Trim() -cne 'O') {
    throw 'A healthy installed suite and an open admission gate are required.'
}
$inheritedOwner = @((Get-Acl -LiteralPath 'C:\Program Files\go-mapi').Access | Where-Object {
    $sid = try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { '' }
    $sid -eq 'S-1-3-0' -and
    ($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0 -and
    ($_.FileSystemRights -band 0x10000000) -ne 0
})
if ($inheritedOwner.Count -eq 0) { throw 'The inherited CREATOR OWNER ACL regression shape is absent.' }
$session = (Get-Process -Id $PID).SessionId
if ($session -le 0) { throw 'Run the on-demand probe in an interactive user session.' }

function InstalledApps {
    @(Get-Process go-mapi -ErrorAction SilentlyContinue | Where-Object {
        $_.SessionId -eq $session -and $_.Path -ieq $app
    })
}
if (@(InstalledApps).Count -ne 0) { throw 'Close the installed app before the on-demand probe.' }

& $HarnessPath $dll '--case' 'Simple Send'
if ($LASTEXITCODE -ne 0) { throw 'Installed DLL MAPI publication failed.' }

$deadline = (Get-Date).AddSeconds(10)
do {
    $running = @(InstalledApps)
    if ($running.Count -eq 1) {
        Start-Sleep -Seconds 1
        if (@(InstalledApps | Where-Object Id -eq $running[0].Id).Count -eq 1) {
            Write-Output "SUITE_ON_DEMAND_PASS session=$session pid=$($running[0].Id)"
            exit 0
        }
    }
    Start-Sleep -Milliseconds 100
} while ((Get-Date) -lt $deadline)
throw 'MAPI publication succeeded, but the installed suite app did not stay running on demand.'
