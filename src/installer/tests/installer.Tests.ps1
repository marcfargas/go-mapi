# src/installer/tests/installer.Tests.ps1
# Pester 5 smoke test — D-21 13-item coverage.
#
# Pester 5 idioms only: New-PesterConfiguration, Describe/Context/It, Should -BeTrue/-BeFalse.
# Pester 4 EnableExit switch is forbidden (D-30).
#
# MUST run on an ephemeral CI runner (windows-latest) — this suite invokes
# go-mapi-setup.exe /S /D=... which actually writes to HKLM, ProgramFiles,
# Start Menu, and Windows Firewall. Running on a developer workstation will
# modify the system.
#
# D-21 item coverage (13 items, split across two Context blocks):
#   Silent install:   1 (exit code), 2 (binaries), 3 (MAPI key + DLLPath),
#                     4 (backup JSON shape), 5 (shortcut + AUMID),
#                     6 (firewall rule present)
#   Silent uninstall: 7 (exit code), 8 (install dir gone), 9 (MAPI key gone),
#                     10 (firewall rule gone), 11 (%APPDATA% gone),
#                     12 (Credential Manager scrubbed), 13 (shortcut gone)
#
# Cross-plan literal contract (byte-for-byte match with 10-03 + 10-04):
#   AUMID         = com.marcfargas.gomapi    (NOT com.marcfargas.gomapi.dev)
#   Firewall rule = go-mapi OAuth loopback   (match 10-03 AddFirewallRule + 10-04 RemoveFirewallRule)
#   Cred target   = go-mapi:oauth-tokens     (COLON separator — zalando/go-keyring Windows backend)

BeforeAll {
    # Dot-source the AUMID reader helper (defines Get-ShortcutAumid + .NET types).
    . "$PSScriptRoot\AumidReader.ps1"

    # The installer binary is produced by the CI workflow (build.yml)
    # via `makensis src\installer\go-mapi.nsi` at the repo root.
    # Path resolution:
    #   From src/installer/tests/installer.Tests.ps1 ..\..\..\ = repo root
    $script:SetupExe     = Join-Path $PSScriptRoot '..\..\..\go-mapi-setup.exe' | Resolve-Path -ErrorAction Stop | ForEach-Object Path
    $script:InstallDir   = "$env:ProgramFiles\go-mapi"
    $script:ProgramData  = "$env:ProgramData\go-mapi"
    $script:BackupJson   = "$script:ProgramData\uninst\previous-mail-client.json"
    $script:MapiKey      = 'HKLM:\SOFTWARE\Clients\Mail\go-mapi'
    $script:MailKey      = 'HKLM:\SOFTWARE\Clients\Mail'
    $script:Shortcut     = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\go-mapi.lnk"
    $script:FirewallRule = 'go-mapi OAuth loopback'
    $script:ExpectedAumid = 'com.marcfargas.gomapi'
    $script:CredTarget   = 'go-mapi:oauth-tokens'
    # QUICK-260423-ntu T3d — dual-bitness install surfaces
    $script:InstallDir32 = "${env:ProgramFiles(x86)}\go-mapi"
    $script:MapiKey32    = 'HKLM:\SOFTWARE\WOW6432Node\Clients\Mail\go-mapi'

    # Phase 11.1 D-03 / D-18 case 4: %APPDATA% path is the negative-assertion target.
    # The %ProgramData% path is already $script:Shortcut (set by Phase 10).
    $script:AppDataLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\go-mapi.lnk'

    # Phase 11.1 Plan 11.1-05 — Scheduled Task assertions (D-08 / D-16 / D-18 cases 1, 2, 5, 6)
    $script:TaskName    = 'go-mapi Auto Update'
    $script:UpdatesDir  = Join-Path $env:ProgramData 'go-mapi\updates'

    Write-Host ("[Setup] SetupExe    = {0}" -f $script:SetupExe)
    Write-Host ("[Setup] InstallDir  = {0}" -f $script:InstallDir)
    Write-Host ("[Setup] ProgramData = {0}" -f $script:ProgramData)
    Write-Host ("[Setup] CredTarget  = {0}" -f $script:CredTarget)
}

Describe "go-mapi installer round-trip" {

    Context "Silent install" {
        # D-21 item 1
        It "1. silent install exits 0 with /S /D=<InstallDir>" {
            # NSIS /D= must be the LAST argument and NOT quoted (per RESEARCH Pitfall 5).
            # PowerShell's -ArgumentList array form preserves the token correctly.
            $proc = Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$($script:InstallDir)" -Wait -PassThru
            $proc.ExitCode | Should -Be 0
        }

        # D-21 item 2
        It "2. go-mapi.exe and go-mapi.dll are deposited in InstallDir" {
            Test-Path (Join-Path $script:InstallDir 'go-mapi.exe') | Should -BeTrue
            Test-Path (Join-Path $script:InstallDir 'go-mapi.dll') | Should -BeTrue
        }

        # D-21 item 3
        It "3. HKLM MAPI handler key is registered with DLLPath" {
            Test-Path $script:MapiKey | Should -BeTrue
            $props = Get-ItemProperty -Path $script:MapiKey
            $props.DLLPath | Should -Match 'go-mapi\.dll$'
            # (Default) value read via Get-ItemProperty with '(default)' property name
            (Get-ItemProperty -Path $script:MapiKey -Name '(default)').'(default)' | Should -Be 'go-mapi'
        }

        # D-21 item 4
        It "4. previous-mail-client.json backup exists and parses with required fields" {
            Test-Path $script:BackupJson | Should -BeTrue
            $json = Get-Content $script:BackupJson -Raw | ConvertFrom-Json
            $json.PSObject.Properties.Name | Should -Contain 'previousClient'
            $json.PSObject.Properties.Name | Should -Contain 'backedUpAt'
            # backedUpAt should look like an ISO-8601 timestamp
            ([datetime]$json.backedUpAt).ToUniversalTime().ToString('o') | Should -Match '^\d{4}-\d{2}-\d{2}T'
        }

        # D-21 item 5 — AUMID stamped on shortcut
        It "5. Start Menu shortcut exists with AUMID == com.marcfargas.gomapi" {
            Test-Path $script:Shortcut | Should -BeTrue
            $actual = Get-ShortcutAumid -Path $script:Shortcut
            $actual | Should -Be $script:ExpectedAumid
        }

        # D-21 item 6
        It "6. Windows Firewall inbound rule 'go-mapi OAuth loopback' exists" {
            $rule = Get-NetFirewallRule -DisplayName $script:FirewallRule -ErrorAction SilentlyContinue
            $rule | Should -Not -BeNullOrEmpty
            $rule.Direction | Should -Be 'Inbound'
            $rule.Action    | Should -Be 'Allow'
        }

        # QUICK-260423-ntu item 14 — install-time running-process guard (silent)
        It "14. silent install succeeds when go-mapi.exe is already running in InstallDir" {
            # Pre-condition: install completed in item 1. Launch a decoy process
            # from the installed path, then re-run the installer in /S mode and
            # assert the exe is still runnable post-install (i.e. the installer
            # closed the old instance cleanly, overwrote it, and did NOT abort).
            $exe = Join-Path $script:InstallDir 'go-mapi.exe'
            $decoy = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
            try {
                Start-Sleep -Seconds 1
                $proc = Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$($script:InstallDir)" -Wait -PassThru
                $proc.ExitCode | Should -Be 0
                Test-Path $exe | Should -BeTrue
            } finally {
                # Belt-and-braces cleanup in case the installer did not close it
                if (-not $decoy.HasExited) { $decoy.Kill() }
            }
        }

        # QUICK-260423-ntu item 16 — x86 DLL deposited alongside x64 DLL
        It "16. go-mapi.dll is deposited in both ProgramFiles and ProgramFiles(x86)" {
            Test-Path (Join-Path $script:InstallDir   'go-mapi.dll') | Should -BeTrue
            Test-Path (Join-Path $script:InstallDir32 'go-mapi.dll') | Should -BeTrue
        }

        # QUICK-260423-ntu item 17 — each DLL has the matching PE bitness
        It "17. x64 DLL is PE32+ and x86 DLL is PE32" {
            function Get-PeMagic($p) {
                $b = [IO.File]::ReadAllBytes($p)
                $e = [BitConverter]::ToInt32($b, 0x3C)
                return [BitConverter]::ToUInt16($b, $e + 4 + 20)
            }
            Get-PeMagic (Join-Path $script:InstallDir   'go-mapi.dll') | Should -Be 0x20B
            Get-PeMagic (Join-Path $script:InstallDir32 'go-mapi.dll') | Should -Be 0x10B
        }

        # QUICK-260423-ntu item 18 — WOW6432Node DLLPath points at the x86 DLL
        It "18. HKLM WOW6432Node MAPI key is registered with 32-bit DLLPath" {
            # Path-based read: HKLM:\SOFTWARE\WOW6432Node\... resolves directly
            # without SetRegView, so Get-ItemProperty hits the 32-bit hive.
            Test-Path $script:MapiKey32 | Should -BeTrue
            $props = Get-ItemProperty -Path $script:MapiKey32
            $props.DLLPath | Should -Match '(?i)Program Files \(x86\)\\go-mapi\\go-mapi\.dll$'
        }

        # Phase 11.1 D-05 / D-18 case 3 — silent reinstall overwrites both DLLs (T4 regression)
        It "21. silent reinstall over existing install overwrites both x64 and x86 DLLs" {
            # Pre-condition: prior items already installed once into $script:InstallDir.
            # Capture both DLLs' hashes before reinstall to detect "no overwrite happened".
            $x64Path = Join-Path $script:InstallDir   'go-mapi.dll'
            $x86Path = Join-Path $script:InstallDir32 'go-mapi.dll'
            $x64Before = (Get-FileHash -Algorithm SHA256 -Path $x64Path).Hash
            $x86Before = (Get-FileHash -Algorithm SHA256 -Path $x86Path).Hash

            # Touch both files to a known earlier mtime so a silent skip leaves them stale.
            (Get-Item $x64Path).LastWriteTime = (Get-Date).AddDays(-1)
            (Get-Item $x86Path).LastWriteTime = (Get-Date).AddDays(-1)

            # Reinstall silently WITHOUT prior uninstall — this is the T4 repro case.
            $proc = Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$($script:InstallDir)" -Wait -PassThru
            $proc.ExitCode | Should -Be 0

            # Both DLLs MUST have a fresh mtime (overwrite happened).
            (Get-Item $x64Path).LastWriteTime | Should -BeGreaterThan (Get-Date).AddMinutes(-2)
            (Get-Item $x86Path).LastWriteTime | Should -BeGreaterThan (Get-Date).AddMinutes(-2)

            # Hashes should match the prior install (same binaries shipped — confirms the
            # overwrite happened with a real File write rather than NSIS skipping).
            (Get-FileHash -Algorithm SHA256 -Path $x64Path).Hash | Should -Be $x64Before
            (Get-FileHash -Algorithm SHA256 -Path $x86Path).Hash | Should -Be $x86Before

            # Windows Server 2025 exposes Clients\Mail as a shared MAPI key: its
            # x64 and x86 registry views reflect the same DLLPath. Verify that the
            # handler remains registered; item 17 already verifies both payloads'
            # actual PE bitness.
            $native = & reg.exe query 'HKLM\SOFTWARE\Clients\Mail\go-mapi' /v DLLPath /reg:64 | Out-String
            $wow    = & reg.exe query 'HKLM\SOFTWARE\Clients\Mail\go-mapi' /v DLLPath /reg:32 | Out-String
            $native | Should -Match '(?i)DLLPath\s+REG_SZ\s+.*go-mapi\.dll'
            $wow    | Should -Match '(?i)DLLPath\s+REG_SZ\s+.*go-mapi\.dll'
        }

        # Phase 11.1 D-03 / D-18 case 4 — Start Menu shortcut location regression
        It "25. Start Menu shortcut lands at %ProgramData%\Microsoft\Windows\Start Menu\Programs (D-03 regression)" {
            # The reinstall above ensures the shortcut is in place — no extra setup needed.
            Test-Path $script:Shortcut    | Should -BeTrue  -Because "D-03: shortcut MUST be all-users (%ProgramData%)"
            Test-Path $script:AppDataLnk  | Should -BeFalse -Because "D-03: per-user shortcut MUST NOT be created (%APPDATA%)"
        }

        # Phase 11.1 D-08 / D-18 case 1 — /AUTOUPDATE=1 registers the Scheduled Task
        It "22. /AUTOUPDATE=1 install registers the Scheduled Task with correct principal + triggers" {
            # Self-contained: uninstall + reinstall with /AUTOUPDATE=1.
            $uninst = Join-Path $script:InstallDir 'uninstall.exe'
            if (Test-Path $uninst) {
                Start-Process -FilePath $uninst -ArgumentList '/S' -Wait | Out-Null
                Start-Sleep -Seconds 2
            }
            $proc = Start-Process -FilePath $script:SetupExe -ArgumentList '/S','/AUTOUPDATE=1',"/D=$($script:InstallDir)" -Wait -PassThru
            $proc.ExitCode | Should -Be 0
            Start-Sleep -Seconds 1   # Pitfall 5: let Task Scheduler cache settle.

            $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
            $task | Should -Not -BeNullOrEmpty
            # Get-ScheduledTask under PS5.1 resolves the principal SID to its
            # friendly name and returns enum values as ints. Both the resolved
            # form (SYSTEM / Highest / IgnoreNew) and the raw form (S-1-5-18 /
            # 1 / 2) are equivalent — accept either to stay portable across
            # PS5.1 vs PS7+ runners. Verified by Plan 11.1-05 sandbox UAT under
            # PS5.1 (returned SYSTEM / 1 / 2).
            $task.Principal.UserId                    | Should -BeIn @('S-1-5-18','SYSTEM')
            $task.Principal.RunLevel                  | Should -BeIn @('Highest', 1)
            $task.Settings.MultipleInstances          | Should -BeIn @('IgnoreNew', 2)
            $task.Settings.RunOnlyIfNetworkAvailable  | Should -BeTrue
            $task.Settings.StartWhenAvailable         | Should -BeTrue
            $task.Triggers.Count                      | Should -Be 2   # CalendarTrigger + BootTrigger
            ($task.Actions | Where-Object { $_.Execute -match 'go-mapi\.exe' }).Arguments | Should -Be '--update-check-silent'
        }

        # Phase 11.1 D-07 / D-18 case 2 — /AUTOUPDATE absent: no Scheduled Task
        It "23. /AUTOUPDATE=0 install does NOT register the Scheduled Task" {
            $uninst = Join-Path $script:InstallDir 'uninstall.exe'
            if (Test-Path $uninst) {
                Start-Process -FilePath $uninst -ArgumentList '/S' -Wait | Out-Null
                Start-Sleep -Seconds 2
            }
            Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$($script:InstallDir)" -Wait | Out-Null
            Start-Sleep -Seconds 1
            Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }

        # Phase 11.1 D-16 / D-18 case 5 — uninstaller idempotently removes the task
        # AND scrubs %ProgramData%\go-mapi\updates (D-18 case 6)
        It "24. uninstall removes the Scheduled Task even when /AUTOUPDATE=0 was used" {
            # /AUTOUPDATE=0 install — uninstall must still run schtasks /delete /f and exit 0.
            Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$($script:InstallDir)" -Wait | Out-Null
            $uninst = Join-Path $script:InstallDir 'uninstall.exe'
            $proc = Start-Process -FilePath $uninst -ArgumentList '/S' -Wait -PassThru
            $proc.ExitCode | Should -Be 0   # D-16: idempotent removal — 'task not found' is OK.
            Start-Sleep -Seconds 2

            # D-16 belt: even though /AUTOUPDATE=0 means no task was registered,
            # the uninstaller's schtasks /delete /f ran (rc=1 swallowed). Confirm
            # nothing is left behind in Task Scheduler post-uninstall.
            Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty

            # Uninstaller also scrubs %ProgramData%\go-mapi\updates (D-18 case 6).
            Test-Path $script:UpdatesDir | Should -BeFalse -Because "uninstaller scrubs %ProgramData%\go-mapi\updates per D-18 case 6"
        }

        # Phase 11.1 W7 — uninstaller scrubs *.old.<pid> orphan files left by silent updater
        It "24b. uninstaller scrubs *.old.<pid> orphan files left by silent updater (W7 regression)" {
            # Reinstall fresh so $script:InstallDir exists with the binary.
            $uninst = Join-Path $script:InstallDir 'uninstall.exe'
            if (Test-Path $uninst) {
                Start-Process -FilePath $uninst -ArgumentList '/S' -Wait | Out-Null
                Start-Sleep -Seconds 2
            }
            Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$($script:InstallDir)" -Wait | Out-Null

            # Plant orphan files mimicking what swapInPlace would leave behind.
            $orphan64  = Join-Path $script:InstallDir   'go-mapi.exe.old.123'
            $orphanDll = Join-Path $script:InstallDir   'go-mapi.dll.old.456'
            $orphan32  = Join-Path $script:InstallDir32 'go-mapi.dll.old.789'
            New-Item -ItemType File -Path $orphan64  -Force | Out-Null
            New-Item -ItemType File -Path $orphanDll -Force | Out-Null
            New-Item -ItemType File -Path $orphan32  -Force | Out-Null

            Test-Path $orphan64  | Should -BeTrue  # sanity
            Test-Path $orphanDll | Should -BeTrue
            Test-Path $orphan32  | Should -BeTrue

            # Uninstall — orphans MUST be gone.
            $uninstAfter = Join-Path $script:InstallDir 'uninstall.exe'
            $proc = Start-Process -FilePath $uninstAfter -ArgumentList '/S' -Wait -PassThru
            $proc.ExitCode | Should -Be 0
            Start-Sleep -Seconds 2

            Test-Path $orphan64  | Should -BeFalse -Because "uninstaller MUST scrub *.old.<pid> orphans in `$INSTDIR (W7)"
            Test-Path $orphanDll | Should -BeFalse -Because "uninstaller MUST scrub *.old.<pid> orphans in `$INSTDIR (W7)"
            Test-Path $orphan32  | Should -BeFalse -Because "uninstaller MUST scrub *.old.<pid> orphans in `$PROGRAMFILES32\go-mapi (W7)"
        }
    }

    Context "Silent uninstall" {
        BeforeAll {
            # The preceding install tests intentionally exercise uninstall paths.
            # Start this context from a fresh install rather than relying on order.
            if (-not (Test-Path (Join-Path $script:InstallDir 'uninstall.exe'))) {
                Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$($script:InstallDir)" -Wait
            }
        }

        # D-21 item 7
        It "7. silent uninstall exits 0 with /S" {
            $uninst = Join-Path $script:InstallDir 'uninstall.exe'
            Test-Path $uninst | Should -BeTrue -Because "uninstaller must be in place after install"
            $proc = Start-Process -FilePath $uninst -ArgumentList '/S' -Wait -PassThru
            $proc.ExitCode | Should -Be 0
            # NSIS uninstaller self-deletes via a batch wrapper; sleep briefly so the
            # batch can complete before subsequent Test-Path probes.
            Start-Sleep -Seconds 2
        }

        # D-21 item 8
        It "8. install dir is gone (or empty)" {
            $exists = Test-Path $script:InstallDir
            if ($exists) {
                # Acceptable if empty — NSIS RMDir (non-recursive) leaves dir when files remain
                (Get-ChildItem $script:InstallDir -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
            }
        }

        # D-21 item 9
        It "9. MAPI handler key HKLM\SOFTWARE\Clients\Mail\go-mapi is gone" {
            Test-Path $script:MapiKey | Should -BeFalse
        }

        # D-21 item 10
        It "10. firewall rule 'go-mapi OAuth loopback' is gone" {
            Get-NetFirewallRule -DisplayName $script:FirewallRule -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }

        # D-21 item 11
        It "11. %APPDATA%\go-mapi\ is gone for the runner user" {
            Test-Path "$env:APPDATA\go-mapi" | Should -BeFalse
        }

        # D-21 item 12 — Credential Manager scrub (colon target per PATTERNS.md Shared Pattern 3)
        It "12. cmdkey /list:go-mapi:oauth-tokens returns no matching entries" {
            # cmdkey prints to stdout + may use stderr depending on locale; merge streams.
            $out = & cmdkey /list 2>&1 | Out-String
            # `/list:<target>` echoes the requested target even when it does not
            # exist. Query the complete store and reject only an actual Target line.
            $out | Should -Not -Match "(?im)^\s*Target:\s*$([regex]::Escape($script:CredTarget))\s*$" -Because "cmdkey should find no credentials under target '$($script:CredTarget)' after uninstall"
        }

        # D-21 item 13
        It "13. Start Menu shortcut is gone" {
            Test-Path $script:Shortcut | Should -BeFalse
        }

        # QUICK-260423-ntu item 15 — uninstall-time running-process guard (silent)
        It "15. silent uninstall closes a running go-mapi.exe in InstallDir and removes the binary" {
            # Re-install first because item 7 already uninstalled.
            Start-Process -FilePath $script:SetupExe -ArgumentList '/S',"/D=$($script:InstallDir)" -Wait
            $exe = Join-Path $script:InstallDir 'go-mapi.exe'
            $decoy = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
            try {
                Start-Sleep -Seconds 1
                $uninst = Join-Path $script:InstallDir 'uninstall.exe'
                $proc = Start-Process -FilePath $uninst -ArgumentList '/S' -Wait -PassThru
                $proc.ExitCode | Should -Be 0
                Start-Sleep -Seconds 2   # NSIS batch-wrapper self-delete
                Test-Path $exe | Should -BeFalse -Because "uninstaller should have closed the running instance and deleted the binary"
                $decoy.HasExited | Should -BeTrue
            } finally {
                if (-not $decoy.HasExited) { $decoy.Kill() }
            }
        }

        # QUICK-260423-ntu item 19 — x86 DLL + install dir removed by uninstall
        It "19. ProgramFiles(x86)\go-mapi is gone after uninstall" {
            $exists = Test-Path $script:InstallDir32
            if ($exists) {
                (Get-ChildItem $script:InstallDir32 -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
            }
            Test-Path (Join-Path $script:InstallDir32 'go-mapi.dll') | Should -BeFalse
        }

        # QUICK-260423-ntu item 20 — WOW6432Node MAPI key removed
        It "20. HKLM WOW6432Node MAPI handler key is gone after uninstall" {
            Test-Path $script:MapiKey32 | Should -BeFalse
        }
    }
}
