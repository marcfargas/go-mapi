[CmdletBinding()]
param([Parameter(Mandatory)][string]$CaseFile)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Attachment.psm1') -Force
Add-Type -Path (Join-Path $PSScriptRoot 'AttachmentNative.cs')
$case = Get-Content -LiteralPath $CaseFile -Raw | ConvertFrom-Json
$result = [ordered]@{ runId=$case.runId; passed=$false; profile=$null; app=$null; mapiReturn=$null; queue=$null; appStopped=$false; credentialRemoved=$false; error=$null; cleanupErrors=@() }
$app = $null; $watcher = $null; $subscriptions = @(); $credentialOwned = $false; $settingsOwned = $false; $appLogOwned = $false
$cleanup = [Collections.Generic.List[string]]::new()
$queue = $null; $settings = $null; $appLog = $null; $fixtureRoot = $null
function QueueFiles { @(Get-ChildItem -LiteralPath $queue -File -Recurse -Force -ErrorAction Stop | Select-Object -ExpandProperty FullName) }
function FakeStatus { Invoke-RestMethod -Uri ('http://' + $case.control.address + '/status') -Headers @{ 'X-Test-Control'=$case.control.token } -TimeoutSec 3 }
try {
    $gateDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (!(Test-Path -LiteralPath (Join-Path $case.root 'worker-go'))) {
        if ([DateTime]::UtcNow -ge $gateDeadline) { throw 'Launcher did not assign worker ownership' }
        Start-Sleep -Milliseconds 100
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $session = (Get-Process -Id $PID).SessionId
    $admin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($identity.User.Value -cne $case.sid -or $admin -or $session -ne $case.session -or $session -eq 0 -or $env:USERPROFILE -ine $case.profilePath) { throw 'Worker requires the selected non-elevated desktop user' }
    $result.profile = @{sid=$identity.User.Value;admin=$admin;session=$session;path=$env:USERPROFILE}
    if ((Get-FileHash -LiteralPath $case.appPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $case.appSha256 -or (Get-FileHash -LiteralPath $case.dllPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $case.dllSha256) { throw 'Installed app/DLL bytes differ from the selected package' }
    $queue = Join-Path $env:LOCALAPPDATA 'go-mapi\queue'
    New-Item -ItemType Directory -Path $queue -Force | Out-Null
    if (@(QueueFiles).Count -or [AttachmentNative]::CredentialExists()) { throw 'Test user has preexisting queue data or credentials' }
    $settings = Join-Path $env:APPDATA 'go-mapi\settings.json'
    $appLog = Join-Path $env:APPDATA 'go-mapi\app.log'
    if ((Test-Path -LiteralPath $settings) -or (Test-Path -LiteralPath $appLog)) { throw 'Test user has preexisting app settings or log' }
    $appLogOwned = $true
    New-Item -ItemType Directory -Path (Split-Path -Parent $settings) -Force | Out-Null
    [IO.File]::WriteAllText($settings,'{"mode":"auto-draft","autostart_enabled":false,"update_checks_enabled":false,"default_apps_prompted":true}',[Text.UTF8Encoding]::new($false))
    $settingsOwned = $true
    $token = @{access_token='synthetic-569-not-a-real-token';refresh_token='synthetic-unused';token_type='Bearer';expiry=[DateTime]::UtcNow.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ')} | ConvertTo-Json -Compress
    $credentialOwned = $true
    [AttachmentNative]::WriteCredential($token)
    if (![AttachmentNative]::CredentialExists()) { throw 'Synthetic credential readback failed' }
    $fixtures = Get-AttachmentFixtures
    $fixturePath = Join-Path $env:USERPROFILE ('attachment-' + $case.runId)
    New-Item -ItemType Directory -Path $fixturePath -ErrorAction Stop | Out-Null
    $fixtureRoot = $fixturePath
    foreach ($name in $fixtures.Keys) { [IO.File]::WriteAllBytes((Join-Path $fixtureRoot $name), $fixtures[$name]) }
    $watcher = [IO.FileSystemWatcher]::new($queue)
    $watcher.IncludeSubdirectories = $false
    foreach ($eventName in @('Created','Renamed','Deleted')) {
        $id = $case.runId + '-' + $eventName
        Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $id
        $subscriptions += $id
    }
    $watcher.EnableRaisingEvents = $true
    $env:HTTPS_PROXY = 'http://' + $case.proxyAddress; $env:HTTP_PROXY=$env:HTTPS_PROXY; $env:NO_PROXY=''; $env:no_proxy=''
    $admission = Join-Path $env:ProgramData 'go-mapi\status\suite-admission-v1'
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while (!(Test-Path -LiteralPath $admission) -or [IO.File]::ReadAllText($admission) -cne 'O') {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Installed suite admission did not open' }
        Start-Sleep -Milliseconds 200
    }
    $app = Start-Process -FilePath $case.appPath -WorkingDirectory $case.root -WindowStyle Hidden -PassThru
    $null = $app.Handle
    if ($app.Path -ine $case.appPath -or $app.SessionId -ne $session) { throw 'Launched app identity differs from the installed same-session image' }
    $result.app = @{pid=$app.Id;createdAt=$app.StartTime.ToUniversalTime().ToString('o');path=$app.Path;session=$app.SessionId;sha256=$case.appSha256;dllSha256=$case.dllSha256;arguments=@()}
    do {
        if ($app.HasExited) { throw 'Installed app exited before authentication readiness' }
        $status = FakeStatus
        if ($status.failed) { throw 'Fake rejected an unexpected request' }
        if ($status.userInfoRequests -ge 1) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Installed app did not authenticate against the isolated fake' }
        Start-Sleep -Milliseconds 200
    } while ($true)
    $result.mapiReturn = [AttachmentNative]::Send($case.dllPath, $fixtureRoot, $case.expected.subject, $case.expected.recipient)
    if ($result.mapiReturn -ne 0) { throw ('Installed MAPI returned ' + $result.mapiReturn) }
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    $events = @(); $descriptor = $null
    do {
        if ($app.HasExited) { throw 'Installed app exited before queue acknowledgement' }
        $status = FakeStatus
        if ($status.failed) { throw 'Fake latched a request or attachment failure' }
        foreach ($id in $subscriptions) {
            foreach ($event in @(Get-Event -SourceIdentifier $id -ErrorAction SilentlyContinue)) {
                $events += [pscustomobject]@{kind=$event.SourceEventArgs.ChangeType.ToString();name=$event.SourceEventArgs.Name}
                Remove-Event -EventIdentifier $event.EventIdentifier
            }
        }
        $published = @($events | Where-Object { $_.kind -in @('Created','Renamed') -and $_.name -like '*.json' } | Select-Object -ExpandProperty name -Unique)
        $deleted = @($events | Where-Object { $_.kind -eq 'Deleted' -and $_.name -like '*.json' } | Select-Object -ExpandProperty name -Unique)
        $result.queue = @{acknowledged=$false;descriptor=$null;events=$events;remaining=@(QueueFiles)}
        if ($published.Count -eq 1 -and $deleted -contains $published[0] -and $status.drafts -and @($status.drafts).Count -eq 1 -and @(QueueFiles).Count -eq 0) { $descriptor = $published[0]; break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Exact draft lacked a matching descriptor publication/deletion and empty queue' }
        Start-Sleep -Milliseconds 200
    } while ($true)
    $result.queue = @{acknowledged=$true;descriptor=$descriptor;events=$events;remaining=@()}
    $result.passed = $true
} catch { $result.error = $_.Exception.Message }
finally {
    foreach ($id in $subscriptions) {
        try { Unregister-Event -SourceIdentifier $id -ErrorAction Stop; Get-Event -SourceIdentifier $id -ErrorAction SilentlyContinue | Remove-Event } catch { $cleanup.Add('queue subscription: ' + $_.Exception.Message) }
    }
    if ($watcher) { try { $watcher.Dispose() } catch { $cleanup.Add('queue watcher: ' + $_.Exception.Message) } }
    if ($app) {
        try { if (!$app.HasExited) { $app.Kill(); if (!$app.WaitForExit(15000)) { throw 'Owned app did not terminate' } }; $result.appStopped=$app.HasExited } catch { $cleanup.Add('app: ' + $_.Exception.Message) }
        try { $app.Dispose() } catch { $cleanup.Add('app handle: ' + $_.Exception.Message) }
    }
    if ($queue) {
        try { $remaining = @(QueueFiles); if ($result.queue) { $result.queue.remaining=$remaining }; if ($remaining.Count) { Copy-Item -LiteralPath $queue -Destination (Join-Path $case.root 'queue-final') -Recurse; throw 'Queue retained data after app exit' } } catch { $cleanup.Add('queue: ' + $_.Exception.Message) }
    }
    if ($credentialOwned) { try { [AttachmentNative]::RemoveCredential(); $result.credentialRemoved=![AttachmentNative]::CredentialExists() } catch { $cleanup.Add('credential: ' + $_.Exception.Message) } }
    if ($appLogOwned -and (Test-Path -LiteralPath $appLog)) { try { Copy-Item -LiteralPath $appLog -Destination (Join-Path $case.root 'app.log'); Remove-Item -LiteralPath $appLog } catch { $cleanup.Add('app log: ' + $_.Exception.Message) } }
    if ($settingsOwned) { try { Remove-Item -LiteralPath $settings -ErrorAction Stop } catch { $cleanup.Add('settings: ' + $_.Exception.Message) } }
    if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
        try {
            foreach ($name in (Get-AttachmentFixtures).Keys) { $path=Join-Path $fixtureRoot $name; if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction Stop } }
            if (@(Get-ChildItem -LiteralPath $fixtureRoot -Force).Count) { throw 'Owned attachment directory contains unexpected files' }
            Remove-Item -LiteralPath $fixtureRoot -ErrorAction Stop
        } catch { $cleanup.Add('attachments: ' + $_.Exception.Message) }
    }
    $result.cleanupErrors = @($cleanup)
    $result.passed = $result.passed -and $cleanup.Count -eq 0 -and $result.appStopped -and $result.credentialRemoved
    Write-AttachmentJson (Join-Path $case.root 'worker.json') $result
}
if (!$result.passed) { throw 'Installed attachment worker failed; inspect worker.json and app.log' }
