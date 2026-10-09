$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
if(!$IsWindows){Write-Output 'HOSTED_CAPABILITY_PARTICIPANT_TESTS_SKIPPED_NON_WINDOWS: actual session-owner, recovery-launcher, watchdog and DACL processes require Windows';exit 0}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$pwsh=Join-Path $PSHOME 'pwsh.exe'
$self=Get-Process -Id $PID;$selfCreation=$self.StartTime.ToUniversalTime().ToFileTimeUtc()
$sha='b'*40
function Invoke-OwnerControl([string]$PipeName,$Request){
    $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)
    try{$pipe.Connect(10000);$writer=[IO.StreamWriter]::new($pipe);$writer.AutoFlush=$true;$reader=[IO.StreamReader]::new($pipe);$writer.WriteLine((ConvertTo-Json -Compress -Depth 24 $Request));$read=$reader.ReadLineAsync();if(!$read.Wait(10000)){throw 'Actual owner response timed out'};ConvertFrom-Json $read.Result}finally{$pipe.Dispose()}
}
# Run the actual owner endpoint in its dedicated job. No RDP/CUA login is attempted.
$run=[guid]::NewGuid().ToString('N');$temp=Join-Path $env:TEMP "t569-participant-$run";New-Item -ItemType Directory $temp | Out-Null
$ownerJob=$null;$owner=$null
try{
    # Compile a bounded daemon double; the real owner still performs its pin,
    # private environment, caller identity, control and shutdown paths.
    Import-Module (Join-Path $PSScriptRoot 'hosted-capability-bundle.psm1') -Force
    $daemonSource=Join-Path $temp 'daemon.cs'
    @'
using System; using System.IO; using System.Threading; using System.Diagnostics;
public class FixtureDaemon {
 public static void Main(string[] args){
  if(args.Length==0){Thread.Sleep(600000);return;}
  if(args[0]=="ping" || args[0]=="disconnect"){Console.Write("{\"ok\":true}");return;}
  string command;
  bool login=args[0]=="connect";
  if(login){int index=Array.IndexOf(args,"-F");if(index<0 || index+1>=args.Length){Environment.Exit(10);return;} command=null;foreach(string line in File.ReadAllLines(args[index+1])){string text=line.Trim();if(text.StartsWith("PasswordCommand "))command=text.Substring(16).Trim().Trim('"');}if(command==null){Environment.Exit(11);return;}}
  else command="powershell.exe -NoProfile -NonInteractive -EncodedCommand "+args[0];
  var info=new ProcessStartInfo(Environment.GetEnvironmentVariable("WINDIR")+"\\System32\\cmd.exe", "/d /s /c "+command);info.UseShellExecute=false;info.RedirectStandardOutput=true;
  var child=Process.Start(info);var read=child.StandardOutput.ReadToEndAsync();if(!child.WaitForExit(20000)){child.Kill();Environment.Exit(3);return;}if(!read.Wait(1000)){Environment.Exit(4);return;}
  string received=read.Result;if(login && received.Length==0){Environment.Exit(5);return;}received=null;int exit=child.ExitCode;child.Dispose();if(exit!=0){Environment.Exit(exit);return;}if(login)Console.Write("{\"bridge_live\":true}");
 }
}
'@ | Set-Content -LiteralPath $daemonSource -Encoding utf8
    $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $daemonPath=Join-Path $temp 'rdpilot-daemon.exe'
    $compilerProcess=Start-Process $compiler -PassThru -ArgumentList @('/nologo','/target:exe',"/out:`"$daemonPath`"","`"$daemonSource`"")
    if(!$compilerProcess.WaitForExit(20000) -or $compilerProcess.ExitCode -ne 0){throw 'Daemon process double compiler failed'};$compilerProcess.Dispose()
    Copy-Item $daemonPath (Join-Path $temp 'rdpilot.exe');[IO.File]::WriteAllText((Join-Path $temp 'rdpilot-bridge.exe'),'source-fixture bridge; never runtime capability evidence')
    $downloadAction=$null
    if($env:T569_TEST_CUA_ARCHIVE_PATH){$sourceArchive=$env:T569_TEST_CUA_ARCHIVE_PATH;$downloadAction={param($uri,$destination,$bytes)Copy-Item -LiteralPath $sourceArchive -Destination $destination}.GetNewClosure()}
    $archive=Initialize-HostedCapabilityCuaArchive -DestinationDirectory (Join-Path $temp 'input') -SourceSHA $sha -TimeoutSeconds 60 -DownloadAction $downloadAction
    $null=Initialize-HostedCapabilityCuaBundle -BinaryDirectory $temp -SourceSHA $sha -PreparedArchivePath $archive.ArchivePath -PreparedReceiptPath $archive.ReceiptPath
    $sample=Get-HostedCapabilityClockSample;$ownerName="Global\Ticket569-$run-session-owner";$pipeName="Ticket569-$run-session-owner"
    $ownerJob=New-HostedCapabilityJob -Name $ownerName -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
    $owner=Start-HostedCapabilityProcess -Job $ownerJob -Executable $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'hosted-session-owner.ps1'),'-RunId',$run,'-SourceSHA',$sha,'-PipeName',$pipeName,'-BinaryDirectory',$temp,'-OwnerJobName',$ownerName,'-SupervisorSID',$sid,'-EvidenceDirectory',$temp,'-SupervisorPID',[string]$PID,'-SupervisorCreationFileTimeUtc',[string]$selfCreation,'-JobStartCounter',[string]$sample.counter,'-CounterFrequency',[string]$sample.frequency,'-SessionName','ticket569')
    $request=@{schema='ticket569-session-owner-v1';runId=$run;sourceSHA=$sha;command='bootstrap'}
    $answer=Invoke-OwnerControl $pipeName $request
    if(!$answer.ok -or !$answer.result.ready -or $answer.result.ownerPID -ne $owner.ProcessId){throw 'Actual owner bootstrap did not authenticate supervisor identity'}
    $privateRuntime=$answer.result.runtimeRoot
    $request.command='health';$answer=Invoke-OwnerControl $pipeName $request
    if($answer.ok){throw 'Disconnected owner accepted a worker-only health request from the supervisor'}
    Import-Module (Join-Path $PSScriptRoot 'hosted-capability-password.psm1') -Force
    foreach($fault in @('none','wrong-creation','wrong-command','outside-job')){
        $passwordName='Ticket569-password-peer-'+[guid]::NewGuid().ToString('N')
        $passwordPipe=[IO.Pipes.NamedPipeServerStream]::new($passwordName,[IO.Pipes.PipeDirection]::Out,1,[IO.Pipes.PipeTransmissionMode]::Byte,([IO.Pipes.PipeOptions]::CurrentUserOnly -bor [IO.Pipes.PipeOptions]::Asynchronous),512,512)
        $clientCode="`$p=[IO.Pipes.NamedPipeClientStream]::new('.','$passwordName',[IO.Pipes.PipeDirection]::In);`$p.Connect(10000);`$byte=`$p.ReadByte();`$p.Dispose();if(`$byte -lt 0){exit 4};exit 0"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($clientCode));$peer=$null;$outside=$null
        try{
            if($fault -eq 'outside-job'){$outside=Start-Process -FilePath (Join-Path $temp 'rdpilot.exe') -ArgumentList @($encoded) -PassThru;$null=$outside.Handle;$peerPID=$outside.Id;$peerCreation=$outside.StartTime.ToUniversalTime().ToFileTimeUtc()}
            else{$peer=Start-HostedCapabilityProcess -Job $ownerJob -Executable (Join-Path $temp 'rdpilot.exe') -ArgumentList @($encoded);$peerPID=$peer.ProcessId;$peerCreation=$peer.CreationFileTimeUtc}
            $expectedCreation=$peerCreation;if($fault -eq 'wrong-creation'){$expectedCreation++}
            $expectedCommand=$encoded;if($fault -eq 'wrong-command'){$expectedCommand='not-the-authorized-password-command'}
            $rejected=$false
            try{$receipt=Send-HostedCapabilityOneShotPassword -Pipe $passwordPipe -Secret 'synthetic-test-only' -GetClientProcessId {param($pipe)Get-HostedCapabilityPipeClientProcessId -PipeHandle $pipe.SafePipeHandle.DangerousGetHandle()} -VerifyClient {
                param($clientPID)Test-HostedCapabilityPasswordPeer -ClientPID $clientPID -LauncherPID ([uint32]$peerPID) -LauncherCreationFileTimeUtc $expectedCreation -LauncherExecutable (Join-Path $temp 'rdpilot.exe') -EncodedCommand $expectedCommand -OwnerSID $sid -OwnerSession $self.SessionId -OwnerJobName $ownerName
            }}catch{$rejected=$true;if($_.Exception.Message -notmatch 'exact authorized process identity'){throw}}
            if(($fault -eq 'none') -eq $rejected){throw 'Actual password peer ancestry decision differed from the injected case'}
            if($peer -and (!$peer.Wait(10000) -or ($fault -eq 'none' -and $peer.ExitCode -ne 0))){throw 'Actual password peer did not reach retained bounded exit'}
            if($outside -and !$outside.WaitForExit(10000)){throw 'Rejected outside-job password peer did not exit'}
        }finally{if($passwordPipe){$passwordPipe.Dispose()};if($peer){if(!$peer.Wait(0)){$peer.Terminate(137);$null=$peer.Wait(5000)};$peer.Dispose()};if($outside){if(!$outside.HasExited){$outside.Kill();$null=$outside.WaitForExit(5000)};$outside.Dispose()}}
    }
    # Actual owner login/PasswordCommand state transitions with a CLI/bridge
    # process double. This cannot establish Windows RDP or CUA capability.
    $loginWorkerScript=Join-Path $temp 'login-worker.ps1';$loginGo=Join-Path $temp 'login-go';$loginReady=Join-Path $temp 'login-ready'
    @'
param([string]$PipeName,[string]$RunId,[string]$SourceSHA,[string]$Ready,[string]$Go)
$ErrorActionPreference='Stop'
function Request-Owner($Request){
 $p=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)
 try{$p.Connect(10000);$w=[IO.StreamWriter]::new($p);$w.AutoFlush=$true;$r=[IO.StreamReader]::new($p);$line=ConvertTo-Json -Compress -Depth 20 $Request;$w.WriteLine($line);$line=$null;$read=$r.ReadLineAsync();if(!$read.Wait(15000)){throw 'Owner login response timed out'};$answer=ConvertFrom-Json $read.Result;if(!$answer.ok){throw 'Owner login fixture request was rejected'};return $answer.result}finally{if($Request.ContainsKey('password')){$Request.password=''};$p.Dispose()}
}
[IO.File]::WriteAllText($Ready,'ready');$until=[DateTime]::UtcNow.AddSeconds(20)
while(!(Test-Path $Go)){if([DateTime]::UtcNow -ge $until){throw 'Owner authorization gate expired'};Start-Sleep -Milliseconds 50}
foreach($ordinal in @(1,2)){
 $secret=[guid]::NewGuid().ToString('N')+'aA1!'
 $result=Request-Owner @{schema='ticket569-session-owner-v1';runId=$RunId;sourceSHA=$SourceSHA;command='login';username='synthetic-bridge-fixture';domain='.';password=$secret}
 $secret=$null
 if(!$result.connected -or !$result.passwordCanaryAbsent -or $result.loginOrdinal -ne $ordinal){throw 'Actual owner login omitted per-login transfer/canary/state proof'}
 $result=Request-Owner @{schema='ticket569-session-owner-v1';runId=$RunId;sourceSHA=$SourceSHA;command='disconnect'}
 if(!$result.disconnected -or !$result.planned){throw 'Actual owner omitted planned disconnect'}
}
'@ | Set-Content -LiteralPath $loginWorkerScript -Encoding utf8
    $loginJob=New-HostedCapabilityJob -Name "Global\Ticket569-$run-fixture-login" -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
    $loginWorker=$null
    try{
        $loginWorker=Start-HostedCapabilityProcess -Job $loginJob -Executable $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-File',$loginWorkerScript,'-PipeName',$pipeName,'-RunId',$run,'-SourceSHA',$sha,'-Ready',$loginReady,'-Go',$loginGo)
        $readyBy=[DateTime]::UtcNow.AddSeconds(10);while(!(Test-Path $loginReady) -and [DateTime]::UtcNow -lt $readyBy){Start-Sleep -Milliseconds 50}
        if(!(Test-Path $loginReady)){throw 'Actual login worker did not reach authorization wait'}
        $request.command='authorize-worker';$request.worker=@{pid=$loginWorker.ProcessId;creationFileTimeUtc=$loginWorker.CreationFileTimeUtc;sid=$sid;sessionId=$self.SessionId}
        $answer=Invoke-OwnerControl $pipeName $request
        if(!$answer.ok -or !$answer.result.authorized){throw 'Actual owner rejected the retained login fixture worker'}
        [IO.File]::WriteAllText($loginGo,'authorized')
        if(!$loginWorker.Wait(60000) -or $loginWorker.ExitCode -ne 0 -or $loginJob.ActiveProcesses -ne 0){throw 'Actual owner/password main-path login state fixture failed'}
        Write-Output 'ACTUAL_OWNER_PASSWORD_MAIN_PATH_PASSED_WITH_CLI_BRIDGE_DOUBLE: two planned logins, one-shot peer ancestry, canary and disconnect; RDP/CUA UNPROVED'
    }finally{if($loginWorker){if(!$loginWorker.Wait(0)){$loginJob.Terminate(137);$null=$loginWorker.Wait(5000)};$loginWorker.Dispose()};$loginJob.Dispose()}
    $request.command='shutdown';$answer=Invoke-OwnerControl $pipeName $request
    if(!$answer.ok -or !$answer.result.privateRuntimeRemoved -or !$owner.Wait(10000) -or $owner.ExitCode -ne 0 -or $ownerJob.ActiveProcesses -ne 0 -or (Test-Path $privateRuntime)){throw 'Actual owner shutdown omitted retained exit/empty-job/private-runtime absence'}
    # Copy only this explicitly scoped source set; never enumerate/copy env files.
    # The temporary commit identifies the copied dirty source, not the task base SHA.
    $fixture=Join-Path $temp 'source';$fixtureScripts=Join-Path $fixture 'tests/installed-attachment'
    New-Item -ItemType Directory $fixtureScripts -Force | Out-Null
    $sourceManifest=@(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object {$_.Extension -in @('.ps1','.psm1','.py')} | ForEach-Object {
        if($_.Name -ceq '.gmail-e2e.env'){throw 'Protected input refused'}
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $fixtureScripts $_.Name)
        @{path=('tests/installed-attachment/'+$_.Name);sha256=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()}
    })
    & git -C $fixture init --quiet
    if($LASTEXITCODE -ne 0){throw 'Isolated source fixture git init failed'}
    & git -C $fixture add -- tests/installed-attachment
    if($LASTEXITCODE -ne 0){throw 'Isolated source fixture git add failed'}
    & git -C $fixture -c user.name=Ticket569Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --quiet -m 'Isolated copied source fixture'
    if($LASTEXITCODE -ne 0){throw 'Isolated source fixture commit failed'}
    $fixtureSHA=(& git -C $fixture rev-parse HEAD).Trim()
    Write-Output (ConvertTo-Json -Compress -Depth 8 @{event='copied-main-fixture-source';fixtureSHA=$fixtureSHA;productionBaseSHA=(& git -C (Join-Path $PSScriptRoot '../..') rev-parse HEAD).Trim();files=$sourceManifest})
    # Rebind the verified input to the fixture commit, preserving its exact archive hash.
    $archiveCopy={param($uri,$destination,$bytes)Copy-Item -LiteralPath $archive.ArchivePath -Destination $destination}.GetNewClosure()
    $fixtureArchive=Initialize-HostedCapabilityCuaArchive -DestinationDirectory (Join-Path $temp 'fixture-input') -SourceSHA $fixtureSHA -TimeoutSeconds 60 -DownloadAction $archiveCopy
    $null=Initialize-HostedCapabilityCuaBundle -BinaryDirectory $temp -SourceSHA $fixtureSHA -PreparedArchivePath $fixtureArchive.ArchivePath -PreparedReceiptPath $fixtureArchive.ReceiptPath
    foreach($fault in @('before-runtime-intent','after-user-create')){
        if(Test-Path -LiteralPath 'C:\crabbox\work\ticket569'){throw 'Main fault fixture requires runtime root preabsence'}
        $mainRun=[guid]::NewGuid().ToString('N');$mainEvidence=Join-Path $temp "main-$fault";$mainProcess=$null
        $environmentNames=@('GITHUB_SHA','GITHUB_ACTIONS','RDPILOT_BIN_DIR','HOSTED_CAPABILITY_JOB_STARTED_AT_UTC','HOSTED_CAPABILITY_JOB_STARTED_QPC','HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY','HOSTED_CAPABILITY_JOB_STARTED_BOOT')
        $saved=@{};foreach($name in $environmentNames){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
        try{
            $sample=Get-HostedCapabilityClockSample
            $env:GITHUB_SHA=$fixtureSHA;$env:GITHUB_ACTIONS='true';$env:RDPILOT_BIN_DIR=$temp
            $env:HOSTED_CAPABILITY_JOB_STARTED_AT_UTC=[DateTime]::UtcNow.ToString('o');$env:HOSTED_CAPABILITY_JOB_STARTED_QPC=[string]$sample.counter
            $env:HOSTED_CAPABILITY_JOB_STARTED_QPC_FREQUENCY=[string]$sample.frequency;$env:HOSTED_CAPABILITY_JOB_STARTED_BOOT=$sample.bootMarker
            $stdout=Join-Path $temp "$fault.stdout.log";$stderr=Join-Path $temp "$fault.stderr.log"
            $mainProcess=Start-Process -FilePath $pwsh -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ArgumentList @('-NoProfile','-NonInteractive','-File',"`"$(Join-Path $fixtureScripts 'hosted-capability-supervisor.ps1')`"",'-SourceSHA',$fixtureSHA,'-RunId',$mainRun,'-EvidenceDirectory',"`"$mainEvidence`"",'-TestFault',$fault)
            $null=$mainProcess.Handle
            if(!$mainProcess.WaitForExit(90000)){throw 'Actual supervisor fault fixture exceeded 90-second bound'}
            Get-Content -LiteralPath $stdout;Get-Content -LiteralPath $stderr
            if($mainProcess.ExitCode -ne 2){throw 'Actual supervisor fault fixture did not fail closed'}
            $completion=Get-Content (Join-Path $mainEvidence 'supervisor-complete.json') -Raw|ConvertFrom-Json
            if(!$completion.workerCallerValidated -or !$completion.workerTerminationProven -or !$completion.ownerCleanupComplete -or ($fault -ceq 'after-user-create' -and !$completion.recoveryCompleted) -or !$completion.localFinalWriteProven -or !$completion.ledgerReplayValid -or $completion.ledgerPendingMutationCount -ne 0 -or $completion.activeProcesses -ne 0 -or $completion.ownerActiveProcessesFinal -ne 0 -or $completion.recoveryActiveProcessesFinal -ne 0 -or !$completion.failureLatched){throw 'Actual supervisor fault fixture omitted caller, replay, recovery, exit or job-zero proof'}
            Import-Module (Join-Path $PSScriptRoot 'hosted-capability-owner.psm1') -Force
            $replay=Read-HostedCapabilityLedger -Directory (Join-Path $mainEvidence 'supervisor') -RunId $mainRun -SourceSHA $fixtureSHA
            $create=@($replay.events|Where-Object {$_.phase -ceq 'intent' -and $_.operation -ceq 'create-disposable-local-user'})
            if(($fault -ceq 'after-user-create') -ne ($create.Count -eq 1)){throw 'Actual worker did not reach the selected mutation fault point'}
            if($fault -ceq 'before-runtime-intent' -and @($replay.events|Where-Object phase -CEQ 'intent').Count){throw 'Before-runtime fault mutated an owned resource'}
            $userName='t569'+$mainRun.Substring(0,10)
            if((Get-LocalUser -Name $userName -ErrorAction SilentlyContinue) -or (Test-Path "C:\Users\$userName") -or (Test-Path 'C:\crabbox\work\ticket569')){throw 'Actual supervisor recovery left a user, profile or owned runtime directory'}
            Write-Output (ConvertTo-Json -Compress -Depth 20 @{event='actual-supervisor-worker-fault-passed';fault=$fault;fixtureSHA=$fixtureSHA;completion=$completion})
        }finally{
            foreach($name in $environmentNames){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}
            if($mainProcess){if(!$mainProcess.HasExited){$mainProcess.Kill();$null=$mainProcess.WaitForExit(5000)};$mainProcess.Dispose()}
            # Emergency cleanup is separate from the assertions above and never counts as recovery proof.
            $leftover=Get-LocalUser -Name ('t569'+$mainRun.Substring(0,10)) -ErrorAction SilentlyContinue
            if($leftover){$profile=Get-CimInstance Win32_UserProfile -Filter "SID='$($leftover.SID.Value)'";if($profile){throw 'Main fixture unexpectedly created a profile; emergency cleanup refused'};Remove-LocalUser -SID $leftover.SID -ErrorAction Stop}
            if((Test-Path 'C:\crabbox\work\ticket569') -and @(Get-ChildItem 'C:\crabbox\work\ticket569' -Force).Count -eq 0){Remove-Item 'C:\crabbox\work\ticket569' -Force}
        }
    }
}finally{if($owner){if(!$owner.Wait(0)){$ownerJob.Terminate(137);$null=$owner.Wait(5000)};$owner.Dispose()};if($ownerJob){$ownerJob.Dispose()};Remove-Item $temp -Recurse -Force}
# Actual recovery script must reject wrong hashes and late gate release without spawning a child.
foreach($fault in @('wrong-launcher-hash','wrong-worker-hash','late-launcher')){
    $run=[guid]::NewGuid().ToString('N');$job=$null;$gate=$null;$failure=$null;$launcher=$null
    try{
        $job=New-HostedCapabilityJob -Name "Global\Ticket569-$run-recovery" -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
        $gate=New-HostedCapabilityGate -Name "Global\Ticket569-$run-recovery-gate" -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
        $failure=New-HostedCapabilityGate -Name "Global\Ticket569-$run-failure" -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
        $script=Join-Path $PSScriptRoot 'hosted-capability-recovery.ps1';$workerScript=Join-Path $PSScriptRoot 'hosted-capability-recovery-worker.ps1'
        $lh=(Get-FileHash $script).Hash.ToLowerInvariant();$wh=(Get-FileHash $workerScript).Hash.ToLowerInvariant()
        if($fault -eq 'wrong-launcher-hash'){$lh='0'*64};if($fault -eq 'wrong-worker-hash'){$wh='0'*64}
        $start=[Diagnostics.Stopwatch]::GetTimestamp();if($fault -eq 'late-launcher'){$start-=1441L*[Diagnostics.Stopwatch]::Frequency;$gate.Release()}
        $launcher=Start-Process -FilePath $pwsh -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-File',"`"$script`"",'-RunId',$run,'-SourceSHA',$sha,'-ExpectedSID',$sid,'-ExpectedSessionId','1','-ExpectedProfilePath',"`"$env:USERPROFILE`"",'-RecoveryJobName',"Global\Ticket569-$run-recovery",'-RecoveryGateName',"Global\Ticket569-$run-recovery-gate",'-ExpectedLauncherSHA256',$lh,'-ExpectedWorkerSHA256',$wh,'-HelperPipeName',"Ticket569-$run-helper",'-FailureEventName',"Global\Ticket569-$run-failure",'-SourceRoot',"`"$PSScriptRoot`"",'-JobStartCounter',[string]$start,'-CounterFrequency',[string][Diagnostics.Stopwatch]::Frequency)
        $null=$launcher.Handle
        if(!$launcher.WaitForExit(10000) -or $launcher.ExitCode -ne 2 -or !$failure.Wait(0) -or $job.ActiveProcesses -ne 0){throw "Actual $fault launcher was not rejected before child creation"}
    }finally{if($launcher){if(!$launcher.HasExited){$launcher.Kill();$null=$launcher.WaitForExit(5000)};$launcher.Dispose()};if($gate){$gate.Dispose()};if($failure){$failure.Dispose()};if($job){$job.Dispose()}}
}
# Use actual Windows candidates with the production identity selector. These
# stand-ins do not run the recovery launcher or claim its profile/session gates.
$run=[guid]::NewGuid().ToString('N');$selectorTemp=Join-Path $env:TEMP "t569-select-$run";New-Item -ItemType Directory $selectorTemp|Out-Null
$selectorChildren=@();$selected=$null
try{
    $candidateScript=Join-Path $selectorTemp 'launcher-standin.ps1'
    '[CmdletBinding()]param([Parameter(ValueFromRemainingArguments=$true)]$Rest);Start-Sleep -Seconds 90'|Set-Content $candidateScript -Encoding utf8
    $launcherHash=(Get-FileHash $candidateScript).Hash.ToLowerInvariant();$workerHash='c'*64;$gateName="Global\Ticket569-$run-recovery-gate"
    $selectorArgs=@('-NoProfile','-NonInteractive','-File',"`"$candidateScript`"",'-RunId',$run,'-SourceSHA',$sha,'-ExpectedLauncherSHA256',$launcherHash,'-ExpectedWorkerSHA256',$workerHash,'-RecoveryGateName',$gateName)
    $first=Start-Process -FilePath $pwsh -PassThru -ArgumentList $selectorArgs;$null=$first.Handle;$selectorChildren+=,$first
    $policy=@{ProcessIds=@([uint32]$first.Id);ExpectedSID=$sid;ExpectedSessionId=$self.SessionId;Executable=$pwsh;ScriptPath=$candidateScript;RunId=$run;SourceSHA=$sha;LauncherSHA256=$launcherHash;WorkerSHA256=$workerHash;GateName=$gateName}
    $selected=Get-HostedCapabilityRecoveryLauncher @policy
    if($selected.Process.Id -ne $first.Id -or $selected.CreationFileTimeUtc -ne $first.StartTime.ToUniversalTime().ToFileTimeUtc()){throw 'Production selector lost exact candidate retained creation identity'}
    $selected.Process.Dispose();$selected=$null
    foreach($fault in @('wrong-session','wrong-source','wrong-hash','wrong-image')){
        $bad=$policy.Clone()
        switch($fault){'wrong-session'{$bad.ExpectedSessionId=$self.SessionId+1};'wrong-source'{$bad.SourceSHA='d'*40};'wrong-hash'{$bad.WorkerSHA256='d'*64};'wrong-image'{$bad.Executable=Join-Path $env:WINDIR 'System32\cmd.exe'}}
        $denied=$false;try{$selected=Get-HostedCapabilityRecoveryLauncher @bad}catch{$denied=$true}
        if(!$denied){$selected.Process.Dispose();throw 'Production selector accepted the mismatched real candidate'}
    }
    $second=Start-Process -FilePath $pwsh -PassThru -ArgumentList $selectorArgs;$null=$second.Handle;$selectorChildren+=,$second
    $policy.ProcessIds=@([uint32]$first.Id,[uint32]$second.Id);$denied=$false
    try{$selected=Get-HostedCapabilityRecoveryLauncher @policy}catch{$denied=$true}
    if(!$denied){throw 'Production selector accepted two live matching launcher candidates'}
    Write-Output 'ACTUAL_PROCESS_LAUNCHER_SELECTOR_PASSED: exact retained candidate, duplicate and SID/session/source/hash/image mismatches; launcher entrypoint stand-ins'
}finally{foreach($child in $selectorChildren){if(!$child.HasExited){$stop=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$child.Id) -CreationFileTimeUtc $child.StartTime.ToUniversalTime().ToFileTimeUtc() -WaitMilliseconds 5000;if(!$stop.terminated){throw 'Selector stand-in retained exit unproved'}};$child.Dispose()};Remove-Item $selectorTemp -Recurse -Force}
# Run the actual independent watchdog, both a normal final-write race and forced timeout.
foreach($mode in @('complete','timeout')){
    $run=[guid]::NewGuid().ToString('N');$temp=Join-Path $env:TEMP "t569-watchdog-$run";New-Item -ItemType Directory $temp | Out-Null
    $jobs=@{};$children=@{};$watcher=$null
    try{
        foreach($role in @('build','worker','session-owner','recovery')){$jobs[$role]=New-HostedCapabilityJob -Name "Global\Ticket569-$run-$role" -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)"}
        foreach($role in @('worker','session-owner')){$children[$role]=Start-HostedCapabilityProcess -Job $jobs[$role] -Executable $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 90')}
        $supervisor=Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 90') -PassThru;$null=$supervisor.Handle
        $identity=@{schema='ticket569-supervisor-identity-v1';runId=$run;sourceSHA=$sha;supervisor=@{pid=$supervisor.Id;creationFileTimeUtc=$supervisor.StartTime.ToUniversalTime().ToFileTimeUtc();sid=$sid;sessionId=$supervisor.SessionId}}
        foreach($pair in @(@('worker','worker'),@('sessionOwner','session-owner'))){$child=$children[$pair[1]];$identity[$pair[0]]=@{pid=$child.ProcessId;creationFileTimeUtc=$child.CreationFileTimeUtc;sid=$sid;sessionId=$self.SessionId}}
        $identityPath=Join-Path $temp 'identity.json';[IO.File]::WriteAllText($identityPath,(ConvertTo-Json $identity -Depth 20))
        $sample=Get-HostedCapabilityClockSample;$seconds=if($mode -eq 'complete'){15}else{4}
        $watcher=Start-Process -FilePath $pwsh -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-File',"`"$(Join-Path $PSScriptRoot 'hosted-capability-watchdog.ps1')`"",'-JobStartCounter',[string]$sample.counter,'-CounterFrequency',[string]$sample.frequency,'-BootMarker',$sample.bootMarker,'-SupervisorIdentityPath',"`"$identityPath`"",'-BuildJobName',"Global\Ticket569-$run-build",'-WorkerJobName',"Global\Ticket569-$run-worker",'-SessionOwnerJobName',"Global\Ticket569-$run-session-owner",'-RecoveryJobName',"Global\Ticket569-$run-recovery",'-RunId',$run,'-SourceSHA',$sha,'-EvidenceDirectory',"`"$temp`"",'-TestDeadlineSeconds',[string]$seconds,'-RequireCloseHandshake')
        if($mode -eq 'complete'){
            $readyBy=[DateTime]::UtcNow.AddSeconds(10)
            while(!(Test-Path (Join-Path $temp 'watchdog-retained-participants.json')) -and [DateTime]::UtcNow -lt $readyBy){Start-Sleep -Milliseconds 50}
            if(!(Test-Path (Join-Path $temp 'watchdog-retained-participants.json'))){throw 'Actual watchdog did not retain participants before completion fixture'}
            foreach($job in $jobs.Values){$job.Terminate(0)}
            foreach($child in $children.Values){if(!$child.Wait(5000)){throw 'Fixture child did not exit'}}
            $supervisor.Kill();$null=$supervisor.WaitForExit(5000)
            $completion=@{runId=$run;sourceSHA=$sha;supervisorFinalized=$true;failure=$false;activeProcesses=0;workerTerminationProven=$true;ownerCleanupComplete=$true;ownerActiveProcessesFinal=0;recoveryActiveProcessesFinal=0;ledgerReplayValid=$true;ledgerPendingMutationCount=0;cleanupStatus='complete';recoveryRequired=$false;recoveryCompleted=$false;localFinalWriteProven=$true;localFinalCounter=[Diagnostics.Stopwatch]::GetTimestamp()}
            [IO.File]::WriteAllText((Join-Path $temp 'supervisor-complete.json'),(ConvertTo-Json $completion))
            $resultBy=[DateTime]::UtcNow.AddSeconds(10)
            while(!(Test-Path (Join-Path $temp 'watchdog-result.json')) -and [DateTime]::UtcNow -lt $resultBy){Start-Sleep -Milliseconds 50}
            if(!(Test-Path (Join-Path $temp 'watchdog-result.json')) -or $watcher.WaitForExit(0)){throw 'Watchdog close handshake did not retain its live process after final result write'}
            $close=Open-HostedCapabilityGate -Name "Global\Ticket569-$run-watchdog-close" -Access 0x0002
            try{$close.Release()}finally{$close.Dispose()}

        }
        if(!$watcher.WaitForExit(20000)){throw 'Actual watchdog exceeded its fixture process deadline'}
        $record=Get-Content (Join-Path $temp 'watchdog-result.json') -Raw | ConvertFrom-Json
        if(@($record.retainedProcessExits | Where-Object {!$_.retained -or !$_.exited}).Count -or @($record.retainedProcessExits).Count -ne 3){throw 'Actual watchdog lacks all three retained process exits'}
        if($mode -eq 'complete'){if($watcher.ExitCode -ne 0 -or !$record.processProof -or $record.status -cne 'supervisor-completed'){throw 'Actual close/final-write path failed'}}
        elseif($watcher.ExitCode -ne 2 -or $record.status -cne 'cleanup-failed' -or @($record.jobs | Where-Object {!$_.zeroCountObserved}).Count){throw 'Actual timeout watchdog did not retain exits plus zero counts'}
    }finally{
        if($watcher){if(!$watcher.HasExited){$watcher.Kill();$null=$watcher.WaitForExit(5000)};$watcher.Dispose()}
        if($supervisor){if(!$supervisor.HasExited){$supervisor.Kill();$null=$supervisor.WaitForExit(5000)};$supervisor.Dispose()}
        foreach($job in $jobs.Values){try{$job.Terminate(137)}catch{};$job.Dispose()};foreach($child in $children.Values){$child.Dispose()}
        Remove-Item $temp -Recurse -Force
    }
}
Write-Output 'HOSTED_CAPABILITY_PARTICIPANT_TESTS_PASSED: actual owner endpoint/shutdown, rejected recovery launcher, and independent watchdog processes'
# The run-scoped event excludes another actual local user's token. Credential
# transfer is in memory only; this account/profile is removed after waited exit.
$run=[guid]::NewGuid().ToString('N');$userName='t569acl'+$run.Substring(0,8);$localUser=$null;$denyEvent=$null;$cross=$null
try{
    $secure=ConvertTo-SecureString -String ([guid]::NewGuid().ToString('N')+'aA1!') -AsPlainText -Force
    $localUser=New-LocalUser -Name $userName -Password $secure -Description 'Ticket569 disposable DACL fault test' -ErrorAction Stop
    $denyName="Global\Ticket569-$run-failure"
    $denyEvent=New-HostedCapabilityGate -Name $denyName -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
    $module=Join-Path $PSScriptRoot 'hosted-capability-native.psm1'
    $expectedCrossSID=$localUser.SID.Value
    $crossCode=@"
`$ErrorActionPreference='Stop'
try{Import-Module '$module' -Force -ErrorAction Stop}catch{exit 10}
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne '$expectedCrossSID'){exit 11}
try{Set-HostedCapabilityFailureEvent -Name '$denyName';exit 12}catch{
    `$cause=`$_.Exception
    while(`$cause -and `$cause -isnot [ComponentModel.Win32Exception]){`$cause=`$cause.InnerException}
    if(`$cause -and `$cause.NativeErrorCode -eq 5){exit 0};exit 13
}
"@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($crossCode))
    $credential=[Management.Automation.PSCredential]::new("$env:COMPUTERNAME\$userName",$secure)
    $cross=Start-Process -FilePath $pwsh -Credential $credential -LoadUserProfile -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded)
    $null=$cross.Handle
    if(!$cross.WaitForExit(20000) -or $cross.ExitCode -ne 0 -or $denyEvent.Wait(0)){throw 'Unlisted cross-user event caller was not denied'}
}finally{
    if($cross){if(!$cross.HasExited){$cross.Kill();$null=$cross.WaitForExit(5000)};$cross.Dispose()}
    if($denyEvent){$denyEvent.Dispose()}
    if($localUser){$profile=Get-CimInstance Win32_UserProfile -Filter "SID='$($localUser.SID.Value)'";if($profile){if($profile.Loaded){throw 'DACL fixture profile remained loaded'};Remove-CimInstance $profile -ErrorAction Stop};Remove-LocalUser -SID $localUser.SID -ErrorAction Stop}
    if($secure){$secure.Dispose()};$credential=$null
}
Write-Output 'HOSTED_CAPABILITY_CROSS_USER_DACL_TEST_PASSED'
