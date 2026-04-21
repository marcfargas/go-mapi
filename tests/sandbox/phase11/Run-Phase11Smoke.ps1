# Run-Phase11Smoke.ps1
#
# Phase 11 clean-machine smoke bootstrap. Runs inside Windows Sandbox as the
# LogonCommand defined in go-mapi-phase11.wsb. Its job is to exercise the full
# v3.0 user journey end-to-end with the smallest possible human tail.
#
# Flow (fully automated except where [HUMAN] is flagged):
#   1. Unblock mapped-folder scripts so PSSecurityException never fires.
#   2. Create timestamped evidence dir under the mapped folder.
#   3. Resolve the installer under test. The ONLY acceptable source is a
#      pre-staged installer at C:\phase11\installer\go-mapi-setup.exe (staged
#      on the host by `build-rc.ps1` or a workflow_dispatch dry-run artifact).
#      There is NO fallback to releases/latest/download/ — that URL serves
#      whatever is the latest PUBLISHED release, which during v3.0 pre-GA is
#      still the v2.1.x installer. Using it would silently smoke-test the wrong
#      binary.
#   4. Silent install (`/S`).
#   5. Launch the app from its Start Menu shortcut.
#   6. [HUMAN] Complete OAuth consent in the browser window the app opens.
#      Script polls app.log for "oauth: signed in as" to detect completion.
#   7. Auto-trigger a MAPI call via `mailto:` (Windows routes this through
#      whatever is registered as the default mail client — that is now go-mapi).
#   8. Verify the queue JSON file appeared in %TEMP%\go-mapi\.
#   9. [HUMAN] Click "Create draft" in the go-mapi window. Script polls app.log
#      for "gmail: draft created id=" to detect completion.
#  10. [HUMAN] Glance at Gmail Drafts to confirm the draft actually appeared.
#      Script prompts for y/n and records the answer in evidence.
#  11. Auto silent-uninstall via `<InstallDir>\uninstall.exe /S`.
#  12. Verify clean uninstall: HKLM mail-client key gone, ProgramFiles dir gone.
#  13. Write 11-SMOKE-EVIDENCE.md with step-by-step PASS/FAIL + screenshot refs.
#
# Everything except the three [HUMAN] steps is scripted. D-14/D-16 accept a
# short manual tail; these three are irreducible (OAuth consent, UI click,
# visual Gmail confirmation).

[CmdletBinding()]
param(
    [string]$StagedInstaller = 'C:\phase11\installer\go-mapi-setup.exe',
    [string]$MappedRoot      = 'C:\phase11',
    [int]$OAuthWaitSeconds   = 300,
    [int]$DraftWaitSeconds   = 120,
    [switch]$NoHumanPrompts
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-IsoStamp { (Get-Date).ToString('yyyyMMdd-HHmmss') }

function Write-StepLog {
    param([string]$Level, [string]$Message)
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

function Unblock-MappedScripts {
    # Mapped-folder files inherit a Zone.Internet MOTW that triggers
    # PSSecurityException even when ExecutionPolicy=Bypass is set, depending
    # on host settings. Strip it for every .ps1 under the mapped root.
    Get-ChildItem -LiteralPath $MappedRoot -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch {} }
}

function New-EvidenceDir {
    param([string]$Root)
    $dir = Join-Path $Root "evidence-$(Get-IsoStamp)"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    foreach ($sub in 'screenshots', 'logs') {
        New-Item -ItemType Directory -Path (Join-Path $dir $sub) -Force | Out-Null
    }
    $dir
}

function Save-Screenshot {
    param([string]$OutPath, [string]$Label)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $gfx.Dispose(); $bmp.Dispose()
        Write-StepLog INFO "Screenshot saved: $OutPath ($Label)"
    } catch { Write-StepLog WARN "Screenshot failed ($Label): $_" }
}

function Resolve-Installer {
    param([string]$Staged)
    if (-not (Test-Path -LiteralPath $Staged)) {
        throw @"
No v3.0 installer staged. Expected at:
    $Staged

The $Staged path must contain a locally-built or workflow_dispatch-produced
v3.0 installer BEFORE the sandbox runs. Do NOT fall back to
releases/latest/download/go-mapi-setup.exe — that serves whichever release is
currently published (v2.1.x during v3.0 pre-GA), and smoking the wrong version
is worse than no smoke at all.

To stage from the host:
    pwsh -File build-rc.ps1                    # build locally (requires NSIS)
  OR
    gh run download --name go-mapi-setup-unsigned \
        -D tests\sandbox\phase11\installer       # from dispatch dry-run

Then re-launch the sandbox.
"@
    }
    Write-StepLog INFO "Installer: $Staged"
    (Resolve-Path -LiteralPath $Staged).ProviderPath
}

function Install-GoMapi {
    param([string]$SetupExe, [string]$LogDir)
    Write-StepLog INFO "Silent install: $SetupExe /S"
    $proc = Start-Process -FilePath $SetupExe -ArgumentList '/S' -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $LogDir 'installer-stdout.log') `
        -RedirectStandardError  (Join-Path $LogDir 'installer-stderr.log')
    Write-StepLog INFO "Installer exit=$($proc.ExitCode)"
    if ($proc.ExitCode -ne 0) { throw "Silent install failed (exit $($proc.ExitCode))" }
}

function Launch-App {
    $shortcut = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\go-mapi.lnk"
    if (-not (Test-Path -LiteralPath $shortcut)) {
        Write-StepLog WARN "Start Menu shortcut missing: $shortcut"
        return $null
    }
    Write-StepLog INFO "Launching app from Start Menu"
    Start-Process -FilePath $shortcut | Out-Null
    # Wait for app process to appear, up to 15s.
    for ($i = 0; $i -lt 30; $i++) {
        $p = Get-Process -Name 'go-mapi' -ErrorAction SilentlyContinue
        if ($p) { Write-StepLog INFO "App process PID=$($p.Id)"; return $p }
        Start-Sleep -Milliseconds 500
    }
    Write-StepLog WARN 'App process did not appear within 15s'
    $null
}

function Get-AppLogPath { Join-Path $env:APPDATA 'go-mapi\app.log' }

function Wait-ForLogLine {
    param(
        [string]$Pattern,
        [int]$TimeoutSeconds,
        [string]$Label
    )
    $log = Get-AppLogPath
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-StepLog INFO "Waiting (max ${TimeoutSeconds}s) for: $Label"
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $log) {
            $hit = Select-String -LiteralPath $log -Pattern $Pattern -SimpleMatch -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($hit) { Write-StepLog INFO "Matched '$Label' at $log line $($hit.LineNumber)"; return $true }
        }
        Start-Sleep -Seconds 2
    }
    Write-StepLog WARN "Timeout waiting for: $Label"
    $false
}

function Trigger-MapiSend {
    # `Start-Process "mailto:..."` goes through ShellExecuteEx, which resolves
    # via HKLM\SOFTWARE\Clients\Mail (set by the installer to go-mapi). The
    # MAPI DLL then writes JSON to %TEMP%\go-mapi\ and the watcher picks it up.
    $target = 'mailto:phase11-smoke@example.com?subject=Phase%2011%20smoke%20test&body=Automated%20smoke%20message%20from%20sandbox.'
    Write-StepLog INFO "Triggering MAPI send via mailto: handler"
    Start-Process $target
}

function Wait-ForQueueFile {
    param([int]$TimeoutSeconds = 15)
    $queueDir = Join-Path $env:TEMP 'go-mapi'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $queueDir) {
            $json = Get-ChildItem -LiteralPath $queueDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($json) { Write-StepLog INFO "Queue JSON appeared: $($json.FullName)"; return $json.FullName }
        }
        Start-Sleep -Milliseconds 500
    }
    Write-StepLog WARN 'No queue JSON appeared within timeout'
    $null
}

function Uninstall-GoMapi {
    $uninst = 'C:\Program Files\go-mapi\uninstall.exe'
    if (-not (Test-Path -LiteralPath $uninst)) {
        Write-StepLog WARN "Uninstaller not found at $uninst"
        return $false
    }
    Write-StepLog INFO "Silent uninstall: $uninst /S"
    $proc = Start-Process -FilePath $uninst -ArgumentList '/S' -Wait -PassThru
    Write-StepLog INFO "Uninstaller exit=$($proc.ExitCode)"
    $proc.ExitCode -eq 0
}

function Test-CleanUninstall {
    $residual = @()
    if (Test-Path 'C:\Program Files\go-mapi') {
        $left = Get-ChildItem 'C:\Program Files\go-mapi' -Recurse -ErrorAction SilentlyContinue
        if ($left) { $residual += "C:\Program Files\go-mapi still exists ($($left.Count) items)" }
    }
    $hklm = 'HKLM:\SOFTWARE\Clients\Mail\go-mapi'
    if (Test-Path $hklm) { $residual += "$hklm still exists" }
    $aumid = 'HKCR:\com.marcfargas.gomapi'
    if (Test-Path $aumid) { $residual += "$aumid still exists (AUMID)" }
    if ($residual) { Write-StepLog WARN "Residual after uninstall: $($residual -join '; ')" }
    else           { Write-StepLog INFO 'No residual: clean uninstall confirmed' }
    , $residual
}

function Prompt-Human {
    param([string]$Message, [string]$Default = 'y')
    if ($NoHumanPrompts) { return $Default }
    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Yellow
    Write-Host " HUMAN: $Message" -ForegroundColor Yellow
    Write-Host '================================================================' -ForegroundColor Yellow
    $resp = Read-Host "[$Default]"
    if (-not $resp) { $resp = $Default }
    $resp
}

function Write-EvidenceLedger {
    param(
        [string]$EvidenceDir,
        [hashtable]$Results
    )
    $dest = Join-Path $MappedRoot '..\..\..\..\..\planning\phases\11-autoupdate-release\11-SMOKE-EVIDENCE.md'
    # The mapped folder is the host's tests/sandbox/phase11 — the ledger lives two
    # levels up in .planning. We write a COPY into the evidence dir (always safe)
    # and let the human copy-paste into the canonical 11-SMOKE-EVIDENCE.md.
    $copy = Join-Path $EvidenceDir 'EVIDENCE.md'
    $stamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    $lines = @(
        '# Phase 11 smoke evidence (sandbox auto-generated)',
        '',
        "- Run at: $stamp",
        "- Evidence dir: $EvidenceDir",
        "- Installer: $($Results.InstallerPath)",
        "- Installer SHA256: $($Results.InstallerSha256)",
        '',
        '## Outcomes',
        ''
        "| Step | Outcome |"
        "|------|---------|"
    )
    foreach ($k in @('install','launch','oauth','mapi','queue','draft','gmail','uninstall','clean')) {
        $v = $Results[$k]
        if (-not $v) { $v = '(not run)' }
        $lines += "| $k | $v |"
    }
    $lines += ''
    $lines += '## Final verdict'
    $lines += ''
    $lines += "- Overall: $($Results.Verdict)"
    $lines += ''
    $lines += 'Copy this block into .planning/phases/11-autoupdate-release/11-SMOKE-EVIDENCE.md on the host.'
    Set-Content -LiteralPath $copy -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    Write-StepLog INFO "Evidence ledger written: $copy"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Unblock-MappedScripts

$script:EvidenceDir = New-EvidenceDir -Root $MappedRoot
$script:LogFile     = Join-Path $script:EvidenceDir 'logs\harness.log'
New-Item -ItemType File -Path $script:LogFile -Force | Out-Null

Write-StepLog INFO 'Phase 11 smoke harness starting'
Write-StepLog INFO "Evidence: $script:EvidenceDir"

$results = @{
    install = $null; launch = $null; oauth = $null; mapi = $null; queue = $null
    draft = $null; gmail = $null; uninstall = $null; clean = $null
    InstallerPath = $null; InstallerSha256 = $null; Verdict = 'PENDING'
}

try {
    $setupExe = Resolve-Installer -Staged $StagedInstaller
    $results.InstallerPath = $setupExe
    $results.InstallerSha256 = (Get-FileHash -LiteralPath $setupExe -Algorithm SHA256).Hash

    Save-Screenshot -OutPath (Join-Path $script:EvidenceDir 'screenshots\01-pre-install.png') -Label 'pre-install'

    Install-GoMapi -SetupExe $setupExe -LogDir (Join-Path $script:EvidenceDir 'logs')
    $results.install = 'PASS'
    Save-Screenshot -OutPath (Join-Path $script:EvidenceDir 'screenshots\02-post-install.png') -Label 'post-install'

    $proc = Launch-App
    if ($proc) {
        $results.launch = 'PASS'
        Save-Screenshot -OutPath (Join-Path $script:EvidenceDir 'screenshots\03-launched.png') -Label 'launched'
    } else {
        $results.launch = 'FAIL (process not detected)'
        throw 'App did not launch'
    }

    # ---- HUMAN: OAuth consent ----
    Prompt-Human 'Complete Google OAuth consent in the browser window the app opened. Press ENTER once the app shows the signed-in state.' | Out-Null
    $oauthOk = Wait-ForLogLine -Pattern 'oauth: signed in as' -TimeoutSeconds $OAuthWaitSeconds -Label 'OAuth sign-in'
    $results.oauth = if ($oauthOk) { 'PASS' } else { 'FAIL (timeout waiting for oauth: signed in as)' }
    Save-Screenshot -OutPath (Join-Path $script:EvidenceDir 'screenshots\04-signed-in.png') -Label 'signed-in'
    if (-not $oauthOk) { throw 'OAuth sign-in never completed' }

    # ---- AUTO: MAPI trigger ----
    Trigger-MapiSend
    $results.mapi = 'PASS (mailto: dispatched)'

    $queuePath = Wait-ForQueueFile -TimeoutSeconds 15
    $results.queue = if ($queuePath) { "PASS ($queuePath)" } else { 'FAIL (no queue JSON)' }
    Save-Screenshot -OutPath (Join-Path $script:EvidenceDir 'screenshots\05-queue-row.png') -Label 'queue-row'

    # ---- HUMAN: click Create draft in the go-mapi window ----
    Prompt-Human 'Click "Create draft" on the queue row in the go-mapi window. Press ENTER after the row clears.' | Out-Null
    $draftOk = Wait-ForLogLine -Pattern 'gmail: draft created id=' -TimeoutSeconds $DraftWaitSeconds -Label 'draft created'
    $results.draft = if ($draftOk) { 'PASS' } else { 'FAIL (timeout waiting for gmail: draft created id=)' }
    Save-Screenshot -OutPath (Join-Path $script:EvidenceDir 'screenshots\06-draft-created.png') -Label 'draft-created'

    # ---- HUMAN: Gmail glance ----
    $gmailResp = Prompt-Human 'Open Gmail Drafts in your browser and confirm the draft appeared. [y]/n' 'y'
    $results.gmail = if ($gmailResp -match '^(y|yes)$') { 'PASS (human confirmed)' } else { 'FAIL (human reported missing)' }

    # ---- AUTO: uninstall ----
    $uninstOk = Uninstall-GoMapi
    $results.uninstall = if ($uninstOk) { 'PASS' } else { 'FAIL' }
    Save-Screenshot -OutPath (Join-Path $script:EvidenceDir 'screenshots\07-post-uninstall.png') -Label 'post-uninstall'

    $residual = Test-CleanUninstall
    $results.clean = if ($residual.Count -eq 0) { 'PASS' } else { "FAIL ($($residual -join '; '))" }

    $allPass = @('install','launch','oauth','mapi','queue','draft','gmail','uninstall','clean') |
        ForEach-Object { $results[$_] } | Where-Object { $_ -notmatch '^PASS' } | Measure-Object
    $results.Verdict = if ($allPass.Count -eq 0) { 'PASS' } else { 'FAIL' }
}
catch {
    Write-StepLog ERROR "Harness failed: $_"
    $results.Verdict = 'ABORTED'
}
finally {
    # Snapshot the app log for post-mortem.
    $appLog = Get-AppLogPath
    if (Test-Path -LiteralPath $appLog) {
        Copy-Item -LiteralPath $appLog -Destination (Join-Path $script:EvidenceDir 'logs\app.log') -Force -ErrorAction SilentlyContinue
    }
    Write-EvidenceLedger -EvidenceDir $script:EvidenceDir -Results $results
    Write-StepLog INFO "Verdict: $($results.Verdict)"
    Write-StepLog INFO "Copy $($script:EvidenceDir)\EVIDENCE.md into 11-SMOKE-EVIDENCE.md on host."
}
