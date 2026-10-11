$ErrorActionPreference='Stop'
$t=$null;$e=$null
$moduleAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-framework-diagnostics.psm1'),[ref]$t,[ref]$e)
foreach($f in $moduleAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){. ([scriptblock]::Create($f.Extent.Text))}
$payloadPath=Join-Path $PSScriptRoot 'hosted-framework-resolver-probe.ps1'
$payload=[IO.File]::ReadAllText($payloadPath)
$payloadAst=[Management.Automation.Language.Parser]::ParseFile($payloadPath,[ref]$t,[ref]$e)
if($e.Count){throw 'Resolver payload parse failed'}
# Execute actual resolver statements, adapting only command/module resolution;
# the final Windows identity read is outside this platform-independent contract.
$statements=@($payloadAst.EndBlock.Statements)
$resolverCode=($statements[0..($statements.Count-2)]|ForEach-Object {$_.Extent.Text}) -join "`n"
$expectedCommands=@('Get-FileHash','Get-CimInstance','Invoke-CimMethod','ConvertTo-Json','Get-Content','Test-Path','Join-Path','Get-Process')
$canary='resolver-exception-secret-canary';$pathCanary='C:\Modules\resolver-path-canary'
$root=Join-Path ([IO.Path]::GetTempPath()) ('t569-resolver-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $root
$oldModulePath=$env:PSModulePath
function Get-Command {
 param($Name,$ErrorAction)
 $script:observedCommands.Add($Name)
 if($Name -cnotin $expectedCommands){throw 'Resolver queried an unexpected command'}
 if($script:case -ceq 'missing' -or ($script:case -in @('import-success','import-failure') -and !$script:importSeen)){throw [Management.Automation.CommandNotFoundException]::new($canary)}
 [pscustomobject]@{CommandType='Function';ModuleName='Microsoft.PowerShell.Utility';Module=[pscustomobject]@{Path=$pathCanary+'\Utility.psm1';Version=[version]'1.0.0.0'}}
}
function Get-Module {
 param([switch]$ListAvailable,$Name,$ErrorAction)
 if(!$ListAvailable -or $Name -cnotin @('Microsoft.PowerShell.Utility','CimCmdlets')){throw 'Resolver discovery widened'}
 if($script:case -ceq 'discovery-failure'){throw [InvalidOperationException]::new($canary)}
 $count=if($script:case -ceq 'caps'){6}else{1}
 for($n=0;$n -lt $count;$n++){[pscustomobject]@{Path=$(if($script:case -ceq 'caps'){'C:\'+('x'*300)}else{$pathCanary+'\'+$Name+'.psd1'});Version=[version]'1.0.0.0';CompatiblePSEditions=@('Desktop','Core')}}
}
function Import-Module {
 param($Name,$Scope,$ErrorAction)
 $script:observedImports.Add($Name)
 if($Scope -cne 'Local' -or $Name -cnotin @([IO.Path]::Combine($PSHOME,'Modules','Microsoft.PowerShell.Utility','Microsoft.PowerShell.Utility.psd1'),[IO.Path]::Combine($PSHOME,'Modules','CimCmdlets','CimCmdlets.psd1'))){throw 'Resolver import was not absolute PSHOME inbox local scope'}
 if($script:case -ceq 'import-failure'){throw [InvalidOperationException]::new($canary)}
 # This local variable must not alter its parent or the next child scope.
 $script:importSeen=$true
 $local:resolverImportScopeCanary=$canary
}
try{
 foreach($case in @('found','missing','import-failure','import-success','discovery-failure','caps')){
  $script:case=$case;$script:importSeen=$false
  $script:observedCommands=[Collections.Generic.List[string]]::new();$script:observedImports=[Collections.Generic.List[string]]::new()
  $env:PSModulePath=if($case -ceq 'caps'){(@(1..40|ForEach-Object {'/'+('m'*300)}) -join [IO.Path]::PathSeparator)}else{('/first'+[IO.Path]::PathSeparator+'/modules/resolver-path-canary')}
  $value=& ([scriptblock]::Create($resolverCode+'; $resolver'))
  $json=ConvertTo-Json $value -Depth 16 -Compress
  $parsed=ConvertFrom-Json $json
  $projected=Copy-FrameworkResolverObservation $parsed
  if($json.Contains($canary) -or !$json.Contains('resolver-path-canary') -and $case -cne 'caps'){throw 'Resolver logged error message or omitted intentionally observed module path'}
  if($script:observedCommands.Count -ne 12 -or ($script:observedCommands.GetRange(0,8) -join ',') -cne ($expectedCommands -join ',') -or $script:observedImports.Count -ne 2){throw 'Resolver widened command/import inventory or changed order'}
  if($case -ceq 'missing' -and $projected.commands.'Get-FileHash'.found){throw 'Missing resolver command projected as found'}
  if($case -ceq 'found' -and !$projected.commands.'Get-FileHash'.found){throw 'Found resolver command lost metadata'}
  foreach($name in @('Microsoft.PowerShell.Utility','CimCmdlets')){
   if($projected.imports.$name.success -ne ($case -cne 'import-failure')){throw 'Resolver import success/failure overwritten'}
   if($case -ceq 'import-failure' -and !$projected.imports.$name.error){throw 'Resolver import failure omitted safe error'}
   if($case -ceq 'import-success' -and !$projected.imports.$name.commands.'Get-FileHash'.found){throw 'Resolver post-import command not observed'}
   if($case -ceq 'caps' -and ($projected.discovery.$name.results.Count -ne 4 -or !$projected.discovery.$name.truncated -or $projected.discovery.$name.results[0].path.Length -ne 260)){throw 'Resolver discovery cap/truncation lost'}
   if($case -ceq 'discovery-failure' -and !$projected.discovery.$name.error){throw 'Resolver discovery failure omitted safe error'}
  }
  if($case -ceq 'caps' -and ($projected.modulePath.entries.Count -ne 32 -or !$projected.modulePath.truncated -or $projected.modulePath.entries[0].Length -ne 260)){throw 'Resolver module path cap/truncation lost'}
  if($case -cne 'caps' -and (($projected.modulePath.entries -join ',') -cne '/first,/modules/resolver-path-canary' -or $projected.modulePath.truncated)){throw 'Resolver module path entry order changed'}
  if(Get-Variable resolverImportScopeCanary -ErrorAction SilentlyContinue){throw 'Resolver import child scope escaped'}
  Write-Output "FRAMEWORK_RESOLVER_EXTRACTED case=$case commands=8 postCommands=2x2 imports=2;MODULE_PATHS_INTENTIONALLY_OBSERVED_NATIVE_WINDOWS_UNRUN"
  # Keep a valid baseline for strict receipt/projection mutation checks.
  if($case -ceq 'found'){$baselineJson=$json}
 }
 foreach($fault in @('root-extra','runtime-extra','edition','runtime-length','path-count','path-length','relative-path','path-flag','command-extra','command-name','found-type','found-with-error','command-type','module-version-length','error-message','error-type','error-hresult','discovery-count','discovery-extra','edition-count','edition-unknown','import-extra','import-success-type','import-post-extra')){
  $v=ConvertFrom-Json $baselineJson
  switch($fault){
   root-extra {$v|Add-Member NoteProperty message $canary}
   runtime-extra {$v.runtime|Add-Member NoteProperty message $canary}
   edition {$v.runtime.edition='other'}
   runtime-length {$v.runtime.version='x'*65}
   path-count {$v.modulePath.entries=@(1..33|ForEach-Object {'C:\Modules'})}
   path-length {$v.modulePath.entries=@('C:\'+('x'*260))}
   relative-path {$v.modulePath.entries=@('not a module path')}
   path-flag {$v.modulePath.truncated='false'}
   command-extra {$v.commands.'Get-FileHash'|Add-Member NoteProperty message $canary}
   command-name {$v.commands|Add-Member NoteProperty Unexpected $v.commands.'Get-FileHash'}
   found-type {$v.commands.'Get-FileHash'.found='true'}
   found-with-error {$v.commands.'Get-FileHash'.error=[pscustomobject]@{type='System.Exception';hresult=1}}
   command-type {$v.commands.'Get-FileHash'.commandType=$canary}
   module-version-length {$v.commands.'Get-FileHash'.moduleVersion='x'*65}
   error-message {$v.discovery.CimCmdlets.error=[pscustomobject]@{type='System.Exception';hresult=1;message=$canary}}
   error-type {$v.discovery.CimCmdlets.error=[pscustomobject]@{type=$canary;hresult=1}}
   error-hresult {$v.discovery.CimCmdlets.error=[pscustomobject]@{type='System.Exception';hresult='1'}}
   discovery-count {$v.discovery.CimCmdlets.results=@(1..5|ForEach-Object {$v.discovery.CimCmdlets.results[0]})}
   discovery-extra {$v.discovery.CimCmdlets|Add-Member NoteProperty message $canary}
   edition-count {$v.discovery.CimCmdlets.results[0].compatiblePSEditions=@('Core','Desktop','Core')}
   edition-unknown {$v.discovery.CimCmdlets.results[0].compatiblePSEditions=@('Unknown')}
   import-extra {$v.imports.CimCmdlets|Add-Member NoteProperty message $canary}
   import-success-type {$v.imports.CimCmdlets.success='true'}
   import-post-extra {$v.imports.CimCmdlets.commands|Add-Member NoteProperty Unexpected $v.commands.'Get-FileHash'}
  }
  $caught=$false;try{$null=Copy-FrameworkResolverObservation $v}catch{$caught=$true}
  if(!$caught){throw "Resolver projection accepted invalid shape: $fault"}
  Write-Output "FRAMEWORK_RESOLVER_STRICT_REJECT case=$fault"
 }
 foreach($fault in @('valid','extra','missing','malformed','truncated','oversized')){
  $receipt=@{USERPROFILE='C:\Users\target';folderUserProfile='C:\Users\target';TEMP='C:\private';TMP='C:\private';sid='S-1-5-21-1';sessionId=7;resolver=(ConvertFrom-Json $baselineJson)}
  switch($fault){extra {$receipt.message=$canary} missing {$receipt.Remove('resolver')}}
  $json=ConvertTo-Json $receipt -Depth 16 -Compress
  switch($fault){malformed {$json='{bad'} truncated {$json=$json.Substring(0,$json.Length-1)} oversized {$json='x'*131073}}
  $path=Join-Path $root ($fault+'.json');[IO.File]::WriteAllText($path,$json)
  $read=Read-FrameworkDiagnosticReceipt $path 'probe'
  if($fault -ceq 'valid'){if($read.parseStatus -cne 'parsed' -or !$read.fields.resolver){throw 'Valid resolver receipt rejected'}}
  elseif($read.fields.Count -or (ConvertTo-Json $read -Depth 16).Contains($canary) -or $read.parseStatus -ceq 'parsed'){throw "Invalid resolver receipt projected fields: $fault"}
  Write-Output "FRAMEWORK_RESOLVER_RECEIPT case=$fault status=$($read.parseStatus)"
 }
 Write-Output 'FRAMEWORK_RESOLVER_EXTRACTED_CAPS_SHAPES_IMPORTS_PASSED;WINDOWS_RESOLUTION_UNRUN'
}finally{$env:PSModulePath=$oldModulePath;Microsoft.PowerShell.Management\Remove-Item -LiteralPath $root -Recurse -Force}
