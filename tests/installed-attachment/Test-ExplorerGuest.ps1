param($InputDirectory,$OutputDirectory)
$ErrorActionPreference='Stop'
if ($env:GOMAPI_SANDBOX -ne '1') { throw 'Run this installer journey only through the owned Windows Sandbox entrypoint' }
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if (!([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Guest setup requires its existing elevated token' }
$work='C:\go-mapi-smoke'
$localInput=Join-Path $work 'input'
# Retain logs as they are written, including when the outer deadline disposes
# the guest before this script can reach its finally block.
$localOutput=Join-Path $OutputDirectory 'smoke'
$errors=[Collections.Generic.List[string]]::new()
$receipt=[ordered]@{passed=$false;phase='starting';pid=$PID;error=$null;user=$null;installed=$false;removed=$false;trustRemoved=$false;userStopped=$false;cleanupErrors=@()}
$startedAt=Get-Date
$trust=[Collections.Generic.List[string]]::new()
$installAttempted=$false;$user=$null;$job=$null;$launcher=$null;$launchOut=$null;$launchErr=$null
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Save-SetupReceipt([string]$Phase, [switch]$BestEffort) {
    $receipt.phase=$Phase
    try { $receipt | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutputDirectory 'installed-smoke-setup.json') }
    catch {
        if (!$BestEffort) { throw }
        $errors.Add('setup receipt '+$Phase+': '+$_.Exception.Message)
    }
}
Save-SetupReceipt 'starting'
function Assert-ProductionSignature([string]$Path) {
    $sig=Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid' -or !$sig.SignerCertificate -or !$sig.TimeStamperCertificate) { throw ('Default Windows signing trust failed: '+$Path) }
    [ordered]@{file=$Path;sha256=(Hash $Path);status=$sig.Status.ToString();subject=$sig.SignerCertificate.Subject;signer=$sig.SignerCertificate.Thumbprint;timestamp=$sig.TimeStamperCertificate.Thumbprint} | ConvertTo-Json -Compress | Add-Content (Join-Path $localOutput 'signatures.ndjson')
}
function Msi([string]$Operation) {
    $log=Join-Path $localOutput $(if ($Operation -eq '/i') {'install.log'} else {'uninstall.log'})
    $process=Start-Process msiexec.exe -ArgumentList @($Operation,('"'+$msi+'"'),'/qn','/norestart','GOMAPI_AUTO_UPDATE=0','/l*v',('"'+$log+'"')) -WindowStyle Hidden -PassThru
    $null=$process.Handle
    try { if (!$process.WaitForExit(180000)) { $process.Kill();$null=$process.WaitForExit(5000);throw 'MSI exceeded three minutes' }; if ($process.ExitCode -ne 0) { throw ('MSI exit '+$process.ExitCode) } } finally { $process.Dispose() }
}
try {
    if ((Test-Path -LiteralPath $work) -or (Get-Service go-mapi -ErrorAction SilentlyContinue)) { throw 'Guest workspace or product already exists' }
    New-Item -ItemType Directory -Path $localInput,$localOutput -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $InputDirectory 'Test-Attachment.ps1'),(Join-Path $InputDirectory 'Invoke-Attachment.ps1'),(Join-Path $InputDirectory 'Attachment.psm1'),(Join-Path $InputDirectory 'AttachmentNative.cs'),(Join-Path $InputDirectory 'fake-gmail.exe'),(Join-Path $InputDirectory 'machine-test-packages.json'),(Join-Path $InputDirectory 'ExplorerSendTo.ps1'),(Join-Path $InputDirectory 'suite.msi') -Destination $localInput
    & icacls.exe $work /grant ('*'+$identity.User.Value+':(OI)(CI)M') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Guest-only workspace ACL grant failed' }
    $msi=Join-Path $localInput 'suite.msi'
    $manifestPath=Join-Path $localInput 'machine-test-packages.json'
    $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ((Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.packages.suiteC.sha256) { throw 'Selected MSI hash differs' }
    $manifest.packages.suiteC.msi=$msi
    $manifest | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $manifestPath
    $webView=@(Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\*','HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\*','HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\*' -ErrorAction SilentlyContinue | Where-Object { $_.name -like '*WebView2*' -and $_.pv -and $_.pv -ne '0.0.0.0' })
    # Wails' Go loader reads 32-bit EdgeUpdate ClientState/EBWebView, not
    # Clients name/pv. These observations alone cannot establish availability;
    # the exact installed app's bounded smoke remains the runtime proof.
    $clientState=@(Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\*','HKCU:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\*','HKCU:\SOFTWARE\Microsoft\EdgeUpdate\ClientState\*' -ErrorAction SilentlyContinue | Where-Object EBWebView | Select-Object EBWebView,PSPath)
    @{clients=@($webView | Select-Object name,pv,PSPath);clientState=$clientState;availability='unproven until exact installed app smoke'} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $localOutput 'webview2.json')
    Add-Type -Path (Join-Path $localInput 'AttachmentNative.cs')
    @'
$ErrorActionPreference='Stop'
$root='C:\go-mapi-smoke'
$output='C:\output\smoke'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$process=Get-Process -Id $PID
$state=@{sid=$identity.User.Value;profile=$env:USERPROFILE;session=$process.SessionId;createdTicks=$process.StartTime.ToUniversalTime().Ticks;pid=$PID;admin=([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
$state | ConvertTo-Json | Set-Content (Join-Path $output 'user-started.json')
try {
    if ($state.admin -or $state.session -le 0) { throw 'SAFER child is not an ordinary desktop token' }
    $deadline=[DateTime]::UtcNow.AddSeconds(240)
    while (!(Test-Path (Join-Path $root 'user-go'))) { if ([DateTime]::UtcNow -ge $deadline) { throw 'Guest setup did not release the user gate' }; Start-Sleep -Milliseconds 200 }
    & C:\go-mapi-smoke\input\Test-Attachment.ps1 -Manifest C:\go-mapi-smoke\input\machine-test-packages.json -FakeBinary C:\go-mapi-smoke\input\fake-gmail.exe -OutputDirectory $output -EntryPoint Explorer
    @{passed=$true} | ConvertTo-Json | Set-Content (Join-Path $output 'user-result.json')
} catch { @{passed=$false;error=$_.Exception.Message} | ConvertTo-Json | Set-Content (Join-Path $output 'user-result.json');exit 1 }
'@ | Set-Content -LiteralPath (Join-Path $work 'Run-User.ps1')
    $launcher=[Diagnostics.Process]::new()
    $launcher.StartInfo=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:WINDIR 'System32\runas.exe'),'/trustlevel:0x20000 "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\go-mapi-smoke\Run-User.ps1"')
    $launcher.StartInfo.UseShellExecute=$false;$launcher.StartInfo.CreateNoWindow=$true
    $launcher.StartInfo.RedirectStandardOutput=$true;$launcher.StartInfo.RedirectStandardError=$true
    if (!$launcher.Start()) {throw 'Same-user SAFER launcher did not start'}
    $launchOut=$launcher.StandardOutput.ReadToEndAsync();$launchErr=$launcher.StandardError.ReadToEndAsync()
    if (!$launcher.WaitForExit(15000)) {$launcher.Kill();$null=$launcher.WaitForExit(5000);throw 'Same-user SAFER launch timed out'}
    $receipt.launch=@{pid=$launcher.Id;exitCode=$launcher.ExitCode}
    if ($null -eq $launcher.ExitCode -or $launcher.ExitCode -ne 0) {throw ('Same-user SAFER launch exit '+$launcher.ExitCode)}
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    while (!(Test-Path (Join-Path $localOutput 'user-started.json'))) { if ([DateTime]::UtcNow -ge $deadline) { throw 'Same-user SAFER child produced no receipt' };Start-Sleep -Milliseconds 200 }
    $started=Get-Content (Join-Path $localOutput 'user-started.json') -Raw | ConvertFrom-Json
    if ($started.admin -or $started.sid -cne $identity.User.Value -or $started.session -ne (Get-Process -Id $PID).SessionId) { throw 'SAFER launch changed account/session or retained elevation' }
    $receipt.user=$started
    $candidate=[Diagnostics.Process]::GetProcessById($started.pid)
    try {
        $null=$candidate.Handle
        if ($candidate.StartTime.ToUniversalTime().Ticks -ne [long]$started.createdTicks) { throw 'User child process identity changed' }
        $user=$candidate;$candidate=$null
    } finally { if ($candidate) { $candidate.Dispose() } }
    $job=[AttachmentJob]::new();$job.Assign($user.Handle)
    Assert-ProductionSignature $msi
    $installAttempted=$true
    Save-SetupReceipt 'installing'
    Msi /i
    $receipt.installed=$true
    Save-SetupReceipt 'installed'
    foreach ($relative in @('user\go-mapi.exe','interceptor\AMD64\go-mapi.dll')) {
        Assert-ProductionSignature (Join-Path 'C:\Program Files\go-mapi' $relative)
    }
    'go' | Set-Content (Join-Path $work 'user-go')
    $deadline=[DateTime]::UtcNow.AddSeconds(300)
    $fakeAdmitted=$false
    while (!$user.HasExited) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Ordinary installed smoke exceeded five minutes' }
        if (!$fakeAdmitted) {
            $readyFiles=@(Get-ChildItem -LiteralPath $localOutput -Recurse -File -Filter fake-ready.json)
            if ($readyFiles.Count -gt 1) { throw 'Unexpected second fake server' }
            if ($readyFiles.Count -eq 1) {
                $ready=Get-Content -LiteralPath $readyFiles[0].FullName -Raw | ConvertFrom-Json
                if ($readyFiles[0].Directory.Name -cne ('smoke-'+$ready.runId)) { throw 'Fake readiness directory differs from run identity' }
                $ca=[Security.Cryptography.X509Certificates.X509Certificate2]::new((Join-Path $readyFiles[0].DirectoryName 'test-ca.pem'))
                $sha=[Security.Cryptography.SHA256]::Create()
                try { $caHash=([BitConverter]::ToString($sha.ComputeHash($ca.RawData))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
                if ($ca.HasPrivateKey -or $caHash -cne $ready.caThumbprintSHA256) { throw 'Fake CA differs from readiness digest' }
                $path='Cert:\LocalMachine\Root\'+$ca.Thumbprint
                if (Test-Path -LiteralPath $path) { throw 'Generated fake CA already trusted' }
                $trust.Add($path)
                $store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine')
                try { $store.Open('ReadWrite');$store.Add($ca) } finally { $store.Close() }
                $fakeAdmitted=$true
            }
        }
        $null=$user.WaitForExit(250)
    }
    if ($user.ExitCode -ne 0) { throw ('Ordinary installed smoke child exit '+$user.ExitCode) }
    $userResult=Get-Content (Join-Path $localOutput 'user-result.json') -Raw | ConvertFrom-Json
    $smoke=Get-Content (Join-Path $localOutput 'attachment-result.json') -Raw | ConvertFrom-Json
    if (!$userResult.passed -or !$smoke.passed) { throw 'Ordinary installed smoke did not pass' }
    $receipt.passed=$true
} catch {
    $receipt.error=$_ | Out-String
    Save-SetupReceipt 'failed' -BestEffort
    # Keep loader/service failures diagnosable before cleanup or guest disposal.
    foreach ($logName in @('Application','System','Microsoft-Windows-CodeIntegrity/Operational')) {
        try {
            @(Get-WinEvent -FilterHashtable @{LogName=$logName;StartTime=$startedAt} -MaxEvents 100 -ErrorAction Stop |
                Select-Object TimeCreated,Id,ProviderName,LevelDisplayName,Message) |
                ConvertTo-Json -Depth 4 | Set-Content (Join-Path $localOutput (($logName -replace '[\\/]','-')+'-events.json'))
        } catch {
            try { $_ | Out-String | Set-Content (Join-Path $localOutput (($logName -replace '[\\/]','-')+'-events-error.txt')) }
            catch { $errors.Add('event evidence: '+$_.Exception.Message) }
        }
    }
}
finally {
    Save-SetupReceipt 'cleanup' -BestEffort
    if ($job) { try { $job.Dispose() } catch { $errors.Add('user job: '+$_.Exception.Message) } }
    if ($user) {
        try { if (!$user.HasExited) { $user.Kill();if (!$user.WaitForExit(5000)) { throw 'Owned user child remains' } };$receipt.userStopped=$user.HasExited } catch { $errors.Add('user child: '+$_.Exception.Message) }
        $user.Dispose()
    }
    if ($launcher) {
        foreach ($stream in @(@{name='runas.stdout';task=$launchOut},@{name='runas.stderr';task=$launchErr})) {
            try {
                $text=if ($stream.task -and $stream.task.Wait(1000)) {$stream.task.GetAwaiter().GetResult()} else {'[stream did not close within one second]'}
                [IO.File]::WriteAllText((Join-Path $localOutput $stream.name),$text)
            } catch {$errors.Add('launcher diagnostics: '+$_.Exception.Message)}
        }
        $launcher.Dispose()
    }
    if ($installAttempted) { try { Msi /x;if ((Get-Service go-mapi -ErrorAction SilentlyContinue) -or (Test-Path 'C:\Program Files\go-mapi\user\go-mapi.exe') -or (Test-Path 'C:\Program Files\go-mapi\interceptor\AMD64\go-mapi.dll') -or (Test-Path 'C:\Program Files\go-mapi\interceptor\x86\go-mapi.dll') -or (Test-Path 'C:\Program Files\go-mapi\service\go-mapi-service.exe')) { throw 'Suite bytes or service remain' };$receipt.removed=$true } catch { $errors.Add('suite cleanup: '+$_.Exception.Message) } }
    foreach ($path in $trust) { try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction Stop };if (Test-Path -LiteralPath $path) { throw 'Owned fake HTTPS CA remains' } } catch { $errors.Add('fake HTTPS CA: '+$_.Exception.Message) } }
    $receipt.trustRemoved=$true
    $receipt.cleanupErrors=@($errors)
    $receipt.passed=$receipt.passed -and $errors.Count -eq 0 -and $receipt.removed -and $receipt.userStopped
    Save-SetupReceipt 'finished'
}
if (!$receipt.passed) { throw ('Installed smoke failed: '+$receipt.error) }
