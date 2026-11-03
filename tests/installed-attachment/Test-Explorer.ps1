#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Manifest,
    [Parameter(Mandatory)][string]$SuiteMsi,
    [Parameter(Mandatory)][string]$FakeBinary,
    [string]$EvidenceRoot = (Join-Path $env:LOCALAPPDATA 'agent-work/retained/go-mapi/issue-9'),
    [ValidateRange(300,1800)][int]$TimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Attachment.psm1') -Force
$Manifest = (Resolve-Path -LiteralPath $Manifest).Path
$SuiteMsi = (Resolve-Path -LiteralPath $SuiteMsi).Path
$FakeBinary = (Resolve-Path -LiteralPath $FakeBinary).Path
$selection = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if ($selection.schema -ceq 'go-mapi-release-v1') {
    $release = $selection
    $dll = @($release.system.components | Where-Object component -ceq 'interceptor' | ForEach-Object artifacts | Where-Object architecture -ceq 'x64')
    if ($release.repository -cne 'marcfargas/go-mapi' -or $dll.Count -ne 1) { throw 'Select an unambiguous go-mapi public release manifest' }
    $selection = [pscustomobject]@{
        schema='go-mapi-machine-test-packages-v1'; sourceCommit=$release.commit
        packages=@{suiteC=@{sha256=$release.suite.artifact.sha256;appSha256=$release.suite.app.sha256;x64DllSha256=$dll[0].sha256;msi='C:\input\suite.msi'}}
    }
}
if ($selection.schema -cne 'go-mapi-machine-test-packages-v1' -or !$selection.packages.suiteC.appSha256 -or !$selection.packages.suiteC.x64DllSha256 -or (Get-FileHash -LiteralPath $SuiteMsi -Algorithm SHA256).Hash.ToLowerInvariant() -cne $selection.packages.suiteC.sha256) { throw 'Select the exact Suite MSI and complete suiteC manifest' }
$run = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ('explorer-' + [guid]::NewGuid().ToString('N'))
$inputs = Join-Path $run 'input'
New-Item -ItemType Directory -Path $inputs -Force | Out-Null
foreach ($name in @('Test-ExplorerGuest.ps1','Test-Attachment.ps1','Invoke-Attachment.ps1','Attachment.psm1','AttachmentNative.cs','ExplorerSendTo.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $inputs
}
Copy-Item -LiteralPath $SuiteMsi -Destination (Join-Path $inputs 'suite.msi')
Copy-Item -LiteralPath $FakeBinary -Destination (Join-Path $inputs 'fake-gmail.exe')
Write-AttachmentJson (Join-Path $inputs 'machine-test-packages.json') $selection
Copy-Item -LiteralPath $Manifest -Destination (Join-Path $run 'selected-manifest.json')
Write-Host ('Explorer regression evidence: ' + $run)
# The existing runner owns exclusion, selected-input hashing, all deadlines and
# exact guest disposal. No second lifecycle implementation lives here.
& (Join-Path $PSScriptRoot '../sandbox/run.ps1') -InputDirectory $inputs -ScriptPath Test-ExplorerGuest.ps1 -RunAs ExistingLogin -Connect -TimeoutSeconds $TimeoutSeconds -EvidenceRoot $run
