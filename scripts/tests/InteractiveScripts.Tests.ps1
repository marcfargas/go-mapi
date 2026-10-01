# Off-desktop checks for the interactive test scripts: parse, ci.yml drift,
# no Ticket/CrabBox residue, and run-gui-install-check.ps1 logic against a stub
# cua-driver. Needs no desktop and no network; runs on Linux or Windows pwsh.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$native = Join-Path $repo 'scripts/run-interactive-native-tests.ps1'
$gui = Join-Path $repo 'scripts/run-gui-install-check.ps1'
$ciYml = Join-Path $repo '.github/workflows/ci.yml'

# 1. Both scripts parse.
foreach ($path in @($native, $gui)) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) "$path does not parse: $(if ($errors.Count) { $errors[0].ToString() })"
}

# 2. The native script's go test line is identical to the ci.yml go-race command.
function Get-RaceCommand([string]$Path) {
    $found = @(Get-Content -LiteralPath $Path | ForEach-Object {
        if ($_ -match '^\s*(?:-\s*run:\s*)?(go test -race -v .+?)\s*$') { $Matches[1] }
    })
    Assert ($found.Count -eq 1) "expected exactly one 'go test -race -v' line in $Path, found $($found.Count)"
    return $found[0]
}
$ciCommand = Get-RaceCommand $ciYml
$scriptCommand = Get-RaceCommand $native
Assert ([string]::Equals($ciCommand, $scriptCommand, [StringComparison]::Ordinal)) "go test drift: ci.yml has '$ciCommand', script has '$scriptCommand'"

# 3. No Ticket, CrabBox or lease residue in either script, in any case and in
#    headers and code (this also bans Release, Please, leases, CrabBox).
foreach ($path in @($native, $gui)) {
    $hits = @(Select-String -LiteralPath $path -Pattern 'gm47[0-9]|go-mapi-4[0-9]{2}-native|/tmp/gm-workers|crabbox|lease')
    Assert ($hits.Count -eq 0) "residue in ${path}: $(($hits | ForEach-Object { "$($_.LineNumber): $($_.Line.Trim())" }) -join '; ')"
}

# 4. run-gui-install-check.ps1 against a stub cua-driver.
$temp = Join-Path ([IO.Path]::GetTempPath()) ('go-mapi-interactive-' + [guid]::NewGuid().ToString('N'))
$oldScenario = $env:STUB_CUA_SCENARIO
$oldDir = $env:STUB_CUA_DIR
try {
    New-Item -ItemType Directory -Force $temp | Out-Null
    $stubScript = Join-Path $temp 'stub-cua-driver.ps1'
    Set-Content -LiteralPath $stubScript -Value @'
$ErrorActionPreference = 'Stop'
$tool = $args[1]
$payload = [Console]::In.ReadToEnd().Trim()
Add-Content -LiteralPath (Join-Path $env:STUB_CUA_DIR 'calls.log') -Value "$tool $payload"
$scenario = $env:STUB_CUA_SCENARIO
if ($scenario -eq 'warning') { [Console]::Error.WriteLine("warning: stub $tool notice") }
$desk = @{ app_name = 'explorer.exe'; title = 'Program Manager'; pid = 10; window_id = 100 }
$folder = @{ app_name = 'explorer.exe'; title = 'Documents'; pid = 10; window_id = 200 }
$other = @{ app_name = 'notepad.exe'; title = 'Untitled'; pid = 20; window_id = 300 }
$new = @{ app_name = 'explorer.exe'; title = 'Home'; pid = 10; window_id = 400 }
switch ($tool) {
    'list_windows' {
        $counter = Join-Path $env:STUB_CUA_DIR 'list.count'
        $n = if (Test-Path -LiteralPath $counter) { [int](Get-Content -LiteralPath $counter -Raw) + 1 } else { 1 }
        Set-Content -LiteralPath $counter -Value $n
        $windows = @($desk, $folder, $other)
        if ($scenario -eq 'twodesktops') { $windows += @{ app_name = 'explorer.exe'; title = 'Program Manager'; pid = 11; window_id = 101 } }
        if ($scenario -eq 'nodesktop') { $windows = @($folder, $other) }
        if ($n -ge 2 -and $scenario -ne 'nonew') { $windows += $new }
        @{ windows = $windows } | ConvertTo-Json -Compress -Depth 5
    }
    'hotkey' {
        if ($scenario -eq 'exitcode') { [Console]::Error.WriteLine('stub hotkey failed'); exit 5 }
        if ($scenario -eq 'iserror') { '{"isError":true,"content":"stub failure"}' } else { '{"ok":true}' }
    }
    default { [Console]::Error.WriteLine("unknown tool $tool"); exit 2 }
}
exit 0
'@
    $onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    if ($onWindows) {
        $stub = Join-Path $temp 'stub-cua-driver.cmd'
        Set-Content -LiteralPath $stub -Value "@pwsh -NoProfile -File `"$stubScript`" %*"
    } else {
        $stub = Join-Path $temp 'stub-cua-driver'
        Set-Content -LiteralPath $stub -Value "#!/bin/sh`nexec pwsh -NoProfile -File '$stubScript' `"`$@`""
        & chmod +x $stub
        Assert ($LASTEXITCODE -eq 0) 'chmod failed'
    }

    function Invoke-GuiCheck([string]$Scenario) {
        $caseDir = Join-Path $temp $Scenario
        New-Item -ItemType Directory -Force $caseDir | Out-Null
        $env:STUB_CUA_SCENARIO = $Scenario
        $env:STUB_CUA_DIR = $caseDir
        $ErrorActionPreference = 'Continue'
        $output = & pwsh -NoProfile -File $gui -Session 'test-session' -Driver $stub -SkipDelay 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $calls = @(Get-Content -LiteralPath (Join-Path $caseDir 'calls.log') -ErrorAction SilentlyContinue)
        return [pscustomobject]@{ Code = $code; Output = $output; Calls = $calls }
    }

    # (a) A new Explorer window appears: success. Responses without isError must not trip StrictMode.
    $r = Invoke-GuiCheck 'ok'
    Assert ($r.Code -eq 0) "ok: expected exit 0, got $($r.Code). $($r.Output)"
    Assert ($r.Output -match "Explorer window opened: 'Home' \(window_id 400\)") "ok: missing success line. $($r.Output)"
    Assert ($r.Calls.Count -eq 3 -and $r.Calls[0] -eq 'list_windows {}' -and $r.Calls[2] -eq 'list_windows {}') "ok: unexpected call sequence: $($r.Calls -join ' | ')"
    $hotkey = ($r.Calls[1] -replace '^hotkey ', '') | ConvertFrom-Json
    Assert ($r.Calls[1] -like 'hotkey *' -and $hotkey.pid -eq 10 -and $hotkey.window_id -eq 100 -and
        $hotkey.session -eq 'test-session' -and (@($hotkey.keys) -join '+') -eq 'win+e') "ok: unexpected hotkey payload: $($r.Calls[1])"

    # (b) The driver returns isError with exit 0: failure.
    $r = Invoke-GuiCheck 'iserror'
    Assert ($r.Code -ne 0) 'iserror: expected non-zero exit'
    Assert ($r.Output -match 'cua-driver hotkey returned isError') "iserror: missing isError message. $($r.Output)"

    # (c) stderr has only warning: lines: success.
    $r = Invoke-GuiCheck 'warning'
    Assert ($r.Code -eq 0) "warning: expected exit 0, got $($r.Code). $($r.Output)"

    # (d) No new Explorer window appears: failure.
    $r = Invoke-GuiCheck 'nonew'
    Assert ($r.Code -ne 0) 'nonew: expected non-zero exit'
    Assert ($r.Output -match 'No new Explorer window appeared') "nonew: missing message. $($r.Output)"

    # (e) Not exactly one Program Manager window: failure, and no hotkey is sent.
    foreach ($scenario in @('nodesktop', 'twodesktops')) {
        $r = Invoke-GuiCheck $scenario
        Assert ($r.Code -ne 0) "${scenario}: expected non-zero exit"
        Assert ($r.Output -match 'Expected one Explorer desktop window') "${scenario}: missing message. $($r.Output)"
        Assert (@($r.Calls | Where-Object { $_ -like 'hotkey *' }).Count -eq 0) "${scenario}: hotkey was sent"
    }

    # A non-zero driver exit code is a failure.
    $r = Invoke-GuiCheck 'exitcode'
    Assert ($r.Code -ne 0) 'exitcode: expected non-zero exit'
    Assert ($r.Output -match 'cua-driver hotkey exited 5\. stub hotkey failed') "exitcode: missing message. $($r.Output)"
} finally {
    $env:STUB_CUA_SCENARIO = $oldScenario
    $env:STUB_CUA_DIR = $oldDir
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'InteractiveScripts tests passed'
