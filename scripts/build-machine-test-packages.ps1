# Build disposable, signed machine packages for native CI. Never use these
# certificates or packages for publication.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$X64Dll,
    [Parameter(Mandatory)][string]$X86Dll,
    [Parameter(Mandatory)][string]$MachineApp,
    [Parameter(Mandatory)][string]$AppBuildManifest,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
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
foreach ($path in @($X64Dll,$X86Dll,$MachineApp,$AppBuildManifest)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing input $path" }
}
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
function Artifact([string]$Path, [string]$Arch) {
    [ordered]@{ architecture = $Arch; filename = [IO.Path]::GetFileName($Path); sha256 = Hash $Path }
}
function Component([string]$Name, [string]$Version, $Artifacts) {
    $value = [ordered]@{ component = $Name; version = $Version; artifacts = @($Artifacts) }
    if ($Name -eq 'app') { $value.distribution = 'machine' }
    $value
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
try {
    $env:MACHINE_RELEASE_METADATA_ORIGIN = $MetadataOrigin
    $x64 = Join-Path $output 'go-mapi-x64.dll'
    $x86 = Join-Path $output 'go-mapi-x86.dll'
    $app = Join-Path $output 'go-mapi-machine.exe'
    Copy-Item -LiteralPath $X64Dll -Destination $x64
    Copy-Item -LiteralPath $X86Dll -Destination $x86
    Copy-Item -LiteralPath $MachineApp -Destination $app
    Copy-Item -LiteralPath $AppBuildManifest -Destination (Join-Path $output 'app-artifacts.json')
    foreach ($path in @($x64,$x86,$app)) { Sign $path }
    $interceptorVersion = (Get-Content (Join-Path $repo 'src\interceptor\interceptor-version.txt') -Raw).Trim()
    $appVersion = [string]$appBuild.version
    $appBuildHash = Hash (Join-Path $output 'app-artifacts.json')
    foreach ($case in @(
        @{ key='systemA'; sku='system'; release='5.0.1-alpha.4'; service='5.0.1-alpha.4' },
        @{ key='systemB'; sku='system'; release='5.0.1-alpha.5'; service='5.0.1-alpha.5' },
        @{ key='systemC'; sku='system'; release='5.0.1-alpha.6'; service='5.0.1-alpha.6' },
        @{ key='suiteA'; sku='suite'; release='5.0.1-alpha.4'; service='5.0.1-alpha.4' },
        @{ key='suiteB'; sku='suite'; release='5.0.1-alpha.5'; service='5.0.1-alpha.5' }
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
        foreach ($path in @($x64,$x86,$app,$servicePath)) { Copy-Item -LiteralPath $path -Destination $inputDir }
        Copy-Item -LiteralPath (Join-Path $output 'app-artifacts.json') -Destination $inputDir
        $components = @(
            (Component 'service' $serviceVersion @((Artifact (Join-Path $inputDir (Split-Path $servicePath -Leaf)) 'x64'))),
            (Component 'interceptor' $interceptorVersion @((Artifact (Join-Path $inputDir (Split-Path $x64 -Leaf)) 'x64'),(Artifact (Join-Path $inputDir (Split-Path $x86 -Leaf)) 'x86')))
        )
        $manifest = [ordered]@{ schema='go-mapi-machine-signed-input-v1'; sku=$case.sku; packageRelease=$case.release; commit=$commit; components=$components }
        if ($case.sku -eq 'suite') {
            $manifest.components += (Component 'app' $appVersion @((Artifact (Join-Path $inputDir (Split-Path $app -Leaf)) 'x64')))
            $manifest.appBuild = [ordered]@{ manifest='app-artifacts.json'; sha256=$appBuildHash; unsignedSha256=$appBuild.artifact.sha256 }
        }
        $inputManifest = Join-Path $inputDir 'signed-input.json'
        WriteJson $inputManifest $manifest
        $msiDir = Join-Path $inputDir 'msi'
        & (Join-Path $repo 'src\installer\msi\build.ps1') -SKU $case.sku -SignedInputManifest $inputManifest -OutputDirectory $msiDir -RequireSignedInputs
        $identity = (& go run ./internal/mapi/cmd/machine-package -- $case.sku $case.release | ConvertFrom-Json)
        if ($LASTEXITCODE -ne 0) { throw 'Machine identity command failed' }
        $msiPath = Join-Path $msiDir $identity.assetName
        if (-not (Test-Path $msiPath)) { throw "Missing built MSI $msiPath" }
        Sign $msiPath
        & (Join-Path $repo 'src\installer\msi\verify.ps1') -SKU $case.sku -PackageRelease $case.release -MsiPath $msiPath
        $packages[$case.key] = [ordered]@{ sku=$case.sku; release=$case.release; identity=$identity; msi=$msiPath; sha256=Hash $msiPath; size=(Get-Item $msiPath).Length; serviceVersion=$serviceVersion; serviceSha256=Hash $servicePath; interceptorVersion=$interceptorVersion; appVersion=if ($case.sku -eq 'suite') { $appVersion } else { $null } }
    }
    foreach ($package in $packages.Values) {
        if (-not (Test-Path -LiteralPath $package.msi -PathType Leaf) -or (Hash $package.msi) -ne $package.sha256) {
            throw "An earlier MSI output was removed or changed: $($package.msi)"
        }
    }
    WriteJson (Join-Path $evidence 'machine-test-packages.json') ([ordered]@{
        schema='go-mapi-machine-test-packages-v1'; sourceCommit=$commit; generatedAtUtc=[DateTime]::UtcNow.ToString('o');
        fixture=[ordered]@{ metadataOrigin=$MetadataOrigin; artifactOrigin=$ArtifactOrigin; checkIntervalSeconds=$CheckIntervalSeconds; signerThumbprint=$signer.Thumbprint; signerPublicCertificate=$publicCert; serviceVersionDerivative='src/service/VERSION only in isolated archive' };
        sourceSubstitutions=[ordered]@{ appVersion=$appVersion; interceptorVersion=$interceptorVersion; canonicalServiceVersion=(Get-Content (Join-Path $repo 'src\service\VERSION') -Raw).Trim(); canonicalAppVersion=(Get-Content (Join-Path $source 'src\app\VERSION') -Raw).Trim(); canonicalInterceptorVersion=(Get-Content (Join-Path $source 'src\interceptor\interceptor-version.txt') -Raw).Trim() };
        inputs=[ordered]@{ x64DllSha256=Hash $X64Dll; x86DllSha256=Hash $X86Dll; unsignedMachineAppSha256=Hash $MachineApp; appBuildManifestSha256=Hash $AppBuildManifest };
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
