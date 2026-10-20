#!/bin/sh
# Selects an available iPhone simulator, boots it when none is booted,
# and runs the stdlib suite on that simulator.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
udid=$(python3 - << 'PY'
import json, subprocess, sys
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
data = json.loads(raw)
booted = []
available = []
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable"):
            continue
        if not device.get("name", "").startswith("iPhone"):
            continue
        if device.get("state") == "Booted":
            booted.append(device["udid"])
        else:
            available.append(device["udid"])
if booted:
    print(booted[0])
elif available:
    print(available[0])
else:
    sys.exit("no available iPhone simulator")
PY
)
state=$(xcrun simctl list devices "$udid" | awk -v id="$udid" '$0 ~ id {print}')
case "$state" in
  *Booted*) ;;
  *) xcrun simctl boot "$udid" ;;
esac
xcrun simctl bootstatus "$udid" -b
"$root/scripts/mobile_simulator_suite.sh" "$udid"
