#!/usr/bin/env bash
# Sabitlenmiş QBE 1.3'ü kaynaktan, upstream `amd64_win` ABI yamasıyla derler. Kullanım: scripts/build_qbe.sh <hedef-dosya> [çalışma-dizini]
#
# Neden yamalı: QBE 1.3'ün `amd64_win` arka ucunda bir spill/reload kopyası YANLIŞ register sınıfını (`Kl`, `instr->cls` yerine) kullanır ve `movsd %r10, ...` gibi
# geçersiz bir komut üretir. Yamasız bir QBE ile macOS/Linux'tan `noxc build --target windows-x64` düşer (v2.0.174 ölçümü); Windows release işi aynı yamayı kendi
# PowerShell adımında uygular. Bu betik aynı metin-yamasını macOS/Linux QBE'sine uygular, böylece release arşivlerindeki `bin/qbe` ile bu makinelerde Windows `.exe`
# çapraz derlenebilir. Yama satırı bulunmazsa (upstream değişmişse) betik SESSİZCE geçmez, hata verir. Kaynak arşivin sağlama toplamı sabittir.
#
# Not: `make` konağın varsayılan hedefini seçer (macOS arm64: arm64_apple, Linux x86-64: amd64_sysv); `noxc` `-t`yi her zaman açıkça geçtiğinden bu önemli değildir.
set -euo pipefail

dest="${1:?kullanım: build_qbe.sh <hedef-dosya> [çalışma-dizini]}"
work="${2:-$(mktemp -d)}"
version="1.3"
url="https://c9x.me/compile/release/qbe-${version}.tar.xz"
sha256="d587905d620dc5e1d2bfa7c2cc642b9b837aa89a3188c6e37b53d756cf66e320"
needle='emit(Ocopy, Kl, instr->to, SLOT(-slot_offset), R);'
patched='emit(Ocopy, instr->cls, instr->to, SLOT(-slot_offset), R);'

mkdir -p "$work"
archive="$work/qbe-${version}.tar.xz"
curl -fsSL -o "$archive" "$url"
if command -v sha256sum >/dev/null 2>&1; then actual="$(sha256sum "$archive" | awk '{print $1}')"; else actual="$(shasum -a 256 "$archive" | awk '{print $1}')"; fi
if [ "$actual" != "$sha256" ]; then
  echo "build_qbe: sağlama toplamı uyuşmuyor (beklenen $sha256, gelen $actual)" >&2
  exit 1
fi
tar xf "$archive" -C "$work"
src="$work/qbe-${version}"

file="$src/amd64/winabi.c"
if ! grep -qF "$needle" "$file"; then
  echo "build_qbe: amd64_win yaması için beklenen satır bulunamadı (upstream değişmiş olabilir): $needle" >&2
  exit 1
fi
# Satır içi, tek geçişli değiştirme (sed/perl bölgesel farklarına bağımlı olmamak için python3).
python3 - "$file" "$needle" "$patched" <<'PY'
import sys
path, needle, patched = sys.argv[1:4]
s = open(path, encoding="utf-8").read()
if s.count(needle) != 1:
    sys.exit("build_qbe: yama satırı beklenen sayıda (1) geçmiyor: %d" % s.count(needle))
open(path, "w", encoding="utf-8").write(s.replace(needle, patched))
PY
grep -qF "$patched" "$file"

jobs="$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2) | head -1)"
make -C "$src" -j"$jobs" >/dev/null
mkdir -p "$(dirname "$dest")"
cp "$src/qbe" "$dest"
chmod 755 "$dest"
echo "build_qbe: yamalı QBE $version -> $dest"
