#!/bin/sh
# run_json_worker_sweep.sh — Faz MN.10 regression gate. Builds
# nox_json_server.nox (nox.json.decode/encode echo handler, ~30-50 tiny
# ARC allocations per request) at several `serve_multicore` worker counts
# and benchmarks each with `wrk`, to prove the shared M:N pool's ARC
# small-object allocator (`RuntimeState.pool_free_lists`) scales with
# worker count instead of regressing.
#
# **Before Faz MN.10** (single global `pool_free_lists_lock` shared by all
# workers) this workload showed a measured INVERSION: 8 workers ran SLOWER
# than 1 worker (~89k req/s vs ~101k req/s on the machine this was
# authored on) — more parallelism made the lock-contended allocator worse,
# not better. **After Faz MN.10** (per-worker-slot, lock-free free lists,
# mirroring `RuntimeState.globals_blocks`'s already-proven design) 8
# workers correctly beats 1 worker (~147k req/s vs ~103k req/s, same
# machine) — this script's PASS/FAIL banner is exactly that CATASTROPHIC
# inversion (8w well under 1w, e.g. the ~88% ratio above), checked
# automatically.
#
# **2026-08 (bkz. plan dosyası "setNonBlocking'in her okuma/yazmada
# gereksiz tekrarını gidermek"):** `io.zig`nin HER read/write/accept
# çağrısında GEREKSİZ tekrarladığı `setNonBlocking` (2 gerçek `fcntl`
# syscall'ı) düzeltildikten SONRA 1/2/4-worker sayıları BİRDEN ~150-160k'dan
# ~208k'ye SIÇRADI (ÖNCEDEN sözde-worker-sayısı-ile-YAVAŞLAMA anomalisinin
# ASIL nedeni BUYMUŞ — pool_free_lists DEĞİL) — 8-worker İSE (BU makinede
# 10 çekirdek, wrk'nin KENDİ 4 istemci iş parçacığıYLA BİRLİKTE 12
# eşzamanlı iş parçacığı = çekirdek-oversubscription) ~201k'de SABİT
# KALDI, DEĞİŞMEDİ — 8w ARTIK 1w'yi %3-4 kadar AZ, AMA yakın bir MARJLA
# (katastrofik %12 inversiyonun TERSİNE) geride bırakıyor, ÇÜNKÜ 1-4w
# ARTIK 8w İLE AYNI donanım tavanına YAKLAŞTI. Bu YÜZDEN eşik AŞAĞIDA
# "8w >= 1w" (strict) YERİNE "8w >= %90 × 1w"e GEVŞETİLDİ — ESKİ
# katastrofik inversiyonu (bkz. YUKARIDAKİ ~88% oran) HÂLÂ yakalar, AMA
# BU yeni, BENİGN "her ikisi de AYNI donanım tavanına YAKIN" durumunu
# YANLIŞ pozitif OLARAK işaretlemez.
#
# Usage: sh benchmarks/http_compare/run_json_worker_sweep.sh
# Requires: noxc built with a ReleaseFast noxrt.o (`zig build
# -Doptimize=ReleaseFast` — a plain `zig build` defaults to Debug, which
# links a DebugAllocator-backed noxrt.o and makes every number in this
# script meaningless; see git history for how this was discovered), clang
# on PATH (`--release` requirement), and `wrk` on PATH.

set -e
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

WRK_ARGS="-t4 -c50 -d10s"
PORT=8803
URL="http://127.0.0.1:${PORT}/"
WORKER_COUNTS="1 2 4 8"

echo "=== building nox_json_server.nox for each worker count ==="
for n in $WORKER_COUNTS; do
    sed "s/__N_WORKERS__/${n}/" nox_json_server.nox > "/tmp/nox_json_server_${n}w.nox"
    "$ROOT/zig-out/bin/noxc" build --release "/tmp/nox_json_server_${n}w.nox" -o "/tmp/nox_json_server_${n}w" 2>&1
done
echo "built."

RESULTS_FILE=/tmp/nox_json_worker_sweep_results.txt
: > "$RESULTS_FILE"

for n in $WORKER_COUNTS; do
    echo ""
    echo "=== ${n} worker(s) ==="
    "/tmp/nox_json_server_${n}w" >"/tmp/nox_json_server_${n}w.log" 2>&1 &
    pid=$!
    sleep 1.5
    if ! curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
        -d '{"name":"nox","value":42,"tags":["a","b","c"],"nested":{"x":1,"y":2}}' "$URL" | grep -q 200; then
        echo "FAILED to get a 200 from ${n}-worker server — see /tmp/nox_json_server_${n}w.log"
        kill -9 "$pid" 2>/dev/null || true
        exit 1
    fi
    reqs=$(wrk $WRK_ARGS -s json_post.lua "$URL" | tee "/tmp/nox_json_server_${n}w_wrk.txt" | grep "Requests/sec" | awk '{print $2}')
    echo "${n} ${reqs}" >> "$RESULTS_FILE"
    kill -9 "$pid" 2>/dev/null || true
    sleep 1
done

echo ""
echo "=== summary (req/sec by worker count) ==="
cat "$RESULTS_FILE"

one_worker=$(awk '$1 == 1 {print $2}' "$RESULTS_FILE")
eight_worker=$(awk '$1 == 8 {print $2}' "$RESULTS_FILE")

echo ""
if awk -v a="$eight_worker" -v b="$one_worker" 'BEGIN { exit !(a >= 0.90 * b) }'; then
    echo "PASS: 8-worker throughput (${eight_worker} req/s) is within 10% of 1-worker (${one_worker} req/s) — no catastrophic MN.10-style lock-contention inversion (bkz. 2026-08 notu, artık ikisi de aynı donanım tavanına yakın)."
    exit 0
else
    echo "FAIL: 8-worker throughput (${eight_worker} req/s) is catastrophically below 1-worker (${one_worker} req/s) — the Faz MN.10 inversion regressed."
    exit 1
fi
