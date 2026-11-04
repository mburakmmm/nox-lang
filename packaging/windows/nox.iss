; Nox Windows kurucusu (Inno Setup 6). `build-installer.ps1` bunu bir release `.zip`'inden açılmış dizinle derler:
;   iscc /DAppVersion=2.0.138 /DSourceDir=<açılmış nox-lang-vX.Y.Z-windows-x64> /DOutputDir=<çıktı> nox.iss
; Kullanıcı başına kurulum VARSAYILANDIR (yönetici izni istemez, %LOCALAPPDATA%\Programs\Nox); sihirbazın başındaki seçenekle tüm
; kullanıcılar için (Program Files, yönetici) de kurulabilir. "Nox'u PATH'e ekle" görevi seçiliyse <kurulum>\bin kullanıcı (ya da
; sistem) PATH'ine eklenir; kaldırırken yalnızca bu girdi silinir, PATH'in geri kalanına dokunulmaz. Aynı sürüm yeniden kurulursa PATH
; ikinci kez eklenmez. Sessiz kurulum: nox-lang-vX.Y.Z-windows-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART [/DIR=...] [/MERGETASKS="!addpath"]

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "stage"
#endif
#ifndef OutputDir
  #define OutputDir "out"
#endif

[Setup]
AppId={{8A7EFBC7-C91C-4F14-B062-415CBA048189}
AppName=Nox
AppVersion={#AppVersion}
AppVerName=Nox {#AppVersion}
AppPublisher=Melih Burak Memiş
AppPublisherURL=https://noxlang.com
AppSupportURL=https://github.com/mburakmmm/nox-lang/issues
AppUpdatesURL=https://github.com/mburakmmm/nox-lang/releases
DefaultDirName={autopf}\Nox
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ChangesEnvironment=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
SolidCompression=yes
LicenseFile={#SourceDir}\LICENSE
InfoAfterFile=after-install.txt
OutputDir={#OutputDir}
OutputBaseFilename=nox-lang-v{#AppVersion}-windows-x64-setup
UninstallDisplayName=Nox {#AppVersion}
UninstallDisplayIcon={app}\bin\noxc.exe
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[Tasks]
Name: "addpath"; Description: "Add Nox to the PATH (so noxc works in any terminal)"; GroupDescription: "Environment:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Code]
function PathRoot: Integer;
begin
  if IsAdminInstallMode then Result := HKEY_LOCAL_MACHINE else Result := HKEY_CURRENT_USER;
end;

function PathSubkey: String;
begin
  if IsAdminInstallMode then
    Result := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  else
    Result := 'Environment';
end;

function PathContains(const Dir: String): Boolean;
var
  Existing: String;
begin
  Result := False;
  if RegQueryStringValue(PathRoot, PathSubkey, 'Path', Existing) then
    Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Existing) + ';') > 0;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Existing, BinDir: String;
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('addpath') then
  begin
    BinDir := ExpandConstant('{app}\bin');
    if not PathContains(BinDir) then
    begin
      if not RegQueryStringValue(PathRoot, PathSubkey, 'Path', Existing) then
        Existing := '';
      if (Existing <> '') and (Existing[Length(Existing)] <> ';') then
        Existing := Existing + ';';
      RegWriteExpandStringValue(PathRoot, PathSubkey, 'Path', Existing + BinDir);
    end;
  end;
end;

// PATH'ten yalnızca `Dir` girdisini çıkarır; diğer girdilerin sırası ve ayırıcıları (kullanıcının sondaki ';'sü dahil) aynen korunur.
function RemovePathEntry(const Path, Dir: String): String;
var
  Rest, Part, Sep: String;
  P: Integer;
begin
  Result := '';
  Rest := Path;
  while Rest <> '' do
  begin
    P := Pos(';', Rest);
    if P = 0 then
    begin
      Part := Rest;
      Rest := '';
      Sep := '';
    end else
    begin
      Part := Copy(Rest, 1, P - 1);
      Rest := Copy(Rest, P + 1, Length(Rest));
      Sep := ';';
    end;
    if CompareText(Part, Dir) <> 0 then
      Result := Result + Part + Sep;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Existing, Updated: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    if RegQueryStringValue(PathRoot, PathSubkey, 'Path', Existing) then
    begin
      Updated := RemovePathEntry(Existing, ExpandConstant('{app}\bin'));
      if Updated <> Existing then
      begin
        // Geriye girdi kalmadıysa değeri boş bırakmak yerine sil: kurulumdan önce PATH tanımsızsa aynı duruma dönülür.
        if Updated = '' then
          RegDeleteValue(PathRoot, PathSubkey, 'Path')
        else
          RegWriteExpandStringValue(PathRoot, PathSubkey, 'Path', Updated);
      end;
    end;
  end;
end;
