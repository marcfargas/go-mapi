# Compile harmless unsigned PE fixtures; never execute them or change trust.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'ServiceBuilds.ps1')
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Action,[string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Assert ($_.Exception.Message -match $Pattern) "Unexpected refusal: $_"
        return
    }
    throw "Expected refusal: $Pattern"
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('go-mapi-service-builds-'+[guid]::NewGuid().ToString('N'))
$environment=@{}
foreach($name in @('GOOS','GOARCH','CGO_ENABLED','GOWORK','GITHUB_ACTIONS','GITHUB_RUN_ID','GITHUB_RUN_ATTEMPT','ACT','MACHINE_RELEASE_METADATA_ORIGIN')) {
    $environment[$name]=[Environment]::GetEnvironmentVariable($name)
}
New-Item -ItemType Directory -Force $temp|Out-Null
try {
    $env:GOOS='windows';$env:GOARCH='amd64';$env:CGO_ENABLED='0';$env:GOWORK='off';$env:GITHUB_ACTIONS='';$env:ACT=''
    $spec=ReadFixtureSpecification (Join-Path $PSScriptRoot 'fixtures/machine.json')
    $settings=Get-ServiceBuildSettings $spec 'https://localhost:18453' 'https://localhost:18453/releases/download/' 60 $true
    $commit='a'*40
    $compiler=Join-Path $env:USERPROFILE 'scoop/apps/mingw-mstorsjo-llvm-ucrt/current/bin/x86_64-w64-mingw32-windres.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { throw 'Service admission PE tests require the maintained native resource compiler' }
    $source=Join-Path $temp 'source'
    New-Item -ItemType Directory $source|Out-Null
    Set-Content -LiteralPath (Join-Path $source 'go.mod') "module admission-fixture`ngo 1.25"
    Set-Content -LiteralPath (Join-Path $source 'main.go') 'package main; func main() {}'
    $template=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../service/version.rc.in') -Raw
    $entries=@(foreach($version in @($spec.versions.baseline,$spec.versions.serviceUpgrade,$spec.versions.packageNext)) {
        $resource=$template.Replace('@MAJOR@','5').Replace('@MINOR@','0').Replace('@PATCH@','1').Replace('@VERSION@',$version)
        $rc=Join-Path $source 'version.rc';$syso=Join-Path $source 'version_windows_amd64.syso'
        [IO.File]::WriteAllText($rc,$resource)
        & $compiler -i $rc -o $syso -O coff
        if ($LASTEXITCODE -ne 0) { throw 'Test PE resource build failed' }
        $filename="go-mapi-service-$version.exe";$destination=Join-Path $temp $filename
        Push-Location $source
        try { & go build -o $destination .; if ($LASTEXITCODE -ne 0) { throw 'Test PE build failed' } }
        finally { Pop-Location }
        [ordered]@{version=$version;filename=$filename;size=(Get-Item -LiteralPath $destination).Length;sha256=Get-ServiceBuildHash $destination}
    })
    $original=[ordered]@{schema='go-mapi-machine-service-builds-v1';publishable=$false;sourceCommit=$commit;
        specificationSha256=$spec.sha256;producer=Get-ServiceBuildProducer;settings=$settings;services=$entries}
    $path=Join-Path $temp 'service-builds.json'
    function WriteInventory($Manifest) { [IO.File]::WriteAllText($path,($Manifest|ConvertTo-Json -Depth 8)) }
    WriteInventory $original
    $admitted=Read-ServiceBuildManifest $path $spec $commit $settings
    Assert ($admitted.services.Count -eq 3 -and $admitted.sha256 -ceq (Get-ServiceBuildHash $path)) 'Valid unsigned service inventory rejected'
    foreach($mode in @('schema','schema-array','publishable','source','source-array','spec','spec-array','producer','producer-extra','origin','origin-array','artifact-origin','interval','timers','readiness','readiness-array','extra','missing','duplicate','version-array','filename','filename-array','traversal','absolute','size','hash','hash-array')) {
        $bad=$original|ConvertTo-Json -Depth 8|ConvertFrom-Json
        switch($mode) {
            schema {$bad.schema='wrong'} publishable {$bad.publishable=$true} source {$bad.sourceCommit='b'*40}
            schema-array {$bad.schema=@($bad.schema)} source-array {$bad.sourceCommit=@($bad.sourceCommit)}
            spec-array {$bad.specificationSha256=@($bad.specificationSha256)}
            spec {$bad.specificationSha256='b'*64} producer {$bad.producer.kind='github-actions'}
            producer-extra {$bad.producer|Add-Member unexpected 'x'}
            origin {$bad.settings.metadataOrigin='https://example.com'} artifact-origin {$bad.settings.artifactOrigin='https://example.com/'}
            origin-array {$bad.settings.metadataOrigin=@($bad.settings.metadataOrigin)}
            interval {$bad.settings.checkIntervalSeconds=60} timers {$bad.settings.timers.heartbeatSeconds=3}
            readiness {$bad.settings.readinessObstruction=$null}
            readiness-array {$bad.settings.readinessObstruction=@($bad.settings.readinessObstruction)}
            extra {$bad|Add-Member unexpected 'x'} missing {$bad.services=@($bad.services[0],$bad.services[1])}
            duplicate {$bad.services[2]=$bad.services[0]} filename {$bad.services[0].filename='other.exe'}
            version-array {$bad.services[0].version=@($bad.services[0].version)}
            filename-array {$bad.services[0].filename=@($bad.services[0].filename)}
            hash-array {$bad.services[0].sha256=@($bad.services[0].sha256)}
            traversal {$bad.services[0].filename='../outside.exe'} absolute {$bad.services[0].filename='C:\outside.exe'}
            size {$bad.services[0].size++} hash {$bad.services[0].sha256='b'*64}
        }
        WriteInventory $bad
        Reject { Read-ServiceBuildManifest $path $spec $commit $settings } 'mismatch|Unexpected|exactly three'
    }
    # Bytes can match the inventory yet still be the wrong architecture, header,
    # version or executable type. Exercise those refusals past the hash gate.
    $first=Join-Path $temp $entries[0].filename
    $bytes=[IO.File]::ReadAllBytes($first)
    foreach($mode in @('machine','header','magic','offset','version','truncated')) {
        $mutated=[byte[]]$bytes.Clone();$pe=[BitConverter]::ToInt32($mutated,0x3c)
        switch($mode) {
            machine {$mutated[$pe+4]=0x4c;$mutated[$pe+5]=0x01}
            header {$mutated[0]=0}
            magic {$mutated[$pe+24]=0x0b;$mutated[$pe+25]=0x01}
            offset {[BitConverter]::GetBytes([int]::MaxValue).CopyTo($mutated,0x3c)}
            version {$mutated=[IO.File]::ReadAllBytes((Join-Path $temp $entries[1].filename))}
            truncated {$mutated=[byte[]]@(1,2,3)}
        }
        [IO.File]::WriteAllBytes($first,$mutated)
        $bad=$original|ConvertTo-Json -Depth 8|ConvertFrom-Json
        $bad.services[0].size=$mutated.Length;$bad.services[0].sha256=Get-ServiceBuildHash $first
        WriteInventory $bad
        Reject { Read-ServiceBuildManifest $path $spec $commit $settings } 'PE|version mismatch'
    }
    [IO.File]::WriteAllBytes($first,$bytes)
    # Windows owns the signature decision; inject its refusal outcome without
    # creating a certificate, modifying trust, or signing anything on the host.
    function Get-AuthenticodeSignature { param($LiteralPath) [pscustomobject]@{Status='Valid'} }
    try {
        WriteInventory $original
        Reject { Read-ServiceBuildManifest $path $spec $commit $settings } 'must be unsigned'
    } finally { Remove-Item Function:Get-AuthenticodeSignature }
    $env:GITHUB_ACTIONS='true';$env:GITHUB_RUN_ID='123';$env:GITHUB_RUN_ATTEMPT='2'
    WriteInventory $original
    Reject { Read-ServiceBuildManifest $path $spec $commit $settings } 'producer'
    $hosted=$original|ConvertTo-Json -Depth 8|ConvertFrom-Json
    $hosted.producer=Get-ServiceBuildProducer
    WriteInventory $hosted
    Read-ServiceBuildManifest $path $spec $commit $settings|Out-Null
    $env:GITHUB_RUN_ATTEMPT='3'
    Reject { Read-ServiceBuildManifest $path $spec $commit $settings } 'producer mismatch'
    $env:ACT='true'
    WriteInventory $original
    Read-ServiceBuildManifest $path $spec $commit $settings|Out-Null
    # Production-timer inventories have no readiness validation or timer object.
    $env:GITHUB_ACTIONS='';$env:ACT=''
    $production=Get-ServiceBuildSettings $spec $settings.metadataOrigin $settings.artifactOrigin 60 $false
    $plain=$original|ConvertTo-Json -Depth 8|ConvertFrom-Json;$plain.settings=$production
    WriteInventory $plain
    Read-ServiceBuildManifest $path $spec $commit $production|Out-Null
    Reject { Read-ServiceBuildManifest $path $spec $commit $settings } 'interval mismatch|setting mismatch'
    $plain.settings.readinessObstruction=@()
    WriteInventory $plain
    Reject { Read-ServiceBuildManifest $path $spec $commit $production } 'setting mismatch'

    # A failed archived-source build must remove a stale success inventory,
    # restore the caller's environment and clean its owned temporary archive.
    $failedRepo=Join-Path $temp 'failed-source'
    $failedService=Join-Path $failedRepo 'src/service'
    New-Item -ItemType Directory -Force $failedService|Out-Null
    Set-Content (Join-Path $failedService 'build.ps1') "throw 'injected service build failure'"
    Set-Content (Join-Path $failedService 'VERSION') '1.0.0'
    & git init --quiet --initial-branch=main $failedRepo
    if ($LASTEXITCODE -ne 0) { throw 'Cannot prepare producer failure fixture' }
    & git -C $failedRepo add src
    if ($LASTEXITCODE -ne 0) { throw 'Cannot stage producer failure fixture' }
    & git -C $failedRepo -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'Cannot commit producer failure fixture' }
    $failedCommit=(& git -C $failedRepo rev-parse HEAD).Trim()
    $failedOutput=Join-Path $temp 'failed-output'
    New-Item -ItemType Directory $failedOutput|Out-Null
    Set-Content (Join-Path $failedOutput 'service-builds.json') 'stale success'
    $env:MACHINE_RELEASE_METADATA_ORIGIN='https://caller.example'
    Reject { New-ServiceBuilds $failedRepo ($failedOutput+[IO.Path]::DirectorySeparatorChar) $spec $failedCommit $settings } 'injected service build failure'
    Assert (-not (Test-Path (Join-Path $failedOutput 'service-builds.json'))) 'Failed producer retained stale success inventory'
    Assert (@(Get-ChildItem -LiteralPath $failedOutput -Force -Filter '.source-*').Count -eq 0) 'Failed producer retained source archive'
    Assert ($env:MACHINE_RELEASE_METADATA_ORIGIN -ceq 'https://caller.example') 'Failed producer changed caller environment'
    Write-Host 'Unsigned service inventory source, settings, identity, bytes and PE admission checks passed'
} finally {
    foreach($name in $environment.Keys) { [Environment]::SetEnvironmentVariable($name,$environment[$name]) }
    if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}
