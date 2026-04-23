<#
.SYNOPSIS
  Collect go-mapi runtime diagnostics (queue tree, log tails, loaded DLLs) into
  a timestamped text file.

.DESCRIPTION
  Produces a single text report at $OutputDir\go-mapi-runtime-<yyyyMMdd-HHmmss>.txt
  covering:
    1. Header (host, user, OS bitness, process bitness)
    2. Queue directory tree under %LOCALAPPDATA%\go-mapi\queue\
    3. errors/ subdir with full contents of each .error file
    4. Interceptor log tail (last 200 lines)
    5. App log tail (last 200 lines)
    6. Processes currently holding go-mapi.dll
    7. Env var snapshot (LOCALAPPDATA, APPDATA, USERPROFILE, TEMP, TMP)
    8. Footer

  Intended for inclusion in bug reports. Only the final "Report written to: …"
  line is echoed to the console. Read-only — does not mutate any state.

.NOTES
  Added by quick/260423-msq.
  Window-PowerShell 5.1 compatible (do not require PowerShell 7).
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

$out = Join-Path $OutputDir "go-mapi-runtime-$timestamp.txt"

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
Append-Line "go-mapi runtime report (script v$scriptVersion)"
Append-Line "Timestamp     : $(Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')"
Append-Line "Computer      : $env:COMPUTERNAME"
Append-Line "User          : $env:USERNAME"
Append-Line "OS            : $([Environment]::OSVersion.VersionString)"
Append-Line "Is64BitOS     : $([Environment]::Is64BitOperatingSystem)"
Append-Line "Is64BitProcess: $([Environment]::Is64BitProcess)"
Append-Line "PSVersion     : $($PSVersionTable.PSVersion)"

# -----------------------------------------------------------------------------
# Section 2: Queue directory tree
# -----------------------------------------------------------------------------
Append-Banner 'Queue directory tree'

$queueRoot = Join-Path $env:LOCALAPPDATA 'go-mapi\queue'
Append-Line "Queue root: $queueRoot"

if (Test-Path -LiteralPath $queueRoot) {
    Safe-Invoke 'Queue tree' {
        $entries = Get-ChildItem -LiteralPath $queueRoot -Recurse -Force -ErrorAction Stop
        $entries |
            Select-Object FullName, Length, LastWriteTime |
            Format-Table -AutoSize |
            Append-Block
        $topJson = @(Get-ChildItem -LiteralPath $queueRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
        Append-Line ''
        Append-Line "Top-level *.json count: $($topJson.Count)"
    }
} else {
    Append-Line '(queue directory does not exist — DLL has not been loaded by any process yet, or the installer did not run)'
}

# -----------------------------------------------------------------------------
# Section 3: errors/ subdir
# -----------------------------------------------------------------------------
Append-Banner 'Errors subdirectory'

$errorsDir = Join-Path $queueRoot 'errors'
Append-Line "Errors dir: $errorsDir"

if (Test-Path -LiteralPath $errorsDir) {
    Safe-Invoke 'Errors subdir' {
        $errFiles = @(Get-ChildItem -LiteralPath $errorsDir -File -ErrorAction SilentlyContinue)
        Append-Line "File count: $($errFiles.Count)"
        foreach ($f in $errFiles) {
            Append-Line ''
            Append-Line "--- $($f.FullName) (size=$($f.Length), mtime=$($f.LastWriteTime)) ---"
            Safe-Invoke "read $($f.Name)" {
                Get-Content -LiteralPath $f.FullName -ErrorAction Stop | Append-Block
            }
        }
    }
} else {
    Append-Line '(errors/ directory does not exist)'
}

# -----------------------------------------------------------------------------
# Section 4: Interceptor log tail
# -----------------------------------------------------------------------------
Append-Banner 'Interceptor log tail'

$interceptorLogNew = Join-Path $env:LOCALAPPDATA 'go-mapi\queue\interceptor.log'
$interceptorLogOld = Join-Path $env:TEMP 'go-mapi\interceptor.log'

if (Test-Path -LiteralPath $interceptorLogNew) {
    Append-Line "Log path (new layout): $interceptorLogNew"
    Safe-Invoke 'interceptor.log tail (new)' {
        Get-Content -LiteralPath $interceptorLogNew -Tail 200 -ErrorAction Stop | Append-Block
    }
} elseif (Test-Path -LiteralPath $interceptorLogOld) {
    Append-Line "Log path (pre-quick/260423-msq fallback): $interceptorLogOld"
    Append-Line '(This location is from before the %LOCALAPPDATA%\go-mapi\queue relocation.'
    Append-Line ' Finding log files here suggests an older DLL is still loaded or installed.)'
    Safe-Invoke 'interceptor.log tail (old)' {
        Get-Content -LiteralPath $interceptorLogOld -Tail 200 -ErrorAction Stop | Append-Block
    }
} else {
    Append-Line "(No interceptor.log found at either $interceptorLogNew or $interceptorLogOld)"
}

# -----------------------------------------------------------------------------
# Section 5: App log tail
# -----------------------------------------------------------------------------
Append-Banner 'App log tail'

$appLog = Join-Path $env:APPDATA 'go-mapi\app.log'
Append-Line "App log: $appLog"

if (Test-Path -LiteralPath $appLog) {
    Safe-Invoke 'app.log tail' {
        Get-Content -LiteralPath $appLog -Tail 200 -ErrorAction Stop | Append-Block
    }
} else {
    Append-Line '(app.log not present — Wails app has not run yet, or the path is wrong)'
}

# -----------------------------------------------------------------------------
# Section 6: Processes currently holding go-mapi.dll
# -----------------------------------------------------------------------------
Append-Banner 'Processes holding go-mapi.dll'

Safe-Invoke 'loaded-DLL scan' {
    $holders = Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $match = $_.Modules | Where-Object { $_.ModuleName -ieq 'go-mapi.dll' }
            if ($match) {
                [PSCustomObject]@{
                    Id          = $_.Id
                    ProcessName = $_.ProcessName
                    DllPath     = ($match | Select-Object -First 1).FileName
                }
            }
        } catch {
            # Access-denied on protected processes is expected; swallow.
        }
    }
    if ($holders) {
        $holders | Format-Table -AutoSize | Append-Block
    } else {
        Append-Line '(no accessible processes currently hold go-mapi.dll)'
    }
}

# -----------------------------------------------------------------------------
# Section 7: Env var snapshot (sanitized)
# -----------------------------------------------------------------------------
Append-Banner 'Env snapshot (sanitized)'
foreach ($name in @('LOCALAPPDATA', 'APPDATA', 'USERPROFILE', 'TEMP', 'TMP')) {
    $value = [Environment]::GetEnvironmentVariable($name, 'Process')
    if ($null -eq $value) { $value = '(unset)' }
    Append-Line ("{0,-14} = {1}" -f $name, $value)
}

# -----------------------------------------------------------------------------
# Footer
# -----------------------------------------------------------------------------
Append-Banner 'Footer'
Append-Line "End of report ($([DateTime]::Now.ToString('o')))"

Write-Host "Report written to: $out"
