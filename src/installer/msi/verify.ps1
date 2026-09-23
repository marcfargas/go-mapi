[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MsiPath,
    [ValidateSet('system','suite')][string]$SKU = 'system',
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
if ([IO.Path]::GetFileName($MsiPath) -ne $identity.assetName) { Fail "MSI filename is not the immutable $SKU asset name $($identity.assetName)" }

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
function LongFileName([string]$Value) { return @($Value -split '\|')[-1] }
function Assert-TableAbsent([string]$Name) {
    if ($script:tables -contains $Name) { Fail "compiled MSI contains forbidden table $Name" }
}

$tables = @(Query 'SELECT `Name` FROM `_Tables`' | ForEach-Object { Field $_ 1 })
if ($tables -notcontains 'Wix4ServiceConfig') { Fail 'compiled MSI is missing WiX Util service recovery configuration' }
Assert-TableAbsent 'MsiServiceConfigFailureActions'

$files = @(Query 'SELECT `FileName`,`Component_` FROM `File`' | ForEach-Object { "$(LongFileName (Field $_ 1))|$(Field $_ 2)" })
if (@($files | Where-Object { $_ -match '^go-mapi\.dll\|' }).Count -ne 2) { Fail 'MSI must contain exactly two interceptor DLL files' }
if (@($files | Where-Object { $_ -match '^go-mapi-service\.exe\|ResidentService$' }).Count -ne 1) { Fail 'MSI must contain exactly one resident service executable' }
$userApps = @($files | Where-Object { $_ -match '^go-mapi\.exe\|SuiteUserExe$' })
if ($SKU -eq 'system' -and ($userApps.Count -ne 0 -or $files -match '(?i)wails|webview')) { Fail 'system MSI contains forbidden user-app payload' }
if ($SKU -eq 'suite' -and $userApps.Count -ne 1) { Fail 'suite MSI must contain exactly one all-users app executable' }
$componentIds = @{}
Query 'SELECT `Component`,`ComponentId` FROM `Component`' | ForEach-Object { $componentIds[(Field $_ 1)] = (Field $_ 2).Trim('{}').ToUpperInvariant() }
$sharedComponentIds = @{
    InterceptorX64 = 'D56189EF-0DA1-4AA1-A764-D90610EC8441'
    InterceptorX86 = '541217D4-4C8D-4D4C-83E5-9CD4CDCF7694'
    MapiRegistrationShared = '1247251F-F476-4520-81A5-25985450B9F8'
    ResidentService = '1E335EC1-0CCC-54A2-ACC2-96EB8FB2E134'
    MachineStateRoots = '813604F6-3EE7-581F-86B6-0F3FC1CF0519'
}
foreach ($name in $sharedComponentIds.Keys) {
    if ($componentIds[$name] -ne $sharedComponentIds[$name]) { Fail "shared cross-SKU component $name has changed identity" }
}
$expectedHealthComponent = if ($SKU -eq 'system') { '5A07A413-53B3-58DF-BC3F-1C405A6B083F' } else { '299FDB55-B38D-5C25-8334-D45FA3CC3DDB' }
if ($componentIds.SystemHealthRegistration -ne $expectedHealthComponent) { Fail 'SKU-specific health component GUID is wrong' }
if ($SKU -eq 'system' -and ($componentIds.ContainsKey('SuiteUserExe') -or $componentIds.ContainsKey('SuiteStartup') -or $componentIds.ContainsKey('SuiteAppHealthRegistration'))) { Fail 'system MSI contains suite-only component ownership' }

$properties = @{}
Query 'SELECT `Property`,`Value` FROM `Property`' | ForEach-Object { $properties[(Field $_ 1)] = (Field $_ 2) }
$expectedUpgradeCode = if ($SKU -eq 'system') { 'B3C97B33-3F10-47CA-9FA7-24EE3B75E325' } else { '2E050A24-94A2-4FC9-B176-C5CCC1225FE6' }
$foreignUpgradeCode = if ($SKU -eq 'system') { '2E050A24-94A2-4FC9-B176-C5CCC1225FE6' } else { 'B3C97B33-3F10-47CA-9FA7-24EE3B75E325' }
if ($properties.ProductCode.Trim('{}') -ne $identity.productCode -or $properties.ProductVersion -ne $identity.productVersion -or $properties.UpgradeCode.Trim('{}') -ne $expectedUpgradeCode) { Fail "compiled MSI identity does not match the production $SKU identity" }
if ($properties.ContainsKey('GOMAPI_MIGRATE_SKU') -and $properties.GOMAPI_MIGRATE_SKU) { Fail 'SKU migration opt-in must have no default' }
$secureProperties = @([string]$properties.SecureCustomProperties -split ';')
if ($secureProperties -notcontains 'GOMAPI_MIGRATE_SKU' -or $secureProperties -notcontains 'GOMAPI_FOREIGN_PRODUCT') { Fail 'migration opt-in and foreign-product detection must be Secure properties' }
$foreignUpgradeRows = @(Query 'SELECT `UpgradeCode`,`VersionMin`,`VersionMax`,`Language`,`Attributes`,`Remove`,`ActionProperty` FROM `Upgrade`' | Where-Object { (Field $_ 7) -eq 'GOMAPI_FOREIGN_PRODUCT' })
if ($foreignUpgradeRows.Count -ne 1) { Fail 'MSI must have exactly one foreign-product Upgrade row' }
$foreignUpgrade = $foreignUpgradeRows[0]
if ((Field $foreignUpgrade 1).Trim('{}') -ne $foreignUpgradeCode -or
    (Field $foreignUpgrade 2) -ne '0.0.0' -or (Field $foreignUpgrade 3) -ne '' -or
    (Field $foreignUpgrade 4) -ne '' -or [int](Field $foreignUpgrade 5) -ne 256 -or
    (Field $foreignUpgrade 6) -ne '') {
    Fail 'foreign-product Upgrade row must cover all versions and remove every feature transactionally'
}
$migrationLaunch = 'Installed OR NOT GOMAPI_FOREIGN_PRODUCT OR GOMAPI_MIGRATE_SKU = "1"'
$launchConditions = @(Query 'SELECT `Condition` FROM `LaunchCondition`' | ForEach-Object { Field $_ 1 })
if ($launchConditions -notcontains $migrationLaunch) { Fail 'foreign machine product must block installation absent explicit migration opt-in' }

$services = @(Query 'SELECT `Name`,`DisplayName`,`ServiceType`,`StartType`,`ErrorControl`,`StartName`,`Arguments`,`Component_` FROM `ServiceInstall`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)|$(Field $_ 6)|$(Field $_ 7)|$(Field $_ 8)" })
if ($services.Count -ne 1 -or $services[0] -ne 'go-mapi|go-mapi system service|16|2|32769|LocalSystem|service|ResidentService') { Fail "unexpected resident service contract: $($services -join ';')" }
$controls = @(Query 'SELECT `Name`,`Event`,`Wait`,`Component_` FROM `ServiceControl`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)" })
if ($controls.Count -ne 1 -or $controls[0] -ne 'go-mapi|163|1|ResidentService') { Fail "unexpected ServiceControl contract: $($controls -join ';')" }
$serviceConfig = @(Query 'SELECT `Name`,`Event`,`ConfigType`,`Argument`,`Component_` FROM `MsiServiceConfig`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)" })
if ($serviceConfig.Count -ne 2 -or $serviceConfig -notcontains 'go-mapi|5|3|1|ResidentService' -or $serviceConfig -notcontains 'go-mapi|5|5|1|ResidentService') { Fail "service is not delayed-auto-start with an unrestricted SID: $($serviceConfig -join ';')" }
$failureActions = @(Query 'SELECT `ServiceName`,`Component_`,`NewService`,`FirstFailureActionType`,`SecondFailureActionType`,`ThirdFailureActionType`,`ResetPeriodInDays`,`RestartServiceDelayInSeconds`,`ProgramCommandLine`,`RebootMessage` FROM `Wix4ServiceConfig`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)|$(Field $_ 6)|$(Field $_ 7)|$(Field $_ 8)|$(Field $_ 9)|$(Field $_ 10)" })
if ($failureActions.Count -ne 1 -or $failureActions[0] -ne 'go-mapi|ResidentService|1|restart|restart|none|1|60||') { Fail "service failure actions are not bounded restart/restart/none with no reboot: $($failureActions -join ';')" }

$registry = @(Query 'SELECT `Root`,`Key`,`Name`,`Value`,`Component_` FROM `Registry`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)" })
if (@($registry | Where-Object { $_ -match 'MapiRegistrationShared' }).Count -lt 3) { Fail 'missing shared active-MAPI registry rows' }
if (-not ($registry -match '%ProgramW6432%\\go-mapi\\interceptor\\%PROCESSOR_ARCHITECTURE%\\go-mapi\.dll')) { Fail 'missing caller-architecture-aware DLLPath' }
if ($registry -match '(?i)UserChoice|HKCU') { Fail 'MSI attempts per-user Default Apps mutation' }
if ($SKU -eq 'suite') {
    if (@($registry | Where-Object { $_ -match '^2\|SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run\|go-mapi-user-machine-v4\|.*--startup --machine-install\|SuiteStartup$' }).Count -ne 1) { Fail 'suite lacks its fixed HKLM Run startup entry' }
    if (@($registry | Where-Object { $_ -match '^2\|SOFTWARE\\go-mapi\\MachineProduct\|SKU\|suite\|SystemHealthRegistration$' }).Count -ne 1) { Fail 'suite health marker is not suite-specific' }
    if (@($registry | Where-Object { $_ -match '^2\|SOFTWARE\\go-mapi\\MachineProduct\|AppVersion\|' }).Count -ne 1) { Fail 'suite lacks its contained app version' }
    $shortcuts = @(Query 'SELECT `Shortcut`,`Directory_`,`Name`,`Target` FROM `Shortcut`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)" })
    if ($shortcuts.Count -ne 1 -or $shortcuts[0] -notmatch '^SuiteAppShortcut\|.*\|go-mapi\|\[#SuiteUserExeFile\]$') { Fail "suite must have one Common Start-menu shortcut: $($shortcuts -join ';')" }
} else {
    if ($registry -match 'SuiteStartup|SuiteAppHealthRegistration|\|suite\|SystemHealthRegistration$') { Fail 'system MSI contains suite registry entries' }
    Assert-TableAbsent 'Shortcut'
}

$actions = @(Query 'SELECT `Action`,`Type`,`Source`,`Target` FROM `CustomAction`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)" })
foreach ($required in @('PrepareAdminMigration','RollbackAdminMigration','RollbackServiceConfiguration','ApplyAdminMigration','VerifyAdminRegistration','PrepareAdminUninstall','RollbackAdminUninstall','FinalizeAdminUninstall')) {
    if (-not ($actions -match "^$required\|")) { Fail "missing custom action $required" }
}
foreach ($required in @('Wix4SchedServiceConfig_X64','Wix4RollbackServiceConfig_X64','Wix4ExecServiceConfig_X64')) {
    if (-not ($actions -match "^$required\|")) { Fail "missing WiX Util service recovery action $required" }
}

$sequence = @(Query 'SELECT `Action`,`Condition`,`Sequence` FROM `InstallExecuteSequence`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)" })
foreach ($required in @('PrepareAdminMigration','RollbackAdminMigration','RollbackServiceConfiguration','ApplyAdminMigration','VerifyAdminRegistration')) {
    if (-not ($sequence -match "^$required\|")) { Fail "custom action $required is not sequenced" }
}
$rollbackSequence = @($sequence | Where-Object { $_ -match '^RollbackServiceConfiguration\|' })[0] -split '\|'
$removeSequence = @($sequence | Where-Object { $_ -match '^RemoveExistingProducts\|' })[0] -split '\|'
$deleteServicesSequence = @($sequence | Where-Object { $_ -match '^DeleteServices\|' })[0] -split '\|'
$findSequence = @($sequence | Where-Object { $_ -match '^FindRelatedProducts\|' })[0] -split '\|'
$launchSequence = @($sequence | Where-Object { $_ -match '^LaunchConditions\|' })[0] -split '\|'
$initializeSequence = @($sequence | Where-Object { $_ -match '^InstallInitialize\|' })[0] -split '\|'
if (-not $findSequence -or -not $launchSequence -or -not $initializeSequence -or
    [int]$findSequence[2] -ge [int]$launchSequence[2] -or
    [int]$launchSequence[2] -ge [int]$initializeSequence[2] -or
    [int]$initializeSequence[2] -ge [int]$removeSequence[2]) {
    Fail 'foreign-product detection and rejection must precede early transactional removal'
}
$betweenInitializeAndRemoval = @($sequence | Where-Object {
    $parts = $_ -split '\|'
    [int]$parts[2] -gt [int]$initializeSequence[2] -and [int]$parts[2] -lt [int]$removeSequence[2]
})
if ($betweenInitializeAndRemoval.Count -ne 0) {
    Fail "early RemoveExistingProducts must follow InstallInitialize with no scripted action between: $($betweenInitializeAndRemoval -join ';')"
}
if ($rollbackSequence[1] -ne 'REMOVE~="ALL" AND UPGRADINGPRODUCTCODE' -or
    [int]$rollbackSequence[2] -ge [int]$deleteServicesSequence[2] -or
    [int]$rollbackSequence[2] -le [int]$removeSequence[2]) {
    Fail 'old-product service configuration rollback must precede DeleteServices without splitting early removal'
}
Write-Host "Verified immutable $SKU identity, mutually exclusive machine Upgrade rows, ordered migration gate, interceptor/service payload, one delayed resident service, bounded recovery, migration actions, and Default Apps boundary."
