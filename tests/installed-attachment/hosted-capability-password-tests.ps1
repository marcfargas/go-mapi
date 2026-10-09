$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-password.psm1') -Force

function New-TestPasswordPipe([string] $Name) {
    [IO.Pipes.NamedPipeServerStream]::new($Name,[IO.Pipes.PipeDirection]::Out,1,[IO.Pipes.PipeTransmissionMode]::Byte,[IO.Pipes.PipeOptions]::Asynchronous,512,512)
}
function New-TestPasswordClient([string] $Name) {
    [IO.Pipes.NamedPipeClientStream]::new('.', $Name, [IO.Pipes.PipeDirection]::In, [IO.Pipes.PipeOptions]::Asynchronous)
}

$ownerSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-session-owner.ps1') -Raw
$workerSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted-capability.ps1') -Raw
$promptSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'hosted_cua_prompt.py') -Raw
if($ownerSource -match 'T569_LOGIN_PASSWORD' -or
   $ownerSource -match '\$envMap\[[^\]]*PASSWORD' -or
   $promptSource -match 'E2E_PASSWORD_PROMPT|GetEnvironmentVariable\(''T569_LOGIN_PASSWORD''' -or
   $ownerSource -notmatch 'PipeOptions\]::CurrentUserOnly' -or
   $ownerSource -notmatch 'WaitForConnectionAsync\(\)' -or
   $ownerSource -notmatch 'Send-HostedCapabilityOneShotPassword' -or
   $ownerSource -notmatch 'Test-HostedCapabilityPasswordPeer' -or
   $ownerSource -notmatch 'finally \{if\(\$passwordPipe\).*\$password=\$null.*\$Request\.password=' -or
   $workerSource -notmatch 'finally \{\$request\.password=' ){
    throw 'Password transfer must use a bounded CurrentUser-only one-shot pipe, exact pinned process ancestry, and clear owner/worker copies on success and failure'
}

$canary='T569-password-canary-4f0a'
$pipeName='Ticket569-password-test-'+[guid]::NewGuid().ToString('N')
$server=New-TestPasswordPipe $pipeName
$client=New-TestPasswordClient $pipeName
try {
    $connect=$client.ConnectAsync()
    try {
        $receipt=Send-HostedCapabilityOneShotPassword -Pipe $server -Secret $canary -GetClientProcessId {param($pipe) 1234} -VerifyClient {param($clientPID) $true}
        if(!$connect.Wait(5000)){throw 'test PasswordCommand client did not connect'}
        $received=[IO.MemoryStream]::new();$buffer=New-Object byte[] 64
        while(($count=$client.Read($buffer,0,$buffer.Length))-gt 0){$received.Write($buffer,0,$count)}
        $actual=[Text.Encoding]::UTF8.GetString($received.ToArray())
        if($actual -cne $canary){throw 'bounded one-shot pipe did not deliver the exact secret bytes'}
        $receiptText=ConvertTo-Json -InputObject $receipt -Compress
        if($receiptText -match [regex]::Escape($canary)){throw 'transfer receipt exposed the password canary'}
        [Array]::Clear($buffer,0,$buffer.Length);$received.Dispose()
    } finally {$client.Dispose()}
} finally {if($client){$client.Dispose()};if($server){$server.Dispose()}}

$failurePipeName='Ticket569-password-fail-'+[guid]::NewGuid().ToString('N')
$server=New-TestPasswordPipe $failurePipeName
$client=New-TestPasswordClient $failurePipeName
try {
    $connect=$client.ConnectAsync()
    try {
        try {
            $null=Send-HostedCapabilityOneShotPassword -Pipe $server -Secret $canary -GetClientProcessId {param($pipe) 1234} -VerifyClient {param($clientPID) $false}
            throw 'unrecognized PasswordCommand peer was allowed to receive the secret'
        } catch {if($_.Exception.Message -notmatch 'exact authorized process identity' -or $_.Exception.Message -match [regex]::Escape($canary)){throw}}
        if(!$connect.Wait(5000)){throw 'failure-path test client did not connect'}
        if($client.ReadByte() -ne -1){throw 'unrecognized PasswordCommand peer received secret bytes before identity rejection'}
    } finally {$client.Dispose()}
} finally {if($client){$client.Dispose()};if($server){$server.Dispose()}}

Write-Output 'HOSTED_CAPABILITY_PASSWORD_TRANSFER_TESTS_PASSED; WINDOWS_PEER_ACL_AND_JOB_CHECKS_NOT_EXERCISED'
