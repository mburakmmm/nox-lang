#!/bin/sh
# noxc-nightly tip denetleyicisi farksal regresyonu: her `ck_gen.py` kipi + depo dosyaları, Zig ile karşılaştırılır.
# Kullanım: sh scripts/ck_regress.sh [çıktı_dizini] [program_sayısı]   (önkoşul: `zig build nightly`)
# Çıkış kodu: herhangi bir farkta 1. Çıktı dizini geçici olmalıdır (macOS yeniden başlatması /tmp'yi siler).
cd "$(dirname "$0")/.." || exit 1
OUT=${1:-${TMPDIR:-/tmp}/ck_regress}
N=${2:-1500}
BIN=./zig-out/bin/noxc-nightly
rc=0
check_out() {
  label="$1"
  st="$2"
  out="$3"
  first=$(printf '%s\n' "$out" | head -n 1)
  echo "$label: $first"
  if [ "$st" -ne 0 ]; then
    rc=1
    printf '%s\n' "$out" | sed -n '2,6p'
    return
  fi
  bad=$(printf '%s\n' "$out" | grep -v '^ck-diff: OK' || true)
  if [ -z "$first" ] || [ -n "$bad" ]; then
    rc=1
    printf '%s\n' "$bad" | head -n 5
  fi
}

seed=200
for mode in "" --async --methods --builtins --recv --try --construct --ptr --extern --spawn --import --inherit --closure --tuple --generic-cls --generic-fn --prelude-proto --sig --bytes-spawn-dec --consts-ffi-intr; do
  seed=$((seed + 1))
  name=$(printf '%s' "$mode" | tr -d '-')
  [ -z "$name" ] && name=base
  dir="$OUT/$name"
  rm -rf "$dir"
  python3 scripts/ck_gen.py --out "$dir" --count "$N" --seed "$seed" $mode >/dev/null || { echo "$name: üreteç hatası"; rc=1; continue; }
  out=$("$BIN" ck-diff check "$dir"/*.nox 2>&1)
  st=$?
  check_out "$name" "$st" "$out"
done
out=$(git ls-files '*.nox' | grep -v '^selfhost/' | xargs "$BIN" ck-diff check 2>&1)
st=$?
check_out "repo" "$st" "$out"
exit $rc
