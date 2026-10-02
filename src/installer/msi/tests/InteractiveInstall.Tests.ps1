#Requires -Version 5.1
<#
Reviewed native attempt harness for interactive (non-/qn) machine MSI installs on a
disposable Windows guest. It never supplies consent or credentials and never adds
/qn, /qb, RunAs, transforms or scope overrides; UAC stays a human/observer action.

  Snapshot  (elevated, lab control)  record machine state to <EvidenceDirectory>\<Label>.json
  Launch    (medium desktop only)    assert medium token/account/session, hash the staged
                                     package, run System32 msiexec full UI with /l*vx and
                                     record the real exit code
  Assert    (elevated, lab control)  compare a snapshot with an expected outcome and
                                     summarise the verbose log and MsiInstaller events

Explorer double-click attempts use Snapshot/Assert around a desktop observation; they have no
direct child exit, so Assert reads the correlated MsiInstaller 1033/1034/11707/11708 events.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Snapshot', 'Launch', 'Assert')][string]$Mode,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [string]$Label = 'snapshot',
    [string]$MsiPath,
    [string]$ExpectedSha256,
    [ValidateSet('FilteredAdministrator', 'StandardUser')][string]$Account,
    [ValidateSet('Install', 'Uninstall')][string]$Operation = 'Install',
    [string]$ProductCode,
    [ValidateSet('Suite', 'System', 'Baseline')][string]$Expect,
    [string]$BaselineLabel = 'baseline',
    [string]$LogPath,
    # JSON object of payload path (relative to %ProgramFiles%\go-mapi) -> SHA256 from the built package inputs.
    [string]$ExpectedPayloadJson,
    [datetime]$Since = [datetime]::MinValue
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$systemUpgradeCode = '{B3C97B33-3F10-47CA-9FA7-24EE3B75E325}'
$suiteUpgradeCode = '{2E050A24-94A2-4FC9-B176-C5CCC1225FE6}'
$mediumIntegrity = 'S-1-16-8192'
$providerDll = '%ProgramW6432%\go-mapi\interceptor\%PROCESSOR_ARCHITECTURE%\go-mapi.dll'

if (-not ('GoMapiTokenProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class GoMapiTokenProbe {
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr info, int length, out int returned);
    static IntPtr Query(IntPtr token, int cls) {
        int size;
        GetTokenInformation(token, cls, IntPtr.Zero, 0, out size);
        IntPtr buffer = Marshal.AllocHGlobal(size);
        if (!GetTokenInformation(token, cls, buffer, size, out size)) { Marshal.FreeHGlobal(buffer); throw new System.ComponentModel.Win32Exception(); }
        return buffer;
    }
    public static string Integrity(IntPtr token) {
        IntPtr buffer = Query(token, 25);
        try { return new SecurityIdentifier(Marshal.ReadIntPtr(buffer)).Value; } finally { Marshal.FreeHGlobal(buffer); }
    }
    public static int ElevationType(IntPtr token) {
        IntPtr buffer = Query(token, 18);
        try { return Marshal.ReadInt32(buffer); } finally { Marshal.FreeHGlobal(buffer); }
    }
    public static bool Elevated(IntPtr token) {
        IntPtr buffer = Query(token, 20);
        try { return Marshal.ReadInt32(buffer) != 0; } finally { Marshal.FreeHGlobal(buffer); }
    }
}
'@
}

function Get-FileSha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-RelatedProducts([string]$UpgradeCode) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    @($installer.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $installer, @($UpgradeCode)) | Where-Object { $_ })
}
function Get-ProductState([string]$Code) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    [int]$installer.GetType().InvokeMember('ProductState', 'GetProperty', $null, $installer, @($Code))
}

function Get-MachineSnapshot {
    $products = [ordered]@{}
    foreach ($entry in @(@('system', $systemUpgradeCode), @('suite', $suiteUpgradeCode))) {
        $products[$entry[0]] = @(Get-RelatedProducts $entry[1] | ForEach-Object {
            [ordered]@{ ProductCode = $_; State = Get-ProductState $_ } })
    }
    $service = @(Get-CimInstance Win32_Service -Filter "Name='go-mapi'" | ForEach-Object {
        [ordered]@{ State = $_.State; StartMode = $_.StartMode; StartName = $_.StartName; PathName = $_.PathName } })
    $root = Join-Path $env:ProgramFiles 'go-mapi'
    $payload = [ordered]@{}
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
            $payload[$_.FullName.Substring($root.Length + 1)] = Get-FileSha256 $_.FullName }
    }
    $providers = [ordered]@{}
    $apps = @()
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
        try {
            $mail = $base.OpenSubKey('SOFTWARE\Clients\Mail', $false)
            $client = $base.OpenSubKey('SOFTWARE\Clients\Mail\go-mapi', $false)
            $providers[$view.ToString()] = [ordered]@{
                Default = if ($mail) { [string]$mail.GetValue($null) } else { $null }
                DllPath = if ($client) { [string]$client.GetValue('DLLPath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
            }
            foreach ($disposable in @($mail, $client)) { if ($disposable) { $disposable.Dispose() } }
            $uninstall = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', $false)
            if ($uninstall) {
                foreach ($name in $uninstall.GetSubKeyNames()) {
                    $key = $uninstall.OpenSubKey($name, $false)
                    $display = [string]$key.GetValue('DisplayName')
                    if ($display -like 'go-mapi*') {
                        $apps += [ordered]@{ View = $view.ToString(); Key = $name; DisplayName = $display
                            DisplayVersion = [string]$key.GetValue('DisplayVersion'); SystemComponent = $key.GetValue('SystemComponent')
                            UninstallString = [string]$key.GetValue('UninstallString') }
                    }
                    $key.Dispose()
                }
                $uninstall.Dispose()
            }
        } finally { $base.Dispose() }
    }
    $shortcut = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'go-mapi\go-mapi.lnk'
    $startup = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'go-mapi-user-machine-v4' -ErrorAction SilentlyContinue
    $marker = Get-ItemProperty 'HKLM:\SOFTWARE\go-mapi\MachineProduct' -ErrorAction SilentlyContinue
    $journalRoot = Join-Path $env:ProgramData 'go-mapi\installer-journal'
    $journal = [ordered]@{}
    if (Test-Path -LiteralPath $journalRoot) {
        Get-ChildItem -LiteralPath $journalRoot -Recurse -Force | Sort-Object FullName | ForEach-Object {
            $journal[$_.FullName.Substring($journalRoot.Length)] = if ($_.PSIsContainer) { 'dir' } else { Get-FileSha256 $_.FullName } }
    }
    $sentinels = [ordered]@{}
    Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $path = Join-Path $_.FullName 'AppData\Local\go-mapi-test\profile-sentinel.txt'
        if (Test-Path -LiteralPath $path) { $sentinels[$_.Name] = Get-FileSha256 $path }
    }
    [ordered]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        Products = $products; Service = $service; Payload = $payload; Providers = $providers; Apps = $apps
        Shortcut = if (Test-Path -LiteralPath $shortcut) { (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut).TargetPath } else { $null }
        Startup = if ($startup) { $startup.'go-mapi-user-machine-v4' } else { $null }
        MarkerSku = if ($marker -and $marker.PSObject.Properties['SKU']) { $marker.SKU } else { $null }
        MarkerRelease = if ($marker -and $marker.PSObject.Properties['PackageRelease']) { $marker.PackageRelease } else { $null }
        Journal = $journal; ProfileSentinels = $sentinels
    }
}

function Get-DesktopContext {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $token = $identity.Token
    $process = Get-Process -Id $PID
    $shells = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -eq $process.SessionId })
    [ordered]@{
        User = $identity.Name; UserSid = $identity.User.Value; SessionId = $process.SessionId
        Integrity = [GoMapiTokenProbe]::Integrity($token); ElevationType = [GoMapiTokenProbe]::ElevationType($token)
        Elevated = [GoMapiTokenProbe]::Elevated($token)
        AdministratorsDenyOnly = [bool](@(@(& whoami.exe /groups) -match 'S-1-5-32-544' -match 'deny only').Count -eq 1)
        ExplorerInSession = $shells.Count
    }
}

New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

switch ($Mode) {
    'Snapshot' {
        $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Snapshot requires the elevated lab control session.' }
        Get-MachineSnapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory "$Label.json") -Encoding UTF8
        "INTERACTIVE_SNAPSHOT_READY label=$Label"
    }
    'Launch' {
        if (-not $Account) { throw 'Launch requires -Account.' }
        $context = Get-DesktopContext
        $context | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'launch-context.json') -Encoding UTF8
        if ($context.Integrity -ne $mediumIntegrity -or $context.Elevated) { throw "Launch context is not medium/unelevated: $($context.Integrity)" }
        if ($context.SessionId -lt 1 -or $context.ExplorerInSession -lt 1) { throw 'Launch must run in an interactive desktop session with Explorer.' }
        if ($Account -eq 'FilteredAdministrator' -and ($context.ElevationType -ne 3 -or -not $context.AdministratorsDenyOnly)) {
            throw 'Expected a UAC-filtered administrator token (elevation type 3, Administrators deny-only).'
        }
        if ($Account -eq 'StandardUser' -and ($context.ElevationType -ne 1 -or $context.AdministratorsDenyOnly -or
                ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
            throw 'Expected a standard user token without Administrators membership.'
        }
        $msiexec = Join-Path $env:WINDIR 'System32\msiexec.exe'
        $log = Join-Path $EvidenceDirectory 'attempt.log'
        if ($Operation -eq 'Install') {
            if (-not $MsiPath -or $ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Install launch requires -MsiPath and -ExpectedSha256.' }
            $actual = Get-FileSha256 $MsiPath
            if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw "Staged package hash mismatch: $actual" }
            $arguments = '/i "{0}" /norestart /l*vx "{1}"' -f $MsiPath, $log
        } else {
            if ($ProductCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw 'Uninstall launch requires -ProductCode.' }
            $actual = $null
            $arguments = '/x {0} /norestart /l*vx "{1}"' -f $ProductCode, $log
        }
        $started = (Get-Date).ToUniversalTime()
        $process = Start-Process -FilePath $msiexec -ArgumentList $arguments -PassThru -Wait
        $result = [ordered]@{ Operation = $Operation; Msi = $MsiPath; Sha256 = $actual; ProductCode = $ProductCode
            Started = $started.ToString('o'); Ended = (Get-Date).ToUniversalTime().ToString('o'); ExitCode = $process.ExitCode; Context = $context }
        $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'launch.json') -Encoding UTF8
        "INTERACTIVE_LAUNCH_EXIT=$($process.ExitCode)"
    }
    'Assert' {
        if (-not $Expect) { throw 'Assert requires -Expect.' }
        $after = Get-MachineSnapshot
        $after | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory "$Label.json") -Encoding UTF8
        $failures = [Collections.Generic.List[string]]::new()
        if ($Expect -eq 'Baseline') {
            $baseline = Get-Content -LiteralPath (Join-Path $EvidenceDirectory "$BaselineLabel.json") -Raw | ConvertFrom-Json
            foreach ($name in 'Products', 'Service', 'Payload', 'Providers', 'Apps', 'Shortcut', 'Startup', 'MarkerSku', 'MarkerRelease', 'Journal', 'ProfileSentinels') {
                $before = $baseline.$name | ConvertTo-Json -Depth 8 -Compress
                $now = ($after | ConvertTo-Json -Depth 8 | ConvertFrom-Json).$name | ConvertTo-Json -Depth 8 -Compress
                if ($before -ne $now) { $failures.Add("$name differs from $BaselineLabel") }
            }
        } else {
            $sku = $Expect.ToLowerInvariant()
            $other = if ($sku -eq 'suite') { 'system' } else { 'suite' }
            $mine = @($after.Products[$sku])
            if ($mine.Count -ne 1 -or $mine[0].State -ne 5) { $failures.Add("expected one installed $sku product (state 5)") }
            if ($ProductCode -and ($mine.Count -ne 1 -or $mine[0].ProductCode -ne $ProductCode)) { $failures.Add("installed $sku ProductCode is not $ProductCode") }
            if (@($after.Products[$other]).Count -ne 0) { $failures.Add("unexpected $other product") }
            if (@($after.Service).Count -ne 1 -or $after.Service[0].State -ne 'Running' -or $after.Service[0].StartName -ne 'LocalSystem') { $failures.Add('service is not one healthy LocalSystem service') }
            foreach ($view in $after.Providers.Keys) {
                if ($after.Providers[$view].Default -ne 'go-mapi' -or $after.Providers[$view].DllPath -ne $providerDll) { $failures.Add("$view MAPI provider registration is wrong") }
            }
            if ($after.MarkerSku -ne $sku) { $failures.Add("machine marker SKU is $($after.MarkerSku)") }
            $visible = @($after.Apps | Where-Object { $_.SystemComponent -ne 1 })
            if ($visible.Count -ne 1) { $failures.Add("expected one visible Apps entry, found $($visible.Count)") }
            $app = Join-Path $env:ProgramFiles 'go-mapi\user\go-mapi.exe'
            if ($sku -eq 'suite' -and ($after.Shortcut -ne $app -or $after.Startup -ne ('"' + $app + '" --startup --machine-install'))) { $failures.Add('suite shortcut or startup entry is wrong') }
            if ($sku -eq 'system' -and ($after.Shortcut -or $after.Startup)) { $failures.Add('system SKU carries suite app resources') }
            if ($ExpectedPayloadJson) {
                $expected = Get-Content -LiteralPath $ExpectedPayloadJson -Raw | ConvertFrom-Json
                foreach ($entry in $expected.PSObject.Properties) {
                    if (-not $after.Payload.Contains($entry.Name)) { $failures.Add("payload $($entry.Name) is missing") }
                    elseif ($after.Payload[$entry.Name] -ne ([string]$entry.Value).ToLowerInvariant()) { $failures.Add("payload $($entry.Name) hash differs") }
                }
            }
        }
        $summary = [ordered]@{ Expect = $Expect; Failures = @($failures) }
        if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
            $lines = Get-Content -LiteralPath $LogPath
            $firstFailure = $lines | Select-String -Pattern 'Return value 3\.' | Select-Object -First 1
            $summary.Log = [ordered]@{
                SfxcaErrors = @($lines | Select-String -SimpleMatch 'SFXCA: Failed' | ForEach-Object { $_.Line })
                FirstReturnValue3 = if ($firstFailure) { $firstFailure.Line } else { $null }
                PrecedingLines = if ($firstFailure) { @($lines[[Math]::Max(0, $firstFailure.LineNumber - 25)..($firstFailure.LineNumber - 1)]) } else { @() }
                Elevation = @($lines | Select-String -Pattern 'MSI_LUA|will be elevated|Credential Request return' | ForEach-Object { $_.Line })
                Completion = @($lines | Select-String -Pattern 'Product: .* -- |MainEngineThread is returning|Installation (success|operation)' | ForEach-Object { $_.Line })
            }
        }
        $summary.Events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MsiInstaller'; StartTime = $Since } -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -in 1033, 1034, 11707, 11708, 11724, 11725 } | Sort-Object TimeCreated |
            ForEach-Object { [ordered]@{ Time = $_.TimeCreated.ToUniversalTime().ToString('o'); Id = $_.Id; Message = ($_.Message -replace '\s+', ' ') } })
        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceDirectory "$Label-assert.json") -Encoding UTF8
        $summary | ConvertTo-Json -Depth 6
        if ($failures.Count -gt 0) { throw "INTERACTIVE_ASSERT_FAIL: $($failures -join '; ')" }
        "INTERACTIVE_ASSERT_PASS expect=$Expect"
    }
}
