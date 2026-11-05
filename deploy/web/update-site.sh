#!/bin/bash
# noxlang.com imajını otomatik günceller (pull tabanlı sürekli dağıtım). Üretim makinesinde (M4) bir zamanlayıcıyla çalışır
# (`com.noxlang.site-update.plist`, 15 dakikada bir). `release.yml`in `site-image` işi her kararlı sürümde, duman testinden geçmiş imajı
# GHCR'ye iter; bu betik yeni bir imaj varsa çeker, siteyi onunla yeniden başlatır, sağlıklı olmasını bekler ve olmazsa ÖNCEKİ imaja döner.
#
# Güvenlik: makineye dışarıdan erişim gerekmez (yalnızca GHCR'den çekme), gizli anahtar yoktur (paket GENEL olmalıdır).
# Yalnızca `noxlang-site` servisine dokunur; noxpkg, kayıt verisi ve diğer servisler etkilenmez.
# Güvenli tekrar: eşzamanlı çalışma kilitle engellenir, güncel ise hiçbir şey yapmaz, çekme başarısızsa site olduğu gibi kalır.
#
#   deploy/web/update-site.sh            # güncelle
#   deploy/web/update-site.sh --check    # yalnızca yeni imaj var mı bak, hiçbir şeyi değiştirme (çıkış 0: güncel, 10: güncelleme var)
#
# macOS'un bash 3.2'sinde çalışır (bash 4 özellikleri kullanılmaz).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER="${DOCKER:-docker}"
CURL="${CURL:-curl}"
IMAGE="${NOXLANG_SITE_IMAGE:-ghcr.io/mburakmmm/noxlang-site:latest}"
COMPOSE_FILE="${COMPOSE_FILE:-$here/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-$here/.env}"
SERVICE="${SERVICE:-noxlang-site}"
SITE_URL="${SITE_URL:-http://127.0.0.1:8081}"
HEALTH_TIMEOUT_S="${HEALTH_TIMEOUT_S:-120}"
LOCK_DIR="${LOCK_DIR:-${TMPDIR:-/tmp}/nox-site-update.lock}"
STATE_DIR="${STATE_DIR:-$HOME/.nox-site-update}"
PRUNE_SCRIPT="${PRUNE_SCRIPT:-$here/prune-docker.sh}"
PRUNE_INTERVAL_S="${PRUNE_INTERVAL_S:-86400}"
repo="${IMAGE%:*}"
previous_tag="${repo}:previous"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# Disk/önbellek şişmesini önler (bkz. prune-docker.sh). Güncelleme ya da geri dönüşten sonra HEMEN (`force`), aksi halde en çok PRUNE_INTERVAL_S'de bir çalışır.
# Temizlik hiçbir zaman güncellemenin sonucunu değiştirmez.
housekeeping() {
  local force="${1:-}" now last
  now="$(date +%s)"
  last="$(cat "$STATE_DIR/last-prune" 2>/dev/null || echo 0)"
  if [ "$force" != "force" ] && [ $((now - last)) -lt "$PRUNE_INTERVAL_S" ]; then return 0; fi
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$now" > "$STATE_DIR/last-prune" 2>/dev/null || true
  [ -x "$PRUNE_SCRIPT" ] && "$PRUNE_SCRIPT" 2>&1 || true
}

compose() {
  local env_args=()
  [ -f "$ENV_FILE" ] && env_args=(--env-file "$ENV_FILE")
  # `${arr[@]+...}`: bash 3.2'de boş dizi + `set -u` "unbound variable" verir.
  NOXLANG_SITE_IMAGE="$IMAGE" "$DOCKER" compose -f "$COMPOSE_FILE" ${env_args[@]+"${env_args[@]}"} "$@"
}

image_id() { "$DOCKER" image inspect --format '{{.Id}}' "$1" 2>/dev/null; }
image_version() { "$DOCKER" image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$1" 2>/dev/null; }
running_image_id() {
  local cid
  cid="$(compose ps -q "$SERVICE" 2>/dev/null | head -1)"
  [ -n "$cid" ] || return 1
  "$DOCKER" inspect --format '{{.Image}}' "$cid" 2>/dev/null
}

# Servis sağlıklı ve /version.txt beklenen sürümü söylüyorsa 0.
wait_healthy() {
  local want="$1" waited=0 cid status served
  while [ "$waited" -lt "$HEALTH_TIMEOUT_S" ]; do
    cid="$(compose ps -q "$SERVICE" 2>/dev/null | head -1)"
    if [ -n "$cid" ]; then
      status="$("$DOCKER" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)"
      if [ "$status" = "healthy" ] || [ "$status" = "none" ]; then
        served="$("$CURL" -fsS --max-time 5 "$SITE_URL/version.txt" 2>/dev/null | tr -d '[:space:]')"
        if [ -n "$served" ] && { [ -z "$want" ] || [ "$served" = "$want" ]; }; then return 0; fi
      fi
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

mode="update"
[ "${1:-}" = "--check" ] && mode="check"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "başka bir güncelleme çalışıyor ($LOCK_DIR), atlandı"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

old_id="$(image_id "$IMAGE" || true)"
if ! "$DOCKER" pull --quiet "$IMAGE" >/dev/null 2>&1; then
  log "HATA: $IMAGE çekilemedi (ağ yok mu, paket genel mi?); site olduğu gibi bırakıldı"
  exit 1
fi
new_id="$(image_id "$IMAGE" || true)"
if [ -z "$new_id" ]; then
  log "HATA: çekilen imaj okunamadı; site olduğu gibi bırakıldı"
  exit 1
fi
new_version="$(image_version "$IMAGE" || true)"
run_id="$(running_image_id || true)"
mkdir -p "$STATE_DIR" 2>/dev/null || true
bad_id="$(cat "$STATE_DIR/bad-image" 2>/dev/null || true)"

if [ "$new_id" = "$run_id" ]; then
  log "güncel: $IMAGE (${new_version:-?})"
  housekeeping
  exit 0
fi
# Sağlıksız çıkıp geri alınmış bir imaj her 15 dakikada yeniden denenip siteyi kesmesin: o imaj kimliği atlanır (sonraki sürüm başka kimlik taşır).
if [ -n "$bad_id" ] && [ "$new_id" = "$bad_id" ]; then
  log "atlandı: ${new_version:-?} daha önce sağlıksız çıktı ve geri alındı (yeni bir sürüm bekleniyor; elle denemek için $STATE_DIR/bad-image dosyasını silin)"
  exit 0
fi
if [ "$mode" = "check" ]; then
  log "güncelleme var: ${new_version:-?} ($IMAGE)"
  exit 10
fi

log "güncelleniyor: ${new_version:-?} ($IMAGE)"
# Geri dönüş noktası: şu an çalışan imaj (varsa) `:previous` etiketiyle saklanır.
if [ -n "$run_id" ]; then "$DOCKER" tag "$run_id" "$previous_tag" >/dev/null 2>&1 || true
elif [ -n "$old_id" ] && [ "$old_id" != "$new_id" ]; then "$DOCKER" tag "$old_id" "$previous_tag" >/dev/null 2>&1 || true; fi

if compose up -d --no-build --no-deps "$SERVICE" >/dev/null 2>&1 && wait_healthy "$new_version"; then
  rm -f "$STATE_DIR/bad-image" 2>/dev/null || true
  log "tamam: ${new_version:-?} yayında"
  housekeeping force
  exit 0
fi

log "HATA: yeni imaj sağlıklı değil, önceki imaja dönülüyor"
printf '%s\n' "$new_id" > "$STATE_DIR/bad-image" 2>/dev/null || true
if [ -n "$run_id" ] && "$DOCKER" image inspect "$previous_tag" >/dev/null 2>&1; then
  "$DOCKER" tag "$previous_tag" "$IMAGE" >/dev/null 2>&1 || true
  if compose up -d --no-build --no-deps "$SERVICE" >/dev/null 2>&1 && wait_healthy ""; then
    log "geri dönüldü: önceki imaj yayında; bozuk imaj bir sonraki sürüme kadar atlanacak"
    housekeeping force
  else
    log "KRİTİK: geri dönüş de sağlıklı değil; elle müdahale gerekir (docker compose logs $SERVICE)"
  fi
else
  log "KRİTİK: geri dönülecek önceki imaj yok; elle müdahale gerekir"
fi
exit 1
