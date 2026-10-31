#!/bin/sh
# Faz 3.5: fiber/yığın/TLS doğrulamasını GERÇEK mobil hedefte çalıştırır (Android arm64 emülatörü ya da iOS simülatörü).
#   scripts/mobile_stack_probe.sh android        # nox_api36 emülatörünü gerekirse açar
#   scripts/mobile_stack_probe.sh ios <UDID>     # açık bir simülatör
# Kontroller: derin ana yığın, derin fiber, 16 iş parçacığı (TLS yıkımı) başarılı çıkar; fiber yığın taşması sinyalle (SIGSEGV/SIGBUS) sonlanır.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
platform=${1:?android | ios <UDID>}
noxc=${NOXC:-"$root/zig-out/bin/noxc"}
work=/tmp/nox-stack-probe
rm -rf "$work"
mkdir -p "$work"
fail=0

check() { # mod beklenen_çıkış beklenen_stdout
  mode=$1; want_rc=$2; want_out=$3
  out=$(run_probe "$mode" 2>"$work/stderr_$mode" || true)
  rc=$(printf '%s\n' "$out" | sed -n 's/^EXIT=//p' | tail -1)
  body=$(printf '%s\n' "$out" | grep -v '^EXIT=' | tr -d '\r' | head -3 | tr '\n' ' ' | sed 's/ *$//')
  case "$want_rc" in
    signal) ok=0; [ "$rc" = 139 ] || [ "$rc" = 138 ] || [ "$rc" = 134 ] && ok=1; [ -z "$body" ] || ok=0 ;;
    *) ok=0; [ "$rc" = "$want_rc" ] && [ "$body" = "$want_out" ] && ok=1 ;;
  esac
  if [ "$ok" = 1 ]; then echo "ok   $mode (çıkış $rc ${body:+çıktı $body})"; else echo "FAIL $mode: çıkış=$rc çıktı=[$body] beklenen=$want_rc/[$want_out]"; fail=1; fi
}

case "$platform" in
android)
  rt="$root/zig-out/lib/noxrt-android-arm64.o"
  [ -x "$noxc" ] && [ -f "$rt" ] || { echo "noxc ya da android arm64 çalışma zamanı yok (zig build)" >&2; exit 1; }
  ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
  if [ -z "$ndk" ]; then parent="$HOME/Library/Android/sdk/ndk"; ndk="$parent/$(ls -1 "$parent" | tail -n 1)"; fi
  clang=""
  for host in darwin-arm64 darwin-x86_64 linux-x86_64 linux-aarch64; do
    c="$ndk/toolchains/llvm/prebuilt/$host/bin/clang"; [ -x "$c" ] && { clang=$c; break; }
  done
  [ -n "$clang" ] || { echo "NDK clang yok" >&2; exit 1; }
  adb=${ADB:-"$HOME/Library/Android/sdk/platform-tools/adb"}
  if ! "$adb" devices | awk 'NR>1 && $2=="device" { found=1 } END { exit !found }'; then
    "${EMULATOR:-$HOME/Library/Android/sdk/emulator/emulator}" -avd nox_api36 -no-window -no-audio -no-boot-anim >/tmp/nox-emulator.log 2>&1 &
    "$adb" wait-for-device
    "$adb" shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done'
  fi
  "$noxc" build --target android-arm64 --emit-obj -o "$work/probe.o" "$root/tests/golden/mobile_stack_probe.nox"
  "$clang" -c -fPIE -target aarch64-linux-android24 -I "$root/include" -o "$work/host.o" "$root/scripts/mobile_stack_host.c"
  "$clang" -fPIE -pie -target aarch64-linux-android24 -o "$work/probe" "$work/host.o" "$work/probe.o" "$rt" -lm -ldl -llog
  "$adb" push "$work/probe" /data/local/tmp/nox-stack-probe >/dev/null
  "$adb" shell chmod 755 /data/local/tmp/nox-stack-probe
  run_probe() { "$adb" shell "NOX_STACK_MODE=$1 NOX_MOBILE_ROOT=/data/local/tmp/nox-stack /data/local/tmp/nox-stack-probe; echo EXIT=\$?"; }
  ;;
ios)
  udid=${2:?simülatör UDID}
  rt="$root/zig-out/lib/noxrt-ios-simulator-arm64.o"
  [ -x "$noxc" ] && [ -f "$rt" ] || { echo "noxc ya da simülatör çalışma zamanı yok (zig build mobile-rt-simulator)" >&2; exit 1; }
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
  "$noxc" build --target ios-simulator-arm64 --emit-obj -o "$work/probe.o" "$root/tests/golden/mobile_stack_probe.nox"
  xcrun --sdk iphonesimulator clang -c -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -I "$root/include" -o "$work/host.o" "$root/scripts/mobile_stack_host.c"
  xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -o "$work/probe" "$work/host.o" "$work/probe.o" "$rt" -framework Security -framework Foundation -framework CFNetwork
  run_probe() { SIMCTL_CHILD_NOX_STACK_MODE=$1 SIMCTL_CHILD_NOX_MOBILE_ROOT=/tmp/nox-stack-root xcrun simctl spawn "$udid" "$work/probe"; echo "EXIT=$?"; }
  ;;
*) echo "bilinmeyen platform: $platform" >&2; exit 2 ;;
esac

check main_deep 0 20000
check fiber_deep 0 1500
check tls_threads 0 240
check fiber_overflow signal ""
exit $fail
