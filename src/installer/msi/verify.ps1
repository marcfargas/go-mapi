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
if ($properties.ContainsKey('GOMAPI_AUTO_UPDATE') -and $properties.GOMAPI_AUTO_UPDATE) { Fail 'automatic update choice must be resolved from explicit property or existing machine setting' }
$secureProperties = @([string]$properties.SecureCustomProperties -split ';')
if ($secureProperties -notcontains 'GOMAPI_MIGRATE_SKU' -or $secureProperties -notcontains 'GOMAPI_FOREIGN_PRODUCT' -or $secureProperties -notcontains 'GOMAPI_AUTO_UPDATE') { Fail 'machine administrator options and foreign-product detection must be Secure properties' }
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
if ($properties.GoMapiSku -ne $SKU) { Fail 'compiled private machine SKU guard input is wrong' }

$services = @(Query 'SELECT `Name`,`DisplayName`,`ServiceType`,`StartType`,`ErrorControl`,`StartName`,`Arguments`,`Component_` FROM `ServiceInstall`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)|$(Field $_ 6)|$(Field $_ 7)|$(Field $_ 8)" })
if ($services.Count -ne 1 -or $services[0] -ne 'go-mapi|go-mapi system service|16|2|32769|LocalSystem|service|ResidentService') { Fail "unexpected resident service contract: $($services -join ';')" }
$controls = @(Query 'SELECT `Name`,`Event`,`Wait`,`Component_` FROM `ServiceControl`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)" })
if ($controls.Count -ne 1 -or $controls[0] -ne 'go-mapi|163|1|ResidentService') { Fail "unexpected ServiceControl contract: $($controls -join ';')" }
$serviceConfig = @(Query 'SELECT `Name`,`Event`,`ConfigType`,`Argument`,`Component_` FROM `MsiServiceConfig`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)" })
if ($serviceConfig.Count -ne 2 -or $serviceConfig -notcontains 'go-mapi|5|3|1|ResidentService' -or $serviceConfig -notcontains 'go-mapi|5|5|1|ResidentService') { Fail "service is not delayed-auto-start with an unrestricted SID: $($serviceConfig -join ';')" }
$failureActions = @(Query 'SELECT `ServiceName`,`Component_`,`NewService`,`FirstFailureActionType`,`SecondFailureActionType`,`ThirdFailureActionType`,`ResetPeriodInDays`,`RestartServiceDelayInSeconds`,`ProgramCommandLine`,`RebootMessage` FROM `Wix4ServiceConfig`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)|$(Field $_ 6)|$(Field $_ 7)|$(Field $_ 8)|$(Field $_ 9)|$(Field $_ 10)" })
if ($failureActions.Count -ne 1 -or $failureActions[0] -ne 'go-mapi|ResidentService|1|restart|restart|none|1|60||') { Fail "service failure actions are not bounded restart/restart/none with no reboot: $($failureActions -join ';')" }

$registry = @(Query 'SELECT `Root`,`Key`,`Name`,`Value`,`Component_` FROM `Registry`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)|$(Field $_ 4)|$(Field $_ 5)" })
if (@($registry | Where-Object { $_ -match '^2\|SOFTWARE\\go-mapi\\MachineProduct\|AutoUpdateEnabled\|#\[GOMAPI_AUTO_UPDATE\]\|SystemHealthRegistration$' }).Count -ne 1) { Fail 'machine update choice must be one installer-owned 64-bit DWORD' }
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
foreach ($required in @('ValidateMachineTransaction','ResolveAutoUpdateChoice','PrepareAdminMigration','RollbackAdminMigration','SnapshotAdminMigration','RollbackServiceConfiguration','ApplyAdminMigration','VerifyAdminRegistration','PrepareAdminUninstall','RollbackResidentUninstallFence','BeginResidentUninstallFence','RollbackAdminUninstall','FinalizeAdminUninstall','CommitAdminUninstall','StopSuiteApps','SetStopSuiteApps','PreStopSuiteApps')) {
    if (-not ($actions -match "^$required\|")) { Fail "missing custom action $required" }
}
# Execution bits: immediate actions impersonate the caller and must not write;
# every machine mutation is in-script (0x400) and non-impersonated (0x800).
function ActionType([string]$Name) { return [int](@($actions | Where-Object { $_ -match "^$Name\|" })[0] -split '\|')[1] }
foreach ($immediate in @('ValidateMachineTransaction','ResolveAutoUpdateChoice','PrepareAdminMigration','PrepareAdminUninstall')) {
    if ((ActionType $immediate) -band 0x0F00) { Fail "$immediate must be an immediate read-only action" }
}
foreach ($deferred in @('SnapshotAdminMigration','ApplyAdminMigration','VerifyAdminRegistration','BeginResidentUninstallFence','FinalizeAdminUninstall','StopSuiteApps')) {
    if (((ActionType $deferred) -band 0x0F00) -ne 0x0C00) { Fail "$deferred must be deferred and non-impersonated" }
}
foreach ($rollback in @('RollbackAdminMigration','RollbackServiceConfiguration','RollbackResidentUninstallFence','RollbackAdminUninstall')) {
    if (((ActionType $rollback) -band 0x0F00) -ne 0x0D00) { Fail "$rollback must be a non-impersonated rollback action" }
}
if (((ActionType 'CommitAdminUninstall') -band 0x0F00) -ne 0x0E00) { Fail 'CommitAdminUninstall must be a non-impersonated commit action' }
# The best-effort pre-stop is an immediate DLL action whose result is ignored:
# it runs as the caller before costing and can never fail the transaction.
$preStopType = ActionType 'PreStopSuiteApps'
if (($preStopType -band 0x3F) -ne 1 -or ($preStopType -band 0x40) -ne 0x40 -or ($preStopType -band 0x0C00)) {
    Fail "PreStopSuiteApps must be an immediate DLL action that continues on error (type $preStopType)"
}
# The suite app stop reads only fixed CustomActionData set by a script-free
# type-51 action; directory properties avoid custom-action bitness.
$stopData = @($actions | Where-Object { $_ -match '^SetStopSuiteApps\|' })[0] -split '\|'
if (([int]$stopData[1] -band 0x3F) -ne 51 -or $stopData[2] -ne 'StopSuiteApps' -or
    $stopData[3] -ne 'FailurePoint=[GOMAPI_TEST_FAILURE_POINT];ProgramFiles64=[ProgramFiles64Folder];CommonAppData=[CommonAppDataFolder]') {
    Fail 'StopSuiteApps must receive exactly its fixed CustomActionData from a type-51 action'
}
foreach ($required in @('Wix4SchedServiceConfig_X64','Wix4RollbackServiceConfig_X64','Wix4ExecServiceConfig_X64')) {
    if (-not ($actions -match "^$required\|")) { Fail "missing WiX Util service recovery action $required" }
}

$sequence = @(Query 'SELECT `Action`,`Condition`,`Sequence` FROM `InstallExecuteSequence`' | ForEach-Object { "$(Field $_ 1)|$(Field $_ 2)|$(Field $_ 3)" })
if (-not ($sequence -match '^CommitAdminUninstall\|REMOVE~="ALL" AND NOT UPGRADINGPRODUCTCODE\|')) { Fail 'manifest cleanup must be commit-only on final uninstall' }
$beginFenceSequence = @($sequence | Where-Object { $_ -match '^BeginResidentUninstallFence\|' })[0] -split '\|'
$rollbackFenceSequence = @($sequence | Where-Object { $_ -match '^RollbackResidentUninstallFence\|' })[0] -split '\|'
$stopServicesSequence = @($sequence | Where-Object { $_ -match '^StopServices\|' })[0] -split '\|'
if (-not $beginFenceSequence -or -not $rollbackFenceSequence -or -not $stopServicesSequence -or
    $beginFenceSequence[1] -ne 'REMOVE~="ALL" AND NOT UPGRADINGPRODUCTCODE' -or
    $rollbackFenceSequence[1] -ne 'REMOVE~="ALL" AND NOT UPGRADINGPRODUCTCODE' -or
    [int]$rollbackFenceSequence[2] -ge [int]$beginFenceSequence[2] -or
    [int]$beginFenceSequence[2] -ge [int]$stopServicesSequence[2]) { Fail 'final uninstall fence must precede service stop with an earlier rollback action' }
foreach ($required in @('ResolveAutoUpdateChoice','PrepareAdminMigration','RollbackAdminMigration','SnapshotAdminMigration','RollbackServiceConfiguration','ApplyAdminMigration','VerifyAdminRegistration')) {
    if (-not ($sequence -match "^$required\|")) { Fail "custom action $required is not sequenced" }
}
function SequenceRow([string]$Name) { return @($sequence | Where-Object { $_ -match "^$Name\|" })[0] -split '\|' }
$migrationOrder = @('RemoveExistingProducts','PrepareAdminMigration','RollbackAdminMigration','SnapshotAdminMigration','ApplyAdminMigration')
for ($index = 1; $index -lt $migrationOrder.Count; $index++) {
    $row = SequenceRow $migrationOrder[$index]
    if ($row[1] -ne 'NOT (REMOVE~="ALL")') { Fail "$($migrationOrder[$index]) must be conditioned to install and maintenance" }
    if ([int](SequenceRow $migrationOrder[$index - 1])[2] -ge [int]$row[2]) {
        Fail "migration order must be $($migrationOrder -join ' < ') (rollback queued before the snapshot it protects)"
    }
}
$verifyRow = SequenceRow 'VerifyAdminRegistration'
if ($verifyRow[1] -ne 'NOT (REMOVE~="ALL")' -or [int](SequenceRow 'WriteRegistryValues')[2] -ge [int]$verifyRow[2] -or
    [int](SequenceRow 'ApplyAdminMigration')[2] -ge [int]$verifyRow[2]) { Fail 'registration verification must follow WriteRegistryValues and migration apply' }
$rollbackSequence = @($sequence | Where-Object { $_ -match '^RollbackServiceConfiguration\|' })[0] -split '\|'
$removeSequence = @($sequence | Where-Object { $_ -match '^RemoveExistingProducts\|' })[0] -split '\|'
$deleteServicesSequence = @($sequence | Where-Object { $_ -match '^DeleteServices\|' })[0] -split '\|'
$findSequence = @($sequence | Where-Object { $_ -match '^FindRelatedProducts\|' })[0] -split '\|'
$launchSequence = @($sequence | Where-Object { $_ -match '^LaunchConditions\|' })[0] -split '\|'
$validateSequence = @($sequence | Where-Object { $_ -match '^InstallValidate\|' })[0] -split '\|'
$guardSequence = @($sequence | Where-Object { $_ -match '^ValidateMachineTransaction\|' })[0] -split '\|'
$initializeSequence = @($sequence | Where-Object { $_ -match '^InstallInitialize\|' })[0] -split '\|'
$choiceSequence = @($sequence | Where-Object { $_ -match '^ResolveAutoUpdateChoice\|' })[0] -split '\|'
if (-not $findSequence -or -not $launchSequence -or -not $validateSequence -or -not $guardSequence -or -not $initializeSequence -or
    -not $choiceSequence -or $choiceSequence[1] -ne 'NOT (REMOVE~="ALL")' -or
    [int]$findSequence[2] -ge [int]$launchSequence[2] -or
    [int]$launchSequence[2] -ge [int]$validateSequence[2] -or
    [int]$validateSequence[2] -ge [int]$guardSequence[2] -or
    [int]$guardSequence[2] -ge [int]$choiceSequence[2] -or
    [int]$choiceSequence[2] -ge [int]$initializeSequence[2] -or
    [int]$initializeSequence[2] -ge [int]$removeSequence[2]) {
    Fail 'foreign-product detection and rejection must precede early transactional removal'
}
# Windows Installer allows an early RemoveExistingProducts only directly after
# InstallInitialize or between InstallExecute and InstallFinalize. The suite app
# stop is the only script executed by the early InstallExecute, so the old
# product is removed after every installed app stopped, in one transaction.
$betweenInitializeAndRemoval = @($sequence | Where-Object {
    $parts = $_ -split '\|'
    [int]$parts[2] -gt [int]$initializeSequence[2] -and [int]$parts[2] -lt [int]$removeSequence[2]
} | Sort-Object { [int](($_ -split '\|')[2]) } | ForEach-Object { ($_ -split '\|')[0] })
if (($betweenInitializeAndRemoval -join ',') -cne 'StopSuiteApps,InstallExecute') {
    Fail "early RemoveExistingProducts must directly follow the InstallExecute that runs only StopSuiteApps after InstallInitialize: $($betweenInitializeAndRemoval -join ';')"
}
if (@($sequence | Where-Object { $_ -match '^InstallExecute(Again)?\|' }).Count -ne 1) { Fail 'machine sequence must contain exactly one InstallExecute' }
$stopSequence = SequenceRow 'StopSuiteApps'
if ($stopSequence[1] -cne 'NOT UPGRADINGPRODUCTCODE' -or (SequenceRow 'InstallExecute')[1] -ne '') {
    Fail 'StopSuiteApps must run in every outer machine transaction and never inside a nested old-product removal'
}
foreach ($later in @('BeginResidentUninstallFence','StopServices','RemoveFiles','InstallFiles')) {
    if ([int]$stopSequence[2] -ge [int](SequenceRow $later)[2]) { Fail "StopSuiteApps must precede $later" }
}
# The pre-stop closes the installed app before Windows Installer costs files,
# so InstallValidate finds no go-mapi.exe in use. It runs only in the outer
# execute sequence, never in a UI, administrative or advertise sequence.
$preStopSequence = SequenceRow 'PreStopSuiteApps'
if (-not $preStopSequence -or $preStopSequence[1] -cne 'NOT UPGRADINGPRODUCTCODE' -or
    [int]$launchSequence[2] -ge [int]$preStopSequence[2] -or
    [int]$preStopSequence[2] -ge [int](SequenceRow 'CostInitialize')[2]) {
    Fail 'PreStopSuiteApps must run after LaunchConditions and before CostInitialize in every outer machine transaction'
}
foreach ($table in @('InstallUISequence','AdminUISequence','AdminExecuteSequence','AdvtExecuteSequence')) {
    if ($tables -notcontains $table) { continue }
    if (@(Query ('SELECT `Action` FROM `' + $table + '`') | Where-Object { (Field $_ 1) -eq 'PreStopSuiteApps' }).Count) {
        Fail "PreStopSuiteApps must not be sequenced in $table"
    }
}
$setStopSequence = SequenceRow 'SetStopSuiteApps'
if (-not $setStopSequence -or [int]$setStopSequence[2] -ge [int]$initializeSequence[2]) { Fail 'StopSuiteApps data must be set before InstallInitialize' }
if ($rollbackSequence[1] -cne 'REMOVE~="ALL"' -or
    [int]$rollbackSequence[2] -ge [int]$deleteServicesSequence[2] -or
    [int]$rollbackSequence[2] -le [int]$removeSequence[2]) {
    Fail 'service configuration rollback must precede DeleteServices on every removal without splitting early removal'
}
Write-Host "Verified immutable $SKU identity, mutually exclusive machine Upgrade rows, ordered migration gate, interceptor/service payload, one delayed resident service, bounded recovery, migration actions, and Default Apps boundary."
