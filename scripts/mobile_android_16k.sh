#!/bin/sh
# TODO 4.4: Android 16 KiB sayfa boyutunu ÇALIŞMA ANINDA doğrular (ELF başlık ölçümü değil): 16 KiB sayfalı çekirdek, Nox yığın/stdlib probe'ları ve
# paylaşılan kütüphane yüklemesi (16 KiB hizalı yüklenir, 4 KiB hizalı yüklenmez). Gerekli imaj (yaklaşık 1,5 GB, bir kez):
#   sdkmanager "system-images;android-35;google_apis_ps16k;arm64-v8a"
# AVD yoksa oluşturulur (nox_api35_16k); mevcut nox_api36 AVD'ye dokunulmaz. Emülatör 5556 portunda açılır.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
sdk=${ANDROID_HOME:-"$HOME/Library/Android/sdk"}
adb=${ADB:-"$sdk/platform-tools/adb"}
emulator=${EMULATOR:-"$sdk/emulator/emulator"}
serial=emulator-5556
export ANDROID_SERIAL=$serial
if ! "$emulator" -list-avds | grep -qx nox_api35_16k; then
  echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd -n nox_api35_16k -k "system-images;android-35;google_apis_ps16k;arm64-v8a" -d pixel_6 --force
fi
if ! "$adb" devices | grep -q "^$serial[[:space:]]*device"; then
  "$emulator" -avd nox_api35_16k -port 5556 -no-window -no-audio -no-boot-anim -no-snapshot >/tmp/nox-emulator16k.log 2>&1 &
  "$adb" wait-for-device
  "$adb" shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done'
fi
page=$("$adb" shell getconf PAGE_SIZE | tr -d '\r')
[ "$page" = 16384 ] || { echo "FAIL: cihaz sayfa boyutu $page, 16384 bekleniyordu" >&2; exit 1; }
echo "ok   sayfa boyutu 16384"
"$root/scripts/mobile_stack_probe.sh" android
run_out=$("$root/scripts/mobile_android_run.sh" 2>&1)
for want in "suite 0 pending 0" "probe 0 pending 0"; do
  echo "$run_out" | grep -q "^$want" || { echo "FAIL: '$want' çıktısı yok"; echo "$run_out" | tail -5; exit 1; }
  echo "ok   $want"
done

ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-"$sdk/ndk/$(ls -1 "$sdk/ndk" | tail -n 1)"}}
clang=""
for host in darwin-arm64 darwin-x86_64 linux-x86_64 linux-aarch64; do
  c="$ndk/toolchains/llvm/prebuilt/$host/bin/clang"; [ -x "$c" ] && { clang=$c; break; }
done
[ -n "$clang" ] || { echo "NDK clang yok" >&2; exit 1; }
rt="$root/zig-out/lib/noxrt-android-arm64.o"
work=/tmp/nox-so16k
rm -rf "$work"
mkdir -p "$work"
"$root/zig-out/bin/noxc" build --target android-arm64 --emit-obj -o "$work/probe.o" "$root/tests/golden/mobile_stack_probe.nox"
cat > "$work/load.c" << 'CEOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
    return dlsym(h, "nox_app_create") ? 0 : 2;
}
CEOF
"$clang" -fPIE -pie -target aarch64-linux-android24 -o "$work/load" "$work/load.c" -ldl
"$adb" push "$work/load" /data/local/tmp/nox-load >/dev/null
"$adb" shell chmod 755 /data/local/tmp/nox-load
fail=0
for align in 16384 4096; do
  "$clang" -shared -fPIC -target aarch64-linux-android24 "-Wl,-z,max-page-size=$align" -o "$work/lib$align.so" "$work/probe.o" "$rt" -lm -ldl -llog
  "$adb" push "$work/lib$align.so" "/data/local/tmp/lib$align.so" >/dev/null
  rc=$("$adb" shell "/data/local/tmp/nox-load /data/local/tmp/lib$align.so >/dev/null 2>&1; echo \$?" | tr -d '\r' | tail -1)
  if [ "$align" = 16384 ]; then
    [ "$rc" = 0 ] && echo "ok   16 KiB hizalı .so yüklenir" || { echo "FAIL: 16 KiB hizalı .so yüklenmedi (çıkış $rc)"; fail=1; }
  else
    [ "$rc" != 0 ] && echo "ok   4 KiB hizalı .so yüklenmez (negatif kontrol, çıkış $rc)" || { echo "FAIL: 4 KiB hizalı .so 16 KiB çekirdekte yüklendi; test ayırt edici değil"; fail=1; }
  fi
done
exit $fail
