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

    # The installer binary is produced by the CI workflow (installer-smoke.yml)
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
            $json.backedUpAt | Should -Match '^\d{4}-\d{2}-\d{2}T'
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
    }

    Context "Silent uninstall" {
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
            $out = & cmdkey /list:$script:CredTarget 2>&1 | Out-String
            # cmdkey output contains 'Target:' lines when an entry matches, or a
            # "NONE" / locale-dependent "no credentials" message when nothing matches.
            # Safe assertion: no line containing the literal target string.
            $out | Should -Not -Match ([regex]::Escape($script:CredTarget)) -Because "cmdkey should find no credentials under target '$($script:CredTarget)' after uninstall"
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
    }
}
