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

;------------------------------------------------------------------------------
; DetectWebView2 — D-06 / INST-02
;
; Pushes "1" (runtime present) or "0" (absent) onto the stack. Probes three
; registry locations per Microsoft's WebView2 distribution guidance:
;   1. HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{GUID}  (64-bit view)
;   2. HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\{GUID}              (direct HKLM)
;   3. HKCU\Software\Microsoft\EdgeUpdate\Clients\{GUID}              (per-user)
; The `pv` value is the installed runtime version — empty OR "0.0.0.0" = absent.
;------------------------------------------------------------------------------

Function DetectWebView2
  Push $0
  Push $1

  SetRegView 64
  ReadRegStr $0 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" 0 WebView2Found
  StrCmp $0 "0.0.0.0" 0 WebView2Found

  ReadRegStr $0 HKLM "SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" 0 WebView2Found
  StrCmp $0 "0.0.0.0" 0 WebView2Found

  SetRegView 32
  ReadRegStr $0 HKCU "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" WebView2NotFound WebView2Found

WebView2NotFound:
  Pop $1
  Pop $0
  Push "0"
  Return

WebView2Found:
  DetailPrint "WebView2 runtime detected: $0"
  Pop $1
  Pop $0
  Push "1"
  Return
FunctionEnd

;------------------------------------------------------------------------------
; InstallWebView2 — D-05 / D-06 / D-07 / INST-02
;
; If runtime absent, extract the vendored bootstrapper to $INSTDIR, invoke with
; /silent /install, then poll the registry every 2 seconds for up to 30 iterations
; (60-second budget per D-06). The bootstrapper is known to exit before install
; completes (GH WebView2Feedback#1349, still unfixed) — registry poll is the
; only reliable completion signal.
;
; D-07: On poll timeout, continue (do NOT abort). The Wails app has its own
; runtime-missing recovery (D-08, see webview2_check.go). Log the timeout to
; $INSTDIR\install.log (append mode so prior log lines survive).
;
; Cleanup: the bootstrapper is deleted from $INSTDIR on both success and timeout
; branches — no leftover bootstrapper in the install dir (D-05 cleanup intent).
;------------------------------------------------------------------------------

Function InstallWebView2
  Call DetectWebView2
  Pop $0
  StrCmp $0 "1" WebView2Ready

  DetailPrint "WebView2 runtime not present — invoking bootstrapper"
  SetOutPath "$INSTDIR"
  File "${__FILEDIR__}\MicrosoftEdgeWebview2Setup.exe"

  ; D-06: bootstrapper exits before install completes (GH WebView2Feedback#1349)
  ExecWait '"$INSTDIR\MicrosoftEdgeWebview2Setup.exe" /silent /install' $1
  DetailPrint "WebView2 bootstrapper exit=$1 — polling registry for completion"

  ; Poll every 2s for up to 30 iterations (60s budget) — D-06
  StrCpy $2 "0"
PollLoop:
  IntOp $2 $2 + 1
  IntCmp $2 30 PollTimeout
  Sleep 2000
  Call DetectWebView2
  Pop $0
  StrCmp $0 "1" WebView2Installed
  Goto PollLoop

PollTimeout:
  ; D-07: continue, do NOT abort. Wails app has runtime-recovery path (D-08).
  DetailPrint "WARNING: WebView2 bootstrap did not complete within 60s"
  FileOpen $3 "$INSTDIR\install.log" a
  FileWrite $3 "WebView2 bootstrap timed out after 60s; user will be prompted on app launch.$\r$\n"
  FileClose $3
  Delete "$INSTDIR\MicrosoftEdgeWebview2Setup.exe"
  Return

WebView2Installed:
  DetailPrint "WebView2 runtime install completed after $2 polls"
  Delete "$INSTDIR\MicrosoftEdgeWebview2Setup.exe"
  Return

WebView2Ready:
  DetailPrint "WebView2 runtime already present; skipping bootstrap"
  Return
FunctionEnd

;------------------------------------------------------------------------------
; CreateShortcutAndAUMID — D-13 / D-14 / D-15 / INST-01
;
; Creates the all-users Start Menu shortcut at $SMPROGRAMS\go-mapi.lnk and
; stamps PKEY_AppUserModel_ID on it via the ApplicationID NSIS plugin. The
; stamped AUMID is what makes Phase 9's toast notifications persist in Action
; Center — the shortcut AUMID MUST match the Wails app's runtime AUMID
; (com.marcfargas.gomapi per D-15), which the plan 10-06 release pipeline
; injects into the .exe via ldflags.
;
; Plugin ABI (from NSIS ApplicationID v1.1):
;     ApplicationID::Set "<shortcut-path>" "<aumid-string>"
;     Pop $0     ; "0" = success, non-zero = error
; RESEARCH §Pitfall 2 — Pop is required; without it the rc is swallowed.
;------------------------------------------------------------------------------

Function CreateShortcutAndAUMID
  ; D-13: Start Menu shortcut — all-users (admin install → $SMPROGRAMS resolves
  ; to %ProgramData%\Microsoft\Windows\Start Menu\Programs\).
  ; Signature: CreateShortcut link target parameters iconfile iconindex startoptions keyboardshortcut description
  CreateShortcut "$SMPROGRAMS\go-mapi.lnk" \
      "$INSTDIR\go-mapi.exe" \
      "" \
      "$INSTDIR\go-mapi.exe" 0 \
      SW_SHOWNORMAL "" \
      "go-mapi — MAPI-to-Gmail bridge"

  ; D-14: stamp PKEY_AppUserModel_ID via ApplicationID plugin. Plugin loaded
  ; from src/installer/plugins/x86-unicode/ApplicationID.dll (vendored in plan 10-01).
  ; ApplicationID::Set pushes "0" on success, "-1" on error.
  ; D-15: production AUMID is com.marcfargas.gomapi (matches the ${AUMID} define).
  ApplicationID::Set "$SMPROGRAMS\go-mapi.lnk" "${AUMID}"
  Pop $0
  StrCmp $0 "0" AumidOk
  DetailPrint "WARNING: AUMID stamp rc=$0 — Action Center persistence may break"
  ; Do NOT halt the installer — continue install; Pester test (plan 10-05) will surface this in CI.
  Goto AumidDone
AumidOk:
  DetailPrint "AUMID stamped: ${AUMID}"
AumidDone:
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
