[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceSHA,
    [Parameter(Mandatory)] [string] $EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$started = [DateTime]::UtcNow
$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$testTrustScript = Join-Path $sourceRoot 'scripts\azure-test-signing-trust.ps1'
$testTrustStatePath = Join-Path $EvidenceDirectory 'azure-test-root.json'
$testTrustPrepared = $false
$runId = [guid]::NewGuid().ToString('N')
$runRoot = 'C:\crabbox\work\ticket569'
$packageRoot = Join-Path $EvidenceDirectory 'alpha9'
$testUserName = 't569' + $runId.Substring(0, 10)
$user = $null
$credential = $null
$profilePath = Join-Path 'C:\Users' $testUserName
$vhdPath = Join-Path $runRoot ("profile-$runId.vhdx")
$backupPath = $profilePath + '.normal-backup'
$profileState = 'normal'
$profileRestored = $true
$cleanupErrors = [Collections.Generic.List[string]]::new()
$steps = [Collections.Generic.List[object]]::new()
$conditions = [Collections.Generic.List[string]]::new()
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

function Write-Atomic([string] $Path, $Value) {
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 12) + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Record-Step([string] $Name, [string] $Status, $Evidence = $null, [int] $ExitCode = 0) {
    $steps.Add([pscustomobject]@{ Name = $Name; Status = $Status; ExitCode = $ExitCode; Evidence = $Evidence; At = [DateTime]::UtcNow.ToString('o') })
    Write-Atomic (Join-Path $EvidenceDirectory 'hosted-capability-steps.json') @($steps)
}

function Invoke-StandardUserProbe([string] $ProfileKind) {
    $outputPath = Join-Path $EvidenceDirectory ("user-$ProfileKind.json")
    $script = Join-Path $PSScriptRoot 'hosted-user-capability.ps1'
    $taskName = "Ticket569-$runId-$ProfileKind"
    $taskOutput = "`"$outputPath`""
    $taskRunId = "`"$runId`""
    $taskVhdPath = "`"$vhdPath`""
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $windowsPowerShell -Argument "-NoProfile -STA -ExecutionPolicy Bypass -File `"$script`" -OutputPath $taskOutput -RunId $taskRunId -ProfileKind $ProfileKind -VhdPath $taskVhdPath"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$testUserName" -LogonType Interactive -RunLevel Limited
    $process = $null
    $windowObserved = $false
    $screenshot = $null
    $exitCode = -1
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        $deadline = [DateTime]::UtcNow.AddSeconds(35)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $outputPath -PathType Leaf) { $windowObserved = $true; break }
            Start-Sleep -Milliseconds 200
        }
        if ($windowObserved) {
            try {
                Add-Type -AssemblyName System.Drawing
                $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
                $bitmap = [Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                $graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size)
                $screenshot = Join-Path $EvidenceDirectory ("user-$ProfileKind-desktop.png")
                $bitmap.Save($screenshot, [Drawing.Imaging.ImageFormat]::Png)
                $graphics.Dispose(); $bitmap.Dispose()
            } catch { $conditions.Add("desktop screenshot unavailable: $($_.Exception.GetType().Name)") }
            $taskDeadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName
                if ($taskInfo.LastRunTime -gt [DateTime]::MinValue -and (Get-ScheduledTask -TaskName $taskName).State -ne 'Running') { break }
                Start-Sleep -Milliseconds 200
            } while ([DateTime]::UtcNow -lt $taskDeadline)
            if ($taskInfo.LastRunTime -gt [DateTime]::MinValue) { $exitCode = [int]$taskInfo.LastTaskResult }
        }
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $result = $null
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        try { $result = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json } catch { $conditions.Add("$ProfileKind user evidence JSON is malformed") }
    }
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    $taskState = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($taskInfo -and $taskInfo.LastRunTime -gt [DateTime]::MinValue) { $exitCode = [int]$taskInfo.LastTaskResult }
    $taskEvidence = [pscustomobject]@{ TaskName = $taskName; State = [string]$taskState.State; LastRunTime = $taskInfo.LastRunTime; LastTaskResult = $taskInfo.LastTaskResult; ResultFileObserved = $windowObserved }
    $wts = if ($result -and $result.SessionId -gt 0) { Get-WtsSessionIdentity ([int]$result.SessionId) } else { $null }
    if ($result) { $result | Add-Member -NotePropertyName WtsSession -NotePropertyValue $wts -Force; $result | Add-Member -NotePropertyName ScheduledTask -NotePropertyValue $taskEvidence -Force }
    Record-Step "standard-user-$ProfileKind-interactive-token-task" $(if ($exitCode -eq 0 -and $result -and $windowObserved) { 'observed' } else { 'condition-unmet' }) @{ Result = $result; Task = $taskEvidence; ErrorLog = "$outputPath.error.txt"; Transcript = "$outputPath.transcript.txt" } $exitCode
    if ($screenshot) { Record-Step "standard-user-$ProfileKind-desktop" 'observed' @{ Path = $screenshot; WindowTitle = $result.WindowTitle } $exitCode }
    return [pscustomobject]@{ ExitCode = $exitCode; Evidence = $result; WindowObserved = $windowObserved; ProcessId = $(if ($result) { $result.ProcessId } else { $null }) }
}

function Connect-LoopbackRdp([string] $AccountName, [Security.SecureString] $Password) {
    $result = [ordered]@{ Server = '127.0.0.1'; ClientProgId = 'MsTscAx.MsTscAx.10'; ConnectHRESULT = $null; OnLoginComplete = $false; EventObservedAt = $null; WtsSession = $null; Condition = $null }
    $client = $null
    $subscription = $null
    try {
        $rdpUsers = Get-LocalGroup -SID 'S-1-5-32-555'
        $members = @(Get-LocalGroupMember -Group $rdpUsers -ErrorAction Stop)
        if ($members.SID.Value -notcontains $script:user.SID.Value) {
            Add-LocalGroupMember -Group $rdpUsers -Member $AccountName -ErrorAction Stop
        }
        Record-Step 'grant-disposable-user-rdp-logon-group' 'observed' @{ GroupSID = $rdpUsers.SID.Value; UserSID = $script:user.SID.Value }
        $client = New-Object -ComObject $result.ClientProgId -ErrorAction Stop
        $subscription = Register-ObjectEvent -InputObject $client -EventName OnLoginComplete -SourceIdentifier "Ticket569-$runId-RdpLogin" -ErrorAction Stop
        $client.Server = '127.0.0.1'
        $client.Domain = $env:COMPUTERNAME
        $client.UserName = $script:user.Name
        $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try { $client.AdvancedSettings9.ClearTextPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer) }
        $client.Connect()
        try { $client.AdvancedSettings9.ClearTextPassword = '' } catch { }
        $result.ConnectHRESULT = '0x00000000'
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $deadline) {
            $event = Get-Event -SourceIdentifier "Ticket569-$runId-RdpLogin" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($event) {
                $result.OnLoginComplete = $true
                $result.EventObservedAt = [DateTime]::UtcNow.ToString('o')
                Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
            }
            if ($result.OnLoginComplete) { break }
            Start-Sleep -Milliseconds 200
        }
        if (!$result.OnLoginComplete) { $result.Condition = 'RDP client Connect returned, but documented OnLoginComplete event was not observed within 30 seconds' }
        else {
            $result.WtsSession = Find-WtsSessionForSid $script:user.SID.Value
            if (!$result.WtsSession) { $result.Condition = 'OnLoginComplete fired but no Active WTS session was independently owned by the disposable user SID' }
        }
    } catch {
        $hresult = [uint32]$_.Exception.HResult
        $result.ConnectHRESULT = ('0x{0:X8}' -f $hresult)
        $result.Condition = $_.Exception.Message
    } finally {
        if ($subscription) { Unregister-Event -SourceIdentifier "Ticket569-$runId-RdpLogin" -ErrorAction SilentlyContinue }
    }
    Record-Step 'loopback-rdp-standard-user-sign-in' $(if ($result.OnLoginComplete -and $result.WtsSession) { 'observed' } else { 'condition-unmet' }) $result
    return [pscustomobject]@{ Evidence = [pscustomobject]$result; Client = $client }
}

function Get-WtsSessionIdentity([int] $SessionId) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Ticket569Wts {
 [DllImport("Wtsapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool WTSQuerySessionInformation(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytes);
 [DllImport("Wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr memory);
 static string Get(int sessionId,int infoClass) { IntPtr value; int bytes; if(!WTSQuerySessionInformation(IntPtr.Zero,sessionId,infoClass,out value,out bytes)) return null; try { return Marshal.PtrToStringUni(value); } finally { WTSFreeMemory(value); } }
 public static string User(int id) { return Get(id,5); }
 public static string Domain(int id) { return Get(id,7); }
 public static int State(int id) { IntPtr value; int bytes; if(!WTSQuerySessionInformation(IntPtr.Zero,id,8,out value,out bytes)) return -1; try { return Marshal.ReadInt32(value); } finally { WTSFreeMemory(value); } }
}
'@ -ErrorAction SilentlyContinue
    $name = [Ticket569Wts]::User($SessionId)
    $domain = [Ticket569Wts]::Domain($SessionId)
    $sid = $null
    if ($name) { try { $sid = ([Security.Principal.NTAccount]"$domain\$name").Translate([Security.Principal.SecurityIdentifier]).Value } catch { } }
    $stateCode = [Ticket569Wts]::State($SessionId)
    $state = switch ($stateCode) { 0 { 'Active' } 1 { 'Connected' } 2 { 'ConnectQuery' } 3 { 'Shadow' } 4 { 'Disconnected' } 5 { 'Idle' } 6 { 'Listen' } 7 { 'Reset' } 8 { 'Down' } 9 { 'Init' } default { 'Unknown' } }
    return [pscustomobject]@{ SessionId = $SessionId; User = $name; Domain = $domain; SID = $sid; StateCode = $stateCode; State = $state }
}

function Find-WtsSessionForSid([string] $SID) {
    foreach ($process in @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue)) {
        if (!$process.UserName -or $process.SessionId -le 0) { continue }
        try { $processSid = ([Security.Principal.NTAccount]$process.UserName).Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
        if ($processSid -ne $SID) { continue }
        $session = Get-WtsSessionIdentity ([int]$process.SessionId)
        if ($session.SID -eq $SID -and $session.State -eq 'Active') { return $session }
    }
    return $null
}

function Wait-ProfileUnloaded([string] $SID, [int] $SessionId) {
    if ($SessionId -gt 0) {
        $wts = Get-WtsSessionIdentity $SessionId
        $owners = @(Get-Process -IncludeUserName | Where-Object { $_.SessionId -eq $SessionId -and $_.UserName } | ForEach-Object {
            try { ([Security.Principal.NTAccount]$_.UserName).Translate([Security.Principal.SecurityIdentifier]).Value } catch { $null }
        })
        if ($wts.SID -eq $SID -and $SID -in $owners) { & logoff.exe $SessionId; $exit = $LASTEXITCODE; if ($exit -ne 0) { throw "exact observed standard-user logoff exited $exit" } }
        Record-Step 'wts-session-owner-before-profile-unload' 'observed' @{ SessionId = $SessionId; WTS = $wts; ProcessesIncludeSID = ($SID -in $owners) }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 500
        $profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $SID
    } while ($profile -and $profile.Loaded -and [DateTime]::UtcNow -lt $deadline)
    if (!$profile -or $profile.Loaded -or (Test-Path "Registry::HKEY_USERS\$SID")) { throw 'The exact standard-user profile or hive remained loaded after observed session exit' }
    Record-Step 'profile-unloaded' 'observed' @{ SID = $SID; SessionId = $SessionId; Loaded = $false; HiveAbsent = $true }
}

try {
    if ($SourceSHA -notmatch '^[0-9a-f]{40}$') { throw 'SourceSHA must be an exact 40-character Git commit ID' }
    $head = (& git -C $sourceRoot rev-parse HEAD).Trim().ToLowerInvariant()
    $status = (& git -C $sourceRoot status --porcelain --untracked-files=all | Out-String).Trim()
    if ($head -ne $SourceSHA.ToLowerInvariant() -or $head -ne $env:GITHUB_SHA.ToLowerInvariant() -or $status) { throw 'Hosted capability probe requires the exact clean workflow and checked-out source SHA' }
    $os = Get-CimInstance Win32_OperatingSystem
    $hostIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $hostProcess = Get-Process -Id $PID
    $sessionQuery = (& query.exe session 2>&1 | Out-String)
    $sessionQueryExit = $LASTEXITCODE
    $serviceInventory = foreach ($serviceName in @('TermService', 'Schedule', 'seclogon')) {
        $service = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
        if ($service) { [pscustomobject]@{ Name = $service.Name; State = $service.State; StartMode = $service.StartMode; StartName = $service.StartName; ExitCode = $service.ExitCode } }
    }
    $rdpDenied = (Get-ItemProperty 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    $rdpListener = @(Get-NetTCPConnection -State Listen -LocalPort 3389 -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, State, OwningProcess)
    $hostWindow = $null
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Ticket569HostDesktop {
 [DllImport("user32.dll")] static extern IntPtr GetProcessWindowStation();
 [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint id);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("user32.dll", SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr handle,int index,StringBuilder value,int length,out int needed);
 static string Name(IntPtr handle) { int needed; GetUserObjectInformation(handle,2,null,0,out needed); if(needed<=0)return null; StringBuilder value=new StringBuilder(needed); if(!GetUserObjectInformation(handle,2,value,value.Capacity,out needed))return null; return value.ToString(); }
 public static string WindowStation() { return Name(GetProcessWindowStation()); }
 public static string Desktop() { return Name(GetThreadDesktop(GetCurrentThreadId())); }
}
'@ -ErrorAction Stop
        $hostWindow = @{ WindowStation = [Ticket569HostDesktop]::WindowStation(); Desktop = [Ticket569HostDesktop]::Desktop() }
    } catch { $hostWindow = @{ Error = $_.Exception.Message; HRESULT = ('0x{0:X8}' -f [uint32]$_.Exception.HResult) } }
    $job = [ordered]@{
        SourceSHA = $head
        WorkflowSHA = $env:GITHUB_SHA
        RunnerOS = $env:ImageOS
        RunnerImageVersion = $env:ImageVersion
        RunnerName = $env:RUNNER_NAME
        RunnerLabel = 'windows-2025'
        ComputerName = $env:COMPUTERNAME
        OSName = $os.Caption
        OSVersion = $os.Version
        OSBuild = $os.BuildNumber
        HostUser = $hostIdentity.Name
        HostSID = $hostIdentity.User.Value
        HostGroups = @($hostIdentity.Groups | ForEach-Object { $_.Value })
        HostSessionId = $hostProcess.SessionId
        HostIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        HostAuthenticationType = $hostIdentity.AuthenticationType
        HostIsSystem = $hostIdentity.IsSystem
        UserInteractive = [Environment]::UserInteractive
        HostWindow = $hostWindow
        WtsSessionInventory = $sessionQuery
        WtsSessionInventoryExitCode = $sessionQueryExit
        RdpAndTaskServices = @($serviceInventory)
        RdpConnectionsDeniedPolicy = $rdpDenied
        ExistingRdpListeners = $rdpListener
        Docs = @('https://docs.github.com/actions/using-github-hosted-runners/about-github-hosted-runners', 'https://github.com/actions/runner-images')
        StartedAt = $started.ToString('o')
    }
    Write-Atomic (Join-Path $EvidenceDirectory 'hosted-image.json') $job
    Record-Step 'host-image-and-workflow-identity' 'observed' $job

    $releaseDir = Join-Path $EvidenceDirectory 'suite-alpha9-release'
    New-Item -ItemType Directory -Path $releaseDir | Out-Null
    & gh release download suite-v3.2.0-alpha.9 --repo marcfargas/go-mapi --dir $releaseDir
    $ghExit = $LASTEXITCODE
    if ($ghExit -ne 0) { Record-Step 'download-immutable-alpha9-assets' 'unknown-setup-failure' $null $ghExit; throw 'GitHub alpha.9 asset download failed; this is not a runner capability verdict' }
    $proofPath = Join-Path $releaseDir 'suite-3.2.0-alpha.9.validation.json'
    $msiPath = Join-Path $releaseDir 'go-mapi-suite-3.2.0-alpha.9-x64.msi'
    if (!(Test-Path $proofPath) -or !(Test-Path $msiPath)) { throw 'Immutable alpha.9 suite MSI or release proof asset is missing' }
    $proof = Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json
    $expectedPackageCommit = '497798ddb1c243c6ab5c97f6ac1cdf6645b89267'
    if ($proof.commit -cne $expectedPackageCommit -or $proof.sku -cne 'suite' -or $proof.packageRelease -cne '3.2.0-alpha.9' -or
        $proof.tag -cne 'suite-v3.2.0-alpha.9' -or $proof.msi.sha256 -notmatch '^[a-f0-9]{64}$' -or
        (Get-FileHash $msiPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $proof.msi.sha256) {
        throw 'Immutable alpha.9 package source/tag/bytes do not match the spike identity'
    }
    $appSource = $proof.componentSources.app
    $appPart = @($proof.peHashes | Where-Object { $_.component -eq 'app' -and $_.architecture -eq 'x64' })
    $dllPart = @($proof.peHashes | Where-Object { $_.component -eq 'interceptor' -and $_.architecture -eq 'x64' })
    if ($appSource.commit -cne $expectedPackageCommit -or $appPart.Count -ne 1 -or $dllPart.Count -ne 1) { throw 'Alpha.9 installed app/DLL source provenance is incomplete' }
    $appPath = Join-Path $env:ProgramFiles 'go-mapi\user\go-mapi.exe'
    $dllPath = Join-Path $env:ProgramFiles 'go-mapi\interceptor\AMD64\go-mapi.dll'
    & $testTrustScript -Mode Prepare -StatePath $testTrustStatePath -SignedFiles @($msiPath)
    $testTrustPrepared = $true
    $testTrust = Get-Content -LiteralPath $testTrustStatePath -Raw | ConvertFrom-Json
    if ($testTrust.schema -cne 'go-mapi-azure-test-root-fixture-v1' -or
        $testTrust.certificateSha256 -cne '41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e' -or
        $testTrust.store -cne 'LocalMachine/Root') {
        throw 'Alpha.9 MSI signing trust state does not match the pinned Azure TEST ONLY root'
    }
    Record-Step 'prepare-alpha9-msi-test-root-trust' 'observed' @{ StatePath = $testTrustStatePath; CertificateSHA256 = $testTrust.certificateSha256; Store = $testTrust.store; Preexisting = $testTrust.preexisting; ImportAttempted = $testTrust.importAttempted; Imported = $testTrust.imported }
    $msiSignature = Get-AuthenticodeSignature -LiteralPath $msiPath
    if ($msiSignature.Status -ne 'Valid') { throw 'Immutable alpha.9 suite MSI does not have a valid Authenticode signature' }
    $msiResult = Start-Process -FilePath msiexec.exe -ArgumentList @('/i', $msiPath, '/qn', 'GOMAPI_AUTO_UPDATE=0', '/norestart') -PassThru -Wait
    Record-Step 'install-immutable-alpha9-suite' $(if ($msiResult.ExitCode -eq 0) { 'observed' } else { 'condition-unmet' }) @{ SourceCommit = $expectedPackageCommit; MSIPath = $msiPath; MSISHA256 = $proof.msi.sha256; Signature = [string]$msiSignature.Status; MSIExitCode = [int]$msiResult.ExitCode }
    if ($msiResult.ExitCode -ne 0) { throw "Alpha.9 MSI install exited $($msiResult.ExitCode); no capability conclusion is made" }
    foreach ($record in @(@{ Path = $appPath; Hash = $appPart[0].signedSha256 }, @{ Path = $dllPath; Hash = $dllPart[0].signedSha256 })) {
        if (!(Test-Path -LiteralPath $record.Path -PathType Leaf) -or (Get-FileHash -LiteralPath $record.Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.Hash) { throw "Installed alpha.9 component did not match immutable release provenance: $($record.Path)" }
    }
    Record-Step 'verify-installed-alpha9-bytes' 'observed' @{ AppSHA256 = $appPart[0].signedSha256; X64DllSHA256 = $dllPart[0].signedSha256; SourceCommit = $expectedPackageCommit }

    $webViewSetup = Join-Path $sourceRoot 'src\installer\MicrosoftEdgeWebview2Setup.exe'
    if (!(Test-Path -LiteralPath $webViewSetup -PathType Leaf)) { throw 'Source-pinned Microsoft WebView2 bootstrapper is absent' }
    $webViewSignature = Get-AuthenticodeSignature -LiteralPath $webViewSetup
    if ($webViewSignature.Status -ne 'Valid' -or $webViewSignature.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'Source-pinned WebView2 bootstrapper does not carry a valid Microsoft signature' }
    $webViewHash = (Get-FileHash -LiteralPath $webViewSetup -Algorithm SHA256).Hash.ToLowerInvariant()
    $webViewProcess = Start-Process -FilePath $webViewSetup -ArgumentList @('/silent', '/install') -PassThru -Wait
    Record-Step 'install-microsoft-webview2-runtime' $(if ($webViewProcess.ExitCode -eq 0) { 'observed' } else { 'condition-unmet' }) @{ SHA256 = $webViewHash; Signature = [string]$webViewSignature.Status; Signer = $webViewSignature.SignerCertificate.Subject; ExitCode = [int]$webViewProcess.ExitCode } ([int]$webViewProcess.ExitCode)
    if ($webViewProcess.ExitCode -ne 0) { throw "Microsoft WebView2 setup exited $($webViewProcess.ExitCode); no capability conclusion is made" }

    $random = [byte[]]::new(36)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($random)
    $passwordText = 'T569!' + [Convert]::ToBase64String($random).Replace('=', 'Z') + 'a1'
    $securePassword = ConvertTo-SecureString $passwordText -AsPlainText -Force
    $passwordText = $null
    [Array]::Clear($random, 0, $random.Length)
    $rng.Dispose()
    $user = New-LocalUser -Name $testUserName -Password $securePassword -PasswordNeverExpires -AccountNeverExpires -Description 'Disposable Ticket 569 hosted capability probe'
    $administrators = Get-LocalGroup -SID 'S-1-5-32-544'
    $adminMembers = @(Get-LocalGroupMember -Group $administrators -ErrorAction Stop)
    $isAdminMember = $adminMembers.SID.Value -contains $user.SID.Value
    if ($isAdminMember) { throw 'Disposable standard user unexpectedly belongs to local Administrators' }
    $evidenceAcl = Get-Acl -LiteralPath $EvidenceDirectory
    $evidenceInheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $evidenceRule = [Security.AccessControl.FileSystemAccessRule]::new($user.SID, [Security.AccessControl.FileSystemRights]::Modify, $evidenceInheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    $evidenceAcl.SetAccessRule($evidenceRule)
    Set-Acl -LiteralPath $EvidenceDirectory -AclObject $evidenceAcl
    Record-Step 'grant-disposable-user-evidence-directory-access' 'observed' @{ Path = $EvidenceDirectory; UserSID = $user.SID.Value; Rights = 'Modify'; Inheritance = 'ContainerInherit,ObjectInherit' }
    Record-Step 'create-disposable-standard-user' 'observed' @{ Name = $testUserName; SID = $user.SID.Value; AdministratorsGroupSID = $administrators.SID.Value; AdminGroupMember = $isAdminMember }

    $rdpLogin = Connect-LoopbackRdp "$env:COMPUTERNAME\$testUserName" $securePassword
    if (!$rdpLogin.Evidence.OnLoginComplete -or !$rdpLogin.Evidence.WtsSession -or $rdpLogin.Evidence.WtsSession.SID -ne $user.SID.Value -or $rdpLogin.Evidence.WtsSession.State -ne 'Active') {
        $conditions.Add('an owned standard-user RDP sign-in was not proven by OnLoginComplete and exact active WTS SID/session evidence')
    } else {
    $normalProbe = Invoke-StandardUserProbe 'normal'
    if ($normalProbe.Evidence) {
        $session = [int]$normalProbe.Evidence.SessionId
        Wait-ProfileUnloaded $user.SID.Value $session
        $normalIdentity = $normalProbe.Evidence
    if ($normalProbe.ExitCode -ne 0 -or $normalIdentity.Admin -or !$normalIdentity.UserInteractive -or
            $normalIdentity.WindowStation -ne 'WinSta0' -or $normalIdentity.Desktop -ne 'Default' -or
            $normalIdentity.UserProfile -ne $profilePath -or $normalIdentity.WtsSession.SID -ne $normalIdentity.SID -or
            $normalIdentity.WtsSession.State -ne 'Active' -or $normalIdentity.SID -ne $user.SID.Value) {
            $conditions.Add('the created standard-user process did not prove a real non-admin interactive profile on WinSta0\\Default')
        } else {
            $profileState = 'preparing'
            & (Join-Path $PSScriptRoot 'profile.ps1') -Action prepare-vhd -SID $user.SID.Value -ProfilePath $profilePath -VhdPath $vhdPath -BackupPath $backupPath -EvidenceDirectory (Join-Path $EvidenceDirectory 'profile-vhd-prepare')
            $prepareExit = $LASTEXITCODE
            Record-Step 'mount-actual-user-profile-vhd' $(if ($prepareExit -eq 0) { 'observed' } else { 'condition-unmet' }) @{ ExitCode = $prepareExit; Profile = $profilePath; Vhd = $vhdPath } $prepareExit
            if ($prepareExit -ne 0) { throw "VHD profile preparation exited $prepareExit" }
            $profileState = 'mounted'
            if ($rdpLogin.Client) { try { $rdpLogin.Client.Disconnect() } catch { $conditions.Add("prior RDP session disconnect before mounted-profile sign-in failed: $($_.Exception.Message)") } }
            $rdpLogin = Connect-LoopbackRdp "$env:COMPUTERNAME\$testUserName" $securePassword
            if (!$rdpLogin.Evidence.OnLoginComplete -or !$rdpLogin.Evidence.WtsSession -or $rdpLogin.Evidence.WtsSession.SID -ne $user.SID.Value -or $rdpLogin.Evidence.WtsSession.State -ne 'Active') {
                throw 'The same disposable user did not re-sign in through loopback RDP after actual profile VHD attachment'
            }
            $mountedProbe = Invoke-StandardUserProbe 'mount-point'
            if ($mountedProbe.Evidence) {
                Wait-ProfileUnloaded $user.SID.Value ([int]$mountedProbe.Evidence.SessionId)
                if ($mountedProbe.ExitCode -ne 0 -or $mountedProbe.Evidence.UserProfile -ne $profilePath -or
                    $mountedProbe.Evidence.ProfileMount.ReparseTag -ne '0xA0000003' -or
                    !$mountedProbe.Evidence.ProfileMount.Attached -or !$mountedProbe.Evidence.ProfileMount.MatchesProfileVolume) {
                    $conditions.Add('the same standard-user SID did not prove its actual VHD volume mounted at its USERPROFILE')
                }
            }
            & (Join-Path $PSScriptRoot 'profile.ps1') -Action restore-normal -SID $user.SID.Value -ProfilePath $profilePath -VhdPath $vhdPath -BackupPath $backupPath -EvidenceDirectory (Join-Path $EvidenceDirectory 'profile-restore')
            $restoreExit = $LASTEXITCODE
            if ($restoreExit -ne 0) { throw "normal profile restoration exited $restoreExit" }
            $profileState = 'normal'
            $profileRestored = $true
            Record-Step 'restore-actual-user-normal-profile' 'observed' @{ ExitCode = $restoreExit; Profile = $profilePath; VhdRemoved = !(Test-Path $vhdPath) } $restoreExit
        }
    } else {
        $conditions.Add('standard-user process did not produce identity/session/desktop evidence')
    }
    }
} catch {
    $failure = $_.ToString()
    $conditions.Add("probe stopped: $failure")
} finally {
    if ($user) {
        try {
            if ($rdpLogin -and $rdpLogin.Client) { try { $rdpLogin.Client.Disconnect() } catch { $cleanupErrors.Add("loopback RDP client disconnect failed: $($_.Exception.Message)") } }
            $profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $user.SID.Value
            if ($profile -and $profile.Loaded) {
                $userProcesses = @(Get-Process -IncludeUserName | Where-Object {
                    if (!$_.UserName) { return $false }
                    try { return (([Security.Principal.NTAccount]$_.UserName).Translate([Security.Principal.SecurityIdentifier]).Value -eq $user.SID.Value) } catch { return $false }
                })
                $sessionIds = @($userProcesses | Select-Object -ExpandProperty SessionId -Unique | Where-Object { $_ -gt 0 })
                foreach ($sessionId in $sessionIds) {
                    $wts = Get-WtsSessionIdentity ([int]$sessionId)
                    if ($wts.SID -ne $user.SID.Value) { throw "Refusing cleanup logoff: WTS session $sessionId is not owned by the disposable SID" }
                    & logoff.exe $sessionId
                    if ($LASTEXITCODE -ne 0) { throw "exact disposable-user session $sessionId logoff exited $LASTEXITCODE" }
                }
                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                do { Start-Sleep -Milliseconds 250; $profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $user.SID.Value } while ($profile -and $profile.Loaded -and [DateTime]::UtcNow -lt $deadline)
                if ($profile -and $profile.Loaded) { throw 'Disposable user profile remained loaded after exact-session logoff' }
            }
            if ($profile -and $profile.Loaded) {
                $unload = Invoke-CimMethod -InputObject $profile -MethodName Unload
                if ($unload.ReturnValue -ne 0) { throw "Win32_UserProfile.Unload returned $($unload.ReturnValue)" }
                Start-Sleep -Milliseconds 500
            }
            if ($profileState -in @('preparing', 'mounted')) {
                & (Join-Path $PSScriptRoot 'profile.ps1') -Action restore-normal -SID $user.SID.Value -ProfilePath $profilePath -VhdPath $vhdPath -BackupPath $backupPath -EvidenceDirectory (Join-Path $EvidenceDirectory 'profile-restore')
                if ($LASTEXITCODE -ne 0) { throw "profile restore exited $LASTEXITCODE" }
                $profileState = 'normal'
            }
            $profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $user.SID.Value
            if ($profile -and $profile.Loaded) { throw 'Disposable user profile is still loaded at cleanup' }
            if ($profile) { Remove-CimInstance -InputObject $profile }
            Remove-LocalUser -SID $user.SID
            $profileRestored = $profileState -eq 'normal' -and !(Test-Path -LiteralPath $vhdPath) -and !(Test-Path -LiteralPath $backupPath)
            Record-Step 'delete-disposable-user-and-profile' 'observed' @{ UserSID = $user.SID.Value; ProfileRestored = $profileRestored }
        } catch { $cleanupErrors.Add("hosted probe cleanup failed: $($_.Exception.Message)") }
    }
    if (Test-Path -LiteralPath $testTrustStatePath -PathType Leaf) {
        try {
            $testTrust = Get-Content -LiteralPath $testTrustStatePath -Raw | ConvertFrom-Json
            & $testTrustScript -Mode Cleanup -StatePath $testTrustStatePath
            $rootPath = "Cert:\LocalMachine\Root\$($testTrust.thumbprint)"
            $rootPresentAfterCleanup = Test-Path -LiteralPath $rootPath
            if ($testTrust.preexisting -and -not $rootPresentAfterCleanup) { throw 'Preexisting Azure TEST root was removed during probe cleanup' }
            if ($testTrust.importAttempted -and -not $testTrust.preexisting -and $rootPresentAfterCleanup) { throw 'Owned Azure TEST root remains after probe cleanup' }
            if (-not (Test-Path -LiteralPath $testTrustStatePath -PathType Leaf)) { throw 'Azure TEST signing ownership state disappeared during cleanup' }
            $testTrustAfter = Get-Content -LiteralPath $testTrustStatePath -Raw | ConvertFrom-Json
            if ($testTrustAfter.schema -cne $testTrust.schema -or $testTrustAfter.thumbprint -cne $testTrust.thumbprint -or
                $testTrustAfter.certificateSha256 -cne $testTrust.certificateSha256 -or $testTrustAfter.preexisting -ne $testTrust.preexisting -or
                $testTrustAfter.importAttempted -ne $testTrust.importAttempted) { throw 'Azure TEST signing ownership state changed during cleanup' }
            Record-Step 'cleanup-alpha9-msi-test-root-trust' 'observed' @{ StatePath = $testTrustStatePath; Preexisting = $testTrust.preexisting; ImportAttempted = $testTrust.importAttempted; RootPresentAfterCleanup = $rootPresentAfterCleanup }
        } catch {
            $cleanupErrors.Add("Azure TEST signing trust cleanup failed: $($_.Exception.Message)")
            try { Record-Step 'cleanup-alpha9-msi-test-root-trust' 'condition-unmet' @{ StatePath = $testTrustStatePath; Error = $_.Exception.Message } 1 } catch { $cleanupErrors.Add("Azure TEST signing trust cleanup evidence write failed: $($_.Exception.Message)") }
        }
    } elseif ($testTrustPrepared) {
        $message = 'Azure TEST signing trust preparation completed but its ownership state is missing; cleanup is unverified'
        $cleanupErrors.Add($message)
        try { Record-Step 'cleanup-alpha9-msi-test-root-trust' 'condition-unmet' @{ StatePath = $testTrustStatePath; Error = $message } 1 } catch { $cleanupErrors.Add("Azure TEST signing trust cleanup evidence write failed: $($_.Exception.Message)") }
    } else {
        Record-Step 'cleanup-alpha9-msi-test-root-trust' 'not-needed' @{ StateFileCreated = $false }
    }
    if ($securePassword) { $securePassword.Dispose() }
    $report = [ordered]@{
        schemaVersion = 1
        sourceSHA = $(if ($job) { $job.SourceSHA } else { $SourceSHA })
        workflowSHA = $env:GITHUB_SHA
        package = @{ tag = 'suite-v3.2.0-alpha.9'; sourceCommit = '497798ddb1c243c6ab5c97f6ac1cdf6645b89267'; use = 'capability-only' }
        verdict = 'capability-unknown-until-observed'
        hostedCapabilities = @{}
        conditions = @($conditions)
        steps = @($steps)
        testTrust = if (Test-Path -LiteralPath $testTrustStatePath -PathType Leaf) { Get-Content -LiteralPath $testTrustStatePath -Raw | ConvertFrom-Json } else { $null }
        cleanup = @{ ProfileRestored = $profileRestored; Errors = @($cleanupErrors) }
        completedAt = [DateTime]::UtcNow.ToString('o')
    }
    $capabilityFiles = Get-ChildItem -LiteralPath $EvidenceDirectory -Filter 'user-*.json' -File -ErrorAction SilentlyContinue
    foreach ($file in $capabilityFiles) {
        try {
            $value = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $report.hostedCapabilities[$value.ProfileKind] = $value
        } catch { $conditions.Add("malformed observation $($file.Name)") }
    }
    if ($cleanupErrors.Count -gt 0 -or !$profileRestored) {
        $report.verdict = 'capability-unknown-cleanup-failed'
    } elseif ($report.hostedCapabilities['normal'] -and $report.hostedCapabilities['mount-point']) {
        $normal = $report.hostedCapabilities.normal
        $mounted = $report.hostedCapabilities['mount-point']
        if ($normal.SessionId -gt 0 -and !$normal.Admin -and $normal.UserInteractive -and $normal.WindowStation -eq 'WinSta0' -and $normal.Desktop -eq 'Default' -and
            $mounted.ProfileMount.ReparseTag -eq '0xA0000003' -and $mounted.ProfileMount.Attached -and $mounted.ProfileMount.MatchesProfileVolume -and $mounted.UserProfile -eq $normal.UserProfile) {
            $report.verdict = 'hosted-standard-user-and-actual-vhd-profile-path-observed'
        } else { $report.verdict = 'hosted-capability-condition-unmet-with-observed-evidence' }
    } elseif ($conditions.Count -gt 0) { $report.verdict = 'capability-unknown-setup-or-observation-incomplete' }
    try { Write-Atomic (Join-Path $EvidenceDirectory 'hosted-capability-final.json') $report } catch { $cleanupErrors.Add("final evidence write failed: $($_.Exception.Message)") }
    if ($cleanupErrors.Count -gt 0) { exit 1 }
}
