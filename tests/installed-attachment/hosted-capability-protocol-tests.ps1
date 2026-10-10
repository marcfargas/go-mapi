$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-protocol.psm1') -Force
function Invoke-PortableProtocolCase([string] $ActionMode) {
    $frames=[Collections.Generic.List[object]]::new();$mutation=@{ran=$false}
    $send={param($request)$null=$frames.Add($request);$id=$request.requestId;if($ActionMode -eq 'reject-intent' -and $request.phase -eq 'intent'){$id=[guid]::NewGuid().ToString('N')};@{acknowledged=$true;requestId=$id;sequence=$frames.Count}}.GetNewClosure()
    try {
        $receipt=Invoke-HostedHelperMutation -Connection ([pscustomobject]@{}) -RunId ('a'*32) -SourceSHA ('b'*40) -Operation 'portable-test-resource' -ResourceIdentity @{name='portable'} -Precondition @{absent=$true} -SendRequest $send -Action {
            if($frames.Count -ne 1 -or $frames[0].phase -cne 'intent') {throw 'action ran before acknowledged durable intent'}
            $mutation.ran=$true
            if($ActionMode -eq 'action-error'){throw 'injected action error'}
            @{created=$true}
        }
        if($ActionMode -ne 'success'){throw 'protocol unexpectedly accepted a rejected intent or action failure'}
        if(!$mutation.ran -or $frames.Count -ne 2 -or $frames[1].phase -cne 'observation' -or $frames[0].requestId -cne $frames[1].requestId -or $receipt.observationSequence -le $receipt.intentSequence){throw 'runtime helper did not complete one acknowledged intent/observation transaction'}
    } catch {
        if($ActionMode -eq 'reject-intent'){
            if($_.Exception.Message -notmatch 'intent' -or $mutation.ran -or $frames.Count -ne 1){throw}
        } elseif($ActionMode -eq 'action-error'){
            if($_.Exception.Message -notmatch 'injected action error' -or !$mutation.ran -or $frames.Count -ne 2 -or $frames[1].result -cne 'failed'){throw}
        } else {throw}
    }
}
Invoke-PortableProtocolCase 'success'
Invoke-PortableProtocolCase 'reject-intent'
Invoke-PortableProtocolCase 'action-error'
$boundaryRoot=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $boundaryRoot | Out-Null
try{
    $preexistingPath=Join-Path $boundaryRoot 'preexisting.json';$runOwnedPath=Join-Path $boundaryRoot 'run-owned.json'
    [IO.File]::WriteAllText($preexistingPath,'{"owner":"preexisting"}',[Text.UTF8Encoding]::new($false))
    $preexisting=[Convert]::ToBase64String([IO.File]::ReadAllBytes($preexistingPath))
    $state=[hashtable]::Synchronized(@{frames=[Collections.Generic.List[object]]::new();actionCount=0})
    $send={param($request)$null=$state.frames.Add($request);@{acknowledged=($request.phase -eq 'intent');requestId=$request.requestId;sequence=$state.frames.Count}}.GetNewClosure()
    try{
        Invoke-HostedHelperMutation -Connection ([pscustomobject]@{}) -RunId ('a'*32) -SourceSHA ('b'*40) -Operation 'create-run-owned-resource' -ResourceIdentity @{path=$runOwnedPath} -Precondition @{absentBeforeMutation=$true} -SendRequest $send -Action {
            $state.actionCount++;[IO.File]::WriteAllText($runOwnedPath,'{"owner":"run"}');@{created=$true}
        }.GetNewClosure() | Out-Null
        throw 'missing observation acknowledgement was accepted'
    }catch{if($_.Exception.Message -notmatch 'observation'){throw}}
    if($state.actionCount -ne 1 -or $state.frames.Count -ne 2 -or $state.frames[0].phase -cne 'intent' -or $state.frames[1].phase -cne 'observation' -or !(Test-Path -LiteralPath $runOwnedPath)){
        throw 'lost observation acknowledgement must not retry the action and must retain its single run-owned mutation for reconciliation'
    }
    if($preexisting -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($preexistingPath))){throw 'lost observation acknowledgement changed byte-for-byte preexisting state'}
}finally{Remove-Item -LiteralPath $boundaryRoot -Recurse -Force}
if (-not $IsWindows) {
    Write-Output 'WINDOWS_PIPE_CALLER_IDENTITY_NOT_EXERCISED'
}

function Invoke-PipeCase([bool] $RejectIntent,[string]$Fault='none') {
    $name='Ticket569-'+[guid]::NewGuid().ToString('N')
    $temp=Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    $ready=Join-Path $temp 'ready';$resultPath=Join-Path $temp 'peer-result.json';$actionPath=Join-Path $temp 'action-ran'
    $peerScript=Join-Path $temp 'peer.ps1'
    @'
param([string]$Name,[string]$ReadyPath,[string]$ResultPath,[string]$ActionPath,[switch]$Reject,[string]$Fault='none')
$ErrorActionPreference='Stop'
$pipe=[IO.Pipes.NamedPipeServerStream]::new($Name,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,4096,4096)
[IO.File]::WriteAllText($ReadyPath,'ready')
try {
    $pipe.WaitForConnection()
    $reader=[IO.StreamReader]::new($pipe,[Text.UTF8Encoding]::new($false),$false,4096,$true)
    $writer=[IO.StreamWriter]::new($pipe,[Text.UTF8Encoding]::new($false),4096,$true);$writer.AutoFlush=$true
    $intent=$reader.ReadLine() | ConvertFrom-Json
    if($intent.phase -cne 'intent'){throw 'peer did not receive the intent frame first'}
    if($Fault -eq 'no-ack'){[IO.File]::WriteAllText($ResultPath,'{"fault":"no-ack"}');return}
    $replyId=if($Reject){[guid]::NewGuid().ToString('N')}else{$intent.requestId}
    $writer.WriteLine((ConvertTo-Json -InputObject @{acknowledged=$true;requestId=$replyId;sequence=1} -Compress))
    if($Fault -eq 'peer-death-after-ack'){[IO.File]::WriteAllText($ResultPath,'{"fault":"peer-death-after-ack"}');return}
    if(!$Reject){
        $observation=$reader.ReadLine() | ConvertFrom-Json
        if($observation.phase -cne 'observation' -or $observation.requestId -cne $intent.requestId -or !(Test-Path -LiteralPath $ActionPath)){throw 'peer observed a missing or mismatched post-action frame'}
        [IO.File]::WriteAllText($ResultPath,(ConvertTo-Json -Compress @{intent=$intent;observation=$observation;actionVisible=$true}))
        $writer.WriteLine((ConvertTo-Json -InputObject @{acknowledged=$true;requestId=$observation.requestId;sequence=2} -Compress))
    } else { [IO.File]::WriteAllText($ResultPath,(ConvertTo-Json -Compress @{intent=$intent;rejected=$true;actionVisible=(Test-Path -LiteralPath $ActionPath)})) }
    $reader.Dispose();$writer.Dispose()
} finally {$pipe.Dispose()}
'@ | Set-Content -LiteralPath $peerScript -Encoding utf8
    $pwsh=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
    $peerArgs=@('-NoLogo','-NoProfile','-NonInteractive','-File',"`"$peerScript`"",'-Name',$name,'-ReadyPath',"`"$ready`"",'-ResultPath',"`"$resultPath`"",'-ActionPath',"`"$actionPath`"")
    $peerArgs+=@('-Fault',$Fault)
    if($RejectIntent){$peerArgs+='-Reject'}
    $peer=Start-Process -FilePath $pwsh -ArgumentList $peerArgs -PassThru
    $client=$null
    try {
        $readyBy=[DateTime]::UtcNow.AddSeconds(10)
        while(!(Test-Path -LiteralPath $ready) -and [DateTime]::UtcNow -lt $readyBy){Start-Sleep -Milliseconds 25}
        if(!(Test-Path -LiteralPath $ready)){throw 'real protocol peer did not create its ready marker'}
        $client=Connect-HostedCapabilitySupervisor -PipeName $name -TimeoutMilliseconds 5000
        if($Fault -ne 'none'){
            $failed=$false
            try{Invoke-HostedHelperMutation -Connection $client -RunId ('a'*32) -SourceSHA ('b'*40) -Operation 'create-real-fault-marker' -ResourceIdentity @{path=$actionPath} -Precondition @{absent=$true} -Action {[IO.File]::WriteAllText($actionPath,'owned mutation');@{created=$true}} | Out-Null}catch{$failed=$true}
            if(!$failed){throw 'Lost actual participant ACK/pipe did not fail the mutation transaction'}
            if($Fault -eq 'no-ack' -and (Test-Path $actionPath)){throw 'Missing real intent ACK allowed the mutation'}
            if($Fault -eq 'peer-death-after-ack' -and !(Test-Path $actionPath)){throw 'Acknowledged single mutation was not retained for reconciliation'}
        } elseif ($RejectIntent) {
            try { Invoke-HostedHelperMutation -Connection $client -RunId ('a'*32) -SourceSHA ('b'*40) -Operation 'test-resource-create' -ResourceIdentity @{name='test'} -Precondition @{absent=$true} -Action { [IO.File]::WriteAllText($actionPath,'ran') } | Out-Null; throw 'bad intent acknowledgement unexpectedly allowed a mutation' }
            catch { if ($_.Exception.Message -notmatch 'intent') { throw } }
            if ((Test-Path -LiteralPath $actionPath)) { throw 'mismatched intent ack must prevent the real mutation callback' }
        } else {
            $receipt=Invoke-HostedHelperMutation -Connection $client -RunId ('a'*32) -SourceSHA ('b'*40) -Operation 'test-resource-create' -ResourceIdentity @{name='test'} -Precondition @{absent=$true} -Action { [IO.File]::WriteAllText($actionPath,'ran');@{created=$true} }
            if ($receipt.intentSequence -ne 1 -or $receipt.observationSequence -ne 2) { throw 'mutation did not complete both real-process acknowledgement boundaries' }
        }
        if(!$peer.WaitForExit(5000) -or $peer.ExitCode -ne 0 -or !(Test-Path -LiteralPath $resultPath)){throw 'real protocol peer did not complete and retain its process result'}
        $peerResult=Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if($Fault -ne 'none'){if($peerResult.fault -cne $Fault){throw 'Actual peer fault result was not retained'}}
        elseif($RejectIntent){if(!$peerResult.rejected -or $peerResult.actionVisible){throw 'rejected real-process intent still changed the mutation target'}}
        elseif(!$peerResult.actionVisible -or $peerResult.observation.phase -cne 'observation'){throw 'real-process peer did not observe the mutation after its acknowledged intent'}
        if($Fault -eq 'peer-death-after-ack'){$client.Writer.AutoFlush=$false;$client.Writer.Write('buffer retained across a dead real peer')}
    } finally {
        if ($client) { $pipeHandle=$client.Pipe.SafePipeHandle;Close-HostedCapabilitySupervisorConnection -Connection $client;if(!$pipeHandle.IsClosed){throw 'Protocol close did not dispose its retained pipe after peer death'} }
        if($peer -and !$peer.HasExited){try{$peer.Kill($true);$null=$peer.WaitForExit(3000)}catch{}}
        if($peer){$peer.Dispose()}
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-PipeCase $false
Invoke-PipeCase $true
Invoke-PipeCase $false 'no-ack'
Invoke-PipeCase $false 'peer-death-after-ack'
Write-Output 'HOSTED_CAPABILITY_PROTOCOL_TESTS_PASSED'
