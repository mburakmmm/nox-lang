# Nox kurulum betiği (Windows) — GitHub Releases'ten (bkz. .github/workflows/
# release.yml'nin windows-x64 işi) önceden derlenmiş bir noxc.exe/noxlsp.exe +
# noxrt.o/swap_asm.o + nox.* stdlib + gömülü qbe.exe paketi indirir,
# $env:NOX_INSTALL_DIR (varsayılan $env:USERPROFILE\.nox-lang) altına açar.
# Kullanım (PowerShell):
#
#   irm https://raw.githubusercontent.com/mburakmmm/nox-lang/main/install.ps1 | iex
#
# Ortam değişkenleriyle özelleştirme:
#   NOX_INSTALL_DIR   kurulum kökü (varsayılan: $env:USERPROFILE\.nox-lang)
#   NOX_VERSION       belirli bir sürüm etiketi (ör. v1.0.0) — varsayılan: en son sürüm
#
# `noxc` çalışma zamanında bir C derleyicisi (`cc`/`gcc`, MinGW-w64) BULMAK
# ZORUNDADIR (linkleme için) — bu betik `qbe`yi PAKETİN İÇİNDE GETİRİR (bkz.
# release workflow'unun belge notu) ama MinGW-w64'ü KURMAZ — `install.sh`nin
# macOS/Linux'ta Xcode CLT/build-essential'a GÜVENDİĞİ AYNI ilke (bkz. o
# betiğin belge notu).

$ErrorActionPreference = "Stop"

$Repo = "mburakmmm/nox-lang"
$InstallDir = if ($env:NOX_INSTALL_DIR) { $env:NOX_INSTALL_DIR } else { Join-Path $env:USERPROFILE ".nox-lang" }

function Write-Log([string]$Message) {
    Write-Host "==> " -ForegroundColor Green -NoNewline
    Write-Host $Message
}
function Write-Warn([string]$Message) {
    Write-Host "!! " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}
function Die([string]$Message) {
    Write-Host "hata: " -ForegroundColor Red -NoNewline
    Write-Host $Message
    exit 1
}

# Yalnızca x86_64 önceden-derlenmiş paketi VAR (bkz. release.yml'nin
# windows-x64 işi) — ARM64 Windows İçin kaynaktan derleme GEREKİR.
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -ne "AMD64") {
    Die "Desteklenmeyen Windows mimarisi: $arch (yalnızca x86_64/AMD64 önceden derlenmiş paket sağlanır — ARM64 için kaynaktan derleyin: bkz. CONTRIBUTING.md)."
}
$Asset = "windows-x64"

function Resolve-Version {
    if ($env:NOX_VERSION) { return $env:NOX_VERSION }
    # install.sh'in AYNI dersi (bkz. o betiğin `resolve_version`ının belge
    # notu) — API çağrısı BAŞARISIZ olursa (henüz Release yoksa/erişilemezse)
    # HATA AÇIK VE YARDIMCI olmalı, ham bir istisna İLE SESSİZCE ÇÖKMEMELİ.
    try {
        $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -ErrorAction Stop
        if ($response.tag_name) { return $response.tag_name }
    } catch {
        # Aşağıdaki Die'a düşülür.
    }
    Die ("en son sürüm etiketi çözülemedi — henüz bir GitHub Release yayımlanmamış olabilir ya da GitHub API'sine erişilemiyor. Belirli bir sürümü elle kurmak için önce şunu çalıştırın: " + '$env:NOX_VERSION = "v1.0.0"' + " (sonra betiği tekrar çalıştırın).")
}

$Version = Resolve-Version
$Stage = "nox-lang-$Version-$Asset"
$Url = "https://github.com/$Repo/releases/download/$Version/$Stage.zip"

Write-Log "Nox $Version ($Asset) indiriliyor..."
$TmpDir = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
try {
    $ZipPath = Join-Path $TmpDir "$Stage.zip"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $ZipPath
    } catch {
        Die "indirilemedi: $Url"
    }

    Write-Log "Açılıyor -> $InstallDir"
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Expand-Archive -Path $ZipPath -DestinationPath $TmpDir
    Copy-Item -Recurse -Force (Join-Path $TmpDir "$Stage\*") $InstallDir
} finally {
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}

$ccFound = Get-Command cc -ErrorAction SilentlyContinue
if (-not $ccFound) { $ccFound = Get-Command gcc -ErrorAction SilentlyContinue }
if (-not $ccFound) {
    Write-Warn "'cc'/'gcc' (MinGW-w64 C derleyicisi) bulunamadı — noxc DERLENEN programları linklerken buna ihtiyaç duyar."
    Write-Warn "Kurulum için: https://www.msys2.org/ (MSYS2 üzerinden 'pacman -S mingw-w64-x86_64-gcc') ya da https://github.com/skeeto/w64devkit"
}

Write-Log "Kuruldu: $InstallDir"

$BinDir = Join-Path $InstallDir "bin"
$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($UserPath -notlike "*$BinDir*") {
    $NewPath = if ($UserPath) { "$UserPath;$BinDir" } else { $BinDir }
    [Environment]::SetEnvironmentVariable("PATH", $NewPath, "User")
    Write-Log "PATH'e eklendi (kalıcı, kullanıcı ortam değişkeni) — YENİ bir terminal açın:"
} else {
    Write-Log "PATH zaten şunu içeriyor:"
}
Write-Host ""
Write-Host "    $BinDir"
Write-Host ""
Write-Log "Doğrulama: noxc --version   (yeni bir terminalde)"
