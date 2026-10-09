[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunId,
    [Parameter(Mandatory)][string] $ExpectedSID,
    [Parameter(Mandatory)][int] $ExpectedSessionId,
    [Parameter(Mandatory)][string] $CertificatePath,
    [Parameter(Mandatory)][string] $Thumbprint,
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][string] $ObserverScriptPath,
    [Parameter(Mandatory)][string] $ObserverAttachedPath,
    [Parameter(Mandatory)][string] $ObserverExitPath,
    [Parameter(Mandatory)][string] $ObserverFailurePath,
    [ValidateRange(0,30)][int] $HoldAfterWriteSeconds = 2
)
$ErrorActionPreference = 'Stop'
$null = Import-Module (Join-Path $PSScriptRoot 'hosted-root-import-policy.psm1') -Force -PassThru
$result = [ordered]@{
    schema='ticket569-currentuser-root-import-v1'; runId=$RunId; sid=$null; sessionId=$null
    processId=$PID; processCreationFileTimeUtc=$null; store='CurrentUser/Root'; userFlag=$true
    subject=$null; thumbprint=$Thumbprint; certutilExitCode=$null; addedObserved=$false
    preexisting=$false; importAttempted=$false; removedObserved=$false; passed=$false; error=$null
}
function Write-Atomic([string] $Path, [object] $Value) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 24) + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
try {
    if ($RunId -notmatch '^[a-f0-9]{32}$' -or $ExpectedSID -notmatch '^S-1-5-21-' -or
        $Thumbprint -notmatch '^[a-fA-F0-9]{40}$' -or !(Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
        throw 'Root import run identity, certificate or thumbprint is malformed'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $process = Get-Process -Id $PID -ErrorAction Stop
    $admin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $result.sid = $identity.User.Value
    $result.sessionId = [int]$process.SessionId
    $result.processCreationFileTimeUtc = $process.StartTime.ToUniversalTime().ToFileTimeUtc()
    if ($result.sid -ne $ExpectedSID -or $result.sessionId -ne $ExpectedSessionId -or $admin -or
        !(Get-CimInstance Win32_UserProfile -Filter "SID='$ExpectedSID'" | Where-Object { $_.Loaded })) {
        throw 'Root import did not start in the exact loaded non-admin user session/profile'
    }
    $observerPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $observerArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',"`"$ObserverScriptPath`"",
        '-TargetProcessId',[string]$PID,'-ExpectedCommand',"`"$PSCommandPath`"",'-ExpectedRunId',$RunId,
        '-AttachedPath',"`"$ObserverAttachedPath`"",'-ExitPath',"`"$ObserverExitPath`"",
        '-FailurePath',"`"$ObserverFailurePath`"",'-TimeoutSeconds','120')
    $observer = Start-Process -FilePath $observerPowerShell -ArgumentList $observerArguments -PassThru
    $attachUntil = [DateTime]::UtcNow.AddSeconds(10)
    while (![IO.File]::Exists($ObserverAttachedPath) -and ![IO.File]::Exists($ObserverFailurePath) -and [DateTime]::UtcNow -lt $attachUntil) { Start-Sleep -Milliseconds 100 }
    if (![IO.File]::Exists($ObserverAttachedPath) -or [IO.File]::Exists($ObserverFailurePath)) { throw 'Retained process observer did not attach before the consent prompt' }
    $result.observerProcessId = $observer.Id
    $result.observerAttachedPath = $ObserverAttachedPath
    $result.observerExitPath = $ObserverExitPath
    $result.observerFailurePath = $ObserverFailurePath
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath)
    try {
        $result.subject = $cert.Subject
        $sha1 = [Security.Cryptography.SHA1]::Create()
        try { $actualThumb = ([BitConverter]::ToString($sha1.ComputeHash($cert.RawData))).Replace('-', '') }
        finally { $sha1.Dispose() }
        if ($actualThumb -cne $Thumbprint.ToUpperInvariant()) { throw 'Public certificate thumbprint differs from its exact run identity' }
    } finally { $cert.Dispose() }
    $present = @(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant())
    if ($present.Count) {
        $result.preexisting = $true
        throw 'Unique prompt-test certificate already exists in CurrentUser Root; preserving its preexisting state'
    }

    # No -f: certutil must ask its real CurrentUser Root consent question. It
    # shares the task's interactive console so native rdpilot CUA can observe it.
    $result.importAttempted = $true
    $certutil = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\certutil.exe') `
        -ArgumentList @('-user','-addstore','Root',$CertificatePath) -NoNewWindow -PassThru
    if (!$certutil.WaitForExit([TimeSpan]::FromMinutes(4).TotalMilliseconds)) {
        $certutil.Kill(); $certutil.WaitForExit(); throw 'Bounded certutil CurrentUser Root prompt did not complete'
    }
    $result.certutilExitCode = [int]$certutil.ExitCode
    $present = @(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant())
    $result.addedObserved = ($result.certutilExitCode -eq 0 -and $present.Count -eq 1 -and $present[0].Subject -ceq $result.subject)
    if (!$result.addedObserved) { throw 'Exact test certificate was not observed in CurrentUser Root after consent' }
} catch {
    $result.error = @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message }
} finally {
    try {
        $match = @(Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant())
        $subjectMatches = ($match.Count -eq 1 -and $match[0].Subject -ceq $result.subject)
        $decision = Get-HostedRootImportCleanupDecision -Preexisting $result.preexisting -ImportAttempted $result.importAttempted `
            -MatchCount $match.Count -SubjectMatches $subjectMatches
        if ($decision -eq 'remove-owned') {
            Remove-Item -LiteralPath "Cert:\CurrentUser\Root\$Thumbprint" -Confirm:$false -ErrorAction Stop
        } elseif ($decision -like 'refuse-*') {
            throw 'Refused cleanup because CurrentUser Root thumbprint is ambiguous or subject-mismatched'
        }
        $absent = @((Get-ChildItem Cert:\CurrentUser\Root -ErrorAction Stop | Where-Object Thumbprint -CEQ $Thumbprint.ToUpperInvariant())).Count -eq 0
        $result.removedObserved = $absent
        if (!$absent -and !$result.preexisting) { throw 'Exact transient CurrentUser Root certificate remains after cleanup' }
    } catch {
        if (!$result.error) { $result.error = @{ type=$_.Exception.GetType().FullName; message=$_.Exception.Message } }
        else { $result.cleanupError = $_.Exception.Message }
        $result.removedObserved = $false
    }
}
$result.completedAtUtc = [DateTime]::UtcNow.ToString('o')
$result.passed = (!$result.error -and $result.addedObserved -and $result.removedObserved -and $result.certutilExitCode -eq 0)
try { Write-Atomic $OutputPath $result } catch { [Console]::Error.WriteLine("final root-import evidence write failed: $($_.Exception.Message)"); exit 2 }
if ($HoldAfterWriteSeconds -gt 0) { Start-Sleep -Seconds $HoldAfterWriteSeconds }
if (!$result.passed) { exit 1 }
exit 0
