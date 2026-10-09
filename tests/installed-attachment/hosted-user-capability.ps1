[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][ValidateSet('normal', 'mount-point')][string] $ProfileKind,
    [Parameter(Mandatory)][string] $ExpectedSID,
    [string] $VhdPath,
    [ValidateRange(0, 15)][int] $HoldAfterWriteSeconds = 3
)

$ErrorActionPreference = 'Stop'
$startedAt = [DateTime]::UtcNow
$record = [ordered]@{
    schema = 'go-mapi-hosted-user-probe-v2'
    runId = $RunId
    profileKind = $ProfileKind
    startedAtUtc = $startedAt.ToString('o')
    completedAtUtc = $null
    processId = $PID
    processCreationFileTimeUtc = $null
    user = $null
    sid = $null
    sessionId = $null
    admin = $null
    userInteractive = [Environment]::UserInteractive
    windowStation = $null
    desktop = $null
    userProfile = $env:USERPROFILE
    userProfileApi = $null
    profileLoaded = $false
    profileSID = $null
    profileLocalPath = $null
    profileHivePresent = $false
    credential = $null
    profileMount = $null
    conditions = [Collections.Generic.List[string]]::new()
    cleanupErrors = [Collections.Generic.List[string]]::new()
    passed = $false
}
$runCredentialTarget = "ticket569-hosted-capability-$RunId"
$credentialWasWritten = $false

function Write-Atomic([string] $Path, [object] $Value) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 32) + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

try {
    if ($RunId -notmatch '^[a-f0-9]{32}$' -or $ExpectedSID -notmatch '^S-1-5-21-') { throw 'Probe run or expected user SID is malformed' }
    if ($ProfileKind -eq 'mount-point' -and (!$VhdPath -or $VhdPath -notlike 'C:\crabbox\work\ticket569\*.vhdx')) { throw 'Mounted-profile probe requires its exact owned VHD path' }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class Ticket569HostedProbe {
 [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
 [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint id);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("user32.dll", SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr h,int i,StringBuilder b,int n,out int needed);
 static string Name(IntPtr h) { int n; GetUserObjectInformation(h,2,null,0,out n); if(n<=0)return null; StringBuilder b=new StringBuilder(n); if(!GetUserObjectInformation(h,2,b,b.Capacity,out n)) throw new Win32Exception(Marshal.GetLastWin32Error()); return b.ToString(); }
 public static string WindowStation() { return Name(GetProcessWindowStation()); }
 public static string Desktop() { return Name(GetThreadDesktop(GetCurrentThreadId())); }
 [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
 [DllImport("userenv.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool GetUserProfileDirectory(IntPtr token,StringBuilder path,ref uint size);
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 public static string ProfileDirectory() { IntPtr token; if(!OpenProcessToken(GetCurrentProcess(),0x0008,out token)) throw new Win32Exception(Marshal.GetLastWin32Error()); try { uint size=0; GetUserProfileDirectory(token,null,ref size); StringBuilder b=new StringBuilder((int)size); if(!GetUserProfileDirectory(token,b,ref size)) throw new Win32Exception(Marshal.GetLastWin32Error()); return b.ToString(); } finally { CloseHandle(token); } }
}
'@ -ErrorAction Stop
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class Ticket569HostedCredentialV2 {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct CREDENTIAL { public uint Flags, Type; public string TargetName, Comment; public long LastWritten; public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist, AttributeCount; public IntPtr Attributes; public string TargetAlias, UserName; }
 [DllImport("advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredWrite(ref CREDENTIAL c,uint f);
 [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredRead(string t,uint type,uint f,out IntPtr c);
 [DllImport("advapi32.dll", EntryPoint="CredDeleteW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredDelete(string t,uint type,uint f);
 [DllImport("advapi32.dll")] static extern void CredFree(IntPtr c);
 public static bool Write(string target,string value) { byte[] bytes=Encoding.UTF8.GetBytes(value); IntPtr blob=Marshal.AllocHGlobal(bytes.Length); try { Marshal.Copy(bytes,0,blob,bytes.Length); CREDENTIAL c=new CREDENTIAL{Type=1,TargetName=target,CredentialBlobSize=(uint)bytes.Length,CredentialBlob=blob,Persist=2,UserName="ticket569-hosted-probe"}; if(!CredWrite(ref c,0)) throw new Win32Exception(Marshal.GetLastWin32Error()); return true; } finally { Marshal.FreeHGlobal(blob); } }
 public static bool ReadMatches(string target,string value) { IntPtr p; if(!CredRead(target,1,0,out p)) throw new Win32Exception(Marshal.GetLastWin32Error()); try { CREDENTIAL found=(CREDENTIAL)Marshal.PtrToStructure(p,typeof(CREDENTIAL)); byte[] actual=new byte[found.CredentialBlobSize]; Marshal.Copy(found.CredentialBlob,actual,0,actual.Length); return Encoding.UTF8.GetString(actual)==value; } finally { CredFree(p); } }
 public static int Delete(string target) { if(CredDelete(target,1,0)) return 0; return Marshal.GetLastWin32Error(); }
 public static int ReadError(string target) { IntPtr p; if(CredRead(target,1,0,out p)) { CredFree(p); return 0; } return Marshal.GetLastWin32Error(); }
}
'@ -ErrorAction Stop

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $process = Get-Process -Id $PID
    $admin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $profile = Get-CimInstance Win32_UserProfile -Filter "SID='$ExpectedSID'" -ErrorAction Stop
    $record.user = $identity.Name
    $record.sid = $identity.User.Value
    $record.sessionId = [int]$process.SessionId
    $record.admin = [bool]$admin
    $record.processCreationFileTimeUtc = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
    $record.windowStation = [Ticket569HostedProbe]::WindowStation()
    $record.desktop = [Ticket569HostedProbe]::Desktop()
    $record.userProfileApi = [Ticket569HostedProbe]::ProfileDirectory()
    if ($profile) {
        $record.profileLoaded = [bool]$profile.Loaded
        $record.profileSID = $profile.SID
        $record.profileLocalPath = $profile.LocalPath
        $record.profileHivePresent = Test-Path "Registry::HKEY_USERS\$ExpectedSID"
    }
    if ($record.sid -ne $ExpectedSID) { $record.conditions.Add('identity-sid-mismatch') }
    if ($record.sessionId -eq 0 -or !$record.userInteractive) { $record.conditions.Add('not-an-interactive-user-session') }
    if ($admin) { $record.conditions.Add('user-is-administrator') }
    if ($record.windowStation -ne 'WinSta0' -or $record.desktop -ne 'Default') { $record.conditions.Add('interactive-desktop-mismatch') }
    if (!$profile -or !$profile.Loaded -or $profile.LocalPath -ne $env:USERPROFILE -or $record.userProfileApi -ne $env:USERPROFILE -or !$record.profileHivePresent) { $record.conditions.Add('actual-loaded-profile-identity-mismatch') }

    $secret = [guid]::NewGuid().ToString('N')
    $credentialWritten = [Ticket569HostedCredentialV2]::Write($runCredentialTarget, $secret)
    $credentialWasWritten = [bool]$credentialWritten
    $credentialRead = [Ticket569HostedCredentialV2]::ReadMatches($runCredentialTarget, $secret)
    $record.credential = [ordered]@{ write=$credentialWritten; read=$true; bytesMatch=$credentialRead }

    if ($ProfileKind -eq 'mount-point') {
        $reparse = (& fsutil.exe reparsepoint query $env:USERPROFILE 2>&1 | Out-String)
        $reparseExit = $LASTEXITCODE
        $volume = (& mountvol.exe $env:USERPROFILE /L 2>&1 | Out-String).Trim()
        $volumeExit = $LASTEXITCODE
        $image = Get-DiskImage -ImagePath $VhdPath -ErrorAction Stop
        $volumes = @(Get-Partition -DiskNumber $image.Number -ErrorAction Stop | Get-Volume -ErrorAction Stop)
        $record.profileMount = [ordered]@{
            reparseTag = if ($reparseExit -eq 0 -and $reparse -match '0xa0000003') { '0xA0000003' } else { $null }
            fsutilExitCode = $reparseExit
            volumeGuid = if ($volumeExit -eq 0) { $volume } else { $null }
            mountvolExitCode = $volumeExit
            vhdPath = $image.ImagePath
            expectedVhdPath = $VhdPath
            attached = [bool]$image.Attached
            volumeMatchesVhd = [bool]($volumeExit -eq 0 -and $volumes | Where-Object { $_.UniqueId -eq $volume })
            filesystem = @($volumes | Select-Object -ExpandProperty FileSystem)
        }
        if ($record.profileMount.reparseTag -ne '0xA0000003' -or !$record.profileMount.attached -or !$record.profileMount.volumeMatchesVhd) { $record.conditions.Add('real-vhd-profile-identity-mismatch') }
    }
} catch {
    $record.conditions.Add("probe-exception:$($_.Exception.GetType().FullName):$($_.Exception.Message)")
} finally {
    if ($credentialWasWritten) {
        $deleteError = [Ticket569HostedCredentialV2]::Delete($runCredentialTarget)
        $readError = [Ticket569HostedCredentialV2]::ReadError($runCredentialTarget)
        if ($null -eq $record.credential) { $record.credential = [ordered]@{} }
        $record.credential.deleteError = $deleteError
        $record.credential.absenceReadError = $readError
        $record.credential.absentAfterCleanup = ($readError -eq 1168)
        if ($deleteError -notin @(0, 1168) -or $readError -ne 1168) { $record.cleanupErrors.Add("WinCred cleanup failed: CredDelete=$deleteError CredRead=$readError") }
    }
}

$record.completedAtUtc = [DateTime]::UtcNow.ToString('o')
$record.passed = ($record.conditions.Count -eq 0 -and $record.cleanupErrors.Count -eq 0 -and $record.credential.bytesMatch -and $record.credential.absentAfterCleanup)
try { Write-Atomic $OutputPath $record }
catch { [Console]::Error.WriteLine("final evidence write failed: $($_.Exception.Message)"); exit 2 }
if ($HoldAfterWriteSeconds -gt 0) { Start-Sleep -Seconds $HoldAfterWriteSeconds }
if (!$record.passed) { exit 1 }
exit 0
