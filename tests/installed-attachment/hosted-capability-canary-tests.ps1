$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-owner.psm1') -Force
$temp=Join-Path ([IO.Path]::GetTempPath()) ('t569-canary-sharing-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
$writer=$null;$ledger=$null
try{
    $secret='Ticket569-local-canary-aA1!'
    $secure=ConvertTo-SecureString $secret -AsPlainText -Force
    $canary=New-HostedSecretCanary $secure
    $data=New-Object byte[] (1MB)
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($data)}finally{$rng.Dispose()}
    [IO.File]::WriteAllBytes((Join-Path $temp 'realistic-screen.png'),$data)
    [IO.File]::WriteAllText((Join-Path $temp 'process-evidence.json'),('"CIM-serialized-process-facts"'*4096))
    $run=[guid]::NewGuid().ToString('N');$source='a'*40
    $ledger=New-HostedCapabilityLedger -Directory (Join-Path $temp 'supervisor') -RunId $run -SourceSHA $source -BootMarker 'test' -JobStartCounter 1 -CounterFrequency 1
    Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='process';operation='actual-open-writer-fixture'}|Out-Null
    $replay=Read-HostedCapabilityLedger -Directory $ledger.Directory -RunId $run -SourceSHA $source
    if(!$replay.valid){throw 'Production ledger reader failed while sole writer remained open'}
    $denied=$false;$secondWriter=$null
    try{$secondWriter=[IO.FileStream]::new((Join-Path $ledger.Directory 'events.ndjson'),[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)}catch [IO.IOException]{$denied=$true}finally{if($secondWriter){$secondWriter.Dispose()}}
    if($IsWindows -and !$denied){throw 'Concurrent reader sharing weakened exclusive writer ownership'}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $scan=Test-HostedSecretCanary -Directories @($temp) -Sha256 $canary.sha256 -Length $canary.length -RollingFingerprint $canary.rollingFingerprint
    if($scan.leaked -or !$scan.bounded -or $scan.bytesRead -lt 1MB){throw 'Realistic open-writer canary scan did not complete cleanly'}
    Write-Output "LOCAL_CANARY_MEASUREMENT bytes=$($scan.bytesRead) elapsedMilliseconds=$($scan.elapsedMilliseconds) platform=$([Environment]::OSVersion.Platform) maxMilliseconds=4000;WINDOWS_TIMING_NOT_INFERRED"
    foreach($encoding in @([Text.Encoding]::UTF8,[Text.UnicodeEncoding]::new($false,$false),[Text.UnicodeEncoding]::new($true,$false))){
        foreach($offset in @(0,1)){
            $path=Join-Path $temp 'injected-binary.bin'
            $payload=$encoding.GetBytes($secret);$blob=New-Object byte[] ($offset+$payload.Length+13);[Array]::Copy($payload,0,$blob,$offset,$payload.Length)
            [IO.File]::WriteAllBytes($path,$blob)
            $writer=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            try{$scan=Test-HostedSecretCanary -Directories @($temp) -Sha256 $canary.sha256 -Length $canary.length -RollingFingerprint $canary.rollingFingerprint;if(!$scan.leaked -or $scan.file -cne $path){throw 'Binary encoded secret missed with open writer'}}finally{$writer.Dispose();$writer=$null}
            Remove-Item -LiteralPath $path
        }
    }
    Write-Output 'OPEN_LEDGER_WRITER_AND_CANARY_READERS_PASSED;SOLE_WRITER_ENFORCEMENT_WINDOWS_ONLY'
}finally{if($writer){$writer.Dispose()};if($ledger){Close-HostedCapabilityLedger $ledger};Remove-Item $temp -Recurse -Force}
