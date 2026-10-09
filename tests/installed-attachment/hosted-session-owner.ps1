[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $RunId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $SourceSHA,
    [Parameter(Mandatory)][ValidatePattern('^Ticket569-[a-f0-9]{32}-session-owner$')][string] $PipeName,
    [Parameter(Mandatory)][string] $BinaryDirectory,
    [Parameter(Mandatory)][ValidatePattern('^Global\\Ticket569-[a-f0-9]{32}-session-owner$')][string] $OwnerJobName,
    [Parameter(Mandatory)][ValidatePattern('^S-1-5-')][string] $SupervisorSID,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [Parameter(Mandatory)][int] $SupervisorPID,
    [Parameter(Mandatory)][long] $SupervisorCreationFileTimeUtc,
    [Parameter(Mandatory)][long] $JobStartCounter,
    [Parameter(Mandatory)][ValidateRange(1,10000000000)][long] $CounterFrequency,
    [Parameter(Mandatory)][string] $SessionName='ticket569'
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
$ownerDeadline=$JobStartCounter+24L*60L*$CounterFrequency
function Get-OwnerWait([int]$Milliseconds){Get-HostedCapabilityWaitBudget $ownerDeadline $CounterFrequency $Milliseconds}
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-password.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-bundle.psm1') -Force
$sourceSHA=$SourceSHA.ToLowerInvariant()
$ownerSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$ownerSession=(Get-Process -Id $PID).SessionId
if($ownerSID -cne $SupervisorSID){throw 'Session owner token SID differs from the recorded supervisor SID'}
$supervisorIdentity=Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$SupervisorPID) -CreationFileTimeUtc $SupervisorCreationFileTimeUtc
if(!$supervisorIdentity.matches){throw 'Session owner refused a stale or mismatched supervisor PID/creation identity'}
$pipe=$null;$reader=$null;$writer=$null;$worker=$null;$recovery=$null;$script:promptProcess=$null;$script:promptIdentity=$null;$promptEvidencePath=$null;$script:promptCompleted=$false;$script:state='disconnected';$script:loginCount=0;$script:daemonProcess=$null;$script:guestBundleVerified=$false
$script:importerIdentity=$null;$script:importerProcess=$null;$script:importerParentHandle=$null;$script:promptServiceReceipt=$null
$script:promptArguments=$null;$script:promptRecoveryAllowed=$false
$runtime=Join-Path ([IO.Path]::GetTempPath()) ('ticket569-rdpilot-owner-'+$RunId)
$cli=Join-Path $BinaryDirectory 'rdpilot.exe';$daemon=Join-Path $BinaryDirectory 'rdpilot-daemon.exe'

function New-PrivateEnv {
    $envMap=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($key in @('PATH','SYSTEMROOT','WINDIR','TEMP','TMP','USERPROFILE','USERNAME','COMPUTERNAME','HOMEDRIVE','HOMEPATH','LOCALAPPDATA','APPDATA')) {
        $value=[Environment]::GetEnvironmentVariable($key);if($value){$envMap[$key]=$value}
    }
    foreach($directory in @('runtime','config','share','cache','appdata')) {New-Item -ItemType Directory -Path (Join-Path $runtime $directory) -Force | Out-Null}
    $configDirectory=Join-Path (Join-Path $runtime 'appdata') 'rdpilot'
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    $configPath=Join-Path $configDirectory 'config.toml'
    $bundlePath=Join-Path $BinaryDirectory 'guest-bundle'
    $bundleReceiptPath=Join-Path $bundlePath 'guest-bundle.json'
    if(!(Test-Path -LiteralPath $bundleReceiptPath -PathType Leaf)){throw 'Pinned guest bundle receipt is missing'}
    try {$bundleReceipt=Get-Content -LiteralPath $bundleReceiptPath -Raw | ConvertFrom-Json -ErrorAction Stop}catch{throw 'Pinned guest bundle receipt is malformed'}
    $bundleContract=Get-HostedCapabilityCuaBundleContract
    $archivePath=Join-Path $bundlePath $bundleContract.ArchiveName
    $bridgePath=Join-Path $bundlePath 'rdpilot-bridge.exe'
    if($bundleReceipt.schema -cne 'ticket569-rdpilot-guest-bundle-v1' -or
       $bundleReceipt.rdpilotSourceCommit -cne '8f799dd1e37422a8966833a08e4ec279f645ec58' -or
       $bundleReceipt.sourceSHA -cne $sourceSHA -or
       $bundleReceipt.cuaReleaseTag -cne $bundleContract.ReleaseTag -or
       $bundleReceipt.cuaArchive -cne $bundleContract.ArchiveName -or
       [long]$bundleReceipt.cuaArchiveBytes -ne $bundleContract.ArchiveBytes -or
       $bundleReceipt.cuaArchiveSHA256 -cne $bundleContract.ArchiveSHA256 -or
       !(Test-Path -LiteralPath $archivePath -PathType Leaf) -or !(Test-Path -LiteralPath $bridgePath -PathType Leaf)) {
        throw 'Pinned guest bundle receipt does not match the supported CUA input contract'
    }
    if(!$script:guestBundleVerified){
        if((Get-Item -LiteralPath $archivePath).Length -ne $bundleContract.ArchiveBytes -or
           (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $bundleContract.ArchiveSHA256 -or
           (Get-FileHash -LiteralPath $bridgePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$bundleReceipt.bridgeSHA256) {
            throw 'Pinned guest bundle files changed after bounded preflight verification'
        }
        $script:guestBundleVerified=$true
    }
    $escapedBundle=$bundlePath.Replace('\','\\').Replace('"','\"')
    $expectedConfig="bundle_path = `"$escapedBundle`"`n"
    if(Test-Path -LiteralPath $configPath){
        if([IO.File]::ReadAllText($configPath) -cne $expectedConfig){throw 'Session-owner rdpilot config changed after pinning'}
    }else{[IO.File]::WriteAllText($configPath,$expectedConfig,[Text.UTF8Encoding]::new($false))}
    # Pinned resolve.rs consumes this process-local override on Windows as well.
    $envMap['RDPILOT_BUNDLE_PATH']=[IO.Path]::GetFullPath($bundlePath)
    $envMap['RDPILOT_SOURCE_SHA']='8f799dd1e37422a8966833a08e4ec279f645ec58'
    $envMap['APPDATA']=Join-Path $runtime 'appdata'
    $envMap['XDG_RUNTIME_DIR']=Join-Path $runtime 'runtime';$envMap['XDG_CONFIG_HOME']=Join-Path $runtime 'config'
    $envMap['XDG_CACHE_HOME']=Join-Path $runtime 'cache';$envMap['RDPILOT_SHARE_ROOT']=Join-Path $runtime 'share'
    $envMap['RDPILOT_DAEMON_SINK_PATH']=Join-Path $runtime 'sessions.json'
    $envMap['RDPILOT_DAEMON_IDLE_TIMEOUT_MS']='1800000';$envMap['RDPILOT_DAEMON_EMPTY_GRACE_MS']='1800000'
    $envMap
}
function Invoke-Rdpilot([string[]] $Arguments,[Collections.Generic.IDictionary[string,string]] $Environment,[int] $TimeoutSeconds=180,
                       [IO.Pipes.NamedPipeServerStream] $PasswordPipe=$null,[string] $Password=$null,[string] $PasswordCommand=$null) {
    $binary=if($Arguments[0] -ceq '__daemon__'){$daemon}else{$cli}
    $psi=[Diagnostics.ProcessStartInfo]::new($binary);$psi.Environment.Clear();$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($key in $Environment.Keys){$psi.Environment[$key]=$Environment[$key]}
    foreach($argument in $Arguments){if($argument -cne '__daemon__'){$psi.ArgumentList.Add([string]$argument)}}
    $process=[Diagnostics.Process]::Start($psi)
    $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
    try {
        if($PasswordPipe){
            if(!$Password -or $Password.Length -gt 512 -or !$PasswordCommand){throw 'one-shot PasswordCommand transfer arguments are malformed'}
            $passwordBudget=Get-OwnerWait 15000
            if($passwordBudget -le 0){throw 'Password transfer reached the absolute owner deadline'}
            $null=Send-HostedCapabilityOneShotPassword -Pipe $PasswordPipe -Secret $Password -GetClientProcessId {
                param($pipe)
                Get-HostedCapabilityPipeClientProcessId -PipeHandle $pipe.SafePipeHandle.DangerousGetHandle()
            } -TimeoutMilliseconds $passwordBudget -VerifyClient {
                param($clientPID)
                Test-HostedCapabilityPasswordPeer -ClientPID $clientPID -LauncherPID ([uint32]$process.Id) -LauncherCreationFileTimeUtc ($process.StartTime.ToUniversalTime().ToFileTimeUtc()) -LauncherExecutable $cli -EncodedCommand (($PasswordCommand -split ' -EncodedCommand ')[1]) -OwnerSID $ownerSID -OwnerSession $ownerSession -OwnerJobName $OwnerJobName
            }
        }
        if(!$process.WaitForExit((Get-OwnerWait ($TimeoutSeconds*1000)))){$process.Kill($true);$process.WaitForExit((Get-OwnerWait 5000))|Out-Null;throw 'Pinned rdpilot operation exceeded its bounded process wait'}
        if(!$stdoutTask.Wait((Get-OwnerWait 5000)) -or !$stderrTask.Wait((Get-OwnerWait 5000))){throw 'Pinned rdpilot output EOF exceeded the absolute owner deadline'}
        $stdout=$stdoutTask.Result;$null=$stderrTask.Result;$exit=$process.ExitCode
    } catch {
        if(!$process.HasExited){try{$process.Kill($true);$process.WaitForExit((Get-OwnerWait 5000))|Out-Null}catch{}}
        throw
    } finally {
        if($PasswordPipe){$PasswordPipe.Dispose()}
        $Password=$null
        $process.Dispose()
    }
    if($exit -ne 0){throw 'Pinned rdpilot command returned a nonzero exit'}
    try {ConvertFrom-Json -InputObject $stdout -ErrorAction Stop} catch {throw 'Pinned rdpilot command returned malformed JSON'}
}
function New-LoginPasswordPipeName([int] $Ordinal) {
    $random=[Security.Cryptography.RandomNumberGenerator]::Create();$bytes=New-Object byte[] 16
    try {$random.GetBytes($bytes);$suffix=([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()}
    finally {$random.Dispose();[Array]::Clear($bytes,0,$bytes.Length)}
    "Ticket569-$RunId-login-$Ordinal-$suffix"
}
function Assert-BridgeHealth([Collections.Generic.IDictionary[string,string]] $Environment) {
    $receipt=Invoke-Rdpilot @('ping','--session',$SessionName,'--json') $Environment 20
    if($null -eq $receipt -or $receipt.ok -isnot [bool] -or !$receipt.ok){throw 'Pinned rdpilot ping did not return its exact {ok:true} health receipt'}
    $receipt
}
function Read-PromptServiceLine([int] $TimeoutMilliseconds) {
    if(!$script:promptProcess -or $script:promptProcess.HasExited){throw 'session-host MCP service is not running'}
    $read=$script:promptProcess.StandardOutput.ReadLineAsync()
    if(!$read.Wait((Get-OwnerWait $TimeoutMilliseconds))){throw 'session-host MCP service exceeded its bounded response wait'}
    $line=$read.Result
    if(!$line -or $line.Length -gt 1048576){throw 'session-host MCP service response is missing or oversized'}
    ConvertFrom-Json -InputObject $line -ErrorAction Stop
}
function Get-PromptArgumentValue([string[]] $Arguments,[string] $Name) {
    $indices=@();for($i=0;$i -lt $Arguments.Count;$i++){if($Arguments[$i] -ceq $Name){$indices+=$i}}
    if($indices.Count -ne 1 -or $indices[0]+1 -ge $Arguments.Count){throw "session-host prompt arguments must contain exactly one $Name value"}
    [string]$Arguments[$indices[0]+1]
}
function Start-PromptService([object] $Request) {
    if($script:promptProcess -or ($script:promptCompleted -and !$script:recoveryPromptStarting)){throw 'session-host prompt service permits one run-scoped prompt operation'}
    $arguments=@($Request.promptArguments)
    if(!$arguments.Count -or $arguments.Count -gt 64 -or @($arguments | Where-Object {$_ -isnot [string] -or $_.Length -gt 4096}).Count){throw 'session-host prompt arguments are malformed or oversized'}
    if(@($arguments | Where-Object {$_ -match '^--(?:service|bin-dir|runtime-root|session-name)(?:=|$)'}).Count){throw 'session-host prompt request attempted to override an owner-pinned service argument'}
    $expectedEvidence=[IO.Path]::GetFullPath((Join-Path $EvidenceDirectory 'current-user-root-prompt.json'))
    $expectedImporter=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'hosted-root-import.ps1'))
    $expectedObserver=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'process-observer.ps1'))
    if([IO.Path]::GetFullPath((Get-PromptArgumentValue $arguments '--evidence')) -cne $expectedEvidence -or
       [IO.Path]::GetFullPath((Get-PromptArgumentValue $arguments '--import-script')) -cne $expectedImporter -or
       [IO.Path]::GetFullPath((Get-PromptArgumentValue $arguments '--observer-script')) -cne $expectedObserver -or
       (Get-PromptArgumentValue $arguments '--run-id') -cne $RunId -or
       (Get-PromptArgumentValue $arguments '--source-sha') -cne $sourceSHA -or
       (Get-PromptArgumentValue $arguments '--supervisor-pipe') -cne "Ticket569-$RunId-helper" -or
       (Get-PromptArgumentValue $arguments '--import-gate') -cne "Global\Ticket569-$RunId-root-import"){
        throw 'session-host prompt request did not match the supervisor-pinned run evidence and helper-script identities'
    }
    $pythonCommand=Get-Command python.exe -ErrorAction Stop
    $scriptPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'hosted_cua_prompt.py'))
    $pythonPath=[IO.Path]::GetFullPath($pythonCommand.Source)
    $psi=[Diagnostics.ProcessStartInfo]::new($pythonPath);$psi.Environment.Clear();$privateEnvironment=New-PrivateEnv;foreach($key in $privateEnvironment.Keys){$psi.Environment[$key]=$privateEnvironment[$key]};$privateEnvironment.Clear();$psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true
    $psi.ArgumentList.Add($scriptPath);$psi.ArgumentList.Add('--bin-dir');$psi.ArgumentList.Add($BinaryDirectory)
    $psi.ArgumentList.Add('--runtime-root');$psi.ArgumentList.Add($runtime);$psi.ArgumentList.Add('--session-name');$psi.ArgumentList.Add($SessionName)
    foreach($argument in $arguments){$psi.ArgumentList.Add($argument)}
    $psi.ArgumentList.Add('--service')
    $script:promptProcess=[Diagnostics.Process]::Start($psi)
    $script:promptIdentity=@{pid=$script:promptProcess.Id;creationFileTimeUtc=$script:promptProcess.StartTime.ToUniversalTime().ToFileTimeUtc();executable=[IO.Path]::GetFullPath($script:promptProcess.MainModule.FileName);sid=$ownerSID;sessionId=$ownerSession;job='session-owner'}
    if($script:promptIdentity.executable -cne $pythonPath -or !(Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$script:promptIdentity.pid) -CreationFileTimeUtc ([long]$script:promptIdentity.creationFileTimeUtc)).matches -or
       !(Test-HostedCapabilityProcessInJob -ProcessId ([uint32]$script:promptIdentity.pid) -JobName $OwnerJobName)){
        try{$script:promptProcess.Kill($true);$script:promptProcess.WaitForExit((Get-OwnerWait 5000))}catch{}
        throw 'session-host MCP service process identity did not match its pinned Python launch'
    }
    try {
        $ready=Read-PromptServiceLine 30000
        if($ready.op -cne 'ready' -or !$ready.nativeMcp.serverInfo){throw 'session-host MCP service omitted its initialized readiness receipt'}
    } catch {
        if($script:promptProcess -and !$script:promptProcess.HasExited){
            try {if((Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$script:promptIdentity.pid) -CreationFileTimeUtc ([long]$script:promptIdentity.creationFileTimeUtc)).matches){$script:promptProcess.Kill($true);$null=$script:promptProcess.WaitForExit((Get-OwnerWait 5000))}}catch{}
        }
        if($script:promptProcess){$script:promptProcess.Dispose();$script:promptProcess=$null}
        $script:promptIdentity=$null
        throw
    }
    $promptEvidencePath=$expectedEvidence
    $script:promptArguments=@($arguments)
    @{process=$script:promptIdentity;nativeMcp=$ready.nativeMcp;session=$SessionName;runtimeRoot=$runtime;retained=$true}
}
function Start-RecoveryPromptService([object]$Request) {
    if($script:state -cne 'connected' -or $script:loginCount -ne 2 -or !$script:promptRecoveryAllowed -or $script:promptProcess -or !$script:promptArguments){
        throw 'Removal-only attachment requires the retained second planned login and proven prior prompt-service stop'
    }
    $targetSID=[string]$Request.expectedSID;$targetSession=[int]$Request.expectedSessionId
    $targetPath=[string]$Request.expectedProfilePath
    $ownedUser=Get-LocalUser -Name ('t569'+$RunId.Substring(0,10)) -ErrorAction Stop
    $profile=Get-CimInstance Win32_UserProfile -Filter "SID='$targetSID'" -ErrorAction Stop
    $sessionProcesses=@(Get-CimInstance Win32_Process -Filter "SessionId=$targetSession" -ErrorAction Stop | Where-Object {
        (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction Stop).Sid -ceq $targetSID
    })
    if($targetSession -le 0 -or $ownedUser.SID.Value -cne $targetSID -or !$sessionProcesses.Count -or !$profile.Loaded -or
       $profile.LocalPath -cne $targetPath -or !(Test-Path "Registry::HKEY_USERS\$targetSID") -or
       (Get-PromptArgumentValue $script:promptArguments '--expected-sid') -cne $targetSID){throw 'Removal-only attachment exact owned SID/session/profile is unavailable'}
    $volume=Get-Volume -FilePath (Join-Path $targetPath 'NTUSER.DAT') -ErrorAction Stop
    $reparse=[bool]((Get-Item -LiteralPath $targetPath -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint)
    if(!$Request.expectedVolumeId -or $volume.UniqueId -cne $Request.expectedVolumeId -or
       $Request.expectedProfileKind -cnotin @('normal','mount-point') -or $reparse -ne ($Request.expectedProfileKind -ceq 'mount-point')){
        throw 'Removal-only attachment actual profile kind/volume differs from the acknowledged context'
    }
    $envMap=New-PrivateEnv
    try{$null=Assert-BridgeHealth $envMap}finally{$envMap.Clear()}
    # Consume the planned-stop authorization before attaching; an unexpected
    # failure can never trigger another attachment, login or importer replay.
    $script:promptRecoveryAllowed=$false
    $arguments=@($script:promptArguments)
    $sessionOption=[Array]::IndexOf($arguments,'--expected-session-id')
    if($sessionOption -lt 0 -or $sessionOption+1 -ge $arguments.Count){throw 'Retained prompt template omitted its exact session option'}
    $arguments[$sessionOption+1]=[string]$targetSession
    $script:recoveryPromptStarting=$true
    try{$receipt=Start-PromptService @{promptArguments=$arguments}}finally{$script:recoveryPromptStarting=$false}
    $script:promptProcess.StandardInput.WriteLine('{"op":"watch-removal"}');$script:promptProcess.StandardInput.Flush()
    $started=Read-PromptServiceLine 5000
    if($started.op -cne 'watching-removal' -or $started.importerLaunched -ne $false){throw 'Removal-only MCP service omitted its no-import watcher receipt'}
    $script:promptCompleted=$true
    $receipt
}
function Invoke-PromptService([int] $TimeoutMilliseconds) {
    if(!$script:promptProcess -or $script:promptCompleted){throw 'session-host MCP service is absent or its bounded prompt request was already used'}
    if(!(Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$script:promptIdentity.pid) -CreationFileTimeUtc ([long]$script:promptIdentity.creationFileTimeUtc)).matches){throw 'session-host MCP service process identity changed before its request'}
    $script:promptProcess.StandardInput.WriteLine('{"op":"run"}');$script:promptProcess.StandardInput.Flush()
    $response=Read-PromptServiceLine $TimeoutMilliseconds
    if($response.op -cne 'result' -or !$response.result){throw 'session-host MCP service returned a malformed prompt result'}
    $script:promptCompleted=$true
    @{result=$response.result;exitCode=[int]$response.exitCode;process=$script:promptIdentity;retained=$true}
}
function Test-PromptServiceAlive {
    if(!$script:promptProcess -or $script:promptProcess.HasExited -or !$script:promptIdentity -or
       !(Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$script:promptIdentity.pid) -CreationFileTimeUtc ([long]$script:promptIdentity.creationFileTimeUtc)).matches){return $false}
    $script:promptProcess.StandardInput.WriteLine('{"op":"status"}');$script:promptProcess.StandardInput.Flush()
    $response=Read-PromptServiceLine 5000
    ($response.op -ceq 'status' -and $response.mcpAlive -eq $true)
}
function Stop-PromptService([int] $TimeoutMilliseconds=10000) {
    if(!$script:promptProcess){return @{stopped=$true;present=$false}}
    $identity=$script:promptIdentity
    if(!$script:promptProcess.HasExited -and !(Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$identity.pid) -CreationFileTimeUtc ([long]$identity.creationFileTimeUtc)).matches){throw 'session-host MCP process identity changed before bounded stop'}
    if(!$script:promptProcess.HasExited){
        $script:promptProcess.StandardInput.WriteLine('{"op":"stop"}');$script:promptProcess.StandardInput.Flush()
        $response=Read-PromptServiceLine ([Math]::Min($TimeoutMilliseconds,5000))
        if($response.op -cne 'stopped' -or $response.result -ne $true){throw 'session-host MCP service omitted its explicit stop receipt'}
        if(!$script:promptProcess.WaitForExit((Get-OwnerWait $TimeoutMilliseconds))){throw 'session-host MCP process did not exit within its bounded stop wait'}
    }
    $script:promptProcess.Refresh()
    if(!$script:promptProcess.HasExited -or !$identity){throw 'session-host MCP process exit identity was not proven through its retained process handle'}
    $exitCode=$script:promptProcess.ExitCode;$script:promptProcess.Dispose();$script:promptProcess=$null
    if($exitCode -ne 0){throw "session-host MCP service exited with code $exitCode"}
    @{stopped=$true;exitCode=$exitCode;process=$identity;waitedHandle=$true}
}
function Test-RuntimeSecret([string] $Secret) {
    if(!$Secret){return $false}
    $sha=[Security.Cryptography.SHA256]::Create()
    $bytes=[Text.Encoding]::UTF8.GetBytes($Secret)
    try{
        $digest=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()
        $check=Test-HostedSecretCanary -Directories @($runtime) -Sha256 $digest -Length $Secret.Length -RollingFingerprint ([Ticket569SecretCanary]::Fingerprint($Secret))
        [bool]$check.leaked
    }catch{return $true}finally{[Array]::Clear($bytes,0,$bytes.Length);$sha.Dispose();$Secret=$null}
}
function Test-Caller([uint32] $ClientPID,[string] $ClientSID,[int] $ClientSession,[int64] $Creation,[ValidateSet('supervisor','worker')][string] $Role) {
    if($ClientSID -cne $ownerSID -or $ClientSession -ne $ownerSession){return $false}
    if($Role -eq 'supervisor'){$expectedPID=$SupervisorPID;$expectedCreation=$SupervisorCreationFileTimeUtc}
    else {if(!$worker){return $false};$expectedPID=$worker.pid;$expectedCreation=$worker.creationFileTimeUtc}
    if($ClientPID -ne [uint32]$expectedPID -or $Creation -ne [int64]$expectedCreation){return $false}
    (Test-HostedCapabilityProcessIdentity -ProcessId $ClientPID -CreationFileTimeUtc $Creation).matches
}
function Send-Reply([object] $Value) {$writer.WriteLine((ConvertTo-Json -InputObject $Value -Depth 24 -Compress))}
function Test-RequestCaller([string] $Role,[uint32] $ClientPID,[string] $ClientSID,[int] $ClientSession,[int64] $Creation) {
    if ($Role -eq 'supervisor') { return Test-Caller $ClientPID $ClientSID $ClientSession $Creation 'supervisor' }
    return Test-Caller $ClientPID $ClientSID $ClientSession $Creation 'worker'
}
function Handle-Request([object] $Request,[uint32] $ClientPID,[string] $ClientSID,[int] $ClientSession,[int64] $ClientCreation) {
    if($Request.schema -cne 'ticket569-session-owner-v1' -or $Request.runId -cne $RunId -or $Request.sourceSHA -cne $sourceSHA){throw 'session owner run/source identity mismatch'}
    if($Request.command -in @('bootstrap','authorize-worker')){
        if(!(Test-Caller $ClientPID $ClientSID $ClientSession $ClientCreation 'supervisor')){throw 'supervisor caller identity mismatch'}
        if($Request.command -eq 'authorize-worker'){
            if($Request.worker.sid -cne $ownerSID -or [int]$Request.worker.sessionId -ne $ownerSession -or [int]$Request.worker.pid -le 0 -or [long]$Request.worker.creationFileTimeUtc -le 0){throw 'authorized worker context is malformed'}
            $identity=Test-HostedCapabilityProcessIdentity -ProcessId ([uint32]$Request.worker.pid) -CreationFileTimeUtc ([long]$Request.worker.creationFileTimeUtc)
            if(!$identity.matches){throw 'authorized worker PID/creation identity is stale'}
            $script:worker=$Request.worker;Send-Reply @{ok=$true;result=@{authorized=$true;worker=$worker;ownerPID=$PID}}
        } else {Send-Reply @{ok=$true;result=@{ready=$true;runtimeRoot=$runtime;session=$SessionName;ownerPID=$PID;ownerSID=$ownerSID;ownerSession=$ownerSession}}}
        return $false
    }
    if(!(Test-Caller $ClientPID $ClientSID $ClientSession $ClientCreation 'worker') -and !(Test-Caller $ClientPID $ClientSID $ClientSession $ClientCreation 'supervisor')){throw 'session owner rejected unrecorded caller PID/creation/SID/session'}
    $isSupervisor=(Test-Caller $ClientPID $ClientSID $ClientSession $ClientCreation 'supervisor')
    $isWorker=(Test-Caller $ClientPID $ClientSID $ClientSession $ClientCreation 'worker')
    switch([string]$Request.command){
        'login' {
            if($isSupervisor){throw 'supervisor is not permitted to transfer a login password'}
            if($script:state -cne 'disconnected'){throw 'automatic reconnect after unexpected or unplanned session state is prohibited'}
            $password=[string]$Request.password;$Request.password=''
            if(!$password -or $password.Length -gt 512){throw 'one-shot password transfer is malformed'}
            $user=[string]$Request.username;$domain=[string]$Request.domain
            if(!$user -or $user.Length -gt 128){$password=$null;throw 'login user name is malformed'}
            $envMap=New-PrivateEnv;$passwordPipe=$null;$passwordScript=$null;$passwordCommand=$null
            try {
                $script:loginCount++;$script:state='connecting'
                $config=Join-Path $runtime "host-$script:loginCount.conf"
                $passwordPipeName=New-LoginPasswordPipeName $script:loginCount
                $passwordPipe=[IO.Pipes.NamedPipeServerStream]::new($passwordPipeName,[IO.Pipes.PipeDirection]::Out,1,[IO.Pipes.PipeTransmissionMode]::Byte,([IO.Pipes.PipeOptions]::CurrentUserOnly -bor [IO.Pipes.PipeOptions]::Asynchronous),512,512)
                $quote={param([string]$value) '"'+$value.Replace('\','\\').Replace('"','\"')+'"'}
                $passwordScript=@'
$p=[IO.Pipes.NamedPipeClientStream]::new('.','{PIPE_NAME}',[IO.Pipes.PipeDirection]::In);$p.Connect(15000);$m=[IO.MemoryStream]::new();$b=New-Object byte[] 513;while(($n=$p.Read($b,0,$b.Length))-gt 0){if($m.Length+$n -gt 512){throw 'password transfer exceeds its byte bound'};$m.Write($b,0,$n)};$s=[Text.Encoding]::UTF8.GetString($m.ToArray());if(!$s){throw 'password transfer was empty'};[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);[Console]::Write($s);$s=$null;[Array]::Clear($b,0,$b.Length);[Array]::Clear($m.GetBuffer(),0,$m.GetBuffer().Length);$m.Dispose();$p.Dispose()
'@
                $passwordScript=$passwordScript.Trim().Replace('{PIPE_NAME}',$passwordPipeName)
                $passwordCommand="powershell.exe -NoProfile -NonInteractive -EncodedCommand "+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($passwordScript))
                $cuaContract=Get-HostedCapabilityCuaBundleContract
                [IO.File]::WriteAllText($config,("Host $SessionName`n  HostName "+(& $quote '127.0.0.1')+"`n  User "+(& $quote $user)+"`n  Domain "+(& $quote $domain)+"`n  Port 3389`n  PasswordCommand "+(& $quote $passwordCommand)+"`n  AcceptInvalidCerts yes`n  CuaVersion "+$cuaContract.ReleaseTag+"`n  CuaAutoDownload no`n"),[Text.UTF8Encoding]::new($false))
                $connected=Invoke-Rdpilot @('connect',$SessionName,'-F',$config,'--name',$SessionName,'--json') $envMap 180 $passwordPipe $password $passwordCommand
                $secretLeaked=Test-RuntimeSecret $password
                if($connected.bridge_live -and !$secretLeaked){
                    try {
                        # The CLI's ping command round-trips the existing guest
                        # bridge. A live flag from connect alone is not a durable
                        # session-health receipt.
                        $null=Assert-BridgeHealth $envMap
                        $script:state='connected'
                    } catch {$script:state='lost';throw 'rdpilot bridge health check failed immediately after connection'}
                }else{$script:state='lost'}
                Send-Reply @{ok=$true;result=@{connected=($script:state -eq 'connected');state=$script:state;session=$SessionName;loginOrdinal=$script:loginCount;passwordCanaryAbsent=(!$secretLeaked);runtimeRoot=$runtime;ownerPID=$PID}}
            } finally {if($passwordPipe){$passwordPipe.Dispose()};$password=$null;$passwordScript=$null;$passwordCommand=$null;$Request.password='';$envMap.Clear()}
            return $false
        }
        'disconnect' {
            if($script:state -cne 'connected'){throw 'planned disconnect refused because no healthy owned session is connected'}
            $envMap=New-PrivateEnv
            try {
                $null=Assert-BridgeHealth $envMap
                # Pinned Disconnect closes MCP/CUA streams: stop and retain its
                # exit receipt first, preserving completed import/removal evidence.
                $promptStop=Stop-PromptService 10000
                $script:promptRecoveryAllowed=[bool]($promptStop.stopped -and $promptStop.waitedHandle -and $script:promptArguments)
                $null=Invoke-Rdpilot @('disconnect','--session',$SessionName,'--json') $envMap 20
                $script:state='disconnected';Send-Reply @{ok=$true;result=@{disconnected=$true;planned=$true;session=$SessionName;promptService=$promptStop}}
            }
            catch {$script:state='lost';throw} finally {$envMap.Clear()}
            return $false
        }
        'health' {
            if($script:state -cne 'connected'){throw 'owned RDP health cannot be proven because the session is not connected'}
            if($Request.requirePromptService -and !$script:promptProcess -and $Request.allowRecoveryWatcher -and $isSupervisor){
                try{$script:promptServiceReceipt=Start-RecoveryPromptService $Request}catch{$script:state='lost';throw}
            }
            if($Request.requirePromptService -and !(Test-PromptServiceAlive)){
                $script:state='lost';throw 'retained session-host MCP service is absent or its exact process identity changed'
            }
            $envMap=New-PrivateEnv
            try {$null=Assert-BridgeHealth $envMap}
            catch {$script:state='lost';throw 'owned RDP bridge health check failed; automatic reconnect is prohibited'}
            finally {$envMap.Clear()}
            Send-Reply @{ok=$true;result=@{healthy=$true;state=$script:state;connected=$true;session=$SessionName;loginCount=$script:loginCount;ownerPID=$PID;promptServiceAlive=[bool]($script:promptProcess -and !$script:promptProcess.HasExited);promptServiceIdentity=$script:promptIdentity}}
            return $false
        }
        'prompt-prepare' {
            if(!$isWorker -or $script:state -cne 'connected' -or $script:importerIdentity){throw 'Importer preparation requires the exact connected worker and permits one launch'}
            $script:promptServiceReceipt=Start-PromptService $Request
            $script:promptProcess.StandardInput.WriteLine('{"op":"launch"}');$script:promptProcess.StandardInput.Flush()
            $launch=Read-PromptServiceLine 30000
            if($launch.op -cne 'importer-launched' -or [int]$launch.receipt.pid -le 0 -or $launch.receipt.running -ne $true){throw 'Pinned native launch_app omitted an importer PID receipt'}
            $importerPID=[uint32]$launch.receipt.pid
            $info=Get-CimInstance Win32_Process -Filter "ProcessId=$importerPID" -ErrorAction Stop
            $child=Get-Process -Id $importerPID -ErrorAction Stop;$null=$child.Handle
            $expectedSID=Get-PromptArgumentValue $Request.promptArguments '--expected-sid';$expectedSession=[int](Get-PromptArgumentValue $Request.promptArguments '--expected-session-id')
            $expectedScript=Join-Path $PSScriptRoot 'hosted-root-import.ps1';$expectedImage=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $fileArgumentsProven=Test-HostedCapabilityCommandArguments $info.CommandLine @{'-File'=$expectedScript;'-Mode'='Import';'-RunId'=$RunId;'-SourceSHA'=$sourceSHA;'-LaunchGateName'="Global\Ticket569-$RunId-root-import"}
            $childSID=(Invoke-CimMethod -InputObject $info -MethodName GetOwnerSid -ErrorAction Stop).Sid
            if($childSID -cne $expectedSID -or $child.SessionId -ne $expectedSession -or [IO.Path]::GetFullPath($child.Path) -cne [IO.Path]::GetFullPath($expectedImage) -or
               !$fileArgumentsProven -or !$info.CommandLine.Contains("Global\Ticket569-$RunId-root-import",[StringComparison]::Ordinal)) {throw 'Native launch receipt did not resolve to the exact gated importer process'}
            $parentInfo=Get-CimInstance Win32_Process -Filter "ProcessId=$($info.ParentProcessId)" -ErrorAction Stop
            $parent=Get-Process -Id ([int]$info.ParentProcessId) -ErrorAction Stop;$null=$parent.Handle
            $parentSID=(Invoke-CimMethod -InputObject $parentInfo -MethodName GetOwnerSid -ErrorAction Stop).Sid
            $parentName=[IO.Path]::GetFileName($parent.Path);$parentHash=(Get-FileHash -LiteralPath $parent.Path).Hash.ToLowerInvariant()
            if($parentSID -cne $expectedSID -or $parent.SessionId -ne $expectedSession -or $parentName -cnotin @('cua-driver.exe','cua-driver-uia.exe')){throw 'Importer ancestry did not resolve to the live exact pinned CUA driver image'}
            $script:importerParent=@{pid=$parent.Id;creationFileTimeUtc=$parent.StartTime.ToUniversalTime().ToFileTimeUtc();sid=$parentSID;sessionId=$parent.SessionId;executable=$parent.Path;imageSHA256=$parentHash}
            $script:importerParentHandle=Open-HostedCapabilityProcessIdentity -ProcessId ([uint32]$parent.Id) -CreationFileTimeUtc $script:importerParent.creationFileTimeUtc
            $script:importerProcess=$child;$parent.Dispose()
            $script:importerIdentity=@{pid=$child.Id;creationFileTimeUtc=$child.StartTime.ToUniversalTime().ToFileTimeUtc();sid=$childSID;sessionId=$child.SessionId;executable=$child.Path;scriptPath=$expectedScript;scriptSHA256=(Get-FileHash $expectedScript).Hash.ToLowerInvariant();parent=$script:importerParent;launchReceipt=$launch.receipt}
            Send-Reply @{ok=$true;result=@{importer=$script:importerIdentity;sessionHost=$script:promptServiceReceipt}}
            return $false
        }
        'importer-identity' {
            if(!$isSupervisor -or !$script:importerProcess -or $script:importerProcess.HasExited -or !$script:importerParentHandle -or $script:importerParentHandle.Wait(0)){throw 'Supervisor importer read lacks retained live importer/parent handles'}
            Send-Reply @{ok=$true;result=@{importer=$script:importerIdentity;retained=$true}}
            return $false
        }
        'prompt-run' {
            if(!$isWorker){throw 'only the identity-authorized worker may request the bounded root-prompt operation'}
            if($script:state -cne 'connected'){throw 'root-prompt UIA request refused because the original RDP session is not connected'}
            $envMap=New-PrivateEnv
            try {
                $null=Assert-BridgeHealth $envMap
                if(!$script:promptProcess -or !$script:importerIdentity){throw 'Prompt run requires the already launched identity-gated importer'}
                $service=$script:promptServiceReceipt
                $timeout=if($Request.timeoutMilliseconds){[int]$Request.timeoutMilliseconds}else{480000}
                if($timeout -lt 1000 -or $timeout -gt 480000){throw 'root-prompt UIA request exceeded the absolute eight-minute bound'}
                $serviceResult=Invoke-PromptService $timeout
                $null=Assert-BridgeHealth $envMap
                if(!(Test-PromptServiceAlive)){$script:state='lost';throw 'retained native MCP attachment failed its post-prompt process check; reconnect is prohibited'}
                Send-Reply @{ok=$true;result=$serviceResult;sessionHost=$service}
            } catch {
                if($script:promptProcess -and $script:promptProcess.HasExited){$script:state='lost'}
                throw
            } finally {$envMap.Clear()}
            return $false
        }
        'status' {
            if($script:state -eq 'connected'){
                $envMap=New-PrivateEnv
                try {$null=Assert-BridgeHealth $envMap}
                catch {$script:state='lost';throw 'owned RDP bridge health check failed; automatic reconnect is prohibited'}
                finally {$envMap.Clear()}
            }
            Send-Reply @{ok=$true;result=@{state=$script:state;connected=($script:state -eq 'connected');session=$SessionName;loginCount=$script:loginCount;ownerPID=$PID}}
            return $false
        }
        'shutdown' {
            $promptStop=Stop-PromptService 10000
            if($script:importerProcess){if(!$script:importerProcess.WaitForExit((Get-OwnerWait 5000))){throw 'Retained importer did not exit before owner shutdown'};$script:importerProcess.Dispose();$script:importerProcess=$null}
            if($isSupervisor -and $script:state -eq 'connected'){
                $envMap=New-PrivateEnv
                try {
                    $null=Assert-BridgeHealth $envMap
                    $null=Invoke-Rdpilot @('disconnect','--session',$SessionName,'--json') $envMap 20
                    $script:state='disconnected'
                } catch {$script:state='lost';throw 'owned RDP session became unhealthy before planned owner shutdown'}
                finally {$envMap.Clear()}
            }
            if($script:state -ne 'disconnected'){throw 'session owner shutdown cannot prove a planned disconnect'}
            $daemonStopped=$false
            if($script:daemonProcess -and !$script:daemonProcess.HasExited){$script:daemonProcess.Kill($true);$daemonStopped=$script:daemonProcess.WaitForExit((Get-OwnerWait 5000))}elseif($script:daemonProcess){$daemonStopped=$true}
            if(!$daemonStopped){throw 'rdpilot daemon did not exit during bounded owner shutdown'}
            $script:daemonProcess.Dispose();$script:daemonProcess=$null
            Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction Stop
            Send-Reply @{ok=$true;result=@{disconnected=$true;planned=$true;session=$SessionName;daemonStopped=$true;privateRuntimeRemoved=(!(Test-Path -LiteralPath $runtime));loginCount=$script:loginCount;promptService=$promptStop}}
            return $true
        }
        default {throw 'session owner command is not permitted'}
    }
}

try {
    if(!(Test-Path -LiteralPath $cli -PathType Leaf) -or !(Test-Path -LiteralPath $daemon -PathType Leaf)){throw 'pinned rdpilot CLI/daemon are absent'}
    $daemonEnv=New-PrivateEnv
    $daemonInfo=[Diagnostics.ProcessStartInfo]::new($daemon);$daemonInfo.UseShellExecute=$false
    $daemonInfo.Environment.Clear();foreach($key in $daemonEnv.Keys){$daemonInfo.Environment[$key]=$daemonEnv[$key]}
    $script:daemonProcess=[Diagnostics.Process]::Start($daemonInfo);$null=$daemonEnv.Clear()
    Start-Sleep -Milliseconds 500
    if($script:daemonProcess.HasExited){throw 'pinned rdpilot daemon exited during startup'}
    if([Diagnostics.Stopwatch]::Frequency -ne $CounterFrequency -or [Diagnostics.Stopwatch]::GetTimestamp() -lt $JobStartCounter){throw 'Session owner rejected an invalid or reversed job QPC clock'}
    $deadline=$JobStartCounter+24L*60L*$CounterFrequency
    $shutdown=$false
    while(!$shutdown){
        $server=[IO.Pipes.NamedPipeServerStream]::new($PipeName,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,([IO.Pipes.PipeOptions]::CurrentUserOnly -bor [IO.Pipes.PipeOptions]::Asynchronous),65536,65536)
        $connect=$server.WaitForConnectionAsync()
        while(!$connect.Wait(100)){
            if($script:daemonProcess.HasExited){throw 'rdpilot daemon unexpectedly exited while the session owner was active'}
            if($script:promptProcess -and $script:promptProcess.HasExited){$script:state='lost';throw 'retained session-host MCP process exited unexpectedly; reconnect is prohibited'}
            if([Diagnostics.Stopwatch]::GetTimestamp() -ge $deadline){throw 'session owner reached the absolute J+24 cleanup cutoff'}
        }
        $clientPID=Get-HostedCapabilityPipeClientProcessId -PipeHandle $server.SafePipeHandle.DangerousGetHandle()
        $clientSID=Get-HostedCapabilityPipeClientSid -Pipe $server
        $clientProcess=Get-Process -Id $clientPID -ErrorAction Stop
        $clientSession=[int]$clientProcess.SessionId
        $clientCreation=$clientProcess.StartTime.ToUniversalTime().ToFileTimeUtc()
        $reader=[IO.StreamReader]::new($server,[Text.UTF8Encoding]::new($false),$false,4096,$true)
        $writer=[IO.StreamWriter]::new($server,[Text.UTF8Encoding]::new($false),4096,$true);$writer.AutoFlush=$true
        try {
            $lineTask=$reader.ReadLineAsync()
            if(!$lineTask.Wait((Get-OwnerWait 5000))){throw 'Session owner request read exceeded its five-second bound'}
            $line=$lineTask.Result
            if(!$line -or $line.Length -gt 1048576){throw 'session owner request frame is missing or oversized'}
            $request=ConvertFrom-Json -InputObject $line -ErrorAction Stop
            $shutdown=[bool](Handle-Request $request $clientPID $clientSID $clientSession $clientCreation)
        } catch {
            Send-Reply @{ok=$false;errorType=$_.Exception.GetType().FullName;error=$_.Exception.Message.Substring(0,[Math]::Min(300,$_.Exception.Message.Length))}
        } finally {
if($request -and $request.PSObject.Properties['password']){$request.password=''};$line=$null;$request=$null;$reader.Dispose();$writer.Dispose();$server.Dispose()}
    }
    if($script:daemonProcess -and !$script:daemonProcess.HasExited){$script:daemonProcess.Kill($true);if(!$script:daemonProcess.WaitForExit((Get-OwnerWait 5000))){throw 'rdpilot daemon did not exit after shutdown'}}
    if($script:daemonProcess){$script:daemonProcess.Dispose()}
    if(Test-Path -LiteralPath $runtime){Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction Stop}
    exit 0
} catch {
    try {if($script:daemonProcess -and !$script:daemonProcess.HasExited){$script:daemonProcess.Kill($true);$script:daemonProcess.WaitForExit((Get-OwnerWait 5000))|Out-Null}} catch{}
    try {if($runtime -and (Test-Path -LiteralPath $runtime)){Remove-Item -LiteralPath $runtime -Recurse -Force -ErrorAction SilentlyContinue}} catch{}
    [Console]::Error.WriteLine(('TICKET569_SESSION_OWNER_FAILED '+$_.Exception.GetType().FullName))
    exit 2
} finally {
    if($script:importerProcess){$script:importerProcess.Dispose()}
    if($script:importerParentHandle){$script:importerParentHandle.Dispose()}
}
