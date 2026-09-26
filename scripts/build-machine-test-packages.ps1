# Build disposable, signed machine packages for native CI. Never use these
# certificates or packages for publication.
[CmdletBinding()]
param(
    [string]$X64Dll,
    [string]$X86Dll,
    [string]$MachineApp,
    [string]$AppBuildManifest,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [string]$SuiteCApp,
    [string]$SuiteCAppBuildManifest,
    [string]$PreSignedPackagesManifest,
    [string]$MetadataOrigin = 'https://localhost:18453',
    [string]$ArtifactOrigin = 'https://localhost:18453/releases/download/',
    [int]$CheckIntervalSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force $output, $evidence | Out-Null
$commit = (& git -C $repo rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw 'Cannot identify source commit' }
if ($CheckIntervalSeconds -lt 60 -or $CheckIntervalSeconds -gt 86400) { throw 'Check interval outside production build bounds' }
if (-not $PreSignedPackagesManifest) {
    foreach ($path in @($X64Dll,$X86Dll,$MachineApp,$AppBuildManifest)) {
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing input $path" }
    }
}
if ([bool]$SuiteCApp -ne [bool]$SuiteCAppBuildManifest) { throw 'Suite C app and build manifest must be supplied together' }
if ($SuiteCApp -and (-not (Test-Path -LiteralPath $SuiteCApp -PathType Leaf) -or
    -not (Test-Path -LiteralPath $SuiteCAppBuildManifest -PathType Leaf))) { throw 'Missing suite C app input' }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function WriteJson([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}
function Sign([string]$Path) {
    & $script:signtool sign /fd SHA256 /sm /sha1 $script:signer.Thumbprint $Path
    if ($LASTEXITCODE -ne 0) { throw "Signing failed: $Path" }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $script:signer.Thumbprint) {
        throw "Test signature invalid: $Path ($($signature.Status))"
    }
}
function AssertValidationProducer([string]$Key, $Validation) {
    $producer = if ($Validation.PSObject.Properties['producer']) { $Validation.producer } else { $null }
    if ($producer -and $producer.kind -ceq 'local') {
        if ([string]::IsNullOrWhiteSpace($producer.executionId) -or
            $Validation.PSObject.Properties['runId'] -or $Validation.PSObject.Properties['runAttempt']) {
            throw "Invalid local signing execution identity: $Key"
        }
    } elseif (-not $producer -or $producer.kind -ceq 'github-actions') {
        if ($Validation.workflow -cne 'Validate machine package' -or
            [string]::IsNullOrWhiteSpace([string]$Validation.runId) -or
            [string]::IsNullOrWhiteSpace([string]$Validation.runAttempt)) {
            throw "Invalid GitHub workflow execution identity: $Key"
        }
    } else { throw "Unknown signing producer: $Key" }
}
function AssertPriorBundle([string]$Path, $Prior, $BProof) {
    if (-not $Prior.priorBundle) { throw 'Suite C validation has no B bundle provenance' }
    $bProducer = if ($BProof.PSObject.Properties['producer']) { $BProof.producer } else { $null }
    $producerMatches = if ($bProducer -and $bProducer.kind -ceq 'local') {
        $Prior.priorBundle.PSObject.Properties['executionId'] -and
        $Prior.priorBundle.executionId -cne '' -and
        $Prior.priorBundle.executionId -ceq $bProducer.executionId -and
        -not $Prior.priorBundle.PSObject.Properties['runId'] -and
        -not $Prior.priorBundle.PSObject.Properties['runAttempt']
    } else {
        $Prior.priorBundle.runId -ceq $BProof.runId -and
        $Prior.priorBundle.runAttempt -ceq $BProof.runAttempt
    }
    if (-not $producerMatches -or $Prior.priorBundle.commit -cne $BProof.commit -or
        $Prior.priorBundle.packageRelease -cne $BProof.packageRelease -or
        $Prior.priorBundle.provenanceSha256 -cne (Hash $Path)) {
        throw 'Suite C validation does not bind the exact signed B bundle provenance'
    }
}
function ResolveWrongSkuSystemReference([string]$ReferencePath) {
    if (-not $ReferencePath -or -not (Test-Path -LiteralPath $ReferencePath -PathType Leaf)) {
        throw 'Selected suite proof requires an existing system fixture for the wrong-SKU negative'
    }
    $sourceManifest = Get-Content -LiteralPath $ReferencePath -Raw | ConvertFrom-Json
    $systemFixture = $sourceManifest.packages.systemB
    $sourceSigning = if ($sourceManifest.fixture.PSObject.Properties['signing']) { [string]$sourceManifest.fixture.signing } elseif (
        $sourceManifest.fixture.signerThumbprint -and $sourceManifest.fixture.signerPublicCertificate) {
        'self-signed-disposable'
    } else { '' }
    $systemIdentity = (& go run ./internal/mapi/cmd/machine-package -- system $systemFixture.release | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $sourceManifest.schema -cne 'go-mapi-machine-test-packages-v1' -or
        $sourceSigning -notin @('self-signed-disposable','pre-signed-Azure') -or
        $systemFixture.sku -cne 'system' -or $systemFixture.identity.productCode -cne $systemIdentity.productCode -or
        $systemFixture.identity.assetName -cne $systemIdentity.assetName -or
        $systemFixture.identity.tag -cne $systemIdentity.tag -or
        $systemFixture.identity.sequence -ne $systemIdentity.sequence -or
        -not (Test-Path -LiteralPath $systemFixture.msi -PathType Leaf) -or
        (Hash $systemFixture.msi) -cne $systemFixture.sha256) {
        throw 'Referenced existing system fixture identity or bytes mismatch'
    }
    [ordered]@{
        sourceManifest=$ReferencePath; sourceManifestSha256=Hash $ReferencePath
        sourceSigning=$sourceSigning; package=$systemFixture
    }
}
function AssertMsiContains([string]$Key, $Entry, $SignedInput) {
    $extract = Join-Path $evidence "extracted-$Key-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force $extract | Out-Null
    try {
        $args = @('/a', ('"' + [IO.Path]::GetFullPath($Entry.msi) + '"'), '/qn', ('TARGETDIR="' + $extract + '"'))
        $process = Start-Process msiexec.exe -ArgumentList $args -PassThru -Wait
        if ($process.ExitCode -ne 0) { throw "Cannot extract final $Key MSI for contained-byte comparison: $($process.ExitCode)" }
        foreach ($part in $SignedInput.components) {
            foreach ($artifact in $part.artifacts) {
                $suffix = switch ($part.component) {
                    'service' { 'go-mapi\service\go-mapi-service.exe' }
                    'app' { 'go-mapi\user\go-mapi.exe' }
                    'interceptor' { "go-mapi\interceptor\$(if ($artifact.architecture -eq 'x64') { 'AMD64' } else { 'x86' })\go-mapi.dll" }
                }
                $files = @(Get-ChildItem -LiteralPath $extract -Recurse -File | Where-Object { $_.FullName.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) })
                if ($files.Count -ne 1 -or (Hash $files[0].FullName) -cne $artifact.sha256) {
                    throw "Final $Key MSI does not contain validated $($part.component)/$($artifact.architecture) bytes"
                }
            }
        }
    } finally { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
}

# Azure mode consumes complete, final-byte signed inputs and MSIs from a typed
# inventory. No test certificate is created and no immutable input is signed.
if ($PreSignedPackagesManifest) {
    $supplied = Get-Content -LiteralPath $PreSignedPackagesManifest -Raw | ConvertFrom-Json
    if ($supplied.schema -ne 'go-mapi-machine-presigned-fixtures-v1' -or $supplied.sourceCommit -cne $commit) {
        throw 'Pre-signed fixture source provenance mismatch'
    }
    $packages = [ordered]@{}
    $systemKeys = @('systemA','systemB','systemC' | Where-Object { $supplied.packages.PSObject.Properties[$_] })
    if ($systemKeys.Count -ne 0 -and $systemKeys.Count -ne 3) { throw 'System A/B/C must be supplied together' }
    foreach ($key in @($systemKeys) + @('suiteA','suiteB','suiteC')) {
        $entry = $supplied.packages.$key
        if (-not $entry -or $entry.key -cne $key -or $entry.packageSourceCommit -notmatch '^[0-9a-f]{40}$' -or
            -not (Test-Path -LiteralPath $entry.signedInputManifest -PathType Leaf) -or
            -not (Test-Path -LiteralPath $entry.validationProvenance -PathType Leaf) -or
            -not (Test-Path -LiteralPath $entry.msi -PathType Leaf)) { throw "Missing typed pre-signed case $key" }
        $input = Get-Content -LiteralPath $entry.signedInputManifest -Raw | ConvertFrom-Json
        $validation = Get-Content -LiteralPath $entry.validationProvenance -Raw | ConvertFrom-Json
        $sku = if ($key.StartsWith('suite')) { 'suite' } else { 'system' }
        if ($input.schema -ne 'go-mapi-machine-signed-input-v1' -or $input.sku -cne $sku -or
            $input.commit -cne $entry.packageSourceCommit -or $input.packageRelease -cne $entry.release) {
            throw "Pre-signed input identity mismatch: $key"
        }
        AssertValidationProducer $key $validation
        if ($validation.schema -cne 'go-mapi-machine-validation-provenance-v1' -or $validation.publishable -ne $false -or
            $validation.repository -cne 'marcfargas/go-mapi' -or
            $validation.commit -cne $input.commit -or $validation.sku -cne $sku -or
            $validation.packageRelease -cne $entry.release -or $validation.msi.signed -ne $true -or
            $validation.msi.sha256 -cne $entry.msiSha256 -or $validation.derivative.kind -cne 'https-localhost-native-fixture' -or
            $validation.derivative.metadataOrigin -cne $MetadataOrigin -or
            $validation.derivative.artifactOrigin -cne $ArtifactOrigin -or
            $validation.derivative.checkIntervalSeconds -ne $CheckIntervalSeconds -or
            ($validation.componentSources | ConvertTo-Json -Depth 8 -Compress) -cne ($entry.componentSources | ConvertTo-Json -Depth 8 -Compress)) {
            throw "Pre-signed validation provenance mismatch: $key"
        }
        if (-not $validation.azure -or [string]::IsNullOrWhiteSpace($validation.azure.endpoint) -or
            [string]::IsNullOrWhiteSpace($validation.azure.account) -or
            [string]::IsNullOrWhiteSpace($validation.azure.certificateProfile) -or
            [string]::IsNullOrWhiteSpace($validation.azure.leafThumbprint)) {
            throw "Azure service signing provenance missing: $key"
        }
        foreach ($component in $(if ($sku -eq 'suite') { @('service','interceptor','app') } else { @('service','interceptor') })) {
            $source = $entry.componentSources.$component
            if (-not $source -or $source.commit -notmatch '^[0-9a-f]{40}$' -or [string]::IsNullOrWhiteSpace($source.buildId)) {
                throw "Missing original component provenance: $key/$component"
            }
        }
        $servicePart = @($input.components | Where-Object component -eq 'service')[0]
        $interceptorPart = @($input.components | Where-Object component -eq 'interceptor')[0]
        if ($entry.componentSources.service.signedSha256 -cne $servicePart.artifacts[0].sha256 -or
            $entry.componentSources.interceptor.x64SignedSha256 -cne @($interceptorPart.artifacts | Where-Object architecture -eq 'x64')[0].sha256 -or
            $entry.componentSources.interceptor.x86SignedSha256 -cne @($interceptorPart.artifacts | Where-Object architecture -eq 'x86')[0].sha256) {
            throw "Component source records do not bind final signed inputs: $key"
        }
        $identity = (& go run ./internal/mapi/cmd/machine-package -- $sku $entry.release | ConvertFrom-Json)
        if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFileName($entry.msi) -cne $identity.assetName -or
            (Hash $entry.msi) -cne $entry.msiSha256 -or
            $validation.productCode -cne $identity.productCode -or $validation.assetName -cne $identity.assetName -or
            $validation.tag -cne $identity.tag -or $validation.productVersion -cne $identity.productVersion -or
            $validation.msi.size -ne (Get-Item -LiteralPath $entry.msi).Length) { throw "Final MSI identity/hash mismatch: $key" }
        $contained = @($input.components | ForEach-Object { "$($_.component)=$($_.version)" } | Sort-Object)
        $recorded = @($validation.contained | ForEach-Object { "$($_.component)=$($_.version)" } | Sort-Object)
        if (($contained -join ',') -cne ($recorded -join ',')) { throw "Contained version provenance mismatch: $key" }
        foreach ($part in $input.components) {
            foreach ($artifact in $part.artifacts) {
                $path = Join-Path (Split-Path $entry.signedInputManifest) $artifact.filename
                if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Hash $path) -cne $artifact.sha256) {
                    throw "Final signed component differs: $key/$($part.component)/$($artifact.architecture)"
                }
                $peProof = @($validation.peHashes | Where-Object { $_.component -ceq $part.component -and $_.architecture -ceq $artifact.architecture -and $_.filename -ceq $artifact.filename })
                if ($peProof.Count -ne 1 -or $peProof[0].signedSha256 -cne $artifact.sha256 -or
                    $peProof[0].unsignedSha256 -notmatch '^[a-f0-9]{64}$') { throw "Signed PE validation hash missing: $key/$($part.component)" }
                $signature = Get-AuthenticodeSignature -LiteralPath $path
                if ($signature.Status -ne 'Valid' -or $signature.SignatureType -ne 'Authenticode' -or
                    -not $signature.TimeStamperCertificate) {
                    throw "Untrusted or untimestamped pre-signed input: $path"
                }
                $version = (Get-Item -LiteralPath $path).VersionInfo
                if ($version.ProductVersion -cne $part.version -or $version.FileVersion -cne $part.version) {
                    throw "Signed PE version differs from inventory: $key/$($part.component)/$($artifact.architecture)"
                }
            }
        }
        if ($sku -eq 'suite') {
            if (-not $input.appBuild -or $input.appBuild.manifest -cne 'app-artifacts.json' -or
                $input.appBuild.sha256 -notmatch '^[a-f0-9]{64}$' -or $input.appBuild.unsignedSha256 -notmatch '^[a-f0-9]{64}$') {
                throw "Missing unsigned-to-signed app provenance: $key"
            }
            $appBuildPath = Join-Path (Split-Path $entry.signedInputManifest) 'app-artifacts.json'
            if (-not (Test-Path -LiteralPath $appBuildPath -PathType Leaf) -or (Hash $appBuildPath) -cne $input.appBuild.sha256) {
                throw "App build manifest hash mismatch: $key"
            }
            $appBuild = Get-Content -LiteralPath $appBuildPath -Raw | ConvertFrom-Json
            $appPart = @($input.components | Where-Object component -eq 'app')[0]
            $signedApp = Join-Path (Split-Path $entry.signedInputManifest) $appPart.artifacts[0].filename
            if ($appBuild.schema -cne 'go-mapi-app-artifacts-v2' -or $appBuild.component -cne 'app' -or
                $appBuild.distribution -cne 'machine' -or $appBuild.source.commit -cne $input.commit -or
                $appBuild.version -cne $appPart.version -or $appBuild.artifact.filename -cne 'go-mapi-machine.exe' -or
                $appBuild.artifact.sha256 -cne $input.appBuild.unsignedSha256 -or
                $appBuild.artifact.peProductVersion -cne $appPart.version -or
                $entry.componentSources.app.commit -cne $appBuild.source.commit -or
                $entry.componentSources.app.buildId -cne $input.appBuild.sha256 -or
                $entry.componentSources.app.signedSha256 -cne $appPart.artifacts[0].sha256 -or
                @($validation.peHashes | Where-Object { $_.component -ceq 'app' -and $_.architecture -ceq 'x64' })[0].unsignedSha256 -cne $input.appBuild.unsignedSha256 -or
                (Get-Item -LiteralPath $signedApp).VersionInfo.ProductVersion -cne $appPart.version -or
                (Get-Item -LiteralPath $signedApp).VersionInfo.FileVersion -cne $appPart.version) {
                throw "Suite app build/PE/source provenance mismatch: $key"
            }
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $entry.msi
        if ($signature.Status -ne 'Valid' -or $signature.SignatureType -ne 'Authenticode' -or
            -not $signature.TimeStamperCertificate -or
            $signature.SignerCertificate.Thumbprint -cne $validation.azure.leafThumbprint -or
            $signature.TimeStamperCertificate.Thumbprint -cne $validation.azure.timestampThumbprint -or
            $validation.azure.signatureStatus -cne 'Valid') {
            throw "Untrusted or unbound Azure MSI: $key"
        }
        & (Join-Path $repo 'src\installer\msi\verify.ps1') -SKU $sku -PackageRelease $entry.release -MsiPath $entry.msi -RequireSignature
        AssertMsiContains $key $entry $input
        $packages[$key] = [ordered]@{ sku=$sku; release=$entry.release; identity=$identity; msi=$entry.msi; sha256=$entry.msiSha256; size=(Get-Item $entry.msi).Length;
            serviceVersion=@($input.components | Where-Object component -eq 'service')[0].version;
            serviceSha256=@($input.components | Where-Object component -eq 'service')[0].artifacts[0].sha256;
            interceptorVersion=@($input.components | Where-Object component -eq 'interceptor')[0].version;
            x64DllSha256=@(@($input.components | Where-Object component -eq 'interceptor')[0].artifacts | Where-Object architecture -eq 'x64')[0].sha256;
            x86DllSha256=@(@($input.components | Where-Object component -eq 'interceptor')[0].artifacts | Where-Object architecture -eq 'x86')[0].sha256;
            appVersion=if ($sku -eq 'suite') { @($input.components | Where-Object component -eq 'app')[0].version } else { $null };
            appSha256=if ($sku -eq 'suite') { @($input.components | Where-Object component -eq 'app')[0].artifacts[0].sha256 } else { $null };
            signedInputManifest=$entry.signedInputManifest; componentSources=$entry.componentSources; packageSourceCommit=$entry.packageSourceCommit }
        $packages[$key].validationProvenance = $entry.validationProvenance
    }
    foreach ($sku in $(if ($systemKeys.Count -eq 3) { @('system','suite') } else { @('suite') })) {
        $a=$packages["${sku}A"]; $b=$packages["${sku}B"]; $c=$packages["${sku}C"]
        if ($a.identity.sequence -ge $b.identity.sequence -or $b.identity.sequence -ge $c.identity.sequence) {
            throw "$sku package releases must increase A/B/C"
        }
    }
    foreach ($partName in @('service','interceptor')) {
        $b = Get-Content $packages.suiteB.signedInputManifest -Raw | ConvertFrom-Json
        $c = Get-Content $packages.suiteC.signedInputManifest -Raw | ConvertFrom-Json
        $bp = @($b.components | Where-Object component -eq $partName)[0]
        $cp = @($c.components | Where-Object component -eq $partName)[0]
        if ($bp.version -cne $cp.version -or ($bp.artifacts | ConvertTo-Json -Compress) -cne ($cp.artifacts | ConvertTo-Json -Compress)) {
            throw "Suite C must reuse exact signed B $partName bytes"
        }
        if (($supplied.packages.suiteB.componentSources.$partName | ConvertTo-Json -Compress) -cne
            ($supplied.packages.suiteC.componentSources.$partName | ConvertTo-Json -Compress)) {
            throw "Suite C lost original B $partName source/build provenance"
        }
    }
    $prior = Get-Content -LiteralPath $packages.suiteC.validationProvenance -Raw | ConvertFrom-Json
    $bProof = Get-Content -LiteralPath $packages.suiteB.validationProvenance -Raw | ConvertFrom-Json
    AssertPriorBundle $packages.suiteB.validationProvenance $prior $bProof
    if ([Management.Automation.SemanticVersion]::Parse($packages.suiteB.appVersion) -ge
        [Management.Automation.SemanticVersion]::Parse($packages.suiteC.appVersion) -or
        $packages.suiteB.appSha256 -ceq $packages.suiteC.appSha256) {
        throw 'Suite C requires a higher app version and different final signed app bytes'
    }
    $references = [ordered]@{}
    if ($systemKeys.Count -eq 0) {
        $references.wrongSkuSystem = ResolveWrongSkuSystemReference ([string]$supplied.wrongSkuSystemFixtureManifest)
    }
    WriteJson (Join-Path $evidence 'machine-test-packages.json') ([ordered]@{
        schema='go-mapi-machine-test-packages-v1'; sourceCommit=$commit; generatedAtUtc=[DateTime]::UtcNow.ToString('o');
        fixture=[ordered]@{ metadataOrigin=$MetadataOrigin; artifactOrigin=$ArtifactOrigin; checkIntervalSeconds=$CheckIntervalSeconds; signing='pre-signed-Azure'; signerThumbprint=$null; signerPublicCertificate=$null };
        provenance=$supplied; packages=$packages; references=$references
    })
    return
}

$signToolCommand = Get-Command signtool.exe -ErrorAction SilentlyContinue
if (-not $signToolCommand) {
    $signToolCommand = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } | Sort-Object FullName -Descending | Select-Object -First 1
}
if (-not $signToolCommand) { throw 'Windows SDK signtool.exe is required' }
$signtool = if ($signToolCommand -is [IO.FileInfo]) { $signToolCommand.FullName } else { $signToolCommand.Source }
$signer = $null
$source = $null
$archive = $null
try {
$signer = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=go-mapi CI $([guid]::NewGuid().ToString('N'))" -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddDays(2)
$publicCert = Join-Path $output 'test-code-signing.cer'
Export-Certificate -Cert $signer -FilePath $publicCert | Out-Null
Import-Certificate -FilePath $publicCert -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $publicCert -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
$certRecord = [ordered]@{ thumbprint = $signer.Thumbprint; subject = $signer.Subject; scope = 'disposable-runner-only'; publicCertificate = $publicCert }
WriteJson (Join-Path $evidence 'test-signer.json') $certRecord

# A clean Git archive keeps versioned service derivatives away from tracked
# source and makes source provenance explicit. It is deleted after the builds.
$source = Join-Path $output 'source-derivative'
$archive = Join-Path $output 'source.zip'
New-Item -ItemType Directory -Force $source | Out-Null
& git -C $repo archive --format=zip -o $archive HEAD
if ($LASTEXITCODE -ne 0) { throw 'Could not archive source commit' }
Expand-Archive -LiteralPath $archive -DestinationPath $source
$originalOrigin = $env:MACHINE_RELEASE_METADATA_ORIGIN
$packages = [ordered]@{}
$serviceHashes = @{}
$appBuild = Get-Content -LiteralPath $AppBuildManifest -Raw | ConvertFrom-Json
if ($appBuild.source.commit -ne $commit -or $appBuild.distribution -ne 'machine' -or $appBuild.artifact.sha256 -ne (Hash $MachineApp)) {
    throw 'Machine app unsigned provenance differs from source or input bytes'
}
$suiteCBuild = $null
if ($SuiteCApp) {
    $suiteCBuild = Get-Content -LiteralPath $SuiteCAppBuildManifest -Raw | ConvertFrom-Json
    if ($suiteCBuild.source.commit -ne $commit -or $suiteCBuild.distribution -ne 'machine' -or
        $suiteCBuild.artifact.sha256 -ne (Hash $SuiteCApp) -or $suiteCBuild.version -ceq $appBuild.version) {
        throw 'Suite C machine app provenance/version mismatch'
    }
}
try {
    $env:MACHINE_RELEASE_METADATA_ORIGIN = $MetadataOrigin
    $x64 = Join-Path $output 'go-mapi-x64.dll'
    $x86 = Join-Path $output 'go-mapi-x86.dll'
    $app = Join-Path $output 'go-mapi-machine.exe'
    $appC = Join-Path $output 'go-mapi-machine-suiteC.exe'
    Copy-Item -LiteralPath $X64Dll -Destination $x64
    Copy-Item -LiteralPath $X86Dll -Destination $x86
    Copy-Item -LiteralPath $MachineApp -Destination $app
    Copy-Item -LiteralPath $AppBuildManifest -Destination (Join-Path $output 'app-artifacts.json')
    foreach ($path in @($x64,$x86,$app)) { Sign $path }
    if ($suiteCBuild) {
        Copy-Item -LiteralPath $SuiteCApp -Destination $appC
        Copy-Item -LiteralPath $SuiteCAppBuildManifest -Destination (Join-Path $output 'app-artifacts-suiteC.json')
        Sign $appC
    }
    $interceptorVersion = (Get-Content (Join-Path $repo 'src\interceptor\interceptor-version.txt') -Raw).Trim()
    $appVersion = [string]$appBuild.version
    $appBuildHash = Hash (Join-Path $output 'app-artifacts.json')
    foreach ($case in @(
        @{ key='systemA'; sku='system'; release='5.0.1-alpha.4'; service='5.0.1-alpha.4' },
        @{ key='systemB'; sku='system'; release='5.0.1-alpha.5'; service='5.0.1-alpha.5' },
        @{ key='systemC'; sku='system'; release='5.0.1-alpha.6'; service='5.0.1-alpha.6' },
        @{ key='suiteA'; sku='suite'; release='5.0.1-alpha.4'; service='5.0.1-alpha.4' },
        @{ key='suiteB'; sku='suite'; release='5.0.1-alpha.5'; service='5.0.1-alpha.5' },
        @{ key='suiteC'; sku='suite'; release='5.0.1-alpha.6'; service='5.0.1-alpha.5' }
    )) {
        $serviceVersion = $case.service
        Set-Content -LiteralPath (Join-Path $source 'src\service\VERSION') -Value $serviceVersion -NoNewline -Encoding ascii
        $servicePath = Join-Path $output "go-mapi-service-$serviceVersion.exe"
        if (-not $serviceHashes.ContainsKey($serviceVersion)) {
            & (Join-Path $source 'src\service\build.ps1') -OutputPath $servicePath -ArtifactOrigin $ArtifactOrigin -CheckIntervalSeconds $CheckIntervalSeconds
            if (-not (Test-Path $servicePath)) { throw "Service build failed: $serviceVersion" }
            Sign $servicePath
            $serviceHashes[$serviceVersion] = Hash $servicePath
        }
        $inputDir = Join-Path $output $case.key
        New-Item -ItemType Directory -Force $inputDir | Out-Null
        $caseApp = if ($case.key -eq 'suiteC') { $appC } else { $app }
        $caseBuild = if ($case.key -eq 'suiteC') { $suiteCBuild } else { $appBuild }
        if ($case.key -eq 'suiteC' -and -not $caseBuild) { continue }
        foreach ($path in @($x64,$x86)) { Copy-Item -LiteralPath $path -Destination $inputDir }
        Copy-Item -LiteralPath $servicePath -Destination (Join-Path $inputDir 'go-mapi-service.exe')
        Copy-Item -LiteralPath $caseApp -Destination (Join-Path $inputDir 'go-mapi-machine.exe')
        $caseBuildPath = if ($case.key -eq 'suiteC') { Join-Path $output 'app-artifacts-suiteC.json' } else { Join-Path $output 'app-artifacts.json' }
        Copy-Item -LiteralPath $caseBuildPath -Destination (Join-Path $inputDir 'app-artifacts.json')
        $inputManifest = Join-Path $inputDir 'signed-input.json'
        $appArgs = if ($case.sku -eq 'suite') { @{ AppVersion=[string]$caseBuild.version; AppBuildManifest=(Join-Path $inputDir 'app-artifacts.json'); UnsignedAppSha256=[string]$caseBuild.artifact.sha256 } } else { @{} }
        & (Join-Path $repo 'scripts/write-machine-signed-input.ps1') -SKU $case.sku -PackageRelease $case.release -SourceCommit $commit `
            -InputDirectory $inputDir -ServiceVersion $serviceVersion -InterceptorVersion $interceptorVersion @appArgs -OutputPath $inputManifest
        $msiDir = Join-Path $inputDir 'msi'
        & (Join-Path $repo 'src\installer\msi\build.ps1') -SKU $case.sku -SignedInputManifest $inputManifest -OutputDirectory $msiDir -RequireSignedInputs
        $identity = (& go run ./internal/mapi/cmd/machine-package -- $case.sku $case.release | ConvertFrom-Json)
        if ($LASTEXITCODE -ne 0) { throw 'Machine identity command failed' }
        $msiPath = Join-Path $msiDir $identity.assetName
        if (-not (Test-Path $msiPath)) { throw "Missing built MSI $msiPath" }
        Sign $msiPath
        & (Join-Path $repo 'src\installer\msi\verify.ps1') -SKU $case.sku -PackageRelease $case.release -MsiPath $msiPath
        $componentSources = [ordered]@{
            service=[ordered]@{ commit=$commit; buildId="test-service-$serviceVersion"; signedSha256=Hash $servicePath }
            interceptor=[ordered]@{ commit=$commit; buildId="test-interceptor-$interceptorVersion"; x64SignedSha256=Hash $x64; x86SignedSha256=Hash $x86 }
        }
        if ($case.sku -eq 'suite') {
            $componentSources.app = [ordered]@{ commit=$commit; buildId=Hash (Join-Path $inputDir 'app-artifacts.json'); signedSha256=Hash (Join-Path $inputDir 'go-mapi-machine.exe') }
        }
        $packages[$case.key] = [ordered]@{ sku=$case.sku; release=$case.release; identity=$identity; msi=$msiPath; sha256=Hash $msiPath; size=(Get-Item $msiPath).Length;
            serviceVersion=$serviceVersion; serviceSha256=Hash $servicePath; interceptorVersion=$interceptorVersion;
            x64DllSha256=Hash $x64; x86DllSha256=Hash $x86; appVersion=if ($case.sku -eq 'suite') { $caseBuild.version } else { $null };
            appSha256=if ($case.sku -eq 'suite') { Hash (Join-Path $inputDir 'go-mapi-machine.exe') } else { $null };
            signedInputManifest=$inputManifest; componentSources=$componentSources; packageSourceCommit=$commit }
    }
    if ($suiteCBuild) {
        foreach ($name in @('serviceSha256','x64DllSha256','x86DllSha256','serviceVersion','interceptorVersion')) {
            if ($packages.suiteB.$name -cne $packages.suiteC.$name) { throw "Suite C changed B $name" }
        }
        foreach ($name in @('service','interceptor')) {
            if (($packages.suiteB.componentSources.$name | ConvertTo-Json -Compress) -cne
                ($packages.suiteC.componentSources.$name | ConvertTo-Json -Compress)) { throw "Suite C lost B $name source/build provenance" }
        }
        if ($packages.suiteB.appSha256 -ceq $packages.suiteC.appSha256) { throw 'Suite C app bytes did not change' }
    }
    foreach ($package in $packages.Values) {
        if (-not (Test-Path -LiteralPath $package.msi -PathType Leaf) -or (Hash $package.msi) -ne $package.sha256) {
            throw "An earlier MSI output was removed or changed: $($package.msi)"
        }
    }
    WriteJson (Join-Path $evidence 'machine-test-packages.json') ([ordered]@{
        schema='go-mapi-machine-test-packages-v1'; sourceCommit=$commit; generatedAtUtc=[DateTime]::UtcNow.ToString('o');
        fixture=[ordered]@{ metadataOrigin=$MetadataOrigin; artifactOrigin=$ArtifactOrigin; checkIntervalSeconds=$CheckIntervalSeconds; signing='self-signed-disposable'; signerThumbprint=$signer.Thumbprint; signerPublicCertificate=$publicCert; serviceVersionDerivative='src/service/VERSION only in isolated archive' };
        sourceSubstitutions=[ordered]@{ appVersion=$appVersion; suiteCAppVersion=if ($suiteCBuild) { [string]$suiteCBuild.version } else { $null }; interceptorVersion=$interceptorVersion; canonicalServiceVersion=(Get-Content (Join-Path $repo 'src\service\VERSION') -Raw).Trim(); canonicalAppVersion=(Get-Content (Join-Path $source 'src\app\VERSION') -Raw).Trim(); canonicalInterceptorVersion=(Get-Content (Join-Path $source 'src\interceptor\interceptor-version.txt') -Raw).Trim() };
        inputs=[ordered]@{ x64DllSha256=Hash $X64Dll; x86DllSha256=Hash $X86Dll; unsignedMachineAppSha256=Hash $MachineApp; appBuildManifestSha256=Hash $AppBuildManifest;
            suiteCUnsignedAppSha256=if ($SuiteCApp) { Hash $SuiteCApp } else { $null }; suiteCAppBuildManifestSha256=if ($SuiteCAppBuildManifest) { Hash $SuiteCAppBuildManifest } else { $null } };
        packages=$packages
    })
} finally {
    $env:MACHINE_RELEASE_METADATA_ORIGIN = $originalOrigin
    if (Test-Path -LiteralPath $source) { Remove-Item -LiteralPath $source -Recurse -Force }
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
}
} catch {
    if ($source -and (Test-Path -LiteralPath $source)) { Remove-Item -LiteralPath $source -Recurse -Force }
    if ($archive -and (Test-Path -LiteralPath $archive)) { Remove-Item -LiteralPath $archive -Force }
    if ($signer) {
        foreach ($store in @('Root','TrustedPublisher','My')) {
            $path = "Cert:\LocalMachine\$store\$($signer.Thumbprint)"
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
    }
    throw
}
