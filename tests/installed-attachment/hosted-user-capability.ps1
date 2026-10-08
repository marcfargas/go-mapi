[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OutputPath,
    [Parameter(Mandatory)] [string] $RunId,
    [Parameter(Mandatory)] [string] $VhdPath,
    [ValidateSet('normal', 'mount-point')] [string] $ProfileKind
)

$ErrorActionPreference = 'Stop'
$transcriptPath = "$OutputPath.transcript.txt"
Start-Transcript -Path $transcriptPath -Force | Out-Null
trap {
    try { [IO.File]::WriteAllText("$OutputPath.error.txt", $_.ToString() + "`n", [Text.UTF8Encoding]::new($false)) } catch { }
    try { Stop-Transcript | Out-Null } catch { }
    exit 3
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$process = Get-Process -Id $PID
$profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $identity.User.Value
$profilePath = $env:USERPROFILE
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class Ticket569HostedProfile {
 [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
 [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
 [DllImport("userenv.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserProfileDirectory(IntPtr token, StringBuilder path, ref uint size);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 public static string Current() { IntPtr token; if(!OpenProcessToken(GetCurrentProcess(),8,out token)) throw new Win32Exception(Marshal.GetLastWin32Error()); try { uint size=0; GetUserProfileDirectory(token,null,ref size); if(size==0) throw new Win32Exception(Marshal.GetLastWin32Error()); StringBuilder path=new StringBuilder((int)size); if(!GetUserProfileDirectory(token,path,ref size)) throw new Win32Exception(Marshal.GetLastWin32Error()); return path.ToString(); } finally { CloseHandle(token); } }
}
'@
$profileApiPath = [Ticket569HostedProfile]::Current()
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$profileValid = $profile -and $profile.Loaded -and $profile.LocalPath -eq $profilePath
$sessionValid = $process.SessionId -gt 0 -and [Environment]::UserInteractive
$null = Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Ticket569HostedDesktop {
 [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
 [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint threadId);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("user32.dll", SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder value, int length, out int needed);
 static string Name(IntPtr handle) { int needed; GetUserObjectInformation(handle,2,null,0,out needed); if(needed<=0) return null; StringBuilder value=new StringBuilder(needed); if(!GetUserObjectInformation(handle,2,value,value.Capacity,out needed)) return null; return value.ToString(); }
 public static string WindowStation() { return Name(GetProcessWindowStation()); }
 public static string Desktop() { return Name(GetThreadDesktop(GetCurrentThreadId())); }
}
'@
$profileMount = $null
if ($ProfileKind -eq 'mount-point') {
    $reparse = (& fsutil.exe reparsepoint query $profilePath 2>&1 | Out-String)
    $volume = (& mountvol.exe $profilePath /L 2>&1 | Out-String).Trim()
    $image = Get-DiskImage -ImagePath $VhdPath -ErrorAction SilentlyContinue | Where-Object Attached | Select-Object -First 1
    $imageVolumes = if ($image) { @(Get-Partition -DiskNumber $image.Number | Get-Volume) } else { @() }
    $profileMount = [pscustomobject]@{
        ReparseTag = $(if ($LASTEXITCODE -eq 0 -and $reparse -match '0xa0000003') { '0xA0000003' } else { $null })
        Volume = $volume
        VhdPath = $(if ($image) { $image.ImagePath } else { $null })
        ExpectedVhdPath = $VhdPath
        Attached = [bool]($image -and $image.Attached)
        MatchesProfileVolume = [bool]($image -and $volume -and ($imageVolumes | Where-Object { $_.UniqueId -eq $volume }))
    }
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class Ticket569HostedCredential {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct CREDENTIAL { public uint Flags, Type; public string TargetName, Comment; public long LastWritten; public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist, AttributeCount; public IntPtr Attributes; public string TargetAlias, UserName; }
 [DllImport("advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredWrite(ref CREDENTIAL credential, uint flags);
 [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
 [DllImport("advapi32.dll", EntryPoint="CredDeleteW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredDelete(string target, uint type, uint flags);
 [DllImport("advapi32.dll")] static extern void CredFree(IntPtr credential);
 public static void RoundTrip(string target, string value) { byte[] bytes=Encoding.UTF8.GetBytes(value); IntPtr blob=Marshal.AllocHGlobal(bytes.Length); try { Marshal.Copy(bytes,0,blob,bytes.Length); CREDENTIAL c=new CREDENTIAL{Type=1,TargetName=target,CredentialBlobSize=(uint)bytes.Length,CredentialBlob=blob,Persist=2,UserName="ticket569-hosted-capability"}; if(!CredWrite(ref c,0)) throw new Win32Exception(Marshal.GetLastWin32Error()); IntPtr found; if(!CredRead(target,1,0,out found)) throw new Win32Exception(Marshal.GetLastWin32Error()); try { CREDENTIAL read=(CREDENTIAL)Marshal.PtrToStructure(found,typeof(CREDENTIAL)); byte[] actual=new byte[read.CredentialBlobSize]; Marshal.Copy(read.CredentialBlob,actual,0,actual.Length); if(Encoding.UTF8.GetString(actual)!=value) throw new Exception("WinCred round-trip bytes differ"); } finally { CredFree(found); } } finally { Marshal.FreeHGlobal(blob); } }
 public static bool Delete(string target) { if(CredDelete(target,1,0)) return true; return Marshal.GetLastWin32Error()==1168; }
 public static bool Absent(string target) { IntPtr credential; if(CredRead(target,1,0,out credential)) { CredFree(credential); return false; } return Marshal.GetLastWin32Error()==1168; }
}
'@

$runCredentialTarget = "ticket569-hosted-capability-$RunId"
$runCredentialValue = [guid]::NewGuid().ToString('N')
$credentialRoundTrip = $false
$credentialAbsent = $false
$certificateSubject = "CN=Ticket 569 hosted capability $RunId"
$certificateThumbprint = $null
$certificateCleanup = $false
$webView = @()
foreach ($key in @(
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
    'Registry::HKEY_CURRENT_USER\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
)) {
    if (Test-Path -LiteralPath $key) {
        $item = Get-ItemProperty -LiteralPath $key
        $webView += [pscustomobject]@{ Key = $key; Version = $item.pv; Path = $item.location }
    }
}
try {
    [Ticket569HostedCredential]::RoundTrip($runCredentialTarget, $runCredentialValue)
    $credentialRoundTrip = $true
} finally {
    $null = [Ticket569HostedCredential]::Delete($runCredentialTarget)
    $credentialAbsent = [Ticket569HostedCredential]::Absent($runCredentialTarget)
}
try {
    $certificate = New-SelfSignedCertificate -Subject $certificateSubject -CertStoreLocation Cert:\CurrentUser\Root -NotAfter (Get-Date).AddHours(1)
    $certificateThumbprint = $certificate.Thumbprint
    $found = @(Get-ChildItem Cert:\CurrentUser\Root | Where-Object Subject -eq $certificateSubject)
    if ($found.Count -ne 1 -or $found[0].Thumbprint -ne $certificateThumbprint) { throw 'Current-user certificate store readback mismatch' }
} finally {
    if ($certificateThumbprint) { Remove-Item -LiteralPath "Cert:\CurrentUser\Root\$certificateThumbprint" -Force -ErrorAction SilentlyContinue }
    $certificateCleanup = @(Get-ChildItem Cert:\CurrentUser\Root | Where-Object Subject -eq $certificateSubject).Count -eq 0
}

$form = [Windows.Forms.Form]::new()
$form.Text = "Ticket569 hosted capability $RunId $ProfileKind"
$form.Width = 360
$form.Height = 120
$form.StartPosition = 'CenterScreen'
$form.add_Shown({
    $record = [ordered]@{
        RunId = $RunId
        ProfileKind = $ProfileKind
        User = $identity.Name
        SID = $identity.User.Value
        SessionId = [int]$process.SessionId
        ProcessId = [int]$process.Id
        InteractiveSession = [bool]$sessionValid
        Admin = [bool]$isAdmin
        UserInteractive = [bool][Environment]::UserInteractive
        WindowStation = [Ticket569HostedDesktop]::WindowStation()
        Desktop = [Ticket569HostedDesktop]::Desktop()
        UserProfile = $profilePath
        UserProfileApi = $profileApiPath
        ProfileApiMatchesEnvironment = ($profileApiPath -eq $profilePath)
        ProfileLoaded = [bool]$profileValid
        ProfileSID = $profile.SID
        ProfileLocalPath = $profile.LocalPath
        ProfileHivePresent = Test-Path "Registry::HKEY_USERS\$($identity.User.Value)"
        WindowTitle = $form.Text
        VisibleWindow = [bool]$form.Visible
        CredentialRoundTrip = $credentialRoundTrip
        CredentialAbsent = $credentialAbsent
        CurrentUserTrustRoundTrip = [bool]$certificateThumbprint
        SyntheticRootAbsent = $certificateCleanup
        WebView2 = $webView
        ProfileMount = $profileMount
        At = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText($OutputPath, (ConvertTo-Json -InputObject $record -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
})
$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 8000
$timer.add_Tick({ $timer.Stop(); $form.Close() })
$timer.Start()
[Windows.Forms.Application]::Run($form)

$result = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
$null = Stop-Transcript
$passed = $result.SessionId -gt 0 -and $result.InteractiveSession -and $result.UserInteractive -and !$result.Admin -and $result.ProfileLoaded -and
    $result.ProfileApiMatchesEnvironment -and $result.ProfileSID -eq $result.SID -and $result.ProfileHivePresent -and
    $result.CredentialRoundTrip -and $result.CredentialAbsent -and $result.CurrentUserTrustRoundTrip -and $result.SyntheticRootAbsent -and
    $result.VisibleWindow -and $result.WindowStation -eq 'WinSta0' -and $result.Desktop -eq 'Default' -and $result.WebView2.Count -gt 0
if ($ProfileKind -eq 'mount-point') {
    $passed = $passed -and $result.ProfileMount.ReparseTag -eq '0xA0000003' -and $result.ProfileMount.Attached -and $result.ProfileMount.MatchesProfileVolume
}
if (!$passed) { exit 2 }
exit 0
