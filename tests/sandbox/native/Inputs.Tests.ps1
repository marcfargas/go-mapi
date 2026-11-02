#requires -Version 7.0
# Host-only contracts. Never invokes the guest entrypoint, a native unit/harness,
# a service test binary, or Windows Sandbox.
[CmdletBinding()]
param(
    [string]$CheckoutRoot = (Join-Path $PSScriptRoot '../../..'),
    [string]$X64BuildDirectory,
    [string]$X86BuildDirectory,
    [string]$ServiceTestBinary,
    [string]$EvidenceDirectory = (Join-Path $PSScriptRoot ('../../../test-results/native-inputs-' + [guid]::NewGuid().ToString('N')))
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$checkout = [IO.Path]::GetFullPath($CheckoutRoot)
if (-not $X64BuildDirectory) { $X64BuildDirectory = Join-Path $checkout 'src/interceptor/build-x64' }
if (-not $X86BuildDirectory) { $X86BuildDirectory = Join-Path $checkout 'src/interceptor/build-x86' }
if (Test-Path -LiteralPath $EvidenceDirectory) { throw 'Select a new evidence directory.' }
New-Item -ItemType Directory -Path $EvidenceDirectory | Out-Null
$evidence = (Get-Item -LiteralPath $EvidenceDirectory).FullName
$guestLibrary = Join-Path $PSScriptRoot 'NativeGuest.ps1'
. $guestLibrary
$prepare = Join-Path $PSScriptRoot 'prepare.ps1'
$tests = [Collections.Generic.List[string]]::new()
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected failure matching $Pattern"
}
$parameters = @{ CheckoutRoot = $checkout; X64BuildDirectory = $X64BuildDirectory; X86BuildDirectory = $X86BuildDirectory }
if ($ServiceTestBinary) { $parameters.ServiceTestBinary = $ServiceTestBinary }
$status = 'FAIL'
try {
    $staged = & $prepare @parameters -OutputDirectory (Join-Path $evidence 'selected')
    $manifest = Get-Content -LiteralPath $staged.Manifest -Raw | ConvertFrom-Json
    Assert ($manifest.Schema -eq 'go-mapi-sandbox-native-v3' -and $manifest.FixtureRoot -ceq 'fixtures') 'Expected the runtime-fixture manifest contract.'
    Assert ($manifest.Builds.Count -eq 2) 'Both architectures must be staged.'
    $expectedFiles = @('Test-Native.ps1', 'NativeGuest.ps1')
    foreach ($arch in @('x64', 'x86')) {
        $expectedFiles += @('message_converter_tests.exe', 'fs_utils_tests.exe', 'queue_v1_tests.exe',
            'component_compat_tests.exe', 'go-mapi-test-harness.exe', 'go-mapi.dll') | ForEach-Object { "$arch/$_" }
    }
    $expectedFiles += @('plain-message.json', 'html-with-attachment.json', 'invalid-attachment.json',
        'invalid-timestamp.json', 'invalid-unsupported-version.json') | ForEach-Object { "fixtures/protocol-fixtures/queue-v1/$_" }
    $expectedFiles += 'fixtures/component-compatibility/compatibility-v1.json'
    if ($ServiceTestBinary) {
        $expectedFiles += 'service.test.exe'
        Assert ($manifest.Service.Path -ceq 'service.test.exe') 'Service inputs must declare the binary.'
    }
    Assert (-not (Compare-Object ($expectedFiles | Sort-Object) ($manifest.Files.Path | Sort-Object))) 'Staged file set differs from the selected binaries, fixtures and guest scripts.'
    foreach ($file in $manifest.Files) {
        Assert ((Get-FileHash -LiteralPath (Join-Path $staged.InputDirectory $file.Path)).Hash -eq $file.SHA256) "Hash mismatch: $($file.Path)"
        Assert ((Get-FileHash -LiteralPath $file.Source).Hash -eq $file.SHA256) "Source mismatch: $($file.Path)"
    }
    $tests.Add('real Release inputs: both architectures, runtime fixtures, source/staged hashes, optional service')
    Expect-Failure { & $prepare @parameters -OutputDirectory $staged.InputDirectory } 'must be new'
    $tests.Add('existing output refused without replacement')
    # Builds and fixture sources relocate without recreating the original checkout.
    $relocated = Join-Path $evidence 'relocated fixtures'
    New-Item -ItemType Directory -Path $relocated | Out-Null
    Copy-Item -LiteralPath (Join-Path $checkout 'tests/protocol-fixtures'),(Join-Path $checkout 'tests/component-compatibility') -Destination $relocated -Recurse
    $copiedBuilds = @{}
    foreach ($build in $manifest.Builds) {
        $copy = Join-Path $evidence ("moved build with spaces/" + $build.Architecture)
        New-Item -ItemType Directory -Path $copy -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $build.BuildDirectory 'bin') -Destination $copy -Recurse
        $copiedBuilds[$build.Architecture] = $copy
    }
    $moved = & $prepare -CheckoutRoot $checkout -X64BuildDirectory $copiedBuilds.x64 -X86BuildDirectory $copiedBuilds.x86 -FixtureSourceRoot $relocated -OutputDirectory (Join-Path $evidence 'moved-selected')
    $movedManifest = Get-Content -LiteralPath $moved.Manifest -Raw | ConvertFrom-Json
    Assert ($movedManifest.Builds[0].BuildDirectory -eq $copiedBuilds.x64 -and $null -eq $movedManifest.Service) 'Explicit build directory or optional service handling failed.'
    foreach ($file in $movedManifest.Files | Where-Object { $_.Path.StartsWith('fixtures/') }) {
        Assert ($file.Source.StartsWith($relocated + [IO.Path]::DirectorySeparatorChar)) 'Explicit fixture source was ignored.'
    }
    $tests.Add('relocated x86/x64 builds and runtime fixture source with spaces; service omitted')
    Copy-Item -LiteralPath (Join-Path $copiedBuilds.x86 'bin/queue_v1_tests.exe') -Destination (Join-Path $copiedBuilds.x64 'bin/queue_v1_tests.exe') -Force
    Expect-Failure { & $prepare -CheckoutRoot $checkout -X64BuildDirectory $copiedBuilds.x64 -X86BuildDirectory $copiedBuilds.x86 -OutputDirectory (Join-Path $evidence 'wrong-arch') } 'Wrong PE architecture'
    $tests.Add('mixed PE architectures refused')
    Remove-Item -LiteralPath (Join-Path $relocated 'protocol-fixtures/queue-v1/plain-message.json')
    Expect-Failure { & $prepare @parameters -FixtureSourceRoot $relocated -OutputDirectory (Join-Path $evidence 'missing-fixture') } 'does not exist|Cannot find path'
    $tests.Add('missing required fixture refused')
    # Harmless native commands prove stderr cannot turn an exit-zero command
    # into a failure, and a nonzero exit cannot become a passing result.
    $command = '[Console]::Out.WriteLine($args[0]); [Console]::Error.WriteLine("diagnostic"); exit 0'
    $probe = Join-Path $evidence 'probe.ps1'
    Set-Content -LiteralPath $probe -Value $command
    Invoke-NativeCheck -Executable (Join-Path $PSHOME 'pwsh.exe') -Arguments @('-NoProfile', '-File', $probe, 'argument with spaces') -Name 'exit-zero' -OutputDirectory $evidence
    Assert ((Get-Content -LiteralPath (Join-Path $evidence 'exit-zero.stdout.txt') -Raw).Trim() -eq 'argument with spaces') 'Lost argument boundary.'
    Assert ((Get-Content -LiteralPath (Join-Path $evidence 'exit-zero.stderr.txt') -Raw).Contains('diagnostic')) 'Lost stderr.'
    Set-Content -LiteralPath $probe -Value '[Console]::Error.WriteLine("expected failure"); exit 23'
    Expect-Failure { Invoke-NativeCheck -Executable (Join-Path $PSHOME 'pwsh.exe') -Arguments @('-NoProfile', '-File', $probe) -Name 'exit-23' -OutputDirectory $evidence } 'exit 23'
    $failed = Get-Content -LiteralPath (Join-Path $evidence 'exit-23.result.json') -Raw | ConvertFrom-Json
    Assert ($failed.ExitCode -eq 23 -and $failed.Status -eq 'FAIL') 'Nonzero exit evidence must survive failure.'
    $tests.Add('checked command exits, separate stdout/stderr, spaced argument, retained failure evidence')
    $windowsProbe = Join-Path $evidence 'windows-powershell-contract.ps1'
    @'
param($Library, $OutputDirectory)
$ErrorActionPreference = 'Stop'
. $Library
$engine = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$probe = Join-Path $OutputDirectory 'ps51-child.ps1'
Set-Content -LiteralPath $probe -Value '[Console]::Out.WriteLine($args[0]); [Console]::Error.WriteLine("stderr"); exit 0'
Invoke-NativeCheck -Executable $engine -Arguments @('-NoProfile', '-File', $probe, 'argument with spaces') -Name 'ps51-zero' -OutputDirectory $OutputDirectory
if ((Get-Content -LiteralPath (Join-Path $OutputDirectory 'ps51-zero.stdout.txt') -Raw).Trim() -ne 'argument with spaces') { throw 'Windows PowerShell lost argument boundaries.' }
$caught = $false
Set-Content -LiteralPath $probe -Value 'exit 19'
try { Invoke-NativeCheck -Executable $engine -Arguments @('-NoProfile', '-File', $probe) -Name 'ps51-nonzero' -OutputDirectory $OutputDirectory } catch { $caught = $true }
if (-not $caught) { throw 'Windows PowerShell lost a nonzero native exit.' }
$record = Get-Content -LiteralPath (Join-Path $OutputDirectory 'ps51-nonzero.result.json') -Raw | ConvertFrom-Json
if ($record.ExitCode -ne 19 -or $record.Status -ne 'FAIL') { throw 'Missing Windows PowerShell failure evidence.' }
$tokens = $null; $errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $Library) 'Test-Native.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Guest entrypoint does not parse under Windows PowerShell.' }
exit 0
'@ | Set-Content -LiteralPath $windowsProbe
    Invoke-NativeCheck -Executable (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Arguments @('-NoProfile', '-File', $windowsProbe, '-Library', $guestLibrary, '-OutputDirectory', $evidence) -Name 'ps51-contract' -OutputDirectory $evidence
    Assert ((Get-Content -LiteralPath (Join-Path $evidence 'ps51-zero.stderr.txt') -Raw).Contains('stderr')) 'Windows PowerShell lost stderr.'
    $tests.Add('guest helper exit/stream behavior and entrypoint syntax under Windows PowerShell 5.1')
    $status = 'PASS'
} finally {
    [ordered]@{ Status = $status; Tests = @($tests); EvidenceDirectory = $evidence; GuestLaunched = $false; NativeOrServiceTestsExecuted = $false } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidence 'host-contract-results.json')
}
Write-Output "PASS: $($tests.Count) host contracts. Evidence: $evidence"
