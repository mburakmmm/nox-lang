#!/bin/sh
# Dört mobil kütüphaneyi üretir ve kanıt yazar. İmza ortamda yoksa
# paket imzasız kalır ve stable iddiası kurulmaz.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
out="$root/mobile-evidence/out"
mkdir -p "$out"
src="$root/tests/golden/mobile_abi_answer.nox"
noxc=${NOXC:-"$root/zig-out/bin/noxc"}
"$noxc" build --target ios-arm64 --emit-static-lib -o "$out/ios-arm64.a" "$src"
"$noxc" build --target ios-simulator-arm64 --emit-static-lib -o "$out/ios-simulator-arm64.a" "$src"
if command -v xcodebuild >/dev/null 2>&1; then
  rm -rf "$out/Nox.xcframework"
  xcodebuild -create-xcframework \
    -library "$out/ios-arm64.a" -headers "$root/include" \
    -library "$out/ios-simulator-arm64.a" -headers "$root/include" \
    -output "$out/Nox.xcframework"
fi
"$noxc" build --target android-arm64 --emit-shared-lib -o "$out/libnoxapp-arm64.so" "$src"
"$noxc" build --target android-x64 --emit-shared-lib -o "$out/libnoxapp-x64.so" "$src"
python3 - "$out" << 'PY'
import pathlib, struct, sys
out = pathlib.Path(sys.argv[1])
def align(path):
    b = path.read_bytes()
    phoff = struct.unpack_from("<Q", b, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", b, 54)
    vals = []
    for i in range(phnum):
        off = phoff + phentsize * i
        if struct.unpack_from("<I", b, off)[0] == 1:
            vals.append(struct.unpack_from("<Q", b, off + 48)[0])
    return min(vals)
for name in ("libnoxapp-arm64.so", "libnoxapp-x64.so"):
    got = align(out / name)
    if got < 16384:
        sys.exit(f"{name} align {got}")
    print(f"{name} align {got}")
PY
if [ "${1:-}" = "--require-signed" ]; then
  echo "signing identity is not configured; IPA, APK and AAB stay unsigned" >&2
  exit 2
fi
echo "unsigned libraries are in mobile-evidence/out; stable remains closed"
