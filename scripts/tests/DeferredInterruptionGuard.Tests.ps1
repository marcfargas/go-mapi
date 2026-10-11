[CmdletBinding()]
param([string]$SourcePath = (Join-Path $PSScriptRoot '../run-machine-update-integration.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
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
    if ($script:lookupError) { Write-Error 'fixture process lookup read error'; return }
    if ($script:livePIDs -contains $Id) {
        $process=[pscustomobject]@{ Id=$Id; ProcessName='unrelated-pwsh'; SessionId=7; StartTime=[DateTime]::Parse('2026-10-12T00:26:58Z'); Path='C:\fixture\unrelated-pwsh.exe' }
        if ($script:identityError) { $process | Add-Member ScriptProperty StartTime { throw 'fixture identity read error' } -Force }
        $process
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
            Assert (($script:lookups -join ',') -eq '1928,9400') "$Name reprobed or omitted a native lookup"
            Assert ($script:productReads -eq 1 -and $script:snapshotReads -eq 1) "$Name reprobed state"
            Assert ($receipt.value.snapshot -eq $script:snapshot) "$Name receipt differs from consumed snapshot"
        }
    }
    Write-Output "PASS $Name"
}
$guardError='Deferred cleanup no longer matches exact conservative interruption state'
Check 'exact conservative state succeeds with exact receipt' {} $null $true
Check 'live runner still rejected without identity-based waiver' { $script:livePIDs=@(1928) } $guardError
Assert ($script:observations[0].value.processes.runner.identity.ProcessName -eq 'unrelated-pwsh') 'Live runner image identity missing'
Assert ($script:observations[0].value.processes.runner.identity.StartTime -eq '2026-10-12T00:26:58.0000000Z') 'Live runner creation identity missing'
Check 'live installer still rejected' { $script:livePIDs=@(9400) } $guardError
Check 'identity read failure retained while presence still rejects' { $script:livePIDs=@(1928); $script:identityError=$true } $guardError
Assert (@($script:observations[0].value.processes.runner.readErrors).Count -eq 1) 'Identity read error omitted'
Check 'process lookup read error retained with existing absence semantics' { $script:lookupError=$true } $null
Assert (@($script:observations[0].value.processes.runner.readErrors).Count -gt 0) 'Native lookup error omitted'
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
