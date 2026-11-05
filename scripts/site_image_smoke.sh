#!/usr/bin/env bash
# noxlang-site imajının duman testi: konteyneri üretim ayarlarıyla (NYX_ENV=production, sıkı CSP, salt okunur kök) başlatır ve
# sitenin temel sözleşmesini doğrular. `release.yml`in `site-image` işi imajı YALNIZCA bu test geçerse GHCR'ye iter;
# yerelde `scripts/site_image_smoke.sh noxlang-site:test` ile de çalıştırılır.
#
# Kontroller: /healthz; ana sayfa ve /download/ 200; ana sayfanın CSP'si sıkı ('wasm-unsafe-eval' YOK); /playground/ 200 ve CSP'si
# 'wasm-unsafe-eval' içerir; Playground varlıkları (WASM ön yüz, çalışma zamanı nesnesi) sunulur ve doğru türdedir; /api/release
# JSON ya da 502 (GitHub'a ulaşılamayan CI) döner; /version.txt imajın etiketiyle uyumludur.
set -euo pipefail

image="${1:?kullanım: site_image_smoke.sh <imaj> [beklenen-sürüm, örn. 2.0.163]}"
expect_version="${2:-}"
name="nox-site-smoke-$$"

# Bu test imajı derleyen makinenin KENDİ CPU'sunda koşar; "native CPU'ya bağımlı ikili" hatasını (başka CPU'da SIGILL, v2.0.171) burada yakalayamaz. Bu yüzden Dockerfile'ın
# `zig build`inin sabit bir `-Dcpu=` taşıdığı statik olarak doğrulanır.
dockerfile="$(cd "$(dirname "$0")/.." && pwd)/services/noxlang-site/Dockerfile"
if ! grep -E '^\s*&&\s+zig build -Doptimize=ReleaseFast .*-Dcpu=|^RUN .*zig build -Doptimize=ReleaseFast .*-Dcpu=' "$dockerfile" >/dev/null; then
  echo "FAIL: $dockerfile içindeki 'zig build -Doptimize=ReleaseFast' -Dcpu= taşımıyor (imaj derleyici makinenin CPU'suna bağlı kalır, başka CPU'da SIGILL)"
  exit 1
fi
port="${SMOKE_PORT:-18199}"

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$name" --read-only --tmpfs /tmp -p "127.0.0.1:${port}:8080" \
  -e NYX_ENV=production -e NYX_SECRET_KEY=smoke-test-secret-key-0123456789abcdef -e NYX_PORT=8080 \
  -e NYX_DB_PATH=:memory: -e NYX_JOBS_DB_PATH=:memory: -e NYX_AUTO_MIGRATE=false -e NYX_SESSION=false -e NYX_CSRF=false \
  -e NYX_CSP="default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; font-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'" \
  "$image" >/dev/null

base="http://127.0.0.1:${port}"
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "$base/healthz" 2>/dev/null; then break; fi
  sleep 1
done
curl -fsS -o /dev/null "$base/healthz" || { echo "FAIL: /healthz yanıt vermedi"; docker logs "$name" | tail -20; exit 1; }

fail=0
check() { if [ "$2" = "ok" ]; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
status() { curl -s -o /dev/null -w '%{http_code}' "$1"; }
header() { curl -sI "$1" | tr -d '\r' | grep -i "^$2:" | head -1 | cut -d: -f2- || true; }

[ "$(status "$base/")" = 200 ] && check "ana sayfa 200" ok || check "ana sayfa 200" no
[ "$(status "$base/download/")" = 200 ] && check "/download/ 200" ok || check "/download/ 200" no
[ "$(status "$base/docs/tutorial/")" = 200 ] && check "/docs/tutorial/ 200" ok || check "/docs/tutorial/ 200" no
[ "$(status "$base/nope-$$")" = 404 ] && check "bilinmeyen yol 404" ok || check "bilinmeyen yol 404" no

root_csp="$(header "$base/" Content-Security-Policy)"
case "$root_csp" in *"wasm-unsafe-eval"*|*cdn.jsdelivr.net*) check "ana sayfa CSP'si sıkı" no ;; *"default-src 'self'"*) check "ana sayfa CSP'si sıkı" ok ;; *) check "ana sayfa CSP'si sıkı" no ;; esac

[ "$(status "$base/playground/")" = 200 ] && check "/playground/ 200" ok || check "/playground/ 200" no
play_csp="$(header "$base/playground/" Content-Security-Policy)"
case "$play_csp" in *"'wasm-unsafe-eval'"*) check "Playground CSP'si WebAssembly'ye izin verir" ok ;; *) check "Playground CSP'si WebAssembly'ye izin verir" no ;; esac

for f in noxc-frontend.wasm noxrt-wasm32-freestanding.o noxrt-wasm32-freestanding-sqlite3.o compiler-rt-wasm32.a; do
  [ "$(status "$base/playground/lib/$f")" = 200 ] && check "Playground varlığı $f" ok || check "Playground varlığı $f" no
done
for f in play.js compile-worker.js run-worker.js wasm_compiler.mjs wasm_host.mjs examples.json; do
  [ "$(status "$base/playground/$f")" = 200 ] && check "Playground dosyası $f" ok || check "Playground dosyası $f" no
done
wasm_type="$(header "$base/playground/lib/noxc-frontend.wasm" Content-Type)"
case "$wasm_type" in *application/wasm*) check "WASM içerik türü" ok ;; *) check "WASM içerik türü ($wasm_type)" no ;; esac
# `|| true`: `head` borudan erken çıkınca curl SIGPIPE alır ve `pipefail` boru hattını başarısız sayar.
magic="$(curl -s "$base/playground/lib/noxc-frontend.wasm" | head -c 4 | od -An -tx1 | tr -d ' \n' || true)"
[ "$magic" = "0061736d" ] && check "WASM sihirli sayı" ok || check "WASM sihirli sayı ($magic)" no

api_status="$(status "$base/api/release")"
case "$api_status" in 200|502) check "/api/release ($api_status)" ok ;; *) check "/api/release ($api_status)" no ;; esac

# /version.txt: sitenin derlendiği Nox sürümü (scripts/build_site.py yazar). Yayımlanan imajın etiketlenen sürümden olduğunu doğrular;
# böylece eski bir imaj yanlışlıkla `latest` yapılamaz.
served_version="$(curl -s "$base/version.txt" | tr -d '[:space:]')"
if [ -n "$expect_version" ]; then
  [ "$served_version" = "$expect_version" ] && check "/version.txt = $expect_version" ok || check "/version.txt ($served_version != $expect_version)" no
else
  [ -n "$served_version" ] && check "/version.txt ($served_version)" ok || check "/version.txt" no
fi
curl -s "$base/playground/examples.json" | grep -q '"id": "hello"' && check "Playground örnekleri" ok || check "Playground örnekleri" no

[ "$fail" = 0 ] || { echo "duman testi BAŞARISIZ"; docker logs "$name" | tail -20; exit 1; }
echo "duman testi temiz"
