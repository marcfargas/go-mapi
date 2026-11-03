# Dot-source the installed-update operations. Definitions only; execution belongs to update.ps1.

function GetReadinessProcessEventAction {
    {
            $p = $Event.SourceEventArgs.NewEvent
            # StopTrace truncates long image names (the runner becomes
            # "go-mapi-update"). Retain stops independently of image name;
            # the audit correlates them to full-name starts by PID/time/session.
            if ($Event.MessageData.kind -eq 'Stop' -or $p.ProcessName -in @('go-mapi-update-runner.exe','msiexec.exe')) {
                $row = [ordered]@{ observedAtUtc=[DateTime]::UtcNow.ToString('o'); name=$p.ProcessName; pid=$p.ProcessID; sessionId=$p.SessionID; timeCreated=$p.TIME_CREATED; parentPid=if ($p.PSObject.Properties['ParentProcessID']) { $p.ParentProcessID } else { $null } }
                Add-Content -LiteralPath $Event.MessageData.path -Value ($row | ConvertTo-Json -Compress) -Encoding utf8
            }
        }
}

function WriteJson([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false)) }

function Record([string]$Kind, $Value) {
    Add-Content -LiteralPath $events -Value (([ordered]@{ atUtc=[DateTime]::UtcNow.ToString('o'); kind=$Kind; value=$Value }) | ConvertTo-Json -Depth 10 -Compress) -Encoding utf8
}

function ReadJson([string]$Path) { if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } else { $null } }

function Hash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # Snapshot polling must not hold the installed image against MSI removal.
    # Get-FileHash's path overload denies delete-sharing on Windows; use the
    # same SHA256 calculation through a stream that permits replacement.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant() } finally { $stream.Dispose() }
}

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
        status=ReadJson $statusPath; recovery=ReadJson $recoveryPath; pending=$pending; replay=$replay; lastResult=$result
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

function Until([string]$Label, [scriptblock]$Condition, [int]$Minutes = $DeadlineMinutes, [int]$PollMilliseconds = 5000, [int]$Seconds = 0) {
    $end = if ($Seconds -gt 0) { [DateTime]::UtcNow.AddSeconds($Seconds) } else { [DateTime]::UtcNow.AddMinutes($Minutes) }
    if ($end -gt $script:overallDeadline) { $end = $script:overallDeadline }
    while ([DateTime]::UtcNow -lt $end) {
        if ($ExerciseSuiteShutdown) { ObserveSuiteShutdown }
        try { $result = & $Condition; if ($result) { return $result } } catch { Record 'poll-error' "$Label`: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    Record 'deadline-snapshot' (Snapshot)
    throw "Deadline waiting for $Label"
}

function WaitLimit([int]$FailureDelaySeconds = 0, [switch]$Install) {
    if (-not $timers) { return 0 }
    return $startupDelaySeconds + $heartbeatSeconds + $checkIntervalSeconds + $FailureDelaySeconds + $(if ($Install) { $installWorkSeconds } else { 0 }) + $waitMarginSeconds
}

function AwaitHealthy([string]$Key) {
    # Recovery retires pending independently of the heartbeat that publishes
    # public health. Require the complete installed-byte/service/health proof,
    # bounded by the existing wait limit and overall phase deadline.
    Until "published healthy $Key" { AssertHealthy $Key } -PollMilliseconds 500 -Seconds (WaitLimit)
}

function Msi([string]$Verb, [string]$Path, [string]$Label, [string[]]$Properties = @()) {
    $log = Join-Path $evidence "$Label-msi.log"
    $args = @($Verb, ('"' + $Path + '"'), '/qn', '/norestart') + $(if ($SKU -eq 'suite') { @('MSIRESTARTMANAGERCONTROL=Disable') } else { @('MSIRMSHUTDOWN=0') }) + $Properties + @('/l*v!', ('"' + $log + '"'))
    $startedUtc = [DateTime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = $null
    Record 'administrator-msi-attempt' ([ordered]@{ label=$Label; verb=$Verb; msiSha256=Hash $Path; startedUtc=$startedUtc.ToString('o'); log=$log })
    try {
        $process = Start-Process msiexec.exe -ArgumentList $args -PassThru
        $null = $process.Handle
        Record 'administrator-msi-started' ([ordered]@{ label=$Label; pid=$process.Id; processStartedUtc=$process.StartTime.ToUniversalTime().ToString('o') })
        if (-not $process.WaitForExit(600000)) {
            Record 'administrator-msi-timeout' ([ordered]@{ label=$Label; pid=$process.Id; elapsedMilliseconds=$watch.Elapsed.TotalMilliseconds; log=$log })
            throw "$Label exceeded the ten-minute MSI deadline; inspect the live installer and log before cleanup"
        }
        $script:lastAdministratorMsiUtc = [DateTime]::UtcNow
        $watch.Stop()
        Record 'administrator-msi' ([ordered]@{ label=$Label; exitCode=$process.ExitCode; log=$log; endedUtc=$script:lastAdministratorMsiUtc.ToString('o'); elapsedMilliseconds=$watch.Elapsed.TotalMilliseconds })
        if ($null -eq $process.ExitCode) { throw "$Label exit code unavailable" }
        if ($process.ExitCode -ne 0) { throw "$Label returned $($process.ExitCode); postboot proof is required for 3010/1641" }
    } catch {
        Record 'administrator-msi-error' ([ordered]@{ label=$Label; elapsedMilliseconds=$watch.Elapsed.TotalMilliseconds; error=$_.Exception.Message; log=$log })
        throw
    } finally {
        $watch.Stop()
        if ($null -ne $process) { $process.Dispose() }
    }
}

function ReadAdmissionGate {
    $path = Join-Path $env:ProgramData 'go-mapi\status\suite-admission-v1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'absent' }
    try {
        $stream = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try { if ($stream.Length -ne 1) { return 'malformed' }; return [string][char]$stream.ReadByte() } finally { $stream.Dispose() }
    } catch [IO.IOException] { return 'locked' }
}

function AssertAdmissionReopened([string]$Label, [int]$Seconds) {
    if ($SKU -ne 'suite') { return }
    $since = $script:lastAdministratorMsiUtc
    $state = ReadAdmissionGate
    while ($state -ne 'O' -and [DateTime]::UtcNow -lt $since.AddSeconds($Seconds)) {
        Start-Sleep -Milliseconds 250
        $state = ReadAdmissionGate
    }
    $elapsed = [math]::Round(([DateTime]::UtcNow - $since).TotalSeconds, 2)
    if ($state -ne 'O') {
        Record 'admission-closed' ([ordered]@{ label=$Label; seconds=$elapsed; state=$state; snapshot=(Snapshot) })
        throw "suite admission stayed closed $elapsed s after $Label"
    }
    Record 'admission-reopened' ([ordered]@{ label=$Label; seconds=$elapsed })
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
    try {
        if ($MachineTargetsExecutable) {
            & $MachineTargetsExecutable --spec $specPath --msi $package.msi --out $targetPath --artifact-origin $manifest.fixture.artifactOrigin
        } else {
            & go run ./internal/mapi/cmd/machine-targets --spec $specPath --msi $package.msi --out $targetPath --artifact-origin $manifest.fixture.artifactOrigin
        }
    }
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
    $args = @('-NoProfile','-File',('"' + (Join-Path $PSScriptRoot 'https-fixture.ps1') + '"'),'-PackageManifest',('"' + $PackageManifest + '"'),'-FixtureDirectory',('"' + $fixture + '"'),'-Port',"$FixturePort")
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
            Where-Object { $_.CommandLine -match 'https-fixture\.ps1' -and $_.CommandLine.Contains($fixture) })
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

function CleanupStep([string]$Name, [scriptblock]$Action) {
    try { & $Action } catch {
        $script:cleanupError = (@($script:cleanupError, "$Name`: $($_.Exception.Message)") | Where-Object { $_ }) -join '; '
        $script:passed = $false
        try { Record "cleanup-$Name-failure" $_.Exception.Message } catch { }
    }
}

function CompleteUpdateScenario {
    # Each cleanup step runs even if an earlier evidence export or cleanup fails.
    CleanupStep 'suite-shutdown' { if ($ExerciseSuiteShutdown) { StopSuiteShutdownProof } }
    CleanupStep 'readiness-evidence' {
        if ($Phase -in @('ReadinessRecovery','Cleanup')) {
            if (Test-Path -LiteralPath $obstructionPath) { Remove-Item -LiteralPath $obstructionPath -Force }
            if (Test-Path -LiteralPath $recoveryPath) { Copy-Item -LiteralPath $recoveryPath -Destination (Join-Path $evidence 'final-recovery.json') -Force }
            Get-ChildItem -LiteralPath $stateDir -Filter 'readiness-hit-*.json' -File -ErrorAction SilentlyContinue | Copy-Item -Destination $evidence -Force
        }
    }
    foreach ($subscription in $processSubscriptions) {
        CleanupStep 'process-observer' { Unregister-Event -SourceIdentifier $subscription.source -ErrorAction Stop }
        CleanupStep 'process-job' { Remove-Job -Job $subscription.job -Force -ErrorAction Stop }
    }
    if ($cleanupOnExit) {
        CleanupStep 'msi' {
            if ($Phase -in @('Cleanup','VerifyReboot') -or $cleanMachineConfirmed) {
                if ($Phase -eq 'InterruptSameBoot' -and $passed) {
                    $script:cleanupDeferred = DeferInterruptedProductCleanup $sameboot
                } elseif ($Phase -eq 'Cleanup' -and $DeferredInterruptionEvidence -and
                    (Test-Path -LiteralPath (Join-Path $DeferredInterruptionEvidence 'cleanup-deferred.json'))) {
                    $script:cleanupDeferred = ReadJson (Join-Path $DeferredInterruptionEvidence 'cleanup-deferred.json')
                    ConfirmDeferredInterruption $script:cleanupDeferred $true | Out-Null
                    Record 'cleanup-deferred-product-confirmed' $script:cleanupDeferred
                } else { RemoveInstalledTestProducts }
            }
        }
        CleanupStep 'fixture' { Cleanup }
    }
}

function ConfirmDeferredInterruption($record, [bool]$RequireFenceProof = $false) {
    if (-not $record -or $record.schema -ne 'go-mapi-interruption-cleanup-deferral-v1' -or
        $record.packageManifestSha256 -ne (Hash $PackageManifest) -or
        $record.systemBMsiSha256 -ne (Hash $manifest.packages.$caseB.msi) -or
        $record.installedProductCode -ne $manifest.packages.$caseB.identity.productCode -or
        $record.installedRelease -ne $manifest.packages.$caseB.release) { throw 'Deferred cleanup evidence does not match current package inputs' }
    $guardObservation = [ordered]@{
        schema='go-mapi-deferred-cleanup-guard-observation-v1'; phase=$Phase; expected=$record
        products=$null; snapshot=$null; processes=[ordered]@{}; readError=$null
    }
    try {
        $products = @(InstalledTestProducts)
        $guardObservation.products = @($products | ForEach-Object {
            [ordered]@{ sku=$_.sku; release=$_.release; productCode=$_.identity.productCode; msi=$_.msi; sha256=$_.sha256 }
        })
        $snapshot = Snapshot
        $guardObservation.snapshot = $snapshot
        foreach ($role in @('runner','installer')) {
            $lookupErrors = @()
            # Observe once; only proven absence or a different creation identity permits cleanup.
            $process = $null
            try { $process = Get-Process -Id $record.$role.pid -ErrorAction SilentlyContinue -ErrorVariable lookupErrors }
            catch { $lookupErrors += $_ }
            $observed = [ordered]@{
                expected=$record.$role; present=[bool]$process
                identity=[ordered]@{}; readErrors=@($lookupErrors | ForEach-Object { $_.Exception.Message })
                createdAtUnixNano=$null; classification='indeterminate'
            }
            $expectedIdentityValid = ($record.$role.pid -is [int] -or $record.$role.pid -is [long]) -and
                $record.$role.pid -gt 0 -and $record.$role.pid -le [int]::MaxValue -and
                $record.$role.createdAtUnixNano -is [long] -and $record.$role.createdAtUnixNano -gt 0
            if (-not $process -and $expectedIdentityValid -and $lookupErrors.Count -eq 1 -and
                $lookupErrors[0].FullyQualifiedErrorId -eq 'NoProcessFoundForGivenId,Microsoft.PowerShell.Commands.GetProcessCommand' -and
                $lookupErrors[0].CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound -and
                $lookupErrors[0].TargetObject -eq $record.$role.pid) {
                $observed.classification = 'absent'
            }
            if ($process -and @($process).Count -eq 1) {
                foreach ($property in @('Id','ProcessName','SessionId','StartTime','Path')) {
                    try {
                        $value = $process.$property
                        if ($property -eq 'StartTime') {
                            if ($value -isnot [DateTime] -or $value.Kind -eq [DateTimeKind]::Unspecified) { throw 'Missing or ambiguous process StartTime' }
                            $utc = $value.ToUniversalTime()
                            $observed.identity[$property] = $utc.ToString('o')
                            # Bound ticks before multiplying so overflow cannot promote arithmetic to Double.
                            if ($utc.Ticks -le 621355968000000000L -or $utc.Ticks -gt 713589688368547758L) { throw 'Process StartTime is outside exact Unix nanosecond range' }
                            $nanos = ([int64]$utc.Ticks - 621355968000000000L) * 100L
                            $observed.createdAtUnixNano = $nanos
                        } else { $observed.identity[$property] = $value }
                    } catch { $observed.readErrors += "$property`: $($_.Exception.Message)" }
                }
                if ($expectedIdentityValid -and $lookupErrors.Count -eq 0 -and
                    $observed.identity['Id'] -eq $record.$role.pid -and $null -ne $observed.createdAtUnixNano) {
                    $observed.classification = if ($observed.createdAtUnixNano -eq $record.$role.createdAtUnixNano) { 'matching' } else { 'reused' }
                }
            }
            $guardObservation.processes[$role] = $observed
        }
    } catch {
        $guardObservation.readError = $_.Exception.Message
        throw
    } finally {
        Record 'cleanup-deferred-guard-observation' $guardObservation
    }
    if ($products.Count -ne 1 -or $products[0].identity.productCode -ne $record.installedProductCode -or
        -not $snapshot.marker -or $snapshot.marker.packageRelease -ne $record.installedRelease -or
        $snapshot.service.state -ne 'Running' -or -not $snapshot.pending -or
        $snapshot.pending.transactionId -ne $record.transactionId -or $snapshot.pending.attempt -ne $record.attempt -or
        $snapshot.pending.phase -ne 'outcome-unconfirmed' -or
        $snapshot.pending.runner.pid -ne $record.runner.pid -or
        $snapshot.pending.runner.createdAtUnixNano -ne $record.runner.createdAtUnixNano -or
        $snapshot.pending.installer.pid -ne $record.installer.pid -or
        $snapshot.pending.installer.createdAtUnixNano -ne $record.installer.createdAtUnixNano -or
        $guardObservation.processes.runner.classification -notin @('absent','reused') -or
        $guardObservation.processes.installer.classification -notin @('absent','reused') -or
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

function WindowsInstallerState {
    $service = Get-CimInstance Win32_Service -Filter "Name='msiserver'" -ErrorAction SilentlyContinue
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='msiexec.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        [ordered]@{ pid=$_.ProcessId; createdUtc=if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('o') } else { $null }; command=$_.CommandLine } })
    [ordered]@{ msiserver=if ($service) { [ordered]@{ state=$service.State; processId=$service.ProcessId } } else { $null }; msiexec=$processes }
}

function CollectUpdateEvidence([string]$Label, [DateTime]$SinceUtc, $Pending = $null) {
    # Diagnostic failure must never replace the scenario's primary failure.
    try {
        $target = Join-Path $evidence "$Label-diagnostics"
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        foreach ($file in @('pending-v2.json','last-result-v1.json')) {
            $path = Join-Path $stateDir $file
            if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $target -Force }
        }
        $updates = Join-Path $env:ProgramData 'go-mapi\updates'
        $logs = Join-Path $updates 'logs'
        if ($Pending) { $logs = Join-Path $logs ([string]$Pending.transactionId) }
        if (Test-Path -LiteralPath $logs) { Copy-Item -LiteralPath $logs -Destination (Join-Path $target 'logs') -Recurse -Force }
        $files = @(if (Test-Path -LiteralPath $updates) {
            Get-ChildItem -LiteralPath $updates -Recurse -Force -ErrorAction SilentlyContinue | Select-Object -First 200 | ForEach-Object {
                [ordered]@{ path=$_.FullName; bytes=if ($_.PSIsContainer) { $null } else { $_.Length }; lastWriteUtc=$_.LastWriteTimeUtc.ToString('o') } } })
        $ready = @(Get-ChildItem -LiteralPath $stateDir -Filter 'ready-*.json' -ErrorAction SilentlyContinue | Select-Object -First 200 | ForEach-Object {
            [ordered]@{ path=$_.FullName; lastWriteUtc=$_.LastWriteTimeUtc.ToString('o'); content=(ReadJson $_.FullName) } })
        $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'go-mapi*' -or $_.Name -eq 'msiexec.exe' } | ForEach-Object {
            [ordered]@{ pid=$_.ProcessId; name=$_.Name; createdUtc=if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('o') } else { $null }; command=$_.CommandLine } })
        $since = $SinceUtc.AddMinutes(-2).ToLocalTime()
        $events = @()
        foreach ($query in @(@{ LogName='Application'; Level=@(1,2,3) }, @{ LogName='System'; Level=@(1,2,3) },
            @{ LogName='Application'; ProviderName='MsiInstaller' }, @{ LogName='System'; ProviderName='Service Control Manager' })) {
            $query.StartTime = $since
            $events += @(Get-WinEvent -FilterHashtable $query -MaxEvents 100 -ErrorAction SilentlyContinue | Sort-Object TimeCreated | ForEach-Object {
                $message = [string]$_.Message
                [ordered]@{ atUtc=$_.TimeCreated.ToUniversalTime().ToString('o'); log=$query.LogName; provider=$_.ProviderName; id=$_.Id; message=$message.Substring(0, [Math]::Min(600, $message.Length)) } })
        }
        $receipt = [ordered]@{ sinceUtc=$SinceUtc.ToString('o'); pending=$Pending; updateDirectory=$files; readyRecords=$ready; processes=$processes; windowsInstaller=(WindowsInstallerState); events=$events }
        WriteJson (Join-Path $target 'evidence.json') $receipt
        Record "$Label-evidence" $receipt
        return $true
    } catch {
        try { Record "$Label-evidence-error" $_.Exception.Message } catch { }
        return $false
    }
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

function ReadinessWaitLimit([switch]$Persistent, [switch]$Install) {
    $attempts = if ($Persistent) { 3 } else { 1 }
    return 350 + (75 * $attempts) + ($failureBaseSeconds * $attempts) + $waitMarginSeconds + $(if ($Install) { $installWorkSeconds } else { 0 })
}

function SetReadinessObstruction([string]$Key) {
    if (-not $manifest.fixture.PSObject.Properties['readinessObstruction'] -or
        $manifest.fixture.readinessObstruction -cne 'target-bound-pre-run-v1') { throw 'Packages lack the explicit readiness validation build provenance' }
    $target = Join-Path $fixture "$Key-targets.json"
    $next = "$obstructionPath.next"
    WriteJson $next ([ordered]@{ schema='go-mapi-readiness-obstruction-v1'; sku=$SKU; digest=Hash $target; artifactSha256=$manifest.packages.$Key.sha256 })
    Move-Item -LiteralPath $next -Destination $obstructionPath -Force
    Record 'obstruction-set' (ReadJson $obstructionPath)
}

function AssertReadinessFailure($Recovery, [string]$Key) {
    if (-not $Recovery -or $Recovery.reservation.sku -cne $SKU -or
        $Recovery.reservation.replay.digest -cne (Hash (Join-Path $fixture "$Key-targets.json")) -or
        $Recovery.reservation.artifactSha256 -cne $manifest.packages.$Key.sha256) { throw 'Readiness failure target identity differs' }
    $hitPath = Join-Path $stateDir "readiness-hit-$($Recovery.reservation.transactionId).json"
    $hit = ReadJson $hitPath
    if (-not $hit -or $hit.schema -cne 'go-mapi-readiness-hit-v1' -or $hit.transactionId -cne $Recovery.reservation.transactionId -or
        $hit.digest -cne $Recovery.reservation.replay.digest -or $hit.artifactSha256 -cne $Recovery.reservation.artifactSha256 -or
        $hit.runner.pid -ne $Recovery.runner.pid -or $hit.runner.createdAtUnixNano -ne $Recovery.runner.createdAtUnixNano) { throw 'Missing exact pre-installer fixture hit' }
    $pending = ReadJson (Join-Path $stateDir 'pending-v2.json')
    if ($pending -and ($pending.PSObject.Properties['installer'] -or $pending.PSObject.Properties['installerThread'] -or
        $pending.PSObject.Properties['exit'] -or $pending.phase -notin @('prepared','handoff-fenced'))) { throw 'Obstructed handoff has installation evidence' }
    $readyPath = Join-Path $stateDir "ready-$($hit.transactionId)-attempt-$($hit.attempt)-v1.json"
    if (Test-Path -LiteralPath $readyPath) { throw 'Obstructed runner published readiness' }
    Copy-Item -LiteralPath $hitPath -Destination (Join-Path $evidence (Split-Path $hitPath -Leaf)) -Force
    Record 'proved-pre-installer-failure' ([ordered]@{ recovery=$Recovery; hit=$hit; pending=$pending })
}

function StartReadinessProcessEvidence {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $elevated = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Record 'execution-identity' ([ordered]@{ name=$identity.Name; elevated=$elevated; sessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId; processId=$PID; sourceCommit=$manifest.sourceCommit })
    if (-not $elevated) { throw 'Readiness proof requires an observed elevated process' }
    foreach ($kind in @('Start','Stop')) {
        $sourceId = "go-mapi-readiness-$runId-$kind"
        $log = Join-Path $evidence "process-$($kind.ToLowerInvariant()).ndjson"
        $subscription = Register-CimIndicationEvent -Query "SELECT * FROM Win32_Process${kind}Trace" -SourceIdentifier $sourceId -MessageData @{ path=$log; kind=$kind } -Action (GetReadinessProcessEventAction)
        $script:processSubscriptions += [ordered]@{ source=$sourceId; job=$subscription }
    }
}

function AssertRecoveryProcessHistory([string]$SuccessfulTransaction) {
    $readyPath = Join-Path $stateDir "ready-$SuccessfulTransaction-attempt-1-v1.json"
    $ready = ReadJson $readyPath
    if (-not $ready -or $ready.transactionId -cne $SuccessfulTransaction) { throw 'Recovered installation lacks durable ready/process identity' }
    Copy-Item -LiteralPath $readyPath -Destination (Join-Path $evidence 'successful-ready.json') -Force
    $msiLogs = Join-Path $env:ProgramData "go-mapi\updates\logs\$SuccessfulTransaction"
    if (-not (Test-Path -LiteralPath $msiLogs)) { throw 'Automatic recovered installation has no MSI log directory' }
    Copy-Item -LiteralPath $msiLogs -Destination (Join-Path $evidence 'recovered-msi') -Recurse -Force
    $starts = @(Get-Content -LiteralPath (Join-Path $evidence 'process-start.ndjson') | ForEach-Object { $_ | ConvertFrom-Json })
    $stops = @(Get-Content -LiteralPath (Join-Path $evidence 'process-stop.ndjson') | ForEach-Object { $_ | ConvertFrom-Json })
    $runners = @($starts | Where-Object name -eq 'go-mapi-update-runner.exe' | Sort-Object { [uint64]$_.timeCreated })
    if ($runners.Count -ne 5) { throw "Expected five physical runners (B2+C3), observed $($runners.Count)" }
    for ($i=0; $i -lt $runners.Count; $i++) {
        $runner = $runners[$i]
        $stop = @($stops | Where-Object { $_.pid -eq $runner.pid -and $_.sessionId -eq $runner.sessionId -and [uint64]$_.timeCreated -ge [uint64]$runner.timeCreated } | Sort-Object { [uint64]$_.timeCreated } | Select-Object -First 1)
        if ($stop.Count -ne 1) { throw "Runner $($runner.pid) has no observed stop" }
        if ($i+1 -lt $runners.Count -and [uint64]$stop[0].timeCreated -gt [uint64]$runners[$i+1].timeCreated) { throw 'Managed runners overlapped' }
    }
    $runnerPids = @($runners | ForEach-Object pid)
    $clients = @($starts | Where-Object { $_.name -eq 'msiexec.exe' -and $_.parentPid -in $runnerPids })
    if ($clients.Count -ne 1 -or $clients[0].pid -ne $ready.installer.pid -or $clients[0].parentPid -ne $ready.runner.pid) { throw 'Managed installer starts differ from the one recovered transaction' }
    Record 'no-overlap-proof' ([ordered]@{ runnerStarts=$runners; runnerStops=@($stops | Where-Object pid -in $runnerPids); installerStarts=$clients; ready=$ready })
}

function TestFixtureInstallerMutexIdle {
    $mutex = $null; $owned = $false
    try {
        try { $mutex = [Threading.Mutex]::OpenExisting('Global\_MSIExecute') }
        catch [Threading.WaitHandleCannotBeOpenedException] { return $true }
        try { $owned = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        return $owned
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

function StopIdleReadinessInstaller([string]$Key, $Ready = $null) {
    # Only precondition disposable validation stages. Never intervene in the
    # interrupted-install scenario or change the production stopped-server gate.
    if (-not $timers -or $Phase -ne 'ReadinessRecovery') { return }
    $snapshot = AssertHealthy $Key
    if ($snapshot.pending) { throw 'Cannot stop fixture installer with pending work' }
    if ($Ready) {
        Until 'completed fixture runner and installer exits' {
            foreach ($identity in @($Ready.runner, $Ready.installer)) {
                if (-not $identity -or ($identity.pid -isnot [int] -and $identity.pid -isnot [long]) -or
                    $identity.pid -le 0 -or $identity.pid -gt [int]::MaxValue -or
                    $identity.createdAtUnixNano -isnot [long] -or $identity.createdAtUnixNano -le 0) { throw 'Invalid completed process identity' }
                $process = $null
                $absent = $false
                try { $process = Get-Process -Id $identity.pid -ErrorAction Stop }
                catch {
                    if ($_.FullyQualifiedErrorId -cne 'NoProcessFoundForGivenId,Microsoft.PowerShell.Commands.GetProcessCommand' -or
                        $_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound -or
                        $_.TargetObject -ne $identity.pid) { throw }
                    $absent = $true
                }
                if (-not $process -and -not $absent) { throw 'Missing process absence proof' }
                if ($process) {
                    try {
                        if (@($process).Count -ne 1 -or $process.Id -ne $identity.pid -or
                            $process.StartTime -isnot [DateTime] -or $process.StartTime.Kind -eq [DateTimeKind]::Unspecified) { throw 'Ambiguous completed process identity' }
                        $created = ([decimal]$process.StartTime.ToUniversalTime().Ticks - 621355968000000000L) * 100
                        if ($created -le 0 -or $created -gt [long]::MaxValue) { throw 'Invalid observed process identity' }
                        if ($created -eq [decimal]$identity.createdAtUnixNano) { return $false }
                    } finally { foreach ($observed in @($process)) { $observed.Dispose() } }
                }
            }
            return $true
        } -PollMilliseconds 100 -Seconds 30 | Out-Null
    }
    $server = Get-Service msiserver -ErrorAction Stop
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $before = [string]$server.Status
        $canStop = $server.CanStop
        if ($server.Status -ne 'Stopped') {
            if ($server.Status -ne 'Running' -or -not $server.CanStop -or -not (TestFixtureInstallerMutexIdle)) {
                throw 'Fixture Windows Installer is busy or cannot accept a normal stop'
            }
            # Recheck the installed unit immediately before service control.
            $snapshot = AssertHealthy $Key
            if ($snapshot.pending) { throw 'Cannot stop fixture installer with pending work' }
            if (@($server.DependentServices | Where-Object Status -ne 'Stopped').Count) { throw 'Fixture installer has running dependent services' }
            $server.Refresh()
            if ($server.Status -ne 'Running' -or -not $server.CanStop) { throw 'Fixture installer changed before stop' }
            $server.Stop()
            $server.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
        $server.Refresh()
        if ($server.Status -ne 'Stopped' -or -not (TestFixtureInstallerMutexIdle)) { throw 'Fixture installer did not become stopped and idle' }
        Record 'readiness-fixture-installer-stopped' ([ordered]@{ key=$Key; before=$before; canStopBefore=$canStop; after=[string]$server.Status; mutexIdleAfter=$true; elapsedMilliseconds=$watch.Elapsed.TotalMilliseconds; ready=$Ready; snapshot=$snapshot })
    } finally { $server.Dispose() }
}

function RunReadinessRecovery($Baseline) {
    StopIdleReadinessInstaller $caseA
    StartReadinessProcessEvidence
    SetReadinessObstruction $caseB
    SelectTarget $caseB
    $failure = Until 'B durable readiness failure' {
        $r=ReadJson $recoveryPath
        if ($r -and $r.reservation.candidate.packageVersion -eq $manifest.packages.$caseB.release -and $r.consumed -eq 1 -and $r.failedAt -ne '0001-01-01T00:00:00Z') { $r }
    } -PollMilliseconds 500 -Seconds (ReadinessWaitLimit)
    AssertReadinessFailure $failure $caseB
    Record 'B-backoff-before-restart' (Snapshot)
    Restart-Service go-mapi -Force
    $restored = ReadJson $recoveryPath
    if ($restored.consumed -ne 1 -or $restored.dueAt -cne $failure.dueAt -or $restored.reservation.transactionId -cne $failure.reservation.transactionId) { throw 'Service restart lost backoff/count' }
    Remove-Item -LiteralPath $obstructionPath -Force
    Record 'B-obstruction-removed' ([ordered]@{ dueAt=$restored.dueAt; transactionId=$restored.reservation.transactionId })
    $b = Until 'automatic B recovery commit' {
        $s=Snapshot
        Record 'recovery-observation' $s
        if ($s.marker.packageRelease -eq $manifest.packages.$caseB.release -and $s.status.health -eq 'healthy' -and -not $s.pending -and
            $s.replay.sequence -eq $manifest.packages.$caseB.identity.sequence -and $s.recovery.stage -eq 'completed') { $s }
    } -PollMilliseconds 1000 -Seconds (ReadinessWaitLimit -Install)
    $b = AssertCommitted $caseB $Baseline.service.processId
    if ($b.recovery.consumed -ne 2 -or $b.recovery.reservation.transactionId -ceq $failure.reservation.transactionId) { throw 'B recovery did not use exactly one fresh automatic reservation' }
    $ready = ReadJson (Join-Path $stateDir "ready-$($b.recovery.reservation.transactionId)-attempt-1-v1.json")
    if (-not $ready -or $ready.transactionId -cne $b.recovery.reservation.transactionId) { throw 'Recovered B lacks exact process identities' }
    StopIdleReadinessInstaller $caseB $ready
    SetReadinessObstruction $caseC
    SelectTarget $caseC
    $seen = @{}
    $exhausted = Until 'C exact three-launch readiness exhaustion' {
        $s=Snapshot; $r=$s.recovery
        Record 'recovery-observation' $s
        if ($r -and $r.reservation.candidate.packageVersion -eq $manifest.packages.$caseC.release -and $r.failedAt -ne '0001-01-01T00:00:00Z') {
            if (-not $seen.ContainsKey($r.reservation.transactionId)) { AssertReadinessFailure $r $caseC; $seen[$r.reservation.transactionId]=$r.consumed }
            if ($r.stage -eq 'exhausted' -and $r.consumed -eq 3 -and -not $s.pending) { $r }
        }
    } -PollMilliseconds 500 -Seconds (ReadinessWaitLimit -Persistent)
    if ($seen.Count -ne 3) { throw 'Persistent fixture did not observe exactly three distinct failed reservations' }
    AwaitHealthy $caseB | Out-Null
    Restart-Service go-mapi -Force
    Remove-Item -LiteralPath $obstructionPath -Force
    $window = $startupDelaySeconds + $heartbeatSeconds + $checkIntervalSeconds + (2 * $failureBaseSeconds) + 10
    $end = [DateTime]::UtcNow.AddSeconds($window)
    if ($end -gt $overallDeadline) { throw 'Insufficient deadline for full exhausted recovery/discovery opportunity' }
    while ([DateTime]::UtcNow -lt $end) {
        $s=Snapshot
        if ($s.pending -or $s.recovery.consumed -ne 3 -or $s.recovery.stage -ne 'exhausted' -or
            $s.recovery.reservation.transactionId -cne $exhausted.reservation.transactionId) { throw 'Exhausted C reopened after restart/obstruction removal' }
        Record 'exhausted-opportunity' $s
        Start-Sleep -Milliseconds 1000
    }
    AwaitHealthy $caseB | Out-Null
    AssertRecoveryProcessHistory $b.recovery.reservation.transactionId
    Record 'readiness-recovery-passed' ([ordered]@{ sku=$SKU; transientTransactions=@($failure.reservation.transactionId,$b.recovery.reservation.transactionId); persistentTransactions=@($seen.Keys); exhausted=$exhausted; windowSeconds=$window })
}
