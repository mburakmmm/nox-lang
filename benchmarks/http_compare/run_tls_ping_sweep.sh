#!/bin/sh
# run_tls_ping_sweep.sh — 2.3 madde 5.1: TLS (HTTP/1.1 keep-alive, wrk) ve HTTP/2 (h2load) sıcak yolu: Nox `serve_multicore_tls` ile Go `net/http` TLS, 1/4 işçide.
# Önkoşul: Linux, noxc (ReleaseFast), clang, wrk, h2load (nghttp2-client), openssl, go. Kullanım: sh benchmarks/http_compare/run_tls_ping_sweep.sh [WORKER_SAYILARI="1 4"]
set -e
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
COUNTS="${1:-1 4}"
OUT=/tmp/ping_sweep
mkdir -p "$OUT"
[ -f "$OUT/cert.pem" ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -days 2 -subj /CN=localhost >/dev/null 2>&1
go build -o "$OUT/go_tls_server" go_tls_ping_server.go
for n in $COUNTS; do
    sed "s/__N_WORKERS__/${n}/" nox_tls_ping_server.nox > "$OUT/nox_tls_${n}w.nox"
    "$ROOT/zig-out/bin/noxc" build --release "$OUT/nox_tls_${n}w.nox" -o "$OUT/nox_tls_${n}w" >/dev/null 2>&1
done
echo "workers | proto | nox | go"
for n in $COUNTS; do
    for proto in h1 h2; do
        row="$n | $proto"
        for kind in nox go; do
            if [ $kind = nox ]; then NOX_POOL_WORKERS=$n "$OUT/nox_tls_${n}w" >/dev/null 2>&1 & port=8807; else "$OUT/go_tls_server" 8808 $n "$OUT/cert.pem" "$OUT/key.pem" >/dev/null 2>&1 & port=8808; fi
            pid=$!
            sleep 2
            if [ $proto = h1 ]; then
                v=$(wrk -t4 -c64 -d8s "https://127.0.0.1:$port/" 2>&1 | awk '/Requests\/sec/ {print $2}')
            else
                v=$(h2load -n 120000 -c 64 -m 10 -t 4 "https://127.0.0.1:$port/" 2>&1 | awk '/finished in/ {for(i=1;i<=NF;i++) if ($i=="req/s,") print $(i-1)}')
            fi
            kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
            row="$row | ${v:-FAIL}"
            sleep 0.5
        done
        echo "$row"
    done
done
