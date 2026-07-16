#!/bin/sh
# run_compare.sh — builds and benchmarks the Nox/Go/Zig/FastAPI HTTP
# servers in benchmarks/http_compare/ with `wrk`, one at a time (all four
# bind to the same port 8801). Each server returns the identical response
# shape: HTTP 200, header "x: x", body "ok" (2 bytes) — see
# benchmarks/RESULTS.md for the methodology notes and results table.
#
# Usage: sh benchmarks/http_compare/run_compare.sh
# Requires: noxc (zig-out/bin/noxc, already built), go, zig, python3 with
# fastapi+uvicorn installed, and `wrk` on PATH.

set -e
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

WRK_ARGS="-t8 -c100 -d15s --latency"
PORT=8801
URL="http://127.0.0.1:${PORT}/"

echo "=== building servers ==="
"$ROOT/zig-out/bin/noxc" build nox_server.nox -o /tmp/http_compare_nox 2>&1
zig build-exe zig_server.zig -O ReleaseFast -femit-bin=/tmp/http_compare_zig 2>&1
go build -o /tmp/http_compare_go go_server.go 2>&1
echo "built."

# $1 = short name for logging, $2 = specific pkill -f pattern for cleanup
# (NEVER a bare interpreter name like "python3" — must uniquely match only
# this benchmark's process), remaining args = the command to run.
run_one() {
    name="$1"
    kill_pattern="$2"
    shift 2
    echo ""
    echo "=== $name ==="
    "$@" >/tmp/http_compare_${name}.log 2>&1 &
    pid=$!
    sleep 1.5
    if ! curl -s -o /dev/null -w "%{http_code}" "$URL" | grep -q 200; then
        echo "FAILED to get a 200 from $name — see /tmp/http_compare_${name}.log"
        kill -9 "$pid" 2>/dev/null || true
        pkill -9 -f "$kill_pattern" 2>/dev/null || true
        return 1
    fi
    wrk $WRK_ARGS "$URL" | tee "/tmp/http_compare_${name}_wrk.txt"
    kill -9 "$pid" 2>/dev/null || true
    pkill -9 -f "$kill_pattern" 2>/dev/null || true
    sleep 1
}

run_one nox /tmp/http_compare_nox /tmp/http_compare_nox
run_one zig /tmp/http_compare_zig /tmp/http_compare_zig
run_one go /tmp/http_compare_go /tmp/http_compare_go
run_one fastapi "uvicorn fastapi_server:app" python3 -m uvicorn fastapi_server:app --host 0.0.0.0 --port "$PORT" --workers 10

echo ""
echo "=== done — raw wrk output in /tmp/http_compare_*_wrk.txt ==="
