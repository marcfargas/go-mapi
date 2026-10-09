[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepoRoot,
    [Parameter(Mandatory)][string] $RdpilotRoot,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string] $SourceSHA
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-bundle.psm1') -Force
foreach ($name in @('HOSTED_CAPABILITY_JOB_STARTED_QPC','HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY','HOSTED_CAPABILITY_JOB_STARTED_BOOT','HOSTED_CAPABILITY_NONBUILD_DONE_QPC','GITHUB_SHA','GITHUB_ENV')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) { throw "Required hosted build environment marker is missing: $name" }
}
$start=[long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC
$frequency=[long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY
$boot=[string]$env:HOSTED_CAPABILITY_JOB_STARTED_BOOT
$nonBuildDone=[long]$env:HOSTED_CAPABILITY_NONBUILD_DONE_QPC
$expectedSha=$SourceSHA.ToLowerInvariant()
$sample=Get-HostedCapabilityClockSample
$clock=Test-HostedCapabilityClock -ExpectedBootMarker $boot -ObservedBootMarker $sample.bootMarker -ExpectedFrequency $frequency -ObservedFrequency $sample.frequency -JobStartCounter $start -CurrentCounter $sample.counter
if (!$clock.valid) { throw ('Hosted build refused because cross-step clock is invalid: ' + ($clock.reasons -join ',')) }
$head=(& git -C $RepoRoot rev-parse HEAD).Trim().ToLowerInvariant()
$headExit=$LASTEXITCODE
$dirty=(& git -C $RepoRoot status --porcelain --untracked-files=all | Out-String).Trim()
if ($headExit -ne 0 -or $LASTEXITCODE -ne 0 -or $head -cne $expectedSha -or $head -cne $env:GITHUB_SHA.ToLowerInvariant() -or $dirty) {
    throw 'Hosted build requires clean checked-out HEAD equal to SourceSHA and GITHUB_SHA'
}
$cargo=(Get-Command cargo.exe -ErrorAction Stop).Source
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$name="Global\Ticket569-$RunId-build"
$sddl="D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
$job=$null
$child=$null
try {
    $job=New-HostedCapabilityJob -Name $name -DaclSddl $sddl
    $sample=Get-HostedCapabilityClockSample
    $clock=Test-HostedCapabilityClock -ExpectedBootMarker $boot -ObservedBootMarker $sample.bootMarker -ExpectedFrequency $frequency -ObservedFrequency $sample.frequency -JobStartCounter $start -CurrentCounter $sample.counter
    if (!$clock.valid) { throw ('Hosted build refused because pre-launch clock is invalid: ' + ($clock.reasons -join ',')) }
    $budget=Get-HostedCapabilityBuildAllowance -JobStartCounter $start -CounterFrequency $frequency -NonBuildCompleteCounter $nonBuildDone -NowCounter $sample.counter
    if (!$budget.allowed) { throw ('Pinned CUA build refused before worker launch: ' + $budget.reason) }
    $buildStartedCounter=[Diagnostics.Stopwatch]::GetTimestamp()
    $child=Start-HostedCapabilityProcess -Job $job -Executable $cargo -WorkingDirectory $RdpilotRoot -ArgumentList @(
        'build','--release','--locked','-p','rdpilot-cli','-p','rdpilot-daemon','-p','rdpilot-mcp','-p','rdpilot-bridge','--target','x86_64-pc-windows-msvc'
    )
    $deadline=[long]$start + 9L * 60L * $frequency
    $hardCap=[long]$buildStartedCounter + [long]420 * $frequency
    if ($hardCap -lt $deadline) { $deadline=$hardCap }
    while ($true) {
        if ($child.Wait(100)) {
            $sample=Get-HostedCapabilityClockSample
            $clock=Test-HostedCapabilityClock -ExpectedBootMarker $boot -ObservedBootMarker $sample.bootMarker -ExpectedFrequency $frequency -ObservedFrequency $sample.frequency -JobStartCounter $start -CurrentCounter $sample.counter
            if (!$clock.valid -or $sample.counter -ge $deadline) { throw 'Pinned rdpilot build did not complete within its clock-validated J+9 boundary' }
            if ($child.ExitCode -ne 0) { throw "Pinned rdpilot build exited $($child.ExitCode)" }
            break
        }
        $now=[Diagnostics.Stopwatch]::GetTimestamp()
        if ($now -ge $deadline) {
            $job.Terminate(137)
            $null=$job.Wait(5000)
            if ($job.ActiveProcesses -ne 0) { throw 'Pinned rdpilot cargo Job Object retained active processes after deadline' }
            throw 'Pinned rdpilot build exhausted min(7 minutes, remaining J+9 preparation time); worker was not launched'
        }
        $sample=Get-HostedCapabilityClockSample
        $clock=Test-HostedCapabilityClock -ExpectedBootMarker $boot -ObservedBootMarker $sample.bootMarker -ExpectedFrequency $frequency -ObservedFrequency $sample.frequency -JobStartCounter $start -CurrentCounter $sample.counter
        if (!$clock.valid) {
            $job.Terminate(137);$null=$job.Wait(5000)
            throw 'Pinned rdpilot build stopped because its job clock changed'
        }
    }
    $drainDeadline=[DateTime]::UtcNow.AddSeconds(5)
    while ($job.ActiveProcesses -ne 0 -and [DateTime]::UtcNow -lt $drainDeadline) { Start-Sleep -Milliseconds 25 }
    if ($job.ActiveProcesses -ne 0) {
        $job.Terminate(137)
        $drainDeadline=[DateTime]::UtcNow.AddSeconds(5)
        while ($job.ActiveProcesses -ne 0 -and [DateTime]::UtcNow -lt $drainDeadline) { Start-Sleep -Milliseconds 25 }
        throw 'Pinned rdpilot build returned before its Job Object process tree was empty'
    }
    $bin=Join-Path $RdpilotRoot 'target/x86_64-pc-windows-msvc/release'
    foreach ($file in @('rdpilot.exe','rdpilot-mcp.exe','rdpilot-daemon.exe','rdpilot-bridge.exe')) {
        if (!(Test-Path -LiteralPath (Join-Path $bin $file) -PathType Leaf)) { throw "Pinned rdpilot build omitted $file" }
    }
    foreach($name in @('HOSTED_CUA_ARCHIVE_PATH','HOSTED_CUA_ARCHIVE_RECEIPT_PATH')){if([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))){throw "Pre-J+2 guest CUA archive marker is missing: $name"}}
    $guestBundle=Initialize-HostedCapabilityCuaBundle -BinaryDirectory $bin -SourceSHA $expectedSha -PreparedArchivePath $env:HOSTED_CUA_ARCHIVE_PATH -PreparedReceiptPath $env:HOSTED_CUA_ARCHIVE_RECEIPT_PATH
    $sample=Get-HostedCapabilityClockSample
    $clock=Test-HostedCapabilityClock -ExpectedBootMarker $boot -ObservedBootMarker $sample.bootMarker -ExpectedFrequency $frequency -ObservedFrequency $sample.frequency -JobStartCounter $start -CurrentCounter $sample.counter
    if (!$clock.valid -or $sample.counter -ge ($start + 9L * 60L * $frequency)) { throw 'Pinned guest bundle preflight crossed the shared J+9 worker-launch boundary' }
    Write-Output ("PINNED_RDPILOT_GUEST_BUNDLE=" + $guestBundle.BundlePath)
    Write-Output ("PINNED_CUA_ARCHIVE_SHA256=" + $guestBundle.Receipt.cuaArchiveSHA256)
    "RDPILOT_BIN_DIR=$bin" | Add-Content -LiteralPath $env:GITHUB_ENV -Encoding utf8
    Write-Output "PINNED_RDPILOT_BUILD_EXIT=$($child.ExitCode)"
} finally {
    if ($child) { $child.Dispose() }
    if ($job) { $job.Dispose() }
}
