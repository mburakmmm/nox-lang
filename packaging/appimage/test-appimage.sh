#!/bin/bash
# AppImage'i çalıştırıp doğrular. Kullanım: test-appimage.sh <dosya.AppImage> <vX.Y.Z>
set -euo pipefail
IMG="$(readlink -f "${1:?AppImage dosyası gerekli}")"
VER="${2:?sürüm etiketi gerekli}"
VER="${VER#v}"
# FUSE gerektirmeden çalışsın (CI): AppImage kendini geçici dizine açar.
export APPIMAGE_EXTRACT_AND_RUN=1

"$IMG" version 2>&1 | tee /dev/stderr | grep -q "noxc $VER"
printf 'print(6 * 7)\n' > /tmp/hello.nox
test "$("$IMG" run /tmp/hello.nox)" = "42"
test "$("$IMG" run --backend qbe /tmp/hello.nox)" = "42"

# `noxc upgrade` koruması 2.0.140'tan itibaren vardır; daha eski bir release üzerinde atlanır.
if [ "$(printf '%s\n' 2.0.140 "$VER" | sort -V | head -n1)" = "2.0.140" ]; then
  if "$IMG" upgrade v99.0.0 2> /tmp/upgrade.err; then echo "upgrade başarılı olmamalıydı"; exit 1; fi
  grep -q "installed by AppImage" /tmp/upgrade.err
else
  echo "== noxc upgrade koruması atlandı ($VER < 2.0.140)"
fi

# AppRun, çağrılış adına (ARGV0) göre noxlsp'yi seçer. AppImage çalışma zamanı ARGV0'ı kendisi belirlediğinden mantık, AppImage açılıp
# AppRun doğrudan çalıştırılarak sınanır: ARGV0=noxlsp ile language server açılır (stdin kapalı olduğundan hemen kapanır), noxc yardımı basılmaz.
EXTRACT="$(mktemp -d)"
(cd "$EXTRACT" && "$IMG" --appimage-extract > /dev/null)
ARGV0=noxlsp timeout 10 "$EXTRACT/squashfs-root/AppRun" < /dev/null > /tmp/lsp.out 2> /tmp/lsp.err || true
if grep -q -E "Usage|Kullanım" /tmp/lsp.err /tmp/lsp.out; then echo "ARGV0=noxlsp noxlsp'yi seçmedi (noxc yardım ekranı basıldı)"; exit 1; fi
# Ve ARGV0'sız çağrı noxc'dir.
"$EXTRACT/squashfs-root/AppRun" version 2>&1 | grep -q "noxc $VER"
rm -rf "$EXTRACT"
echo "appimage testi: temiz"
