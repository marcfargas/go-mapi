$ErrorActionPreference='Stop'
# Ordinary CI fixture only. This runs in the runner, whose compiler TEMP is
# available; credential-launched Framework children inherit the private path.
function New-FrameworkCompilerDirectory([string]$RunId,[string]$RunnerSID,[string]$TargetSID) {
    if($RunId -notmatch '^[a-f0-9]{32}$' -or $RunnerSID -notmatch '^S-1-5-[0-9-]+$' -or $TargetSID -notmatch '^S-1-5-21-[0-9-]+$' -or $RunnerSID -ceq $TargetSID){throw 'Invalid compiler directory context'}
    $parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath('CommonApplicationData'))
    if(!$parent -or ![IO.Path]::IsPathRooted($parent)){throw 'Compiler parent path unavailable'}
    for($ancestor=Get-Item -LiteralPath $parent -Force -ErrorAction Stop;$ancestor;$ancestor=$ancestor.Parent){
        if(($ancestor -isnot [IO.DirectoryInfo]) -or ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Compiler parent ancestry is not an ordinary directory'}
    }
    $path=Join-Path $parent ("t569-framework-compiler-$RunId")
    if(Test-Path -LiteralPath $path){throw 'Compiler directory collision'}
    if(!('Ticket569FrameworkDirectory' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class Ticket569FrameworkDirectory {
 [StructLayout(LayoutKind.Sequential)] struct SA { public int length; public IntPtr descriptor; public int inherit; }
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string text,uint revision,out IntPtr descriptor,out uint size);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateDirectoryW(string path,ref SA security);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
 public static void Create(string path,string sddl) {
  IntPtr descriptor; uint size;
  if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl,1,out descriptor,out size))throw new Win32Exception(Marshal.GetLastWin32Error());
  try { SA security=new SA{length=Marshal.SizeOf(typeof(SA)),descriptor=descriptor,inherit=0};
   if(!CreateDirectoryW(path,ref security))throw new Win32Exception(Marshal.GetLastWin32Error());
  } finally { LocalFree(descriptor); }
 }
}
'@
    }
    $grants=@($RunnerSID,'S-1-5-18',$TargetSID)|Sort-Object -Unique
    $sddl="O:${RunnerSID}D:P"+ (($grants|ForEach-Object {"(A;OICI;FA;;;$_)"}) -join '')
    # CreateDirectoryW fails ERROR_ALREADY_EXISTS; an occupied path is never
    # adopted or modified. The protected DACL exists at the instant of creation.
    [Ticket569FrameworkDirectory]::Create($path,$sddl)
    $receipt=@{path=$path;parent=$parent;runId=$RunId;ownerSID=$RunnerSID;grants=$grants;created=$true}
    $receipt
}
function Assert-FrameworkCompilerDirectory($Receipt) {
    if(!$Receipt -or $Receipt.created -ne $true -or $Receipt.runId -notmatch '^[a-f0-9]{32}$' -or
       [IO.Path]::GetFullPath($Receipt.path) -cne (Join-Path $Receipt.parent ("t569-framework-compiler-$($Receipt.runId)"))){throw 'Compiler directory ownership/path receipt invalid'}
    for($ancestor=Get-Item -LiteralPath $Receipt.parent -Force -ErrorAction Stop;$ancestor;$ancestor=$ancestor.Parent){
        if(($ancestor -isnot [IO.DirectoryInfo]) -or ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Compiler parent ancestry changed before use/cleanup'}
    }
    $item=Get-Item -LiteralPath $Receipt.path -Force -ErrorAction Stop
    if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Compiler directory replaced or reparse'}
    $acl=Get-Acl -LiteralPath $Receipt.path -ErrorAction Stop
    if(!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $Receipt.ownerSID){throw 'Compiler directory owner or protection changed'}
    $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    $expected=@($Receipt.grants|Sort-Object -Unique)
    if($rules.Count -ne $expected.Count){throw 'Compiler directory grants differ'}
    foreach($grant in $expected){
        $matches=@($rules|Where-Object {$_.IdentityReference.Value -ceq $grant -and !$_.IsInherited -and
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.FileSystemRights -eq [Security.AccessControl.FileSystemRights]::FullControl -and
            $_.InheritanceFlags -eq ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit) -and
            $_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None})
        if($matches.Count -ne 1){throw 'Compiler directory exact DACL differs'}
    }
}
function Invoke-FrameworkCompilerLaunch {
    [CmdletBinding()]
    param($Receipt,[scriptblock]$Launch,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][ValidateScript({
            if([IO.Path]::DirectorySeparatorChar -eq [char]92){$_ -cmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+(?:\\|$))'}
            else{[IO.Path]::IsPathRooted($_)}
        })][string]$ChildUserProfile)

    Assert-FrameworkCompilerDirectory $Receipt
    # Decide from the actual parent's cmdlet metadata, not a version guess.
    $frameworkChildEnvironment=@{}
    if((Get-Command Start-Process -CommandType Cmdlet).Parameters.ContainsKey('Environment')){
        $frameworkChildEnvironment.Environment=@{TEMP=$Receipt.path;TMP=$Receipt.path;USERPROFILE=$ChildUserProfile}
        & $Launch $frameworkChildEnvironment
        return
    }
    $oldTemp=[Environment]::GetEnvironmentVariable('TEMP','Process');$oldTmp=[Environment]::GetEnvironmentVariable('TMP','Process');$oldUserProfile=[Environment]::GetEnvironmentVariable('USERPROFILE','Process')
    try {
        [Environment]::SetEnvironmentVariable('TEMP',$Receipt.path,'Process')
        [Environment]::SetEnvironmentVariable('TMP',$Receipt.path,'Process')
        [Environment]::SetEnvironmentVariable('USERPROFILE',$ChildUserProfile,'Process')
        & $Launch $frameworkChildEnvironment
    } finally {
        try {[Environment]::SetEnvironmentVariable('TEMP',$(if($null -eq $oldTemp){[NullString]::Value}else{$oldTemp}),'Process')}
        finally {
            try {[Environment]::SetEnvironmentVariable('TMP',$(if($null -eq $oldTmp){[NullString]::Value}else{$oldTmp}),'Process')}
            finally {[Environment]::SetEnvironmentVariable('USERPROFILE',$(if($null -eq $oldUserProfile){[NullString]::Value}else{$oldUserProfile}),'Process')}
        }
    }
}
function Remove-FrameworkCompilerDirectory($Receipt) {
    if(!$Receipt){return}
    Assert-FrameworkCompilerDirectory $Receipt
    if(@(Get-ChildItem -LiteralPath $Receipt.path -Recurse -Force -ErrorAction Stop|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Compiler cleanup refuses reparse descendants'}
    Remove-Item -LiteralPath $Receipt.path -Recurse -Force -ErrorAction Stop
    if(Test-Path -LiteralPath $Receipt.path){throw 'Compiler directory remains after cleanup'}
    Write-Output 'FRAMEWORK_ACTUAL_COMPILER_DIRECTORY_ABSENCE_PASSED'
}
Export-ModuleMember -Function New-FrameworkCompilerDirectory,Assert-FrameworkCompilerDirectory,Invoke-FrameworkCompilerLaunch,Remove-FrameworkCompilerDirectory
