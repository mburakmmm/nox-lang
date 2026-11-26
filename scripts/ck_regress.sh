#!/bin/sh
# noxc-nightly tip denetleyicisi farksal regresyonu: her `ck_gen.py` kipi + depo dosyaları, Zig ile karşılaştırılır.
# Kullanım: sh scripts/ck_regress.sh [çıktı_dizini] [program_sayısı]   (önkoşul: `zig build nightly`)
# Çıkış kodu: herhangi bir farkta 1. Çıktı dizini geçici olmalıdır (macOS yeniden başlatması /tmp'yi siler).
cd "$(dirname "$0")/.." || exit 1
OUT=${1:-${TMPDIR:-/tmp}/ck_regress}
N=${2:-1500}
BIN=./zig-out/bin/noxc-nightly
rc=0
seed=200
for mode in "" --async --methods --builtins --recv --try --construct --ptr --extern --spawn --import --inherit --closure --tuple --generic-cls; do
  seed=$((seed + 1))
  name=$(printf '%s' "$mode" | tr -d '-')
  [ -z "$name" ] && name=base
  dir="$OUT/$name"
  rm -rf "$dir"
  python3 scripts/ck_gen.py --out "$dir" --count "$N" --seed "$seed" $mode >/dev/null || { echo "$name: üreteç hatası"; rc=1; continue; }
  res=$($BIN ck-diff check "$dir"/*.nox 2>&1 | head -1)
  echo "$name: $res"
  case "$res" in "ck-diff: OK"*) ;; *) rc=1 ;; esac
done
res=$(git ls-files '*.nox' | grep -v '^selfhost/' | xargs $BIN ck-diff check 2>&1 | head -1)
echo "repo: $res"
case "$res" in "ck-diff: OK"*) ;; *) rc=1 ;; esac
exit $rc
