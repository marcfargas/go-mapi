# Fixed failure-only -File payload launched by the framework fixture. No production imports.
$ErrorActionPreference='Stop'
function Limit-ResolverString($Value,[int]$Maximum){
 if($null -eq $Value){return $null}
 $text=[string]$Value
 if($text.IndexOfAny([char[]]@(0,10,13)) -ge 0){return $null}
 if($text.Length -gt $Maximum){return $text.Substring(0,$Maximum)}
 $text
}
function Limit-ResolverPath($Value){
 if($Value -isnot [string] -or $Value -cnotmatch '^(?:[A-Za-z]:[\\/]|\\\\|/)'){return $null}
 Limit-ResolverString $Value 260
}
function Get-ResolverError($Exception){
 $type=$Exception.GetType().FullName
 if($type.Length -gt 256 -or $type -cnotmatch '^(?:[A-Za-z_][A-Za-z0-9_+`]*\.)*[A-Za-z_][A-Za-z0-9_+`]*Exception$'){$type='System.Exception'}
 @{type=$type;hresult=[int]$Exception.HResult}
}
function Get-ResolverCommand($Name){
 $r=@{found=$false;commandType=$null;moduleName=$null;modulePath=$null;moduleVersion=$null;error=$null}
 try{
  $command=Get-Command -Name $Name -ErrorAction Stop
  if($null -ne $command){
   $r.found=$true;$r.commandType=Limit-ResolverString ([string]$command.CommandType) 32
   $r.moduleName=Limit-ResolverString $command.ModuleName 128
   if($command.Module){$r.modulePath=Limit-ResolverPath $command.Module.Path;$r.moduleVersion=Limit-ResolverString ([string]$command.Module.Version) 64}
  }
 }catch{$r.error=Get-ResolverError $_.Exception}
 $r
}
$commands=@{}
foreach($name in @('Get-FileHash','Get-CimInstance','Invoke-CimMethod','ConvertTo-Json','Get-Content','Test-Path','Join-Path','Get-Process')){$commands[$name]=Get-ResolverCommand $name}
$moduleEntries=[Collections.Generic.List[object]]::new();$modulePathTruncated=$false
foreach($entry in ([string]$env:PSModulePath -split [regex]::Escape([string][IO.Path]::PathSeparator))){
 if($moduleEntries.Count -eq 32){$modulePathTruncated=$true;break}
 if($entry.Length -gt 260){$modulePathTruncated=$true}
 $moduleEntries.Add((Limit-ResolverPath $entry))
}
$discovery=@{};$imports=@{}
foreach($name in @('Microsoft.PowerShell.Utility','CimCmdlets')){
 $results=[Collections.Generic.List[object]]::new();$resolverError=$null;$truncated=$false
 try{
  foreach($module in (Get-Module -ListAvailable -Name $name -ErrorAction Stop)){
   if($results.Count -eq 4){$truncated=$true;break}
   $editions=[Collections.Generic.List[string]]::new()
   foreach($edition in $module.CompatiblePSEditions){if($edition -cin @('Desktop','Core') -and !$editions.Contains($edition)){$editions.Add($edition)}}
   if(([string]$module.Path).Length -gt 260){$truncated=$true}
   $results.Add(@{path=(Limit-ResolverPath $module.Path);version=(Limit-ResolverString ([string]$module.Version) 64);compatiblePSEditions=@($editions)})
  }
 }catch{$resolverError=Get-ResolverError $_.Exception}
 $discovery[$name]=@{results=@($results);truncated=$truncated;error=$resolverError}
 $imports[$name]=& {
  param($ModuleName)
  $path=[IO.Path]::Combine($PSHOME,'Modules',$ModuleName,($ModuleName+'.psd1'))
  $success=$false;$resolverError=$null
  try{Import-Module -Name $path -Scope Local -ErrorAction Stop;$success=$true}catch{$resolverError=Get-ResolverError $_.Exception}
  @{path=(Limit-ResolverPath $path);success=$success;error=$resolverError;commands=@{'Get-FileHash'=(Get-ResolverCommand 'Get-FileHash');'Get-CimInstance'=(Get-ResolverCommand 'Get-CimInstance')}}
 } $name
}
$resolver=@{runtime=@{edition=(Limit-ResolverString $PSVersionTable.PSEdition 16);version=(Limit-ResolverString ([string]$PSVersionTable.PSVersion) 64);pshome=(Limit-ResolverPath $PSHOME)};modulePath=@{entries=@($moduleEntries);truncated=$modulePathTruncated};commands=$commands;discovery=$discovery;imports=$imports}
# Preserve the existing explicitly authorized identity/environment observation.
@{USERPROFILE=$env:USERPROFILE;folderUserProfile=[Environment]::GetFolderPath('UserProfile');TEMP=$env:TEMP;TMP=$env:TMP;sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;sessionId=(Get-Process -Id $PID).SessionId;resolver=$resolver}|ConvertTo-Json -Depth 16 -Compress
