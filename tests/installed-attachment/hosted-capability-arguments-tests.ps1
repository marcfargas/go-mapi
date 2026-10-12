$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
$path='C:\source with spaces\hosted-capability-recovery-worker.ps1';$run='a'*32;$sha='b'*40;$hash='c'*64
$expected=@{'-File'=$path;'-RunId'=$run;'-SourceSHA'=$sha;'-ExpectedWorkerSHA256'=$hash}
foreach($command in @(( '"powershell.exe" "-File" "'+$path+'" "-RunId" "'+$run+'" "-SourceSHA" "'+$sha+'" "-ExpectedWorkerSHA256" "'+$hash+'"'),('powershell.exe -File "'+$path+'" -RunId '+$run+' -SourceSHA '+$sha+' -ExpectedWorkerSHA256 '+$hash))){
    if(!(Test-HostedCapabilityCommandArguments $command $expected)){throw 'Own generated quoted or task argument form was rejected'}
    foreach($bad in @($command.Replace($sha,'d'*40),($command+' -RunId '+$run),$command.Replace('"'+$path+'"','"'+$path+'suffix"'),($command+' "unbalanced'))){
        if(Test-HostedCapabilityCommandArguments $bad $expected){throw 'Malformed or mismatched command line was accepted'}
    }
}
$escaped=[Ticket569CapabilityNative]::SplitCommandLine('"powershell.exe" "C:\trailing\\" "embedded\"quote"')
if($escaped[1] -cne 'C:\trailing\' -or $escaped[2] -cne 'embedded"quote'){throw 'Command argument escapes did not round trip'}
Write-Output 'QUOTED_GENERATED_AND_TASK_COMMAND_ARGUMENTS_PASSED;WINDOWS_PROCESS_CREATION_UNRUN_ON_LINUX'

# Exercise the actual nested command's PID writer, without starting a sleeper.
# Its pipeline object must survive generation in a different parent scope.
$tokens=$null;$errors=$null
$fixture=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'hosted-capability-process-tests.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Native process fixture did not parse'}
$assignments=@($fixture.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$grandchildCommand'},$true))
if($assignments.Count -ne 1){throw 'Actual grandchild command generation is missing/ambiguous'}
$generate=[scriptblock]::Create($assignments[0].Extent.Text)
foreach($parentItem in @($null,[pscustomobject]@{Id=8181})){
    & {
        param($Generate,$ParentItem)
        $pwsh='fixture-pwsh';$grandchildPath=Join-Path ([IO.Path]::GetTempPath()) ('t569 nested pid '+[guid]::NewGuid().ToString('N'));$_=$ParentItem
        try{
            . $Generate
            $tokens=$null;$errors=$null;$inner=[Management.Automation.Language.Parser]::ParseInput($grandchildCommand,[ref]$tokens,[ref]$errors)
            $writers=@($inner.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Extent.Text.Contains('WriteAllText')},$true))
            if($errors.Count -or $writers.Count -ne 1){throw 'Generated grandchild PID writer is missing/malformed'}
            [pscustomobject]@{Id=4242}|ForEach-Object ([scriptblock]::Create($writers[0].Extent.Text))
            if([IO.File]::ReadAllText($grandchildPath) -cne '4242'){throw 'Grandchild PID writer interpolated the parent pipeline identity or emitted an empty PID'}
        }finally{if([IO.File]::Exists($grandchildPath)){[IO.File]::Delete($grandchildPath)}}
    } $generate $parentItem
}
Write-Output 'NESTED_GRANDCHILD_COMMAND_ACTUAL_PID_WRITE_PASSED;WINDOWS_PROCESS_CREATION_UNRUN_ON_LINUX'
