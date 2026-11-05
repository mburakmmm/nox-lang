#!/bin/bash
# Üretim makinesinde (M4) Docker disk/önbellek şişmesini önler: eski noxlang-site imaj sürümlerini, bizim imajlarımızdan kalan etiketsiz (dangling) katmanları ve eski
# derleme önbelleğini siler. `update-site.sh` her güncellemeden/geri dönüşten sonra ve günde en çok bir kez çağırır; elle `docker compose up -d --build` yaptıktan sonra da
# doğrudan çalıştırılabilir (`deploy/web/prune-docker.sh`).
#
# GÜVENLİ KAPSAM (makine başka projeleri de barındırır: rift, astro-ai ...): çalışan bir konteynerin kullandığı hiçbir imaja, volume'a ya da ağa dokunulmaz.
#   1) `ghcr.io/mburakmmm/noxlang-site` imajının `latest` ve `previous` DIŞINDaki sürüm etiketleri (2.0.163 gibi) silinir; `previous` geri dönüş noktasıdır, korunur.
#   2) Etiketsiz imajlar: yalnızca bizim etiketimizi taşıyanlar hemen, diğerleri DANGLING_MAX_AGE'den (24h) eskiyse silinir.
#   3) Derleme önbelleği BUILD_CACHE_MAX_AGE'den (48h) eskiyse silinir (yeniden derleme birkaç dakikalıktır).
# Hiçbir adım hata verirse betik durmaz (temizlik, güncellemeyi asla başarısız kılmamalıdır); çıkış kodu her zaman 0'dır.
#
# macOS'un bash 3.2'sinde çalışır.
set -u
DOCKER="${DOCKER:-docker}"
REPO="${NOXLANG_SITE_REPO:-ghcr.io/mburakmmm/noxlang-site}"
SOURCE_LABEL="${NOXLANG_SOURCE_LABEL:-https://github.com/mburakmmm/nox-lang}"
DANGLING_MAX_AGE="${DANGLING_MAX_AGE:-24h}"
BUILD_CACHE_MAX_AGE="${BUILD_CACHE_MAX_AGE:-48h}"

log() { printf '%s prune: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

removed=0
for ref in $("$DOCKER" images --format '{{.Repository}}:{{.Tag}}' "$REPO" 2>/dev/null); do
  case "${ref##*:}" in latest|previous|'<none>') continue ;; esac
  # Çalışan bir konteyner kullanıyorsa `rmi` reddeder; bu beklenen ve zararsızdır.
  if "$DOCKER" rmi "$ref" >/dev/null 2>&1; then
    log "eski imaj etiketi silindi: $ref"
    removed=$((removed + 1))
  fi
done

"$DOCKER" image prune -f --filter "label=org.opencontainers.image.source=$SOURCE_LABEL" >/dev/null 2>&1 || true
"$DOCKER" image prune -f --filter "until=$DANGLING_MAX_AGE" >/dev/null 2>&1 || true
"$DOCKER" builder prune -f --filter "until=$BUILD_CACHE_MAX_AGE" >/dev/null 2>&1 || true

cache="$("$DOCKER" system df --format '{{.Type}}={{.Size}}' 2>/dev/null | tr '\n' ' ')"
log "tamam (silinen etiket: $removed; ${cache:-boyut okunamadı})"
exit 0
