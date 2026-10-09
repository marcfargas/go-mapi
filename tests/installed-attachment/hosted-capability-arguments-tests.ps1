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
