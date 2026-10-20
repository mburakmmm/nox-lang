#!/bin/sh
# Boots nothing by itself. The caller passes a booted simulator UDID.
# Runs the stdlib suite, including the verified TLS handshake, and fails
# unless the host prints a zero result with no pending exception.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
udid=${1:?booted simulator UDID}
noxc=${NOXC:-"$root/zig-out/bin/noxc"}
rt="$root/zig-out/lib/noxrt-ios-simulator-arm64.o"
if [ ! -x "$noxc" ] || [ ! -f "$rt" ]; then
  echo "noxc or the simulator runtime is missing" >&2
  exit 1
fi
work=/tmp/nox-sim-suite
rm -rf "$work"
mkdir -p "$work"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
"$noxc" build --target ios-simulator-arm64 --emit-obj -o "$work/suite.o" "$root/tests/golden/mobile_stdlib_suite.nox"
cat > "$work/host.c" << 'EOF'
#include "nox_embed.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
extern int64_t mobile_suite(void *rt, char *root);
int main(void) {
    const char *dir = "/tmp/nox-suite-root";
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
xcrun --sdk iphonesimulator clang -c -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -I "$root/include" -o "$work/host.o" "$work/host.c"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -o "$work/host" \
  "$work/host.o" "$work/suite.o" "$rt" \
  -framework Security -framework Foundation -framework CFNetwork
xcrun simctl spawn "$udid" "$work/host"
