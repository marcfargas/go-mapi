$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-index.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('ticket569-index-'+[guid]::NewGuid().ToString('N'))
$download=Join-Path $root 'downloaded'
New-Item -ItemType Directory -Path $root | Out-Null
$run='a4c071dd8c774e9bab2be183fa6436cd';$source='a'*40
try{
    $sourceDir=Join-Path $root 'source';New-Item -ItemType Directory -Path $sourceDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $sourceDir 'one.json'),'one',[Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Path (Join-Path $sourceDir 'nested') | Out-Null
    [IO.File]::WriteAllText((Join-Path $sourceDir 'nested/two.json'),'two',[Text.UTF8Encoding]::new($false))
    $created=New-HostedCapabilityEvidenceIndex -Directory $sourceDir -RunId $run -SourceSHA $source
    if(!$created.valid -or $created.entryCount -ne 2 -or $created.indexSHA256 -notmatch '^[a-f0-9]{64}$'){throw 'index writer failed to emit and locally audit normalized per-file size/SHA-256 evidence'}
    if((Test-HostedCapabilityEvidenceIndex -Directory $sourceDir -RunId ('b'*32) -SourceSHA $source).valid){throw 'index auditor accepted the wrong run binding'}
    if((Test-HostedCapabilityEvidenceIndex -Directory $sourceDir -RunId $run -SourceSHA ('b'*40)).valid){throw 'index auditor accepted the wrong source binding'}

    $missingRoot=Join-Path $root 'missing';New-Item -ItemType Directory -Path $missingRoot | Out-Null
    $missing=Resolve-HostedCapabilityRetention -InitialStatus attempted-unverified -IndexPath (Join-Path $sourceDir 'evidence-index.json') -DownloadedDirectory $missingRoot -RunId $run -SourceSHA $source -ArtifactObservedByRoot $true
    if($missing.status -cne 'attempted-unverified' -or $missing.verified){throw 'missing downloaded index was treated as retained evidence'}

    Copy-Item -LiteralPath $sourceDir -Destination $download -Recurse
    $correct=Resolve-HostedCapabilityRetention -InitialStatus attempted-unverified -IndexPath (Join-Path $sourceDir 'evidence-index.json') -DownloadedDirectory $download -RunId $run -SourceSHA $source -ArtifactObservedByRoot $true
    if($correct.status -cne 'verified' -or !$correct.verified -or $correct.entryCount -ne 2){throw 'correct independently downloaded bytes did not pass complete index verification'}
    $apiUnavailable=Resolve-HostedCapabilityRetention -InitialStatus attempted-unverified -IndexPath (Join-Path $sourceDir 'evidence-index.json') -DownloadedDirectory $download -RunId $run -SourceSHA $source -ArtifactObservedByRoot $false
    if($apiUnavailable.status -cne 'attempted-unverified' -or $apiUnavailable.verified){throw 'local downloaded bytes bypassed missing root artifact API observation'}

    [IO.File]::WriteAllText((Join-Path $download 'one.json'),'bad',[Text.UTF8Encoding]::new($false))
    $changed=Resolve-HostedCapabilityRetention -InitialStatus attempted-unverified -IndexPath (Join-Path $sourceDir 'evidence-index.json') -DownloadedDirectory $download -RunId $run -SourceSHA $source -ArtifactObservedByRoot $true
    if($changed.status -cne 'attempted-unverified' -or $changed.verified){throw 'changed downloaded artifact bytes passed retention audit'}
    Remove-Item -LiteralPath (Join-Path $download 'one.json') -Force
    $absent=Resolve-HostedCapabilityRetention -InitialStatus attempted-unverified -IndexPath (Join-Path $sourceDir 'evidence-index.json') -DownloadedDirectory $download -RunId $run -SourceSHA $source -ArtifactObservedByRoot $true
    if($absent.status -cne 'attempted-unverified' -or $absent.verified){throw 'missing indexed artifact file passed retention audit'}

    $indexPath=Join-Path $download 'evidence-index.json'
    $index=Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
    $index.files[0].path='../outside.json'
    [IO.File]::WriteAllText($indexPath,(ConvertTo-Json -InputObject $index -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
    if((Test-HostedCapabilityEvidenceIndex -Directory $download -RunId $run -SourceSHA $source).valid){throw 'index auditor accepted parent traversal in indexed path'}

    # Finals that appear after the worker scan must be included by closeout,
    # and any later unindexed file must invalidate the upload set.
    foreach($name in @('supervisor-complete.json','watchdog-result.json','watchdog-retained-participants.json')){[IO.File]::WriteAllText((Join-Path $sourceDir $name),'final')}
    if((Test-HostedCapabilityEvidenceIndex -Directory $sourceDir -RunId $run -SourceSHA $source).valid){throw 'Auditor ignored files added after indexing'}
    $late=New-HostedCapabilityEvidenceIndex -Directory $sourceDir -RunId $run -SourceSHA $source
    if(!$late.valid -or $late.entryCount -ne 5){throw 'Closeout index omitted final supervisor/watchdog evidence'}
    $unavailable={param($path)throw 'injected SHA-256 API unavailable'}.GetNewClosure()
    $failed=Resolve-HostedCapabilityRetention -InitialStatus attempted-unverified -IndexPath (Join-Path $sourceDir 'evidence-index.json') -DownloadedDirectory $sourceDir -RunId $run -SourceSHA $source -ArtifactObservedByRoot $true -HashProvider $unavailable
    if($failed.status -cne 'attempted-unverified' -or $failed.verified){throw 'unavailable hashing API bypassed the retention audit'}
    foreach($status in @('not-started','attempted-failed')){
        $retention=Resolve-HostedCapabilityRetention -InitialStatus $status
        if($retention.status -cne $status -or $retention.verified){throw "retention audit promoted $status without root download proof"}
    }
}finally{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
Write-Output 'HOSTED_CAPABILITY_INDEX_TESTS_PASSED'
