$ErrorActionPreference='Stop'
$t=$null;$e=$null
$modulePath=Join-Path $PSScriptRoot 'hosted-framework-diagnostics.psm1'
$moduleAst=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$t,[ref]$e)
foreach($f in $moduleAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text.Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))))}
$probeFunctions=@($moduleAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-FrameworkDiagnosticProbe'},$true))
if($probeFunctions.Count -ne 1 -or $probeFunctions[0].Extent.Text.Contains('-EncodedCommand') -or !$probeFunctions[0].Extent.Text.Contains("@('-NoProfile','-NonInteractive','-File',")){throw 'Probe -File source gate failed'}
$payloadPath=Join-Path $PSScriptRoot 'hosted-framework-resolver-probe.ps1'
$payload=[IO.File]::ReadAllText($payloadPath)
$payloadAst=[Management.Automation.Language.Parser]::ParseFile($payloadPath,[ref]$t,[ref]$e)
if($e.Count -or @($payloadAst.FindAll({param($n)$n -is [Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -ieq 'error'},$true)).Count){throw 'Payload retains automatic Error reference'}
# Only Windows identity is adapted; execute all actual resolver/output statements.
$adapted=$payload.Replace('[Security.Principal.WindowsIdentity]::GetCurrent().User.Value',"'S-1-5-21-1'")
$canary='resolver-launch-message-canary'
$adapters=@'
$ErrorActionPreference='Stop'
function Get-Command {param($Name,$ErrorAction) [pscustomobject]@{CommandType='Function';ModuleName='Microsoft.PowerShell.Utility';Module=[pscustomobject]@{Path='C:\Modules\Utility.psm1';Version=[version]'1.0.0.0'}}}
function Get-Module {param([switch]$ListAvailable,$Name,$ErrorAction) @()}
function Import-Module {param($Name,$Scope,$ErrorAction) if($Scope -cne 'Local'){throw 'Unexpected import scope'}}
function Get-Process {param($Id) [pscustomobject]@{SessionId=7}}
'@
$root=Join-Path ([IO.Path]::GetTempPath()) ('t569-resolver-launch-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $root
try{
 $adaptedPath=Join-Path $root 'resolver-adapted.ps1';[IO.File]::WriteAllText($adaptedPath,$adapted)
 foreach($mode in @('global','file')){
  $checks=[PowerShell]::Create()
  try{
   $null=$checks.AddScript($adapters).AddStatement()
   if($mode -ceq 'global'){$null=$checks.AddScript($adapted,$false)}
   else{$null=$checks.AddCommand($adaptedPath)}
   $lines=@($checks.Invoke());if($checks.HadErrors -or $lines.Count -ne 1){throw "Fresh $mode payload failed or did not produce exactly one receipt"}
   $path=Join-Path $root ($mode+'.json');[IO.File]::WriteAllText($path,[string]$lines[0])
   # Existing env observations remain actual. Supply only the synthetic SID via
   # the single platform adapter above; no fabricated resolver output.
   $receipt=Read-FrameworkDiagnosticReceipt $path 'probe'
   if($receipt.parseStatus -cne 'parsed' -or !$receipt.fields.resolver.commands.'Get-FileHash'.found -or $receipt.fields.resolver.imports.CimCmdlets.success -ne $true){throw "Fresh $mode payload receipt did not project"}
   $validReceiptJson=[string]$lines[0]
   Write-Output "FRAMEWORK_RESOLVER_FRESH_RUNSPACE mode=$mode receipt=parsed;WINDOWS_IDENTITY_AND_RESOLUTION_ADAPTED"
  }finally{$checks.Dispose()}
 }
 $realisticExe='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
 $realisticPath='D:\a\go-mapi\go-mapi\tests\installed-attachment\'+('long-directory-'*20)+'\hosted-framework-resolver-probe.ps1'
 $serialized=Get-FrameworkProbeCommandLine $realisticExe $realisticPath
 $expected='"'+$realisticExe+'" -NoProfile -NonInteractive -File "'+$realisticPath+'"'
 if($serialized -cne $expected -or $serialized.Length -ge 1024){throw 'Actual realistic argument serialization does not fit credential backend'}
 Write-Output "FRAMEWORK_RESOLVER_CREDENTIAL_COMMAND_BOUND realisticLength=$($serialized.Length) maximumExclusive=1024"
 # Real failure branch still observes first snapshot on both streams. Launch
 # adapter returns an actual emitted/projected receipt from the fresh runspace.
 $fixture=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-capability-framework-tests.ps1'),[ref]$t,[ref]$e)
 $condition='!$launcher.WaitForExit(10000) -or $launcher.ExitCode -ne 0 -or $job.ActiveProcesses -ne 0'
 $gates=@($fixture.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq $condition},$true))
 if($gates.Count -ne 1){throw 'Original primary gate changed'}
 $gate=[scriptblock]::Create($gates[0].Extent.Text)
 $primary='Actual Framework launcher/worker success did not retain empty-job exit'
 $profile=$root;$run='a'*32;$compilerDirectory=@{path=$root};$launcherStderr=Join-Path $root 'launcher.stderr';[IO.File]::WriteAllText($launcherStderr,'')
 $freq=[Diagnostics.Stopwatch]::Frequency;$start=[Diagnostics.Stopwatch]::GetTimestamp();$frameworkAcceptedConnections=0;$frameworkFactNames=@()
 $launcher=[pscustomobject]@{HasExited=$true;ExitCode=2};$launcher|Add-Member ScriptMethod WaitForExit {param($Ms)$true}
 $job=@{ActiveProcesses=0};$failure=[pscustomobject]@{};$failure|Add-Member ScriptMethod Wait {param($Ms)$true}
 $secure=ConvertTo-SecureString $canary -AsPlainText -Force;$credential=[Management.Automation.PSCredential]::new('synthetic-fixture',$secure)
 $global:t569ResolverLaunchState=@{payloadPath=$payloadPath;receiptJson=$validReceiptJson;calls=0;wrapperCalls=0;lines=$null;stderrWriter=$null;beforeLaunch=$false}
 function Invoke-FrameworkCompilerLaunch {param($Directory,$Launch)$global:t569ResolverLaunchState.wrapperCalls++; & $Launch @{Environment=@{TEMP=$Directory.path;TMP=$Directory.path}}}
 function global:Start-Process {
  param($FilePath,$Credential,[switch]$LoadUserProfile,[switch]$PassThru,$ArgumentList,$RedirectStandardOutput,$RedirectStandardError,$Environment)
  $state=$global:t569ResolverLaunchState;$state.calls++
  if($state.lines.Count -ne 1 -or $state.stderrWriter.ToString().TrimEnd() -cne $state.lines[0]){throw 'Probe began before identical stdout/stderr snapshot'}
  $state.beforeLaunch=$true
  if(!$LoadUserProfile -or !$PassThru -or $null -eq $Credential -or $Environment.TEMP -cne $Environment.TMP -or ($ArgumentList -join ' ') -cne ('-NoProfile -NonInteractive -File "'+$state.payloadPath+'"')){throw 'Fixed-File argv/wrapper/credential/profile changed'}
  [IO.File]::WriteAllText($RedirectStandardOutput,$state.receiptJson);[IO.File]::WriteAllText($RedirectStandardError,'')
  $p=[pscustomobject]@{HasExited=$true;ExitCode=0;Disposed=$false};$p|Add-Member ScriptMethod WaitForExit {param($Ms)$true};$p|Add-Member ScriptMethod Dispose {$this.Disposed=$true};$state.process=$p;$p
 }
 foreach($case in @('file','oversized')){
  $exe=if($case -ceq 'file'){$realisticExe}else{'C:\'+('x'*1000)+'\powershell.exe'}
  $state=$global:t569ResolverLaunchState;$state.calls=0;$state.wrapperCalls=0;$state.beforeLaunch=$false;$state.process=$null
  $state.lines=[Collections.Generic.List[string]]::new();$state.stderrWriter=[IO.StringWriter]::new();$originalStderr=[Console]::Error;$caught=$null
  try{[Console]::SetError($state.stderrWriter);try{. $gate|ForEach-Object {$state.lines.Add([string]$_)}}catch{$caught=$_.Exception.Message}}
  finally{[Console]::SetError($originalStderr);$state.stderrWriter.Dispose()}
  if($caught -cne $primary -or $state.lines.Count -ne 2 -or $state.stderrWriter.ToString().TrimEnd() -cne $state.lines[0]){throw 'Fixed-File guard changed primary or snapshot'}
  $probe=ConvertFrom-Json $state.lines[1].Substring('FRAMEWORK_LAUNCHER_ENVIRONMENT_PROBE '.Length)
  if($case -ceq 'file'){
   if(!$state.beforeLaunch -or $state.calls -ne 1 -or $state.wrapperCalls -ne 1 -or !$state.process.Disposed -or $probe.output.parseStatus -cne 'parsed'){throw 'Fixed-File launch did not preserve ordering/projection/disposal'}
  }elseif($state.calls -or $state.wrapperCalls -or $probe.launched -or $probe.commandLineLength -lt 1024 -or $probe.errors.launchOrWait.exceptionChain[-1].type -cne 'System.ArgumentOutOfRangeException' -or $state.lines[1].Contains('x'*100) -or $state.lines[1].Contains($canary)){throw 'Oversized guard launched or leaked payload/primary'}
  Write-Output "FRAMEWORK_RESOLVER_ACTUAL_GATE case=$case primary=unchanged snapshot=preserved length=$($probe.commandLineLength) launchCalls=$($state.calls);CREDENTIAL_BACKEND_UNRUN"
 }
 Write-Output 'FRAMEWORK_RESOLVER_FILE_GLOBAL_LENGTH_GUARDS_PASSED;WINDOWS_CREDENTIAL_LAUNCH_UNRUN'
}finally{
 if($secure){$secure.Dispose()};Remove-Item Function:\global:Start-Process -ErrorAction SilentlyContinue;Remove-Variable t569ResolverLaunchState -Scope Global -ErrorAction SilentlyContinue
 Microsoft.PowerShell.Management\Remove-Item -LiteralPath $root -Recurse -Force
}
