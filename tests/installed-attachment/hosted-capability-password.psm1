Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Send-HostedCapabilityOneShotPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IO.Pipes.NamedPipeServerStream] $Pipe,
        [Parameter(Mandatory)][string] $Secret,
        [Parameter(Mandatory)][scriptblock] $GetClientProcessId,
        [Parameter(Mandatory)][scriptblock] $VerifyClient,
        [ValidateRange(1,30000)][int] $TimeoutMilliseconds=15000
    )
    $bytes=$null
    try {
        if(!$Secret -or $Secret.Length -gt 512){throw 'one-shot password transfer is malformed or oversized'}
        $connected=$Pipe.WaitForConnectionAsync()
        if(!$connected.Wait($TimeoutMilliseconds)){throw 'PasswordCommand did not connect to its bounded one-shot pipe'}
        $clientPID=[uint32](& $GetClientProcessId $Pipe)
        if(!$clientPID -or !(& $VerifyClient $clientPID)){throw 'PasswordCommand pipe caller did not match its exact authorized process identity'}
        $bytes=[Text.Encoding]::UTF8.GetBytes($Secret)
        if($bytes.Length -gt 512){throw 'one-shot password byte transfer exceeds its bound'}
        $Pipe.Write($bytes,0,$bytes.Length);$Pipe.Flush()
        @{sent=$true;clientPID=$clientPID;byteCount=$bytes.Length;oneShot=$true}
    } finally {
        if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}
        $Secret=$null
        $Pipe.Dispose()
    }
}

Export-ModuleMember -Function Send-HostedCapabilityOneShotPassword

function Test-HostedCapabilityPasswordPeer {
    [CmdletBinding()]
    param([uint32]$ClientPID,[uint32]$LauncherPID,[long]$LauncherCreationFileTimeUtc,[string]$LauncherExecutable,[string]$EncodedCommand,[string]$OwnerSID,[int]$OwnerSession,[string]$OwnerJobName)
    $handles=[Collections.Generic.List[Diagnostics.Process]]::new()
    try{
        $client=Get-Process -Id $ClientPID -ErrorAction Stop;$null=$client.Handle;$handles.Add($client)
        $clientInfo=Get-CimInstance Win32_Process -Filter "ProcessId=$ClientPID" -ErrorAction Stop
        $parent=Get-Process -Id ([int]$clientInfo.ParentProcessId) -ErrorAction Stop;$null=$parent.Handle;$handles.Add($parent)
        $parentInfo=Get-CimInstance Win32_Process -Filter "ProcessId=$($parent.Id)" -ErrorAction Stop
        $launcher=Get-Process -Id $LauncherPID -ErrorAction Stop;$null=$launcher.Handle;$handles.Add($launcher)
        $launcherInfo=Get-CimInstance Win32_Process -Filter "ProcessId=$LauncherPID" -ErrorAction Stop
        foreach($pair in @(@($client,$clientInfo),@($parent,$parentInfo),@($launcher,$launcherInfo))){
            $process=$pair[0];$info=$pair[1];$sid=(Invoke-CimMethod -InputObject $info -MethodName GetOwnerSid -ErrorAction Stop).Sid
            if($process.HasExited -or $sid -cne $OwnerSID -or $process.SessionId -ne $OwnerSession -or !(Test-HostedCapabilityProcessInJob -ProcessId ([uint32]$process.Id) -JobName $OwnerJobName)){return $false}
        }
        $valid=($parentInfo.ParentProcessId -eq $LauncherPID -and $launcher.StartTime.ToUniversalTime().ToFileTimeUtc() -eq $LauncherCreationFileTimeUtc -and
            [IO.Path]::GetFullPath($launcherInfo.ExecutablePath) -ieq [IO.Path]::GetFullPath($LauncherExecutable) -and
            [IO.Path]::GetFullPath($clientInfo.ExecutablePath) -ieq [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')) -and
            [IO.Path]::GetFullPath($parentInfo.ExecutablePath) -ieq [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\cmd.exe')) -and
            $EncodedCommand -and $clientInfo.CommandLine.Contains($EncodedCommand,[StringComparison]::Ordinal))
        [bool]$valid
    }catch{return $false}finally{foreach($handle in $handles){$handle.Dispose()}}
}
Export-ModuleMember -Function Send-HostedCapabilityOneShotPassword, Test-HostedCapabilityPasswordPeer
