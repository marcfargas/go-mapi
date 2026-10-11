[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'public-admission.psm1') -Force
$root = Join-Path ([IO.Path]::GetTempPath()) ('ticket569-admission-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$gate = Join-Path $root 'gate'
$evidence = Join-Path $root 'observations.jsonl'
$clock = [pscustomobject]@{ At = [DateTime]::Parse('2026-10-12T00:00:00Z').ToUniversalTime(); Slept = 0 }
$now = { $clock.At }.GetNewClosure()
$pause = { param($ms) $clock.At = $clock.At.AddMilliseconds($ms); $clock.Slept += $ms }.GetNewClosure()
$service = { @{ Name = 'go-mapi'; Status = 'Running'; StartType = 'Automatic' } }

function Assert([bool] $Condition, [string] $Message) { if (!$Condition) { throw $Message } }
function Expect-Timeout([string] $Path, [DateTime] $Deadline) {
    Remove-Item -LiteralPath $evidence -Force -ErrorAction SilentlyContinue
    try {
        $null = Wait-Ticket569PublicAdmission -Path $Path -DeadlineUtc $Deadline -EvidencePath $evidence -Now $now -Pause $pause -Service $service
        throw 'Expected timeout, but readiness passed'
    } catch { if ($_.Exception.Message -notmatch '^Public admission readiness timed out') { throw } }
    @(Get-Content -LiteralPath $evidence | ForEach-Object { $_ | ConvertFrom-Json })
}

try {
    # Real public files; time is deterministic and the service adapter is synthetic.
    foreach ($bytes in @([byte[]]@(), [byte[]]@(79,79), [byte[]]@(88))) {
        [IO.File]::WriteAllBytes($gate, $bytes)
        Assert ((Read-Ticket569PublicAdmission $gate).State -ceq 'malformed') 'Malformed file was admitted'
    }
    [IO.File]::WriteAllBytes($gate, [byte[]]@(67))
    $changeToOpen = {
        param($ms)
        $clock.At = $clock.At.AddMilliseconds($ms); $clock.Slept += $ms
        [IO.File]::WriteAllBytes($gate, [byte[]]@(79))
    }.GetNewClosure()
    $deadline = $clock.At.AddSeconds(1)
    $result = Wait-Ticket569PublicAdmission -Path $gate -DeadlineUtc $deadline -EvidencePath $evidence -Now $now -Pause $changeToOpen -Service $service
    $records = @(Get-Content -LiteralPath $evidence | ForEach-Object { $_ | ConvertFrom-Json })
    Assert (($records.State -join ',') -ceq 'C,O') 'C-to-O observation history was not retained'
    Assert ($result.State -ceq 'O' -and !$result.FullMachineAdmissionEquivalent) 'Byte readiness claimed full security equivalence'
    Assert ($records[0].Service.Status -ceq 'Running' -and $records[0].DeadlineUtc -eq $records[1].DeadlineUtc) 'SCM receipt missing or deadline restarted'

    # Default candidate/direct behavior: missing gate never silently becomes alpha7.
    Remove-Item -LiteralPath $gate
    $records = @(Expect-Timeout $gate $clock.At.AddMilliseconds(500))
    Assert (($records.State | Select-Object -Unique) -ceq 'missing') 'Missing candidate gate was admitted/misclassified'
    Assert ($clock.At -eq ([DateTime]$records[-1].DeadlineUtc).ToUniversalTime()) 'Missing-gate wait extended the deadline'

    # File.Open(directory) exercises an actual access failure, not a fabricated state.
    $records = @(Expect-Timeout $root $clock.At.AddMilliseconds(250))
    Assert ($records[-1].State -ceq 'read-error' -and $records[-1].ReadError.Type) 'Access-error receipt was lost'

    [IO.File]::WriteAllBytes($gate, [byte[]]@(67))
    $records = @(Expect-Timeout $gate $clock.At.AddMilliseconds(125))
    Assert ($records[-1].State -ceq 'C') 'Closed-gate timeout lost last state'
    Assert ($clock.At -eq ([DateTime]$records[-1].DeadlineUtc).ToUniversalTime()) 'Last poll exceeded remaining budget'
    [IO.File]::WriteAllBytes($gate, [byte[]]@(79))
    $records = @(Expect-Timeout $gate $clock.At)
    Assert ($records[-1].State -ceq 'O') 'Already-expired budget did not record O before refusing'

    # Only explicit historical alpha7 bypasses this newer candidate readiness lower bound.
    Remove-Item -LiteralPath $evidence, $gate
    $result = Wait-Ticket569PublicAdmission -Path $gate -DeadlineUtc $clock.At -EvidencePath $evidence -HistoricalAlpha7 -Now $now -Service $service `
        -Read { throw 'Historical alpha7 must not require a new-format gate' }
    Assert ($result.State -ceq 'historical-not-required' -and !$result.FullMachineAdmissionEquivalent) 'Historical baseline readiness was relabeled'
    Write-Output 'PUBLIC_ADMISSION_BYTE_CONTROL_PASSED;CLOCK_AND_SCM_ADAPTED_FULL_PRODUCTION_ADMISSION_UNRUN'
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
