# Collect-Phase11Evidence.ps1
#
# Post-harness evidence gathering. Run INSIDE the sandbox (before closing it)
# or on the host AFTER the sandbox has been torn down (the mapped folder
# persists - that's the whole point of the .wsb MappedFolders block).
#
# Responsibilities:
#   - Copy %APPDATA%\go-mapi\app.log into the evidence directory (captures
#     OAuth/queue/Gmail activity the human performed during the manual tail).
#   - Copy %LOCALAPPDATA%\go-mapi\*.log if present.
#   - Snapshot the MAPI JSON staging dir (%TEMP%\go-mapi\) before the app
#     deletes processed files - useful if the draft step failed.
#   - Dump installer/uninstaller logs from %TEMP%.
#   - Write a final evidence-manifest.json listing every file collected with
#     SHA256 hashes, so SMOKE-EVIDENCE.md can cite integrity-checked names.
#
# DOES NOT take screenshots (Run-Phase11Smoke.ps1 does that during automation)
# and DOES NOT attempt to parse OAuth tokens or email body content - privacy
# baseline from CLAUDE.md + D-15 is "capture app behavior/status, not secrets".

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$EvidenceDir,
    [string]$MappedRoot = 'C:\phase11'
)

$ErrorActionPreference = 'Stop'

function Resolve-LatestEvidenceDir {
    param([string]$Root)
    $candidates = Get-ChildItem -LiteralPath $Root -Directory -Filter 'evidence-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    if (-not $candidates) {
        throw "No evidence-* directories under $Root - did Run-Phase11Smoke.ps1 run?"
    }
    return $candidates[0].FullName
}

function Copy-IfExists {
    param([string]$Src, [string]$DestDir, [string]$Label)
    if (Test-Path -LiteralPath $Src) {
        $destName = Join-Path $DestDir (Split-Path $Src -Leaf)
        Copy-Item -LiteralPath $Src -Destination $destName -Force -Recurse
        Write-Host "[collect] OK $Label :: $Src"
        return $destName
    } else {
        Write-Host "[collect] SKIP $Label :: $Src (not present)"
        return $null
    }
}

function New-EvidenceManifest {
    param([string]$EvidenceDir)
    $manifest = [ordered]@{
        generatedAt  = (Get-Date).ToString('o')
        evidenceDir  = $EvidenceDir
        sandboxHost  = $env:COMPUTERNAME
        files        = @()
    }
    Get-ChildItem -LiteralPath $EvidenceDir -File -Recurse | ForEach-Object {
        $rel = $_.FullName.Substring($EvidenceDir.Length).TrimStart('\','/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        $manifest.files += [ordered]@{
            path   = $rel
            bytes  = $_.Length
            sha256 = $hash
        }
    }
    $manifestPath = Join-Path $EvidenceDir 'evidence-manifest.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-Host "[collect] manifest: $manifestPath"
}

if (-not $EvidenceDir) {
    $EvidenceDir = Resolve-LatestEvidenceDir -Root $MappedRoot
}
if (-not (Test-Path -LiteralPath $EvidenceDir)) {
    throw "EvidenceDir does not exist: $EvidenceDir"
}

Write-Host "[collect] Evidence directory: $EvidenceDir"

$logsDir = Join-Path $EvidenceDir 'logs'
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

Copy-IfExists -Src "$env:APPDATA\go-mapi\app.log"      -DestDir $logsDir -Label 'app.log'
Copy-IfExists -Src "$env:LOCALAPPDATA\go-mapi"         -DestDir $logsDir -Label 'LocalAppData\go-mapi'
Copy-IfExists -Src "$env:TEMP\go-mapi"                 -DestDir $logsDir -Label 'TEMP\go-mapi (MAPI JSON staging)'
Copy-IfExists -Src "$env:TEMP\nsis-uninst-go-mapi.log" -DestDir $logsDir -Label 'NSIS uninstall log'
Copy-IfExists -Src "$env:TEMP\nsis-install-go-mapi.log" -DestDir $logsDir -Label 'NSIS install log'

New-EvidenceManifest -EvidenceDir $EvidenceDir

Write-Host "[collect] done. Files under $EvidenceDir are ready for the host-side review."
