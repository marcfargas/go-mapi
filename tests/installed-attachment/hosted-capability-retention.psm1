$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'hosted-capability-verdict.psm1') -Force
function Assert-HostedCapabilityRetentionCanaries([string]$Directory,[string]$RunId,[string]$SourceSHA){
    $finalPath=Join-Path $Directory 'hosted-capability-final.json'
    $identityPath=Join-Path $Directory 'secret-canary-identity.json'
    $hashes=@()
    if(Test-Path -LiteralPath $finalPath){
        $final=Get-Content -LiteralPath $finalPath -Raw|ConvertFrom-Json
        if($final.runId -cne $RunId -or $final.sourceSHA -cne $SourceSHA -or !$final.secretCanary.checked -or $final.secretCanary.leakDetected){throw 'Evidence retention blocked by failed or unknown final secret scan'}
        $hashes=@($final.secretCanary.hashes)
    }elseif(Test-Path -LiteralPath $identityPath){
        $identity=Get-Content -LiteralPath $identityPath -Raw|ConvertFrom-Json
        if($identity.schema -cne 'ticket569-secret-canary-v1' -or $identity.runId -cne $RunId -or $identity.sourceSHA -cne $SourceSHA -or !$identity.hashes.Count){throw 'Evidence retention blocked by unknown early secret identity'}
        $hashes=@($identity.hashes)
    }elseif(Test-Path -LiteralPath (Join-Path $Directory 'supervisor-identity.json')){
        $identity=Get-Content -LiteralPath (Join-Path $Directory 'supervisor-identity.json') -Raw|ConvertFrom-Json
        if($identity.worker){throw 'Evidence retention blocked: started worker lacks durable secret identity or checked final scan'}
    }
    foreach($canary in $hashes){
        if($canary.sha256 -notmatch '^[0-9a-f]{64}$' -or [int]$canary.length -le 0){throw 'Invalid retention canary identity'}
        $scan=Test-HostedSecretCanary -Directories @($Directory) -Sha256 $canary.sha256 -Length $canary.length -RollingFingerprint $canary.rollingFingerprint
        if($scan.leaked){throw 'Evidence retention blocked by a password canary'}
    }
}
Export-ModuleMember -Function Assert-HostedCapabilityRetentionCanaries
