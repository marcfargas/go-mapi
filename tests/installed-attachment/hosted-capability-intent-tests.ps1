$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-intent.psm1') -Force
$run='a'*32;$sha='b'*40;$sid='S-1-5-21-1-2-3-1001';$thumb='C'*40
$rules=Get-HostedCapabilityWorkerIntentRules
$name='t569'+$run.Substring(0,10);$profile="C:\Users\$name";$runtime='C:\crabbox\work\ticket569'
$allEvents=@($rules.Keys | ForEach-Object {@{phase='intent';operation=$_;requestId=[guid]::NewGuid().ToString('N');resourceIdentity=@{taskName="Ticket569-$run-normal"}}})
$context=@{runId=$run;sourceSHA=$sha;worker=@{pid=1};owner=@{pid=2;creationFileTimeUtc=3};ownerRuntime='owner-runtime';userSID=$sid;session=@{sid=$sid;sessionId=4};child=@{pid=5;creationFileTimeUtc=6};scriptRoot=$PSScriptRoot;replay=@{valid=$true;events=$allEvents;mutations=@(@{intent=@{operation='create-and-export-unique-prompt-certificate'};observation=@{result='completed';observed=@{thumbprint=$thumb}}})}}
$values=@{name=$name;username=$name;sid=$sid;memberSid=$sid;groupSid='S-1-5-32-555';path=$runtime;runId=$run;host='127.0.0.1';session='ticket569';sessionOwnerPID=2;ownerPID=2;sessionOwnerCreationFileTimeUtc=3;ownerCreationFileTimeUtc=3;runtimeRoot='owner-runtime';pid=5;creationFileTimeUtc=6;taskChildPID=5;childCreationFileTimeUtc=6;sessionId=4;taskName="Ticket569-$run-normal";scriptPath=(Join-Path $PSScriptRoot 'hosted-user-capability.ps1');scriptSha256=(Get-FileHash (Join-Path $PSScriptRoot 'hosted-user-capability.ps1')).Hash.ToLowerInvariant();subject="CN=Ticket569-Root-Prompt-$run";store='LocalMachine/My';thumbprint=$thumb;exportPath="$profile\root-prompt-$run.cer";paths=@("$profile\root-prompt-$run.cer");vhdPath="$runtime\profile-$run.vhdx";profilePath=$profile;backupPath="$profile.normal-backup";volumeId='\\?\Volume{12345678-1234-1234-1234-123456789012}\';drive='T';diskNumber=1}
$count=0;$denied=0
function Assert-Rejected($Request,$Context) {
    $accepted=$false
    try{$null=Assert-HostedCapabilityWorkerIntent $Request $Context;$accepted=$true}catch{}
    if($accepted){throw "Unauthorized $($Request.operation) intent reached the ACK boundary"}
    $script:denied++
}
foreach($op in $rules.Keys){
    $rule=$rules[$op];$resource=@{};$pre=@{}
    foreach($field in $rule.fields){$resource[$field]=$values[$field]}
    foreach($field in $rule.true){$pre[$field]=$true}
    foreach($field in $rule.false){$pre[$field]=$false}
    foreach($field in $rule.present){$pre[$field]=0}
    if($rule.values){foreach($field in $rule.values.Keys){$pre[$field]=$rule.values[$field]}}
    if($rule.kind){$pre[$rule.kind]='normal'}
    if($op -eq 'run-pinned-cua-currentuser-root-prompt'){$resource.store='CurrentUser/Root'}
    if($op -eq 'handoff-session-owner-to-supervisor-cleanup'){$resource.pid=2;$resource.creationFileTimeUtc=3}
    $request=@{phase='intent';requestId=[guid]::NewGuid().ToString('N');runId=$run;sourceSHA=$sha;operation=$op;resourceIdentity=$resource;precondition=$pre}
    if(!(Assert-HostedCapabilityWorkerIntent $request $context)){throw "Exact allowed $op was refused"};$count++
    foreach($field in $rule.fields){$bad=$resource.Clone();$bad.Remove($field);$copy=$request.Clone();$copy.resourceIdentity=$bad;Assert-Rejected $copy $context}
    foreach($field in (@($rule.true)+@($rule.false)+@($rule.present) | Where-Object {$_})){$bad=$pre.Clone();$bad.Remove($field);$copy=$request.Clone();$copy.precondition=$bad;Assert-Rejected $copy $context}
    foreach($field in $rule.true){$bad=$pre.Clone();$bad[$field]='true';$copy=$request.Clone();$copy.precondition=$bad;Assert-Rejected $copy $context}
    $badContext=$context.Clone();$badContext.replay=@{valid=$true;events=@();mutations=@()}
    if($rule.owned){Assert-Rejected $request $badContext}
    $replayedContext=$context.Clone();$replayedContext.replay=@{valid=$true;events=@($allEvents)+@{requestId=$request.requestId};mutations=$context.replay.mutations};Assert-Rejected $request $replayedContext
    $copy=$request.Clone();$copy.sourceSHA='c'*40;Assert-Rejected $copy $context
}
if($count -ne 36){throw "Expected all 36 emitted worker mutations, observed $count"}
Write-Output "HOSTED_CAPABILITY_INTENT_TESTS_PASSED;allowed=$count;denied=$denied"
$helperRoles=@{
    'user-probe'=@('write-owned-run-credential','read-owned-run-credential','delete-owned-run-credential','verify-owned-run-credential-absence')
    'root-import'=@('seed-exact-currentuser-synthetic-credential','delete-exact-currentuser-synthetic-credential','recover-delete-exact-currentuser-synthetic-credential','import-exact-currentuser-root-certificate','remove-exact-owned-currentuser-root-certificate')
    'recovery-worker'=@('recovery-delete-exact-currentuser-synthetic-credential')
    'root-remove'=@('recovery-remove-exact-owned-currentuser-root-certificate')
}
$helperAllowed=0;$helperDenied=0
foreach($role in $helperRoles.Keys){foreach($operation in @($helperRoles.Values|ForEach-Object {$_})){
    $request=@{operation=$operation;resourceIdentity=@{target='synthetic'};precondition=@{credentialAbsent=$true}}
    $rejected=$false;try{$null=Assert-HostedCapabilityHelperOperation -Request $request -Role $role}catch{$rejected=$true}
    if(($operation -cin $helperRoles[$role]) -eq $rejected){throw 'Authenticated helper role accepted an operation from another caller scope'}
    if($rejected){$helperDenied++}else{$helperAllowed++;$request.precondition.credentialAbsent='true';$bad=$false;try{$null=Assert-HostedCapabilityHelperOperation -Request $request -Role $role}catch{$bad=$true};if(!$bad){throw 'Helper accepted a string boolean precondition'}}
}}
Write-Output "HOSTED_CAPABILITY_HELPER_ROLE_TESTS_PASSED;allowed=$helperAllowed;denied=$helperDenied"
