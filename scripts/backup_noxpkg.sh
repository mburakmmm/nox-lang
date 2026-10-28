#!/bin/sh
# noxpkg veri yedeği: saatlik yerel anlık görüntü + (isteğe bağlı) restic ile Cloudflare R2'ye şifreli kopya.
#
# noxpkg'nin durumu `noxpkg.db`dir. Hesap, yorum ve hata bildirimi yalnızca oradadır.
# `index.json` / `inbox.json` sunucunun sildiği bir kaynak DEĞİL, katalog aynasıdır;
# arşivdeki kopya canlı dosyadan DEĞİL, `.backup` ile alınan veritabanından üretilir.
# Böylece yedek, o anki katalogla birebir kalır. `ratelimit.txt` varsa yanında gider.
# Off-site kopya da bu arşivin kendisidir, canlı dosyanın yarım kopyası değil.
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
FILES="index.json inbox.json ratelimit.txt noxpkg.db"

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

# SQLite dosyası varsa başlığı ve (sqlite3 kuruluysa) bütünlük denetimini geçmelidir.
validate_sqlite() {
    dir="$1"
    [ -f "$dir/noxpkg.db" ] || return 0
    magic=$(head -c 15 "$dir/noxpkg.db" 2>/dev/null || true)
    [ "$magic" = "SQLite format 3" ] || return 1
    if command -v sqlite3 >/dev/null 2>&1; then
        out=$(sqlite3 "$dir/noxpkg.db" "PRAGMA integrity_check;" 2>/dev/null || echo fail)
        [ "$out" = "ok" ] || return 1
    fi
    return 0
}

copy_sqlite() {
    stage="$1"
    [ -f "$DATA_DIR/noxpkg.db" ] || return 0
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 -cmd ".timeout 8000" "$DATA_DIR/noxpkg.db" ".backup '$stage/noxpkg.db'" || return 1
    else
        cp "$DATA_DIR/noxpkg.db" "$stage/noxpkg.db" || return 1
    fi
    return 0
}

# Aynayı yedeklenen veritabanından yazar. Canlı JSON bayatsa arşive girmez.
# `packages` tablosu yoksa (eski/yabancı dosya) dokunulmaz.
export_catalog() {
    db="$1"
    dest="$2"
    command -v sqlite3 >/dev/null 2>&1 || return 0
    has=$(sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='packages';")
    [ "$has" = "1" ] || return 0
    sqlite3 "$db" "SELECT json_object('packages', IFNULL((SELECT json_group_array(json_object('name', name, 'repo', repo, 'description', description, 'tags', json(tags))) FROM (SELECT name, repo, description, tags FROM packages ORDER BY name)), json('[]')));" > "$dest/index.json.tmp" || return 1
    sqlite3 "$db" "SELECT json_object('submissions', IFNULL((SELECT json_group_array(json_object('id', id, 'name', name, 'repo', repo, 'ref', ref, 'description', description, 'tags', json(tags), 'submitted_at_ms', submitted_at_ms)) FROM (SELECT id, name, repo, ref, description, tags, submitted_at_ms FROM submissions ORDER BY submitted_at_ms)), json('[]')));" > "$dest/inbox.json.tmp" || return 1
    mv "$dest/index.json.tmp" "$dest/index.json"
    mv "$dest/inbox.json.tmp" "$dest/inbox.json"
    return 0
}

# Veritabanındaki paket ve gönderi kimlikleri JSON aynasıyla aynı mı.
catalog_matches() {
    dir="$1"
    [ -f "$dir/noxpkg.db" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0
    has=$(sqlite3 "$dir/noxpkg.db" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='packages';")
    [ "$has" = "1" ] || return 0
    [ -f "$dir/index.json" ] && [ -f "$dir/inbox.json" ] || return 1
    db_names=$(sqlite3 "$dir/noxpkg.db" "SELECT name FROM packages ORDER BY name;")
    json_names=$(jq -r '.packages[].name' "$dir/index.json" | sort)
    [ "$db_names" = "$json_names" ] || return 1
    db_ids=$(sqlite3 "$dir/noxpkg.db" "SELECT id FROM submissions ORDER BY id;")
    json_ids=$(jq -r '.submissions[].id' "$dir/inbox.json" | sort)
    [ "$db_ids" = "$json_ids" ] || return 1
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
    if [ -f "$DATA_DIR/noxpkg.db" ]; then
        copy_sqlite "$stage" || die "SQLite yedeği alınamadı"
        export_catalog "$stage/noxpkg.db" "$stage" || die "katalog aynası veritabanından üretilemedi"
        present="noxpkg.db"
        [ -f "$stage/index.json" ] && present="$present index.json"
        [ -f "$stage/inbox.json" ] && present="$present inbox.json"
        if [ -f "$DATA_DIR/ratelimit.txt" ]; then cp "$DATA_DIR/ratelimit.txt" "$stage/ratelimit.txt"; present="$present ratelimit.txt"; fi
    else
        for f in index.json inbox.json ratelimit.txt; do
            if [ -f "$DATA_DIR/$f" ]; then cp "$DATA_DIR/$f" "$stage/$f"; present="$present $f"; fi
        done
    fi
    [ -n "$present" ] || die "yedeklenecek dosya yok ($DATA_DIR)"
    validate_dir "$stage" || die "JSON doğrulaması başarısız — bozuk veri YEDEKLENMEDİ"
    validate_sqlite "$stage" || die "SQLite doğrulaması başarısız — bozuk veri YEDEKLENMEDİ"
    catalog_matches "$stage" || die "katalog aynası veritabanıyla uyuşmuyor — yedeklenmedi"
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    out="$BACKUP_DIR/noxpkg-$ts.tar.gz"
    tmp="$out.partial"
    # shellcheck disable=SC2086
    tar -czf "$tmp" -C "$stage" $present
    mv "$tmp" "$out"
    printf '%s\n' "$out" > "$BACKUP_DIR/.last_snapshot"
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
    target="$BACKUP_DIR"
    if [ -f "$BACKUP_DIR/.last_snapshot" ]; then target=$(cat "$BACKUP_DIR/.last_snapshot"); fi
    [ -f "$target" ] || { log "UYARI: off-site için arşiv yok"; return 1; }
    restic backup "$target" --tag noxpkg --quiet || return 1
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
    validate_sqlite "$dest" || die "geri yüklenen SQLite doğrulanamadı"
    catalog_matches "$dest" || die "geri yüklenen katalog veritabanıyla uyuşmuyor"
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
