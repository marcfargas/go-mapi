[CmdletBinding()]
param([Parameter(Mandatory)] [string] $OutputPath)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$process = Get-Process -Id $PID
$admin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$profile = Get-CimInstance Win32_UserProfile | Where-Object SID -eq $identity.User.Value
if ($process.SessionId -eq 0 -or $admin -or !$profile -or !$profile.Loaded -or $profile.LocalPath -ne $env:USERPROFILE) {
    throw 'Current CUA process is not the loaded non-admin interactive user profile'
}
$item = Get-Item -LiteralPath $env:USERPROFILE -Force
$reparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
$record = [pscustomobject]@{
    User = $identity.Name
    SID = $identity.User.Value
    PID = $PID
    SessionId = $process.SessionId
    Admin = $admin
    UserProfile = $env:USERPROFILE
    ProfileLocalPath = $profile.LocalPath
    ProfileLoaded = [bool]$profile.Loaded
    IsReparsePoint = $reparse
    At = [DateTime]::UtcNow.ToString('o')
}
$temp = "$OutputPath.$([guid]::NewGuid().ToString('N')).tmp"
[IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $record -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temp -Destination $OutputPath -Force
exit 0
