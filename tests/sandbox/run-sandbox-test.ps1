# run-sandbox-test.ps1 - Orchestrate Windows Sandbox DLL test via CLI
# Usage: .\run-sandbox-test.ps1 [-SetupOnly] [-RegistrationOnly] [-FullTest]

param(
    [switch]$SetupOnly,        # Just run setup (install WinAppDriver)
    [switch]$RegistrationOnly, # Just test DLL registration
    [switch]$FullTest,         # Run full test with UI automation
    [switch]$KeepRunning       # Don't stop sandbox when done
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot | Split-Path | Split-Path  # Go up to project root

Write-Host "=== Windows Sandbox DLL Test ===" -ForegroundColor Cyan
Write-Host "Project root: $ProjectRoot"

# Check if WSB CLI is available
$wsbPath = Get-Command wsb -ErrorAction SilentlyContinue
if (-not $wsbPath) {
    Write-Host "ERROR: wsb CLI not found. Requires Windows 11 24H2+" -ForegroundColor Red
    exit 1
}

# Check for existing sandbox
# Separate stderr from stdout so non-JSON diagnostics (first-run banners,
# telemetry notices, update nags) don't break the ConvertFrom-Json parse
# under $ErrorActionPreference = "Stop". See WR-02 in 05-REVIEW.md.
try {
    $listOutput = wsb list --raw 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($listOutput)) {
        $existing = $null
    } else {
        $existing = $listOutput | ConvertFrom-Json -ErrorAction Stop
    }
} catch {
    Write-Host "WARNING: Could not parse 'wsb list --raw' output: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Continuing -- assuming no existing sandbox." -ForegroundColor Yellow
    $existing = $null
}

if ($existing -and $existing.WindowsSandboxEnvironments.Count -gt 0) {
    Write-Host "WARNING: Existing sandbox found. Stopping it..." -ForegroundColor Yellow
    foreach ($sb in $existing.WindowsSandboxEnvironments) {
        wsb stop --id $sb.Id 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 2
}

# Start sandbox (no config - we'll share folder separately)
Write-Host "`n[1/4] Starting Windows Sandbox..."
# Defensive JSON parse: same pattern as 'wsb list --raw' above. See WR-02.
try {
    $startRaw = wsb start --raw 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($startRaw)) {
        Write-Host "ERROR: 'wsb start --raw' exited with code $LASTEXITCODE and no output" -ForegroundColor Red
        exit 1
    }
    $startResult = $startRaw | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host "ERROR: Could not parse 'wsb start --raw' output: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Raw output: $startRaw" -ForegroundColor Red
    exit 1
}
if (-not $startResult.Id) {
    Write-Host "ERROR: Failed to start sandbox" -ForegroundColor Red
    Write-Host $startResult
    exit 1
}
$sandboxId = $startResult.Id
Write-Host "OK: Sandbox started with ID: $sandboxId" -ForegroundColor Green

# Share project folder (read-only)
Write-Host "`n[2/4] Sharing project folder..."
wsb share --id $sandboxId --host-path $ProjectRoot --sandbox-path "C:\go-mapi" 2>&1 | Out-Null
Write-Host "OK: Shared $ProjectRoot -> C:\go-mapi (read-only)" -ForegroundColor Green

# Create and share output folder (writable)
$OutputFolder = Join-Path $env:TEMP "go-mapi-sandbox-output"
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
wsb share --id $sandboxId --host-path $OutputFolder --sandbox-path "C:\output" --allow-write 2>&1 | Out-Null
Write-Host "OK: Shared $OutputFolder -> C:\output (writable)" -ForegroundColor Green

# Wait for sandbox to be ready
Write-Host "Waiting for sandbox to initialize..."
Start-Sleep -Seconds 5

# Function to execute command in sandbox
function Invoke-SandboxCommand {
    param(
        [string]$Command,
        [string]$Description,
        [switch]$AllowFailure
    )
    Write-Host "`n> $Description"
    $result = wsb exec --id $sandboxId --command $Command --run-as System --raw 2>&1 | ConvertFrom-Json
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        Write-Host "FAILED: Exit code $($result.ExitCode)" -ForegroundColor Red
        return $false
    }
    Write-Host "OK: Exit code $($result.ExitCode)" -ForegroundColor Green
    return $true
}

# Test DLL registration
Write-Host "`n[3/4] Testing DLL registration..."
$regSuccess = Invoke-SandboxCommand `
    -Command "powershell -ExecutionPolicy Bypass -File C:\go-mapi\tests\sandbox\test-dll-registration.ps1" `
    -Description "DLL registration test"

# Retrieve and display the test output from writable share
$logFile = Join-Path $OutputFolder "registration-test.log"
Write-Host "`n--- Test Output ---"
if (Test-Path $logFile) {
    Get-Content $logFile
} else {
    Write-Host "(No output file found at $logFile)"
}
Write-Host "--- End Output ---"

if (-not $regSuccess) {
    Write-Host "`n=== DLL REGISTRATION TEST FAILED ===" -ForegroundColor Red
    if (-not $KeepRunning) {
        wsb stop --id $sandboxId 2>&1 | Out-Null
    }
    exit 1
}

if ($RegistrationOnly) {
    Write-Host "`n=== DLL REGISTRATION TEST PASSED ===" -ForegroundColor Green
    if (-not $KeepRunning) {
        Write-Host "Stopping sandbox..."
        wsb stop --id $sandboxId 2>&1 | Out-Null
    } else {
        Write-Host "Sandbox left running. ID: $sandboxId"
    }
    exit 0
}

# Run setup (WinAppDriver install)
if ($SetupOnly -or $FullTest) {
    Write-Host "`n[4/4] Running setup (WinAppDriver)..."
    $setupSuccess = Invoke-SandboxCommand `
        -Command "powershell -ExecutionPolicy Bypass -File C:\go-mapi\tests\sandbox\setup.ps1" `
        -Description "WinAppDriver setup"

    # Display setup output
    $setupLog = Join-Path $OutputFolder "setup.log"
    Write-Host "`n--- Setup Output ---"
    if (Test-Path $setupLog) {
        Get-Content $setupLog
    } else {
        Write-Host "(No setup log found)"
    }
    Write-Host "--- End Output ---"
}

if ($SetupOnly) {
    Write-Host "`n=== SETUP COMPLETE ===" -ForegroundColor Cyan
    if (-not $KeepRunning) {
        Write-Host "Stopping sandbox..."
        wsb stop --id $sandboxId 2>&1 | Out-Null
    } else {
        Write-Host "Sandbox left running. ID: $sandboxId"
    }
    exit 0
}

# Full test: install -> verify -> uninstall round-trip (REL-02)
if ($FullTest) {
    Write-Host "`n[5/5] Running REL-02 install -> verify -> uninstall flow..." -ForegroundColor Cyan

    # Sanity check: the host-side Inno Setup compile must have happened already
    $hostInstaller = Join-Path $ProjectRoot 'src\installer\dist\go-mapi-setup.exe'
    if (-not (Test-Path $hostInstaller)) {
        Write-Host "ERROR: $hostInstaller not found." -ForegroundColor Red
        Write-Host "Compile it on the host first:" -ForegroundColor Yellow
        Write-Host '  & "C:\Program Files (x86)\Inno Setup 6\iscc.exe" /DGOMAPIVersion=2.0.0-local src\installer\go-mapi.iss' -ForegroundColor Yellow
        if (-not $KeepRunning) { wsb stop --id $sandboxId 2>&1 | Out-Null }
        exit 1
    }
    Write-Host "OK: Found $hostInstaller ($((Get-Item $hostInstaller).Length) bytes)" -ForegroundColor Green

    $fullSuccess = Invoke-SandboxCommand `
        -Command "powershell -ExecutionPolicy Bypass -File C:\go-mapi\tests\sandbox\install-and-verify.ps1" `
        -Description "Install-and-verify round-trip"

    # Retrieve the script log
    $fullLog = Join-Path $OutputFolder "install-and-verify.log"
    Write-Host "`n--- Install+Verify Output ---"
    if (Test-Path $fullLog) {
        Get-Content $fullLog
    } else {
        Write-Host "(No install-and-verify.log found at $fullLog)"
    }
    Write-Host "--- End Output ---"

    if (-not $fullSuccess) {
        Write-Host "`n=== REL-02 FULL TEST FAILED ===" -ForegroundColor Red
        if (-not $KeepRunning) { wsb stop --id $sandboxId 2>&1 | Out-Null }
        exit 1
    }
    Write-Host "`n=== REL-02 FULL TEST PASSED ===" -ForegroundColor Green
}

# Cleanup
if (-not $KeepRunning) {
    Write-Host "`nStopping sandbox..."
    wsb stop --id $sandboxId 2>&1 | Out-Null
    Write-Host "OK: Sandbox stopped" -ForegroundColor Green
} else {
    Write-Host "`nSandbox left running. ID: $sandboxId"
    Write-Host "To stop: wsb stop --id $sandboxId"
    Write-Host "To connect: wsb connect --id $sandboxId"
}

Write-Host "`n=== TEST COMPLETE ===" -ForegroundColor Green
