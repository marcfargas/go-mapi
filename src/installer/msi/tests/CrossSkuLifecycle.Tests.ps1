[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SystemMsi,
    [Parameter(Mandatory)][string]$SuiteMsi,
    [Parameter(Mandatory)][string]$NewerSuiteMsi,
    [string]$LogDirectory = (Join-Path $env:TEMP 'go-mapi-cross-sku-msi')
)

$ErrorActionPreference = 'Stop'
$systemCode = '{B3C97B33-3F10-47CA-9FA7-24EE3B75E325}'
$suiteCode = '{2E050A24-94A2-4FC9-B176-C5CCC1225FE6}'
$installer = New-Object -ComObject WindowsInstaller.Installer
$systemPath = (Resolve-Path -LiteralPath $SystemMsi).Path
$suitePath = (Resolve-Path -LiteralPath $SuiteMsi).Path
$newerSuitePath = (Resolve-Path -LiteralPath $NewerSuiteMsi).Path
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

function RelatedProducts([string]$UpgradeCode) {
    @($installer.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $installer, @($UpgradeCode)) | Where-Object { $_ })
}
function RunMsi([string]$Verb, [string]$Path, [string]$Name, [string[]]$Properties = @()) {
    $arguments = @($Verb, ('"' + $Path + '"'), '/qn', '/norestart', 'MSIRMSHUTDOWN=0') + $Properties +
        @('/l*v', ('"' + (Join-Path $LogDirectory ($Name + '.log')) + '"'))
    $process = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -PassThru
    return $process.ExitCode
}
function AssertMachine([string]$SKU, [string]$Sentinel) {
    $system = @(RelatedProducts $systemCode)
    $suite = @(RelatedProducts $suiteCode)
    $expectedSystem = if ($SKU -eq 'system') { 1 } else { 0 }
    $expectedSuite = if ($SKU -eq 'suite') { 1 } else { 0 }
    if ($system.Count -ne $expectedSystem -or $suite.Count -ne $expectedSuite) {
        throw "Expected $SKU only; system=$($system.Count), suite=$($suite.Count)"
    }
    $service = @(Get-CimInstance Win32_Service -Filter "Name='go-mapi'")
    if ($service.Count -ne 1 -or $service[0].StartName -ne 'LocalSystem' -or
        $service[0].StartMode -ne 'Auto' -or $service[0].State -ne 'Running') {
        throw "Service unhealthy after $SKU transaction"
    }
    $marker = Get-ItemProperty 'HKLM:\SOFTWARE\go-mapi\MachineProduct'
    if ($marker.SKU -ne $SKU) { throw "Machine health marker is $($marker.SKU), expected $SKU" }
    $interceptor = Join-Path $env:ProgramFiles 'go-mapi\interceptor'
    $manifestPath = Join-Path $interceptor 'installed-component-v1.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Interceptor manifest missing after $SKU transaction" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 'go-mapi-installed-interceptor-v1' -or @($manifest.artifacts).Count -ne 2 -or
        -not (Test-Path -LiteralPath (Join-Path $interceptor 'AMD64\go-mapi.dll')) -or
        -not (Test-Path -LiteralPath (Join-Path $interceptor 'x86\go-mapi.dll'))) {
        throw "Interceptor payload unhealthy after $SKU transaction"
    }
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            $mail = $base.OpenSubKey('SOFTWARE\Clients\Mail', $false)
            $client = $base.OpenSubKey('SOFTWARE\Clients\Mail\go-mapi', $false)
            try {
                $provider = if ($mail) { $mail.GetValue($null) } else { $null }
                $dllPath = if ($client) { $client.GetValue('DLLPath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
                if ($provider -ne 'go-mapi' -or $dllPath -ne '%ProgramW6432%\go-mapi\interceptor\%PROCESSOR_ARCHITECTURE%\go-mapi.dll') {
                    throw "$view MAPI registration unhealthy after $SKU transaction"
                }
            } finally {
                if ($mail) { $mail.Dispose() }
                if ($client) { $client.Dispose() }
            }
        } finally { $base.Dispose() }
    }
    $appPath = Join-Path $env:ProgramFiles 'go-mapi\user\go-mapi.exe'
    $shortcut = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'go-mapi\go-mapi.lnk'
    $startup = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'go-mapi-user-machine-v4' -ErrorAction SilentlyContinue
    if ($SKU -eq 'suite') {
        if (-not (Test-Path -LiteralPath $appPath) -or -not (Test-Path -LiteralPath $shortcut) -or
            -not $startup -or $marker.AppVersion -eq $null) { throw 'Suite machine app resources are incomplete' }
        $shell = New-Object -ComObject WScript.Shell
        $target = $shell.CreateShortcut($shortcut).TargetPath
        if ($target -ne $appPath -or
            $startup.'go-mapi-user-machine-v4' -ne ('"' + $appPath + '" --startup --machine-install')) {
            throw 'Suite Start Menu target or all-users startup command is wrong'
        }
    } elseif ((Test-Path -LiteralPath $appPath) -or (Test-Path -LiteralPath $shortcut) -or $startup) {
        throw 'Suite machine app resources remain under system SKU'
    }
    if ((Get-Content -LiteralPath $Sentinel -Raw) -ne 'profile-data-preserved') {
        throw 'User-profile sentinel was changed by machine migration'
    }
    [pscustomobject]@{ Event = 'MachineAssert'; SKU = $SKU; SystemProducts = $system.Count;
        SuiteProducts = $suite.Count; Service = $service[0].State; ProfileSentinel = 'unchanged' } |
        ConvertTo-Json -Compress
}
function AssertExit([int]$Actual, [int]$Expected, [string]$Step) {
    if ($Actual -eq 3010) { throw "$Step requires a reboot on this same lease and postboot verification; inspect $LogDirectory" }
    if ($Actual -ne $Expected) { throw "$Step returned $Actual, expected $Expected; inspect $LogDirectory" }
    [pscustomobject]@{ Event = 'MsiExit'; Step = $Step; Exit = $Actual } | ConvertTo-Json -Compress
}
function MachineSnapshot() {
    $marker = Get-ItemProperty 'HKLM:\SOFTWARE\go-mapi\MachineProduct'
    $app = Join-Path $env:ProgramFiles 'go-mapi\user\go-mapi.exe'
    $service = Join-Path $env:ProgramFiles 'go-mapi\service\go-mapi-service.exe'
    $shortcut = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'go-mapi\go-mapi.lnk'
    $startup = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'go-mapi-user-machine-v4' -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        SKU = $marker.SKU; PackageRelease = $marker.PackageRelease; AppVersion = $marker.AppVersion
        AutoUpdateEnabled = $marker.AutoUpdateEnabled
        AppHash = if (Test-Path -LiteralPath $app) { (Get-FileHash -LiteralPath $app -Algorithm SHA256).Hash } else { '' }
        ServiceHash = if (Test-Path -LiteralPath $service) { (Get-FileHash -LiteralPath $service -Algorithm SHA256).Hash } else { '' }
        ShortcutHash = if (Test-Path -LiteralPath $shortcut) { (Get-FileHash -LiteralPath $shortcut -Algorithm SHA256).Hash } else { '' }
        Startup = if ($startup) { $startup.'go-mapi-user-machine-v4' } else { '' }
    }
}
function AssertSnapshot($Before, [string]$Step) {
    $after = MachineSnapshot
    if (($Before | ConvertTo-Json -Compress) -ne ($after | ConvertTo-Json -Compress)) {
        throw "$Step changed the original machine product; inspect $LogDirectory"
    }
}
function WithRollbackDisabled([scriptblock]$Test) {
    $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer'
    $key = Get-ItemProperty -LiteralPath $path -Name DisableRollback -ErrorAction SilentlyContinue
    $hadValue = $null -ne $key
    $oldValue = if ($hadValue) { $key.DisableRollback } else { $null }
    New-Item -Path $path -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name DisableRollback -PropertyType DWord -Value 1 -Force | Out-Null
    try { & $Test } finally {
        if ($hadValue) { Set-ItemProperty -LiteralPath $path -Name DisableRollback -Value $oldValue }
        else { Remove-ItemProperty -LiteralPath $path -Name DisableRollback -ErrorAction SilentlyContinue }
    }
}

if (@(RelatedProducts $systemCode).Count -ne 0 -or @(RelatedProducts $suiteCode).Count -ne 0 -or
    (Get-Service go-mapi -ErrorAction SilentlyContinue)) {
    throw 'Cross-SKU lifecycle test requires a clean machine, not an existing go-mapi install'
}
if (Get-ScheduledTask -TaskName 'go-mapi Auto Update' -ErrorAction SilentlyContinue) {
    throw 'Cross-SKU lifecycle test requires no pre-existing legacy task'
}
$sentinelDirectory = Join-Path $env:LOCALAPPDATA 'go-mapi'
New-Item -ItemType Directory -Path $sentinelDirectory -Force | Out-Null
$sentinel = Join-Path $sentinelDirectory ("migration-sentinel-" + [guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllText($sentinel, 'profile-data-preserved')
$legacyTask = 'go-mapi Auto Update'
$unrelatedTask = 'go-mapi-unrelated-' + [guid]::NewGuid().ToString('N')
$taskAction = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit 0'
$taskTrigger = New-ScheduledTaskTrigger -Daily -At '23:59'
try {
Register-ScheduledTask -TaskName $legacyTask -Action $taskAction -Trigger $taskTrigger -Force | Out-Null
Register-ScheduledTask -TaskName $unrelatedTask -Action $taskAction -Trigger $taskTrigger -Force | Out-Null

WithRollbackDisabled {
    AssertExit (RunMsi '/i' $suitePath 'suite-fresh-rollback-disabled') 1603 'rollback-disabled suite fresh install'
}
if (@(RelatedProducts $systemCode).Count -ne 0 -or @(RelatedProducts $suiteCode).Count -ne 0) { throw 'Rollback-disabled fresh install changed product inventory' }

AssertExit (RunMsi '/i' $suitePath 'suite-fresh' @('GOMAPI_AUTO_UPDATE=0')) 0 'suite fresh install'
AssertMachine 'suite' $sentinel
if (Get-ScheduledTask -TaskName $legacyTask -ErrorAction SilentlyContinue) { throw 'Suite did not retire the exact legacy update task' }
if (-not (Get-ScheduledTask -TaskName $unrelatedTask -ErrorAction SilentlyContinue)) { throw 'Suite changed an unrelated scheduled task' }
if ((MachineSnapshot).AutoUpdateEnabled -ne 0) { throw 'Fresh suite disabled setting was not written' }
$suiteInitial = MachineSnapshot
AssertExit (RunMsi '/fa' $suitePath 'suite-repair-preserve-disabled') 0 'suite repair preserving disabled setting'
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteInitial 'suite repair'
WithRollbackDisabled {
    AssertExit (RunMsi '/fa' $suitePath 'suite-repair-rollback-disabled') 1603 'rollback-disabled suite repair'
}
AssertSnapshot $suiteInitial 'rollback-disabled suite repair'
# Windows Installer /f repair does not forward a supplied public setting into the elevated transaction.
# Re-enter through /i with explicit reinstall mode when an administrator changes the choice.
AssertExit (RunMsi '/i' $suitePath 'suite-enable-update' @('REINSTALL=ALL', 'REINSTALLMODE=amus', 'GOMAPI_AUTO_UPDATE=1')) 0 'suite explicit update enable'
if ((MachineSnapshot).AutoUpdateEnabled -ne 1) { throw 'Suite explicit setting enable failed' }
AssertExit (RunMsi '/fa' $suitePath 'suite-repair-preserve-enabled') 0 'suite repair preserving enabled setting'
$suiteBeforeUpgrade = MachineSnapshot
AssertExit (RunMsi '/i' $newerSuitePath 'suite-upgrade-after-registration-fault' @('GOMAPI_TEST_FAILURE_POINT=after-registration')) 1603 'newer suite rollback after registration'
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteBeforeUpgrade 'newer suite failed upgrade'
AssertExit (RunMsi '/i' $newerSuitePath 'suite-upgrade') 0 'suite manual same-SKU upgrade'
AssertMachine 'suite' $sentinel
if ((MachineSnapshot).AutoUpdateEnabled -ne 1) { throw 'Suite upgrade did not preserve enabled setting' }
WithRollbackDisabled {
    AssertExit (RunMsi '/x' $newerSuitePath 'suite-final-rollback-disabled') 1603 'rollback-disabled suite final uninstall'
}
AssertMachine 'suite' $sentinel
$suiteBeforeFinalUninstall = MachineSnapshot
AssertExit (RunMsi '/x' $newerSuitePath 'suite-final-after-destructive-fault' @('GOMAPI_TEST_FAILURE_POINT=after-uninstall-finalize')) 1603 'suite final uninstall rollback after destructive action'
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteBeforeFinalUninstall 'suite final uninstall fault'
AssertExit (RunMsi '/x' $newerSuitePath 'suite-final-uninstall') 0 'suite final uninstall'
if (@(RelatedProducts $suiteCode).Count -ne 0 -or (Get-Service go-mapi -ErrorAction SilentlyContinue)) { throw 'Suite final uninstall left product or service' }

AssertExit (RunMsi '/i' $systemPath 'system-initial') 0 'system initial install'
AssertMachine 'system' $sentinel
AssertExit (RunMsi '/i' $suitePath 'suite-rejected') 1603 'suite without opt-in'
AssertMachine 'system' $sentinel
$systemBeforeMigration = MachineSnapshot
WithRollbackDisabled {
    AssertExit (RunMsi '/i' $suitePath 'system-to-suite-rollback-disabled' @('GOMAPI_MIGRATE_SKU=1')) 1603 'rollback-disabled system to suite migration'
}
AssertSnapshot $systemBeforeMigration 'rollback-disabled system to suite migration'
AssertExit (RunMsi '/i' $suitePath 'suite-after-old-removal-before-cleanup-fault' @('GOMAPI_MIGRATE_SKU=1', 'GOMAPI_TEST_FAILURE_POINT=before-cleanup')) 1603 'suite migration rollback after old-product removal'
AssertMachine 'system' $sentinel
AssertSnapshot $systemBeforeMigration 'suite migration before-cleanup fault'
AssertExit (RunMsi '/i' $suitePath 'suite-after-registration-fault' @('GOMAPI_MIGRATE_SKU=1', 'GOMAPI_TEST_FAILURE_POINT=after-registration')) 1603 'suite migration rollback after registration'
AssertMachine 'system' $sentinel
AssertSnapshot $systemBeforeMigration 'suite migration after-registration fault'
AssertExit (RunMsi '/i' $suitePath 'suite-migration' @('GOMAPI_MIGRATE_SKU=1')) 0 'system to suite migration'
AssertMachine 'suite' $sentinel
AssertExit (RunMsi '/fa' $suitePath 'suite-repair') 0 'suite repair'
AssertMachine 'suite' $sentinel
AssertExit (RunMsi '/i' $systemPath 'system-rejected') 1603 'system without opt-in'
AssertMachine 'suite' $sentinel
$suiteBeforeMigration = MachineSnapshot
WithRollbackDisabled {
    AssertExit (RunMsi '/i' $systemPath 'suite-to-system-rollback-disabled' @('GOMAPI_MIGRATE_SKU=1')) 1603 'rollback-disabled suite to system migration'
}
AssertSnapshot $suiteBeforeMigration 'rollback-disabled suite to system migration'
AssertExit (RunMsi '/i' $systemPath 'system-after-removal-fault' @('GOMAPI_MIGRATE_SKU=1', 'GOMAPI_TEST_FAILURE_POINT=after-cleanup')) 1603 'system migration rollback after cleanup'
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteBeforeMigration 'system migration after-cleanup fault'
AssertExit (RunMsi '/i' $systemPath 'system-after-registration-fault' @('GOMAPI_MIGRATE_SKU=1', 'GOMAPI_TEST_FAILURE_POINT=after-registration')) 1603 'system migration rollback after registration'
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteBeforeMigration 'system migration after-registration fault'
AssertExit (RunMsi '/i' $systemPath 'system-migration' @('GOMAPI_MIGRATE_SKU=1')) 0 'suite to system migration'
AssertMachine 'system' $sentinel
AssertExit (RunMsi '/x' $systemPath 'system-final-uninstall') 0 'system final uninstall'
if (@(RelatedProducts $systemCode).Count -ne 0 -or @(RelatedProducts $suiteCode).Count -ne 0 -or
    (Get-Service go-mapi -ErrorAction SilentlyContinue)) {
    throw 'Final uninstall left a machine product or service behind'
}
if ((Get-Content -LiteralPath $sentinel -Raw) -ne 'profile-data-preserved') {
    throw 'Final uninstall changed user-profile data'
}
if (-not (Get-ScheduledTask -TaskName $unrelatedTask -ErrorAction SilentlyContinue)) { throw 'Machine lifecycle removed an unrelated scheduled task' }
Unregister-ScheduledTask -TaskName $unrelatedTask -Confirm:$false
[pscustomobject]@{ Event = 'CrossSkuLifecyclePass'; SystemToSuite = $true;
    SuiteToSystem = $true; RejectedBothDirections = $true; RollbackBothDirections = $true } |
    ConvertTo-Json -Compress
} finally {
    foreach ($task in @($legacyTask,$unrelatedTask)) {
        if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $task -Confirm:$false
        }
    }
    if (Test-Path -LiteralPath $sentinel) { Remove-Item -LiteralPath $sentinel -Force }
}
