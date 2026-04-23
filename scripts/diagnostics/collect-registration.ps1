<#
.SYNOPSIS
  Collect go-mapi MAPI registration + DLL diagnostics into a timestamped text file.

.DESCRIPTION
  Produces a single text report at $OutputDir\go-mapi-registration-<yyyyMMdd-HHmmss>.txt
  covering:
    1. Header (host, user, OS bitness, process bitness)
    2. HKLM mail clients (native view)
    3. HKLM mail clients (WOW6432 view)
    4. HKLM go-mapi registration (both views)
    5. DLL presence, size, SHA256, PE bitness (32 vs 64)
    6. DLL export probe via LoadLibraryEx + GetProcAddress
    7. Footer

  Intended for inclusion in bug reports. Only the final "Report written to: …" line
  is echoed to the console.

.NOTES
  Added by quick/260423-msq.
  Window-PowerShell 5.1 compatible (do not require PowerShell 7).
  The export probe runs in the CURRENT process's architecture — re-run this script
  from C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe to probe the 32-bit DLL.
#>
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputDir = "$env:USERPROFILE\Desktop"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$scriptVersion = '1.0'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not (Test-Path -LiteralPath $OutputDir)) {
    try {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    } catch {
        Write-Error "Failed to create OutputDir '$OutputDir': $($_.Exception.Message)"
        exit 1
    }
}

$out = Join-Path $OutputDir "go-mapi-registration-$timestamp.txt"

function Append-Banner {
    param([string]$Title)
    Add-Content -LiteralPath $out -Value ''
    Add-Content -LiteralPath $out -Value ('=' * 72)
    Add-Content -LiteralPath $out -Value "=== Section: $Title ==="
    Add-Content -LiteralPath $out -Value ('=' * 72)
}

function Append-Line {
    param([string]$Line = '')
    Add-Content -LiteralPath $out -Value $Line
}

function Append-Block {
    param([Parameter(ValueFromPipeline = $true)]$Input)
    process {
        if ($null -eq $Input) { return }
        $text = $Input | Out-String -Width 240
        $text = $text.TrimEnd("`r", "`n")
        if ($text.Length -gt 0) {
            Add-Content -LiteralPath $out -Value $text
        }
    }
}

function Safe-Invoke {
    param(
        [string]$Description,
        [scriptblock]$Action
    )
    try {
        & $Action
    } catch {
        Append-Line "[$Description] ERROR: $($_.Exception.Message)"
    }
}

# -----------------------------------------------------------------------------
# Section 1: Header
# -----------------------------------------------------------------------------
Append-Banner 'Header'
Append-Line "go-mapi registration report (script v$scriptVersion)"
Append-Line "Timestamp     : $(Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')"
Append-Line "Computer      : $env:COMPUTERNAME"
Append-Line "User          : $env:USERNAME"
Append-Line "OS            : $([Environment]::OSVersion.VersionString)"
Append-Line "Is64BitOS     : $([Environment]::Is64BitOperatingSystem)"
Append-Line "Is64BitProcess: $([Environment]::Is64BitProcess)"
Append-Line "PSVersion     : $($PSVersionTable.PSVersion)"

# -----------------------------------------------------------------------------
# Section 2: HKLM mail clients (native view)
# -----------------------------------------------------------------------------
Append-Banner 'HKLM mail clients (native view)'
Safe-Invoke 'HKLM Mail clients' {
    Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Clients\Mail' -ErrorAction Stop |
        Select-Object Name, PSChildName |
        Append-Block
    Append-Line ''
    Append-Line 'Default value at HKLM:\SOFTWARE\Clients\Mail :'
    Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Clients\Mail' -ErrorAction Stop |
        Format-List '(default)', '*' |
        Append-Block
}

# -----------------------------------------------------------------------------
# Section 3: HKLM mail clients (WOW6432 view)
# -----------------------------------------------------------------------------
Append-Banner 'HKLM mail clients (WOW6432 view)'
Safe-Invoke 'HKLM WOW6432 Mail clients' {
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Clients\Mail') {
        Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Clients\Mail' -ErrorAction Stop |
            Select-Object Name, PSChildName |
            Append-Block
        Append-Line ''
        Append-Line 'Default value at HKLM:\SOFTWARE\WOW6432Node\Clients\Mail :'
        Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Clients\Mail' -ErrorAction Stop |
            Format-List '(default)', '*' |
            Append-Block
    } else {
        Append-Line '(No HKLM:\SOFTWARE\WOW6432Node\Clients\Mail key — 32-bit view not present)'
    }
}

# -----------------------------------------------------------------------------
# Section 4: HKLM go-mapi registration (native + WOW6432)
# -----------------------------------------------------------------------------
Append-Banner 'HKLM go-mapi registration'
foreach ($root in @('HKLM:\SOFTWARE\Clients\Mail\go-mapi',
                    'HKLM:\SOFTWARE\WOW6432Node\Clients\Mail\go-mapi')) {
    Append-Line ''
    Append-Line "Key: $root"
    Safe-Invoke "Dump $root" {
        if (Test-Path -LiteralPath $root) {
            Get-ItemProperty -LiteralPath $root | Format-List * | Append-Block
            # Dump all subkeys recursively
            Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Append-Line ''
                    Append-Line "Subkey: $($_.Name)"
                    Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue |
                        Format-List * |
                        Append-Block
                }
        } else {
            Append-Line '(key not present)'
        }
    }
}

# -----------------------------------------------------------------------------
# Section 5: DLL presence + PE bitness + hash
# -----------------------------------------------------------------------------
Append-Banner 'DLL presence / PE bitness / SHA256'

$dllCandidates = @(
    "$env:ProgramFiles\go-mapi\go-mapi.dll",
    "${env:ProgramFiles(x86)}\go-mapi\go-mapi.dll"
)

function Get-PEBitness {
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 0x40) { return 'unknown (file too small)' }
        # e_lfanew is a 4-byte little-endian value at offset 0x3C.
        $e_lfanew = [BitConverter]::ToInt32($bytes, 0x3C)
        if ($bytes.Length -lt ($e_lfanew + 0x18 + 2)) { return 'unknown (truncated PE)' }
        # "PE\0\0" + FileHeader(20 bytes) + OptionalHeader magic(2 bytes).
        $magic = [BitConverter]::ToUInt16($bytes, $e_lfanew + 4 + 20)
        switch ($magic) {
            0x10B { return 'PE32 (32-bit / x86)' }
            0x20B { return 'PE32+ (64-bit / x64 or arm64)' }
            default { return ('unknown (magic=0x{0:X4})' -f $magic) }
        }
    } catch {
        return "error: $($_.Exception.Message)"
    }
}

foreach ($dll in $dllCandidates) {
    Append-Line ''
    Append-Line "Candidate path: $dll"
    if (Test-Path -LiteralPath $dll) {
        try {
            $item = Get-Item -LiteralPath $dll
            Append-Line "  Present        : YES"
            Append-Line "  Size (bytes)   : $($item.Length)"
            Append-Line "  LastWriteTime  : $($item.LastWriteTime)"
            $bitness = Get-PEBitness -Path $dll
            Append-Line "  PE bitness     : $bitness"
            $hash = Get-FileHash -LiteralPath $dll -Algorithm SHA256
            Append-Line "  SHA256         : $($hash.Hash)"
        } catch {
            Append-Line "  ERROR inspecting DLL: $($_.Exception.Message)"
        }
    } else {
        Append-Line "  Present        : NO"
    }
}

# -----------------------------------------------------------------------------
# Section 6: DLL export probe (LoadLibraryEx + GetProcAddress)
# -----------------------------------------------------------------------------
Append-Banner 'DLL export probe (in-process)'
Append-Line 'Probes the CURRENT PowerShell process architecture.'
Append-Line "CurrentProcessIs64Bit: $([Environment]::Is64BitProcess)"
Append-Line 'Re-run via C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe to probe the 32-bit DLL.'

$csharp = @'
using System;
using System.Runtime.InteropServices;

public static class GoMapiProbe
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibraryExW(string lpFileName, IntPtr hFile, uint dwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FreeLibrary(IntPtr hModule);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string lpProcName);

    [DllImport("kernel32.dll")]
    public static extern uint GetLastError();

    public const uint DONT_RESOLVE_DLL_REFERENCES = 0x00000001;
    public const uint LOAD_LIBRARY_AS_DATAFILE   = 0x00000002;
}
'@

try {
    Add-Type -TypeDefinition $csharp -ErrorAction Stop
} catch {
    Append-Line "Could not compile probe shim: $($_.Exception.Message)"
    Append-Line 'Skipping export probe.'
}

$expectedExports = @(
    'MAPISendMail',
    'MAPISendMailW',
    'MAPILogon',
    'MAPILogoff',
    'MAPIFreeBuffer',
    'MAPISendDocuments'
)

foreach ($dll in $dllCandidates) {
    Append-Line ''
    Append-Line "Probing: $dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        Append-Line '  (not present — skipped)'
        continue
    }
    # DONT_RESOLVE_DLL_REFERENCES lets us inspect exports without running DllMain.
    $h = [GoMapiProbe]::LoadLibraryExW($dll, [IntPtr]::Zero, [GoMapiProbe]::DONT_RESOLVE_DLL_REFERENCES)
    if ($h -eq [IntPtr]::Zero) {
        $err = [GoMapiProbe]::GetLastError()
        Append-Line ('  LoadLibraryEx failed (GetLastError=0x{0:X8} / {1})' -f $err, $err)
        continue
    }
    try {
        foreach ($exp in $expectedExports) {
            $addr = [GoMapiProbe]::GetProcAddress($h, $exp)
            if ($addr -eq [IntPtr]::Zero) {
                $err = [GoMapiProbe]::GetLastError()
                Append-Line ('  {0,-20} NOT FOUND (GetLastError=0x{1:X8})' -f $exp, $err)
            } else {
                Append-Line ('  {0,-20} found  at 0x{1:X}' -f $exp, $addr.ToInt64())
            }
        }
    } finally {
        [void][GoMapiProbe]::FreeLibrary($h)
    }
}

# -----------------------------------------------------------------------------
# Footer
# -----------------------------------------------------------------------------
Append-Banner 'Footer'
Append-Line "End of report ($([DateTime]::Now.ToString('o')))"

Write-Host "Report written to: $out"
