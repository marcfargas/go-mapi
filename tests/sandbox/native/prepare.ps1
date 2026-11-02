#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$CheckoutRoot = (Join-Path $PSScriptRoot '../../..'),
    [string]$X64BuildDirectory,
    [string]$X86BuildDirectory,
    [string]$FixtureSourceRoot,
    [string]$ServiceTestBinary,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Release', 'Debug')][string]$Configuration = 'Release'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PEMachine([string]$Path) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Not a PE file: $Path" }
        $reader.BaseStream.Position = 0x3c
        $reader.BaseStream.Position = $reader.ReadUInt32()
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Not a PE file: $Path" }
        $reader.ReadUInt16()
    } finally { $reader.Dispose() }
}
$checkout = (Get-Item -LiteralPath $CheckoutRoot).FullName
if (-not $X64BuildDirectory) { $X64BuildDirectory = Join-Path $checkout 'src/interceptor/build-x64' }
if (-not $X86BuildDirectory) { $X86BuildDirectory = Join-Path $checkout 'src/interceptor/build-x86' }
if (-not $FixtureSourceRoot) { $FixtureSourceRoot = Join-Path $checkout 'tests' }
$fixtureRoot = (Get-Item -LiteralPath $FixtureSourceRoot).FullName
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "OutputDirectory must be new (no merging or replacement): $output" }
$copies = [Collections.Generic.List[object]]::new()
$builds = foreach ($arch in @('x64', 'x86')) {
    $build = [IO.Path]::GetFullPath($(if ($arch -eq 'x64') { $X64BuildDirectory } else { $X86BuildDirectory }))
    foreach ($name in @('message_converter_tests.exe', 'fs_utils_tests.exe', 'queue_v1_tests.exe',
        'component_compat_tests.exe', 'go-mapi-test-harness.exe', 'go-mapi.dll')) {
        $source = Join-Path $build "bin/$name"
        $expected = if ($arch -eq 'x64') { 0x8664 } else { 0x14c }
        if ((Get-PEMachine $source) -ne $expected) { throw "Wrong PE architecture for ${arch}: $source" }
        $copies.Add([pscustomobject]@{ Source = $source; Path = "$arch/$name" })
    }
    [ordered]@{ Architecture = $arch; BuildDirectory = $build; Configuration = $Configuration }
}
# Fixture locations are runtime inputs, not paths compiled into the executables.
foreach ($relative in @('plain-message.json', 'html-with-attachment.json', 'invalid-attachment.json',
    'invalid-timestamp.json', 'invalid-unsupported-version.json') | ForEach-Object { "protocol-fixtures/queue-v1/$_" }) {
    $copies.Add([pscustomobject]@{ Source = (Join-Path $fixtureRoot $relative); Path = "fixtures/$relative" })
}
$copies.Add([pscustomobject]@{ Source = (Join-Path $fixtureRoot 'component-compatibility/compatibility-v1.json'); Path = 'fixtures/component-compatibility/compatibility-v1.json' })
foreach ($copy in $copies | Where-Object { $_.Path.StartsWith('fixtures/') }) {
    $null = Get-Content -LiteralPath $copy.Source -Raw | ConvertFrom-Json
}
$service = $null
if ($ServiceTestBinary) {
    $source = (Get-Item -LiteralPath $ServiceTestBinary).FullName
    $machine = Get-PEMachine $source
    if ($machine -notin @(0x14c, 0x8664, 0xaa64)) { throw 'Unsupported service test PE architecture.' }
    $service = [ordered]@{ Path = 'service.test.exe'; PEMachine = ('0x{0:x4}' -f $machine) }
    $copies.Add([pscustomobject]@{ Source = $source; Path = $service.Path })
}
foreach ($name in @('Test-Native.ps1', 'NativeGuest.ps1')) {
    $copies.Add([pscustomobject]@{ Source = (Join-Path $PSScriptRoot $name); Path = $name })
}
# HEAD is context only; selected file hashes identify dirty or prebuilt inputs.
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
[ordered]@{
    Schema = 'go-mapi-sandbox-native-v3'; PreparedAtUtc = [DateTime]::UtcNow.ToString('o')
    CheckoutRoot = $checkout; CheckoutHead = [string]$head; RelevantCheckoutStatus = $dirty
    Builds = @($builds); FixtureRoot = 'fixtures'; Service = $service; Files = @($files)
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'native-inputs.json') -Encoding utf8
[pscustomobject]@{ InputDirectory = $output; ScriptPath = 'Test-Native.ps1'; Manifest = (Join-Path $output 'native-inputs.json'); ServiceIncluded = ($null -ne $service) }
