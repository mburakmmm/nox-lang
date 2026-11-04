#!/bin/bash
# Gereken varlıkların TAMAMINI içeren en yeni kararlı release etiketini yazar.
# "En son sürüm" bir release hâlâ yayımlanırken (varlıklar tek tek yüklenir) eksik olabilir; sürüm kesmeden paket denemeleri bu yüzden kararsız olurdu.
# Kullanım: GH_TOKEN=... scripts/latest_release_with.sh <varlık-soneki>...    ör.  ... linux-x64.tar.gz linux-arm64.tar.gz
set -euo pipefail
REPO="${REPO:-mburakmmm/nox-lang}"
for tag in $(gh release list --repo "$REPO" --exclude-pre-releases --limit 10 --json tagName --jq '.[].tagName'); do
  assets="$(gh release view "$tag" --repo "$REPO" --json assets --jq '.assets[].name')"
  ok=1
  for suffix in "$@"; do
    echo "$assets" | grep -q -- "${suffix}\$" || { ok=0; break; }
  done
  if [ "$ok" = 1 ]; then echo "$tag"; exit 0; fi
done
echo "gereken varlıkları içeren kararlı release bulunamadı: $*" >&2
exit 1
