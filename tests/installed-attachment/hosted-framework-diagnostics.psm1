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
function Assert-ResolverKeys($Value,$Names){
 if($null -eq $Value -or $Value -isnot [pscustomobject]){throw [FormatException]::new('Resolver object shape invalid')}
 $keys=@($Value.PSObject.Properties.Name)
 if($keys.Count -ne $Names.Count){throw [FormatException]::new('Resolver keys invalid')}
 foreach($name in $Names){if($name -cnotin $keys){throw [FormatException]::new('Resolver keys invalid')}}
}
function Assert-ResolverText($Value,[int]$Maximum,[switch]$Path){
 if($null -eq $Value){return}
 if($Value -isnot [string] -or $Value.Length -gt $Maximum -or $Value.IndexOfAny([char[]]@(0,10,13)) -ge 0 -or ($Path -and $Value -cnotmatch '^(?:[A-Za-z]:[\\/]|\\\\|/)')){throw [FormatException]::new('Resolver scalar invalid')}
}
function Copy-ResolverError($Value){
 if($null -eq $Value){return $null}
 Assert-ResolverKeys $Value @('type','hresult')
 $type=Get-FrameworkSafeExceptionType $Value.type
 if(!$type -or $type.Length -gt 256 -or ($Value.hresult -isnot [int] -and $Value.hresult -isnot [long]) -or $Value.hresult -lt [int]::MinValue -or $Value.hresult -gt [int]::MaxValue){throw [FormatException]::new('Resolver error invalid')}
 @{type=$type;hresult=[int]$Value.hresult}
}
function Copy-ResolverCommand($Value){
 Assert-ResolverKeys $Value @('found','commandType','moduleName','modulePath','moduleVersion','error')
 if($Value.found -isnot [bool]){throw [FormatException]::new('Resolver found invalid')}
 Assert-ResolverText $Value.commandType 32;Assert-ResolverText $Value.moduleName 128
 Assert-ResolverText $Value.modulePath 260 -Path;Assert-ResolverText $Value.moduleVersion 64
 if($null -ne $Value.commandType -and $Value.commandType -cnotin @('Alias','Function','Filter','Cmdlet','ExternalScript','Application','Script','Configuration')){throw [FormatException]::new('Resolver command type invalid')}
 if(!$Value.found -and ($null -ne $Value.commandType -or $null -ne $Value.moduleName -or $null -ne $Value.modulePath -or $null -ne $Value.moduleVersion)){throw [FormatException]::new('Missing resolver command has metadata')}
 $error=Copy-ResolverError $Value.error
 if($Value.found -and $null -ne $error){throw [FormatException]::new('Found resolver command has error')}
 @{found=$Value.found;commandType=$Value.commandType;moduleName=$Value.moduleName;modulePath=$Value.modulePath;moduleVersion=$Value.moduleVersion;error=$error}
}
function Copy-FrameworkResolverObservation($Value){
 Assert-ResolverKeys $Value @('runtime','modulePath','commands','discovery','imports')
 Assert-ResolverKeys $Value.runtime @('edition','version','pshome')
 Assert-ResolverText $Value.runtime.edition 16;Assert-ResolverText $Value.runtime.version 64;Assert-ResolverText $Value.runtime.pshome 260 -Path
 if($Value.runtime.edition -cnotin @('Desktop','Core')){throw [FormatException]::new('Resolver edition invalid')}
 Assert-ResolverKeys $Value.modulePath @('entries','truncated')
 if($Value.modulePath.entries -isnot [array] -or $Value.modulePath.entries.Count -gt 32 -or $Value.modulePath.truncated -isnot [bool]){throw [FormatException]::new('Resolver module path cap invalid')}
 foreach($entry in $Value.modulePath.entries){Assert-ResolverText $entry 260 -Path}
 $commandNames=@('Get-FileHash','Get-CimInstance','Invoke-CimMethod','ConvertTo-Json','Get-Content','Test-Path','Join-Path','Get-Process')
 Assert-ResolverKeys $Value.commands $commandNames
 $commands=@{};foreach($name in $commandNames){$commands[$name]=Copy-ResolverCommand $Value.commands.$name}
 $moduleNames=@('Microsoft.PowerShell.Utility','CimCmdlets')
 Assert-ResolverKeys $Value.discovery $moduleNames;Assert-ResolverKeys $Value.imports $moduleNames
 $discovery=@{};$imports=@{}
 foreach($name in $moduleNames){
  $d=$Value.discovery.$name;Assert-ResolverKeys $d @('results','truncated','error')
  if($d.results -isnot [array] -or $d.results.Count -gt 4 -or $d.truncated -isnot [bool]){throw [FormatException]::new('Resolver discovery cap invalid')}
  $results=[Collections.Generic.List[object]]::new()
  foreach($module in $d.results){
   Assert-ResolverKeys $module @('path','version','compatiblePSEditions')
   Assert-ResolverText $module.path 260 -Path;Assert-ResolverText $module.version 64
   if($module.compatiblePSEditions -isnot [array] -or $module.compatiblePSEditions.Count -gt 2){throw [FormatException]::new('Resolver compatible editions invalid')}
   foreach($edition in $module.compatiblePSEditions){if($edition -cnotin @('Desktop','Core')){throw [FormatException]::new('Resolver compatible edition invalid')}}
   if(@($module.compatiblePSEditions|Select-Object -Unique).Count -ne $module.compatiblePSEditions.Count){throw [FormatException]::new('Resolver compatible editions duplicated')}
   $results.Add(@{path=$module.path;version=$module.version;compatiblePSEditions=@($module.compatiblePSEditions)})
  }
  $discovery[$name]=@{results=@($results);truncated=$d.truncated;error=(Copy-ResolverError $d.error)}
  $i=$Value.imports.$name;Assert-ResolverKeys $i @('path','success','error','commands')
  Assert-ResolverText $i.path 260 -Path
  if($i.success -isnot [bool]){throw [FormatException]::new('Resolver import success invalid')}
  $error=Copy-ResolverError $i.error
  if($i.success -and $null -ne $error){throw [FormatException]::new('Successful resolver import has error')}
  Assert-ResolverKeys $i.commands @('Get-FileHash','Get-CimInstance')
  $imports[$name]=@{path=$i.path;success=$i.success;error=$error;commands=@{'Get-FileHash'=(Copy-ResolverCommand $i.commands.'Get-FileHash');'Get-CimInstance'=(Copy-ResolverCommand $i.commands.'Get-CimInstance')}}
 }
 @{runtime=@{edition=$Value.runtime.edition;version=$Value.runtime.version;pshome=$Value.runtime.pshome};modulePath=@{entries=@($Value.modulePath.entries);truncated=$Value.modulePath.truncated};commands=$commands;discovery=$discovery;imports=$imports}
}
function Read-FrameworkDiagnosticReceipt($Path,[string]$Kind){
 $r=@{exists=$null;bytes=$null;parseStatus='unread';fields=@{};errors=@{}}
 try{$r.exists=Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop}catch{$r.errors.exists=Get-FrameworkDiagnosticError $_.Exception;return $r}
 if(!$r.exists){$r.parseStatus='missing';return $r}
 try{$r.bytes=(Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length}catch{$r.errors.bytes=Get-FrameworkDiagnosticError $_.Exception}
 try{if($Kind -ceq 'probe' -and ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length -gt 131072)){throw [FormatException]::new('Probe output exceeds cap')};$raw=Get-Content -LiteralPath $Path -Raw -ErrorAction Stop}catch{$r.errors.read=Get-FrameworkDiagnosticError $_.Exception;return $r}
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
   Assert-ResolverKeys $v @('USERPROFILE','folderUserProfile','TEMP','TMP','sid','sessionId','resolver')
   foreach($key in @('USERPROFILE','folderUserProfile','TEMP','TMP')){Assert-ResolverText $v.$key 260 -Path}
   if($v.sid -isnot [string] -or $v.sid -cnotmatch '^S-1-5-[0-9-]+$' -or $v.sid.Length -gt 184 -or ($v.sessionId -isnot [int] -and $v.sessionId -isnot [long]) -or $v.sessionId -lt 0 -or $v.sessionId -gt 65535){throw [FormatException]::new('Probe identity invalid')}
   $r.fields.resolver=Copy-FrameworkResolverObservation $v.resolver
   foreach($key in @('USERPROFILE','folderUserProfile','TEMP','TMP')){if($v.$key -is [string]){$r.fields[$key]=$v.$key}}
   if($v.sid -is [string] -and $v.sid -match '^S-1-5-[0-9-]+$'){$r.fields.sid=$v.sid}
   if($v.sessionId -is [int] -or $v.sessionId -is [long]){$r.fields.sessionId=$v.sessionId}
  }
 }catch{$r.parseStatus='invalid';$r.fields=@{};$r.errors.parse=Get-FrameworkDiagnosticError $_.Exception}
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
function Get-FrameworkProbeCommandLine($Executable,$ProbePath){
 $arguments=@('-NoProfile','-NonInteractive','-File',('"'+$ProbePath+'"'))
 '"'+$Executable+'" '+($arguments -join ' ')
}
function Invoke-FrameworkDiagnosticProbe($Directory,$Executable,$Credential){
 $r=@{launched=$false;waited=$false;timedOut=$false;killed=$false;killWaited=$false;exited=$null;exitCode=$null;errors=@{};output=$null;commandLineLength=$null}
 $p=$null;$path=Join-Path $Directory.path 'launcher-environment-probe.stdout';$err=$path+'.stderr'
 $probePath=Join-Path $PSScriptRoot 'hosted-framework-resolver-probe.ps1'
 try{
  $r.commandLineLength=(Get-FrameworkProbeCommandLine $Executable $probePath).Length
  if($r.commandLineLength -ge 1024){throw [ArgumentOutOfRangeException]::new('Probe command line exceeds credential launch limit')}
  $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+15L*[Diagnostics.Stopwatch]::Frequency
  $p=Invoke-FrameworkCompilerLaunch $Directory ({param($frameworkChildEnvironment) Start-Process $Executable -Credential $Credential -LoadUserProfile -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-File',"`"$probePath`"") -RedirectStandardOutput $path -RedirectStandardError $err @frameworkChildEnvironment}.GetNewClosure())
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
