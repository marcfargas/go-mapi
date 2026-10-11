$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('t569-lease-caller-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
$profilePath='C:\Users\t569leasefixture';$vhdPath='C:\crabbox\work\ticket569\profile-fixture.vhdx';$backupPath="$profilePath.normal-backup";$SID='S-1-5-21-1'
$global:t569LeasePaths=@{};$global:t569LeaseCalls=[Collections.Generic.List[string]]::new();$global:t569LeaseLoaded=$false;$global:t569LeaseAttached=$false;$global:t569LeaseMounted=$false
$global:t569LeaseVolume='\\?\Volume{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}\'
function Test-Path {param($LiteralPath,$Path,$PathType) $p=if($LiteralPath){$LiteralPath}else{$Path};if($p -like 'C:*' -or $p -like 'T:*' -or $p -like 'Registry:*'){[bool]$global:t569LeasePaths[$p]}else{Microsoft.PowerShell.Management\Test-Path -LiteralPath $p}}
function Join-Path {param($Path,$ChildPath)if($Path -like 'C:*'){$Path+'\'+$ChildPath}else{Microsoft.PowerShell.Management\Join-Path $Path $ChildPath}}
function New-Item {param($ItemType,$Path,[switch]$Force,$ErrorAction)if($Path -like 'C:*'){$global:t569LeasePaths[$Path]=$true;[pscustomobject]@{FullName=$Path}}else{Microsoft.PowerShell.Management\New-Item -ItemType $ItemType -Path $Path -Force:$Force}}
function Get-CimInstance {param($ClassName,$ErrorAction)@{SID=$SID;LocalPath=$profilePath;Loaded=$global:t569LeaseLoaded}}
function Get-ChildItem {param($LiteralPath,[switch]$Recurse,[switch]$File,[switch]$Force,$ErrorAction)@{Length=1234}}
function Get-DiskImage {param($ImagePath,$ErrorAction)if($ImagePath -cne $vhdPath){throw 'Lease adapter received an unowned image'};@{Attached=$global:t569LeaseAttached;DevicePath='fixture-device';Number=99}}
function Get-Volume {param($DriveLetter)if($DriveLetter -cne 'T'){throw 'Lease adapter received an unexpected drive'};@{UniqueId=$global:t569LeaseVolume;FileSystem='NTFS';FileSystemLabel='Ticket569Profile';Size=8GB}}
function Rename-Item {param($LiteralPath,$NewName,$ErrorAction)if($LiteralPath -cne $profilePath -or $NewName -cne 't569leasefixture.normal-backup'){throw 'Lease rename identity changed'};$global:t569LeaseCalls.Add('rename');$global:t569LeasePaths[$profilePath]=$false;$global:t569LeasePaths[$backupPath]=$true}
function diskpart.exe {
 param($Mode,$ScriptFile)
 if($Mode -cne '/s'){throw 'Lease diskpart argument contract changed'}
 $commands=[IO.File]::ReadAllText($ScriptFile);$global:t569LeaseCalls.Add('diskpart')
 if($commands -like '*create vdisk*'){$global:t569LeasePaths[$vhdPath]=$true}
 elseif($commands -like '*attach vdisk*'){$global:t569LeaseAttached=$true}
 elseif($commands -like '*format fs=ntfs*'){$global:t569LeasePaths['T:\']=$true}
 else{throw 'Unexpected Lease diskpart mutation'}
 $global:LASTEXITCODE=0;'diskpart Windows adapter; no host mutation'
}
function robocopy.exe {
 param($Source,$Destination,$Mirror,$CopyAll,$NoJunctions,$Retry,$Wait,$Log)
 if($Source -cne $profilePath -or $Destination -cne 'T:\' -or $Mirror -cne '/MIR' -or $CopyAll -cne '/COPYALL'){throw 'Lease copy argument contract changed'}
 $global:t569LeaseCalls.Add('copy');$global:t569LeasePaths['T:\NTUSER.DAT']=$true;$global:LASTEXITCODE=1
}
function mountvol.exe {
 param($Path,$Action)
 if($Path -ceq $profilePath -and $Action -ceq $global:t569LeaseVolume){$global:t569LeaseMounted=$true;$global:t569LeaseCalls.Add('mount')}
 elseif($Path -ceq $profilePath -and $Action -ceq '/L'){if(!$global:t569LeaseMounted){throw 'Lease readback before mount'};$global:t569LeaseVolume}
 elseif($Path -ceq 'T:\' -and $Action -ceq '/D'){$global:t569LeasePaths['T:\']=$false;$global:t569LeaseCalls.Add('remove-drive')}
 else{throw 'Unexpected Lease mountvol mutation'}
 $global:LASTEXITCODE=0
}
function fsutil.exe {param($Operation,$Query,$Path)if($Operation -cne 'reparsepoint' -or $Query -cne 'query' -or $Path -cne $profilePath -or !$global:t569LeaseMounted){throw 'Lease mount identity readback differs'};$global:LASTEXITCODE=0;'Reparse Tag Value : 0xa0000003'}
try{
 $global:t569LeasePaths[$profilePath]=$true;$global:t569LeasePaths["$profilePath\NTUSER.DAT"]=$true
 # The unchanged run.py remote_script path supplies only these string values:
 # no MutationHook, mode or Hosted clock arguments are smuggled into the call.
 & (Join-Path $PSScriptRoot 'profile.ps1') -Action prepare-vhd -SID $SID -ProfilePath $profilePath -VhdPath $vhdPath -BackupPath $backupPath -EvidenceDirectory $temp | Out-Null
 if($LASTEXITCODE -ne 0){throw 'Unchanged Lease caller failed'}
 $identity=Get-Content (Join-Path $temp 'profile-vhd-identity.json') -Raw|ConvertFrom-Json
 $copy=Get-Content (Join-Path $temp 'profile-copy-exit.json') -Raw|ConvertFrom-Json
 if($identity.VolumeId -cne $global:t569LeaseVolume -or $identity.ReparseTag -cne '0xA0000003' -or !$identity.SourceWasUnloaded -or $copy.ExitCode -ne 1 -or !$global:t569LeasePaths[$backupPath] -or !$global:t569LeaseMounted -or $global:t569LeasePaths['T:\'] -or ($global:t569LeaseCalls -join ',') -cne 'diskpart,diskpart,diskpart,copy,rename,mount,remove-drive'){throw 'Production Lease prepare-vhd did not preserve copy receipt or ordered guarded conversion'}
 $global:t569LeaseLoaded=$true;$before=$global:t569LeaseCalls.Count;$denied=$false
 try{& (Join-Path $PSScriptRoot 'profile.ps1') -Action prepare-vhd -SID $SID -ProfilePath $profilePath -VhdPath $vhdPath -BackupPath $backupPath -EvidenceDirectory $temp}catch{$denied=$true}
 if(!$denied -or $global:t569LeaseCalls.Count -ne $before){throw 'Loaded Lease profile reached an external mutator'}
 Write-Output 'PRODUCTION_LEASE_PREPARE_VHD_UNCHANGED_STRING_CALLER_PASSED;COPY_EXIT1_RECEIPT_AND_LOADED_PROFILE_REJECTION;WINDOWS_DISK_PROFILE_APIS_ADAPTED_NO_HOST_MUTATION'
}finally{Microsoft.PowerShell.Management\Remove-Item $temp -Recurse -Force;Remove-Variable t569LeasePaths,t569LeaseCalls,t569LeaseLoaded,t569LeaseAttached,t569LeaseMounted,t569LeaseVolume -Scope Global -ErrorAction SilentlyContinue}
