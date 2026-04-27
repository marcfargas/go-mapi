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
;   QUICK-260423-msq — DLL queue relocated from %TEMP%\go-mapi\ to
;                %LOCALAPPDATA%\go-mapi\queue\ (DLL creates it at DllMain; installer does not
;                pre-create it — no install-time action required for the path itself).

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
; Phase 11.1 Plan 05 — D-07 / D-08 silent auto-update wiring.
;   FileFunc.nsh : ${GetParameters} + ${GetOptions} for /AUTOUPDATE=N parsing.
;   nsDialogs.nsh: nsDialogs::Create + ${NSD_*} for the AutoUpdate page checkbox.
;   LogicLib.nsh : ${If}/${Else}/${EndIf} + ${DoUntil}/${LoopUntil}/${Errors}
;                  used by AutoUpdatePageLeave and un.ScrubOldOrphans.
!include "FileFunc.nsh"
!include "nsDialogs.nsh"
!include "LogicLib.nsh"

; Phase 11.1 D-07: parsed in .onInit, propagated through the AutoUpdate page,
; consumed by RegisterScheduledTask. Strict bool — only the literal "1" enables.
Var AutoUpdateFlag
Var AutoUpdateCheckboxState   ; nsDialogs handle for the FinishPage-adjacent checkbox.

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${__FILEDIR__}\..\..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
; Phase 11.1 D-07: AutoUpdate opt-in checkbox page. Default OFF. /AUTOUPDATE=1
; on the command line forces enable for silent installs (the page is skipped
; in /S mode and when the flag is already set).
Page custom AutoUpdatePage AutoUpdatePageLeave
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

;------------------------------------------------------------------------------
; .onInit — parse /AUTOUPDATE=N (Phase 11.1 D-07).
;
; Default OFF: empty string after GetOptions = parameter not specified.
; Strict bool comparison downstream (StrCmp $AutoUpdateFlag "1") so any value
; other than the literal "1" — including "0", "true", "yes", or anything else —
; resolves to OFF. RESEARCH §T-11.1.05-03: the parsed value never flows into
; ExecWait argument construction; only the fixed schtasks command line uses it.
;------------------------------------------------------------------------------
Function .onInit
  ${GetParameters} $R0
  ${GetOptions} $R0 "/AUTOUPDATE=" $AutoUpdateFlag
FunctionEnd

;------------------------------------------------------------------------------
; AutoUpdatePage — interactive UI checkbox (Phase 11.1 D-07).
;
; Skipped if /S (silent install) — silent installs use /AUTOUPDATE=N only.
; Skipped if /AUTOUPDATE=1 was already set on the command line — no need to
; ask again. Default state is UNCHECKED per D-07.
;------------------------------------------------------------------------------
Function AutoUpdatePage
  ; Skip if /S (silent install) — silent installs use /AUTOUPDATE only.
  IfSilent 0 +2
    Abort
  ; Skip if /AUTOUPDATE=1 was already set on the command line.
  StrCmp $AutoUpdateFlag "1" 0 +3
    DetailPrint "Auto-update pre-set via /AUTOUPDATE=1 — skipping checkbox page"
    Abort

  !insertmacro MUI_HEADER_TEXT "Automatic updates" "Enable unattended updates for this machine"
  nsDialogs::Create 1018
  Pop $0

  ${NSD_CreateLabel} 0 0 100% 40u "go-mapi can keep itself up-to-date automatically using a Windows Scheduled Task that runs as SYSTEM. The task downloads, verifies SHA-256 integrity, and applies updates without prompting users. Recommended for managed/RDS environments."
  Pop $0

  ${NSD_CreateCheckbox} 0 50u 100% 12u "Enable automatic updates (creates a Scheduled Task)"
  Pop $1
  ${NSD_SetState} $1 ${BST_UNCHECKED}    ; D-07 default OFF
  StrCpy $AutoUpdateCheckboxState $1

  nsDialogs::Show
FunctionEnd

Function AutoUpdatePageLeave
  ${NSD_GetState} $AutoUpdateCheckboxState $0
  ${If} $0 == ${BST_CHECKED}
    StrCpy $AutoUpdateFlag "1"
  ${Else}
    StrCpy $AutoUpdateFlag "0"
  ${EndIf}
  DetailPrint "AutoUpdateFlag chosen: $AutoUpdateFlag"
FunctionEnd

;------------------------------------------------------------------------------
; Install section
;------------------------------------------------------------------------------

Section "Install" SecInstall
  ; QUICK-260423-ntu T2 — if a previous install's go-mapi.exe is running in
  ; $INSTDIR, give it a chance to close cleanly (WM_CLOSE via taskkill
  ; without /F triggers the intentionalQuit path in src/app/main.go) before
  ; we overwrite the binary. Silent mode auto-retries; interactive mode
  ; prompts the user. MUST be the first statement in the section.
  Call EnsureAppNotRunning

  SetOutPath "$INSTDIR"

  ; Staged binary paths — produced by:
  ;   npm run build:interceptor         (clang + CMake → build-x64/ + build-x86/)
  ;   wails build -platform windows/amd64 (→ go-mapi.exe with go:embed frontend)
  ;
  ; QUICK-260423-ntu T3c — dual-bitness layout: x64 DLL lands in $INSTDIR
  ; (= $PROGRAMFILES64\go-mapi) for native MAPI callers; x86 DLL lands in
  ; $PROGRAMFILES32\go-mapi for legacy 32-bit MAPI callers. Registry
  ; DLLPath writes below route each view to the matching-bitness DLL.
  ; PHASE 11.1 T4 (D-04): explicit Delete + SetOverwrite try collapses transient
  ; AV/filter holds into a no-op rather than aborting the installer. RESEARCH
  ; §Pattern 1 + §Pitfall 1. NSIS default SetOverwrite is `on`, which makes
  ; reinstall fail hard on any transient lock; `try` skips silently if write
  ; fails (the explicit Delete clears the prior version first so it does not).
  ClearErrors
  Delete "$INSTDIR\go-mapi.exe"
  Delete "$INSTDIR\go-mapi.dll"
  SetOverwrite try
  File "${__FILEDIR__}\..\app\build\bin\go-mapi.exe"
  File "${__FILEDIR__}\..\interceptor\build-x64\bin\go-mapi.dll"
  SetOverwrite on

  ; x86 DLL — same T4 treatment in $PROGRAMFILES32 view.
  CreateDirectory "$PROGRAMFILES32\go-mapi"
  SetOutPath "$PROGRAMFILES32\go-mapi"
  ClearErrors
  Delete "$PROGRAMFILES32\go-mapi\go-mapi.dll"
  SetOverwrite try
  File "${__FILEDIR__}\..\interceptor\build-x86\bin\go-mapi.dll"
  SetOverwrite on

  ; Reset $OUTDIR for the rest of the install section
  SetOutPath "$INSTDIR"

  ; QUICK-260423-msq — diagnostic scripts shipped alongside the app for the
  ; future in-app "Report bug" flow. PS 5.1-compatible, non-admin, read-only.
  ; Installed to $INSTDIR\diagnostics\ so the Wails app can invoke them at a
  ; known relative path when the user triggers a bug report.
  SetOutPath "$INSTDIR\diagnostics"
  File "${__FILEDIR__}\..\..\scripts\diagnostics\collect-registration.ps1"
  File "${__FILEDIR__}\..\..\scripts\diagnostics\collect-runtime.ps1"
  SetOutPath "$INSTDIR"

  ; D-10 + T-10-01-01 — MUST run BEFORE the HKLM Mail (Default) overwrite below
  ; so the pre-install mail client name is captured correctly.
  Call BackupPreviousMailClient

  ; D-09 — MAPI handler registration (machine-wide).
  ; Subkey + DLLPath are set first; the HKLM\SOFTWARE\Clients\Mail\(Default)
  ; overwrite happens AFTER the backup call above.
  WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "" "go-mapi"
  WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "DLLPath" "$INSTDIR\go-mapi.dll"
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "go-mapi"

  ; QUICK-260423-ntu T3c — 32-bit registry view. SetRegView 32 redirects
  ; HKLM reads/writes into the WOW6432Node subtree, matching the existing
  ; pattern used by DetectWebView2 (lines 269/282/292/300). This routes
  ; 32-bit MAPI callers to the i686 DLL at $PROGRAMFILES32\go-mapi.
  SetRegView 32
  WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "" "go-mapi"
  WriteRegStr HKLM "SOFTWARE\Clients\Mail\go-mapi" "DLLPath" "$PROGRAMFILES32\go-mapi\go-mapi.dll"
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "go-mapi"
  SetRegView default

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

  ; D-03: best-effort cleanup of stale per-user shortcut from pre-11.1 builds.
  SetShellVarContext current
  Delete "$SMPROGRAMS\go-mapi.lnk"
  ; (next call to CreateShortcutAndAUMID below already wrapped to all-users)

  ; Stub calls — bodies are filled in by later plans. Each stub emits a
  ; DetailPrint so the installer log documents which milestone owns the work.
  Call InstallWebView2           ; plan 10-02
  Call CreateShortcutAndAUMID    ; plan 10-03 (D-03)
  Call AddFirewallRule           ; plan 10-03
  Call RegisterScheduledTask     ; Phase 11.1 D-08 (gated on $AutoUpdateFlag)
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

  ; QUICK-260423-ntu T3c — also capture the WOW6432 view's (Default)
  ; Mail client so the uninstaller can restore both views symmetrically.
  SetRegView 32
  ReadRegStr $4 HKLM "SOFTWARE\Clients\Mail" ""
  SetRegView default

  ; Upgrade case: existing install. Preserve original backup, skip write.
  StrCmp $0 "go-mapi" AlreadyUs
  ; Clean install with no prior default Mail client.
  StrCmp $0 "" BackupNull

  ; WR-02: escape $0 (and $4) for JSON string context before interpolation.
  ; A mail client display name may legally contain `"` or `\` (e.g. locale-
  ; specific or custom enterprise names) which would otherwise produce
  ; invalid JSON and break the uninstaller's restore path.
  Push $0
  Call EscapeJsonString
  Pop $0

  Push $4
  Call EscapeJsonString
  Pop $4

  ; Get ISO-8601 UTC timestamp via Windows PowerShell (not pwsh — end-user
  ; machines may only have PS 5.1 per §Anti-Patterns in 10-RESEARCH.md).
  nsExec::ExecToStack 'powershell.exe -NoProfile -Command "[DateTime]::UtcNow.ToString(\"yyyy-MM-ddTHH:mm:ssZ\")"'
  Pop $2   ; exit code (discard)
  Pop $3   ; stdout (timestamp + trailing CRLF)
  StrCpy $3 $3 -2   ; strip trailing \r\n

  FileOpen  $1 "$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json" w
  StrCmp $4 "" BackupWriteNative32
  FileWrite $1 '{"previousClient":"$0","previousClient32":"$4","backedUpAt":"$3"}'
  Goto BackupWriteDone
BackupWriteNative32:
  FileWrite $1 '{"previousClient":"$0","previousClient32":null,"backedUpAt":"$3"}'
BackupWriteDone:
  FileClose $1
  DetailPrint "Previous Mail client backed up: native='$0' wow6432='$4'"
  Return

BackupNull:
  nsExec::ExecToStack 'powershell.exe -NoProfile -Command "[DateTime]::UtcNow.ToString(\"yyyy-MM-ddTHH:mm:ssZ\")"'
  Pop $2
  Pop $3
  StrCpy $3 $3 -2

  ; Also escape $4 for the WOW6432 side of the null-backup path (it may
  ; still have a non-empty value even when the native view is empty).
  Push $4
  Call EscapeJsonString
  Pop $4

  FileOpen  $1 "$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json" w
  StrCmp $4 "" BackupNullNoWow
  FileWrite $1 '{"previousClient":null,"previousClient32":"$4","backedUpAt":"$3"}'
  Goto BackupNullDone
BackupNullNoWow:
  FileWrite $1 '{"previousClient":null,"previousClient32":null,"backedUpAt":"$3"}'
BackupNullDone:
  FileClose $1
  DetailPrint "No previous native Mail client (wow6432='$4' backed up)"
  Return

AlreadyUs:
  DetailPrint "Upgrade detected — preserving existing previous-mail-client.json"
  Return
FunctionEnd

;------------------------------------------------------------------------------
; EnsureAppNotRunning — QUICK-260423-ntu T2 (installer scope)
;
; If a go-mapi.exe process is running, offer clean-close-and-retry. Uses
; `tasklist` (core Windows tool, no plugin) for detection and `taskkill`
; WITHOUT /F for graceful shutdown — WM_CLOSE maps to the same
; intentionalQuit path in src/app/main.go that the tray "Quit" menu item
; triggers. Polls every 500ms up to 20 iterations (10s budget) for the
; process to exit; aborts on timeout.
;
; Image-name match only (no WMIC path-narrowing) — go-mapi.exe is unique
; enough in practice that a duplicate unrelated process is an acceptable
; v3.0 risk, and WMIC has been removed on recent Windows 11 builds.
;
; Silent mode (`/S` — used by CI Pester harness) auto-selects "close and
; retry" so the test harness does not hang on a MessageBox.
;
; The un.EnsureAppNotRunning copy below is a byte-for-byte duplicate with
; the `un.` prefix — NSIS requires it for uninstaller-scope functions.
;------------------------------------------------------------------------------

Function EnsureAppNotRunning
  Push $0
  Push $1

  ; Quick probe — is any go-mapi.exe running at all?
  nsExec::ExecToStack 'tasklist /FI "IMAGENAME eq go-mapi.exe" /NH /FO CSV'
  Pop $0   ; exit code
  Pop $1   ; stdout

  Push $1
  Push "go-mapi.exe"
  Call StrContains
  Pop $0   ; "1" = found, "0" = not found
  StrCmp $0 "1" EANR_Found EANR_NotFound

EANR_Found:
  DetailPrint "go-mapi.exe is running — attempting graceful close"
  IfSilent EANR_SilentRetry EANR_AskUser

EANR_AskUser:
  MessageBox MB_OKCANCEL|MB_ICONEXCLAMATION "go-mapi is currently running. Click OK to close it and continue, or Cancel to abort the installer." IDOK EANR_SilentRetry IDCANCEL EANR_Cancel

EANR_Cancel:
  DetailPrint "User cancelled — aborting installer"
  Pop $1
  Pop $0
  Abort "Installer aborted by user (go-mapi was running)."

EANR_SilentRetry:
  ; Send WM_CLOSE to every go-mapi.exe instance (no /F — honours
  ; intentionalQuit path). /IM matches by image name; /T includes children.
  nsExec::ExecToStack 'taskkill /IM go-mapi.exe'
  Pop $0
  Pop $1
  DetailPrint "taskkill /IM go-mapi.exe rc=$0"

  ; Poll loop — 20 iterations * 500ms = 10s budget
  StrCpy $0 0
EANR_PollLoop:
  Sleep 500
  nsExec::ExecToStack 'tasklist /FI "IMAGENAME eq go-mapi.exe" /NH /FO CSV'
  Pop $1   ; exit code (discard)
  Pop $1   ; stdout
  Push $1
  Push "go-mapi.exe"
  Call StrContains
  Pop $1
  StrCmp $1 "0" EANR_Exited
  IntOp $0 $0 + 1
  IntCmp $0 20 EANR_Timeout
  Goto EANR_PollLoop

EANR_Timeout:
  DetailPrint "ERROR: go-mapi.exe did not exit within 10s"
  Pop $1
  Pop $0
  IfSilent EANR_SilentAbort
  MessageBox MB_OK|MB_ICONSTOP "go-mapi did not close within 10 seconds. Please close it manually and re-run the installer."
EANR_SilentAbort:
  Abort "go-mapi.exe still running after 10s close poll."

EANR_Exited:
  DetailPrint "go-mapi.exe exited after $0 poll iterations"
  Pop $1
  Pop $0
  Return

EANR_NotFound:
  Pop $1
  Pop $0
FunctionEnd

;------------------------------------------------------------------------------
; StrContains (installer scope) — shared by EnsureAppNotRunning.
;
; Mirror of un.StrContains (lives in the uninstall section because the
; uninstaller already needed it for backup-JSON parsing). We keep a separate
; installer-scope copy rather than un.-prefixing both to avoid NSIS function
; scope restrictions.
;
; Push haystack, push needle. Pops "1" (found) or "0". Case-sensitive.
;------------------------------------------------------------------------------

Function StrContains
  Exch $R1   ; needle
  Exch
  Exch $R2   ; haystack
  Push $R3   ; needle-length
  Push $R4   ; haystack cursor
  Push $R5   ; needle cursor
  StrLen $R3 $R1
  StrCpy $R4 0
SC_Loop:
  StrCpy $R5 $R2 $R3 $R4
  StrCmp $R5 $R1 SC_Found
  StrCmp $R5 "" SC_NotFound
  IntOp $R4 $R4 + 1
  Goto SC_Loop
SC_Found:
  StrCpy $R1 "1"
  Goto SC_Done
SC_NotFound:
  StrCpy $R1 "0"
SC_Done:
  Pop $R5
  Pop $R4
  Pop $R3
  Pop $R2
  Exch $R1
FunctionEnd

;------------------------------------------------------------------------------
; EscapeJsonString — WR-02
;
; Pops one string off the stack, pushes a JSON-string-safe version. NSIS has
; no native JSON escaper; for the narrow context of a previous-mail-client
; display name written into a JSON string literal, the two characters that
; matter are `\` and `"`. Order matters: backslash MUST be escaped before
; quote (escaping quote first would then double-escape our new backslash).
;
; Register usage (local only — all $R* values restored before return):
;   $R0 = input/output string         $R3 = output buffer
;   $R1 = length                      $R4 = single char at cursor
;   $R2 = cursor (0-indexed)
;------------------------------------------------------------------------------

Function EscapeJsonString
  Exch $R0     ; input string
  Push $R1
  Push $R2
  Push $R3
  Push $R4

  StrCpy $R3 ""
  StrLen $R1 $R0
  StrCpy $R2 0

EscLoop:
  IntCmp $R2 $R1 EscDone
  StrCpy $R4 $R0 1 $R2
  StrCmp $R4 "\" EscBackslash
  StrCmp $R4 '"' EscQuote
  StrCpy $R3 "$R3$R4"
  Goto EscNext
EscBackslash:
  StrCpy $R3 "$R3\\"
  Goto EscNext
EscQuote:
  StrCpy $R3 '$R3\"'
  Goto EscNext
EscNext:
  IntOp $R2 $R2 + 1
  Goto EscLoop

EscDone:
  StrCpy $R0 $R3
  Pop $R4
  Pop $R3
  Pop $R2
  Pop $R1
  Exch $R0     ; push escaped string; restore caller's $R0
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
; Each probe rejects pv="" OR pv="0.0.0.0" (Microsoft's broken-install sentinel
; per WebView2 distribution docs) — matches the Go-side check in
; webview2_check.go (`pv != "" && pv != "0.0.0.0"`). The two layers MUST stay
; in sync or the installer skips the bootstrapper while the app shows the
; "WebView2 required" dialog.
;------------------------------------------------------------------------------

Function DetectWebView2
  Push $0
  Push $1

  SetRegView 64
  ReadRegStr $0 HKLM "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" TryDirectHKLM
  StrCmp $0 "0.0.0.0" TryDirectHKLM
  Goto WebView2Found

TryDirectHKLM:
  ReadRegStr $0 HKLM "SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" TryHKCU
  StrCmp $0 "0.0.0.0" TryHKCU
  Goto WebView2Found

TryHKCU:
  SetRegView 32
  ReadRegStr $0 HKCU "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" "pv"
  StrCmp $0 "" WebView2NotFound
  StrCmp $0 "0.0.0.0" WebView2NotFound
  Goto WebView2Found

WebView2NotFound:
  ; IN-04: reset registry view before returning so subsequent registry writes
  ; in the install section (AddFirewallRule, future growth) are not silently
  ; redirected through WOW6432Node or forced to the 32-bit view.
  SetRegView default
  Pop $1
  Pop $0
  Push "0"
  Return

WebView2Found:
  ; IN-04: see WebView2NotFound above — reset view before returning.
  SetRegView default
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
  ; D-03 (Phase 11.1): tight SetShellVarContext all wrap around the All Users
  ; shortcut create. Pitfall 2: this also redirects $APPDATA, $LOCALAPPDATA,
  ; $DESKTOP — keep the wrap tight so the existing %ProgramData% walk at
  ; lines 666-676 stays in default `current` context.
  SetShellVarContext all
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
  SetShellVarContext current
  StrCmp $0 "0" AumidOk
  DetailPrint "WARNING: AUMID stamp rc=$0 — Action Center persistence may break"
  ; Do NOT halt the installer — continue install; Pester test (plan 10-05) will surface this in CI.
  Goto AumidDone
AumidOk:
  DetailPrint "AUMID stamped: ${AUMID}"
AumidDone:
FunctionEnd

;------------------------------------------------------------------------------
; AddFirewallRule — D-16 / INST-06
;
; Creates an inbound Windows Firewall rule named "go-mapi OAuth loopback" bound
; to program=$INSTDIR\go-mapi.exe. Pre-creating the rule at install time avoids
; the first-bind firewall prompt that Windows otherwise raises when go-mapi
; binds its OAuth loopback listener — on RDS that prompt appears on the server
; console, invisible to the user in the RDP session (RESEARCH §Pitfall 4).
;
; Why netsh over `powershell.exe -Command "New-NetFirewallRule ..."`:
;   - single-line ExecWait with no PowerShell quote escaping
;   - works on all Windows 10+ SKUs without the NetSecurity PS module
;   - shorter NSIS script (RESEARCH §Pitfall 4 recommendation)
;
; Why program= (not localport=):
;   - go-mapi binds 127.0.0.1:0 (ephemeral port) for the OAuth loopback server
;   - a program-scoped rule is both narrower (only this .exe) and port-stable
;   - broad port exposure is avoided; tampering with $INSTDIR requires admin
;
; Rule name "go-mapi OAuth loopback" MUST match byte-for-byte the uninstall
; counterpart in plan 10-04 — a typo here breaks uninstall.
;------------------------------------------------------------------------------

Function AddFirewallRule
  ExecWait 'netsh advfirewall firewall add rule name="go-mapi OAuth loopback" dir=in program="$INSTDIR\go-mapi.exe" action=allow profile=any' $0
  DetailPrint "firewall add rule rc=$0"
  ; Do NOT halt on non-zero rc — group policy may block netsh writes, in which
  ; case OAuth on RDS will still hang but desktop Windows works (Windows
  ; auto-classifies loopback without the prompt on non-RDS sessions).
FunctionEnd

;------------------------------------------------------------------------------
; RegisterScheduledTask — Phase 11.1 D-08 / D-09 / D-14
;
; Gated on $AutoUpdateFlag == "1" (D-07: default OFF, only the literal "1"
; enables — the .onInit GetOptions parser keeps strict-bool semantics).
;
; Steps:
;   1. Stage tasks/go-mapi-auto-update.xml into $INSTDIR.
;   2. Substitute INSTDIR_PLACEHOLDER -> $INSTDIR via PowerShell 5.1.
;      [regex]::Escape on the replacement value protects against any
;      regex meta in $INSTDIR (RESEARCH §T-11.1.05-04). -Encoding Unicode
;      preserves the UTF-16 LE BOM that schtasks /XML requires.
;   3. schtasks /create /XML <path> /TN "go-mapi Auto Update" /F /RU SYSTEM
;      /RL HIGHEST. /F suppresses "task already exists" → idempotent
;      re-install (RESEARCH §Pitfall 3). /RU + /RL are defensive overrides
;      of the XML <Principals> block (typo guard).
;   4. Delete the staged XML — the definition lives in Task Scheduler now.
;------------------------------------------------------------------------------

Function RegisterScheduledTask
  StrCmp $AutoUpdateFlag "1" 0 SkipTask
  DetailPrint "Auto-update opt-in: registering Scheduled Task 'go-mapi Auto Update'"

  ; Generate the Task Scheduler XML programmatically with $INSTDIR baked in.
  ; The earlier "stage tasks/go-mapi-auto-update.xml + nsExec PowerShell
  ; substitution" pattern shipped in Plan 11.1-05 e9b2693 proved unreliable —
  ; the XML retained INSTDIR_PLACEHOLDER literal because the nested-quote
  ; escaping in the nsExec command line prevented PowerShell from running the
  ; substitution at all. Programmatic generation eliminates the entire
  ; substitution step.
  ;
  ; FileWriteUTF16LE (with /BOM on the first call) writes proper UTF-16 LE
  ; bytes preceded by the 0xFF 0xFE BOM — the encoding schtasks /XML requires
  ; on Win 10/11. NOTE: NSIS Unicode-build's plain `FileWrite` writes ANSI/
  ; UTF-8 bytes (single-byte per char), NOT UTF-16 LE, despite what some
  ; older NSIS docs imply — verified empirically in Plan 11.1-05 sandbox UAT
  ; (the staged file had a 0xFF 0xFE BOM followed by single-byte ASCII for
  ; "<?xml...", which schtasks decoded as garbage Chinese characters and
  ; rejected as malformed XML). FileWriteUTF16LE is the correct primitive.
  ;
  ; The committed src/installer/tasks/go-mapi-auto-update.xml file remains as
  ; the canonical reference for the task shape — it is no longer staged at
  ; install time, but downstream docs and future maintainers can read it.
  FileOpen $0 "$INSTDIR\go-mapi-auto-update.xml" w
  FileWriteUTF16LE /BOM $0 '<?xml version="1.0" encoding="UTF-16"?>$\r$\n'
  FileWriteUTF16LE $0 '<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">$\r$\n'
  FileWriteUTF16LE $0 '  <RegistrationInfo>$\r$\n'
  FileWriteUTF16LE $0 '    <Description>go-mapi silent auto-update — fetches and applies updates without elevating the interactive user.</Description>$\r$\n'
  FileWriteUTF16LE $0 '    <URI>\go-mapi Auto Update</URI>$\r$\n'
  FileWriteUTF16LE $0 '  </RegistrationInfo>$\r$\n'
  FileWriteUTF16LE $0 '  <Triggers>$\r$\n'
  FileWriteUTF16LE $0 '    <CalendarTrigger>$\r$\n'
  FileWriteUTF16LE $0 '      <StartBoundary>2026-01-01T03:00:00</StartBoundary>$\r$\n'
  FileWriteUTF16LE $0 '      <Enabled>true</Enabled>$\r$\n'
  FileWriteUTF16LE $0 '      <RandomDelay>PT30M</RandomDelay>$\r$\n'
  FileWriteUTF16LE $0 '      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>$\r$\n'
  FileWriteUTF16LE $0 '    </CalendarTrigger>$\r$\n'
  FileWriteUTF16LE $0 '    <BootTrigger>$\r$\n'
  FileWriteUTF16LE $0 '      <Enabled>true</Enabled>$\r$\n'
  FileWriteUTF16LE $0 '      <Delay>PT5M</Delay>$\r$\n'
  FileWriteUTF16LE $0 '    </BootTrigger>$\r$\n'
  FileWriteUTF16LE $0 '  </Triggers>$\r$\n'
  FileWriteUTF16LE $0 '  <Principals>$\r$\n'
  FileWriteUTF16LE $0 '    <Principal id="Author">$\r$\n'
  FileWriteUTF16LE $0 '      <UserId>S-1-5-18</UserId>$\r$\n'
  FileWriteUTF16LE $0 '      <RunLevel>HighestAvailable</RunLevel>$\r$\n'
  FileWriteUTF16LE $0 '    </Principal>$\r$\n'
  FileWriteUTF16LE $0 '  </Principals>$\r$\n'
  FileWriteUTF16LE $0 '  <Settings>$\r$\n'
  FileWriteUTF16LE $0 '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>$\r$\n'
  FileWriteUTF16LE $0 '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>$\r$\n'
  FileWriteUTF16LE $0 '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>$\r$\n'
  FileWriteUTF16LE $0 '    <AllowHardTerminate>true</AllowHardTerminate>$\r$\n'
  FileWriteUTF16LE $0 '    <StartWhenAvailable>true</StartWhenAvailable>$\r$\n'
  FileWriteUTF16LE $0 '    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>$\r$\n'
  FileWriteUTF16LE $0 '    <Enabled>true</Enabled>$\r$\n'
  FileWriteUTF16LE $0 '    <ExecutionTimeLimit>PT12H</ExecutionTimeLimit>$\r$\n'
  FileWriteUTF16LE $0 '  </Settings>$\r$\n'
  FileWriteUTF16LE $0 '  <Actions Context="Author">$\r$\n'
  FileWriteUTF16LE $0 '    <Exec>$\r$\n'
  FileWriteUTF16LE $0 '      <Command>"$INSTDIR\go-mapi.exe"</Command>$\r$\n'
  FileWriteUTF16LE $0 '      <Arguments>--update-check-silent</Arguments>$\r$\n'
  FileWriteUTF16LE $0 '    </Exec>$\r$\n'
  FileWriteUTF16LE $0 '  </Actions>$\r$\n'
  FileWriteUTF16LE $0 '</Task>$\r$\n'
  FileClose $0

  ; /F idempotent re-install. /RU SYSTEM is defensive (XML already pins
  ; <UserId>S-1-5-18</UserId>). NOTE: /RL is INCOMPATIBLE with /XML — schtasks
  ; rejects with "la opción /XML solo puede usarse con /S /U /P /RU /RP /F /IT
  ; /TN" if both are passed. RunLevel comes from <RunLevel>HighestAvailable</RunLevel>
  ; in the XML instead.
  ExecWait 'schtasks /create /XML "$INSTDIR\go-mapi-auto-update.xml" /TN "go-mapi Auto Update" /F /RU SYSTEM' $0
  DetailPrint "schtasks /create rc=$0"

  ; One-shot stage file — definition now lives in Task Scheduler database.
  Delete "$INSTDIR\go-mapi-auto-update.xml"
  Goto Done

SkipTask:
  DetailPrint "Auto-update opt-in not set (/AUTOUPDATE=0 or absent) — skipping Scheduled Task"

Done:
FunctionEnd

;------------------------------------------------------------------------------
; Uninstall section
;
; Full 10-step scrub (D-18) lives in plan 10-04. This stub keeps the
; uninstaller compilable so `makensis` does not fail on the scaffold plan.
;------------------------------------------------------------------------------

Section "Uninstall"
  ; Phase 11.1 D-16: remove the Scheduled Task FIRST so it cannot fire
  ; mid-uninstall (the task launches go-mapi.exe --update-check-silent which
  ; would write to $INSTDIR while we are scrubbing it). schtasks /delete /f
  ; is idempotent — rc=0 (removed) and rc=1 (not found) are both swallowed
  ; by un.RemoveScheduledTask, so /AUTOUPDATE=0 installs uninstall cleanly too.
  Call un.RemoveScheduledTask

  ; QUICK-260423-ntu T2 — runs SECOND now (was first): if go-mapi.exe is
  ; still running when the uninstaller starts, WM_CLOSE it and wait up to
  ; 10s for the intentionalQuit path to fire before any Delete runs.
  Call un.EnsureAppNotRunning

  ; D-18: 10-step full scrub. Steps execute in order; failures log but do
  ; not abort — we want to get as close to a clean state as possible even
  ; when some steps fail (e.g. firewall rule GPO-locked, AV-locked file).

  ; 1. Firewall rule — name MUST match plan 10-03 AddFirewallRule byte-for-byte
  ExecWait 'netsh advfirewall firewall delete rule name="go-mapi OAuth loopback"' $0
  DetailPrint "firewall delete rule rc=$0"

  ; 2. Start Menu shortcut (plan 10-03 stamped the AUMID on this .lnk)
  SetShellVarContext all
  Delete "$SMPROGRAMS\go-mapi.lnk"
  SetShellVarContext current

  ; 3. MAPI handler key (native view)
  DeleteRegKey HKLM "SOFTWARE\Clients\Mail\go-mapi"

  ; 3b. QUICK-260423-ntu T3c — WOW6432 MAPI handler key (32-bit view)
  SetRegView 32
  DeleteRegKey HKLM "SOFTWARE\Clients\Mail\go-mapi"
  SetRegView default

  ; 4. Restore (Default) Mail client from backup (D-11)
  Call un.RestorePreviousMailClient

  ; Phase 11.1 D-18 case 6: scrub silent-update staging dir (Plan 11.1-04 writes
  ; here under SYSTEM context; Plan 11.1-05 owns the cleanup).
  ; Use ReadEnvStr to read %PROGRAMDATA% directly. The `$APPDATA\..\..\ProgramData`
  ; pattern used elsewhere in this file (BackupPreviousMailClient, RestorePreviousMailClient)
  ; resolves to `<userprofile>\ProgramData` under default `current` context — a
  ; non-existent path. Verified by Plan 11.1-05 sandbox UAT (Test B updates_dir_after=true
  ; while planted file remained at C:\ProgramData\go-mapi\updates). ReadEnvStr is
  ; reliable across user/SYSTEM contexts.
  ReadEnvStr $0 PROGRAMDATA
  RMDir /r "$0\go-mapi\updates"

  ; Phase 11.1 W7: belt-and-braces cleanup of *.old.<pid> orphans left by
  ; silent-updater swaps (Plan 11.1-04 swapInPlace renames the old binary
  ; aside via MoveFileEx before placing the new one). Plan 11.1-04 also
  ; cleans these proactively at silent-update start; this catches any orphans
  ; that survive past the last cycle. Runs before the binary scrub at step 9.
  Push "$INSTDIR"
  Call un.ScrubOldOrphans
  Push "$PROGRAMFILES32\go-mapi"
  Call un.ScrubOldOrphans

  ; 5. %ProgramData%\go-mapi\uninst\ — remove AFTER the restore (step 4) since
  ; the restore reads from this directory
  RMDir /r "$APPDATA\..\..\ProgramData\go-mapi\uninst"
  RMDir    "$APPDATA\..\..\ProgramData\go-mapi"   ; only if empty (non-recursive)

  ; 6. %TEMP%\go-mapi\ — best-effort. Under elevated uninstall this is the
  ; SYSTEM user's TEMP, not the real user's. Real users' temp already
  ; auto-cleans via the delete-on-process privacy model in src/app/watcher_bridge.go.
  RMDir /r "$TEMP\go-mapi"

  ; 7. %APPDATA%\go-mapi\ — uninstalling user only (D-19 multi-user caveat:
  ; other users on the machine retain their own copies; documented in README)
  RMDir /r "$APPDATA\go-mapi"

  ; 8. Windows Credential Manager — target is "<service>:<username>" per
  ; zalando/go-keyring Windows backend (PATTERNS.md §Shared Pattern 3).
  ; CONTEXT specifics line 199 wrote the slash-separated form — WRONG.
  ; Verified target: "go-mapi:oauth-tokens" (colon). This is the byte-for-byte
  ; value returned by zalando/go-keyring's credName() method for
  ; service="go-mapi" + username="oauth-tokens" (see src/app/auth.go:27-28).
  ExecWait 'cmdkey /delete:go-mapi:oauth-tokens' $0
  DetailPrint "cmdkey /delete:go-mapi:oauth-tokens rc=$0"

  ; 9. Binaries (x64 side) — the un.EnsureAppNotRunning call at the start
  ; of this section has already closed any running go-mapi.exe so these
  ; Deletes succeed.
  Delete "$INSTDIR\go-mapi.exe"
  Delete "$INSTDIR\go-mapi.dll"
  Delete "$INSTDIR\uninstall.exe"
  Delete "$INSTDIR\install.log"

  ; 9b. Diagnostic scripts (QUICK-260423-msq)
  Delete "$INSTDIR\diagnostics\collect-registration.ps1"
  Delete "$INSTDIR\diagnostics\collect-runtime.ps1"
  RMDir  "$INSTDIR\diagnostics"

  ; 9c. QUICK-260423-ntu T3c — x86 DLL + its parallel install dir
  Delete "$PROGRAMFILES32\go-mapi\go-mapi.dll"
  RMDir  "$PROGRAMFILES32\go-mapi"

  ; 10. Install dir (RMDir non-recursive — only removes if empty)
  RMDir "$INSTDIR"

  ; Add/Remove Programs entry
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"

  DetailPrint "Uninstall complete"
SectionEnd

; D-11: on uninstall, restore HKLM\SOFTWARE\Clients\Mail\(Default) from the backup JSON.
; Only restores if:
;   1. backup JSON exists AND
;   2. current (Default) still points at "go-mapi" (don't clobber another installer) AND
;   3. the restoration target's subkey still exists under HKLM\SOFTWARE\Clients\Mail\
; Otherwise: try fallbacks (Microsoft Outlook -> Outlook -> Windows Mail) or clear to "".
Function un.RestorePreviousMailClient
  ; Guard 1: only restore if current (Default) is still our claim
  ReadRegStr $0 HKLM "SOFTWARE\Clients\Mail" ""
  StrCmp $0 "go-mapi" 0 DoneRestore
  DetailPrint "Mail (Default) is still 'go-mapi' — proceeding with restore"

  ; IN-05: parse the backup JSON via PowerShell's ConvertFrom-Json instead of a
  ; naive substring search. The previous substring-based detection of
  ; `"previousClient":null` would false-match on a display-name containing that
  ; exact literal (contrived, but brittle); ConvertFrom-Json unambiguously
  ; distinguishes `null` from a string value, and also correctly unescapes
  ; JSON-escaped `"` / `\` characters written by EscapeJsonString (WR-02).
  ;
  ; Shape (from BackupPreviousMailClient, single line):
  ;   {"previousClient":null,"backedUpAt":"..."}     OR
  ;   {"previousClient":"<name>","backedUpAt":"..."}
  ;
  ; PowerShell output:
  ;   - missing file / parse error: non-zero exit code -> fall through to fallbacks
  ;   - previousClient=null:        exit 0, stdout = "" (just trailing CRLF)
  ;   - previousClient="<name>":    exit 0, stdout = "<name>" + trailing CRLF
  StrCpy $1 ""  ; candidate name
  IfFileExists "$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json" 0 NoBackup
  nsExec::ExecToStack 'powershell.exe -NoProfile -Command "try { $$j = Get-Content -LiteralPath ''$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json'' -Raw | ConvertFrom-Json; if ($$null -ne $$j.previousClient) { Write-Output $$j.previousClient } exit 0 } catch { exit 1 }"'
  Pop $4    ; exit code
  Pop $1    ; stdout (empty if null or parse error)
  StrCmp $4 "0" 0 TryFallbacks
  ; Strip trailing CRLF if present (same pattern as BackupPreviousMailClient's timestamp)
  ; IntCmp len 2 <equal> <less> <greater>: trim when len >= 2 (equal or greater);
  ; skip when len < 2 (no CRLF could fit).
  StrLen $4 $1
  IntCmp $4 2 0 SkipTrim 0
  StrCpy $1 $1 -2
SkipTrim:
  StrCmp $1 "" TryFallbacks
  DetailPrint "Backup contains previousClient='$1'"
  Goto VerifyAndRestore

NoBackup:
  DetailPrint "No backup JSON at %ProgramData%\go-mapi\uninst\previous-mail-client.json — trying fallbacks"
  Goto TryFallbacks

VerifyAndRestore:
  ; Confirm the target subkey still exists under HKLM\SOFTWARE\Clients\Mail\<name>
  ; (some other installer may have removed it since backup).
  ReadRegStr $5 HKLM "SOFTWARE\Clients\Mail\$1" ""
  StrCmp $5 "" TryFallbacks     ; subkey gone; fall through
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "$1"
  DetailPrint "Restored Mail (Default) to: $1"
  Goto DoneRestore

TryFallbacks:
  ; Try "Microsoft Outlook" -> "Outlook" -> "Windows Mail" -> clear
  ReadRegStr $5 HKLM "SOFTWARE\Clients\Mail\Microsoft Outlook" ""
  StrCmp $5 "" TryOutlook
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "Microsoft Outlook"
  DetailPrint "Fallback: restored Mail (Default) to 'Microsoft Outlook'"
  Goto DoneRestore
TryOutlook:
  ReadRegStr $5 HKLM "SOFTWARE\Clients\Mail\Outlook" ""
  StrCmp $5 "" TryWinMail
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "Outlook"
  DetailPrint "Fallback: restored Mail (Default) to 'Outlook'"
  Goto DoneRestore
TryWinMail:
  ReadRegStr $5 HKLM "SOFTWARE\Clients\Mail\Windows Mail" ""
  StrCmp $5 "" ClearDefault
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "Windows Mail"
  DetailPrint "Fallback: restored Mail (Default) to 'Windows Mail'"
  Goto DoneRestore
ClearDefault:
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" ""
  DetailPrint "No fallback Mail client available — cleared (Default)"
DoneRestore:
  ; QUICK-260423-ntu T3c — symmetric WOW6432 restore. If the backup JSON
  ; is present and contains a non-null previousClient32 value, write it
  ; back to the 32-bit view's (Default). Parse via PowerShell's
  ; ConvertFrom-Json — same pattern as the native-view restore above.
  IfFileExists "$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json" 0 NoWow6432
  nsExec::ExecToStack 'powershell.exe -NoProfile -Command "try { $$j = Get-Content -LiteralPath ''$APPDATA\..\..\ProgramData\go-mapi\uninst\previous-mail-client.json'' -Raw | ConvertFrom-Json; if ($$null -ne $$j.previousClient32) { Write-Output $$j.previousClient32 } exit 0 } catch { exit 1 }"'
  Pop $4    ; exit code
  Pop $1    ; stdout
  StrCmp $4 "0" 0 NoWow6432
  StrLen $4 $1
  IntCmp $4 2 0 WowSkipTrim 0
  StrCpy $1 $1 -2
WowSkipTrim:
  StrCmp $1 "" NoWow6432
  SetRegView 32
  ReadRegStr $5 HKLM "SOFTWARE\Clients\Mail\$1" ""
  StrCmp $5 "" WowKeyGone
  WriteRegStr HKLM "SOFTWARE\Clients\Mail" "" "$1"
  DetailPrint "Restored WOW6432 Mail (Default) to: $1"
  Goto WowDone
WowKeyGone:
  DetailPrint "WOW6432 previous client subkey missing — skipping restore"
WowDone:
  SetRegView default
  Goto Wow6432End
NoWow6432:
Wow6432End:
FunctionEnd

; Helper: case-sensitive substring check. Push haystack, push needle. Pops "1" (found) or "0".
Function un.StrContains
  Exch $R1   ; needle
  Exch
  Exch $R2   ; haystack
  Push $R3   ; needle-length
  Push $R4   ; haystack cursor
  Push $R5   ; needle cursor
  StrLen $R3 $R1
  StrCpy $R4 0
un.SC_Loop:
  StrCpy $R5 $R2 $R3 $R4
  StrCmp $R5 $R1 un.SC_Found
  StrCmp $R5 "" un.SC_NotFound   ; cursor past end of haystack
  IntOp $R4 $R4 + 1
  Goto un.SC_Loop
un.SC_Found:
  StrCpy $R1 "1"
  Goto un.SC_Done
un.SC_NotFound:
  StrCpy $R1 "0"
un.SC_Done:
  ; IN-02: correct save/restore sequence. Prelude saved prev$R1, prev$R2 via
  ; Exch $R1; Exch; Exch $R2 (2 saves, stack = [prev$R1, prev$R2]), then
  ; Push $R3..$R5 (stack = [prev$R1, prev$R2, prev$R3, prev$R4, prev$R5]).
  ; Result lives in $R1. Exit: pop $R5..$R3, pop prev$R2 into $R2, then Exch $R1
  ; swaps the remaining prev$R1 on stack with the result in $R1 — caller sees
  ; the result on top of stack, $R1 is restored, $R2 is restored.
  Pop $R5
  Pop $R4
  Pop $R3
  Pop $R2     ; restore prev$R2
  Exch $R1    ; swap prev$R1 on stack with result in $R1: stack top = result, $R1 = prev$R1
FunctionEnd

; Helper: extract substring between two delimiters. Push haystack, push startDelim, push endDelim.
; Returns the substring on the stack, or "" if not found.
Function un.StrExtract
  Exch $R1   ; endDelim
  Exch
  Exch $R2   ; startDelim
  Exch 2
  Exch $R3   ; haystack
  Push $R4   ; startDelim-length
  Push $R5   ; startIndex
  Push $R6   ; cursor/endIndex
  Push $R7   ; temp
  StrLen $R4 $R2
  StrCpy $R5 0
un.SE_FindStart:
  StrCpy $R7 $R3 $R4 $R5
  StrCmp $R7 $R2 un.SE_FoundStart
  StrCmp $R7 "" un.SE_NotFound
  IntOp $R5 $R5 + 1
  Goto un.SE_FindStart
un.SE_FoundStart:
  IntOp $R5 $R5 + $R4     ; cursor past startDelim
  StrCpy $R6 $R5
un.SE_FindEnd:
  StrCpy $R7 $R3 1 $R6
  StrCmp $R7 $R1 un.SE_FoundEnd
  StrCmp $R7 "" un.SE_NotFound
  IntOp $R6 $R6 + 1
  Goto un.SE_FindEnd
un.SE_FoundEnd:
  IntOp $R7 $R6 - $R5
  StrCpy $R1 $R3 $R7 $R5
  Goto un.SE_Done
un.SE_NotFound:
  StrCpy $R1 ""
un.SE_Done:
  ; IN-03: correct save/restore sequence. Prelude:
  ;   Exch $R1 (save prev$R1), Exch, Exch $R2 (save prev$R2), Exch 2, Exch $R3
  ;   (save prev$R3). Post-prelude stack (bottom->top):
  ;     [prev$R2, prev$R1, prev$R3]
  ;   Then Push $R4..$R7 adds 4 items. Full stack:
  ;     [prev$R2, prev$R1, prev$R3, prev$R4, prev$R5, prev$R6, prev$R7]
  ; Result lives in $R1. Cleanup: pop R7..R4 (restores R4..R7), Pop R3 (restores
  ; prev$R3), then the remaining stack is [prev$R2, prev$R1]. We need to restore
  ; $R2 = prev$R2 and $R1 = prev$R1, and push result. Swap the top two so
  ; prev$R2 is on top, Pop into $R2, then Exch $R1 swaps prev$R1 with result.
  Pop $R7
  Pop $R6
  Pop $R5
  Pop $R4
  Pop $R3     ; restore prev$R3
  Exch        ; swap top two: stack was [prev$R2, prev$R1] -> [prev$R1, prev$R2]
  Pop $R2     ; restore prev$R2
  Exch $R1    ; swap prev$R1 on stack with result in $R1: stack top = result, $R1 = prev$R1
FunctionEnd

;------------------------------------------------------------------------------
; un.EnsureAppNotRunning — QUICK-260423-ntu T2 (uninstaller scope)
;
; Byte-for-byte duplicate of EnsureAppNotRunning above with the un. prefix
; required by NSIS for uninstaller-scope functions. NSIS macros would avoid
; the duplication but the body is small enough that inline is clearer.
; Uses un.StrContains (already defined above).
;------------------------------------------------------------------------------

Function un.EnsureAppNotRunning
  Push $0
  Push $1

  nsExec::ExecToStack 'tasklist /FI "IMAGENAME eq go-mapi.exe" /NH /FO CSV'
  Pop $0
  Pop $1

  Push $1
  Push "go-mapi.exe"
  Call un.StrContains
  Pop $0
  StrCmp $0 "1" unEANR_Found unEANR_NotFound

unEANR_Found:
  DetailPrint "go-mapi.exe is running — attempting graceful close"
  IfSilent unEANR_SilentRetry unEANR_AskUser

unEANR_AskUser:
  MessageBox MB_OKCANCEL|MB_ICONEXCLAMATION "go-mapi is currently running. Click OK to close it and continue, or Cancel to abort the uninstaller." IDOK unEANR_SilentRetry IDCANCEL unEANR_Cancel

unEANR_Cancel:
  DetailPrint "User cancelled — aborting uninstaller"
  Pop $1
  Pop $0
  Abort "Uninstaller aborted by user (go-mapi was running)."

unEANR_SilentRetry:
  nsExec::ExecToStack 'taskkill /IM go-mapi.exe'
  Pop $0
  Pop $1
  DetailPrint "taskkill /IM go-mapi.exe rc=$0"

  StrCpy $0 0
unEANR_PollLoop:
  Sleep 500
  nsExec::ExecToStack 'tasklist /FI "IMAGENAME eq go-mapi.exe" /NH /FO CSV'
  Pop $1
  Pop $1
  Push $1
  Push "go-mapi.exe"
  Call un.StrContains
  Pop $1
  StrCmp $1 "0" unEANR_Exited
  IntOp $0 $0 + 1
  IntCmp $0 20 unEANR_Timeout
  Goto unEANR_PollLoop

unEANR_Timeout:
  DetailPrint "ERROR: go-mapi.exe did not exit within 10s"
  Pop $1
  Pop $0
  IfSilent unEANR_SilentAbort
  MessageBox MB_OK|MB_ICONSTOP "go-mapi did not close within 10 seconds. Please close it manually and re-run the uninstaller."
unEANR_SilentAbort:
  Abort "go-mapi.exe still running after 10s close poll."

unEANR_Exited:
  DetailPrint "go-mapi.exe exited after $0 poll iterations"
  Pop $1
  Pop $0
  Return

unEANR_NotFound:
  Pop $1
  Pop $0
FunctionEnd

;------------------------------------------------------------------------------
; un.RemoveScheduledTask — Phase 11.1 D-16
;
; Idempotent removal of the silent-update Scheduled Task. Runs unconditionally
; — installs that did NOT register the task (e.g. /AUTOUPDATE=0) still call
; this; rc=1 ("task not found") is swallowed. /F suppresses the confirmation
; prompt. Logged via DetailPrint for installer-log forensic trail.
;------------------------------------------------------------------------------

Function un.RemoveScheduledTask
  ExecWait 'schtasks /delete /tn "go-mapi Auto Update" /f' $0
  DetailPrint "schtasks /delete rc=$0 (0=removed, 1=not found — both ok)"
FunctionEnd

;------------------------------------------------------------------------------
; un.ScrubOldOrphans — Phase 11.1 W7
;
; Belt-and-braces cleanup of *.old.<pid> orphan files left behind by the
; silent updater's MoveFileEx rename-while-running pattern (Plan 11.1-04
; swapInPlace). Plan 11.1-04 cleans these proactively at silent-update start;
; this uninstaller helper catches any orphans that survive past the last
; update cycle. Pattern matches both go-mapi.exe.old.<pid> and
; go-mapi.dll.old.<pid> via NSIS FindFirst/FindNext.
;
; Stack contract: caller pushes the directory path (e.g. "$INSTDIR"), function
; pops it, scrubs all "*.old.*" matches in that directory, returns nothing.
;------------------------------------------------------------------------------

Function un.ScrubOldOrphans
  Pop $R0   ; directory path (e.g. "$INSTDIR")
  Push $R1
  Push $R2

  ClearErrors
  FindFirst $R1 $R2 "$R0\*.old.*"
  IfErrors un.SOO_Done
un.SOO_Loop:
  StrCmp $R2 "" un.SOO_Done
  Delete "$R0\$R2"
  DetailPrint "scrubbed orphan: $R0\$R2"
  ClearErrors
  FindNext $R1 $R2
  IfErrors un.SOO_Done
  Goto un.SOO_Loop
un.SOO_Done:
  FindClose $R1
  Pop $R2
  Pop $R1
FunctionEnd
