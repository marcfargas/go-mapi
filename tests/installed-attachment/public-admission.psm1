Set-StrictMode -Version 2.0

# A readiness lower bound only. The installed app still performs the authoritative
# admission check (ACL, reparse, file identity and shared lock) before userinfo.
function Read-Ticket569PublicAdmission {
    param([Parameter(Mandatory)][string] $Path)
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            if ($stream.Length -ne 1) { return @{ State = 'malformed'; ReadError = $null } }
            $value = $stream.ReadByte()
            $state = if ($value -eq 79) { 'O' } elseif ($value -eq 67) { 'C' } else { 'malformed' }
            return @{ State = $state; ReadError = $null }
        } finally { $stream.Dispose() }
    } catch {
        $error = $_.Exception.GetBaseException()
        $state = if ($error -is [IO.FileNotFoundException] -or $error -is [IO.DirectoryNotFoundException]) { 'missing' } else { 'read-error' }
        return @{ State = $state; ReadError = @{ Type = $error.GetType().FullName; HResult = $error.HResult } }
    }
}

function Wait-Ticket569PublicAdmission {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][DateTime] $DeadlineUtc,
        [Parameter(Mandatory)][string] $EvidencePath,
        [switch] $HistoricalAlpha7,
        [scriptblock] $Read = { param($Path) Read-Ticket569PublicAdmission -Path $Path },
        [scriptblock] $Now = { [DateTime]::UtcNow },
        [scriptblock] $Pause = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds },
        [scriptblock] $Service = {
            $service = Get-Service -Name go-mapi -ErrorAction Stop
            @{ Name = $service.Name; Status = [string]$service.Status; StartType = [string]$service.StartType }
        }
    )
    do {
        $serviceState = $null; $serviceError = $null
        try { $serviceState = & $Service } catch { $serviceError = $_.Exception.GetBaseException().GetType().FullName }
        $observation = if ($HistoricalAlpha7) { @{ State = 'historical-not-required'; ReadError = $null } } else { & $Read $Path }
        $at = & $Now
        $record = [ordered]@{
            SchemaVersion = 1; Predicate = 'public-byte-readiness-lower-bound'; FullMachineAdmissionEquivalent = $false
            At = $at.ToUniversalTime().ToString('o'); DeadlineUtc = $DeadlineUtc.ToUniversalTime().ToString('o')
            GatePath = $Path; State = $observation.State; ReadError = $observation.ReadError
            Service = $serviceState; ServiceError = $serviceError
        }
        [IO.File]::AppendAllText($EvidencePath, (ConvertTo-Json -InputObject $record -Depth 6 -Compress) + "`n", [Text.UTF8Encoding]::new($false))
        if ($HistoricalAlpha7) { return $record }
        if ($at -ge $DeadlineUtc) { throw "Public admission readiness timed out within the existing userinfo deadline; last state=$($observation.State)" }
        if ($observation.State -ceq 'O') { return $record }
        $remaining = ($DeadlineUtc - $at).TotalMilliseconds
        & $Pause ([int][math]::Min(250, [math]::Ceiling($remaining)))
    } while ($true)
}

Export-ModuleMember -Function Read-Ticket569PublicAdmission, Wait-Ticket569PublicAdmission
