#!/usr/bin/env bash
# Aşama 0.1 deneyi: Nox'ta yazılmış bir işlev Zig'den C ABI ile çağrılır (yol A: statik bağlama).
# Gerekenler: zig-out/bin/noxc, zig-out/lib/noxrt.o (ReleaseFast için önce `zig build -Doptimize=ReleaseFast`), clang, zig.
# Kullanım: selfhost/spike/01-zig-calls-nox/run.sh        (çıktı: bayt sayacı + Nox/Zig süre oranı)
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT="$PWD"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp selfhost/spike/01-zig-calls-nox/count.nox "$T/count.nox"
"$ROOT/zig-out/bin/noxc" build -o "$T/count" "$T/count.nox" >/dev/null     # `.ll` ikilinin yanına bırakılır; yalnızca LLVM çıktısına ihtiyacımız var
sed 's/@main(/@nox_spike_main(/g' "$T/count.ll" > "$T/count2.ll"             # `main` çakışmasını kaldır (temiz çözüm: hosted --emit-obj + dışa aktarma listesi, bkz. plan 0.3)
clang -O2 -c "$T/count2.ll" -o "$T/count.o" 2>/dev/null
zig build-exe selfhost/spike/01-zig-calls-nox/harness.zig "$T/count.o" "$ROOT/zig-out/lib/noxrt.o" -lc -OReleaseFast -femit-bin="$T/harness"
"$T/harness"
