$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch { return }
    throw "Expected failure: $Message"
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$temp = Join-Path ([IO.Path]::GetTempPath()) ('go-mapi-app-build-' + [guid]::NewGuid().ToString('N'))
$oldClient=$env:GOMAPI_OAUTH_CLIENT_ID; $oldSecret=$env:GOMAPI_OAUTH_CLIENT_SECRET
$oldMetadata=$env:GOMAPI_ADMIN_RELEASE_METADATA_URL; $oldCC=$env:CC; $oldCXX=$env:CXX
try {
    $appRoot = Join-Path $temp 'appcase'
    New-Item -ItemType Directory -Force (Join-Path $appRoot 'src/app'),(Join-Path $appRoot 'src/app/build/windows') | Out-Null
    Copy-Item (Join-Path $repo 'src/app/build.ps1') (Join-Path $appRoot 'src/app/build.ps1')
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
    $builder = Join-Path $appRoot 'src/app/build.ps1'
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
            $command = if ($entry[2] -eq 'machine') { 'just build-user-machine' } elseif ($entry[1] -eq '0.0.0-dev') { 'just build-user' } else { 'just build-user-release' }
            Assert ($m.version -eq $entry[1] -and $distribution -eq $entry[2] -and $m.artifact.filename -eq $entry[3] -and
                $m.source.commit -eq ('a' * 40) -and $m.build.command -eq $command -and $m.artifact.sha256 -eq (Get-FileHash (Join-Path $entry[0] $entry[3]) -Algorithm SHA256).Hash.ToLowerInvariant()) 'Wails pair mismatch'
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

    Write-Host 'App build output and rollback contracts passed'
} finally {
    $env:GOMAPI_OAUTH_CLIENT_ID=$oldClient; $env:GOMAPI_OAUTH_CLIENT_SECRET=$oldSecret
    $env:GOMAPI_ADMIN_RELEASE_METADATA_URL=$oldMetadata; $env:CC=$oldCC; $env:CXX=$oldCXX
    foreach($name in @('wails','go','node','npm')) { Remove-Item "function:global:$name" -ErrorAction SilentlyContinue }
    Remove-Variable -Name StubWailsMode -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
