#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName='Full')]
param(
    [Parameter(Mandatory)][string]$X64Dll,
    [Parameter(Mandatory)][string]$X64Harness,
    [Parameter(Mandatory)][string]$X86Dll,
    [Parameter(Mandatory)][string]$X86Harness,
    [Parameter(Mandatory)][string]$InterceptorVersion,
    [Parameter(Mandatory)][string]$AppVersion,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [Parameter(Mandatory, ParameterSetName='Full')][string]$Manifest,
    [Parameter(Mandatory, ParameterSetName='Full')][string]$SuiteMsi,
    [Parameter(Mandatory, ParameterSetName='Component')][switch]$ComponentOnly,
    [string]$AppProbeBinary,
    [Parameter(ParameterSetName='Full')][string]$FakeBinary,
    [ValidateRange(300,1800)][int]$TimeoutSeconds = 1200
)
$ErrorActionPreference = 'Stop'
$componentArgs = @{
    X64Dll=$X64Dll;X64Harness=$X64Harness;X86Dll=$X86Dll;X86Harness=$X86Harness
    InterceptorVersion=$InterceptorVersion;AppVersion=$AppVersion;EvidenceDirectory=$EvidenceDirectory
}
if ($ComponentOnly) {
    if ($env:GOMAPI_SANDBOX -ne '1' -and !($env:GITHUB_ACTIONS -eq 'true' -and !$env:ACT)) {
        throw 'Component-only execution changes Windows state. Run it in an owned disposable guest.'
    }
    if ($AppProbeBinary) { $componentArgs.AppProbeBinary=$AppProbeBinary }
    & (Join-Path $PSScriptRoot 'component-integration.ps1') @componentArgs
    exit 0
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$attachment = Join-Path $repo 'tests/installed-attachment'
Import-Module (Join-Path $attachment 'Attachment.psm1') -Force
$Manifest = (Resolve-Path -LiteralPath $Manifest).Path
$SuiteMsi = (Resolve-Path -LiteralPath $SuiteMsi).Path
if ($AppProbeBinary) { $AppProbeBinary = (Resolve-Path -LiteralPath $AppProbeBinary).Path }
if ($FakeBinary) { $FakeBinary = (Resolve-Path -LiteralPath $FakeBinary).Path }
$selection = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if ($selection.schema -ceq 'go-mapi-release-v1') {
    $release = $selection
    $dll = @($release.system.components | Where-Object component -ceq 'interceptor' | ForEach-Object artifacts | Where-Object architecture -ceq 'x64')
    if ($release.repository -cne 'marcfargas/go-mapi' -or $dll.Count -ne 1) { throw 'Select an unambiguous go-mapi public release manifest' }
    $selection = [pscustomobject]@{
        schema='go-mapi-machine-test-packages-v1';sourceCommit=$release.commit
        packages=@{suiteC=@{sha256=$release.suite.artifact.sha256;appSha256=$release.suite.app.sha256;x64DllSha256=$dll[0].sha256;msi='C:\input\suite.msi'}}
    }
}
if ($selection.schema -cne 'go-mapi-machine-test-packages-v1' -or !$selection.packages.suiteC.appSha256 -or !$selection.packages.suiteC.x64DllSha256 -or (Get-FileHash -LiteralPath $SuiteMsi -Algorithm SHA256).Hash.ToLowerInvariant() -cne $selection.packages.suiteC.sha256) { throw 'Select the exact Suite MSI and complete suiteC manifest' }
$run = Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) ('e2e-' + [guid]::NewGuid().ToString('N'))
$inputs = Join-Path $run 'input'
New-Item -ItemType Directory -Path $inputs -Force | Out-Null
foreach ($name in @('Test-ExplorerGuest.ps1','Test-Attachment.ps1','Invoke-Attachment.ps1','Attachment.psm1','AttachmentNative.cs','ExplorerSendTo.ps1')) {
    Copy-Item -LiteralPath (Join-Path $attachment $name) -Destination $inputs
}
foreach ($name in @('e2e-guest.ps1','component-integration.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $inputs }
foreach ($file in @(
    @{source=$SuiteMsi;name='suite.msi'},@{source=$X64Dll;name='x64.dll'},@{source=$X86Dll;name='x86.dll'},
    @{source=$X64Harness;name='x64-harness.exe'},@{source=$X86Harness;name='x86-harness.exe'}
)) { Copy-Item -LiteralPath $file.source -Destination (Join-Path $inputs $file.name) }
Write-AttachmentJson (Join-Path $inputs 'machine-test-packages.json') $selection
Write-AttachmentJson (Join-Path $inputs 'versions.json') @{interceptor=$InterceptorVersion;app=$AppVersion}
Copy-Item -LiteralPath $Manifest -Destination (Join-Path $run 'selected-manifest.json')
$head = & git -C $repo rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot record e2e source revision' }
$dirty = @(& git -C $repo status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0) { throw 'Cannot record e2e source status' }
& git -C $repo diff --binary HEAD -- src/app internal tests Justfile | Set-Content (Join-Path $run 'source.patch')
if ($LASTEXITCODE -ne 0) { throw 'Cannot retain e2e source patch' }
Write-AttachmentJson (Join-Path $run 'source.json') @{
    head=$head;dirty=$dirty;go=(& go version);powershell=$PSVersionTable.PSVersion.ToString()
    appProbe=$(if ($AppProbeBinary) {'supplied binary'} else {'built from checkout'})
    fake=$(if ($FakeBinary) {'supplied binary'} else {'built from checkout'})
}
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $run 'e2e.ps1')
Push-Location $repo
try {
    if ($AppProbeBinary) { Copy-Item -LiteralPath $AppProbeBinary -Destination (Join-Path $inputs 'app-probe.exe') }
    else {
        & just build-frontend
        if ($LASTEXITCODE -ne 0) { throw 'Frontend build failed' }
        & go test -c -o (Join-Path $inputs 'app-probe.exe') ./src/app
        if ($LASTEXITCODE -ne 0) { throw 'App queue probe compilation failed' }
    }
    if ($FakeBinary) { Copy-Item -LiteralPath $FakeBinary -Destination (Join-Path $inputs 'fake-gmail.exe') }
    else {
        $savedGoWork = $env:GOWORK
        try {
            $env:GOWORK = 'off'
            & go build -C tests/installed-attachment/fake-gmail -o (Join-Path $inputs 'fake-gmail.exe')
            if ($LASTEXITCODE -ne 0) { throw 'Gmail fixture compilation failed' }
        } finally { $env:GOWORK = $savedGoWork }
    }
} finally { Pop-Location }
Write-Host ('Windows e2e evidence: ' + $run)
# Existing lifecycle owner provides selected-input hashing, deadlines, exclusion
# and exact guest disposal. Only compilation and staging execute on the host.
& (Join-Path $PSScriptRoot 'run.ps1') -InputDirectory $inputs -ScriptPath e2e-guest.ps1 -RunAs ExistingLogin -Connect -TimeoutSeconds $TimeoutSeconds -EvidenceRoot $run
