$ErrorActionPreference='Stop'
function Get-FrameworkDiagnosticError($Exception){
 $chain=[Collections.Generic.List[object]]::new()
 for($e=$Exception;$e;$e=$e.InnerException){$chain.Add(@{type=$e.GetType().FullName;hresult=$e.HResult})}
 @{exceptionChain=@($chain)}
}
function Get-FrameworkSafeExceptionType($Value){
 if($Value -is [string] -and $Value -cmatch '^(?:[A-Za-z_][A-Za-z0-9_+`]*\.)*[A-Za-z_][A-Za-z0-9_+`]*Exception$'){return $Value}
 $null
}
function Read-FrameworkDiagnosticReceipt($Path,[string]$Kind){
 $r=@{exists=$null;bytes=$null;parseStatus='unread';fields=@{};errors=@{}}
 try{$r.exists=Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop}catch{$r.errors.exists=Get-FrameworkDiagnosticError $_.Exception;return $r}
 if(!$r.exists){$r.parseStatus='missing';return $r}
 try{$r.bytes=(Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length}catch{$r.errors.bytes=Get-FrameworkDiagnosticError $_.Exception}
 try{$raw=Get-Content -LiteralPath $Path -Raw -ErrorAction Stop}catch{$r.errors.read=Get-FrameworkDiagnosticError $_.Exception;return $r}
 if([string]::IsNullOrWhiteSpace($raw)){$r.parseStatus='empty';return $r}
 try{
  $v=ConvertFrom-Json -InputObject $raw -ErrorAction Stop
  if(!$v){throw [FormatException]::new('Diagnostic receipt is not an object')}
  $r.parseStatus='parsed'
  if($Kind -ceq 'launcher'){
   $r.fields.schemaMatches=($v.schema -ceq 'ticket569-recovery-launcher-v1')
   if($v.child.pid -is [int] -or $v.child.pid -is [long]){$r.fields.childPID=$v.child.pid}
   if($v.suspendedChildValidated -is [bool]){$r.fields.suspendedChildValidated=$v.suspendedChildValidated}
  }elseif($Kind -ceq 'worker'){
   if($v.failed -is [bool]){$r.fields.failed=$v.failed}
   $r.fields.errorType=Get-FrameworkSafeExceptionType $v.errorType
   if($v.rootStatus -cin @('verified','unverified','unknown')){$r.fields.rootStatus=$v.rootStatus}
   if($v.credentialFinalCredReadError -is [int] -or $v.credentialFinalCredReadError -is [long]){$r.fields.credentialFinalCredReadError=$v.credentialFinalCredReadError}
  }elseif($Kind -ceq 'probe'){
   foreach($key in @('USERPROFILE','folderUserProfile','TEMP','TMP')){if($v.$key -is [string]){$r.fields[$key]=$v.$key}}
   if($v.sid -is [string] -and $v.sid -match '^S-1-5-[0-9-]+$'){$r.fields.sid=$v.sid}
   if($v.sessionId -is [int] -or $v.sessionId -is [long]){$r.fields.sessionId=$v.sessionId}
  }
 }catch{$r.parseStatus='invalid';$r.errors.parse=Get-FrameworkDiagnosticError $_.Exception}
 $r
}
function Get-FrameworkLauncherCommandAllowlist {
 @('Add-Type','ConvertTo-Json','Export-ModuleMember','Get-CimInstance','Get-Content','Get-FileHash','Get-HostedCapabilityWaitBudget','Get-Process','Import-Module','Invoke-CimMethod','Join-Path','Open-HostedCapabilityGate','Open-HostedCapabilityJob','Set-HostedCapabilityFailureEvent','Set-StrictMode','Start-HostedCapabilityProcess','Test-HostedCapabilityCommandArguments','Test-HostedCapabilityProcessIdentity','Test-Path')
}
function Read-FrameworkDiagnosticStderr($Path){
 $r=@{exceptionTypes=@();failureDetails=@();errors=@{}}
 try{
  # Retain only exception type lines within the first 2KB; never arbitrary
  # output, exception messages, command lines or credential objects.
  $stream=[IO.File]::OpenRead($Path)
  try{$buffer=[byte[]]::new(2048);$count=$stream.Read($buffer,0,$buffer.Length)}finally{$stream.Dispose()}
  $text=[Text.Encoding]::UTF8.GetString($buffer,0,$count)
  $r.exceptionTypes=@($text -split '\r?\n'|ForEach-Object {if($_ -cmatch '^TICKET569_RECOVERY_LAUNCHER_FAILED (.+)$'){Get-FrameworkSafeExceptionType $Matches[1]}}|Where-Object {$null -ne $_})
  # InvocationInfo can name a line in the launcher or either imported module.
  # The three-key contract cannot distinguish files; use their maximum bound.
  $maximumLine=0
  foreach($source in @('hosted-capability-recovery.ps1','hosted-capability-native.psm1','hosted-capability-clock.psm1')){$maximumLine=[Math]::Max($maximumLine,[IO.File]::ReadAllLines((Join-Path $PSScriptRoot $source)).Length)}
  $allowed=Get-FrameworkLauncherCommandAllowlist
  $details=[Collections.Generic.List[object]]::new()
  # Only newline-terminated detail lines wholly inside the first 2KB qualify.
  foreach($match in [regex]::Matches($text,'(?m)^TICKET569_RECOVERY_LAUNCHER_FAILURE_DETAIL ([^\r\n]*)\r?\n')){
   $json=$match.Groups[1].Value
   # Restrict every value before JSON parsing; this also excludes messages,
   # nested data, escaped content and duplicate-key forms after the key check.
   if($json -cnotmatch '^\{\s*"(?:type|line|command)"\s*:\s*(?:null|-?[0-9]+|"[A-Za-z0-9_.+`-]*")\s*(?:,\s*"(?:type|line|command)"\s*:\s*(?:null|-?[0-9]+|"[A-Za-z0-9_.+`-]*")\s*){2}\}$'){continue}
   try{$v=ConvertFrom-Json -InputObject $json -ErrorAction Stop}catch{continue}
   $keys=@($v.PSObject.Properties.Name)
   if($keys.Count -ne 3 -or 'type' -cnotin $keys -or 'line' -cnotin $keys -or 'command' -cnotin $keys){continue}
   $type=Get-FrameworkSafeExceptionType $v.type
   if(!$type -or $type.Length -gt 256){continue}
   if($null -ne $v.line -and (($v.line -isnot [int] -and $v.line -isnot [long]) -or $v.line -le 0 -or $v.line -gt $maximumLine)){continue}
   if($type -ceq 'System.Management.Automation.CommandNotFoundException'){
    if($v.command -isnot [string] -or ($v.command -cnotin $allowed -and $v.command -cne 'redacted')){continue}
   }elseif($null -ne $v.command){continue}
   $details.Add(@{type=$type;line=$v.line;command=$v.command})
  }
  $r.failureDetails=@($details)
 }catch{$r.errors.read=Get-FrameworkDiagnosticError $_.Exception}
 $r
}
function Invoke-FrameworkDiagnosticProbe($Directory,$Executable,$Credential){
 $r=@{launched=$false;waited=$false;timedOut=$false;killed=$false;killWaited=$false;exited=$null;exitCode=$null;errors=@{};output=$null}
 $p=$null;$path=Join-Path $Directory.path 'launcher-environment-probe.stdout';$err=$path+'.stderr'
 $code="@{USERPROFILE=`$env:USERPROFILE;folderUserProfile=[Environment]::GetFolderPath('UserProfile');TEMP=`$env:TEMP;TMP=`$env:TMP;sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;sessionId=(Get-Process -Id `$PID).SessionId}|ConvertTo-Json -Compress"
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
 try{
  $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+15L*[Diagnostics.Stopwatch]::Frequency
  $p=Invoke-FrameworkCompilerLaunch $Directory ({param($frameworkChildEnvironment) Start-Process $Executable -Credential $Credential -LoadUserProfile -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -RedirectStandardOutput $path -RedirectStandardError $err @frameworkChildEnvironment}.GetNewClosure())
  $r.launched=$true
  # Reserve up to five seconds within the 15s deadline for kill-and-wait.
  $wait=[int][Math]::Max(0,[Math]::Min(10000,[Math]::Floor(($deadline-[Diagnostics.Stopwatch]::GetTimestamp())*1000.0/[Diagnostics.Stopwatch]::Frequency)-5000))
  $r.waited=$p.WaitForExit($wait);$r.timedOut=!$r.waited
 }catch{$r.errors.launchOrWait=Get-FrameworkDiagnosticError $_.Exception}
 finally{
  if($p){
   try{
    if(!$p.HasExited){$p.Kill();$r.killed=$true;$remaining=[int][Math]::Max(0,[Math]::Min(5000,[Math]::Floor(($deadline-[Diagnostics.Stopwatch]::GetTimestamp())*1000.0/[Diagnostics.Stopwatch]::Frequency)));$r.killWaited=$p.WaitForExit($remaining)}
   }catch{$r.errors.killOrWait=Get-FrameworkDiagnosticError $_.Exception}
   try{$r.exited=$p.HasExited;if($r.exited){$r.exitCode=$p.ExitCode}}catch{$r.errors.exit=Get-FrameworkDiagnosticError $_.Exception}
   try{$p.Dispose()}catch{$r.errors.dispose=Get-FrameworkDiagnosticError $_.Exception}
  }
 }
 $r.output=Read-FrameworkDiagnosticReceipt $path 'probe'
 $r.stderr=Read-FrameworkDiagnosticStderr $err
 $r
}
function Get-FrameworkLauncherFailureDiagnostic($Launcher,$Job,$Failure,$Connections,$Facts,$Start,$Frequency,$Profile,$Run,$Stderr,$Directory,$Executable,$Credential){
 $r=@{schema='ticket569-framework-launcher-failure-diagnostic-v1';errors=@{};acceptedConnections=$Connections;factNames=@($Facts|Where-Object {$_ -is [string] -and $_ -cin @('recovery-run-credential-state','session-host-health')});elapsedMilliseconds=([Diagnostics.Stopwatch]::GetTimestamp()-$Start)*1000.0/$Frequency}
 try{$r.hasExited=$Launcher.HasExited}catch{$r.errors.hasExited=Get-FrameworkDiagnosticError $_.Exception}
 try{$r.waitForExit10000=$Launcher.WaitForExit(10000)}catch{$r.errors.wait=Get-FrameworkDiagnosticError $_.Exception}
 try{$r.exitCode=$Launcher.ExitCode}catch{$r.errors.exitCode=Get-FrameworkDiagnosticError $_.Exception}
 try{$r.activeProcesses=$Job.ActiveProcesses}catch{$r.errors.activeProcesses=Get-FrameworkDiagnosticError $_.Exception}
 try{$r.failureEventSet=$Failure.Wait(0)}catch{$r.errors.failureEvent=Get-FrameworkDiagnosticError $_.Exception}
 $r.launcherReceipt=Read-FrameworkDiagnosticReceipt (Join-Path $Profile ".ticket569-$Run-recovery-launcher.json") 'launcher'
 $r.workerReceipt=Read-FrameworkDiagnosticReceipt (Join-Path $Profile ".ticket569-$Run-recovery.json") 'worker'
 $r.launcherStderr=Read-FrameworkDiagnosticStderr $Stderr
 $r
}
Export-ModuleMember -Function Get-FrameworkLauncherFailureDiagnostic,Invoke-FrameworkDiagnosticProbe
