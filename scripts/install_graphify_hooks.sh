#!/bin/sh
# İSTEĞE BAĞLI (kullanıcı çalıştırır): kod grafını commit/birleştirme/dal değişimi/yeniden yazımdan SONRA otomatik yeniler
# (post-commit, post-merge, post-checkout, post-rewrite). Kurulum yereldir (`.git/hooks`, tüm worktree'lerde ortak) ve idempotenttir;
# mevcut bir hook'u silmez, sonuna ekler. Kaldırmak için ilgili hook dosyalarından "graphify_refresh.sh" satırını silin.
# Not: graphify'ın KENDİ git hook'unu (graphify hook install) KULLANMAYIN — Nox ek çıkarımını (scripts/graphify_build.py) bilmez ve siler.
set -e
hooks=$(git rev-parse --git-common-dir)/hooks
mkdir -p "$hooks"
for h in post-commit post-merge post-checkout post-rewrite; do
  f="$hooks/$h"
  [ -f "$f" ] || printf '#!/bin/sh\n' > "$f"
  grep -q "graphify_refresh.sh" "$f" || printf '\n# graphify kod grafı (scripts/install_graphify_hooks.sh)\n"$(git rev-parse --show-toplevel)/scripts/graphify_refresh.sh" >/dev/null 2>&1 || true\n' >> "$f"
  chmod +x "$f"
  echo "kuruldu: $f"
done
