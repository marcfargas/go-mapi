[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('prepare-vhd', 'restore-normal')] [string] $Action,
    [Parameter(Mandatory)] [string] $SID,
    [Parameter(Mandatory)] [string] $ProfilePath,
    [Parameter(Mandatory)] [string] $VhdPath,
    [Parameter(Mandatory)] [string] $BackupPath,
    [Parameter(Mandatory)] [string] $EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
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
    New-Item -ItemType Directory -Path $vhdParent -Force | Out-Null
    $drive = 'T'
    if (Test-Path "$drive`:\") { throw 'Temporary T: drive is occupied' }
    $diskpart = @"
create vdisk file="$VhdPath" maximum=8192 type=expandable
select vdisk file="$VhdPath"
attach vdisk
create partition primary
format fs=ntfs label="Ticket569Profile" quick
assign letter=$drive
"@
    $diskpartPath = Join-Path $EvidenceDirectory 'create-profile-vhd.diskpart'
    [IO.File]::WriteAllText($diskpartPath, $diskpart, [Text.Encoding]::ASCII)
    $diskpartOutput = & diskpart.exe /s $diskpartPath 2>&1 | Out-String
    $diskpartExit = $LASTEXITCODE
    Write-Atomic (Join-Path $EvidenceDirectory 'create-profile-vhd.json') @{ ExitCode = $diskpartExit; Output = $diskpartOutput }
    if ($diskpartExit -ne 0 -or !(Test-Path "$drive`:\")) { throw 'DiskPart failed to create and mount the profile VHD' }
    try {
        $image = Get-DiskImage -ImagePath $VhdPath
        $volume = Get-Volume -DriveLetter $drive
        if (!$image.Attached -or $volume.FileSystem -ne 'NTFS' -or $volume.FileSystemLabel -ne 'Ticket569Profile') { throw 'Created profile image is not an attached NTFS volume with the expected label' }
        if (!(Test-Path -LiteralPath (Join-Path $ProfilePath 'NTUSER.DAT'))) { throw 'Normal profile hive file is missing' }
        & robocopy.exe $ProfilePath "$drive`:\" /MIR /COPYALL /XJ /R:0 /W:0 /LOG:(Join-Path $EvidenceDirectory 'profile-copy.log') | Out-Null
        $copyExit = $LASTEXITCODE
        Write-Atomic (Join-Path $EvidenceDirectory 'profile-copy-exit.json') @{ ExitCode = $copyExit }
        if ($copyExit -gt 7) { throw "Profile copy failed with robocopy exit $copyExit" }
        if (!(Test-Path "$drive`:\NTUSER.DAT")) { throw 'Copied profile hive is missing from the VHD' }
        $null = Assert-Unloaded $SID $ProfilePath
        Rename-Item -LiteralPath $ProfilePath -NewName (Split-Path -Leaf $BackupPath)
        New-Item -ItemType Directory -Path $ProfilePath | Out-Null
        & mountvol.exe $ProfilePath $volume.UniqueId | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not mount the VHD volume at the original profile path' }
        & mountvol.exe "$drive`:\" /D | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not remove the temporary VHD drive letter' }
        $reparse = & fsutil.exe reparsepoint query $ProfilePath 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $reparse -notmatch '0xa0000003') { throw 'Mounted profile path lacks volume mount-point reparse tag 0xA0000003' }
        $mountedVolume = (& mountvol.exe $ProfilePath /L 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or !$mountedVolume) { throw 'Could not read back the mounted profile volume GUID' }
        Write-Atomic (Join-Path $EvidenceDirectory 'profile-vhd-identity.json') @{ SID = $SID; ProfilePath = $ProfilePath; BackupPath = $BackupPath; VhdPath = $VhdPath; ImageAttached = [bool]$image.Attached; ImageDevicePath = $image.DevicePath; VolumeId = $mountedVolume; FileSystem = $volume.FileSystem; Size = $volume.Size; ReparseTag = '0xA0000003'; SourceWasUnloaded = $true }
    } finally {
        if (Test-Path "$drive`:\") { & mountvol.exe "$drive`:\" /D | Out-Null }
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
    if (!$profileExists) { throw 'Restoration backup exists but the original profile path is absent' }
    $reparse = & fsutil.exe reparsepoint query $ProfilePath 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $reparse -match '0xa0000003') {
        if (!$image -or !$image.Attached) { throw 'Mounted profile point has no attached owned VHD' }
        $mountedVolume = (& mountvol.exe $ProfilePath /L 2>&1 | Out-String).Trim()
        $imageVolumes = @(Get-Partition -DiskNumber $image.Number | Get-Volume)
        if (!$mountedVolume -or !($imageVolumes | Where-Object { $_.UniqueId -eq $mountedVolume })) { throw 'Profile mount point does not resolve to a volume on the owned VHD' }
        & mountvol.exe $ProfilePath /D | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not detach profile volume mount point' }
        Remove-Item -LiteralPath $ProfilePath -Force
    } else {
        $placeholder = @(Get-ChildItem -LiteralPath $ProfilePath -Force -ErrorAction Stop)
        if ($placeholder.Count -ne 0) { throw 'Unconverted profile path is not an empty recovery placeholder' }
        Remove-Item -LiteralPath $ProfilePath -Force
    }
    Rename-Item -LiteralPath $BackupPath -NewName (Split-Path -Leaf $ProfilePath)
} elseif (!$profileExists) {
    throw 'Neither the original profile nor its restoration backup exists'
} else {
    $reparse = & fsutil.exe reparsepoint query $ProfilePath 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $reparse -match '0xa0000003') {
        throw 'Profile is mounted but its normal-profile backup is absent; refusing destructive restore'
    }
    if ($image -and $image.Attached) {
        # Conversion had not renamed the normal directory, so only the temporary VHD needs cleanup.
    }
}
$null = Assert-Unloaded $SID $ProfilePath
if ($image -and $image.Attached) { Dismount-DiskImage -ImagePath $VhdPath -ErrorAction Stop }
if (Test-Path -LiteralPath $VhdPath -PathType Leaf) { Remove-Item -LiteralPath $VhdPath -Force }
if (Test-Path -LiteralPath $VhdPath) { throw 'Owned profile VHD file remains after normal-profile restoration' }
Write-Atomic (Join-Path $EvidenceDirectory 'profile-normal-restored.json') @{ SID = $SID; ProfilePath = $ProfilePath; RestoredFrom = $(if ($backupExists) { $BackupPath } else { $null }); VhdPath = $VhdPath; VhdDiskNumber = $diskNumber; VhdDetached = $true; VhdRemoved = $true; ProfileLoaded = $false }
exit 0
