$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-owner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-present-root-support.psm1') -Force
$tokens=$null;$parseErrors=$null
$supervisorAST=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-capability-supervisor.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Supervisor parse failed'}
foreach($name in @('Assert-HostedPresentRootInterceptEligibility','Try-HostedPresentRootIntercept','Get-HostedPresentRootAdmission','Assert-HostedPresentRootBarrier','Process-HostedPresentRootBarrier','Assert-HostedExerciseRecoveryCutoff','Pump-HostedCapabilityHelper','Save-HostedPresentRootRecoveryEvidence','Invoke-HostedSessionRecovery')){
 $functions=@($supervisorAST.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($functions.Count -ne 1){throw "Source extraction failed $name"}
 . ([scriptblock]::Create($functions[0].Extent.Text))
}
function Expect-Failure([scriptblock]$Action,[string]$Name){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};if(!$caught){throw "Present Root fault escaped $Name"};Write-Output "PRESENT_ROOT_ADAPTER_REFUSED $Name"}
function Clone($Value){ConvertFrom-Json (ConvertTo-Json $Value -Depth 64) -AsHashtable}
$originalWindir=$env:WINDIR
$temp=Join-Path ([IO.Path]::GetTempPath()) ('t569-present-source-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
$env:WINDIR=Join-Path $temp 'qualified-windows'
$RunId='a'*32;$expectedSha='b'*40;$frequency=[Diagnostics.Stopwatch]::Frequency;$TestFault='present-root-recovery';$ledger=$null
function Handle($ExitCode=137) {
 $o=[pscustomobject]@{Exited=$false;ExitCode=$ExitCode;TerminationFails=$false;WaitFails=$false;Disposed=$false;Requested=$null}
 $o|Add-Member ScriptMethod Wait {param($Ms)if($this.WaitFails){return $false};$this.Exited}
 $o|Add-Member ScriptMethod Terminate {param($Code)if($this.TerminationFails){throw 'terminate adapter failed'};$this.Requested=$Code;$this.Exited=$true}
 $o
}
function Get-HostedObservedProfileContext($ProfilePath,$StepName){@{kind=$script:profileKind;volumeId=$script:volume;profilePath=$ProfilePath}}
function Test-HostedCapabilityProcessIdentity {param($ProcessId,$CreationFileTimeUtc)@{matches=(!$script:identityLost)}}
function Test-HostedCapabilityCommandArguments {param($Command,$Arguments)!$script:commandWrong}
function Invoke-SessionOwnerControl {param($Request,$TimeoutMilliseconds)if($script:healthThrows){throw 'lost health adapter'};$script:healthCalls++;$script:health}
function New-SessionOwnerRequest {param($Command,$Extra)if($Extra.allowRecoveryWatcher){throw 'Replacement watcher prohibited'};$Extra.command=$Command;$Extra}
function Close-HostedCapabilityHelperEndpoint {param([switch]$Reopen,[switch]$AllowRecoveryHandoff)if(!$Reopen -or $AllowRecoveryHandoff){throw 'Wrong endpoint handoff'};$script:closed=$true;$script:helperReader=$null;$script:helperReadTask=$null;$script:helperServer=@{IsConnected=$false}}
function Drain-HostedCapabilityFinishingHelpers {}
function New-Context {
 if($script:ledger){Close-HostedCapabilityLedger $script:ledger}
 $script:runRoot=Join-Path $temp ([guid]::NewGuid().ToString('N'));$script:EvidenceDirectory=$runRoot;New-Item -ItemType Directory $runRoot|Out-Null
 $script:ledger=New-HostedCapabilityLedger -Directory $runRoot -RunId $RunId -SourceSHA $expectedSha -BootMarker 'synthetic' -JobStartCounter ([Diagnostics.Stopwatch]::GetTimestamp()) -CounterFrequency $frequency
 $script:profilePath=Join-Path $runRoot 'profile';New-Item -ItemType Directory $profilePath|Out-Null
 $script:profileKind='normal';$script:volume='synthetic-volume';$script:identityLost=$false;$script:commandWrong=$false;$script:healthThrows=$false;$script:healthCalls=0
 $script:pending=$null;$script:helperPending=$null;$script:presentRootBarrier=$null;$script:presentRootIntercept=$null;$script:failure=$false;$script:closed=$false;$script:cleanupCalled=$false
 $script:TestFault='present-root-recovery';$script:exerciseRecoveryCutoff=$null;$script:presentRootRecoveryEvidence=$null
 $script:thumb='C'*40;$script:subject="CN=Ticket569-Root-Prompt-$RunId"
 $script:importer=@{pid=501;creationFileTimeUtc=111111;sid='S-1-5-21-1-2-3-1001';sessionId=7;scriptPath=(Join-Path $PSScriptRoot 'hosted-root-import.ps1');scriptSHA256=(Get-FileHash (Join-Path $PSScriptRoot 'hosted-root-import.ps1')).Hash.ToLowerInvariant();parent=@{pid=401;creationFileTimeUtc=999}}
 $script:identity=$importer.Clone();$identity.role='root-import';$script:expectedRootImporter=$importer
 $script:rootImporterHandle=Handle;$script:rootImporterParentHandle=Handle;$script:ownerProcess=Handle
 $script:ownerIdentity=@{pid=601;creationFileTimeUtc=222222}
 $script:presentRootPromptIdentity=@{pid=701;creationFileTimeUtc=333333}
 $script:workerIdentity=@{pid=801;creationFileTimeUtc=444444}
 $script:worker=Handle
 $script:job=[pscustomobject]@{ActiveProcesses=1;FailTermination=$false;Terminated=$false}
 $job|Add-Member ScriptMethod Terminate {param($Code)if($this.FailTermination){throw 'job termination adapter failed'};$this.Terminated=$true;$this.ActiveProcesses=0;$script:worker.Exited=$true}
 $script:writer=[pscustomobject]@{Lines=[Collections.Generic.List[string]]::new()};$writer|Add-Member ScriptMethod WriteLine {param($Line)$this.Lines.Add($Line)}
 $sessionEvent=Write-HostedCapabilityLedgerEvent $ledger @{phase='process';operation='exact-active-user-session-observed';resourceIdentity=@{sid=$importer.sid;sessionId=7;profilePath=$profilePath;stepName='exact-active-user-wts-session';profileContext=@{kind='normal';volumeId=$volume}}}
 $script:authoritativeSessionFact=@{sid=$importer.sid;sessionId=7;profilePath=$profilePath;stepName='exact-active-user-wts-session';profileContext=@{kind='normal';volumeId=$volume};ledgerSequence=$sessionEvent.sequence}
 $resource=@{store='CurrentUser/Root';thumbprint=$thumb;subject=$subject;sid=$importer.sid;sessionId=7}
 $pre=Write-HostedCapabilityLedgerEvent $ledger @{phase='process';operation='helper-fact-currentuser-root-exact-thumbprint-preabsence';resourceIdentity=$resource;observed=@{matchCount=0;preexisting=$false};processIdentity=$identity}
 $importIntent=Write-HostedCapabilityLedgerEvent $ledger @{phase='intent';requestId='import';operation='import-exact-currentuser-root-certificate';resourceIdentity=$resource;processIdentity=$identity}
 $observed=@{waited=$true;processExited=$true;identityCreationRetained=$true;exitCode=0;imageMatchesExpected=$true;timedOut=$false;terminationRequested=$false;process=@{pid=901;creationFileTimeUtc=555555;sid=$importer.sid;sessionId=7;thumbprint=$thumb;executable=(Join-Path $env:WINDIR 'System32\certutil.exe')}}
 $importObs=Write-HostedCapabilityLedgerEvent $ledger @{phase='observation';requestId='import';operation='import-exact-currentuser-root-certificate';resourceIdentity=$resource;result='completed';observed=$observed;processIdentity=$identity}
 $script:rootPreabsenceFacts=@{};$rootPreabsenceFacts[$thumb]=@{sequence=$pre.sequence;subject=$subject;sid=$importer.sid;sessionId=7}
 $script:rootImportAttempts=@{};$rootImportAttempts[$thumb]=$importIntent.sequence
 $script:rootImportObservations=@{};$rootImportObservations[$thumb]=$importObs
 $script:request=@{schema='ticket569-supervisor-request-v1';runId=$RunId;sourceSHA=$expectedSha;requestId='unapproved-delete';phase='intent';operation='remove-exact-owned-currentuser-root-certificate';resourceIdentity=$resource;precondition=@{exactMatch=$true;importAttempted=$true;preabsenceSequence=$pre.sequence}}
 $now=[Diagnostics.Stopwatch]::GetTimestamp();$script:deadlines=@{work=$now+1000L*$frequency;cleanup=$now+1400L*$frequency}
 $script:health=@{ok=$true;result=@{healthy=$true;connected=$true;state='connected';session='ticket569';ownerPID=$ownerIdentity.pid;promptServiceAlive=$true;promptServiceIdentity=$presentRootPromptIdentity}}
 $script:prompt=@{schema='ticket569-hosted-cua-prompt-v1';status='harness-defect';fault='the exact user/session CurrentUser Root child did not publish a successful post-cleanup result';answerIssued=$true;promptClosed=$true;sessionOwnerRetained=$true;disconnected=$false;daemonStopped=$false;privateRuntimeRemoved=$false;removalConsentObserved=$false;importLaunchReceipt=@{pid=$importer.pid}}
 Write-HostedCapabilityAtomicJson (Join-Path $EvidenceDirectory 'current-user-root-prompt.json') $prompt
 $script:attached=@{PID=$importer.pid;CreationFileTimeUtc=$importer.creationFileTimeUtc;HandleRetained=$true;CommandLine='synthetic pinned args'}
 $script:exited=@{PID=$importer.pid;CreationFileTimeUtc=$importer.creationFileTimeUtc;HandleRetained=$true;ExitCode=137}
 Write-HostedCapabilityAtomicJson (Join-Path $profilePath "root-import-attached-$RunId.json") $attached
 Write-HostedCapabilityAtomicJson (Join-Path $profilePath "root-import-exit-$RunId.json") $exited
 $script:barrierRequest=@{requestId='barrier';observed=@{deliberateFailedPrompt=$true;observationAcknowledged=$true;prompt=@{sessionHost=@{retained=$true;process=$presentRootPromptIdentity}};ownerReply=@{exitCode=1;retained=$true;process=$presentRootPromptIdentity;result=$prompt}}}
}
function Prepare-Barrier {
 if(!(Try-HostedPresentRootIntercept $request $identity) -or !$presentRootIntercept.eligible -or !$closed){throw 'Synthetic intercept control failed'}
 $ri=@{sid=$importer.sid;sessionId=7;thumbprint=$thumb}
 $null=Write-HostedCapabilityLedgerEvent $ledger @{phase='intent';requestId='prompt';operation='run-pinned-cua-currentuser-root-prompt';resourceIdentity=$ri}
 $null=Write-HostedCapabilityLedgerEvent $ledger @{phase='observation';requestId='prompt';operation='run-pinned-cua-currentuser-root-prompt';resourceIdentity=$ri;result='failed';observed=@{errorType='synthetic acknowledged mutation failure'}}
}
try {
 New-Context;Assert-HostedPresentRootInterceptEligibility $request $identity
 foreach($fault in @('none','role','operation','phase','duplicate','pending','preabsence','import-attempt','exact-match','subject','store','sid','session','script-hash','parent-ended','importer-ended','prior-exit','prior-wait','prior-exited','prior-retained','prior-image','prior-timeout','prior-terminated','certutil-image','certutil-pid','profile-volume','profile-kind','ledger-pair','prior-wait-string','exact-match-string','preabsence-string')){
  New-Context
  switch($fault){
   none {$script:TestFault='none'} role {$identity.role='root-remove'} operation {$request.operation='other'} phase {$request.phase='observation'} duplicate {$script:presentRootIntercept=@{eligible=$true}} pending {$script:helperPending=@{requestId='pending'}}
   preabsence {$request.precondition.preabsenceSequence++} import-attempt {$request.precondition.importAttempted=$false} exact-match {$request.precondition.exactMatch=$false} subject {$request.resourceIdentity.subject='wrong'} store {$request.resourceIdentity.store='wrong'} sid {$identity.sid='wrong'} session {$identity.sessionId=8} script-hash {$identity.scriptSHA256='wrong'} parent-ended {$rootImporterParentHandle.Exited=$true} importer-ended {$rootImporterHandle.Exited=$true}
   prior-wait-string {$rootImportObservations[$thumb].observed.waited='true'} exact-match-string {$request.precondition.exactMatch='true'} preabsence-string {$request.precondition.preabsenceSequence=[string]$request.precondition.preabsenceSequence}
   prior-exit {$rootImportObservations[$thumb].observed.exitCode=7} prior-wait {$rootImportObservations[$thumb].observed.waited=$false} prior-exited {$rootImportObservations[$thumb].observed.processExited=$false} prior-retained {$rootImportObservations[$thumb].observed.identityCreationRetained=$false} prior-image {$rootImportObservations[$thumb].observed.imageMatchesExpected=$false} prior-timeout {$rootImportObservations[$thumb].observed.timedOut=$true} prior-terminated {$rootImportObservations[$thumb].observed.terminationRequested=$true} certutil-image {$rootImportObservations[$thumb].observed.process.executable='wrong'} certutil-pid {$rootImportObservations[$thumb].observed.process.pid=0} profile-volume {$script:volume='wrong'} profile-kind {$script:profileKind='mount-point'} ledger-pair {$rootImportAttempts[$thumb]=999}
  }
  Expect-Failure {Assert-HostedPresentRootInterceptEligibility $request $identity} "intercept-$fault"
  if(Try-HostedPresentRootIntercept $request $identity){throw "Refused intercept suppressed normal acknowledgement $fault"}
  if($rootImporterHandle.Exited -and $fault -cne 'importer-ended'){throw 'Refused intercept killed importer'}
 }
 foreach($fault in @('terminate','wait','wrong-exit')){
  New-Context
  switch($fault){terminate {$rootImporterHandle.TerminationFails=$true} wait {$rootImporterHandle.WaitFails=$true} wrong-exit {$rootImporterHandle.ExitCode=2}}
  $null=Try-HostedPresentRootIntercept $request $identity
  if($presentRootIntercept.eligible -or !$script:failure){throw 'Unproved importer stop became barrier eligible'}
 }
 New-Context;Prepare-Barrier
 $replay=Read-HostedCapabilityLedger $runRoot $RunId $expectedSha
 if(!$replay.valid -or $replay.pending.Count -or @($replay.events|Where-Object {$_.operation -ceq 'remove-exact-owned-currentuser-root-certificate'}).Count){throw 'Accepted intercept wrote deletion intent/pending mutation'}
 $proof=Assert-HostedPresentRootBarrier $barrierRequest
 if(!$proof.admission.allowed -or $healthCalls -ne 1){throw 'Independent owner health/admission not run'}
 foreach($fault in @('none','no-intercept','ineligible','unwaited','wrong-exit','duplicate','worker-pending','helper-pending','unacknowledged','wrong-failure','observer-pid','observer-creation','observer-handle','observer-exit','observer-missing','owner-pid','owner-creation','owner-retained','owner-result','cua-answer','cua-close','cua-status','cua-fault','cua-importchild','cua-removal','parent-lost','context-volume','context-kind','command','identity','owner-health-throw','owner-unhealthy','service-dead','service-identity','owner-ended','no-budget','insufficient-budget','j21','cua-answer-string','observer-pid-string','owner-retained-string','service-health-string')){
  New-Context;Prepare-Barrier
  switch($fault){
   none {$script:TestFault='none'} no-intercept {$script:presentRootIntercept=$null} ineligible {$presentRootIntercept.eligible=$false} unwaited {$presentRootIntercept.waited=$false} wrong-exit {$presentRootIntercept.exitCode=2} duplicate {$script:presentRootBarrier=@{accepted=$true}} worker-pending {$script:pending=@{operation='pending'}} helper-pending {$script:helperPending=@{operation='pending'}} unacknowledged {$barrierRequest.observed.observationAcknowledged=$false} wrong-failure {$barrierRequest.observed.deliberateFailedPrompt=$false}
   cua-answer-string {$prompt.answerIssued='true'} observer-pid-string {$attached.PID=[string]$attached.PID} owner-retained-string {$barrierRequest.observed.ownerReply.retained='true'} service-health-string {$health.result.healthy='true'}
   observer-pid {$attached.PID++} observer-creation {$exited.CreationFileTimeUtc++} observer-handle {$attached.HandleRetained=$false} observer-exit {$exited.ExitCode=0}
   owner-pid {$barrierRequest.observed.ownerReply.process=Clone $presentRootPromptIdentity;$barrierRequest.observed.ownerReply.process.pid++} owner-creation {$barrierRequest.observed.ownerReply.process=Clone $presentRootPromptIdentity;$barrierRequest.observed.ownerReply.process.creationFileTimeUtc++} owner-retained {$barrierRequest.observed.ownerReply.retained=$false} owner-result {$barrierRequest.observed.ownerReply.result=@{status='fake'}}
   cua-answer {$prompt.answerIssued=$false} cua-close {$prompt.promptClosed=$false} cua-status {$prompt.status='unknown'} cua-fault {$prompt.fault='generic error'} cua-importchild {$prompt.importChild=@{passed=$true}} cua-removal {$prompt.removalConsentObserved=$true}
   parent-lost {$rootImporterParentHandle.Exited=$true} context-volume {$script:volume='wrong'} context-kind {$script:profileKind='mount-point'} command {$script:commandWrong=$true} identity {$script:identityLost=$true} owner-health-throw {$script:healthThrows=$true} owner-unhealthy {$health.result.healthy=$false} service-dead {$health.result.promptServiceAlive=$false} service-identity {$health.result.promptServiceIdentity=Clone $presentRootPromptIdentity;$health.result.promptServiceIdentity.pid++} owner-ended {$ownerProcess.Exited=$true}
   no-budget {$script:deadlines=@{work=0;cleanup=0}} insufficient-budget {$deadlines.cleanup=[Diagnostics.Stopwatch]::GetTimestamp()+609L*$frequency} j21 {$deadlines.work=[Diagnostics.Stopwatch]::GetTimestamp()}
  }
  Write-HostedCapabilityAtomicJson (Join-Path $EvidenceDirectory 'current-user-root-prompt.json') $prompt
  Write-HostedCapabilityAtomicJson (Join-Path $profilePath "root-import-attached-$RunId.json") $attached
  Write-HostedCapabilityAtomicJson (Join-Path $profilePath "root-import-exit-$RunId.json") $exited
  if($fault -ceq 'observer-missing'){Remove-Item (Join-Path $profilePath "root-import-exit-$RunId.json")}
  Expect-Failure {Assert-HostedPresentRootBarrier $barrierRequest} "barrier-$fault"
  Process-HostedPresentRootBarrier $barrierRequest
  if($writer.Lines.Count -ne 1 -or (ConvertFrom-Json $writer.Lines[0]).status -cne 'refused' -or $job.Terminated){throw 'Refused barrier suppressed acknowledgement/cleanup or terminated Job'}
 }
 New-Context;Prepare-Barrier;Process-HostedPresentRootBarrier $barrierRequest
 if($writer.Lines.Count -or !$job.Terminated -or !$presentRootBarrier.workerWaited -or !$presentRootBarrier.workerJobEmpty -or $presentRootBarrier.workerExit -ne 137){throw 'Accepted barrier acknowledged/live worker could cleanup'}
 foreach($fault in @('job-throw','worker-wait','partial-job')){
  New-Context;Prepare-Barrier
  switch($fault){job-throw {$job.FailTermination=$true} worker-wait {$worker.WaitFails=$true} partial-job {$job|Add-Member ScriptMethod Terminate {$script:worker.Exited=$true;$this.ActiveProcesses=1} -Force}}
  Expect-Failure {Process-HostedPresentRootBarrier $barrierRequest} "worker-stop-$fault"
  if($writer.Lines.Count){throw 'Failed accepted worker stop got acknowledgement'}
 }
 # Pump regression executes the actual body when the handler closes its reader.
 New-Context;$script:helperServer=@{IsConnected=$true};$script:helperReadTask=[Threading.Tasks.Task]::FromResult('synthetic-request');$script:helperAcceptTask=$null;$script:helperReadDeadlineCounter=$null
 function Process-HostedCapabilityHelperRequest {param($Line)Close-HostedCapabilityHelperEndpoint -Reopen}
 Pump-HostedCapabilityHelper
 if($script:helperReadTask -or !$closed){throw 'Pump rearmed a null reader after partial termination/handoff'}
 # Real filesystem receipt retention with adapted native results/processes.
 # The exact Save function consumes the real ledger replay and copies bytes.
 foreach($fault in @('none','consent-late','consent-missing','consent-cutoff','empty','remove-false','readback-false','wrong-thumb','wrong-subject','wrong-session','exit-nonzero','exit-unwaited','ancestry','consent','write-failed','copy-failed')){
  New-Context;Prepare-Barrier;Process-HostedPresentRootBarrier $barrierRequest
  $script:recoveryJobName="Global\Ticket569-$RunId-recovery";$script:recoveryJob=@{ActiveProcesses=0};$script:expectedRecoveryWorker=@{pid=1001;creationFileTimeUtc=1002}
  $launcher=@{pid=1101;creationFileTimeUtc=1102;scriptSHA256=('d'*64);workerScriptSHA256=('e'*64)};$lp=@{ExitCode=0}
  $result=@{removedRootThumbprints=@($thumb);sid=$importer.sid;sessionId=7}
  $remove=@{schema='ticket569-currentuser-root-import-v1';runId=$RunId;sid=$importer.sid;sessionId=7;thumbprint=$thumb;subject=$subject;passed=$true;removedOwned=$true;removedObserved=$true;processId=1201;processCreationFileTimeUtc=1202}
  $ancestry=@{schema='ticket569-recovery-launcher-v1';runId=$RunId;sourceSHA=$expectedSha;launcher=@{pid=1101;scriptSHA256=('d'*64)};workerScriptSHA256=('e'*64);child=@{pid=1001;creationFileTimeUtc=1002;sid=$importer.sid;sessionId=7;job=$recoveryJobName};suspendedChildValidated=$true;gateReleased=$true}
  $consent=@{status='observed-and-answered';promptClosed=$true;observation=@{pid=1301;windowId=1302;affirmativeElementToken='synthetic-owned-remove'}}
  $removeIdentity=@{role='root-remove';pid=1201;creationFileTimeUtc=1202}
  $ri=@{thumbprint=$thumb};$null=Write-HostedCapabilityLedgerEvent $ledger @{phase='intent';requestId='real-remove-adapter';operation='recovery-remove-exact-owned-currentuser-root-certificate';resourceIdentity=$ri;processIdentity=$removeIdentity;precondition=@{preabsenceSequence=$presentRootIntercept.preabsenceSequence;importAttemptSequence=$presentRootIntercept.importSequence;exactSubjectMatch=$true;uniqueThumbprintMatch=$true}}
  $null=Write-HostedCapabilityLedgerEvent $ledger @{phase='observation';requestId='real-remove-adapter';operation='recovery-remove-exact-owned-currentuser-root-certificate';resourceIdentity=$ri;result='completed';observed=@{absent=$true};processIdentity=$removeIdentity}
  $exitObs=@{waitedHandle=$true;identityMatched=$true;exitCode=0}
  switch($fault){empty {$result.removedRootThumbprints=@()} remove-false {$remove.removedOwned=$false} readback-false {$remove.removedObserved=$false} wrong-thumb {$remove.thumbprint='D'*40} wrong-subject {$remove.subject='wrong'} wrong-session {$remove.sessionId=8} exit-nonzero {$exitObs.exitCode=7} exit-unwaited {$exitObs.waitedHandle=$false} ancestry {$ancestry.child.creationFileTimeUtc++} consent {$consent.promptClosed=$false}}
  $null=Write-HostedCapabilityLedgerEvent $ledger @{phase='process';operation='validated-helper-process-exit-observed';processIdentity=$removeIdentity;observed=$exitObs}
  Write-HostedCapabilityAtomicJson (Join-Path $profilePath ".ticket569-$RunId-root-remove-$($thumb.ToLowerInvariant()).json") $remove
  Write-HostedCapabilityAtomicJson (Join-Path $profilePath ".ticket569-$RunId-recovery-launcher.json") $ancestry
  Write-HostedCapabilityAtomicJson (Join-Path $profilePath ".ticket569-$RunId-recovery.json") $result
  $consentPath=Join-Path $EvidenceDirectory 'current-user-root-removal-consent.json'
  $lateWriter=$null;$lateWriteTask=$null
  if($fault -ceq 'consent-late'){
   $lateWriter=[PowerShell]::Create()
   $null=$lateWriter.AddScript('param($Path,$Json) Start-Sleep -Milliseconds 300; [IO.File]::WriteAllText($Path,$Json)').AddArgument($consentPath).AddArgument((ConvertTo-Json $consent -Depth 32))
   $lateWriteTask=$lateWriter.BeginInvoke()
  }elseif($fault -ceq 'consent-missing'){
   $script:exerciseRecoveryCutoff=[Diagnostics.Stopwatch]::GetTimestamp()+[long](0.3*$frequency)
  }elseif($fault -ceq 'consent-cutoff'){
   $script:exerciseRecoveryCutoff=[Diagnostics.Stopwatch]::GetTimestamp()-1
  }else{Write-HostedCapabilityAtomicJson $consentPath $consent}
  $script:writeFault=($fault -ceq 'write-failed');$script:copyFault=($fault -ceq 'copy-failed')
  function Write-HostedCapabilityAtomicJson {param($Path,$Value)if($script:writeFault -and $Path.EndsWith('present-root-recovery-evidence.json')){throw 'support evidence write adapter fault'};hosted-capability-owner\Write-HostedCapabilityAtomicJson -Path $Path -Value $Value}
  function Copy-Item {param($LiteralPath,$Destination,$ErrorAction)if($script:copyFault){throw 'support receipt copy adapter fault'};Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -ErrorAction Stop}
  $consentElapsed=[Diagnostics.Stopwatch]::StartNew()
  if($fault -in @('none','consent-late')){
   Save-HostedPresentRootRecoveryEvidence $result $launcher $lp $profilePath
   foreach($name in @('present-root-recovery-evidence.json','present-root-remove-receipt.json','present-root-launcher-receipt.json','present-root-recovery-receipt.json','present-root-import-attached-receipt.json','present-root-import-exit-receipt.json')){if(!(Test-Path (Join-Path $EvidenceDirectory $name))){throw 'Actual receipt bytes not retained before profile removal'}}
  }else{Expect-Failure {Save-HostedPresentRootRecoveryEvidence $result $launcher $lp $profilePath} "retention-$fault"}
  if($lateWriter){$null=$lateWriter.EndInvoke($lateWriteTask);if($lateWriter.HadErrors){throw 'Delayed receipt writer failed'};$lateWriter.Dispose();Write-Output "PRESENT_ROOT_LATE_CONSENT_REAL_FILE_ACCEPTED elapsedMilliseconds=$($consentElapsed.ElapsedMilliseconds);WATCHER_NATIVE_ADAPTED"}
  if($fault -in @('consent-missing','consent-cutoff')){
   if($script:presentRootRecoveryEvidence){throw 'Missing/cutoff consent retained support evidence'}
   if($consentElapsed.ElapsedMilliseconds -gt 2000){throw 'Missing/cutoff consent ignored its clipped deadline'}
   Write-Output "PRESENT_ROOT_CONSENT_REFUSED case=$fault elapsedMilliseconds=$($consentElapsed.ElapsedMilliseconds) supportEvidence=absent;REAL_FILESYSTEM_WATCHER_ADAPTED"
  }
  $script:writeFault=$false;$script:copyFault=$false
 }
 Write-Output 'PRESENT_ROOT_RECOVERY_RETENTION_EXTRACTED_PASSED;NATIVE_RESULTS_AND_CUA_ADAPTED_REAL_FILESYSTEM_AND_LEDGER'

 # Worker gating is the exact first outer-catch statement extracted from source.
 $t=$null;$e=$null;$workerAST=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-capability.ps1'),[ref]$t,[ref]$e)
 $outer=@($workerAST.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.CatchClauses.Count -eq 1 -and $n.CatchClauses[0].Body.Extent.Text.Contains('if (!$failureLatched)')},$true))
 if($outer.Count -ne 1){throw 'Worker outer catch not unique'}
 $barrierGate=[scriptblock]::Create($outer[0].CatchClauses[0].Body.Statements[0].Extent.Text)
 function Send-HostedPresentRootBarrier {param($Observed)$script:barrierCalls++;if(!$Observed.observationAcknowledged){throw 'Wrong first catch barrier'}}
 foreach($mode in @('none','present-root-recovery')){foreach($eligible in @($true,$false)){foreach($ack in @($true,$false)){
  $script:TestFault=$mode;$script:presentRootExerciseEligible=$eligible;$script:barrierCalls=0;$ex=[Exception]::new('acknowledged failure');if($ack){$ex.Data['Ticket569MutationObservationAcknowledged']=$true}
  try{throw $ex}catch{. $barrierGate;$script:normalCatchRan=$true}
  if($barrierCalls -ne [int]($mode -ceq 'present-root-recovery' -and $eligible -and $ack)){throw 'Worker barrier escaped exact failed-observation gate'}
 }}}
 # Cutoff source and actual recovery wrapper fault paths: unchanged normal run,
 # both exercise wait-loop expiry contexts reach recovery Job stop and cleanup.
 $sensitive=@($supervisorAST.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-HostedSensitiveSessionRecovery'},$true))[0].Extent.Text
 if(([regex]::Matches($sensitive,'Assert-HostedExerciseRecoveryCutoff')).Count -lt 3 -or !$sensitive.Contains('$deadline=if($TestFault')){throw 'Exercise cutoff not applied to discovery and worker waits'}
 function Assert-BeforeRecoveryDeadline {}
 function Get-CimInstance {param($ClassName,$Filter,$ErrorAction)if($ClassName -ceq 'Win32_UserProfile'){@{Loaded=$true;LocalPath=$script:authoritativeSessionFact.profilePath}}else{@{SessionId=7}}}
 function Test-Path {param($LiteralPath,$Path,$PathType)$p=if($LiteralPath){$LiteralPath}else{$Path};if($p -like 'Registry::*'){$true}else{Microsoft.PowerShell.Management\Test-Path -LiteralPath $p}}
 function Get-SupervisorProcessSID {$script:authoritativeSessionFact.sid}
 function Invoke-OwnedPostSessionCleanup {param($Fact,$Live,$SensitiveProven)$script:cleanupCalled=$true;@{profileRemoved=$true;userRemoved=$true}}
 foreach($phase in @('launcher-discovery','worker-wait')){
  New-Context;$script:exerciseRecoveryCutoff=[Diagnostics.Stopwatch]::GetTimestamp()-1
  $script:recoveryJob=[pscustomobject]@{ActiveProcesses=1;Terminated=$false};$recoveryJob|Add-Member ScriptMethod Terminate {param($Code)$this.Terminated=$true;$this.ActiveProcesses=0}
  $loops=@($supervisorAST.FindAll({param($n)$n -is [Management.Automation.Language.WhileStatementAst] -and ($n.Extent.Text.StartsWith('while([Diagnostics.Stopwatch]::GetTimestamp() -lt $deadline)') -or $n.Extent.Text.StartsWith('while(!$taskProcess.WaitForExit('))},$true))
  if($loops.Count -ne 2){throw 'Exact recovery wait-loop extraction failed'}
  $script:sensitiveLoop=[scriptblock]::Create($loops[$(if($phase -ceq 'launcher-discovery'){0}else{1})].Extent.Text)
  $script:deadline=[Diagnostics.Stopwatch]::GetTimestamp()+100L*$frequency
  $script:taskProcess=[pscustomobject]@{};$taskProcess|Add-Member ScriptMethod WaitForExit {param($Milliseconds)$false}
  function Invoke-HostedSensitiveSessionRecovery {. $script:sensitiveLoop;throw 'Expired exact recovery loop escaped'}
  $r=Invoke-HostedSessionRecovery
  if(!$script:cleanupCalled -or !$recoveryJob.Terminated -or $r.sensitiveContextProven){throw "Exercise cutoff did not reach existing failed recovery and owned cleanup $phase"}
  Write-Output "PRESENT_ROOT_RECOVERY_CUTOFF_ADAPTER phase=$phase cleanup=attempted;NATIVE_UNRUN"
 }
 $script:TestFault='none';Assert-HostedExerciseRecoveryCutoff
 & (Join-Path $PSScriptRoot 'hosted-present-root-wait-tests.ps1')
 Write-Output 'PRESENT_ROOT_INTERCEPT_BARRIER_CUTOFF_EXTRACTED_PASSED;PROCESS_PROFILE_CUA_ADAPTERS_NATIVE_PRESENT_UNRUN'
}finally{if($ledger){Close-HostedCapabilityLedger $ledger};$env:WINDIR=$originalWindir;Microsoft.PowerShell.Management\Remove-Item $temp -Recurse -Force}
