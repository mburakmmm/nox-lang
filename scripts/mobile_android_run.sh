#!/bin/sh
# Runs the stdlib suite and the runtime probe on the arm64 emulator.
# Boots nox_api36 when no device is attached. android-x64 is not executed.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
noxc=${NOXC:-"$root/zig-out/bin/noxc"}
rt="$root/zig-out/lib/noxrt-android-arm64.o"
if [ ! -x "$noxc" ] || [ ! -f "$rt" ]; then
  echo "noxc or the android arm64 runtime is missing" >&2
  exit 1
fi
ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}
if [ -z "$ndk" ]; then
  parent="$HOME/Library/Android/sdk/ndk"
  name=$(ls -1 "$parent" | tail -n 1)
  ndk="$parent/$name"
fi
clang=""
for host in darwin-arm64 darwin-x86_64 linux-x86_64 linux-aarch64; do
  candidate="$ndk/toolchains/llvm/prebuilt/$host/bin/clang"
  if [ -x "$candidate" ]; then
    clang=$candidate
    break
  fi
done
if [ -z "$clang" ]; then
  echo "NDK clang was not found" >&2
  exit 1
fi
adb=${ADB:-"$HOME/Library/Android/sdk/platform-tools/adb"}
if ! "$adb" devices | awk 'NR>1 && $2=="device" { found=1 } END { exit !found }'; then
  emulator=${EMULATOR:-"$HOME/Library/Android/sdk/emulator/emulator"}
  "$emulator" -avd nox_api36 -no-window -no-audio -no-boot-anim >/tmp/nox-emulator.log 2>&1 &
  "$adb" wait-for-device
  "$adb" shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done'
fi
work=/tmp/nox-android-run
rm -rf "$work"
mkdir -p "$work"
"$noxc" build --target android-arm64 --emit-obj -o "$work/suite.o" "$root/tests/golden/mobile_stdlib_suite.nox"
"$noxc" build --target android-arm64 --emit-obj -o "$work/probe.o" "$root/tests/golden/mobile_runtime_probe.nox"
cat > "$work/suite_host.c" << 'EOF'
#include "nox_embed.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
extern int64_t mobile_suite(void *rt, char *root);
int main(void) {
    const char *dir = "/data/local/tmp/nox-suite-root";
    NoxEmbedSlot slot = {NOX_EMBED_ABI, 0};
    NoxHostConfig cfg;
    void *app = 0;
    void *rt = 0;
    char *root = 0;
    int64_t code = 0;
    int32_t pending = 0;
    mkdir(dir, 0700);
    memset(&cfg, 0, sizeof(cfg));
    cfg.size = sizeof(cfg);
    cfg.abi_version = NOX_EMBED_ABI;
    cfg.slot = &slot;
    cfg.documents = dir;
    cfg.support = dir;
    cfg.cache = dir;
    cfg.temp_dir = dir;
    if (nox_app_create(&cfg, &app) != 0 || app == 0) return 10;
    nox_embed_bind(app);
    if (nox_app_start(app) != 0) return 11;
    rt = nox_app_runtime(app);
    if (rt == 0) return 12;
    root = nox_str_from_cstr(rt, dir);
    if (root == 0) return 13;
    code = mobile_suite(rt, root);
    pending = nox_exception_pending(rt);
    fprintf(stderr, "suite %lld pending %d\n", (long long)code, pending);
    nox_str_release(rt, root);
    if (pending) return 20;
    if (code != 0) return (int)code;
    return 0;
}
EOF
"$clang" -c -fPIE -target aarch64-linux-android24 -I "$root/include" -o "$work/suite_host.o" "$work/suite_host.c"
"$clang" -c -fPIE -target aarch64-linux-android24 -I "$root/include" -o "$work/probe_host.o" "$root/scripts/mobile_probe_host.c"
"$clang" -fPIE -pie -target aarch64-linux-android24 -o "$work/suite" "$work/suite_host.o" "$work/suite.o" "$rt" -lm -ldl -llog
"$clang" -fPIE -pie -target aarch64-linux-android24 -o "$work/probe" "$work/probe_host.o" "$work/probe.o" "$rt" -lm -ldl -llog
"$adb" push "$work/suite" /data/local/tmp/nox-suite
"$adb" push "$work/probe" /data/local/tmp/nox-probe
"$adb" shell chmod 755 /data/local/tmp/nox-suite /data/local/tmp/nox-probe
"$adb" shell /data/local/tmp/nox-suite
"$adb" shell rm -rf /data/local/tmp/nox-mobile-probe
"$adb" shell mkdir -p /data/local/tmp/nox-mobile-probe
"$adb" shell NOX_MOBILE_ROOT=/data/local/tmp/nox-mobile-probe /data/local/tmp/nox-probe
