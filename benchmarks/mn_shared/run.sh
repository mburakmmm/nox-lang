#!/bin/bash
# 9.0.1 ölçüm tabanı: her program × backend × işçi sayısı. Kullanım: benchmarks/mn_shared/run.sh [işçi listesi, örn. "1 2 4 8"]
# Önkoşul: `zig build -Doptimize=ReleaseFast` (Debug runtime ~100x yavaş).
cd "$(dirname "$0")/../.." || exit 1
NOXC=${NOXC:-zig-out/bin/noxc}
WORKERS=${1:-"1 2 4 8"}
OUT=$(mktemp -d)
for prog in pure_compute shared_dict shared_dict_hot shared_all; do
  for be in llvm qbe; do
    "$NOXC" build --backend $be -o "$OUT/$prog.$be" benchmarks/mn_shared/$prog.nox >/dev/null 2>&1 || { echo "$prog $be: DERLEME HATASI"; continue; }
    for w in $WORKERS; do
      s=$(python3 -c 'import time;print(time.time())')
      o=$(NOX_POOL_WORKERS=$w "$OUT/$prog.$be" 2>&1 | tr '\n' ' ')
      e=$(python3 -c "import time;print(round(time.time()-$s,2))")
      echo "$prog backend=$be workers=$w sure=${e}s cikti=[$o]"
    done
    s=$(python3 -c 'import time;print(time.time())')
    o=$("$OUT/$prog.$be" 2>&1 | tr '\n' ' ')
    e=$(python3 -c "import time;print(round(time.time()-$s,2))")
    echo "$prog backend=$be workers=varsayilan sure=${e}s cikti=[$o]"
  done
done
rm -rf "$OUT"
