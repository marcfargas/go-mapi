function Write-AttachmentJson([string]$Path, $Value) {
    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-AttachmentFixtures {
    @{ 'report.txt' = [Text.Encoding]::UTF8.GetBytes("exact attachment`r`nwith bytes`0"); 'image.bin' = [byte[]]@(0, 1, 2, 253, 254, 255) }
}

function Assert-AttachmentResult([string]$Directory, $Case) {
    $worker = Get-Content -LiteralPath (Join-Path $Directory 'worker.json') -Raw | ConvertFrom-Json
    $fake = Get-Content -LiteralPath (Join-Path $Directory 'fake-final.json') -Raw | ConvertFrom-Json
    if (!$worker.passed -or $worker.runId -cne $Case.runId -or $worker.error -or @($worker.cleanupErrors).Count) { throw 'Attachment worker or its cleanup failed' }
    if ($worker.profile.sid -cne $Case.sid -or $worker.profile.admin -or $worker.profile.session -le 0 -or $worker.profile.session -ne $Case.session -or $worker.profile.path -ine $Case.profilePath) { throw 'Attachment worker lacks the selected non-elevated desktop identity' }
    if ($worker.app.sha256 -cne $Case.appSha256 -or $worker.app.dllSha256 -cne $Case.dllSha256 -or $worker.app.path -ine $Case.appPath -or $worker.app.session -ne $worker.profile.session -or @($worker.app.arguments).Count -ne 0) { throw 'Attachment app/DLL identity differs from the selected package' }
    if ($Case.entryPoint -eq 'Explorer') {
        $shell = $worker.explorer
        $folder = Join-Path $Case.profilePath ('attachment files ' + $Case.runId)
        $paths = @($Case.expected.attachments.PSObject.Properties.Name | ForEach-Object { Join-Path $folder $_ } | Sort-Object)
        if ($worker.entryPoint -cne 'Explorer' -or $null -ne $worker.mapiReturn -or !$shell.invoked -or !$shell.windowClosed -or $shell.pid -le 0 -or $shell.session -ne $Case.session -or $shell.ownerSid -cne $Case.sid -or $shell.folder -ine $folder -or (@($shell.selectedPaths | Sort-Object) -join '|') -cne ($paths -join '|') -or (@($shell.menus) -join '|') -cne 'Send to|Mail recipient') { throw 'Explorer selection, menu invocation or owned window cleanup is incomplete' }
    } elseif ($worker.mapiReturn -ne 0) { throw 'Installed native call failed' }
    if (!$worker.queue.acknowledged -or !$worker.queue.descriptor -or @($worker.queue.remaining).Count -or !$worker.credentialRemoved -or !$worker.appStopped) { throw 'Attachment queue acknowledgement or owned cleanup is incomplete' }
    if (!$fake.final -or $fake.schemaVersion -ne 1 -or $fake.runId -cne $Case.runId -or $fake.failed -or @($fake.errors).Count -or $fake.rejectedRequests -ne 0 -or $fake.userInfoRequests -ne 1 -or $fake.draftAttempts -ne 1 -or !$fake.drafts -or @($fake.drafts).Count -ne 1) { throw 'Final fake result does not establish exactly one accepted draft' }
    $draft = $fake.drafts[0]
    if ($Case.entryPoint -eq 'Explorer') {
        if ($draft.recipient) { throw 'Explorer draft unexpectedly has a recipient' }
    } else {
        $recipient = [Net.Mail.MailAddress]::new($draft.recipient)
        if ($draft.subject -cne $Case.expected.subject -or $recipient.Address -cne $Case.expected.recipient) { throw 'Final draft envelope differs from the expected message' }
    }
    $seen = @{}
    foreach ($attachment in $draft.attachments) {
        $expected = $Case.expected.attachments.PSObject.Properties[$attachment.name]
        if (!$expected -or $seen.ContainsKey($attachment.name) -or $attachment.sha256 -cne $expected.Value) { throw 'Final draft attachment bytes or names differ' }
        $seen[$attachment.name] = $true
    }
    if ($seen.Count -ne @($Case.expected.attachments.PSObject.Properties).Count) { throw 'Final draft attachment set is incomplete' }
    [pscustomobject]@{ runId=$Case.runId; descriptor=$worker.queue.descriptor; appSha256=$Case.appSha256; dllSha256=$Case.dllSha256; passed=$true }
}

Export-ModuleMember -Function Write-AttachmentJson, Get-AttachmentFixtures, Assert-AttachmentResult
