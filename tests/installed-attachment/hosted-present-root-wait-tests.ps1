$ErrorActionPreference='Stop'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('t569-barrier-wait-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $fixture
$childScript=Join-Path $fixture 'exact-barrier-child.ps1'
@'
param($PipeName,$SourceRoot,$CleanupPath,[int]$DeadlineSeconds)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $SourceRoot 'hosted-capability-clock.psm1') -Force
Import-Module (Join-Path $SourceRoot 'hosted-capability-protocol.psm1') -Force
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'hosted-capability.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Worker parse failed'}
foreach($name in @('Send-HostedPresentRootBarrier','Get-HostedCounter')){
 $found=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($found.Count -ne 1){throw "Exact source function missing $name"}
 . ([scriptblock]::Create($found[0].Extent.Text))
}
$script:counterFrequency=[Diagnostics.Stopwatch]::Frequency
$script:jobStartCounter=[Diagnostics.Stopwatch]::GetTimestamp()
$script:workDeadlineCounter=$jobStartCounter+[long]$DeadlineSeconds*$counterFrequency
$script:TestFault='present-root-recovery';$script:runId='a'*32;$script:sourceSHA='b'*40
$script:supervisorConnection=Connect-HostedCapabilitySupervisor -PipeName $PipeName
try{Send-HostedPresentRootBarrier -Observed @{observationAcknowledged=$true}}
catch{[IO.File]::WriteAllText($CleanupPath+'.error',$_.Exception.Message)}
finally{
 [IO.File]::WriteAllText($CleanupPath,'ordinary-finally-cleanup-adapter')
 Close-HostedCapabilitySupervisorConnection $supervisorConnection
}
'@ | Set-Content -LiteralPath $childScript -Encoding utf8
$exe=(Get-Process -Id $PID).Path
try{
 foreach($case in @('delayed-accept','refused','eof','deadline')){
  $pipeName='Ticket569-'+[guid]::NewGuid().ToString('N')
  $server=[IO.Pipes.NamedPipeServerStream]::new($pipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous)
  $child=$null;$reader=$null;$writer=$null
  $cleanup=Join-Path $fixture ($case+'.cleanup')
  $deadline=if($case -ceq 'deadline'){3}else{90}
  try{
   $connectionTask=$server.WaitForConnectionAsync()
   $child=Start-Process -FilePath $exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',('"'+$childScript+'"'),'-PipeName',$pipeName,'-SourceRoot',('"'+$PSScriptRoot+'"'),'-CleanupPath',('"'+$cleanup+'"'),'-DeadlineSeconds',[string]$deadline) -PassThru -RedirectStandardOutput (Join-Path $fixture ($case+'.stdout')) -RedirectStandardError (Join-Path $fixture ($case+'.stderr'))
   if(!$connectionTask.Wait(10000)){throw "Test child did not connect $case"}
   $reader=[IO.StreamReader]::new($server,[Text.UTF8Encoding]::new($false),$false,4096,$true)
   $writer=[IO.StreamWriter]::new($server,[Text.UTF8Encoding]::new($false),4096,$true);$writer.AutoFlush=$true
   $requestTask=$reader.ReadLineAsync()
   if(!$requestTask.Wait(10000)){throw "Test child sent no barrier $case"}
   $request=ConvertFrom-Json $requestTask.Result
   if($request.event -cne 'present-root-recovery-barrier' -or $request.phase -cne 'lifecycle'){throw 'Wrong exact barrier request'}
   if($case -ceq 'delayed-accept'){
    $elapsed=[Diagnostics.Stopwatch]::StartNew()
    while($elapsed.ElapsedMilliseconds -lt 31000){
     if($child.WaitForExit(100)){throw ('Barrier reached cleanup before delayed acceptance: '+(Get-Content ($cleanup+'.error') -Raw -ErrorAction SilentlyContinue))}
     if(Test-Path -LiteralPath $cleanup){throw 'Delayed acceptance ran cleanup while validation remained pending'}
    }
    # An actual local retained child is stopped after >30s, adapting only the
    # accepted Windows Job termination. No acceptance acknowledgement is sent.
    $child.Kill()
    if(!$child.WaitForExit(5000) -or (Test-Path -LiteralPath $cleanup)){throw 'Delayed accepted termination allowed worker finally cleanup'}
    Write-Output "PRESENT_ROOT_BARRIER_DELAYED_ACCEPT elapsedMilliseconds=$($elapsed.ElapsedMilliseconds) cleanup=absent;REAL_LOCAL_PIPE_PROCESS_WINDOWS_JOB_ADAPTED"
   }else{
    if($case -ceq 'refused'){$writer.WriteLine((ConvertTo-Json -Compress @{acknowledged=$true;requestId=$request.requestId;status='refused'}))}
    if($case -ceq 'eof'){$writer.Dispose();$writer=$null;$reader.Dispose();$reader=$null;$server.Dispose()}
    if(!$child.WaitForExit(10000) -or !(Test-Path -LiteralPath $cleanup)){throw "Refused/EOF/deadline did not reach ordinary cleanup $case"}
    if($case -ceq 'refused' -and (Test-Path ($cleanup+'.error'))){throw 'Exact refusal did not return normally'}
    if($case -ceq 'eof' -and (Get-Content ($cleanup+'.error') -Raw) -notmatch 'closed'){throw 'EOF was not refused'}
    if($case -ceq 'deadline' -and (Get-Content ($cleanup+'.error') -Raw) -notmatch 'J\+21'){throw 'Absolute work deadline was not enforced'}
    Write-Output "PRESENT_ROOT_BARRIER_RELEASE case=$case cleanup=observed;REAL_LOCAL_PIPE_PROCESS_WINDOWS_NATIVE_UNRUN"
   }
  }finally{
   if($child){if(!$child.HasExited){$child.Kill();$null=$child.WaitForExit(5000)};$child.Dispose()}
   if($writer){$writer.Dispose()};if($reader){$reader.Dispose()};$server.Dispose()
  }
 }
 Write-Output 'PRESENT_ROOT_BARRIER_DELAY_REFUSAL_EOF_DEADLINE_EXACT_SOURCE_PASSED;WINDOWS_JOB_UNRUN'
}finally{Remove-Item -LiteralPath $fixture -Recurse -Force}
