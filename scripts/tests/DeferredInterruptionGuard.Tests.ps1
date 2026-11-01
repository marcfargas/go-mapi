[CmdletBinding()]
param([string]$SourcePath = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$SourcePath) { $SourcePath = Join-Path $PSScriptRoot '../run-machine-update-integration.ps1' }
# Portable replay of the actual guard function; no native product/process/store operations.
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Production source does not parse' }
$function=$ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConfirmDeferredInterruption' },$true)
if (!$function) { throw 'Production conservative cleanup guard is absent' }
Invoke-Expression $function.Extent.Text
function Assert($condition,[string]$message) { if (!$condition) { throw $message } }
$PackageManifest='fixture-manifest'; $Phase='Cleanup'; $caseB='systemB'
$manifest=@{ packages=@{ systemB=@{ sku='system'; release='5.0.1-alpha.5'; msi='fixture-msi'; sha256='msi-hash'; identity=@{ productCode='owned-B'; sequence=42 } } } }
function Hash([string]$Path) {
    switch ($Path) { 'fixture-manifest' { 'manifest-hash' } 'fixture-msi' { 'msi-hash' } 'fixture-fence' { if (!$script:badFence) { 'fence-hash' } else { 'changed-fence-hash' } } }
}
function InstalledTestProducts {
    $script:productReads++
    if ($script:productError) { throw 'product inventory read failed' }
    $script:products
}
function Snapshot {
    $script:snapshotReads++
    if ($script:snapshotError) { throw 'snapshot read failed' }
    $script:snapshot
}
function Get-Process {
    [CmdletBinding()]
    param([int]$Id)
    $script:lookups += $Id
    if ($script:lookupError -eq 'throw') { throw 'fixture terminating lookup error' }
    if ($script:lookupError) { Write-Error 'fixture process lookup read error'; return }
    if ($script:livePIDs -contains $Id) {
        $process=[pscustomobject]@{ Id=$Id; ProcessName=$script:processName; SessionId=$null; Path=$null }
        $process | Add-Member ScriptProperty StartTime {
            $script:startReads[$this.Id]++
            if ($script:identityError) { throw 'fixture identity read error' }
            $script:startTimes[$this.Id]
        }
        if ($script:wrongId) { $process.Id=111 }
        if ($script:ambiguous) { $process; $process } else { $process }
    } elseif (!$script:silentAbsence) {
        # Write-Error appends this mock's function name to the native error ID.
        # Supply the structured ErrorVariable result directly, without any host PID probe.
        $notFound=[Management.Automation.ErrorRecord]::new(
            [InvalidOperationException]::new('Localized native absence fixture'),
            $script:absenceId,$script:absenceCategory,($Id + $script:absenceTargetOffset))
        Set-Variable -Name lookupErrors -Scope 1 -Value @($notFound)
    }
}
function Select-String { param([string]$LiteralPath,[string]$Pattern,[switch]$Quiet) !$script:badFenceText }
function Record([string]$Kind,$Value) {
    if ($script:recordError) { throw 'guard observation write failed' }
    $script:observations += [pscustomobject]@{ kind=$Kind; value=$Value }
}
function Reset {
    $script:record=@{
        schema='go-mapi-interruption-cleanup-deferral-v1'; packageManifestSha256='manifest-hash'; systemBMsiSha256='msi-hash'
        installedProductCode='owned-B'; installedRelease='5.0.1-alpha.5'; transactionId='same-transaction'; attempt=1
        runner=@{ pid=1928; createdAtUnixNano=[long]1791764507267080100 }
        installer=@{ pid=9400; createdAtUnixNano=[long]1791764507308011300 }
        uninstallFenceLog='fixture-fence'; uninstallFenceLogSha256='fence-hash'
    }
    $script:products=@($manifest.packages.systemB)
    $script:snapshot=@{
        marker=@{ packageRelease='5.0.1-alpha.5' }; service=@{ state='Running' }
        pending=@{ transactionId='same-transaction'; attempt=1; phase='outcome-unconfirmed'
            runner=@{ pid=1928; createdAtUnixNano=[long]1791764507267080100 }
            installer=@{ pid=9400; createdAtUnixNano=[long]1791764507308011300 } }
        replay=$null
    }
    $script:observations=@(); $script:lookups=@(); $script:productReads=0; $script:snapshotReads=0
    $script:livePIDs=@(); $script:lookupError=$false; $script:identityError=$false
    $script:startReads=@{1928=0;9400=0}; $script:startTimes=@{
        1928=[DateTime]::new(639273613072670801L,[DateTimeKind]::Utc)
        9400=[DateTime]::new(639273613073080113L,[DateTimeKind]::Utc)
    }
    $script:processName='unrelated-pwsh'; $script:wrongId=$false; $script:ambiguous=$false; $script:silentAbsence=$false
    $script:absenceId='NoProcessFoundForGivenId,Microsoft.PowerShell.Commands.GetProcessCommand'
    $script:absenceCategory=[Management.Automation.ErrorCategory]::ObjectNotFound; $script:absenceTargetOffset=0
    $script:productError=$false; $script:snapshotError=$false; $script:recordError=$false
    $script:badFence=$false; $script:badFenceText=$false
}
function Check([string]$Name,[scriptblock]$Arrange,[string]$ExpectedError,[bool]$Fence=$false) {
    Reset; & $Arrange
    $caught=$null
    try { $result=ConfirmDeferredInterruption $script:record $Fence } catch { $caught=$_.Exception.Message }
    if ($ExpectedError) { Assert ($caught -eq $ExpectedError) "$Name changed expected failure: $caught" }
    else { Assert (!$caught) "$Name failed: $caught"; Assert ($result.pending.transactionId -eq 'same-transaction') "$Name changed successful snapshot" }
    if (!$script:recordError) {
        Assert ($script:observations.Count -eq 1) "$Name lacks exactly one guard observation"
        $receipt=$script:observations[0]
        Assert ($receipt.kind -eq 'cleanup-deferred-guard-observation') "$Name wrong observation kind"
        Assert ($receipt.value.expected.runner.createdAtUnixNano -eq [long]1791764507267080100) "$Name lost exact64-bit expected identity"
        if (!$script:productError -and !$script:snapshotError) {
            Assert (($script:lookups -join ',') -eq "$($script:record.runner.pid),$($script:record.installer.pid)") "$Name reprobed or omitted a native lookup"
            Assert ($script:productReads -eq 1 -and $script:snapshotReads -eq 1) "$Name reprobed state"
            Assert ($receipt.value.snapshot -eq $script:snapshot) "$Name receipt differs from consumed snapshot"
            foreach ($pidValue in @(1928,9400)) {
                if (!$script:wrongId -and !$script:ambiguous) {
                    Assert ($script:startReads[$pidValue] -eq [int]($script:livePIDs -contains $pidValue)) "$Name reread or omitted StartTime for $pidValue"
                }
            }
        }
    }
    Write-Output "PASS $Name"
}
$guardError='Deferred cleanup no longer matches exact conservative interruption state'
Check 'exact conservative state succeeds with exact receipt' {} $null $true
Check 'JSON-roundtrip record and snapshot permit native absence' {
    $script:record=$script:record | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $script:snapshot=$script:snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
} $null $true
Check 'JSON-roundtrip record and snapshot permit reused PID' {
    $script:record=$script:record | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $script:snapshot=$script:snapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $script:livePIDs=@(1928); $script:startTimes[1928]=$script:startTimes[1928].AddTicks(1)
} $null
Check 'matching runner rejected' { $script:livePIDs=@(1928) } $guardError
Assert ($script:observations[0].value.processes.runner.identity.ProcessName -eq 'unrelated-pwsh') 'Live runner image identity missing'
Assert ($script:observations[0].value.processes.runner.createdAtUnixNano -ceq [long]1791764507267080100) 'Live runner exact creation identity missing'
Check 'matching installer rejected' { $script:livePIDs=@(9400) } $guardError
Check 'both matching rejected' { $script:livePIDs=@(1928,9400) } $guardError
foreach ($live in @(@(1928),@(9400),@(1928,9400))) {
    Check "reused roles $live accepted" { $script:livePIDs=$live; foreach ($id in $live) { $script:startTimes[$id]=$script:startTimes[$id].AddTicks(1) } } $null
}
Check 'matching runner and reused installer rejected' { $script:livePIDs=@(1928,9400); $script:startTimes[9400]=$script:startTimes[9400].AddTicks(-1) } $guardError
Check 'reused runner and matching installer rejected' { $script:livePIDs=@(1928,9400); $script:startTimes[1928]=$script:startTimes[1928].AddTicks(1) } $guardError
Check 'spoofed name does not waive matching identity' { $script:livePIDs=@(1928); $script:processName='go-mapi-update-runner' } $guardError
Check 'same name does not block reuse' { $script:livePIDs=@(1928); $script:processName='go-mapi-update-runner'; $script:startTimes[1928]=$script:startTimes[1928].AddTicks(-1) } $null
Assert ($script:observations[0].value.processes.runner.createdAtUnixNano -ceq [long]1791764507267080000) 'Adjacent 100ns identity rounded'
Check 'UTC conversion and JSON retain exact Int64' { $script:livePIDs=@(1928); $script:startTimes[1928]=$script:startTimes[1928].ToLocalTime().AddTicks(1) } $null
$jsonReceipt=$script:observations[0].value | ConvertTo-Json -Depth 20 | ConvertFrom-Json
Assert ($jsonReceipt.processes.runner.createdAtUnixNano -is [long] -and $jsonReceipt.processes.runner.createdAtUnixNano -ceq [long]1791764507267080200) 'JSON lost exact observed Int64 identity'
Assert ($script:observations[0].value.processes.runner.identity.StartTime -eq '2026-10-12T00:21:47.2670802Z') 'UTC creation identity missing'
Check 'null image name does not block reuse' { $script:livePIDs=@(1928); $script:processName=$null; $script:startTimes[1928]=$script:startTimes[1928].AddTicks(1) } $null
Check 'identity read failure retained while presence still rejects' { $script:livePIDs=@(1928); $script:identityError=$true } $guardError
Assert (@($script:observations[0].value.processes.runner.readErrors).Count -eq 1) 'Identity read error omitted'
Check 'process lookup read error rejects' { $script:lookupError=$true } $guardError
Assert (@($script:observations[0].value.processes.runner.readErrors).Count -gt 0) 'Native lookup error omitted'
Check 'terminating lookup failure rejects' { $script:lookupError='throw' } $guardError
Check 'absence without native proof rejects' { $script:silentAbsence=$true } $guardError
Check 'wrong structured absence ID rejects' { $script:absenceId='UnexpectedLookupError' } $guardError
Check 'wrong structured absence category rejects' { $script:absenceCategory=[Management.Automation.ErrorCategory]::PermissionDenied } $guardError
Check 'wrong structured absence target rejects' { $script:absenceTargetOffset=1 } $guardError
foreach ($badTime in @($null,'not a DateTime',[DateTime]::new(639273613072670801L,[DateTimeKind]::Unspecified),[DateTime]::new([DateTime]::MaxValue.Ticks,[DateTimeKind]::Utc))) {
    Check "invalid creation time $badTime rejects" { $script:livePIDs=@(1928); $script:startTimes[1928]=$badTime } $guardError
}
Check 'mismatched observed PID rejects' { $script:livePIDs=@(1928); $script:wrongId=$true } $guardError
Check 'ambiguous process result rejects' { $script:livePIDs=@(1928); $script:ambiguous=$true } $guardError
Check 'floating expected creation identity rejects' { $script:record.runner.createdAtUnixNano=[double]1791764507267080100 } $guardError
Check 'string expected PID rejects' { $script:record.runner.pid='1928' } $guardError
Check 'nonpositive expected PID rejects' { $script:record.runner.pid=-1 } $guardError
Check 'zero owned products rejected' { $script:products=@() } $guardError
Check 'multiple owned products rejected' { $script:products=@($manifest.packages.systemB,$manifest.packages.systemB) } $guardError
Check 'foreign product rejected' { $script:products=@(@{ sku='system'; release='5.0.1-alpha.5'; msi='fixture-msi'; sha256='msi-hash'; identity=@{productCode='foreign'} }) } $guardError
Check 'marker drift rejected' { $script:snapshot.marker.packageRelease='foreign' } $guardError
Check 'service state drift rejected' { $script:snapshot.service.state='Stopped' } $guardError
Check 'transaction drift rejected' { $script:snapshot.pending.transactionId='foreign' } $guardError
Check 'attempt drift rejected' { $script:snapshot.pending.attempt=2 } $guardError
Check 'nonconservative phase rejected' { $script:snapshot.pending.phase='running' } $guardError
Check 'runner creation drift rejected' { $script:snapshot.pending.runner.createdAtUnixNano++ } $guardError
Check 'installer creation drift rejected' { $script:snapshot.pending.installer.createdAtUnixNano++ } $guardError
Check 'replay commit still rejected' { $script:snapshot.replay=@{sequence=42} } $guardError
Check 'changed uninstall fence still rejected' { $script:badFence=$true } 'Deferred cleanup lacks the exact final-uninstall fence refusal log' $true
Check 'missing uninstall refusal still rejected' { $script:badFenceText=$true } 'Deferred cleanup lacks the exact final-uninstall fence refusal log' $true
Check 'inventory read failure preserved with partial receipt' { $script:productError=$true } 'product inventory read failed'
Assert ($script:observations[0].value.readError -eq 'product inventory read failed') 'Inventory read error omitted'
Check 'snapshot read failure preserved with partial receipt' { $script:snapshotError=$true } 'snapshot read failed'
Assert ($script:observations[0].value.readError -eq 'snapshot read failed') 'Snapshot read error omitted'
Check 'observation write failure cannot become success' { $script:recordError=$true } 'guard observation write failed'
'QUALIFICATION: portable mocked guard controls; native Windows cleanup UNRUN.'
