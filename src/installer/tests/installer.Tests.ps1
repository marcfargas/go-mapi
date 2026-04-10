#Requires -Version 7
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

# Pester 5 installer smoke test for go-mapi.
#
# Phase 3 / INST-07 / 03-04-PLAN.
#
# Runs a full silent install -> verify -> silent uninstall -> verify cycle
# against src/installer/dist/go-mapi-setup.exe. Must run as Administrator
# (silent install writes to %ProgramFiles% and HKLM). Intended for
# windows-latest GitHub Actions runners; local runs should use a throwaway VM.

BeforeAll {
    $script:InstallerPath = (Resolve-Path (Join-Path $PSScriptRoot '..\dist\go-mapi-setup.exe')).Path
    $script:InstallDir = Join-Path $env:ProgramFiles 'go-mapi'
    $script:ProgramData = Join-Path $env:ProgramData 'go-mapi'
    $script:ManifestPath = Join-Path $script:ProgramData 'com.gomapi.host.json'
    $script:BackupPath = Join-Path $script:ProgramData 'uninst\previous-mail-client.json'
    $script:UninstExe = Join-Path $script:InstallDir 'unins000.exe'

    $script:BrowserKeys = @(
        'HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host'
        'HKLM:\SOFTWARE\Chromium\NativeMessagingHosts\com.gomapi.host'
        'HKLM:\SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host'
        'HKLM:\SOFTWARE\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.gomapi.host'
        'HKLM:\SOFTWARE\Vivaldi\NativeMessagingHosts\com.gomapi.host'
    )

    $script:MapiHandlerKey = 'HKLM:\SOFTWARE\Clients\Mail\go-mapi'
    $script:MailClientsKey = 'HKLM:\SOFTWARE\Clients\Mail'
}

Describe 'go-mapi installer smoke test' {

    Context 'Silent install' {
        It 'runs the installer silently and exits 0' {
            $logPath = Join-Path ([System.IO.Path]::GetTempPath()) 'go-mapi-install.log'
            if (Test-Path $logPath) { Remove-Item $logPath -Force }
            $proc = Start-Process -FilePath $script:InstallerPath `
                -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$logPath" `
                -Wait -PassThru
            $proc.ExitCode | Should -Be 0
            Test-Path $logPath | Should -BeTrue
        }

        It 'installs go-mapi.dll to Program Files' {
            Test-Path (Join-Path $script:InstallDir 'go-mapi.dll') | Should -BeTrue
        }

        It 'installs go-mapi-host.exe to Program Files' {
            Test-Path (Join-Path $script:InstallDir 'go-mapi-host.exe') | Should -BeTrue
        }

        It 'registers the MAPI handler key with DLLPath' {
            Test-Path $script:MapiHandlerKey | Should -BeTrue
            $dllPath = (Get-ItemProperty -Path $script:MapiHandlerKey -Name 'DLLPath').DLLPath
            $dllPath | Should -Match 'go-mapi\.dll$'
            Test-Path $dllPath | Should -BeTrue
        }

        It 'sets go-mapi as the active default mail client' {
            $default = (Get-ItemProperty -Path $script:MailClientsKey -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
            $default | Should -Be 'go-mapi'
        }

        It 'writes a valid shared native-messaging manifest under ProgramData' {
            Test-Path $script:ManifestPath | Should -BeTrue
            $json = Get-Content $script:ManifestPath -Raw | ConvertFrom-Json
            $json.name | Should -Be 'com.gomapi.host'
            $json.type | Should -Be 'stdio'
            $json.path | Should -Match 'go-mapi-host\.exe$'
            $json.allowed_origins | Should -Not -BeNullOrEmpty
            $json.allowed_origins.Count | Should -BeGreaterOrEqual 1
        }

        It 'registers all five browser native-messaging trees pointing at the shared manifest' {
            foreach ($key in $script:BrowserKeys) {
                Test-Path $key | Should -BeTrue -Because "expected browser registry tree $key"
                $val = (Get-ItemProperty -Path $key -Name '(default)').'(default)'
                $val | Should -Be $script:ManifestPath -Because "key $key should point at the shared manifest"
            }
        }

        It 'writes a valid previous-mail-client backup JSON when a previous client existed' {
            # A fresh windows-latest runner may have no default Mail client set,
            # in which case BackupPreviousMailClient() deliberately skips the
            # write per Phase 3 CONTEXT D-09. So this test is permissive: the
            # backup file is OPTIONAL, but if it exists it MUST be valid JSON
            # with the required fields.
            if (Test-Path $script:BackupPath) {
                $json = Get-Content $script:BackupPath -Raw | ConvertFrom-Json
                $json.PSObject.Properties.Name | Should -Contain 'previousClient'
                $json.PSObject.Properties.Name | Should -Contain 'backedUpAt'
                $json.previousClient | Should -Not -BeNullOrEmpty
            }
            else {
                # Also valid: no previous client existed, so no backup was written.
                # Assert the ProgramData\go-mapi\uninst directory exists (the
                # installer creates it unconditionally via [Dirs]).
                Test-Path (Join-Path $script:ProgramData 'uninst') | Should -BeTrue
            }
        }
    }

    Context 'Silent uninstall' {
        It 'has an uninstaller at the expected path' {
            Test-Path $script:UninstExe | Should -BeTrue
        }

        It 'runs the uninstaller silently and exits 0' {
            $proc = Start-Process -FilePath $script:UninstExe `
                -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' `
                -Wait -PassThru
            $proc.ExitCode | Should -Be 0
        }

        It 'removes all five browser registry trees' {
            foreach ($key in $script:BrowserKeys) {
                Test-Path $key | Should -BeFalse -Because "browser registry key $key should be gone"
            }
        }

        It 'removes the MAPI handler key' {
            Test-Path $script:MapiHandlerKey | Should -BeFalse
        }

        It 'removes the shared manifest file' {
            Test-Path $script:ManifestPath | Should -BeFalse
        }

        It 'removes the previous-mail-client backup JSON' {
            Test-Path $script:BackupPath | Should -BeFalse
        }

        It 'removes the install directory (or leaves it empty)' {
            # Inno Setup may leave the empty dir if any files it did not track
            # remain (e.g. the install log). Accept either fully-gone or empty.
            if (Test-Path $script:InstallDir) {
                $remaining = @(Get-ChildItem -Path $script:InstallDir -Force -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.PSIsContainer })
                $remaining.Count | Should -Be 0 -Because 'install dir should contain no files after uninstall'
            }
        }
    }
}
