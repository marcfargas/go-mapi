[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Manifest,
    [Parameter(Mandatory)][string]$FakeBinary,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('suiteA','suiteB','suiteC')][string]$Package = 'suiteC',
    [ValidateSet('InstalledDll','Explorer')][string]$EntryPoint = 'InstalledDll'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Attachment.psm1') -Force
Add-Type -Path (Join-Path $PSScriptRoot 'AttachmentNative.cs')
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$session = (Get-Process -Id $PID).SessionId
if (([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $session -eq 0) { throw 'Run as the existing non-elevated desktop user in a disposable Windows guest with the suite already installed' }
$runId = [guid]::NewGuid().ToString('N')
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$root = Join-Path $OutputDirectory ('smoke-' + $runId)
$FakeBinary = (Resolve-Path -LiteralPath $FakeBinary).Path
$errors = [Collections.Generic.List[string]]::new()
$result = [ordered]@{runId=$runId;passed=$false;sourceCommit=$null;package=$Package;entryPoint=$EntryPoint;smoke=$null;error=$null;cleanupErrors=@()}
$fake = $null; $worker = $null; $job = $null; $control = $null
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    $manifestObject = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
    $fixture = $manifestObject.packages.$Package
    if ($manifestObject.schema -cne 'go-mapi-machine-test-packages-v1' -or !$fixture.appSha256 -or !$fixture.x64DllSha256) { throw 'Select a complete current suite fixture manifest' }
    foreach ($hash in @($fixture.sha256,$fixture.appSha256,$fixture.x64DllSha256)) { if ($hash -cnotmatch '^[a-f0-9]{64}$') { throw 'Fixture lacks exact lowercase SHA256 identities' } }
    $appPath = Join-Path $env:ProgramFiles 'go-mapi\user\go-mapi.exe'
    $dllPath = Join-Path $env:ProgramFiles 'go-mapi\interceptor\AMD64\go-mapi.dll'
    if ((Hash $appPath) -cne $fixture.appSha256 -or (Hash $dllPath) -cne $fixture.x64DllSha256) { throw 'Installed suite bytes differ from selected fixture; install it in the guest before running this smoke' }
    $result.sourceCommit = $manifestObject.sourceCommit
    Write-AttachmentJson (Join-Path $root 'inputs.json') @{manifestSha256=(Hash $Manifest);fakeSha256=(Hash $FakeBinary);msiSha256=$fixture.sha256;sourceCommit=$result.sourceCommit;package=$Package}
    $hashes = @{}
    foreach ($entry in (Get-AttachmentFixtures).GetEnumerator()) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hashes[$entry.Key] = ([BitConverter]::ToString($sha.ComputeHash($entry.Value))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    }
    $expected = @{runId=$runId;subject=('Attachment ' + $runId);recipient='attachment@example.invalid';attachments=$hashes;entryPoint=$EntryPoint}
    if ($EntryPoint -eq 'Explorer') { $expected.subject=''; $expected.recipient='' }
    Write-AttachmentJson (Join-Path $root 'expected.json') $expected
    $fake = Start-Process $FakeBinary -ArgumentList @('--root',('"'+$root+'"'),'--expected',('"'+(Join-Path $root 'expected.json')+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'fake.stdout') -RedirectStandardError (Join-Path $root 'fake.stderr')
    $null = $fake.Handle
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (!(Test-Path (Join-Path $root 'fake-ready.json'))) {
        if ($fake.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'Isolated fake did not become ready' }
        Start-Sleep -Milliseconds 100
    }
    $ready = Get-Content (Join-Path $root 'fake-ready.json') -Raw | ConvertFrom-Json
    $control = Get-Content (Join-Path $root 'fake-control.json') -Raw | ConvertFrom-Json
    $ca = [Security.Cryptography.X509Certificates.X509Certificate2]::new((Join-Path $root 'test-ca.pem'))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $caHash = ([BitConverter]::ToString($sha.ComputeHash($ca.RawData))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    if ($ready.pid -ne $fake.Id -or $ready.runId -cne $runId -or $ready.address -cnotmatch '^127\.0\.0\.1:[0-9]+$' -or $control.address -cnotmatch '^127\.0\.0\.1:[0-9]+$' -or $control.token -cnotmatch '^[a-f0-9]{64}$' -or $ready.caThumbprintSHA256 -cne $caHash) { throw 'Fake readiness is not bound to the exact owned process and generated CA' }
    # The elevated guest setup owns trust. A normal-user Root import opens a
    # Windows consent dialog, so this worker only observes the exact admitted CA.
    $trustPath = 'Cert:\LocalMachine\Root\' + $ca.Thumbprint
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (!(Test-Path -LiteralPath $trustPath)) {
        if ($fake.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'Guest setup did not admit the generated test-ca.pem from this smoke directory' }
        Start-Sleep -Milliseconds 200
    }
    if ([Convert]::ToBase64String((Get-Item -LiteralPath $trustPath).RawData) -cne [Convert]::ToBase64String($ca.RawData)) { throw 'Admitted fake CA bytes differ from the owned server certificate' }
    $case = @{runId=$runId;root=$root;sid=$identity.User.Value;profilePath=$env:USERPROFILE;session=$session;appPath=$appPath;dllPath=$dllPath;appSha256=$fixture.appSha256;dllSha256=$fixture.x64DllSha256;expected=$expected;entryPoint=$EntryPoint;proxyAddress=$ready.address;control=$control}
    $casePath = Join-Path $root 'case.json'
    Write-AttachmentJson $casePath $case
    $job = [AttachmentJob]::new()
    $script = Join-Path $PSScriptRoot 'Invoke-Attachment.ps1'
    $worker = Start-Process (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile','-NonInteractive','-File',('"'+$script+'"'),'-CaseFile',('"'+$casePath+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'worker.stdout') -RedirectStandardError (Join-Path $root 'worker.stderr')
    $job.Assign($worker.Handle)
    [IO.File]::WriteAllText((Join-Path $root 'worker-go'),'go')
    if (!$worker.WaitForExit(240000)) { throw 'Attachment worker exceeded four minutes' }
    if ($worker.ExitCode -ne 0) { throw ('Attachment worker exit ' + $worker.ExitCode) }
} catch { $result.error = $_.Exception.Message }
finally {
    if ($job) { try { $job.Dispose() } catch { $errors.Add('worker tree: ' + $_.Exception.Message) } }
    if ($worker) {
        try { if (!$worker.HasExited) { $worker.Kill(); if (!$worker.WaitForExit(10000)) { throw 'Owned worker did not stop' } } } catch { $errors.Add('worker: ' + $_.Exception.Message) }
        try { $worker.Dispose() } catch { $errors.Add('worker handle: ' + $_.Exception.Message) }
    }
    if ($fake) {
        try {
            if (!$fake.HasExited -and $control) { $null = Invoke-RestMethod -Method Post -Uri ('http://'+$control.address+'/shutdown') -Headers @{'X-Test-Control'=$control.token} -TimeoutSec 5 }
            if (!$fake.WaitForExit(10000)) { throw 'Fake did not finalize within ten seconds' }
            if ($fake.ExitCode -ne 0) { throw ('Final fake exit ' + $fake.ExitCode) }
        } catch { $errors.Add('fake: ' + $_.Exception.Message) }
        try { if (!$fake.HasExited) { $fake.Kill(); if (!$fake.WaitForExit(5000)) { throw 'Owned fake did not stop' } } } catch { $errors.Add('fake stop: ' + $_.Exception.Message) }
        try { $fake.Dispose() } catch { $errors.Add('fake handle: ' + $_.Exception.Message) }
    }
    if (!$result.error -and !$errors.Count) {
        try { $result.smoke = Assert-AttachmentResult $root ($case | ConvertTo-Json -Depth 8 | ConvertFrom-Json); $result.passed = $true } catch { $result.error = $_.Exception.Message }
    }
    $result.cleanupErrors = @($errors)
    Write-AttachmentJson (Join-Path $OutputDirectory 'attachment-result.json') $result
}
if (!$result.passed) { throw 'Installed attachment smoke failed; inspect attachment-result.json and its smoke directory' }
