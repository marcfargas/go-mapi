$ErrorActionPreference='Stop'
if(!$IsWindows){Write-Output 'HOSTED_CAPABILITY_PROFILE_TESTS_SKIPPED_NON_WINDOWS: production profile rename/mount crash and guarded restore need Windows disk/profile APIs';exit 0}
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-owner.psm1') -Force
$pwsh=Join-Path $PSHOME 'pwsh.exe';$sha='b'*40
$temp=Join-Path $env:TEMP ('t569-profile-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
$wrapper=Join-Path $temp 'profile-wrapper.ps1'
@'
param([string]$Scripts,[string]$Action,[string]$SID,[string]$ProfilePath,[string]$VhdPath,[string]$BackupPath,[string]$EvidenceDirectory,[string]$RunId,[string]$SourceSHA,[string]$Fault='none',[ValidateSet('Hosted','Lease','MissingHostedHook')][string]$Mode='Hosted')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $Scripts 'hosted-capability-owner.psm1') -Force
Import-Module (Join-Path $Scripts 'hosted-capability-clock.psm1') -Force
$sample=Get-HostedCapabilityClockSample
$ledger=New-HostedCapabilityLedger -Directory (Join-Path $EvidenceDirectory 'ledger') -RunId $RunId -SourceSHA $SourceSHA -BootMarker $sample.bootMarker -JobStartCounter $sample.counter -CounterFrequency $sample.frequency
# The fixture is this ledger's sole writer. It exercises production profile.ps1;
# it is not the production supervisor's pipe authentication fixture.
if($Mode -cne 'Hosted'){
 $selected=if($Mode -ceq 'Lease'){'Lease'}else{'Hosted'}
 & (Join-Path $Scripts 'profile.ps1') -Action $Action -SID $SID -ProfilePath $ProfilePath -VhdPath $VhdPath -BackupPath $BackupPath -EvidenceDirectory $EvidenceDirectory -MutationMode $selected
 exit 0
}
& (Join-Path $Scripts 'profile.ps1') -Action $Action -SID $SID -ProfilePath $ProfilePath -VhdPath $VhdPath -BackupPath $BackupPath -EvidenceDirectory $EvidenceDirectory -MutationMode Hosted -DeadlineCounter ($sample.counter+120L*$sample.frequency) -CounterFrequency $sample.frequency -MutationHook {
    param($operation,$resource,$precondition,$actionBody)
    $request=[guid]::NewGuid().ToString('N')
    $null=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='intent';requestId=$request;operation=$operation;resourceIdentity=$resource;precondition=$precondition}
    $observed=& $actionBody
    # A true process exit between mutation and observation leaves a pending intent.
    if($operation -ceq $Fault){[Environment]::Exit(77)}
    $null=Write-HostedCapabilityLedgerEvent -Ledger $ledger -Event @{phase='observation';requestId=$request;operation=$operation;resourceIdentity=$resource;result='completed';observed=$observed}
    [pscustomobject]@{result=$observed}
}
'@ | Set-Content -LiteralPath $wrapper -Encoding utf8
function Invoke-ProfileFixture([string]$Action,[string]$Fault,[string]$Evidence,[string]$Mode='Hosted'){
    $stdout=Join-Path $temp "$Action-$Fault.stdout.log";$stderr=Join-Path $temp "$Action-$Fault.stderr.log"
    $child=Start-Process -FilePath $pwsh -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ArgumentList @('-NoProfile','-NonInteractive','-File',"`"$wrapper`"",'-Scripts',"`"$PSScriptRoot`"",'-Action',$Action,'-SID',$local.SID.Value,'-ProfilePath',"`"$profilePath`"",'-BackupPath',"`"$backupPath`"",'-VhdPath',"`"$vhdPath`"",'-EvidenceDirectory',"`"$Evidence`"",'-RunId',$run,'-SourceSHA',$sha,'-Fault',$Fault,'-Mode',$Mode)
    try{$null=$child.Handle;if(!$child.WaitForExit(120000)){$child.Kill();$null=$child.WaitForExit(5000);throw 'Production profile fixture exceeded bounded retained process wait'};Get-Content $stdout|Write-Host;Get-Content $stderr|Write-Host;return $child.ExitCode}finally{$child.Dispose()}
}
try{
foreach($fault in @('rename-normal-profile-to-owned-backup','mount-vhd-at-original-profile-path')){
    if((Test-Path 'T:\') -or (Test-Path 'C:\crabbox\work\ticket569')){throw 'Profile crash fixture requires exact temporary-drive/runtime preabsence'}
    $run=[guid]::NewGuid().ToString('N');$userName='t569p'+$run.Substring(0,8);$local=$null;$initializer=$null;$credential=$null;$secure=$null
    $profilePath="C:\Users\$userName";$backupPath="$profilePath.normal-backup";$vhdPath="C:\crabbox\work\ticket569\profile-$run.vhdx"
    try{
        $secure=ConvertTo-SecureString ([guid]::NewGuid().ToString('N')+'aA1!') -AsPlainText -Force
        $local=New-LocalUser -Name $userName -Password $secure -ErrorAction Stop
        $credential=[Management.Automation.PSCredential]::new("$env:COMPUTERNAME\$userName",$secure)
        $initializer=Start-Process -FilePath $pwsh -Credential $credential -LoadUserProfile -PassThru -ArgumentList @('-NoProfile','-NonInteractive','-Command','exit 0')
        $null=$initializer.Handle;if(!$initializer.WaitForExit(20000) -or $initializer.ExitCode -ne 0){throw 'Disposable real profile initialization did not exit successfully'}
        $until=[DateTime]::UtcNow.AddSeconds(20)
        do{$profile=Get-CimInstance Win32_UserProfile -Filter "SID='$($local.SID.Value)'";if($profile -and !$profile.Loaded -and !(Test-Path "Registry::HKEY_USERS\$($local.SID.Value)")){break};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $until)
        if(!$profile -or $profile.Loaded -or $profile.LocalPath -cne $profilePath){throw 'Fixture did not produce the exact unloaded real profile'}
        $sentinel=Join-Path $profilePath ".ticket569-$run-sentinel";[IO.File]::WriteAllText($sentinel,$run)
        $hiveHash=(Get-FileHash (Join-Path $profilePath 'NTUSER.DAT')).Hash
        $prepare=Join-Path $temp "$fault-prepare";$restore=Join-Path $temp "$fault-restore"
        if((Invoke-ProfileFixture 'prepare-vhd' $fault $prepare) -ne 77){throw 'Production profile did not reach the selected crash between mutation and observation'}
        $replay=Read-HostedCapabilityLedger -Directory (Join-Path $prepare 'ledger') -RunId $run -SourceSHA $sha
        if(!$replay.valid -or $replay.pending.Count -ne 1 -or $replay.pending[0].operation -cne $fault -or !(Test-Path $backupPath)){throw 'Durable replay lost the crash-point owned pending intent/normal backup'}
        if((Invoke-ProfileFixture 'restore-normal' 'none' $restore) -ne 0){throw 'Production guarded restore failed after the actual profile conversion crash'}
        if((Invoke-ProfileFixture 'restore-normal' 'none' (Join-Path $temp "$fault-lease") 'Lease') -ne 0){throw 'Existing lease caller without a hook no longer works'}
        if((Invoke-ProfileFixture 'restore-normal' 'none' (Join-Path $temp "$fault-hosted-missing") 'MissingHostedHook') -eq 0){throw 'Hosted caller without its mandatory hook was accepted'}
        $restored=Read-HostedCapabilityLedger -Directory (Join-Path $restore 'ledger') -RunId $run -SourceSHA $sha
        if(!$restored.valid -or $restored.pending.Count -ne 0 -or (Test-Path $vhdPath) -or (Test-Path $backupPath) -or (Test-Path 'T:\') -or [IO.File]::ReadAllText($sentinel) -cne $run -or (Get-FileHash (Join-Path $profilePath 'NTUSER.DAT')).Hash -cne $hiveHash){throw 'Guarded restore failed exact original bytes, no-pending replay or VHD/mount absence'}
        Write-Output (ConvertTo-Json -Compress -Depth 10 @{event='actual-production-profile-crash-restored';fault=$fault;syntheticFixtureSHA=$sha;profileSourceSHA256=(Get-FileHash (Join-Path $PSScriptRoot 'profile.ps1')).Hash;pendingIntent=$replay.pending[0];restoreOperations=@($restored.events|ForEach-Object operation)})
    }finally{
        if($initializer){if(!$initializer.HasExited){$initializer.Kill();$null=$initializer.WaitForExit(5000)};$initializer.Dispose()}
        # Emergency restore does not count as test proof and uses production guards.
        if($local -and ((Test-Path $backupPath) -or (Test-Path $vhdPath))){$null=Invoke-ProfileFixture 'restore-normal' 'none' (Join-Path $temp "$fault-emergency")}
        if($local){$profile=Get-CimInstance Win32_UserProfile -Filter "SID='$($local.SID.Value)'";if($profile){if($profile.Loaded){throw 'Profile fixture cleanup refuses a loaded profile'};Remove-CimInstance $profile -ErrorAction Stop};Remove-LocalUser -SID $local.SID -ErrorAction Stop}
        if((Test-Path 'C:\crabbox\work\ticket569') -and @(Get-ChildItem 'C:\crabbox\work\ticket569' -Force).Count -eq 0){Remove-Item 'C:\crabbox\work\ticket569' -Force}
        if($secure){$secure.Dispose()};$credential=$null
    }
}
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
Write-Output 'HOSTED_CAPABILITY_PROFILE_TESTS_PASSED: actual profile conversion crashes, pending replay and guarded restoration'
