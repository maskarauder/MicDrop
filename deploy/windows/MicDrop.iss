; Build with tools/build_windows_installer.ps1 and the pinned Inno Setup compiler.
; The payload is a curated staging directory, never a live installation/user profile.
#ifndef PayloadDir
  #error PayloadDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef BuildRevision
  #error BuildRevision is required
#endif
#define VersionSuffix Pos("-", AppVersion)
#if VersionSuffix > 0
  #define NumericVersion Copy(AppVersion, 1, VersionSuffix - 1)
#else
  #define NumericVersion AppVersion
#endif

; Test variants have disjoint application/data paths, registry entries and mutexes.
; These are compiler definitions, not production installer command-line switches.
#ifdef InstallerTest
  #ifndef TestRoot
    #error TestRoot is required for InstallerTest
  #endif
  #ifndef TestId
    #error TestId is required for InstallerTest
  #endif
  ; Keep AppId below Inno's 57-character ANSI uninstall-key shortening limit.
  #define ProductId "MicDrop.Test." + TestId
  #define ProductName "MicDrop Installer Test " + TestId
  #define InstallDirectory TestRoot + "\app"
  #define DataDirectory TestRoot + "\data"
  ; Inno 7.1 CreateAnIcon omits the 64-bit uninstall flag. SYSTEM's Programs
  ; lives under System32 and would be redirected to SysWOW64 during deletion.
  #define ProgramDirectory TestRoot + "\start-menu"
  #define DesktopDirectory TestRoot + "\desktop"
  #define RunValue ProductId
  #define MutexPrefix "Local\" + ProductId + "."
#else
  #define ProductId "MicDrop.Desktop"
  #define ProductName "MicDrop"
  #define InstallDirectory "{localappdata}\Programs\MicDrop"
  #define DataDirectory "{localappdata}\MicDrop"
  #define ProgramDirectory "{userprograms}"
  #define DesktopDirectory "{userdesktop}"
  #define RunValue "MicDrop"
  #define MutexPrefix "Local\MicDrop.Desktop."
#endif

[Setup]
AppId={#ProductId}
AppName={#ProductName}
AppVersion={#AppVersion}
AppVerName={#ProductName} {#AppVersion} ({#BuildRevision})
AppComments=Development build. Microphone return requires a separately installed virtual audio cable.
DefaultDirName={#InstallDirectory}
DefaultGroupName={#ProductName}
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=no
UsePreviousAppDir=no
UsePreviousGroup=no
PrivilegesRequired=lowest
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
#ifdef InstallerTest
MinVersion=10.0
#else
MinVersion=10.0.22000
#endif
CloseApplications=no
RestartApplications=no
AlwaysRestart=no
RestartIfNeededByRun=no
AllowCancelDuringInstall=no
AllowNetworkDrive=no
AllowUNCPath=no
AllowRootDirectory=no
Uninstallable=not IsRemoving
UninstallDisplayIcon={app}\MicDrop.exe
UninstallDisplayName={#ProductName}
SetupLogging=yes
UninstallLogging=yes
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=MicDrop-{#AppVersion}-{#BuildRevision}-windows-x64-setup
VersionInfoVersion={#NumericVersion}
VersionInfoDescription=MicDrop development installer
VersionInfoProductTextVersion={#AppVersion} ({#BuildRevision})

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\MicDrop-maintenance.exe"; Flags: dontcopy
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Check: not IsRemoving

[Icons]
Name: "{#ProgramDirectory}\{#ProductName}\MicDrop"; Filename: "{app}\MicDrop.exe"; WorkingDir: "{app}"; Check: not IsRemoving
Name: "{#DesktopDirectory}\{#ProductName}"; Filename: "{app}\MicDrop.exe"; WorkingDir: "{app}"; Tasks: desktopicon; Check: not IsRemoving

[InstallDelete]
; Remove only known files shipped by previous packages, after ownership guards.
Type: files; Name: "{app}\windows-host.exe"; Check: not IsRemoving
Type: files; Name: "{app}\DESKTOP-GUIDE.md"; Check: not IsRemoving
Type: files; Name: "{app}\INPUT-BRIDGE-GUIDE.md"; Check: not IsRemoving
Type: files; Name: "{app}\MICROPHONE-RETURN-GUIDE.md"; Check: not IsRemoving
Type: files; Name: "{app}\DUPLEX-GUIDE.md"; Check: not IsRemoving
Type: files; Name: "{app}\HEADSET-INPUTS-GUIDE.md"; Check: not IsRemoving
Type: files; Name: "{app}\REMOTE-GUIDE.md"; Check: not IsRemoving
Type: files; Name: "{app}\M3_TURN_TESTING.md"; Check: not IsRemoving
Type: files; Name: "{app}\ADVANCED_SETTINGS.md"; Check: not IsRemoving
Type: files; Name: "{app}\ANDROID_ADB_TESTING.md"; Check: not IsRemoving
Type: files; Name: "{app}\PR39_REMAINING_TESTS.md"; Check: not IsRemoving
Type: files; Name: "{app}\M3_CLOSEOUT.md"; Check: not IsRemoving
Type: files; Name: "{app}\M3_ICE_STARTUP.md"; Check: not IsRemoving
Type: files; Name: "{app}\M3_ICE_TRICKLE.md"; Check: not IsRemoving
Type: files; Name: "{app}\M3_ROUTE_SELECTION.md"; Check: not IsRemoving
Type: files; Name: "{app}\INSTALLER-GUIDE.md"; Check: not IsRemoving
Type: files; Name: "{app}\latency-tools\latency.py"; Check: not IsRemoving
Type: files; Name: "{app}\latency-tools\requirements.txt"; Check: not IsRemoving
Type: files; Name: "{app}\latency-tools\README.md"; Check: not IsRemoving
Type: dirifempty; Name: "{app}\latency-tools"; Check: not IsRemoving
Type: files; Name: "{#DesktopDirectory}\{#ProductName}.lnk"; Check: RemoveDesktopShortcut

; No Run entry is created by setup. The existing in-app startup checkbox remains
; opt-in. No UninstallDelete wildcard: Inno only removes files it installed.

[Code]
const
  TokenQuery = $0008;
  TokenUser = 1;
  ErrorAlreadyExists = 183;
  ErrorFileNotFound = 2;
  ErrorPathNotFound = 3;
  GenericRead = $80000000;
  GenericWrite = $40000000;
  OpenExisting = 3;
  FileAttributeNormal = $80;
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';

type
  TTokenUserBuffer = record
    Sid: NativeUInt;
    Attributes: LongWord;
    { SID_AND_ATTRIBUTES plus enough inline space for any Windows user SID. }
    Reserved: array[0..1023] of Byte;
  end;

var
  DesktopMutex, PairingLock: THandle;
  MaintenancePage: TWizardPage;
  MaintenanceAction: String;
  AlreadyInstalled, HadDesktopShortcut: Boolean;
  InstalledVersion: String;

function WinGetCurrentProcess: THandle;
  external 'GetCurrentProcess@kernel32.dll stdcall';
function WinOpenProcessToken(ProcessHandle: THandle; DesiredAccess: LongWord;
  var TokenHandle: THandle): BOOL;
  external 'OpenProcessToken@advapi32.dll stdcall';
function WinGetTokenInformation(TokenHandle: THandle; InformationClass: Integer;
  var Information: TTokenUserBuffer; InformationLength: LongWord;
  var ReturnLength: LongWord): BOOL;
  external 'GetTokenInformation@advapi32.dll stdcall';
function WinConvertSidToStringSid(Sid: NativeUInt; var Text: NativeUInt): BOOL;
  external 'ConvertSidToStringSidW@advapi32.dll stdcall';
function CopyWideString(Destination: String; Source: NativeUInt;
  MaxCount: Integer): NativeUInt;
  external 'lstrcpynW@kernel32.dll stdcall';
function WideStringLength(Text: NativeUInt): Integer;
  external 'lstrlenW@kernel32.dll stdcall';
function WinLocalFree(Memory: NativeUInt): NativeUInt;
  external 'LocalFree@kernel32.dll stdcall';
function WinCloseHandle(Handle: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';
function WinCreateMutex(SecurityAttributes: NativeUInt; InitialOwner: BOOL;
  Name: String): THandle;
  external 'CreateMutexW@kernel32.dll stdcall';
function WinCreateFile(Name: String; Access, ShareMode: LongWord;
  SecurityAttributes: NativeUInt; CreationDisposition, Flags: LongWord;
  Template: THandle): THandle;
  external 'CreateFileW@kernel32.dll stdcall';

function UserSid: String;
var
  Token: THandle;
  User: TTokenUserBuffer;
  Needed: LongWord;
  Text: NativeUInt;
  Count: Integer;
begin
  Result := '';
  if not WinOpenProcessToken(WinGetCurrentProcess, TokenQuery, Token) then
    Exit;
  try
    if not WinGetTokenInformation(Token, TokenUser, User, SizeOf(User), Needed) then
      Exit;
    if not WinConvertSidToStringSid(User.Sid, Text) then
      Exit;
    try
      Count := WideStringLength(Text);
      if (Count < 3) or (Count > 184) then
        Exit;
      SetLength(Result, Count + 1);
      CopyWideString(Result, Text, Count + 1);
      SetLength(Result, Count);
    finally
      WinLocalFree(Text);
    end;
  finally
    WinCloseHandle(Token);
  end;
end;

procedure ReleaseGuards;
begin
  if PairingLock <> 0 then begin
    WinCloseHandle(PairingLock);
    PairingLock := 0;
  end;
  if DesktopMutex <> 0 then begin
    WinCloseHandle(DesktopMutex);
    DesktopMutex := 0;
  end;
end;

function OpenExistingExclusive(const Name: String; var Handle: THandle): Boolean;
var
  Code: LongWord;
begin
  Handle := WinCreateFile(Name, GenericRead or GenericWrite, 0, 0,
    OpenExisting, FileAttributeNormal, 0);
  Code := DLLGetLastError;
  Result := Handle <> THandle(-1);
  if not Result then begin
    Handle := 0;
    { A missing file is safe. Never create a pairing lock or user-data directory. }
    Result := (Code = ErrorFileNotFound) or (Code = ErrorPathNotFound);
  end;
end;

function AcquireGuards: String;
var
  Sid, Path: String;
  Code: LongWord;
  Probe: THandle;
  Index: Integer;
  Names: array[0..2] of String;
begin
  ReleaseGuards;
  Result := 'MicDrop files are still in use. Exit any elevated MicDrop copy, or close ' +
    'the program holding these files, then retry. No replacement/removal was started.';
  if CompareText(ExpandFileName(ExpandConstant('{app}')),
      ExpandFileName(ExpandConstant('{#InstallDirectory}'))) <> 0 then begin
    Result := 'MicDrop must be installed in its per-user application folder. ' +
      'Run setup again without a /DIR override.';
    Exit;
  end;
  Sid := UserSid;
  if Sid = '' then begin
    Result := 'Windows could not identify the current user. No files were changed.';
    Exit;
  end;
  DesktopMutex := WinCreateMutex(0, False, '{#MutexPrefix}' + Sid);
  Code := DLLGetLastError;
  if (DesktopMutex = 0) or (Code = ErrorAlreadyExists) then begin
    ReleaseGuards;
    Exit;
  end;
  { Keeping this same mutex open also prevents another GUI instance from starting
    while the matching executable and DLL are being replaced or removed. }
  Path := ExpandConstant('{#DataDirectory}\identity\paired-listener.lock');
  if not OpenExistingExclusive(Path, PairingLock) then begin
    ReleaseGuards;
    Exit;
  end;
  Names[0] := 'MicDrop.exe';
  Names[1] := 'windows-host.exe';
  Names[2] := 'micdrop_rtc.dll';
  for Index := 0 to 2 do begin
    if not OpenExistingExclusive(ExpandConstant('{app}\') + Names[Index], Probe) then begin
      ReleaseGuards;
      Exit;
    end;
    if Probe <> 0 then
      WinCloseHandle(Probe);
  end;
  Result := '';
end;

function IsRemoving: Boolean;
begin
  Result := MaintenanceAction = 'uninstall';
end;

function RemoveDesktopShortcut: Boolean;
begin
  Result := not IsRemoving and HadDesktopShortcut and not IsTaskSelected('desktopicon');
end;

function StopRunningHosts(FromUninstaller: Boolean): String;
var
  Helper, Arguments: String;
  Code: Integer;
begin
  Result := '';
  if FromUninstaller then begin
    Helper := ExpandConstant('{app}\MicDrop-maintenance.exe');
    if not FileExists(Helper) then begin
      { A damaged install can still be removed after the user exits the host. }
      Result := AcquireGuards;
      Exit;
    end;
  end else begin
    ExtractTemporaryFile('MicDrop-maintenance.exe');
    Helper := ExpandConstant('{tmp}\MicDrop-maintenance.exe');
  end;
  Arguments := '';
#ifdef InstallerTest
  Arguments := '--scope "{#TestRoot}"';
#endif
  if not Exec(Helper, Arguments, '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
    Result := 'MicDrop could not finish shutdown. Exit any running MicDrop copies and retry.';
end;

function RemoveInstalledCopy: String;
var
  Uninstaller: String;
  Code, Attempt: Integer;
begin
  Result := 'The installed uninstaller is missing. Use Modify / repair first, then retry.';
  Uninstaller := ExpandConstant('{app}\unins000.exe');
  if not FileExists(Uninstaller) then
    Exit;
  ReleaseGuards;
  if not Exec(Uninstaller, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '',
      SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then begin
    Result := 'MicDrop could not be uninstalled. Close any program using its files, then retry.';
    Exit;
  end;
  { Inno's launcher exits before its temporary child releases the mutex/lock. }
  for Attempt := 1 to 300 do begin
    if not FileExists(Uninstaller) and
        not RegKeyExists(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#ProductId}_is1') then begin
      Result := AcquireGuards;
      if Result = '' then
        Exit;
    end;
    Sleep(100);
  end;
  Result := 'MicDrop uninstall cleanup has not finished. Wait a moment and retry.';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  NeedsRestart := False;
  Result := 'Run setup without a /DIR override; MicDrop uses its fixed per-user application folder.';
  if CompareText(ExpandFileName(ExpandConstant('{app}')),
      ExpandFileName(ExpandConstant('{#InstallDirectory}'))) <> 0 then
    Exit;
  Result := StopRunningHosts(False);
  if Result <> '' then
    Exit;
  if IsRemoving then
    Result := RemoveInstalledCopy
  else
    Result := AcquireGuards;
end;

procedure CurStepChanged(Step: TSetupStep);
var
  Value, LegacyHost: String;
begin
  if not IsRemoving and (Step = ssPostInstall) then begin
    { Preserve an existing opt-in that used the removed installed CLI. Do not
      create a new startup entry or redirect a separate portable installation. }
    LegacyHost := ExpandConstant('{app}\windows-host.exe');
    if RegQueryStringValue(HKCU, RunKey, '{#RunValue}', Value) and
        ((CompareText(Value, '"' + LegacyHost + '" desktop --background') = 0) or
         (CompareText(Value, LegacyHost + ' desktop --background') = 0)) then begin
      if not RegWriteStringValue(HKCU, RunKey, '{#RunValue}',
          '"' + ExpandConstant('{app}\MicDrop.exe') + '" desktop --background') then
        RaiseException('Could not update the existing MicDrop startup entry.');
    end;
  end;
  if IsRemoving and (Step = ssPostInstall) then
    { No files or uninstall registration are written in removal mode. Inno may
      create an empty app directory; remove only if empty, preserving user files. }
    RemoveDir(ExpandConstant('{app}'));
end;

procedure DeinitializeSetup;
begin
  ReleaseGuards;
end;

function IsInstalledStartup(const Value: String): Boolean;
var
  Gui, Cli: String;
begin
  Gui := ExpandConstant('{app}\MicDrop.exe');
  Cli := ExpandConstant('{app}\windows-host.exe');
  Result := (CompareText(Value, '"' + Gui + '" desktop --background') = 0) or
    (CompareText(Value, Gui + ' desktop --background') = 0) or
    (CompareText(Value, '"' + Cli + '" desktop --background') = 0) or
    (CompareText(Value, Cli + ' desktop --background') = 0);
end;

procedure CurUninstallStepChanged(Step: TUninstallStep);
var
  Value, Problem: String;
begin
  if Step = usUninstall then begin
    { This event runs after the uninstall confirmation, before any removal. }
    Problem := StopRunningHosts(True);
    if Problem = '' then
      Problem := AcquireGuards;
    if Problem <> '' then
      RaiseException(Problem);
    { Do not delete a startup preference that now points to a portable copy. }
    if RegQueryStringValue(HKCU, RunKey, '{#RunValue}', Value) and
        IsInstalledStartup(Value) then begin
      if not RegDeleteValue(HKCU, RunKey, '{#RunValue}') then
        RaiseException('Could not remove this installation''s Windows startup entry.');
    end;
  end;
end;

procedure DeinitializeUninstall;
begin
  ReleaseGuards;
end;

function InitializeSetup: Boolean;
var
  Location: String;
begin
  MaintenanceAction := Lowercase(ExpandConstant('{param:MAINTENANCE|upgrade}'));
  Result := (MaintenanceAction = 'upgrade') or (MaintenanceAction = 'modify') or
    (MaintenanceAction = 'uninstall');
  if not Result then begin
    SuppressibleMsgBox('Use /MAINTENANCE=upgrade, modify, or uninstall.', mbError, MB_OK, IDOK);
    Exit;
  end;
  AlreadyInstalled := RegQueryStringValue(HKCU,
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#ProductId}_is1',
    'InstallLocation', Location);
  if AlreadyInstalled then begin
    Result := CompareText(RemoveBackslashUnlessRoot(Location),
      RemoveBackslashUnlessRoot(ExpandConstant('{#InstallDirectory}'))) = 0;
    if not Result then begin
      SuppressibleMsgBox('The registered MicDrop location does not match this installer.', mbError, MB_OK, IDOK);
      Exit;
    end;
    RegQueryStringValue(HKCU,
      'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#ProductId}_is1',
      'DisplayVersion', InstalledVersion);
  end;
  if IsRemoving and not AlreadyInstalled then begin
    SuppressibleMsgBox('MicDrop is not installed for this Windows account.', mbError, MB_OK, IDOK);
    Result := False;
  end;
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  if not IsRemoving then begin
    if IsTaskSelected('desktopicon') then
      SetPreviousData(PreviousDataKey, 'DesktopShortcut', 'yes')
    else
      SetPreviousData(PreviousDataKey, 'DesktopShortcut', 'no');
  end;
end;

procedure ChooseMaintenance(Sender: TObject);
begin
  case TNewButton(Sender).Tag of
    1: MaintenanceAction := 'upgrade';
    2: MaintenanceAction := 'modify';
    3: MaintenanceAction := 'uninstall';
  end;
  WizardForm.NextButton.OnClick(WizardForm.NextButton);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := ((PageID = wpWelcome) and AlreadyInstalled) or
    ((PageID = MaintenancePage.ID) and (not AlreadyInstalled or WizardSilent)) or
    ((PageID = wpSelectTasks) and (IsRemoving or (AlreadyInstalled and (MaintenanceAction = 'upgrade'))));
end;

procedure CurPageChanged(PageID: Integer);
begin
  if (PageID = MaintenancePage.ID) and not WizardSilent then
    WizardForm.NextButton.Visible := False;
  if PageID = wpReady then begin
    if IsRemoving then begin
      WizardForm.NextButton.Caption := '&Uninstall';
      WizardForm.ReadyLabel.Caption := 'Setup is ready to remove MicDrop from this Windows account.';
      WizardForm.ReadyMemo.Lines.Text := 'Remove MicDrop from this Windows account.' + #13#10#13#10 +
        'Running MicDrop copies will be closed and active connections will end.' + #13#10#13#10 +
        'Settings, pairings, remote configuration and logs will be kept.';
    end else begin
      WizardForm.NextButton.Caption := '&Install';
      WizardForm.ReadyLabel.Caption := 'Setup is ready to install this MicDrop package.';
      WizardForm.ReadyMemo.Lines.Add(#13#10 + 'Running MicDrop copies will be closed before files are replaced.');
    end;
  end;
  if (PageID = wpFinished) and IsRemoving then begin
    WizardForm.FinishedHeadingLabel.Caption := 'MicDrop has been removed';
    WizardForm.FinishedLabel.Caption := 'Your settings, pairings, remote configuration and logs are still available if you reinstall.';
  end;
end;

procedure InitializeWizard;
var
  Button: TNewButton;
  Index: Integer;
begin
  WizardForm.WelcomeLabel2.Caption := 'Install MicDrop for your Windows account.' + #13#10#13#10 +
    'Your saved settings, paired phones, remote configuration and logs are preserved. ' +
    'Setup closes running MicDrop copies before installing or upgrading.' + #13#10#13#10 +
    'Microphone return requires a separately installed virtual audio cable. ' +
    'Sign-in startup stays controlled by the checkbox in MicDrop.';
  HadDesktopShortcut := GetPreviousData('DesktopShortcut', 'no') = 'yes';
  MaintenancePage := CreateCustomPage(wpWelcome, 'Manage MicDrop',
    'Installed: ' + InstalledVersion + '  |  This package: {#AppVersion} (' + Copy('{#BuildRevision}', 1, 12) + ')');
  for Index := 1 to 3 do begin
    Button := TNewButton.Create(WizardForm);
    Button.Parent := MaintenancePage.Surface;
    Button.Left := ScaleX(16);
    Button.Top := ScaleY(16 + (Index - 1) * 64);
    Button.Width := MaintenancePage.SurfaceWidth - ScaleX(32);
    Button.Height := ScaleY(44);
    Button.Tag := Index;
    case Index of
      1: Button.Caption := '&Upgrade / reinstall this package';
      2: Button.Caption := '&Modify shortcuts / repair installation';
      3: Button.Caption := '&Uninstall MicDrop (keep settings and logs)';
    end;
    Button.OnClick := @ChooseMaintenance;
  end;
end;
