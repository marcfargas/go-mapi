$ErrorActionPreference='Stop'
$statement="Import-Module -Name ([IO.Path]::Combine(`$PSHOME,'Modules','Microsoft.PowerShell.Utility','Microsoft.PowerShell.Utility.psd1')) -ErrorAction Stop"
foreach($name in @('hosted-capability-recovery.ps1','hosted-capability-recovery-worker.ps1')){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "Recovery source parse failed: $name"}
    $imports=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -ceq $statement},$true))
    $hashes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Get-FileHash'},$true))
    if($imports.Count -ne 1 -or !$hashes.Count -or $imports[0].Extent.EndOffset -ge $hashes[0].Extent.StartOffset){throw "Inbox import missing or late: $name"}
    if($name -ceq 'hosted-capability-recovery.ps1'){
        $outer=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
        if($outer.Count -ne 1 -or $outer[0].Body.Statements[0].Extent.Text -cne $statement){throw 'Launcher inbox import is not first inside try'}
    }else{
        $statements=$ast.EndBlock.Statements
        $index=@(0..($statements.Count-1)|Where-Object {$statements[$_].Extent.Text -ceq $statement})
        if($index.Count -ne 1 -or !$statements[$index[0]+1].Extent.Text.StartsWith('$actualWorkerSHA256=(Get-FileHash')){throw 'Worker inbox import is not immediately before hash'}
    }
    $changes=@($ast.FindAll({param($n)($n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ieq '$env:PSModulePath') -or ($n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Import-Module' -and $n.Extent.Text -match 'CimCmdlets')},$true))
    if($changes.Count){throw 'Recovery resolver correction changed PSModulePath or imports CIM'}
    Write-Output "RECOVERY_INBOX_UTILITY_SOURCE_ORDER_PASSED script=$name"
}
# Run the production import against this host's inbox module and compare a
# real file digest with an independent .NET SHA-256 calculation.
. ([scriptblock]::Create($statement))
$path=Join-Path ([IO.Path]::GetTempPath()) ('t569-utility-'+[guid]::NewGuid().ToString('N'))
$sha=[Security.Cryptography.SHA256]::Create()
try{
    $bytes=[Text.Encoding]::UTF8.GetBytes("ticket569 inbox utility hash fixture`n")
    [IO.File]::WriteAllBytes($path,$bytes)
    $expected=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if($actual -cne $expected){throw 'Inbox Get-FileHash differs from .NET SHA-256'}
    Write-Output 'RECOVERY_INBOX_UTILITY_REAL_IMPORT_HASH_PASSED;PWSH_ACTUAL_WINDOWS_DESKTOP_UNRUN'
}finally{$sha.Dispose();if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}

# The worker and adjacent RemoveOwned CLI must prepare their own runtime's
# Certificate provider before actual CurrentUser Root reads, inside their catch.
$securityStatement=@'
Import-Module -Name ([IO.Path]::Combine($PSHOME,'Modules','Microsoft.PowerShell.Security','Microsoft.PowerShell.Security.psd1')) -ErrorAction Stop
'@
foreach($name in @('hosted-capability-recovery-worker.ps1','hosted-root-import.ps1')){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "Certificate source parse failed: $name"}
    $imports=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -ceq $securityStatement},$true))
    $reads=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Get-ChildItem' -and $n.Extent.Text.Contains('Cert:\CurrentUser\Root')},$true)|Sort-Object {$_.Extent.StartOffset})
    $outer=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text.Contains($securityStatement)})
    if($imports.Count -ne 1 -or !$reads.Count -or $outer.Count -ne 1 -or $imports[0].Extent.StartOffset -le $outer[0].Body.Extent.StartOffset -or $imports[0].Extent.EndOffset -ge $reads[0].Extent.StartOffset){throw "Runtime Security import is missing/late/outside failure catch: $name"}
    $boundary=[scriptblock]::Create($imports[0].Extent.Text+[Environment]::NewLine+$reads[0].Extent.Text)
    foreach($fault in @($false,$true)){
        & {
            param($Boundary,$Fault,$ScriptName)
            $script:providerReady=$false;$script:certificateRead=$false
            function Import-Module {param($Name,$ErrorAction)
                if($Name -cne [IO.Path]::Combine($PSHOME,'Modules','Microsoft.PowerShell.Security','Microsoft.PowerShell.Security.psd1') -or $ErrorAction -cne 'Stop'){throw 'Certificate import used another runtime or swallowed failures'}
                if($Fault){throw [InvalidOperationException]::new('Injected Security import failure')}
                $script:providerReady=$true
            }
            function Get-ChildItem {param($Path,$ErrorAction)
                $script:certificateRead=$true
                if(!$script:providerReady -or $Path -cne 'Cert:\CurrentUser\Root' -or $ErrorAction -cne 'Stop'){throw 'Certificate read preceded provider preparation or changed store'}
                @()
            }
            $caught=$null;try{. $Boundary}catch{$caught=$_}
            if(($Fault -and (!$caught -or $script:certificateRead)) -or (!$Fault -and ($caught -or !$script:certificateRead))){throw 'Actual Certificate import/read boundary lost fail-closed ordering'}
            Write-Output "RECOVERY_INBOX_SECURITY_BOUNDARY script=$ScriptName importFault=$Fault certificateRead=$script:certificateRead;PROVIDER_ADAPTER"
        } $boundary $fault $name
    }
}
. ([scriptblock]::Create($securityStatement))
if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
    $null=Get-PSProvider -PSProvider Certificate -ErrorAction Stop
    $null=Get-ChildItem -LiteralPath 'Cert:\CurrentUser\Root' -ErrorAction Stop
    Write-Output 'RECOVERY_INBOX_SECURITY_REAL_CURRENTUSER_READ_PASSED;CURRENT_TEST_TOKEN_NOT_CREDENTIAL_WORKER'
}else{
    Write-Output 'RECOVERY_INBOX_SECURITY_REAL_IMPORT_PASSED;WINDOWS_CERTIFICATE_PROVIDER_READ_UNRUN'
}
