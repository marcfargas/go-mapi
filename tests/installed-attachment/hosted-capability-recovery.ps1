[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceSHA,
    [Parameter(Mandatory)][ValidatePattern('^S-1-5-21-')][string] $ExpectedSID,
    [Parameter(Mandatory)][ValidateRange(1,65535)][int] $ExpectedSessionId,
    [Parameter(Mandatory)][string] $ExpectedProfilePath,
    [Parameter(Mandatory)][string] $RecoveryJobName,
    [Parameter(Mandatory)][ValidatePattern('^Global\\Ticket569-[a-f0-9]{32}-recovery-gate$')][string] $RecoveryGateName,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string] $ExpectedLauncherSHA256,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string] $ExpectedWorkerSHA256,
    [Parameter(Mandatory)][ValidatePattern('^Ticket569-[a-f0-9]{32}-helper$')][string] $HelperPipeName,
    [Parameter(Mandatory)][ValidatePattern('^Global\\Ticket569-[a-f0-9]{32}-failure$')][string] $FailureEventName,
    [Parameter(Mandatory)][string] $SourceRoot,
    [Parameter(Mandatory)][long] $JobStartCounter,
    [Parameter(Mandatory)][ValidateRange(1,10000000000)][long] $CounterFrequency
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
$job=$null;$child=$null;$gate=$null
try {
    $launcherScriptHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if($launcherScriptHash -cne $ExpectedLauncherSHA256){throw 'Recovery launcher script SHA-256 did not match the supervisor authorization'}
    $workerScript=Join-Path $PSScriptRoot 'hosted-capability-recovery-worker.ps1'
    $workerScriptHash=(Get-FileHash -LiteralPath $workerScript -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if($workerScriptHash -cne $ExpectedWorkerSHA256){throw 'Recovery worker script SHA-256 did not match the supervisor authorization'}
    $gate=Open-HostedCapabilityGate -Name $RecoveryGateName -Access 0x00100000
    $gateDeadline=$JobStartCounter+24L*60L*$CounterFrequency
    while(!$gate.Wait((Get-HostedCapabilityWaitBudget $gateDeadline $CounterFrequency 100))){if([Diagnostics.Stopwatch]::GetTimestamp() -ge $gateDeadline){throw 'Recovery launcher expired while waiting for supervisor identity-gate release'}}
    $frequency=[Diagnostics.Stopwatch]::Frequency;$startCounter=[Diagnostics.Stopwatch]::GetTimestamp()
    if($frequency -ne $CounterFrequency -or $startCounter -lt $JobStartCounter){throw 'Recovery launcher refused invalid or reversed job QPC markers'}
    $deadline=$JobStartCounter+24L*60L*$CounterFrequency
    if($startCounter -ge $deadline){throw 'Recovery launcher reached the hard J+24 cleanup cutoff'}
    # The supervisor validated the clean source SHA before creating this task
    # and authorized these exact recovery script hashes before releasing the
    # gate. Do not ask the non-admin account to trust a runner-owned Git tree.
    $launcherIdentity=[Security.Principal.WindowsIdentity]::GetCurrent();$launcherProcess=Get-Process -Id $PID
    $profile=Get-CimInstance Win32_UserProfile -Filter "SID='$ExpectedSID'" -ErrorAction Stop
    $admin=([Security.Principal.WindowsPrincipal]$launcherIdentity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if($launcherIdentity.User.Value -cne $ExpectedSID -or $launcherProcess.SessionId -ne $ExpectedSessionId -or $launcherProcess.SessionId -eq 0 -or $admin -or
       !$profile -or !$profile.Loaded -or $profile.LocalPath -cne $ExpectedProfilePath -or $env:USERPROFILE -cne $ExpectedProfilePath -or
       !(Test-Path -LiteralPath "Registry::HKEY_USERS\$ExpectedSID")){throw 'Recovery launcher is not in the exact loaded non-admin SID/session/profile'}
    $job=Open-HostedCapabilityJob -Name $RecoveryJobName -Access 0x0005
    if(($job.LimitFlags -band 0x2000) -eq 0 -or $job.ActiveProcesses -ne 0){throw 'Supervisor Recovery Job is not empty and kill-on-close before worker creation'}
    $childScript=$workerScript
    $powershell=Join-Path $PSHOME 'pwsh.exe';if(!(Test-Path -LiteralPath $powershell)){$powershell=Join-Path $PSHOME 'powershell.exe'}
    if(!(Test-Path -LiteralPath $powershell)){$powershell=(Get-Process -Id $PID).Path}
    $childArgs=@('-NoLogo','-NoProfile','-NonInteractive','-File',$childScript,'-RunId',$RunId,'-SourceSHA',$SourceSHA.ToLowerInvariant(),'-ExpectedWorkerSHA256',$ExpectedWorkerSHA256,'-ExpectedSID',$ExpectedSID,'-ExpectedSessionId',[string]$ExpectedSessionId,'-ExpectedProfilePath',$ExpectedProfilePath,'-RecoveryJobName',$RecoveryJobName,'-HelperPipeName',$HelperPipeName,'-FailureEventName',$FailureEventName,'-SourceRoot',$SourceRoot,'-JobStartCounter',[string]$JobStartCounter,'-CounterFrequency',[string]$CounterFrequency)
    $child=Start-HostedCapabilityProcess -Job $job -Executable $powershell -ArgumentList $childArgs -WorkingDirectory $SourceRoot -LeaveSuspended
    $childProcess=Get-Process -Id ([int]$child.ProcessId) -ErrorAction Stop
    $childSID=$null
    try{$cim=Get-CimInstance Win32_Process -Filter "ProcessId=$($child.ProcessId)" -ErrorAction Stop;$owner=Invoke-CimMethod -InputObject $cim -MethodName GetOwnerSid -ErrorAction Stop;$childSID=[string]$owner.Sid}catch{throw 'Recovery launcher could not verify the suspended child token identity'}
    $childIdentity=@{pid=[int]$child.ProcessId;creationFileTimeUtc=$child.CreationFileTimeUtc;sid=$childSID;sessionId=$childProcess.SessionId;job=$RecoveryJobName;sourceSHA=$SourceSHA.ToLowerInvariant()}
    $childCim=Get-CimInstance Win32_Process -Filter "ProcessId=$($child.ProcessId)" -ErrorAction Stop
    $childCommand=[string]$childCim.CommandLine
    $childArgumentsProven=Test-HostedCapabilityCommandArguments $childCommand @{'-File'=$childScript;'-RunId'=$RunId;'-SourceSHA'=$SourceSHA.ToLowerInvariant();'-ExpectedWorkerSHA256'=$ExpectedWorkerSHA256}
    if($childSID -cne $ExpectedSID -or $childProcess.SessionId -ne $ExpectedSessionId -or !$job.ActiveProcesses -or
       !(Test-HostedCapabilityProcessIdentity -ProcessId $child.ProcessId -CreationFileTimeUtc $child.CreationFileTimeUtc).matches -or
       [IO.Path]::GetFullPath($childProcess.Path) -cne [IO.Path]::GetFullPath($powershell) -or !$childArgumentsProven){
        throw 'Recovery worker failed exact PID/creation/SID/session/image/script/hash/run/Job Object verification while suspended'
    }
    $identityPath=Join-Path $ExpectedProfilePath ".ticket569-$RunId-recovery-launcher.json"
    [IO.File]::WriteAllText($identityPath,(ConvertTo-Json -InputObject @{schema='ticket569-recovery-launcher-v1';runId=$RunId;sourceSHA=$SourceSHA.ToLowerInvariant();launcher=@{pid=$PID;sid=$launcherIdentity.User.Value;sessionId=$launcherProcess.SessionId;scriptSHA256=$launcherScriptHash};child=$childIdentity;workerScriptSHA256=$workerScriptHash;gateName=$RecoveryGateName;gateReleased=$true;jobLimitFlags=$job.LimitFlags;activeProcessesBeforeResume=$job.ActiveProcesses;suspendedChildValidated=$true;recordedBeforeResumeQpc=[Diagnostics.Stopwatch]::GetTimestamp()} -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
    $child.Resume()
    while(!$child.Wait((Get-HostedCapabilityWaitBudget $deadline $CounterFrequency 100))){
        if([Diagnostics.Stopwatch]::GetTimestamp() -ge $deadline){Set-HostedCapabilityFailureEvent -Name $FailureEventName;throw 'Recovery worker reached the hard J+24 cleanup cutoff'}
    }
    if($job.ActiveProcesses -ne 0){throw 'Recovery worker exited while its Job Object still contained processes'}
    exit $child.ExitCode
} catch {
    $record=$_
    try { Set-HostedCapabilityFailureEvent -Name $FailureEventName } catch {}
    [Console]::Error.WriteLine(('TICKET569_RECOVERY_LAUNCHER_FAILED '+$_.Exception.GetType().FullName))
    try {
        $diagnosticCommands=@('Add-Type','ConvertTo-Json','Export-ModuleMember','Get-CimInstance','Get-Content','Get-FileHash','Get-HostedCapabilityWaitBudget','Get-Process','Import-Module','Invoke-CimMethod','Join-Path','Open-HostedCapabilityGate','Open-HostedCapabilityJob','Set-HostedCapabilityFailureEvent','Set-StrictMode','Start-HostedCapabilityProcess','Test-HostedCapabilityCommandArguments','Test-HostedCapabilityProcessIdentity','Test-Path')
        $type=$record.Exception.GetType().FullName
        if($type.Length -gt 256 -or $type -cnotmatch '^(?:[A-Za-z_][A-Za-z0-9_+`]*\.)*[A-Za-z_][A-Za-z0-9_+`]*Exception$'){$type='System.Exception'}
        $line=$record.InvocationInfo.ScriptLineNumber
        if($line -isnot [int] -or $line -le 0){$line=$null}
        $command=$null
        if($record.Exception -is [Management.Automation.CommandNotFoundException]){
            $command=$record.Exception.CommandName
            if($command -isnot [string] -or $command -cnotin $diagnosticCommands){$command='redacted'}
        }
        [Console]::Error.WriteLine(('TICKET569_RECOVERY_LAUNCHER_FAILURE_DETAIL '+(ConvertTo-Json -InputObject ([ordered]@{type=$type;line=$line;command=$command}) -Compress)))
    } catch {}
    exit 2
} finally {if($child){$child.Dispose()};if($job){$job.Dispose()};if($gate){$gate.Dispose()}}
