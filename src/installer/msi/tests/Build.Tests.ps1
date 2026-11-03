$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch { return }
    throw "Expected failure: $Message"
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
$temp = Join-Path ([IO.Path]::GetTempPath()) ('go-mapi-msi-build-' + [guid]::NewGuid().ToString('N'))
try {
    $input = Join-Path $temp 'inputs'
    New-Item -ItemType Directory -Force $input | Out-Null
    foreach ($name in @('go-mapi-service.exe','go-mapi-x86.dll','go-mapi-x64.dll','go-mapi-machine.exe')) { Set-Content (Join-Path $input $name) $name }
    $unsigned = (Get-FileHash (Join-Path $input 'go-mapi-machine.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    $appBuild = [ordered]@{ schema='go-mapi-app-artifacts-v2'; component='app'; version='5.0.1-alpha.4'; distribution='machine'; source=@{ commit=('a' * 40) }; artifact=@{ filename='go-mapi-machine.exe'; peProductVersion='5.0.1-alpha.4'; sha256=$unsigned } }
    $buildPath = Join-Path $input 'app-artifacts.json'
    [IO.File]::WriteAllText($buildPath, ($appBuild | ConvertTo-Json -Depth 5))
    $writer = Join-Path $repo 'src/installer/msi/write-signed-input.ps1'
    $out = Join-Path $input 'signed-input.json'
    $common = @{ SKU='suite'; PackageRelease='5.0.1-alpha.4'; SourceCommit=('a' * 40); InputDirectory=$input; ServiceVersion='5.0.1-alpha.4'; InterceptorVersion='5.0.1-alpha.4'; AppVersion='5.0.1-alpha.4'; AppBuildManifest=$buildPath; UnsignedAppSha256=$unsigned; OutputPath=$out }
    & $writer @common
    $signed = Get-Content $out -Raw | ConvertFrom-Json
    Assert ($signed.schema -eq 'go-mapi-machine-signed-input-v1' -and @($signed.components).Count -eq 3 -and $signed.appBuild.unsignedSha256 -eq $unsigned) 'signed input inventory mismatch'
    $publicBuildPath = Join-Path $input 'machine-app-artifacts.json'
    Copy-Item -LiteralPath $buildPath -Destination $publicBuildPath
    $public = $common.Clone(); $public.AppBuildManifest = $publicBuildPath
    & $writer @public
    $publicInput = Get-Content $out -Raw | ConvertFrom-Json
    Assert ($publicInput.appBuild.manifest -ceq 'machine-app-artifacts.json' -and
        $publicInput.appBuild.sha256 -ceq (Get-FileHash $publicBuildPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'public machine app provenance link does not resolve'
    $bad = $common.Clone(); $bad.AppBuildManifest = Join-Path $temp 'app-artifacts.json'
    Copy-Item -LiteralPath $buildPath -Destination $bad.AppBuildManifest
    Reject { & $writer @bad } 'app provenance outside component bundle'
    & $writer -SKU system -PackageRelease '5.0.1-alpha.4' -SourceCommit ('a' * 40) -InputDirectory $input `
        -ServiceVersion '5.0.1-alpha.4' -InterceptorVersion '5.0.1-alpha.4' -OutputPath $out
    $systemInput = Get-Content $out -Raw | ConvertFrom-Json
    Assert ($systemInput.sku -eq 'system' -and @($systemInput.components).Count -eq 2 -and
        $systemInput.PSObject.Properties.Name -notcontains 'appBuild') 'system inventory gained an app'
    $bad = $common.Clone(); $bad.SKU = 'system'; Reject { & $writer @bad } 'wrong SKU app inventory'
    $bad = $common.Clone(); $bad.ServiceVersion = 'bad'; Reject { & $writer @bad } 'bad service version'
    $bad = $common.Clone(); $bad.SourceCommit = ('b' * 40); Reject { & $writer @bad } 'wrong app source commit'
    $bad = $common.Clone(); $bad.UnsignedAppSha256 = ('0' * 64); Reject { & $writer @bad } 'wrong unsigned hash'
    Remove-Item (Join-Path $input 'go-mapi-x86.dll')
    Reject { & $writer @common } 'missing input'

    # Validation timers are a CI-fixture input only: the release build refuses
    # every one of them, a partial or non-shortening set, and sub-minute checks
    # without the set. Each guard throws before any toolchain is needed.
    function RejectMessage([scriptblock]$Action, [string]$Pattern, [string]$What) {
        try { & $Action } catch {
            Assert ($_.Exception.Message -match $Pattern) "$What failed for the wrong reason: $($_.Exception.Message)"
            return
        }
        throw "Expected failure: $What"
    }
    $testPackages = Join-Path $repo 'src/installer/msi/tests/build-fixtures.ps1'
    . $testPackages -OutputDirectory unused -EvidenceDirectory unused
    $specPath = Join-Path $repo 'src/installer/msi/tests/fixtures/machine.json'
    $spec = ReadFixtureSpecification $specPath
    Assert ($spec.sha256 -ceq (Get-FileHash $specPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'fixture specification hash differs'
    Assert ($spec.cases.Count -eq 6 -and ($spec.cases.key -join ',') -ceq 'systemA,systemB,systemC,suiteA,suiteB,suiteC') 'fixture cases changed'
    foreach ($case in $spec.cases) {
        $role = switch ($case.key.Substring($case.key.Length-1)) { A {'baseline'} B {'serviceUpgrade'} C {'packageNext'} }
        Assert ($case.release -ceq $spec.versions.$role) "fixture release role differs for $($case.key)"
        $serviceRole = if ($case.key -eq 'suiteC') { 'serviceUpgrade' } else { $role }
        Assert ($case.service -ceq $spec.versions.$serviceRole) "fixture service role differs for $($case.key)"
    }
    foreach ($mode in @('schema','ordering','counter','timer','fractional-timer','string-timer')) {
        $badSpec = Get-Content $specPath -Raw | ConvertFrom-Json
        switch ($mode) {
            schema { $badSpec.schema='unknown' }
            ordering { $badSpec.versions.packageNext=$badSpec.versions.serviceUpgrade }
            counter { $badSpec.versions.baseline='5.0.1-alpha.100' }
            timer { $badSpec.timers.failureDelayBaseSeconds=901 }
            fractional-timer { $badSpec.timers.heartbeatSeconds=1.5 }
            string-timer { $badSpec.timers.heartbeatSeconds='2' }
        }
        $badPath=Join-Path $temp 'bad-spec.json'; $badSpec | ConvertTo-Json -Depth 5 | Set-Content $badPath
        Reject { ReadFixtureSpecification $badPath } "invalid fixture $mode"
    }
    $serviceBuild = Join-Path $repo 'src/service/build.ps1'
    $serviceOut = Join-Path $temp 'service.exe'
    $oldMachineOrigin = $env:MACHINE_RELEASE_METADATA_ORIGIN
    $env:MACHINE_RELEASE_METADATA_ORIGIN = 'https://go-mapi.app'
    try {
        foreach ($timer in @(@{ ValidationStartupDelaySeconds=5 }, @{ ValidationHeartbeatSeconds=2 }, @{ ValidationFailureBaseSeconds=30 },
                @{ ValidationStartupDelaySeconds=120; ValidationHeartbeatSeconds=60; ValidationFailureBaseSeconds=900 })) {
            $releaseArgs = $timer.Clone()
            RejectMessage { & $serviceBuild -OutputPath $serviceOut -RequireMachineReleaseTrust @releaseArgs } 'must not carry validation timers' "release build with $($timer.Keys -join ',')"
        }
        $oneTimer = @{ ValidationStartupDelaySeconds=5 }
        RejectMessage { & $serviceBuild -OutputPath $serviceOut @oneTimer } 'supplied together' 'partial validation timer set'
        $tooLong = @{ ValidationStartupDelaySeconds=121; ValidationHeartbeatSeconds=2; ValidationFailureBaseSeconds=30 }
        RejectMessage { & $serviceBuild -OutputPath $serviceOut @tooLong } 'shorten the production' 'startup delay above production'
        $tooLong = @{ ValidationStartupDelaySeconds=5; ValidationHeartbeatSeconds=61; ValidationFailureBaseSeconds=30 }
        RejectMessage { & $serviceBuild -OutputPath $serviceOut @tooLong } 'shorten the production' 'heartbeat above production'
        $tooLong = @{ ValidationStartupDelaySeconds=5; ValidationHeartbeatSeconds=2; ValidationFailureBaseSeconds=901 }
        RejectMessage { & $serviceBuild -OutputPath $serviceOut @tooLong } 'shorten the production' 'failure base above production'
        $zero = @{ ValidationStartupDelaySeconds=0; ValidationHeartbeatSeconds=2; ValidationFailureBaseSeconds=30 }
        RejectMessage { & $serviceBuild -OutputPath $serviceOut @zero } 'shorten the production' 'zero startup delay'
        RejectMessage { & $serviceBuild -OutputPath $serviceOut -CheckIntervalSeconds 5 } 'outside bounds' 'sub-minute check interval without validation timers'
        RejectMessage { & $serviceBuild -OutputPath $serviceOut -RequireMachineReleaseTrust -CheckIntervalSeconds 60 } 'six-hour' 'release build with a 60-second check interval'
    } finally { $env:MACHINE_RELEASE_METADATA_ORIGIN = $oldMachineOrigin }
    # The pre-signed (production-timer) fixture path refuses the shortened set.
    RejectMessage { & $testPackages -OutputDirectory (Join-Path $temp 'tp-out') -EvidenceDirectory (Join-Path $temp 'tp-evidence') `
        -PreSignedPackagesManifest (Join-Path $temp 'missing-presigned.json') -ValidationTimers } 'only to the self-signed CI build' 'validation timers with pre-signed fixtures'
    RejectMessage { & $testPackages -OutputDirectory (Join-Path $temp 'tp-out') -EvidenceDirectory (Join-Path $temp 'tp-evidence') `
        -ValidationTimers } 'require -FixtureSpecification' 'self-signed fixture without explicit specification'

    Write-Host 'MSI signed-input and validation-build contracts passed'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
