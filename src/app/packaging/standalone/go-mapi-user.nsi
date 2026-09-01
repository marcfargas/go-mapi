Unicode true
RequestExecutionLevel user

!include "MUI2.nsh"
!include "nsDialogs.nsh"
!include "LogicLib.nsh"

!ifndef GOMAPI_VERSION
  !error "GOMAPI_VERSION is required"
!endif
!ifndef GOMAPI_EXE
  !error "GOMAPI_EXE is required"
!endif
!ifndef GOMAPI_OUTPUT
  !error "GOMAPI_OUTPUT is required"
!endif

Name "go-mapi"
OutFile "${GOMAPI_OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\go-mapi"
InstallDirRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi-user-v4" "InstallLocation"

Var AutostartCheckbox
Var AutostartEnabled
Var PurgeCheckbox
Var PurgeData

Function .onInit
  ; A first install defaults to startup-on even when the UI is suppressed.
  ; A silent reinstall has no user choice to apply, so retain the existing
  ; persisted preference and task state instead of resetting an opt-out.
  StrCpy $AutostartEnabled ${BST_CHECKED}
  IfSilent silentInstall interactiveInstall
silentInstall:
  IfFileExists "$APPDATA\go-mapi\settings.json" preserveSilentPreference interactiveInstall
preserveSilentPreference:
  StrCpy $AutostartEnabled -1
interactiveInstall:
FunctionEnd

Function un.onInit
  ; Silent/ordinary uninstall preserves per-user data unless the interactive
  ; user explicitly chooses the purge option.
  StrCpy $PurgeData ${BST_UNCHECKED}
FunctionEnd

!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
Page custom InstallOptionsPage InstallOptionsLeave
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
UninstPage custom un.DataOptionsPage un.DataOptionsLeave
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function InstallOptionsPage
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}
  ${NSD_CreateCheckbox} 0 12u 100% 12u "Start go-mapi when I sign in"
  Pop $AutostartCheckbox
  ${NSD_Check} $AutostartCheckbox
  nsDialogs::Show
FunctionEnd

Function InstallOptionsLeave
  ${NSD_GetState} $AutostartCheckbox $AutostartEnabled
FunctionEnd

Section "go-mapi" SEC_APP
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /oname=go-mapi.exe "${GOMAPI_EXE}"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi-user-v4" "DisplayName" "go-mapi"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi-user-v4" "DisplayVersion" "${GOMAPI_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi-user-v4" "Publisher" "Marc Fargas"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi-user-v4" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi-user-v4" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi-user-v4" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi-user-v4" "NoRepair" 1

  ${If} $AutostartEnabled == ${BST_CHECKED}
    ExecWait '"$INSTDIR\go-mapi.exe" --configure-autostart=true' $0
    ${If} $0 != 0
      IfSilent +2
      MessageBox MB_ICONEXCLAMATION "go-mapi was installed, but Windows did not register startup. You can fix this from the app."
    ${EndIf}
  ${ElseIf} $AutostartEnabled == ${BST_UNCHECKED}
    ExecWait '"$INSTDIR\go-mapi.exe" --configure-autostart=false' $0
    ${If} $0 != 0
      IfSilent +2
      MessageBox MB_ICONEXCLAMATION "go-mapi was installed, but the startup preference could not be saved. You can fix this from the app."
    ${EndIf}
  ${EndIf}
  ExecWait '"$INSTDIR\go-mapi.exe" --handoff-from-store' $0
  ${If} $0 != 0
    IfSilent +2
    MessageBox MB_ICONSTOP "The Microsoft Store handoff did not complete. go-mapi will not start a second queue consumer. Run this installer again to resume."
    Abort
  ${EndIf}
SectionEnd

Function un.DataOptionsPage
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}
  ${NSD_CreateCheckbox} 0 12u 100% 24u "Also remove settings, queued mail, logs, and saved sign-in credentials"
  Pop $PurgeCheckbox
  nsDialogs::Show
FunctionEnd

Function un.DataOptionsLeave
  ${NSD_GetState} $PurgeCheckbox $PurgeData
FunctionEnd

Section "Uninstall"
  SetShellVarContext current
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "go-mapi-user-startup-v4"
  ${If} $PurgeData == ${BST_CHECKED}
    ExecWait '"$INSTDIR\go-mapi.exe" --purge-user-data' $0
    ${If} $0 != 0
      IfSilent +2
      MessageBox MB_ICONSTOP "User data could not be completely removed. The application files will be left in place so the operation can be retried."
      Abort
    ${EndIf}
  ${EndIf}
  ; Do not retain $INSTDIR as the uninstaller process's current directory:
  ; Windows will otherwise reject the deferred directory removal even after
  ; all payload files have been deleted.
  SetOutPath "$TEMP"
  Delete "$INSTDIR\go-mapi.exe"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
  ; The running uninstaller cannot remove its own image until it exits. A
  ; short-lived external batch file runs after that handle is released and
  ; removes only this per-user install directory, then removes itself.
  FileOpen $0 "$TEMP\go-mapi-user-v4-cleanup.cmd" w
  FileWrite $0 "@echo off$\r$\n"
  ; The helper inherits $INSTDIR as its working directory. Switch away before
  ; retrying RMDir, otherwise Windows keeps that directory undeletable.
  FileWrite $0 "cd /d $\"$TEMP$\"$\r$\n"
  ; Retry until the uninstaller's own image handle has been released. A fixed
  ; delay races on slower Windows machines and leaves an empty install root.
  FileWrite $0 ":retry$\r$\n"
  FileWrite $0 "rmdir /s /q $\"$INSTDIR$\"$\r$\n"
  FileWrite $0 "if exist $\"$INSTDIR$\" (ping 127.0.0.1 -n 2 > NUL & goto retry)$\r$\n"
  FileWrite $0 "del $\"%~f0$\"$\r$\n"
  FileClose $0
  ; Start the batch through an explicitly detached cmd.exe. ExecShell can make
  ; the helper a child of this uninstaller, which deadlocks its retry loop on
  ; the still-open uninstall.exe image.
  Exec '"$SYSDIR\cmd.exe" /c start "" /b "$SYSDIR\cmd.exe" /c call "$TEMP\go-mapi-user-v4-cleanup.cmd"'
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\go-mapi-user-v4"
SectionEnd
