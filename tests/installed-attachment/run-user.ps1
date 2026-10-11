[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RunRoot,
    [Parameter(Mandatory)] [string] $ExpectedJson,
    [Parameter(Mandatory)] [string] $AppPath,
    [Parameter(Mandatory)] [string] $X64DllPath,
    [Parameter(Mandatory)] [string] $FakeBinary,
    [ValidateSet('normal', 'mount-point')] [string] $ProfileKind,
    [string] $ExpectedProfilePath = $env:USERPROFILE,
    [string] $ExpectedVhdPath,
    [switch] $RecordCandidateFailure
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'Continue'
$runError = $null
$app = $null
$fake = $null
$certificate = $null
$credWasWritten = $false
$credentialAttempted = $false
$runId = [IO.Path]::GetFileName($RunRoot)
$certificateSubject = "CN=Ticket 569 synthetic CA $runId"
$control = $null
$appWasKilled = $false
$queue = Join-Path $env:LOCALAPPDATA 'go-mapi\queue'
$initialQueue = @()
$initialQueueKnown = $false
$queueWatcher = $null
$queueEventRegistrations = @()
$ErrorFile = Join-Path $RunRoot 'transaction-error.json'

function Write-AtomicJson([string] $Path, $Value) {
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $json = ConvertTo-Json -InputObject $Value -Depth 12
    [IO.File]::WriteAllText($temp, $json + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-QueueInventory([string] $Path) {
    if (!(Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force | ForEach-Object {
        [pscustomobject]@{ RelativePath = $_.FullName.Substring($Path.Length).TrimStart('\'); Length = $_.Length; SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
}

function Assert-RealInteractiveProfile {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $session = (Get-Process -Id $PID).SessionId
    $admin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($session -eq 0) { throw 'Session0 cannot satisfy the interactive installed-app test' }
    if ($admin) { throw 'The MAPI caller must be a standard user' }
    if ($env:USERPROFILE -ne $ExpectedProfilePath) { throw 'USERPROFILE does not match the observed real user profile path' }
    $profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $identity.User.Value
    if (!$profile -or !$profile.Loaded -or $profile.LocalPath -ne $env:USERPROFILE) { throw 'Windows did not report the signed-in SID profile as loaded at USERPROFILE' }
    $item = Get-Item -LiteralPath $env:USERPROFILE -Force
    $reparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($ProfileKind -eq 'mount-point' -and !$reparse) { throw 'The actual profile folder is not a mounted volume path' }
    if ($ProfileKind -eq 'normal' -and $reparse) { throw 'The normal profile unexpectedly resolves through a reparse point' }
    $tag = $null
    $volume = $null
    $disk = $null
    if ($ProfileKind -eq 'mount-point') {
        $reparseText = (& fsutil.exe reparsepoint query $env:USERPROFILE 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $reparseText -notmatch '0xa0000003') { throw 'The profile mount point is not the required volume mount-point reparse tag' }
        $tag = '0xA0000003'
        $volume = (& mountvol.exe $env:USERPROFILE /L 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or !$volume) { throw 'Could not resolve the mounted profile volume GUID' }
        if (!$ExpectedVhdPath) { throw 'Mounted profile verification requires the exact owned VHD path' }
        $image = Get-DiskImage -ImagePath $ExpectedVhdPath -ErrorAction Stop
        if (!$image.Attached) { throw 'The expected owned profile VHDX is not attached' }
        $partitions = @(Get-Partition -DiskNumber $image.Number)
        $volumes = @($partitions | Get-Volume)
        $disk = [pscustomobject]@{ ImagePath = $image.ImagePath; Number = $image.Number; Attached = $image.Attached }
        $volumePath = $volume.TrimEnd('\')
        if (!(@($volumes | Where-Object { $_.Path -and $_.Path.TrimEnd('\') -ieq $volumePath }).Count)) {
            throw 'The USERPROFILE mount volume does not belong to the exact expected VHD image partitions'
        }
    }
    return [pscustomobject]@{ User = $identity.Name; SID = $identity.User.Value; SessionId = $session; PID = $PID; Admin = $admin; UserProfile = $env:USERPROFILE; LocalPath = $profile.LocalPath; Loaded = [bool]$profile.Loaded; ProfileKind = $ProfileKind; ReparseTag = $tag; Volume = $volume; Vhd = $disk }
}

function Import-RunScopedCertificate([string] $CertPath, [string] $Subject) {
    $encodedPath = $CertPath.Replace("'", "''")
    $importCommand = "`$ErrorActionPreference='Stop'; Import-Certificate -FilePath '$encodedPath' -CertStoreLocation 'Cert:\CurrentUser\Root' | Out-Null; exit 0"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($importCommand))
    $import = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand) -PassThru
    if (!$import.WaitForExit(90000)) { Stop-Process -Id $import.Id -Force -ErrorAction SilentlyContinue; throw 'Certificate import child timed out before CUA confirmation' }
    $import.Refresh()
    if ($import.ExitCode -ne 0) { throw "Certificate import child exited $($import.ExitCode)" }
    Write-AtomicJson (Join-Path $RunRoot 'trust-import-exit.json') @{ PID = $import.Id; ExitCode = [int]$import.ExitCode; Subject = $Subject }
}

try {
    if (!(Test-Path -LiteralPath $RunRoot -PathType Container)) { throw 'Run output directory must be created before the interactive process starts' }
    if (Get-ChildItem -LiteralPath $RunRoot -Force | Measure-Object | Select-Object -ExpandProperty Count) { throw 'Run output directory is not empty' }
    if (!(Test-Path $ExpectedJson -PathType Leaf) -or !(Test-Path $AppPath -PathType Leaf) -or !(Test-Path $X64DllPath -PathType Leaf)) { throw 'Expected draft or installed app/DLL is missing' }
    $expect = Get-Content -LiteralPath $ExpectedJson -Raw | ConvertFrom-Json
    if ($expect.runId -ne $runId) { throw 'Expected draft runId does not match the unique output directory' }
    $profile = Assert-RealInteractiveProfile
    Write-AtomicJson (Join-Path $RunRoot 'profile-before.json') $profile
    $initialQueue = @(Get-QueueInventory $queue)
    $initialQueueKnown = $true
    if ($initialQueue.Count -ne 0) { throw 'The isolated queue has preexisting files' }
    New-Item -ItemType Directory -Path $queue -Force | Out-Null
    $queueEventsPath = Join-Path $RunRoot 'queue-events.txt'
    $queueWatcher = [IO.FileSystemWatcher]::new($queue)
    $queueWatcher.IncludeSubdirectories = $true
    $queueWatcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::DirectoryName -bor [IO.NotifyFilters]::LastWrite
    $queueWatcher.EnableRaisingEvents = $true
    foreach ($eventName in @('Created', 'Deleted', 'Renamed')) {
        $sourceId = "Ticket569Queue$runId$eventName"
        $queueEventRegistrations += Register-ObjectEvent -InputObject $queueWatcher -EventName $eventName -SourceIdentifier $sourceId -MessageData $queueEventsPath -Action {
            $change = $Event.SourceEventArgs.ChangeType.ToString()
            $name = $Event.SourceEventArgs.Name
            Add-Content -LiteralPath $Event.MessageData -Value "$change|$name"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $env:APPDATA 'go-mapi\app.log') -PathType Leaf) { throw 'Disposable profile already has an app log; refusing to collect or overwrite it' }
    $existingCredential = & cmdkey.exe /list:go-mapi:oauth-tokens 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $existingCredential -match 'Target:') { throw 'A go-mapi credential already exists in this disposable profile' }

    if (!(Test-Path $FakeBinary -PathType Leaf)) { throw 'The prebuilt fake-gmail test helper is missing' }
    $fake = Start-Process -FilePath $FakeBinary -ArgumentList @('--root', $RunRoot, '--expected', $ExpectedJson) -PassThru -WindowStyle Hidden
    $readyPath = Join-Path $RunRoot 'fake-ready.json'
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (!(Test-Path $readyPath) -and [DateTime]::UtcNow -lt $readyDeadline) {
        $fake.Refresh()
        if ($fake.HasExited) { throw "Fake exited before readiness with code $($fake.ExitCode)" }
        Start-Sleep -Milliseconds 100
    }
    if (!(Test-Path $readyPath)) { throw 'Fake readiness timed out' }
    $ready = Get-Content $readyPath -Raw | ConvertFrom-Json
    if ($ready.runId -ne $runId -or $ready.pid -ne $fake.Id -or $ready.address -notlike '127.0.0.1:*') { throw 'Fake readiness identity/bind did not match this run' }
    $control = Get-Content (Join-Path $RunRoot 'fake-control.json') -Raw | ConvertFrom-Json
    $certPath = Join-Path $RunRoot 'test-ca.pem'
    Import-RunScopedCertificate $certPath $certificateSubject
    $certificate = Get-ChildItem Cert:\CurrentUser\Root | Where-Object Subject -eq $certificateSubject
    if (@($certificate).Count -ne 1) { throw 'Expected exactly one run-specific synthetic CA certificate' }
    $certificate = @($certificate)[0]
    if ($certificate.Subject -notlike "*Ticket 569 synthetic CA $runId*" -or $certificate.HasPrivateKey) { throw 'Imported trust does not match the exact public-only run CA' }
    Write-AtomicJson (Join-Path $RunRoot 'trust-identity.json') @{ RunId = $runId; Subject = $certificate.Subject; Thumbprint = $certificate.Thumbprint; FakeSHA256 = $ready.caThumbprintSHA256 }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Ticket569Native {
 [DllImport("kernel32.dll", EntryPoint="LoadLibraryW", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr LoadLibrary(string path);
 [DllImport("kernel32.dll", EntryPoint="GetProcAddress", CharSet=CharSet.Ansi, SetLastError=true)] static extern IntPtr GetProcAddress(IntPtr module, string name);
 [DllImport("kernel32.dll", EntryPoint="FreeLibrary", SetLastError=true)] static extern bool FreeLibrary(IntPtr module);
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct Cred { public uint Flags, Type; public string TargetName, Comment; public long LastWritten; public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist, AttributeCount; public IntPtr Attributes; public string TargetAlias, UserName; }
 [DllImport("advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredWrite(ref Cred credential, uint flags);
 [DllImport("advapi32.dll", EntryPoint="CredDeleteW", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool CredDelete(string target, uint type, uint flags);
 [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
 [DllImport("advapi32.dll")] static extern void CredFree(IntPtr buffer);
 public static void Write(string target, string value) { byte[] bytes=Encoding.UTF8.GetBytes(value); IntPtr p=Marshal.AllocHGlobal(bytes.Length); try { Marshal.Copy(bytes,0,p,bytes.Length); Cred c=new Cred{Type=1,TargetName=target,CredentialBlobSize=(uint)bytes.Length,CredentialBlob=p,Persist=2,UserName="oauth-tokens"}; if(!CredWrite(ref c,0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); } finally { Marshal.FreeHGlobal(p); } }
 public static bool Exists(string target) { IntPtr p; if(CredRead(target,1,0,out p)) { CredFree(p); return true; } return Marshal.GetLastWin32Error()!=1168; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)] public struct Recip { public uint reserved, recipClass; public string name, address; public uint entrySize; public IntPtr entry; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)] public struct FileDesc { public uint reserved, flags, position; public string path, name; public IntPtr type; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)] public struct Message { public uint reserved; public string subject, note, messageType, date, conversation; public uint flags; public IntPtr originator; public uint recipCount; public IntPtr recips; public uint fileCount; public IntPtr files; }
 public static uint Send(string dllPath, string root) { IntPtr dll=LoadLibrary(dllPath); if(dll==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); IntPtr proc=GetProcAddress(dll,"MAPISendMail"); if(proc==IntPtr.Zero){FreeLibrary(dll);throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());} var send=(SendMail)Marshal.GetDelegateForFunctionPointer(proc,typeof(SendMail)); Recip recip=new Recip{recipClass=1,name="Synthetic 569",address="SMTP:test@example.invalid"}; IntPtr rp=Marshal.AllocHGlobal(Marshal.SizeOf(recip)); int size=Marshal.SizeOf(typeof(FileDesc)); IntPtr fp=Marshal.AllocHGlobal(size*2); try { Marshal.StructureToPtr(recip,rp,false); string[] names={"report.txt","image.bin"}; for(int i=0;i<2;i++){ FileDesc f=new FileDesc{position=0xffffffff,path=System.IO.Path.Combine(root,names[i]),name=names[i]}; Marshal.StructureToPtr(f,IntPtr.Add(fp,size*i),false); } Message m=new Message{subject="Ticket569 installed Windows seam",note="Synthetic body",recipCount=1,recips=rp,fileCount=2,files=fp}; return send(UIntPtr.Zero,UIntPtr.Zero,ref m,0,0); } finally { Marshal.DestroyStructure(rp,typeof(Recip)); Marshal.FreeHGlobal(rp); for(int i=0;i<2;i++) Marshal.DestroyStructure(IntPtr.Add(fp,size*i),typeof(FileDesc)); Marshal.FreeHGlobal(fp); FreeLibrary(dll); } }
 [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet=CharSet.Ansi)] delegate uint SendMail(UIntPtr session, UIntPtr ui, ref Message message, uint flags, uint reserved);
}
'@
    $token = @{ access_token = 'synthetic-569-not-a-real-token'; refresh_token = 'synthetic-unused'; token_type = 'Bearer'; expiry = [DateTime]::UtcNow.AddHours(3).ToString('yyyy-MM-ddTHH:mm:ssZ') } | ConvertTo-Json -Compress
    $credentialAttempted = $true
    [Ticket569Native]::Write('go-mapi:oauth-tokens', $token)
    $credWasWritten = $true
    $credExists = [Ticket569Native]::Exists('go-mapi:oauth-tokens')
    if (!$credExists) { throw 'WinCred readback did not find the synthetic token' }
    $settingsDir = Join-Path $env:APPDATA 'go-mapi'
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $settingsDir 'settings.json'), '{"mode":"auto-draft","autostart_enabled":false,"update_checks_enabled":false,"default_apps_prompted":true}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes((Join-Path $RunRoot 'report.txt'), [Text.Encoding]::UTF8.GetBytes("exact attachment`r`nwith bytes`0"))
    [IO.File]::WriteAllBytes((Join-Path $RunRoot 'image.bin'), [byte[]]@(0,1,2,253,254,255))

    $env:HTTPS_PROXY = "http://$($ready.address)"
    $env:HTTP_PROXY = $env:HTTPS_PROXY
    $env:NO_PROXY = ''
    $env:no_proxy = ''
    $app = Start-Process -FilePath $AppPath -PassThru -WorkingDirectory $RunRoot
    if ($app.Path -ne $AppPath) { throw 'Started app path differs from the installed suite app' }
    $appHash = (Get-FileHash -LiteralPath $AppPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $dllHash = (Get-FileHash -LiteralPath $X64DllPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-AtomicJson (Join-Path $RunRoot 'installed-app.json') @{ PID = $app.Id; SessionId = $app.SessionId; Path = $app.Path; SHA256 = $appHash; DLL = $X64DllPath; DLLSHA256 = $dllHash; AppArguments = @() }

    $userInfoDeadline = [DateTime]::UtcNow.AddSeconds(90)
    $userInfoSeen = $false
    while ([DateTime]::UtcNow -lt $userInfoDeadline) {
        $app.Refresh()
        if ($app.HasExited) { throw "Installed app exited before userinfo with code $($app.ExitCode)" }
        try {
            $headers = @{ 'X-Test-Control' = $control.token }
            $status = Invoke-RestMethod -Method Get -Uri "http://$($control.address)/status" -Headers $headers -TimeoutSec 3
            if ($status.failed) { throw 'Fake rejected an unexpected request before native MAPI' }
            if ($status.userInfoRequests -ge 1) { $userInfoSeen = $true; break }
        } catch { if ($_.Exception.Message -like 'Fake rejected*') { throw } }
        Start-Sleep -Milliseconds 200
    }
    if (!$userInfoSeen) { throw 'Installed app did not contact the isolated fake within 90 seconds' }
    Write-AtomicJson (Join-Path $RunRoot 'app-ready.json') @{ PID = $app.Id; SessionId = $app.SessionId; UserInfoObserved = $true; At = [DateTime]::UtcNow.ToString('o') }
    $mapiCode = [Ticket569Native]::Send($X64DllPath, $RunRoot)
    Write-AtomicJson (Join-Path $RunRoot 'mapi-result.json') @{ Return = $mapiCode; CallerPID = $PID; CallerSession = (Get-Process -Id $PID).SessionId; DllPath = $X64DllPath; DllSHA256 = $dllHash; At = [DateTime]::UtcNow.ToString('o') }
    if ($mapiCode -ne 0) { throw "Installed MAPI returned $mapiCode" }

    $draftDeadline = [DateTime]::UtcNow.AddSeconds(90)
    $draftObserved = $false
    while ([DateTime]::UtcNow -lt $draftDeadline) {
        $headers = @{ 'X-Test-Control' = $control.token }
        $status = Invoke-RestMethod -Method Get -Uri "http://$($control.address)/status" -Headers $headers -TimeoutSec 3
        if ($status.failed) { throw 'Fake latched a failed or rejected request' }
        if ($status.acceptedDrafts -gt 0) { $draftObserved = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (!$draftObserved) { throw 'No exact synthetic draft was observed before timeout' }
    $queueBeforeStop = @(Get-QueueInventory $queue)
    $drainDeadline = [DateTime]::UtcNow.AddSeconds(30)
    $queueDrained = $false
    while ([DateTime]::UtcNow -lt $drainDeadline) {
        $app.Refresh()
        if ($app.HasExited) { throw 'Installed app exited before terminal queue acknowledgement' }
        $queueNow = @(Get-QueueInventory $queue)
        $events = @()
        if (Test-Path -LiteralPath $queueEventsPath) { $events = @(Get-Content -LiteralPath $queueEventsPath) }
        $created = @($events | Where-Object { $_ -match '^(Created|Renamed)\|' })
        $deleted = @($events | Where-Object { $_ -match '^Deleted\|' })
        if ($created.Count -gt 0 -and $deleted.Count -gt 0 -and $queueNow.Count -eq 0) { $queueDrained = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (!$queueDrained) { throw 'Accepted draft did not reach terminal queue processing acknowledgement before timeout' }
    $queueBeforeStop = @(Get-QueueInventory $queue)
    Write-AtomicJson (Join-Path $RunRoot 'queue-before-stop.json') @{ files = $queueBeforeStop; terminalAcknowledgement = $queueDrained; events = @(Get-Content -LiteralPath $queueEventsPath) }

} catch {
    $runError = $_.ToString()
} finally {
    foreach ($registration in $queueEventRegistrations) { Unregister-Event -SubscriptionId $registration.Id -ErrorAction SilentlyContinue }
    if ($queueWatcher) { $queueWatcher.EnableRaisingEvents = $false; $queueWatcher.Dispose() }
    $appExit = $null
    if ($app) {
        $app.Refresh()
        if (!$app.HasExited) {
            Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
            $appWasKilled = $true
        }
        $app.WaitForExit(15000) | Out-Null
        $app.Refresh()
        if ($app.HasExited) { $appExit = [int]$app.ExitCode }
        Write-AtomicJson (Join-Path $RunRoot 'app-exit.json') @{ PID = $app.Id; HasExited = [bool]$app.HasExited; ExitCode = $appExit; ForcedTermination = $appWasKilled }
    }
    if ($control -and $fake) {
        try { Invoke-RestMethod -Method Post -Uri "http://$($control.address)/shutdown" -Headers @{ 'X-Test-Control' = $control.token } -TimeoutSec 5 | Out-Null } catch { if (!$runError) { $runError = "Fake graceful stop failed: $_" } }
        $fake.WaitForExit(15000) | Out-Null
        $fake.Refresh()
        if (!$fake.HasExited) { Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue; $fake.WaitForExit(5000) | Out-Null; if (!$runError) { $runError = 'Fake did not stop after bounded drain' } }
        $fake.Refresh()
        Write-AtomicJson (Join-Path $RunRoot 'fake-exit.json') @{ PID = $fake.Id; HasExited = [bool]$fake.HasExited; ExitCode = $(if ($fake.HasExited) { [int]$fake.ExitCode } else { $null }) }
    } elseif ($fake) {
        $fake.Refresh()
        if (!$fake.HasExited) {
            Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue
            $fake.WaitForExit(5000) | Out-Null
        }
        $fake.Refresh()
        Write-AtomicJson (Join-Path $RunRoot 'fake-exit.json') @{ PID = $fake.Id; HasExited = [bool]$fake.HasExited; ExitCode = $(if ($fake.HasExited) { [int]$fake.ExitCode } else { $null }); ForcedTermination = $true }
    }
    if ($fake -and $fake.HasExited -and $fake.ExitCode -ne 0 -and !$runError) { $runError = "Fake exited $($fake.ExitCode)" }
    $fakeFinalPath = Join-Path $RunRoot 'fake-final.json'
    $final = $null
    if (Test-Path $fakeFinalPath) { try { $final = Get-Content $fakeFinalPath -Raw | ConvertFrom-Json } catch { if (!$runError) { $runError = 'Fake final result is truncated or malformed' } } }
    if (!$final -and !$runError) { $runError = 'Fake final result is absent' }
    if ($final -and (!$final.final -or $final.runId -ne $runId -or $final.failed -or $final.errors.Count -ne 0 -or $final.rejectedRequests -ne 0 -or $final.draftAttempts -ne 1 -or $final.acceptedDrafts -ne 1 -or $final.drafts.Count -ne 1)) { if (!$runError) { $runError = 'Fake final one-draft oracle failed' } }
    $queueAfter = @()
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    if ($initialQueueKnown) {
        try { $queueAfter = @(Get-QueueInventory $queue); Write-AtomicJson (Join-Path $RunRoot 'queue-after-stop.json') @{ files = $queueAfter; inspected = $true } } catch { if (!$runError) { $runError = "Queue final scan failed: $_" } }
        if ($queueAfter.Count -ne 0 -and !$runError) { $runError = 'Queue retained a pending message or attachment file after the app stopped' }
    } else {
        Write-AtomicJson (Join-Path $RunRoot 'queue-after-stop.json') @{ files = @(); inspected = $false }
    }
    if ($initialQueueKnown -and (Test-Path -LiteralPath $queue)) {
        try {
            $queueArchive = Join-Path $RunRoot 'queue-final'
            Copy-Item -LiteralPath $queue -Destination $queueArchive -Recurse -Force
            Write-AtomicJson (Join-Path $RunRoot 'queue-archive.json') @{ Source = $queue; Destination = $queueArchive; InitiallyEmpty = ($initialQueue.Count -eq 0); ArchivedFiles = @(Get-QueueInventory $queueArchive) }
            if ($initialQueue.Count -eq 0) {
                Get-ChildItem -LiteralPath $queue -Force | Remove-Item -Recurse -Force
                if (@(Get-QueueInventory $queue).Count -ne 0) { $cleanupErrors.Add('isolated synthetic queue could not be cleared after archival') }
            }
        } catch { $cleanupErrors.Add("isolated queue archive/cleanup failed: $_") }
    }
    if ($credentialAttempted) {
        $deleted = [Ticket569Native]::CredDelete('go-mapi:oauth-tokens', 1, 0)
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if (!$deleted -and $lastError -ne 1168) { $cleanupErrors.Add("CredDeleteW failed with $lastError") }
        if ([Ticket569Native]::Exists('go-mapi:oauth-tokens')) { $cleanupErrors.Add('synthetic WinCred remains') }
    }
    $runCertificates = @(Get-ChildItem Cert:\CurrentUser\Root | Where-Object Subject -eq $certificateSubject)
    foreach ($runCertificate in $runCertificates) {
        Remove-Item -LiteralPath "Cert:\CurrentUser\Root\$($runCertificate.Thumbprint)" -ErrorAction SilentlyContinue
    }
    if (@(Get-ChildItem Cert:\CurrentUser\Root | Where-Object Subject -eq $certificateSubject).Count -ne 0) {
        $cleanupErrors.Add('exact synthetic root remains in CurrentUser Root')
    }
    if ($app -and (Get-Process -Id $app.Id -ErrorAction SilentlyContinue)) { $cleanupErrors.Add('installed app process remains') }
    if ($fake -and (Get-Process -Id $fake.Id -ErrorAction SilentlyContinue)) { $cleanupErrors.Add('fake process remains') }
    $appLogPath = Join-Path $env:APPDATA 'go-mapi\app.log'
    if ($app -and (Test-Path -LiteralPath $appLogPath -PathType Leaf)) {
        try {
            Copy-Item -LiteralPath $appLogPath -Destination (Join-Path $RunRoot 'app.log') -ErrorAction Stop
            Remove-Item -LiteralPath $appLogPath -Force -ErrorAction Stop
        } catch { $cleanupErrors.Add("Per-case app log archive/removal failed: $_") }
    }
    $credentialAbsent = $true
    if ($credentialAttempted) { $credentialAbsent = ![Ticket569Native]::Exists('go-mapi:oauth-tokens') }
    $syntheticRootAbsent = @(Get-ChildItem Cert:\CurrentUser\Root | Where-Object Subject -eq $certificateSubject).Count -eq 0
    Write-AtomicJson (Join-Path $RunRoot 'cleanup.json') @{ Completed = ($cleanupErrors.Count -eq 0); Errors = @($cleanupErrors); CredentialAbsent = $credentialAbsent; SyntheticRootAbsent = $syntheticRootAbsent; QueueWasInspected = $initialQueueKnown; AppExit = $appExit; AppForcedTermination = $appWasKilled }
    if ($cleanupErrors.Count -gt 0) { $runError = 'Cleanup failure overrides transaction result: ' + ($cleanupErrors -join '; ') }
    if ($runError) { try { Write-AtomicJson $ErrorFile @{ RunId = $runId; Failed = $true; Error = $runError; At = [DateTime]::UtcNow.ToString('o') } } catch {} }
}

if ($runError) {
    Write-Error $runError
    exit 1
}
Write-AtomicJson (Join-Path $RunRoot 'transaction-final.json') @{ RunId = $runId; Passed = $true; Profile = $ProfileKind; At = [DateTime]::UtcNow.ToString('o') }
exit 0
