$ErrorActionPreference='Stop'
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-framework-diagnostics.psm1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Diagnostic module parse failed'}
foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
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
$global:t569FrameworkDiagnosticTestState=@{canary=$canary;compilerPath=$null;fault='none';process=$null;stderrPrefix=$launcherFailurePrefix;emittedLines=[Collections.Generic.List[string]]::new();firstSnapshotSeen=$false}
function Invoke-FrameworkCompilerLaunch {param($Directory,$Launch)$script:wrapperCalls++; & $Launch @{Environment=@{TEMP=$Directory.path;TMP=$Directory.path}}}
function global:Start-Process {
 param($FilePath,$Credential,[switch]$LoadUserProfile,[switch]$PassThru,$ArgumentList,$RedirectStandardOutput,$RedirectStandardError,$Environment)
 if(!$global:t569FrameworkDiagnosticTestState.firstSnapshotSeen -or $global:t569FrameworkDiagnosticTestState.emittedLines.Count -ne 1){throw 'Synchronous probe began before the first diagnostic snapshot was observed'}
 if($global:t569FrameworkDiagnosticTestState.fault -cne 'stderr'){
  $stderrLines=@($global:t569FrameworkDiagnosticTestState.stderrWriter.ToString() -split '\r?\n' | Where-Object {$_ -ne ''})
  if($stderrLines.Count -ne 1 -or $stderrLines[0] -cne $global:t569FrameworkDiagnosticTestState.emittedLines[0] -or $stderrLines[0].Contains($global:t569FrameworkDiagnosticTestState.canary)){throw 'Synchronous probe began before the identical safe stderr snapshot was observed'}
  $global:t569FrameworkDiagnosticTestState.stderrBeforeProbe=$true
 }
 if(!$LoadUserProfile -or !$PassThru -or $Environment.TEMP -cne $global:t569FrameworkDiagnosticTestState.compilerPath){throw 'Probe did not use the same credential/environment launch wrapper'}
 $decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
 if($decoded.Contains($global:t569FrameworkDiagnosticTestState.canary) -or $decoded.Contains('Credential') -or !$decoded.Contains("GetFolderPath('UserProfile')")){throw 'Probe encoded payload contains a credential or omitted environment observation'}
 if($global:t569FrameworkDiagnosticTestState.fault -ceq 'launch'){throw [InvalidOperationException]::new($global:t569FrameworkDiagnosticTestState.canary)}
 [IO.File]::WriteAllText($RedirectStandardOutput,(ConvertTo-Json @{USERPROFILE='C:\Users\target';folderUserProfile='C:\Users\target';TEMP='C:\ProgramData\private';TMP='C:\ProgramData\private';sid='S-1-5-21-1';sessionId=7} -Depth 8))
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
 Write-Output 'FRAMEWORK_DIAGNOSTIC_EXTRACTED_FAULTS_PASSED;FILESYSTEM_REAL_PROCESSES_CREDENTIALS_ADAPTED_WINDOWS_UNRUN'
}finally{$secure.Dispose();Microsoft.PowerShell.Management\Remove-Item -LiteralPath $root -Recurse -Force;Remove-Item Function:\global:Start-Process -ErrorAction SilentlyContinue;Remove-Variable t569FrameworkDiagnosticTestState -Scope Global -ErrorAction SilentlyContinue}
