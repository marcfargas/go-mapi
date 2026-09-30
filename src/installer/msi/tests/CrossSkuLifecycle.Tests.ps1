[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SystemMsi,
    [Parameter(Mandatory)][string]$SuiteMsi,
    [Parameter(Mandatory)][string]$NewerSuiteMsi,
    # A newer suite whose contained app file differs from SuiteMsi's, so an
    # upgrade to it replaces a running go-mapi.exe.
    [Parameter(Mandatory)][string]$NewerAppSuiteMsi,
    [string]$LogDirectory = (Join-Path $env:TEMP 'go-mapi-cross-sku-msi'),
    # Lease-only: require an installed app instance in a session other than
    # the msiexec client's. Hosted CI runners have one usable session, so
    # without this switch the session set is only recorded.
    [switch]$RequireOtherSession,
    # Focused running-app case from a clean machine. It records the
    # behavioral evidence before asserting, so it also proves the defect on
    # packages that lack the suite app stop.
    [ValidateSet('All','Repair','PreStopThrow','Upgrade','UpgradeApp','Uninstall','Switch')][string]$RunningAppCase = 'All',
    # Lease-only: upgrade from these published suite bytes to NewerSuiteMsi
    # with installed apps running.
    [string]$PublishedSuiteMsi
)

$ErrorActionPreference = 'Stop'
$systemCode = '{B3C97B33-3F10-47CA-9FA7-24EE3B75E325}'
$suiteCode = '{2E050A24-94A2-4FC9-B176-C5CCC1225FE6}'
$installer = New-Object -ComObject WindowsInstaller.Installer
$systemPath = (Resolve-Path -LiteralPath $SystemMsi).Path
$suitePath = (Resolve-Path -LiteralPath $SuiteMsi).Path
$newerSuitePath = (Resolve-Path -LiteralPath $NewerSuiteMsi).Path
$newerAppSuitePath = (Resolve-Path -LiteralPath $NewerAppSuiteMsi).Path
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

function RelatedProducts([string]$UpgradeCode) {
    @($installer.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $installer, @($UpgradeCode)) | Where-Object { $_ })
}
function RunMsi([string]$Verb, [string]$Path, [string]$Name, [string[]]$Properties = @()) {
    # msiexec /fa drops every property, including the REBOOT=ReallySuppress
    # of /norestart: a repair that needs a reboot then restarts the machine
    # (exit 1641). Run the identical repair through /i so they apply.
    if ($Verb -eq '/fa') { $Verb = '/i'; $Properties = @('REINSTALL=ALL', 'REINSTALLMODE=a') + $Properties }
    $arguments = @($Verb, ('"' + $Path + '"'), '/qn', '/norestart', 'MSIRMSHUTDOWN=0') + $Properties +
        @('/l*v', ('"' + (Join-Path $LogDirectory ($Name + '.log')) + '"'))
    $process = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -PassThru
    $script:LastMsiExitTime = Get-Date
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
# A rolled-back removal must restore the resident service's SCM settings;
# without them its health proof fails and suite admission stays closed.
function Assert-ServiceConfiguration([string]$Step) {
    $registry = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\go-mapi'
    $sidType = (& sc.exe qsidtype go-mapi | Out-String)
    $failure = (& sc.exe qfailure go-mapi | Out-String)
    if ($registry.DelayedAutoStart -ne 1 -or $sidType -notmatch 'SERVICE_SID_TYPE:\s+UNRESTRICTED' -or
        @([regex]::Matches($failure, 'RESTART --')).Count -ne 2) {
        throw "$Step left the resident service configuration unrestored: delayed=$($registry.DelayedAutoStart) $($sidType -replace '\s+', ' ') $($failure -replace '\s+', ' ')"
    }
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
# Install-time preparation must leave the committed journal byte-identical and
# no transaction backup directory behind when MSI rolls back.
function JournalSnapshot() {
    $journalRoot = Join-Path $env:ProgramData 'go-mapi\installer-journal'
    $journal = Join-Path $journalRoot 'admin-migration-v1.json'
    $backupRoot = Join-Path $journalRoot 'backup'
    return [pscustomobject]@{
        JournalHash = if (Test-Path -LiteralPath $journal) { (Get-FileHash -LiteralPath $journal -Algorithm SHA256).Hash } else { '' }
        TransactionBackups = if (Test-Path -LiteralPath $backupRoot) { (@(Get-ChildItem -LiteralPath $backupRoot -Directory | ForEach-Object Name | Sort-Object) -join ',') } else { '' }
    }
}
function AssertJournal($Before, [string]$Step) {
    if (($Before | ConvertTo-Json -Compress) -ne ((JournalSnapshot) | ConvertTo-Json -Compress)) {
        throw "$Step left the migration journal or transaction backups changed; inspect $LogDirectory"
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


# Running installed suite app coverage (Ticket 529). Every transaction that
# replaces or removes the installed app must stop it in every session itself:
# exit 0 (never 3010), no reboot operation, no surviving instance, and a
# same-name process with another image left running.
$appImage = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'go-mapi\user\go-mapi.exe'))
$gatePath = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'go-mapi\status\suite-admission-v1'
$clientSession = (Get-Process -Id $PID).SessionId
$testRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) ('go-mapi-lifecycle-test-' + [guid]::NewGuid().ToString('N'))
$script:testTasks = @()
$script:decoy = $null

function Write-Evidence([string]$Name, $Value) {
    $Value | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $LogDirectory ($Name + '.json')) -Encoding utf8
}
function Get-GateState() {
    if (-not (Test-Path -LiteralPath $gatePath -PathType Leaf)) { return 'A' }
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            $stream = [IO.File]::Open($gatePath, 'Open', 'Read', 'ReadWrite')
            try {
                if ($stream.Length -ne 1) { return 'M' }
                return [string][char]$stream.ReadByte()
            } finally { $stream.Dispose() }
        } catch [IO.IOException] { Start-Sleep -Milliseconds 50 }
    }
    throw 'Suite admission gate stayed locked'
}
# The resident service is the only writer of O. It reopens the gate as soon as
# Windows Installer is idle after it has proved the installed product healthy;
# its one-minute heartbeat is the backstop.
# Seconds from $Since until the gate reads O, or $null after $Seconds.
function Measure-GateOpen([datetime]$Since, [int]$Seconds) {
    $deadline = $Since.AddSeconds($Seconds)
    do {
        if ((Get-GateState) -eq 'O') { return [math]::Round(((Get-Date) - $Since).TotalSeconds, 2) }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $null
}
# -FromMsiExit counts from the exit of the last RunMsi, not from this call.
function Wait-GateOpen([string]$Step, [int]$Seconds = 120, [switch]$FromMsiExit) {
    $since = if ($FromMsiExit) { $script:LastMsiExitTime } else { Get-Date }
    if ($null -eq (Measure-GateOpen $since $Seconds)) {
        $from = if ($FromMsiExit) { ' of the msiexec exit' } else { '' }
        throw "$Step`: suite admission did not reopen within $Seconds s$from (state $(Get-GateState))"
    }
}
function Get-InstalledApps() {
    @(Get-CimInstance Win32_Process -Filter "Name='go-mapi.exe'" | Where-Object {
        $_.ExecutablePath -and [string]::Equals([IO.Path]::GetFullPath($_.ExecutablePath), $appImage, [StringComparison]::OrdinalIgnoreCase)
    })
}
function Get-SessionUsers() {
    # One Explorer owner per interactive session other than the msiexec client's.
    $seen = @{}
    foreach ($explorer in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -ne $clientSession })) {
        if ($seen.ContainsKey($explorer.SessionId)) { continue }
        $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
        if ($owner.ReturnValue -eq 0 -and $owner.User) {
            $seen[$explorer.SessionId] = [pscustomobject]@{ SessionId = $explorer.SessionId; User = "$($owner.Domain)\$($owner.User)" }
        }
    }
    @($seen.Values)
}
function Start-TestTask([string]$Label, [string]$Execute, [string]$Argument, $Principal) {
    $name = 'go-mapi-lifecycle-' + $Label + '-' + [guid]::NewGuid().ToString('N')
    $action = if ($Argument) { New-ScheduledTaskAction -Execute $Execute -Argument $Argument } else { New-ScheduledTaskAction -Execute $Execute }
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
    Register-ScheduledTask -TaskName $name -Action $action -Principal $Principal -Settings $settings -Force | Out-Null
    $script:testTasks += $name
    Start-ScheduledTask -TaskName $name
    return $name
}
function Remove-TestTasks() {
    foreach ($task in @($script:testTasks)) {
        if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $task -Confirm:$false }
    }
    $script:testTasks = @()
}
# Starts the installed app in every other interactive session and in session 0.
# If neither stays alive (for example a hosted runner without an Explorer
# session), it starts one in the current session. It never skips silently.
function Start-InstalledSuiteApps([string]$Step) {
    Wait-GateOpen $Step
    foreach ($user in Get-SessionUsers) {
        $principal = New-ScheduledTaskPrincipal -UserId $user.User -LogonType Interactive -RunLevel Limited
        Start-TestTask 'app' $appImage '' $principal | Out-Null
    }
    Start-TestTask 'app0' $appImage '' (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) | Out-Null
    Start-Sleep -Seconds 5
    $alive = Get-InstalledApps
    if ($alive.Count -eq 0) {
        Start-Process -FilePath $appImage | Out-Null
        Start-Sleep -Seconds 5
        $alive = Get-InstalledApps
    }
    $sessions = @($alive | ForEach-Object SessionId | Sort-Object -Unique)
    Write-Host ([pscustomobject]@{ Event = 'InstalledAppsRunning'; Step = $Step; ClientSession = $clientSession;
        Instances = @($alive | ForEach-Object { [pscustomobject]@{ Pid = $_.ProcessId; Session = $_.SessionId } }) } |
        ConvertTo-Json -Compress -Depth 4)
    if ($alive.Count -eq 0) { throw "$Step`: no installed go-mapi app instance stayed alive" }
    if ($RequireOtherSession -and -not ($sessions | Where-Object { $_ -ne $clientSession })) {
        throw "$Step`: no installed app instance runs outside the installer session $clientSession"
    }
    return $alive
}
# A process with the app's file name but another image: never stopped (outcome 6).
function Start-Decoy() {
    if ($script:decoy -and -not $script:decoy.HasExited) { return }
    $directory = Join-Path $testRoot 'decoy'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $decoyPath = Join-Path $directory 'go-mapi.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $decoyPath -Force
    $script:decoy = Start-Process -FilePath $decoyPath -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru
}
function Stop-Decoy() {
    if ($script:decoy -and -not $script:decoy.HasExited) { Stop-Process -Id $script:decoy.Id -Force -ErrorAction SilentlyContinue }
    $script:decoy = $null
}
function Get-PendingRenames() {
    $value = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    @($value | Where-Object { $_ })
}
# Runs one transaction with installed apps running and records every
# behavioral fact before any assertion, then asserts them in that order.
function Invoke-RunningAppTransaction([string]$Verb, [string]$Path, [string]$Name, [string[]]$Properties = @(), [int]$Expected = 0,
    [switch]$AllowSurvivors, [string]$ExpectMessage,
    # A stop that ends at its bound logs the bound line instead of completing.
    [string]$StopMarker = 'go-mapi suite app stop complete: stopped=') {
    $before = MachineSnapshot
    $renamesBefore = Get-PendingRenames
    $running = Start-InstalledSuiteApps $Name
    Start-Decoy
    $exit = RunMsi $Verb $Path $Name $Properties
    $survivors = Get-InstalledApps
    $renamesAfter = Get-PendingRenames
    $newRenames = @($renamesAfter | Where-Object { $renamesBefore -notcontains $_ })
    $log = Join-Path $LogDirectory ($Name + '.log')
    $lines = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() }
    $inUse = @($lines | Where-Object { ($_ -match '(?i)go-mapi\.exe' -and $_ -match '(?i)in use|held in use|reboot') -or
        $_ -match '(?i)Scheduling reboot operation|Must reboot|ReplacedInUseFiles = 1' })
    $stopLine = @(for ($index = 0; $index -lt $lines.Count; $index++) { if ($lines[$index].Contains($StopMarker)) { $index } })
    $removeLine = @(for ($index = 0; $index -lt $lines.Count; $index++) { if ($lines[$index] -match 'Action start [0-9:]+: RemoveExistingProducts\.') { $index } })
    # The best-effort pre-stop must finish before the outer transaction costs
    # files, because Windows Installer records files in use during costing.
    $preStopLines = @(for ($index = 0; $index -lt $lines.Count; $index++) { if ($lines[$index] -match 'go-mapi suite app pre-stop') { $index } })
    $executeLine = @(for ($index = 0; $index -lt $lines.Count; $index++) { if ($lines[$index] -match ': Running ExecuteSequence') { $index } })
    $executeStart = if ($executeLine.Count) { $executeLine[0] } else { 0 }
    $costLine = @(for ($index = $executeStart; $index -lt $lines.Count; $index++) { if ($lines[$index] -match 'Action start [0-9:]+: CostInitialize\.') { $index } })
    $preStopSummary = @($lines | Where-Object { $_ -match 'go-mapi suite app pre-stop: terminated=[0-9]+ skipped=[0-9]+' } | Select-Object -First 1)
    $setupErrors = @($lines | Where-Object { $_ -match 'go-mapi setup could not' })
    # Final uninstall removes the machine marker; a snapshot then has nothing to read.
    $after = if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\go-mapi\MachineProduct') { MachineSnapshot } else { $null }
    $evidence = [ordered]@{
        Step = $Name; Verb = $Verb; Expected = $Expected; Exit = $exit
        RunningBefore = @($running | ForEach-Object { [ordered]@{ Pid = $_.ProcessId; Session = $_.SessionId } })
        Survivors = @($survivors | ForEach-Object { [ordered]@{ Pid = $_.ProcessId; Session = $_.SessionId } })
        NewPendingRenames = $newRenames; InUseOrRebootLines = $inUse
        DecoyAlive = [bool]($script:decoy -and -not $script:decoy.HasExited)
        StopLogLine = if ($stopLine.Count) { $stopLine[0] } else { $null }
        PreStopLine = if ($preStopSummary.Count) { $preStopSummary[0] } else { $null }
        PreStopLastLogLine = if ($preStopLines.Count) { $preStopLines[-1] } else { $null }
        PreStopTerminated = if ($preStopSummary.Count -and $preStopSummary[0] -match 'terminated=([0-9]+)') { [int]$Matches[1] } else { $null }
        PreStopSkipped = if ($preStopSummary.Count -and $preStopSummary[0] -match 'skipped=([0-9]+)') { [int]$Matches[1] } else { $null }
        CostInitializeLine = if ($costLine.Count) { $costLine[0] } else { $null }
        SetupErrorLines = $setupErrors
        RemoveExistingProductsLine = if ($removeLine.Count) { $removeLine[0] } else { $null }
        GateAfter = Get-GateState; Before = $before; After = $after
    }
    Write-Evidence ($Name + '-running-apps') $evidence
    $failures = @()
    if ($exit -eq 3010) { $failures += 'exit 3010 (reboot required)' }
    elseif ($exit -ne $Expected) { $failures += "exit $exit, expected $Expected" }
    if ($newRenames.Count) { $failures += "new PendingFileRenameOperations: $($newRenames -join ', ')" }
    if ($inUse.Count) { $failures += "files-in-use or reboot log lines: $($inUse -join ' | ')" }
    if ($survivors.Count -and -not $AllowSurvivors) { $failures += "installed app still running: $(@($survivors | ForEach-Object { "$($_.ProcessId)/s$($_.SessionId)" }) -join ', ')" }
    if (-not $evidence.DecoyAlive) { $failures += 'same-name process with another image was stopped' }
    if ($ExpectMessage -and -not @($lines | Where-Object { $_.Contains($ExpectMessage) })) { $failures += "verbose log lacks the setup message '$ExpectMessage'" }
    if ($Expected -eq 0 -and $setupErrors.Count) { $failures += "successful transaction reported a setup error: $($setupErrors -join ' | ')" }
    # The stop marker is checked last, so packages without the stop still
    # report the behavioral defect above.
    if (-not $stopLine.Count) { $failures += 'verbose log lacks the suite app stop' }
    elseif ($removeLine.Count -and $removeLine[0] -lt $stopLine[0]) { $failures += 'RemoveExistingProducts started before the suite app stop completed' }
    if (-not $preStopLines.Count) { $failures += 'verbose log lacks the suite app pre-stop' }
    elseif (-not $costLine.Count -or $preStopLines[-1] -gt $costLine[0]) { $failures += 'suite app pre-stop did not finish before the outer CostInitialize' }
    [pscustomobject]@{ Event = 'RunningAppTransaction'; Step = $Name; Exit = $exit; Survivors = $survivors.Count;
        NewPendingRenames = $newRenames.Count; Failures = $failures } | ConvertTo-Json -Compress -Depth 4
    if ($failures.Count) { throw "$Name with installed apps running failed: $($failures -join '; '); inspect $LogDirectory" }
    # With a suite installed afterwards, admission reopens within 15 s of the
    # msiexec exit. After a rollback the time is recorded only; the launch
    # check keeps its own 120 s bound.
    if (@(RelatedProducts $suiteCode).Count -eq 1) {
        $bound = if ($Expected -eq 0) { 15 } else { 120 }
        $evidence.GateOpenSeconds = Measure-GateOpen $script:LastMsiExitTime $bound
        Write-Evidence ($Name + '-running-apps') $evidence
        [pscustomobject]@{ Event = 'GateOpen'; Step = $Name; Exit = $exit; Seconds = $evidence.GateOpenSeconds; Bound = $bound } | ConvertTo-Json -Compress
        if ($Expected -eq 0) { Wait-GateOpen $Name 15 -FromMsiExit }
    }
    Stop-Decoy
}
# On-demand launch through the installed interceptor (the system MAPI stub
# loads go-mapi.dll from the registered DLLPath), in an interactive session
# when one exists, else in the current session.
function Assert-LaunchRestored([string]$Step) {
    Wait-GateOpen $Step
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $acl = Get-Acl -LiteralPath $testRoot
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.SecurityIdentifier]'S-1-5-32-545', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $testRoot -AclObject $acl
    $result = Join-Path $testRoot ('send-' + [guid]::NewGuid().ToString('N') + '.txt')
    $sender = Join-Path $testRoot 'mapi-send.ps1'
    Set-Content -LiteralPath $sender -Encoding ascii -Value @'
param([string]$Result)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
public class GoMapiLifecycleMessage {
    public int Reserved; public string Subject; public string NoteText; public string MessageType;
    public string DateReceived; public string ConversationId; public int Flags; public IntPtr Originator;
    public int RecipientCount; public IntPtr Recipients; public int FileCount; public IntPtr Files;
}
public static class GoMapiLifecycleSender {
    [DllImport("mapi32.dll", CharSet = CharSet.Ansi)]
    public static extern int MAPISendMail(IntPtr session, IntPtr window, GoMapiLifecycleMessage message, int flags, int reserved);
}
"@
$message = New-Object GoMapiLifecycleMessage
$message.Subject = 'go-mapi lifecycle on-demand launch probe'
$message.NoteText = 'Installed interceptor launch check.'
[IO.File]::WriteAllText($Result, [string][GoMapiLifecycleSender]::MAPISendMail([IntPtr]::Zero, [IntPtr]::Zero, $message, 0, 0))
'@
    $users = @(Get-SessionUsers)
    # A running single instance would absorb the launch; start from none.
    Get-InstalledApps | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $known = @(Get-InstalledApps | ForEach-Object ProcessId)
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$sender`" -Result `"$result`""
    $senderProcess = $null
    if ($users.Count) {
        $principal = New-ScheduledTaskPrincipal -UserId $users[0].User -LogonType Interactive -RunLevel Limited
        Start-TestTask 'send' $powerShell $arguments $principal | Out-Null
    } else {
        # Without another session (hosted runners) the sender runs here. The
        # interceptor starts the resident app as the sender's child, and
        # Start-Process -Wait would wait for that descendant too: never wait
        # for the tree, only for the sender itself.
        $senderProcess = Start-Process -FilePath $powerShell -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $null = $senderProcess.Handle # keeps the exit code readable after exit
    }
    $senderExited = $null
    $senderExitCode = $null
    $deadline = (Get-Date).AddSeconds(60)
    $launched = @()
    try {
        do {
            Start-Sleep -Seconds 1
            $launched = @(Get-InstalledApps | Where-Object { $known -notcontains $_.ProcessId })
            $code = if (Test-Path -LiteralPath $result) { (Get-Content -LiteralPath $result -Raw).Trim() } else { $null }
        } while (((-not $launched.Count) -or $null -eq $code) -and (Get-Date) -lt $deadline)
    } finally {
        if ($senderProcess) {
            # Process.WaitForExit(int) waits for this process only.
            $senderExited = $senderProcess.WaitForExit(30000)
            if ($senderExited) { $senderExitCode = $senderProcess.ExitCode }
            else { Stop-Process -Id $senderProcess.Id -Force -ErrorAction SilentlyContinue }
        }
    }
    $clientExplorer = [bool](@(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -eq $clientSession }).Count)
    [pscustomobject]@{ Event = 'LaunchRestored'; Step = $Step; MapiResult = $code;
        Launched = @($launched | ForEach-Object { [pscustomobject]@{ Pid = $_.ProcessId; Session = $_.SessionId } });
        SenderInClientSession = [bool]$senderProcess; SenderExited = $senderExited; SenderExitCode = $senderExitCode;
        ClientSession = $clientSession; ClientSessionExplorer = $clientExplorer } |
        ConvertTo-Json -Compress -Depth 4
    if ($code -ne '0') { throw "$Step`: MAPISendMail through the installed interceptor returned '$code'" }
    if (-not $launched.Count) { throw "$Step`: the interceptor did not launch the installed app on demand" }
    if ($senderProcess -and -not $senderExited) { throw "$Step`: the launch probe sender did not exit within 30 s after the probe" }
}
function Remove-TestResidue() {
    Remove-TestTasks
    Stop-Decoy
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
# Focused cases start from a clean machine and end clean, so each running-app
# path records its own verdict (also on packages that lack the stop).
function Invoke-FocusedRunningAppCase([string]$Case) {
    $source = if ($Case -eq 'Published') { (Resolve-Path -LiteralPath $PublishedSuiteMsi).Path } else { $suitePath }
    try {
        AssertExit (RunMsi '/i' $source ("focused-$Case-install".ToLowerInvariant()) @('GOMAPI_AUTO_UPDATE=0')) 0 "focused $Case suite install"
        AssertMachine 'suite' $sentinel
        switch ($Case) {
            'Repair' {
                Invoke-RunningAppTransaction '/fa' $suitePath 'focused-repair' @()
                AssertMachine 'suite' $sentinel
                Assert-LaunchRestored 'focused repair'
            }
            'PreStopThrow' {
                Invoke-RunningAppTransaction '/fa' $suitePath 'focused-repair-pre-stop-throw' @('GOMAPI_TEST_FAILURE_POINT=pre-stop-throw') `
                    -ExpectMessage 'go-mapi suite app pre-stop ignored an error'
                AssertMachine 'suite' $sentinel
                Assert-LaunchRestored 'focused repair after an ignored pre-stop error'
            }
            'Upgrade' {
                $old = MachineSnapshot
                Invoke-RunningAppTransaction '/i' $newerSuitePath 'focused-upgrade' @()
                AssertMachine 'suite' $sentinel
                if ((MachineSnapshot).PackageRelease -eq $old.PackageRelease) { throw 'focused upgrade did not install the newer suite' }
                Assert-LaunchRestored 'focused upgrade'
            }
            'UpgradeApp' {
                $old = MachineSnapshot
                Invoke-RunningAppTransaction '/i' $newerAppSuitePath 'focused-upgrade-app' @()
                AssertMachine 'suite' $sentinel
                $new = MachineSnapshot
                if ($new.AppHash -eq $old.AppHash -or $new.AppVersion -eq $old.AppVersion) { throw 'focused app upgrade did not replace the app' }
                Assert-LaunchRestored 'focused app upgrade'
            }
            'Published' {
                $old = MachineSnapshot
                Invoke-RunningAppTransaction '/i' $newerSuitePath 'focused-published-upgrade' @()
                AssertMachine 'suite' $sentinel
                $new = MachineSnapshot
                if ($new.PackageRelease -eq $old.PackageRelease -or $new.AppHash -eq $old.AppHash) { throw 'upgrade from published suite did not replace the app' }
                Assert-LaunchRestored 'focused published upgrade'
            }
            'Uninstall' {
                Invoke-RunningAppTransaction '/x' $suitePath 'focused-uninstall' @()
                if (@(RelatedProducts $suiteCode).Count -ne 0 -or (Test-Path -LiteralPath (Split-Path $appImage))) { throw 'focused uninstall left the suite app behind' }
            }
            'Switch' {
                Invoke-RunningAppTransaction '/i' $systemPath 'focused-switch' @('GOMAPI_MIGRATE_SKU=1')
                AssertMachine 'system' $sentinel
                if (Test-Path -LiteralPath (Split-Path $appImage)) { throw 'suite-to-system switch left the suite app payload' }
                if ((Get-GateState) -eq 'O') { throw 'suite-to-system switch left suite admission open' }
            }
        }
        [pscustomobject]@{ Event = 'FocusedRunningAppCasePass'; Case = $Case } | ConvertTo-Json -Compress
    } finally {
        Get-InstalledApps | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        foreach ($code in @(RelatedProducts $suiteCode) + @(RelatedProducts $systemCode)) {
            RunMsi '/x' $code ("focused-$Case-cleanup".ToLowerInvariant()) | Out-Null
        }
        Remove-TestResidue
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
if ($PublishedSuiteMsi) { Invoke-FocusedRunningAppCase 'Published'; return }
if ($RunningAppCase -ne 'All') { Invoke-FocusedRunningAppCase $RunningAppCase; return }

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
Invoke-RunningAppTransaction '/fa' $suitePath 'suite-repair-preserve-disabled'
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteInitial 'suite repair'
Assert-LaunchRestored 'suite repair with apps running'
# The pre-stop is best effort: an error in it is logged and ignored, never
# shown as a setup error, and the deferred stop still stops every instance.
Invoke-RunningAppTransaction '/fa' $suitePath 'suite-repair-pre-stop-throw' @('GOMAPI_TEST_FAILURE_POINT=pre-stop-throw') `
    -ExpectMessage 'go-mapi suite app pre-stop ignored an error'
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteInitial 'suite repair after an ignored pre-stop error'
Assert-LaunchRestored 'suite repair after an ignored pre-stop error'
WithRollbackDisabled {
    AssertExit (RunMsi '/fa' $suitePath 'suite-repair-rollback-disabled') 1603 'rollback-disabled suite repair'
}
AssertSnapshot $suiteInitial 'rollback-disabled suite repair'
# Windows Installer /f repair does not forward a supplied public setting into the elevated transaction.
# Re-enter through /i with explicit reinstall mode when an administrator changes the choice.
AssertExit (RunMsi '/i' $suitePath 'suite-enable-update' @('REINSTALL=ALL', 'REINSTALLMODE=amus', 'GOMAPI_AUTO_UPDATE=1')) 0 'suite explicit update enable'
if ((MachineSnapshot).AutoUpdateEnabled -ne 1) { throw 'Suite explicit setting enable failed' }
AssertExit (RunMsi '/fa' $suitePath 'suite-repair-preserve-enabled') 0 'suite repair preserving enabled setting'
$suiteBeforeFailedRepair = MachineSnapshot
AssertExit (RunMsi '/i' $suitePath 'suite-repair-after-registration-fault' @('REINSTALL=ALL', 'REINSTALLMODE=amus', 'GOMAPI_TEST_FAILURE_POINT=after-registration')) 1603 'suite failed repair after registration'
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteBeforeFailedRepair 'suite failed repair after registration'
$suiteBeforeUpgrade = MachineSnapshot
Invoke-RunningAppTransaction '/i' $newerSuitePath 'suite-upgrade-after-registration-fault' @('GOMAPI_TEST_FAILURE_POINT=after-registration') -Expected 1603
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteBeforeUpgrade 'newer suite failed upgrade'
Assert-LaunchRestored 'newer suite rollback after registration'
# Rollback right after a real stop, and the bounded-stop failure branch with
# its actionable message: the old product stays and launch is restored.
Invoke-RunningAppTransaction '/i' $newerSuitePath 'suite-upgrade-after-suite-stop-fault' @('GOMAPI_TEST_FAILURE_POINT=after-suite-stop') -Expected 1603
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteBeforeUpgrade 'newer suite rollback after suite app stop'
Assert-LaunchRestored 'newer suite rollback after suite app stop'
Invoke-RunningAppTransaction '/i' $newerSuitePath 'suite-upgrade-suite-stop-bound-fault' @('GOMAPI_TEST_FAILURE_POINT=suite-stop-bound') -Expected 1603 -AllowSurvivors `
    -StopMarker 'go-mapi suite app stop bound exceeded' `
    -ExpectMessage 'go-mapi setup could not close the running go-mapi app in every user session'
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteBeforeUpgrade 'newer suite bounded suite app stop failure'
Assert-LaunchRestored 'newer suite bounded suite app stop failure'
$suiteJournalBeforeUpgrade = JournalSnapshot
foreach ($point in @('before-prepare', 'after-partial-snapshot', 'after-snapshot')) {
    AssertExit (RunMsi '/i' $newerSuitePath ('suite-upgrade-' + $point + '-fault') @('GOMAPI_TEST_FAILURE_POINT=' + $point)) 1603 ('newer suite rollback at ' + $point)
    AssertMachine 'suite' $sentinel
    AssertSnapshot $suiteBeforeUpgrade ('newer suite ' + $point + ' fault')
    AssertJournal $suiteJournalBeforeUpgrade ('newer suite ' + $point + ' fault')
}
Invoke-RunningAppTransaction '/i' $newerSuitePath 'suite-upgrade'
AssertMachine 'suite' $sentinel
if ((MachineSnapshot).PackageRelease -eq $suiteBeforeUpgrade.PackageRelease -or
    (MachineSnapshot).ServiceHash -eq $suiteBeforeUpgrade.ServiceHash) { throw 'Suite upgrade did not replace the machine payload' }
Assert-LaunchRestored 'suite manual same-SKU upgrade'
if ((MachineSnapshot).AutoUpdateEnabled -ne 1) { throw 'Suite upgrade did not preserve enabled setting' }
WithRollbackDisabled {
    AssertExit (RunMsi '/x' $newerSuitePath 'suite-final-rollback-disabled') 1603 'rollback-disabled suite final uninstall'
}
AssertMachine 'suite' $sentinel
$suiteBeforeFinalUninstall = MachineSnapshot
Invoke-RunningAppTransaction '/x' $newerSuitePath 'suite-final-after-destructive-fault' @('GOMAPI_TEST_FAILURE_POINT=after-uninstall-finalize') -Expected 1603
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteBeforeFinalUninstall 'suite final uninstall fault'
Assert-ServiceConfiguration 'suite final uninstall rollback'
Assert-LaunchRestored 'suite final uninstall rollback'
Invoke-RunningAppTransaction '/x' $newerSuitePath 'suite-final-uninstall'
if (@(RelatedProducts $suiteCode).Count -ne 0 -or (Get-Service go-mapi -ErrorAction SilentlyContinue)) { throw 'Suite final uninstall left product or service' }
if (Test-Path -LiteralPath (Split-Path $appImage)) { throw 'Suite final uninstall left the suite app payload' }

# The same-version upgrade above keeps go-mapi.exe. This upgrade replaces the
# running app file itself, so Windows Installer checks it for use.
AssertExit (RunMsi '/i' $suitePath 'suite-app-upgrade-base' @('GOMAPI_AUTO_UPDATE=0')) 0 'suite install before app upgrade'
AssertMachine 'suite' $sentinel
$suiteBeforeAppUpgrade = MachineSnapshot
Invoke-RunningAppTransaction '/i' $newerAppSuitePath 'suite-upgrade-app'
AssertMachine 'suite' $sentinel
if ((MachineSnapshot).AppHash -eq $suiteBeforeAppUpgrade.AppHash -or
    (MachineSnapshot).AppVersion -eq $suiteBeforeAppUpgrade.AppVersion) { throw 'Suite app upgrade did not replace the app' }
Assert-LaunchRestored 'suite upgrade that replaces the app'
Invoke-RunningAppTransaction '/x' $newerAppSuitePath 'suite-app-upgrade-uninstall'
if (@(RelatedProducts $suiteCode).Count -ne 0 -or (Test-Path -LiteralPath (Split-Path $appImage))) { throw 'Suite uninstall after app upgrade left the suite app behind' }

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
$systemJournalBeforeMigration = JournalSnapshot
foreach ($point in @('before-prepare', 'after-partial-snapshot', 'after-snapshot')) {
    AssertExit (RunMsi '/i' $suitePath ('suite-migration-' + $point + '-fault') @('GOMAPI_MIGRATE_SKU=1', ('GOMAPI_TEST_FAILURE_POINT=' + $point))) 1603 ('suite migration rollback at ' + $point)
    AssertMachine 'system' $sentinel
    AssertSnapshot $systemBeforeMigration ('suite migration ' + $point + ' fault')
    AssertJournal $systemJournalBeforeMigration ('suite migration ' + $point + ' fault')
}
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
Invoke-RunningAppTransaction '/i' $systemPath 'system-after-removal-fault' @('GOMAPI_MIGRATE_SKU=1', 'GOMAPI_TEST_FAILURE_POINT=after-cleanup') -Expected 1603
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteBeforeMigration 'system migration after-cleanup fault'
Assert-LaunchRestored 'system migration rollback after cleanup'
Invoke-RunningAppTransaction '/i' $systemPath 'system-after-registration-fault' @('GOMAPI_MIGRATE_SKU=1', 'GOMAPI_TEST_FAILURE_POINT=after-registration') -Expected 1603
AssertMachine 'suite' $sentinel
AssertSnapshot $suiteBeforeMigration 'system migration after-registration fault'
Assert-LaunchRestored 'system migration rollback after registration'
Invoke-RunningAppTransaction '/i' $systemPath 'system-migration' @('GOMAPI_MIGRATE_SKU=1')
AssertMachine 'system' $sentinel
if (Test-Path -LiteralPath (Split-Path $appImage)) { throw 'Suite to system migration left the suite app payload' }
if ((Get-GateState) -eq 'O') { throw 'Suite to system migration left suite admission open' }
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
    Remove-TestResidue
}
