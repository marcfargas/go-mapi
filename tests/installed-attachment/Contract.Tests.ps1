$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Attachment.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('attachment-oracle-'+[guid]::NewGuid().ToString('N'))
function Clone($Value) { $Value | ConvertTo-Json -Depth 12 | ConvertFrom-Json }
function Check([bool]$Condition,[string]$Message) { if (!$Condition) { throw $Message } }
$case=Clone @{
    runId='owned-smoke';sid='S-1-5-21-1-2-3-1001';profilePath='C:\Users\owned';session=1
    appPath='C:\Program Files\go-mapi\user\go-mapi.exe';appSha256=('a'*64);dllSha256=('b'*64)
    expected=@{subject='Exact subject';recipient='attachment@example.invalid';attachments=@{'report.txt'=('c'*64);'image.bin'=('d'*64)}}
}
$worker=Clone @{
    runId=$case.runId;passed=$true;error=$null;cleanupErrors=@();mapiReturn=0;appStopped=$true;credentialRemoved=$true
    profile=@{sid=$case.sid;path=$case.profilePath;admin=$false;session=1}
    app=@{path=$case.appPath;sha256=$case.appSha256;dllSha256=$case.dllSha256;session=1;arguments=@()}
    queue=@{acknowledged=$true;descriptor='owned.json';remaining=@()}
}
$fake=Clone @{
    final=$true;schemaVersion=1;runId=$case.runId;failed=$false;errors=@();rejectedRequests=0
    userInfoRequests=1;draftAttempts=1
    drafts=@(@{subject=$case.expected.subject;recipient=('Owned <'+$case.expected.recipient+'>');attachments=@(@{name='report.txt';sha256=('c'*64)},@{name='image.bin';sha256=('d'*64)})})
}
function Verify($WorkerValue,$FakeValue,$CaseValue) {
    Write-AttachmentJson (Join-Path $root 'worker.json') $WorkerValue
    Write-AttachmentJson (Join-Path $root 'fake-final.json') $FakeValue
    Assert-AttachmentResult $root $CaseValue
}
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    Check (Verify $worker $fake $case).passed 'Valid installed smoke was rejected'
    $rejections=@(
        @{name='primary failure';worker={param($w) $w.passed=$false}},
        @{name='cleanup failure';worker={param($w) $w.cleanupErrors=@('credential cleanup')}},
        @{name='wrong run';worker={param($w) $w.runId='other'}},
        @{name='wrong user';worker={param($w) $w.profile.sid='other'}},
        @{name='administrator';worker={param($w) $w.profile.admin=$true}},
        @{name='session zero';worker={param($w) $w.profile.session=0}},
        @{name='different desktop session';worker={param($w) $w.profile.session=2}},
        @{name='fake profile path';worker={param($w) $w.profile.path='C:\fabricated'}},
        @{name='wrong app';worker={param($w) $w.app.sha256=('e'*64)}},
        @{name='wrong DLL';worker={param($w) $w.app.dllSha256=('e'*64)}},
        @{name='app arguments';worker={param($w) $w.app.arguments=@('--queue')}},
        @{name='MAPI failure';worker={param($w) $w.mapiReturn=2}},
        @{name='no acknowledgement';worker={param($w) $w.queue.acknowledged=$false}},
        @{name='no descriptor';worker={param($w) $w.queue.descriptor=$null}},
        @{name='queue leftovers';worker={param($w) $w.queue.remaining=@('unacknowledged.json')}},
        @{name='live app';worker={param($w) $w.appStopped=$false}},
        @{name='credential remains';worker={param($w) $w.credentialRemoved=$false}},
        @{name='nonfinal snapshot';fake={param($f) $f.final=$false}},
        @{name='wrong fake run';fake={param($f) $f.runId='other'}},
        @{name='latched rejection';fake={param($f) $f.failed=$true}},
        @{name='duplicate authentication';fake={param($f) $f.userInfoRequests=2}},
        @{name='duplicate draft';fake={param($f) $f.drafts=@($f.drafts[0],$f.drafts[0])}},
        @{name='no accepted draft';fake={param($f) $f.drafts=@()}},
        @{name='failed draft attempt';fake={param($f) $f.draftAttempts=2}},
        @{name='wrong subject';fake={param($f) $f.drafts[0].subject='different'}},
        @{name='recipient substring';fake={param($f) $f.drafts[0].recipient='prefixattachment@example.invalid'}},
        @{name='wrong bytes';fake={param($f) $f.drafts[0].attachments[0].sha256=('e'*64)}},
        @{name='duplicate attachment';fake={param($f) $f.drafts[0].attachments[1]=$f.drafts[0].attachments[0]}},
        @{name='missing attachment';fake={param($f) $f.drafts[0].attachments=@($f.drafts[0].attachments[0])}}
    )
    foreach ($test in $rejections) {
        $w=Clone $worker;$f=Clone $fake
        if ($test.worker) { & $test.worker $w }
        if ($test.fake) { & $test.fake $f }
        $rejected=$false
        try { $null=Verify $w $f $case } catch { $rejected=$true }
        Check $rejected ('Oracle accepted '+$test.name)
    }
    foreach ($content in @($null, '{')) {
        $null=Verify $worker $fake $case
        $path=Join-Path $root 'fake-final.json'
        if ($null -eq $content) { Remove-Item -LiteralPath $path } else { [IO.File]::WriteAllText($path,$content) }
        $rejected=$false
        try { $null=Assert-AttachmentResult $root $case } catch { $rejected=$true }
        Check $rejected 'Oracle accepted a missing or truncated final snapshot'
    }
    $fixtures=Get-AttachmentFixtures
    Check ([BitConverter]::ToString($fixtures['image.bin']) -ceq '00-01-02-FD-FE-FF') 'Binary fixture changed'
    Check ([Text.Encoding]::UTF8.GetString($fixtures['report.txt']) -ceq "exact attachment`r`nwith bytes`0") 'Text fixture changed'
    $explorerCase=Clone $case
    $explorerCase | Add-Member entryPoint Explorer
    $explorerCase.expected.subject=''; $explorerCase.expected.recipient=''
    $explorerWorker=Clone $worker
    $explorerWorker.mapiReturn=$null
    $explorerWorker | Add-Member entryPoint Explorer
    $folder=Join-Path $case.profilePath ('attachment files '+$case.runId)
    $explorerWorker | Add-Member explorer ([pscustomobject]@{pid=123;session=1;ownerSid=$case.sid;folder=$folder;selectedPaths=@((Join-Path $folder 'image.bin'),(Join-Path $folder 'report.txt'));menus=@('Send to','Mail recipient');invoked=$true;windowClosed=$true})
    $explorerFake=Clone $fake
    $explorerFake.drafts[0].subject='Emailing report.txt, image.bin'
    $explorerFake.drafts[0].recipient=''
    Check (Verify $explorerWorker $explorerFake $explorerCase).passed 'Valid Explorer smoke was rejected'
    foreach ($change in @(
        {param($w) $w.explorer=$null},
        {param($w) $w.mapiReturn=0},
        {param($w) $w.entryPoint='InstalledDll'},
        {param($w) $w.explorer.selectedPaths=@('C:\other\report.txt')},
        {param($w) $w.explorer.menus=@('Send to')},
        {param($w) $w.explorer.invoked=$false},
        {param($w) $w.explorer.windowClosed=$false},
        {param($w) $w.explorer.ownerSid='other'},
        {param($w) $w.explorer.session=2}
    )) {
        $w=Clone $explorerWorker
        & $change $w
        $rejected=$false
        try { $null=Verify $w $explorerFake $explorerCase } catch { $rejected=$true }
        Check $rejected 'Oracle accepted incomplete or substituted Explorer evidence'
    }
    $rejected=$false
    try { $null=Verify $explorerWorker $fake $explorerCase } catch { $rejected=$true }
    Check $rejected 'Oracle accepted an addressed Explorer draft'
    'Attachment oracle contracts passed'
} finally {
    # The only recursive deletion is this exact, newly created temporary test directory.
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
