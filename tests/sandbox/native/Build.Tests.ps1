# Native build failure propagation without invoking a compiler or CTest.
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('go-mapi-native-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixture 'src/interceptor') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'src/interceptor/build.ps1') -Destination (Join-Path $fixture 'src/interceptor/build.ps1')
Copy-Item -LiteralPath (Join-Path $repo 'components.json') -Destination $fixture
$calls = [Collections.Generic.List[string]]::new()
$ctestExit = 0
function Test-Path {
    param([string]$Path)
    if ($Path -match 'mingw-mstorsjo-llvm-ucrt.current.bin(?:[\\/][^\\/]*-(?:clang(?:\+\+)?|windres)\.exe)?$') { return $true }
    if ($Path -match 'mingw-mstorsjo-llvm-ucrt.current.bin[\\/](?:cmake|ninja)\.exe$') { return $false }
    Microsoft.PowerShell.Management\Test-Path -LiteralPath $Path
}
function Get-Command {
    param([string]$Name)
    if ($Name -in @('cmake', 'ninja')) { return [pscustomobject]@{ Source = $Name } }
    Microsoft.PowerShell.Core\Get-Command $Name
}
function cmake { $global:LASTEXITCODE = 0 }
function ctest { $calls.Add(($args -join ' ')); $global:LASTEXITCODE = $ctestExit }
try {
    foreach ($code in @(0, 7, 8)) {
        $ctestExit = $code
        $calls.Clear()
        $failed = $false
        try { & (Join-Path $fixture 'src/interceptor/build.ps1') -Config Release -RunTests } catch {
            if ($_.Exception.Message -ne "CTest failed with exit code $code") { throw }
            $failed = $true
        }
        if ($failed -ne ($code -ne 0)) { throw "CTest exit $code was not propagated" }
        if ($calls.Count -ne 1 -or $calls[0] -notmatch '--output-on-failure' -or
            $calls[0] -notmatch '--build-config Release' -or $calls[0] -notmatch '--no-tests=error') {
            throw "CTest invocation mismatch for exit $code"
        }
    }
    Write-Output 'Native build contracts passed (fake compiler/CTest, unchanged build entrypoint).'
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not ([IO.Path]::GetFullPath($fixture)).StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
