#!/bin/bash
# Derlenmiş snap'i (classic) kurar, çalıştırır ve kaldırır. Kullanım: test-snap.sh <dosya.snap> <vX.Y.Z>
set -euo pipefail
SNAPFILE="${1:?snap dosyası gerekli}"
VER="${2:?sürüm etiketi gerekli}"
VER="${VER#v}"

sudo snap install --dangerous --classic "$SNAPFILE"
noxc version 2>&1 | tee /dev/stderr | grep -q "noxc $VER"
command -v noxc.noxlsp >/dev/null || command -v noxlsp >/dev/null || snap info noxc | grep -q noxlsp
test -x /snap/noxc/current/bin/noxlsp
test -x /snap/noxc/current/bin/qbe
printf 'print(6 * 7)\n' > /tmp/hello.nox
test "$(noxc run /tmp/hello.nox)" = "42"
test "$(noxc run --backend qbe /tmp/hello.nox)" = "42"

# `noxc upgrade` koruması 2.0.140'tan itibaren vardır; daha eski bir release üzerinde atlanır.
if [ "$(printf '%s\n' 2.0.140 "$VER" | sort -V | head -n1)" = "2.0.140" ]; then
  if noxc upgrade v99.0.0 2> /tmp/upgrade.err; then echo "upgrade başarılı olmamalıydı"; exit 1; fi
  grep -q "installed by snap" /tmp/upgrade.err
  grep -q "snap refresh noxc" /tmp/upgrade.err
else
  echo "== noxc upgrade koruması atlandı ($VER < 2.0.140)"
fi

sudo snap remove noxc
test ! -e /snap/noxc
echo "snap testi: temiz"
