#!/usr/bin/env bash
# Aşama 0.8 deneyi: Nox'ta özyinelemeli bir yürüyüş + zincir serbest bırakma, Zig'den çağrılır; ana iş parçacığı yığını ile büyük yığınlı iş parçacığı karşılaştırılır.
# Kullanım: selfhost/spike/02-deep-recursion/run.sh [N ...]   (varsayılan: 10000 100000 1000000)
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT="$PWD"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
"$ROOT/zig-out/bin/noxc" build --selfhost-obj -o "$T/deep.o" selfhost/spike/02-deep-recursion/deep.nox >/dev/null
zig build-exe selfhost/spike/02-deep-recursion/harness.zig "$T/deep.o" "$ROOT/zig-out/lib/noxrt.o" -lc -OReleaseFast -femit-bin="$T/h" 2>&1 | grep -v warning || true
echo "ulimit -s (KiB): $(ulimit -s)"
for n in ${@:-10000 100000 1000000}; do
  for mb in 0 256; do
    printf "yığın=%sMB  " "$mb"
    "$T/h" "$n" "$mb" 2>&1 | tail -1 || echo "n=$n ÇÖKTÜ (sinyal)"
  done
done
