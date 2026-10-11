$ErrorActionPreference='Stop'
if(-not ('T569FrameworkJobSecurity' -as [type])){
 Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
public static class T569FrameworkJobSecurity {
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetKernelObjectSecurity(IntPtr handle,uint info,[Out] byte[] descriptor,uint length,out uint needed);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int info,IntPtr buffer,uint length,out uint needed);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenJobObjectW(uint access,bool inherit,string name);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
 public static string ReadJobDaclAndLabel(IntPtr handle){
  uint needed;GetKernelObjectSecurity(handle,0x14,null,0,out needed);
  int error=Marshal.GetLastWin32Error();
  if(error!=122 || needed==0 || needed>65536)throw new Win32Exception(error);
  byte[] descriptor=new byte[needed];
  if(!GetKernelObjectSecurity(handle,0x14,descriptor,(uint)descriptor.Length,out needed))throw new Win32Exception(Marshal.GetLastWin32Error());
  return new RawSecurityDescriptor(descriptor,0).GetSddlForm(AccessControlSections.Access|AccessControlSections.Audit);
 }
 public static string ReadCurrentTokenIntegrity(){
  using(WindowsIdentity identity=WindowsIdentity.GetCurrent()){
   uint needed;GetTokenInformation(identity.Token,25,IntPtr.Zero,0,out needed);
   int error=Marshal.GetLastWin32Error();
   if(error!=122 || needed==0 || needed>65536)throw new Win32Exception(error);
   IntPtr buffer=Marshal.AllocHGlobal((int)needed);
   try{
    if(!GetTokenInformation(identity.Token,25,buffer,needed,out needed))throw new Win32Exception(Marshal.GetLastWin32Error());
    return new SecurityIdentifier(Marshal.ReadIntPtr(buffer)).Value;
   }finally{Marshal.FreeHGlobal(buffer);}
  }
 }
 public static int QueryOnlyJobOpen(string name){
  if(name==null || !System.Text.RegularExpressions.Regex.IsMatch(name,@"\AGlobal\\Ticket569-[a-f0-9]{32}-recovery\z"))throw new ArgumentException();
  IntPtr handle=OpenJobObjectW(0x4,false,name);
  if(handle==IntPtr.Zero)return Marshal.GetLastWin32Error();
  try{return 0;}finally{if(!CloseHandle(handle))throw new Win32Exception(Marshal.GetLastWin32Error());}
 }
}
'@ -ErrorAction Stop
}
function Get-FrameworkRecoveryJobSecurity($Job){
 $r=@{daclAndLabelSddl=$null;errorCode=$null}
 try{$r.daclAndLabelSddl=[T569FrameworkJobSecurity]::ReadJobDaclAndLabel($Job.Handle)}
 catch{$e=$_.Exception;for($i=0;$e -and $i -lt 8;$i++){if($e -is [ComponentModel.Win32Exception]){$r.errorCode=$e.NativeErrorCode;break};$e=$e.InnerException}}
 $r
}
function Get-FrameworkRecoveryJobAccess([string]$Name){
 $r=@{integritySID=$null;integrityErrorCode=$null;queryOnlyErrorCode=$null}
 try{$sid=[T569FrameworkJobSecurity]::ReadCurrentTokenIntegrity();if($sid -cmatch '^S-1-16-[0-9]{1,10}$'){$r.integritySID=$sid}}
 catch{$e=$_.Exception;for($i=0;$e -and $i -lt 8;$i++){if($e -is [ComponentModel.Win32Exception]){$r.integrityErrorCode=$e.NativeErrorCode;break};$e=$e.InnerException}}
 try{$r.queryOnlyErrorCode=[T569FrameworkJobSecurity]::QueryOnlyJobOpen($Name)}catch{}
 $r
}
Export-ModuleMember -Function Get-FrameworkRecoveryJobSecurity,Get-FrameworkRecoveryJobAccess
