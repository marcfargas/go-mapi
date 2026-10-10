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
