$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-framework-compiler.psm1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Compiler fixture parse failed'}
# Execute both exact, unmodified ancestor loops in a clean runspace with the
# real provider and a multi-level chain; raw DirectoryInfo.Parent has no
# provider PSIsContainer property. No Get-Item/attribute adapter participates.
$loops=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.ForStatementAst] -and $n.Extent.Text.Contains('for($ancestor=Get-Item')},$true))
if($loops.Count -ne 2){throw 'Expected both real ancestor loops'}
$actualDirectory=Microsoft.PowerShell.Management\Get-Item -LiteralPath ([IO.Path]::GetTempPath())
if(!$actualDirectory.Parent -or $actualDirectory.Parent -isnot [IO.DirectoryInfo]){throw 'Real directory parent chain unavailable'}
foreach($loop in $loops){
    $clean=[PowerShell]::Create()
    try {
        $null=$clean.AddScript('$parent=$args[0];$Receipt=@{parent=$parent};'+$loop.Extent.Text).AddArgument($actualDirectory.FullName)
        $null=$clean.Invoke()
        if($clean.HadErrors){throw ($clean.Streams.Error|Out-String)}
    }finally{$clean.Dispose()}
}
Write-Output 'FRAMEWORK_COMPILER_REAL_DIRECTORY_ANCESTRY_LOOPS_PASSED;ACTUAL_PROVIDER_RAW_PARENT_CHAIN'
foreach($name in @('New-FrameworkCompilerDirectory','Assert-FrameworkCompilerDirectory','Invoke-FrameworkCompilerLaunch','Remove-FrameworkCompilerDirectory')){
    $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
    if($f.Count -ne 1){throw "Compiler extraction failed $name"}
    $text=$f[0].Extent.Text
    if($name -ceq 'New-FrameworkCompilerDirectory'){
        # Windows creation and ACL seam only. All guards/launch/finally are exact.
        $text=$text.Replace("[Environment]::GetFolderPath('CommonApplicationData')",'$script:parent')
        $text=$text.Replace('[Ticket569FrameworkDirectory]::Create($path,$sddl)','Create-CompilerDirectoryAdapter $path $sddl')
    }
    # Adapt only attribute reads for reparse observations; DirectoryInfo type
    # and traversal guards execute with real directory objects.
    $text=$text.Replace('($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)','(Test-CompilerAdapterReparse $ancestor)')
    $text=$text.Replace('($item.Attributes -band [IO.FileAttributes]::ReparsePoint)','(Test-CompilerAdapterReparse $item)')
    . ([scriptblock]::Create($text))
}
Add-Type 'public static class Ticket569FrameworkDirectory {}'
function New-State {
    $script:parent=if($IsWindows){'C:\qualified-programdata'}else{'/qualified-programdata'}
    $script:run='a'*32;$script:runner='S-1-5-21-1-2-3-500';$script:target='S-1-5-21-1-2-3-1001'
    $script:exists=$false;$script:created=$false;$script:launchCount=0;$script:removed=$false;$script:fault=''
    $script:receipt=@{created=$true;path=(Join-Path $parent "t569-framework-compiler-$run");parent=$parent;runId=$run;ownerSID=$runner;grants=@($runner,'S-1-5-18',$target)}
}
function Get-Item {param($LiteralPath,[switch]$Force,$ErrorAction)
    if($script:fault -ceq 'missing'){throw 'missing directory adapter'}
    if($script:fault -ceq 'not-directory'){return [IO.FileInfo]::new((Join-Path ([IO.Path]::GetTempPath()) 'compiler-test-adapter-file'))}
    $dir=[IO.DirectoryInfo]::new([IO.Path]::GetTempPath());$dir|Add-Member NoteProperty PSIsContainer $true -Force;$dir
}
function Test-CompilerAdapterReparse($Item){$script:fault -cin @('reparse','ancestor-reparse')}
function Test-Path {param($LiteralPath)$script:exists}
function Create-CompilerDirectoryAdapter($Path,$Sddl){if($script:fault -ceq 'atomic-collision'){throw 'ERROR_ALREADY_EXISTS adapter'};$script:exists=$true;$script:created=$true;$script:createSDDL=$Sddl}
function Get-Acl {param($LiteralPath,$ErrorAction)
    $o=[pscustomobject]@{AreAccessRulesProtected=($script:fault -cne 'unprotected')}
    $o|Add-Member ScriptMethod GetOwner {param($type)@{Value=$(if($script:fault -ceq 'owner'){'S-1-5-18'}else{$script:runner})}}
    $o|Add-Member ScriptMethod GetAccessRules {
        foreach($g in $script:receipt.grants){
            [pscustomobject]@{IdentityReference=@{Value=$g};IsInherited=($script:fault -ceq 'inherited');AccessControlType=$(if($script:fault -ceq 'deny'){[Security.AccessControl.AccessControlType]::Deny}else{[Security.AccessControl.AccessControlType]::Allow});FileSystemRights=$(if($script:fault -ceq 'rights'){[Security.AccessControl.FileSystemRights]::Read}else{[Security.AccessControl.FileSystemRights]::FullControl});InheritanceFlags=$(if($script:fault -ceq 'inherit-flags'){[Security.AccessControl.InheritanceFlags]::None}else{[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit});PropagationFlags=$(if($script:fault -ceq 'propagation'){[Security.AccessControl.PropagationFlags]::InheritOnly}else{[Security.AccessControl.PropagationFlags]::None})}
        }
        if($script:fault -ceq 'extra-ace'){@{IdentityReference=@{Value='S-1-1-0'}}}
    }
    $o
}
function Get-Command {param($Name,$CommandType)@{Parameters=$(if($script:environmentSupported){@{Environment=$true}}else{@{}})}}
function Get-ChildItem {param($LiteralPath,[switch]$Recurse,[switch]$Force,$ErrorAction)if($script:fault -ceq 'child-reparse'){@{Attributes=[IO.FileAttributes]::ReparsePoint}}}
function Remove-Item {param($LiteralPath,[switch]$Recurse,[switch]$Force,$ErrorAction)if($script:fault -ceq 'cleanup-throw'){throw 'cleanup adapter'};$script:removed=$true;if($script:fault -cne 'residual'){$script:exists=$false}}
function Expect-Failure([scriptblock]$Action,[string]$Name){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};if(!$caught){throw "Compiler fault escaped $Name"};Write-Output "COMPILER_ADAPTER_REFUSED $Name"}
New-State
$actual=New-FrameworkCompilerDirectory $run $runner $target
Assert-FrameworkCompilerDirectory $actual
if(!$script:created -or !$script:createSDDL.Contains("O:${runner}D:P") -or !$script:createSDDL.Contains("(A;OICI;FA;;;$target)")){throw 'Atomic exact security adapter binding differs'}
foreach($f in @('ancestor-reparse','not-directory','atomic-collision')){New-State;$script:fault=$f;Expect-Failure {New-FrameworkCompilerDirectory $run $runner $target} $f;if($script:removed){throw 'Failed creation removed unowned path'}}
New-State;$script:exists=$true;Expect-Failure {New-FrameworkCompilerDirectory $run $runner $target} 'collision';if($script:created -or $script:removed){throw 'Occupied path was adopted'}
foreach($args in @(@('bad',$runner,$target),@($run,'bad',$target),@($run,$runner,$runner))){Expect-Failure {New-FrameworkCompilerDirectory @args} 'invalid-input'}
foreach($f in @('missing','reparse','ancestor-reparse','not-directory','unprotected','owner','extra-ace','deny','rights','inherited','inherit-flags','propagation')){New-State;$script:exists=$true;$script:fault=$f;Expect-Failure {Invoke-FrameworkCompilerLaunch $receipt {$script:launchCount++}} $f;if($script:launchCount){throw 'Guard failed to prevent launch'}}
New-State;$receipt.path=Join-Path $parent 'other';Expect-Failure {Invoke-FrameworkCompilerLaunch $receipt {$script:launchCount++}} 'path'
$originalTemp=[Environment]::GetEnvironmentVariable('TEMP','Process');$originalTmp=[Environment]::GetEnvironmentVariable('TMP','Process')
try {
 foreach($supported in @($true,$false)){
  foreach($preset in @($true,$false)){
   foreach($launchThrows in @($true,$false)){
    New-State;$script:exists=$true;$script:environmentSupported=$supported
    [Environment]::SetEnvironmentVariable('TEMP',$(if($preset){'original-temp'}else{[NullString]::Value}),'Process')
    [Environment]::SetEnvironmentVariable('TMP',$(if($preset){'original-tmp'}else{[NullString]::Value}),'Process')
    $beforeTemp=[Environment]::GetEnvironmentVariable('TEMP','Process');$beforeTmp=[Environment]::GetEnvironmentVariable('TMP','Process')
    $caught=$false
    try {$result=Invoke-FrameworkCompilerLaunch $receipt {
       param($frameworkChildEnvironment)
       $script:launchCount++
       if($supported){if($frameworkChildEnvironment.Environment.TEMP -cne $receipt.path -or $frameworkChildEnvironment.Environment.TMP -cne $receipt.path -or [Environment]::GetEnvironmentVariable('TEMP','Process') -cne $beforeTemp){throw 'Per-child environment binding differs'}}
       elseif([Environment]::GetEnvironmentVariable('TEMP','Process') -cne $receipt.path -or [Environment]::GetEnvironmentVariable('TMP','Process') -cne $receipt.path -or $frameworkChildEnvironment.Count){throw 'Scoped inherited environment differs'}
       if($launchThrows){throw 'expected launch failure'}
       [pscustomobject]@{actualProcessReturn='retained-adapter'}
    }}catch{if($_.Exception.Message -cne 'expected launch failure'){throw};$caught=$true}
    if($caught -ne $launchThrows -or $script:launchCount -ne 1 -or (!$launchThrows -and $result.actualProcessReturn -cne 'retained-adapter')){throw 'Launch result/throw differs'}
    if([Environment]::GetEnvironmentVariable('TEMP','Process') -cne $beforeTemp -or [Environment]::GetEnvironmentVariable('TMP','Process') -cne $beforeTmp){throw 'TEMP/TMP did not restore exactly including unset'}
   }
  }
 }
}finally{[Environment]::SetEnvironmentVariable('TEMP',$(if($null -eq $originalTemp){[NullString]::Value}else{$originalTemp}),'Process');[Environment]::SetEnvironmentVariable('TMP',$(if($null -eq $originalTmp){[NullString]::Value}else{$originalTmp}),'Process')}
foreach($f in @('child-reparse','cleanup-throw','residual')){New-State;$script:exists=$true;$script:fault=$f;Expect-Failure {Remove-FrameworkCompilerDirectory $receipt} $f}
New-State;$script:exists=$true;$marker=@(Remove-FrameworkCompilerDirectory $receipt);if(!$script:removed -or $script:exists -or $marker -cnotcontains 'FRAMEWORK_ACTUAL_COMPILER_DIRECTORY_ABSENCE_PASSED'){throw 'Actual absence gate adapter failed'}
# Every credential command keeps the actual production argv and the environment
# splat inside the guarded invocation. Descendants inherit TEMP/TMP naturally.
$framework=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'hosted-capability-framework-tests.ps1'))
$credentialLines=@($framework.Split([char]10)|Where-Object {$_ -match 'Start-Process \$exe -Credential \$credential'})
if($credentialLines.Count -ne 3 -or @($credentialLines|Where-Object {$_ -notmatch 'Invoke-FrameworkCompilerLaunch.*@frameworkChildEnvironment'}).Count){throw 'A credential launch escaped compiler environment'}
Write-Output 'FRAMEWORK_COMPILER_EXTRACTED_GUARDS_LAUNCH_CLEANUP_PASSED;WINDOWS_CREATE_DACL_ADAPTERS_NATIVE_UNRUN'
