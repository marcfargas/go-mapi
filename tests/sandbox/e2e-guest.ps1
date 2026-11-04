param($InputDirectory, $OutputDirectory)
$ErrorActionPreference = 'Stop'
if ($env:GOMAPI_SANDBOX -ne '1') { throw 'Run the full e2e suite through the owned Sandbox runner' }
$result = [ordered]@{passed=$false;explorer=$false;component=$false;error=$null}
$result | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'e2e-result.json')
try {
    # Explorer requires a clean user queue; the component proof retains its
    # descriptors as evidence, so it runs after the installed journey's cleanup.
    & (Join-Path $InputDirectory 'Test-ExplorerGuest.ps1') -InputDirectory $InputDirectory -OutputDirectory $OutputDirectory
    $setup = Get-Content (Join-Path $OutputDirectory 'installed-smoke-setup.json') -Raw | ConvertFrom-Json
    if (!$setup.passed) { throw 'Installed Explorer journey did not pass' }
    $result.explorer = $true
    $versions = Get-Content (Join-Path $InputDirectory 'versions.json') -Raw | ConvertFrom-Json
    & (Join-Path $InputDirectory 'component-integration.ps1') `
        -X64Dll (Join-Path $InputDirectory 'x64.dll') -X64Harness (Join-Path $InputDirectory 'x64-harness.exe') `
        -X86Dll (Join-Path $InputDirectory 'x86.dll') -X86Harness (Join-Path $InputDirectory 'x86-harness.exe') `
        -AppProbeBinary (Join-Path $InputDirectory 'app-probe.exe') `
        -InterceptorVersion $versions.interceptor -AppVersion $versions.app `
        -EvidenceDirectory (Join-Path $OutputDirectory 'component')
    $component = Get-Content (Join-Path $OutputDirectory 'component/component-integration.json') -Raw | ConvertFrom-Json
    if (@($component.results).Count -ne 2) { throw 'Both native architectures must pass' }
    $result.component = $true
    $result.passed = $true
} catch { $result.error = $_.Exception.Message }
finally { $result | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'e2e-result.json') }
if (!$result.passed) { throw ('Windows e2e failed: ' + $result.error) }
