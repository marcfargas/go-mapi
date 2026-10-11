Set-StrictMode -Version 2.0

# Debug 776: the disposable matrix profile can already contain a resident go-mapi app and its app.log before a case
# starts. Only an explicit owned-fixture caller may stop the exact installed app of the current standard SID/session
# and preserve the prior log as separate evidence; every other situation fails closed.

function Get-Ticket569AppProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name = 'go-mapi.exe'" -ErrorAction Stop | ForEach-Object {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Id = [int]$_.ProcessId; Name = $_.Name; ExecutablePath = $_.ExecutablePath; SessionId = [int]$_.SessionId
            OwnerSid = $(if ($owner) { $owner.Sid } else { $null })
            CreationDate = $(if ($_.CreationDate) { ([DateTime]$_.CreationDate).ToUniversalTime().ToString('o') } else { $null })
        }
    })
}

function Stop-Ticket569OwnedApp {
    # Debug 779: positive exit proof from the same retained process handle; process listing is not exit proof.
    param(
        [Parameter(Mandatory)] [int] $ProcessId,
        [int] $TimeoutMilliseconds = 30000,
        # Process.Handle is lazy: open and retain the native handle before Kill so wait/exit fields come from it.
        [scriptblock] $GetHandle = { param([int] $Id) $p = Get-Process -Id $Id -ErrorAction Stop; $null = $p.Handle; $p }
    )
    $handle = & $GetHandle $ProcessId
    if (!$handle) { throw "Owned fixture app process $ProcessId handle could not be opened" }
    try {
        $handle.Kill()
        if (!$handle.WaitForExit($TimeoutMilliseconds)) { throw "Owned fixture app process $ProcessId did not exit within $TimeoutMilliseconds ms" }
        $handle.Refresh()
        if ($handle.HasExited -ne $true) { throw "Owned fixture app process $ProcessId handle does not report exit" }
        # ExitCode/ExitTime come from the same handle; a platform that cannot report them records null rather than inventing values.
        $exitCode = try { $handle.ExitCode } catch { $null }
        $exitTime = try { $handle.ExitTime } catch { $null }
        [ordered]@{ HasExited = $true; ExitCode = $exitCode; ExitedUtc = $(if ($exitTime) { $exitTime.ToUniversalTime().ToString('o') } else { $null })
            ObservedExitedUtc = [DateTime]::UtcNow.ToString('o') }
    } finally {
        if ($handle -is [IDisposable]) { $handle.Dispose() }
    }
}

function Invoke-Ticket569AppFixturePreparation {
    param(
        [Parameter(Mandatory)] [string] $AppLogPath,
        [Parameter(Mandatory)] [string] $AppPath,
        [Parameter(Mandatory)] [string] $RunRoot,
        [Parameter(Mandatory)] [string] $Sid,
        [Parameter(Mandatory)] [int] $SessionId,
        [switch] $OwnedFixture,
        [scriptblock] $GetProcesses = { Get-Ticket569AppProcesses },
        [scriptblock] $StopProcess = { param([int] $ProcessId) Stop-Ticket569OwnedApp -ProcessId $ProcessId }
    )
    $appName = ($AppPath -split '[\\/]')[-1]
    $resident = @(& $GetProcesses | Where-Object { $_.Name -ieq $appName -or ($_.ExecutablePath -and $_.ExecutablePath -ieq $AppPath) })
    $logPresent = Test-Path -LiteralPath $AppLogPath -PathType Leaf
    if (!$OwnedFixture) {
        if ($resident.Count) { throw 'The installed app is already running before the case; refusing to share it' }
        if ($logPresent) { throw 'Disposable profile already has an app log; refusing to collect or overwrite it' }
        return $null
    }
    foreach ($process in $resident) {
        if (!$process.ExecutablePath -or $process.ExecutablePath -ine $AppPath -or $process.SessionId -ne $SessionId -or $process.OwnerSid -ne $Sid) {
            throw "Unrecognized go-mapi process $($process.Id) is not the owned fixture app; refusing to stop or share it"
        }
    }
    $stopped = @()
    foreach ($process in $resident) {
        $exit = & $StopProcess $process.Id
        if (!$exit -or $exit.HasExited -ne $true) { throw "Owned fixture app process $($process.Id) has no positive exit proof" }
        $stopped += [ordered]@{ PID = $process.Id; ExecutablePath = $process.ExecutablePath; SessionId = $process.SessionId; OwnerSid = $process.OwnerSid; CreationDate = $process.CreationDate
            HasExited = $true; ExitCode = $exit.ExitCode; ExitedUtc = $exit.ExitedUtc }
    }
    $log = $null
    if (Test-Path -LiteralPath $AppLogPath -PathType Leaf) {
        $item = Get-Item -LiteralPath $AppLogPath -Force
        $destination = Join-Path $RunRoot 'preexisting-app.log'
        if (Test-Path -LiteralPath $destination) { throw 'Preserved prior app log destination already exists' }
        $sha = (Get-FileHash -LiteralPath $AppLogPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $log = [ordered]@{ Source = $AppLogPath; Preserved = $destination; SHA256 = $sha; Length = $item.Length
            CreationTimeUtc = $item.CreationTimeUtc.ToString('o'); LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o') }
        Move-Item -LiteralPath $AppLogPath -Destination $destination -ErrorAction Stop
        if ((Test-Path -LiteralPath $AppLogPath) -or (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) {
            throw 'Prior app log was not preserved exactly and removed from the case profile'
        }
    }
    $receipt = [ordered]@{ SchemaVersion = 1; Sid = $Sid; SessionId = $SessionId; AppPath = $AppPath; StoppedOwnedApps = $stopped; PreexistingAppLog = $log }
    [IO.File]::WriteAllText((Join-Path $RunRoot 'preexisting-app-fixture.json'), (ConvertTo-Json -InputObject $receipt -Depth 6), [Text.UTF8Encoding]::new($false))
    return $receipt
}

Export-ModuleMember -Function Invoke-Ticket569AppFixturePreparation, Get-Ticket569AppProcesses, Stop-Ticket569OwnedApp
