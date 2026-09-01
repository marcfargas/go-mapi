# Runs the component-boundary MAPISendMail integration proof.  It is a
# test-only activation path: each native harness explicitly LoadLibrarys its
# supplied DLL, so this script neither packages nor registers a product
# interceptor.  Run it in a managed interactive Windows desktop session.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$X64Dll,
    [Parameter(Mandatory)][string]$X64Harness,
    [Parameter(Mandatory)][string]$X86Dll,
    [Parameter(Mandatory)][string]$X86Harness,
    [Parameter(Mandatory)][string]$InterceptorVersion,
    [Parameter(Mandatory)][string]$AppVersion,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [string]$QueueDirectory = (Join-Path $env:LOCALAPPDATA 'go-mapi\queue')
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runId = [guid]::NewGuid().ToString('N')
$startedAt = [DateTime]::UtcNow.ToString('o')
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$logPath = Join-Path $evidence 'component-integration.log'

# Desktop launch is intentionally asynchronous and does not relay stderr to
# the caller. Preserve a terminating failure beside the normal evidence log
# while still rethrowing so an incomplete run can never look successful.
trap {
    Add-Content -LiteralPath $logPath -Value ("[{0}] FAIL {1}" -f [DateTime]::UtcNow.ToString('o'), ($_ | Out-String).Trim())
    throw
}

function Fail([string]$Message) { throw "Component integration failed: $Message" }
function Log([string]$Message) {
    $line = "[{0}] {1}" -f [DateTime]::UtcNow.ToString('o'), $Message
    Add-Content -LiteralPath $logPath -Value $line
    Write-Host $line
}
function Get-PeMachine([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { Fail "$Path is not an MZ executable" }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { Fail "$Path has no PE signature" }
        switch ($reader.ReadUInt16()) { 0x014c { return 'x86' }; 0x8664 { return 'x64' }; default { Fail "$Path has unsupported PE machine" } }
    } finally { $stream.Dispose() }
}
function Get-FileRecord([string]$Path, [string]$ExpectedMachine) {
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { Fail "missing input $resolved" }
    $machine = Get-PeMachine $resolved
    if ($machine -ne $ExpectedMachine) { Fail "$resolved machine $machine, expected $ExpectedMachine" }
    return [ordered]@{ path = $resolved; sha256 = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant(); peMachine = $machine }
}
function Get-QueuePaths {
    if (-not (Test-Path -LiteralPath $QueueDirectory)) { return @() }
    return @(Get-ChildItem -LiteralPath $QueueDirectory -Filter '*.json' -File | ForEach-Object { $_.FullName })
}

if ([string]::IsNullOrWhiteSpace($InterceptorVersion) -or $InterceptorVersion -eq '0.0.0-dev') { Fail 'InterceptorVersion must be an explicit non-development version' }
if ([string]::IsNullOrWhiteSpace($AppVersion) -or $AppVersion -eq '0.0.0-dev') { Fail 'AppVersion must be an explicit non-development version' }
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'src\app\go.mod'))) { Fail 'must run from a go-mapi worktree containing src/app' }

$inputs = [ordered]@{
    x64Dll = Get-FileRecord $X64Dll 'x64'; x64Harness = Get-FileRecord $X64Harness 'x64'
    x86Dll = Get-FileRecord $X86Dll 'x86'; x86Harness = Get-FileRecord $X86Harness 'x86'
    interceptorVersion = $InterceptorVersion; appVersion = $AppVersion
}
$results = @()
Log "run=$runId activation=test-harness-explicit-load queue=$QueueDirectory"

foreach ($case in @(
    [ordered]@{ architecture = 'x64'; dll = $inputs.x64Dll; harness = $inputs.x64Harness },
    [ordered]@{ architecture = 'x86'; dll = $inputs.x86Dll; harness = $inputs.x86Harness }
)) {
    $before = @(Get-QueuePaths)
    $env:GO_MAPI_TEST_RETAIN_OUTPUT = '1'
    $harnessLogPath = Join-Path $evidence "$($case.architecture)-harness.log"
    # Redirect native stderr to a file.  Piping 2>&1 under Stop turns an
    # expected native stderr line into a PowerShell NativeCommandError before
    # $LASTEXITCODE can be assessed.
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $case.harness.path $case.dll.path *> $harnessLogPath
    $ErrorActionPreference = $savedErrorActionPreference
    $harnessExitCode = $LASTEXITCODE
    Remove-Item Env:GO_MAPI_TEST_RETAIN_OUTPUT -ErrorAction SilentlyContinue
    if ($harnessExitCode -ne 0) { Fail "$($case.architecture) MAPISendMail harness failed ($harnessExitCode)" }
    $newPaths = @(Get-QueuePaths | Where-Object { $_ -notin $before })
    if ($newPaths.Count -eq 0) { Fail "$($case.architecture) MAPISendMail harness emitted no queue descriptor" }

    $descriptor = $newPaths[0]
    $ackPath = Join-Path $evidence "$($case.architecture)-app-ack.json"
    $env:GO_MAPI_INTEGRATION_QUEUE = $QueueDirectory
    $env:GO_MAPI_INTEGRATION_DESCRIPTOR = $descriptor
    $env:GO_MAPI_INTEGRATION_ACK_PATH = $ackPath
    Push-Location $repoRoot
    try { $probeOutput = & go test ./src/app -run '^TestIntegrationQueueConsumerProbe$' -count=1 2>&1 | Out-String; $probeExitCode = $LASTEXITCODE }
    finally { Pop-Location; Remove-Item Env:GO_MAPI_INTEGRATION_QUEUE,Env:GO_MAPI_INTEGRATION_DESCRIPTOR,Env:GO_MAPI_INTEGRATION_ACK_PATH -ErrorAction SilentlyContinue }
    Set-Content -LiteralPath (Join-Path $evidence "$($case.architecture)-app-probe.log") -Value $probeOutput
    if ($probeExitCode -ne 0 -or -not (Test-Path -LiteralPath $ackPath)) { Fail "$($case.architecture) Wails queue-consumer acknowledgement missing" }
    $ack = Get-Content -LiteralPath $ackPath -Raw | ConvertFrom-Json
    $descriptorHash = (Get-FileHash -LiteralPath $descriptor -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ack.descriptorSha256 -ne $descriptorHash) { Fail "$($case.architecture) app acknowledgement does not match native descriptor" }
    $results += [ordered]@{ architecture = $case.architecture; activation = 'explicit test-harness LoadLibrary (no product registration)'; harnessExitCode = $harnessExitCode; descriptorPath = $descriptor; descriptorSha256 = $descriptorHash; appAcknowledgement = $ack }
    Log "$($case.architecture) MAPISendMail caller and app consumer passed"
}

$manifest = [ordered]@{
    schema = 'go-mapi-component-integration-v1'; runId = $runId; startedAtUtc = $startedAt; finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    host = [ordered]@{ computerName = $env:COMPUTERNAME; os = [Environment]::OSVersion.VersionString; user = [Environment]::UserName }
    queueDirectory = $QueueDirectory; components = $inputs; results = $results
}
[IO.File]::WriteAllText((Join-Path $evidence 'component-integration.json'), ($manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Log "PASS run=$runId evidence=$evidence"
