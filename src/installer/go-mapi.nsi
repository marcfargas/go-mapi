; go-mapi.nsi — NSIS installer for go-mapi (v3.0)
;
; Plan 10-01 scaffold: ModernUI2 layout, admin-elevation, machine-wide install,
; MAPI handler registration, previous-mail-client backup, Add/Remove Programs
; metadata, and stub Call sites for plans 10-02 / 10-03 / 10-04.
;
; Compile with:
;     makensis /DGOMAPI_VERSION=0.0.0-dev src\installer\go-mapi.nsi
;
; Requires: pre-built src\app\build\bin\go-mapi.exe and
;           src\interceptor\build\bin\go-mapi.dll (staged by CI in plan 10-05 /
;           release pipeline in plan 10-06).
;
; References:
;   D-01, D-02, D-03, D-04 — NSIS + admin + machine-wide + output filename
;   D-09 — HKLM\SOFTWARE\Clients\Mail\go-mapi registration layout
;   D-10 — BackupPreviousMailClient BEFORE overwriting HKLM Mail (Default)
;   D-12 — %ProgramData%\go-mapi\uninst\ directory for backup JSON
;   T-10-01-01 — ordering invariant enforced below (Call BackupPreviousMailClient
;                precedes WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "go-mapi")

Unicode True

;------------------------------------------------------------------------------
; Product defines (consumed by plans 10-02 / 10-03 / 10-04)
;------------------------------------------------------------------------------

!ifndef GOMAPI_VERSION
  !define GOMAPI_VERSION "0.0.0-dev"
!endif

!define PRODUCT_NAME      "go-mapi"
!define PRODUCT_VERSION   "${GOMAPI_VERSION}"
!define PRODUCT_PUBLISHER "Marc Fargas"
!define PRODUCT_WEB_SITE  "https://github.com/marcfargas/go-mapi"
!define AUMID             "com.marcfargas.gomapi"

;------------------------------------------------------------------------------
; Compiler / installer-wide settings
;------------------------------------------------------------------------------

SetCompressor /SOLID lzma
RequestExecutionLevel admin
InstallDir   "$PROGRAMFILES64\go-mapi"
OutFile      "go-mapi-setup.exe"
Name         "${PRODUCT_NAME} ${PRODUCT_VERSION}"
BrandingText "${PRODUCT_NAME} ${PRODUCT_VERSION} — LGPL-3.0"

; Repo-local plugin directory for vendored NSIS plugins (ApplicationID.dll).
; `${__FILEDIR__}` resolves to src\installer\ at makensis time.
!addplugindir "${__FILEDIR__}\plugins"

;------------------------------------------------------------------------------
; ModernUI2 pages
;------------------------------------------------------------------------------

!include "MUI2.nsh"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${__FILEDIR__}\..\..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

;------------------------------------------------------------------------------
; Install section
;------------------------------------------------------------------------------

Section "Install" SecInstall
  SetOutPath "$INSTDIR"

  ; Staged binary paths — produced by:
  ;   npm run build:interceptor         (MinGW + CMake → go-mapi.dll)
  ;   wails build -platform windows/amd64 (→ go-mapi.exe with go:embed frontend)
  File "${__FILEDIR__}\..\app\build\bin\go-mapi.exe"
  File "${__FILEDIR__}\..\interceptor\build\bin\go-mapi.dll"

  ; D-10 + T-10-01-01 — MUST run BEFORE the HKLM Mail (Default) overwrite below
  ; so the pre-install mail client name is captured correctly.
  Call BackupPreviousMailClient

  ; D-09 — MAPI handler registration (machine-wide).
  ; Subkey + DLLPath are set first; the HKLM\SOFTWARE\Clients\Mail\(Default)
  ; overwrite happens AFTER the backup call above.
  WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "" "go-mapi"
  WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "DLLPath" "$INSTDIR\go-mapi.dll"
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "go-mapi"

  ; Uninstaller binary
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; Add/Remove Programs metadata
  WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "DisplayName"     "${PRODUCT_NAME}"
  WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "DisplayVersion"  "${PRODUCT_VERSION}"
  WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "Publisher"       "${PRODUCT_PUBLISHER}"
  WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "URLInfoAbout"    "${PRODUCT_WEB_SITE}"
  WriteRegStr   HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "NoModify"        1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" "NoRepair"        1

  ; Stub calls — bodies are filled in by later plans. Each stub emits a
  ; DetailPrint so the installer log documents which milestone owns the work.
  Call InstallWebView2           ; plan 10-02
  Call CreateShortcutAndAUMID    ; plan 10-03
  Call AddFirewallRule           ; plan 10-03
SectionEnd

;------------------------------------------------------------------------------
; BackupPreviousMailClient — D-10 / T-10-01-01
;
; Writes %ProgramData%\go-mapi\uninst\previous-mail-client.json with the shape
;     {"previousClient": "<name>"|null, "backedUpAt": "<ISO-8601>"}
; so the uninstaller (plan 10-04) can restore the pre-install Mail client.
;
; Upgrade case (current (Default) is already "go-mapi") intentionally preserves
; the existing backup — overwriting would lose the original previous-client
; name across reinstalls.
;
; Timestamp primitive: nsExec::ExecToStack invokes powershell.exe once to emit
; an ISO-8601 UTC date. nsExec ships with core NSIS, so no additional plugin
; is required. The newline returned by PowerShell is trimmed via StrCpy -2
; (strips the trailing CRLF).
;------------------------------------------------------------------------------

Function BackupPreviousMailClient
  ; `$APPDATA\..\..\ProgramData` resolves to `%ProgramData%` at install time
  ; (admin context). Same primitive used by the uninstaller section stub.
  CreateDirectory "$APPDATA\..\..\ProgramData\go-mapi\uninst"

  ReadRegStr $0 HKLM "SOFTWARE\Clients\Mail" ""

  ; Upgrade case: existing install. Preserve original backup, skip write.
  StrCmp $0 "go-mapi" AlreadyUs
  ; Clean install with no prior default Mail client.
  StrCmp $0 "" BackupNull

  ; Get ISO-8601 UTC timestamp via Windows PowerShell (not pwsh — end-user
  ; machines may only have PS 5.1 per §Anti-Patterns in 10-RESEARCH.md).
  nsExec::ExecToStack 'powershell.exe -NoProfile -Command "[DateTime]::UtcNow.ToString(\"yyyy-MM-ddTHH:mm:ssZ\")"'
  Pop $2   ; exit code (discard)
  Pop $3   ; stdout (timestamp + trailing CRLF)
  StrCpy $3 $3 -2   ; strip trailing \r\n

  FileOpen  $1 "$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json" w
  FileWrite $1 '{"previousClient":"$0","backedUpAt":"$3"}'
  FileClose $1
  DetailPrint "Previous Mail client backed up: $0"
  Return

BackupNull:
  nsExec::ExecToStack 'powershell.exe -NoProfile -Command "[DateTime]::UtcNow.ToString(\"yyyy-MM-ddTHH:mm:ssZ\")"'
  Pop $2
  Pop $3
  StrCpy $3 $3 -2

  FileOpen  $1 "$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json" w
  FileWrite $1 '{"previousClient":null,"backedUpAt":"$3"}'
  FileClose $1
  DetailPrint "No previous Mail client (null backup written)"
  Return

AlreadyUs:
  DetailPrint "Upgrade detected — preserving existing previous-mail-client.json"
  Return
FunctionEnd

;------------------------------------------------------------------------------
; Stub Functions — bodies filled in by later plans. They exist in this plan
; so the NSIS script remains compilable and the Install-section Call sites
; resolve cleanly.
;------------------------------------------------------------------------------

Function InstallWebView2
  DetailPrint "stub: InstallWebView2 — implemented in plan 10-02"
FunctionEnd

Function CreateShortcutAndAUMID
  DetailPrint "stub: CreateShortcutAndAUMID — implemented in plan 10-03"
FunctionEnd

Function AddFirewallRule
  DetailPrint "stub: AddFirewallRule — implemented in plan 10-03"
FunctionEnd

;------------------------------------------------------------------------------
; Uninstall section
;
; Full 10-step scrub (D-18) lives in plan 10-04. This stub keeps the
; uninstaller compilable so `makensis` does not fail on the scaffold plan.
;------------------------------------------------------------------------------

Section "Uninstall"
  DetailPrint "stub: Uninstall body — implemented in plan 10-04"
  ; Remove Add/Remove Programs entry so an incomplete uninstall cannot leave
  ; orphaned metadata. Everything else (binaries, registry, shortcuts, etc.)
  ; is fleshed out in plan 10-04.
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"
SectionEnd

Function un.RestorePreviousMailClient
  DetailPrint "stub: un.RestorePreviousMailClient — implemented in plan 10-04"
FunctionEnd
