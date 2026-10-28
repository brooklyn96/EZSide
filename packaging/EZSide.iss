; Inno Setup script for EZSide - bundles the Flutter Windows runner + the
; portable Python engine.
;
; Build (from repo root, after building the app + assembling the engine):
;   ISCC /DAppVersion=1.2.0 packaging\EZSide.iss
; Output: dist\installer\EZSide-Setup-<ver>-x64.exe

#ifndef AppVersion
  #define AppVersion "1.2.0"
#endif
#define AppName "EZSide"
#define AppPublisher "EZSide"
#define AppExe "EZSide.exe"
#define AppUrl "https://github.com/brooklyn96/EZSide"
; The AppId also names the Add/Remove Programs key, which the rollback code at the
; bottom of this file reads and repairs. Defined once so the two can never drift.
#define AppId "{629FBABF-9841-429C-84C3-5F1B313F305E}"

[Setup]
AppId={{#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppSupportURL={#AppUrl}
; ── Look and feel: EZSide's identity, not the stock wizard ───────────────────
; dark             force the dark appearance whatever the user's Windows theme is. The
;                  installer hands over to a near-black app, and a light wizard opening
;                  it is a visible seam.
; hidebevels       the divider lines read as creases on top of the background art.
; includetitlebar  style the title bar and border too, so the window is one surface —
;                  the app's own window is chromeless for the same reason.
; Colours are the app's dark tokens: #0B0B0D canvas, #2F7BFF blue accent.
WizardStyle=modern dark hidebevels includetitlebar
WizardSizePercent=130
WizardBackColor=#0b0b0d
WizardBackImageFile=brand\backdrop.png
WizardImageFile=brand\panel.png
WizardSmallImageFile=brand\logo.png
; Inno 6 hides the welcome page by default in modern style, which would leave
; the branded panel showing only on the final page.
DisableWelcomePage=no
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist\installer
OutputBaseFilename=EZSide-Setup-{#AppVersion}-x64
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\app\{#AppExe}
UninstallDisplayName={#AppName}
; unins000.exe/.dat live in the program folder, so they move aside and come back with it
; during an upgrade, exactly as the rollback code below assumes.
UninstallFilesDir={app}\app
AppMutex=EZSide.Running.Mutex
; The wizard and Add/Remove entry use the same mark as the app itself.
SetupIconFile=..\src\iPASide.Flutter\windows\runner\resources\app_icon.ico

; ── Flow: one screen, then it installs ────────────────────────────────────────
; The stock wizard asks four questions — folder, group, tasks, confirm — about an
; install that has one sensible shape. What is left is a branded screen carrying the
; desktop-shortcut choice, the folder page (where EZSide and its data live), then
; progress, then done.
;
; No LicenseFile: MIT grants its rights without acceptance, so a click-through gate
; would be theatre. LICENSE still ships in {app}\app, which is what MIT actually asks for.
DisableReadyPage=yes
; The install folder holds the program in {app}\app and everything EZSide writes in
; {app}\data (see the [Code] notes), so picking it is how the user keeps EZSide off a
; nearly full system drive, e.g. D:\EZSide. Per-user (PrivilegesRequired=lowest), so any
; folder the user can write to works without admin; the {autopf} default resolves to the
; per-user Programs folder. The folder is chosen on the first install only: `auto` hides the
; page once an install is registered, and UsePreviousAppDir (default yes) makes every
; upgrade, the in-app updater's included, reuse it. To move an install: uninstall and
; keep the data, install into the new folder, then copy data\ there.
DisableDirPage=auto
; The folder checks in [Code] (NextButtonClick, PrepareToInstall) replace Inno's stock
; "folder already exists" prompt.
DirExistsWarning=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
; EZSide's own voice. Inno's default copy ("It is recommended that you close all
; other applications") tells the user nothing about what they are installing.
SetupWindowTitle=%1 Setup
WelcomeLabel1=Install EZSide
WelcomeLabel2=EZSide signs any .ipa with your own Apple ID and installs it on your iPhone or iPad, over USB or Wi-Fi — no paid developer account.
; Inno appends this to the welcome text. The default ("Click Next to continue") now
; contradicts the button, which reads Install because the Ready page is gone.
ClickNext=Setup installs the app together with its self-contained signing engine. Your Apple ID is only ever sent to Apple.
WizardInstalling=Installing EZSide
InstallingLabel=Copying the app and its signing engine. The engine is a self-contained Python runtime, so this takes a few seconds.
FinishedHeadingLabel=EZSide is ready
FinishedLabel=Connect your iPhone over USB, unlock it and tap Trust. Then sign in with your Apple ID and drop an .ipa onto the window.%n%nYou also need Apple Devices (or iTunes) installed for USB access.
FinishedLabelNoIcons=Connect your iPhone over USB, unlock it and tap Trust. Then sign in with your Apple ID and drop an .ipa onto the window.
ClickFinish=Click Finish to close Setup.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; The program folder is installer-owned by construction: nothing but Setup (and Python's
; own __pycache__) writes there. This runs after CurStepChanged(ssInstall), so after a
; successful move-aside it matches nothing; otherwise it clears a leftover, half-written
; or lock-blocked copy before [Files] writes a fresh one. PrepareToInstall has already
; made sure {app} is EZSide's own folder or an empty one. {app}\data is never touched.
Type: filesandordirs; Name: "{app}\app"

[Files]
Source: "..\publish\app\*"; DestDir: "{app}\app"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\dist\engine\*"; DestDir: "{app}\app\engine"; Flags: recursesubdirs createallsubdirs ignoreversion
; Not installed — extracted to {tmp} at runtime to stand in for the native progress
; bar, which cannot be recoloured. See CreateProgressBar.
Source: "brand\bar-track.png"; Flags: dontcopy
Source: "brand\bar-fill.png"; Flags: dontcopy

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\app\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\app\{#AppExe}"; Tasks: desktopicon

[Run]
; Check: never offer to start a payload that just failed to run. After a rolled-back
; upgrade the restored older EZSide is fine to launch; a damaged one is not.
; No skipifsilent: the in-app updater installs with /SILENT and the user expects the
; app to come back afterwards (the update flow closes it so Setup can swap files).
Filename: "{app}\app\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall; Check: InstalledAppIsUsable

[Code]
// ── Transactional upgrade: move aside, verify, then commit ────────────────────────
// An upgrade replaces ~215 MB of app plus bundled engine in place. When that only
// half-applies - a truncated download, a crash mid-copy, a payload that shipped
// broken - the user is left with a folder that looks installed but cannot sign
// anything, and no route back. So an upgrade is staged instead of applied blind:
//
//   ssInstall      If a previous install is present, RENAME the program folder
//                  {app}\app aside to {app}\app.rollback. A rename within one volume
//                  only rewrites directory metadata, so it costs milliseconds where
//                  copying 215 MB aside would cost minutes. Inno then installs into a
//                  clean, empty {app}\app.
//   ssPostInstall  PROVE the new payload runs, then either discard the backup or put
//                  it back under its own name.
//
// A first install has nothing to move aside and nothing to fall back to, so it passes
// through here untouched.
//
// The folder the user picks ({app}, e.g. D:\EZSide) holds exactly two things: {app}\app,
// the program (exe, dlls, the Flutter runner's own data\ assets, the engine, unins*.*),
// and {app}\data, every byte EZSide writes - the Apple ID session, the signing
// certificate and private key, the anisette state, the sideload registry, install.log.
// Only {app}\app ever moves or is deleted here. Setup never moves, renames or deletes
// anything in {app}\data; it only appends to {app}\data\install.log. So no failure path
// below - verify failure, cancel, kill, power loss, a locked file, a failed restore - can
// touch the user's data; the worst any of them leaves is a stale app.rollback folder.
//
// One measured limit to know before rearranging this: by the time Setup reaches
// ssPostInstall the install is already committed as far as Inno is concerned. Raising
// an exception there still exits 0 and still leaves the Add/Remove entry written, so a
// rolled-back upgrade cannot report itself through the exit code. What it can do, and
// does below, is put the working version back, say so on the final page, and leave a
// record on disk. (The in-app updater launches Setup detached and interactively, so
// the final page - not the exit code - is what a user actually sees.)

var
  // Written at ssInstall, read at ssPostInstall.
  BackupTaken: Boolean;
  // True once the backup has been dealt with for good, either discarded because the new
  // payload verified or successfully put back. Until then the backup is still the only
  // complete copy of a working EZSide, and DeinitializeSetup will restore it.
  UpgradeSettled: Boolean;
  PreviousVersion: String;
  // Non-empty once the new payload has failed to verify; drives the final page.
  FailureHeading: String;
  FailureDetail: String;
  // False only when what is left in {app} is known-broken.
  AppUsable: Boolean;

  // Welcome-page extras. The one real choice and the fine print live there so the whole
  // wizard is a single screen. They are created in InitializeWizard and positioned when
  // the page is first shown, by which point the form has its final DPI-scaled layout.
  DesktopIconCheck: TNewCheckBox;
  Highlights: TNewStaticText;
  FinePrint: TNewStaticText;
  // Stand-ins for the native progress bar.
  BarTrack: TBitmapImage;
  BarFill: TBitmapImage;

  // {app}, read when the uninstaller starts; used by the post-uninstall data question.
  UninstallAppDir: String;

// ── Brand-coloured progress bar ───────────────────────────────────────────────
// TNewProgressBar exposes no colour property, and the active style paints it the stock
// green, which reads as a different product against this canvas. So the native bar is
// hidden and two stretched images stand in: a dark track and a flat blue (#2F7BFF) fill
// whose width follows real progress. Images rather than coloured panels, because a VCL
// style overrides control colours set from Pascal but cannot restyle a bitmap.
procedure CreateProgressBar;
begin
  ExtractTemporaryFile('bar-track.png');
  ExtractTemporaryFile('bar-fill.png');

  BarTrack := TBitmapImage.Create(WizardForm);
  BarTrack.Parent := WizardForm.InstallingPage;
  BarTrack.Stretch := True;
  BarTrack.PngImage.LoadFromFile(ExpandConstant('{tmp}\bar-track.png'));
  BarTrack.Visible := False;

  BarFill := TBitmapImage.Create(WizardForm);
  BarFill.Parent := WizardForm.InstallingPage;
  BarFill.Stretch := True;
  BarFill.PngImage.LoadFromFile(ExpandConstant('{tmp}\bar-fill.png'));
  BarFill.Visible := False;
end;

// Lay the stand-in exactly over the native bar, and hide the original.
procedure ShowProgressBar;
begin
  WizardForm.ProgressGauge.Visible := False;

  BarTrack.Left := WizardForm.ProgressGauge.Left;
  BarTrack.Top := WizardForm.ProgressGauge.Top;
  BarTrack.Width := WizardForm.ProgressGauge.Width;
  BarTrack.Height := WizardForm.ProgressGauge.Height;
  BarTrack.Visible := True;

  BarFill.Left := BarTrack.Left;
  BarFill.Top := BarTrack.Top;
  BarFill.Height := BarTrack.Height;
  BarFill.Width := 0;
  BarFill.Visible := True;
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
begin
  if (BarFill <> nil) and BarFill.Visible and (MaxProgress > 0) then
    BarFill.Width := (BarTrack.Width * CurProgress) div MaxProgress;
end;

procedure InitializeWizard;
begin
  CreateProgressBar;

  Highlights := TNewStaticText.Create(WizardForm);
  Highlights.Parent := WizardForm.WelcomePage;
  Highlights.WordWrap := False;
  Highlights.Caption :=
    '•   Sign and install any .ipa with your own Apple ID' + #13#10 +
    '•   Inject .deb or .dylib tweaks while you do it' + #13#10 +
    '•   Re-signs your apps before their 7 days run out';

  DesktopIconCheck := TNewCheckBox.Create(WizardForm);
  DesktopIconCheck.Parent := WizardForm.WelcomePage;
  DesktopIconCheck.Caption := 'Create a desktop shortcut';

  FinePrint := TNewStaticText.Create(WizardForm);
  FinePrint.Parent := WizardForm.WelcomePage;
  FinePrint.WordWrap := True;
end;

// The program folder: the only tree Setup moves aside, restores or deletes.
function AppDir: String;
begin
  Result := ExpandConstant('{app}\app');
end;

// Everything EZSide writes. Never an operand of a rename or a delete in this script.
function DataDir: String;
begin
  Result := ExpandConstant('{app}\data');
end;

function BackupDir: String;
begin
  // A sibling of the program folder, so the backup is guaranteed to be on the same
  // volume and the move stays a rename. Anywhere else - {tmp}, another drive - risks a
  // cross-volume move, which Windows quietly turns into a full byte-for-byte copy.
  Result := AppDir + '.rollback';
end;

function InstallLogPath: String;
begin
  // Next to the rest of the data, outside the folder that is renamed away, replaced and
  // sometimes deleted while this log is being written.
  Result := AddBackslash(DataDir) + 'install.log';
end;

procedure LogInstall(Msg: String);
var
  Existing: AnsiString;
  Line: String;
begin
  Log(Msg);  // also into Setup's own /LOG file, when one was asked for
  Line := '[' + GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + '] {#AppVersion}: ' + Msg;
  ForceDirectories(DataDir);
  if LoadStringFromFile(InstallLogPath, Existing) then
    SaveStringToFile(InstallLogPath, Existing + Line + #13#10, False)
  else
    SaveStringToFile(InstallLogPath, Line + #13#10, False);
end;

function UninstallKey: String;
begin
  // Per-user install, so Inno keeps the Add/Remove entry under HKCU.
  Result := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppId}_is1';
end;

// Erasing a directory tree from a path that came out of a constant deserves a positive
// identification first: {app} can be pointed anywhere with /DIR=, and "the folder
// exists" is not the same as "this folder is ours to delete".
function LooksLikeOurInstall(Dir: String): Boolean;
begin
  Result := (Length(Dir) > 3) and DirExists(Dir)
        and FileExists(AddBackslash(Dir) + '{#AppExe}');
end;

function DirIsEmpty(Dir: String): Boolean;
var
  FindRec: TFindRec;
begin
  Result := True;
  if FindFirst(AddBackslash(Dir) + '*', FindRec) then
  try
    repeat
      if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        Result := False;
    until (not Result) or not FindNext(FindRec);
  finally
    FindClose(FindRec);
  end;
end;

// The install folder is user-chosen, so Setup must not treat "a folder that already
// exists" as "a folder that is ours": picking D:\Tools must not let [InstallDelete] clear
// a D:\Tools\app that belongs to something else. A folder is fine when it does not exist,
// is empty, or is EZSide's own: a registered install (app\EZSide.exe), an interrupted
// upgrade (app.rollback\EZSide.exe), or a killed first install or an uninstall that kept
// the data (data\install.log, written at ssInstall before any file is copied).
function AcceptableInstallRoot(Dir: String): Boolean;
begin
  Result := not DirExists(Dir) or DirIsEmpty(Dir)
         or FileExists(AddBackslash(Dir) + 'app\{#AppExe}')
         or FileExists(AddBackslash(Dir) + 'app.rollback\{#AppExe}')
         or FileExists(AddBackslash(Dir) + 'data\install.log');
end;

function ForeignFolderMessage: String;
begin
  Result := 'That folder already has other files in it. Pick an empty folder or one that'
    + ' does not exist yet, for example D:\EZSide.';
end;

// "The exe is there" is not proof of a working install. The engine is ~10,000 files of
// Python and native code, and the failure guarded against here is precisely the one
// where everything is present but something is truncated. `ipaside_engine version`
// imports the whole engine package on its way to printing one line - pymobiledevice3,
// anisette's unicorn native library, cryptography, Pillow - so exit code 0 means the
// payload actually runs, not merely that it arrived.
function NewInstallAnswers: Boolean;
var
  Engine, Probe, Detail: String;
  Output: AnsiString;
  ResultCode: Integer;
begin
  Result := False;

  if not FileExists(AddBackslash(AppDir) + '{#AppExe}') then
  begin
    LogInstall('verify: {#AppExe} is missing from ' + AppDir);
    Exit;
  end;

  Engine := AddBackslash(AppDir) + 'engine\python\python.exe';
  if not FileExists(Engine) then
  begin
    LogInstall('verify: the bundled engine is missing (' + Engine + ')');
    Exit;
  end;

  // Routed through cmd.exe with the output redirected to a file: Setup is a GUI process
  // with no console for the child to inherit, and capturing the text means a failure
  // leaves the real Python traceback in the log rather than a bare exit code.
  // Inno has no way to set an environment variable for a child, but cmd can: the `set`
  // gives this one process IPASIDE_DATA_DIR={app}\data, the same answer the engine's
  // installed-layout detection reaches by itself. Stating it keeps the check from ever
  // writing anywhere but the folder the user chose.
  Probe := ExpandConstant('{tmp}\engine-verify.txt');
  DeleteFile(Probe);
  if not Exec(ExpandConstant('{cmd}'),
              '/c "set "IPASIDE_DATA_DIR=' + DataDir + '" && "' + Engine
                + '" -m ipaside_engine version > "' + Probe + '" 2>&1"',
              AppDir, SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    LogInstall('verify: the engine could not be started at all');
    Exit;
  end;

  if LoadStringFromFile(Probe, Output) then
    Detail := Trim(String(Output))
  else
    Detail := '(no output)';

  Result := ResultCode = 0;
  if Result then
    LogInstall('verify: engine answered - ' + Detail)
  else
    LogInstall('verify: engine exited ' + IntToStr(ResultCode) + ' - ' + Detail);
end;

// Put the moved-aside install back under its own name. Shared by the two ways an upgrade
// can go wrong: the new payload failing to verify, and Setup never getting that far.
function RestorePreviousInstall: Boolean;
begin
  // Order matters: RenameFile cannot land on a directory that already exists, so the new
  // (or half-written) payload has to be gone before the backup can take its name back.
  // Whatever is in the program folder now was put there by this Setup run: BackupTaken
  // means the folder that was there before has been renamed away. It holds no user data.
  if DirExists(AppDir) and (Length(AppDir) > 3) then
    DelTree(AppDir, True, True, True);

  Result := RenameFile(BackupDir, AppDir);
  if Result then
  begin
    UpgradeSettled := True;
    // The one Add/Remove value that would otherwise lie. Everything else in that entry
    // - install location, uninstall command, icon - still describes the restored files.
    if PreviousVersion <> '' then
      RegWriteStringValue(HKEY_CURRENT_USER, UninstallKey, 'DisplayVersion', PreviousVersion);
  end;
end;

procedure StageUpgrade;
begin
  // A backup still here at ssInstall means an earlier run died between moving the
  // program folder aside and discarding the backup, or could not discard it. Which
  // of the two folders is the working EZSide is not guessed: the one in place is
  // asked to prove itself exactly as a fresh payload is; if it cannot, the backup -
  // the last version known to work - takes its name back, and this run upgrades
  // from it with rollback protection. A backup without EZSide.exe is debris of an
  // interrupted delete.
  if LooksLikeOurInstall(BackupDir) then
  begin
    if NewInstallAnswers then
    begin
      LogInstall('the install in place works; discarding a rollback backup left behind by an earlier run');
      DelTree(BackupDir, True, True, True);
    end
    else
    begin
      if DirExists(AppDir) then DelTree(AppDir, True, True, True);
      if RenameFile(BackupDir, AppDir) then
        LogInstall('recovered the previous install from ' + BackupDir)
      else
        LogInstall('could not put the previous install back from ' + BackupDir + ' - leaving it there');
    end;
  end
  else if DirExists(BackupDir) then
    DelTree(BackupDir, True, True, True);

  // No EZSide.exe means there is nothing to fall back to: a first install, or a
  // directory some earlier run left half-written. Both install straight in, and
  // [InstallDelete] clears whatever is lying in the program folder.
  if not FileExists(AddBackslash(AppDir) + '{#AppExe}') then
  begin
    LogInstall('first install into ' + AppDir);
    Exit;
  end;

  // Read while it is still true: Inno rewrites DisplayVersion during the install, so
  // from here on the registry claims the new version even if the files on disk end up
  // being the old ones again.
  RegQueryStringValue(HKEY_CURRENT_USER, UninstallKey, 'DisplayVersion', PreviousVersion);

  // AppMutex has already turned the install away if EZSide itself is running, but a
  // resident engine process, an antivirus scan, an open Explorer window or a console
  // whose current directory is inside the program folder can still hold a handle, and
  // then this fails. So does a backup from an earlier run that could not be cleared
  // above (the target name is taken). A missing safety net is not worth failing an
  // otherwise fine upgrade over, so record it and continue without one.
  if RenameFile(AppDir, BackupDir) then
  begin
    BackupTaken := True;
    LogInstall('upgrade from version ' + PreviousVersion + ': previous install moved to '
      + BackupDir);
  end
  else
    LogInstall('upgrade from version ' + PreviousVersion + ': could not move the previous'
      + ' install aside (a file is in use, or an older backup could not be cleared) -'
      + ' installing in place, WITHOUT rollback protection');
end;

procedure RollBackUpgrade;
begin
  WizardForm.StatusLabel.Caption := 'Restoring the previous version of EZSide...';

  if RestorePreviousInstall then
  begin
    LogInstall('ROLLED BACK: version ' + PreviousVersion + ' restored to ' + AppDir);
    FailureHeading := 'The update was rolled back';
    // Kept to about five lines: this same text goes on the Finished page, whose label has
    // a fixed height, and anything longer is silently clipped there (seen while testing).
    FailureDetail :=
      'EZSide {#AppVersion} was installed, but its signing engine did not start, so Setup'
      + ' put your previous version back - EZSide still works. Your Apple ID session and'
      + ' signing material were not touched.' + #13#10#13#10
      + 'Details: ' + InstallLogPath;
  end
  else
  begin
    // Both trees still exist, so nothing is lost - but the program folder is empty and
    // only the user can free whatever is holding it. Name the folder so the recovery is
    // a rename. UpgradeSettled stays False on purpose: DeinitializeSetup gets one more
    // attempt once Setup has let go of everything it had open. The next Setup run also
    // puts the backup back on its own (StageUpgrade).
    AppUsable := False;
    LogInstall('ROLLBACK FAILED: ' + BackupDir + ' could not be moved back to ' + AppDir);
    FailureHeading := 'EZSide is not installed';
    FailureDetail :=
      'The new files were removed, but the previous version could not be moved back -'
      + ' something on this PC is holding that folder open. Nothing was lost; it is intact'
      + ' at' + #13#10 + BackupDir + #13#10#13#10
      + 'Restart Windows and run Setup again.';
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    BackupTaken := False;
    UpgradeSettled := False;
    AppUsable := True;
    PreviousVersion := '';
    FailureHeading := '';
    FailureDetail := '';
    StageUpgrade;
  end;

  if CurStep = ssPostInstall then
  begin
    if NewInstallAnswers then
    begin
      // Committed. From here the backup must never come back, whatever happens next.
      UpgradeSettled := True;
      if BackupTaken then
      begin
        // Leaving 200-odd MB of superseded payload behind next to the install, on a
        // drive the user chose because it had little room to spare, would undo the
        // point of keeping the install small.
        WizardForm.StatusLabel.Caption := 'Removing the previous version...';
        DelTree(BackupDir, True, True, True);
        LogInstall('new install verified; rollback backup discarded');
      end
      else
        LogInstall('install verified');
      Exit;
    end;

    if BackupTaken then
      RollBackUpgrade
    else
    begin
      // Nothing to go back to, so the wizard must not claim success either.
      AppUsable := False;
      LogInstall('install did NOT verify and there was no previous version to restore');
      FailureHeading := 'EZSide is not ready';
      FailureDetail :=
        'EZSide was installed, but its signing engine did not start, and there was no'
        + ' previous version to restore. Running Setup again usually fixes a damaged'
        + ' download.' + #13#10#13#10
        + 'Details: ' + InstallLogPath;
    end;

    // Suppressible on purpose: a scripted or silent install must not hang on a dialog,
    // and install.log is the record that survives either way.
    SuppressibleMsgBox(FailureHeading + #13#10#13#10 + FailureDetail,
      mbCriticalError, MB_OK, IDOK);
  end;
end;

function InstalledAppIsUsable: Boolean;
begin
  Result := AppUsable;
end;

procedure DeinitializeSetup;
begin
  // Last line of defence, and not a theoretical one: ssPostInstall never runs at all if
  // the user hits Cancel during the copy or Setup dies partway through. Observed while
  // testing this - cancelling mid-copy left a 110 MB half-written {app} next to the
  // intact 320 MB backup, i.e. precisely the broken install this section exists to
  // prevent. DeinitializeSetup always runs, so the recovery belongs here as well.
  if UpgradeSettled or not BackupTaken or not DirExists(BackupDir) then
    Exit;

  if RestorePreviousInstall then
    LogInstall('setup did not finish (cancelled or interrupted); version '
      + PreviousVersion + ' restored from the backup')
  else
    LogInstall('setup did not finish and the previous version could NOT be moved back -'
      + ' it is still intact at ' + BackupDir);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  // The tasks page is skipped, so the welcome-page checkbox is the only thing that can
  // select the task, and it has to be applied before the install reads it.
  if CurPageID = wpWelcome then
  begin
    if DesktopIconCheck.Checked then
      WizardSelectTasks('desktopicon')
    else
      WizardSelectTasks('!desktopicon');
  end;

  // Shown only on a first install (DisableDirPage=auto). The user can pick another folder.
  if CurPageID = wpSelectDir then
  begin
    if not AcceptableInstallRoot(WizardDirValue) then
    begin
      SuppressibleMsgBox(ForeignFolderMessage, mbError, MB_OK, IDOK);
      Result := False;
    end;
  end;
end;

// The same check on every path, page shown or not, silent or not: an upgrade skips the
// folder page, so /DIR=<other folder> would otherwise reach [InstallDelete] unchecked.
// A non-empty result stops Setup at the Preparing page (exit code 7), before
// [InstallDelete] and [Files] have touched anything.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not AcceptableInstallRoot(ExpandConstant('{app}')) then
    Result := ForeignFolderMessage;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  // The only task has a checkbox on the welcome page already; its own page would be a
  // second click asking the same question.
  Result := PageID = wpSelectTasks;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  HighlightsTop, HighlightsMaxTop: Integer;
begin
  if CurPageID = wpWelcome then
  begin
    // Everything below the intro copy is anchored to the BOTTOM of the page. The copy
    // above varies in height with DPI, font scaling and translation, so measuring
    // downward from it eventually collides with it — and anchoring the fine print up
    // from the bottom is what stops its last line being clipped off the page edge.
    Highlights.Left := WizardForm.WelcomeLabel2.Left;
    Highlights.Width := WizardForm.WelcomeLabel2.Width;
    // Sit directly under the intro copy, which means measuring it: AutoSize collapses
    // the label to its wrapped text height, where Inno otherwise leaves it stretched
    // down the page. Clamped, so if that copy ever grows the list stops above the
    // checkbox instead of overlapping it.
    WizardForm.WelcomeLabel2.AutoSize := True;
    HighlightsTop := WizardForm.WelcomeLabel2.Top + WizardForm.WelcomeLabel2.Height + ScaleY(20);
    HighlightsMaxTop := WizardForm.WelcomePage.ClientHeight - ScaleY(152);
    if HighlightsTop > HighlightsMaxTop then
      HighlightsTop := HighlightsMaxTop;
    Highlights.Top := HighlightsTop;

    DesktopIconCheck.Left := WizardForm.WelcomeLabel2.Left;
    DesktopIconCheck.Width := WizardForm.WelcomeLabel2.Width;
    DesktopIconCheck.Height := ScaleY(20);
    DesktopIconCheck.Top := WizardForm.WelcomePage.ClientHeight - ScaleY(76);
    // Reflect /TASKS= from the command line rather than overwriting it.
    DesktopIconCheck.Checked := WizardIsTaskSelected('desktopicon');

    FinePrint.Left := WizardForm.WelcomeLabel2.Left;
    FinePrint.Width := WizardForm.WelcomeLabel2.Width;
    FinePrint.Height := ScaleY(46);
    FinePrint.Top := WizardForm.WelcomePage.ClientHeight - ScaleY(48);
    // {app} is not initialised while the welcome page is showing, so it is not read here.
    if WizardForm.PrevAppDir <> '' then
    begin
      // An upgrade: the folder page will be skipped (DisableDirPage=auto), so this is the
      // last page before copying and its button is the Install button.
      WizardForm.NextButton.Caption := SetupMessage(msgButtonInstall);
      FinePrint.Caption :=
        'Free and open source (MIT). No account, no telemetry, no EZSide server.' + #13#10 +
        'Updates EZSide in ' + WizardForm.PrevAppDir + '. Your data stays there.';
    end
    else
      FinePrint.Caption :=
        'Free and open source (MIT). No account, no telemetry, no EZSide server.' + #13#10 +
        'Pick the install folder next - EZSide keeps all its data there.';
  end;

  // There is no Ready page to press Install on any more, so the folder page is the last
  // one before copying and its button is that button.
  if CurPageID = wpSelectDir then
    WizardForm.NextButton.Caption := SetupMessage(msgButtonInstall);

  if CurPageID = wpInstalling then
    ShowProgressBar;

  // The [Messages] copy for this page promises a working EZSide and tells the user to
  // plug in an iPhone. When the payload failed to verify that is simply untrue, and
  // this page is the only place most people will ever look.
  if (CurPageID = wpFinished) and (FailureHeading <> '') then
  begin
    WizardForm.FinishedHeadingLabel.Caption := FailureHeading;
    WizardForm.FinishedLabel.Caption := FailureDetail;
  end;
end;

// ── Uninstall: the user's data is theirs to keep or delete ────────────────────────
// The uninstaller removes only what Setup installed, so {app}\data (accounts, signing
// certificates, app copies, install.log) is still there afterwards. Ask once, default
// No. A silent uninstall must neither ask nor delete: that path is scripted, and an
// uninstall followed by a reinstall must not cost anyone their Apple ID session.
// The program folder and a leftover app.rollback are installer-owned and always go.
function InitializeUninstall: Boolean;
begin
  // Read up front: nothing else in the uninstaller depends on {app} still being
  // resolvable by the time the post-uninstall step runs.
  UninstallAppDir := ExpandConstant('{app}');
  Result := True;
end;

// The question is shown in English and Vietnamese. Vietnamese letters are written as
// character codes so the text survives however the compiler decodes this file.
// (The parameter is not named DataDir: that is the install-time function above.)
function DeleteDataQuestion(Folder: String): String;
begin
  Result :=
    'Also delete EZSide data (accounts, certificates, app copies) in ' + Folder + '?'
    + #13#10#13#10
    + 'Xo' + #225 + ' lu' + #244 + 'n d' + #7919 + ' li' + #7879 + 'u EZSide (t' + #224
    + 'i kho' + #7843 + 'n, ch' + #7913 + 'ng ch' + #7881 + ', b' + #7843 + 'n sao app)'
    + ' trong ' + Folder + '?';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  UserData: String;
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;
  if Length(UninstallAppDir) <= 3 then
    Exit;

  // Installer-owned leftovers: a backup from an interrupted upgrade (with or without its
  // EZSide.exe - without it, it is debris of an interrupted delete) and whatever the
  // uninstaller did not record, such as Python's __pycache__. The root passed
  // AcceptableInstallRoot at install time, so these two names inside it are ours.
  if DirExists(AddBackslash(UninstallAppDir) + 'app.rollback') then
    DelTree(AddBackslash(UninstallAppDir) + 'app.rollback', True, True, True);
  if DirExists(AddBackslash(UninstallAppDir) + 'app') then
    DelTree(AddBackslash(UninstallAppDir) + 'app', True, True, True);

  if UninstallSilent then
    Exit;

  UserData := AddBackslash(UninstallAppDir) + 'data';
  if not DirExists(UserData) then
    Exit;

  if MsgBox(DeleteDataQuestion(UserData), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
  begin
    DelTree(UserData, True, True, True);
    // The uninstaller already tried to remove the install folder while data was still in
    // it; now that the data is gone the folder is empty. RemoveDir refuses a non-empty one.
    RemoveDir(UninstallAppDir);
  end;
end;
