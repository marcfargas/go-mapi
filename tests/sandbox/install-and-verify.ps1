# install-and-verify.ps1 - In-sandbox runner for REL-02 full install -> verify -> uninstall flow
# Runs inside the Windows Sandbox as SYSTEM via `wsb exec`.
# Preconditions: C:\go-mapi is the project folder (read-only share), C:\output is writable.
# The installer MUST have been compiled already - this script does NOT run iscc.exe.
# Compile go-mapi-setup.exe on the HOST first (outside the sandbox) via
#   iscc.exe /DGOMAPIVersion=2.0.0-local src/installer/go-mapi.iss
# The resulting src/installer/dist/go-mapi-setup.exe is read through the C:\go-mapi share.

$ErrorActionPreference = "Stop"
$OutputFile = "C:\output\install-and-verify.log"
$InstallerPath = "C:\go-mapi\src\installer\dist\go-mapi-setup.exe"

function Log($msg) {
    Write-Host $msg
    Add-Content -Path $OutputFile -Value $msg
}

"" | Set-Content $OutputFile
Log "=== REL-02 Install + Verify + Uninstall ==="
Log "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log ""

# Step 1: Verify the pre-built installer is present on the share
Log "[1/6] Checking installer exists..."
if (-not (Test-Path $InstallerPath)) {
    Log "FAILED: $InstallerPath not found. Compile it first on the host with:"
    Log "  iscc.exe /DGOMAPIVersion=2.0.0-local src\installer\go-mapi.iss"
    exit 1
}
Log "OK: Found $InstallerPath"
Log "  Size: $((Get-Item $InstallerPath).Length) bytes"

# Step 2: Silent install
Log ""
Log "[2/6] Running silent install (/VERYSILENT /SUPPRESSMSGBOXES)..."
$proc = Start-Process -FilePath $InstallerPath -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/LOG=C:\output\inno-install.log" -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Log "FAILED: Installer exit code $($proc.ExitCode). See C:\output\inno-install.log"
    exit 1
}
Log "OK: Installer exit code 0"

# Step 3: Verify HKLM registry keys
Log ""
Log "[3/6] Verifying HKLM registry keys..."
$expectedKeys = @(
    "HKLM:\SOFTWARE\Clients\Mail\go-mapi",
    "HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host",
    "HKLM:\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host",
    "HKLM:\SOFTWARE\Chromium\NativeMessagingHosts\com.gomapi.host",
    "HKLM:\SOFTWARE\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.gomapi.host",
    "HKLM:\SOFTWARE\Vivaldi\NativeMessagingHosts\com.gomapi.host"
)
$regFail = $false
foreach ($key in $expectedKeys) {
    if (Test-Path $key) {
        Log "  OK: $key"
    } else {
        Log "  FAILED: $key missing"
        $regFail = $true
    }
}
if ($regFail) { Log "FAILED: one or more registry keys missing"; exit 1 }
Log "OK: all 6 registry keys present"

# Step 4: Verify files on disk
Log ""
Log "[4/6] Verifying installed files..."
# previous-mail-client.json is only created by the installer's [Code]
# section when a prior default mail client exists on the machine. Clean
# sandbox runs have none, so we don't assert its presence here. The
# post-uninstall check at step 6 already excludes it for the same reason.
$expectedFiles = @(
    "$env:ProgramFiles\go-mapi\go-mapi.dll",
    "$env:ProgramFiles\go-mapi\go-mapi-host.exe",
    "$env:ProgramData\go-mapi\com.gomapi.host.json"
)
$fileFail = $false
foreach ($f in $expectedFiles) {
    if (Test-Path $f) {
        Log "  OK: $f"
    } else {
        Log "  FAILED: $f missing"
        $fileFail = $true
    }
}
if ($fileFail) { Log "FAILED: one or more files missing"; exit 1 }
Log "OK: all 3 files present"

# Step 5: Silent uninstall
Log ""
Log "[5/6] Running silent uninstall..."
$uninst = "$env:ProgramFiles\go-mapi\unins000.exe"
if (-not (Test-Path $uninst)) {
    Log "FAILED: uninstaller not found at $uninst"
    exit 1
}
$proc = Start-Process -FilePath $uninst -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/LOG=C:\output\inno-uninstall.log" -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Log "FAILED: Uninstaller exit code $($proc.ExitCode)"
    exit 1
}
Log "OK: Uninstaller exit code 0"

# Step 6: Verify clean state after uninstall
Log ""
Log "[6/6] Verifying clean post-uninstall state..."
$stillPresent = @()
foreach ($key in $expectedKeys) {
    if (Test-Path $key) { $stillPresent += "registry: $key" }
}
foreach ($f in @("$env:ProgramFiles\go-mapi\go-mapi.dll",
                 "$env:ProgramFiles\go-mapi\go-mapi-host.exe",
                 "$env:ProgramData\go-mapi\com.gomapi.host.json")) {
    if (Test-Path $f) { $stillPresent += "file: $f" }
}
if ($stillPresent.Count -gt 0) {
    Log "FAILED: post-uninstall state not clean:"
    foreach ($s in $stillPresent) { Log "  $s" }
    exit 1
}
Log "OK: post-uninstall state clean"

Log ""
Log "=== REL-02 FULL FLOW PASSED ==="
exit 0
