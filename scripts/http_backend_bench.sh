#!/bin/sh
# Referans backend'in (examples/todo-backend) `wrk` ile yük ölçümü: /health, kimlik doğrulamalı JWT+SQLite listesi, yazma.
#   NOXC=<ReleaseFast kurulumunun noxc'si> scripts/http_backend_bench.sh [backend=llvm] [saniye=6]
# ÖNEMLİ: ölçümü `zig build -Doptimize=ReleaseFast --prefix /tmp/nox-rel` ile kurulan noxc ile yapın (NOXC=/tmp/nox-rel/bin/noxc). Düz `zig build` Debug çalışma zamanı üretir:
# DebugAllocator her tahsiste yığın izi yakalar ve sonuçlar ~100 kat düşük çıkar (istek başına ~0,5 ms).
set -u
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
noxc=${NOXC:-"$root/zig-out/bin/noxc"}
backend=${1:-llvm}
secs=${2:-6}
command -v wrk >/dev/null 2>&1 || { echo "wrk gerekli (brew install wrk)"; exit 1; }
work=$(mktemp -d)
trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null; rm -rf "$work"' EXIT
ulimit -n 30000 2>/dev/null || true
"$noxc" build "$root/examples/todo-backend/app.nox" --backend "$backend" -o "$work/app" >/dev/null || exit 1
port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
B=http://127.0.0.1:$port
PORT=$port TODO_DB="$work/bench.db" RATE_LIMIT=100000000 "$work/app" >/dev/null 2>&1 &
srv=$!
i=0; while ! curl -s "$B/health" >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
curl -s -X POST "$B/register" -d '{"user":"bench","password":"benchbench123"}' >/dev/null
T=$(curl -s -X POST "$B/login" -d '{"user":"bench","password":"benchbench123"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
i=0; while [ $i -lt 20 ]; do curl -s -X POST "$B/todos" -H "Authorization: Bearer $T" -d "{\"title\":\"item $i\"}" >/dev/null; i=$((i + 1)); done
cat >"$work/post.lua" <<'LUA'
wrk.method = "POST"
wrk.body = '{"title":"bench"}'
LUA
echo "backend=$backend wrk -t4, ${secs}s"
echo "--- GET /health (-c64)"; wrk -t4 -c64 -d${secs}s "$B/health" | grep -E "Requests/sec|Latency|Socket|Non-2xx"
echo "--- GET /todos (JWT + SQLite, 20 satır, -c64)"; wrk -t4 -c64 -d${secs}s -H "Authorization: Bearer $T" "$B/todos" | grep -E "Requests/sec|Latency|Socket|Non-2xx"
echo "--- POST /todos (yazma, -c32)"; wrk -t4 -c32 -d${secs}s -s "$work/post.lua" -H "Authorization: Bearer $T" "$B/todos" | grep -E "Requests/sec|Latency|Socket|Non-2xx"
