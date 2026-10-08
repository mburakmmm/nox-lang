#!/bin/sh
# noxpkg veri yedeği: saatlik yerel anlık görüntü + (isteğe bağlı) restic ile Cloudflare R2'ye şifreli kopya.
#
# noxpkg'nin durumu BİRKAÇ KÜÇÜK JSON dosyasıdır (`index.json`, `inbox.json`, `ratelimit.txt`); SQLite YOKTUR.
# Sunucu her dosyayı geçici dosya + `rename` ile ATOMİK yazar, bu yüzden tek tek okunan her dosya tutarlıdır.
# (`approve` önce indeksi sonra gelen kutusunu yazar; iki dosyanın aynı anda alınması beklenmez — en kötü durumda
# bir onay iki anlık görüntüye bölünür ve bir sonraki saat düzelir.)
#
# Kullanım:
#   backup_noxpkg.sh once                   tek anlık görüntü al (+ rotasyon + varsa R2'ye gönder)
#   backup_noxpkg.sh loop                   BACKUP_INTERVAL_SECONDS aralığıyla sonsuz döngü (konteyner girişi)
#   backup_noxpkg.sh restore <dosya|latest> <hedef-dizin>
#                                           bir anlık görüntüyü hedef dizine açar (ÜZERİNE YAZMAZ: dizin boş/yok olmalı)
#   backup_noxpkg.sh verify                 son anlık görüntüyü geçici dizine açıp JSON'u doğrular (geri yükleme testi)
#
# Ortam: DATA_DIR (/data), BACKUP_DIR (/backups), KEEP_HOURLY (48), KEEP_DAILY (30), KEEP_WEEKLY (12),
#        BACKUP_INTERVAL_SECONDS (3600); R2 için RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_ACCESS_KEY_ID,
#        AWS_SECRET_ACCESS_KEY (hepsi doluysa off-site açılır). Yalnızca POSIX sh + tar + gzip (+ jq, restic varsa).

set -eu

DATA_DIR="${DATA_DIR:-/data}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
KEEP_HOURLY="${KEEP_HOURLY:-48}"
KEEP_DAILY="${KEEP_DAILY:-30}"
KEEP_WEEKLY="${KEEP_WEEKLY:-12}"
BACKUP_INTERVAL_SECONDS="${BACKUP_INTERVAL_SECONDS:-3600}"
FILES="index.json inbox.json ratelimit.txt"

log() { printf '%s backup: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "HATA: $*" >&2; exit 1; }

# Tüm JSON dosyalarının geçerli olduğunu denetler (jq varsa jq, yoksa en azından boş olmadığını ve { ile başladığını).
validate_dir() {
    dir="$1"
    for f in index.json inbox.json; do
        [ -f "$dir/$f" ] || continue
        if command -v jq >/dev/null 2>&1; then
            jq -e . "$dir/$f" >/dev/null 2>&1 || return 1
        else
            [ -s "$dir/$f" ] || return 1
            head -c 1 "$dir/$f" | grep -q '[{[]' || return 1
        fi
    done
    return 0
}

# ---- tarih aritmetiği (date -d'ye bağımlı OLMADAN; busybox/GNU/BSD'de aynı) ----
# YYYYMMDD -> 1970-01-01'den beri gün sayısı (Howard Hinnant "days_from_civil").
days_from_ymd() {
    y=$(printf '%s' "$1" | cut -c1-4 | sed 's/^0*//')
    m=$(printf '%s' "$1" | cut -c5-6 | sed 's/^0*//')
    d=$(printf '%s' "$1" | cut -c7-8 | sed 's/^0*//')
    [ -n "$y" ] || y=0; [ -n "$m" ] || m=1; [ -n "$d" ] || d=1
    if [ "$m" -le 2 ]; then y=$((y - 1)); fi
    era=$((y / 400))
    yoe=$((y - era * 400))
    if [ "$m" -gt 2 ]; then mp=$((m - 3)); else mp=$((m + 9)); fi
    doy=$(( (153 * mp + 2) / 5 + d - 1 ))
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    echo $((era * 146097 + doe - 719468))
}

# noxpkg-YYYYMMDDTHHMMSSZ.tar.gz -> YYYYMMDD
snap_day() { basename "$1" | sed -E 's/^noxpkg-([0-9]{8})T.*/\1/'; }

list_snapshots() { ls -1 "$BACKUP_DIR"/noxpkg-*.tar.gz 2>/dev/null | sort; }

# Rotasyon: en yeni KEEP_HOURLY + her gün için en yeni (son KEEP_DAILY gün) + her hafta için en yeni (son KEEP_WEEKLY hafta).
rotate() {
    all=$(list_snapshots) || true
    [ -n "$all" ] || return 0
    keep=$(mktemp)
    # saatlik: en yeni N
    printf '%s\n' "$all" | tail -n "$KEEP_HOURLY" >> "$keep"
    # günlük: gün başına en yeni, en yeni KEEP_DAILY gün
    printf '%s\n' "$all" | while read -r f; do printf '%s %s\n' "$(snap_day "$f")" "$f"; done \
        | sort -k1,1 -k2,2 | awk '{last[$1]=$2} END {for (d in last) print d, last[d]}' | sort -r \
        | head -n "$KEEP_DAILY" | awk '{print $2}' >> "$keep"
    # haftalık: (gün sayısı / 7) başına en yeni, en yeni KEEP_WEEKLY hafta
    printf '%s\n' "$all" | while read -r f; do
        d=$(snap_day "$f"); n=$(days_from_ymd "$d"); printf '%s %s\n' "$((n / 7))" "$f"
    done | sort -k1,1n -k2,2 | awk '{last[$1]=$2} END {for (w in last) print w, last[w]}' | sort -rn \
        | head -n "$KEEP_WEEKLY" | awk '{print $2}' >> "$keep"
    sort -u "$keep" -o "$keep"
    before=$(printf '%s\n' "$all" | wc -l | tr -d ' ')
    printf '%s\n' "$all" | while read -r f; do
        if ! grep -qxF "$f" "$keep"; then rm -f "$f" "$f.sha256"; fi
    done
    after=$(list_snapshots | wc -l | tr -d ' ')
    rm -f "$keep"
    log "rotasyon: $before -> $after anlık görüntü"
}

snapshot() {
    [ -d "$DATA_DIR" ] || die "veri dizini yok: $DATA_DIR"
    mkdir -p "$BACKUP_DIR"
    stage=$(mktemp -d "$BACKUP_DIR/.stage.XXXXXX")
    trap 'rm -rf "$stage"' EXIT
    present=""
    for f in $FILES; do
        if [ -f "$DATA_DIR/$f" ]; then cp "$DATA_DIR/$f" "$stage/$f"; present="$present $f"; fi
    done
    [ -n "$present" ] || die "yedeklenecek dosya yok ($DATA_DIR)"
    validate_dir "$stage" || die "JSON doğrulaması başarısız — bozuk veri YEDEKLENMEDİ"
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    out="$BACKUP_DIR/noxpkg-$ts.tar.gz"
    tmp="$out.partial"
    # shellcheck disable=SC2086
    tar -czf "$tmp" -C "$stage" $present
    mv "$tmp" "$out"
    ( cd "$BACKUP_DIR" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
    rm -rf "$stage"; trap - EXIT
    log "anlık görüntü: $out ($(wc -c < "$out") bayt)"
    rotate
    return 0
}

offsite() {
    if [ -z "${RESTIC_REPOSITORY:-}" ] || [ -z "${RESTIC_PASSWORD:-}" ] || [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        log "off-site kapalı (RESTIC_*/AWS_* ayarlı değil) — yalnızca yerel anlık görüntü"
        return 0
    fi
    command -v restic >/dev/null 2>&1 || { log "UYARI: restic yok, off-site atlandı"; return 1; }
    restic snapshots >/dev/null 2>&1 || { log "restic deposu başlatılıyor"; restic init >/dev/null || return 1; }
    restic backup "$DATA_DIR" --tag noxpkg --quiet || return 1
    restic forget --tag noxpkg --keep-hourly "$KEEP_HOURLY" --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly 12 --prune --quiet || return 1
    log "off-site (restic/R2) tamam"
}

status_ok() { date -u +%s > "$BACKUP_DIR/.last_ok"; }

restore() {
    src="$1"; dest="$2"
    if [ "$src" = latest ]; then src=$(list_snapshots | tail -n 1); fi
    [ -n "$src" ] && [ -f "$src" ] || die "anlık görüntü bulunamadı"
    if [ -f "$src.sha256" ]; then ( cd "$(dirname "$src")" && sha256sum -c "$(basename "$src").sha256" >/dev/null ) || die "sağlama toplamı UYUŞMUYOR: $src"; fi
    if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then die "hedef dizin boş değil (üzerine yazılmaz): $dest"; fi
    mkdir -p "$dest"
    tar -xzf "$src" -C "$dest"
    validate_dir "$dest" || die "geri yüklenen veri doğrulanamadı"
    log "geri yüklendi: $src -> $dest"
}

verify() {
    snap=$(list_snapshots | tail -n 1)
    [ -n "$snap" ] || die "doğrulanacak anlık görüntü yok"
    tmp=$(mktemp -d)
    restore "$snap" "$tmp/restored"
    for f in $FILES; do
        if [ -f "$DATA_DIR/$f" ] && [ ! -f "$tmp/restored/$f" ]; then rm -rf "$tmp"; die "geri yüklemede eksik dosya: $f"; fi
    done
    rm -rf "$tmp"
    log "geri yükleme testi geçti: $snap"
}

main() {
case "${1:-}" in
    once) snapshot; if offsite; then :; else log "UYARI: off-site başarısız"; fi; status_ok ;;
    loop)
        log "başlıyor: aralık=${BACKUP_INTERVAL_SECONDS}s veri=$DATA_DIR yedek=$BACKUP_DIR"
        while true; do
            if ( snapshot ); then
                if offsite; then :; else log "UYARI: off-site başarısız (yerel anlık görüntü alındı)"; fi
                status_ok
            else
                log "UYARI: anlık görüntü başarısız"
            fi
            sleep "$BACKUP_INTERVAL_SECONDS"
        done ;;
    restore) [ $# -eq 3 ] || die "kullanım: restore <dosya|latest> <hedef-dizin>"; restore "$2" "$3" ;;
    verify) verify ;;
    *) die "kullanım: $0 {once|loop|restore <dosya|latest> <dizin>|verify}" ;;
esac
}

# BACKUP_LIB=1: işlevleri yalnızca yükle (test betiği için); aksi halde komutu çalıştır.
if [ "${BACKUP_LIB:-0}" != 1 ]; then main "$@"; fi
