#!/bin/sh
# TODO 3.9: saat/entropi/log sözleşmesi gerçek mobil hedefte. Program 4 sn uyur; bu sırada süreç 3 sn dondurulup sürdürülür (SIGSTOP/SIGCONT, uygulamanın arka plana
# alınmasının benzetimi). Monoton saat, uyku dahil monoton saat ve duvar saati birbirleriyle tutarlı (uyku zamanlayıcısı süreç donmuşken de akar: ~4 sn) ilerlemeli;
# CSPRNG iki çağrıda farklı 32 hex karakter vermeli; log seviye filtresi ve gizli değer maskeleme çalışmalı.
# NOT: gerçek CİHAZ uykusu (suspend) emülatörde/simülatörde yoktur; `nox.time.boot_ms` ile `instant_now` arasındaki uyku farkı belgelenmiştir (docs/stdlib/time.md), ölçülmedi.
#   scripts/mobile_clock_probe.sh ios <UDID>  |  scripts/mobile_clock_probe.sh android
set -u
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
platform=${1:?android | ios <UDID>}
noxc=${NOXC:-"$root/zig-out/bin/noxc"}
work=/tmp/nox-clock-probe
rm -rf "$work"; mkdir -p "$work"
case "$platform" in
android)
  rt="$root/zig-out/lib/noxrt-android-arm64.o"
  sdk=${ANDROID_HOME:-"$HOME/Library/Android/sdk"}
  adb=${ADB:-"$sdk/platform-tools/adb"}
  ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-"$sdk/ndk/$(ls -1 "$sdk/ndk" | tail -n 1)"}}
  clang=""; for h in darwin-arm64 darwin-x86_64 linux-x86_64 linux-aarch64; do c="$ndk/toolchains/llvm/prebuilt/$h/bin/clang"; [ -x "$c" ] && { clang=$c; break; }; done
  [ -n "$clang" ] && [ -f "$rt" ] || { echo "NDK clang ya da android çalışma zamanı yok" >&2; exit 1; }
  "$noxc" build --target android-arm64 --emit-obj -o "$work/probe.o" "$root/tests/golden/mobile_clock_probe.nox" >/dev/null
  "$clang" -c -fPIE -target aarch64-linux-android24 -I "$root/include" -o "$work/host.o" "$root/scripts/mobile_stack_host.c"
  "$clang" -fPIE -pie -target aarch64-linux-android24 -o "$work/probe" "$work/host.o" "$work/probe.o" "$rt" -lm -ldl -llog
  "$adb" push "$work/probe" /data/local/tmp/nox-clock-probe >/dev/null; "$adb" shell chmod 755 /data/local/tmp/nox-clock-probe
  run_probe() { "$adb" shell "NOX_MOBILE_ROOT=/data/local/tmp/nox-clock /data/local/tmp/nox-clock-probe 2>/dev/null" | tr -d '\r' | head -1; }
  pid_of() { "$adb" shell pidof nox-clock-probe | tr -d '\r'; }
  stop_pid() { "$adb" shell kill -STOP "$1"; }
  cont_pid() { "$adb" shell kill -CONT "$1"; }
  ;;
ios)
  udid=${2:?simülatör UDID}
  rt="$root/zig-out/lib/noxrt-ios-simulator-arm64.o"
  [ -f "$rt" ] || { echo "simülatör çalışma zamanı yok" >&2; exit 1; }
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
  "$noxc" build --target ios-simulator-arm64 --emit-obj -o "$work/probe.o" "$root/tests/golden/mobile_clock_probe.nox" >/dev/null
  xcrun --sdk iphonesimulator clang -c -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -I "$root/include" -o "$work/host.o" "$root/scripts/mobile_stack_host.c"
  xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -o "$work/probe" "$work/host.o" "$work/probe.o" "$rt" -framework Security -framework Foundation -framework CFNetwork
  run_probe() { SIMCTL_CHILD_NOX_MOBILE_ROOT=/tmp/nox-clock-root xcrun simctl spawn "$udid" "$work/probe" 2>/dev/null | head -1; }
  pid_of() { pgrep -f "$work/probe" | head -1; }
  stop_pid() { kill -STOP "$1"; }
  cont_pid() { kill -CONT "$1"; }
  ;;
*) echo "bilinmeyen platform" >&2; exit 2 ;;
esac

run_probe >"$work/out.txt" &
bg=$!
# Süreç başlatma gecikmesi (CI'da ilk `simctl spawn` ~10 sn) test konusu değildir: süreç görünene kadar beklenir, sonra 1 sn uyku içinde dondurulur.
pid=""; n=0
while [ -z "$pid" ] && [ $n -lt 80 ]; do pid=$(pid_of); [ -n "$pid" ] || { sleep 0.25; n=$((n+1)); }; done
sleep 1
if [ -n "$pid" ]; then stop_pid "$pid"; sleep 3; cont_pid "$pid"; fi
wait $bg
line=$(cat "$work/out.txt")
python3 - "$line" "${pid:-}" <<'PY'
import re, sys
line, pid = sys.argv[1], sys.argv[2]
m = re.fullmatch(r"mono=(\d+) boot=(\d+) wall=(\d+) rng=(\w+) log=(\w+) redact=(\w+)", line)
if not m:
    print(f"FAIL: çıktı ayrıştırılamadı: [{line}]"); sys.exit(1)
mono, boot, wall = (int(m.group(i)) for i in (1, 2, 3))
errs = []
for name, v in (("mono", mono), ("boot", boot), ("wall", wall)):
    if not 3900 <= v <= 5500:
        errs.append(f"{name}={v} ms (beklenen 3900..5500: uyku süreç donmuşken de akar)")
if max(mono, boot, wall) - min(mono, boot, wall) > 300:
    errs.append(f"saatler birbirinden >300 ms ayrıştı: mono={mono} boot={boot} wall={wall}")
for k, v in (("rng", m.group(4)), ("log", m.group(5)), ("redact", m.group(6))):
    if v != "ok":
        errs.append(f"{k}={v}")
if not pid:
    errs.append("süreç bulunamadı (dondurma uygulanmadı)")
if errs:
    print("FAIL:", "; ".join(errs), "|", line); sys.exit(1)
print(f"ok   saat/entropi/log: {line} (pid {pid} 3 sn durdurulup sürdürüldü)")
PY
