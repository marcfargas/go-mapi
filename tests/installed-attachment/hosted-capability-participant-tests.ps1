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
  bool login=args[0]=="connect";var watch=Stopwatch.StartNew();
  if(login){int index=Array.IndexOf(args,"-F");if(index<0 || index+1>=args.Length){Trace(login,10,-1,watch,false);Environment.Exit(10);return;} command=null;foreach(string line in File.ReadAllLines(args[index+1])){string text=line.Trim();if(text.StartsWith("PasswordCommand "))command=text.Substring(16).Trim().Trim('"');}if(command==null){Trace(login,11,-1,watch,false);Environment.Exit(11);return;}}
  else command="powershell.exe -NoProfile -NonInteractive -EncodedCommand "+args[0];
  var info=new ProcessStartInfo(Environment.GetEnvironmentVariable("WINDIR")+"\\System32\\cmd.exe", "/d /s /c "+command);info.UseShellExecute=false;info.RedirectStandardOutput=true;
  // Owner path: 15s client connect, then unbounded CIM peer verification and client exit, inside its 180s CLI wait.
  var child=Process.Start(info);var read=child.StandardOutput.ReadToEndAsync();if(!child.WaitForExit(60000)){child.Kill();Trace(login,3,-1,watch,false);Environment.Exit(3);return;}if(!read.Wait(1000)){Trace(login,4,child.ExitCode,watch,false);Environment.Exit(4);return;}
  string received=read.Result;bool nonEmpty=received.Length>0;received=null;int exit=child.ExitCode;if(login && !nonEmpty){Trace(login,5,exit,watch,false);Environment.Exit(5);return;}child.Dispose();if(exit!=0){Trace(login,6,exit,watch,nonEmpty);Environment.Exit(exit);return;}Trace(login,0,exit,watch,nonEmpty);if(login)Console.Write("{\"bridge_live\":true}");
 }
 // Fixture-only connect trace: fixed exit-reason code, child exit code, elapsed
 // milliseconds and a non-empty flag. Never records the PasswordCommand output.
 static void Trace(bool login,int code,int childExit,Stopwatch watch,bool nonEmpty){
  if(!login)return;
  try{File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"fixture-connect-trace.txt"),"connect "+code+" "+childExit+" "+watch.ElapsedMilliseconds+" "+(nonEmpty?1:0)+"\n");}catch{}
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
$stage='authorization-gate';$ordinal=0;$script:replyErrorType=$null;$script:replyGuard=$null;$script:requestElapsedMs=$null
# Exact owner literal throw messages on the login/disconnect request paths. Only the
# matching fixed code is retained; the owner reply text itself is never recorded.
$ownerGuards=@(
 @('run-source-mismatch','session owner run/source identity mismatch'),
 @('caller-unrecorded','session owner rejected unrecorded caller PID/creation/SID/session'),
 @('supervisor-login','supervisor is not permitted to transfer a login password'),
 @('state-not-disconnected','automatic reconnect after unexpected or unplanned session state is prohibited'),
 @('password-malformed','one-shot password transfer is malformed'),
 @('user-malformed','login user name is malformed'),
 @('bundle-receipt-missing','Pinned guest bundle receipt is missing'),
 @('bundle-receipt-malformed','Pinned guest bundle receipt is malformed'),
 @('bundle-receipt-mismatch','Pinned guest bundle receipt does not match the supported CUA input contract'),
 @('bundle-files-changed','Pinned guest bundle files changed after bounded preflight verification'),
 @('config-changed','Session-owner rdpilot config changed after pinning'),
 @('transfer-arguments-malformed','one-shot PasswordCommand transfer arguments are malformed'),
 @('transfer-deadline','Password transfer reached the absolute owner deadline'),
 @('transfer-secret-malformed','one-shot password transfer is malformed or oversized'),
 @('transfer-connect-timeout','PasswordCommand did not connect to its bounded one-shot pipe'),
 @('transfer-peer-identity','PasswordCommand pipe caller did not match its exact authorized process identity'),
 @('transfer-byte-bound','one-shot password byte transfer exceeds its bound'),
 @('cli-process-timeout','Pinned rdpilot operation exceeded its bounded process wait'),
 @('cli-output-eof','Pinned rdpilot output EOF exceeded the absolute owner deadline'),
 @('cli-nonzero-exit','Pinned rdpilot command returned a nonzero exit'),
 @('cli-malformed-json','Pinned rdpilot command returned malformed JSON'),
 @('post-connect-health','rdpilot bridge health check failed immediately after connection'),
 @('ping-receipt','Pinned rdpilot ping did not return its exact {ok:true} health receipt'),
 @('disconnect-not-connected','planned disconnect refused because no healthy owned session is connected'),
 @('request-read-timeout','Session owner request read exceeded its five-second bound'),
 @('request-frame','session owner request frame is missing or oversized'),
 @('command-not-permitted','session owner command is not permitted'))
function Request-Owner($Request){
 $script:replyErrorType=$null;$script:replyGuard=$null;$script:requestElapsedMs=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
 $p=[IO.Pipes.NamedPipeClientStream]::new('.',$PipeName,[IO.Pipes.PipeDirection]::InOut)
 # Fixture login: password15s + double child/EOF61s + owner EOF10s + health/EOF30s; 14s slack.
 try{$p.Connect(10000);$w=[IO.StreamWriter]::new($p);$w.AutoFlush=$true;$r=[IO.StreamReader]::new($p);$line=ConvertTo-Json -Compress -Depth 20 $Request;$w.WriteLine($line);$line=$null;$read=$r.ReadLineAsync();$replied=$read.Wait(130000);$script:requestElapsedMs=[long]$watch.ElapsedMilliseconds;if(!$replied){throw 'Owner login response timed out'};$answer=ConvertFrom-Json $read.Result;if(!$answer.ok){if($answer.errorType -is [string] -and $answer.errorType -cmatch '^System\.[A-Za-z0-9_.+`]+Exception$'){$script:replyErrorType=$answer.errorType};$script:replyGuard='unlisted';if($answer.error -is [string]){foreach($guard in $ownerGuards){if($answer.error -ceq $guard[1]){$script:replyGuard=$guard[0];break}}};throw 'Owner login fixture request was rejected'};return $answer.result}finally{if($Request.ContainsKey('password')){$Request.password=''};$p.Dispose()}
}
try{
[IO.File]::WriteAllText($Ready,'ready');$until=[DateTime]::UtcNow.AddSeconds(20)
while(!(Test-Path $Go)){if([DateTime]::UtcNow -ge $until){throw 'Owner authorization gate expired'};Start-Sleep -Milliseconds 50}
foreach($ordinal in @(1,2)){
 $secret=[guid]::NewGuid().ToString('N')+'aA1!'
 $stage='login-request'
 $result=Request-Owner @{schema='ticket569-session-owner-v1';runId=$RunId;sourceSHA=$SourceSHA;command='login';username='synthetic-bridge-fixture';domain='.';password=$secret}
 $secret=$null
 $stage='login-receipt'
 if(!$result.connected -or !$result.passwordCanaryAbsent -or $result.loginOrdinal -ne $ordinal){throw 'Actual owner login omitted per-login transfer/canary/state proof'}
 $stage='disconnect-request'
 $result=Request-Owner @{schema='ticket569-session-owner-v1';runId=$RunId;sourceSHA=$SourceSHA;command='disconnect'}
 $stage='disconnect-receipt'
 if(!$result.disconnected -or !$result.planned){throw 'Actual owner omitted planned disconnect'}
}
}catch{
 [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $Ready) 'login-worker-failure.json'),(ConvertTo-Json -Compress -InputObject @{stage=$stage;ordinal=$ordinal;exceptionType=$_.Exception.GetType().FullName;replyErrorType=$script:replyErrorType;replyGuard=$script:replyGuard;requestElapsedMs=$script:requestElapsedMs}))
 throw
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
        # Two login/disconnect cycles: four 10s pipe connects + four 130s replies + 20s slack.
        $loginWaited=$loginWorker.Wait(580000)
        $loginExitCode=if($loginWaited){$loginWorker.ExitCode}else{$null}
        $loginActiveProcesses=$loginJob.ActiveProcesses
        if(!$loginWaited -or $loginExitCode -ne 0 -or $loginActiveProcesses -ne 0){
            Write-Output ('ACTUAL_OWNER_PASSWORD_FAILURE_STATE '+(ConvertTo-Json -Compress -InputObject @{waited=$loginWaited;exitCode=$loginExitCode;activeProcesses=$loginActiveProcesses}))
            $loginFailurePath=Join-Path $temp 'login-worker-failure.json'
            if($loginWaited -and $loginExitCode -ne 0 -and (Test-Path -LiteralPath $loginFailurePath)){
                $loginFailure=Get-Content -LiteralPath $loginFailurePath -Raw|ConvertFrom-Json
                $replyGuard=if($loginFailure.replyGuard -is [string] -and $loginFailure.replyGuard -cmatch '^[a-z-]{1,40}$'){$loginFailure.replyGuard}else{$null}
                $requestElapsedMs=if($loginFailure.requestElapsedMs -is [long] -or $loginFailure.requestElapsedMs -is [int]){[long]$loginFailure.requestElapsedMs}else{$null}
                Write-Output ('ACTUAL_OWNER_PASSWORD_CHILD_FAILURE '+(ConvertTo-Json -Compress -InputObject @{stage=$loginFailure.stage;ordinal=$loginFailure.ordinal;exceptionType=$loginFailure.exceptionType;replyErrorType=$loginFailure.replyErrorType;replyGuard=$replyGuard;requestElapsedMs=$requestElapsedMs}))
            }
            $connectTracePath=Join-Path $temp 'fixture-connect-trace.txt'
            if(Test-Path -LiteralPath $connectTracePath){
                $connectTrace=@(Get-Content -LiteralPath $connectTracePath -TotalCount 8 | Where-Object {$_ -cmatch '^connect (?:0|3|4|5|6|10|11) -?\d{1,10} \d{1,7} [01]$'})
                Write-Output ('ACTUAL_OWNER_PASSWORD_DOUBLE_TRACE '+(ConvertTo-Json -Compress -InputObject $connectTrace))
            }else{Write-Output 'ACTUAL_OWNER_PASSWORD_DOUBLE_TRACE absent'}
            throw 'Actual owner/password main-path login state fixture failed'
        }
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
    # The owner fixture above pinned $temp\guest-bundle to the synthetic SHA and has
    # exited; remove it so the no-overwrite bundle guard can pin the fixture commit.
    Remove-Item -LiteralPath (Join-Path $temp 'guest-bundle') -Recurse -Force -ErrorAction Stop
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
            # after-user-create faults before any session fact exists, so the supervisor's Invoke-HostedSessionRecovery takes
            # Invoke-OwnedPreSessionCleanup (supervisor.ps1 ~985/625-647 at base 8592ec0; offsets are approximate). Its receipt
            # has no sensitiveContextProven, so production keeps recoveryCompleted false ('unverified-no-session'). This fixture
            # accepts that path only with ledger proof scoped to this run's own user: a valid replay with no session fact and
            # no pending mutation; exactly one completed create-disposable-local-user for t569+mainRun[0..9] with its created
            # SID; exactly one completed remove-owned-presession-local-user for that name and created SID (observed absent);
            # and exactly one preSession/userAbsent recovery receipt for that created SID. The later user/profile/runtime
            # absence assertion still runs independently.
            $preSessionRecoveryProven=$false
            if($fault -ceq 'after-user-create' -and !$completion.recoveryCompleted -and $completion.recoveryRequired -eq $true){
                Import-Module (Join-Path $PSScriptRoot 'hosted-capability-owner.psm1') -Force
                $recoveryReplay=Read-HostedCapabilityLedger -Directory (Join-Path $mainEvidence 'supervisor') -RunId $mainRun -SourceSHA $fixtureSHA
                $expectedUser='t569'+$mainRun.Substring(0,10)
                $created=@($recoveryReplay.mutations|Where-Object {$_.intent.operation -ceq 'create-disposable-local-user' -and $_.intent.resourceIdentity.name -ceq $expectedUser -and $_.observation.result -ceq 'completed' -and $_.observation.observed.name -ceq $expectedUser -and $_.observation.observed.sid -is [string] -and $_.observation.observed.sid})
                $createdSid=if($created.Count -eq 1){[string]$created[0].observation.observed.sid}else{$null}
                $removed=@($recoveryReplay.mutations|Where-Object {$_.intent.operation -ceq 'remove-owned-presession-local-user' -and $createdSid -and $_.intent.resourceIdentity.name -ceq $expectedUser -and $_.intent.resourceIdentity.sid -ceq $createdSid -and $_.observation.resourceIdentity.name -ceq $expectedUser -and $_.observation.resourceIdentity.sid -ceq $createdSid -and $_.observation.result -ceq 'completed' -and $_.observation.observed.absent -eq $true})
                $receipt=@($recoveryReplay.events|Where-Object {$_.phase -ceq 'process' -and $_.operation -ceq 'same-session-recovery-completed-before-j-plus-24' -and $_.resourceIdentity.preSession -eq $true -and $_.resourceIdentity.userAbsent -eq $true -and $createdSid -and $_.resourceIdentity.sid -ceq $createdSid})
                $preSessionRecoveryProven=[bool]($recoveryReplay.valid -and $null -eq $recoveryReplay.sessionFact -and @($recoveryReplay.pending).Count -eq 0 -and $created.Count -eq 1 -and $removed.Count -eq 1 -and $receipt.Count -eq 1)
            }
            # Same 11 checks as before, except the recoveryCompleted criterion now also admits the scoped pre-session
            # alternate proof above. On failure, project only the failed check names and fixed verdict/reason codes.
            $missing=@(foreach($check in @(
                @('workerCallerValidated',!$completion.workerCallerValidated),@('workerTerminationProven',!$completion.workerTerminationProven),
                @('ownerCleanupComplete',!$completion.ownerCleanupComplete),@('recoveryCompleted',($fault -ceq 'after-user-create' -and !$completion.recoveryCompleted -and !$preSessionRecoveryProven)),
                @('localFinalWriteProven',!$completion.localFinalWriteProven),@('ledgerReplayValid',!$completion.ledgerReplayValid),
                @('ledgerPendingMutationCount',($completion.ledgerPendingMutationCount -ne 0)),@('activeProcesses',($completion.activeProcesses -ne 0)),
                @('ownerActiveProcessesFinal',($completion.ownerActiveProcessesFinal -ne 0)),@('recoveryActiveProcessesFinal',($completion.recoveryActiveProcessesFinal -ne 0)),
                @('failureLatched',!$completion.failureLatched))){if($check[1]){$check[0]}})
            if($missing.Count){
                # Finite source-derived whitelists only; any other value (including lowercase text) becomes 'unlisted'.
                $verdicts=@('feasible-observed','unavailable-supported-capability','harness-defect','transient-setup','unknown','cleanup-failed')
                $statuses=@('complete','failed','unverified')
                $reasons=@('required-process-or-job-termination-proof-missing','worker-outer-cleanup-not-proven','exact-session-recovery-not-proven')
                # Literal Write-HostedCapabilityFailure -Code values in hosted-capability-supervisor.ps1; its one dynamic
                # worker-supplied code (line 1154) is deliberately not listed and projects as 'unlisted'.
                $failureLiterals=@('currentuser-root-session-host-lost-during-recovery','final-ledger-replay-invalid-or-pending','finishing-helper-exit-deadline','finishing-helper-nonzero-exit','global-failure-event-latched','global-failure-event-latched-during-cleanup','helper-endpoint-process-exit-unproved','helper-mutation-observation-missing','helper-observation-missing-at-endpoint-close','mutation-observation-missing','owned-private-runtime-cleanup-unverified','owned-runtime-directory-remaining','owner-assignment-launcher-exit-unproven','present-root-exercise-barrier-refused','present-root-exercise-deliberate-importer-stop','present-root-exercise-importer-stop-unproved','present-root-exercise-intercept-refused','recovery-helper-handoff-identity-unproved','recovery-task-stop-failed','rejected-recovery-launcher-termination-unproven','same-context-sensitive-recovery-unverified','same-session-recovery-failed','session-owner-cleanup-failed','supervisor-protocol-failure','worker-exit-unobserved','worker-job-not-empty','worker-nonzero-exit')
                $pick={param($value,$allowed)if($null -eq $value){$null}elseif($value -is [string] -and $allowed -ccontains $value){$value}else{'unlisted'}}
                $reasonCodes=@(@($completion.cleanupReasons)|Where-Object {$null -ne $_}|Select-Object -First 16|ForEach-Object {if($_ -is [string] -and $_.StartsWith('pending-mutation:',[StringComparison]::Ordinal)){'pending-mutation'}else{& $pick $_ $reasons}})
                $failureRecords=Join-Path (Join-Path $mainEvidence 'supervisor') 'failure-records'
                $failureCodes=if(Test-Path -LiteralPath $failureRecords -PathType Container){@(Get-ChildItem -LiteralPath $failureRecords -File -Filter '*.json' | Select-Object -First 16 | ForEach-Object {$prefix=if($_.Name -cmatch '^(.+)-[0-9a-f]{32}\.json$'){$Matches[1]}else{$null};if($prefix -and $failureLiterals -ccontains $prefix){$prefix}else{'unlisted'}})}else{@()}
                $workerExitValue=if($completion.workerExit -is [int] -or $completion.workerExit -is [long]){[long]$completion.workerExit}else{$null}
                $recoveryRequiredValue=if($completion.recoveryRequired -is [bool]){$completion.recoveryRequired}else{$null}
                # Exact supervisor.ps1:99-121/1012-1068 and native GetPipeClientProcessId/GetPipeClientSid literals, the
                # Win32 1368 system text, and two fixed prefixes whose dynamic suffix is dropped; anything else is 'unlisted'.
                $protocolLiterals=@('Adjacent worker-launch clean HEAD/GITHUB_SHA validation failed','Worker did not send its first protocol frame before its bounded launch deadline','Named-pipe caller PID/creation/SID/session did not match the recorded worker identity','Session owner bootstrap identity did not match its dedicated supervisor-owned process','Session owner refused the supervisor-authorized worker identity','Supervisor refused worker launch at or after the absolute J+9 cutoff','Supervisor refused worker launch because session-owner bootstrap reached the absolute J+9 cutoff','Worker did not connect to the supervisor protocol before its bounded launch deadline','Session-owner control absolute deadline reached','session-owner control response exceeded its bound','session-owner closed its control pipe without a response','GetNamedPipeClientProcessId failed','Could not identify named-pipe client SID','Unable to impersonate using a named pipe until data has been read from that pipe.')
                $protocolPrefixes=@(@('session-owner control request timed out: ','session-owner-control-timeout'),@('Cannot find a process with the process identifier ','get-process-not-found'))
                # native.psm1:481/486 call these static methods with one argument; PowerShell wraps a native throw as
                # MethodInvocationException 'Exception calling "<M>" with "1" argument(s): "<inner>"'. Exact strings only.
                $protocolWrapped=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
                foreach($wrap in @(@('GetPipeClientSid','Unable to impersonate using a named pipe until data has been read from that pipe.','GetPipeClientSid:cannot-impersonate-before-read'),@('GetPipeClientSid','Could not identify named-pipe client SID','GetPipeClientSid:client-sid-unidentified'),@('GetPipeClientProcessId','GetNamedPipeClientProcessId failed','GetPipeClientProcessId:client-pid-failed'))){$protocolWrapped['Exception calling "'+$wrap[0]+'" with "1" argument(s): "'+$wrap[1]+'"']=$wrap[2]}
                $protocolValue=$completion.protocolError
                $protocolCode=if($null -eq $protocolValue){$null}elseif($protocolValue -isnot [string]){'unlisted'}elseif($protocolWrapped.ContainsKey($protocolValue)){$protocolWrapped[$protocolValue]}elseif($protocolLiterals -ccontains $protocolValue){$protocolValue}else{$category='unlisted';foreach($prefix in $protocolPrefixes){if($protocolValue.StartsWith($prefix[0],[StringComparison]::Ordinal)){$category=$prefix[1];break}};$category}
                $launchOperations=@('session-owner-started-outside-worker-job','worker-started-in-kill-on-close-job','worker-pipe-caller-validated')
                $launchStages=$null
                try{Import-Module (Join-Path $PSScriptRoot 'hosted-capability-owner.psm1') -Force;$stageReplay=Read-HostedCapabilityLedger -Directory (Join-Path $mainEvidence 'supervisor') -RunId $mainRun -SourceSHA $fixtureSHA;$launchStages=[ordered]@{};foreach($operation in $launchOperations){$launchStages[$operation]=[bool]@($stageReplay.events|Where-Object {$_.operation -ceq $operation}).Count}}catch{$launchStages=$null}
                Write-Output ('ACTUAL_SUPERVISOR_FAULT_PROTOCOL '+(ConvertTo-Json -Compress -InputObject @{protocolError=$protocolCode;launchStages=$launchStages}))
                Write-Output ('ACTUAL_SUPERVISOR_FAULT_FAILURE_CODES '+(ConvertTo-Json -Compress -InputObject @($failureCodes)))
                Write-Output ('ACTUAL_SUPERVISOR_FAULT_COMPLETION '+(ConvertTo-Json -Compress -InputObject @{fault=$fault;missing=$missing;workerExit=$workerExitValue;workerVerdict=(& $pick $completion.workerVerdict $verdicts);supervisorVerdict=(& $pick $completion.supervisorVerdict $verdicts);primaryVerdict=(& $pick $completion.primaryVerdict $verdicts);cleanupStatus=(& $pick $completion.cleanupStatus $statuses);cleanupReasons=$reasonCodes;recoveryRequired=$recoveryRequiredValue}))
                throw 'Actual supervisor fault fixture omitted caller, replay, recovery, exit or job-zero proof'
            }
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
            $completion=@{testFault='none';runId=$run;sourceSHA=$sha;supervisorFinalized=$true;failure=$false;activeProcesses=0;workerTerminationProven=$true;ownerCleanupComplete=$true;ownerActiveProcessesFinal=0;recoveryActiveProcessesFinal=0;ledgerReplayValid=$true;ledgerPendingMutationCount=0;cleanupStatus='complete';recoveryRequired=$false;recoveryCompleted=$false;localFinalWriteProven=$true;localFinalCounter=[Diagnostics.Stopwatch]::GetTimestamp()}
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
    # Start-Process -Credential uses CreateProcessWithLogonW, whose lpCommandLine is limited to 1024 characters
    # (Microsoft Learn). The former -EncodedCommand form was about 1.7k characters and Windows refused it with
    # "The parameter is incorrect". Same checks and exit codes, as one single-line -Command with no double quotes.
    $crossCode="`$ErrorActionPreference='Stop';try{Import-Module '$module' -Force -ErrorAction Stop}catch{exit 10};if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne '$expectedCrossSID'){exit 11};try{Set-HostedCapabilityFailureEvent -Name '$denyName';exit 12}catch{`$cause=`$_.Exception;while(`$cause -and `$cause -isnot [ComponentModel.Win32Exception]){`$cause=`$cause.InnerException};if(`$cause -and `$cause.NativeErrorCode -eq 5){exit 0};exit 13}"
    if($crossCode.Contains('"') -or $crossCode.Contains('  ') -or ('"'+$pwsh+'" -NoProfile -NonInteractive -Command '+$crossCode).Length -ge 1024){throw 'Cross-user DACL command line exceeds the CreateProcessWithLogonW 1024-character bound or is not quote-free'}
    $credential=[Management.Automation.PSCredential]::new("$env:COMPUTERNAME\$userName",$secure)
    $cross=Start-Process -FilePath $pwsh -Credential $credential -LoadUserProfile -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-Command',$crossCode)
    $null=$cross.Handle
    $crossWaited=$cross.WaitForExit(20000);$crossExit=if($crossWaited){[int]$cross.ExitCode}else{$null};$denySignaled=[bool]$denyEvent.Wait(0)
    # Fixed fields only: the child's documented exit code (0/10/11/12/13 or other int), wait result and event state.
    Write-Output ('CROSS_USER_DACL_CHILD '+(ConvertTo-Json -Compress -InputObject @{waited=$crossWaited;exitCode=$crossExit;denyEventSignaled=$denySignaled}))
    if(!$crossWaited -or $crossExit -ne 0 -or $denySignaled){throw 'Unlisted cross-user event caller was not denied'}
}finally{
    if($cross){if(!$cross.HasExited){$cross.Kill();$null=$cross.WaitForExit(5000)};$cross.Dispose()}
    if($denyEvent){$denyEvent.Dispose()}
    # CI 38130942645 observed Win32_UserProfile.Loaded still true here about 10s after launch; allow a bounded
    # 30s for the unload before the unchanged loaded-profile refusal.
    if($localUser){$profileFilter="SID='$($localUser.SID.Value)'";$profile=Get-CimInstance Win32_UserProfile -Filter $profileFilter;$unloadBy=[DateTime]::UtcNow.AddSeconds(30);while($profile -and $profile.Loaded -and [DateTime]::UtcNow -lt $unloadBy){Start-Sleep -Milliseconds 500;$profile=Get-CimInstance Win32_UserProfile -Filter $profileFilter};if($profile){if($profile.Loaded){throw 'DACL fixture profile remained loaded'};Remove-CimInstance $profile -ErrorAction Stop};Remove-LocalUser -SID $localUser.SID -ErrorAction Stop}
    if($secure){$secure.Dispose()};$credential=$null
}
Write-Output 'HOSTED_CAPABILITY_CROSS_USER_DACL_TEST_PASSED'
