# Native installed-service proof. Hosted runs on an elevated disposable Windows
# runner; the resumable phases require an external logout/reboot orchestrator.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageManifest,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateSet('system','suite')][string]$SKU = 'system',
    [ValidateSet('Hosted','PrepareNoUser','VerifyNoUser','InterruptSameBoot','PrepareReboot','VerifyReboot','Cleanup')][string]$Phase = 'Hosted',
    [int]$FixturePort = 18453,
    [int]$DeadlineMinutes = 35,
    [string]$DeferredInterruptionEvidence
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
$PackageManifest = [IO.Path]::GetFullPath($PackageManifest)
$manifest = Get-Content -LiteralPath $PackageManifest -Raw | ConvertFrom-Json
$caseA = "${SKU}A"; $caseB = "${SKU}B"; $caseC = "${SKU}C"
if (-not $manifest.packages.$caseA -or -not $manifest.packages.$caseB -or -not $manifest.packages.$caseC) {
    throw "Fixture manifest lacks complete $SKU A/B/C cases"
}
if ($manifest.schema -ne 'go-mapi-machine-test-packages-v1' -or $manifest.fixture.metadataOrigin -ne "https://localhost:$FixturePort" -or
    $manifest.fixture.artifactOrigin -ne "https://localhost:$FixturePort/releases/download/") { throw 'Fixture origin or package manifest mismatch' }
$wrongSkuSystem = if ($manifest.PSObject.Properties['references'] -and $manifest.references.PSObject.Properties['wrongSkuSystem']) {
    $manifest.references.wrongSkuSystem
} else { $null }
if ($wrongSkuSystem -and ($wrongSkuSystem.package.sku -cne 'system' -or
    (Get-FileHash -LiteralPath $wrongSkuSystem.sourceManifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $wrongSkuSystem.sourceManifestSha256 -or
    (Get-FileHash -LiteralPath $wrongSkuSystem.package.msi -Algorithm SHA256).Hash.ToLowerInvariant() -cne $wrongSkuSystem.package.sha256)) {
    throw 'Wrong-SKU system fixture reference changed'
}
$signing = if ($manifest.fixture.PSObject.Properties['signing']) { [string]$manifest.fixture.signing } elseif (
    $manifest.fixture.signerThumbprint -and $manifest.fixture.signerPublicCertificate) { 'self-signed-disposable' } else {
    throw 'Fixture signing provenance is missing and legacy self-signed fields are incomplete'
}
if ($signing -notin @('self-signed-disposable','pre-signed-Azure')) { throw 'Unknown fixture signing provenance' }
$azureSigned = $signing -eq 'pre-signed-Azure'
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$fixture = Join-Path $evidence 'fixture'
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$ownerPath = Join-Path $evidence 'owner.json'
$events = Join-Path $evidence 'events.ndjson'
$stateDir = Join-Path $env:ProgramData 'go-mapi\service'
$statusPath = Join-Path $env:ProgramData 'go-mapi\status\status-v2.json'
$markerPath = 'HKLM:\SOFTWARE\go-mapi\MachineProduct'
$signer = [string]$manifest.fixture.signerThumbprint
$runId = [guid]::NewGuid().ToString('N')
$overallDeadline = [DateTime]::UtcNow.AddMinutes($DeadlineMinutes)
function WriteJson([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false)) }
function Record([string]$Kind, $Value) {
    Add-Content -LiteralPath $events -Value (([ordered]@{ atUtc=[DateTime]::UtcNow.ToString('o'); kind=$Kind; value=$Value }) | ConvertTo-Json -Depth 10 -Compress) -Encoding utf8
}
function ReadJson([string]$Path) { if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } else { $null } }
function Hash([string]$Path) { if (Test-Path -LiteralPath $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null } }
function Snapshot {
    $marker = Get-ItemProperty -LiteralPath $markerPath -ErrorAction SilentlyContinue
    $service = Get-CimInstance Win32_Service -Filter "Name='go-mapi'" -ErrorAction SilentlyContinue
    $exe = Join-Path $env:ProgramFiles 'go-mapi\service\go-mapi-service.exe'
    $pending = ReadJson (Join-Path $stateDir 'pending-v2.json')
    $replay = ReadJson (Join-Path $stateDir "replay-$SKU-v1.json")
    $result = ReadJson (Join-Path $stateDir 'last-result-v1.json')
    [ordered]@{
        marker=if ($marker) { [ordered]@{ sku=$marker.SKU; packageRelease=$marker.PackageRelease; serviceVersion=$marker.ServiceVersion; autoUpdateEnabled=$marker.AutoUpdateEnabled } } else { $null }
        service=if ($service) { [ordered]@{ name=$service.Name; state=$service.State; startName=$service.StartName; startMode=$service.StartMode; processId=$service.ProcessId; path=$service.PathName; executableSha256=Hash $exe } } else { $null }
        status=ReadJson $statusPath; pending=$pending; replay=$replay; lastResult=$result
        legacyTaskCount=@(Get-ScheduledTask -TaskName 'go-mapi Auto Update' -ErrorAction SilentlyContinue).Count
    }
}
function AssertHealthy([string]$Key) {
    $snapshot = Snapshot
    $package = $manifest.packages.$Key
    if (-not $snapshot.marker -or $snapshot.marker.sku -ne $SKU -or $snapshot.marker.packageRelease -ne $package.release -or
        $snapshot.marker.serviceVersion -ne $package.serviceVersion -or $snapshot.service.state -ne 'Running' -or
        $snapshot.service.startName -ne 'LocalSystem' -or $snapshot.service.startMode -ne 'Auto' -or
        $snapshot.service.executableSha256 -ne $package.serviceSha256 -or $snapshot.status.health -ne 'healthy' -or
        $snapshot.legacyTaskCount -ne 0) { throw "Installed $Key is not healthy" }
    if ($SKU -eq 'suite') {
        $dll64 = Join-Path $env:ProgramFiles 'go-mapi\interceptor\AMD64\go-mapi.dll'
        $dll86 = Join-Path $env:ProgramFiles 'go-mapi\interceptor\x86\go-mapi.dll'
        $app = Join-Path $env:ProgramFiles 'go-mapi\user\go-mapi.exe'
        if ((Hash $dll64) -ne $package.x64DllSha256 -or (Hash $dll86) -ne $package.x86DllSha256 -or
            (Hash $app) -ne $package.appSha256) { throw "Installed $Key component bytes differ" }
    }
    $snapshot
}
function Until([string]$Label, [scriptblock]$Condition, [int]$Minutes = $DeadlineMinutes) {
    $end = [DateTime]::UtcNow.AddMinutes($Minutes)
    if ($end -gt $script:overallDeadline) { $end = $script:overallDeadline }
    while ([DateTime]::UtcNow -lt $end) {
        try { $result = & $Condition; if ($result) { return $result } } catch { Record 'poll-error' "$Label`: $($_.Exception.Message)" }
        Start-Sleep -Seconds 5
    }
    Record 'deadline-snapshot' (Snapshot)
    throw "Deadline waiting for $Label"
}
function Msi([string]$Verb, [string]$Path, [string]$Label, [string[]]$Properties = @()) {
    $log = Join-Path $evidence "$Label-msi.log"
    $args = @($Verb, ('"' + $Path + '"'), '/qn', '/norestart') + $(if ($SKU -eq 'suite') { @('MSIRESTARTMANAGERCONTROL=Disable') } else { @('MSIRMSHUTDOWN=0') }) + $Properties + @('/l*v', ('"' + $log + '"'))
    $process = Start-Process msiexec.exe -ArgumentList $args -PassThru
    if (-not $process.WaitForExit(600000)) {
        Record 'administrator-msi-timeout' ([ordered]@{ label=$Label; pid=$process.Id; log=$log })
        throw "$Label exceeded the ten-minute MSI deadline; inspect the live installer and log before cleanup"
    }
    Record 'administrator-msi' ([ordered]@{ label=$Label; exitCode=$process.ExitCode; log=$log })
    if ($process.ExitCode -ne 0) { throw "$Label returned $($process.ExitCode); postboot proof is required for 3010/1641" }
}
function Target([string]$Key, [string]$MinimumService, [string]$TargetSKU = $SKU) {
    $package = if ($Key -eq 'systemB' -and $SKU -eq 'suite' -and $wrongSkuSystem) {
        $wrongSkuSystem.package
    } else { $manifest.packages.$Key }
    if (-not $package) { throw "Missing target fixture $Key" }
    $specPath = Join-Path $fixture "$Key-spec.json"
    $targetPath = Join-Path $fixture "$Key-targets.json"
    $spec = [ordered]@{
        sku=$TargetSKU; packageRelease=$package.release
        contained=@(@{component='service';version=$package.serviceVersion},@{component='interceptor';version=$package.interceptorVersion})
        compatibility=@(@{component='service';minInclusive=$MinimumService;maxExclusive='7.0.0'},@{component='interceptor';minInclusive='4.0.0';maxExclusive='7.0.0'})
        issuedAt=[DateTime]::UtcNow.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
        expiresAt=[DateTime]::UtcNow.AddDays(1).ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    if ($TargetSKU -eq 'suite') {
        $spec.contained += @{component='app';version=$package.appVersion}
        $spec.compatibility += @{component='app';minInclusive=$manifest.packages.$caseA.appVersion;maxExclusive='7.0.0'}
    }
    WriteJson $specPath $spec
    Push-Location $repo
    try { & go run ./internal/mapi/cmd/machine-targets --spec $specPath --msi $package.msi --out $targetPath --artifact-origin $manifest.fixture.artifactOrigin }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $targetPath)) { throw "Target generation failed: $Key" }
    Record 'target' ([ordered]@{ key=$Key; sha256=Hash $targetPath; msiSha256=$package.sha256 })
}
function SelectTarget([string]$Key) {
    $next = Join-Path $fixture 'target-selection.next.json'
    WriteJson $next ([ordered]@{ $SKU=$Key; selectedAtUtc=[DateTime]::UtcNow.ToString('o') })
    Move-Item -LiteralPath $next -Destination (Join-Path $fixture 'target-selection.json') -Force
    Record 'publish-target' $Key
}
function SelectWrongSkuTarget([string]$Key) {
    $package = if ($Key -eq 'systemB' -and $SKU -eq 'suite' -and $wrongSkuSystem) {
        $wrongSkuSystem.package
    } else { $manifest.packages.$Key }
    if (-not $package -or $package.sku -eq $SKU) { throw 'Negative target must use the other SKU' }
    $next = Join-Path $fixture 'target-selection.next.json'
    WriteJson $next ([ordered]@{ $SKU=$Key; negativeWrongSku=$true; selectedAtUtc=[DateTime]::UtcNow.ToString('o') })
    Move-Item -LiteralPath $next -Destination (Join-Path $fixture 'target-selection.json') -Force
    Record 'publish-wrong-sku-target' $Key
}
function RequestCount([string]$Path) {
    if (-not (Test-Path -LiteralPath (Join-Path $fixture 'requests.ndjson'))) { return 0 }
    return @(Get-Content -LiteralPath (Join-Path $fixture 'requests.ndjson') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.path -ceq $Path -and $_.status -eq 200 }).Count
}
function RemoveSignerTrust {
    if ($azureSigned) { throw 'Azure signing trust is outside fixture ownership' }
    foreach ($store in @('Root','TrustedPublisher')) {
        $path = "Cert:\LocalMachine\$store\$signer"
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Record 'signer-trust-removed' $signer
}
function RestoreSignerTrust {
    if ($azureSigned) { return }
    $certificate = [string]$manifest.fixture.signerPublicCertificate
    if (-not (Test-Path -LiteralPath $certificate)) { throw 'Missing owned signer public certificate' }
    $public = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certificate)
    if ($public.Thumbprint -ne $signer) { throw 'Owned signer public certificate differs from package manifest' }
    foreach ($store in @('Root','TrustedPublisher')) { Import-Certificate -FilePath $certificate -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null }
    if (-not (Test-Path "Cert:\LocalMachine\Root\$signer") -or
        -not (Test-Path "Cert:\LocalMachine\TrustedPublisher\$signer")) { throw 'Owned signer trust restoration failed' }
    Record 'signer-trust-restored' $signer
}
function InstallFixture {
    if (Test-Path -LiteralPath $ownerPath) { throw 'Fixture owner record already exists' }
    & netsh http show sslcert "hostnameport=localhost:$FixturePort" *> $null
    if ($LASTEXITCODE -eq 0) { throw "HTTPS hostnameport localhost:$FixturePort already has a binding" }
    $tls = New-SelfSignedCertificate -DnsName localhost -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddDays(2)
    $appId = [guid]::NewGuid().ToString('B')
    $owner = [ordered]@{ runId=$runId; tlsThumbprint=$tls.Thumbprint; signerThumbprint=$signer; appId=$appId; port=$FixturePort; bootTimeUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o'); packageManifest=[IO.Path]::GetFullPath($PackageManifest); fixturePid=$null }
    WriteJson $ownerPath $owner
    $tlsPublic = Join-Path $fixture 'test-tls.cer'
    Export-Certificate -Cert $tls -FilePath $tlsPublic | Out-Null
    Import-Certificate -FilePath $tlsPublic -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    & netsh http add sslcert "hostnameport=localhost:$FixturePort" "certhash=$($tls.Thumbprint)" "appid=$appId" 'certstorename=MY' | Out-File (Join-Path $fixture 'netsh-add.log')
    if ($LASTEXITCODE -ne 0) { throw 'HTTPS fixture binding failed' }
    $args = @('-NoProfile','-File',('"' + (Join-Path $PSScriptRoot 'machine-update-https-fixture.ps1') + '"'),'-PackageManifest',('"' + $PackageManifest + '"'),'-FixtureDirectory',('"' + $fixture + '"'),'-Port',"$FixturePort")
    $child = Start-Process pwsh -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $fixture 'stdout.log') -RedirectStandardError (Join-Path $fixture 'stderr.log')
    $owner.fixturePid = $child.Id
    WriteJson $ownerPath $owner
    Until 'HTTPS fixture start' { (Invoke-WebRequest -Uri "https://localhost:$FixturePort/machine/suite/targets.json" -TimeoutSec 3 -SkipHttpErrorCheck).StatusCode -eq 404 } 2 | Out-Null
    Record 'fixture-start' $owner
}
function Cleanup {
    $owner = ReadJson $ownerPath
    if ($owner) {
        Set-Content -LiteralPath (Join-Path $fixture 'stop') -Value 'stop'
        $owned = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'machine-update-https-fixture\.ps1' -and $_.CommandLine.Contains($fixture) })
        foreach ($entry in $owned) {
            $child = Get-Process -Id $entry.ProcessId -ErrorAction SilentlyContinue
            if ($child) { $child.WaitForExit(3000) | Out-Null; if (-not $child.HasExited) { Stop-Process -Id $entry.ProcessId -Force } }
        }
        & netsh http delete sslcert "hostnameport=localhost:$($owner.port)" | Out-File (Join-Path $fixture 'netsh-delete.log')
        & netsh http show sslcert "hostnameport=localhost:$($owner.port)" *> $null
        if ($LASTEXITCODE -eq 0) { throw 'Owned HTTPS binding remains after cleanup' }
        foreach ($store in @('Root','My')) {
            $path = "Cert:\LocalMachine\$store\$($owner.tlsThumbprint)"
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        $task = "go-mapi-ci-fixture-$($owner.runId)"
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    }
    if (-not $azureSigned) {
        foreach ($store in @('Root','TrustedPublisher','My')) {
            $path = "Cert:\LocalMachine\$store\$signer"
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        foreach ($store in @('Root','TrustedPublisher','My')) {
            if (Test-Path "Cert:\LocalMachine\$store\$signer") { throw "Owned signer remains in $store after cleanup" }
        }
    }
    Record 'cleanup' ([ordered]@{ fixtureRemoved=$true; signerRemoved=(-not $azureSigned) })
}
function FindOwnedPackage([string]$FamilySku, [string]$ProductCode) {
    $matches = @($manifest.packages.PSObject.Properties | ForEach-Object Value |
        Where-Object { $_ -and $_.sku -eq $FamilySku -and $_.identity.productCode.Trim('{}') -eq $ProductCode.Trim('{}') } |
        Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}
function InstalledTestProducts {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $found = @()
    foreach ($family in @(
        @{ sku='system'; code='{B3C97B33-3F10-47CA-9FA7-24EE3B75E325}' },
        @{ sku='suite'; code='{2E050A24-94A2-4FC9-B176-C5CCC1225FE6}' }
    )) {
        $related = @($installer.GetType().InvokeMember('RelatedProducts','GetProperty',$null,$installer,@($family.code)) | Where-Object { $_ })
        foreach ($code in $related) {
            $package = FindOwnedPackage $family.sku ([string]$code)
            if (-not $package) { throw "Foreign $($family.sku) product $code exists; refusing to remove it" }
            $found += $package
        }
    }
    return $found
}
function RemoveInstalledTestProducts {
    foreach ($package in @(InstalledTestProducts)) { Msi '/x' $package.msi "cleanup-$($package.sku)-$($package.release)" }
    if (@(InstalledTestProducts).Count -ne 0 -or (Get-Service go-mapi -ErrorAction SilentlyContinue)) {
        throw 'Owned machine package or service remains after cleanup'
    }
}
function ConfirmDeferredInterruption($record, [bool]$RequireFenceProof = $false) {
    if (-not $record -or $record.schema -ne 'go-mapi-interruption-cleanup-deferral-v1' -or
        $record.packageManifestSha256 -ne (Hash $PackageManifest) -or
        $record.systemBMsiSha256 -ne (Hash $manifest.packages.$caseB.msi) -or
        $record.installedProductCode -ne $manifest.packages.$caseB.identity.productCode -or
        $record.installedRelease -ne $manifest.packages.$caseB.release) { throw 'Deferred cleanup evidence does not match current package inputs' }
    $products = @(InstalledTestProducts)
    $snapshot = Snapshot
    if ($products.Count -ne 1 -or $products[0].identity.productCode -ne $record.installedProductCode -or
        -not $snapshot.marker -or $snapshot.marker.packageRelease -ne $record.installedRelease -or
        $snapshot.service.state -ne 'Running' -or -not $snapshot.pending -or
        $snapshot.pending.transactionId -ne $record.transactionId -or $snapshot.pending.attempt -ne $record.attempt -or
        $snapshot.pending.phase -ne 'outcome-unconfirmed' -or
        $snapshot.pending.runner.pid -ne $record.runner.pid -or
        $snapshot.pending.runner.createdAtUnixNano -ne $record.runner.createdAtUnixNano -or
        $snapshot.pending.installer.pid -ne $record.installer.pid -or
        $snapshot.pending.installer.createdAtUnixNano -ne $record.installer.createdAtUnixNano -or
        (Get-Process -Id $record.runner.pid -ErrorAction SilentlyContinue) -or
        (Get-Process -Id $record.installer.pid -ErrorAction SilentlyContinue) -or
        ($snapshot.replay -and $snapshot.replay.sequence -eq $manifest.packages.$caseB.identity.sequence)) {
        throw 'Deferred cleanup no longer matches exact conservative interruption state'
    }
    if ($RequireFenceProof) {
        if (-not $record.uninstallFenceLog -or -not $record.uninstallFenceLogSha256 -or
            (Hash $record.uninstallFenceLog) -ne $record.uninstallFenceLogSha256 -or
            -not (Select-String -LiteralPath $record.uninstallFenceLog -Pattern 'Resident uninstall fence refused the operation' -Quiet)) {
            throw 'Deferred cleanup lacks the exact final-uninstall fence refusal log'
        }
    }
    return $snapshot
}
function DeferInterruptedProductCleanup($witness) {
    $products = @(InstalledTestProducts)
    if ($products.Count -ne 1) { throw 'Exactly one manifest-owned product is required for interruption deferral' }
    $package = $products[0]
    if ($package.identity.productCode -ne $manifest.packages.$caseB.identity.productCode -or
        $package.release -ne $manifest.packages.$caseB.release) { throw "Interruption deferral requires exact installed $caseB" }
    $record = [ordered]@{
        schema='go-mapi-interruption-cleanup-deferral-v1'; packageManifestSha256=Hash $PackageManifest
        systemBMsiSha256=Hash $manifest.packages.$caseB.msi
        transactionId=$witness.pending.transactionId; attempt=$witness.pending.attempt
        runner=$witness.pending.runner; installer=$witness.pending.installer
        installedProductCode=$package.identity.productCode; installedRelease=$package.release
        reason='Final uninstall is fenced while the exact interrupted transaction remains pending; ephemeral runner disposal removes the test product.'
    }
    ConfirmDeferredInterruption $record | Out-Null
    $label = "cleanup-$($package.sku)-$($package.release)"
    $log = Join-Path $evidence "$label-msi.log"
    try { Msi '/x' $package.msi $label; throw 'Uninstall unexpectedly succeeded while interrupted transaction remained pending' }
    catch {
        if ($_.Exception.Message -notmatch [regex]::Escape("$label returned 1603") -or
            -not (Test-Path -LiteralPath $log) -or
            -not (Select-String -LiteralPath $log -Pattern 'Resident uninstall fence refused the operation' -Quiet)) { throw }
    }
    ConfirmDeferredInterruption $record | Out-Null
    $record['uninstallFenceLog'] = $log
    $record['uninstallFenceLogSha256'] = Hash $log
    $record['recordedAtUtc'] = [DateTime]::UtcNow.ToString('o')
    WriteJson (Join-Path $evidence 'cleanup-deferred.json') $record
    Record 'cleanup-deferred-to-ephemeral-runner-disposal' $record
    return $record
}
function AssertNoInteractiveUser {
    $sessions = @(quser 2>$null | Select-Object -Skip 1 | Where-Object { $_ -match '\b(Active|Disc)\b' })
    if ($sessions.Count -ne 0) { throw 'Interactive session exists; no-user phase cannot claim proof' }
}
function MatchingLiveTransaction($Pending) {
    if (-not $Pending -or $Pending.phase -notin @('running','installer-running') -or -not $Pending.runner -or -not $Pending.installer) { return $false }
    $ready = ReadJson (Join-Path $stateDir "ready-$($Pending.transactionId)-attempt-$($Pending.attempt)-v1.json")
    if (-not $ready -or $ready.transactionId -ne $Pending.transactionId -or $ready.runner.pid -ne $Pending.runner.pid -or
        $ready.installer.pid -ne $Pending.installer.pid -or $ready.runner.createdAtUnixNano -ne $Pending.runner.createdAtUnixNano -or
        $ready.installer.createdAtUnixNano -ne $Pending.installer.createdAtUnixNano) { return $false }
    $runner = Get-Process -Id $Pending.runner.pid -ErrorAction SilentlyContinue
    $installer = Get-Process -Id $Pending.installer.pid -ErrorAction SilentlyContinue
    if (-not $runner -or -not $installer -or -not $runner.Path.EndsWith('go-mapi-update-runner.exe') -or
        -not $installer.Path.EndsWith('msiexec.exe')) { return $false }
    $runnerNanos = ([int64]$runner.StartTime.ToUniversalTime().Ticks - 621355968000000000L) * 100L
    $installerNanos = ([int64]$installer.StartTime.ToUniversalTime().Ticks - 621355968000000000L) * 100L
    if ($runnerNanos -ne $Pending.runner.createdAtUnixNano -or $installerNanos -ne $Pending.installer.createdAtUnixNano) { return $false }
    $runnerCommand = Get-CimInstance Win32_Process -Filter "ProcessId=$($Pending.runner.pid)"
    $installerCommand = Get-CimInstance Win32_Process -Filter "ProcessId=$($Pending.installer.pid)"
    if ($runnerCommand.CommandLine -notmatch [regex]::Escape($Pending.transactionId) -or $installerCommand.CommandLine -notmatch '/qn') { return $false }
    return $true
}
function AssertCommitted([string]$Key, [int]$PreviousPid) {
    $package = $manifest.packages.$Key
    $snapshot = AssertHealthy $Key
    if ($snapshot.pending -or $snapshot.replay.sequence -ne $package.identity.sequence -or
        $snapshot.lastResult.result -ne 'installed' -or $snapshot.lastResult.sequence -ne $package.identity.sequence -or
        ($SKU -eq 'system' -and $snapshot.service.processId -eq $PreviousPid)) { throw "$Key did not commit on a healthy installed unit" }
    Record 'committed' ([ordered]@{ key=$Key; snapshot=$snapshot })
    return $snapshot
}

$passed = $false
$cleanupOnExit = $Phase -eq 'Hosted' -or $Phase -eq 'InterruptSameBoot' -or $Phase -eq 'Cleanup'
$cleanupError = $null
$cleanupDeferred = $null
$cleanMachineConfirmed = $false
try {
    if ($Phase -eq 'Cleanup') {
        Record 'cleanup-requested' ([ordered]@{ packageManifest=$PackageManifest; owner=ReadJson $ownerPath })
    } elseif ($Phase -in @('Hosted','PrepareNoUser','InterruptSameBoot','PrepareReboot')) {
        if ((Get-Service go-mapi -ErrorAction SilentlyContinue) -or @(InstalledTestProducts).Count -ne 0 -or
            (Get-ScheduledTask -TaskName 'go-mapi Auto Update' -ErrorAction SilentlyContinue)) {
            throw 'Clean machine required: go-mapi service, machine product or legacy task already exists'
        }
        $cleanMachineConfirmed = $true
        # A preceding Hosted phase removes fixture trust in finally. Reimport
        # only the exact public certificate bound in the package manifest;
        # the signed MSI bytes and private key are never regenerated.
        RestoreSignerTrust
        InstallFixture
        Target $caseA $manifest.packages.$caseA.serviceVersion
        Target $caseB $manifest.packages.$caseA.serviceVersion
        Target $caseC $manifest.packages.$caseB.serviceVersion
        if ($SKU -eq 'suite' -and $Phase -eq 'Hosted') { Target 'systemB' $manifest.packages.$caseA.serviceVersion 'system' }
        if ($Phase -eq 'PrepareNoUser') { SelectTarget $caseA }
        Msi '/i' $manifest.packages.$caseA.msi 'bootstrap-A' @('GOMAPI_AUTO_UPDATE=1')
        $a = Until 'healthy A' { $s=Snapshot; if ($s.status.health -eq 'healthy' -and $s.marker.packageRelease -eq $manifest.packages.$caseA.release) { $s } } 3
        Record 'bootstrap' $a
        $owner = ReadJson $ownerPath
        $owner | Add-Member -NotePropertyName baselineServicePid -NotePropertyValue $a.service.processId
        WriteJson $ownerPath $owner
        if ($Phase -ne 'PrepareNoUser') {
            if ($SKU -eq 'suite' -and $Phase -eq 'Hosted') {
                $priorDiscovery = ReadJson (Join-Path $stateDir "discovery-$SKU-v1.json")
                $beforeFailures = if ($priorDiscovery) { [int]$priorDiscovery.failures } else { 0 }
                $beforeRequests = RequestCount '/machine/suite/targets.json'
                SelectWrongSkuTarget 'systemB'
                Until 'wrong-SKU rejection' {
                    $s=Snapshot; $d=ReadJson (Join-Path $stateDir "discovery-$SKU-v1.json")
                    if ($d -and (RequestCount '/machine/suite/targets.json') -gt $beforeRequests -and $d.failures -gt $beforeFailures -and
                        $s.marker.packageRelease -eq $manifest.packages.$caseA.release -and -not $s.pending) { $s }
                } | ForEach-Object { Record 'wrong-sku-refused' $_ }
            }
            SelectTarget $caseB
        }
    }
    if ($Phase -eq 'Hosted') {
        $b = Until 'automatic B commit' { $s=Snapshot; if ($s.marker.packageRelease -eq $manifest.packages.$caseB.release -and $s.status.health -eq 'healthy' -and -not $s.pending -and $s.replay.sequence -eq $manifest.packages.$caseB.identity.sequence) { $s } }
        $b = AssertCommitted $caseB $a.service.processId
        $beforeFailures = (ReadJson (Join-Path $stateDir "discovery-$SKU-v1.json")).failures
        $beforeReplay = $b.replay.sequence
        if (-not $azureSigned) {
        RemoveSignerTrust
        $owner = ReadJson $ownerPath
        if ((Test-Path "Cert:\LocalMachine\Root\$signer") -or (Test-Path "Cert:\LocalMachine\TrustedPublisher\$signer") -or
            -not (Test-Path "Cert:\LocalMachine\Root\$($owner.tlsThumbprint)") -or
            (Hash $manifest.packages.$caseC.msi) -ne $manifest.packages.$caseC.sha256) {
            throw 'Owned code-signing trust removal or independent TLS trust is inconsistent'
        }
        Record 'C-owned-trust-removed' ([ordered]@{ signer=$signer; tlsThumbprint=$owner.tlsThumbprint; msiSha256=$manifest.packages.$caseC.sha256 })
        # A restart makes the changed machine certificate trust visible to the
        # service's WinHTTP/WinVerifyTrust process without changing its engine.
        Restart-Service go-mapi -Force
        $cPath = "/releases/download/$($manifest.packages.$caseC.identity.tag)/$($manifest.packages.$caseC.identity.assetName)"
        SelectTarget $caseC
        Until 'untrusted C rejection after artifact GET' {
            $s=Snapshot; $d=ReadJson (Join-Path $stateDir "discovery-$SKU-v1.json")
            if ((RequestCount $cPath) -gt 0 -and $d.failures -gt $beforeFailures -and $s.marker.packageRelease -eq $manifest.packages.$caseB.release -and
                $s.status.health -eq 'healthy' -and -not $s.pending -and $s.replay.sequence -eq $beforeReplay) { $s }
        } | ForEach-Object { Record 'untrusted-C-refused' $_ }
        RestoreSignerTrust
        if ((Hash $manifest.packages.$caseC.msi) -ne $manifest.packages.$caseC.sha256) { throw 'C MSI bytes changed across trust restoration' }
        Restart-Service go-mapi -Force
        } else {
            if ((Hash $manifest.packages.$caseC.msi) -ne $manifest.packages.$caseC.sha256) { throw 'Azure-signed C MSI bytes changed' }
            SelectTarget $caseC
        }
        $c = Until 'automatic C commit after trust restoration' { $s=Snapshot; if ($s.marker.packageRelease -eq $manifest.packages.$caseC.release -and $s.status.health -eq 'healthy' -and -not $s.pending -and $s.replay.sequence -eq $manifest.packages.$caseC.identity.sequence) { $s } } 28
        $c = AssertCommitted $caseC $b.service.processId
        Msi '/i' $manifest.packages.$caseC.msi 'administrator-disable' @('REINSTALL=ALL','REINSTALLMODE=amus','GOMAPI_AUTO_UPDATE=0')
        $disabled = AssertHealthy $caseC
        if ($disabled.marker.autoUpdateEnabled -ne 0) { throw 'Administrator disable did not persist' }
        $requestsBefore = if (Test-Path (Join-Path $fixture 'requests.ndjson')) { (Get-Content (Join-Path $fixture 'requests.ndjson') -Raw) } else { '' }
        Restart-Service go-mapi -Force
        if ([DateTime]::UtcNow.AddSeconds(185) -gt $overallDeadline) { throw 'Insufficient test deadline for disabled full startup/cadence window' }
        Start-Sleep -Seconds 185 # exceeds the production two-minute startup delay and one 60-second cadence
        $requestsAfter = if (Test-Path (Join-Path $fixture 'requests.ndjson')) { (Get-Content (Join-Path $fixture 'requests.ndjson') -Raw) } else { '' }
        $disabled = AssertHealthy $caseC
        if ($requestsBefore -cne $requestsAfter -or $disabled.pending -or $disabled.marker.autoUpdateEnabled -ne 0 -or $disabled.status.updates -ne 'disabled') { throw 'Disabled resident service issued a request or changed installed state' }
        Record 'disabled-window' ([ordered]@{ seconds=185; snapshot=$disabled })
    } elseif ($Phase -eq 'PrepareNoUser') {
        Record 'await-external-logoff' (Snapshot)
    } elseif ($Phase -eq 'VerifyNoUser') {
        AssertNoInteractiveUser
        if (-not (Test-Path -LiteralPath $ownerPath)) { throw 'No owned preparation fixture exists' }
        $baseline = AssertHealthy $caseA
        if ($baseline.pending -or ($baseline.replay -and $baseline.replay.sequence -ge $manifest.packages.$caseB.identity.sequence)) {
            throw 'No-user baseline already has a pending or committed B update before publication'
        }
        Record 'no-user-before-publication' $baseline
        SelectTarget $caseB
        Until 'no-user automatic B commit' { $x=Snapshot; if ($x.marker.packageRelease -eq $manifest.packages.$caseB.release -and $x.status.health -eq 'healthy' -and $x.replay.sequence -eq $manifest.packages.$caseB.identity.sequence -and -not $x.pending) { $x } } | Out-Null
        $b = AssertCommitted $caseB $baseline.service.processId
        AssertNoInteractiveUser
        SelectTarget $caseC
        Until 'no-user automatic C commit' { $x=Snapshot; if ($x.marker.packageRelease -eq $manifest.packages.$caseC.release -and $x.status.health -eq 'healthy' -and $x.replay.sequence -eq $manifest.packages.$caseC.identity.sequence -and -not $x.pending) { $x } } | Out-Null
        $c = AssertCommitted $caseC $b.service.processId
        AssertNoInteractiveUser
        Record 'no-user-A-B-C-committed' $c
    } elseif ($Phase -eq 'InterruptSameBoot') {
        $pending = Until 'matching runner and installer liveness' {
            $p=ReadJson (Join-Path $stateDir 'pending-v2.json')
            if ($p -and $p.candidate.packageVersion -eq $manifest.packages.$caseB.release -and (MatchingLiveTransaction $p)) { $p }
        } 12
        Record 'interruption-observed' $pending
        if (-not (MatchingLiveTransaction $pending)) { throw 'Exact runner/installer identity changed before interruption' }
        Stop-Process -Id $pending.runner.pid -Force
        $sameboot = Until 'conservative same-boot reconciliation' {
            $s=Snapshot
            $installer=Get-Process -Id $pending.installer.pid -ErrorAction SilentlyContinue
            if (-not $installer -and (-not $s.replay -or $s.replay.sequence -ne $manifest.packages.$caseB.identity.sequence) -and
                $s.pending -and $s.pending.phase -in @('outcome-unconfirmed','repair-required','reboot-pending','rolled-back')) { $s }
        } 8
        Record 'sameboot-conservative' $sameboot
    } elseif ($Phase -eq 'PrepareReboot') {
        $pending = Until 'matching pending before external reboot' {
            $p=ReadJson (Join-Path $stateDir 'pending-v2.json')
            if ($p -and $p.candidate.packageVersion -eq $manifest.packages.$caseB.release -and (MatchingLiveTransaction $p)) { $p }
        } 12
        $owner = ReadJson $ownerPath
        $task = "go-mapi-ci-fixture-$($owner.runId)"
        $action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument ("-NoProfile -File `"$PSScriptRoot\machine-update-https-fixture.ps1`" -PackageManifest `"$PackageManifest`" -FixtureDirectory `"$fixture`" -Port $FixturePort")
        $trigger = New-ScheduledTaskTrigger -AtStartup
        Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest | Out-Null
        if (-not (MatchingLiveTransaction $pending)) { throw 'Exact runner/installer identity changed before reboot interruption' }
        Stop-Process -Id $pending.runner.pid -Force
        WriteJson (Join-Path $evidence 'reboot-intent.json') ([ordered]@{ bootTimeUtc=$owner.bootTimeUtc; requestedAtUtc=[DateTime]::UtcNow.ToString('o'); transactionId=$pending.transactionId; attempt=$pending.attempt; runner=$pending.runner; installer=$pending.installer })
        Record 'interrupted-runner-and-immediate-reboot-request' ([ordered]@{ bootTimeUtc=$owner.bootTimeUtc; task=$task; pending=$pending; snapshot=Snapshot })
        & shutdown.exe /r /t 0
        if ($LASTEXITCODE -ne 0) { throw 'Windows rejected immediate test reboot request' }
    } elseif ($Phase -eq 'VerifyReboot') {
        $owner = ReadJson $ownerPath
        $intent = ReadJson (Join-Path $evidence 'reboot-intent.json')
        $startup = ReadJson (Join-Path $fixture 'startup-pending.json')
        if (-not $intent -or -not $startup -or $startup.pending.transactionId -ne $intent.transactionId -or
            $startup.pending.attempt -ne $intent.attempt -or $startup.pending.runner.pid -ne $intent.runner.pid -or
            $startup.pending.installer.pid -ne $intent.installer.pid -or
            [DateTime]::Parse($startup.bootTimeUtc) -le [DateTime]::Parse($intent.bootTimeUtc)) {
            throw 'No matching pending transaction was captured at startup after the test reboot'
        }
        if ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime() -le [DateTime]::Parse($owner.bootTimeUtc)) { throw 'Boot identity did not change' }
        Until 'postboot healthy B reconciliation' { $x=Snapshot; if ($x.marker.packageRelease -eq $manifest.packages.$caseB.release -and $x.status.health -eq 'healthy' -and -not $x.pending -and $x.replay.sequence -eq $manifest.packages.$caseB.identity.sequence) { $x } } | Out-Null
        $b = AssertCommitted $caseB $owner.baselineServicePid
        SelectTarget $caseC
        Until 'postboot automatic C commit' { $x=Snapshot; if ($x.marker.packageRelease -eq $manifest.packages.$caseC.release -and $x.status.health -eq 'healthy' -and -not $x.pending -and $x.replay.sequence -eq $manifest.packages.$caseC.identity.sequence) { $x } } | Out-Null
        $c = AssertCommitted $caseC $b.service.processId
        Record 'postboot-C-committed' $c
        $cleanupOnExit = $true
    }
    $passed = $true
} catch {
    Record 'failure' ([ordered]@{ phase=$Phase; error=($_ | Out-String).Trim(); snapshot=Snapshot })
    if ($Phase -in @('PrepareNoUser','PrepareReboot')) { $cleanupOnExit = $true }
    throw
} finally {
    if ($cleanupOnExit) {
        $cleanupError = $null
        if ($Phase -in @('Cleanup','VerifyReboot') -or $cleanMachineConfirmed) {
            try {
                if ($Phase -eq 'InterruptSameBoot' -and $passed) {
                    $cleanupDeferred = DeferInterruptedProductCleanup $sameboot
                } elseif ($Phase -eq 'Cleanup' -and $DeferredInterruptionEvidence -and
                    (Test-Path -LiteralPath (Join-Path $DeferredInterruptionEvidence 'cleanup-deferred.json'))) {
                    $cleanupDeferred = ReadJson (Join-Path $DeferredInterruptionEvidence 'cleanup-deferred.json')
                    ConfirmDeferredInterruption $cleanupDeferred $true | Out-Null
                    Record 'cleanup-deferred-product-confirmed' $cleanupDeferred
                } else {
                    RemoveInstalledTestProducts
                }
            }
            catch { $cleanupError = $_.Exception.Message; Record 'cleanup-msi-failure' $cleanupError }
        }
        try { Cleanup } catch { $cleanupError = $_.Exception.Message; Record 'cleanup-fixture-failure' $cleanupError }
        if ($cleanupError) { $passed = $false }
    }
    $result = [ordered]@{ schema='go-mapi-machine-update-integration-v1'; phase=$Phase; passed=$passed; cleanupError=$cleanupError; cleanupDeferred=$cleanupDeferred; sourceCommit=$manifest.sourceCommit; packageManifest=[IO.Path]::GetFullPath($PackageManifest); packageManifestSha256=Hash $PackageManifest; finishedAtUtc=[DateTime]::UtcNow.ToString('o'); finalSnapshot=Snapshot }
    WriteJson (Join-Path $evidence "machine-update-$($Phase.ToLowerInvariant()).json") $result
    if ($Phase -eq 'Hosted') { WriteJson (Join-Path $evidence 'machine-update-integration.json') $result }
    if ($cleanupError) { throw "Native test cleanup failed: $cleanupError" }
}
