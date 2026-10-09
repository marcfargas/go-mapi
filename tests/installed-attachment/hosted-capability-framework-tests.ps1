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
# Load only the real helper definition: executing the supervisor entry point
# would start orchestration instead of this owned pipe regression.
$tokens=$null;$parseErrors=$null
$supervisorAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Scripts 'hosted-capability-supervisor.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Production supervisor parse failed'}
$helpers=@($supervisorAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'New-HostedCapabilityHelperServer'},$true))
if($helpers.Count -ne 1){throw 'Expected exactly one production helper definition'}
. ([scriptblock]::Create($helpers[0].Extent.Text))
function Wait-HelperRegressionTask($Task,[long]$Deadline,[long]$Frequency){
 $budget=Get-HostedCapabilityWaitBudget -DeadlineCounter $Deadline -CounterFrequency $Frequency -MaximumMilliseconds 5000
 if($budget -le 0 -or !$Task.Wait($budget)){throw 'Production helper regression exceeded its absolute deadline'}
}
function Get-HelperRegressionAceRows($Descriptor){
 if(!$Descriptor.DiscretionaryAcl -or !($Descriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected)){throw 'Production helper DACL is absent or unprotected'}
 foreach($ace in $Descriptor.DiscretionaryAcl){
  if($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or $ace.AceQualifier -ne [Security.AccessControl.AceQualifier]::AccessAllowed -or $ace.AceFlags -ne [Security.AccessControl.AceFlags]::None){throw 'Unexpected helper ACE type or flags'}
  # Named pipes use the Windows file generic mapping. Normalize either raw
  # generic rights or the kernel-mapped rights before comparing exact grants.
  $mask=[long]$ace.AccessMask -band 0xffffffffL
  foreach($mapping in @(@(0x10000000L,0x001f01ffL),@(0x80000000L,0x00120089L),@(0x40000000L,0x00120116L),@(0x20000000L,0x001200a0L))){
   if($mask -band $mapping[0]){$mask=($mask -band (-bnot $mapping[0])) -bor $mapping[1]}
  }
  '{0}|{1:x8}' -f $ace.SecurityIdentifier.Value,$mask
 }
}
foreach($targetSID in @($null,'S-1-5-21-0-0-0-569')){
 $RunId=[guid]::NewGuid().ToString('N');$server=$null;$client=$null
 $frequency=[Diagnostics.Stopwatch]::Frequency;$deadline=[Diagnostics.Stopwatch]::GetTimestamp()+5L*$frequency
 try{
  $server=New-HostedCapabilityHelperServer -TargetSID $targetSID
  $actualSecurity=if('System.IO.Pipes.PipesAclExtensions' -as [type]){[IO.Pipes.PipesAclExtensions]::GetAccessControl($server)}else{$server.GetAccessControl()}
  $expectedSddl="D:P(A;;GA;;;SY)(A;;GA;;;$sid)";if($targetSID){$expectedSddl+="(A;;GRGW;;;$targetSID)"}
  $expected=[Security.AccessControl.RawSecurityDescriptor]::new($expectedSddl)
  $actual=[Security.AccessControl.RawSecurityDescriptor]::new($actualSecurity.GetSecurityDescriptorBinaryForm(),0)
  $expectedAces=@(Get-HelperRegressionAceRows $expected|Sort-Object);$actualAces=@(Get-HelperRegressionAceRows $actual|Sort-Object)
  if($expectedAces.Count -ne $actualAces.Count -or ($expectedAces -join ';') -cne ($actualAces -join ';')){throw 'Production helper exact DACL grants differ'}
  $client=[IO.Pipes.NamedPipeClientStream]::new('.',"Ticket569-$RunId-helper",[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
  $accept=$server.WaitForConnectionAsync();$connect=$client.ConnectAsync(5000)
  Wait-HelperRegressionTask $connect $deadline $frequency;Wait-HelperRegressionTask $accept $deadline $frequency
  foreach($transfer in @(@($client,$server,'owned-client-to-helper'),@($server,$client,'helper-to-owned-client'))){
   $payload=[Text.Encoding]::UTF8.GetBytes($transfer[2]);$received=[byte[]]::new($payload.Length)
   $write=$transfer[0].WriteAsync($payload,0,$payload.Length);$offset=0
   while($offset -lt $received.Length){
    $read=$transfer[1].ReadAsync($received,$offset,$received.Length-$offset)
    Wait-HelperRegressionTask $read $deadline $frequency
    if($read.Result -le 0){throw 'Production helper I/O ended early'};$offset+=$read.Result
   }
   Wait-HelperRegressionTask $write $deadline $frequency
   if([Convert]::ToBase64String($received) -cne [Convert]::ToBase64String($payload)){throw 'Production helper byte I/O differs'}
  }
 }finally{if($client){$client.Dispose()};if($server){$server.Dispose()}}
}
Write-Output "PRODUCTION_HELPER_PIPE_DACL_BIDIRECTIONAL_IO_PASSED version=$($PSVersionTable.PSVersion) CLR=$([Environment]::Version);SYNTHETIC_TARGET_ACL_ONLY_CURRENT_TOKEN_CLIENT"
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
 $pipe=[IO.Pipes.NamedPipeServerStreamAcl]::Create($pipeName,[IO.Pipes.PipeDirection]::InOut,4,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536,$security,[IO.HandleInheritability]::None,[IO.Pipes.PipeAccessRights]0)
 $accept=$pipe.WaitForConnectionAsync();$start=[Diagnostics.Stopwatch]::GetTimestamp();$freq=[Diagnostics.Stopwatch]::Frequency
 # Seed only a newly created account's unique synthetic Root certificate using
 # a store API fixture; the production worker must invoke actual RemoveOwned.
 $seedScript=Join-Path $env:TEMP ("t569-seed-$run.ps1")
 @'
param([string]$RunId)
$ErrorActionPreference='Stop'
$subject="CN=Ticket569-Root-Prompt-$RunId"
$phase='identity-profile-readiness'
try{
 $childIdentity=[ordered]@{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;sessionId=[Diagnostics.Process]::GetCurrentProcess().SessionId;profile=[Environment]::GetFolderPath('UserProfile')}
 Write-Output "SEED_PHASE=$phase"
 Write-Output ('SEED_IDENTITY='+($childIdentity|ConvertTo-Json -Compress -Depth 3))
 $phase='root-preabsence'
 Write-Output "SEED_PHASE=$phase"
 if(@(Get-ChildItem Cert:\CurrentUser\Root|Where-Object Subject -CEQ $subject).Count){throw 'Synthetic Root preabsence failed'}
 $phase='certificate-create';Write-Output "SEED_PHASE=$phase"
 $cert=New-SelfSignedCertificate -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My'
 $phase='certificate-created';Write-Output "SEED_PHASE=$phase"
 $phase='root-store-create';Write-Output "SEED_PHASE=$phase"
 $store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','CurrentUser')
 try{
  $phase='root-store-open';Write-Output "SEED_PHASE=$phase"
  $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
  $phase='root-add';Write-Output "SEED_PHASE=$phase"
  $store.Add($cert)
 }finally{$store.Close()}
 $phase='root-readback';Write-Output "SEED_PHASE=$phase"
 if(@(Get-ChildItem Cert:\CurrentUser\Root|Where-Object Thumbprint -CEQ $cert.Thumbprint).Count -ne 1){throw 'Synthetic Root fixture seed did not read back'}
 $phase='complete';Write-Output "SEED_PHASE=$phase"
}catch{
 $message=[string]$_.Exception.Message
 if($message.Length -gt 1024){$message=$message.Substring(0,1024)}
 [Console]::Error.WriteLine("SEED_FAILURE_PHASE=$phase")
 [Console]::Error.WriteLine("SEED_ERROR_TYPE=$($_.Exception.GetType().FullName)")
 [Console]::Error.WriteLine("SEED_ERROR_HRESULT=$($_.Exception.HResult)")
 [Console]::Error.WriteLine("SEED_ERROR_MESSAGE=$message")
 exit 1
}
'@|Set-Content $seedScript -Encoding utf8
 $seedStdout="$seedScript.stdout";$seedStderr="$seedScript.stderr"
 $seed=$null;$seedProcessStarted=$false;$seedWaitCompleted=$null;$seedTimedOut=$null;$seedHasExited=$null;$seedExitCode=$null;$seedExitCodeRetained=$null
 $seedKillAttempted=$false;$seedKillSucceeded=$null;$seedKillError=$null;$seedKillWaitCompleted=$null
 $seedIdentity=[ordered]@{pid=$null;creationTimeUtc=$null;sessionId=$null;childReportedSid=$null;childReportedSessionId=$null;childReportedProfile=$null;intendedSid=$target;intendedSessionId=$self.SessionId;intendedProfile=$profile;intendedExecutablePath=$exe;intendedExecutableName=[IO.Path]::GetFileName($exe);parentObservedSid=$null;parentSidObservation='not queried';childSidProvenance='reported by seed child';sidMatchesIntended=$null;sessionMatchesIntended=$null;profileMatchesIntended=$null;matchPolicy='reported-only; target matches do not change the existing seed pass gate';observationErrors=@()}
 $seedIdentityErrors=@();$seedCaptureErrors=@();$seedStdoutText=$null;$seedStderrText=$null;$seedLaunchError=$null;$seedDiagnosticError=$null;$seedParentPhase='process-starting'
 try{
  try{
   try{
   Write-Output "SEED_PARENT_PHASE=$seedParentPhase"
   try{$seed=Start-Process $exe -Credential $credential -LoadUserProfile -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-File',"`"$seedScript`"",'-RunId',$run) -RedirectStandardOutput $seedStdout -RedirectStandardError $seedStderr;$seedProcessStarted=$true}catch{
    $seedLaunchError=[string]$_.Exception.Message
    throw
   }
   $seedParentPhase='process-started';Write-Output "SEED_PARENT_PHASE=$seedParentPhase"
   $seedIdentity.pid=$seed.Id
   try{$seedIdentity.creationTimeUtc=$seed.StartTime.ToUniversalTime().ToString('o')}catch{$seedIdentityErrors+=('process creation time observation failed: '+[string]$_.Exception.Message)}
   try{$seedIdentity.sessionId=$seed.SessionId}catch{$seedIdentityErrors+=('parent process session observation failed: '+[string]$_.Exception.Message)}
   $seedParentPhase=if($seedIdentityErrors.Count){'identity-incomplete'}else{'identity-observed'};Write-Output "SEED_PARENT_PHASE=$seedParentPhase"
   $seedParentPhase='waiting-15000ms';Write-Output "SEED_PARENT_PHASE=$seedParentPhase"
   $seedWaitCompleted=$seed.WaitForExit(15000)
   $seedTimedOut=!$seedWaitCompleted
   if($seedTimedOut){
    $seedParentPhase='timeout-kill';Write-Output "SEED_PARENT_PHASE=$seedParentPhase"
    $seedKillAttempted=$true
    try{$seed.Kill();$seedKillSucceeded=$true}catch{$seedKillSucceeded=$false;$seedKillError=[string]$_.Exception.Message}
    try{$seedKillWaitCompleted=$seed.WaitForExit(5000)}catch{$seedKillWaitCompleted=$false;if(!$seedKillError){$seedKillError=[string]$_.Exception.Message}else{$seedCaptureErrors+=('kill-wait failed: '+[string]$_.Exception.Message)}}
   }
   try{$seedHasExited=$seed.HasExited}catch{$seedCaptureErrors+=('process exit-state observation failed: '+[string]$_.Exception.Message)}
   if($seedHasExited -eq $true){
    try{$seedExitCode=$seed.ExitCode;$seedExitCodeRetained=($null -ne $seedExitCode)}catch{$seedExitCodeRetained=$false;$seedCaptureErrors+=('ExitCode read failed: '+[string]$_.Exception.Message)}
    if($seedExitCodeRetained -eq $false){$seedCaptureErrors+='Process exited but its ExitCode was not retained'}
   }
   try{if(Test-Path -LiteralPath $seedStdout){$read=Get-Content -LiteralPath $seedStdout -Raw -ErrorAction Stop;$seedStdoutText=if($null -eq $read){''}else{[string]$read}}}catch{$seedCaptureErrors+=('stdout read failed: '+[string]$_.Exception.Message)}
   try{if(Test-Path -LiteralPath $seedStderr){$read=Get-Content -LiteralPath $seedStderr -Raw -ErrorAction Stop;$seedStderrText=if($null -eq $read){''}else{[string]$read}}}catch{$seedCaptureErrors+=('stderr read failed: '+[string]$_.Exception.Message)}
   foreach($field in @('seedStdoutText','seedStderrText')){
    $value=Get-Variable -Name $field -ValueOnly
    if($null -ne $value){$value=[string]$value;$value=$value -replace '[^\x09\x0A\x0D\x20-\x7E]','?';if($value.Length -gt 12000){$value=$value.Substring(0,12000)+'...[truncated]'};Set-Variable -Name $field -Value $value}
   }
   if($null -ne $seedStdoutText){
    $childIdentityLine=[regex]::Match($seedStdoutText,'(?m)^SEED_IDENTITY=(\{[^\r\n]+\})\r?$')
    if($childIdentityLine.Success){
     try{
      $childIdentityRecord=ConvertFrom-Json $childIdentityLine.Groups[1].Value -ErrorAction Stop
      $seedIdentity.childReportedSid=$childIdentityRecord.sid
      $seedIdentity.childReportedSessionId=$childIdentityRecord.sessionId
      $seedIdentity.childReportedProfile=$childIdentityRecord.profile
      if(!$seedIdentity.childReportedSid -or ($null -ne $seedIdentity.sessionId -and $seedIdentity.childReportedSessionId -ne $seedIdentity.sessionId)){$seedIdentityErrors+='Child-reported identity is missing SID or differs from parent-observed session'}
      $seedIdentity.sidMatchesIntended=($seedIdentity.childReportedSid -ceq $seedIdentity.intendedSid)
      if($null -ne $seedIdentity.sessionId){$seedIdentity.sessionMatchesIntended=($seedIdentity.sessionId -eq $seedIdentity.intendedSessionId)}
      if($seedIdentity.childReportedProfile){$seedIdentity.profileMatchesIntended=($seedIdentity.childReportedProfile -ieq $seedIdentity.intendedProfile)}
     }catch{$seedIdentityErrors+=('Child identity receipt parse failed: '+[string]$_.Exception.Message)}
    }else{$seedIdentityErrors+='Child identity/profile receipt was not captured'}
   }
   $seedIdentity.observationErrors=@($seedIdentityErrors)
   $seedParentPhase=if($seedTimedOut){'timeout-observed'}elseif($seedWaitCompleted -eq $true){'wait-completed'}else{'wait-unobserved'};Write-Output "SEED_PARENT_PHASE=$seedParentPhase"
  }catch{$seedDiagnosticError=[string]$_.Exception.Message;throw}
 }finally{
  if($seedProcessStarted){
   if($null -eq $seedStdoutText){try{if(Test-Path -LiteralPath $seedStdout){$read=Get-Content -LiteralPath $seedStdout -Raw -ErrorAction Stop;$seedStdoutText=if($null -eq $read){''}else{[string]$read}}else{$seedCaptureErrors+='stdout file was not present at receipt'}}catch{$seedCaptureErrors+=('stdout read in receipt finally failed: '+[string]$_.Exception.Message)}}
   if($null -eq $seedStderrText){try{if(Test-Path -LiteralPath $seedStderr){$read=Get-Content -LiteralPath $seedStderr -Raw -ErrorAction Stop;$seedStderrText=if($null -eq $read){''}else{[string]$read}}else{$seedCaptureErrors+='stderr file was not present at receipt'}}catch{$seedCaptureErrors+=('stderr read in receipt finally failed: '+[string]$_.Exception.Message)}}
   foreach($field in @('seedStdoutText','seedStderrText')){$value=Get-Variable -Name $field -ValueOnly;if($null -ne $value){$value=[string]$value -replace '[^\x09\x0A\x0D\x20-\x7E]','?';if($value.Length -gt 12000){$value=$value.Substring(0,12000)+'...[truncated]'};Set-Variable -Name $field -Value $value}}
  }
  foreach($name in @('seedLaunchError','seedDiagnosticError','seedKillError')){
   $value=[string](Get-Variable -Name $name -ValueOnly)
   if($value){$value=$value -replace '[^\x09\x0A\x0D\x20-\x7E]','?';if($value.Length -gt 1024){$value=$value.Substring(0,1024)};Set-Variable -Name $name -Value $value}
  }
  foreach($errors in @('seedIdentityErrors','seedCaptureErrors')){$values=Get-Variable -Name $errors -ValueOnly;if($null -eq $values){$values=@()}else{$values=@($values)};for($i=0;$i -lt $values.Count;$i++){$value=[string]$values[$i];$value=$value -replace '[^\x09\x0A\x0D\x20-\x7E]','?';if($value.Length -gt 1024){$value=$value.Substring(0,1024)};$values[$i]=$value};Set-Variable -Name $errors -Value $values}
  $seedIdentity.observationErrors=@($seedIdentityErrors)
  if($seedProcessStarted){
   $seedReceipt=[ordered]@{kind='ticket569-seed-child';runId=$run;parentPhase=$seedParentPhase;scriptPath=$seedScript;stdoutPath=$seedStdout;stderrPath=$seedStderr;processStarted=$true;launchError=$null;identity=$seedIdentity;waitCompleted=$seedWaitCompleted;timedOut=$seedTimedOut;hasExited=$seedHasExited;exitCode=$seedExitCode;exitCodeRetained=$seedExitCodeRetained;killAttempted=$seedKillAttempted;killSucceeded=$seedKillSucceeded;killError=$seedKillError;killWaitCompleted=$seedKillWaitCompleted;identityErrors=$seedIdentityErrors;captureErrors=$seedCaptureErrors;diagnosticError=$seedDiagnosticError;stdout=$seedStdoutText;stderr=$seedStderrText}
  }else{
   $seedReceipt=[ordered]@{kind='ticket569-seed-child';runId=$run;parentPhase=$seedParentPhase;scriptPath=$seedScript;stdoutPath=$seedStdout;stderrPath=$seedStderr;processStarted=$false;launchError=$seedLaunchError;identity=$seedIdentity;waitCompleted=$null;timedOut=$null;hasExited=$null;exitCode=$null;exitCodeRetained=$null;killAttempted=$null;killSucceeded=$null;killError=$null;killWaitCompleted=$null;identityErrors=$seedIdentityErrors;captureErrors=$seedCaptureErrors;diagnosticError=$seedDiagnosticError;stdout=$null;stderr=$null}
  }
  try{Write-Output ('SEED_CHILD_RECEIPT='+($seedReceipt|ConvertTo-Json -Compress -Depth 6))}catch{Write-Output 'SEED_CHILD_RECEIPT_ERROR=receipt serialization or output failed';throw}
 }
  if(!$seedProcessStarted){throw 'Disposable non-admin Root seed process did not start'}
  if($seedIdentityErrors.Count){throw 'Disposable non-admin Root seed process identity observation failed'}
  if($seedCaptureErrors.Count){throw 'Disposable non-admin Root seed child output/exit capture failed'}
  if(!$seedWaitCompleted -or $seedExitCodeRetained -ne $true -or $seedExitCode -ne 0){throw 'Disposable non-admin Root seed fixture failed'}
 }finally{
  if($seed){if(!$seed.HasExited -and !$seedKillAttempted){$seed.Kill();$null=$seed.WaitForExit(5000)};$seed.Dispose()}
  Remove-Item $seedScript -Force
  if(Test-Path -LiteralPath $seedStdout){Remove-Item -LiteralPath $seedStdout -Force}
  if(Test-Path -LiteralPath $seedStderr){Remove-Item -LiteralPath $seedStderr -Force}
 }
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
  $pipe=[IO.Pipes.NamedPipeServerStreamAcl]::Create($pipeName,[IO.Pipes.PipeDirection]::InOut,4,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536,$security,[IO.HandleInheritability]::None,[IO.Pipes.PipeAccessRights]0)
  $accept=$pipe.WaitForConnectionAsync()
 }
 if(!$removeMutationObserved){throw 'Actual launcher -> worker -> RemoveOwned main-path mutation was not observed'}
 if(!$launcher.WaitForExit(10000) -or $launcher.ExitCode -ne 0 -or $job.ActiveProcesses -ne 0){throw 'Actual Framework launcher/worker success did not retain empty-job exit'}
 $resultPath=Join-Path $profile ".ticket569-$run-recovery.json";$result=Get-Content $resultPath -Raw|ConvertFrom-Json
 if($result.failed -or $result.credentialFinalCredReadError -ne 1168 -or $result.rootSubjectRemaining){throw 'Framework real empty credential/Root store readback failed'}
 if($pipe){$pipe.Dispose();$pipe=$null}
 # Exercise the actual powershell.exe -File RemoveOwned interface and its true/
 # false argument binding in the same disposable account/profile/session.
 $pipe=[IO.Pipes.NamedPipeServerStreamAcl]::Create($pipeName,[IO.Pipes.PipeDirection]::InOut,4,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536,$security,[IO.HandleInheritability]::None,[IO.Pipes.PipeAccessRights]0)
 $accept=$pipe.WaitForConnectionAsync();$removeResult=Join-Path $profile ".ticket569-$run-remove.json"
 $launcher.Dispose();$launcher=Start-Process $exe -Credential $credential -LoadUserProfile -PassThru -ArgumentList @('-NoProfile','-File',"`"$(Join-Path $PSScriptRoot 'hosted-root-import.ps1')`"",'-Mode','RemoveOwned','-RunId',$run,'-SourceSHA',$sha,'-JobStartCounter',[string]$start,'-CounterFrequency',[string]$freq,'-SupervisorPipeName',$pipeName,'-ExpectedSID',$target,'-ExpectedSessionId',[string]$self.SessionId,'-Thumbprint',('0'*40),'-ExpectedSubject',"`"CN=Ticket569-Root-Prompt-$run`"",'-OwnershipPreexisting','false','-OwnershipImportAttempted','true','-OwnershipPreabsenceSequence','1','-OwnershipImportSequence','2','-OutputPath',"`"$removeResult`"",'-HoldAfterWriteSeconds','0')
 if(!$accept.Wait(20000) -or !$launcher.WaitForExit(10000) -or $launcher.ExitCode -ne 0){throw 'Actual Framework RemoveOwned already-absent main path failed'}
 $removed=Get-Content $removeResult -Raw|ConvertFrom-Json;if(!$removed.passed -or !$removed.removedObserved){throw 'RemoveOwned actual empty store readback failed'}
 if($pipe){$pipe.Dispose();$pipe=$null}
 $probeGate=New-HostedCapabilityGate -Name "Global\Ticket569-$run-user-normal" -DaclSddl "D:P(A;;GA;;;SY)(A;;GA;;;$sid)(A;;0x00100000;;;$target)"
 try{
  foreach($fault in @('none','wrong-run')){
   $pipe=[IO.Pipes.NamedPipeServerStreamAcl]::Create($pipeName,[IO.Pipes.PipeDirection]::InOut,4,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,65536,65536,$security,[IO.HandleInheritability]::None,[IO.Pipes.PipeAccessRights]0)
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
