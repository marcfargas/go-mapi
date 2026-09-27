# Focused contract checks. Real PE builds and installations run in hosted Windows CI.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch { return }
    throw "Expected failure: $Message"
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$temp = Join-Path ([IO.Path]::GetTempPath()) ('go-mapi-build-ci-' + [guid]::NewGuid().ToString('N'))
$oldClient = $env:GOMAPI_OAUTH_CLIENT_ID
$oldSecret = $env:GOMAPI_OAUTH_CLIENT_SECRET
$oldMetadata = $env:GOMAPI_ADMIN_RELEASE_METADATA_URL
$oldCC = $env:CC
$oldCXX = $env:CXX
try {
    $preparer = Join-Path $repo 'scripts/prepare-windows-build.ps1'
    $originalProfile = $env:USERPROFILE
    try {
        if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
            $env:USERPROFILE = Join-Path $temp 'missing-native-tools'
        }
        Reject { & $preparer -Native } 'missing native prerequisite'
    } finally { $env:USERPROFILE = $originalProfile }
    $appRoot = Join-Path $temp 'appcase'
    New-Item -ItemType Directory -Force (Join-Path $appRoot 'scripts'),(Join-Path $appRoot 'src/app/build/windows') | Out-Null
    Copy-Item (Join-Path $repo 'scripts/build-wails.ps1') (Join-Path $appRoot 'scripts/build-wails.ps1')
    Copy-Item (Join-Path $repo 'components.json') (Join-Path $appRoot 'components.json')
    Set-Content (Join-Path $appRoot 'src/app/VERSION') '0.0.0-dev' -NoNewline
    $env:GOMAPI_OAUTH_CLIENT_ID = 'ci-client'
    $env:GOMAPI_OAUTH_CLIENT_SECRET = 'ci-secret'
    $env:GOMAPI_ADMIN_RELEASE_METADATA_URL = 'https://example.test/admin-targets.json'
    $global:StubWailsMode = ''
    function global:wails {
        if ($args[0] -eq 'version') { $global:LASTEXITCODE = 0; return 'Wails CLI v2.12.0' }
        $dir = (Get-Location).Path
        New-Item -ItemType Directory -Force (Join-Path $dir 'build/bin'),(Join-Path $dir 'build/windows') | Out-Null
        Set-Content (Join-Path $dir 'build/appicon.png') 'generated'
        Set-Content (Join-Path $dir 'build/windows/icon.ico') 'generated'
        Set-Content (Join-Path $dir 'build/windows/wails.exe.manifest') 'generated'
        if ($global:StubWailsMode -eq 'early') { $global:LASTEXITCODE = 7; return }
        Set-Content (Join-Path $dir 'build/bin/go-mapi.exe') ((Get-Content (Join-Path $dir 'VERSION') -Raw).Trim() + [string]($args -join ' '))
        $global:LASTEXITCODE = if ($global:StubWailsMode -eq 'late') { 8 } else { 0 }
    }
    function global:go { $global:LASTEXITCODE = 0; if ($args[0] -eq 'version') { return 'go version go1.25 windows/amd64' } }
    function global:node { $global:LASTEXITCODE = 0; return 'v20.0.0' }
    function global:npm { $global:LASTEXITCODE = 0; return '10.0.0' }
    $builder = Join-Path $appRoot 'scripts/build-wails.ps1'
    $standalone = Join-Path $temp 'standalone'
    $machineA = Join-Path $temp 'machineA'
    $machineC = Join-Path $temp 'machineC'
    $scratch = Join-Path $appRoot 'src/app/build/bin/go-mapi.exe'
    New-Item -ItemType Directory -Force (Split-Path $scratch) | Out-Null
    Set-Content $scratch 'scratch-sentinel'
    $info = Join-Path $appRoot 'src/app/build/windows/info.json'
    Set-Content $info 'info-sentinel'
    $env:CC = 'old-cc'; $env:CXX = 'old-cxx'
    foreach ($round in 1..2) {
        & $builder -UseEnvironmentCredentials -SourceCommit ('a' * 40) -OutputDirectory $standalone
        Set-Content (Join-Path $appRoot 'src/app/VERSION') '5.0.1-alpha.4' -NoNewline
        & $builder -Release -MachineDistribution -UseEnvironmentCredentials -SourceCommit ('a' * 40) -OutputDirectory $machineA
        Set-Content (Join-Path $appRoot 'src/app/VERSION') '5.0.2-alpha.1' -NoNewline
        & $builder -Release -MachineDistribution -UseEnvironmentCredentials -SourceCommit ('a' * 40) -OutputDirectory $machineC
        foreach ($entry in @(@($standalone,'0.0.0-dev','standalone','go-mapi.exe'),@($machineA,'5.0.1-alpha.4','machine','go-mapi-machine.exe'),@($machineC,'5.0.2-alpha.1','machine','go-mapi-machine.exe'))) {
            $m = Get-Content (Join-Path $entry[0] 'app-artifacts.json') -Raw | ConvertFrom-Json
            $distribution = if ($m.PSObject.Properties.Name -contains 'distribution') { $m.distribution } else { 'standalone' }
            Assert ($m.version -eq $entry[1] -and $distribution -eq $entry[2] -and $m.artifact.filename -eq $entry[3] -and
                $m.source.commit -eq ('a' * 40) -and $m.artifact.sha256 -eq (Get-FileHash (Join-Path $entry[0] $entry[3]) -Algorithm SHA256).Hash.ToLowerInvariant()) 'Wails pair mismatch'
        }
        Assert ((Get-Content $scratch -Raw).Trim() -eq 'scratch-sentinel') 'default scratch output changed'
        Assert ((Get-Content $info -Raw).Trim() -eq 'info-sentinel') 'info.json changed'
        Assert ($env:CC -eq 'old-cc' -and $env:CXX -eq 'old-cxx') 'compiler environment changed'
        foreach ($path in @('build/appicon.png','build/windows/icon.ico','build/windows/wails.exe.manifest')) {
            Assert (-not (Test-Path (Join-Path $appRoot "src/app/$path"))) "generated resource leaked: $path"
        }
        Set-Content (Join-Path $appRoot 'src/app/VERSION') '0.0.0-dev' -NoNewline
    }
    $defaultOutput = Join-Path $appRoot 'src/app/build/bin'
    Remove-Item -LiteralPath $scratch -Force
    Set-Content (Join-Path $appRoot 'src/app/VERSION') '5.0.1-alpha.4' -NoNewline
    & $builder -Release -MachineDistribution -UseEnvironmentCredentials -SourceCommit ('a' * 40)
    $freshMachine = Get-Content (Join-Path $defaultOutput 'app-artifacts.json') -Raw | ConvertFrom-Json
    Assert ($freshMachine.artifact.filename -eq 'go-mapi-machine.exe' -and
        @(Get-ChildItem -LiteralPath $defaultOutput -Filter 'go-mapi*.exe' -File).Count -eq 1) 'fresh default machine build retains scratch EXE'
    Set-Content (Join-Path $appRoot 'src/app/VERSION') '0.0.0-dev' -NoNewline
    foreach ($round in 1..2) {
        & $builder -UseEnvironmentCredentials -SourceCommit ('a' * 40)
        Assert (@(Get-ChildItem -LiteralPath $defaultOutput -Filter 'go-mapi*.exe' -File).Count -eq 1) 'default dev build has extra EXE'
        Set-Content (Join-Path $appRoot 'src/app/VERSION') '5.0.1-alpha.4' -NoNewline
        & $builder -Release -MachineDistribution -UseEnvironmentCredentials -SourceCommit ('a' * 40)
        $defaultPair = Get-Content (Join-Path $defaultOutput 'app-artifacts.json') -Raw | ConvertFrom-Json
        Assert ($defaultPair.version -eq '5.0.1-alpha.4' -and $defaultPair.artifact.filename -eq 'go-mapi-machine.exe' -and
            @(Get-ChildItem -LiteralPath $defaultOutput -Filter 'go-mapi*.exe' -File).Count -eq 1) 'default machine A pair is invalid'
        Set-Content (Join-Path $appRoot 'src/app/VERSION') '5.0.2-alpha.1' -NoNewline
        & $builder -Release -MachineDistribution -UseEnvironmentCredentials -SourceCommit ('a' * 40) -OutputDirectory ($defaultOutput + [IO.Path]::DirectorySeparatorChar)
        $defaultPair = Get-Content (Join-Path $defaultOutput 'app-artifacts.json') -Raw | ConvertFrom-Json
        Assert ($defaultPair.version -eq '5.0.2-alpha.1' -and $defaultPair.artifact.filename -eq 'go-mapi-machine.exe' -and
            $defaultPair.artifact.sha256 -eq (Get-FileHash (Join-Path $defaultOutput 'go-mapi-machine.exe') -Algorithm SHA256).Hash.ToLowerInvariant() -and
            @(Get-ChildItem -LiteralPath $defaultOutput -Filter 'go-mapi*.exe' -File).Count -eq 1) 'default trailing-separator machine C pair is invalid'
        Set-Content (Join-Path $appRoot 'src/app/VERSION') '0.0.0-dev' -NoNewline
    }
    $defaultBefore = Get-Content (Join-Path $defaultOutput 'app-artifacts.json') -Raw
    $global:StubWailsMode = 'late'
    Reject { & $builder -UseEnvironmentCredentials -SourceCommit ('a' * 40) } 'default Wails rollback'
    Assert ((Get-Content (Join-Path $defaultOutput 'app-artifacts.json') -Raw) -eq $defaultBefore -and
        -not (Test-Path -LiteralPath $scratch)) 'default machine pair lost on failed build'
    $global:StubWailsMode = ''
    Remove-Item -LiteralPath (Join-Path $defaultOutput 'go-mapi-machine.exe'),(Join-Path $defaultOutput 'app-artifacts.json') -Force
    Set-Content $scratch 'scratch-sentinel'
    $sentinel = Join-Path $temp 'unowned'
    New-Item -ItemType Directory -Force $sentinel | Out-Null
    Set-Content (Join-Path $sentinel 'go-mapi.exe') 'do-not-touch'
    Reject { & $builder -UseEnvironmentCredentials -SourceCommit ('a' * 40) -OutputDirectory $sentinel } 'unowned output'
    Assert ((Get-Content (Join-Path $sentinel 'go-mapi.exe') -Raw).Trim() -eq 'do-not-touch') 'unowned output changed'
    foreach ($mode in @('early','late')) {
        $global:StubWailsMode = $mode
        $before = (Get-Content (Join-Path $standalone 'app-artifacts.json') -Raw)
        $beforeExe = (Get-FileHash (Join-Path $standalone 'go-mapi.exe') -Algorithm SHA256).Hash
        Reject { & $builder -UseEnvironmentCredentials -SourceCommit ('a' * 40) -OutputDirectory $standalone } "$mode Wails failure"
        Assert ((Get-Content (Join-Path $standalone 'app-artifacts.json') -Raw) -eq $before) 'old output lost on failure'
        Assert ((Get-FileHash (Join-Path $standalone 'go-mapi.exe') -Algorithm SHA256).Hash -eq $beforeExe) 'old executable lost on failure'
        Assert ((Get-Content $scratch -Raw).Trim() -eq 'scratch-sentinel') 'scratch lost on failure'
        Assert ((Get-Content $info -Raw).Trim() -eq 'info-sentinel') 'info lost on failure'
    }
    $global:StubWailsMode = ''
    Set-Content (Join-Path $appRoot 'src/app/build/appicon.png') 'resource-sentinel'
    Reject { & $builder -Release -UseEnvironmentCredentials -SourceCommit ('a' * 40) -OutputDirectory $machineA } 'release resource sentinel'
    Assert ((Get-Content (Join-Path $appRoot 'src/app/build/appicon.png') -Raw).Trim() -eq 'resource-sentinel') 'resource sentinel changed'
    Assert ((Get-Content (Join-Path $appRoot 'src/app/VERSION') -Raw).Trim() -eq '0.0.0-dev') 'temporary VERSION not restored'
    Remove-Item (Join-Path $appRoot 'src/app/build/appicon.png') -Force

    $nativeRoot = Join-Path $temp 'nativecase'
    $nativeDir = Join-Path $nativeRoot 'src/interceptor'
    New-Item -ItemType Directory -Force $nativeDir | Out-Null
    Copy-Item (Join-Path $repo 'components.json') (Join-Path $nativeRoot 'components.json')
    $nativeSource = Get-Content (Join-Path $repo 'src/interceptor/build.ps1') -Raw
    $start = $nativeSource.IndexOf('# Find the mingw-mstorsjo-llvm-ucrt toolchain')
    $end = $nativeSource.IndexOf('# Clean build directory', $start)
    Assert ($start -ge 0 -and $end -gt $start) 'native entrypoint setup seam changed'
    $nativeStandins = @'
$cmakePath = 'cmake'
$ninjaPath = 'ninja'
$gccPath = 'clang'
$gxxPath = 'clang++'
$rcPathForCMake = 'windres'
'@
    $nativeBuilder = Join-Path $nativeDir 'build.ps1'
    [IO.File]::WriteAllText($nativeBuilder, $nativeSource.Substring(0,$start) + $nativeStandins + [Environment]::NewLine + $nativeSource.Substring($end))
    function global:cmake { $global:LASTEXITCODE = 0 }
    function global:ctest {
        Add-Content $env:FAKE_CTEST_LOG ($args -join ' ')
        $global:LASTEXITCODE = [int]$env:FAKE_CTEST_EXIT
    }
    $env:FAKE_CTEST_LOG = Join-Path $nativeRoot 'ctest.log'
    foreach ($code in @(0,7,8)) {
        $env:FAKE_CTEST_EXIT = [string]$code
        Remove-Item -LiteralPath $env:FAKE_CTEST_LOG -Force -ErrorAction SilentlyContinue
        if ($code -eq 0) { & $nativeBuilder -Config Release -RunTests }
        else { Reject { & $nativeBuilder -Config Release -RunTests } "CTest exit $code" }
        $calls = @(Get-Content $env:FAKE_CTEST_LOG)
        Assert ($calls.Count -eq 1 -and $calls[0] -match '--output-on-failure' -and
            $calls[0] -match '--build-config Release' -and $calls[0] -match '--no-tests=error') "CTest invocation mismatch for exit $code"
    }

    $input = Join-Path $temp 'inputs'
    New-Item -ItemType Directory -Force $input | Out-Null
    foreach ($name in @('go-mapi-service.exe','go-mapi-x86.dll','go-mapi-x64.dll','go-mapi-machine.exe')) { Set-Content (Join-Path $input $name) $name }
    $unsigned = (Get-FileHash (Join-Path $input 'go-mapi-machine.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    $appBuild = [ordered]@{ schema='go-mapi-app-artifacts-v2'; component='app'; version='5.0.1-alpha.4'; distribution='machine'; source=@{ commit=('a' * 40) }; artifact=@{ filename='go-mapi-machine.exe'; peProductVersion='5.0.1-alpha.4'; sha256=$unsigned } }
    $buildPath = Join-Path $input 'app-artifacts.json'
    [IO.File]::WriteAllText($buildPath, ($appBuild | ConvertTo-Json -Depth 5))
    $writer = Join-Path $repo 'scripts/write-machine-signed-input.ps1'
    $out = Join-Path $input 'signed-input.json'
    $common = @{ SKU='suite'; PackageRelease='5.0.1-alpha.4'; SourceCommit=('a' * 40); InputDirectory=$input; ServiceVersion='5.0.1-alpha.4'; InterceptorVersion='5.0.1-alpha.4'; AppVersion='5.0.1-alpha.4'; AppBuildManifest=$buildPath; UnsignedAppSha256=$unsigned; OutputPath=$out }
    & $writer @common
    $signed = Get-Content $out -Raw | ConvertFrom-Json
    Assert ($signed.schema -eq 'go-mapi-machine-signed-input-v1' -and @($signed.components).Count -eq 3 -and $signed.appBuild.unsignedSha256 -eq $unsigned) 'signed input inventory mismatch'
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

    $hostRoot = Join-Path $temp 'hostcase'
    New-Item -ItemType Directory -Force (Join-Path $hostRoot 'scripts'),(Join-Path $hostRoot 'src/installer/msi/tests') | Out-Null
    Copy-Item (Join-Path $repo 'scripts/run-hosted-machine-integration.ps1') (Join-Path $hostRoot 'scripts/run-hosted-machine-integration.ps1')
    @'
param($SystemMsi,$SuiteMsi,$NewerSuiteMsi,$LogDirectory)
if ($env:FAKE_CROSS_FAIL -eq '1') { throw 'stub cross-SKU failure' }
New-Item -ItemType Directory -Force $LogDirectory | Out-Null
Set-Content (Join-Path $LogDirectory 'lifecycle.log') 'ok'
& pwsh -NoProfile -Command 'exit 7'
'@ | Set-Content (Join-Path $hostRoot 'src/installer/msi/tests/CrossSkuLifecycle.Tests.ps1')
    @'
param($PackageManifest,$EvidenceDirectory,$SKU,$Phase,$FixturePort,$DeadlineMinutes,$DeferredInterruptionEvidence)
$name = Split-Path $EvidenceDirectory -Leaf
Add-Content $env:FAKE_PHASE_LOG "$name/$Phase"
if ($env:FAKE_PHASE_FAIL -eq "$name/$Phase") { throw 'stub phase failure' }
New-Item -ItemType Directory -Force $EvidenceDirectory | Out-Null
if ($env:FAKE_PHASE_DROP -ne "$name/$Phase") {
  @{ schema='go-mapi-machine-update-integration-v1'; phase=$Phase; passed=$true; cleanupError=$null; packageManifest=[IO.Path]::GetFullPath($PackageManifest) } |
    ConvertTo-Json | Set-Content (Join-Path $EvidenceDirectory "machine-update-$($Phase.ToLowerInvariant()).json")
}
& pwsh -NoProfile -Command 'exit 7'
'@ | Set-Content (Join-Path $hostRoot 'scripts/run-machine-update-integration.ps1')
    $msis = Join-Path $hostRoot 'msis'; New-Item -ItemType Directory -Force $msis | Out-Null
    $packages = @{}
    foreach ($name in @('systemA','systemB','systemC','suiteA','suiteB','suiteC')) {
        $path = Join-Path $msis "$name.msi"; Set-Content $path $name
        $packages[$name] = @{ msi=$path; sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $fixturePath = Join-Path $hostRoot 'fixture.json'
    @{ schema='go-mapi-machine-test-packages-v1'; fixture=@{ metadataOrigin='https://localhost:18453'; artifactOrigin='https://localhost:18453/releases/download/' }; packages=$packages } |
        ConvertTo-Json -Depth 5 | Set-Content $fixturePath
    $runner = Join-Path $hostRoot 'scripts/run-hosted-machine-integration.ps1'
    $evidence = Join-Path $hostRoot 'evidence'
    $env:FAKE_PHASE_LOG = Join-Path $hostRoot 'phases.log'
    & $runner -PackageManifest $fixturePath -EvidenceDirectory $evidence
    $events = @(Get-Content $env:FAKE_PHASE_LOG)
    Assert (($events[0..3] -join ',') -eq 'update/Hosted,suite-update/Hosted,suite-update/Cleanup,update-interruption/InterruptSameBoot') 'hosted sequence changed'
    Assert (($events[-3..-1] -join ',') -eq 'suite-update/Cleanup,update/Cleanup,update-interruption/Cleanup') 'cleanup order changed'
    $env:FAKE_CROSS_FAIL = '1'
    try { & $runner -PackageManifest $fixturePath -EvidenceDirectory $evidence; throw 'Expected cross-SKU failure' }
    catch { Assert ($_.Exception.Message -match 'Cross-SKU lifecycle failed with exit code' -and
        -not (Test-Path (Join-Path $evidence 'cross-sku/lifecycle.log'))) 'cross-SKU failure or stale log went unnoticed' }
    $env:FAKE_CROSS_FAIL = ''
    Clear-Content $env:FAKE_PHASE_LOG
    $env:FAKE_PHASE_DROP = 'update/Hosted'; $env:FAKE_PHASE_FAIL = 'suite-update/Cleanup'
    try { & $runner -PackageManifest $fixturePath -EvidenceDirectory $evidence; throw 'Expected hosted failure' }
    catch { Assert ($_.Exception.Message -match 'Missing phase result' -and $_.Exception.Message -match 'suite-update') 'primary and cleanup failure not aggregated' }
    $env:FAKE_PHASE_DROP = ''; $env:FAKE_PHASE_FAIL = ''
    Set-Content (Join-Path $evidence 'update-interruption/cleanup-deferred.json') '{}'
    Clear-Content $env:FAKE_PHASE_LOG
    & $runner -PackageManifest $fixturePath -EvidenceDirectory $evidence -CleanupOnly
    Assert ((@((Get-Content $env:FAKE_PHASE_LOG)) -join ',') -eq 'update/Cleanup,update-interruption/Cleanup') 'deferred cleanup routing changed'
    Write-Host 'BuildCi contracts passed'
} finally {
    $env:GOMAPI_OAUTH_CLIENT_ID = $oldClient
    $env:GOMAPI_OAUTH_CLIENT_SECRET = $oldSecret
    $env:GOMAPI_ADMIN_RELEASE_METADATA_URL = $oldMetadata
    $env:CC = $oldCC; $env:CXX = $oldCXX
    foreach ($name in @('StubWailsMode','FAKE_PHASE_LOG','FAKE_PHASE_FAIL','FAKE_PHASE_DROP','FAKE_CROSS_FAIL','FAKE_CTEST_LOG','FAKE_CTEST_EXIT')) { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
    foreach ($name in @('wails','go','node','npm','cmake','ctest')) { Remove-Item "function:global:$name" -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
