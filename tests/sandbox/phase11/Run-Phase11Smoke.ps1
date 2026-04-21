# Run-Phase11Smoke.ps1
#
# Phase 11 clean-machine smoke bootstrap. Runs inside Windows Sandbox as the
# LogonCommand defined in go-mapi-phase11.wsb. Its job is to:
#
#   1. Prepare a timestamped evidence directory under the mapped folder so that
#      screenshots, videos, and logs survive sandbox teardown and land back on
#      the host filesystem.
#   2. Stage the installer under test. Source of truth (in order of preference):
#        a) A release-candidate installer pre-staged at C:\phase11\installer\go-mapi-setup.exe
#           by the human before launching the sandbox (used when a workflow_dispatch
#           dry-run built the artifact but the release is not yet published).
#        b) The stable public asset URL
#           https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe
#           (used for the pre-GA rehearsal against the latest published v3 release).
#   3. Run the installer silently to the point where the Start Menu shortcut exists,
#      capture a screenshot, and LAUNCH the app so the human can complete the
#      manual tail (sign in, MAPI trigger, queue, Gmail draft, uninstall).
#   4. Seed 11-SMOKE-EVIDENCE.md with the harness run metadata so the human only
#      has to append per-step outcomes.
#
# DO NOT extend this script to automate OAuth consent, MAPI shell triggering, or
# Gmail API assertions. Phase 11 D-14 + D-16 accept a short manual tail - the
# goal is reproducibility + evidence, not hands-free automation.

[CmdletBinding()]
param(
    [string]$InstallerSource = $env:GOMAPI_PHASE11_INSTALLER_SOURCE,
    [string]$InstallerUrl    = 'https://github.com/marcfargas/go-mapi/releases/latest/download/go-mapi-setup.exe',
    [string]$StagedInstaller = 'C:\phase11\installer\go-mapi-setup.exe',
    [string]$MappedRoot      = 'C:\phase11',
    [switch]$SkipLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Get-IsoStamp {
    return (Get-Date).ToString('yyyyMMdd-HHmmss')
}

function Write-StepLog {
    param([string]$Level, [string]$Message)
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
}

function New-EvidenceDir {
    param([string]$Root)
    $stamp = Get-IsoStamp
    $dir = Join-Path -Path $Root -ChildPath "evidence-$stamp"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'screenshots') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'video')       -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'logs')        -Force | Out-Null
    return $dir
}

function Resolve-InstallerPath {
    # Preference order: explicit -InstallerSource > staged file > latest-download URL.
    # The caller (human) can populate C:\phase11\installer\go-mapi-setup.exe before
    # launching sandbox if they're testing a workflow_dispatch dry-run artifact.
    param(
        [string]$Explicit,
        [string]$Staged,
        [string]$Url,
        [string]$EvidenceDir
    )

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) {
            Write-StepLog INFO "Using explicit installer path: $Explicit"
            return (Resolve-Path -LiteralPath $Explicit).ProviderPath
        }
        Write-StepLog WARN "Explicit installer path does not exist: $Explicit - falling back"
    }

    if (Test-Path -LiteralPath $Staged) {
        Write-StepLog INFO "Using pre-staged installer (workflow_dispatch dry-run artifact?): $Staged"
        return (Resolve-Path -LiteralPath $Staged).ProviderPath
    }

    $dest = Join-Path $EvidenceDir 'go-mapi-setup.exe'
    Write-StepLog INFO "Downloading stable installer: $Url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing
    if (-not (Test-Path -LiteralPath $dest)) {
        throw "Installer download failed: $Url -> $dest"
    }
    Write-StepLog INFO "Downloaded installer to: $dest"
    return $dest
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
        $gfx.Dispose()
        $bmp.Dispose()
        Write-StepLog INFO "Screenshot saved: $OutPath ($Label)"
    } catch {
        Write-StepLog WARN "Screenshot failed: $Label :: $_"
    }
}

function Install-GoMapi {
    param([string]$SetupExe, [string]$LogPath)
    Write-StepLog INFO "Launching installer silently: $SetupExe"
    # NSIS silent: /S is the supported switch. We do NOT pass /D= here because
    # the Phase 10 installer already picks the correct default (per-machine).
    $proc = Start-Process -FilePath $SetupExe -ArgumentList '/S' -Wait -PassThru `
        -RedirectStandardOutput (Join-Path (Split-Path $LogPath) 'installer-stdout.log') `
        -RedirectStandardError  (Join-Path (Split-Path $LogPath) 'installer-stderr.log')
    Write-StepLog INFO "Installer exit code: $($proc.ExitCode)"
    if ($proc.ExitCode -ne 0) {
        throw "Silent install failed (exit $($proc.ExitCode)). See installer-stderr.log."
    }
}

function Launch-App {
    $shortcut = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\go-mapi.lnk"
    if (-not (Test-Path -LiteralPath $shortcut)) {
        Write-StepLog WARN "Start Menu shortcut not found, nothing to launch: $shortcut"
        return
    }
    Write-StepLog INFO "Launching app from Start Menu shortcut"
    Start-Process -FilePath $shortcut | Out-Null
    Start-Sleep -Seconds 5
}

function Write-EvidenceHeader {
    param([string]$EvidenceDir, [string]$SetupExe, [string]$InstallerSource)
    $stamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
    $lines = @(
        '## Harness run metadata (auto-generated by Run-Phase11Smoke.ps1)',
        '',
        "- Evidence dir: $EvidenceDir",
        "- Installer path: $SetupExe",
        "- Installer source mode: $InstallerSource",
        "- Sandbox host: $env:COMPUTERNAME",
        "- Started at: $stamp",
        '',
        'The human tail MUST fill per-step outcomes in 11-SMOKE-EVIDENCE.md on the host.'
    )
    $lines -join [Environment]::NewLine | Set-Content -LiteralPath (Join-Path $EvidenceDir 'harness-metadata.md') -Encoding UTF8
}

# --- main ---

$script:EvidenceDir = New-EvidenceDir -Root $MappedRoot
$script:LogFile     = Join-Path $script:EvidenceDir 'logs\harness.log'
New-Item -ItemType File -Path $script:LogFile -Force | Out-Null

Write-StepLog INFO "Phase 11 smoke harness starting"
Write-StepLog INFO "Evidence directory: $script:EvidenceDir"

$sourceMode = if ($InstallerSource) {
    'explicit'
} elseif (Test-Path -LiteralPath $StagedInstaller) {
    'staged-workflow_dispatch-artifact'
} else {
    'releases/latest/download/go-mapi-setup.exe'
}
Write-StepLog INFO "Installer source mode: $sourceMode"

$setupExe = Resolve-InstallerPath -Explicit $InstallerSource -Staged $StagedInstaller -Url $InstallerUrl -EvidenceDir $script:EvidenceDir

Save-Screenshot -OutPath (Join-Path $script:EvidenceDir 'screenshots\01-pre-install.png') -Label 'pre-install'
Install-GoMapi -SetupExe $setupExe -LogPath $script:LogFile
Save-Screenshot -OutPath (Join-Path $script:EvidenceDir 'screenshots\02-post-install.png') -Label 'post-install'

if (-not $SkipLaunch) {
    Launch-App
    Save-Screenshot -OutPath (Join-Path $script:EvidenceDir 'screenshots\03-app-launched.png') -Label 'app-launched'
}

Write-EvidenceHeader -EvidenceDir $script:EvidenceDir -SetupExe $setupExe -InstallerSource $sourceMode

Write-StepLog INFO "Harness automated portion complete."
Write-StepLog INFO "Next: human must complete the manual tail - see 11-SMOKE-CHECKLIST.md"
Write-StepLog INFO "Evidence dir (on host via mapped folder): $script:EvidenceDir"
