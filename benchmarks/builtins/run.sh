#!/bin/sh
# Builtin mikro-benchmark paketi (2.2 aşama 1): aynı 17 iş Nox / C (clang -O2) / CPython. Ölçüt C'dir (bkz. project/v2-2-yol-haritasi-2026-11.md).
# Kullanım: benchmarks/builtins/run.sh [noxc yolu]  (ReleaseFast ile derlenmiş noxc/çalışma zamanı gerekir: zig build -Doptimize=ReleaseFast --prefix /tmp/zrf)
NOXC=${1:-/tmp/zrf/bin/noxc}
D=$(mktemp -d)
HERE=$(cd "$(dirname "$0")" && pwd)
clang -O2 -o "$D/c" "$HERE/builtins_perf.c" -lm && "$D/c" | awk '{print $1, $2}' > "$D/c.txt"
"$NOXC" run "$HERE/builtins_perf.nox" | awk '{print $1, $2}' > "$D/n.txt"
python3 "$HERE/builtins_perf.py" | awk '{print $1, $2}' > "$D/p.txt"
printf '%-22s %9s %9s %9s %8s\n' benchmark nox_ms c_ms py_ms nox/c
paste -d' ' "$D/n.txt" "$D/c.txt" "$D/p.txt" | awk '{n=$2+0;c=$4+0;p=$6+0;r=(c>0)?n/c:0;printf "%-22s %9d %9d %9d %8.2f\n",$1,n,c,p,r}'
rm -rf "$D"
