#!/bin/bash
# Faz 9.8: M:N paylaşılan modül durumu yarış stresi. `tests/golden/codegen_cases/mn_shared_*.nox` ve `mn_dyn_*.nox` fixture'larını iki backend'de derler ve `NOX_POOL_WORKERS` 1/2/4/8 ile
# ROUNDS tur çalıştırır; çıktı `.expected` ile bire bir aynı olmalı ve stderr boş (sızıntı/çökme yok) olmalıdır.
# Kullanım: [BACKENDS="llvm"] scripts/mn_shared_stress.sh [ROUNDS=5] [WORKERS="1 2 4 8"]   (önkoşul: `zig build`; nightly: .github/workflows/stress.yml)
cd "$(dirname "$0")/.." || exit 1
ROUNDS=${1:-5}
WORKERS=${2:-"1 2 4 8"}
BACKENDS=${BACKENDS:-"llvm qbe"}
NOXC=${NOXC:-zig-out/bin/noxc}
OUT=$(mktemp -d)
fail=0
total=0
for src in tests/golden/codegen_cases/mn_shared_*.nox tests/golden/codegen_cases/mn_dyn_*.nox tests/golden/codegen_cases/wasm_host_interleave.nox; do
  name=$(basename "$src" .nox)
  exp="tests/golden/codegen_cases/$name.expected"
  [ -f "$exp" ] || continue
  for be in $BACKENDS; do
    if ! "$NOXC" build --backend $be -o "$OUT/$name.$be" "$src" >"$OUT/build.log" 2>&1; then
      echo "DERLEME HATASI: $name ($be)"; fail=$((fail + 1)); continue
    fi
    for w in $WORKERS; do
      r=0
      while [ $r -lt "$ROUNDS" ]; do
        total=$((total + 1))
        NOX_POOL_WORKERS=$w timeout 120 "$OUT/$name.$be" >"$OUT/out.txt" 2>"$OUT/err.txt"
        rc=$?
        if [ $rc -ne 0 ] || ! cmp -s "$OUT/out.txt" "$exp" || [ -s "$OUT/err.txt" ]; then
          echo "BAŞARISIZ: $name backend=$be workers=$w tur=$r rc=$rc"
          head -c 300 "$OUT/err.txt"
          fail=$((fail + 1))
        fi
        r=$((r + 1))
      done
    done
  done
done
rm -rf "$OUT"
echo "mn_shared_stress: $total çalıştırma, $fail hata"
[ $fail -eq 0 ]
