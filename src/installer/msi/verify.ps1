[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MsiPath,
    [switch]$RequireSignature
)

$ErrorActionPreference = 'Stop'
function Fail([string]$Message) { throw "Admin MSI verification failed: $Message" }
if (-not (Test-Path $MsiPath)) { Fail "missing MSI $MsiPath" }
if ($RequireSignature -and (Get-AuthenticodeSignature $MsiPath).Status -ne 'Valid') { Fail 'release MSI signature is not valid' }

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
if ($files -match '(?i)go-mapi\.exe|wails|webview') { Fail 'MSI contains forbidden user-app payload' }

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
Write-Host 'Verified interceptor-only payload, caller-architecture-aware shared HKLM registration, mandatory migration actions, and Default Apps boundary.'
