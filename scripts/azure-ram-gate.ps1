<#
.SYNOPSIS
    Phase 7 RAM gate — Azure orchestration for go-mapi WebView2 RAM measurement.

.DESCRIPTION
    Provisions an ephemeral Windows Server 2022 Datacenter VM (Standard_D4s_v3) in a
    fresh Azure resource group, installs WebView2 runtime, creates N test users added to
    the Performance Log Users group, uploads the go-mapi binary, launches N concurrent
    in-VM scheduled-task sessions running measure-ram.ps1, pulls the CSV back to the dev
    machine, then destroys the resource group.

    Azure CLI + PowerShell only. No IaC state. No manual Hetzner provisioning.

.NOTES
    Per-session metric = SUM of go-mapi.exe Private WS + all msedgewebview2.exe child
    Private WS (correlated via Win32_Process.ParentProcessId == go-mapi.exe PID).
    See scripts/azure-ram-gate.README.md for full prerequisites and gotchas.
#>

[CmdletBinding()]
param(
    [int]    $N              = 5,
    [string] $SubscriptionId,
    [string] $Location       = 'westeurope',
    [string] $VmSize         = 'Standard_D4s_v3',
    [string] $RgName         = "rg-gomapi-ramgate-$([DateTime]::UtcNow.ToString('yyyyMMddHHmm'))",
    [string] $BinaryPath     = 'src/app/build/bin/go-mapi.exe',
    [string] $MeasureScript  = 'scripts/measure-ram.ps1',
    [string] $CsvOut         = 'docs/measurements/phase-07-ram-gate.csv',
    [switch] $Confirm,
    [switch] $KeepResourceGroup,
    [switch] $Smoke,
    [int]    $PollTimeoutMinutes = 60
)

# Smoke mode: fastest possible end-to-end pipeline validation.
# N=1, single iteration, 10s idle periods → ~2 min wall time.
# Use to verify provision/bootstrap/task/orchestrator chain works before committing
# to a full measurement run. Data produced is NOT the real gate result.
if ($Smoke) {
    $N = 1
    $PollTimeoutMinutes = 8
    Write-Host "  [SMOKE] overriding: N=1, PollTimeoutMinutes=8, worker uses short idles + 1 iter" -ForegroundColor Yellow
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -------- preflight --------
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($code, $msg) { Write-Error $msg; exit $code }

Write-Step "Preflight checks"

try {
    $azRaw = (az --version 2>$null | Out-String)
    if (-not $azRaw) { Fail 2 "Azure CLI not found. Install with: winget install Microsoft.AzureCLI" }
    $azVer = [regex]::Match($azRaw, 'azure-cli\s+([\d\.]+)').Groups[1].Value
    if (-not $azVer) { Fail 2 "Could not parse az CLI version from: $azRaw" }
    if ([version]$azVer -lt [version]'2.50') { Fail 2 "Azure CLI $azVer < 2.50 required." }
    Write-Host "  az CLI version: $azVer"
} catch {
    Fail 2 "Preflight failed parsing az --version: $_"
}

try {
    $acct = az account show --output json 2>$null | ConvertFrom-Json
    if (-not $acct) { Fail 2 "Not logged in. Run: az login" }
    Write-Host "  Signed in as: $($acct.user.name)  (subscription: $($acct.name))"
} catch {
    Fail 2 "az account show failed: $_"
}

if ($SubscriptionId) {
    Write-Step "Setting subscription $SubscriptionId"
    az account set --subscription $SubscriptionId | Out-Null
}

if (-not (Test-Path $BinaryPath)) { Fail 2 "Binary not found at $BinaryPath (run Plan 03 build first)." }
if (-not (Test-Path $MeasureScript)) { Fail 2 "measure-ram.ps1 not found at $MeasureScript" }

$costEstimate = [math]::Round(0.082 * 1 + (0.02 * $N), 2)  # VM hourly + per-session overhead rough
Write-Host ""
Write-Host "  Target: $VmSize in $Location"
Write-Host "  Sessions: N=$N"
Write-Host "  Resource group: $RgName"
Write-Host "  Estimated run cost: ~`$0.41 (N=5 reference) — scales with wall time, not N"
Write-Host ""

if (-not $Confirm) {
    Fail 2 "Refusing to proceed without -Confirm flag. Re-run with -Confirm once cost is accepted."
}

# -------- binary hash for verification --------
$binaryHash = (Get-FileHash -Path $BinaryPath -Algorithm SHA256).Hash
Write-Host "  Binary SHA256: $binaryHash"

# -------- provision --------
$vmName       = 'gomapi-ramgate'  # Windows computer name ≤15 chars
$adminUser    = 'gomapiadmin'
# Generate strong password (memory only, never persisted)
# Cryptographic RNG; works on pwsh 7 (System.Web unavailable on .NET Core).
function New-StrongPassword {
    param([int]$Length = 20, [int]$MinSpecial = 5)
    $upper   = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = [char[]]'abcdefghjkmnpqrstuvwxyz'
    $digits  = [char[]]'23456789'
    $special = [char[]]'!@#%^*()-_=+[]{}:,.?'
    $rng     = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf     = [byte[]]::new(1)
    $pick    = { param([char[]]$s) $rng.GetBytes($buf); $s[$buf[0] % $s.Length] }
    $chars   = @(
        & $pick $upper; & $pick $upper
        & $pick $lower; & $pick $lower
        & $pick $digits; & $pick $digits
    )
    for ($i = 0; $i -lt $MinSpecial; $i++) { $chars += & $pick $special }
    $all = $upper + $lower + $digits + $special
    while ($chars.Count -lt $Length) { $chars += & $pick $all }
    -join ($chars | Sort-Object { $rng.GetBytes($buf); $buf[0] })
}

$adminPass    = New-StrongPassword -Length 24 -MinSpecial 6
$userPasswords = @{}
for ($i = 1; $i -le $N; $i++) {
    $userPasswords["ramtest$i"] = New-StrongPassword -Length 20 -MinSpecial 5
}

try {
    Write-Step "Creating resource group $RgName"
    az group create --name $RgName --location $Location --output none
    # Emit RG name to stderr immediately so user sees it even if script dies later
    [Console]::Error.WriteLine("RESOURCE_GROUP=$RgName  (manual cleanup if script crashes: az group delete --name $RgName --yes --no-wait)")

    Write-Step "Creating Windows Server 2022 VM ($VmSize)"
    $vmCreate = az vm create `
        --resource-group $RgName `
        --name $vmName `
        --image 'MicrosoftWindowsServer:WindowsServer:2022-datacenter:latest' `
        --size $VmSize `
        --admin-username $adminUser `
        --admin-password $adminPass `
        --nsg-rule NONE `
        --public-ip-sku Standard `
        --output json 2>&1
    if ($LASTEXITCODE -ne 0) { Fail 3 "az vm create failed: $vmCreate" }
    Write-Host "  VM created."

    # -------- bootstrap via run-command --------
    Write-Step "Bootstrapping VM (users, Performance Log Users group, WebView2 runtime)"

    $userLines = foreach ($u in $userPasswords.Keys) {
        $p = $userPasswords[$u]
        @"
`$securePass = ConvertTo-SecureString '$p' -AsPlainText -Force
if (-not (Get-LocalUser -Name '$u' -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name '$u' -Password `$securePass -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Add-LocalGroupMember -Group 'Users' -Member '$u'
}
Add-LocalGroupMember -Group 'Performance Log Users' -Member '$u' -ErrorAction SilentlyContinue
# Assert membership -- fail loud if missing (silent failure would yield empty CSV)
`$m = Get-LocalGroupMember -Group 'Performance Log Users' -Member '$u' -ErrorAction SilentlyContinue
if (-not `$m) { throw "FATAL: user $u not in Performance Log Users group -- Win32_PerfRawData_PerfProc_Process would return empty" }
"@
    }

    $bootstrap = @"
`$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path C:\gomapi -Force | Out-Null
# Grant Users modify on C:\gomapi so ramtest* workers can write CSV fragments and flags
icacls C:\gomapi /grant 'Users:(OI)(CI)M' /T | Out-Null
$($userLines -join "`n")

# WebView2 Evergreen bootstrapper (silent install)
`$wvUrl = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'
`$wvExe = 'C:\gomapi\MicrosoftEdgeWebview2Setup.exe'
Invoke-WebRequest -Uri `$wvUrl -OutFile `$wvExe -UseBasicParsing
Start-Process -FilePath `$wvExe -ArgumentList '/silent','/install' -Wait

# Confirm WebView2 runtime present
`$wvKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
`$wvVer = (Get-ItemProperty -Path `$wvKey -ErrorAction Stop).pv
Write-Output "WEBVIEW2_VERSION=`$wvVer"
Set-Content -Path C:\gomapi\webview2-version.txt -Value `$wvVer

# Assertion: every ramtest user is in Performance Log Users
for (`$i = 1; `$i -le $N; `$i++) {
    `$u = "ramtest`$i"
    `$m = Get-LocalGroupMember -Group 'Performance Log Users' -Member `$u -ErrorAction SilentlyContinue
    if (-not `$m) { throw "ASSERT: `$u not in Performance Log Users" }
}
Write-Output 'BOOTSTRAP_OK'
"@

    $bootstrapFile = Join-Path $env:TEMP "ramgate-bootstrap-$RgName.ps1"
    Set-Content -Path $bootstrapFile -Value $bootstrap -Encoding UTF8

    $bootResult = az vm run-command invoke `
        --resource-group $RgName `
        --name $vmName `
        --command-id RunPowerShellScript `
        --scripts "@$bootstrapFile" `
        --output json 2>&1
    $bootResult = ($bootResult | Out-String)
    if ($LASTEXITCODE -ne 0) { Fail 4 "Bootstrap run-command failed: $bootResult" }
    if ($bootResult -notmatch 'BOOTSTRAP_OK') { Fail 4 "Bootstrap did not reach OK marker. Output:`n$bootResult" }
    Write-Host "  Bootstrap completed."

    # -------- upload binary --------
    Write-Step "Uploading go-mapi.exe to VM"
    $binBytes  = [System.IO.File]::ReadAllBytes((Resolve-Path $BinaryPath))
    $binB64    = [Convert]::ToBase64String($binBytes)
    $scriptCap = 30000  # run-command payload soft cap (~32 KB)

    if ($binB64.Length -lt $scriptCap) {
        $uploadScript = @"
`$b = '$binB64'
[System.IO.File]::WriteAllBytes('C:\gomapi\go-mapi.exe', [Convert]::FromBase64String(`$b))
`$h = (Get-FileHash -Path 'C:\gomapi\go-mapi.exe' -Algorithm SHA256).Hash
Write-Output "UPLOADED_SHA256=`$h"
"@
        $uploadFile = Join-Path $env:TEMP "ramgate-upload-$RgName.ps1"
        Set-Content -Path $uploadFile -Value $uploadScript -Encoding UTF8
        $upRes = az vm run-command invoke `
            --resource-group $RgName --name $vmName `
            --command-id RunPowerShellScript `
            --scripts "@$uploadFile" --output json 2>&1
        if ($LASTEXITCODE -ne 0) { Fail 4 "Binary inline upload failed: $upRes" }
        Write-Host "  Inline upload path (binary ≤ 30 KB base64)."
    } else {
        # Fallback: transient Storage Account + SAS
        Write-Host "  Inline payload too large ($($binB64.Length) chars) — falling back to Storage Account SAS."
        $saName = "gomapiram$(Get-Random -Minimum 1000 -Maximum 9999)"
        az storage account create --name $saName --resource-group $RgName --location $Location --sku Standard_LRS --output none
        $saKey = (az storage account keys list --resource-group $RgName --account-name $saName --query '[0].value' -o tsv)
        az storage container create --name drops --account-name $saName --account-key $saKey --output none
        az storage blob upload --account-name $saName --account-key $saKey --container-name drops --name go-mapi.exe --file $BinaryPath --output none
        $expiry = (Get-Date).AddHours(2).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $sas = az storage blob generate-sas --account-name $saName --account-key $saKey --container-name drops --name go-mapi.exe --permissions r --expiry $expiry -o tsv
        $sasUrl = "https://$saName.blob.core.windows.net/drops/go-mapi.exe?$sas"
        $sasScript = @"
Invoke-WebRequest -Uri '$sasUrl' -OutFile 'C:\gomapi\go-mapi.exe' -UseBasicParsing
`$h = (Get-FileHash -Path 'C:\gomapi\go-mapi.exe' -Algorithm SHA256).Hash
Write-Output "UPLOADED_SHA256=`$h"
"@
        $sasFile = Join-Path $env:TEMP "ramgate-sas-$RgName.ps1"
        Set-Content -Path $sasFile -Value $sasScript -Encoding UTF8
        $upRes = az vm run-command invoke --resource-group $RgName --name $vmName --command-id RunPowerShellScript --scripts "@$sasFile" --output json 2>&1
        if ($LASTEXITCODE -ne 0) { Fail 4 "SAS download run-command failed: $upRes" }
    }
    $upRes = ($upRes | Out-String)

    # Verify uploaded SHA matches
    if ($upRes -match 'UPLOADED_SHA256=([0-9A-Fa-f]{64})') {
        $remoteHash = $Matches[1]
        if ($remoteHash -ne $binaryHash) { Fail 4 "Binary SHA mismatch after upload: local=$binaryHash remote=$remoteHash" }
        Write-Host "  Binary SHA256 verified: $remoteHash"
    } else {
        Write-Warning "Could not parse UPLOADED_SHA256 from run-command output."
    }

    # -------- upload measure-ram.ps1 --------
    Write-Step "Uploading measure-ram.ps1 to VM"
    $msContent = Get-Content $MeasureScript -Raw
    $msB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($msContent))
    $msUpload = @"
`$b = '$msB64'
[System.IO.File]::WriteAllBytes('C:\gomapi\measure-ram.ps1', [Convert]::FromBase64String(`$b))
Write-Output 'MEASURE_SCRIPT_UPLOADED'
"@
    $msFile = Join-Path $env:TEMP "ramgate-measure-$RgName.ps1"
    Set-Content -Path $msFile -Value $msUpload -Encoding UTF8
    $msRes = az vm run-command invoke --resource-group $RgName --name $vmName --command-id RunPowerShellScript --scripts "@$msFile" --output json 2>&1
    if ($LASTEXITCODE -ne 0) { Fail 4 "measure-ram.ps1 upload failed: $msRes" }

    # -------- register per-user scheduled tasks (passing passwords) --------
    Write-Step "Registering per-user scheduled tasks inside VM"
    $taskLines = foreach ($u in $userPasswords.Keys) {
        $p = $userPasswords[$u]
        @"
`$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\gomapi\measure-ram.ps1 -Worker -User $u$(if ($Smoke) { " -Smoke" })'
`$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddYears(10))
`$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName 'gomapi-ramtest-$u' -Action `$action -Trigger `$trigger -Settings `$settings -User '$u' -Password '$p' -RunLevel Limited -Force | Out-Null
"@
    }

    $orchestrate = @"
`$ErrorActionPreference = 'Stop'
$($taskLines -join "`n")
# Kick the orchestrator (runs as admin) which will Start-ScheduledTask for all and wait on flags
Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\gomapi\measure-ram.ps1','-Orchestrate','-N','$N'$(if ($Smoke) { ",'-Smoke'" }) -WindowStyle Hidden
Write-Output 'ORCHESTRATOR_STARTED'
"@
    $orchFile = Join-Path $env:TEMP "ramgate-orch-$RgName.ps1"
    Set-Content -Path $orchFile -Value $orchestrate -Encoding UTF8
    $orchRes = az vm run-command invoke --resource-group $RgName --name $vmName --command-id RunPowerShellScript --scripts "@$orchFile" --output json 2>&1
    if ($LASTEXITCODE -ne 0) { Fail 4 "Orchestrator start failed: $orchRes" }

    # -------- poll for completion --------
    Write-Step "Polling for measurement-complete.flag (hard ${PollTimeoutMinutes}-min ceiling)"
    $pollScript = "if (Test-Path 'C:\gomapi\measurement-complete.flag') { Write-Output 'DONE' } else { Write-Output 'PENDING' }"
    $pollFile = Join-Path $env:TEMP "ramgate-poll-$RgName.ps1"
    Set-Content -Path $pollFile -Value $pollScript -Encoding UTF8
    $deadline = (Get-Date).AddMinutes($PollTimeoutMinutes)
    $complete = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 60
        $pres = az vm run-command invoke --resource-group $RgName --name $vmName --command-id RunPowerShellScript --scripts "@$pollFile" --output json 2>&1
        $pres = ($pres | Out-String)
        if ($pres -match 'DONE') { $complete = $true; break }
        Write-Host "  still measuring…  ($([math]::Round(($deadline - (Get-Date)).TotalMinutes,1)) min remaining)"
    }
    if (-not $complete) { Fail 5 "Measurement timeout — flag never appeared on VM." }
    Write-Host "  measurement-complete.flag seen."

    # -------- pull CSV --------
    Write-Step "Pulling CSV back from VM"
    $pullScript = "Get-Content 'C:\gomapi\phase-07-ram-gate.csv' -Raw"
    $pullFile = Join-Path $env:TEMP "ramgate-pull-$RgName.ps1"
    Set-Content -Path $pullFile -Value $pullScript -Encoding UTF8
    $pullRes = az vm run-command invoke --resource-group $RgName --name $vmName --command-id RunPowerShellScript --scripts "@$pullFile" --output json 2>&1
    $pullRes = ($pullRes | Out-String)
    if ($LASTEXITCODE -ne 0) { Fail 6 "CSV pull run-command failed: $pullRes" }
    # Always dump raw response to a diagnostic file so we can debug next failure.
    $diagFile = Join-Path $env:TEMP "ramgate-pull-response-$RgName.json"
    Set-Content -Path $diagFile -Value $pullRes -Encoding UTF8
    try {
        $pullJson = $pullRes | ConvertFrom-Json
        $csvText = (($pullJson.value | Where-Object { $_.code -like '*StdOut*' } | Select-Object -First 1).message)
    } catch {
        Fail 6 "Could not parse pull run-command JSON: $_`nRaw saved at: $diagFile"
    }
    if (-not $csvText -or $csvText -notmatch 'iteration.*session_user') {
        Fail 6 "Pulled CSV content looks wrong (no header row). Raw response saved at: $diagFile`nFirst 500 chars: $($csvText.Substring(0, [Math]::Min(500, $csvText.Length)))"
    }
    $csvDir = Split-Path -Parent $CsvOut
    if (-not (Test-Path $csvDir)) { New-Item -ItemType Directory -Path $csvDir -Force | Out-Null }
    Set-Content -Path $CsvOut -Value $csvText -Encoding UTF8 -NoNewline
    Write-Host "  CSV written to $CsvOut ($($csvText.Length) chars)"

    # Also pull webview2 version
    $wvPullScript = "Get-Content 'C:\gomapi\webview2-version.txt' -Raw"
    $wvFile = Join-Path $env:TEMP "ramgate-wv-$RgName.ps1"
    Set-Content -Path $wvFile -Value $wvPullScript -Encoding UTF8
    $wvRes = az vm run-command invoke --resource-group $RgName --name $vmName --command-id RunPowerShellScript --scripts "@$wvFile" --output json 2>&1
    $wvRes = ($wvRes | Out-String)
    if ($wvRes -match '([\d]+\.[\d]+\.[\d]+\.[\d]+)') {
        Write-Host "  WebView2 runtime version on VM: $($Matches[1])"
    }

} finally {
    if ($KeepResourceGroup) {
        Write-Warning "KeepResourceGroup set — NOT destroying $RgName. Manual cleanup required: az group delete --name $RgName --yes --no-wait"
    } else {
        Write-Step "Destroying resource group $RgName (cost control)"
        az group delete --name $RgName --yes --no-wait --output none 2>$null
        Write-Host "  az group delete issued (--no-wait). Confirm later with: az group show --name $RgName"
    }
}

Write-Host ""
Write-Host "DONE. CSV at: $CsvOut" -ForegroundColor Green
Write-Host "Binary SHA256: $binaryHash"
Write-Host "Next: run measure-ram.ps1 -Aggregate $CsvOut to summarise."
