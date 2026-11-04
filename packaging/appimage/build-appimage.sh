#!/bin/bash
# Bir GitHub Release arşivinden AppImage üretir.
# Kullanım: build-appimage.sh <vX.Y.Z> <x86_64|aarch64> <çıktı-dizini>
# Çıktı: <çıktı>/noxc-<sürüm>-<mimari>.AppImage ve .sha256. `appimagetool` yoksa GitHub'dan indirilir (CI için; yerelde PATH'e koyun).
# AppRun, çağrılış adına göre noxc ya da noxlsp çalıştırır (AppImage'e `noxlsp` adıyla symlink verilirse language server açılır).
set -euo pipefail
TAG="${1:?sürüm etiketi gerekli (vX.Y.Z)}"
ARCH="${2:?mimari gerekli (x86_64|aarch64)}"
OUT="${3:?çıktı dizini gerekli}"
REPO="${REPO:-mburakmmm/nox-lang}"
VER="${TAG#v}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

case "$ARCH" in
  x86_64) ASSET=linux-x64 ;;
  aarch64) ASSET=linux-arm64 ;;
  *) echo "desteklenmeyen mimari: $ARCH" >&2; exit 1 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

echo "== release arşivi indiriliyor ($TAG, $ASSET)"
ARCHIVE="nox-lang-${TAG}-${ASSET}.tar.gz"
curl -fsSL -o "$WORK/$ARCHIVE" "https://github.com/$REPO/releases/download/$TAG/$ARCHIVE"
EXPECTED="$(curl -fsSL "https://github.com/$REPO/releases/download/$TAG/$ARCHIVE.sha256" | awk '{print $1}')"
ACTUAL="$( (sha256sum "$WORK/$ARCHIVE" 2>/dev/null || shasum -a 256 "$WORK/$ARCHIVE") | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || { echo "sağlama toplamı uyuşmuyor: $EXPECTED != $ACTUAL" >&2; exit 1; }
tar xzf "$WORK/$ARCHIVE" -C "$WORK"

echo "== AppDir"
APPDIR="$WORK/noxc.AppDir"
mkdir -p "$APPDIR/usr"
cp -a "$WORK/nox-lang-${TAG}-${ASSET}/bin" "$WORK/nox-lang-${TAG}-${ASSET}/lib" "$WORK/nox-lang-${TAG}-${ASSET}/include" "$APPDIR/usr/"
install -Dm644 "$WORK/nox-lang-${TAG}-${ASSET}/LICENSE" "$APPDIR/usr/share/licenses/noxc/LICENSE"
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
# Arşivle gelen `qbe` noxc'nin çıplak PATH aramasında bulunsun.
export PATH="$HERE/usr/bin:$PATH"
case "$(basename "${ARGV0:-$0}")" in
  noxlsp*) exec "$HERE/usr/bin/noxlsp" "$@" ;;
esac
exec "$HERE/usr/bin/noxc" "$@"
APPRUN
chmod 755 "$APPDIR/AppRun"
cat > "$APPDIR/noxc.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=noxc
GenericName=Nox compiler
Comment=Compiler and project tool for the Nox programming language
Exec=noxc
Icon=noxc
Terminal=true
Categories=Development;
DESKTOP
cp "$ROOT/assets/brand/icon-256.png" "$APPDIR/noxc.png"
cp "$ROOT/assets/brand/icon-256.png" "$APPDIR/.DirIcon"

TOOL="$(command -v appimagetool || true)"
if [ -z "$TOOL" ]; then
  echo "== appimagetool indiriliyor"
  TOOL="$WORK/appimagetool"
  curl -fsSL -o "$TOOL" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage"
  chmod +x "$TOOL"
fi

echo "== AppImage"
FILE="$OUT/noxc-${VER}-${ARCH}.AppImage"
# FUSE olmayan ortamlarda (CI, konteyner) araç kendini açıp çalıştırsın.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$ARCH" "$TOOL" "$APPDIR" "$FILE"
chmod +x "$FILE"
(cd "$OUT" && (sha256sum "$(basename "$FILE")" 2>/dev/null || shasum -a 256 "$(basename "$FILE")") > "$(basename "$FILE").sha256")
echo "AppImage: $FILE ($(du -h "$FILE" | cut -f1))"
