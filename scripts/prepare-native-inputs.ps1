#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$CheckoutRoot = (Join-Path $PSScriptRoot '..'),
    [string]$X64BuildDirectory,
    [string]$X86BuildDirectory,
    # Parent of protocol-fixtures and component-compatibility. Omit to use each
    # build's original fixtures; relocation never changes the compiled paths.
    [string]$FixtureSourceRoot,
    [string]$ServiceTestBinary,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Release', 'Debug')][string]$Configuration = 'Release'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-FullPath([string]$Path) { [IO.Path]::GetFullPath($Path) }
function Get-PEMachine([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Not a PE file: $Path" }
        $stream.Position = 0x3c
        $stream.Position = $reader.ReadUInt32()
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Not a PE file: $Path" }
        return $reader.ReadUInt16()
    } finally { $reader.Dispose() }
}
function Get-CacheValue([string]$Text, [string]$Name) {
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + ':[^=\r\n]+=(.*)\r?$')
    if (-not $match.Success) { throw "CMake cache is missing $Name" }
    return $match.Groups[1].Value.Trim()
}
function Get-CompiledPath([string]$Ninja, [string]$Name, [string]$Binary) {
    $paths = @([regex]::Matches($Ninja, [regex]::Escape($Name) + '=\\?"([^"\r\n]*?)\\?"') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($paths.Count -ne 1 -or $paths[0] -notmatch '^[A-Za-z]:/') {
        throw "Expected one absolute Windows $Name definition in build.ninja. Rebuild with src/interceptor/build.ps1."
    }
    # A stale/reconfigured CMake tree must not silently describe different bytes.
    $contents = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Binary))
    if (-not $contents.Contains($paths[0])) { throw "$Name in CMake metadata does not match $Binary; rebuild it." }
    return $paths[0]
}

$checkout = (Get-Item -LiteralPath $CheckoutRoot).FullName
if (-not $X64BuildDirectory) { $X64BuildDirectory = Join-Path $checkout 'src/interceptor/build-x64' }
if (-not $X86BuildDirectory) { $X86BuildDirectory = Join-Path $checkout 'src/interceptor/build-x86' }
$output = Get-FullPath $OutputDirectory
if (Test-Path -LiteralPath $output) { throw "OutputDirectory must be new (no merging or replacement): $output" }
$copies = [Collections.Generic.List[object]]::new()
$builds = [Collections.Generic.List[object]]::new()
$units = @('message_converter_tests', 'fs_utils_tests', 'queue_v1_tests', 'component_compat_tests')
$queueFiles = @('plain-message.json', 'html-with-attachment.json', 'invalid-attachment.json', 'invalid-timestamp.json', 'invalid-unsupported-version.json')
foreach ($arch in @('x64', 'x86')) {
    $build = Get-FullPath $(if ($arch -eq 'x64') { $X64BuildDirectory } else { $X86BuildDirectory })
    $cachePath = Join-Path $build 'CMakeCache.txt'
    $ninjaPath = Join-Path $build 'build.ninja'
    $cache = Get-Content -LiteralPath $cachePath -Raw
    if ((Get-CacheValue $cache 'CMAKE_GENERATOR') -ne 'Ninja' -or
        (Get-CacheValue $cache 'CMAKE_BUILD_TYPE') -ne $Configuration -or
        (Get-CacheValue $cache 'BUILD_TESTS') -ne 'ON') {
        throw "$arch requires a Ninja $Configuration build with BUILD_TESTS=ON; use src/interceptor/build.ps1 -Tests."
    }
    $ninja = Get-Content -LiteralPath $ninjaPath -Raw
    foreach ($name in @($units | ForEach-Object { "$_.exe" }) + @('go-mapi-test-harness.exe', 'go-mapi.dll')) {
        $source = Join-Path $build "bin/$name"
        $machine = Get-PEMachine $source
        $expected = if ($arch -eq 'x64') { 0x8664 } else { 0x14c }
        if ($machine -ne $expected) { throw "Wrong PE architecture for ${arch}: $source" }
        $copies.Add([pscustomobject]@{ Source = $source; Path = "$arch/$name" })
    }
    $queue = Get-CompiledPath $ninja 'GO_MAPI_QUEUE_FIXTURE_DIR' (Join-Path $build 'bin/queue_v1_tests.exe')
    $compat = Get-CompiledPath $ninja 'GO_MAPI_COMPAT_FIXTURE' (Join-Path $build 'bin/component_compat_tests.exe')
    $root = Split-Path (Split-Path (Get-FullPath $queue) -Parent) -Parent
    if ((Get-FullPath $queue) -ne (Join-Path $root 'protocol-fixtures/queue-v1') -or
        (Get-FullPath $compat) -ne (Join-Path $root 'component-compatibility/compatibility-v1.json')) {
        throw "Unsupported fixture layout in $arch build metadata. Expected one tests fixture root."
    }
    $fixtureSource = if ($FixtureSourceRoot) { Get-FullPath $FixtureSourceRoot } else { $root }
    foreach ($relative in @($queueFiles | ForEach-Object { "protocol-fixtures/queue-v1/$_" }) + @('component-compatibility/compatibility-v1.json')) {
        $source = Join-Path $fixtureSource $relative
        # Even the intentionally invalid protocol cases are syntactically JSON.
        $null = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json
        $copies.Add([pscustomobject]@{ Source = $source; Path = "fixtures/$arch/$relative" })
    }
    $builds.Add([ordered]@{
        Architecture = $arch; BuildDirectory = $build; Configuration = $Configuration
        CMakeSourceDirectory = Get-CacheValue $cache 'CMAKE_HOME_DIRECTORY'
        Compiler = Get-CacheValue $cache 'CMAKE_CXX_COMPILER'
        CMakeCacheSHA256 = (Get-FileHash -LiteralPath $cachePath -Algorithm SHA256).Hash
        NinjaSHA256 = (Get-FileHash -LiteralPath $ninjaPath -Algorithm SHA256).Hash
        CompiledQueueFixtureDirectory = $queue; CompiledCompatibilityFixtureFile = $compat
        BuildFixtureRoot = $root; FixtureSourceRoot = $fixtureSource
    })
}
$service = $null
if ($ServiceTestBinary) {
    $servicePath = (Get-Item -LiteralPath $ServiceTestBinary).FullName
    $machine = Get-PEMachine $servicePath
    if ($machine -notin @(0x14c, 0x8664, 0xaa64)) { throw 'Unsupported service test PE architecture.' }
    $fixture = (Get-Item -LiteralPath (Join-Path $checkout 'src/service/runner_windows.go')).FullName
    $service = [ordered]@{ Source = $servicePath; Path = 'service.test.exe'; FixturePath = 'runner_windows.go'; PEMachine = ('0x{0:x4}' -f $machine) }
    $copies.Add([pscustomobject]@{ Source = $servicePath; Path = $service.Path })
    $copies.Add([pscustomobject]@{ Source = $fixture; Path = $service.FixturePath })
}
foreach ($name in @('Test-Native.ps1', 'NativeGuest.ps1')) {
    $copies.Add([pscustomobject]@{ Source = (Join-Path $PSScriptRoot "../tests/sandbox/native/$name"); Path = $name })
}
# Identity of the selected checkout is context, not proof that dirty/pre-existing
# binaries were built from HEAD. Artifact/fixture hashes are the exact handoff.
$head = & git -C $checkout rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot record checkout HEAD.' }
$dirty = @(& git -C $checkout status --porcelain --untracked-files=normal -- src/interceptor tests/protocol-fixtures tests/component-compatibility src/service internal components.json go.mod go.sum)
if ($LASTEXITCODE -ne 0) { throw 'Cannot record relevant checkout status.' }
New-Item -ItemType Directory -Path $output | Out-Null
$files = foreach ($copy in $copies) {
    $target = Join-Path $output $copy.Path
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $copy.Source -Destination $target
    [ordered]@{ Path = $copy.Path; Source = $copy.Source; Bytes = (Get-Item -LiteralPath $target).Length; SHA256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash }
}
$manifest = [ordered]@{
    Schema = 'go-mapi-sandbox-native-v2'; PreparedAtUtc = [DateTime]::UtcNow.ToString('o')
    CheckoutRoot = $checkout; CheckoutHead = [string]$head; RelevantCheckoutStatus = $dirty
    Builds = @($builds); Service = $service; Files = @($files)
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'native-inputs.json') -Encoding utf8
[pscustomobject]@{ InputDirectory = $output; ScriptPath = 'Test-Native.ps1'; Manifest = (Join-Path $output 'native-inputs.json'); ServiceIncluded = ($null -ne $service) }
