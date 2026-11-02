# Windows PowerShell 5.1 compatible. Sourcing defines helpers only.
function Invoke-NativeCheck {
    param([string]$Executable, [string[]]$Arguments, [string]$Name, [string]$OutputDirectory)
    $prefix = Join-Path $OutputDirectory $Name
    $record = [ordered]@{ Name = $Name; Executable = $Executable; Arguments = @($Arguments); StartedAtUtc = [DateTime]::UtcNow.ToString('o'); ExitCode = $null; Status = 'RUNNING' }
    # Retain command identity even if the runner's deadline tears down the guest.
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$prefix.result.json"
    try {
        # Windows PowerShell turns redirected native stderr into ErrorRecords.
        # Keep both streams and decide success from the captured native exit.
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $global:LASTEXITCODE = $null
        & $Executable @Arguments 1> "$prefix.stdout.txt" 2> "$prefix.stderr.txt"
        $code = $global:LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $record.ExitCode = $code
        if ($null -eq $code -or $code -ne 0) { throw "$Name failed (exit $code); see $prefix.*" }
        $record.Status = 'PASS'
    } catch {
        $record.Status = 'FAIL'
        $record.Error = $_.Exception.Message
        throw
    } finally {
        $record.FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
        $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$prefix.result.json"
    }
}

function Resolve-NativeInputFile([string]$InputDirectory, [string]$RelativePath) {
    $root = [IO.Path]::GetFullPath($InputDirectory).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if ([IO.Path]::IsPathRooted($RelativePath) -or -not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Invalid selected file: $RelativePath" }
    return $path
}
