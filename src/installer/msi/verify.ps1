[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MsiPath,
    [ValidateSet('system')][string]$SKU = 'system',
    [Parameter(Mandatory)][string]$PackageRelease,
    [switch]$RequireSignature
)

$ErrorActionPreference = 'Stop'
function Fail([string]$Message) { throw "Admin MSI verification failed: $Message" }
if (-not (Test-Path $MsiPath)) { Fail "missing MSI $MsiPath" }
if ($RequireSignature -and (Get-AuthenticodeSignature $MsiPath).Status -ne 'Valid') { Fail 'release MSI signature is not valid' }
$identityJSON = & go run ./internal/mapi/cmd/machine-package -- $SKU $PackageRelease 2>&1
if ($LASTEXITCODE -ne 0) { Fail "production package identity rejected the release: $identityJSON" }
$identity = $identityJSON | ConvertFrom-Json
if ([IO.Path]::GetFileName($MsiPath) -ne $identity.assetName) { Fail "MSI filename is not the immutable system asset name $($identity.assetName)" }

$installer = New-Object -ComObject WindowsInstaller.Installer
$database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @((Resolve-Path $MsiPath).Path, 0))
function Query([string]$Sql) {
    $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($Sql))
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    $rows = @()
    while ($true) {
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if (-not $record) { break }
        $rows += $record
    }
    return $rows
}
function Field($Record, [int]$Index) { $Record.GetType().InvokeMember('StringData', 'GetProperty', $null, $Record, @($Index)) }

$files = @(Query 'SELECT `FileName`,`Component_` FROM `File`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)" })
if (@($files | Where-Object { $_ -match '^go-mapi\.dll\|' }).Count -ne 2) { Fail 'MSI must contain exactly two interceptor DLL files' }
if (@($files | Where-Object { $_ -match '^go-mapi-service\.exe\|ResidentService$' }).Count -ne 1) { Fail 'MSI must contain exactly one resident service executable' }
if ($files -match '(?i)wails|webview') { Fail 'system MSI contains forbidden user-app payload' }

$properties = @{}
Query 'SELECT `Property`,`Value` FROM `Property`' | ForEach-Object { $properties[(Field $_ 1)] = (Field $_ 2) }
if ($properties.ProductCode.Trim('{}') -ne $identity.productCode -or $properties.ProductVersion -ne $identity.productVersion -or $properties.UpgradeCode.Trim('{}') -ne 'B3C97B33-3F10-47CA-9FA7-24EE3B75E325') { Fail 'compiled MSI identity does not match the production system identity' }

$services = @(Query 'SELECT `Name`,`DisplayName`,`ServiceType`,`StartType`,`ErrorControl`,`StartName`,`Arguments`,`Component_` FROM `ServiceInstall`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)|$(Field $_ 6)|$(Field $_ 7)|$(Field $_ 8)" })
if ($services.Count -ne 1 -or $services[0] -ne 'go-mapi|go-mapi system service|16|2|1|LocalSystem|service|ResidentService') { Fail "unexpected resident service contract: $($services -join ';')" }
$controls = @(Query 'SELECT `Name`,`Event`,`Wait`,`Component_` FROM `ServiceControl`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)" })
if ($controls.Count -ne 1 -or $controls[0] -ne 'go-mapi|305|1|ResidentService') { Fail "unexpected ServiceControl contract: $($controls -join ';')" }
$serviceConfig = @(Query 'SELECT `Name`,`Event`,`ConfigType`,`Argument`,`Component_` FROM `MsiServiceConfig`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)" })
if ($serviceConfig.Count -ne 2 -or $serviceConfig -notcontains 'go-mapi|3|3|1|ResidentService' -or $serviceConfig -notcontains 'go-mapi|3|5|1|ResidentService') { Fail "service is not delayed-auto-start with an unrestricted SID: $($serviceConfig -join ';')" }
$failureActions = @(Query 'SELECT `Name`,`Event`,`ResetPeriod`,`Actions`,`DelayActions`,`Component_` FROM `MsiServiceConfigFailureActions`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)|$(Field $_ 6)" })
if ($failureActions.Count -ne 1 -or $failureActions[0] -notmatch '^go-mapi\|3\|86400\|1\[~\]1\[~\]0\[~\]\|60000\[~\]300000\[~\]0\[~\]\|ResidentService$') { Fail "service failure actions are not bounded restart/restart/none: $($failureActions -join ';')" }

$registry = @(Query 'SELECT `Root`,`Key`,`Name`,`Value`,`Component_` FROM `Registry`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)" })
if (@($registry | Where-Object { $_ -match 'MapiRegistrationShared' }).Count -lt 3) { Fail 'missing shared active-MAPI registry rows' }
if (-not ($registry -match '%ProgramW6432%\\go-mapi\\interceptor\\%PROCESSOR_ARCHITECTURE%\\go-mapi\.dll')) { Fail 'missing caller-architecture-aware DLLPath' }
if ($registry -match '(?i)UserChoice|HKCU') { Fail 'MSI attempts per-user Default Apps mutation' }

$actions = @(Query 'SELECT `Action`,`Type`,`Source`,`Target` FROM `CustomAction`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)" })
foreach ($required in @('PrepareAdminMigration','RollbackAdminMigration','ApplyAdminMigration','VerifyAdminRegistration','PrepareAdminUninstall','RollbackAdminUninstall','FinalizeAdminUninstall')) {
    if (-not ($actions -match "^$required\|")) { Fail "missing custom action $required" }
}

$sequence = @(Query 'SELECT `Action`,`Condition`,`Sequence` FROM `InstallExecuteSequence`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)" })
foreach ($required in @('PrepareAdminMigration','RollbackAdminMigration','ApplyAdminMigration','VerifyAdminRegistration')) {
    if (-not ($sequence -match "^$required\|")) { Fail "custom action $required is not sequenced" }
}
Write-Host 'Verified immutable system identity, interceptor/service payload, one delayed resident service, bounded recovery, migration actions, and Default Apps boundary.'
