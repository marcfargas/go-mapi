# The supervisor calls this gate before writing an intent or returning an ACK.
# Its context is supervisor-observed identity plus replay of its sole-writer journal.
function Get-HostedCapabilityWorkerIntentRules {
    @{
        'create-owned-hosted-capability-runtime-root'=@{fields=@('path','runId');true=@('exactRunScopedRoot')}
        'create-disposable-local-user'=@{fields=@('name');true=@('absent');false=@('administrator')}
        'grant-remote-desktop-users-membership'=@{fields=@('groupSid','memberSid');true=@('memberAbsent');owned='create-disposable-local-user'}
        'planned-standard-user-rdp-login'=@{fields=@('sid','username','host','sessionOwnerPID','sessionOwnerCreationFileTimeUtc');true=@('plannedLogin','sessionOwnerReady');values=@{passwordTransferPath='worker-direct-named-pipe'};owned='create-disposable-local-user'}
        'planned-disconnect-of-owned-rdp-session'=@{fields=@('session','ownerPID','ownerCreationFileTimeUtc');true=@('connected','disconnectIsPlanned');owned='planned-standard-user-rdp-login'}
        'handoff-session-owner-to-supervisor-cleanup'=@{fields=@('pid','creationFileTimeUtc','runtimeRoot','session');true=@('plannedDisconnectCompleted','supervisorOwnsSeparateKillOnCloseJob')}
        'register-exact-run-scoped-interactive-user-task'=@{fields=@('taskName','sid','sessionId','scriptPath','scriptSha256');true=@('taskAbsent');kind='profileKind'}
        'start-exact-run-scoped-interactive-user-task'=@{fields=@('taskName','sid','sessionId');true=@('taskRegistered');kind='expectedProfileKind';owned='register-exact-run-scoped-interactive-user-task'}
        'stop-exact-user-task-instance'=@{fields=@('taskName','sid','sessionId','taskChildPID','childCreationFileTimeUtc');true=@('childExited');values=@{taskState='Running'};owned='register-exact-run-scoped-interactive-user-task'}
        'unregister-exact-user-task'=@{fields=@('taskName','sid','sessionId');true=@('taskCompleted');present=@('taskResult');owned='register-exact-run-scoped-interactive-user-task'}
        'stop-owned-user-task-during-cleanup'=@{fields=@('taskName','sid','sessionId','taskChildPID');true=@('taskOwned','cleanup');owned='register-exact-run-scoped-interactive-user-task'}
        'unregister-owned-user-task-during-cleanup'=@{fields=@('taskName','sid','sessionId');true=@('taskOwned','cleanup');owned='register-exact-run-scoped-interactive-user-task'}
        'terminate-exact-owned-user-task-child'=@{fields=@('pid','creationFileTimeUtc','sid','sessionId');true=@('taskOwned','childIdentityObserved')}
        'create-and-export-unique-prompt-certificate'=@{fields=@('subject','store','exportPath');true=@('subjectAbsent','exportAbsent')}
        'run-pinned-cua-currentuser-root-prompt'=@{fields=@('sid','sessionId','subject','thumbprint','store');true=@('exactActiveSessionObserved','targetAbsent');owned='create-and-export-unique-prompt-certificate'}
        'remove-exact-prompt-certificate'=@{fields=@('store','subject','thumbprint');true=@('sameCertificatePresent');owned='create-and-export-unique-prompt-certificate'}
        'remove-owned-prompt-temporary-files'=@{fields=@('paths');true=@('pathsUniqueRunScoped');owned='create-and-export-unique-prompt-certificate'}
        'remove-exact-unloaded-user-profile'=@{fields=@('sid','profilePath');true=@('sessionUnloaded','exactUserOwned');values=@{profileState='normal'};owned='create-disposable-local-user'}
        'remove-owned-user-and-group-membership'=@{fields=@('name','sid','groupSid');true=@('profileAbsent','userOwned');present=@('groupGrantOwned');owned='create-disposable-local-user'}
        'create-owned-profile-vhd-parent-directory'=@{fields=@('path','vhdPath');true=@('pathIsExactTicket569RuntimeRoot')}
        'profile-diskpart-create-profile-vhd'=@{fields=@('vhdPath');true=@('vhdAbsent')}
        'profile-diskpart-attach-profile-vhd'=@{fields=@('vhdPath');true=@('vhdExists');false=@('attached');owned='profile-diskpart-create-profile-vhd'}
        'profile-diskpart-format-profile-vhd'=@{fields=@('vhdPath','drive');true=@('vhdAttached','driveAbsent');owned='profile-diskpart-attach-profile-vhd'}
        'copy-normal-profile-into-owned-vhd'=@{fields=@('sid','profilePath','vhdPath','volumeId');true=@('sourceProfileUnloaded','vhdAttached','destinationEmpty');owned='profile-diskpart-format-profile-vhd'}
        'rename-normal-profile-to-owned-backup'=@{fields=@('sid','profilePath','backupPath');true=@('profileUnloaded','backupAbsent');owned='copy-normal-profile-into-owned-vhd'}
        'create-original-profile-mount-directory'=@{fields=@('sid','profilePath');true=@('profilePathAbsent');owned='rename-normal-profile-to-owned-backup'}
        'mount-vhd-at-original-profile-path'=@{fields=@('sid','profilePath','vhdPath','volumeId');true=@('backupPresent','vhdAttached','profileDirectoryPresent');owned='rename-normal-profile-to-owned-backup'}
        'remove-temporary-vhd-drive-letter'=@{fields=@('vhdPath','drive');true=@('profileMountVerified','temporaryDriveAssigned');owned='profile-diskpart-format-profile-vhd'}
        'cleanup-temporary-vhd-drive-letter'=@{fields=@('vhdPath','drive');true=@('temporaryDriveStillAssigned');owned='profile-diskpart-format-profile-vhd'}
        'recreate-missing-profile-restore-placeholder'=@{fields=@('sid','profilePath','backupPath');true=@('normalBackupPresent','originalProfilePathAbsent');owned='rename-normal-profile-to-owned-backup'}
        'detach-vhd-profile-mount-point'=@{fields=@('sid','profilePath','vhdPath','volumeId');true=@('mountedVhdVerified','normalBackupPresent');owned='mount-vhd-at-original-profile-path'}
        'remove-profile-mount-placeholder'=@{fields=@('sid','profilePath');true=@('mountDetached','normalBackupPresent');owned='rename-normal-profile-to-owned-backup'}
        'remove-empty-profile-restore-placeholder'=@{fields=@('sid','profilePath','backupPath');true=@('normalBackupPresent','profilePathIsEmpty','reparseMountAbsent');owned='rename-normal-profile-to-owned-backup'}
        'restore-normal-profile-from-owned-backup'=@{fields=@('sid','profilePath','backupPath');true=@('profileUnloaded','backupPresent','mountPointAbsent');owned='rename-normal-profile-to-owned-backup'}
        'dismount-owned-profile-vhd'=@{fields=@('sid','vhdPath','diskNumber');true=@('normalProfileRestored','imageAttached');owned='profile-diskpart-create-profile-vhd'}
        'remove-owned-profile-vhd-file'=@{fields=@('sid','vhdPath');true=@('normalProfileRestored','imageDetached');owned='profile-diskpart-create-profile-vhd'}
    }
}
function Get-HostedIntentField($Object,[string]$Name) {
    if($Object -is [Collections.IDictionary]){return $Object[$Name]}
    if($Object){$p=$Object.PSObject.Properties[$Name];if($p){return $p.Value}}
    return $null
}
function Assert-HostedCapabilityWorkerIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Context)
    $rules=Get-HostedCapabilityWorkerIntentRules
    $op=[string]$Request.operation;$r=$Request.resourceIdentity;$p=$Request.precondition
    if(!$Context.replay.valid -or !$Context.worker -or $Request.runId -cne $Context.runId -or $Request.sourceSHA -cne $Context.sourceSHA -or $Request.phase -cne 'intent' -or $Request.requestId -notmatch '^[a-f0-9]{32}$' -or !$rules.ContainsKey($op)){throw 'Worker intent caller/run/source/phase/operation is unauthorized'}
    if(@($Context.replay.events | Where-Object requestId -CEQ $Request.requestId).Count){throw 'Worker intent request identity was replayed'}
    $rule=$rules[$op]
    foreach($field in $rule.fields){if($null -eq (Get-HostedIntentField $r $field) -or [string](Get-HostedIntentField $r $field) -ceq ''){throw "Worker intent lacks resource field $field"}}
    foreach($field in $rule.true){$v=Get-HostedIntentField $p $field;if($v -isnot [bool] -or $v -ne $true){throw "Worker intent lacks true precondition $field"}}
    foreach($field in $rule.false){$v=Get-HostedIntentField $p $field;if($v -isnot [bool] -or $v -ne $false){throw "Worker intent lacks false precondition $field"}}
    foreach($field in $rule.present){if($null -eq (Get-HostedIntentField $p $field)){throw "Worker intent lacks precondition $field"}}
    if($rule.values){foreach($field in $rule.values.Keys){if((Get-HostedIntentField $p $field) -cne $rule.values[$field]){throw "Worker intent has a mismatched precondition $field"}}}
    $name='t569'+$Context.runId.Substring(0,10);$profile="C:\Users\$name";$runtime='C:\crabbox\work\ticket569';$vhd="$runtime\profile-$($Context.runId).vhdx"
    $expected=@{name=$name;username=$name;profilePath=$profile;backupPath="$profile.normal-backup";vhdPath=$vhd;groupSid='S-1-5-32-555';memberSid=$Context.userSID;sid=$Context.userSID;host='127.0.0.1';drive='T';subject="CN=Ticket569-Root-Prompt-$($Context.runId)";session='ticket569';exportPath="$profile\root-prompt-$($Context.runId).cer";sessionOwnerPID=$Context.owner.pid;sessionOwnerCreationFileTimeUtc=$Context.owner.creationFileTimeUtc;ownerPID=$Context.owner.pid;ownerCreationFileTimeUtc=$Context.owner.creationFileTimeUtc;runtimeRoot=$Context.ownerRuntime;runId=$Context.runId}
    foreach($field in $rule.fields){if($expected.ContainsKey($field) -and (!$expected[$field] -or (Get-HostedIntentField $r $field) -cne $expected[$field])){throw "Worker intent resource $field does not match supervisor identity"}}
    if($rule.fields -contains 'path' -and $r.path -cne $runtime){throw 'Worker intent runtime path differs from the reviewed owned path'}
    if($rule.fields -contains 'sessionId' -and (!$Context.session -or $r.sid -cne $Context.session.sid -or [int]$r.sessionId -ne [int]$Context.session.sessionId)){throw 'Worker intent session was not durably observed by the supervisor'}
    if($r.taskName -and $r.taskName -cnotin @("Ticket569-$($Context.runId)-normal","Ticket569-$($Context.runId)-mount-point")){throw 'Worker intent task is outside the exact run task pair'}
    if($rule.kind -and ((Get-HostedIntentField $p $rule.kind) -notin @('normal','mount-point') -or $r.taskName -cne "Ticket569-$($Context.runId)-$(Get-HostedIntentField $p $rule.kind)")){throw 'Worker intent task/profile-kind pair differs'}
    if($r.scriptPath -and ($r.scriptPath -cne (Join-Path $Context.scriptRoot 'hosted-user-capability.ps1') -or $r.scriptSha256 -cne (Get-FileHash -LiteralPath $r.scriptPath -Algorithm SHA256).Hash.ToLowerInvariant())){throw 'Worker intent script path/hash differs from the pinned helper'}
    if($r.thumbprint -and $r.thumbprint -notmatch '^[A-Fa-f0-9]{40}$'){throw 'Worker intent certificate thumbprint is malformed'}
    if($r.store -and $r.store -cne $(if($op -eq 'run-pinned-cua-currentuser-root-prompt'){'CurrentUser/Root'}else{'LocalMachine/My'})){throw 'Worker intent certificate store differs'}
    if($r.volumeId -and $r.volumeId -notmatch '^\\\\\?\\Volume\{[a-fA-F0-9-]{36}\}\\$'){throw 'Worker intent volume identity is malformed'}
    if($r.paths){$allowed=@('root-prompt','root-import','root-import-attached','root-import-exit','root-import-observer-failure');foreach($path in $r.paths){if($path -cnotin @($allowed | ForEach-Object {"$profile\$_-$($Context.runId).$(if($_ -eq 'root-prompt'){'cer'}else{'json'})"})){throw 'Worker temporary-file intent includes an unowned path'}}}
    if($op -eq 'handoff-session-owner-to-supervisor-cleanup' -and ($r.pid -ne $Context.owner.pid -or $r.creationFileTimeUtc -ne $Context.owner.creationFileTimeUtc)){throw 'Worker owner handoff identity differs'}
    if($r.taskChildPID -or $op -eq 'terminate-exact-owned-user-task-child'){
        $id=if($r.taskChildPID){$r.taskChildPID}else{$r.pid};$created=if($r.childCreationFileTimeUtc){$r.childCreationFileTimeUtc}else{$r.creationFileTimeUtc}
        if(!$Context.child -or $id -ne $Context.child.pid -or ($created -and $created -ne $Context.child.creationFileTimeUtc)){throw 'Worker intent child does not match the retained authenticated peer'}
    }
    if($rule.owned){
        $owned=@($Context.replay.events | Where-Object {$_.phase -ceq 'intent' -and $_.operation -ceq $rule.owned})
        if($r.taskName){$owned=@($owned | Where-Object {$_.resourceIdentity.taskName -ceq $r.taskName})}
        if($r.thumbprint){$owned=@($Context.replay.mutations | Where-Object {$_.intent.operation -ceq $rule.owned -and $_.observation.result -ceq 'completed' -and $_.observation.observed.thumbprint -ceq $r.thumbprint})}
        if(!$owned.Count){throw 'Worker intent has no matching supervisor-journal ownership authority'}
    }
    $true
}
function Assert-HostedCapabilityHelperOperation {
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][ValidateSet('user-probe','root-import','recovery-worker','root-remove')][string]$Role)
    $allowed=@{
        'user-probe'=@('write-owned-run-credential','read-owned-run-credential','delete-owned-run-credential','verify-owned-run-credential-absence')
        'root-import'=@('seed-exact-currentuser-synthetic-credential','delete-exact-currentuser-synthetic-credential','recover-delete-exact-currentuser-synthetic-credential','import-exact-currentuser-root-certificate','remove-exact-owned-currentuser-root-certificate')
        'recovery-worker'=@('recovery-delete-exact-currentuser-synthetic-credential')
        'root-remove'=@('recovery-remove-exact-owned-currentuser-root-certificate')
    }
    if($Request.operation -cnotin $allowed[$Role]){throw 'Helper operation is not authorized for the authenticated caller role'}
    if(!$Request.precondition -or !$Request.resourceIdentity){throw 'Helper operation lacks resource/precondition evidence'}
    # Boolean preconditions cannot be replaced by strings such as "false".
    $booleanNames=@('credentialAbsent','credentialSeeded','targetExact','targetExactRunScoped','credentialJustWritten','credentialWasWritten','targetRunScoped','writeIntentSupervisorOwned','importAttempted','exactSubjectMatch','uniqueThumbprintMatch')
    foreach($name in $booleanNames){$value=Get-HostedIntentField $Request.precondition $name;if($null -ne $value -and ($value -isnot [bool] -or !$value)){throw 'Helper boolean precondition is not exactly true'}}
    $true
}
Export-ModuleMember -Function Assert-HostedCapabilityWorkerIntent, Get-HostedCapabilityWorkerIntentRules, Assert-HostedCapabilityHelperOperation
