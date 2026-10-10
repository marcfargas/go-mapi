$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-owner.psm1') -Force
$root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$run = 'a4c071dd8c774e9bab2be183fa6436cd'
$ledger = New-HostedCapabilityLedger -Directory $root -RunId $run -SourceSHA ('a' * 40) -BootMarker 'test-boot' -JobStartCounter 1000 -CounterFrequency 100
try {
    if (-not (Test-Path (Join-Path $root 'owner-state.json')) -or -not (Test-Path (Join-Path $root 'events.ndjson'))) {
        throw 'owner ledger must exist before any mutation'
    }
    $mutationCount = 0
    try {
        Invoke-HostedAcknowledgedMutation -Ledger $ledger -RunId $run -SourceSHA ('a' * 40) -Operation 'create-test-resource' -ResourceIdentity @{ name='ticket569-test-a4c071dd' } -Precondition @{ absentBeforeMutation=$true } -SendIntent { param($request) @{ acknowledged=$false; requestId=$request.requestId } } -Action { $script:mutationCount++ } -SendObservation { param($request) @{ acknowledged=$true; requestId=$request.requestId } }
        throw 'mutation unexpectedly proceeded without the supervisor flush acknowledgement'
    } catch {
        if ($_.Exception.Message -notmatch 'acknowledg') { throw }
    }
    if ($mutationCount -ne 0 -or $ledger.Sequence -ne 0) { throw 'missing intent acknowledgement must block mutation and observation' }

    $receipt = Invoke-HostedAcknowledgedMutation -Ledger $ledger -RunId $run -SourceSHA ('a' * 40) -Operation 'create-test-resource' -ResourceIdentity @{ name='ticket569-test-a4c071dd' } -Precondition @{ absentBeforeMutation=$true } -SendIntent {
        param($request)
        $event = Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event $request
        @{ acknowledged=$true; requestId=$request.requestId; sequence=$event.sequence }
    } -Action {
        if ($ledger.Sequence -ne 1) { throw 'mutation ran before its durable intent event' }
        $script:mutationCount++
        @{ sid='S-1-5-21-100-200-300-400'; created=$true }
    } -SendObservation {
        param($request)
        $event = Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event $request
        @{ acknowledged=$true; requestId=$request.requestId; sequence=$event.sequence }
    }
    if ($mutationCount -ne 1 -or $receipt.intentSequence -ne 1 -or $receipt.observationSequence -ne 2) {
        throw 'acknowledged mutation must be bracketed by durable intent and observation events'
    }
    $events = @(Get-Content -LiteralPath (Join-Path $root 'events.ndjson') | ForEach-Object { $_ | ConvertFrom-Json })
    if ($events.Count -ne 2 -or $events[0].phase -ne 'intent' -or $events[1].phase -ne 'observation') {
        throw 'ledger journal must retain ordered intent and observation records'
    }
    $replay=Read-HostedCapabilityLedger -Directory $root -RunId $run -SourceSHA ('a' * 40)
    if(!$replay.valid -or $replay.sequence -ne 2 -or $replay.pending.Count -ne 0){throw 'ledger replay must verify the paired durable intent and observation'}
    $failure = Write-HostedCapabilityFailure -Ledger $ledger -Code 'worker-timeout' -Evidence @{ pid=42 }
    if (-not $failure.latched -or -not (Test-HostedCapabilityFailure -Ledger $ledger)) { throw 'failure latch did not become set' }
    Write-HostedCapabilityFailure -Ledger $ledger -Code 'cleanup-unverified' -Evidence @{ resource='profile' } | Out-Null
    if (-not (Test-HostedCapabilityFailure -Ledger $ledger)) { throw 'a later result cleared the irreversible failure latch' }
    $markers = @(Get-ChildItem -LiteralPath (Join-Path $root 'failure-records') -Filter '*.json')
    if ($markers.Count -ne 2) { throw 'each failure must be persisted as a unique create-new marker' }
} finally {
    Close-HostedCapabilityLedger -Ledger $ledger
    Remove-Item -LiteralPath $root -Recurse -Force
}
$resourceRoot=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $resourceRoot | Out-Null
$resourceLedger=New-HostedCapabilityLedger -Directory $resourceRoot -RunId $run -SourceSHA ('a'*40) -BootMarker 'test-boot' -JobStartCounter 1000 -CounterFrequency 100
try{
    Write-HostedCapabilityLedgerEvent -Ledger $resourceLedger -Event @{phase='resource';operation='run-scoped-failure-event-created';resourceIdentity=@{name='Global\\Ticket569-test-failure'}} | Out-Null
}finally{Close-HostedCapabilityLedger -Ledger $resourceLedger}
$resourceReplay=Read-HostedCapabilityLedger -Directory $resourceRoot -RunId $run -SourceSHA ('a'*40)
if(!$resourceReplay.valid -or $resourceReplay.sequence -ne 1){throw 'supervisor resource facts must be durable replayable ledger events'}
Remove-Item -LiteralPath $resourceRoot -Recurse -Force
$cutRoot=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cutRoot | Out-Null
$cutLedger=New-HostedCapabilityLedger -Directory $cutRoot -RunId $run -SourceSHA ('a' * 40) -BootMarker 'test-boot' -JobStartCounter 1000 -CounterFrequency 100
try {
    $requestId=[guid]::NewGuid().ToString('N')
    Write-HostedCapabilityLedgerEvent -Ledger $cutLedger -Event @{requestId=$requestId;phase='intent';operation='create-crash-cut-resource';resourceIdentity=@{name='ticket569-cut-resource'};precondition=@{absentBeforeMutation=$true};processIdentity=@{pid=99}} | Out-Null
    $cutLedger.Stream.Flush($true)
} finally { Close-HostedCapabilityLedger -Ledger $cutLedger }
$replay=Read-HostedCapabilityLedger -Directory $cutRoot -RunId $run -SourceSHA ('a' * 40)
if(!$replay.valid -or $replay.sequence -ne 1 -or $replay.pending.Count -ne 1 -or $replay.pending[0].operation -cne 'create-crash-cut-resource' -or $replay.failureLatched){throw 'crash-after-intent replay must preserve the resource as pending/unknown without inferring absence'}
Remove-Item -LiteralPath $cutRoot -Recurse -Force

$boundaryRoot=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $boundaryRoot | Out-Null
$boundaryRun='b5d172fe40364b90a5eb7593901af035'
$boundarySource='b'*40
$boundaryLedger=New-HostedCapabilityLedger -Directory $boundaryRoot -RunId $boundaryRun -SourceSHA $boundarySource -BootMarker 'test-boot' -JobStartCounter 1000 -CounterFrequency 100
$preexistingPath=Join-Path $boundaryRoot 'preexisting-resource.json'
$ownedPath=Join-Path $boundaryRoot 'run-owned-resource.json'
[IO.File]::WriteAllText($preexistingPath,'{"owner":"preexisting"}',[Text.UTF8Encoding]::new($false))
$preexistingBytes=[IO.File]::ReadAllBytes($preexistingPath)
try{
    try{
        Invoke-HostedAcknowledgedMutation -Ledger $boundaryLedger -RunId $boundaryRun -SourceSHA $boundarySource -Operation 'replace-resource' -ResourceIdentity @{path=$preexistingPath} -Precondition @{absentBeforeMutation=$true} -SendIntent {param($request)@{acknowledged=$false;requestId=$request.requestId}} -Action {[IO.File]::WriteAllText($preexistingPath,'{"owner":"run"}');$true} -SendObservation {param($request)@{acknowledged=$true;requestId=$request.requestId;sequence=2}}
        throw 'missing intent acknowledgement allowed a mutation against a preexisting resource'
    }catch{if($_.Exception.Message -notmatch 'acknowledgement'){throw}}
    if([Convert]::ToBase64String($preexistingBytes) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($preexistingPath))){throw 'missing intent acknowledgement changed the byte-for-byte preexisting resource'}
    try{
        Invoke-HostedAcknowledgedMutation -Ledger $boundaryLedger -RunId $boundaryRun -SourceSHA $boundarySource -Operation 'create-run-resource' -ResourceIdentity @{path=$ownedPath} -Precondition @{absentBeforeMutation=$true} -SendIntent {
            param($request);$event=Write-HostedCapabilityLedgerEvent -Ledger $boundaryLedger -Event $request;@{acknowledged=$true;requestId=$request.requestId;sequence=$event.sequence}
        } -Action {[IO.File]::WriteAllText($ownedPath,'{"owner":"run"}');@{created=$true}} -SendObservation {param($request)@{acknowledged=$false;requestId=$request.requestId;sequence=2}}
        throw 'missing observation acknowledgement was not rejected'
    }catch{if($_.Exception.Message -notmatch 'observation'){throw}}
    $boundaryReplay=Read-HostedCapabilityLedger -Directory $boundaryRoot -RunId $boundaryRun -SourceSHA $boundarySource
    if(!$boundaryReplay.valid -or $boundaryReplay.pending.Count -ne 1 -or $boundaryReplay.pending[0].operation -cne 'create-run-resource' -or !(Test-Path -LiteralPath $ownedPath)){
        throw 'a lost post-action acknowledgement must remain pending/unknown and preserve the observed run resource for exact-source recovery'
    }
    if([Convert]::ToBase64String($preexistingBytes) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($preexistingPath))){throw 'post-action observation uncertainty modified an unrelated preexisting resource'}
}finally{Close-HostedCapabilityLedger -Ledger $boundaryLedger;Remove-Item -LiteralPath $boundaryRoot -Recurse -Force}
Write-Output 'HOSTED_CAPABILITY_OWNER_TESTS_PASSED'
# Execute the production stop function's pre-prompt branch. A worker fault can
# happen before the prompt service exists, but shutdown still needs a receipt.
$ownerPath=Join-Path $PSScriptRoot 'hosted-session-owner.ps1';$parseErrors=$null;$tokens=$null
$ownerAST=[Management.Automation.Language.Parser]::ParseFile($ownerPath,[ref]$tokens,[ref]$parseErrors)
$stopAST=$ownerAST.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Stop-PromptService'},$true)
. ([scriptblock]::Create($stopAST.Extent.Text))
$script:promptProcess=$null
$receipt=Stop-PromptService
if(!$receipt.stopped -or $receipt.present){throw 'Production owner stop omitted its pre-prompt absence receipt'}
Write-Output 'HOSTED_CAPABILITY_OWNER_PRE_PROMPT_STOP_PASSED'
