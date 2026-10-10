Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-HostedCapabilityFileHash {
    param([Parameter(Mandatory)][string] $Path,[scriptblock] $HashProvider)
    if($HashProvider){return [string](& $HashProvider $Path)}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$stream=[IO.File]::OpenRead($Path);try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose()}}
    finally{$sha.Dispose()}
}

function Test-HostedCapabilityEvidenceIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $SourceSHA,
        [scriptblock] $HashProvider
    )
    $indexPath=Join-Path $Directory 'evidence-index.json'
    if(!(Test-Path -LiteralPath $indexPath -PathType Leaf)){return [pscustomobject]@{valid=$false;reason='index-missing';indexSHA256=$null;entryCount=0}}
    try{
        $Directory=(Get-Item -LiteralPath $Directory -ErrorAction Stop).FullName
        $indexPath=(Get-Item -LiteralPath $indexPath -ErrorAction Stop).FullName
        $index=Get-Content -LiteralPath $indexPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if($index.schema -cne 'ticket569-evidence-index-v1' -or $index.runId -cne $RunId -or $index.sourceSHA -cne $SourceSHA){throw 'index identity/schema mismatch'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($entry in @($index.files)){
            $relative=[string]$entry.path
            if(!$relative -or $relative.Contains(':') -or [IO.Path]::IsPathRooted($relative) -or $relative.StartsWith('/') -or $relative.Contains([string][char]92) -or $relative.Split('/').Contains('..') -or !$seen.Add($relative)){throw 'index path is invalid or duplicated'}
            $path=Join-Path $Directory ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))
            if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw "indexed file is missing: $relative"}
            $item=Get-Item -LiteralPath $path -ErrorAction Stop
            if([long]$item.Length -ne [long]$entry.sizeBytes){throw "indexed file size mismatch: $relative"}
            $digest=Get-HostedCapabilityFileHash -Path $path -HashProvider $HashProvider
            if($digest -notmatch '^[a-f0-9]{64}$' -or $digest -cne [string]$entry.sha256){throw "indexed file SHA-256 mismatch: $relative"}
        }
        $actual=@(Get-ChildItem -LiteralPath $Directory -File -Recurse -ErrorAction Stop | Where-Object {$_.FullName -cne $indexPath})
        if($actual.Count -ne $seen.Count){throw 'actual evidence file set differs from the indexed upload set'}
        foreach($file in $actual){
            $relative=[IO.Path]::GetRelativePath($Directory,$file.FullName).Replace([char]92,[char]'/')
            if(!$seen.Contains($relative) -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'unindexed or linked evidence file is outside the audited upload set'}
        }
        $indexDigest=Get-HostedCapabilityFileHash -Path $indexPath -HashProvider $HashProvider
        if($indexDigest -notmatch '^[a-f0-9]{64}$'){throw 'index SHA-256 provider returned malformed output'}
        [pscustomobject]@{valid=$true;reason=$null;indexSHA256=$indexDigest;entryCount=@($index.files).Count}
    }catch{[pscustomobject]@{valid=$false;reason='index-invalid';detail=$_.Exception.Message;indexSHA256=$null;entryCount=0}}
}

function New-HostedCapabilityEvidenceIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $SourceSHA,
        [scriptblock] $HashProvider
    )
    if(!(Test-Path -LiteralPath $Directory -PathType Container)){throw 'Evidence directory is missing'}
    $Directory=(Get-Item -LiteralPath $Directory -ErrorAction Stop).FullName
    $indexPath=Join-Path $Directory 'evidence-index.json'
    if(Test-Path -LiteralPath $indexPath -PathType Leaf){$indexPath=(Get-Item -LiteralPath $indexPath -ErrorAction Stop).FullName}
    $entries=@(Get-ChildItem -LiteralPath $Directory -File -Recurse -ErrorAction Stop | Where-Object {$_.FullName -cne $indexPath} | Sort-Object FullName | ForEach-Object {
        $relative=[IO.Path]::GetRelativePath($Directory,$_.FullName).Replace([char]92,[char]'/')
        @{path=$relative;sizeBytes=[long]$_.Length;sha256=(Get-HostedCapabilityFileHash -Path $_.FullName -HashProvider $HashProvider)}
    })
    if(!$entries.Count){throw 'Evidence index refuses an empty evidence directory'}
    $index=@{schema='ticket569-evidence-index-v1';runId=$RunId;sourceSHA=$SourceSHA;files=$entries}
    $temporary=$indexPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $index -Depth 8 -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$indexPath,$true)
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}}
    $validation=Test-HostedCapabilityEvidenceIndex -Directory $Directory -RunId $RunId -SourceSHA $SourceSHA -HashProvider $HashProvider
    if(!$validation.valid){throw "Generated evidence index failed independent validation: $($validation.reason) $($validation.detail)"}
    $validation
}

function Resolve-HostedCapabilityRetention {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('not-started','attempted-failed','attempted-unverified')][string] $InitialStatus,
        [string] $IndexPath,
        [string] $DownloadedDirectory,
        [string] $RunId,
        [string] $SourceSHA,
        [bool] $ArtifactObservedByRoot=$false,
        [scriptblock] $HashProvider
    )
    if($InitialStatus -ne 'attempted-unverified'){
        return [pscustomobject]@{status=$InitialStatus;verified=$false;reason='upload-not-successfully-attempted'}
    }
    if(!$ArtifactObservedByRoot -or !$IndexPath -or !$DownloadedDirectory){
        return [pscustomobject]@{status='attempted-unverified';verified=$false;reason='root-artifact-api-or-download-unavailable'}
    }
    if(!(Test-Path -LiteralPath $IndexPath -PathType Leaf) -or !(Test-Path -LiteralPath $DownloadedDirectory -PathType Container)){
        return [pscustomobject]@{status='attempted-unverified';verified=$false;reason='downloaded-artifact-or-index-missing'}
    }
    $localIndex=Join-Path $DownloadedDirectory 'evidence-index.json'
    try{
        $expected=Get-Content -LiteralPath $IndexPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $downloaded=Get-Content -LiteralPath $localIndex -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if($expected.schema -cne 'ticket569-evidence-index-v1' -or $expected.runId -cne $RunId -or $expected.sourceSHA -cne $SourceSHA -or
           (Get-HostedCapabilityFileHash -Path $IndexPath -HashProvider $HashProvider) -cne (Get-HostedCapabilityFileHash -Path $localIndex -HashProvider $HashProvider)){
            return [pscustomobject]@{status='attempted-unverified';verified=$false;reason='downloaded-index-missing-or-mismatch'}
        }
        $audit=Test-HostedCapabilityEvidenceIndex -Directory $DownloadedDirectory -RunId $RunId -SourceSHA $SourceSHA -HashProvider $HashProvider
        if(!$audit.valid){return [pscustomobject]@{status='attempted-unverified';verified=$false;reason='downloaded-bytes-missing-or-mismatch';detail=$audit.detail}}
        [pscustomobject]@{status='verified';verified=$true;reason=$null;indexSHA256=$audit.indexSHA256;entryCount=$audit.entryCount;auditedAtUtc=[DateTime]::UtcNow.ToString('o')}
    }catch{[pscustomobject]@{status='attempted-unverified';verified=$false;reason='artifact-api-or-audit-unavailable';detail=$_.Exception.Message}}
}

Export-ModuleMember -Function New-HostedCapabilityEvidenceIndex, Test-HostedCapabilityEvidenceIndex, Resolve-HostedCapabilityRetention
