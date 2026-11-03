function ReadFixtureSpecification([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Self-signed fixtures require -FixtureSpecification' }
    $path = [IO.Path]::GetFullPath($Path)
    $spec = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($spec.schema -cne 'go-mapi-machine-fixture-spec-v1') { throw 'Unknown machine fixture specification schema' }
    $order = @{}
    foreach ($role in @('baseline','serviceUpgrade','packageNext','appUpgrade')) {
        $value = [string]$spec.versions.$role
        # This fixed development fixture uses alpha releases. General release
        # validation and MSI identity derivation remain owned by machine-package.
        if ($value -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-alpha\.([1-9][0-9]?)$' -or
            [int]$Matches[1] -gt 255 -or [int]$Matches[1]%2 -ne 1 -or [int]$Matches[2] -gt 255 -or [int]$Matches[3] -gt 65) {
            throw "Invalid alpha fixture version for $role`: $value"
        }
        $order[$role] = [version]::new([int]$Matches[1],[int]$Matches[2],[int]$Matches[3],[int]$Matches[4])
    }
    if ($order.baseline -ge $order.serviceUpgrade -or $order.serviceUpgrade -ge $order.packageNext -or
        $order.baseline -ge $order.appUpgrade) { throw 'Fixture versions must advance baseline -> serviceUpgrade -> packageNext and baseline -> appUpgrade' }
    foreach ($bound in @(@('startupDelaySeconds',120),@('heartbeatSeconds',60),@('checkIntervalSeconds',86400),@('failureDelayBaseSeconds',900))) {
        $value = $spec.timers.($bound[0])
        if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt $bound[1]) { throw "Fixture timer $($bound[0]) must shorten the production values" }
    }
    $v = $spec.versions
    [pscustomobject]@{
        path=$path; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); versions=$v; timers=$spec.timers
        cases=@(
            @{ key='systemA'; sku='system'; release=$v.baseline; service=$v.baseline },
            @{ key='systemB'; sku='system'; release=$v.serviceUpgrade; service=$v.serviceUpgrade },
            @{ key='systemC'; sku='system'; release=$v.packageNext; service=$v.packageNext },
            @{ key='suiteA'; sku='suite'; release=$v.baseline; service=$v.baseline },
            @{ key='suiteB'; sku='suite'; release=$v.serviceUpgrade; service=$v.serviceUpgrade },
            @{ key='suiteC'; sku='suite'; release=$v.packageNext; service=$v.serviceUpgrade }
        )
    }
}
function Get-ServiceBuildSettings($Specification, [string]$MetadataOrigin, [string]$ArtifactOrigin,
    [int]$CheckIntervalSeconds, [bool]$ValidationTimers) {
    if ($CheckIntervalSeconds -lt 60 -or $CheckIntervalSeconds -gt 86400) { throw 'Check interval outside production build bounds' }
    $metadataUri=$null; $artifactUri=$null
    if ($MetadataOrigin -notmatch '^https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?$' -or
        -not [Uri]::TryCreate($MetadataOrigin,[UriKind]::Absolute,[ref]$metadataUri) -or
        $metadataUri.UserInfo -or $metadataUri.Query -or $metadataUri.Fragment -or $metadataUri.AbsolutePath -ne '/') { throw 'Invalid service metadata origin' }
    if (-not [Uri]::TryCreate($ArtifactOrigin,[UriKind]::Absolute,[ref]$artifactUri) -or
        $artifactUri.Scheme -ne 'https' -or -not $artifactUri.Host -or $artifactUri.UserInfo -or
        $artifactUri.Query -or $artifactUri.Fragment -or -not $ArtifactOrigin.EndsWith('/')) { throw 'Invalid service artifact origin' }
    [ordered]@{
        metadataOrigin=$MetadataOrigin; artifactOrigin=$ArtifactOrigin
        checkIntervalSeconds=if ($ValidationTimers) { $Specification.timers.checkIntervalSeconds } else { $CheckIntervalSeconds }
        timers=if ($ValidationTimers) { $Specification.timers } else { $null }
        readinessObstruction=if ($ValidationTimers) { 'target-bound-pre-run-v1' } else { $null }
    }
}
function Get-ServiceBuildProducer {
    if ($env:GITHUB_ACTIONS -eq 'true' -and -not $env:ACT) {
        if (-not $env:GITHUB_RUN_ID -or -not $env:GITHUB_RUN_ATTEMPT) { throw 'Missing service build workflow identity' }
        return [ordered]@{kind='github-actions';runId=$env:GITHUB_RUN_ID;runAttempt=$env:GITHUB_RUN_ATTEMPT}
    }
    [ordered]@{kind='local'}
}
function Assert-ServiceBuildFields($Value, [string[]]$Fields, [string]$Label) {
    if ((@($Value.PSObject.Properties.Name | Sort-Object) -join ',') -cne (@($Fields | Sort-Object) -join ',')) {
        throw "Unexpected $Label fields"
    }
}
function Get-ServiceBuildHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-UnsignedServicePe([string]$Path, [string]$Version) {
    $file = Get-Item -LiteralPath $Path
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Service input cannot be a reparse point' }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw 'Service input is not an x64 PE' }
        $stream.Position=0x3c; $offset=$reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $stream.Length-26) { throw 'Service input has invalid PE header' }
        $stream.Position=$offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw 'Service input is not an x64 PE' }
        $stream.Position=$offset+24
        if ($reader.ReadUInt16() -ne 0x20b) { throw 'Service input is not PE32+' }
    } finally { $stream.Dispose() }
    if ($file.VersionInfo.ProductVersion -cne $Version -or $file.VersionInfo.FileVersion -cne $Version) { throw 'Service PE version mismatch' }
    if ((Get-AuthenticodeSignature -LiteralPath $Path).Status -ne 'NotSigned') { throw 'Service build input must be unsigned' }
}
function Read-ServiceBuildManifest([string]$Path, $Specification, [string]$Commit, $Settings) {
    $path = [IO.Path]::GetFullPath($Path)
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-ServiceBuildFields $manifest @('schema','publishable','sourceCommit','specificationSha256','producer','settings','services') 'service build manifest'
    if ($manifest.schema -isnot [string] -or $manifest.sourceCommit -isnot [string] -or
        $manifest.specificationSha256 -isnot [string] -or
        $manifest.schema -cne 'go-mapi-machine-service-builds-v1' -or $manifest.publishable -isnot [bool] -or
        $manifest.publishable -ne $false -or $manifest.sourceCommit -cne $Commit -or
        $manifest.specificationSha256 -cne $Specification.sha256) { throw 'Service build source or specification mismatch' }
    $producer = Get-ServiceBuildProducer
    Assert-ServiceBuildFields $manifest.producer @($producer.Keys) 'service producer'
    foreach ($key in $producer.Keys) {
        if ($manifest.producer.$key -isnot [string] -or $manifest.producer.$key -cne $producer[$key]) { throw "Service build producer mismatch: $key" }
    }
    Assert-ServiceBuildFields $manifest.settings @($Settings.Keys) 'service settings'
    foreach ($key in @('metadataOrigin','artifactOrigin','readinessObstruction')) {
        if ($null -eq $Settings[$key]) {
            if ($null -ne $manifest.settings.$key) { throw "Service build setting mismatch: $key" }
        } elseif ($manifest.settings.$key -isnot [string] -or $manifest.settings.$key -cne $Settings[$key]) {
            throw "Service build setting mismatch: $key"
        }
    }
    if (($manifest.settings.checkIntervalSeconds -isnot [int] -and $manifest.settings.checkIntervalSeconds -isnot [long]) -or
        $manifest.settings.checkIntervalSeconds -ne $Settings.checkIntervalSeconds) { throw 'Service build check interval mismatch' }
    if ($Settings.timers) {
        Assert-ServiceBuildFields $manifest.settings.timers @('startupDelaySeconds','heartbeatSeconds','checkIntervalSeconds','failureDelayBaseSeconds') 'service timers'
        foreach ($key in @('startupDelaySeconds','heartbeatSeconds','checkIntervalSeconds','failureDelayBaseSeconds')) {
            $value=$manifest.settings.timers.$key
            if (($value -isnot [int] -and $value -isnot [long]) -or $value -ne $Settings.timers.$key) { throw "Service build timer mismatch: $key" }
        }
    } elseif ($null -ne $manifest.settings.timers) { throw 'Unexpected service validation timers' }
    $versions=@($Specification.versions.baseline,$Specification.versions.serviceUpgrade,$Specification.versions.packageNext)
    if (@($manifest.services).Count -ne 3) { throw 'Service build must contain exactly three versions' }
    $admitted=@{}
    foreach ($entry in $manifest.services) {
        Assert-ServiceBuildFields $entry @('version','filename','size','sha256') 'service entry'
        if ($entry.version -isnot [string] -or $entry.filename -isnot [string] -or $entry.sha256 -isnot [string] -or
            $entry.version -cnotin $versions -or $admitted.ContainsKey([string]$entry.version) -or
            $entry.filename -cne "go-mapi-service-$($entry.version).exe") { throw 'Service build filename or version set mismatch' }
        $file=Join-Path (Split-Path $path) $entry.filename
        if (($entry.size -isnot [int] -and $entry.size -isnot [long]) -or $entry.size -le 0 -or
            $entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or -not (Test-Path -LiteralPath $file -PathType Leaf) -or
            (Get-Item -LiteralPath $file).Length -ne $entry.size -or (Get-ServiceBuildHash $file) -cne $entry.sha256) { throw 'Service build bytes mismatch' }
        Assert-UnsignedServicePe $file $entry.version
        $admitted[$entry.version]=[pscustomobject]@{path=$file;sha256=$entry.sha256;size=$entry.size}
    }
    [pscustomobject]@{path=$path;sha256=Get-ServiceBuildHash $path;services=$admitted}
}
function New-ServiceBuilds([string]$Repository, [string]$OutputDirectory, $Specification, [string]$Commit, $Settings) {
    $output=[IO.Path]::GetFullPath($OutputDirectory)
    New-Item -ItemType Directory -Force $output | Out-Null
    $manifestPath=Join-Path $output 'service-builds.json'
    if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force -ErrorAction Stop }
    $temporary=Join-Path $output ('.source-' + [guid]::NewGuid().ToString('N'))
    $source=Join-Path $temporary 'source'; $archive=Join-Path $temporary 'source.zip'
    New-Item -ItemType Directory -Force $source | Out-Null
    $originalOrigin=$env:MACHINE_RELEASE_METADATA_ORIGIN
    try {
        & git -C $Repository archive --format=zip -o $archive $Commit
        if ($LASTEXITCODE -ne 0) { throw 'Could not archive service source commit' }
        Expand-Archive -LiteralPath $archive -DestinationPath $source
        $env:MACHINE_RELEASE_METADATA_ORIGIN=$Settings.metadataOrigin
        $entries=@(foreach ($version in @($Specification.versions.baseline,$Specification.versions.serviceUpgrade,$Specification.versions.packageNext)) {
            Set-Content -LiteralPath (Join-Path $source 'src/service/VERSION') -Value $version -NoNewline -Encoding ascii
            $filename="go-mapi-service-$version.exe"; $destination=Join-Path $output $filename
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            $arguments=@{OutputPath=$destination;ArtifactOrigin=$Settings.artifactOrigin;CheckIntervalSeconds=$Settings.checkIntervalSeconds}
            if ($Settings.timers) {
                $arguments.ValidationStartupDelaySeconds=$Settings.timers.startupDelaySeconds
                $arguments.ValidationHeartbeatSeconds=$Settings.timers.heartbeatSeconds
                $arguments.ValidationFailureBaseSeconds=$Settings.timers.failureDelayBaseSeconds
                $arguments.ValidationReadinessFault=$true
            }
            & (Join-Path $source 'src/service/build.ps1') @arguments
            Assert-UnsignedServicePe $destination $version
            [ordered]@{version=$version;filename=$filename;size=(Get-Item -LiteralPath $destination).Length;sha256=Get-ServiceBuildHash $destination}
        })
        $manifest=[ordered]@{schema='go-mapi-machine-service-builds-v1';publishable=$false;sourceCommit=$Commit;
            specificationSha256=$Specification.sha256;producer=Get-ServiceBuildProducer;settings=$Settings;services=$entries}
        [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        Read-ServiceBuildManifest $manifestPath $Specification $Commit $Settings
    } catch {
        Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        $env:MACHINE_RELEASE_METADATA_ORIGIN=$originalOrigin
        if ([IO.Path]::GetFullPath($temporary).StartsWith($output.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $temporary -Recurse -Force
        }
    }
}
