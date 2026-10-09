$ErrorActionPreference='Stop'
if(!$IsWindows){Write-Output 'HOSTED_CAPABILITY_FRAMEWORK_TESTS_UNRUN: actual powershell.exe5.1 participant runtime requires Windows';exit 0}
$temp=Join-Path $env:TEMP ('t569-framework-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
$script=Join-Path $temp 'import-framework.ps1'
@'
param([string]$Scripts)
$ErrorActionPreference='Stop'
foreach($name in @('native','clock','protocol','credential','owner','canary','verdict')){Import-Module (Join-Path $Scripts ("hosted-capability-$name.psm1")) -Force}
Import-Module (Join-Path $Scripts 'hosted-root-import-policy.psm1') -Force
# Execute native main-path kernel functions on Framework, not just Add-Type.
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$run=[guid]::NewGuid().ToString('N')
$job=New-HostedCapabilityJob -Name "Global\Ticket569-$run-framework" -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)"
$child=$null
try{
 $exe=(Get-Process -Id $PID).Path
 $child=Start-HostedCapabilityProcess -Job $job -Executable $exe -ArgumentList @('-NoProfile','-NonInteractive','-Command','exit 0')
 if(!$child.Wait(10000) -or $child.ExitCode -ne 0 -or $job.ActiveProcesses -ne 0){throw 'Framework native participant creation/retained exit failed'}
}catch{throw}finally{if($child){$child.Dispose()};$job.Dispose()}
& (Join-Path $Scripts 'hosted-capability-arguments-tests.ps1')
if($LASTEXITCODE -and $LASTEXITCODE -ne 0){throw 'Framework generated argv regression failed'}
& (Join-Path $Scripts 'hosted-capability-mainpath-tests.ps1')
if($LASTEXITCODE -and $LASTEXITCODE -ne 0){throw 'Framework production gate/cleanup regression failed'}
Write-Output "FRAMEWORK_NATIVE_MAIN_PATH_PASSED version=$($PSVersionTable.PSVersion) CLR=$([Environment]::Version)"
'@|Set-Content $script -Encoding utf8
try{
 foreach($exe in @((Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'),(Join-Path $PSHOME 'pwsh.exe'))){
  $out=Join-Path $temp ((Split-Path $exe -Leaf)+'.stdout');$err=$out+'.stderr'
  $p=Start-Process $exe -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-File',"`"$script`"",'-Scripts',"`"$PSScriptRoot`"") -RedirectStandardOutput $out -RedirectStandardError $err
  try{if(!$p.WaitForExit(30000)){throw 'Framework regression timed out'};Get-Content $out|Write-Output;Get-Content $err|Write-Output;if($p.ExitCode -ne 0){throw 'Actual participant-runtime import/native path failed'}}finally{if(!$p.HasExited){$p.Kill();$null=$p.WaitForExit(5000)};$p.Dispose()}
 }
}finally{Remove-Item $temp -Recurse -Force}
# Actual non-admin participant main paths. A service-only Windows runner has no
# authorized interactive session, so it reports that prerequisite explicitly.
$self=Get-Process -Id $PID
if($self.SessionId -le 0){Write-Output 'FRAMEWORK_PARTICIPANT_SUCCESS_UNRUN_NO_INTERACTIVE_SESSION';exit 0}
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
$run=[guid]::NewGuid().ToString('N');$sha='b'*40;$name='t569f'+$run.Substring(0,8);$user=$null;$launcher=$null;$job=$null;$gate=$null;$failure=$null;$pipe=$null
$secure=ConvertTo-SecureString ([guid]::NewGuid().ToString('N')+'aA1!') -AsPlainText -Force
try{
 $user=New-LocalUser -Name $name -Password $secure -ErrorAction Stop
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$target=$user.SID.Value
 $credential=[Management.Automation.PSCredential]::new("$env:COMPUTERNAME\$name",$secure)
 $profile="C:\Users\$name";$exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $launcherScript=Join-Path $PSScriptRoot 'hosted-capability-recovery.ps1';$workerScript=Join-Path $PSScriptRoot 'hosted-capability-recovery-worker.ps1'
 $jobName="Global\Ticket569-$run-recovery";$gateName="Global\Ticket569-$run-recovery-gate";$pipeName="Ticket569-$run-helper"
 $job=New-HostedCapabilityJob -Name $jobName -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)(A;;0x5;;;$target)"
 $gate=New-HostedCapabilityGate -Name $gateName -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)(A;;0x00100000;;;$target)"
 $failure=New-HostedCapabilityGate -Name "Global\Ticket569-$run-failure" -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)(A;;0x0002;;;$target)"
 $security=[IO.Pipes.PipeSecurity]::new();$security.SetSecurityDescriptorSddlForm("D:P(A;;GA;;;SY)(A;;GA;;;$sid)(A;;GRGW;;;$target)")
 $pipe=[IO.Pipes.NamedPipeServerStreamAcl]::Create($pipeName,[IO.Pipes.PipeDirection]::InOut,4,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536,$security,[IO.HandleInheritability]::None,[IO.Pipes.PipeAccessRights]::FullControl)
 $accept=$pipe.WaitForConnectionAsync();$start=[Diagnostics.Stopwatch]::GetTimestamp();$freq=[Diagnostics.Stopwatch]::Frequency
 # Seed only a newly created account's unique synthetic Root certificate using
 # a store API fixture; the production worker must invoke actual RemoveOwned.
 $seedScript=Join-Path $env:TEMP ("t569-seed-$run.ps1")
 @'
param([string]$RunId)
$ErrorActionPreference='Stop'
$subject="CN=Ticket569-Root-Prompt-$RunId"
if(@(Get-ChildItem Cert:\CurrentUser\Root|Where-Object Subject -CEQ $subject).Count){throw 'Synthetic Root preabsence failed'}
$cert=New-SelfSignedCertificate -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My'
$store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser')
try{$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite);$store.Add($cert)}finally{$store.Close()}
if(@(Get-ChildItem Cert:\CurrentUser\Root|Where-Object Thumbprint -CEQ $cert.Thumbprint).Count -ne 1){throw 'Synthetic Root fixture seed did not read back'}
'@|Set-Content $seedScript -Encoding utf8
 $seed=Start-Process $exe -Credential $credential -LoadUserProfile -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-File',"`"$seedScript`"",'-RunId',$run)
 try{if(!$seed.WaitForExit(15000) -or $seed.ExitCode -ne 0){throw 'Disposable non-admin Root seed fixture failed'}}finally{if(!$seed.HasExited){$seed.Kill();$null=$seed.WaitForExit(5000)};$seed.Dispose();Remove-Item $seedScript -Force}
 $launcher=Start-Process $exe -Credential $credential -LoadUserProfile -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-File',"`"$launcherScript`"",'-RunId',$run,'-SourceSHA',$sha,'-ExpectedSID',$target,'-ExpectedSessionId',[string]$self.SessionId,'-ExpectedProfilePath',"`"$profile`"",'-RecoveryJobName',$jobName,'-RecoveryGateName',$gateName,'-ExpectedLauncherSHA256',(Get-FileHash $launcherScript).Hash.ToLowerInvariant(),'-ExpectedWorkerSHA256',(Get-FileHash $workerScript).Hash.ToLowerInvariant(),'-HelperPipeName',$pipeName,'-FailureEventName',"Global\Ticket569-$run-failure",'-SourceRoot',"`"$PSScriptRoot`"",'-JobStartCounter',[string]$start,'-CounterFrequency',[string]$freq)
 $null=$launcher.Handle
 if($launcher.SessionId -ne $self.SessionId){throw 'Credential launcher did not inherit the authorized interactive session'}
 $gate.Release()
 $sequence=1;$removeMutationObserved=$false;$until=[Diagnostics.Stopwatch]::GetTimestamp()+45L*$freq
 while(!$launcher.HasExited){
  while(!$accept.Wait(50)){if($launcher.HasExited){break};if([Diagnostics.Stopwatch]::GetTimestamp() -ge $until){throw 'Framework participant fixture exceeded its bounded connection wait'}}
  if($launcher.HasExited -and !$pipe.IsConnected){break}
  $clientPID=Get-HostedCapabilityPipeClientProcessId -PipeHandle $pipe.SafePipeHandle.DangerousGetHandle()
  $client=Get-CimInstance Win32_Process -Filter "ProcessId=$clientPID"
  if((Invoke-CimMethod -InputObject $client -MethodName GetOwnerSid).Sid -cne $target -or $client.SessionId -ne $self.SessionId){throw 'Framework fixture helper caller differs from exact account/session'}
  $reader=[IO.StreamReader]::new($pipe);$writer=[IO.StreamWriter]::new($pipe);$writer.AutoFlush=$true
  while($true){
   $read=$reader.ReadLineAsync();if(!$read.Wait(10000)){throw 'Framework helper fixture request timed out'}
   if(!$read.Result){break}
   $request=ConvertFrom-Json $read.Result
   $response=@{acknowledged=$true;requestId=$request.requestId;sequence=$sequence++}
   if($request.phase -ceq 'fact'){
    switch($request.name){
     'recovery-run-credential-state'{$response.credentialWriteOwned=$false}
     'session-host-health'{$response.sessionHostHealth=@{healthy=$true;adapter='fixture-no-CUA'}}
     'recovery-root-removal-ownership'{$response.rootOwnership=@{preexisting=$false;importAttempted=$true;preabsenceSequence=1;importAttemptSequence=2}}
     default{throw 'Unexpected recovery fact in Framework fixture'}
    }
   }elseif($request.phase -cin @('intent','observation') -and $request.operation -ceq 'recovery-remove-exact-owned-currentuser-root-certificate'){
    if($request.resourceIdentity.subject -cne "CN=Ticket569-Root-Prompt-$run" -or $request.resourceIdentity.sid -cne $target){throw 'RemoveOwned fixture resource identity differs'}
    if($request.phase -ceq 'observation'){if($request.result -cne 'completed' -or !$request.observed.absent){throw 'Actual RemoveOwned did not observe owned certificate absence'};$removeMutationObserved=$true}
   }else{throw 'Unexpected recovery protocol mutation in Framework fixture'}
   $writer.WriteLine((ConvertTo-Json -Compress -Depth 10 $response))
  }
  $pipe.Dispose();$pipe=$null
  if($launcher.WaitForExit(100)){break}
  $pipe=[IO.Pipes.NamedPipeServerStreamAcl]::Create($pipeName,[IO.Pipes.PipeDirection]::InOut,4,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536,$security,[IO.HandleInheritability]::None,[IO.Pipes.PipeAccessRights]::FullControl)
  $accept=$pipe.WaitForConnectionAsync()
 }
 if(!$removeMutationObserved){throw 'Actual launcher -> worker -> RemoveOwned main-path mutation was not observed'}
 if(!$launcher.WaitForExit(10000) -or $launcher.ExitCode -ne 0 -or $job.ActiveProcesses -ne 0){throw 'Actual Framework launcher/worker success did not retain empty-job exit'}
 $resultPath=Join-Path $profile ".ticket569-$run-recovery.json";$result=Get-Content $resultPath -Raw|ConvertFrom-Json
 if($result.failed -or $result.credentialFinalCredReadError -ne 1168 -or $result.rootSubjectRemaining){throw 'Framework real empty credential/Root store readback failed'}
 if($pipe){$pipe.Dispose();$pipe=$null}
 # Exercise the actual powershell.exe -File RemoveOwned interface and its true/
 # false argument binding in the same disposable account/profile/session.
 $pipe=[IO.Pipes.NamedPipeServerStreamAcl]::Create($pipeName,[IO.Pipes.PipeDirection]::InOut,4,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536,$security,[IO.HandleInheritability]::None,[IO.Pipes.PipeAccessRights]::FullControl)
 $accept=$pipe.WaitForConnectionAsync();$removeResult=Join-Path $profile ".ticket569-$run-remove.json"
 $launcher.Dispose();$launcher=Start-Process $exe -Credential $credential -LoadUserProfile -PassThru -ArgumentList @('-NoProfile','-File',"`"$(Join-Path $PSScriptRoot 'hosted-root-import.ps1')`"",'-Mode','RemoveOwned','-RunId',$run,'-SourceSHA',$sha,'-JobStartCounter',[string]$start,'-CounterFrequency',[string]$freq,'-SupervisorPipeName',$pipeName,'-ExpectedSID',$target,'-ExpectedSessionId',[string]$self.SessionId,'-Thumbprint',('0'*40),'-ExpectedSubject',"`"CN=Ticket569-Root-Prompt-$run`"",'-OwnershipPreexisting','false','-OwnershipImportAttempted','true','-OwnershipPreabsenceSequence','1','-OwnershipImportSequence','2','-OutputPath',"`"$removeResult`"",'-HoldAfterWriteSeconds','0')
 if(!$accept.Wait(20000) -or !$launcher.WaitForExit(10000) -or $launcher.ExitCode -ne 0){throw 'Actual Framework RemoveOwned already-absent main path failed'}
 $removed=Get-Content $removeResult -Raw|ConvertFrom-Json;if(!$removed.passed -or !$removed.removedObserved){throw 'RemoveOwned actual empty store readback failed'}
 if($pipe){$pipe.Dispose();$pipe=$null}
 $probeGate=New-HostedCapabilityGate -Name "Global\Ticket569-$run-user-normal" -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)(A;;0x00100000;;;$target)"
 try{
  foreach($fault in @('none','wrong-run')){
   $pipe=[IO.Pipes.NamedPipeServerStreamAcl]::Create($pipeName,[IO.Pipes.PipeDirection]::InOut,4,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536,$security,[IO.HandleInheritability]::None,[IO.Pipes.PipeAccessRights]::FullControl)
   $accept=$pipe.WaitForConnectionAsync();$probeResult=Join-Path $profile (".ticket569-$run-probe-$fault.json")
   $probeRun=if($fault -ceq 'none'){$run}else{'d'*32}
   $launcher.Dispose();$launcher=Start-Process $exe -Credential $credential -LoadUserProfile -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-File',"`"$(Join-Path $PSScriptRoot 'hosted-user-capability.ps1')`"",'-RunId',$probeRun,'-SourceSHA',$sha,'-ProfileKind','normal','-ExpectedSID',$target,'-ExpectedSessionId',[string]$self.SessionId,'-JobStartCounter',[string]$start,'-CounterFrequency',[string]$freq,'-SupervisorPipeName',$pipeName,'-LaunchGateName',"Global\Ticket569-$run-user-normal",'-OutputPath',"`"$probeResult`"",'-HoldAfterWriteSeconds','0')
   $null=$launcher.Handle
   if($fault -ceq 'none'){
    Start-Sleep -Milliseconds 500
    if($launcher.HasExited -or $pipe.IsConnected -or (Test-Path $probeResult)){throw 'Valid early user probe mutated/connected/exited before its identity gate'}
    $probeGate.Release()
    $waitUntil=[Diagnostics.Stopwatch]::GetTimestamp()+15L*$freq
    while(!$launcher.HasExited -and !$pipe.IsConnected -and [Diagnostics.Stopwatch]::GetTimestamp() -lt $waitUntil){$null=$accept.Wait(50)}
    if($pipe.IsConnected){
     $r=[IO.StreamReader]::new($pipe);$w=[IO.StreamWriter]::new($pipe);$w.AutoFlush=$true
     while($true){$line=$r.ReadLineAsync();if(!$line.Wait(5000)){throw 'Actual user probe acknowledgement fixture timed out'};if(!$line.Result){break};$q=ConvertFrom-Json $line.Result;if($q.phase -cnotin @('intent','observation')){throw 'Unexpected actual user probe protocol request'};$w.WriteLine((ConvertTo-Json -Compress @{acknowledged=$true;requestId=$q.requestId;sequence=$sequence++}))}
    }
    if(!$launcher.WaitForExit(10000) -or !(Test-Path $probeResult)){throw 'Authorized user probe did not reach its actual post-gate API/result path'}
    $observed=Get-Content $probeResult -Raw|ConvertFrom-Json
    if($observed.sid -cne $target -or $observed.sessionId -ne $self.SessionId){throw 'Post-gate actual user identity differs'}
    # A credential-created process can have a separate window station; that
    # identity failure remains a negative result and is not capability proof.
    Write-Output "FRAMEWORK_ACTUAL_EARLY_USER_GATE_RELEASE_PASSED probePassed=$($observed.passed);NON_RDP_WINDOW_STATION_QUALIFIED"
   }else{
    if(!$launcher.WaitForExit(10000) -or $launcher.ExitCode -eq 0 -or $pipe.IsConnected -or (Test-Path $probeResult)){throw 'Mismatched user gate escaped before mutation'}
    Write-Output 'FRAMEWORK_ACTUAL_EARLY_USER_GATE_MISMATCH_REJECTED'
   }
   $pipe.Dispose();$pipe=$null
  }
 }finally{$probeGate.Dispose()}
 Write-Output 'FRAMEWORK_ACTUAL_LAUNCHER_WORKER_REMOVEOWNED_CERTIFICATE_DELETION_PASSED;HEALTH_PROTOCOL_ADAPTER_NO_CUA'
}finally{
 if($launcher){if(!$launcher.HasExited){$launcher.Kill();$null=$launcher.WaitForExit(5000)};$launcher.Dispose()}
 if($job){if($job.ActiveProcesses){$job.Terminate(137)};$job.Dispose()};if($gate){$gate.Dispose()};if($failure){$failure.Dispose()};if($pipe){$pipe.Dispose()}
 if($user){$unloadBy=[DateTime]::UtcNow.AddSeconds(20);do{$p=Get-CimInstance Win32_UserProfile -Filter "SID='$($user.SID.Value)'";if(!$p -or !$p.Loaded){break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $unloadBy);if($p -and $p.Loaded){throw 'Framework fixture refuses loaded profile cleanup'};if($p){Remove-CimInstance $p};Remove-LocalUser -SID $user.SID};$secure.Dispose()
}
