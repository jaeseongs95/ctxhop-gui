; Per-user installer for the ctxhop GUI vNext release package (Inno Setup 6.7).
; Build: ISCC.exe /DStage=<extracted release zip>\ctxhop-gui-vnext /DTag=<release date tag> CtxHop-GUI-vNext.iss
; User data lives in %LOCALAPPDATA%\CtxHopGUI and is never touched by setup or uninstall.
#ifndef Stage
  #error Pass /DStage=<extracted release zip>\ctxhop-gui-vnext
#endif
#ifndef Tag
  #error Pass /DTag=<release date tag>, for example /DTag=20260927.1
#endif
; Tag 20260927.1 -> version 2026.09.27.1, the same form as the first release (2026.09.27).
#define AppVer Copy(Tag, 1, 4) + "." + Copy(Tag, 5, 2) + "." + Copy(Tag, 7, 20)
; Same command as Run-CtxHop-GUI-vNext.cmd, started minimized so no console window flashes.
; Setup stays in 32-bit mode like the first release so upgrades keep one uninstall log; the shortcut path is
; resolved by 64-bit Explorer and the [Run] entry uses the 64bit flag, so both start 64-bit Windows PowerShell.
#define PowerShell "{win}\System32\WindowsPowerShell\v1.0\powershell.exe"
; Single quotes keep the doubled quotes that the [Icons]/[Run] parameter syntax needs around the path.
#define GuiArgs '-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File ""{app}\GUI.ps1""'

[Setup]
AppId={{2CC6D235-90EE-48E7-9059-3FFC393D8C9E}
AppName=CtxHop GUI vNext
AppVersion={#AppVer}
AppPublisher=jaeseongs95
AppPublisherURL=https://github.com/jaeseongs95/ctxhop
AppUpdatesURL=https://github.com/jaeseongs95/ctxhop/releases
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
DefaultDirName={autopf}\CtxHop GUI vNext
; A fixed folder keeps the install away from the data folder.
DisableDirPage=yes
DisableProgramGroupPage=yes
; Every GUI worker task (list, backup, restore, setup...) holds this mutex; the stable ctxhop-gui uses the same name.
AppMutex=CtxHopGUI-operation
; Never let Restart Manager close ctxhop.exe in the middle of a task.
CloseApplications=no
OutputDir=out
OutputBaseFilename=CtxHop-GUI-vNext-{#Tag}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=CtxHop GUI vNext
UninstallDisplayIcon={#PowerShell}

[Languages]
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
; AppMutex means a GUI task is running (its worker keeps the mutex even if the GUI window is closed).
korean.SetupAppRunningError=CtxHop GUI 작업(목록·백업·복원·설정)이 진행 중입니다.%n%n작업이 끝난 뒤 확인을 누르세요. 취소를 누르면 설치를 끝냅니다.
english.SetupAppRunningError=A CtxHop GUI task (list, backup, restore or setup) is running.%n%nClick OK after the task has finished, or Cancel to exit Setup.
korean.UninstallAppRunningError=CtxHop GUI 작업(목록·백업·복원·설정)이 진행 중입니다.%n%n작업이 끝난 뒤 확인을 누르세요. 취소를 누르면 제거를 끝냅니다.
english.UninstallAppRunningError=A CtxHop GUI task (list, backup, restore or setup) is running.%n%nClick OK after the task has finished, or Cancel to exit Uninstall.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#Stage}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\CtxHop GUI vNext"; Filename: "{#PowerShell}"; Parameters: "{#GuiArgs}"; WorkingDir: "{app}"; Flags: runminimized
Name: "{autodesktop}\CtxHop GUI vNext"; Filename: "{#PowerShell}"; Parameters: "{#GuiArgs}"; WorkingDir: "{app}"; Flags: runminimized; Tasks: desktopicon

[Run]
; Offered only when Setup is not elevated, so the GUI and its worker never start as administrator.
Filename: "{#PowerShell}"; Parameters: "{#GuiArgs}"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,CtxHop GUI vNext}"; Flags: postinstall nowait skipifsilent runminimized 64bit; Check: not IsAdmin

[InstallDelete]
; Earlier builds shipped these source copies; the source now lives in the ctxhop-gui repository.
Type: filesandordirs; Name: "{app}\claude-source"
Type: filesandordirs; Name: "{app}\transport-source"

[UninstallDelete]
; Python bytecode cache only; a user-made backend\runtime.json stays.
Type: filesandordirs; Name: "{app}\backend\__pycache__"
