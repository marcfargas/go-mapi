; go-mapi installer (Inno Setup 6)
;
; Phase 3 / INST-01..INST-06 / 03-01-PLAN
;
; This script builds a single Windows installer executable that:
;   - Copies go-mapi.dll and go-mapi-host.exe to %ProgramFiles%\go-mapi
;   - Registers the MAPI handler at HKLM\SOFTWARE\Clients\Mail\go-mapi
;   - Backs up the previous default Mail client to
;     %ProgramData%\go-mapi\uninst\previous-mail-client.json before overwriting
;   - Renders a single native-messaging manifest from the shared .tmpl file
;     (src/native-host/manifests/com.gomapi.host.chrome.json.tmpl) to
;     %ProgramData%\go-mapi\com.gomapi.host.json
;   - Writes five HKLM browser native-messaging registry trees (Chrome,
;     Chromium, Edge, Brave, Vivaldi) all pointing at the shared manifest
;   - Uninstalls cleanly: removes everything it installed and restores the
;     previous default Mail client from the backup JSON
;
; The installer requires a single UAC elevation prompt and writes no per-user
; state (all state under HKLM and %ProgramData%\go-mapi\).
;
; Build:
;   iscc /DGOMAPIVersion=1.0.0 src\installer\go-mapi.iss
;
; Output: src\installer\dist\go-mapi-setup.exe
;
; The .tmpl file is embedded in the compiled installer via the [Files] section
; with the `dontcopy` flag, then extracted on install via ExtractTemporaryFile
; and rendered by the RenderManifest() Pascal function. This keeps one source
; of truth for the manifest schema shared with scripts\install.ps1.

#ifndef GOMAPIVersion
  #define GOMAPIVersion "0.0.0-dev"
#endif

#define AppName "go-mapi"
#define AppPublisher "Marc Fargas"
#define AppURL "https://github.com/marcfargas/go-mapi"
#define SupportURL "https://github.com/marcfargas/go-mapi/issues"
#define UpdatesURL "https://github.com/marcfargas/go-mapi/releases"

[Setup]
AppId={{A5F0B0B6-3E2A-4B5C-8C7D-9F1E2A3B4C5D}
AppName={#AppName}
AppVersion={#GOMAPIVersion}
AppVerName={#AppName} {#GOMAPIVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#SupportURL}
AppUpdatesURL={#UpdatesURL}
DefaultDirName={autopf}\go-mapi
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=no
PrivilegesRequired=admin
OutputBaseFilename=go-mapi-setup
OutputDir=dist
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
MinVersion=10.0.17763
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\go-mapi-host.exe
LicenseFile={#SourcePath}\..\..\LICENSE
; Single UAC prompt — no elevation beyond initial launch.
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Payload binaries — produced by `npm run build:interceptor` and
; `npm run build:native-host` before iscc is invoked.
Source: "{#SourcePath}\..\..\src\interceptor\build\bin\go-mapi.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\..\..\src\native-host\build\go-mapi-host.exe"; DestDir: "{app}"; Flags: ignoreversion

; Native-messaging manifest template — embedded in the installer via
; `dontcopy`; extracted on install via ExtractTemporaryFile() from the
; [Code] section. This keeps the manifest schema in one place
; (src/native-host/manifests/...tmpl) shared with install.ps1.
Source: "{#SourcePath}\..\..\src\native-host\manifests\com.gomapi.host.chrome.json.tmpl"; Flags: dontcopy

[Dirs]
; Create the shared %ProgramData%\go-mapi directory and the uninst subdir for
; the previous-client backup. uninsneveruninstall — we manage deletion
; explicitly in the CurUninstallStepChanged handler so we can check for
; emptiness first.
Name: "{commonappdata}\go-mapi"; Flags: uninsneveruninstall
Name: "{commonappdata}\go-mapi\uninst"; Flags: uninsneveruninstall

[Registry]
; --- MAPI handler registration at HKLM\SOFTWARE\Clients\Mail\go-mapi ---
; The (Default) value on the handler key is the display name; DLLPath is the
; absolute path to the handler DLL that mapi32.dll forwards calls to.
; The HKLM\SOFTWARE\Clients\Mail (Default) value (= active default Mail
; client) is NOT set here — it is set from Pascal code AFTER the previous
; client backup has been written.
Root: HKLM; Subkey: "SOFTWARE\Clients\Mail\go-mapi"; ValueType: string; ValueName: ""; ValueData: "go-mapi"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\Clients\Mail\go-mapi"; ValueType: string; ValueName: "DLLPath"; ValueData: "{app}\go-mapi.dll"

; --- Five browser native-messaging registry trees ---
; All under HKLM so the manifest is machine-wide (INST-04: no per-user state).
; Each key's (Default) value is the absolute path to the shared manifest file
; at %ProgramData%\go-mapi\com.gomapi.host.json.
Root: HKLM; Subkey: "SOFTWARE\Google\Chrome\NativeMessagingHosts\com.gomapi.host"; ValueType: string; ValueName: ""; ValueData: "{commonappdata}\go-mapi\com.gomapi.host.json"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\Chromium\NativeMessagingHosts\com.gomapi.host"; ValueType: string; ValueName: ""; ValueData: "{commonappdata}\go-mapi\com.gomapi.host.json"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\Microsoft\Edge\NativeMessagingHosts\com.gomapi.host"; ValueType: string; ValueName: ""; ValueData: "{commonappdata}\go-mapi\com.gomapi.host.json"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.gomapi.host"; ValueType: string; ValueName: ""; ValueData: "{commonappdata}\go-mapi\com.gomapi.host.json"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\Vivaldi\NativeMessagingHosts\com.gomapi.host"; ValueType: string; ValueName: ""; ValueData: "{commonappdata}\go-mapi\com.gomapi.host.json"; Flags: uninsdeletekey

[Code]
const
  // Chrome Web Store extension ID. Placeholder until the CWS listing is
  // published. When the listing goes live, update this constant and rebuild
  // the installer. Same placeholder as scripts\install.ps1.
  GO_MAPI_EXTENSION_ID = 'PLACEHOLDER_EXTENSION_ID_32CHR';

  MAIL_CLIENTS_KEY = 'SOFTWARE\Clients\Mail';
  GO_MAPI_MAIL_CLIENT_NAME = 'go-mapi';

// --- Helpers ----------------------------------------------------------------

// RenderManifest reads the native-messaging manifest template file, performs
// literal string substitution of the {{HOST_PATH}} and {{EXTENSION_ID}}
// placeholders, and returns the rendered JSON as a string.
//
// The HostExePath is JSON-escaped by doubling backslashes before insertion,
// matching the behavior of the PowerShell Render-ManifestTemplate helper in
// scripts\install.ps1 (see the comment block around line 180 there). Without
// escaping, Windows paths like C:\Program Files\go-mapi\go-mapi-host.exe
// would produce invalid JSON because \g, \P etc. are not legal JSON string
// escapes.
function RenderManifest(const TemplatePath, HostExePath, ExtensionId: String): String;
var
  Template: AnsiString;
  Rendered: String;
  HostPathEscaped: String;
begin
  if not LoadStringFromFile(TemplatePath, Template) then
  begin
    Log('RenderManifest: failed to load template from ' + TemplatePath);
    Result := '';
    Exit;
  end;

  Rendered := String(Template);

  // JSON-escape backslashes in the host path before substitution.
  HostPathEscaped := HostExePath;
  StringChange(HostPathEscaped, '\', '\\');

  // Literal placeholder substitution — no regex, no escaping concerns because
  // {{HOST_PATH}} and {{EXTENSION_ID}} contain no regex metacharacters and
  // StringChange is a plain substring replace.
  StringChange(Rendered, '{{HOST_PATH}}', HostPathEscaped);
  StringChange(Rendered, '{{EXTENSION_ID}}', ExtensionId);

  Result := Rendered;
end;

// BackupPreviousMailClient reads HKLM\SOFTWARE\Clients\Mail (Default) and, if
// the current value is neither empty nor 'go-mapi' and no backup file already
// exists, writes a JSON backup to %ProgramData%\go-mapi\uninst\previous-mail-client.json.
//
// The "don't overwrite existing backup" rule (D-09) preserves the original
// backup across upgrade reinstalls — we want to restore the client that was
// the default BEFORE go-mapi was first installed, not the value from a
// previous go-mapi install cycle.
procedure BackupPreviousMailClient();
var
  CurrentDefault: String;
  BackupDir: String;
  BackupFile: String;
  Timestamp: String;
  BackupJson: String;
begin
  BackupDir := ExpandConstant('{commonappdata}\go-mapi\uninst');
  BackupFile := BackupDir + '\previous-mail-client.json';

  if FileExists(BackupFile) then
  begin
    Log('BackupPreviousMailClient: backup already exists, preserving it');
    Exit;
  end;

  CurrentDefault := '';
  RegQueryStringValue(HKLM, MAIL_CLIENTS_KEY, '', CurrentDefault);

  if (CurrentDefault = '') or (CurrentDefault = GO_MAPI_MAIL_CLIENT_NAME) then
  begin
    Log('BackupPreviousMailClient: current default is empty or go-mapi, skipping backup');
    Exit;
  end;

  ForceDirectories(BackupDir);

  // ISO-8601 with explicit Z suffix. GetDateTimeString uses local time — the
  // Z is a white lie but keeps the format consistent with other go-mapi
  // timestamp fields and is clearly documented as installer-written.
  Timestamp := GetDateTimeString('yyyy-mm-dd''T''hh:nn:ss', #0, #0) + 'Z';

  BackupJson :=
    '{"previousClient":"' + CurrentDefault + '",' +
    '"backedUpAt":"' + Timestamp + '"}';

  if SaveStringToFile(BackupFile, BackupJson, False) then
    Log('BackupPreviousMailClient: saved ' + CurrentDefault + ' to ' + BackupFile)
  else
    Log('BackupPreviousMailClient: failed to save backup to ' + BackupFile);
end;

// SetGoMapiAsDefaultMailClient writes 'go-mapi' to HKLM\SOFTWARE\Clients\Mail
// (Default). Called after BackupPreviousMailClient so the backup captures the
// pre-install value.
procedure SetGoMapiAsDefaultMailClient();
begin
  if RegWriteStringValue(HKLM, MAIL_CLIENTS_KEY, '', GO_MAPI_MAIL_CLIENT_NAME) then
    Log('SetGoMapiAsDefaultMailClient: (Default) set to go-mapi')
  else
    Log('SetGoMapiAsDefaultMailClient: failed to set (Default)');
end;

// WriteSharedManifest extracts the embedded manifest template to the
// installer's temp directory, renders it via RenderManifest, and writes the
// result to %ProgramData%\go-mapi\com.gomapi.host.json.
procedure WriteSharedManifest();
var
  TemplatePath: String;
  ManifestPath: String;
  HostExePath: String;
  Rendered: String;
begin
  ExtractTemporaryFile('com.gomapi.host.chrome.json.tmpl');
  TemplatePath := ExpandConstant('{tmp}\com.gomapi.host.chrome.json.tmpl');

  HostExePath := ExpandConstant('{app}\go-mapi-host.exe');
  ManifestPath := ExpandConstant('{commonappdata}\go-mapi\com.gomapi.host.json');

  Rendered := RenderManifest(TemplatePath, HostExePath, GO_MAPI_EXTENSION_ID);

  if Rendered = '' then
  begin
    Log('WriteSharedManifest: RenderManifest returned empty string');
    Exit;
  end;

  ForceDirectories(ExpandConstant('{commonappdata}\go-mapi'));

  if SaveStringToFile(ManifestPath, Rendered, False) then
    Log('WriteSharedManifest: wrote manifest to ' + ManifestPath)
  else
    Log('WriteSharedManifest: failed to write manifest to ' + ManifestPath);
end;

// ExtractJsonStringField is a minimal string extractor for the
// {"previousClient":"VALUE","backedUpAt":"..."} format written by
// BackupPreviousMailClient. Pascal Script has no JSON parser; the format is
// strict and controlled, so substring extraction is safe.
function ExtractJsonStringField(const Json, FieldName: String): String;
var
  SearchKey: String;
  StartPos, ValueStart, ValueEnd: Integer;
begin
  Result := '';
  SearchKey := '"' + FieldName + '":"';
  StartPos := Pos(SearchKey, Json);
  if StartPos = 0 then
    Exit;
  ValueStart := StartPos + Length(SearchKey);
  ValueEnd := ValueStart;
  while (ValueEnd <= Length(Json)) and (Json[ValueEnd] <> '"') do
    ValueEnd := ValueEnd + 1;
  if ValueEnd > Length(Json) then
    Exit;
  Result := Copy(Json, ValueStart, ValueEnd - ValueStart);
end;

// RestorePreviousMailClient reads the backup JSON written at install time and
// restores HKLM\SOFTWARE\Clients\Mail (Default) to the saved value if the
// corresponding subkey still exists. Falls back to well-known Mail client
// names (Outlook, Windows Mail) or clears the value if nothing is usable.
procedure RestorePreviousMailClient();
var
  BackupFile: String;
  BackupContents: AnsiString;
  PreviousClient: String;
  FallbackNames: TArrayOfString;
  I: Integer;
  Restored: Boolean;
begin
  BackupFile := ExpandConstant('{commonappdata}\go-mapi\uninst\previous-mail-client.json');
  Restored := False;

  if FileExists(BackupFile) and LoadStringFromFile(BackupFile, BackupContents) then
  begin
    PreviousClient := ExtractJsonStringField(String(BackupContents), 'previousClient');
    if (PreviousClient <> '') and RegKeyExists(HKLM, MAIL_CLIENTS_KEY + '\' + PreviousClient) then
    begin
      if RegWriteStringValue(HKLM, MAIL_CLIENTS_KEY, '', PreviousClient) then
      begin
        Log('RestorePreviousMailClient: restored ' + PreviousClient + ' from backup');
        Restored := True;
      end;
    end;
  end;

  if not Restored then
  begin
    // Fallback order matches scripts\install.ps1 uninstall path.
    SetArrayLength(FallbackNames, 3);
    FallbackNames[0] := 'Microsoft Outlook';
    FallbackNames[1] := 'Outlook';
    FallbackNames[2] := 'Windows Mail';

    for I := 0 to GetArrayLength(FallbackNames) - 1 do
    begin
      if RegKeyExists(HKLM, MAIL_CLIENTS_KEY + '\' + FallbackNames[I]) then
      begin
        if RegWriteStringValue(HKLM, MAIL_CLIENTS_KEY, '', FallbackNames[I]) then
        begin
          Log('RestorePreviousMailClient: fell back to ' + FallbackNames[I]);
          Restored := True;
          Break;
        end;
      end;
    end;
  end;

  if not Restored then
  begin
    RegWriteStringValue(HKLM, MAIL_CLIENTS_KEY, '', '');
    Log('RestorePreviousMailClient: cleared (Default) — no previous client or fallback available');
  end;
end;

// CleanTempGoMapi best-effort deletes the %TEMP%\go-mapi directory (the
// watcher's drop zone). Per D-15, this only cleans the %TEMP% visible to the
// uninstaller (typically the SYSTEM account's temp, since uninstall runs
// elevated). Real user-profile %TEMP%\go-mapi directories are not iterated —
// they are already deleted on-process by the native host per the project's
// privacy-first policy, so leftovers only exist on abnormal termination.
procedure CleanTempGoMapi();
var
  TempDir: String;
  GoMapiTempDir: String;
begin
  TempDir := GetEnv('TEMP');
  if TempDir = '' then
    Exit;
  GoMapiTempDir := TempDir + '\go-mapi';
  if DirExists(GoMapiTempDir) then
  begin
    if DelTree(GoMapiTempDir, True, True, True) then
      Log('CleanTempGoMapi: removed ' + GoMapiTempDir)
    else
      Log('CleanTempGoMapi: failed to remove ' + GoMapiTempDir + ' (best-effort, ignoring)');
  end;
end;

// --- Install event hook -----------------------------------------------------

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    // Back up BEFORE the [Registry] section runs (it runs at ssPostInstall)
    // so the backup captures the truly pre-install value. Inno Setup runs
    // ssInstall before writing [Registry] entries.
    BackupPreviousMailClient();
  end
  else if CurStep = ssPostInstall then
  begin
    // By ssPostInstall, [Files] and [Registry] have both run. Write the
    // rendered manifest (depends on {app} being populated) and set go-mapi as
    // the active default Mail client.
    WriteSharedManifest();
    SetGoMapiAsDefaultMailClient();
  end;
end;

// --- Uninstall event hook ---------------------------------------------------

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  CurrentDefault: String;
  ManifestPath: String;
  BackupFile: String;
  UninstDir: String;
  GoMapiProgramData: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    // If go-mapi is still the default Mail client, restore the previous one.
    CurrentDefault := '';
    RegQueryStringValue(HKLM, MAIL_CLIENTS_KEY, '', CurrentDefault);
    if CurrentDefault = GO_MAPI_MAIL_CLIENT_NAME then
      RestorePreviousMailClient();

    // Delete the shared manifest file.
    ManifestPath := ExpandConstant('{commonappdata}\go-mapi\com.gomapi.host.json');
    if FileExists(ManifestPath) then
    begin
      if DeleteFile(ManifestPath) then
        Log('Uninstall: removed ' + ManifestPath)
      else
        Log('Uninstall: failed to remove ' + ManifestPath);
    end;

    // Delete the previous-client backup JSON and the uninst directory.
    BackupFile := ExpandConstant('{commonappdata}\go-mapi\uninst\previous-mail-client.json');
    if FileExists(BackupFile) then
    begin
      DeleteFile(BackupFile);
      Log('Uninstall: removed ' + BackupFile);
    end;

    UninstDir := ExpandConstant('{commonappdata}\go-mapi\uninst');
    if DirExists(UninstDir) then
    begin
      RemoveDir(UninstDir);
      Log('Uninstall: removed ' + UninstDir);
    end;

    GoMapiProgramData := ExpandConstant('{commonappdata}\go-mapi');
    if DirExists(GoMapiProgramData) then
    begin
      RemoveDir(GoMapiProgramData);
      Log('Uninstall: removed ' + GoMapiProgramData);
    end;

    // Best-effort cleanup of %TEMP%\go-mapi.
    CleanTempGoMapi();
  end;
end;
