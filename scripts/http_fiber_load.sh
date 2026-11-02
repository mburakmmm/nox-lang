#!/bin/sh
# nox.http istemcisinin fiber yolunu (OS iş parçacığı açmadan) yüksek eşzamanlılıkta sınar: N eşzamanlı istek, hepsi başarılı olmalı ve tepe iş parçacığı sayısı küçük kalmalı.
#   scripts/http_fiber_load.sh [N=3000] [azami_iş_parçacığı=16]
# Çıktı: tepe iş parçacığı, tepe RSS, süre. Çıkış kodu: başarısız istek ya da iş parçacığı sınırı aşımı varsa 1.
# Not: işletim sisteminin dinleme birikimi (macOS `kern.ipc.somaxconn` = 128) çok büyük patlamalarda (≳10000) sunucu tarafında birkaç bağlantıyı reddettirir; bu Nox'un sınırı değildir.
set -u
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
n=${1:-3000}
max_threads=${2:-16}
noxc=${NOXC:-"$root/zig-out/bin/noxc"}
work=$(mktemp -d)
trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null; rm -rf "$work"' EXIT
ulimit -n 30000 2>/dev/null || true
python3 "$root/scripts/http_load_server.py" >"$work/port" &
srv=$!
i=0; while [ ! -s "$work/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
port=$(cat "$work/port")
"$noxc" build "$root/tests/stress/http_fiber_load.nox" -o "$work/load" >/dev/null || exit 1
LOAD_N=$n LOAD_URL="http://127.0.0.1:$port/" "$work/load" >"$work/out" 2>&1 &
pid=$!
mxt=0; mxr=0
thread_count() {
  if [ -d /proc/$pid/task ]; then ls /proc/$pid/task 2>/dev/null | wc -l; else ps -M "$pid" 2>/dev/null | tail -n +2 | wc -l; fi
}
while kill -0 $pid 2>/dev/null; do
  t=$(thread_count | tr -d ' '); r=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' ')
  [ -n "$t" ] && [ "$t" -gt "$mxt" ] && mxt=$t
  [ -n "$r" ] && [ "$r" -gt "$mxr" ] && mxr=$r
  sleep 0.1
done
wait $pid
line=$(tail -1 "$work/out")
echo "N=$n tepe iş parçacığı=$mxt tepe RSS=$((mxr / 1024)) MB :: $line"
case "$line" in "N $n ok $n timeouts 0 errors 0 bad 0 "*) ;; *) echo "FAIL: tüm istekler başarılı olmalıydı"; exit 1 ;; esac
[ "$mxt" -le "$max_threads" ] || { echo "FAIL: tepe iş parçacığı $mxt > $max_threads"; exit 1; }
