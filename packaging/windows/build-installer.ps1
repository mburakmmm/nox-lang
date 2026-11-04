# Release `.zip`'inden açılmış bir dizinden (bin\, lib\, include\, LICENSE, ...) Windows kurucusunu derler.
#   .\build-installer.ps1 -Stage <dizin> -Version 2.0.138 -OutDir <çıktı>
# Çıktı: <OutDir>\nox-lang-v<Version>-windows-x64-setup.exe ve .sha256. Inno Setup 6 (`iscc`) gerekir: runner'da
# `choco install innosetup -y`; yerelde https://jrsoftware.org/isinfo.php.
param(
    [Parameter(Mandatory = $true)][string]$Stage,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$OutDir
)
$ErrorActionPreference = "Stop"

$iscc = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    foreach ($candidate in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")) {
        if (Test-Path $candidate) { $iscc = $candidate; break }
    }
}
if (-not $iscc) { throw "Inno Setup (ISCC.exe) bulunamadı: choco install innosetup -y" }
if (-not (Test-Path (Join-Path $Stage "bin\noxc.exe"))) { throw "$Stage içinde bin\noxc.exe yok: bu bir Windows release arşivi açılmış dizini olmalı" }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
& $iscc "/DAppVersion=$Version" "/DSourceDir=$((Resolve-Path $Stage).Path)" "/DOutputDir=$((Resolve-Path $OutDir).Path)" (Join-Path $here "nox.iss")
if ($LASTEXITCODE -ne 0) { throw "iscc başarısız (çıkış $LASTEXITCODE)" }

$exe = Join-Path $OutDir "nox-lang-v$Version-windows-x64-setup.exe"
if (-not (Test-Path $exe)) { throw "beklenen kurucu üretilmedi: $exe" }
$hash = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()
Set-Content -Path "$exe.sha256" -Value "$hash  $(Split-Path -Leaf $exe)" -NoNewline
Write-Host "kurucu: $exe ($([math]::Round((Get-Item $exe).Length / 1MB, 1)) MB)"
