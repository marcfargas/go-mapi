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

  ; WR-02: escape $0 for JSON string context before interpolation. A mail
  ; client display name may legally contain `"` or `\` (e.g. locale-specific
  ; or custom enterprise names) which would otherwise produce invalid JSON
  ; and break the uninstaller's restore path (which parses the file).
  Push $0
  Call EscapeJsonString
  Pop $0

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
; Uninstall section
;
; Full 10-step scrub (D-18) lives in plan 10-04. This stub keeps the
; uninstaller compilable so `makensis` does not fail on the scaffold plan.
;------------------------------------------------------------------------------

Section "Uninstall"
  ; D-18: 10-step full scrub. Steps execute in order; failures log but do
  ; not abort — we want to get as close to a clean state as possible even
  ; when some steps fail (e.g. firewall rule GPO-locked, AV-locked file).

  ; 1. Firewall rule — name MUST match plan 10-03 AddFirewallRule byte-for-byte
  ExecWait 'netsh advfirewall firewall delete rule name="go-mapi OAuth loopback"' $0
  DetailPrint "firewall delete rule rc=$0"

  ; 2. Start Menu shortcut (plan 10-03 stamped the AUMID on this .lnk)
  Delete "$SMPROGRAMS\go-mapi.lnk"

  ; 3. MAPI handler key
  DeleteRegKey HKLM "SOFTWARE\Clients\Mail\go-mapi"

  ; 4. Restore (Default) Mail client from backup (D-11)
  Call un.RestorePreviousMailClient

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

  ; 9. Binaries
  Delete "$INSTDIR\go-mapi.exe"
  Delete "$INSTDIR\go-mapi.dll"
  Delete "$INSTDIR\uninstall.exe"
  Delete "$INSTDIR\install.log"

  ; 9b. Diagnostic scripts (QUICK-260423-msq)
  Delete "$INSTDIR\diagnostics\collect-registration.ps1"
  Delete "$INSTDIR\diagnostics\collect-runtime.ps1"
  RMDir  "$INSTDIR\diagnostics"

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
