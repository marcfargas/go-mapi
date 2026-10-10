$ErrorActionPreference='Stop'
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-framework-diagnostics.psm1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Diagnostic module parse failed'}
# Create() loses the module's source-root binding; retain that real fixture
# directory for reviewed source-line bounds in the extracted parser.
foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text.Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))))}
$t=$null;$e=$null
$fixture=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-capability-framework-tests.ps1'),[ref]$t,[ref]$e)
$recovery=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-capability-recovery.ps1'),[ref]$t,[ref]$e)
$prefixes=@($recovery.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.StartsWith('TICKET569_RECOVERY_LAUNCHER_FAILED')},$true))
if($prefixes.Count -ne 1){throw 'Actual recovery launcher stderr format not unique'}
$launcherFailurePrefix=$prefixes[0].Value
$condition='!$launcher.WaitForExit(10000) -or $launcher.ExitCode -ne 0 -or $job.ActiveProcesses -ne 0'
$gates=@($fixture.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq $condition},$true))
if($gates.Count -ne 1){throw 'Original compound launcher condition changed'}
$gate=[scriptblock]::Create($gates[0].Extent.Text)
$primary='Actual Framework launcher/worker success did not retain empty-job exit'
$canary='fixture-password-secret-canary-not-for-logs'
$secure=ConvertTo-SecureString $canary -AsPlainText -Force
$credential=[Management.Automation.PSCredential]::new('synthetic-fixture-account',$secure)
$root=Join-Path ([IO.Path]::GetTempPath()) ('t569-framework-diag-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $root
$run='a'*32;$freq=[Diagnostics.Stopwatch]::Frequency;$start=[Diagnostics.Stopwatch]::GetTimestamp();$exe='qualified-process-adapter'
$frameworkAcceptedConnections=2;$frameworkFactNames=@('recovery-run-credential-state','session-host-health',$canary)
$global:t569FrameworkDiagnosticTestState=@{canary=$canary;compilerPath=$null;fault='none';process=$null;stderrPrefix=$launcherFailurePrefix;emittedLines=[Collections.Generic.List[string]]::new();firstSnapshotSeen=$false;payloadPath=(Join-Path $PSScriptRoot 'hosted-framework-resolver-probe.ps1')}
function Invoke-FrameworkCompilerLaunch {param($Directory,$Launch,$ChildUserProfile)$script:wrapperCalls++; & $Launch @{Environment=@{TEMP=$Directory.path;TMP=$Directory.path;USERPROFILE=$ChildUserProfile}}}
function global:Start-Process {
 param($FilePath,$Credential,[switch]$LoadUserProfile,[switch]$PassThru,$ArgumentList,$RedirectStandardOutput,$RedirectStandardError,$Environment)
 if(!$global:t569FrameworkDiagnosticTestState.firstSnapshotSeen -or $global:t569FrameworkDiagnosticTestState.emittedLines.Count -ne 1){throw 'Synchronous probe began before the first diagnostic snapshot was observed'}
 if($global:t569FrameworkDiagnosticTestState.fault -cne 'stderr'){
  $stderrLines=@($global:t569FrameworkDiagnosticTestState.stderrWriter.ToString() -split '\r?\n' | Where-Object {$_ -ne ''})
  if($stderrLines.Count -ne 1 -or $stderrLines[0] -cne $global:t569FrameworkDiagnosticTestState.emittedLines[0] -or $stderrLines[0].Contains($global:t569FrameworkDiagnosticTestState.canary)){throw 'Synchronous probe began before the identical safe stderr snapshot was observed'}
  $global:t569FrameworkDiagnosticTestState.stderrBeforeProbe=$true
 }
 if(!$LoadUserProfile -or !$PassThru -or $Environment.TEMP -cne $global:t569FrameworkDiagnosticTestState.compilerPath -or $Environment.USERPROFILE -cne $global:t569FrameworkDiagnosticTestState.compilerPath -or $Environment.Count -ne 3){throw 'Probe did not use the same credential/environment launch wrapper'}
 if($ArgumentList.Count -ne 4 -or ($ArgumentList[0..2] -join ',') -cne '-NoProfile,-NonInteractive,-File' -or $ArgumentList[-1] -cne ('"'+$global:t569FrameworkDiagnosticTestState.payloadPath+'"')){throw 'Probe did not launch the exact fixed payload file'}
 $payload=[IO.File]::ReadAllText($global:t569FrameworkDiagnosticTestState.payloadPath)
 if($payload.Contains($global:t569FrameworkDiagnosticTestState.canary) -or $payload.Contains('Credential') -or !$payload.Contains("GetFolderPath('UserProfile')")){throw 'Fixed probe payload contains a credential or omitted environment observation'}
 if($global:t569FrameworkDiagnosticTestState.fault -ceq 'launch'){throw [InvalidOperationException]::new($global:t569FrameworkDiagnosticTestState.canary)}
 $resolver=@{runtime=@{edition='Desktop';version='5.1.0.0';pshome='C:\Windows\System32\WindowsPowerShell\v1.0'};modulePath=@{entries=@('C:\Modules');truncated=$false};commands=@{};discovery=@{};imports=@{}}
 $command=@{found=$false;commandType=$null;moduleName=$null;modulePath=$null;moduleVersion=$null;error=@{type='System.Management.Automation.CommandNotFoundException';hresult=-2146233087}}
 foreach($name in @('Get-FileHash','Get-CimInstance','Invoke-CimMethod','ConvertTo-Json','Get-Content','Test-Path','Join-Path','Get-Process')){$resolver.commands[$name]=$command}
 foreach($name in @('Microsoft.PowerShell.Utility','CimCmdlets')){$resolver.discovery[$name]=@{results=@();truncated=$false;error=$null};$resolver.imports[$name]=@{path='C:\inbox\'+$name+'.psd1';success=$false;error=@{type='System.InvalidOperationException';hresult=-2146233079};commands=@{'Get-FileHash'=$command;'Get-CimInstance'=$command}}}
 [IO.File]::WriteAllText($RedirectStandardOutput,(ConvertTo-Json @{USERPROFILE='C:\Users\target';folderUserProfile='C:\Users\target';TEMP='C:\ProgramData\private';TMP='C:\ProgramData\private';sid='S-1-5-21-1';sessionId=7;resolver=$resolver} -Depth 16))
 $probeRaw=[IO.File]::ReadAllText($RedirectStandardOutput)
 if($probeRaw.Contains($global:t569FrameworkDiagnosticTestState.canary) -or $probeRaw.Contains('PSCredential') -or $probeRaw.Contains('SecureString')){throw 'Probe output serialized secret/credential object'}
 [IO.File]::WriteAllText($RedirectStandardError,$global:t569FrameworkDiagnosticTestState.stderrPrefix+"System.InvalidOperationException`n"+$global:t569FrameworkDiagnosticTestState.canary)
 $o=[pscustomobject]@{HasExited=($global:t569FrameworkDiagnosticTestState.fault -notin @('timeout','kill-wait'));ExitCode=0;Killed=$false;Disposed=$false;Waits=[Collections.Generic.List[int]]::new()}
 $o|Add-Member ScriptMethod WaitForExit {param($Ms)$this.Waits.Add($Ms);$this.HasExited}
 $o|Add-Member ScriptMethod Kill {$this.Killed=$true;if($global:t569FrameworkDiagnosticTestState.fault -cne 'kill-wait'){$this.HasExited=$true}}
 $o|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
 $global:t569FrameworkDiagnosticTestState.process=$o;$o
}
function Get-Content {param($LiteralPath,[switch]$Raw,$ErrorAction)if($script:deniedPath -ceq $LiteralPath){throw [UnauthorizedAccessException]::new($canary)};Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw -ErrorAction Stop}
function New-Context($Exit,$Count,$LauncherReceipt='valid',$WorkerReceipt='valid',$ProbeFault='none'){
 $script:profile=Join-Path $root ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $profile
 $script:compilerDirectory=@{path=$profile};$script:launcherStderr=Join-Path $profile 'credential-launcher.stderr'
 [IO.File]::WriteAllText($launcherStderr,$launcherFailurePrefix+"System.InvalidOperationException`n$canary`n"+('z'*3000))
 $script:launcher=[pscustomobject]@{HasExited=$true;ExitCode=$Exit};$launcher|Add-Member ScriptMethod WaitForExit {param($Ms)$true}
 $script:job=@{ActiveProcesses=$Count};$script:failure=[pscustomobject]@{};$failure|Add-Member ScriptMethod Wait {param($Ms)if($Ms -ne 0){throw 'Failure event probe waited'};$true}
 $script:wrapperCalls=0;$script:deniedPath=$null
 $global:t569FrameworkDiagnosticTestState.compilerPath=$profile;$global:t569FrameworkDiagnosticTestState.fault=$ProbeFault;$global:t569FrameworkDiagnosticTestState.process=$null
 $global:t569FrameworkDiagnosticTestState.emittedLines.Clear();$global:t569FrameworkDiagnosticTestState.firstSnapshotSeen=$false
 $global:t569FrameworkDiagnosticTestState.stderrBeforeProbe=$false
 foreach($pair in @(@('launcher',$LauncherReceipt),@('worker',$WorkerReceipt))){
  $path=Join-Path $profile $(if($pair[0] -ceq 'launcher'){".ticket569-$run-recovery-launcher.json"}else{".ticket569-$run-recovery.json"})
  if($pair[1] -ceq 'missing'){continue}
  $body=switch($pair[1]){
   empty {''} truncated {'{"failed":'}
   valid {if($pair[0] -ceq 'launcher'){ConvertTo-Json @{schema='ticket569-recovery-launcher-v1';child=@{pid=123};suspendedChildValidated=$true;password=$canary;credential=$credential} -Depth 8}else{ConvertTo-Json @{failed=$true;errorType='InvalidOperationException';rootStatus='unverified';credentialFinalCredReadError=1168;password=$canary;credential=$credential} -Depth 8}}
  }
  [IO.File]::WriteAllText($path,$body)
 }
}
function Invoke-FailedGate {
 $lines=[Collections.Generic.List[string]]::new();$caught=$null
 $stderrWriter=[IO.StringWriter]::new();$originalStderr=[Console]::Error
 $global:t569FrameworkDiagnosticTestState.stderrWriter=$stderrWriter
 if($global:t569FrameworkDiagnosticTestState.fault -ceq 'stderr'){$stderrWriter.Dispose()}
 try{
  [Console]::SetError($stderrWriter)
  try{. $gate|ForEach-Object {$lines.Add([string]$_);$global:t569FrameworkDiagnosticTestState.emittedLines.Add([string]$_);if($lines.Count -eq 1 -and $lines[0].StartsWith('FRAMEWORK_LAUNCHER_FAILURE_DIAGNOSTIC ')){$global:t569FrameworkDiagnosticTestState.firstSnapshotSeen=$true}}}catch{$caught=$_.Exception.Message}
 }finally{[Console]::SetError($originalStderr);$stderrWriter.Dispose()}
 if($caught -cne $primary -or $lines.Count -ne 2 -or !$lines[0].StartsWith('FRAMEWORK_LAUNCHER_FAILURE_DIAGNOSTIC ') -or !$lines[1].StartsWith('FRAMEWORK_LAUNCHER_ENVIRONMENT_PROBE ')){throw 'Diagnostic replaced primary error or omitted/duplicated/reordered output'}
 if($global:t569FrameworkDiagnosticTestState.fault -cne 'stderr'){
  $stderrLines=@($stderrWriter.ToString() -split '\r?\n' | Where-Object {$_ -ne ''})
  if(!$global:t569FrameworkDiagnosticTestState.stderrBeforeProbe -or $stderrLines.Count -ne 1 -or $stderrLines[0] -cne $lines[0]){throw 'Stderr snapshot missing, different, duplicated, or late'}
  if($stderrLines[0].Contains($canary) -or $stderrLines[0].Contains('PSCredential') -or $stderrLines[0].Contains('SecureString')){throw 'Stderr snapshot serialized secret/credential object'}
 }
 foreach($line in $lines){if($line.Contains($canary) -or $line.Contains('PSCredential') -or $line.Contains('SecureString')){throw 'Snapshot/probe serialized secret/credential object'}}
 $first=ConvertFrom-Json ($lines[0].Substring('FRAMEWORK_LAUNCHER_FAILURE_DIAGNOSTIC '.Length)) -AsHashtable
 if($first.ContainsKey('environmentProbe')){throw 'First diagnostic snapshot still includes the synchronous probe'}
 # Combine only in the test return value for existing fault assertions; the
 # actual two emitted JSON objects remain separate and ordered.
 $first.environmentProbe=ConvertFrom-Json ($lines[1].Substring('FRAMEWORK_LAUNCHER_ENVIRONMENT_PROBE '.Length)) -AsHashtable
 $first
}
try{
 New-Context 0 0
 $successStderr=[IO.StringWriter]::new();$originalStderr=[Console]::Error
 try{[Console]::SetError($successStderr);$success=@(. $gate)}finally{[Console]::SetError($originalStderr);$successStderr.Dispose()}
 if($success.Count -or $successStderr.ToString().Length -or $wrapperCalls -or $global:t569FrameworkDiagnosticTestState.process){throw 'Success path created diagnostic/probe'}
 Write-Output 'FRAMEWORK_DIAG_SUCCESS_NO_SNAPSHOT_NO_PROBE'
 foreach($suffix in @('System.InvalidOperationException','prefix-only','wrong-prefix','non-type','canary-message','bare-type')){
  $line=switch($suffix){
   prefix-only {$launcherFailurePrefix.TrimEnd()}
   wrong-prefix {'WRONG_LAUNCHER_PREFIX System.InvalidOperationException'}
   non-type {$launcherFailurePrefix+'not an exception type'}
   canary-message {$launcherFailurePrefix+'System.InvalidOperationException '+$canary}
   bare-type {'System.InvalidOperationException'}
   default {$launcherFailurePrefix+$suffix}
  }
  $stderr=Join-Path $root ('stderr-'+$suffix+'.txt');[IO.File]::WriteAllText($stderr,$line+"`n"+$canary)
  $readback=Read-FrameworkDiagnosticStderr $stderr
  $expected=if($suffix -ceq 'System.InvalidOperationException'){1}else{0}
  if($readback.exceptionTypes.Count -ne $expected -or ($expected -and $readback.exceptionTypes[0] -cne 'System.InvalidOperationException') -or (ConvertTo-Json $readback -Depth 12).Contains($canary)){throw 'Production-prefixed stderr parser leaked a canary or accepted an invalid line'}
  Write-Output "FRAMEWORK_DIAG_STDERR_FORMAT case=$suffix acceptedTypes=$expected;PRODUCTION_PREFIX_AST_DERIVED"
 }
 foreach($pair in @(@(2,0),@(0,1),@(2,1))){
  New-Context $pair[0] $pair[1];$snapshot=Invoke-FailedGate
  if($snapshot.exitCode -ne $pair[0] -or $snapshot.activeProcesses -ne $pair[1] -or !$snapshot.hasExited -or !$snapshot.waitForExit10000 -or !$snapshot.failureEventSet -or $snapshot.acceptedConnections -ne 2 -or $snapshot.factNames.Count -ne 2 -or $wrapperCalls -ne 1){throw 'Failure snapshot lost actual compound assertion inputs'}
  if(!$snapshot.launcherReceipt.fields.schemaMatches -or $snapshot.launcherReceipt.fields.childPID -ne 123 -or !$snapshot.launcherReceipt.fields.suspendedChildValidated -or !$snapshot.workerReceipt.fields.failed -or $snapshot.workerReceipt.fields.credentialFinalCredReadError -ne 1168){throw 'Actual launcher/worker receipt schema projection differs'}
  if($snapshot.environmentProbe.output.fields.USERPROFILE -cne 'C:\Users\target' -or !$global:t569FrameworkDiagnosticTestState.process.Disposed){throw ('Probe environment receipt or process disposal missing '+(ConvertTo-Json @{probe=$snapshot.environmentProbe;disposed=$global:t569FrameworkDiagnosticTestState.process.Disposed} -Depth 16 -Compress))}
  Write-Output "FRAMEWORK_DIAG_COMPOUND_FAILURE exit=$($pair[0]) job=$($pair[1]) primary=unchanged"
 }
 foreach($kind in @('launcher','worker')){foreach($shape in @('missing','empty','truncated','valid')){
  if($kind -ceq 'launcher'){New-Context 2 0 $shape 'valid'}else{New-Context 2 0 'valid' $shape}
  $snapshot=Invoke-FailedGate;$receipt=$snapshot[$kind+'Receipt'];$expected=if($shape -ceq 'truncated'){'invalid'}elseif($shape -ceq 'valid'){'parsed'}else{$shape}
  if($receipt.parseStatus -cne $expected -or ($shape -cne 'missing' -and $null -eq $receipt.bytes)){throw ('Receipt existence/bytes/parse diagnostic lost shape '+$kind+' '+$shape+' '+(ConvertTo-Json $receipt -Depth 12 -Compress))}
  Write-Output "FRAMEWORK_DIAG_RECEIPT kind=$kind shape=$shape primary=unchanged"
 }}
 New-Context 2 0;$script:deniedPath=Join-Path $profile ".ticket569-$run-recovery-launcher.json";$snapshot=Invoke-FailedGate
 if(!$snapshot.launcherReceipt.errors.read -or $snapshot.workerReceipt.parseStatus -cne 'parsed'){throw 'Denied receipt read masked primary or stopped independent reads'}
 foreach($fault in @('timeout','kill-wait','launch')){
  New-Context 2 0 'valid' 'valid' $fault;$snapshot=Invoke-FailedGate;$p=$snapshot.environmentProbe
  if($fault -ceq 'launch'){if(!$p.errors.launchOrWait -or $p.launched){throw 'Probe launch failure missing'}}
  else{
   $probeProcess=$global:t569FrameworkDiagnosticTestState.process
   if(!$p.timedOut -or !$p.killed -or !$probeProcess.Killed -or !$probeProcess.Disposed -or $probeProcess.Waits.Count -ne 2 -or $probeProcess.Waits[0] -gt 10000 -or $probeProcess.Waits[1] -gt 5000){throw 'Probe timeout did not retain bounded kill-and-wait'}
   if($p.killWaited -ne ($fault -ceq 'timeout')){throw 'Probe kill-wait outcome overwritten'}
  }
  if(!$global:t569FrameworkDiagnosticTestState.firstSnapshotSeen){throw 'Probe fault lost the preceding snapshot'}
  Write-Output "FRAMEWORK_DIAG_PROBE fault=$fault firstSnapshotBeforeProbe=True identicalSafeStderrBeforeProbe=True primary=unchanged;PROCESS_ADAPTER_NATIVE_UNRUN"
 }
 New-Context 2 0 'valid' 'valid' 'stderr';$snapshot=Invoke-FailedGate
 if($wrapperCalls -ne 1 -or !$global:t569FrameworkDiagnosticTestState.process.Disposed){throw 'Failed stderr write prevented the probe or disposal'}
 Write-Output 'FRAMEWORK_DIAG_STDERR_WRITE_FAILURE primary=unchanged stdout=preserved probe=completed;REAL_DISPOSED_TEXTWRITER'
 # Contract comes from all literal command ASTs in the launcher and its two
 # actual imports; no runtime/module inventory or argument values are logged.
 $sourceNames=@('hosted-capability-recovery.ps1','hosted-capability-native.psm1','hosted-capability-clock.psm1')
 $derived=@();$sourceMaximum=0
 foreach($name in $sourceNames){
  $path=Join-Path $PSScriptRoot $name;$t=$null;$e=$null
  $sourceAst=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
  if($e.Count){throw 'Launcher/import contract source parse failed'}
  $derived+=@($sourceAst.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()}|Where-Object {$null -ne $_})
  $sourceMaximum=[Math]::Max($sourceMaximum,[IO.File]::ReadAllLines($path).Length)
 }
 $derived=@($derived|Sort-Object -Unique)
 $outer=@($recovery.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
 if($outer.Count -ne 1 -or $outer[0].CatchClauses[0].Body.Statements[0].Extent.Text -cne '$record=$_'){throw 'Launcher primary record is not captured first'}
 $launcherCatch=$outer[0].CatchClauses[0]
 $allowAssignments=@($launcherCatch.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$diagnosticCommands'},$true))
 if($allowAssignments.Count -ne 1){throw 'Launcher diagnostic literal allowlist missing or ambiguous'}
 $literal=@($allowAssignments[0].Right.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true)|ForEach-Object {$_.Value})
 if(($literal -join "`n") -cne ($derived -join "`n") -or (@(Get-FrameworkLauncherCommandAllowlist) -join "`n") -cne ($derived -join "`n")){throw 'Launcher/parser literal command allowlist drifted from actual source ASTs'}
 $oldMarker="[Console]::Error.WriteLine(('TICKET569_RECOVERY_LAUNCHER_FAILED '+`$_.Exception.GetType().FullName))"
 if(!$launcherCatch.Extent.Text.Contains($oldMarker) -or $launcherCatch.Body.Statements[-1].Extent.Text -cne 'exit 2'){throw 'Original launcher type marker or exit2 contract changed'}
 Write-Output "LAUNCHER_DETAIL_LITERAL_COMMANDS_AST_MATCH count=$($derived.Count) sourceMaximum=$sourceMaximum;LINE_SOURCE_AMBIGUOUS_LAUNCHER_NATIVE_CLOCK"
 foreach($case in @('allowed','unknown','message-canary','command-canary','event-fault','detail-fault','utility-import-fault')){
  $body=switch($case){
   utility-import-fault {$outer[0].Body.Statements[0].Extent.Text}
   unknown {"& 'T569-Unknown-Missing'"}
   command-canary {"& '$canary'"}
   message-canary {"throw [InvalidOperationException]::new('$canary')"}
   default {"& 'Get-HostedCapabilityWaitBudget'"}
  }
  $event=if($case -ceq 'event-fault'){"throw [InvalidOperationException]::new('$canary')"}else{''}
  $faultSetup=if($case -ceq 'utility-import-fault'){"function Import-Module {param(`$Name,`$ErrorAction) throw [InvalidOperationException]::new('$canary')}"}else{''}
  if($case -ceq 'detail-fault'){
   $faultSetup=@'
Add-Type -TypeDefinition 'public class T569DetailFailWriter : System.IO.TextWriter { private System.IO.TextWriter inner; public T569DetailFailWriter(System.IO.TextWriter value){inner=value;} public override System.Text.Encoding Encoding { get{return inner.Encoding;} } public override void WriteLine(string value){if(value.StartsWith("TICKET569_RECOVERY_LAUNCHER_FAILURE_DETAIL ")){throw new System.InvalidOperationException("fixture-password-secret-canary-not-for-logs");} inner.WriteLine(value);} }'
[Console]::SetError([T569DetailFailWriter]::new([Console]::Error))
'@
  }
  $driver=Join-Path $root ('launcher-catch-'+$case+'.ps1')
  $code="`$ErrorActionPreference='Stop'`n`$child=`$null;`$job=`$null;`$gate=`$null`nfunction Set-HostedCapabilityFailureEvent {param(`$Name) $event}`n$faultSetup`ntry { $body } "+$launcherCatch.Extent.Text+' finally '+$outer[0].Finally.Extent.Text
  [IO.File]::WriteAllText($driver,$code)
  $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Microsoft.PowerShell.Management\Get-Process -Id $PID).Path
  foreach($arg in @('-NoLogo','-NoProfile','-File',$driver)){$psi.ArgumentList.Add($arg)}
  $psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
  $p=[Diagnostics.Process]::Start($psi)
  try{
   $outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
   if(!$p.WaitForExit(15000)){$p.Kill();$null=$p.WaitForExit(5000);throw 'Extracted launcher catch test process timed out'}
   $stdout=$outTask.GetAwaiter().GetResult();$stderrText=$errTask.GetAwaiter().GetResult()
   $expectedType=if($case -in @('message-canary','utility-import-fault')){'System.InvalidOperationException'}else{'System.Management.Automation.CommandNotFoundException'}
   $actualLines=@($stderrText -split '\r?\n'|Where-Object {$_ -ne ''})
   if($p.ExitCode -ne 2 -or $stdout.Length -or $actualLines.Count -ne $(if($case -ceq 'detail-fault'){1}else{2}) -or $actualLines[0] -cne ($launcherFailurePrefix+$expectedType) -or $stderrText.Contains($canary)){throw "Extracted launcher catch changed primary marker/exit2 or leaked secret: $case"}
   $stderrPath=Join-Path $root ('launcher-catch-'+$case+'.stderr');[IO.File]::WriteAllText($stderrPath,$stderrText)
   $parsed=Read-FrameworkDiagnosticStderr $stderrPath
   if($parsed.exceptionTypes.Count -ne 1 -or $parsed.exceptionTypes[0] -cne $expectedType -or $parsed.failureDetails.Count -ne $(if($case -ceq 'detail-fault'){0}else{1})){throw "Extracted launcher detail failed strict readback: $case"}
   if($case -cne 'detail-fault'){
    $detail=$parsed.failureDetails[0]
    $expectedCommand=if($case -in @('message-canary','utility-import-fault')){$null}elseif($case -in @('unknown','command-canary')){'redacted'}else{'Get-HostedCapabilityWaitBudget'}
    if($detail.type -cne $expectedType -or $detail.command -cne $expectedCommand -or $detail.line -isnot [long] -and $detail.line -isnot [int] -or $detail.line -le 0 -or $detail.line -gt $sourceMaximum){throw "Extracted launcher detail projection differs: $case"}
   }
   Write-Output "LAUNCHER_DETAIL_ACTUAL_EXTRACTED_CATCH case=$case marker=unchanged exit=2;MISSING_COMMAND_REAL_WINDOWS_UNRUN"
   Write-Output $stderrText.TrimEnd()
  }finally{$p.Dispose()}
 }
 $detailPrefix='TICKET569_RECOVERY_LAUNCHER_FAILURE_DETAIL '
 $cnf='System.Management.Automation.CommandNotFoundException'
 foreach($case in @('allowed','redacted','non-cnf','null-line','module-line','extra','missing','duplicate','wrong-case','wrong-prefix','malformed','truncated','no-newline','beyond-2kb','boundary-truncated','message','command-canary','non-cnf-command','unknown-command','wrong-command-type','wrong-line-type','zero-line','negative-line','beyond-source','float-line','bad-type','long-type')){
  $value=[ordered]@{type=$cnf;line=1;command='Get-CimInstance'};$prefix=$detailPrefix;$tail="`n";$head=''
  switch($case){
   redacted {$value.command='redacted'}
   non-cnf {$value.type='System.InvalidOperationException';$value.command=$null}
   null-line {$value.line=$null}
   module-line {$value.line=$sourceMaximum}
   extra {$value.message=$canary}
   missing {$value.Remove('line')}
   wrong-case {$value=[ordered]@{Type=$cnf;line=1;command='Get-CimInstance'}}
   wrong-prefix {$prefix='WRONG_FAILURE_DETAIL '}
   no-newline {$tail=''}
   beyond-2kb {$head=('x'*2048)+"`n"}
   boundary-truncated {$head=('x'*1990)+"`n"}
   message {$value.command='Get-CimInstance '+$canary}
   command-canary {$value.command=$canary}
   non-cnf-command {$value.type='System.InvalidOperationException'}
   unknown-command {$value.command='T569-Unknown-Missing'}
   wrong-command-type {$value.command=1}
   wrong-line-type {$value.line='1'}
   zero-line {$value.line=0}
   negative-line {$value.line=-1}
   beyond-source {$value.line=$sourceMaximum+1}
   float-line {$value.line=1.5}
   bad-type {$value.type='not exception'}
   long-type {$value.type=('A'*257)+'Exception'}
  }
  $json=ConvertTo-Json -InputObject $value -Compress
  switch($case){
   duplicate {$json='{"type":"'+$cnf+'","line":1,"line":2,"command":"Get-CimInstance"}'}
   malformed {$json='{not-json}'}
   truncated {$json=$json.Substring(0,$json.Length-2)}
  }
  $path=Join-Path $root ('detail-parser-'+$case+'.stderr');[IO.File]::WriteAllText($path,$head+$prefix+$json+$tail)
  $readback=Read-FrameworkDiagnosticStderr $path
  $expected=if($case -in @('allowed','redacted','non-cnf','null-line','module-line')){1}else{0}
  if($readback.failureDetails.Count -ne $expected -or (ConvertTo-Json $readback -Depth 12).Contains($canary)){throw "Strict launcher detail parser accepted invalid or leaked data: $case"}
  Write-Output "LAUNCHER_DETAIL_STRICT_PARSER case=$case accepted=$expected"
 }
 $resolverChecks=[PowerShell]::Create()
 try{
  $null=$resolverChecks.AddScript('& $args[0]').AddArgument((Join-Path $PSScriptRoot 'hosted-framework-resolver-tests.ps1'))
  $resolverChecks.Invoke()|Write-Output
  if($resolverChecks.HadErrors){throw ($resolverChecks.Streams.Error|Out-String)}
 }finally{$resolverChecks.Dispose()}
 $launchChecks=[PowerShell]::Create()
 try{
  $null=$launchChecks.AddScript('& $args[0]').AddArgument((Join-Path $PSScriptRoot 'hosted-framework-resolver-launch-tests.ps1'))
  $launchChecks.Invoke()|Write-Output
  if($launchChecks.HadErrors){throw ($launchChecks.Streams.Error|Out-String)}
 }finally{$launchChecks.Dispose()}
 Write-Output 'FRAMEWORK_DIAGNOSTIC_EXTRACTED_FAULTS_PASSED;FILESYSTEM_REAL_PROCESSES_CREDENTIALS_ADAPTED_WINDOWS_UNRUN'
}finally{$secure.Dispose();Microsoft.PowerShell.Management\Remove-Item -LiteralPath $root -Recurse -Force;Remove-Item Function:\global:Start-Process -ErrorAction SilentlyContinue;Remove-Variable t569FrameworkDiagnosticTestState -Scope Global -ErrorAction SilentlyContinue}
