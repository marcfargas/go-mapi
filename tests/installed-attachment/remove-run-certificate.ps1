[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RunRoot,
    [Parameter(Mandatory)] [string] $RunId,
    [Parameter(Mandatory)] [string] $Subject,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9A-Fa-f]{40}$')] [string] $Thumbprint
)

$ErrorActionPreference = 'Stop'
$errorText = $null
$absent = $false
$requested = $false
function Write-AtomicJson([string] $Path, $Value) {
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 6), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

try {
    if ([IO.Path]::GetFileName($RunRoot) -cne $RunId -or $Subject -cne "CN=Ticket 569 synthetic CA $RunId") {
        throw 'Removal is restricted to the exact run-owned synthetic CA'
    }
    $path = "Cert:\CurrentUser\Root\$Thumbprint"
    $certificate = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($certificate) {
        if ($certificate.Subject -cne $Subject -or $certificate.Thumbprint -ine $Thumbprint -or $certificate.HasPrivateKey) {
            throw 'CurrentUser Root certificate does not match the exact public run CA'
        }
        $requested = $true
        Write-AtomicJson (Join-Path $RunRoot 'trust-remove-request.json') @{
            RunId = $RunId; Phase = 'delete'; PID = $PID; Subject = $Subject; Thumbprint = $Thumbprint.ToUpperInvariant()
            CreationFileTimeUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToFileTimeUtc()
        }
        # This child is interactive: Windows requires an exact Root Store DELETE consent, confirmed by CUA.
        Remove-Item -LiteralPath $path -ErrorAction Stop
    }
} catch {
    $errorText = $_.ToString()
} finally {
    try {
        $absent = !(Test-Path -LiteralPath "Cert:\CurrentUser\Root\$Thumbprint")
        if (!$absent -and !$errorText) { $errorText = 'Exact synthetic root remains after removal' }
    } catch {
        $errorText = "$errorText; post-removal inventory failed: $_"
    }
    Write-AtomicJson (Join-Path $RunRoot 'trust-remove-child.json') @{
        RunId = $RunId; Phase = 'delete'; PID = $PID; Subject = $Subject; Thumbprint = $Thumbprint.ToUpperInvariant()
        Requested = $requested; SyntheticRootAbsent = $absent; Error = $errorText; Completed = (!$errorText -and $absent)
    }
}
if ($errorText) { Write-Error $errorText; exit 1 }
exit 0
