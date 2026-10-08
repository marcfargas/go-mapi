[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $TargetProcessId,
    [Parameter(Mandatory)] [string] $ExpectedCommand,
    [Parameter(Mandatory)] [string] $ExpectedRunId,
    [Parameter(Mandatory)] [string] $AttachedPath,
    [Parameter(Mandatory)] [string] $ExitPath,
    [Parameter(Mandatory)] [string] $FailurePath,
    [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

function Write-Atomic([string] $Path, $Value) {
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

if (!('Ticket569ProcessObserver' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Ticket569ProcessObserver {
 [StructLayout(LayoutKind.Sequential)] public struct FileTime { public uint Low; public uint High; }
 [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern uint GetProcessId(IntPtr handle);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr handle, out FileTime creation, out FileTime exitTime, out FileTime kernel, out FileTime user);
 public static long GetCreationFileTime(IntPtr handle) {
  FileTime creation, exitTime, kernel, user;
  if (!GetProcessTimes(handle, out creation, out exitTime, out kernel, out user)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  return ((long)creation.High << 32) | creation.Low;
 }
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
}
'@
}

$handle = [IntPtr]::Zero
try {
    $before = Get-CimInstance Win32_Process -Filter "ProcessId = $TargetProcessId" -ErrorAction Stop
    if (!$before -or $before.CommandLine.IndexOf($ExpectedCommand, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $before.CommandLine.IndexOf($ExpectedRunId, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw 'Target PID did not identify the expected live command'
    }
    $handle = [Ticket569ProcessObserver]::OpenProcess(0x00100000 -bor 0x00001000, $false, $TargetProcessId)
    if ($handle -eq [IntPtr]::Zero) { throw "OpenProcess failed with $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    if ([Ticket569ProcessObserver]::GetProcessId($handle) -ne $TargetProcessId) { throw 'Process handle identity differed from requested PID' }
    $after = Get-CimInstance Win32_Process -Filter "ProcessId = $TargetProcessId" -ErrorAction Stop
    if (!$after -or $after.CommandLine.IndexOf($ExpectedCommand, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        $after.CommandLine.IndexOf($ExpectedRunId, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw 'Target PID command identity changed while opening the process handle'
    }
    $beforeCimTime = ([DateTime]$before.CreationDate).ToUniversalTime().ToFileTimeUtc()
    $afterCimTime = ([DateTime]$after.CreationDate).ToUniversalTime().ToFileTimeUtc()
    $creationTicks = [Ticket569ProcessObserver]::GetCreationFileTime($handle)
    if ([Math]::Abs($creationTicks - $beforeCimTime) -gt 10000 -or [Math]::Abs($creationTicks - $afterCimTime) -gt 10000) {
        throw 'Retained process handle creation time does not match the observed launcher identity'
    }
    $creation = [DateTime]::FromFileTimeUtc($creationTicks).ToString('o')
    Write-Atomic $AttachedPath @{ SchemaVersion = 1; PID = $TargetProcessId; ProcessName = $after.Name; CommandLine = $after.CommandLine; CreationDateFromHandle = $creation; CreationFileTimeUtc = $creationTicks; CimCreationFileTimeUtc = $afterCimTime; HandleRetained = $true; AttachedAt = [DateTime]::UtcNow.ToString('o') }
    $wait = [Ticket569ProcessObserver]::WaitForSingleObject($handle, [uint32]($TimeoutSeconds * 1000))
    if ($wait -ne 0) { throw "WaitForSingleObject did not observe termination (result $wait)" }
    [uint32]$exitCode = 0
    if (![Ticket569ProcessObserver]::GetExitCodeProcess($handle, [ref]$exitCode)) { throw "GetExitCodeProcess failed with $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    Write-Atomic $ExitPath @{ SchemaVersion = 1; PID = $TargetProcessId; ExitCode = [long]$exitCode; CreationDateFromHandle = $creation; CreationFileTimeUtc = $creationTicks; HandleRetained = $true; ExitedAt = [DateTime]::UtcNow.ToString('o') }
} catch {
    try { Write-Atomic $FailurePath @{ PID = $TargetProcessId; Error = $_.ToString(); At = [DateTime]::UtcNow.ToString('o') } } catch {}
    return
} finally {
    if ($handle -ne [IntPtr]::Zero) { [void][Ticket569ProcessObserver]::CloseHandle($handle) }
}
