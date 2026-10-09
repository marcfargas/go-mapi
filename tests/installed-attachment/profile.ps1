[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('prepare-vhd', 'restore-normal')] [string] $Action,
    [Parameter(Mandatory)] [string] $SID,
    [Parameter(Mandatory)] [string] $ProfilePath,
    [Parameter(Mandatory)] [string] $VhdPath,
    [Parameter(Mandatory)] [string] $BackupPath,
    [Parameter(Mandatory)] [string] $EvidenceDirectory,
    [scriptblock] $MutationHook,
    [ValidateSet('Lease','Hosted')][string] $MutationMode = 'Lease',
    [long] $DeadlineCounter,
    [long] $CounterFrequency
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if($MutationMode -ceq 'Hosted' -and !$MutationHook){throw 'Hosted profile mutations require the sole-writer supervisor hook'}
if($MutationMode -ceq 'Hosted' -and ($DeadlineCounter -le 0 -or $CounterFrequency -ne [Diagnostics.Stopwatch]::Frequency)){throw 'Hosted profile mutations require the actual absolute deadline and QPC frequency'}
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-clock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-native.psm1') -Force
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null

function Write-Atomic([string] $Path, $Value) {
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 12) + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Assert-Unloaded([string] $ExpectedSID, [string] $ExpectedPath) {
    $profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $ExpectedSID
    if (!$profile -or $profile.LocalPath -ne $ExpectedPath) { throw 'Windows profile SID/path identity differs from the requested profile' }
    if ($profile.Loaded) { throw 'Profile remains loaded; refusing to copy, mount or restore it' }
    if (Test-Path "Registry::HKEY_USERS\$ExpectedSID") { throw 'The profile SID hive remains loaded; refusing to copy, mount or restore it' }
    return $profile
}

function Invoke-ProfileMutation([string] $Operation,[object] $ResourceIdentity,[object] $Precondition,[scriptblock] $Action) {
    if($MutationHook){& $MutationHook $Operation $ResourceIdentity $Precondition $Action}
    elseif($MutationMode -ceq 'Lease'){[pscustomobject]@{result=(& $Action)}}
    else{throw 'Missing acknowledged hosted profile mutation hook'}
}

function Invoke-ProfileNative([string]$Name,[string[]]$Arguments) {
    if($MutationMode -ceq 'Lease'){
        $output=& $Name @Arguments 2>&1 | Out-String
        $script:profileNativeExit=$LASTEXITCODE
        return $output
    }
    $budget=Get-HostedCapabilityWaitBudget $DeadlineCounter $CounterFrequency 120000
    if($budget -le 0){throw 'Hosted profile native operation reached its absolute deadline'}
    $executable=[IO.Path]::GetFullPath((Join-Path $env:WINDIR ('System32\'+$Name)))
    $token=[guid]::NewGuid().ToString('N')
    $stdout=Join-Path $EvidenceDirectory ("native-$token.stdout.log")
    $stderr=Join-Path $EvidenceDirectory ("native-$token.stderr.log")
    # These utilities are leaf Windows processes. Retain the actual handle and
    # creation identity; a timeout remains a failed acknowledged mutation.
    $quoted=@($Arguments|ForEach-Object {'"'+([regex]::Replace([regex]::Replace($_,'(\\*)"','$1$1\"'),'(\\+)$','$1$1'))+'"'})
    $process=Start-Process -FilePath $executable -ArgumentList $quoted -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $created=$process.StartTime.ToUniversalTime().ToFileTimeUtc()
    try{
        $null=$process.Handle
        if([IO.Path]::GetFullPath($process.MainModule.FileName) -cne $executable){throw 'Hosted profile native executable identity differs'}
        if(!$process.WaitForExit((Get-HostedCapabilityWaitBudget $DeadlineCounter $CounterFrequency $budget))){throw 'Hosted profile native operation exceeded its absolute bounded wait'}
        $script:profileNativeExit=$process.ExitCode
        ([IO.File]::ReadAllText($stdout)+[IO.File]::ReadAllText($stderr))
    }finally{
        if(!$process.HasExited){
            $stop=Stop-HostedCapabilityProcessIdentity -ProcessId ([uint32]$process.Id) -CreationFileTimeUtc $created -WaitMilliseconds (Get-HostedCapabilityWaitBudget $DeadlineCounter $CounterFrequency 5000)
            if(!$stop.terminated){throw 'Hosted profile native process exit remains unproved'}
        }
        Write-Atomic (Join-Path $EvidenceDirectory ("native-$token-process.json")) @{pid=$process.Id;creationFileTimeUtc=$created;executable=$executable;exitProven=$process.HasExited;exitCode=if($process.HasExited){$process.ExitCode}else{$null};deadlineCounter=$DeadlineCounter}
        $process.Dispose()
    }
}

function Invoke-Diskpart([string] $Name,[string] $Commands,[object] $ResourceIdentity,[object] $Precondition) {
    $diskpartPath=Join-Path $EvidenceDirectory "$Name.diskpart"
    [IO.File]::WriteAllText($diskpartPath,$Commands,[Text.Encoding]::ASCII)
    Invoke-ProfileMutation "profile-diskpart-$Name" $ResourceIdentity $Precondition {
        $output=Invoke-ProfileNative 'diskpart.exe' @('/s',$diskpartPath)
        $exit=$script:profileNativeExit
        Write-Atomic (Join-Path $EvidenceDirectory "$Name.json") @{exitCode=$exit;output=$output}
        if($exit -ne 0){throw "DiskPart $Name operation exited $exit"}
        @{exitCode=$exit;output=$output}
    }
}

if ($ProfilePath -notmatch '^C:\\Users\\[^\\]+$' -or $VhdPath -notlike 'C:\crabbox\work\ticket569\*.vhdx' -or $BackupPath -ne "$ProfilePath.normal-backup") {
    throw 'Profile/VHD/backup paths must use the reviewed isolated ticket569 layout'
}
$profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $SID
if (!$profile -or $profile.LocalPath -ne $ProfilePath) { throw 'Requested SID is not mapped to the specified real profile path' }

if ($Action -eq 'prepare-vhd') {
    $null = Assert-Unloaded $SID $ProfilePath
    if (Test-Path -LiteralPath $VhdPath) { throw 'The owned VHD path already exists; refusing to overwrite it' }
    if (Test-Path -LiteralPath $BackupPath) { throw 'The normal-profile backup already exists; refusing to overwrite it' }
    $profileBytes = (Get-ChildItem -LiteralPath $ProfilePath -Recurse -File -Force -ErrorAction Stop | Measure-Object -Property Length -Sum).Sum
    if ($profileBytes -gt 7GB) { throw 'Profile exceeds the bounded 8 GiB test VHD capacity' }
    $vhdParent = Split-Path -Parent $VhdPath
    Invoke-ProfileMutation 'create-owned-profile-vhd-parent-directory' @{path=$vhdParent;vhdPath=$VhdPath} @{pathIsExactTicket569RuntimeRoot=($vhdParent -ceq 'C:\crabbox\work\ticket569')} {
        if(!(Test-Path -LiteralPath $vhdParent -PathType Container)){New-Item -ItemType Directory -Path $vhdParent -Force | Out-Null}
        @{path=$vhdParent;present=(Test-Path -LiteralPath $vhdParent -PathType Container)}
    }
    $drive = 'T'
    if (Test-Path "$drive`:\") { throw 'Temporary T: drive is occupied' }
    Invoke-Diskpart 'create-profile-vhd' "create vdisk file=`"$VhdPath`" maximum=8192 type=expandable`r`n" @{vhdPath=$VhdPath} @{vhdAbsent=$true}
    if(!(Test-Path -LiteralPath $VhdPath -PathType Leaf)){throw 'DiskPart did not create the owned profile VHD file'}
    Invoke-Diskpart 'attach-profile-vhd' "select vdisk file=`"$VhdPath`"`r`nattach vdisk`r`n" @{vhdPath=$VhdPath} @{vhdExists=$true;attached=$false}
    if(!(Get-DiskImage -ImagePath $VhdPath -ErrorAction Stop).Attached){throw 'DiskPart did not attach the owned profile VHD'}
    Invoke-Diskpart 'format-profile-vhd' "select vdisk file=`"$VhdPath`"`r`ncreate partition primary`r`nformat fs=ntfs label=`"Ticket569Profile`" quick`r`nassign letter=$drive`r`n" @{vhdPath=$VhdPath;drive=$drive} @{vhdAttached=$true;driveAbsent=$true}
    if (!(Test-Path "$drive`:\")) { throw 'DiskPart failed to format and mount the profile VHD' }
    try {
        $image = Get-DiskImage -ImagePath $VhdPath
        $volume = Get-Volume -DriveLetter $drive
        if (!$image.Attached -or $volume.FileSystem -ne 'NTFS' -or $volume.FileSystemLabel -ne 'Ticket569Profile') { throw 'Created profile image is not an attached NTFS volume with the expected label' }
        if (!(Test-Path -LiteralPath (Join-Path $ProfilePath 'NTUSER.DAT'))) { throw 'Normal profile hive file is missing' }
        $copyReceipt=Invoke-ProfileMutation 'copy-normal-profile-into-owned-vhd' @{sid=$SID;profilePath=$ProfilePath;vhdPath=$VhdPath;volumeId=$volume.UniqueId} @{sourceProfileUnloaded=$true;vhdAttached=$true;destinationEmpty=$true} {
            Invoke-ProfileNative 'robocopy.exe' @($ProfilePath,"$drive`:\",'/MIR','/COPYALL','/XJ','/R:0','/W:0',('/LOG:'+(Join-Path $EvidenceDirectory 'profile-copy.log'))) | Out-Null
            $exit=$script:profileNativeExit
            Write-Atomic (Join-Path $EvidenceDirectory 'profile-copy-exit.json') @{ExitCode=$exit}
            if($exit -gt 7){throw "Profile copy failed with robocopy exit $exit"}
            @{exitCode=$exit;copiedHive=(Test-Path "$drive`:\NTUSER.DAT")}
        }
        $copyExit=[int]$copyReceipt.result.exitCode
        if (!(Test-Path "$drive`:\NTUSER.DAT")) { throw 'Copied profile hive is missing from the VHD' }
        $null = Assert-Unloaded $SID $ProfilePath
        Invoke-ProfileMutation 'rename-normal-profile-to-owned-backup' @{sid=$SID;profilePath=$ProfilePath;backupPath=$BackupPath} @{profileUnloaded=$true;backupAbsent=$true} {
            Rename-Item -LiteralPath $ProfilePath -NewName (Split-Path -Leaf $BackupPath) -ErrorAction Stop
            if(!(Test-Path -LiteralPath $BackupPath -PathType Container) -or (Test-Path -LiteralPath $ProfilePath)){throw 'Normal-profile rename did not produce the exact backup identity'}
            @{backupPresent=$true;profilePathAbsent=$true}
        }
        Invoke-ProfileMutation 'create-original-profile-mount-directory' @{sid=$SID;profilePath=$ProfilePath} @{profilePathAbsent=$true} {
            New-Item -ItemType Directory -Path $ProfilePath -ErrorAction Stop | Out-Null
            @{profilePathPresent=(Test-Path -LiteralPath $ProfilePath -PathType Container)}
        }
        Invoke-ProfileMutation 'mount-vhd-at-original-profile-path' @{sid=$SID;profilePath=$ProfilePath;vhdPath=$VhdPath;volumeId=$volume.UniqueId} @{backupPresent=$true;vhdAttached=$true;profileDirectoryPresent=$true} {
            Invoke-ProfileNative 'mountvol.exe' @($ProfilePath,$volume.UniqueId) | Out-Null
            if ($script:profileNativeExit -ne 0) { throw 'Could not mount the VHD volume at the original profile path' }
            @{exitCode=$script:profileNativeExit;mountedVolume=(Invoke-ProfileNative 'mountvol.exe' @($ProfilePath,'/L')).Trim()}
        }
        $reparse = Invoke-ProfileNative 'fsutil.exe' @('reparsepoint','query',$ProfilePath)
        if ($script:profileNativeExit -ne 0 -or $reparse -notmatch '0xa0000003') { throw 'Mounted profile path lacks volume mount-point reparse tag 0xA0000003' }
        $mountedVolume = (Invoke-ProfileNative 'mountvol.exe' @($ProfilePath,'/L')).Trim()
        if ($script:profileNativeExit -ne 0 -or !$mountedVolume -or $mountedVolume -cne $volume.UniqueId) { throw 'Could not read back the mounted profile volume GUID' }
        Invoke-ProfileMutation 'remove-temporary-vhd-drive-letter' @{vhdPath=$VhdPath;drive=$drive} @{profileMountVerified=$true;temporaryDriveAssigned=$true} {
            Invoke-ProfileNative 'mountvol.exe' @("$drive`:\",'/D') | Out-Null
            if ($script:profileNativeExit -ne 0) { throw 'Could not remove the temporary VHD drive letter' }
            @{exitCode=$script:profileNativeExit;driveAbsent=(!(Test-Path "$drive`:\"))}
        }
        Write-Atomic (Join-Path $EvidenceDirectory 'profile-vhd-identity.json') @{ SID = $SID; ProfilePath = $ProfilePath; BackupPath = $BackupPath; VhdPath = $VhdPath; ImageAttached = [bool]$image.Attached; ImageDevicePath = $image.DevicePath; VolumeId = $mountedVolume; FileSystem = $volume.FileSystem; Size = $volume.Size; ReparseTag = '0xA0000003'; SourceWasUnloaded = $true }
    } finally {
        if (Test-Path "$drive`:\") {
            Invoke-ProfileMutation 'cleanup-temporary-vhd-drive-letter' @{vhdPath=$VhdPath;drive=$drive} @{temporaryDriveStillAssigned=$true} {
                Invoke-ProfileNative 'mountvol.exe' @("$drive`:\",'/D') | Out-Null
                if($script:profileNativeExit -ne 0){throw 'Could not remove the temporary VHD drive letter during cleanup'}
                @{exitCode=$script:profileNativeExit;driveAbsent=(!(Test-Path "$drive`:\"))}
            }
        }
    }
    exit 0
}

$null = Assert-Unloaded $SID $ProfilePath
$backupExists = Test-Path -LiteralPath $BackupPath -PathType Container
$profileExists = Test-Path -LiteralPath $ProfilePath -PathType Container
$image = $null
if (Test-Path -LiteralPath $VhdPath -PathType Leaf) { $image = Get-DiskImage -ImagePath $VhdPath -ErrorAction Stop }
$diskNumber = if ($image) { $image.Number } else { $null }
if ($backupExists) {
    if (!$profileExists) {
        Invoke-ProfileMutation 'recreate-missing-profile-restore-placeholder' @{sid=$SID;profilePath=$ProfilePath;backupPath=$BackupPath} @{normalBackupPresent=$true;originalProfilePathAbsent=$true} {
            if(Test-Path -LiteralPath $ProfilePath){throw 'Profile placeholder path became occupied before recovery creation'}
            New-Item -ItemType Directory -Path $ProfilePath -ErrorAction Stop | Out-Null
            @{profilePathPresent=(Test-Path -LiteralPath $ProfilePath -PathType Container)}
        }
    }
    $reparse = Invoke-ProfileNative 'fsutil.exe' @('reparsepoint','query',$ProfilePath)
    if ($script:profileNativeExit -eq 0 -and $reparse -match '0xa0000003') {
        if (!$image -or !$image.Attached) { throw 'Mounted profile point has no attached owned VHD' }
        $mountedVolume = (Invoke-ProfileNative 'mountvol.exe' @($ProfilePath,'/L')).Trim()
        $imageVolumes = @(Get-Partition -DiskNumber $image.Number | Get-Volume)
        if (!$mountedVolume -or !($imageVolumes | Where-Object { $_.UniqueId -eq $mountedVolume })) { throw 'Profile mount point does not resolve to a volume on the owned VHD' }
        Invoke-ProfileMutation 'detach-vhd-profile-mount-point' @{sid=$SID;profilePath=$ProfilePath;vhdPath=$VhdPath;volumeId=$mountedVolume} @{mountedVhdVerified=$true;normalBackupPresent=$true} {
            Invoke-ProfileNative 'mountvol.exe' @($ProfilePath,'/D') | Out-Null
            if ($script:profileNativeExit -ne 0) { throw 'Could not detach profile volume mount point' }
            @{exitCode=$script:profileNativeExit;mountAbsent=((Invoke-ProfileNative 'fsutil.exe' @('reparsepoint','query',$ProfilePath)) -notmatch '0xa0000003')}
        }
        Invoke-ProfileMutation 'remove-profile-mount-placeholder' @{sid=$SID;profilePath=$ProfilePath} @{mountDetached=$true;normalBackupPresent=$true} {
            Remove-Item -LiteralPath $ProfilePath -Force -ErrorAction Stop
            @{profilePathAbsent=(!(Test-Path -LiteralPath $ProfilePath))}
        }
    } else {
        $placeholder = @(Get-ChildItem -LiteralPath $ProfilePath -Force -ErrorAction Stop)
        if ($placeholder.Count -ne 0) { throw 'Unconverted profile path is not an empty recovery placeholder' }
        Invoke-ProfileMutation 'remove-empty-profile-restore-placeholder' @{sid=$SID;profilePath=$ProfilePath;backupPath=$BackupPath} @{normalBackupPresent=$true;profilePathIsEmpty=$true;reparseMountAbsent=$true} {
            $current=@(Get-ChildItem -LiteralPath $ProfilePath -Force -ErrorAction Stop)
            if($current.Count -ne 0){throw 'Profile restore placeholder is no longer empty'}
            Remove-Item -LiteralPath $ProfilePath -Force -ErrorAction Stop
            @{profilePathAbsent=(!(Test-Path -LiteralPath $ProfilePath))}
        }
    }
    Invoke-ProfileMutation 'restore-normal-profile-from-owned-backup' @{sid=$SID;profilePath=$ProfilePath;backupPath=$BackupPath} @{profileUnloaded=$true;backupPresent=$true;mountPointAbsent=(!(Test-Path -LiteralPath $ProfilePath -PathType Container) -or $reparse -notmatch '0xa0000003')} {
        Rename-Item -LiteralPath $BackupPath -NewName (Split-Path -Leaf $ProfilePath) -ErrorAction Stop
        @{backupAbsent=(!(Test-Path -LiteralPath $BackupPath));profilePresent=(Test-Path -LiteralPath $ProfilePath -PathType Container)}
    }
} elseif (!$profileExists) {
    throw 'Neither the original profile nor its restoration backup exists'
} else {
    $reparse = Invoke-ProfileNative 'fsutil.exe' @('reparsepoint','query',$ProfilePath)
    if ($script:profileNativeExit -eq 0 -and $reparse -match '0xa0000003') {
        throw 'Profile is mounted but its normal-profile backup is absent; refusing destructive restore'
    }
    if ($image -and $image.Attached) {
        # Conversion had not renamed the normal directory, so only the temporary VHD needs cleanup.
    }
}
$null = Assert-Unloaded $SID $ProfilePath
if ($image -and $image.Attached) { Invoke-ProfileMutation 'dismount-owned-profile-vhd' @{sid=$SID;vhdPath=$VhdPath;diskNumber=$image.Number} @{normalProfileRestored=$true;imageAttached=$true} { Dismount-DiskImage -ImagePath $VhdPath -ErrorAction Stop;@{attached=([bool](Get-DiskImage -ImagePath $VhdPath).Attached)} } }
if (Test-Path -LiteralPath $VhdPath -PathType Leaf) { $image=Get-DiskImage -ImagePath $VhdPath -ErrorAction Stop;if($image.Attached){throw 'Owned VHD remains attached after bounded restore; file removal refused'} }
if (Test-Path -LiteralPath $VhdPath -PathType Leaf) { Invoke-ProfileMutation 'remove-owned-profile-vhd-file' @{sid=$SID;vhdPath=$VhdPath} @{normalProfileRestored=$true;imageDetached=(!$image -or !$image.Attached)} { Remove-Item -LiteralPath $VhdPath -Force -ErrorAction Stop;@{absent=(!(Test-Path -LiteralPath $VhdPath))} } }
if (Test-Path -LiteralPath $VhdPath) { throw 'Owned profile VHD file remains after normal-profile restoration' }
Write-Atomic (Join-Path $EvidenceDirectory 'profile-normal-restored.json') @{ SID = $SID; ProfilePath = $ProfilePath; RestoredFrom = $(if ($backupExists) { $BackupPath } else { $null }); VhdPath = $VhdPath; VhdDiskNumber = $diskNumber; VhdDetached = $true; VhdRemoved = $true; ProfileLoaded = $false }
exit 0
