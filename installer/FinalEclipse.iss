#define MyAppName "FinalEclipse"
#define MyAppVersion "1.0.0"
#define MyAppExeName "FinalEclipse.exe"
[Setup]
AppId={{3E67C9DC-680B-4B7F-9E85-3199F4AEE101}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=FinalEclipse
DefaultDirName={localappdata}\Programs\FinalEclipse
DefaultGroupName=FinalEclipse
OutputDir=..\release\windows
OutputBaseFilename=FinalEclipse-Setup-1.0.0
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
Uninstallable=yes

[Files]
Source: "..\FinalEclipse.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\FinalEclipse.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Test-Release.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]

