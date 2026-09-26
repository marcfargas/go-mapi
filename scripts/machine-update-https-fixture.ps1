# Child process for the native updater test. The parent owns the HTTPS binding
# and certificate. Only two fixed target paths and manifest-listed MSI paths
# can be served; no arbitrary filesystem paths enter through the URL.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageManifest,
    [Parameter(Mandatory)][string]$FixtureDirectory,
    [Parameter(Mandatory)][int]$Port
)
$ErrorActionPreference = 'Stop'
$manifest = Get-Content -LiteralPath $PackageManifest -Raw | ConvertFrom-Json
$directory = [IO.Path]::GetFullPath($FixtureDirectory)
New-Item -ItemType Directory -Force $directory | Out-Null
$log = Join-Path $directory 'requests.ndjson'
$selection = Join-Path $directory 'target-selection.json'
$stop = Join-Path $directory 'stop'
$caseKeys = @('systemA','systemB','systemC','suiteA','suiteB','suiteC')
$wrongSkuSystem = if ($manifest.PSObject.Properties['references'] -and $manifest.references.PSObject.Properties['wrongSkuSystem']) {
    $manifest.references.wrongSkuSystem
} else { $null }
if ($wrongSkuSystem -and ($wrongSkuSystem.package.sku -cne 'system' -or
    (Get-FileHash -LiteralPath $wrongSkuSystem.sourceManifest -Algorithm SHA256).Hash.ToLowerInvariant() -cne $wrongSkuSystem.sourceManifestSha256 -or
    (Get-FileHash -LiteralPath $wrongSkuSystem.package.msi -Algorithm SHA256).Hash.ToLowerInvariant() -cne $wrongSkuSystem.package.sha256)) {
    throw 'Wrong-SKU system fixture reference changed'
}
$pendingPath = Join-Path $env:ProgramData 'go-mapi\service\pending-v2.json'
if (Test-Path -LiteralPath $pendingPath) {
    # At startup the service is delayed; capture the protected pre-reconcile
    # record under the new boot identity before serving release traffic.
    $observation = [ordered]@{
        bootTimeUtc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        capturedAtUtc=[DateTime]::UtcNow.ToString('o')
        pending=(Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json)
    }
    [IO.File]::WriteAllText((Join-Path $directory 'startup-pending.json'), ($observation | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("https://localhost:$Port/")
$listener.Start()
try {
    while (-not (Test-Path -LiteralPath $stop)) {
        $next = $listener.GetContextAsync()
        while (-not $next.Wait(500)) {
            if (Test-Path -LiteralPath $stop) { break }
        }
        if (-not $next.IsCompleted) { break }
        $context = $next.GetAwaiter().GetResult()
        $requestPath = $context.Request.Url.AbsolutePath
        $record = [ordered]@{ atUtc=[DateTime]::UtcNow.ToString('o'); method=$context.Request.HttpMethod; path=$requestPath; status=404 }
        try {
            $path = $null
            if ($requestPath -in @('/machine/system/targets.json','/machine/suite/targets.json') -and (Test-Path -LiteralPath $selection)) {
                $chosen = Get-Content -LiteralPath $selection -Raw | ConvertFrom-Json
                $sku = if ($requestPath -eq '/machine/system/targets.json') { 'system' } else { 'suite' }
                $key = if ($chosen.PSObject.Properties.Name -contains $sku) { [string]$chosen.$sku } elseif ($sku -eq 'system') { [string]$chosen.key } else { '' }
                # A deliberately wrong-SKU key is allowed only for an explicit
                # negative; normal selections cannot cross the SKU boundary.
                $package = if ($key -eq 'systemB' -and $wrongSkuSystem) { $wrongSkuSystem.package } else { $manifest.packages.$key }
                if ($key -in $caseKeys -and $package -and
                    ($package.sku -eq $sku -or $chosen.negativeWrongSku -eq $true)) {
                    $path = Join-Path $directory "$key-targets.json"
                }
            } else {
                foreach ($key in $caseKeys) {
                    $package = $manifest.packages.$key
                    if (-not $package) { continue }
                    $expected = "/releases/download/$($package.identity.tag)/$($package.identity.assetName)"
                    if ($requestPath -ceq $expected -and (Get-FileHash -LiteralPath $package.msi -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $package.sha256) {
                        $path = $package.msi; break
                    }
                }
            }
            if ($context.Request.HttpMethod -ne 'GET') { $context.Response.StatusCode = 405; $record.status = 405 }
            elseif ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                $stream = [IO.File]::OpenRead($path)
                try {
                    $context.Response.StatusCode = 200
                    $context.Response.ContentType = if ($path.EndsWith('.json')) { 'application/json' } else { 'application/octet-stream' }
                    $context.Response.ContentLength64 = $stream.Length
                    $stream.CopyTo($context.Response.OutputStream)
                    $record.status = 200
                    $record.bytes = $stream.Length
                } finally { $stream.Dispose() }
            } else { $context.Response.StatusCode = 404 }
        } catch {
            $record.error = $_.Exception.Message
            try { $context.Response.StatusCode = 500 } catch { }
        } finally {
            try { $context.Response.Close() } catch { }
            Add-Content -LiteralPath $log -Value ($record | ConvertTo-Json -Compress) -Encoding utf8
        }
    }
} finally { $listener.Stop(); $listener.Close() }
