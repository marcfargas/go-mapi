# Windows PowerShell 5.1 guest program, invoked by just sandbox-test.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$InputDirectory, [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
if ($env:GOMAPI_SANDBOX -cne '1') { throw 'Run only in the owned disposable Sandbox' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (!([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Guest installation requires elevation' }
function ReadJson([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function WriteJson([string]$Name, $Value) { [IO.File]::WriteAllText((Join-Path $OutputDirectory $Name), ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false)) }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$markerPath = 'HKLM:\SOFTWARE\go-mapi\MachineProduct'
$uninstallPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
$productRoot = Join-Path $env:ProgramFiles 'go-mapi'
$receipt = [ordered]@{passed=$false; error=$null; offline=$false; installed=$false; upgraded=$false; removed=$false; cleanupErrors=@()}
$cleanupErrors = [Collections.Generic.List[string]]::new()
$attempted = $false
$ownedProducts = @()

function AssertSignature([string]$Path, $Proof, [string]$Filename) {
    $expected = @($Proof.signatures | Where-Object file -ceq $Filename)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($expected.Count -ne 1 -or $expected[0].status -cne 'Valid' -or $signature.Status -ne 'Valid' -or
        $signature.SignatureType -ne 'Authenticode' -or !$signature.SignerCertificate -or !$signature.TimeStamperCertificate -or
        $signature.SignerCertificate.Subject -cne $expected[0].signerSubject -or
        $signature.SignerCertificate.Thumbprint -cne $expected[0].signerThumbprint -or
        $signature.TimeStamperCertificate.Thumbprint -cne $expected[0].timestampThumbprint) { throw "Default Windows signature trust differs: $Filename" }
    [ordered]@{path=$Path; sha256=(Hash $Path); status=$signature.Status.ToString(); signer=$signature.SignerCertificate.Thumbprint; timestamp=$signature.TimeStamperCertificate.Thumbprint} |
        ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $OutputDirectory 'signatures.ndjson')
}
function InvokeMsi([string]$Operation, [string]$Package, [string]$LogName) {
    $log = Join-Path $OutputDirectory $LogName
    $process = Start-Process msiexec.exe -ArgumentList @($Operation,('"'+$Package+'"'),'/qn','/norestart','GOMAPI_AUTO_UPDATE=0','/l*v',('"'+$log+'"')) -WindowStyle Hidden -PassThru
    $null = $process.Handle
    try {
        if (!$process.WaitForExit(180000)) { $process.Kill(); $null=$process.WaitForExit(5000); throw "MSI timed out: $LogName" }
        if ($process.ExitCode -ne 0) { throw "MSI exit $($process.ExitCode): $LogName" }
    } finally { $process.Dispose() }
}
function AssertInstalled($Release, $Manifest, [string]$Name) {
    $marker = Get-ItemProperty -LiteralPath $markerPath
    $registration = Get-ItemProperty -LiteralPath (Join-Path $uninstallPath ('{'+$Release.suite.productCode.Trim('{}')+'}'))
    if ($marker.SKU -cne 'suite' -or $marker.PackageRelease -cne $Release.version -or
        $marker.ServiceVersion -cne $Release.system.version -or $marker.InterceptorVersion -cne $Release.system.version -or
        $marker.AppVersion -cne $Release.version -or $marker.AutoUpdateEnabled -ne 0 -or
        $registration.DisplayVersion -cne $Release.suite.productVersion) { throw 'Installed package versions or Suite ownership differ' }
    $startup = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    if ($startup.'go-mapi-user-machine-v4' -cne ('"'+(Join-Path $productRoot 'user\go-mapi.exe')+'" --startup --machine-install')) { throw 'Machine App startup ownership differs' }
    $files = foreach ($part in $Manifest.components) { foreach ($artifact in $part.artifacts) {
        $relative = switch ($part.component) {
            'app' { 'user\go-mapi.exe' }
            'service' { 'service\go-mapi-service.exe' }
            'interceptor' { 'interceptor\'+$(if ($artifact.architecture -ceq 'x64') {'AMD64'} else {'x86'})+'\go-mapi.dll' }
            default { throw 'Unexpected Suite component' }
        }
        $path = Join-Path $productRoot $relative
        if ((Hash $path) -cne $artifact.sha256 -or (Get-Item -LiteralPath $path).VersionInfo.ProductVersion -cne $part.version) { throw "Installed hash/version differs: $relative" }
        [ordered]@{component=$part.component; architecture=$artifact.architecture; path=$path; version=$part.version; sha256=$artifact.sha256}
    } }
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        $service = Get-CimInstance Win32_Service -Filter "Name='go-mapi'"
        $statusFile = Join-Path $env:ProgramData 'go-mapi\status\status-v2.json'
        $status = if (Test-Path -LiteralPath $statusFile) { ReadJson $statusFile } else { $null }
        if ($service.State -eq 'Running' -and $status.health -ceq 'healthy' -and $status.packageVersion -ceq $Release.version) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($service.State -ne 'Running' -or $service.StartName -cne 'LocalSystem' -or $service.StartMode -ne 'Auto' -or
        $status.schema -cne 'go-mapi-public-status-v2' -or $status.health -cne 'healthy' -or
        $status.sku -cne 'suite' -or $status.packageVersion -cne $Release.version -or
        $status.serviceVersion -cne $Release.system.version -or $status.interceptorVersion -cne $Release.system.version -or
        $status.appVersion -cne $Release.version -or $status.updates -cne 'disabled') { throw 'Installed Suite service is not healthy' }
    WriteJson "$Name.json" ([ordered]@{version=$Release.version; system=$Release.system.version; productCode=$Release.suite.productCode; files=@($files); status=$status; service=$service | Select-Object Name,State,StartName,StartMode,PathName})
}
try {
    if ((Test-Path -LiteralPath $markerPath) -or (Get-Service go-mapi -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $productRoot)) { throw 'Guest already contains machine product state' }
    $sets = @()
    foreach ($name in @('prior','current')) {
        $root = Join-Path $InputDirectory $name
        $release = ReadJson (Join-Path $root 'release.json')
        $proof = ReadJson (Join-Path $root "suite-$($release.version).validation.json")
        $manifestPath = Join-Path $root "go-mapi-suite-$($release.version).manifest.json"
        $manifest = ReadJson $manifestPath
        $package = Join-Path $root $release.suite.artifact.file
        if ($release.schema -cne 'go-mapi-release-v1' -or $release.repository -cne 'marcfargas/go-mapi' -or
            $proof.schema -cne 'go-mapi-machine-validation-provenance-v1' -or $proof.publishable -ne $true -or $proof.sku -cne 'suite' -or
            $proof.packageRelease -cne $release.version -or $proof.commit -cne $release.commit -or
            [string]$proof.runId -cne [string]$release.runId -or [string]$proof.runAttempt -cne [string]$release.runAttempt -or
            $proof.validationTrust -cne 'windows-default' -or $proof.testTrust -or $proof.azure.account -cne 'lachispa' -or
            $proof.azure.certificateProfile -cne 'lachispa' -or $proof.azure.endpoint -cne 'https://weu.codesigning.azure.net/' -or
            $proof.signedInputManifest.sha256 -cne (Hash $manifestPath) -or
            $proof.msi.sha256 -cne (Hash $package) -or $release.suite.artifact.sha256 -cne $proof.msi.sha256 -or
            (Get-Item -LiteralPath $package).Length -ne $release.suite.artifact.size -or
            $manifest.sku -cne 'suite' -or $manifest.commit -cne $release.commit -or $manifest.packageRelease -cne $release.version -or
            (@($manifest.components.component | Sort-Object) -join ',') -cne 'app,interceptor,service') { throw 'Selected production Suite inputs differ' }
        AssertSignature $package $proof ([IO.Path]::GetFileName($package))
        $sets += @{release=$release; proof=$proof; manifest=$manifest; package=$package}
    }
    $old = $sets[0]; $new = $sets[1]
    if ($old.release.system.reused -or !$new.release.system.reused -or
        $new.release.system.manifestSha256 -cne (Hash (Join-Path $InputDirectory 'prior\release.json')) -or
        $new.release.suite.sequence -le $old.release.suite.sequence -or $new.release.suite.upgradeCode -cne $old.release.suite.upgradeCode) { throw 'Not an advancing same-family reused-System Suite' }
    foreach ($component in @('service','interceptor')) {
        $before = @($old.manifest.components | Where-Object component -ceq $component)[0]
        $after = @($new.manifest.components | Where-Object component -ceq $component)[0]
        if (($before | ConvertTo-Json -Depth 10 -Compress) -cne ($after | ConvertTo-Json -Depth 10 -Compress)) { throw "Reused $component payload changes" }
    }
    # Signature verification above may use normal Windows revocation/chain fetches.
    # Installation itself must succeed after every guest adapter is disabled.
    $adapters = @(Get-NetAdapter -IncludeHidden | Where-Object Status -ne 'Disabled')
    if (!$adapters.Count) { throw 'No guest adapter observed before offline trial' }
    $adapters | Disable-NetAdapter -Confirm:$false
    $remaining = @(Get-NetAdapter -IncludeHidden | Where-Object Status -eq 'Up')
    WriteJson 'offline.json' @{disabled=@($adapters | Select-Object Name,InterfaceGuid,Status); remainingUp=@($remaining | Select-Object Name,InterfaceGuid)}
    if ($remaining.Count) { throw 'Guest still has an active adapter' }
    $receipt.offline = $true
    $ownedProducts = @($old.release.suite.productCode,$new.release.suite.productCode)
    $attempted = $true
    InvokeMsi /i $old.package 'install-prior.log'
    $receipt.installed = $true
    AssertInstalled $old.release $old.manifest 'prior-installed'
    InvokeMsi /i $new.package 'upgrade-current.log'
    $receipt.upgraded = $true
    AssertInstalled $new.release $new.manifest 'current-installed'
    if (Test-Path -LiteralPath (Join-Path $uninstallPath ('{'+$old.release.suite.productCode.Trim('{}')+'}'))) { throw 'Prior Suite product remains registered after upgrade' }
    foreach ($part in $new.manifest.components) { foreach ($artifact in $part.artifacts) {
        $relative = switch ($part.component) { 'app' {'user\go-mapi.exe'} 'service' {'service\go-mapi-service.exe'} 'interceptor' {'interceptor\'+$(if ($artifact.architecture -ceq 'x64') {'AMD64'} else {'x86'})+'\go-mapi.dll'} }
        AssertSignature (Join-Path $productRoot $relative) $new.proof $artifact.filename
    } }
    $receipt.passed = $true
} catch { $receipt.error = $_.Exception.Message }
finally {
    if ($attempted) {
        foreach ($code in $ownedProducts) {
            $key = Join-Path $uninstallPath ('{'+$code.Trim('{}')+'}')
            if (Test-Path -LiteralPath $key) {
                try { InvokeMsi /x ('{'+$code.Trim('{}')+'}') ("remove-$code.log") } catch { $cleanupErrors.Add($_.Exception.Message) }
            }
        }
        if ((Test-Path -LiteralPath $markerPath) -or (Get-Service go-mapi -ErrorAction SilentlyContinue) -or
            (Test-Path -LiteralPath (Join-Path $productRoot 'user\go-mapi.exe')) -or
            (Test-Path -LiteralPath (Join-Path $productRoot 'service\go-mapi-service.exe')) -or
            (Test-Path -LiteralPath (Join-Path $productRoot 'interceptor\AMD64\go-mapi.dll')) -or
            (Test-Path -LiteralPath (Join-Path $productRoot 'interceptor\x86\go-mapi.dll'))) { $cleanupErrors.Add('Machine product remains after removal') }
        foreach ($code in $ownedProducts) {
            if (Test-Path -LiteralPath (Join-Path $uninstallPath ('{'+$code.Trim('{}')+'}'))) { $cleanupErrors.Add("Owned MSI registration remains: $code") }
        }
        $startup = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
        if ($startup.'go-mapi-user-machine-v4') { $cleanupErrors.Add('Suite machine startup remains') }
        $shortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\go-mapi\go-mapi.lnk'
        if (Test-Path -LiteralPath $shortcut) { $cleanupErrors.Add('Suite Start Menu shortcut remains') }
        $receipt.removed = $cleanupErrors.Count -eq 0
    }
    $receipt.cleanupErrors = @($cleanupErrors)
    $receipt.passed = $receipt.passed -and $receipt.removed -and !$cleanupErrors.Count
    WriteJson 'reused-suite-result.json' $receipt
}
if (!$receipt.passed) { throw "Reused Suite acceptance incomplete: $($receipt.error); $($cleanupErrors -join '; ')" }
