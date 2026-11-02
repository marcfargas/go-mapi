#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$InputDirectory, [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NativeGuest.ps1')
$result = [ordered]@{ Status = 'FAIL'; Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name; Checks = @(); ServiceIncluded = $false }
try {
    # This procedure is exclusively for the selected-input Sandbox runner.
    if ([IO.Path]::GetFullPath($InputDirectory).TrimEnd('\') -ne 'C:\input' -or
        [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\') -ne 'C:\output') { throw 'Run through just sandbox-test with its C:\input and C:\output shares.' }
    if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'Native/service checks require -RunAs System in the disposable guest.' }
    $manifestPath = Join-Path $InputDirectory 'native-inputs.json'
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $OutputDirectory 'native-inputs.json')
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Schema -ne 'go-mapi-sandbox-native-v3' -or $manifest.FixtureRoot -cne 'fixtures' -or $manifest.Builds.Count -ne 2 -or
        (@($manifest.Builds.Architecture | Sort-Object) -join ',') -ne 'x64,x86') { throw 'Unsupported native inputs manifest.' }
    if ($null -ne $manifest.Service) {
        if ($manifest.Service.Path -cne 'service.test.exe' -or
            @($manifest.Files | Where-Object { $_.Path -ceq 'service.test.exe' }).Count -ne 1) { throw 'Unsupported service inputs.' }
    }
    foreach ($file in $manifest.Files) {
        $path = Resolve-NativeInputFile $InputDirectory $file.Path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.SHA256 -or
            (Get-Item -LiteralPath $path).Length -ne $file.Bytes) { throw "Selected input changed: $($file.Path)" }
    }
    # Copy selected inputs off the read-only share before execution.
    $work = Join-Path $env:TEMP ('go-mapi-native-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $result.WorkDirectory = $work
    foreach ($file in $manifest.Files | Where-Object { $_.Path.StartsWith('fixtures/') }) {
        $target = Join-Path $work $file.Path
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Resolve-NativeInputFile $InputDirectory $file.Path) -Destination $target
    }
    $env:GO_MAPI_TEST_FIXTURE_ROOT = Join-Path $work 'fixtures'
    foreach ($build in $manifest.Builds) {
        $arch = $build.Architecture
        $bin = Join-Path $work $arch
        Copy-Item -LiteralPath (Join-Path $InputDirectory $arch) -Destination $bin -Recurse
        Push-Location $bin
        try {
            foreach ($unit in @('message_converter_tests', 'fs_utils_tests', 'queue_v1_tests', 'component_compat_tests')) {
                $name = "$arch-$unit"
                Invoke-NativeCheck -Executable (Join-Path $bin "$unit.exe") -Name $name -OutputDirectory $OutputDirectory
                $result.Checks += $name
            }
            $name = "$arch-mapi-harness"
            Invoke-NativeCheck -Executable (Join-Path $bin 'go-mapi-test-harness.exe') -Arguments @((Join-Path $bin 'go-mapi.dll')) -Name $name -OutputDirectory $OutputDirectory
            $result.Checks += $name
        } finally { Pop-Location }
    }
    $result.ServiceIncluded = ($null -ne $manifest.Service)
    if ($result.ServiceIncluded) {
        # A fresh guest should have no product registration. Refuse to borrow it
        # so successful cleanup is unambiguous for this selected-input journey.
        if (Get-Service -Name go-mapi -ErrorAction SilentlyContinue) { throw 'Guest already has a go-mapi service; refusing service fixture.' }
        $serviceExe = Join-Path $work 'service.test.exe'
        Copy-Item -LiteralPath (Resolve-NativeInputFile $InputDirectory $manifest.Service.Path) -Destination $serviceExe
        $serviceFailure = $null
        Push-Location $work
        try {
            Invoke-NativeCheck -Executable $serviceExe -Arguments @('-test.v', '-test.timeout=5m') -Name 'service' -OutputDirectory $OutputDirectory
            $result.Checks += 'service'
        } catch {
            $serviceFailure = $_
        } finally {
            Pop-Location
            $result.ServiceFixtureRemoved = ($null -eq (Get-Service -Name go-mapi -ErrorAction SilentlyContinue))
        }
        if ($serviceFailure) { throw "Service tests failed: $($serviceFailure.Exception.Message) ServiceFixtureRemoved=$($result.ServiceFixtureRemoved)" }
        if (-not $result.ServiceFixtureRemoved) { throw 'Service fixture remains in guest; see service logs.' }
    }
    $result.Status = 'PASS'
} catch {
    $result.Error = $_.Exception.Message
    throw
} finally {
    $result.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'native-result.json')
}
