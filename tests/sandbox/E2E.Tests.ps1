# Test suite composition with inert journey implementations; no installer,
# native harness, trust changes or Sandbox is executed by these contracts.
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('gomapi-e2e-' + [guid]::NewGuid().ToString('N'))
$savedMarker = $env:GOMAPI_SANDBOX
$savedActions = $env:GITHUB_ACTIONS
$savedAct = $env:ACT
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'e2e-guest.ps1') -Destination $root
    @'
param($InputDirectory,$OutputDirectory)
if ($env:E2E_FAIL -eq 'explorer') { throw 'inert Explorer failure' }
@{passed=$true} | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'installed-smoke-setup.json')
'explorer' | Add-Content (Join-Path $OutputDirectory 'order.txt')
'@ | Set-Content (Join-Path $root 'Test-ExplorerGuest.ps1')
    @'
param($X64Dll,$X64Harness,$X86Dll,$X86Harness,$AppProbeBinary,$InterceptorVersion,$AppVersion,$EvidenceDirectory)
if ($env:E2E_FAIL -eq 'component') { throw 'inert component failure' }
if ($AppProbeBinary -cne (Join-Path $PSScriptRoot 'app-probe.exe')) { throw 'compiled app probe was not selected' }
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
@{results=@(@{architecture='x64'},@{architecture='x86'})} | ConvertTo-Json | Set-Content (Join-Path $EvidenceDirectory 'component-integration.json')
'component' | Add-Content (Join-Path (Split-Path $EvidenceDirectory) 'order.txt')
'@ | Set-Content (Join-Path $root 'component-integration.ps1')
    @{app='1.2.3';interceptor='1.2.3'} | ConvertTo-Json | Set-Content (Join-Path $root 'versions.json')
    $env:GOMAPI_SANDBOX = '1'
    foreach ($failure in @('','explorer','component')) {
        $env:E2E_FAIL = $failure
        $output = Join-Path $root ('output-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $output | Out-Null
        $thrown = $false
        try { & (Join-Path $root 'e2e-guest.ps1') -InputDirectory $root -OutputDirectory $output } catch { $thrown = $true }
        $result = Get-Content (Join-Path $output 'e2e-result.json') -Raw | ConvertFrom-Json
        if ($failure) {
            if (!$thrown -or $result.passed -or $result.error -notlike ('*inert '+$failure+' failure*')) { throw "Suite swallowed $failure failure" }
        } elseif ($thrown -or !$result.passed -or !$result.explorer -or !$result.component -or
            ((Get-Content (Join-Path $output 'order.txt')) -join ',') -cne 'explorer,component') { throw ('Suite did not require both journeys in clean-queue order: ' + ($result | ConvertTo-Json -Compress)) }
    }
    $env:GOMAPI_SANDBOX = $null
    $thrown = $false
    try { & (Join-Path $root 'e2e-guest.ps1') -InputDirectory $root -OutputDirectory $output } catch { $thrown = $true }
    if (!$thrown) { throw 'Guest suite accepted unguarded execution' }
    $arguments = @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'e2e.ps1'),
        '-ComponentOnly','-X64Dll','unused','-X64Harness','unused','-X86Dll','unused','-X86Harness','unused',
        '-InterceptorVersion','1.2.3','-AppVersion','1.2.3','-EvidenceDirectory',$output)
    foreach ($act in @('','true')) {
        $env:GITHUB_ACTIONS = 'true'; $env:ACT = $act
        if (!$act) { $env:GITHUB_ACTIONS = $null }
        $null = & pwsh @arguments 2>&1
        if ($LASTEXITCODE -eq 0) { throw 'Component-only wrapper accepted host or act execution' }
    }
    & {
        # Exercise the actual installer setup's finally block with inert owned
        # resources and failing evidence storage. Every cleanup must still run.
        $setupPath = Join-Path $PSScriptRoot '../installed-attachment/Test-ExplorerGuest.ps1'
        $tokens=$null; $parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($setupPath,[ref]$tokens,[ref]$parseErrors)
        if ($parseErrors) { throw 'Cannot parse installer cleanup contract' }
        $save=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-SetupReceipt'},$false)
        . ([scriptblock]::Create($save.Extent.Text))
        $outer=$ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] } | Select-Object -Last 1
        function Set-Content { throw 'inert disk-full evidence failure' }
        function Get-Service { $null }
        function Test-Path { $false }
        $cleanup=@{msi=$false}
        function Msi { $cleanup.msi=$true }
        $job=[pscustomobject]@{disposed=$false}
        $job | Add-Member ScriptMethod Dispose {$this.disposed=$true}
        $user=[pscustomobject]@{HasExited=$true;disposed=$false}
        $user | Add-Member ScriptMethod Dispose {$this.disposed=$true}
        $launcher=$null; $installAttempted=$true; $trust=@('inert-owned-CA')
        $errors=[Collections.Generic.List[string]]::new()
        $receipt=@{passed=$true}; $OutputDirectory=$root
        $writeFailed=$false
        try { & ([scriptblock]::Create(($outer.Finally.Statements.Extent.Text -join "`n"))) } catch { $writeFailed=$true }
        if (!$writeFailed -or !$job.disposed -or !$user.disposed -or !$cleanup.msi -or
            !$receipt.removed -or !$receipt.trustRemoved -or $receipt.passed -or !$errors.Count) {
            throw 'Evidence failure prevented owned cleanup or was accepted as a pass'
        }
    }
    'Windows e2e suite contracts passed'
} finally {
    $env:GOMAPI_SANDBOX = $savedMarker
    $env:GITHUB_ACTIONS = $savedActions
    $env:ACT = $savedAct
    Remove-Item Env:E2E_FAIL -ErrorAction SilentlyContinue
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
