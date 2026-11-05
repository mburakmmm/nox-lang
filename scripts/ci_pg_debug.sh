#!/usr/bin/env bash
# GEÇİCİ teşhis betiği (.github/workflows/pg-debug.yml): GitHub runner'ında nox.postgres WASM testinin neden "memory access out of bounds" ile düştüğünü
# daraltmak için aynı programı farklı koşullarda çalıştırır ve sunucudan gelen baytları kaydeder. Kök neden bulununca silinir.
set -uo pipefail
export PATH="$PWD/zig-out/bin:$PATH"
PGB="${PGB:-$(ls -d /usr/lib/postgresql/*/bin | head -1)}"
work="$(mktemp -d /tmp/nox-pgdbg-XXXXXX)"
port=15432
echo "== ortam"; uname -a; node --version; wasm-opt --version; "$PGB/pg_ctl" --version; nproc; free -m | head -2; ulimit -a | grep -E "virtual|max memory|open files" || true
sed "s/__PORT__/$port/g" tests/golden/wasm_pg_program.nox.in > "$work/prog.nox"
NOX_WASM_NAMES=1 noxc build --target wasm32-freestanding-asyncify "$work/prog.nox" -o "$work/prog.wasm" 2>&1 | tail -1
echo "wasm: $(wc -c < "$work/prog.wasm") bayt"

start_pg() {  # $1 = ek sunucu seçenekleri
  rm -rf "$work/data"; echo secret > "$work/pw"
  LC_ALL=C "$PGB/initdb" -D "$work/data" -U postgres --auth=scram-sha-256 --pwfile "$work/pw" -E UTF8 --locale=C >/dev/null 2>&1
  LC_ALL=C "$PGB/pg_ctl" -D "$work/data" -o "-p $((port + 1)) -k $work -c listen_addresses=127.0.0.1 -c fsync=off $1" -l "$work/log" -w start >/dev/null 2>&1
}
stop_pg() { LC_ALL=C "$PGB/pg_ctl" -D "$work/data" -m immediate -w stop >/dev/null 2>&1; }

cat > "$work/sniff.mjs" <<'JS'
import net from 'node:net';
const [,, lp, tp, out] = process.argv;
import fs from 'node:fs';
const log = [];
net.createServer((c) => {
  const s = net.connect(Number(tp), '127.0.0.1');
  c.on('data', (d) => { log.push(`C->S ${d.length}`); s.write(d); });
  s.on('data', (d) => { log.push(`S->C ${d.length} ${JSON.stringify(d.toString('latin1').replace(/[^\x20-\x7e]/g, '.').slice(0, 160))}`); c.write(d); fs.writeFileSync(out, log.join('\n')); });
  c.on('close', () => s.destroy()); s.on('close', () => c.destroy()); c.on('error', () => {}); s.on('error', () => {});
}).listen(Number(lp), '127.0.0.1');
JS

run_case() {  # $1 ad, $2 sunucu seçenekleri, $3 node bayrakları
  start_pg "$2"
  node "$work/sniff.mjs" "$port" $((port + 1)) "$work/sniff.txt" & local sp=$!
  sleep 1
  local res; res="$(node --no-warnings $3 compiler/wasm_host.mjs "$work/prog.wasm" --allow-net 2>&1 | head -12 | tr '\n' '|')"
  echo "== [$1] ${res:0:420}"
  kill $sp 2>/dev/null; stop_pg
  [ -f "$work/sniff.txt" ] && { head -14 "$work/sniff.txt" | cut -c1-200 | sed 's/^/     /'; rm -f "$work/sniff.txt"; }
}
run_case varsayilan ""  ""
run_case varsayilan-2 "" ""
run_case liftoff-only "" "--liftoff-only"
run_case no-liftoff "" "--no-liftoff"
run_case tz-utc "-c timezone=Etc/UTC" ""
run_case scram-iter-1000 "-c scram_iterations=1000" ""

echo "== proxy'siz doğrudan (sürücü ile aynı düzen): PG 15432'de"
start_pg_direct() { rm -rf "$work/data"; echo secret > "$work/pw"; LC_ALL=C "$PGB/initdb" -D "$work/data" -U postgres --auth=scram-sha-256 --pwfile "$work/pw" -E UTF8 --locale=C >/dev/null 2>&1; LC_ALL=C "$PGB/pg_ctl" -D "$work/data" -o "-p $port -k $work -c listen_addresses=127.0.0.1 -c fsync=off" -l "$work/log" -w start >/dev/null 2>&1; }
for i in 1 2 3; do
  start_pg_direct
  res="$(node --no-warnings compiler/wasm_host.mjs "$work/prog.wasm" --allow-net 2>&1 | head -6 | tr '\n' '|')"
  echo "== [dogrudan-$i] ${res:0:300}"
  LC_ALL=C "$PGB/pg_ctl" -D "$work/data" -m immediate -w stop >/dev/null 2>&1
done
echo "== gerçek sürücü (tests/golden/wasm_pg_driver.mjs) 3 kez"
for i in 1 2 3; do
  res="$(node tests/golden/wasm_pg_driver.mjs "$PWD/zig-out/bin/noxc" tests/golden/wasm_pg_program.nox.in compiler/wasm_host.mjs 2>&1 | head -12 | tr '\n' '|')"
  echo "== [surucu-$i] ${res:0:400}"
done
echo "== zig build wasm-test (Zig test düzeneği, özet)"
zig build wasm-test 2>&1 | grep -E "error: '|surucu stderr|RuntimeError|BrkAllocator|passed|failed" | head -12
rm -rf "$work"
