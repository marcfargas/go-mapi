$ErrorActionPreference='Stop'
function Test-SupportBoolean($Value,[bool]$Expected){($Value -is [bool]) -and $Value -eq $Expected}
function Test-SupportInteger($Value){$Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [uint64]}
# This validator gives qualified supporting credit only. It is never a hosted
# capability/installed-matrix acceptance validator and cannot make CI feasible.
function Test-HostedPresentRootRecoverySupport {
    param([Parameter(Mandatory)]$Identity,[Parameter(Mandatory)]$Completion,
        [Parameter(Mandatory)]$Replay,[Parameter(Mandatory)]$IndependentAbsence,[Parameter(Mandatory)]$ResourceBinding,
        [Parameter(Mandatory)][int]$SupervisorExitCode)
    $reasons=[Collections.Generic.List[string]]::new()
    $exercise=$Completion.presentRootExercise;$e=$exercise.recoveryEvidence
    if($Identity.testFault -cne 'present-root-recovery' -or $Completion.testFault -cne 'present-root-recovery' -or !$e -or $e.testFault -cne 'present-root-recovery'){$reasons.Add('exact-exercise-binding-missing')}
    if(!$e -or $Identity.runId -cne $Completion.runId -or $Identity.sourceSHA -cne $Completion.sourceSHA -or
        $e.runId -cne $Completion.runId -or $e.sourceSHA -cne $Completion.sourceSHA){$reasons.Add('source-run-binding-missing')}
    if($SupervisorExitCode -eq 0 -or !(Test-SupportBoolean $Completion.failure $true) -or !(Test-SupportBoolean $Completion.failureLatched $true) -or
        $Completion.cleanupStatus -cne 'unverified' -or $Completion.supervisorVerdict -cne 'cleanup-failed' -or
        !(Test-SupportBoolean $Completion.localFinalWriteProven $true) -or !(Test-SupportBoolean $Completion.supervisorFinalized $true)){$reasons.Add('truthful-failed-overall-result-missing')}
    if(!(Test-SupportBoolean $Replay.valid $true) -or $Replay.pending.Count -ne 0 -or !(Test-SupportBoolean $Completion.ledgerReplayValid $true) -or $Completion.ledgerPendingMutationCount -ne 0){$reasons.Add('final-ledger-not-settled')}
    $start=@($Replay.events|Where-Object {$_.phase -ceq 'process' -and $_.operation -ceq 'supervisor-started'})
    if($start.Count -ne 1 -or $start[0].resourceIdentity.testFault -cne 'present-root-recovery'){$reasons.Add('ledger-exercise-binding-missing')}
    if(!(Test-SupportBoolean $Completion.workerTerminationProven $true) -or !(Test-SupportBoolean $Completion.ownerCleanupComplete $true) -or
        !(Test-SupportBoolean $Completion.recoveryRequired $true) -or !(Test-SupportBoolean $Completion.recoveryCompleted $true) -or
        $Completion.activeProcesses -ne 0 -or $Completion.ownerActiveProcessesFinal -ne 0 -or $Completion.recoveryActiveProcessesFinal -ne 0){$reasons.Add('retained-participant-job-exits-missing')}
    if(!(Test-SupportBoolean $e.intercept.eligible $true) -or !(Test-SupportBoolean $e.intercept.waited $true) -or $e.intercept.exitCode -ne 137 -or
        !(Test-SupportBoolean $e.barrier.accepted $true) -or !(Test-SupportBoolean $e.barrier.workerWaited $true) -or $e.barrier.workerExit -ne 137 -or !(Test-SupportBoolean $e.barrier.workerJobEmpty $true)){$reasons.Add('deliberate-intercept-barrier-proof-missing')}
    foreach($number in @($SupervisorExitCode,$Completion.workerExit,$Completion.activeProcesses,$Completion.ownerActiveProcessesFinal,$Completion.recoveryActiveProcessesFinal,$Completion.ledgerPendingMutationCount,$e.intercept.exitCode,$e.barrier.workerExit,$e.launcherExitCode,$e.recoveryCompletedCounter,$exercise.cleanupCompletedCounter,$e.cleanupDeadline,$e.recoveryCutoff,$e.counterFrequency,$e.recovery.sessionId,$e.recovery.credentialFinalCredReadError,$e.removeResult.processId,$e.removeResult.processCreationFileTimeUtc,$e.removeResult.sessionId,$e.removalExit.observed.exitCode)){
        if(!(Test-SupportInteger $number)){$reasons.Add('required-numeric-proof-missing-or-malformed')}
    }
    $thumb=[string]$e.intercept.resource.thumbprint;$subject=[string]$e.intercept.resource.subject;$r=$e.recovery;$remove=$e.removeResult
    if($thumb -notmatch '^[A-F0-9]{40}$' -or $subject -cne "CN=Ticket569-Root-Prompt-$($Completion.runId)" -or
        !$r -or !(Test-SupportBoolean $r.failed $false) -or $r.rootStatus -cne 'verified' -or !(Test-SupportBoolean $r.rootSubjectRemaining $false) -or
        $r.credentialFinalCredReadError -ne 1168 -or !(Test-SupportBoolean $r.sessionLeftActiveForSupervisorLogoff $true) -or
        @($r.removedRootThumbprints).Count -ne 1 -or $r.removedRootThumbprints[0] -cne $thumb -or
        $r.runId -cne $Completion.runId -or $r.sourceSHA -cne $Completion.sourceSHA -or $r.sid -cne $e.intercept.importer.sid -or $r.sessionId -ne $e.intercept.importer.sessionId -or
        $r.profilePath -cne $e.barrier.proof.context.profilePath -or
        !(Test-SupportBoolean $r.sessionHostHealthBefore.healthy $true) -or !(Test-SupportBoolean $r.sessionHostHealthAfter.healthy $true)){$reasons.Add('real-present-recovery-result-incomplete')}
    if(!$remove -or $remove.schema -cne 'ticket569-currentuser-root-import-v1' -or $remove.runId -cne $Completion.runId -or
        $remove.sid -cne $r.sid -or $remove.sessionId -ne $r.sessionId -or $remove.subject -cne $subject -or $remove.thumbprint -cne $thumb -or
        !(Test-SupportBoolean $remove.passed $true) -or !(Test-SupportBoolean $remove.removedOwned $true) -or !(Test-SupportBoolean $remove.removedObserved $true) -or
        !(Test-SupportBoolean $e.removalExit.observed.waitedHandle $true) -or !(Test-SupportBoolean $e.removalExit.observed.identityMatched $true) -or $e.removalExit.observed.exitCode -ne 0 -or
        $e.removalExit.processIdentity.role -cne 'root-remove' -or $e.removalExit.processIdentity.pid -ne $remove.processId -or
        $e.removalExit.processIdentity.creationFileTimeUtc -ne $remove.processCreationFileTimeUtc){$reasons.Add('waited-actual-RemoveOwned-result-incomplete')}
    $mutations=@($Replay.mutations|Where-Object {$_.intent.operation -ceq 'recovery-remove-exact-owned-currentuser-root-certificate' -and $_.intent.resourceIdentity.thumbprint -ceq $thumb})
    if($mutations.Count -ne 1 -or $mutations[0].observation.result -cne 'completed' -or !(Test-SupportBoolean $mutations[0].observation.observed.absent $true) -or
        !(Test-SupportBoolean $mutations[0].intent.precondition.exactSubjectMatch $true) -or !(Test-SupportBoolean $mutations[0].intent.precondition.uniqueThumbprintMatch $true) -or
        $mutations[0].intent.precondition.preabsenceSequence -ne $e.intercept.preabsenceSequence -or $mutations[0].intent.precondition.importAttemptSequence -ne $e.intercept.importSequence -or
        $mutations[0].intent.processIdentity.role -cne 'root-remove'){$reasons.Add('actual-present-removal-ledger-ownership-missing')}
    if($e.launcherExitCode -ne 0 -or !(Test-SupportBoolean $e.recoveryJobEmpty $true) -or !$e.launcher.pid -or !$e.launcher.creationFileTimeUtc -or
        $e.launcherAncestry.launcher.pid -ne $e.launcher.pid -or $e.launcherAncestry.launcher.scriptSHA256 -cne $e.launcher.scriptSHA256 -or
        $e.launcherAncestry.workerScriptSHA256 -cne $e.launcher.workerScriptSHA256 -or !(Test-SupportBoolean $e.launcherAncestry.suspendedChildValidated $true) -or
        !(Test-SupportBoolean $e.launcherAncestry.gateReleased $true) -or $e.launcherAncestry.child.sid -cne $r.sid -or $e.launcherAncestry.child.sessionId -ne $r.sessionId -or
        !$e.launcherAncestry.child.creationFileTimeUtc){$reasons.Add('real-recovery-ancestry-incomplete')}
    if($e.removalConsent.status -cne 'observed-and-answered' -or !(Test-SupportBoolean $e.removalConsent.promptClosed $true) -or
        !$e.removalConsent.observation.pid -or !$e.removalConsent.observation.windowId -or !$e.removalConsent.observation.affirmativeElementToken){$reasons.Add('real-owned-removal-CUA-incomplete')}
    if($e.counterFrequency -le 0 -or !(Test-SupportBoolean $e.barrier.proof.admission.allowed $true) -or $e.barrier.proof.admission.counter -ge $e.barrier.proof.admission.workDeadline -or
        $e.recoveryCompletedCounter -le $e.barrier.proof.admission.counter -or $e.recoveryCompletedCounter -ge $e.recoveryCutoff -or
        $exercise.cleanupCompletedCounter -lt $e.recoveryCompletedCounter -or $exercise.cleanupCompletedCounter -ge $e.cleanupDeadline){$reasons.Add('absolute-timing-proof-incomplete')}
    $cleanup=@($Replay.events|Where-Object {$_.operation -ceq 'same-session-recovery-completed-before-j-plus-24' -and (Test-SupportBoolean $_.resourceIdentity.sensitiveContextProven $true) -and (Test-SupportBoolean $_.resourceIdentity.ownedCleanup.profileRemoved $true) -and (Test-SupportBoolean $_.resourceIdentity.ownedCleanup.userRemoved $true)})
    if($cleanup.Count -ne 1 -or !(Test-SupportBoolean $exercise.ownedCleanup.profileRemoved $true) -or !(Test-SupportBoolean $exercise.ownedCleanup.userRemoved $true)){$reasons.Add('owned-profile-user-cleanup-missing')}
    foreach($op in @('remove-exact-run-localmachine-prompt-certificate','remove-empty-owned-hosted-runtime-root')){
        $completed=@($Replay.mutations|Where-Object {$_.intent.operation -ceq $op -and $_.observation.result -ceq 'completed' -and (Test-SupportBoolean $_.observation.observed.absent $true)})
        if(!$completed.Count){$reasons.Add("cleanup-ledger-proof-missing:$op")}
    }
    if($ResourceBinding.runId -cne $Completion.runId -or $ResourceBinding.sourceSHA -cne $Completion.sourceSHA -or
        !$ResourceBinding.leaseId -or $IndependentAbsence.leaseId -cne $ResourceBinding.leaseId -or
        $IndependentAbsence.schema -cne 'ticket569-present-root-independent-absence-v1' -or $IndependentAbsence.runId -cne $Completion.runId -or
        $IndependentAbsence.sourceSHA -cne $Completion.sourceSHA -or $IndependentAbsence.sid -cne $r.sid -or $IndependentAbsence.sessionId -ne $r.sessionId -or
        !$IndependentAbsence.verifier -or $IndependentAbsence.verifier -ceq $IndependentAbsence.executor){$reasons.Add('distinct-independent-checker-binding-missing')}
    foreach($name in @('account','rdpMembership','profileRecord','profileDirectory','profileHive','userSession','exportedCer','localMachinePromptCertificate','probeTasks','runtimeDirectory','participantProcesses','jobs','azureResources','brokerCredentials','sshKey','tunnel','rdpConnection')){
        $resource=$IndependentAbsence.resources.$name
        $expectedResource=$ResourceBinding.resources.$name
        if(!$expectedResource -or !$resource -or !(Test-SupportBoolean $resource.absent $true) -or !$resource.resourceIdentity -or !$resource.rawEvidenceSHA256 -or $resource.rawEvidenceSHA256 -notmatch '^[a-f0-9]{64}$' -or
            (ConvertTo-Json $expectedResource -Depth 32 -Compress) -cne (ConvertTo-Json $resource.resourceIdentity -Depth 32 -Compress)){$reasons.Add("independent-absence-missing:$name")}
    }
    [pscustomobject]@{qualifiedSupportingObserved=($reasons.Count -eq 0);verdict=if($reasons.Count){'unverified-qualified-support'}else{'qualified-present-root-support-observed'};reasons=@($reasons);acceptanceCredit=$false;historicalCauseCredit=$false;timings=@{barrier=$e.barrier.proof.admission;recovery=$e.recoveryCompletedCounter;cleanup=$exercise.cleanupCompletedCounter}}
}
Export-ModuleMember -Function Test-HostedPresentRootRecoverySupport
