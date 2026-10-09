[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceSHA,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [ValidateRange(1, 30)][int] $DeadlineMinutes = 30,
    [string] $JobStartedAtUtc
)

$ErrorActionPreference = 'Stop'
$null = Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force -PassThru
$ProgressPreference = 'SilentlyContinue'
$startedAt = [DateTime]::UtcNow
$jobStartedAt = if ($JobStartedAtUtc) { [DateTimeOffset]::Parse($JobStartedAtUtc).UtcDateTime } else { $startedAt }
$deadline = $jobStartedAt.AddMinutes($DeadlineMinutes)
$cleanupReserveMinutes = [Math]::Min(3, [Math]::Max(.25, $DeadlineMinutes * .1))
$workDeadline = $deadline.AddMinutes(-$cleanupReserveMinutes)
$script:deadline = $workDeadline
$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runId = [guid]::NewGuid().ToString('N')
$runRoot = 'C:\crabbox\work\ticket569'
$testUserName = 't569' + $runId.Substring(0, 10)
$user = $null
$password = $null
$passwordCanary = $null
$rdpForm = $null
$rdpControl = $null
$rdpConnected = $false
$activeSessionId = $null
$profilePath = $null
$vhdPath = Join-Path $runRoot "profile-$runId.vhdx"
$backupPath = $null
$promptCertificate = $null
$promptCertificatePath = $null
$promptImportResultPath = $null
$profileState = 'not-created'
$userCreated = $false
$rdpGroupAdded = $false
$failureLatched = $false
$cleanupErrors = [Collections.Generic.List[string]]::new()
$conditions = [Collections.Generic.List[object]]::new()
$steps = [Collections.Generic.List[object]]::new()
$normalResult = [ordered]@{ status='not-run'; evidence=$null }
$vhdResult = [ordered]@{ status='not-run'; evidence=$null }
$rootPromptResult = [ordered]@{ status='unknown'; reason='The pinned native rdpilot CUA route has not yet observed the exact owned CurrentUser Root consent prompt.' }
$verdict = 'unknown'
$positiveRoute = $false
$writeFailed = $false
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

function Write-Atomic([string] $Path, [object] $Value) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 48) + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Format-HResult([int] $Value) {
    return '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes($Value), 0)
}

function Latch-Failure([string] $Name, [string] $Class, [object] $Evidence = $null) {
    $script:failureLatched = $true
    $script:conditions.Add([pscustomobject]@{ name=$Name; class=$Class; evidence=$Evidence; at=[DateTime]::UtcNow.ToString('o') })
}

function Record-Step([string] $Name, [string] $Status, [object] $Evidence = $null, [Nullable[int]] $ExitCode = $null) {
    $step = [pscustomobject]@{ name=$Name; status=$Status; exitCode=$ExitCode; evidence=$Evidence; at=[DateTime]::UtcNow.ToString('o') }
    $script:steps.Add($step)
    try { Write-Atomic (Join-Path $EvidenceDirectory 'preflight-steps.json') @($script:steps) }
    catch { $script:writeFailed = $true; Latch-Failure 'evidence-write' 'harness-defect' $_.Exception.Message }
}

function Assert-HostedPhaseBudget([string] $Phase, [int] $RequiredSeconds, [ValidateSet('normal','vhd')][string] $ResultName) {
    $budget = Test-HostedPhaseBudget -NowUtc ([DateTime]::UtcNow) -WorkDeadlineUtc $workDeadline -RequiredSeconds $RequiredSeconds
    if ($budget.allowed) { return }
    $evidence = @{ phase=$Phase; remainingSeconds=$budget.remainingSeconds; requiredSeconds=$budget.requiredSeconds; workDeadlineUtc=$budget.workDeadlineUtc; classification='transient-setup' }
    if ($ResultName -eq 'normal') { $normalResult.status='transient-setup'; $normalResult.evidence=$evidence }
    else { $vhdResult.status='transient-setup'; $vhdResult.evidence=$evidence }
    Latch-Failure "$Phase-budget-exhausted" 'transient-setup' $evidence
    Record-Step $Phase 'skipped-budget-exhausted' $evidence
    throw "Remaining preflight work budget cannot fit the $Phase phase while preserving cleanup and evidence time"
}

function Add-WtsTypes {
    if ('Ticket569HostedWts' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Ticket569WtsSession { public Int32 SessionId; public IntPtr WinStationName; public Int32 State; }
public static class Ticket569HostedWts {
 [DllImport("Wtsapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool WTSEnumerateSessions(IntPtr server,int reserved,int version,out IntPtr sessions,out int count);
 [DllImport("Wtsapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool WTSQuerySessionInformation(IntPtr server,int sessionId,int infoClass,out IntPtr buffer,out int bytes);
 [DllImport("Wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr memory);
 static string Query(int id,int infoClass) { IntPtr b; int n; if(!WTSQuerySessionInformation(IntPtr.Zero,id,infoClass,out b,out n)) return null; try { return Marshal.PtrToStringUni(b); } finally { WTSFreeMemory(b); } }
 public static object[] Sessions() { IntPtr b; int count; if(!WTSEnumerateSessions(IntPtr.Zero,0,1,out b,out count)) throw new Win32Exception(Marshal.GetLastWin32Error()); try { List<object> r=new List<object>(); int size=Marshal.SizeOf(typeof(Ticket569WtsSession)); for(int i=0;i<count;i++){ Ticket569WtsSession s=(Ticket569WtsSession)Marshal.PtrToStructure(IntPtr.Add(b,i*size),typeof(Ticket569WtsSession)); r.Add(new { SessionId=s.SessionId, Station=Marshal.PtrToStringUni(s.WinStationName), State=s.State, User=Query(s.SessionId,5), Domain=Query(s.SessionId,7) }); } return r.ToArray(); } finally { WTSFreeMemory(b); } }
}
'@ -ErrorAction Stop
}

function Get-SidSessions([string] $SID) {
    foreach ($session in [Ticket569HostedWts]::Sessions()) {
        if (!$session.User) { continue }
        try { $sid = ([Security.Principal.NTAccount]"$($session.Domain)\$($session.User)").Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { continue }
        if ($sid -eq $SID) {
            [pscustomobject]@{ SessionId=[int]$session.SessionId; Station=[string]$session.Station; State=[int]$session.State; User=[string]$session.User; Domain=[string]$session.Domain; SID=$sid }
        }
    }
}

function Wait-ActiveUserSession([string] $SID, [int] $TimeoutSeconds) {
    $stopAt = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $matches = @(Get-SidSessions $SID | Where-Object { $_.State -eq 0 })
        if ($matches.Count -eq 1 -and $matches[0].SessionId -gt 0) { return $matches[0] }
        if ([DateTime]::UtcNow -ge $script:deadline) { throw 'Preflight deadline elapsed while waiting for the exact Active WTS SID/session' }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $stopAt)
    return $null
}

function Get-ProfileRecord([string] $SID) {
    Get-CimInstance Win32_UserProfile -Filter "SID='$SID'" -ErrorAction Stop | Select-Object -First 1
}

function Wait-ProfileUnloaded([string] $SID, [int] $SessionId, [int] $TimeoutSeconds) {
    $logoff = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\logoff.exe') -ArgumentList @([string]$SessionId) -PassThru -Wait
    $sessionGone = $false
    $stopAt = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $sessionGone = @((Get-SidSessions $SID) | Where-Object SessionId -eq $SessionId).Count -eq 0
        $profile = Get-ProfileRecord $SID
        $hiveGone = !(Test-Path "Registry::HKEY_USERS\$SID")
        if ($sessionGone -and (!$profile -or !$profile.Loaded) -and $hiveGone) { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $stopAt)
    if ($logoff.ExitCode -ne 0 -or !$sessionGone -or (Get-ProfileRecord $SID).Loaded -or (Test-Path "Registry::HKEY_USERS\$SID")) {
        throw "Exact RDP session/profile did not unload after logoff; exit=$($logoff.ExitCode)"
    }
    Record-Step 'exact-user-logoff-profile-unloaded' 'observed' @{ SID=$SID; sessionId=$SessionId; loaded=$false; hivePresent=$false; logoffExit=[int]$logoff.ExitCode } $logoff.ExitCode
}

function Connect-LoopbackRdp([string] $AccountName, [Security.SecureString] $SecurePassword, [string] $SID) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -TypeDefinition @'
using System;
using System.Windows.Forms;
public class Ticket569HostedRdpControl : AxHost {
 public Ticket569HostedRdpControl() : base(Type.GetTypeFromProgID("MsTscAx.MsTscAx.10").GUID.ToString("B")) {}
 public object ClientObject { get { return GetOcx(); } }
}
'@ -ReferencedAssemblies @('System.Windows.Forms.dll') -ErrorAction Stop
    $form = [Windows.Forms.Form]::new()
    $form.Text = "Ticket 569 hosted session preflight $runId"
    $form.Width = 1024; $form.Height = 768; $form.StartPosition = 'CenterScreen'
    $control = [Ticket569HostedRdpControl]::new()
    $control.Width = 1000; $control.Height = 700
    $form.Controls.Add($control)
    $flow = [hashtable]::Synchronized(@{ connected=$false; connectCalled=$false; error=$null; session=$null; deadline=[DateTime]::UtcNow.AddSeconds(45) })
    if ($script:deadline -lt $flow.deadline) { $flow.deadline = $script:deadline }
    $timer = [Windows.Forms.Timer]::new(); $timer.Interval = 250
    $form.add_Shown({
        try {
            $client = $control.ClientObject
            $client.Server = '127.0.0.1'
            $client.Domain = $env:COMPUTERNAME
            $client.UserName = $AccountName
            $client.AdvancedSettings9.EnableCredSspSupport = 1
            $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($SecurePassword)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringUni($passwordPointer)
                $client.AdvancedSettings9.ClearTextPassword = $plain
                $plain = $null
            } finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($passwordPointer) }
            $flow.connectCalled = $true
            $client.Connect()
            try { $client.AdvancedSettings9.ClearTextPassword = '' } catch { }
        } catch { $flow.error = @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message; hresult=(Format-HResult $_.Exception.HResult) } }
    }.GetNewClosure())
    $timer.add_Tick({
        if ($flow.error) { $timer.Stop(); $form.Close(); return }
        try {
            $found = @(Get-SidSessions $SID | Where-Object { $_.State -eq 0 -and $_.SessionId -gt 0 })
            if ($found.Count -eq 1) { $flow.session = $found[0]; $flow.connected=$true; $timer.Stop(); $form.Close(); return }
        } catch { $flow.error = @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message; hresult=(Format-HResult $_.Exception.HResult) }; $timer.Stop(); $form.Close(); return }
        if ([DateTime]::UtcNow -ge $flow.deadline) { $timer.Stop(); $form.Close() }
    }.GetNewClosure())
    $timer.Start()
    [Windows.Forms.Application]::Run($form)
    $script:rdpForm = $form
    $script:rdpControl = $control
    if ($flow.connected -and $flow.session) { $script:rdpConnected=$true; return [pscustomobject]@{ session=$flow.session; connectCalled=$flow.connectCalled; error=$flow.error; host='STA; AxHost-sited MsTscAx control; Windows Forms message pump'; loopback='127.0.0.1' } }
    return [pscustomobject]@{ session=$null; connectCalled=$flow.connectCalled; error=$flow.error; host='STA; AxHost-sited MsTscAx control; Windows Forms message pump'; loopback='127.0.0.1' }
}

function Get-ProcessOwnerSID([CimInstance] $Process) {
    try { $owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwnerSid -ErrorAction Stop; return [string]$owner.Sid }
    catch { return $null }
}

function Invoke-StandardUserProbe([string] $ProfileKind, [string] $SID, [int] $SessionId) {
    $scriptPath = Join-Path $PSScriptRoot 'hosted-user-capability.ps1'
    $observerPath = Join-Path $PSScriptRoot 'process-observer.ps1'
    $outputPath = Join-Path $EvidenceDirectory "user-$ProfileKind.json"
    $taskName = "Ticket569-$runId-$ProfileKind"
    $pwsh = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"",'-OutputPath',"`"$outputPath`"",'-RunId',$runId,'-ProfileKind',$ProfileKind,'-ExpectedSID',$SID,'-HoldAfterWriteSeconds','4')
    if ($ProfileKind -eq 'mount-point') { $arguments += @('-VhdPath',"`"$vhdPath`"") }
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument ($arguments -join ' ')
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$testUserName" -LogonType Interactive -RunLevel Limited
    $observedChildPid = $null; $attachedPath = Join-Path $EvidenceDirectory "user-$ProfileKind-attached.json"; $exitPath = Join-Path $EvidenceDirectory "user-$ProfileKind-exit.json"; $failurePath = Join-Path $EvidenceDirectory "user-$ProfileKind-observer-failure.json"
    $taskEvidence = $null; $result = $null
    try {
        if (Test-Path -LiteralPath $outputPath) { throw 'Fresh user probe result path is occupied' }
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $findUntil = [DateTime]::UtcNow.AddSeconds(20)
        do {
            $matches = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
                $_.CommandLine -and $_.CommandLine.Contains($scriptPath,[StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine.Contains($runId,[StringComparison]::OrdinalIgnoreCase) -and (Get-ProcessOwnerSID $_) -eq $SID
            })
            if ($matches.Count -eq 1) { $observedChildPid = [int]$matches[0].ProcessId; break }
            if ($matches.Count -gt 1) { throw 'More than one task child matched the run/SID; PID identity is ambiguous' }
            Start-Sleep -Milliseconds 150
        } while ([DateTime]::UtcNow -lt $findUntil)
        if (!$observedChildPid) { throw 'Task child PID was not observed for the exact user SID and command' }
        $observer = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',"`"$observerPath`"",'-TargetProcessId',[string]$observedChildPid,'-ExpectedCommand',$scriptPath,'-ExpectedRunId',$runId,'-AttachedPath',"`"$attachedPath`"",'-ExitPath',"`"$exitPath`"",'-FailurePath',"`"$failurePath`"",'-TimeoutSeconds','100') -PassThru -Wait
        if ($observer.ExitCode -ne 0 -or !(Test-Path $attachedPath) -or !(Test-Path $exitPath) -or (Test-Path $failurePath)) { throw 'Retained-handle task-child observation did not complete successfully' }
        $attached = Get-Content $attachedPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $waited = Get-Content $exitPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($attached.PID -ne $observedChildPid -or $waited.PID -ne $observedChildPid -or !$attached.HandleRetained -or !$waited.HandleRetained -or
            $attached.CreationFileTimeUtc -ne $waited.CreationFileTimeUtc -or $waited.ExitCode -ne 0) { throw 'Retained-handle task child PID/creation/exit evidence is inconsistent' }
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $taskEvidence = @{ Name=$taskName; State=[string]$task.State; LastRunTime=$taskInfo.LastRunTime.ToUniversalTime().ToString('o'); LastTaskResult=[int]$taskInfo.LastTaskResult; TaskChildPID=$observedChildPid; ChildCreationFileTimeUtc=$waited.CreationFileTimeUtc; WaitedChildExit=[int]$waited.ExitCode }
        if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop }
        $null = Wait-Process -Id $observedChildPid -Timeout 5 -ErrorAction SilentlyContinue
        if (Get-Process -Id $observedChildPid -ErrorAction SilentlyContinue) { throw 'Observed task child process remains after stop/wait' }
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        if ($taskInfo.LastRunTime -eq [DateTime]::MinValue -or $taskInfo.LastTaskResult -ne 0) { throw 'Scheduled task did not provide a successful completed instance result' }
        if (!(Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw 'Atomic child result is missing after the waited process exit' }
        $result = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($result.runId -ne $runId -or $result.sid -ne $SID -or $result.sessionId -ne $SessionId -or
            $result.processId -ne $observedChildPid -or $result.processCreationFileTimeUtc -ne $attached.CreationFileTimeUtc -or !$result.passed) {
            throw 'Post-exit child result does not match exact SID/session/process or probe conditions'
        }
        Record-Step "standard-user-$ProfileKind-probe" 'observed' @{ result=$result; task=$taskEvidence; attached=$attached; waitedExit=$waited }
        return [pscustomobject]@{ result=$result; task=$taskEvidence; attached=$attached; waitedExit=$waited }
    } finally {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            try {
                $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
                if (!$taskEvidence) { $taskEvidence = @{ Name=$taskName; State=[string]$task.State; LastRunTime=$taskInfo.LastRunTime.ToUniversalTime().ToString('o'); LastTaskResult=[int]$taskInfo.LastTaskResult; TaskChildPID=$observedChildPid } }
                if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop }
                if ($observedChildPid -and (Get-Process -Id $observedChildPid -ErrorAction SilentlyContinue)) { Stop-Process -Id $observedChildPid -Force -ErrorAction Stop }
                if ($observedChildPid -and (Get-Process -Id $observedChildPid -ErrorAction SilentlyContinue)) { throw 'User probe task child survived cleanup stop' }
                Record-Step "task-evidence-before-unregister-$ProfileKind" 'observed' $taskEvidence
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
                if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Owned task remains registered after cleanup' }
            } catch { $script:cleanupErrors.Add("$ProfileKind task/process cleanup failed: $($_.Exception.Message)"); Latch-Failure "task-cleanup-$ProfileKind" 'cleanup-failed' $_.Exception.Message }
        }
    }
}

function Disconnect-OwnedRdp {
    if ($script:rdpConnected -and $script:rdpControl) {
        try { $client = $script:rdpControl.ClientObject; if ($client.Connected -ne 0) { $client.Disconnect() } }
        catch { $script:cleanupErrors.Add("RDP disconnect failed: $($_.Exception.Message)") }
        $script:rdpConnected = $false
    }
    if ($script:rdpForm) { try { $script:rdpForm.Close(); $script:rdpForm.Dispose() } catch { $script:cleanupErrors.Add("RDP host disposal failed: $($_.Exception.Message)") }; $script:rdpForm=$null; $script:rdpControl=$null }
}

try {
    if ($env:GITHUB_ACTIONS -eq 'true' -and !$JobStartedAtUtc) { throw 'Workflow invocation omitted the job-wide start time required for the shared 30-minute deadline' }
    if ($SourceSHA -notmatch '^[0-9a-f]{40}$') { throw 'SourceSHA must be a full Git commit ID' }
    $head = (& git -C $sourceRoot rev-parse HEAD).Trim().ToLowerInvariant()
    $headExit = $LASTEXITCODE
    $status = (& git -C $sourceRoot status --porcelain --untracked-files=all | Out-String).Trim()
    if ($headExit -ne 0 -or $head -cne $SourceSHA.ToLowerInvariant() -or $head -cne $env:GITHUB_SHA.ToLowerInvariant() -or $status) { throw 'Preflight requires the exact clean workflow source SHA' }
    if ([DateTime]::UtcNow -ge $workDeadline) { throw 'Job-wide preflight work deadline elapsed during source preparation; reserved cleanup and evidence time remains' }
    if (Test-Path $vhdPath) { throw 'Unique preflight VHD path is unexpectedly occupied' }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $hostIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $hostAdmin = ([Security.Principal.WindowsPrincipal]$hostIdentity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Add-WtsTypes
    $sessionInventory = @([Ticket569HostedWts]::Sessions())
    $term = Get-CimInstance Win32_Service -Filter "Name='TermService'" -ErrorAction SilentlyContinue
    $denyPath = Join-Path $EvidenceDirectory 'user-rights.inf'
    $seceditText = (& secedit.exe /export /cfg $denyPath /areas USER_RIGHTS 2>&1 | Out-String)
    $seceditExit = $LASTEXITCODE
    $denyRdp = if ($seceditExit -eq 0 -and (Test-Path $denyPath)) { Select-String -LiteralPath $denyPath -Pattern '^SeDenyRemoteInteractiveLogonRight\s*=' | ForEach-Object Line } else { @() }
    $rdpPolicy = (Get-ItemProperty 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    $listener = @(Get-NetTCPConnection -State Listen -LocalPort 3389 -ErrorAction SilentlyContinue | Select-Object LocalAddress,LocalPort,OwningProcess)
    $hostRecord = [ordered]@{
        sourceSHA=$head; workflowSHA=$env:GITHUB_SHA; runnerImageOS=$env:ImageOS; runnerImageVersion=$env:ImageVersion; runnerName=$env:RUNNER_NAME
        osName=$os.Caption; osVersion=$os.Version; osBuild=$os.BuildNumber
        hostUser=$hostIdentity.Name; hostSID=$hostIdentity.User.Value; hostSessionId=(Get-Process -Id $PID).SessionId; hostIsAdmin=$hostAdmin; hostIsSystem=$hostIdentity.IsSystem
        hostUserInteractive=[Environment]::UserInteractive; wtsSessionInventory=$sessionInventory; termService=$term; fDenyTSConnections=$rdpPolicy
        listeners=$listener; denyRemoteInteractiveRights=$denyRdp; seceditExit=$seceditExit; seceditOutput=$seceditText
        documents=@('https://docs.github.com/actions/using-github-hosted-runners/about-github-hosted-runners','https://github.com/actions/runner-images')
        startedAtUtc=$startedAt.ToString('o')
    }
    Write-Atomic (Join-Path $EvidenceDirectory 'hosted-image.json') $hostRecord
    Record-Step 'host-image-source-and-session-inventory' 'observed' $hostRecord

    if (!$hostAdmin) { throw 'Hosted runner is not elevated enough to prepare and restore the disposable real profile' }
    $password = New-Object Security.SecureString
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $random = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $randomBytes = New-Object byte[] 32
    try {
        $random.GetBytes($randomBytes)
        foreach ($value in $randomBytes) { $password.AppendChar($alphabet[[int]$value % $alphabet.Length]) }
    } finally { [Array]::Clear($randomBytes,0,$randomBytes.Length); $random.Dispose() }
    foreach ($character in Get-HostedPasswordRequiredCharacters) { $password.AppendChar($character) }
    $passwordCanary = New-HostedSecretCanary $password
    $password.MakeReadOnly()
    $user = New-LocalUser -Name $testUserName -Password $password -AccountNeverExpires -PasswordNeverExpires:$false -Description 'Disposable Ticket 569 hosted preflight user' -ErrorAction Stop
    $userCreated = $true
    $profilePath = Join-Path 'C:\Users' $testUserName
    $promptCertificatePath = Join-Path $profilePath "root-prompt-$runId.cer"
    $promptImportResultPath = Join-Path $profilePath "root-import-$runId.json"
    $backupPath = "$profilePath.normal-backup"
    $admins = Get-LocalGroup -SID 'S-1-5-32-544'
    $adminMembers = @(Get-LocalGroupMember -Group $admins -ErrorAction Stop | ForEach-Object { $_.SID.Value })
    if ($adminMembers -contains $user.SID.Value) { throw 'Disposable user is present in Administrators' }
    $rdu = Get-LocalGroup -SID 'S-1-5-32-555'
    $rduMembers = @(Get-LocalGroupMember -Group $rdu -ErrorAction Stop | ForEach-Object { $_.SID.Value })
    if ($rduMembers -notcontains $user.SID.Value) { Add-LocalGroupMember -Group $rdu -Member $testUserName -ErrorAction Stop; $rdpGroupAdded=$true }
    Record-Step 'create-disposable-nonadmin-user-and-rights' 'observed' @{ name=$testUserName; sid=$user.SID.Value; administrator=$false; remoteDesktopUsersSID=$rdu.SID.Value; groupGrantAdded=$rdpGroupAdded; denyRdsRights=$denyRdp }

    $connection = Connect-LoopbackRdp -AccountName $testUserName -SecurePassword $password -SID $user.SID.Value
    $session = if ($connection.session) { $connection.session } else { Wait-ActiveUserSession $user.SID.Value 1 }
    if (!$session) {
        $class = if ($connection.error) { 'harness-defect' } else { 'unknown' }
        Latch-Failure 'hosted-normal-signin' $class @{ connection=$connection; fDenyTSConnections=$rdpPolicy; termService=$term; listeners=$listener; denyRights=$denyRdp }
        $normalResult.status = $class
        $normalResult.evidence = $connection
        throw 'Hosted STA/sited RDP session was not positively observed; this is not an unavailable-capability verdict'
    }
    $activeSessionId = [int]$session.SessionId
    $profileState = 'normal'
    $positiveRoute = $true
    Record-Step 'exact-active-user-wts-session' 'observed' $session
    Assert-HostedPhaseBudget -Phase 'normal-session-probe' -RequiredSeconds 125 -ResultName normal
    $normalProbe = Invoke-StandardUserProbe -ProfileKind normal -SID $user.SID.Value -SessionId $activeSessionId
    $normalResult.status = if ($normalProbe.result.passed) { 'feasible-observed' } else { 'harness-defect' }
    $normalResult.evidence = $normalProbe
    if (!$normalProbe.result.passed) { Latch-Failure 'normal-session-probe' 'harness-defect' $normalProbe }

    # Exercise only a fresh, uniquely named certificate consent prompt in the
    # exact already-observed standard-user session. This does not import MSI,
    # package, or test-signing trust and always removes the transient cert.
    if (!$env:RDPILOT_BIN_DIR -or !(Test-Path (Join-Path $env:RDPILOT_BIN_DIR 'rdpilot.exe')) -or
        !(Test-Path (Join-Path $env:RDPILOT_BIN_DIR 'rdpilot-mcp.exe'))) {
        throw 'Pinned hosted CUA client/MCP build is unavailable'
    }
    $promptSubject = "CN=Ticket569-Root-Prompt-$runId"
    $promptCertificate = New-SelfSignedCertificate -Type Custom -Subject $promptSubject `
        -KeyUsage CertSign,CRLSign -KeyUsageProperty Sign `
        -TextExtension @('2.5.29.19={critical}{text}ca=TRUE') `
        -CertStoreLocation Cert:\LocalMachine\My -NotAfter ([DateTime]::Now.AddHours(2)) -ErrorAction Stop
    $null = Export-Certificate -Cert $promptCertificate -FilePath $promptCertificatePath -Type CERT -Force -ErrorAction Stop
    $promptEvidencePath = Join-Path $EvidenceDirectory 'current-user-root-prompt.json'
    $rootObserverScript = Join-Path $PSScriptRoot 'process-observer.ps1'
    $rootObserverAttachedPath = Join-Path $profilePath "root-import-attached-$runId.json"
    $rootObserverExitPath = Join-Path $profilePath "root-import-exit-$runId.json"
    $rootObserverFailurePath = Join-Path $profilePath "root-import-observer-failure-$runId.json"
    $pythonCommand = Get-Command python -ErrorAction Stop
    $promptStart = [Diagnostics.ProcessStartInfo]::new($pythonCommand.Source)
    $promptStart.UseShellExecute = $false
    $promptStart.RedirectStandardInput = $true
    foreach ($argument in @(
        (Join-Path $PSScriptRoot 'hosted_cua_prompt.py'), '--bin-dir', $env:RDPILOT_BIN_DIR,
        '--host', '127.0.0.1', '--port', '3389', '--username', $testUserName, '--domain', $env:COMPUTERNAME,
        '--expected-name', $promptCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false),
        '--expected-sid', $user.SID.Value, '--expected-session-id', [string]$activeSessionId,
        '--run-id', $runId, '--thumbprint', $promptCertificate.Thumbprint,
        '--certificate-path', $promptCertificatePath,
        '--import-script', (Join-Path $PSScriptRoot 'hosted-root-import.ps1'),
        '--observer-script', $rootObserverScript,
        '--observer-attached', $rootObserverAttachedPath,
        '--observer-exit', $rootObserverExitPath,
        '--observer-failure', $rootObserverFailurePath,
        '--import-result', $promptImportResultPath, '--evidence', $promptEvidencePath,
        '--connect-timeout', '180', '--prompt-timeout', '30', '--close-timeout', '10', '--child-timeout', '120'
    )) { $promptStart.ArgumentList.Add([string]$argument) }
    $promptProcess = [Diagnostics.Process]::Start($promptStart)
    $passwordBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
    try {
        $passwordForPipe = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordBstr)
        $promptProcess.StandardInput.WriteLine((ConvertTo-Json -InputObject @{ password=$passwordForPipe } -Compress))
        $promptProcess.StandardInput.Flush(); $promptProcess.StandardInput.Close()
        $passwordForPipe = $null
    } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBstr) }
    $promptWaitMs = [int][Math]::Max(1000, [Math]::Min(8 * 60 * 1000, ($workDeadline - [DateTime]::UtcNow).TotalMilliseconds))
    if (!$promptProcess.WaitForExit($promptWaitMs)) {
        $promptProcess.Kill($true); $promptProcess.WaitForExit(10000) | Out-Null
        throw 'Pinned native CUA CurrentUser Root prompt route exceeded its bounded deadline'
    }
    if ($promptProcess.ExitCode -ne 0 -or !(Test-Path -LiteralPath $promptEvidencePath -PathType Leaf)) {
        $promptDetail = if (Test-Path $promptEvidencePath) { Get-Content $promptEvidencePath -Raw | ConvertFrom-Json } else { $null }
        $rootPromptResult = [ordered]@{ status='harness-defect'; evidence=$promptDetail; processExitCode=[int]$promptProcess.ExitCode }
        Latch-Failure 'current-user-root-prompt-route' 'harness-defect' $rootPromptResult
        throw 'Pinned native CUA did not positively observe, answer and verify the exact CurrentUser Root prompt'
    }
    $rootPromptResult = Get-Content -LiteralPath $promptEvidencePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($rootPromptResult.status -ne 'observed-and-answered' -or !$rootPromptResult.disconnected -or
        !$rootPromptResult.daemonStopped -or !$rootPromptResult.privateRuntimeRemoved -or !$rootPromptResult.secretCanaryAbsent -or
        !$rootPromptResult.importChild.passed -or !$rootPromptResult.importChild.removedObserved -or
        !$rootPromptResult.processObservation.exit.HandleRetained -or $rootPromptResult.processObservation.exit.ExitCode -ne 0) {
        $rootPromptResult.status = 'harness-defect'
        Latch-Failure 'current-user-root-prompt-route' 'harness-defect' $rootPromptResult
        throw 'CUA prompt evidence or exact CurrentUser Root add/remove proof is incomplete'
    }
    $conditions.Add([pscustomobject]@{ name='current-user-root-prompt-route'; class='observed'; evidence=$rootPromptResult; at=[DateTime]::UtcNow.ToString('o') })
    Record-Step 'current-user-root-prompt-route' 'observed-and-answered' $rootPromptResult
    Disconnect-OwnedRdp
    Wait-ProfileUnloaded -SID $user.SID.Value -SessionId $activeSessionId -TimeoutSeconds 40
    $activeSessionId = $null
    Assert-HostedPhaseBudget -Phase 'vhd-profile-preparation' -RequiredSeconds 180 -ResultName vhd
    $profileState = 'preparing'
    & (Join-Path $PSScriptRoot 'profile.ps1') -Action prepare-vhd -SID $user.SID.Value -ProfilePath $profilePath -VhdPath $vhdPath -BackupPath $backupPath -EvidenceDirectory (Join-Path $EvidenceDirectory 'vhd-prepare')
    $profileState = 'mounted'
    $vhdIdentity = Connect-LoopbackRdp -AccountName $testUserName -SecurePassword $password -SID $user.SID.Value
    if (!$vhdIdentity.session) { $vhdResult.status='unknown'; $vhdResult.evidence=$vhdIdentity; Latch-Failure 'hosted-vhd-signin' 'unknown' $vhdIdentity; throw 'Exact standard-user WTS session was not re-observed after VHD profile mount' }
    $activeSessionId = [int]$vhdIdentity.session.SessionId
    Record-Step 'vhd-active-user-wts-session' 'observed' $vhdIdentity
    Assert-HostedPhaseBudget -Phase 'vhd-session-probe' -RequiredSeconds 125 -ResultName vhd
    $vhdProbe = Invoke-StandardUserProbe -ProfileKind mount-point -SID $user.SID.Value -SessionId $activeSessionId
    $vhdResult.status = if ($vhdProbe.result.passed) { 'feasible-observed' } else { 'harness-defect' }
    $vhdResult.evidence = $vhdProbe
    if (!$vhdProbe.result.passed) { Latch-Failure 'vhd-session-probe' 'harness-defect' $vhdProbe }
} catch {
    if (!$failureLatched) {
        $kind = if ($_.Exception.Message -match 'timed out|temporar|download|network') { 'transient-setup' } else { 'harness-defect' }
        Latch-Failure 'preflight-exception' $kind @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message; hresult=(Format-HResult $_.Exception.HResult) }
    }
} finally {
    Disconnect-OwnedRdp
    if ($promptCertificate) {
        try {
            $privateCertPath = "Cert:\LocalMachine\My\$($promptCertificate.Thumbprint)"
            if (Test-Path -LiteralPath $privateCertPath) { Remove-Item -LiteralPath $privateCertPath -Force -ErrorAction Stop }
            if (Test-Path -LiteralPath $privateCertPath) { throw 'Temporary prompt fixture certificate remains in LocalMachine/My' }
        } catch { $cleanupErrors.Add("Temporary prompt certificate cleanup failed: $($_.Exception.Message)"); Latch-Failure 'prompt-certificate-cleanup' 'cleanup-failed' $_.Exception.Message }
    }
    try {
        foreach ($ownedPath in @($promptCertificatePath, $promptImportResultPath, $rootObserverAttachedPath, $rootObserverExitPath, $rootObserverFailurePath)) {
            if ($ownedPath) { Remove-Item -LiteralPath $ownedPath -Force -ErrorAction SilentlyContinue }
        }
        if (@($promptCertificatePath, $promptImportResultPath, $rootObserverAttachedPath, $rootObserverExitPath, $rootObserverFailurePath | Where-Object { $_ -and (Test-Path -LiteralPath $_) }).Count) {
            throw 'Temporary prompt certificate/result file remains after cleanup'
        }
    } catch { $cleanupErrors.Add("Temporary prompt certificate file cleanup failed: $($_.Exception.Message)"); Latch-Failure 'prompt-certificate-file-cleanup' 'cleanup-failed' $_.Exception.Message }
    if ($activeSessionId -and $user) {
        try { Wait-ProfileUnloaded -SID $user.SID.Value -SessionId $activeSessionId -TimeoutSeconds 40; $activeSessionId=$null }
        catch { $cleanupErrors.Add("RDP session/profile logoff failed: $($_.Exception.Message)"); Latch-Failure 'session-cleanup' 'cleanup-failed' $_.Exception.Message }
    }
    if ($user -and $profilePath -and $profileState -ne 'normal') {
        try {
            & (Join-Path $PSScriptRoot 'profile.ps1') -Action restore-normal -SID $user.SID.Value -ProfilePath $profilePath -VhdPath $vhdPath -BackupPath $backupPath -EvidenceDirectory (Join-Path $EvidenceDirectory 'vhd-restore')
            $profileState='normal'
            Record-Step 'guarded-profile-restore' 'observed' @{ sid=$user.SID.Value; profilePath=$profilePath; vhdPath=$vhdPath; backupPath=$backupPath }
        } catch { $cleanupErrors.Add("Guarded VHD-profile restoration failed: $($_.Exception.Message)"); Latch-Failure 'profile-restore' 'cleanup-failed' $_.Exception.Message }
    }
    $profileRemaining = $false
    if ($user) {
        try {
            $profile = Get-ProfileRecord $user.SID.Value
            if ($profile) {
                if ($profile.Loaded -or (Test-Path "Registry::HKEY_USERS\$($user.SID.Value)")) { throw 'Disposable profile remained loaded during profile cleanup' }
                if (($profile.LocalPath -cne $profilePath) -or $profilePath -notlike "C:\Users\$testUserName") { throw 'Disposable profile path no longer matches its owned unique identity' }
                Remove-CimInstance -InputObject $profile -ErrorAction Stop
            }
            $profileRemaining = [bool](Get-ProfileRecord $user.SID.Value)
            if ($profileRemaining) { throw 'Disposable user profile remains registered after removal' }
            if (Test-Path -LiteralPath $profilePath) { throw 'Disposable profile directory remains after exact profile removal' }
        } catch { $cleanupErrors.Add("Disposable profile cleanup failed: $($_.Exception.Message)"); Latch-Failure 'profile-cleanup' 'cleanup-failed' $_.Exception.Message }
    }
    if ($user -and $password) {
        try {
            $password.Dispose(); $password=$null
            if ($rdpGroupAdded) { Remove-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-555') -Member $testUserName -ErrorAction Stop }
            Remove-LocalUser -Name $testUserName -ErrorAction Stop
            if (Get-LocalUser -Name $testUserName -ErrorAction SilentlyContinue) { throw 'Disposable user remains after removal' }
            $userCreated=$false
            Record-Step 'remove-disposable-user-and-group' 'observed' @{ name=$testUserName; removed=$true; rdpGroupGrantRemoved=$rdpGroupAdded }
        } catch { $cleanupErrors.Add("Disposable user/group cleanup failed: $($_.Exception.Message)"); Latch-Failure 'user-cleanup' 'cleanup-failed' $_.Exception.Message }
    } elseif ($password) {
        $password.Dispose(); $password=$null
    }
    if (($profileState -in @('preparing','mounted')) -or $cleanupErrors.Count) { Latch-Failure 'outer-cleanup' 'cleanup-failed' @($cleanupErrors) }
    $secretCanaryCheckFailed = $false
    try { $secretCanaryResult = if ($passwordCanary) { Test-HostedSecretCanary -Directory $EvidenceDirectory -Sha256 $passwordCanary.sha256 -Length $passwordCanary.length } else { [pscustomobject]@{ leaked=$false; file=$null } } }
    catch {
        $secretCanaryCheckFailed = $true
        $secretCanaryResult = [pscustomobject]@{ leaked=$false; file=$null }
        Latch-Failure 'secret-canary-check' 'harness-defect' $_.Exception.Message
    }
    if ($secretCanaryResult.leaked) { Latch-Failure 'secret-leak-canary' 'harness-defect' @{ file=$secretCanaryResult.file } }
    $verdict = Resolve-HostedCapabilityVerdict -Conditions @($conditions) -Normal $normalResult -Vhd $vhdResult `
        -RootPrompt $rootPromptResult -PositiveRoute $positiveRoute -CleanupErrors @($cleanupErrors) `
        -ProfileState $profileState -UserCreated $userCreated
    $final = [ordered]@{
        schema='go-mapi-hosted-capability-final-v2'; sourceSHA=$SourceSHA.ToLowerInvariant(); runId=$runId
        startedAtUtc=$startedAt.ToString('o'); jobStartedAtUtc=$jobStartedAt.ToString('o'); workDeadlineUtc=$workDeadline.ToString('o')
        completedAtUtc=[DateTime]::UtcNow.ToString('o'); deadlineMinutes=$DeadlineMinutes; cleanupReserveSeconds=[int]($cleanupReserveMinutes * 60)
        verdict=$verdict; failureLatched=[bool]$failureLatched; positiveRouteObserved=[bool]$positiveRoute
        normal=$normalResult; vhd=$vhdResult; currentUserRootPrompt=$rootPromptResult
        conditions=@($conditions); steps=@($steps); cleanup=@{ profileState=$profileState; profileRegistered=$profileRemaining; errors=@($cleanupErrors); userRemoved=(-not $userCreated); rdpDisconnected=(-not $rdpConnected) }
        noMsiUsed=$true; noTrustStoreSubstitution=$true; webView2='optional-observation-not-collected'; outerCleanupComplete=($profileState -in @('normal','not-created') -and $cleanupErrors.Count -eq 0 -and !$userCreated)
        secretCanary=@{ checked=(-not $secretCanaryCheckFailed); leakDetected=[bool]$secretCanaryResult.leaked; leakedFile=$secretCanaryResult.file }
    }
    $finalization = Invoke-HostedCapabilityFinalization -Final $final -WriteEvidence {
        param($value) Write-Atomic (Join-Path $EvidenceDirectory 'hosted-capability-final.json') $value
    }
    if ($finalization.writeFailed) {
        $verdict=$finalization.verdict; $writeFailed=$true
        Latch-Failure 'final-evidence-write' 'harness-defect' $finalization.message
        [Console]::Error.WriteLine("final snapshot write failed: $($finalization.message)")
    }
    elseif ($passwordCanary) {
        try { $finalCanaryCheck = Test-HostedSecretCanary -Directory $EvidenceDirectory -Sha256 $passwordCanary.sha256 -Length $passwordCanary.length }
        catch {
            $finalCanaryCheck = [pscustomobject]@{ leaked=$false; file=$null }
            Latch-Failure 'final-evidence-secret-canary-check' 'harness-defect' $_.Exception.Message
        }
        if ($finalCanaryCheck.leaked -or $secretCanaryCheckFailed) {
            $verdict='harness-defect'
            if ($finalCanaryCheck.leaked) { Latch-Failure 'final-evidence-secret-leak' 'harness-defect' }
            $final.verdict=$verdict; $final.failureLatched=$true
            $final.conditions=@($conditions)
            $final.secretCanary.checked=(-not $secretCanaryCheckFailed)
            $final.secretCanary.leakDetected=[bool]$finalCanaryCheck.leaked
            $final.secretCanary.leakedFile=if ($finalCanaryCheck.leaked) { 'hosted-capability-final.json' } else { $null }
            $finalization = Invoke-HostedCapabilityFinalization -Final $final -WriteEvidence {
                param($value) Write-Atomic (Join-Path $EvidenceDirectory 'hosted-capability-final.json') $value
            }
            if ($finalization.writeFailed) { $writeFailed=$true; [Console]::Error.WriteLine("final snapshot rewrite failed: $($finalization.message)") }
        }
    }
}

Write-Output "HOSTED_CAPABILITY_VERDICT=$verdict"
if ($verdict -eq 'feasible-observed' -and !$writeFailed) { exit 0 }
exit 1
