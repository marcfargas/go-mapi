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
        [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\') -ne 'C:\output') { throw 'Run through scripts/run-sandbox-test.ps1 with its C:\input and C:\output shares.' }
    if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'Native/service checks require -RunAs System in the disposable guest.' }
    $manifestPath = Join-Path $InputDirectory 'native-inputs.json'
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $OutputDirectory 'native-inputs.json')
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Schema -ne 'go-mapi-sandbox-native-v2' -or $manifest.Builds.Count -ne 2 -or
        (@($manifest.Builds.Architecture | Sort-Object) -join ',') -ne 'x64,x86') { throw 'Unsupported native inputs manifest.' }
    # Service paths are a fixed selected-file contract, including the source
    # fixture read by readiness tests from their working directory.
    if ($null -ne $manifest.Service) {
        if ($manifest.Service.Path -cne 'service.test.exe' -or $manifest.Service.FixturePath -cne 'runner_windows.go') { throw 'Unsupported service inputs.' }
        foreach ($required in @($manifest.Service.Path, $manifest.Service.FixturePath)) {
            if (@($manifest.Files | Where-Object { $_.Path -ceq $required }).Count -ne 1) { throw "Required service input must be listed once: $required" }
        }
    }
    foreach ($file in $manifest.Files) {
        $path = Resolve-NativeInputFile $InputDirectory $file.Path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.SHA256 -or
            (Get-Item -LiteralPath $path).Length -ne $file.Bytes) { throw "Selected input changed: $($file.Path)" }
    }
    # Copy executable inputs off the read-only share; the harness and service
    # tests may create local sidecars. Nothing is installed or registered here.
    $work = Join-Path $env:TEMP ('go-mapi-native-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $result.WorkDirectory = $work
    foreach ($build in $manifest.Builds) {
        $arch = $build.Architecture
        $root = [IO.Path]::GetFullPath($build.BuildFixtureRoot)
        if ($root -notmatch '^[A-Za-z]:\\.+\\tests$' -or
            [IO.Path]::GetFullPath($build.CompiledQueueFixtureDirectory) -ne (Join-Path $root 'protocol-fixtures/queue-v1') -or
            [IO.Path]::GetFullPath($build.CompiledCompatibilityFixtureFile) -ne (Join-Path $root 'component-compatibility/compatibility-v1.json')) { throw "Invalid compiled fixture layout for $arch" }
        $drive = [IO.Path]::GetPathRoot($root)
        if (-not (Test-Path -LiteralPath $drive)) {
            # Preserve a build made on another drive without requiring that
            # volume on the disposable guest. The mapping dies with the guest.
            $driveStorage = Join-Path $work ('fixture-drive-' + $drive.Substring(0, 1))
            New-Item -ItemType Directory -Path $driveStorage | Out-Null
            Invoke-NativeCheck -Executable (Join-Path $env:SystemRoot 'System32/subst.exe') -Arguments @($drive.TrimEnd('\'), $driveStorage) -Name ("fixture-drive-" + $drive.Substring(0, 1)) -OutputDirectory $OutputDirectory
        }
        # Use only fixture files listed and hashed by the host preparer, never a
        # checkout share. Different build roots can coexist in one guest.
        foreach ($file in $manifest.Files | Where-Object { $_.Path.StartsWith("fixtures/$arch/") }) {
            $relative = $file.Path.Substring("fixtures/$arch/".Length)
            $target = Join-Path $root $relative
            New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
            Copy-Item -LiteralPath (Resolve-NativeInputFile $InputDirectory $file.Path) -Destination $target -Force
        }
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
        Copy-Item -LiteralPath (Resolve-NativeInputFile $InputDirectory $manifest.Service.FixturePath) -Destination (Join-Path $work 'runner_windows.go')
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
