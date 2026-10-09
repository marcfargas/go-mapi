[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceSHA,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [ValidateRange(1, 30)][int] $DeadlineMinutes = 30,
    [string] $JobStartedAtUtc,
    [Parameter(Mandatory)][ValidatePattern('^Global\\Ticket569-[a-f0-9]{32}-failure$')][string] $FailureEventName,
    [ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
    [int] $SessionOwnerPID,
    [long] $SessionOwnerCreationFileTimeUtc,
    [string] $SessionOwnerRuntimeRoot,
    [ValidateSet('none','before-runtime-intent','after-user-create')][string] $TestFault='none'
)

$ErrorActionPreference = 'Stop'
$null = Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force -PassThru
$null = Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force -PassThru
$null = Import-Module (Join-Path $PSScriptRoot 'hosted-capability-protocol.psm1') -Force -PassThru
$null = Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force -PassThru
$ProgressPreference = 'SilentlyContinue'
$startedAt = [DateTime]::UtcNow
$clockSample = Get-HostedCapabilityClockSample
if ($env:GITHUB_ACTIONS -eq 'true') {
    foreach ($marker in @('HOSTED_CAPABILITY_JOB_STARTED_QPC','HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY','HOSTED_CAPABILITY_JOB_STARTED_BOOT')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($marker))) { throw "Workflow invocation omitted required monotonic clock marker $marker" }
    }
    $jobStartCounter = [long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC
    $counterFrequency = [long]$env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY
    $bootMarker = [string]$env:HOSTED_CAPABILITY_JOB_STARTED_BOOT
    $clockCheck = Test-HostedCapabilityClock -ExpectedBootMarker $bootMarker -ObservedBootMarker $clockSample.bootMarker -ExpectedFrequency $counterFrequency -ObservedFrequency $clockSample.frequency -JobStartCounter $jobStartCounter -CurrentCounter $clockSample.counter
    if (!$clockCheck.valid) { throw ('Hosted probe refused before setup because the cross-step clock is invalid: ' + ($clockCheck.reasons -join ',')) }
    $jobStartedAt = [DateTimeOffset]::Parse($JobStartedAtUtc).UtcDateTime
} else {
    $jobStartCounter = $clockSample.counter
    $counterFrequency = $clockSample.frequency
    $bootMarker = $clockSample.bootMarker
    $jobStartedAt = if ($JobStartedAtUtc) { [DateTimeOffset]::Parse($JobStartedAtUtc).UtcDateTime } else { $startedAt }
}
$deadlines = Get-HostedCapabilityDeadlines -JobStartCounter $jobStartCounter -CounterFrequency $counterFrequency
$jobDeadlineCounter = $jobStartCounter + 30L * 60L * $counterFrequency
$workDeadlineCounter = $deadlines.work
Set-HostedCapabilityProtocolDeadline -DeadlineCounter $deadlines.work -CounterFrequency $counterFrequency
$cleanupDeadlineCounter = $deadlines.cleanup
$deadline = $jobStartedAt.AddMinutes(30)
$workDeadline = $jobStartedAt.AddMinutes(21)
$script:deadlineCounter = $workDeadlineCounter
$script:cleanupDeadlineCounter = $cleanupDeadlineCounter
$script:jobStartCounter = $jobStartCounter
$script:counterFrequency = $counterFrequency
$script:expectedBootMarker = $bootMarker
$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$runId = if ($RunId) { $RunId } else { [guid]::NewGuid().ToString('N') }
$script:runId=$runId
$script:sourceSHA=$SourceSHA.ToLowerInvariant()
$runRoot = 'C:\crabbox\work\ticket569'
$testUserName = 't569' + $runId.Substring(0, 10)
$user = $null
$password = $null
$passwordCanary = $null
$rdpForm = $null
$rdpControl = $null
$rdpConnected = $false
$script:rdpSessionName='ticket569'
$script:rdpOwnerProcess=$null
$script:rdpOwnerRuntime=$SessionOwnerRuntimeRoot
if($SessionOwnerPID -gt 0 -and $SessionOwnerCreationFileTimeUtc -gt 0){
    $script:rdpOwnerProcess=[Diagnostics.Process]::GetProcessById($SessionOwnerPID)
    $ownerIdentity=Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$SessionOwnerPID) -CreationFileTimeUtc $SessionOwnerCreationFileTimeUtc
    if(!$ownerIdentity.matches){throw 'Worker refused a session owner PID whose creation time does not match supervisor identity'}
}
$script:sessionLoginCanaries=[Collections.Generic.List[object]]::new()
$script:secretCanaryRoots=@($EvidenceDirectory,$script:rdpOwnerRuntime)
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
$script:supervisorConnection = $null
$conditions = [Collections.Generic.List[object]]::new()
$steps = [Collections.Generic.List[object]]::new()
$normalResult = [ordered]@{ status='not-run'; evidence=$null }
$vhdResult = [ordered]@{ status='not-run'; evidence=$null }
$rootPromptResult = [ordered]@{ status='unknown'; reason='The pinned native rdpilot CUA route has not yet observed the exact owned CurrentUser Root consent prompt.' }
$verdict = 'unknown'
$positiveRoute = $false
$writeFailed = $false
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

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
    try { Set-HostedCapabilityFailureEvent -Name $FailureEventName }
    catch { $script:writeFailed=$true; $script:cleanupErrors.Add("Global failure event signal failed: $($_.Exception.GetType().FullName)") }
    if ($script:supervisorConnection) {
        try {
            $requestId=[guid]::NewGuid().ToString('N')
            $code=(([string]$Name).ToLowerInvariant() -replace '[^a-z0-9-]','-').Trim('-')
            if (!$code) {$code='worker-failure'}
            $ack=Send-HostedCapabilitySupervisorRequest -Connection $script:supervisorConnection -Request @{schema='ticket569-supervisor-request-v1';runId=$script:runId;sourceSHA=$script:sourceSHA;requestId=$requestId;phase='failure';code=$code;evidence=@{class=$Class;evidence=$Evidence}}
            if (!$ack.acknowledged -or $ack.requestId -cne $requestId) { throw 'Supervisor failure latch acknowledgement was missing' }
        } catch { $script:writeFailed=$true; $script:cleanupErrors.Add("Supervisor failure latch delivery failed: $($_.Exception.Message)") }
    }
}

function Invoke-RunMutation([string] $Operation,[object] $ResourceIdentity,[object] $Precondition,[scriptblock] $Action) {
    if (!$script:supervisorConnection) { throw 'No acknowledged supervisor channel is available; refusing resource mutation' }
    Invoke-HostedProtocolMutation -Connection $script:supervisorConnection -RunId $script:runId -SourceSHA $script:sourceSHA -Operation $Operation -ResourceIdentity $ResourceIdentity -Precondition $Precondition -Action $Action
}

function Send-RunLifecycle([string] $Event,[object] $Observed=$null) {
    if (!$script:supervisorConnection) { return }
    $requestId=[guid]::NewGuid().ToString('N')
    $ack=Send-HostedCapabilitySupervisorRequest -Connection $script:supervisorConnection -Request @{schema='ticket569-supervisor-request-v1';runId=$script:runId;sourceSHA=$script:sourceSHA;requestId=$requestId;phase='lifecycle';event=$Event;observed=$Observed}
    if (!$ack.acknowledged -or $ack.requestId -cne $requestId) { throw 'Supervisor lifecycle acknowledgement was missing' }
}

function Get-HostedCounter {
    $frequency = [Diagnostics.Stopwatch]::Frequency
    if ($frequency -ne $script:counterFrequency) { throw 'Hosted probe QPC frequency changed during execution' }
    $counter = [Diagnostics.Stopwatch]::GetTimestamp()
    if ($counter -lt $script:jobStartCounter) { throw 'Hosted probe QPC counter moved behind the job-start marker' }
    return [long]$counter
}

function Record-Step([string] $Name, [string] $Status, [object] $Evidence = $null, [Nullable[int]] $ExitCode = $null) {
    $step = [pscustomobject]@{ name=$Name; status=$Status; exitCode=$ExitCode; evidence=$Evidence; at=[DateTime]::UtcNow.ToString('o') }
    $script:steps.Add($step)
    try { Write-Atomic (Join-Path $EvidenceDirectory 'preflight-steps.json') @($script:steps) }
    catch { $script:writeFailed = $true; Latch-Failure 'evidence-write' 'harness-defect' $_.Exception.Message }
    if($Name -in @('exact-active-user-wts-session','vhd-active-user-wts-session') -and $Status -ceq 'observed'){
        $sessionEvidence=$Evidence
        if($Evidence.PSObject.Properties['session']){$sessionEvidence=$Evidence.session}
        Send-RunLifecycle -Event 'active-user-session-observed' -Observed @{stepName=$Name;session=$sessionEvidence}
    }
}

function Assert-HostedPhaseBudget([string] $Phase, [int] $RequiredSeconds, [ValidateSet('normal','vhd')][string] $ResultName) {
    $now = Get-HostedCounter
    $remaining = [int][Math]::Floor(($script:workDeadlineCounter - $now) / [double]$script:counterFrequency)
    $budget = [pscustomobject]@{ allowed=($remaining -ge $RequiredSeconds); remainingSeconds=$remaining; requiredSeconds=$RequiredSeconds; workDeadlineUtc=$workDeadline }
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
    $stopAt = (Get-HostedCounter) + [long]$TimeoutSeconds * $script:counterFrequency
    do {
        $matches = @(Get-SidSessions $SID | Where-Object { $_.State -eq 0 })
        if ($matches.Count -eq 1 -and $matches[0].SessionId -gt 0) { return $matches[0] }
        if ((Get-HostedCounter) -ge $script:deadlineCounter) { throw 'Preflight J+21 deadline elapsed while waiting for the exact Active WTS SID/session' }
        Start-Sleep -Milliseconds 250
    } while ((Get-HostedCounter) -lt $stopAt -and (Get-HostedCounter) -lt $script:deadlineCounter)
    return $null
}

function Get-ProfileRecord([string] $SID) {
    Get-CimInstance Win32_UserProfile -Filter "SID='$SID'" -ErrorAction Stop | Select-Object -First 1
}

function Wait-ProfileUnloaded([string] $SID, [int] $SessionId, [int] $TimeoutSeconds) {
    $logoffPath=[IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\logoff.exe'))
    $logoff = Start-Process -FilePath $logoffPath -ArgumentList @([string]$SessionId) -PassThru
    $logoffIdentity=@{pid=$logoff.Id;creationFileTimeUtc=$logoff.StartTime.ToUniversalTime().ToFileTimeUtc();executable=[IO.Path]::GetFullPath($logoff.MainModule.FileName);sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;sessionId=$logoff.SessionId}
    if($logoffIdentity.executable -cne $logoffPath){try{$logoff.Kill();$null=$logoff.WaitForExit((Get-HostedCapabilityWaitBudget $script:deadlineCounter $script:counterFrequency 5000))}catch{};throw 'Profile logoff launched an unexpected executable image'}
    $logoffDeadline=[Math]::Min((Get-HostedCounter)+[long]$TimeoutSeconds*$script:counterFrequency,$script:deadlineCounter)
    while(!$logoff.WaitForExit((Get-HostedCapabilityWaitBudget $logoffDeadline $script:counterFrequency 100)) -and (Get-HostedCounter) -lt $logoffDeadline){}
    if(!$logoff.HasExited){try{$logoff.Kill();$null=$logoff.WaitForExit((Get-HostedCapabilityWaitBudget $script:deadlineCounter $script:counterFrequency 5000))}catch{};throw 'Exact logoff process exceeded its bounded cleanup deadline'}
    $sessionGone = $false
    $stopAt = (Get-HostedCounter) + [long]$TimeoutSeconds * $script:counterFrequency
    do {
        $sessionGone = @((Get-SidSessions $SID) | Where-Object SessionId -eq $SessionId).Count -eq 0
        $profile = Get-ProfileRecord $SID
        $hiveGone = !(Test-Path "Registry::HKEY_USERS\$SID")
        if ($sessionGone -and (!$profile -or !$profile.Loaded) -and $hiveGone) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-HostedCounter) -lt $stopAt -and (Get-HostedCounter) -lt $script:deadlineCounter)
    if ($logoff.ExitCode -ne 0 -or !$sessionGone -or (Get-ProfileRecord $SID).Loaded -or (Test-Path "Registry::HKEY_USERS\$SID")) {
        throw "Exact RDP session/profile did not unload after logoff; exit=$($logoff.ExitCode)"
    }
    Record-Step 'exact-user-logoff-profile-unloaded' 'observed' @{ SID=$SID; sessionId=$SessionId; loaded=$false; hivePresent=$false; logoffExit=[int]$logoff.ExitCode;logoffProcess=$logoffIdentity;waitedHandle=$true } $logoff.ExitCode
    $logoff.Dispose()
}

function Invoke-SessionOwnerRequest([object] $Request,[int] $TimeoutMilliseconds=5000) {
    $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',"Ticket569-$($script:runId)-session-owner",[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::None)
    $reader=$null;$writer=$null
    try {
        $pipe.Connect((Get-HostedCapabilityWaitBudget $script:deadlineCounter $script:counterFrequency $TimeoutMilliseconds))
        $writer=[IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),4096,$true);$writer.AutoFlush=$true
        $reader=[IO.StreamReader]::new($pipe,[Text.UTF8Encoding]::new($false),$false,4096,$true)
        $Request.runId=$script:runId;$Request.sourceSHA=$script:sourceSHA
        $writer.WriteLine((ConvertTo-Json -InputObject $Request -Depth 24 -Compress))
        $task=$reader.ReadLineAsync()
        if(!$task.Wait((Get-HostedCapabilityWaitBudget $script:deadlineCounter $script:counterFrequency $TimeoutMilliseconds))){throw 'Session owner did not answer within its bounded request wait'}
        if(!$task.Result){throw 'Session owner closed the request without a response'}
        $response=ConvertFrom-Json -InputObject $task.Result -ErrorAction Stop
        if(!$response.ok){throw "Session owner rejected request: $($response.errorType)"}
        return $response
    } finally {if($reader){$reader.Dispose()};if($writer){$writer.Dispose()};$pipe.Dispose()}
}

function Connect-LoopbackRdp([string] $AccountName, [Security.SecureString] $SecurePassword, [string] $SID) {
    if (!$script:rdpOwnerProcess) {
        throw 'Session owner was not started and authorized by the supervisor outside the worker Job Object'
    }
    $passwordPointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try { $oneShot=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer) }
    $script:loginPasswordOneShot=$oneShot;$oneShot=$null
    $script:loginUserName=$AccountName;$script:loginSID=$SID
    try { $null=Invoke-RunMutation -Operation 'planned-standard-user-rdp-login' -ResourceIdentity @{sid=$SID;username=$AccountName;host='127.0.0.1';sessionOwnerPID=$script:rdpOwnerProcess.Id;sessionOwnerCreationFileTimeUtc=$script:rdpOwnerProcess.StartTime.ToUniversalTime().ToFileTimeUtc()} -Precondition @{plannedLogin=$true;sessionOwnerReady=$true;passwordTransferPath='worker-direct-named-pipe'} -Action {
        $request=[ordered]@{schema='ticket569-session-owner-v1';command='login';username=$script:loginUserName;domain=$env:COMPUTERNAME;password=$script:loginPasswordOneShot}
        try {$response=Invoke-SessionOwnerRequest $request 190000}
        finally {$request.password=''}
        if (!$response.result.connected -or !$response.result.passwordCanaryAbsent) { throw 'Pinned rdpilot login failed or its one-shot password canary appeared in the private runtime' }
        $script:sessionLoginResult=$response.result
        $script:sessionLoginCanaries.Add(@{ordinal=$response.result.loginOrdinal;passwordCanaryAbsent=[bool]$response.result.passwordCanaryAbsent;sid=$script:loginSID})
        @{connected=$response.result.connected;loginOrdinal=$response.result.loginOrdinal;passwordCanaryAbsent=$response.result.passwordCanaryAbsent;sid=$script:loginSID}
    } } finally { $script:loginPasswordOneShot=$null;$script:loginUserName=$null;$script:loginSID=$null }
    $response=$script:sessionLoginResult
    $session=Wait-ActiveUserSession $SID 30
    if (!$session) { return [pscustomobject]@{session=$null;connectCalled=$true;error=$null;host='pinned rdpilot single-owner session host';loopback='127.0.0.1'} }
    $script:rdpConnected=$true
    [pscustomobject]@{session=$session;connectCalled=$true;error=$null;host='pinned rdpilot persistent single-owner session host';loopback='127.0.0.1';sessionOwnerPID=$script:rdpOwnerProcess.Id;sessionOwnerCreationFileTimeUtc=$script:rdpOwnerProcess.StartTime.ToUniversalTime().ToFileTimeUtc();loginOrdinal=$response.result.loginOrdinal;passwordCanaryAbsent=$response.result.passwordCanaryAbsent}
}

function Assert-OwnedRdpHealthy([string] $Phase,[bool] $RequirePromptService=$false) {
    $answer=Invoke-SessionOwnerRequest ([ordered]@{schema='ticket569-session-owner-v1';command='health';requirePromptService=$RequirePromptService}) 30000
    if(!$answer.result.healthy -or $answer.result.state -cne 'connected' -or
       $answer.result.session -cne $script:rdpSessionName -or ($RequirePromptService -and !$answer.result.promptServiceAlive)){
        throw "Session owner did not prove the original RDP bridge healthy during $Phase"
    }
    $answer.result
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
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-STA','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"",'-OutputPath',"`"$outputPath`"",'-RunId',$runId,'-SourceSHA',$script:sourceSHA,'-ProfileKind',$ProfileKind,'-ExpectedSID',$SID,'-ExpectedSessionId',[string]$SessionId,'-SupervisorPipeName',"Ticket569-$runId-helper",'-HoldAfterWriteSeconds','4','-LaunchGateName',"Global\Ticket569-$runId-user-$ProfileKind",'-JobStartCounter',[string]$script:jobStartCounter,'-CounterFrequency',[string]$script:counterFrequency)
    if ($ProfileKind -eq 'mount-point') { $arguments += @('-VhdPath',"`"$vhdPath`"") }
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument ($arguments -join ' ')
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$testUserName" -LogonType Interactive -RunLevel Limited
    $observedChildPid = $null;$childCreation=$null; $attachedPath = Join-Path $EvidenceDirectory "user-$ProfileKind-attached.json"; $exitPath = Join-Path $EvidenceDirectory "user-$ProfileKind-exit.json"; $failurePath = Join-Path $EvidenceDirectory "user-$ProfileKind-observer-failure.json"
    $taskEvidence = $null; $result = $null
    try {
        if (Test-Path -LiteralPath $outputPath) { throw 'Fresh user probe result path is occupied' }
        $null=Invoke-RunMutation -Operation 'register-exact-run-scoped-interactive-user-task' -ResourceIdentity @{taskName=$taskName;sid=$SID;sessionId=$SessionId;scriptPath=$scriptPath;scriptSha256=(Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()} -Precondition @{taskAbsent=(!(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue));profileKind=$ProfileKind} -Action { Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null;@{registered=($null -ne (Get-ScheduledTask -TaskName $taskName -ErrorAction Stop))} }
        $null=Invoke-RunMutation -Operation 'start-exact-run-scoped-interactive-user-task' -ResourceIdentity @{taskName=$taskName;sid=$SID;sessionId=$SessionId} -Precondition @{taskRegistered=$true;expectedProfileKind=$ProfileKind} -Action { Start-ScheduledTask -TaskName $taskName;@{started=$true} }
        $findUntil = (Get-HostedCounter) + 20L * $script:counterFrequency
        do {
            $matches = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
                $_.CommandLine -and $_.CommandLine.Contains($scriptPath,[StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine.Contains($runId,[StringComparison]::OrdinalIgnoreCase) -and (Get-ProcessOwnerSID $_) -eq $SID
            })
            if ($matches.Count -eq 1) { $observedChildPid = [int]$matches[0].ProcessId; break }
            if ($matches.Count -gt 1) { throw 'More than one task child matched the run/SID; PID identity is ambiguous' }
            Start-Sleep -Milliseconds 150
        } while ((Get-HostedCounter) -lt $findUntil -and (Get-HostedCounter) -lt $script:deadlineCounter)
        if (!$observedChildPid) { throw 'Task child PID was not observed for the exact user SID and command' }
        $childCim=Get-CimInstance Win32_Process -Filter "ProcessId=$observedChildPid" -ErrorAction Stop
        $childProcess=Get-Process -Id $observedChildPid -ErrorAction Stop
        $childCreation=$childProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
        $script:expectedUserChildIdentity=@{pid=$observedChildPid;creationFileTimeUtc=$childCreation;sid=$SID;sessionId=$SessionId;taskName=$taskName;scriptPath=$scriptPath;scriptSHA256=(Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()}
        Send-RunLifecycle -Event 'user-probe-child-identity-observed' -Observed $script:expectedUserChildIdentity
        $observer = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',"`"$observerPath`"",'-TargetProcessId',[string]$observedChildPid,'-ExpectedCommand',$scriptPath,'-ExpectedRunId',$runId,'-AttachedPath',"`"$attachedPath`"",'-ExitPath',"`"$exitPath`"",'-FailurePath',"`"$failurePath`"",'-TimeoutSeconds','100') -PassThru
        $observerDeadline=(Get-HostedCounter)+120L*$script:counterFrequency
        while(!$observer.WaitForExit((Get-HostedCapabilityWaitBudget $observerDeadline $script:counterFrequency 100))){
            if((Get-HostedCounter) -ge $observerDeadline){try{$observer.Kill($true)}catch{};throw 'Task child mutation/probe observer exceeded its bounded deadline'}
        }
        $observer.Refresh()
        if ($observer.ExitCode -ne 0 -or !(Test-Path $attachedPath) -or !(Test-Path $exitPath) -or (Test-Path $failurePath)) { throw 'Retained-handle task-child observation did not complete successfully' }
        $attached = Get-Content $attachedPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $waited = Get-Content $exitPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $result=Get-Content -LiteralPath $outputPath -Raw|ConvertFrom-Json -ErrorAction Stop
        $supportedLimitation=if($ProfileKind -ceq 'mount-point'){Get-HostedVhdSupportedLimitation $result $normalResult}else{$null}
        $expectedChildExit=if($supportedLimitation){1}else{0}
        if ($attached.PID -ne $observedChildPid -or $waited.PID -ne $observedChildPid -or !$attached.HandleRetained -or !$waited.HandleRetained -or
            $attached.CreationFileTimeUtc -ne $waited.CreationFileTimeUtc -or $waited.ExitCode -ne $expectedChildExit) { throw 'Retained-handle task child PID/creation/exit evidence is inconsistent' }
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $taskEvidence = @{ Name=$taskName; State=[string]$task.State; LastRunTime=$taskInfo.LastRunTime.ToUniversalTime().ToString('o'); LastTaskResult=[int]$taskInfo.LastTaskResult; TaskChildPID=$observedChildPid; ChildCreationFileTimeUtc=$waited.CreationFileTimeUtc; WaitedChildExit=[int]$waited.ExitCode }
        if ($task.State -eq 'Running') { $null=Invoke-RunMutation -Operation 'stop-exact-user-task-instance' -ResourceIdentity @{taskName=$taskName;sid=$SID;sessionId=$SessionId;taskChildPID=$observedChildPid;childCreationFileTimeUtc=$childCreation} -Precondition @{taskState='Running';childExited=$true} -Action { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop;@{stopped=$true} } }
        if (Get-Process -Id $observedChildPid -ErrorAction SilentlyContinue) { throw 'Observed task child process remains after stop/wait' }
        $null=Invoke-RunMutation -Operation 'unregister-exact-user-task' -ResourceIdentity @{taskName=$taskName;sid=$SID;sessionId=$SessionId} -Precondition @{taskCompleted=$true;taskResult=[int]$taskInfo.LastTaskResult} -Action { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop;@{absent=($null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue))} }
        if ($taskInfo.LastRunTime -eq [DateTime]::MinValue -or $taskInfo.LastTaskResult -ne $expectedChildExit) { throw 'Scheduled task did not provide a successful completed instance result' }
        if (!(Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw 'Atomic child result is missing after the waited process exit' }
        $result = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($result.runId -ne $runId -or $result.sid -ne $SID -or $result.sessionId -ne $SessionId -or
            $result.processId -ne $observedChildPid -or $result.processCreationFileTimeUtc -ne $attached.CreationFileTimeUtc -or (!$result.passed -and !$supportedLimitation)) {
            throw 'Post-exit child result does not match exact SID/session/process or probe conditions'
        }
        Record-Step "standard-user-$ProfileKind-probe" 'observed' @{ result=$result; task=$taskEvidence; attached=$attached; waitedExit=$waited }
        return [pscustomobject]@{ result=$result; task=$taskEvidence; attached=$attached; waitedExit=$waited; supportedLimitation=$supportedLimitation }
    } finally {
        $script:expectedUserChildIdentity=$null
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            try {
                $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
                if (!$taskEvidence) { $taskEvidence = @{ Name=$taskName; State=[string]$task.State; LastRunTime=$taskInfo.LastRunTime.ToUniversalTime().ToString('o'); LastTaskResult=[int]$taskInfo.LastTaskResult; TaskChildPID=$observedChildPid } }
                if ($task.State -eq 'Running') { $null=Invoke-RunMutation -Operation 'stop-owned-user-task-during-cleanup' -ResourceIdentity @{taskName=$taskName;sid=$SID;sessionId=$SessionId;taskChildPID=$observedChildPid} -Precondition @{taskOwned=$true;cleanup=$true} -Action { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop;@{stopped=$true} } }
                if ($observedChildPid -and (Get-Process -Id $observedChildPid -ErrorAction SilentlyContinue)) { $null=Invoke-RunMutation -Operation 'terminate-exact-owned-user-task-child' -ResourceIdentity @{pid=$observedChildPid;creationFileTimeUtc=$childCreation;sid=$SID;sessionId=$SessionId} -Precondition @{taskOwned=$true;childIdentityObserved=$true} -Action { $identity=Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$observedChildPid) -CreationFileTimeUtc ([long]$childCreation);if(!$identity.matches){throw 'Task child PID was reused before cleanup termination'};$stop=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$observedChildPid) -CreationFileTimeUtc ([long]$childCreation) -WaitMilliseconds 5000;if(!$stop.terminated){throw 'Exact task child did not exit within its bounded handle wait'};@{terminated=$true;waitedHandle=$true;exitCode=$stop.exitCode} } }
                if ($observedChildPid -and (Get-Process -Id $observedChildPid -ErrorAction SilentlyContinue)) { throw 'User probe task child survived cleanup stop' }
                Record-Step "task-evidence-before-unregister-$ProfileKind" 'observed' $taskEvidence
                $null=Invoke-RunMutation -Operation 'unregister-owned-user-task-during-cleanup' -ResourceIdentity @{taskName=$taskName;sid=$SID;sessionId=$SessionId} -Precondition @{taskOwned=$true;cleanup=$true} -Action { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop;@{absent=($null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue))} }
                if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Owned task remains registered after cleanup' }
            } catch { $script:cleanupErrors.Add("$ProfileKind task/process cleanup failed: $($_.Exception.Message)"); Latch-Failure "task-cleanup-$ProfileKind" 'cleanup-failed' $_.Exception.Message }
        }
    }
}

function Disconnect-OwnedRdp {
    if ($script:rdpConnected -and $script:rdpOwnerProcess) {
        try {
            $null=Invoke-RunMutation -Operation 'planned-disconnect-of-owned-rdp-session' -ResourceIdentity @{session=$script:rdpSessionName;ownerPID=$script:rdpOwnerProcess.Id;ownerCreationFileTimeUtc=$script:rdpOwnerProcess.StartTime.ToUniversalTime().ToFileTimeUtc()} -Precondition @{connected=$true;disconnectIsPlanned=$true} -Action {
                $answer=Invoke-SessionOwnerRequest ([ordered]@{schema='ticket569-session-owner-v1';command='disconnect'}) 30000
                if (!$answer.result.disconnected -or !$answer.result.planned) { throw 'Session owner did not confirm its planned disconnect' }
                $script:rdpConnected=$false
                @{session=$script:rdpSessionName;disconnected=$true;planned=$true}
            }
        } catch { $script:cleanupErrors.Add("RDP disconnect failed: $($_.Exception.Message)"); Latch-Failure 'rdp-disconnect' 'cleanup-failed' $_.Exception.Message }
    }
}

function Stop-OwnedRdpSessionHost {
    if (!$script:rdpOwnerProcess) { return $null }
    $process=$script:rdpOwnerProcess
    $identity=@{pid=$process.Id;creationFileTimeUtc=$process.StartTime.ToUniversalTime().ToFileTimeUtc();runtimeRoot=$script:rdpOwnerRuntime;session=$script:rdpSessionName}
    $receipt=Invoke-RunMutation -Operation 'handoff-session-owner-to-supervisor-cleanup' -ResourceIdentity $identity -Precondition @{plannedDisconnectCompleted=(!$script:rdpConnected);supervisorOwnsSeparateKillOnCloseJob=$true} -Action {
        if($script:rdpConnected){throw 'Session owner cannot be handed off while the exact RDP session remains connected'}
        @{pid=$identity.pid;creationFileTimeUtc=$identity.creationFileTimeUtc;shutdownOwner='supervisor';privateRuntime=$identity.runtimeRoot}
    }
    return $receipt.result
}

try {
    if ($SourceSHA -notmatch '^[0-9a-f]{40}$') { throw 'SourceSHA must be a full Git commit ID' }
    $head = (& git -C $sourceRoot rev-parse HEAD).Trim().ToLowerInvariant()
    $headExit = $LASTEXITCODE
    $status = (& git -C $sourceRoot status --porcelain --untracked-files=all | Out-String).Trim()
    if ($headExit -ne 0 -or $head -cne $SourceSHA.ToLowerInvariant() -or $head -cne $env:GITHUB_SHA.ToLowerInvariant() -or $status) { throw 'Preflight requires the exact clean workflow source SHA' }
    $script:supervisorConnection=Connect-HostedCapabilitySupervisor -PipeName "Ticket569-$runId" -TimeoutMilliseconds 10000
    if($TestFault -ceq 'before-runtime-intent'){throw 'Injected bounded fault before runtime intent'}
    $null=Invoke-RunMutation -Operation 'create-owned-hosted-capability-runtime-root' -ResourceIdentity @{path=$runRoot;runId=$runId} -Precondition @{exactRunScopedRoot=$true} -Action {
        if(Test-Path -LiteralPath $runRoot -PathType Leaf){throw 'Hosted capability runtime root is occupied by a file'}
        if(!(Test-Path -LiteralPath $runRoot -PathType Container)){New-Item -ItemType Directory -Path $runRoot -Force | Out-Null}
        @{path=$runRoot;present=(Test-Path -LiteralPath $runRoot -PathType Container)}
    }
    $preflightApartmentState = [Threading.Thread]::CurrentThread.ApartmentState.ToString()
    if ((Get-HostedCounter) -ge $workDeadlineCounter) { throw 'Job-wide preflight work deadline elapsed during source preparation; reserved cleanup and evidence time remains' }
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
        hostUserInteractive=[Environment]::UserInteractive; preflightApartmentState=$preflightApartmentState; wtsSessionInventory=$sessionInventory; termService=$term; fDenyTSConnections=$rdpPolicy
        listeners=$listener; denyRemoteInteractiveRights=$denyRdp; seceditExit=$seceditExit; seceditOutput=$seceditText
        documents=@('https://docs.github.com/actions/using-github-hosted-runners/about-github-hosted-runners','https://github.com/actions/runner-images')
        startedAtUtc=$startedAt.ToString('o')
    }
    Write-Atomic (Join-Path $EvidenceDirectory 'hosted-image.json') $hostRecord
    Record-Step 'host-image-source-and-session-inventory' 'observed' $hostRecord
    if ($preflightApartmentState -cne 'STA') { throw "Hosted capability preflight requires STA; observed $preflightApartmentState" }

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
    Write-Atomic (Join-Path $EvidenceDirectory 'secret-canary-identity.json') @{schema='ticket569-secret-canary-v1';runId=$runId;sourceSHA=$script:sourceSHA;hashes=@($passwordCanary)}
    $password.MakeReadOnly()
    $null=Invoke-RunMutation -Operation 'create-disposable-local-user' -ResourceIdentity @{name=$testUserName} -Precondition @{absent=$true;administrator=$false} -Action {
        $script:user=New-LocalUser -Name $testUserName -Password $password -AccountNeverExpires -PasswordNeverExpires:$false -Description 'Disposable Ticket 569 hosted preflight user' -ErrorAction Stop
        $script:userCreated=$true
        @{name=$script:user.Name;sid=$script:user.SID.Value;administrator=$false}
    }
    if($TestFault -ceq 'after-user-create'){throw 'Injected bounded fault after acknowledged user creation'}
    $profilePath = Join-Path 'C:\Users' $testUserName
    $promptCertificatePath = Join-Path $profilePath "root-prompt-$runId.cer"
    $promptImportResultPath = Join-Path $profilePath "root-import-$runId.json"
    $backupPath = "$profilePath.normal-backup"
    $admins = Get-LocalGroup -SID 'S-1-5-32-544'
    $adminMembers = @(Get-LocalGroupMember -Group $admins -ErrorAction Stop | ForEach-Object { $_.SID.Value })
    if ($adminMembers -contains $user.SID.Value) { throw 'Disposable user is present in Administrators' }
    $rdu = Get-LocalGroup -SID 'S-1-5-32-555'
    $rduMembers = @(Get-LocalGroupMember -Group $rdu -ErrorAction Stop | ForEach-Object { $_.SID.Value })
    if ($rduMembers -notcontains $user.SID.Value) {
        $null=Invoke-RunMutation -Operation 'grant-remote-desktop-users-membership' -ResourceIdentity @{groupSid=$rdu.SID.Value;memberSid=$user.SID.Value} -Precondition @{memberAbsent=$true} -Action {
            Add-LocalGroupMember -Group $rdu -Member $testUserName -ErrorAction Stop
            $script:rdpGroupAdded=$true
            @{groupSid=$rdu.SID.Value;memberSid=$user.SID.Value;added=$true}
        }
    }
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
    $taskScriptHash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'hosted-user-capability.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:normalProbe=Invoke-StandardUserProbe -ProfileKind normal -SID $user.SID.Value -SessionId $activeSessionId
    $normalProbe=$script:normalProbe
    $normalResult.status = if ($normalProbe.result.passed) { 'feasible-observed' } else { 'harness-defect' }
    $normalResult.evidence = $normalProbe
    if (!$normalProbe.result.passed) { Latch-Failure 'normal-session-probe' 'harness-defect' $normalProbe }

    try { $promptSessionHealth=Assert-OwnedRdpHealthy 'before-currentuser-root-prompt' }
    catch {
        $script:rootPromptResult=[ordered]@{status='unverified';reason='The retained single-owner RDP bridge was not healthy before the CurrentUser Root prompt.';phase='before-currentuser-root-prompt'}
        Latch-Failure 'current-user-root-session-lost' 'unknown' $script:rootPromptResult
        throw 'CurrentUser Root prompt is unverified because the original RDP bridge was lost; reconnect is prohibited'
    }

    # Exercise only a fresh, uniquely named certificate consent prompt in the
    # exact already-observed standard-user session. This does not import MSI,
    # package, or test-signing trust and always removes the transient cert.
    if (!$env:RDPILOT_BIN_DIR -or !(Test-Path (Join-Path $env:RDPILOT_BIN_DIR 'rdpilot.exe')) -or
        !(Test-Path (Join-Path $env:RDPILOT_BIN_DIR 'rdpilot-mcp.exe'))) {
        throw 'Pinned hosted CUA client/MCP build is unavailable'
    }
    $promptSubject = "CN=Ticket569-Root-Prompt-$runId"
    $null=Invoke-RunMutation -Operation 'create-and-export-unique-prompt-certificate' -ResourceIdentity @{subject=$promptSubject;store='LocalMachine/My';exportPath=$promptCertificatePath} -Precondition @{subjectAbsent=$true;exportAbsent=(!(Test-Path -LiteralPath $promptCertificatePath))} -Action {
        $script:promptCertificate=New-SelfSignedCertificate -Type Custom -Subject $promptSubject `
            -KeyUsage CertSign,CRLSign -KeyUsageProperty Sign `
            -TextExtension @('2.5.29.19={critical}{text}ca=TRUE') `
            -CertStoreLocation Cert:\LocalMachine\My -NotAfter ([DateTime]::Now.AddHours(2)) -ErrorAction Stop
        $null=Export-Certificate -Cert $script:promptCertificate -FilePath $promptCertificatePath -Type CERT -Force -ErrorAction Stop
        @{thumbprint=$script:promptCertificate.Thumbprint;subject=$script:promptCertificate.Subject;store='LocalMachine/My';exportPath=$promptCertificatePath}
    }
    $promptEvidencePath = Join-Path $EvidenceDirectory 'current-user-root-prompt.json'
    $rootObserverScript = Join-Path $PSScriptRoot 'process-observer.ps1'
    $rootObserverAttachedPath = Join-Path $profilePath "root-import-attached-$runId.json"
    $rootObserverExitPath = Join-Path $profilePath "root-import-exit-$runId.json"
    $rootObserverFailurePath = Join-Path $profilePath "root-import-observer-failure-$runId.json"
    $promptArguments = @(
        '--expected-name', $promptCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false),
        '--expected-sid', $user.SID.Value, '--expected-session-id', [string]$activeSessionId,
        '--run-id', $runId, '--thumbprint', $promptCertificate.Thumbprint,
        '--source-sha', $script:sourceSHA, '--supervisor-pipe', "Ticket569-$runId-helper",
        '--certificate-path', $promptCertificatePath,
        '--job-start-counter', [string]$script:jobStartCounter, '--counter-frequency', [string]$script:counterFrequency,
        '--import-script', (Join-Path $PSScriptRoot 'hosted-root-import.ps1'),
        '--import-gate', "Global\Ticket569-$runId-root-import",
        '--observer-script', $rootObserverScript,
        '--observer-attached', $rootObserverAttachedPath,
        '--observer-exit', $rootObserverExitPath,
        '--observer-failure', $rootObserverFailurePath,
        '--import-result', $promptImportResultPath, '--evidence', $promptEvidencePath,
        '--prompt-timeout', '30', '--close-timeout', '10', '--child-timeout', '120'
    )
    $null=Invoke-RunMutation -Operation 'run-pinned-cua-currentuser-root-prompt' -ResourceIdentity @{sid=$user.SID.Value;sessionId=$activeSessionId;subject=$promptSubject;thumbprint=$promptCertificate.Thumbprint;store='CurrentUser/Root'} -Precondition @{exactActiveSessionObserved=$true;targetAbsent=$true} -Action {
    $promptRemainingMs = [int][Math]::Floor(($workDeadlineCounter - (Get-HostedCounter)) / [double]$counterFrequency * 1000)
    $promptWaitMs = [int][Math]::Max(1000, [Math]::Min(8 * 60 * 1000, $promptRemainingMs))
    $prepareRequest=[ordered]@{schema='ticket569-session-owner-v1';command='prompt-prepare';promptArguments=$promptArguments}
    $prepared=Invoke-SessionOwnerRequest $prepareRequest 45000
    if(!$prepared.result.importer){throw 'Owner did not return the retained pinned launch_app importer identity'}
    Send-RunLifecycle -Event 'root-importer-launch-observed' -Observed $prepared.result.importer
    $request=[ordered]@{schema='ticket569-session-owner-v1';command='prompt-run';promptArguments=$promptArguments;timeoutMilliseconds=$promptWaitMs}
    try { $answer=Invoke-SessionOwnerRequest $request ($promptWaitMs+30000) }
    catch {
        $script:rootPromptResult=[ordered]@{status='unverified';reason='The session-host UIA request did not return a bounded owner receipt; the existing session is not reconnected.';phase='owner-hosted-prompt-request'}
        Latch-Failure 'current-user-root-session-lost' 'unknown' $script:rootPromptResult
        throw 'CurrentUser Root prompt is unverified because its owner-hosted UIA request did not return a bounded receipt'
    }
    $script:promptServiceReceipt=$answer.result
    if ([int]$answer.result.exitCode -ne 0 -or !$answer.sessionHost.retained -or !(Test-Path -LiteralPath $promptEvidencePath -PathType Leaf)) {
        $promptDetail = if (Test-Path $promptEvidencePath) { Get-Content $promptEvidencePath -Raw | ConvertFrom-Json } else { $null }
        $script:rootPromptResult = [ordered]@{ status='harness-defect'; evidence=$promptDetail; processExitCode=[int]$answer.result.exitCode;sessionHost=$answer.sessionHost }
        Latch-Failure 'current-user-root-prompt-route' 'harness-defect' $script:rootPromptResult
        throw 'Pinned native CUA did not positively observe, answer and verify the exact CurrentUser Root prompt'
    }
    $script:rootPromptResult = Get-Content -LiteralPath $promptEvidencePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $script:rootPromptResult.sessionHost=$answer.sessionHost
    try { $promptSessionHealthAfter=Assert-OwnedRdpHealthy 'after-currentuser-root-prompt' $true }
    catch {
        $script:rootPromptResult.status='unverified'
        $script:rootPromptResult.reason='The original RDP bridge was lost before the post-prompt health receipt.'
        Latch-Failure 'current-user-root-session-lost' 'unknown' $script:rootPromptResult
        throw 'CurrentUser Root prompt result is unverified because the original RDP bridge was lost; reconnect is prohibited'
    }
    $script:rootPromptResult.sessionHealthBefore=$promptSessionHealth
    $script:rootPromptResult.sessionHealthAfter=$promptSessionHealthAfter
    if ($rootPromptResult.status -ne 'observed-and-answered' -or !$rootPromptResult.sessionOwnerRetained -or
        !$rootPromptResult.sessionHost.retained -or !$rootPromptResult.sessionHost.process.pid -or !$rootPromptResult.sessionHost.process.creationFileTimeUtc -or
        $rootPromptResult.disconnected -or $rootPromptResult.daemonStopped -or $rootPromptResult.privateRuntimeRemoved -or
        !$rootPromptResult.importChild.passed -or !$rootPromptResult.importChild.removedObserved -or
        !$rootPromptResult.processObservation.exit.HandleRetained -or $rootPromptResult.processObservation.exit.ExitCode -ne 0) {
        $script:rootPromptResult.status = 'harness-defect'
        Latch-Failure 'current-user-root-prompt-route' 'harness-defect' $script:rootPromptResult
        throw 'CUA prompt evidence or exact CurrentUser Root add/remove proof is incomplete'
    }
    $script:rootPromptResult
    }
    $rootPromptResult=$script:rootPromptResult
    $conditions.Add([pscustomobject]@{ name='current-user-root-prompt-route'; class='observed'; evidence=$rootPromptResult; at=[DateTime]::UtcNow.ToString('o') })
    Record-Step 'current-user-root-prompt-route' 'observed-and-answered' $rootPromptResult
    Disconnect-OwnedRdp
    Wait-ProfileUnloaded -SID $user.SID.Value -SessionId $activeSessionId -TimeoutSeconds 40
    $activeSessionId = $null
    Assert-HostedPhaseBudget -Phase 'vhd-profile-preparation' -RequiredSeconds 180 -ResultName vhd
    $profileState = 'preparing'
    & (Join-Path $PSScriptRoot 'profile.ps1') -Action prepare-vhd -SID $user.SID.Value -ProfilePath $profilePath -VhdPath $vhdPath -BackupPath $backupPath -EvidenceDirectory (Join-Path $EvidenceDirectory 'vhd-prepare') -MutationMode Hosted -DeadlineCounter $script:deadlineCounter -CounterFrequency $script:counterFrequency -MutationHook {
        param($operation,$resourceIdentity,$precondition,$action)
        Invoke-RunMutation -Operation $operation -ResourceIdentity $resourceIdentity -Precondition $precondition -Action $action
    }
    $profileState = 'mounted'
    $vhdIdentity = Connect-LoopbackRdp -AccountName $testUserName -SecurePassword $password -SID $user.SID.Value
    if (!$vhdIdentity.session) { $vhdResult.status='unknown'; $vhdResult.evidence=$vhdIdentity; Latch-Failure 'hosted-vhd-signin' 'unknown' $vhdIdentity; throw 'Exact standard-user WTS session was not re-observed after VHD profile mount' }
    $activeSessionId = [int]$vhdIdentity.session.SessionId
    Record-Step 'vhd-active-user-wts-session' 'observed' $vhdIdentity
    Assert-HostedPhaseBudget -Phase 'vhd-session-probe' -RequiredSeconds 125 -ResultName vhd
    $vhdTaskHash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'hosted-user-capability.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:vhdProbe=Invoke-StandardUserProbe -ProfileKind mount-point -SID $user.SID.Value -SessionId $activeSessionId
    $vhdProbe=$script:vhdProbe
    $vhdResult.status = if ($vhdProbe.result.passed) { 'feasible-observed' } elseif($vhdProbe.supportedLimitation){'unavailable-supported-capability'}else { 'harness-defect' }
    $vhdResult.evidence = $vhdProbe
    if($vhdProbe.supportedLimitation){Latch-Failure 'vhd-supported-native-api-refusal' 'unavailable-supported-capability' $vhdProbe.supportedLimitation}
    elseif (!$vhdProbe.result.passed) { Latch-Failure 'vhd-session-probe' 'harness-defect' $vhdProbe }
} catch {
    if (!$failureLatched) {
        $kind = if ($_.Exception.Message -match 'timed out|temporar|download|network') { 'transient-setup' } else { 'harness-defect' }
        Latch-Failure 'preflight-exception' $kind @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message; hresult=(Format-HResult $_.Exception.HResult) }
    }
} finally {
    try { Send-RunLifecycle -Event 'cleanup-started' -Observed @{ atUtc=[DateTime]::UtcNow.ToString('o'); counter=(Get-HostedCounter) } }
    catch { $cleanupErrors.Add("Supervisor cleanup phase notification failed: $($_.Exception.Message)"); Latch-Failure 'supervisor-cleanup-phase' 'cleanup-failed' $_.Exception.Message }
    # Successful observations are evidence, not latched failures. Only the
    # narrow supported-refusal failure permits this worker cleanup route;
    # any other class or cleanup error still requires supervisor recovery.
    $failureConditions=@($conditions|Where-Object class -CNE 'observed')
    $onlySupportedLimitation=[bool]($failureConditions.Count -gt 0 -and @($failureConditions|Where-Object class -CNE 'unavailable-supported-capability').Count -eq 0 -and $cleanupErrors.Count -eq 0)
    if(!$failureLatched -or $onlySupportedLimitation){
    $ownerCleanupAuthorized=$false
    Disconnect-OwnedRdp
    try{Send-RunLifecycle -Event 'session-owner-shutdown-before-outer-cleanup' -Observed @{beforeLogoff=$true};$ownerCleanupAuthorized=$true}catch{$cleanupErrors.Add('Owner shutdown/empty-job proof missing before logoff');Latch-Failure 'owner-shutdown-before-logoff' 'cleanup-failed' $_.Exception.Message}
    if($ownerCleanupAuthorized){
    if ($promptCertificate) {
        try {
            $privateCertPath = "Cert:\LocalMachine\My\$($promptCertificate.Thumbprint)"
            $null=Invoke-RunMutation -Operation 'remove-exact-prompt-certificate' -ResourceIdentity @{store='LocalMachine/My';thumbprint=$promptCertificate.Thumbprint;subject=$promptCertificate.Subject} -Precondition @{sameCertificatePresent=(Test-Path -LiteralPath $privateCertPath)} -Action {
                if (Test-Path -LiteralPath $privateCertPath) { Remove-Item -LiteralPath $privateCertPath -Force -ErrorAction Stop }
                if (Test-Path -LiteralPath $privateCertPath) { throw 'Temporary prompt fixture certificate remains in LocalMachine/My' }
                @{store='LocalMachine/My';thumbprint=$promptCertificate.Thumbprint;absent=$true}
            }
        } catch { $cleanupErrors.Add("Temporary prompt certificate cleanup failed: $($_.Exception.Message)"); Latch-Failure 'prompt-certificate-cleanup' 'cleanup-failed' $_.Exception.Message }
    }
    try {
        $ownedPromptFiles=@($promptCertificatePath, $promptImportResultPath, $rootObserverAttachedPath, $rootObserverExitPath, $rootObserverFailurePath | Where-Object { $_ })
        $null=Invoke-RunMutation -Operation 'remove-owned-prompt-temporary-files' -ResourceIdentity @{paths=$ownedPromptFiles} -Precondition @{pathsUniqueRunScoped=$true} -Action {
            foreach ($ownedPath in $ownedPromptFiles) { if (Test-Path -LiteralPath $ownedPath) { Remove-Item -LiteralPath $ownedPath -Force -ErrorAction Stop } }
            if (@($ownedPromptFiles | Where-Object { Test-Path -LiteralPath $_ }).Count) { throw 'Temporary prompt certificate/result file remains after cleanup' }
            @{paths=$ownedPromptFiles;allAbsent=$true}
        }
    } catch { $cleanupErrors.Add("Temporary prompt certificate file cleanup failed: $($_.Exception.Message)"); Latch-Failure 'prompt-certificate-file-cleanup' 'cleanup-failed' $_.Exception.Message }
    if ($activeSessionId -and $user) {
        try { Wait-ProfileUnloaded -SID $user.SID.Value -SessionId $activeSessionId -TimeoutSeconds 40; $activeSessionId=$null }
        catch { $cleanupErrors.Add("RDP session/profile logoff failed: $($_.Exception.Message)"); Latch-Failure 'session-cleanup' 'cleanup-failed' $_.Exception.Message }
    }
    if ($user -and $profilePath) {
        try {
            $restored = Invoke-HostedProfileRestoreIfRequired -ProfileState $profileState -Restore {
                & (Join-Path $PSScriptRoot 'profile.ps1') -Action restore-normal -SID $user.SID.Value -ProfilePath $profilePath -VhdPath $vhdPath -BackupPath $backupPath -EvidenceDirectory (Join-Path $EvidenceDirectory 'vhd-restore') -MutationMode Hosted -DeadlineCounter $script:deadlineCounter -CounterFrequency $script:counterFrequency -MutationHook {
                    param($operation,$resourceIdentity,$precondition,$action)
                    Invoke-RunMutation -Operation $operation -ResourceIdentity $resourceIdentity -Precondition $precondition -Action $action
                }
            }
            if ($restored) {
                $profileState='normal'
                Record-Step 'guarded-profile-restore' 'observed' @{ sid=$user.SID.Value; profilePath=$profilePath; vhdPath=$vhdPath; backupPath=$backupPath }
            }
        } catch { $cleanupErrors.Add("Guarded VHD-profile restoration failed: $($_.Exception.Message)"); Latch-Failure 'profile-restore' 'cleanup-failed' $_.Exception.Message }
    }
    $profileRemaining = $false
    if ($user) {
        try {
            $null=Invoke-RunMutation -Operation 'remove-exact-unloaded-user-profile' -ResourceIdentity @{sid=$user.SID.Value;profilePath=$profilePath} -Precondition @{sessionUnloaded=($null -eq $activeSessionId);profileState=$profileState;exactUserOwned=[bool]$userCreated} -Action {
                $profile = Get-ProfileRecord $user.SID.Value
                if ($profile) {
                    if ($profile.Loaded -or (Test-Path "Registry::HKEY_USERS\$($user.SID.Value)")) { throw 'Disposable profile remained loaded during profile cleanup' }
                    if (($profile.LocalPath -cne $profilePath) -or $profilePath -notlike "C:\Users\$testUserName") { throw 'Disposable profile path no longer matches its owned unique identity' }
                    Remove-CimInstance -InputObject $profile -ErrorAction Stop
                }
                $script:profileRemaining = [bool](Get-ProfileRecord $user.SID.Value)
                if ($script:profileRemaining) { throw 'Disposable user profile remains registered after removal' }
                if (Test-Path -LiteralPath $profilePath) { throw 'Disposable profile directory remains after exact profile removal' }
                @{sid=$user.SID.Value;profileRemoved=$true;directoryAbsent=$true}
            }
            $profileRemaining=$script:profileRemaining
        } catch { $cleanupErrors.Add("Disposable profile cleanup failed: $($_.Exception.Message)"); Latch-Failure 'profile-cleanup' 'cleanup-failed' $_.Exception.Message }
    }
    if ($user -and $password) {
        try {
            $password.Dispose(); $password=$null
            $null=Invoke-RunMutation -Operation 'remove-owned-user-and-group-membership' -ResourceIdentity @{name=$testUserName;sid=$user.SID.Value;groupSid='S-1-5-32-555'} -Precondition @{profileAbsent=(!$profileRemaining);userOwned=[bool]$userCreated;groupGrantOwned=[bool]$rdpGroupAdded} -Action {
                if ($rdpGroupAdded) { Remove-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-555') -Member $testUserName -ErrorAction Stop }
                Remove-LocalUser -Name $testUserName -ErrorAction Stop
                if (Get-LocalUser -Name $testUserName -ErrorAction SilentlyContinue) { throw 'Disposable user remains after removal' }
                $script:userCreated=$false
                @{name=$testUserName;sid=$user.SID.Value;removed=$true;rdpGroupGrantRemoved=$rdpGroupAdded}
            }
            Record-Step 'remove-disposable-user-and-group' 'observed' @{ name=$testUserName; removed=$true; rdpGroupGrantRemoved=$rdpGroupAdded }
        } catch { $cleanupErrors.Add("Disposable user/group cleanup failed: $($_.Exception.Message)"); Latch-Failure 'user-cleanup' 'cleanup-failed' $_.Exception.Message }
    } elseif ($password) {
        $password.Dispose(); $password=$null
    }
    }
    }
    if($password){$password.Dispose();$password=$null}
    if (($profileState -in @('preparing','mounted')) -or $cleanupErrors.Count) { Latch-Failure 'outer-cleanup' 'cleanup-failed' @($cleanupErrors) }
    $secretCanaryCheckFailed = $false
    try { $secretCanaryResult = if ($passwordCanary) { Test-HostedSecretCanary -Directories $script:secretCanaryRoots -Sha256 $passwordCanary.sha256 -Length $passwordCanary.length -RollingFingerprint $passwordCanary.rollingFingerprint } else { [pscustomobject]@{ leaked=$false; file=$null } } }
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
        completedAtUtc=[DateTime]::UtcNow.ToString('o'); deadlineMinutes=$DeadlineMinutes
        jobStartCounter=$jobStartCounter; qpcFrequency=$counterFrequency; bootMarker=$bootMarker
        workDeadlineCounter=$workDeadlineCounter; cleanupDeadlineCounter=$cleanupDeadlineCounter; finalDeadlineCounter=$deadlines.final
        verdict=$verdict; failureLatched=[bool]$failureLatched; positiveRouteObserved=[bool]$positiveRoute
        normal=$normalResult; vhd=$vhdResult; currentUserRootPrompt=$rootPromptResult
        conditions=@($conditions); steps=@($steps); cleanup=@{ profileState=$profileState; profileRegistered=$profileRemaining; errors=@($cleanupErrors); userRemoved=(-not $userCreated); rdpDisconnected=(-not $rdpConnected) }
        noMsiUsed=$true; noTrustStoreSubstitution=$true; webView2='optional-observation-not-collected'; outerCleanupComplete=($profileState -in @('normal','not-created') -and $cleanupErrors.Count -eq 0 -and !$userCreated)
        secretCanary=@{ hashes=@($passwordCanary | Where-Object {$_});loginTransfers=@($script:sessionLoginCanaries);checked=(-not $secretCanaryCheckFailed); leakDetected=[bool]$secretCanaryResult.leaked; leakedFile=$secretCanaryResult.file }
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
        try { $finalCanaryCheck = Test-HostedSecretCanary -Directories $script:secretCanaryRoots -Sha256 $passwordCanary.sha256 -Length $passwordCanary.length -RollingFingerprint $passwordCanary.rollingFingerprint }
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
    try { Send-RunLifecycle -Event 'worker-finalized' -Observed @{verdict=$verdict;outerCleanupComplete=($profileState -in @('normal','not-created') -and $cleanupErrors.Count -eq 0 -and !$userCreated);finalPath=(Join-Path $EvidenceDirectory 'hosted-capability-final.json');writeFailed=$writeFailed} }
    catch { $writeFailed=$true;Latch-Failure 'supervisor-finalization' 'harness-defect' $_.Exception.Message }
    if ($script:supervisorConnection) { Close-HostedCapabilitySupervisorConnection -Connection $script:supervisorConnection; $script:supervisorConnection=$null }
}

Write-Output "HOSTED_CAPABILITY_VERDICT=$verdict"
if ($verdict -eq 'feasible-observed' -and !$writeFailed) { exit 0 }
exit 1
