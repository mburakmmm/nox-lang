#!/bin/sh
# TODO 3.7: disk-dolu davranışı gerçek mobil hedefte (atomik yazma eski içeriği korur, artık dosya bırakmaz; düz yazma ve SQLite temiz hata verir, veritabanı tutarlı kalır).
#   scripts/mobile_sandbox_probe.sh ios <UDID>     iOS simülatörü; RLIMIT_FSIZE (EFBIG) + GERÇEK ENOSPC (macOS RAM diski)
#   scripts/mobile_sandbox_probe.sh android        android-arm64 emülatörü; RLIMIT_FSIZE; ANDROID_FILL=1 ise bölümü doldurarak GERÇEK ENOSPC (feda edilebilir emülatörde!)
set -u
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
platform=${1:?android | ios <UDID>}
noxc=${NOXC:-"$root/zig-out/bin/noxc"}
work=/tmp/nox-sbx-probe
rm -rf "$work"; mkdir -p "$work"
fail=0
want_base="baseline atomic=ok intact=yes tmp_left=no plain=ok sqlite=ok consistent=yes temp_sort=ok vacuum=ok"
want_full="disk_full atomic=fail intact=yes tmp_left=no plain=fail sqlite=fail consistent=yes temp_sort=ok vacuum=ok"

check() { # ad beklenen alınan
  if [ "$3" = "$2" ]; then echo "ok   $1: $3"; else echo "FAIL $1: [$3] beklenen [$2]"; fail=$((fail+1)); fi
}

case "$platform" in
android)
  rt="$root/zig-out/lib/noxrt-android-arm64.o"
  sdk=${ANDROID_HOME:-"$HOME/Library/Android/sdk"}
  adb=${ADB:-"$sdk/platform-tools/adb"}
  ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-"$sdk/ndk/$(ls -1 "$sdk/ndk" | tail -n 1)"}}
  clang=""; for h in darwin-arm64 darwin-x86_64 linux-x86_64 linux-aarch64; do c="$ndk/toolchains/llvm/prebuilt/$h/bin/clang"; [ -x "$c" ] && { clang=$c; break; }; done
  [ -n "$clang" ] && [ -f "$rt" ] || { echo "NDK clang ya da android çalışma zamanı yok" >&2; exit 1; }
  "$noxc" build --target android-arm64 --emit-obj -o "$work/probe.o" "$root/tests/golden/mobile_sandbox_probe.nox" >/dev/null
  "$clang" -c -fPIE -target aarch64-linux-android24 -I "$root/include" -o "$work/host.o" "$root/scripts/mobile_sandbox_host.c"
  "$clang" -fPIE -pie -target aarch64-linux-android24 -o "$work/probe" "$work/host.o" "$work/probe.o" "$rt" -lm -ldl -llog
  "$adb" push "$work/probe" /data/local/tmp/nox-sbx-probe >/dev/null; "$adb" shell chmod 755 /data/local/tmp/nox-sbx-probe
  run_probe() { # mod kök [fsize] [blok]
    "$adb" shell "rm -rf '$2'; mkdir -p '$2'; NOX_SBX_MODE=$1 NOX_MOBILE_ROOT='$2' NOX_SBX_FSIZE='${3:-}' NOX_SBX_BLOCKS=${4:-256} /data/local/tmp/nox-sbx-probe 2>/dev/null; rm -rf '$2'" | tr -d '\r' | head -1
  }
  root_dir=/data/local/tmp/nox-sbx-root
  ;;
ios)
  udid=${2:?simülatör UDID}
  rt="$root/zig-out/lib/noxrt-ios-simulator-arm64.o"
  [ -f "$rt" ] || { echo "simülatör çalışma zamanı yok" >&2; exit 1; }
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
  "$noxc" build --target ios-simulator-arm64 --emit-obj -o "$work/probe.o" "$root/tests/golden/mobile_sandbox_probe.nox" >/dev/null
  xcrun --sdk iphonesimulator clang -c -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -I "$root/include" -o "$work/host.o" "$root/scripts/mobile_sandbox_host.c"
  xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -o "$work/probe" "$work/host.o" "$work/probe.o" "$rt" -framework Security -framework Foundation -framework CFNetwork
  run_probe() {
    rm -rf "$2"; mkdir -p "$2"
    SIMCTL_CHILD_NOX_SBX_MODE=$1 SIMCTL_CHILD_NOX_MOBILE_ROOT="$2" SIMCTL_CHILD_NOX_SBX_FSIZE="${3:-}" SIMCTL_CHILD_NOX_SBX_BLOCKS="${4:-256}" xcrun simctl spawn "$udid" "$work/probe" 2>/dev/null | head -1
    rm -rf "$2"
  }
  root_dir=/tmp/nox-sbx-root
  ;;
*) echo "bilinmeyen platform" >&2; exit 2 ;;
esac

check baseline          "$want_base" "$(run_probe baseline "$root_dir")"
check disk_full_efbig   "$want_full" "$(run_probe disk_full "$root_dir" 20000)"

if [ "$platform" = ios ]; then
  # GERÇEK ENOSPC: 32 MB RAM diski, 64 KB boş bırakacak kadar doldurulur.
  dev=$(hdiutil attach -nomount ram://65536 | awk '{print $1}')
  if diskutil erasevolume HFS+ noxfull "$dev" >/dev/null 2>&1; then
    dd if=/dev/zero of=/Volumes/noxfull/fill bs=4096 2>/dev/null
    sz=$(stat -f %z /Volumes/noxfull/fill); truncate -s $((sz - 65536)) /Volumes/noxfull/fill
    check disk_full_enospc "$want_full" "$(run_probe disk_full /Volumes/noxfull/root)"
    rm -f /Volumes/noxfull/fill
    check space_recovered "$want_base" "$(run_probe baseline /Volumes/noxfull/root)"
    diskutil eject "$dev" >/dev/null 2>&1 || hdiutil detach "$dev" -force >/dev/null 2>&1
  else
    echo "FAIL disk_full_enospc: RAM diski biçimlendirilemedi"; fail=$((fail+1)); hdiutil detach "$dev" -force >/dev/null 2>&1
  fi
elif [ "${ANDROID_FILL:-0}" = 1 ]; then
  fill=/data/local/tmp/nox-fill
  trap '"$adb" shell rm -f "$fill" >/dev/null 2>&1' EXIT
  "$adb" shell "dd if=/dev/zero of=$fill bs=1048576 2>/dev/null; stat -c %s $fill" >"$work/fillsize" 2>/dev/null
  # Android kabuğu (mksh) 32-bit aritmetik kullanır; boyut hesabı Mac tarafında yapılır.
  sz=$(tr -d '\r' < "$work/fillsize" | tail -1)
  "$adb" shell "truncate -s $((sz - 2097152)) $fill; df -k /data | tail -1" | tr -d '\r' | tail -1
  # Boşluk ~2 MB: yük 4 MB (8192 blok) olduğundan atomik/düz yazma ve SQLite eklemeleri gerçekten ENOSPC ile başarısız olur.
  check disk_full_enospc "$want_full" "$(run_probe disk_full "$root_dir" "" 8192)"
  "$adb" shell rm -f "$fill"; sleep 2
  check space_recovered "$want_base" "$(run_probe baseline "$root_dir")"
fi
echo "başarısız senaryo: $fail"
[ $fail -eq 0 ]
