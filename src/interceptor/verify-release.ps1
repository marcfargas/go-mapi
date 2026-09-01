# Builds and verifies the independently releasable interceptor unit only.
# It deliberately does not invoke the app, Wails, an installer, registry tools,
# elevation, or any npm workspace command.
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$PreserveQueueEvidence
)

$ErrorActionPreference = "Stop"
$interceptorRoot = $PSScriptRoot
$repoRoot = [IO.Path]::GetFullPath((Join-Path $interceptorRoot "..\.."))
$componentFile = Join-Path $repoRoot "components.json"
$versionFile = Join-Path $interceptorRoot "interceptor-version.txt"

# $PSScriptRoot is initialized only after parameter binding, so calculate the
# default here rather than in the param block.
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "release\interceptor"
}

function Fail([string]$Message) { throw "Interceptor release verification failed: $Message" }

function Get-PeMachine([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { Fail "$Path is not an MZ executable" }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { Fail "$Path has no PE signature" }
        switch ($reader.ReadUInt16()) {
            0x014c { return "x86" }
            0x8664 { return "x64" }
            default { Fail "$Path has an unsupported PE machine type" }
        }
    } finally { $stream.Dispose() }
}

function Get-RequiredExports([string]$DefPath) {
    return @(Get-Content -LiteralPath $DefPath | ForEach-Object {
        $line = $_.Trim()
        if ($line -and $line -notmatch '^(LIBRARY|EXPORTS)\b') { ($line -split '\s+')[0] }
    })
}

function Assert-Exports([string]$DllPath, [string[]]$RequiredExports) {
    $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if ($dumpbin) {
        $exports = & $dumpbin.Source /exports $DllPath 2>&1 | Out-String
    } else {
        $nm = Get-Command llvm-nm.exe -ErrorAction SilentlyContinue
        if (-not $nm) { $nm = Get-Command nm.exe -ErrorAction SilentlyContinue }
        if (-not $nm) { Fail "Neither dumpbin.exe nor llvm-nm.exe/nm.exe is available to inspect exports" }
        $exports = & $nm.Source -g --defined-only $DllPath 2>&1 | Out-String
    }
    foreach ($export in $RequiredExports) {
        if ($exports -notmatch "(?m)(^|[\s_])$([regex]::Escape($export))(@\d+)?(\s|$)") {
            Fail "$DllPath does not export required symbol $export"
        }
    }
}

function Get-QueueDirectory { Join-Path $env:LOCALAPPDATA "go-mapi\queue" }

function Get-QueueJsonPaths([string]$QueueDirectory) {
    if (-not (Test-Path -LiteralPath $QueueDirectory)) { return @() }
    return @(Get-ChildItem -LiteralPath $QueueDirectory -Filter '*.json' -File | ForEach-Object { $_.FullName })
}

function Assert-HarnessQueueVersion([string]$Arch, [string]$QueueDirectory, [string[]]$BeforePaths, [string]$ExpectedVersion) {
    $newPaths = @(Get-QueueJsonPaths $QueueDirectory | Where-Object { $_ -notin $BeforePaths })
    if ($newPaths.Count -eq 0) { Fail "$Arch harness did not emit queue-v1 descriptors" }
    $matching = @($newPaths | Where-Object {
        try { (Get-Content -LiteralPath $_ -Raw | ConvertFrom-Json).interceptorVersion -eq $ExpectedVersion } catch { $false }
    })
    if ($matching.Count -eq 0) { Fail "$Arch harness emitted no descriptor with interceptorVersion $ExpectedVersion" }
    if (-not $PreserveQueueEvidence) {
        foreach ($path in $newPaths) {
            $descriptor = Get-Item -LiteralPath $path
            Remove-Item -LiteralPath $path -Force
            Remove-Item -LiteralPath (Join-Path $descriptor.DirectoryName $descriptor.BaseName) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not (Test-Path -LiteralPath $componentFile)) { Fail "missing components.json" }
if (-not (Test-Path -LiteralPath $versionFile)) { Fail "missing src/interceptor/interceptor-version.txt" }
$component = ((Get-Content -LiteralPath $componentFile -Raw | ConvertFrom-Json).components.interceptor)
$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($version) -or $version -eq "0.0.0-dev") { Fail "interceptor-version.txt must be a non-development release version" }
if ($component.artifact -ne "go-mapi.dll") { Fail "internal artifact must remain go-mapi.dll" }
if ($component.queueProtocol -ne "queue-v1") { Fail "queue protocol must be queue-v1" }
if ($component.requires.component -ne 'app' -or [string]::IsNullOrWhiteSpace($component.requires.minInclusive)) { Fail 'interceptor counterpart requirement is invalid' }
$manifestArchitectures = @($component.architectures | Sort-Object)
if ($manifestArchitectures.Count -ne 2 -or ($manifestArchitectures -join ',') -ne 'x64,x86') { Fail "manifest must declare exactly x64 and x86" }
if ($component.publicationNames.x64 -ne "go-mapi-x64.dll" -or $component.publicationNames.x86 -ne "go-mapi-x86.dll") { Fail "manifest publication names are invalid" }

$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
New-Item -ItemType Directory -Path $output -Force | Out-Null
$requiredExports = Get-RequiredExports (Join-Path $interceptorRoot "mapi_exports.def")
$artifacts = @()

foreach ($arch in @("x64", "x86")) {
    & (Join-Path $interceptorRoot "build.ps1") -Arch $arch -Config Release -Tests -Clean -Release
    if ($LASTEXITCODE -ne 0) { Fail "$arch build failed" }

    $buildDir = Join-Path $interceptorRoot "build-$arch"
    $dll = Join-Path $buildDir "bin\go-mapi.dll"
    $harness = Join-Path $buildDir "bin\go-mapi-test-harness.exe"
    if (-not (Test-Path -LiteralPath $dll) -or -not (Test-Path -LiteralPath $harness)) { Fail "$arch build did not produce DLL and matching harness" }
    if ((Get-PeMachine $dll) -ne $arch) { Fail "$arch DLL PE machine does not match" }
    if ((Get-PeMachine $harness) -ne $arch) { Fail "$arch harness PE machine does not match" }
    Assert-Exports $dll $requiredExports
    $peVersion = (Get-Item -LiteralPath $dll).VersionInfo.ProductVersion
    if ($peVersion -notmatch [regex]::Escape($version)) { Fail "$arch DLL ProductVersion $peVersion does not match $version" }
    & ctest --test-dir $buildDir --output-on-failure
    if ($LASTEXITCODE -ne 0) { Fail "$arch CTest failed" }
    $queueDirectory = Get-QueueDirectory
    $queueBefore = Get-QueueJsonPaths $queueDirectory
    $env:GO_MAPI_TEST_RETAIN_OUTPUT = "1"
    & $harness $dll
    if ($LASTEXITCODE -ne 0) { Fail "$arch matching-bitness harness failed" }
    Remove-Item Env:GO_MAPI_TEST_RETAIN_OUTPUT -ErrorAction SilentlyContinue
    Assert-HarnessQueueVersion $arch $queueDirectory $queueBefore $version

    $publishedName = [string]$component.publicationNames.$arch
    $publishedPath = Join-Path $output $publishedName
    Copy-Item -LiteralPath $dll -Destination $publishedPath -Force
    $artifacts += [ordered]@{
        architecture = $arch
        filename = $publishedName
        sha256 = (Get-FileHash -LiteralPath $publishedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        peMachine = (Get-PeMachine $publishedPath)
        peProductVersion = $version
    }
}

$artifactManifest = [ordered]@{
    component = "interceptor"
    version = $version
    queueProtocol = $component.queueProtocol
    requires = $component.requires
    artifacts = $artifacts
}
# Windows PowerShell 5.1 does not support Set-Content's utf8NoBOM encoding
# value.  Use .NET explicitly so both Windows PowerShell 5.1 and PowerShell 7
# produce the release manifest as UTF-8 without a BOM.
$artifactManifestJson = $artifactManifest | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText(
    (Join-Path $output "interceptor-artifacts.json"),
    $artifactManifestJson,
    (New-Object System.Text.UTF8Encoding($false))
)
Write-Host "Verified and staged interceptor release artifacts in $output"
