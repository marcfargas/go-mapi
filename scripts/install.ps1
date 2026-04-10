#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs or uninstalls go-mapi.

.DESCRIPTION
    One-liner installer/uninstaller for go-mapi. Downloads the latest release
    (or a specific version) from GitHub, installs binaries, registers the MAPI
    handler, and sets up native messaging for Chrome, Chromium, and Edge.

    Install (fully automated):
      irm https://raw.githubusercontent.com/marcfargas/go-mapi/main/scripts/install.ps1 | iex

    Uninstall:
      .\install.ps1 -Uninstall

.PARAMETER Uninstall
    Remove go-mapi: deletes registry entries, restores previous mail client,
    removes installed files.

.PARAMETER ExtensionId
    Chrome/Edge extension ID (32 lowercase letters). If not provided and not in
    -Unattended mode, the script will auto-detect or prompt interactively.

.PARAMETER Version
    Specific version to install (e.g., "v0.1.0"). Defaults to "latest".

.PARAMETER InstallDir
    Target directory. Defaults to "C:\Program Files\go-mapi".

.PARAMETER Local
    Install from local build artifacts instead of downloading from GitHub.
    Searches the repo build output directories automatically.

.PARAMETER BuildDir
    When used with -Local, specifies the directory containing built artifacts.

.PARAMETER Unattended
    Silent install mode. Auto-detects extension ID, suppresses prompts, logs to file.
    Exits with error code if requirements not met. Suitable for automation/CI.

.PARAMETER KeepFiles
    When used with -Uninstall, only removes registry entries but keeps files.

.PARAMETER LogFile
    Path to log file. Defaults to $InstallDir\install.log

.EXAMPLE
    # Interactive install (auto-detects extension ID)
    irm https://raw.githubusercontent.com/marcfargas/go-mapi/main/scripts/install.ps1 | iex

.EXAMPLE
    # Non-interactive install
    .\install.ps1 -ExtensionId "abcdefghijklmnopqrstuvwxyz123456"

.EXAMPLE
    # Unattended install (for automation)
    .\install.ps1 -Unattended

.EXAMPLE
    # Developer: install from local build
    .\install.ps1 -ExtensionId "abc..." -Local

.EXAMPLE
    # Uninstall
    .\install.ps1 -Uninstall
#>

param(
    [switch]$Uninstall,
    [string]$ExtensionId,
    [string]$Version = "latest",
    [string]$InstallDir = "C:\Program Files\go-mapi",
    [switch]$Local,
    [string]$BuildDir,
    [switch]$Unattended,
    [switch]$KeepFiles,
    [string]$LogFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$GH_REPO = "marcfargas/go-mapi"
$Script:LogPath = if ($LogFile) { $LogFile } else { Join-Path $InstallDir "install.log" }

# --- Logging ---

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "[$timestamp] [$Level] $Msg"
    
    # Ensure log directory exists
    $logDir = Split-Path $Script:LogPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    Add-Content -Path $Script:LogPath -Value $logMsg -ErrorAction SilentlyContinue
}

function Write-Step { 
    param([string]$Msg) 
    Write-Host "  [+] $Msg" -ForegroundColor Green 
    Write-Log $Msg "INFO"
}

function Write-Info { 
    param([string]$Msg) 
    Write-Host "  [i] $Msg" -ForegroundColor Cyan 
    Write-Log $Msg "INFO"
}

function Write-Warn { 
    param([string]$Msg) 
    Write-Host "  [!] $Msg" -ForegroundColor Yellow 
    Write-Log $Msg "WARN"
}

function Write-Skip { 
    param([string]$Msg) 
    Write-Host "  [-] $Msg" -ForegroundColor DarkGray 
    Write-Log $Msg "INFO"
}

function Write-ErrorLog {
    param([string]$Msg)
    Write-Host "  [ERROR] $Msg" -ForegroundColor Red
    Write-Log $Msg "ERROR"
}

# --- Manifest template rendering ---

# Render-ManifestTemplate reads a native-messaging manifest .tmpl file and
# performs literal string substitution of the HOST_PATH and EXTENSION_ID
# placeholders. Uses the PowerShell String.Replace() method (NOT the -replace
# regex operator) because:
#   1. The double-brace placeholder tokens contain regex metacharacters.
#   2. Windows paths contain backslashes, which regex substitution would try
#      to interpret as escape sequences.
# String.Replace() performs literal substring replacement with zero escaping.
function Render-ManifestTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$ExtensionId
    )

    if ([string]::IsNullOrWhiteSpace($TemplatePath)) {
        throw "Render-ManifestTemplate: TemplatePath is null or empty"
    }
    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        throw "Render-ManifestTemplate: InstallDir is null or empty"
    }
    if ([string]::IsNullOrWhiteSpace($ExtensionId)) {
        throw "Render-ManifestTemplate: ExtensionId is null or empty"
    }
    if (-not (Test-Path $TemplatePath)) {
        throw "Render-ManifestTemplate: template not found at $TemplatePath"
    }

    Write-Log "Rendering manifest template: $TemplatePath" "INFO"

    # Build placeholder tokens programmatically to avoid any PowerShell brace
    # expansion ambiguity in the script source itself.
    $openToken = '{' + '{'
    $closeToken = '}' + '}'
    $hostPathPlaceholder = $openToken + 'HOST_PATH' + $closeToken
    $extensionIdPlaceholder = $openToken + 'EXTENSION_ID' + $closeToken

    $hostExePath = (Join-Path $InstallDir "go-mapi-host.exe")

    # JSON escape: backslashes in Windows paths must be doubled so the
    # rendered file is valid JSON. We do this BEFORE the literal .Replace()
    # because .Replace() performs raw substring insertion — the template
    # has no idea whether the substituted value needs escaping. The
    # equivalent Phase 3 Inno Setup installer will need to apply the same
    # transformation in its Pascal Script.
    $hostExePathJson = $hostExePath.Replace('\', '\\').Replace('"', '\"')

    # Get-Content -Raw returns a single string preserving line endings.
    $template = Get-Content -Raw -Path $TemplatePath

    # Literal substring replacement via String.Replace() — no regex escaping.
    $rendered = $template.Replace($hostPathPlaceholder, $hostExePathJson).Replace($extensionIdPlaceholder, $ExtensionId)

    # Validate the rendered content is parseable JSON before returning.
    try {
        $null = $rendered | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Render-ManifestTemplate: rendered template is not valid JSON. Template: $TemplatePath. Error: $($_.Exception.Message)"
    }

    return $rendered
}

$browsers = @(
    @{ Name = "Chrome";   Path = "HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.gomapi.host" },
    @{ Name = "Chromium"; Path = "HKCU:\Software\Chromium\NativeMessagingHosts\com.gomapi.host" },
    @{ Name = "Edge";     Path = "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host" }
)

# --- Prerequisites Check ---

function Test-Prerequisites {
    Write-Log "Checking prerequisites" "INFO"
    
    # Windows version
    $osVersion = [System.Environment]::OSVersion.Version
    if ($osVersion.Major -lt 10) {
        Write-ErrorLog "Windows 10 or later required (detected: Windows $($osVersion.Major).$($osVersion.Minor))"
        return $false
    }
    Write-Log "OS: Windows $($osVersion.Major).$($osVersion.Minor) OK" "INFO"
    
    # PowerShell version
    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -lt 5) {
        Write-ErrorLog "PowerShell 5.0 or later required (detected: $psVersion)"
        return $false
    }
    Write-Log "PowerShell: $psVersion OK" "INFO"
    
    # Admin rights (already enforced by #Requires but let's log it)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-ErrorLog "Administrator privileges required"
        return $false
    }
    Write-Log "Running as Administrator: OK" "INFO"
    
    return $true
}

# --- Auto-detect Extension ID ---

function Get-InstalledExtensionIds {
    Write-Log "Auto-detecting extension IDs" "INFO"
    $foundIds = @()
    
    # Chrome profile paths
    $chromePaths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Profile 1\Extensions"
    )
    
    # Edge profile paths
    $edgePaths = @(
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Extensions",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Profile 1\Extensions"
    )
    
    $allPaths = $chromePaths + $edgePaths
    
    foreach ($path in $allPaths) {
        if (Test-Path $path) {
            $extensions = Get-ChildItem -Path $path -Directory -ErrorAction SilentlyContinue
            foreach ($ext in $extensions) {
                if ($ext.Name -match '^[a-z]{32}$') {
                    # Check if it has a manifest (to verify it's installed)
                    $versions = Get-ChildItem -Path $ext.FullName -Directory -ErrorAction SilentlyContinue
                    if ($versions) {
                        $manifestPath = Join-Path $versions[0].FullName "manifest.json"
                        if (Test-Path $manifestPath) {
                            # Try to read manifest to check if it's go-mapi
                            try {
                                $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
                                if ($manifest.name -eq "go-mapi") {
                                    Write-Log "Found go-mapi extension: $($ext.Name)" "INFO"
                                    $foundIds += $ext.Name
                                }
                            } catch {
                                # Not JSON or can't read, skip
                            }
                        }
                    }
                }
            }
        }
    }
    
    return @($foundIds | Select-Object -Unique)
}

# ============================================================
#  UNINSTALL
# ============================================================

if ($Uninstall) {
    Write-Host ""
    Write-Host "  go-mapi uninstaller" -ForegroundColor White
    Write-Host "  ========================================" -ForegroundColor DarkGray
    Write-Log "=== UNINSTALL STARTED ===" "INFO"

    # Read install metadata if available
    $metadataPath = Join-Path $InstallDir ".install-metadata.json"
    $metadata = $null
    if (Test-Path $metadataPath) {
        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        Write-Info "Found installation: $($metadata.version) (installed $($metadata.installedAt))"
    } else {
        Write-Info "Install dir: $InstallDir"
    }
    Write-Host ""

    # --- Step 1: Remove native messaging registrations ---

    Write-Host "  Step 1: Remove browser registrations" -ForegroundColor White

    foreach ($browser in $browsers) {
        if (Test-Path $browser.Path) {
            Remove-Item -Path $browser.Path -Force
            Write-Step "Removed $($browser.Name) registration"
        } else {
            Write-Skip "$($browser.Name) not registered"
        }
    }

    # --- Step 2: Remove MAPI registry entries ---

    Write-Host ""
    Write-Host "  Step 2: Remove MAPI registration" -ForegroundColor White

    $mailClientsPath = "HKLM:\SOFTWARE\Clients\Mail"
    $goMapiRegPath   = "$mailClientsPath\go-mapi"

    $currentDefault = $null
    try {
        $currentDefault = (Get-ItemProperty -Path $mailClientsPath -Name "(Default)" -ErrorAction SilentlyContinue).'(Default)'
    } catch { }

    if (Test-Path $goMapiRegPath) {
        Remove-Item -Path $goMapiRegPath -Recurse -Force
        Write-Step "Removed registry key: $goMapiRegPath"
    } else {
        Write-Skip "MAPI registry key not found"
    }

    # Restore previous default mail client
    if ($currentDefault -eq "go-mapi") {
        $previousDefault = $null

        # Try backup file first
        $backupFile = Join-Path $InstallDir ".previous-mail-client"
        if (Test-Path $backupFile) {
            $previousDefault = (Get-Content $backupFile -Raw).Trim()
        }
        # Try metadata
        elseif ($metadata -and $metadata.previousClient) {
            $previousDefault = $metadata.previousClient
        }

        if ($previousDefault -and (Test-Path "$mailClientsPath\$previousDefault")) {
            Set-ItemProperty -Path $mailClientsPath -Name "(Default)" -Value $previousDefault -Force
            Write-Step "Restored default mail client: $previousDefault"
        } else {
            # Auto-detect common clients
            $fallbacks = @("Microsoft Outlook", "Outlook", "Windows Mail")
            $restored = $false
            foreach ($fallback in $fallbacks) {
                if (Test-Path "$mailClientsPath\$fallback") {
                    Set-ItemProperty -Path $mailClientsPath -Name "(Default)" -Value $fallback -Force
                    Write-Step "Restored default mail client: $fallback (auto-detected)"
                    $restored = $true
                    break
                }
            }
            if (-not $restored) {
                Set-ItemProperty -Path $mailClientsPath -Name "(Default)" -Value "" -Force
                Write-Warn "No previous mail client found — cleared default"
            }
        }
    } else {
        Write-Info "Default mail client is '$currentDefault' (not go-mapi, leaving unchanged)"
    }

    # --- Step 3: Remove files ---

    Write-Host ""
    Write-Host "  Step 3: Remove files" -ForegroundColor White

    if ($KeepFiles) {
        Write-Info "KeepFiles specified — skipping file removal"
    } elseif (Test-Path $InstallDir) {
        $fileCount = (Get-ChildItem -Path $InstallDir -Force).Count
        Remove-Item -Path $InstallDir -Recurse -Force
        Write-Step "Removed $InstallDir ($fileCount files)"
    } else {
        Write-Skip "Install directory not found"
    }

    # --- Done ---

    Write-Host ""
    Write-Host "  ========================================" -ForegroundColor DarkGray
    Write-Host "  go-mapi uninstalled" -ForegroundColor Green
    Write-Log "=== UNINSTALL COMPLETED ===" "INFO"
    Write-Host ""

    exit 0
}

# ============================================================
#  INSTALL
# ============================================================

function Get-LatestRelease {
    $url = "https://api.github.com/repos/$GH_REPO/releases/latest"
    try {
        $release = Invoke-RestMethod -Uri $url -Headers @{ Accept = "application/vnd.github.v3+json" }
        return $release
    } catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-ErrorLog "No releases found at $url. Is the repository public?"
        }
        throw
    }
}

function Get-SpecificRelease {
    param([string]$Tag)
    $url = "https://api.github.com/repos/$GH_REPO/releases/tags/$Tag"
    try {
        return Invoke-RestMethod -Uri $url -Headers @{ Accept = "application/vnd.github.v3+json" }
    } catch {
        Write-ErrorLog "Release '$Tag' not found at $url"
        throw
    }
}

function Download-Asset {
    param([string]$Url, [string]$OutPath, [string]$Name)
    Write-Host "      Downloading $Name..." -NoNewline
    Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing
    $size = [math]::Round((Get-Item $OutPath).Length / 1KB)
    Write-Host " ${size}KB" -ForegroundColor DarkGray
    Write-Log "Downloaded $Name (${size}KB)" "INFO"
}

function Find-LocalArtifact {
    param([string]$FileName, [string[]]$SearchPaths)
    foreach ($dir in $SearchPaths) {
        $path = Join-Path $dir $FileName
        if (Test-Path $path) { return $path }
    }
    return $null
}

# --- Banner ---

Write-Host ""
Write-Host "  go-mapi installer" -ForegroundColor White
Write-Host "  ========================================" -ForegroundColor DarkGray
Write-Log "=== INSTALL STARTED ===" "INFO"

# --- Check prerequisites ---

if (-not (Test-Prerequisites)) {
    Write-Host ""
    Write-ErrorLog "Prerequisites check failed. See log: $Script:LogPath"
    exit 1
}

# --- Check if already installed ---

$metadataPath = Join-Path $InstallDir ".install-metadata.json"
$existingInstall = $null
if (Test-Path $metadataPath) {
    try {
        $existingInstall = Get-Content $metadataPath -Raw | ConvertFrom-Json
        Write-Host ""
        Write-Warn "go-mapi is already installed (version: $($existingInstall.version))"
        Write-Info "This will upgrade/reinstall go-mapi"
        
        if (-not $Unattended) {
            $continue = Read-Host "  Continue? (Y/n)"
            if ($continue -eq "n" -or $continue -eq "N") {
                Write-Host ""
                Write-Info "Installation cancelled"
                exit 0
            }
        }
    } catch {
        Write-Warn "Could not read existing installation metadata"
    }
}

# --- Auto-detect or prompt for Extension ID ---

if (-not $ExtensionId) {
    $detectedIds = @(Get-InstalledExtensionIds)  # Force array
    
    if ($detectedIds -and $detectedIds.Count -eq 1) {
        $ExtensionId = $detectedIds[0]
        Write-Host ""
        Write-Step "Auto-detected extension ID: $ExtensionId"
    }
    elseif ($detectedIds -and $detectedIds.Count -gt 1) {
        Write-Host ""
        Write-Info "Multiple go-mapi extensions found:"
        for ($i = 0; $i -lt $detectedIds.Count; $i++) {
            Write-Host "    $($i + 1). $($detectedIds[$i])"
        }
        
        if ($Unattended) {
            # In unattended mode, use the first one
            $ExtensionId = $detectedIds[0]
            Write-Info "Unattended mode: using first ID: $ExtensionId"
        } else {
            $selection = Read-Host "  Select extension (1-$($detectedIds.Count)) or enter custom ID"
            if ($selection -match '^\d+$' -and [int]$selection -le $detectedIds.Count) {
                $ExtensionId = $detectedIds[[int]$selection - 1]
            } else {
                $ExtensionId = $selection
            }
        }
    }
    else {
        # No extensions found
        if ($Unattended) {
            Write-ErrorLog "No go-mapi extension detected. Install extension first or provide -ExtensionId"
            exit 1
        }
        
        Write-Host ""
        Write-Info "No go-mapi extension detected in browser profiles"
        Write-Host ""
        Write-Host "  You need to install the extension first:" -ForegroundColor Cyan
        Write-Host "    Chrome: https://chrome.google.com/webstore/detail/go-mapi/[ID-HERE]" -ForegroundColor Gray
        Write-Host "    Edge:   https://microsoftedge.microsoft.com/addons/detail/go-mapi/[ID-HERE]" -ForegroundColor Gray
        Write-Host ""
        Write-Info "Or enter the extension ID manually (find at chrome://extensions with Developer mode ON)."
        Write-Host ""
        $ExtensionId = Read-Host "  Extension ID (32 chars, or press Enter to skip)"
        
        if (-not $ExtensionId) {
            Write-Host ""
            Write-Warn "No extension ID provided. Installation will continue, but you'll need to"
            Write-Warn "re-run this installer with -ExtensionId after installing the extension."
            Write-Host ""
            if (-not $Unattended) {
                $continue = Read-Host "  Continue anyway? (Y/n)"
                if ($continue -eq "n" -or $continue -eq "N") {
                    exit 0
                }
            }
            $ExtensionId = "PLACEHOLDER_EXTENSION_ID_32CHR"
        }
    }
}

if ($ExtensionId -ne "PLACEHOLDER_EXTENSION_ID_32CHR" -and $ExtensionId -notmatch '^[a-z]{32}$') {
    Write-ErrorLog "Invalid extension ID: '$ExtensionId'. Must be 32 lowercase letters (from chrome://extensions)."
    exit 1
}

Write-Host ""
Write-Info "Install dir:  $InstallDir"
Write-Info "Extension ID: $ExtensionId"
Write-Log "Extension ID: $ExtensionId" "INFO"

# --- Resolve repo root (used by -Local mode for both artifact discovery and
#     manifest template rendering). Safe to compute unconditionally; only
#     consumed when $Local is set.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($scriptDir) {
    $repoRoot = Split-Path -Parent $scriptDir
} else {
    # Script was loaded from memory (e.g. irm | iex) — no on-disk path.
    $repoRoot = $null
}

# --- Acquire artifacts ---

$tempDir = Join-Path $env:TEMP "go-mapi-install-$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    if ($Local) {
        # --- Local mode: find build artifacts ---
        Write-Host ""
        Write-Host "  Step 1: Locate build artifacts" -ForegroundColor White

        if (-not $repoRoot) {
            Write-ErrorLog "Local mode requires the installer to be invoked from a file path (not piped from memory)."
            exit 1
        }

        if ($BuildDir) {
            $searchPaths = @($BuildDir)
        } else {
            $searchPaths = @(
                (Join-Path $repoRoot "src\interceptor\build\bin"),
                (Join-Path $repoRoot "src\native-host\build"),
                (Join-Path $repoRoot "build"),
                (Join-Path $repoRoot "dist")
            )
        }

        $dllSource = Find-LocalArtifact "go-mapi.dll" $searchPaths
        $hostSource = Find-LocalArtifact "go-mapi-host.exe" $searchPaths

        if (-not $dllSource) {
            Write-ErrorLog "go-mapi.dll not found. Run 'npm run build:interceptor' first.`nSearched: $($searchPaths -join ', ')"
            exit 1
        }
        if (-not $hostSource) {
            Write-ErrorLog "go-mapi-host.exe not found. Run 'npm run build:native-host' first.`nSearched: $($searchPaths -join ', ')"
            exit 1
        }

        Write-Step "Found DLL:  $dllSource"
        Write-Step "Found Host: $hostSource"

        $dllArtifact = $dllSource
        $hostArtifact = $hostSource
        $installedVersion = "local-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    } else {
        # --- Download mode: fetch from GitHub releases ---
        Write-Host ""
        Write-Host "  Step 1: Fetch release from GitHub" -ForegroundColor White

        if ($Version -eq "latest") {
            $release = Get-LatestRelease
        } else {
            $release = Get-SpecificRelease -Tag $Version
        }

        $tag = $release.tag_name
        Write-Step "Release: $tag ($($release.published_at.ToString('yyyy-MM-dd')))"
        Write-Log "Downloading release: $tag" "INFO"

        # Find assets
        $dllAsset  = $release.assets | Where-Object { $_.name -eq "go-mapi.dll" }
        $hostAsset = $release.assets | Where-Object { $_.name -eq "go-mapi-host.exe" }

        if (-not $dllAsset) { 
            Write-ErrorLog "Release $tag is missing go-mapi.dll asset"
            exit 1
        }
        if (-not $hostAsset) { 
            Write-ErrorLog "Release $tag is missing go-mapi-host.exe asset"
            exit 1
        }

        # Download
        $dllArtifact = Join-Path $tempDir "go-mapi.dll"
        $hostArtifact = Join-Path $tempDir "go-mapi-host.exe"

        Download-Asset -Url $dllAsset.browser_download_url  -OutPath $dllArtifact  -Name "go-mapi.dll"
        Download-Asset -Url $hostAsset.browser_download_url -OutPath $hostArtifact -Name "go-mapi-host.exe"

        Write-Step "Downloaded $([math]::Round(($dllAsset.size + $hostAsset.size) / 1KB))KB total"

        $installedVersion = $tag
    }

    # --- Step 2: Install files ---

    Write-Host ""
    Write-Host "  Step 2: Install files" -ForegroundColor White

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        Write-Step "Created: $InstallDir"
    }

    Copy-Item -Path $dllArtifact  -Destination (Join-Path $InstallDir "go-mapi.dll")      -Force
    Copy-Item -Path $hostArtifact -Destination (Join-Path $InstallDir "go-mapi-host.exe")  -Force
    Write-Step "Installed go-mapi.dll"
    Write-Step "Installed go-mapi-host.exe"

    # --- Step 3: Register MAPI handler ---

    Write-Host ""
    Write-Host "  Step 3: Register MAPI handler" -ForegroundColor White

    $mailClientsPath = "HKLM:\SOFTWARE\Clients\Mail"
    $goMapiRegPath   = "$mailClientsPath\go-mapi"
    $dllInstallPath  = Join-Path $InstallDir "go-mapi.dll"

    # Back up current default mail client
    $previousDefault = $null
    try {
        $previousDefault = (Get-ItemProperty -Path $mailClientsPath -Name "(Default)" -ErrorAction SilentlyContinue).'(Default)'
    } catch { }

    if ($previousDefault -and $previousDefault -ne "go-mapi") {
        $previousDefault | Out-File -FilePath (Join-Path $InstallDir ".previous-mail-client") -Encoding UTF8 -NoNewline
        Write-Info "Backed up previous default: $previousDefault"
    }

    # Register — DLLPath must be a VALUE on the key (not a subkey).
    # This is how mapi32.dll stub finds the actual MAPI DLL to load.
    New-Item -Path $goMapiRegPath -Force | Out-Null
    New-ItemProperty -Path $goMapiRegPath -Name "(Default)" -Value "go-mapi" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $goMapiRegPath -Name "DLLPath" -Value $dllInstallPath -PropertyType String -Force | Out-Null

    Set-ItemProperty -Path $mailClientsPath -Name "(Default)" -Value "go-mapi" -Force

    Write-Step "Registered MAPI handler"
    Write-Step "Set as default mail client"

    # --- Step 4: Native messaging ---

    Write-Host ""
    Write-Host "  Step 4: Register native messaging" -ForegroundColor White

    $manifestPath = Join-Path $InstallDir "com.gomapi.host.json"

    if ($Local -and $repoRoot) {
        # Local mode: render the canonical .tmpl file via literal string
        # substitution. This is the same template that Phase 3's Inno Setup
        # installer will consume via Pascal Script StringChange, so the
        # schema lives in exactly one place.
        $templatePath = Join-Path $repoRoot 'src\native-host\manifests\com.gomapi.host.chrome.json.tmpl'
        if (-not (Test-Path $templatePath)) {
            throw "Manifest template not found: $templatePath"
        }

        $rendered = Render-ManifestTemplate -TemplatePath $templatePath -InstallDir $InstallDir -ExtensionId $ExtensionId
        Set-Content -Path $manifestPath -Value $rendered -Encoding UTF8 -NoNewline
        Write-Step "Rendered manifest from template: $manifestPath"
    } else {
        # Download mode (irm | iex): the script is running from memory with
        # no repo checkout, so we cannot read the .tmpl file. Fall back to
        # inline hashtable construction.
        #
        # CANONICAL SCHEMA: src/native-host/manifests/com.gomapi.host.chrome.json.tmpl
        # The inline hashtable below MUST stay schema-equivalent to that
        # template (same keys, same values modulo placeholder substitution).
        # Any schema change must update BOTH this hashtable AND the .tmpl
        # file. In Local mode, the template file is consumed directly.
        $manifest = @{
            name            = "com.gomapi.host"
            description     = "go-mapi Native Messaging Host"
            path            = (Join-Path $InstallDir "go-mapi-host.exe")
            type            = "stdio"
            allowed_origins = @("chrome-extension://$ExtensionId/")
        } | ConvertTo-Json -Depth 10

        $manifest | Out-File -FilePath $manifestPath -Encoding UTF8
        Write-Step "Created manifest: $manifestPath"
    }

    foreach ($browser in $browsers) {
        $parentPath = Split-Path $browser.Path
        if (-not (Test-Path $parentPath)) {
            New-Item -Path $parentPath -Force | Out-Null
        }
        New-Item -Path $browser.Path -Force | Out-Null
        Set-ItemProperty -Path $browser.Path -Name "(Default)" -Value $manifestPath
        Write-Step "Registered $($browser.Name)"
    }

    # --- Save install metadata ---

    @{
        version         = $installedVersion
        installDir      = $InstallDir
        extensionId     = $ExtensionId
        installedAt     = (Get-Date -Format "o")
        previousClient  = $previousDefault
        installedBy     = $env:USERNAME
        computerName    = $env:COMPUTERNAME
    } | ConvertTo-Json -Depth 10 | Out-File -FilePath (Join-Path $InstallDir ".install-metadata.json") -Encoding UTF8

    # --- Done ---

    Write-Host ""
    Write-Host "  ========================================" -ForegroundColor DarkGray
    Write-Host "  Installed go-mapi $installedVersion" -ForegroundColor Green
    Write-Log "=== INSTALL COMPLETED: $installedVersion ===" "INFO"
    Write-Host ""
    Write-Host "  Install dir:      $InstallDir" -ForegroundColor White
    Write-Host "  MAPI DLL:         $dllInstallPath" -ForegroundColor Gray
    Write-Host "  Native host:      $(Join-Path $InstallDir 'go-mapi-host.exe')" -ForegroundColor Gray
    Write-Host "  Default client:   go-mapi" -ForegroundColor Gray
    if ($previousDefault -and $previousDefault -ne "go-mapi") {
        Write-Host "  Previous client:  $previousDefault (backed up)" -ForegroundColor DarkGray
    }
    Write-Host ""
    
    if ($ExtensionId -eq "PLACEHOLDER_EXTENSION_ID_32CHR") {
        Write-Host "  ⚠ IMPORTANT: Extension not detected!" -ForegroundColor Yellow
        Write-Host "    1. Install the extension from Chrome Web Store" -ForegroundColor Yellow
        Write-Host "    2. Re-run this installer to register native messaging" -ForegroundColor Yellow
        Write-Host ""
    }
    
    Write-Host "  Next steps:" -ForegroundColor Cyan
    if ($ExtensionId -ne "PLACEHOLDER_EXTENSION_ID_32CHR") {
        Write-Host "    1. Open the go-mapi extension in your browser"
        Write-Host "    2. Sign in with your Google account"
        Write-Host "    3. Right-click a file → Send to → Mail recipient"
    } else {
        Write-Host "    1. Install go-mapi extension from Chrome Web Store"
        Write-Host "    2. Run: .\install.ps1 -ExtensionId <your-extension-id>"
    }
    Write-Host ""
    Write-Host "  Log file: $Script:LogPath" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  To uninstall:" -ForegroundColor DarkGray
    Write-Host "    .\install.ps1 -Uninstall" -ForegroundColor DarkGray
    Write-Host ""

    exit 0

} catch {
    Write-Host ""
    Write-ErrorLog "Installation failed: $($_.Exception.Message)"
    Write-Host "  See log for details: $Script:LogPath" -ForegroundColor Red
    Write-Log "EXCEPTION: $($_.Exception.ToString())" "ERROR"
    Write-Log "=== INSTALL FAILED ===" "ERROR"
    Write-Host ""
    exit 1
} finally {
    # Clean up temp dir
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
