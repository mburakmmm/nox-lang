#!/bin/sh
# run_ping_worker_sweep.sh — 2.3 madde 5.1: Nox `serve_multicore` ping işlevinin 1/2/4/8 işçide ölçeği, AYNI wrk şekliyle ÇOK İŞ PARÇACIKLI C (epoll + SO_REUSEPORT) ve Go ile karşılaştırılır.
# Linux'ta (WSL dahil) çalışır: SO_REUSEPORT çekirdek-düzeyi dağıtımı Linux'a özgüdür (macOS/Windows'ta Nox tek paylaşılan dinleme soketi kullanır).
# Önkoşul: noxc (ReleaseFast: `zig build -Doptimize=ReleaseFast`), clang (`--release` için), cc, wrk, isteğe bağlı go. Kullanım: sh benchmarks/http_compare/run_ping_worker_sweep.sh [WORKER_SAYILARI="1 2 4 8"] [WRK_ARGS]
set -e
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
COUNTS="${1:-1 2 4 8}"
WRK_ARGS="${2:--t4 -c64 -d10s}"
OUT=/tmp/ping_sweep
mkdir -p "$OUT"
cc -O2 -pthread c_server.c -o "$OUT/c_server"
HAVE_GO=0
if command -v go >/dev/null 2>&1; then go build -o "$OUT/go_server" go_ping_server.go && HAVE_GO=1; fi
for n in $COUNTS; do
    sed "s/__N_WORKERS__/${n}/" nox_ping_server.nox > "$OUT/nox_ping_${n}w.nox"
    "$ROOT/zig-out/bin/noxc" build --release "$OUT/nox_ping_${n}w.nox" -o "$OUT/nox_ping_${n}w" >/dev/null 2>&1
done
echo "workers | nox rps | C rps | Go rps  (wrk $WRK_ARGS)"
for n in $COUNTS; do
    row="$n"
    for kind in nox c go; do
        case $kind in
            nox) cmd="$OUT/nox_ping_${n}w"; port=8804; env_pre="NOX_POOL_WORKERS=$n" ;;
            c)   cmd="$OUT/c_server 8805 $n"; port=8805; env_pre="" ;;
            go)  if [ $HAVE_GO = 0 ]; then row="$row | -"; continue; fi; cmd="$OUT/go_server 8806 $n"; port=8806; env_pre="" ;;
        esac
        env $env_pre $cmd >/dev/null 2>&1 &
        pid=$!
        sleep 1.5
        rps=$(wrk $WRK_ARGS "http://127.0.0.1:$port/" 2>&1 | awk '/Requests\/sec/ {print $2}')
        kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
        row="$row | ${rps:-FAIL}"
        sleep 0.5
    done
    echo "$row"
done
