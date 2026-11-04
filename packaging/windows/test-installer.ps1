# Kurucuyu sessizce kurar, doğrular, yeniden kurar (PATH tekrarı yok), kaldırır ve izlerin silindiğini doğrular.
#   .\test-installer.ps1 -Installer <setup.exe> [-InstallDir <dizin>]
# Kullanıcı PATH'ine (HKCU\Environment) bakar; yönetici gerekmez.
param(
    [Parameter(Mandatory = $true)][string]$Installer,
    [string]$InstallDir = (Join-Path ([System.IO.Path]::GetTempPath()) "nox-installer-test")
)
$ErrorActionPreference = "Stop"
$bin = Join-Path $InstallDir "bin"
$failures = @()
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "ok   $what" } else { Write-Host "FAIL $what"; $script:failures += $what }
}
function UserPathEntries { ([Environment]::GetEnvironmentVariable("Path", "User") -split ";") | Where-Object { $_ -ne "" } }
function Count-Entry { @(UserPathEntries | Where-Object { $_.TrimEnd("\") -ieq $bin }).Count }

if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
$before = [Environment]::GetEnvironmentVariable("Path", "User")
$install = @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CURRENTUSER", "/DIR=$InstallDir")

$p = Start-Process -FilePath $Installer -ArgumentList $install -Wait -PassThru
Check ($p.ExitCode -eq 0) "kurulum çıkış kodu 0 ($($p.ExitCode))"
Check (Test-Path (Join-Path $bin "noxc.exe")) "bin\noxc.exe kuruldu"
Check (Test-Path (Join-Path $InstallDir "lib\noxrt.o")) "lib\noxrt.o kuruldu"
Check (Test-Path (Join-Path $InstallDir "lib\nox\stdlib")) "stdlib kuruldu"
Check ((Count-Entry) -eq 1) "kullanıcı PATH'ine bin eklendi (tam bir kez)"
$ver = & (Join-Path $bin "noxc.exe") version 2>&1
Check ($LASTEXITCODE -eq 0 -and "$ver" -match "noxc \d+\.\d+\.\d+") "noxc version çalışır ($ver)"
Check (Test-Path (Join-Path $InstallDir "unins000.exe")) "kaldırıcı var"

# Yeniden kurulum: PATH çiftlenmemeli.
$p = Start-Process -FilePath $Installer -ArgumentList $install -Wait -PassThru
Check ($p.ExitCode -eq 0 -and (Count-Entry) -eq 1) "yeniden kurulumda PATH çiftlenmez"

# Kaldırma: kaldırıcı kendini geçici dizine kopyalayıp hemen döner; bitmesini bekle.
Start-Process -FilePath (Join-Path $InstallDir "unins000.exe") -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") -Wait | Out-Null
for ($i = 0; $i -lt 60 -and (Test-Path (Join-Path $bin "noxc.exe")); $i++) { Start-Sleep -Seconds 1 }
Check (-not (Test-Path (Join-Path $bin "noxc.exe"))) "kaldırma noxc.exe'yi sildi"
Check ((Count-Entry) -eq 0) "kaldırma PATH girdisini sildi"
$after = [Environment]::GetEnvironmentVariable("Path", "User")
Check (("$after") -ceq ("$before")) "kullanıcının PATH'inin geri kalanı birebir korundu (önce=[$before] sonra=[$after])"

if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue }
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) başarısız"; exit 1 }
Write-Host "kurucu testi: temiz"
