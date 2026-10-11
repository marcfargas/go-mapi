$ErrorActionPreference='Stop'
# Execute production control flow, with explicit Windows store/identity/process
# adapters. These checks never create a certificate or claim native deletion.
Import-Module (Join-Path $PSScriptRoot 'hosted-root-import-policy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-protocol.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
function Read-ProductionAst([string]$Name){
 $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name),[ref]$t,[ref]$e)
 if($e){throw "Production parse failed: $Name"};$a
}
$importAst=Read-ProductionAst 'hosted-root-import.ps1'
$workerAst=Read-ProductionAst 'hosted-capability-recovery-worker.ps1'
$frameworkAst=Read-ProductionAst 'hosted-capability-framework-tests.ps1'
$outer=@($importAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.Extent.Text.Contains("if(`$Mode -eq 'RemoveOwned')")})
if($outer.Count -ne 1){throw 'Importer enclosing production try/catch/finally not unique'}
$importText=$outer[0].Extent.Text
# Only two Windows identity expressions are adapted; all validation, policy,
# mutation calls, exception handling and final pass logic remain production.
$importText=$importText.Replace('[Security.Principal.WindowsIdentity]::GetCurrent()','$fixtureIdentity').Replace('([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)','$false')
$importFlow=[scriptblock]::Create($importText)
$finalPass=@($importAst.EndBlock.Statements|Where-Object {$_.Extent.Text.StartsWith("if(`$Mode -eq 'Import'){`$result.passed")})
$failExit=@($importAst.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq 'if (!$result.passed) { exit 1 }'})
$successExit=@($importAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.ExitStatementAst]})
if($finalPass.Count -ne 1 -or $failExit.Count -ne 1 -or $successExit.Count -ne 1){throw 'Production final pass/exit map differs'}
function Get-ProductionExit($Result){
 $result=$Result
 if(& ([scriptblock]::Create($failExit[0].Clauses[0].Item1.Extent.Text))){
  & ([scriptblock]::Create($failExit[0].Clauses[0].Item2.Statements[0].Pipeline.Extent.Text))
 }else{& ([scriptblock]::Create($successExit[0].Pipeline.Extent.Text))}
}
$RunId='a'*32;$SourceSHA='b'*40;$ExpectedSID='S-1-5-21-1';$ExpectedSessionId=7;$ExpectedProfilePath='/qualified-adapter-profile'
$Thumbprint='C'*40;$ExpectedSubject="CN=Ticket569-Root-Prompt-$RunId"
$fixtureIdentity=@{User=@{Value=$ExpectedSID}}
function Get-Process {param($Id,$ErrorAction)@{SessionId=$ExpectedSessionId;StartTime=[DateTime]::UtcNow}}
function Get-CimInstance {param($ClassName,$Filter)@{Loaded=$true}}
function Connect-HostedCapabilityHelper {param($PipeName)$script:connection}
function Get-ChildItem {
 param($Path,$ErrorAction)
 $script:reads++
 if($script:case -ceq 'readback-throw' -and $script:reads -gt 1){throw 'adapted store readback failure'}
 if($script:recoveryCase -ceq 'wrong-subject' -and $script:reads -gt 1){return @([pscustomobject]@{Thumbprint=$Thumbprint;Subject='CN=wrong'})}
 @($script:store)
}
function Remove-Item {
 param($LiteralPath,$Confirm,$ErrorAction)
 $script:actions.Add($LiteralPath)
 if($LiteralPath -cne "Cert:\CurrentUser\Root\$Thumbprint"){throw 'Deletion path differs from exact owned thumbprint'}
 if($script:peerState.frames.Count -ne 1 -or $script:peerState.frames[0].phase -cne 'intent'){throw 'Mutation preceded real pipe acknowledged intent'}
 if($script:case -ceq 'remove-throw'){throw 'adapted deletion failure'}
 if($script:case -cne 'residual'){$script:store=@()}
}
function Get-FixturePeerError($Exception,$State,$Task){
 $chain=[Collections.Generic.List[object]]::new();$pending=[Collections.Generic.Stack[Exception]]::new();$pending.Push($Exception)
 while($pending.Count){
  $current=$pending.Pop()
  $chain.Add(@{type=$current.GetType().FullName;hresult=$current.HResult;detail=$current.ToString()})
  if($current -is [AggregateException]){foreach($inner in $current.InnerExceptions){$pending.Push($inner)}}
  elseif($current.InnerException){$pending.Push($current.InnerException)}
 }
 @{phase=$State.phase;caseName=$State.caseName;frameCount=$State.frames.Count;lastFramePhase=$State.lastFramePhase;taskStatus=$(if($Task){[string]$Task.Status}else{'not-created'});acceptTaskStatus=$State.acceptTaskStatus;serverConnectedBeforeRelease=$State.serverConnectedBeforeRelease;exceptionChain=@($chain)}
}
$script:peerFault='none'
function Open-FixturePeer([bool]$Deny){
 $name='Ticket569-'+[guid]::NewGuid().ToString('N')+'-helper'
 $script:peerState=[hashtable]::Synchronized(@{caseName=$script:case;phase='accept';frames=[Collections.Generic.List[object]]::new();lastFramePhase=$null;error=$null;acceptTaskStatus='not-created';serverConnectedBeforeRelease=$false;order=[Collections.Generic.List[string]]::new()})
 $server=$null;$accept=$null;$script:connection=$null;$script:peer=$null;$script:peerTask=$null
 try{
  $server=[IO.Pipes.NamedPipeServerStream]::new($name,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,4096,4096)
  # Start accept on the caller before connect, and complete it before handing
  # the server to another runspace or letting production close the client.
  $accept=$server.WaitForConnectionAsync();$peerState.order.Add('accept-started')
  $script:connection=Connect-HostedCapabilitySupervisor -PipeName $name -TimeoutMilliseconds 5000
  $peerState.order.Add('client-connected')
  if(!$accept.Wait(5000)){throw 'Fixture peer connection timeout'}
  $peerState.acceptTaskStatus=[string]$accept.Status;$peerState.serverConnectedBeforeRelease=$server.IsConnected
  if($peerState.acceptTaskStatus -cne 'RanToCompletion' -or !$peerState.serverConnectedBeforeRelease){throw 'Fixture server accept did not produce a connected server before release'}
  $peerState.order.Add('accept-completed')
  $script:peer=[powershell]::Create()
  $null=$script:peer.AddScript({param($server,$state,$deny,$fault,$errorFormatter)
   $ErrorActionPreference='Stop'
   $formatError=[scriptblock]::Create($errorFormatter);$read=$null;$pendingMutation=$null
   try{
    $state.phase='read'
    $r=[IO.StreamReader]::new($server);$w=[IO.StreamWriter]::new($server);$w.AutoFlush=$true
    while($true){
     $state.phase='read'
     $read=if($fault -ceq 'read'){[Threading.Tasks.Task]::FromException[string]([IO.IOException]::new('Injected fixture read fault',-2146232800))}else{$r.ReadLineAsync()}
     if(!$read.Wait(5000)){throw 'Fixture peer frame timeout'}
     if($null -eq $read.Result){
      if($pendingMutation){throw 'Fixture peer EOF before the acknowledged intent observation'}
      break
     }
     $q=ConvertFrom-Json -InputObject $read.Result -ErrorAction Stop
     if(!$q -or $q.phase -cnotin @('intent','observation') -or !$q.requestId){throw 'Fixture peer malformed mutation frame'}
     $state.frames.Add($q);$state.lastFramePhase=$q.phase
     if($q.phase -ceq 'intent'){
      if($pendingMutation){throw 'Fixture peer received intent before the previous observation'}
      if(!$deny){$pendingMutation=$q.requestId}
     }else{
      if(!$pendingMutation -or $q.requestId -cne $pendingMutation){throw 'Fixture peer observation lacks its exact acknowledged intent'}
      $pendingMutation=$null
     }
     $state.phase='write'
     if($fault -ceq 'write'){
      $failingWriter=[pscustomobject]@{};$failingWriter|Add-Member ScriptMethod WriteLine {param($Line)throw [IO.IOException]::new('Injected fixture write fault',-2146232800)}
      $failingWriter.WriteLine('injected-ack-write')
     }
     $w.WriteLine((ConvertTo-Json -Compress @{acknowledged=(!$deny);requestId=$q.requestId;sequence=$state.frames.Count}))
    }
   }catch{$state.error=& $formatError $_.Exception $state $read}finally{$server.Dispose()}
  }.ToString()).AddArgument($server).AddArgument($script:peerState).AddArgument($Deny).AddArgument($script:peerFault).AddArgument(${function:Get-FixturePeerError}.ToString())
  $script:peerTask=$script:peer.BeginInvoke();$peerState.order.Add('peer-started')
  $peerState.order.Add('client-released')
 }catch{
  $peerState.error=Get-FixturePeerError $_.Exception $peerState $accept
  if($connection){Close-HostedCapabilitySupervisorConnection $connection}
  if($peer){$peer.Dispose()};if($server){$server.Dispose()}
  throw [InvalidOperationException]::new((ConvertTo-Json $peerState.error -Depth 24 -Compress),$_.Exception)
 }
}
function Close-FixturePeer {
 Close-HostedCapabilitySupervisorConnection $script:connection
 if(!$script:peerTask.AsyncWaitHandle.WaitOne(5000)){throw 'Fixture peer did not terminate'}
 try{$null=$script:peer.EndInvoke($script:peerTask)}finally{$script:peer.Dispose()}
 if($script:peerState.error){throw (ConvertTo-Json $script:peerState.error -Depth 24 -Compress)}
}
foreach($caseName in @('present','absent','preexisting','missing-owned','missing-sequence','unordered','wrong-subject','duplicate','deny-intent','remove-throw','residual','readback-throw')){
 $script:case=$caseName;$script:reads=0;$script:actions=[Collections.Generic.List[string]]::new()
 $script:store=@([pscustomobject]@{Thumbprint=$Thumbprint;Subject=$ExpectedSubject})
 if($caseName -ceq 'absent'){$script:store=@()}
 if($caseName -ceq 'wrong-subject'){$script:store[0].Subject='CN=wrong'}
 if($caseName -ceq 'duplicate'){$script:store+= $script:store[0]}
 $Mode='RemoveOwned';$ownershipPreexistingValue=$caseName -ceq 'preexisting';$ownershipImportAttemptedValue=$caseName -cne 'missing-owned'
 $OwnershipPreabsenceSequence=1L;$OwnershipImportSequence=2L
 if($caseName -ceq 'missing-sequence'){$OwnershipPreabsenceSequence=0L}
 if($caseName -ceq 'unordered'){$OwnershipImportSequence=1L}
 $credentialSeeded=$false;$result=@{passed=$false;error=$null;removedObserved=$false};$supervisor=$null
 Open-FixturePeer ($caseName -ceq 'deny-intent')
 try{. $importFlow;. ([scriptblock]::Create($finalPass[0].Extent.Text))}finally{Close-FixturePeer}
 $expectedPass=$caseName -cin @('present','absent','preexisting')
 $expectedExit=if($expectedPass){0}else{1}
 if([bool]$result.passed -ne $expectedPass -or (Get-ProductionExit $result) -ne $expectedExit){throw "Production RemoveOwned pass/exit mismatch: $caseName"}
 if($expectedPass -and $caseName -cne 'preexisting' -and (!$result.removedObserved -or @($script:store).Count)){throw 'Accepted adapted deletion/absence lacks final absence'}
 if(!$expectedPass -and !$result.error){throw 'Production fault lacks retained result error'}
 $expectedActions=if($caseName -cin @('present','remove-throw','residual','readback-throw')){1}else{0}
 if($script:actions.Count -ne $expectedActions){throw "Production mutation count mismatch: $caseName"}
 if($expectedActions -and ($script:peerState.frames.Count -ne 2 -or $script:peerState.frames[1].phase -cne 'observation')){throw 'Production mutation lacks real pipe observation'}
 if($caseName -cin @('remove-throw','residual','readback-throw') -and $script:peerState.frames[1].result -cne 'failed'){throw 'Mutation error lacked failed real pipe observation'}
 if($caseName -ceq 'preexisting' -and (!$result.preservedPreexisting -or @($script:store).Count -ne 1)){throw 'Preexisting adapted store changed'}
 Write-Output "ROOT_REMOVEOWNED_CASE case=$caseName passed=$($result.passed) exit=$expectedExit mutations=$($script:actions.Count) frames=$($script:peerState.frames.Count)"
}
Write-Output 'ROOT_REMOVEOWNED_EXTRACTED_MAINPATH_PASSED;STORE_IDENTITY_ADAPTERS_NO_NATIVE_DELETION'

# Exercise these exact fixture functions, before later Windows adapters replace
# protocol-close helpers. Normal zero-frame close needs no goodbye frame.
foreach($attempt in 1..20){
 $script:case="zero-frame-immediate-close-$attempt";Open-FixturePeer $false
 if($peerState.acceptTaskStatus -cne 'RanToCompletion' -or $peerState.serverConnectedBeforeRelease -ne $true -or ($peerState.order -join ',') -cne 'accept-started,client-connected,accept-completed,peer-started,client-released'){throw 'Fixture released a client before accepted server handoff'}
 Close-FixturePeer
 if($peerState.frames.Count -ne 0 -or $peerState.error){throw 'Zero-frame EOF was suppressed or gained a frame'}
 Write-Output "ROOT_FIXTURE_ZERO_FRAME_ACCEPT_BEFORE_CLOSE attempt=$attempt frames=0 acceptTaskStatus=$($peerState.acceptTaskStatus) serverConnectedBeforeRelease=$($peerState.serverConnectedBeforeRelease)"
}
foreach($faultCase in @('partial-frame','frame-timeout','intent-close','read','write')){
 $script:case=$faultCase;$script:peerFault=if($faultCase -cin @('read','write')){$faultCase}else{'none'}
 Open-FixturePeer $false
 $failure=$null
 if($faultCase -ceq 'partial-frame'){$connection.Writer.Write('{"phase":"intent"');$connection.Writer.Flush()}
 if($faultCase -cin @('intent-close','write')){
  $request=@{phase='intent';requestId=[guid]::NewGuid().ToString('N')}
  $connection.Writer.WriteLine((ConvertTo-Json $request -Compress))
  if($faultCase -ceq 'intent-close'){
   $ack=$connection.Reader.ReadLineAsync();if(!$ack.Wait(5000)){throw 'Fault test intent acknowledgement timed out'}
   $reply=ConvertFrom-Json $ack.Result
   if(!$reply.acknowledged -or $reply.requestId -cne $request.requestId){throw 'Fault test never had an acknowledged intent'}
  }
 }
 if($faultCase -ceq 'frame-timeout'){
  # Keep the actual connected client open until the peer's five-second frame
  # deadline fires; closing first would test EOF rather than timeout.
  if(!$peerTask.AsyncWaitHandle.WaitOne(7000)){throw 'Peer frame timeout test remained live'}
 }
 try{Close-FixturePeer}catch{$failure=$_}
 if(!$failure -or !$peerState.error){throw "Fixture swallowed peer fault $faultCase"}
 $errorDetail=$peerState.error
 $expectedPhase=if($faultCase -ceq 'write'){'write'}else{'read'}
 $expectedFrames=if($faultCase -cin @('intent-close','write')){1}else{0}
 $expectedLastPhase=if($expectedFrames){'intent'}else{$null}
 if($errorDetail.phase -cne $expectedPhase -or $errorDetail.caseName -cne $faultCase -or $errorDetail.frameCount -ne $expectedFrames -or $errorDetail.lastFramePhase -cne $expectedLastPhase -or !$errorDetail.taskStatus -or !$errorDetail.exceptionChain.Count){throw 'Peer fault lost structured operation context'}
 if($faultCase -cin @('read','write') -and @($errorDetail.exceptionChain|Where-Object {$_.type -ceq 'System.IO.IOException' -and $_.hresult -eq -2146232800}).Count -ne 1){throw 'Injected peer fault lost exact IOException/HResult'}
 if($faultCase -ceq 'read' -and $errorDetail.taskStatus -cne 'Faulted'){throw 'Injected read did not fault the actual task wait'}
 Write-Output ('ROOT_FIXTURE_PEER_FAULT_RETAINED '+(ConvertTo-Json $errorDetail -Depth 24 -Compress))
}
$script:peerFault='none'
Write-Output 'ROOT_FIXTURE_ACCEPT_ORDER_AND_STRICT_PEER_FAULTS_PASSED;LOCAL_PIPE_RUNTIME_WINDOWS_FUTURE_SOURCE_PROOF'

# Extract the exact worker health/enumeration/foreach/result checks. Setup's
# Windows identity/profile/Job/native credential checks are outside this seam.
$workerTry=@($workerAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0]
$begin=@($workerTry.Body.Statements|Where-Object {$_.Extent.Text.StartsWith('$sessionHostHealthBefore=Get-HostedCapabilityHelperFact')})[0]
$end=@($workerTry.Body.Statements|Where-Object {$_.Extent.Text.StartsWith('if(@(Get-ChildItem')})[-1]
$fixtureSourceRoot=$PSScriptRoot
$workerFlow=[scriptblock]::Create('$PSScriptRoot=$fixtureSourceRoot'+"`n"+$workerAst.Extent.Text.Substring($begin.Extent.StartOffset,$end.Extent.EndOffset-$begin.Extent.StartOffset))
function Get-HostedCapabilityHelperFact {
 param($Connection,$RunId,$SourceSHA,$Name,$ResourceIdentity,$Observed)
 if($Name -ceq 'session-host-health'){
  @{sessionHostHealth=@{healthy= !($script:recoveryCase -ceq 'unhealthy-before' -and $Observed.phase -ceq 'recovery-before-root-cleanup') -and !($script:recoveryCase -ceq 'unhealthy-after' -and $Observed.phase -ceq 'recovery-after-root-cleanup');adapter='qualified-portable'}}
 }elseif($Name -ceq 'recovery-root-removal-ownership'){
  if($ResourceIdentity.thumbprint -cne $Thumbprint -or $ResourceIdentity.subject -cne $ExpectedSubject){throw 'Worker requested different ownership identity'}
  if($script:recoveryCase -ceq 'missing-ownership'){return @{}}
  @{rootOwnership=@{preexisting=$false;importAttempted=$true;preabsenceSequence=1;importAttemptSequence=2}}
 }else{throw 'Unexpected extracted worker fact'}
}
function Close-HostedCapabilitySupervisorConnection {param($Connection)}
function Test-Path {param($LiteralPath)($script:childStarted -and $script:recoveryCase -cne 'missing-result')}
function Get-Content {
 param($LiteralPath,[switch]$Raw)
 if($script:recoveryCase -ceq 'truncated-result'){return '{'}
 ConvertTo-Json -Compress @{passed=$script:recoveryCase -cne 'failed-result';removedObserved=$true;thumbprint=$(if($script:recoveryCase -ceq 'wrong-thumb'){'D'*40}else{$Thumbprint});subject=$ExpectedSubject}
}
function Write-RecoveryResult {param($Value)$script:workerResult=$Value}
function Start-Process {
 param($FilePath,$ArgumentList,[switch]$PassThru)
 $script:childStarted=$true;$script:generatedArgs=@($ArgumentList)
 if($script:recoveryCase -ceq 'timeout'){$script:JobStartCounter=[Diagnostics.Stopwatch]::GetTimestamp()-25L*60L*$CounterFrequency}
 $obj=[pscustomobject]@{Id=123;StartTime=[DateTime]::UtcNow;MainModule=@{FileName=$FilePath};SessionId=$(if($script:recoveryCase -ceq 'wrong-session'){8}else{7});HasExited=$script:recoveryCase -cne 'timeout';ExitCode=$(if($script:recoveryCase -ceq 'nonzero'){1}else{0});Killed=$false;Disposed=$false;Waits=0;Refreshed=$false}
 if($script:recoveryCase -ceq 'wrong-image'){$obj.MainModule.FileName='/wrong/image'}
 $obj|Add-Member ScriptMethod WaitForExit {param($Milliseconds)$this.Waits++;$this.HasExited}
 $obj|Add-Member ScriptMethod Kill {$this.Killed=$true;$this.HasExited=$true}
 $obj|Add-Member ScriptMethod Refresh {$this.Refreshed=$true}
 $obj|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
 $script:retainedProcess=$obj
 # The child adapter represents only its supplied result and logical store
 # observation; it never executes the Windows Certificate provider.
 if($script:recoveryCase -cne 'residual-root'){$script:store=@()}
 $obj
}
$env:WINDIR=if($IsWindows){$env:WINDIR}else{'/qualified-windows'}
$HelperPipeName="Ticket569-$RunId-helper";$RecoveryJobName="Global\Ticket569-$RunId-recovery"
$CounterFrequency=[Diagnostics.Stopwatch]::Frequency;$recoveryIdentity=@{sid=$ExpectedSID;sessionId=$ExpectedSessionId}
$credentialTarget="ticket569-hosted-capability-$RunId";$credentialWriteOwned=$false;$credentialRecoveryAction='preserve-absent';$credentialDeleteError=1168;$credentialFinalError=1168
foreach($caseName in @('success','empty','missing-ownership','wrong-subject','duplicate','nonzero','timeout','missing-result','truncated-result','failed-result','wrong-thumb','wrong-session','wrong-image','unhealthy-before','unhealthy-after','residual-root')){
 $script:recoveryCase=$caseName;$script:childStarted=$false;$script:workerResult=$null;$script:retainedProcess=$null
 $script:JobStartCounter=[Diagnostics.Stopwatch]::GetTimestamp();$recoveryDeadline=$JobStartCounter+24L*60L*$CounterFrequency
 $script:store=@([pscustomobject]@{Thumbprint=$Thumbprint;Subject=$ExpectedSubject});$supervisor=@{};$script:reads=0;$script:case='worker'
 if($caseName -ceq 'empty'){$script:store=@()}
 if($caseName -ceq 'duplicate'){$script:store+= $script:store[0]}
 $failure=$null;try{. $workerFlow}catch{$failure=$_.Exception.Message}
 if($caseName -ceq 'success'){
  if($failure -or !$script:workerResult -or $script:workerResult.failed -or $script:workerResult.rootSubjectRemaining -or @($script:workerResult.removedRootThumbprints).Count -ne 1 -or !$script:retainedProcess.Disposed){throw "Extracted worker success not retained: $failure"}
  if($script:retainedProcess.Waits -lt 1 -or !$script:retainedProcess.Refreshed -or !$script:retainedProcess.HasExited -or $script:retainedProcess.ExitCode -ne 0 -or $script:workerResult.sid -cne $ExpectedSID -or $script:workerResult.sessionId -ne $ExpectedSessionId -or $script:workerResult.profilePath -cne $ExpectedProfilePath -or $script:workerResult.sourceSHA -cne $SourceSHA -or $script:workerResult.removedRootThumbprints[0] -cne $Thumbprint){throw 'Successful adapted process/result binding differs'}
  $successfulArgs=@($script:generatedArgs);$successfulStart=$JobStartCounter
 }elseif($caseName -ceq 'empty'){
  if($failure -or $script:childStarted -or $script:workerResult.failed -or @($script:workerResult.removedRootThumbprints).Count){throw 'Adapted empty worker unexpectedly invoked removal or failed'}
 }elseif(!$failure){throw "Extracted worker fault passed: $caseName"}
 if($caseName -cin @('unhealthy-before','unhealthy-after') -and (!$script:workerResult.failed -or $script:workerResult.rootStatus -ceq 'verified')){throw 'Unhealthy adapted session reached verified'}
 if($caseName -ceq 'timeout' -and !$script:retainedProcess.Killed){throw 'Actual job-clock timeout did not kill adapted process'}
 Write-Output "RECOVERY_ROOT_LOOP_CASE case=$caseName failure=$failure"
}
Write-Output 'RECOVERY_ROOT_LOOP_EXTRACTED_MAINPATH_PASSED;PROCESS_STORE_HEALTH_ADAPTERS'

# Compare generated production argv to the direct actual Windows CLI fixture.
# Only thumbprint (including its run-scoped receipt filename) and finishing
# hold may differ; ordering of named arguments is immaterial to -File binding.
$direct=@($frameworkAst.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Start-Process' -and $n.Extent.Text.Contains("'-Mode','RemoveOwned'")},$true))
if($direct.Count -ne 1){throw 'Direct absent CLI not unique'}
$argsAst=@($direct[0].CommandElements|Where-Object {$_ -is [Management.Automation.Language.ArrayExpressionAst]})[0]
$run=$RunId;$sha=$SourceSHA;$start=$successfulStart;$freq=$CounterFrequency;$pipeName=$HelperPipeName;$target=$ExpectedSID;$self=@{SessionId=$ExpectedSessionId};$removeResult=Join-Path $ExpectedProfilePath ".ticket569-$RunId-root-remove-$('0'*40).json"
$directArgs=@(& ([scriptblock]::Create('$PSScriptRoot=$fixtureSourceRoot'+"`n"+$argsAst.Extent.Text)))
function Argument-Map($Values){
 $map=@{};for($i=0;$i -lt $Values.Count;$i++){
  $key=[string]$Values[$i];if($key -cin @('-NoLogo','-NoProfile','-NonInteractive')){$map[$key]=$true}else{if($i+1 -ge $Values.Count){throw 'Malformed generated argv'};$map[$key]=[string]$Values[++$i]}
 };$map
}
$a=Argument-Map $successfulArgs;$b=Argument-Map $directArgs
if($b['-HoldAfterWriteSeconds'] -cne '0'){throw 'Direct absent CLI must have bounded finishing hold'};$b.Remove('-HoldAfterWriteSeconds')
if($b['-Thumbprint'] -cne ('0'*40)){throw 'Direct absent CLI thumbprint changed'};$b['-Thumbprint']=$a['-Thumbprint'];$b['-OutputPath']=$b['-OutputPath'].Replace(('0'*40),$Thumbprint.ToLowerInvariant())
if($a.Count -ne $b.Count){throw 'Direct/worker CLI argument counts differ'}
foreach($key in $a.Keys){if(!$b.ContainsKey($key) -or $a[$key] -cne $b[$key]){throw "Direct/worker CLI binding differs: $key"}}
Write-Output 'RECOVERY_REMOVEOWNED_DIRECT_CLI_ARGV_BINDING_PASSED'

# Focused fixture/workflow checks: a zero exit or UNRUN cannot supply a marker.
$fixtureText=$frameworkAst.Extent.Text
$ciText=[IO.File]::ReadAllText((Join-Path $fixtureSourceRoot '../../.github/workflows/ci.yml'))
if($fixtureText -match 'CERTIFICATE_DELETION_PASSED|New-SelfSignedCertificate|CertAddCertificateContextToStore|seedStage|removeMutationObserved'){throw 'Ordinary fixture retained seed or false deletion proof'}
foreach($marker in @('FRAMEWORK_ACTUAL_EMPTY_STORE_RECOVERY_PASSED;HEALTH_PROTOCOL_ADAPTER_NO_CUA','FRAMEWORK_ACTUAL_REMOVEOWNED_ALREADY_ABSENT_CLI_PASSED;SIMULATED_LEDGER_IMPORT_ATTEMPT_NO_IMPORT','FRAMEWORK_ACTUAL_PROFILE_ACCOUNT_ABSENCE_PASSED')){
 if(!$fixtureText.Contains($marker) -or !$ciText.Contains($marker)){throw "Actual required fixture marker missing: $marker"}
}
if(!$ciText.Contains('$frameworkOutput -cnotcontains $marker') -or !$ciText.Contains('$rootOutput -cnotcontains $marker') -or !$ciText.Contains('if ($rootExit -ne 0)') -or !$ciText.Contains('if ($frameworkExit -ne 0)')){throw 'CI must fail absent proof/UNRUN and propagate nonzero exits'}
Write-Output 'ROOT_FIXTURE_TRUTHFUL_MARKER_SOURCE_CHECKS_PASSED'
