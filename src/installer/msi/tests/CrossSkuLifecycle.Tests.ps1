[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SystemMsi,
    [Parameter(Mandatory)][string]$SuiteMsi,
    [string]$LogDirectory = (Join-Path $env:TEMP 'go-mapi-cross-sku-msi')
)

$ErrorActionPreference = 'Stop'
$systemCode = '{B3C97B33-3F10-47CA-9FA7-24EE3B75E325}'
$suiteCode = '{2E050A24-94A2-4FC9-B176-C5CCC1225FE6}'
$installer = New-Object -ComObject WindowsInstaller.Installer
$systemPath = (Resolve-Path -LiteralPath $SystemMsi).Path
$suitePath = (Resolve-Path -LiteralPath $SuiteMsi).Path
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
    if ($Actual -ne $Expected) { throw "$Step returned $Actual, expected $Expected; inspect $LogDirectory" }
    [pscustomobject]@{ Event = 'MsiExit'; Step = $Step; Exit = $Actual } | ConvertTo-Json -Compress
}

if (@(RelatedProducts $systemCode).Count -ne 0 -or @(RelatedProducts $suiteCode).Count -ne 0 -or
    (Get-Service go-mapi -ErrorAction SilentlyContinue)) {
    throw 'Cross-SKU lifecycle test requires a clean machine, not an existing go-mapi install'
}
$sentinelDirectory = Join-Path $env:LOCALAPPDATA 'go-mapi'
New-Item -ItemType Directory -Path $sentinelDirectory -Force | Out-Null
$sentinel = Join-Path $sentinelDirectory ("migration-sentinel-" + [guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllText($sentinel, 'profile-data-preserved')

AssertExit (RunMsi '/i' $systemPath 'system-initial') 0 'system initial install'
AssertMachine 'system' $sentinel
AssertExit (RunMsi '/i' $suitePath 'suite-rejected') 1603 'suite without opt-in'
AssertMachine 'system' $sentinel
AssertExit (RunMsi '/i' $suitePath 'suite-before-removal-fault' @('GOMAPI_MIGRATE_SKU=1', 'GOMAPI_TEST_FAILURE_POINT=before-cleanup')) 1603 'suite migration rollback before cleanup'
AssertMachine 'system' $sentinel
AssertExit (RunMsi '/i' $suitePath 'suite-migration' @('GOMAPI_MIGRATE_SKU=1')) 0 'system to suite migration'
AssertMachine 'suite' $sentinel
AssertExit (RunMsi '/fa' $suitePath 'suite-repair') 0 'suite repair'
AssertMachine 'suite' $sentinel
AssertExit (RunMsi '/i' $systemPath 'system-rejected') 1603 'system without opt-in'
AssertMachine 'suite' $sentinel
AssertExit (RunMsi '/i' $systemPath 'system-after-removal-fault' @('GOMAPI_MIGRATE_SKU=1', 'GOMAPI_TEST_FAILURE_POINT=after-cleanup')) 1603 'system migration rollback after cleanup'
AssertMachine 'suite' $sentinel
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
[pscustomobject]@{ Event = 'CrossSkuLifecyclePass'; SystemToSuite = $true;
    SuiteToSystem = $true; RejectedBothDirections = $true; RollbackBothDirections = $true } |
    ConvertTo-Json -Compress
