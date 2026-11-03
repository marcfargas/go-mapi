# Exercise the actual Just process boundary with inert component implementations.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('gomapi-entrypoints-' + [guid]::NewGuid().ToString('N'))
$marker = $env:GOMAPI_SANDBOX
function FailureExit([scriptblock]$Action) {
    # Windows PowerShell turns redirected native stderr into error records.
    $ErrorActionPreference='Continue'
    & $Action *> $null
    return $LASTEXITCODE
}
try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'distribution/signing'),(Join-Path $fixture 'src/app') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'Justfile') -Destination $fixture
    $signing = @'
param([string]$Mode,[string]$StatePath,[string[]]$SignedFiles)
@{mode=$Mode;state=$StatePath;files=@($SignedFiles)} | ConvertTo-Json -Compress
'@
    $registration = @'
param([string]$ExePath,[switch]$Force)
@{path=$ExePath;force=[bool]$Force} | ConvertTo-Json -Compress
'@
    Set-Content -LiteralPath (Join-Path $fixture 'distribution/signing/azure-test-trust.ps1') -Value $signing
    Set-Content -LiteralPath (Join-Path $fixture 'src/app/register-dev-aumid.ps1') -Value $registration
    # This marker reaches only the inert temporary implementations above.
    $env:GOMAPI_SANDBOX = '1'
    $justfile = Join-Path $fixture 'Justfile'
    $raw = & just --justfile $justfile azure-test-trust Prepare 'state path.json' 'first image.exe' 'second image.dll'
    if ($LASTEXITCODE -ne 0) { throw 'Signing entrypoint failed' }
    $result = $raw | ConvertFrom-Json
    if ($result.mode -cne 'Prepare' -or $result.state -cne 'state path.json' -or ($result.files -join '|') -cne 'first image.exe|second image.dll') { throw 'Signing entrypoint lost array boundaries' }
    $raw = & just --justfile $justfile azure-test-trust Cleanup 'state path.json'
    if ($LASTEXITCODE -ne 0 -or @(($raw | ConvertFrom-Json).files | Where-Object { $null -ne $_ }).Count) { throw 'Cleanup requires no signed files' }
    $raw = & just --justfile $justfile register-dev-aumid -ExePath 'app path.exe' -Force
    if ($LASTEXITCODE -ne 0) { throw 'Registration entrypoint failed' }
    $result = $raw | ConvertFrom-Json
    if ($result.path -cne 'app path.exe' -or !$result.force) { throw 'Registration entrypoint lost overrides' }
    Add-Content -LiteralPath (Join-Path $fixture 'distribution/signing/azure-test-trust.ps1') -Value "throw 'inert failure'"
    $code=FailureExit { & just --justfile $justfile azure-test-trust Prepare 'state path.json' 'image.exe' }
    if ($code -eq 0) { throw 'Signing entrypoint swallowed component failure' }
    $oldActions = $env:GITHUB_ACTIONS; $oldAct = $env:ACT
    try {
        $env:GOMAPI_SANDBOX = $null; $env:GITHUB_ACTIONS = 'true'; $env:ACT = 'true'
        $code=FailureExit { & just --justfile $justfile test-system x64 Release }
        if ($code -eq 0) { throw 'Machine-changing command accepted a local act runner' }
    } finally { $env:GITHUB_ACTIONS = $oldActions; $env:ACT = $oldAct }
    # Exercise the real workflow wrapper without launching act or build tools.
    $oldPath=$env:PATH
    try {
        $bin=Join-Path $fixture 'fake tools'; New-Item -ItemType Directory -Path $bin | Out-Null
        @'
ConvertTo-Json -InputObject @($args) | Set-Content -LiteralPath $env:FAKE_ACT_LOG
exit ([int]$env:FAKE_ACT_EXIT)
'@ | Set-Content -LiteralPath (Join-Path $bin 'act.ps1')
        $env:PATH=$bin+[IO.Path]::PathSeparator+$env:PATH
        $env:FAKE_ACT_LOG=Join-Path $fixture 'act-arguments.json'; $env:FAKE_ACT_EXIT='0'
        & just --justfile $justfile ci-plan app-packages
        if ($LASTEXITCODE -ne 0) { throw 'Package job planning failed' }
        $arguments=Get-Content $env:FAKE_ACT_LOG -Raw | ConvertFrom-Json
        if (($arguments -join '|') -cne '-P|windows-latest=-self-hosted|-W|.github/workflows/ci.yml|-j|app-packages|--matrix|role:standalone|--list') { throw 'Workflow mapping, selection or planning changed' }
        & just --justfile $justfile package-user
        if ($LASTEXITCODE -ne 0) { throw 'Package workflow wrapper failed' }
        $arguments=Get-Content $env:FAKE_ACT_LOG -Raw | ConvertFrom-Json
        if ($arguments[-2] -ne '--artifact-server-path' -or -not $arguments[-1].StartsWith((Join-Path $fixture 'release/act'))) { throw 'Package artifacts would not survive the act workspace' }
        $env:FAKE_ACT_EXIT='23'
        $code=FailureExit { & just --justfile $justfile ci }
        if ($code -ne 23) { throw 'Workflow wrapper swallowed act failure' }
        Remove-Item -LiteralPath $env:FAKE_ACT_LOG
        $code=FailureExit { & just --justfile $justfile ci run admin-msi-scenario }
        if ($code -eq 0 -or (Test-Path $env:FAKE_ACT_LOG)) { throw 'Workflow wrapper accepted a machine-changing job' }
    } finally {
        $env:PATH=$oldPath
        Remove-Item env:FAKE_ACT_LOG,env:FAKE_ACT_EXIT -ErrorAction SilentlyContinue
    }
    # Exercise the workflow's version-resolution step in a disposable source
    # layout. Ordinary packaging must not become an upgrade-fixture build.
    $workflow=Get-Content (Join-Path $repo '.github/workflows/ci.yml') -Raw
    $step=[regex]::Match($workflow,'(?ms)^      - name: Resolve the selected app version\r?\n.*?^        run: \|\r?\n(?<script>(?:          [^\r\n]*\r?\n)+)')
    if (-not $step.Success) { throw 'Missing app-version resolution step' }
    foreach ($selection in @(@('standalone','source'),@('appA','baseline'),@('appC','appUpgrade'))) {
        if ($workflow -notmatch "role: $($selection[0])\r?\n\s+version: $($selection[1])") { throw "Wrong version authority for $($selection[0])" }
    }
    $resolveVersion=[scriptblock]::Create([regex]::Replace($step.Groups['script'].Value,'(?m)^          ',''))
    New-Item -ItemType Directory -Path (Join-Path $fixture 'src/interceptor'),(Join-Path $fixture 'src/installer/msi/tests/fixtures') -Force | Out-Null
    $specPath=Join-Path $fixture 'src/installer/msi/tests/fixtures/machine.json'
    $spec=Get-Content (Join-Path $repo 'src/installer/msi/tests/fixtures/machine.json') -Raw | ConvertFrom-Json
    $appPath=Join-Path $fixture 'src/app/VERSION'; $interceptorPath=Join-Path $fixture 'src/interceptor/interceptor-version.txt'
    $sourceApp="3.2.0-alpha.10`r`n"; $sourceInterceptor="3.2.0-alpha.9`r`n"
    $oldRole=$env:APP_VERSION_ROLE; $oldOutput=$env:GITHUB_OUTPUT
    Push-Location $fixture
    try {
        foreach ($role in @('source','baseline','appUpgrade')) {
            [IO.File]::WriteAllText($appPath,$sourceApp,[Text.Encoding]::ASCII)
            [IO.File]::WriteAllText($interceptorPath,$sourceInterceptor,[Text.Encoding]::ASCII)
            if ($role -eq 'source') { Remove-Item -LiteralPath $specPath -ErrorAction SilentlyContinue }
            else { $spec | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $specPath }
            $env:APP_VERSION_ROLE=$role; $env:GITHUB_OUTPUT=Join-Path $fixture "version-$role.txt"
            & $resolveVersion
            $expected=if ($role -eq 'source') { $sourceApp.Trim() } else { [string]$spec.versions.$role }
            if ((Get-Content $env:GITHUB_OUTPUT -Raw).Trim() -cne "version=$expected") { throw "Wrong packaging version for $role" }
            if ($role -eq 'source') {
                if ([IO.File]::ReadAllText($appPath) -cne $sourceApp -or [IO.File]::ReadAllText($interceptorPath) -cne $sourceInterceptor) { throw 'Ordinary packaging rewrote canonical versions' }
            } elseif ([IO.File]::ReadAllText($appPath) -cne $expected -or [IO.File]::ReadAllText($interceptorPath) -cne $spec.versions.baseline) { throw "Upgrade fixture binding changed: $role" }
        }
    } finally {
        Pop-Location
        $env:APP_VERSION_ROLE=$oldRole; $env:GITHUB_OUTPUT=$oldOutput
    }
    # Exercise the real MSIX render step: adjacent prereleases must upgrade,
    # and the Store-reserved fourth version component remains zero.
    $action=Get-Content (Join-Path $repo '.github/actions/package-user/action.yml') -Raw
    $render=[regex]::Match($action,'(?ms)^    - name: Render the MSIX identity manifest\r?\n.*?^      run: \|\r?\n(?<script>(?:        [^\r\n]*\r?\n)+)')
    if (-not $render.Success) { throw 'Missing MSIX render step' }
    $renderManifest=[scriptblock]::Create([regex]::Replace($render.Groups['script'].Value,'(?m)^        ',''))
    $savedPackageEnvironment=@{}
    foreach ($name in @('PACKAGE_STAGE','PACKAGE_VERSION','PACKAGE_IDENTITY','PACKAGE_PUBLISHER','PACKAGE_DISPLAY')) { $savedPackageEnvironment[$name]=[Environment]::GetEnvironmentVariable($name) }
    try {
        $env:PACKAGE_STAGE=Join-Path $fixture 'msix-stage'; New-Item -ItemType Directory $env:PACKAGE_STAGE | Out-Null
        $env:PACKAGE_IDENTITY='test.identity'; $env:PACKAGE_PUBLISHER='CN=Test & Example'; $env:PACKAGE_DISPLAY='Test'
        foreach ($case in @(@('3.2.0-alpha.11','3.2.111.0'),@('3.2.0-alpha.12','3.2.112.0'),@('3.2.0-beta.1','3.2.201.0'),@('4.2.0','4.2.0.0'))) {
            $env:PACKAGE_VERSION=$case[0]
            & $renderManifest
            $manifest=[xml](Get-Content (Join-Path $env:PACKAGE_STAGE 'AppxManifest.xml') -Raw)
            if ($manifest.Package.Identity.Version -cne $case[1] -or $manifest.Package.Identity.Publisher -cne $env:PACKAGE_PUBLISHER) { throw "MSIX identity mapping failed: $($case[0])" }
        }
    } finally {
        foreach ($entry in $savedPackageEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key,$entry.Value) }
    }
    'Just argument, failure and MSIX version contracts passed'
} finally {
    $env:GOMAPI_SANDBOX = $marker
    if ([IO.Path]::GetFullPath($fixture).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
