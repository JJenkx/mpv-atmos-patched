; mpv-patched.iss — Inno Setup 6 installer for the patched portable mpv+FFmpeg
;
; Two modes, chosen on a wizard page (or /PORTABLE=1 on the command line):
;   • System install  — Program Files, Start menu, file associations
;                       (Default Programs pattern), uninstaller.
;   • Portable install — pure extraction to any folder: no registry writes,
;                       no uninstaller, nothing outside the chosen dir.
; BOTH modes ship the identical self-contained payload: every DLL beside
; mpv.exe and the full portable_config/ (mpv's native portable mode), so the
; player is never affected by system libraries or other ffmpeg installs.
;
; Compile: wine ISCC.exe mpv-patched.iss   (see ../build_installer.sh)

; These are overridable from the command line, so ONE script builds both variants:
;   ISCC /DAppName=mpv-enhanced-atmos /DAppId={{...}} /DDisplayName="mpv (Enhanced + Atmos)" ...
; The AppId MUST differ per variant, or installing one would upgrade/uninstall the
; other and they could not coexist.
#ifndef AppName
  #define AppName    "mpv-atmos"
#endif
#ifndef DisplayName
  #define DisplayName "mpv (Atmos)"
#endif
#ifndef AppId
  #define AppId      "{{9E6A2A6B-30F2-4D2C-9E7A-5B1C64A1E58D}"
#endif
#ifndef AppPublisher
  #define AppPublisher "custom build"
#endif
#ifndef AppVersion
  #define AppVersion GetDateTimeString('yyyy.mm.dd', '-', ':')
#endif
#ifndef DistDir
  #define DistDir    "..\dist-win"
#endif
#ifndef IconFile
  #define IconFile   "..\mpv-win\src\mpv\etc\mpv-icon.ico"
#endif
; Space-separated media extensions to register in system mode
#define Exts "mkv mp4 m4v avi webm mov wmv ts m2ts mts mpg mpeg vob flv ogv 3gp flac mp3 m4a aac opus ogg oga wav wv dts ac3 eac3 thd mka ape"

[Setup]
AppId={#AppId}
AppName={#DisplayName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=auto
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog commandline
OutputDir=Output
OutputBaseFilename={#AppName}-setup
Compression=lzma2/max
SolidCompression=yes
LZMAUseSeparateProcess=yes
SetupIconFile={#IconFile}
UninstallDisplayIcon={app}\mpv.exe
ChangesAssociations=yes
WizardStyle=modern
; Portable mode: no uninstaller files, no uninstall registry key
Uninstallable=not IsPortableMode
CreateUninstallRegKey=not IsPortableMode

[Files]
Source: "{#DistDir}\*"; Excludes: "dist-manifest.txt"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Dirs]
; System mode: state dirs inside portable_config must be writable by normal
; users even under Program Files. ACL only on portable_config — never on
; {app} itself (a user-writable DLL directory would invite DLL planting).
Name: "{app}\portable_config";              Permissions: users-modify; Check: not IsPortableMode
Name: "{app}\portable_config\watch_later";  Permissions: users-modify; Check: not IsPortableMode
Name: "{app}\portable_config\shader_cache"; Permissions: users-modify; Check: not IsPortableMode
Name: "{app}\portable_config\icc_cache";    Permissions: users-modify; Check: not IsPortableMode
Name: "{app}\portable_config\playlists";    Permissions: users-modify; Check: not IsPortableMode
; portable mode: same tree, no ACL fiddling (target is user-writable anyway)
Name: "{app}\portable_config\watch_later";  Check: IsPortableMode
Name: "{app}\portable_config\shader_cache"; Check: IsPortableMode
Name: "{app}\portable_config\icc_cache";    Check: IsPortableMode
Name: "{app}\portable_config\playlists";    Check: IsPortableMode

[Icons]
Name: "{group}\{#DisplayName}";  Filename: "{app}\mpv.exe"; Check: not IsPortableMode
Name: "{group}\ffmpeg (console)"; Filename: "{cmd}"; Parameters: "/k cd /d ""{app}"""; WorkingDir: "{app}"; Check: not IsPortableMode
Name: "{autodesktop}\{#DisplayName}"; Filename: "{app}\mpv.exe"; Tasks: desktopicon; Check: not IsPortableMode

[Tasks]
Name: desktopicon; Description: "Create a &desktop shortcut"; Flags: unchecked; Check: not IsPortableMode

[Registry]
; Default Programs pattern: capabilities + per-extension ProgIDs. mpv shows up
; in Windows' "Default apps" UI without stealing existing defaults.
Root: HKA; Subkey: "Software\Clients\Media\{#AppName}"; ValueType: string; ValueName: ""; ValueData: "{#AppName}"; Flags: uninsdeletekey; Check: not IsPortableMode
Root: HKA; Subkey: "Software\Clients\Media\{#AppName}\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "{#DisplayName}"; Check: not IsPortableMode
Root: HKA; Subkey: "Software\Clients\Media\{#AppName}\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "mpv with TrueHD/Dolby Atmos passthrough"; Check: not IsPortableMode
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "{#AppName}"; ValueData: "Software\Clients\Media\{#AppName}\Capabilities"; Flags: uninsdeletevalue; Check: not IsPortableMode

[Code]
var
  ModePage: TInputOptionWizardPage;

function IsPortableCmdLine(): Boolean;
begin
  Result := ExpandConstant('{param:PORTABLE|0}') = '1';
end;

function IsPortableMode(): Boolean;
begin
  if IsPortableCmdLine() then
    Result := True
  else if ModePage <> nil then
    Result := (ModePage.SelectedValueIndex = 1)
  else
    Result := False;
end;

procedure InitializeWizard();
begin
  ModePage := CreateInputOptionPage(wpWelcome,
    'Installation Mode', 'How should {#DisplayName} be installed?',
    'Both modes are fully self-contained (own FFmpeg, codecs and config; ' +
    'never affected by system libraries). Choose how it integrates:',
    True, False);
  ModePage.Add('System install' + #13#10 +
    'Program Files, Start menu entry, shows in Default-apps for media files, uninstaller.');
  ModePage.Add('Portable install' + #13#10 +
    'Just extract to a folder of your choice. No registry entries, no uninstaller. ' +
    'Settings live beside mpv.exe in portable_config.');
  ModePage.SelectedValueIndex := 0;
  if IsPortableCmdLine() then
    ModePage.SelectedValueIndex := 1;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  // Suggest a user-writable default for portable mode, but never clobber a
  // directory the user already chose (wizard edit or /DIR= on the command line).
  if (CurPageID = wpSelectDir) and IsPortableMode()
     and (WizardForm.DirEdit.Text = ExpandConstant('{autopf}\{#AppName}')) then
    WizardForm.DirEdit.Text := ExpandConstant('{userdocs}\{#AppName}');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if IsPortableMode() then
    if (PageID = wpSelectProgramGroup) or (PageID = wpSelectTasks) then
      Result := True;
end;

// Register per-extension ProgIDs at install time (system mode only).
// Done in code so the extension list stays a single #define.
procedure RegisterExtensions();
var
  Exts: TStringList;
  i: Integer;
  Ext, ProgId, ExePath: String;
begin
  ExePath := ExpandConstant('{app}\mpv.exe');
  Exts := TStringList.Create;
  try
    Exts.Delimiter := ' ';
    Exts.DelimitedText := '{#Exts}';
    for i := 0 to Exts.Count - 1 do
    begin
      Ext := Exts[i];
      ProgId := '{#AppName}.' + Ext;
      RegWriteStringValue(HKA, 'Software\Classes\' + ProgId, '', 'Media file (' + Ext + ')');
      RegWriteStringValue(HKA, 'Software\Classes\' + ProgId + '\DefaultIcon', '', '"' + ExePath + '",0');
      RegWriteStringValue(HKA, 'Software\Classes\' + ProgId + '\shell\open\command', '', '"' + ExePath + '" -- "%1"');
      RegWriteStringValue(HKA, 'Software\Classes\.' + Ext + '\OpenWithProgids', ProgId, '');
      RegWriteStringValue(HKA, 'Software\Clients\Media\{#AppName}\Capabilities\FileAssociations', '.' + Ext, ProgId);
    end;
  finally
    Exts.Free;
  end;
end;

procedure UnregisterExtensions();
var
  Exts: TStringList;
  i: Integer;
  Ext, ProgId: String;
begin
  Exts := TStringList.Create;
  try
    Exts.Delimiter := ' ';
    Exts.DelimitedText := '{#Exts}';
    for i := 0 to Exts.Count - 1 do
    begin
      Ext := Exts[i];
      ProgId := '{#AppName}.' + Ext;
      RegDeleteKeyIncludingSubkeys(HKA, 'Software\Classes\' + ProgId);
      RegDeleteValue(HKA, 'Software\Classes\.' + Ext + '\OpenWithProgids', ProgId);
    end;
  finally
    Exts.Free;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and (not IsPortableMode()) then
    RegisterExtensions();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    UnregisterExtensions();
end;
