#!/bin/sh
# Kod grafını (graphify-out/) yeniler (~15 sn). Elle, `scripts/precheck.sh` içinden (her commit öncesi) ve isteğe bağlı git hook'larından (scripts/install_graphify_hooks.sh) kullanılır.
# Tek seferde tek yenileme: `graphify-out/.build.lock` dizini (atomik mkdir). graphify yoksa sessizce çıkar (commit/precheck'i asla bozmaz).
# Varsayılan: arka planda çalışır. `--wait`: bitene dek bekler ve özet satırını basar (ajan, analizden hemen önce kodu değiştirdiyse bunu kullanır).
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" || exit 0
bin=$(command -v graphify) || bin="$HOME/.local/bin/graphify"
[ -x "$bin" ] || exit 0
py=$(head -1 "$bin" | sed 's/^#!//')
[ -x "$py" ] || exit 0
mkdir -p graphify-out
if ! mkdir graphify-out/.build.lock 2>/dev/null; then
  # çökmüş bir yenilemeden kalan eski kilidi (10 dakikadan eski) temizle
  [ -n "$(find graphify-out/.build.lock -maxdepth 0 -mmin +10 2>/dev/null)" ] && rmdir graphify-out/.build.lock 2>/dev/null
  exit 0
fi
run() {
  "$py" scripts/graphify_build.py --force >graphify-out/build.log 2>&1
  rmdir graphify-out/.build.lock 2>/dev/null
}
if [ "${1:-}" = "--wait" ]; then
  run
  grep "^graf" graphify-out/build.log | tail -1
else
  (run &) >/dev/null 2>&1
fi
exit 0
