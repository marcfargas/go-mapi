#Requires -Version 5.1
<#
Controlled consumer-test metadata only. The parent owns guest hosts, certificate,
HTTPS binding and exact cleanup. No artifacts, redirects or production API are served.
FixtureDirectory contains system-targets.json, suite-targets.json and
app-selection.json: {"releaseTrack":"development"}. Optional latestAppVersion
and appUpdateAvailable expose the existing App update UI without downloading it.
The fixture reloads files on every request and stops on FixtureDirectory/stop or
TimeoutSeconds. ready.json, requests.ndjson and final.json are local test receipts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FixtureDirectory,
    [string]$Prefix = 'https://go-mapi.app:443/',
    [ValidateRange(1,3600)][int]$TimeoutSeconds = 1200
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false,$true)
$prefixUri = $null
if (-not [Uri]::TryCreate($Prefix,[UriKind]::Absolute,[ref]$prefixUri) -or
    $prefixUri.UserInfo -or $prefixUri.AbsolutePath -cne '/' -or $prefixUri.Query -or $prefixUri.Fragment -or
    -not (($prefixUri.Scheme -ceq 'https' -and $prefixUri.Host -ceq 'go-mapi.app' -and $prefixUri.Port -eq 443) -or
          ($prefixUri.Scheme -ceq 'http' -and $prefixUri.Host -in @('127.0.0.1','localhost','[::1]')))) {
    throw 'Prefix must be https://go-mapi.app:443/ or a loopback HTTP test origin'
}
$directory = [IO.Path]::GetFullPath($FixtureDirectory)
if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'FixtureDirectory must already exist' }
foreach ($name in @('ready.json','requests.ndjson','final.json','stop')) {
    if (Test-Path -LiteralPath (Join-Path $directory $name)) { throw "Refusing prior fixture control or receipt: $name" }
}
$stopPath = Join-Path $directory 'stop'
$logPath = Join-Path $directory 'requests.ndjson'
$started = [DateTime]::UtcNow
$deadline = $started.AddSeconds($TimeoutSeconds)
$count = 0
$reason = 'failed'
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add($Prefix)
function Write-Json([string]$Path,$Value) {
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 12),$utf8)
        [IO.File]::Move($temporary,$Path)
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
function Read-BoundedFile([string]$Path) {
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -lt 1 -or $stream.Length -gt 1MB) { throw 'Fixture file exceeds bound' }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes,$offset,$bytes.Length-$offset)
            if ($read -eq 0) { throw 'Truncated fixture file' }
            $offset += $read
        }
        return ,$bytes
    } finally { $stream.Dispose() }
}
function Is-Release([string]$Value) {
    return $Value -cmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:alpha|beta|nightly)\.[1-9][0-9]*)?$'
}
function Read-Selection {
    $value = $utf8.GetString((Read-BoundedFile (Join-Path $directory 'app-selection.json'))) | ConvertFrom-Json
    $names = @($value.PSObject.Properties.Name)
    if ($value -is [array] -or $names -notcontains 'releaseTrack' -or
        $value.releaseTrack -cnotin @('stable','development') -or
        @($names | Where-Object { $_ -cnotin @('releaseTrack','latestAppVersion','appUpdateAvailable') }).Count) {
        throw 'Invalid controlled App selection'
    }
    $hasVersion = $names -contains 'latestAppVersion'
    $hasAvailable = $names -contains 'appUpdateAvailable'
    if ($hasVersion -ne $hasAvailable -or ($hasVersion -and
        ((-not (Is-Release $value.latestAppVersion)) -or $value.appUpdateAvailable -isnot [bool]))) {
        throw 'Invalid controlled App offer'
    }
    return $value
}
try {
    $null = Read-Selection
    $listener.Start()
    Write-Json (Join-Path $directory 'ready.json') ([ordered]@{pid=$PID;prefix=$Prefix;startedAtUtc=$started.ToString('o');deadlineUtc=$deadline.ToString('o')})
    $reason='timeout'
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $stopPath) { $reason='stop-file'; break }
        $next = $listener.GetContextAsync()
        while (-not $next.Wait(200)) {
            if ((Test-Path -LiteralPath $stopPath) -or [DateTime]::UtcNow -ge $deadline) { break }
        }
        if (-not $next.IsCompleted) {
            if (Test-Path -LiteralPath $stopPath) { $reason='stop-file' }
            break
        }
        $context = $next.GetAwaiter().GetResult()
        $request = $context.Request
        $response = $context.Response
        $path = $request.Url.AbsolutePath
        $track = [string]$request.Headers['X-Go-Mapi-Release-Track']
        $installed = [string]$request.Headers['X-Go-Mapi-Installed-Version']
        # Never retain arbitrary headers, query values, malformed request bodies or credentials.
        $record = [ordered]@{atUtc=[DateTime]::UtcNow.ToString('o');method=$request.HttpMethod;
            path=if ($path -cin @('/machine/system/targets.json','/machine/suite/targets.json','/api/updates/v1/check')) {$path} else {'unserved'};
            status=500;releaseTrack=if ($track -cin @('stable','development')) {$track} else {''};
            installedVersion=if ((Is-Release $installed) -and $installed.Length -le 128) {$installed} else {''}}
        $status=404
        $body=$utf8.GetBytes('{"error":"unserved fixture route"}')
        try {
            $selection = Read-Selection
            if ($request.Url.Query) { $status=400 }
            elseif ($path -cin @('/machine/system/targets.json','/machine/suite/targets.json')) {
                if ($request.HttpMethod -cne 'GET') { $status=405 }
                elseif ($track -cne $selection.releaseTrack -or $request.HasEntityBody -or
                    ($installed -and (($installed.Length -gt 128) -or (-not (Is-Release $installed))))) { $status=400 }
                else {
                    $name = if ($path -ceq '/machine/system/targets.json') {'system-targets.json'} else {'suite-targets.json'}
                    $targetPath = Join-Path $directory $name
                    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) { $status=503 }
                    else { $body=Read-BoundedFile $targetPath; $status=200 }
                }
            } elseif ($path -ceq '/api/updates/v1/check') {
                if ($request.HttpMethod -cne 'POST') { $status=405 }
                elseif ($request.ContentLength64 -gt 4096) { $status=413 }
                elseif ($request.ContentType -notmatch '^application/json(?:\s*;\s*charset=utf-8)?$') { $status=415 }
                else {
                    $memory=[IO.MemoryStream]::new()
                    try {
                        $buffer=New-Object byte[] 4097
                        $bodyDeadline=[DateTime]::UtcNow.AddSeconds(5)
                        while ($memory.Length -le 4096) {
                            $pending=$request.InputStream.ReadAsync($buffer,0,[int](4097-$memory.Length))
                            $remaining=[Math]::Max(1,[int]($bodyDeadline-[DateTime]::UtcNow).TotalMilliseconds)
                            if (-not $pending.Wait($remaining)) { $status=408; break }
                            $read=$pending.GetAwaiter().GetResult()
                            if ($read -eq 0) { break }
                            $memory.Write($buffer,0,$read)
                        }
                        if ($status -ne 408) {
                            if ($memory.Length -gt 4096) { $status=413 }
                            else {
                                $status=400
                                $json=''
                                try { $json=$utf8.GetString($memory.ToArray()); $value=$json | ConvertFrom-Json } catch { $value=$null }
                                $expected=@('schema','appVersion','interceptorVersion','distributionChannel','releaseTrack','os','architecture')
                                $fields=if ($null -ne $value) {@($value.PSObject.Properties.Name | Sort-Object)} else {@()}
                                if ($json -notmatch '\\' -and [regex]::Matches($json,'"[^"\\]+"\s*:').Count -eq $expected.Count -and
                                    ($fields -join ',') -ceq (($expected | Sort-Object) -join ',') -and
                                    @($expected | Where-Object { $value.$_ -isnot [string] }).Count -eq 0 -and
                                    $value.schema -ceq 'go-mapi-update-check-v1' -and $value.os -ceq 'windows' -and $value.architecture -ceq 'x64' -and
                                    $value.distributionChannel -cin @('standalone','store') -and $value.releaseTrack -ceq $selection.releaseTrack -and
                                    $value.appVersion.Length -le 128 -and (Is-Release $value.appVersion) -and $value.interceptorVersion.Length -le 128 -and
                                    ($value.interceptorVersion -cin @('','absent','unknown') -or (Is-Release $value.interceptorVersion))) {
                                    $record.body=[ordered]@{}
                                    foreach ($field in $expected) { $record.body[$field]=$value.$field }
                                    $latest=$value.appVersion; $available=$false
                                    if ($selection.PSObject.Properties.Name -contains 'latestAppVersion') {
                                        $latest=$selection.latestAppVersion; $available=$selection.appUpdateAvailable
                                    }
                                    $interceptorLatest=if (Is-Release $value.interceptorVersion) {$value.interceptorVersion} else {''}
                                    $answer=[ordered]@{schema='go-mapi-update-check-v1';
                                        app=[ordered]@{installedVersion=$value.appVersion;latestVersion=$latest;updateAvailable=$available};
                                        interceptor=[ordered]@{installedVersion=$value.interceptorVersion;latestVersion=$interceptorLatest;updateAvailable=$false};
                                        compatibility='unknown'}
                                    $body=$utf8.GetBytes(($answer | ConvertTo-Json -Depth 5 -Compress)); $status=200
                                }
                            }
                        }
                    } finally { $memory.Dispose() }
                }
            }
        } catch { $status=500; $record.error='fixture-read-or-request-failure' }
        try {
            $response.StatusCode=$status
            $response.Headers['Cache-Control']='no-store'
            $response.ContentType='application/json; charset=utf-8'
            if ($status -ne 200) { $body=$utf8.GetBytes('{"error":"controlled fixture request refused"}') }
            $response.ContentLength64=$body.Length
            $response.OutputStream.Write($body,0,$body.Length)
        } catch { $record.responseError='client-disconnected' }
        finally {
            $record.status=$status; $record.bytes=$body.Length
            $hasher=[Security.Cryptography.SHA256]::Create()
            try {$record.responseSha256=([BitConverter]::ToString($hasher.ComputeHash($body))).Replace('-','').ToLowerInvariant()}
            finally {$hasher.Dispose()}
            try { $response.Close() } catch { }
            [IO.File]::AppendAllText($logPath,(($record | ConvertTo-Json -Depth 5 -Compress)+[Environment]::NewLine),$utf8)
            $count++
        }
    }
} finally {
    $listener.Close()
    Write-Json (Join-Path $directory 'final.json') ([ordered]@{pid=$PID;stoppedAtUtc=[DateTime]::UtcNow.ToString('o');reason=$reason;requests=$count})
}
