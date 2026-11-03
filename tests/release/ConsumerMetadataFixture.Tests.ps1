#Requires -Version 7.0
# Executes only a loopback HTTP fixture. No TLS bindings, trust, hosts or installers.
param([string]$FixtureShell=(Get-Process -Id $PID).Path)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Join-Path ([IO.Path]::GetTempPath()) ('go-mapi-consumer-http-'+[guid]::NewGuid().ToString('N'))
$utf8=[Text.UTF8Encoding]::new($false)
$fixture=Join-Path $PSScriptRoot 'ConsumerMetadataFixture.ps1'
$process=$null
$client=$null
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) {throw $Message} }
function Write-Json([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 8),$utf8) }
function Start-Fixture([string]$Directory,[string]$Prefix,[int]$Timeout=30) {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$FixtureShell
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardError=$true
    $info.RedirectStandardOutput=$true
    foreach ($argument in @('-NoProfile','-File',$fixture,'-FixtureDirectory',$Directory,'-Prefix',$Prefix,'-TimeoutSeconds',"$Timeout")) {
        $info.ArgumentList.Add($argument)
    }
    return [Diagnostics.Process]::Start($info)
}
function Wait-Ready([Diagnostics.Process]$Child,[string]$Directory) {
    $until=[DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath (Join-Path $Directory 'ready.json'))) {
        if ($Child.HasExited) { throw ('Fixture exited: '+$Child.StandardError.ReadToEnd()+$Child.StandardOutput.ReadToEnd()) }
        if ([DateTime]::UtcNow -ge $until) {throw 'Fixture readiness timed out'}
        Start-Sleep -Milliseconds 50
    }
    $ready=Get-Content -LiteralPath (Join-Path $Directory 'ready.json') -Raw | ConvertFrom-Json
    Check ($ready.pid -eq $Child.Id) 'Readiness PID does not identify the owned fixture'
}
function Request([string]$Method,[string]$Path,[string]$Body='', $Headers=@{}) {
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$script:origin+$Path)
    try {
        foreach ($key in $Headers.Keys) { $null=$request.Headers.TryAddWithoutValidation($key,[string]$Headers[$key]) }
        if ($Body) {$request.Content=[Net.Http.StringContent]::new($Body,[Text.Encoding]::UTF8,'application/json')}
        $response=$client.SendAsync($request).GetAwaiter().GetResult()
        try {
            return [pscustomobject]@{status=[int]$response.StatusCode;body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
                noStore=$response.Headers.CacheControl.NoStore;contentType=$response.Content.Headers.ContentType.MediaType}
        } finally {$response.Dispose()}
    } finally {$request.Dispose()}
}
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $directory=Join-Path $root 'main'
    New-Item -ItemType Directory -Path $directory | Out-Null
    Write-Json (Join-Path $directory 'app-selection.json') @{releaseTrack='development'}
    $systemBody="{`"schema`":`"controlled-target`",`"version`":`"original`"}`n"
    $suiteBody="{`"schema`":`"controlled-target`",`"sku`":`"suite`"}`n"
    [IO.File]::WriteAllText((Join-Path $directory 'system-targets.json'),$systemBody,$utf8)
    [IO.File]::WriteAllText((Join-Path $directory 'suite-targets.json'),$suiteBody,$utf8)
    $reservation=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $reservation.Start()
    $port=$reservation.LocalEndpoint.Port
    $reservation.Stop()
    $script:origin="http://127.0.0.1:$port"
    $process=Start-Fixture $directory ($origin+'/')
    Wait-Ready $process $directory
    $handler=[Net.Http.HttpClientHandler]::new()
    $handler.UseProxy=$false
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=[TimeSpan]::FromSeconds(10)
    $headers=@{'X-Go-Mapi-Release-Track'='development';'X-Go-Mapi-Installed-Version'='3.2.0-beta.2'}
    $result=Request GET '/machine/system/targets.json' '' $headers
    Check ($result.status -eq 200 -and $result.body -ceq $systemBody -and $result.noStore -and $result.contentType -ceq 'application/json') 'System target path/bytes/no-store contract failed'
    $result=Request GET '/machine/suite/targets.json' '' $headers
    Check ($result.status -eq 200 -and $result.body -ceq $suiteBody) 'Suite target path did not resolve exact bytes'
    $refresh="{`"schema`":`"controlled-target`",`"version`":`"refreshed`"}`n"
    [IO.File]::WriteAllText((Join-Path $directory 'system-targets.json'),$refresh,$utf8)
    $result=Request GET '/machine/system/targets.json' '' @{'X-Go-Mapi-Release-Track'='development'}
    Check ($result.status -eq 200 -and $result.body -ceq $refresh) 'Target file was not reread for bootstrap/refresh'
    Check ((Request GET '/machine/system/targets.json').status -eq 400) 'Missing track header was accepted'
    Check ((Request GET '/machine/system/targets.json' '' @{'X-Go-Mapi-Release-Track'='stable'}).status -eq 400) 'Wrong track was accepted'
    Check ((Request POST '/machine/system/targets.json' '{}' $headers).status -eq 405) 'Wrong target method was accepted'
    Check ((Request GET '/machine/system/targets.json?secret=not-retained' '' $headers).status -eq 400) 'Query-bearing target URL was accepted'
    Check ((Request GET '/releases/download/v3.2.0-beta.2/go-mapi-system-3.2.0-beta.2-x64.msi' '' $headers).status -eq 404) 'Fixture served an artifact path'
    Remove-Item -LiteralPath (Join-Path $directory 'suite-targets.json')
    Check ((Request GET '/machine/suite/targets.json' '' $headers).status -eq 503) 'Missing target file was accepted'
    $request=@{schema='go-mapi-update-check-v1';appVersion='3.2.0-beta.2';interceptorVersion='absent';
        distributionChannel='standalone';releaseTrack='development';os='windows';architecture='x64'}
    $result=Request POST '/api/updates/v1/check' ($request | ConvertTo-Json -Compress)
    $answer=$result.body | ConvertFrom-Json
    Check ($result.status -eq 200 -and $result.noStore -and $answer.schema -ceq $request.schema) 'Actual App check endpoint/no-store failed'
    Check ($answer.app.installedVersion -ceq $request.appVersion -and $answer.app.latestVersion -ceq $request.appVersion -and -not $answer.app.updateAvailable) 'Default App no-update response changed installed identity'
    Check ($answer.interceptor.installedVersion -ceq 'absent' -and $answer.interceptor.latestVersion -ceq '' -and -not $answer.interceptor.updateAvailable) 'Missing interceptor echo is incompatible with actual client wire'
    $request.interceptorVersion='unknown'
    $answer=(Request POST '/api/updates/v1/check' ($request | ConvertTo-Json -Compress)).body | ConvertFrom-Json
    Check ($answer.interceptor.installedVersion -ceq 'unknown' -and $answer.interceptor.latestVersion -ceq '' -and -not $answer.interceptor.updateAvailable) 'Unreadable interceptor identity did not retain actual unknown/no-update wire semantics'
    $request.interceptorVersion='3.2.0-beta.2'
    $request.distributionChannel='store'
    $answer=(Request POST '/api/updates/v1/check' ($request | ConvertTo-Json -Compress)).body | ConvertFrom-Json
    Check ($answer.interceptor.installedVersion -ceq $request.interceptorVersion -and $answer.interceptor.latestVersion -ceq $request.interceptorVersion) 'Installed interceptor response changed identity'
    Write-Json (Join-Path $directory 'app-selection.json') @{releaseTrack='development';latestAppVersion='3.2.0-beta.3';appUpdateAvailable=$true}
    $answer=(Request POST '/api/updates/v1/check' ($request | ConvertTo-Json -Compress)).body | ConvertFrom-Json
    Check ($answer.app.latestVersion -ceq '3.2.0-beta.3' -and $answer.app.updateAvailable -and $answer.app.installedVersion -ceq $request.appVersion) 'Explicit controlled offer was not reloaded'
    foreach ($change in @(@{schema='wrong'},@{os='linux'},@{architecture='arm64'},@{releaseTrack='stable'},@{distributionChannel='managed'},@{appVersion='invalid'},@{extra='not-retained'},@{appVersion=123})) {
        $bad=$request.Clone()
        foreach ($key in $change.Keys) {$bad[$key]=$change[$key]}
        Check ((Request POST '/api/updates/v1/check' ($bad | ConvertTo-Json -Compress)).status -eq 400) ('Malformed App request was accepted: '+($change.Keys -join ','))
    }
    Check ((Request POST '/api/updates/v1/check' '{"bad":').status -eq 400) 'Malformed JSON was accepted'
    $duplicate=($request | ConvertTo-Json -Compress) -replace '^\{','{"schema":"wrong",'
    Check ((Request POST '/api/updates/v1/check' $duplicate).status -eq 400) 'Duplicate request field was accepted'
    Check ((Request POST '/api/updates/v1/check' ('x'*4097)).status -eq 413) 'Oversized App body was accepted'
    Check ((Request GET '/api/updates/v1/check').status -eq 405) 'Wrong App method was accepted'
    [IO.File]::WriteAllText((Join-Path $directory 'app-selection.json'),'{',$utf8)
    Check ((Request GET '/machine/system/targets.json' '' $headers).status -eq 500) 'Malformed selection was accepted'
    [IO.File]::WriteAllText((Join-Path $directory 'stop'),'stop',$utf8)
    Check ($process.WaitForExit(10000)) 'Fixture did not stop on its owned stop file'
    Check ($process.ExitCode -eq 0) ('Fixture failed: '+$process.StandardError.ReadToEnd())
    $final=Get-Content -LiteralPath (Join-Path $directory 'final.json') -Raw | ConvertFrom-Json
    $requests=@(Get-Content -LiteralPath (Join-Path $directory 'requests.ndjson') | ForEach-Object {$_ | ConvertFrom-Json})
    Check ($final.reason -ceq 'stop-file' -and $final.requests -eq $requests.Count) 'Final request accounting or stop reason differs'
    $posted=@($requests | Where-Object {$_.status -eq 200 -and $_.method -ceq 'POST'})
    Check ($posted.Count -eq 4 -and $posted[0].body.appVersion -ceq '3.2.0-beta.2' -and $posted[0].body.interceptorVersion -ceq 'absent' -and $posted[1].body.interceptorVersion -ceq 'unknown') 'Request receipt lost exact validated App identities'
    $targeted=@($requests | Where-Object {$_.status -eq 200 -and $_.method -ceq 'GET'})
    Check ($targeted[0].releaseTrack -ceq 'development' -and $targeted[0].installedVersion -ceq '3.2.0-beta.2' -and $targeted[2].installedVersion -ceq '') 'Target headers/bootstrap absence not retained faithfully'
    Check ($targeted[0].responseSha256 -cne $targeted[2].responseSha256 -and $targeted[0].responseSha256 -cmatch '^[a-f0-9]{64}$') 'Target response bytes were not bound in refresh receipts'
    Check (-not ((Get-Content -LiteralPath (Join-Path $directory 'requests.ndjson') -Raw).Contains('not-retained'))) 'Arbitrary query or malformed body reached receipts'
    foreach ($badPrefix in @('http://go-mapi.app/','https://localhost:443/','http://0.0.0.0:12345/')) {
        $badDirectory=Join-Path $root ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $badDirectory | Out-Null
        $child=Start-Fixture $badDirectory $badPrefix
        try {
            Check ($child.WaitForExit(10000)) 'Invalid prefix refusal timed out'
            Check ($child.ExitCode -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $badDirectory 'ready.json'))) 'Non-loopback or wrong HTTPS origin was accepted'
        } finally {if (-not $child.HasExited) {$child.Kill()};$child.Dispose()}
    }
    $timeoutDirectory=Join-Path $root 'timeout'
    New-Item -ItemType Directory -Path $timeoutDirectory | Out-Null
    Write-Json (Join-Path $timeoutDirectory 'app-selection.json') @{releaseTrack='development'}
    $child=Start-Fixture $timeoutDirectory ($origin+'/') 2
    try {
        Wait-Ready $child $timeoutDirectory
        Check ($child.WaitForExit(8000)) 'Fixture exceeded bounded lifetime'
        $final=Get-Content -LiteralPath (Join-Path $timeoutDirectory 'final.json') -Raw | ConvertFrom-Json
        Check ($child.ExitCode -eq 0 -and $final.reason -ceq 'timeout') 'Bounded fixture timeout did not dispose its listener'
    } finally {if (-not $child.HasExited) {$child.Kill()};$child.Dispose()}
    'Consumer metadata HTTP contracts passed'
} finally {
    if ($client) {$client.Dispose()}
    if ($process) {if (-not $process.HasExited) {$process.Kill();$null=$process.WaitForExit(5000)};$process.Dispose()}
    $resolvedRoot=[IO.Path]::GetFullPath($root)
    $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if ($resolvedRoot.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRoot).StartsWith('go-mapi-consumer-http-',[StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
