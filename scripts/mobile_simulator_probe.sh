#!/bin/sh
# Runs the async, thread and websocket probe on a booted iOS simulator.
# The caller passes the UDID. A live SMTP session is not opened.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
udid=${1:?booted simulator UDID}
noxc=${NOXC:-"$root/zig-out/bin/noxc"}
rt="$root/zig-out/lib/noxrt-ios-simulator-arm64.o"
if [ ! -x "$noxc" ] || [ ! -f "$rt" ]; then
  echo "noxc or the simulator runtime is missing" >&2
  exit 1
fi
work=/tmp/nox-sim-probe
rm -rf "$work"
mkdir -p "$work"
export NOX_MOBILE_ROOT=/tmp/nox-mobile-probe
export SIMCTL_CHILD_NOX_MOBILE_ROOT=/tmp/nox-mobile-probe
rm -rf "$NOX_MOBILE_ROOT"
mkdir -p "$NOX_MOBILE_ROOT"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
"$noxc" build --target ios-simulator-arm64 --emit-obj -o "$work/probe.o" "$root/tests/golden/mobile_runtime_probe.nox"
xcrun --sdk iphonesimulator clang -c -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -I "$root/include" -o "$work/host.o" "$root/scripts/mobile_probe_host.c"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -o "$work/host" \
  "$work/host.o" "$work/probe.o" "$rt" \
  -framework Security -framework Foundation -framework CFNetwork
xcrun simctl spawn "$udid" "$work/host"
