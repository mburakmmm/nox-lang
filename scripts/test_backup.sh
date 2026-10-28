#!/bin/sh
# scripts/backup_noxpkg.sh testi: anlık görüntü, bozuk veriyi reddetme, rotasyon, geri yükleme, sağlama toplamı.
# Çalıştırma:  sh scripts/test_backup.sh        (busybox/alpine ve GNU/BSD sh'ta geçmelidir)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "BAŞARISIZ: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

export DATA_DIR="$T/data" BACKUP_DIR="$T/backups" KEEP_HOURLY=2 KEEP_DAILY=2 KEEP_WEEKLY=1
mkdir -p "$DATA_DIR"
printf '{"packages":[{"name":"nyx","repo":"github.com/mburakmmm/nyx","description":"d","tags":["web"]}]}\n' > "$DATA_DIR/index.json"
printf '{"pending":[]}\n' > "$DATA_DIR/inbox.json"
: > "$DATA_DIR/ratelimit.txt"

# 1) tek anlık görüntü + sağlama toplamı + doğrulama
sh "$HERE/backup_noxpkg.sh" once >/dev/null
n=$(ls "$BACKUP_DIR"/noxpkg-*.tar.gz | wc -l | tr -d ' ')
[ "$n" = 1 ] || fail "1 anlık görüntü bekleniyordu, $n var"
[ -f "$BACKUP_DIR"/noxpkg-*.tar.gz.sha256 ] || fail "sha256 dosyası yok"
sh "$HERE/backup_noxpkg.sh" verify >/dev/null || fail "verify başarısız"
ok "anlık görüntü + sağlama toplamı + verify"

# 2) bozuk JSON yedeklenmez
snap_before=$(ls "$BACKUP_DIR"/noxpkg-*.tar.gz | wc -l | tr -d ' ')
printf '{bozuk json' > "$DATA_DIR/index.json"
if command -v jq >/dev/null 2>&1; then
    if sh "$HERE/backup_noxpkg.sh" once >/dev/null 2>&1; then fail "bozuk JSON yedeklendi"; fi
    snap_after=$(ls "$BACKUP_DIR"/noxpkg-*.tar.gz | wc -l | tr -d ' ')
    [ "$snap_before" = "$snap_after" ] || fail "bozuk veri için yeni anlık görüntü oluştu"
    ok "bozuk JSON reddedildi (jq)"
else
    echo "atlandı - bozuk JSON (jq yok; yedek betiği yalnızca temel denetim yapar)"
fi
printf '{"packages":[{"name":"nyx","repo":"github.com/mburakmmm/nyx","description":"d","tags":["web"]}]}\n' > "$DATA_DIR/index.json"

# 3) rotasyon: sentetik adlar (saatlik 2 + günlük 2 + haftalık 1)
rm -rf "$BACKUP_DIR"; mkdir -p "$BACKUP_DIR"
for ts in 20260101T000000Z 20260101T120000Z 20260102T000000Z 20260102T120000Z 20260103T000000Z 20260103T120000Z 20260103T230000Z; do
    echo x > "$BACKUP_DIR/noxpkg-$ts.tar.gz"
done
( BACKUP_LIB=1; . "$HERE/backup_noxpkg.sh"; rotate >/dev/null )
got=$(ls "$BACKUP_DIR"/noxpkg-*.tar.gz | sed 's/.*noxpkg-//; s/.tar.gz//' | tr '\n' ' ')
want="20260102T120000Z 20260103T120000Z 20260103T230000Z "
[ "$got" = "$want" ] || fail "rotasyon yanlış: '$got' (beklenen '$want')"
ok "rotasyon (saatlik/günlük/haftalık)"

# 4) geri yükleme: üzerine yazmaz, içerik aynı, bozuk arşivi reddeder
rm -rf "$BACKUP_DIR"; mkdir -p "$BACKUP_DIR"
sh "$HERE/backup_noxpkg.sh" once >/dev/null
mkdir "$T/restore1"
sh "$HERE/backup_noxpkg.sh" restore latest "$T/restore1" >/dev/null || fail "restore başarısız"
cmp "$DATA_DIR/index.json" "$T/restore1/index.json" || fail "index.json farklı"
cmp "$DATA_DIR/inbox.json" "$T/restore1/inbox.json" || fail "inbox.json farklı"
if sh "$HERE/backup_noxpkg.sh" restore latest "$T/restore1" >/dev/null 2>&1; then fail "dolu dizinin üzerine yazıldı"; fi
ok "geri yükleme (aynı içerik, üzerine yazmaz)"
snap=$(ls "$BACKUP_DIR"/noxpkg-*.tar.gz | tail -n 1)
printf 'corrupt' >> "$snap"
if sh "$HERE/backup_noxpkg.sh" restore latest "$T/restore2" >/dev/null 2>&1; then fail "bozuk arşiv kabul edildi"; fi
ok "bozuk arşiv sağlama toplamıyla reddedildi"

# 5) SQLite: tutarlı kopya, bozuk dosya reddi
if command -v sqlite3 >/dev/null 2>&1; then
    rm -f "$DATA_DIR/index.json" "$DATA_DIR/inbox.json" "$DATA_DIR/ratelimit.txt"
    rm -rf "$BACKUP_DIR"; mkdir -p "$BACKUP_DIR"
    sqlite3 "$DATA_DIR/noxpkg.db" "CREATE TABLE t(x TEXT); INSERT INTO t VALUES ('nyx');"
    sh "$HERE/backup_noxpkg.sh" once >/dev/null || fail "sqlite anlık görüntüsü alınamadı"
    mkdir -p "$T/restore-db"
    sh "$HERE/backup_noxpkg.sh" restore latest "$T/restore-db" >/dev/null || fail "sqlite restore başarısız"
    got=$(sqlite3 "$T/restore-db/noxpkg.db" "SELECT x FROM t;")
    [ "$got" = "nyx" ] || fail "geri yüklenen sqlite satırı: '$got'"
    printf 'nope' > "$DATA_DIR/noxpkg.db"
    if sh "$HERE/backup_noxpkg.sh" once >/dev/null 2>&1; then fail "bozuk sqlite yedeklendi"; fi
    ok "sqlite yedek + bozuk dosya reddi"

    # 6) Bayat JSON arşive girmez; katalog yedekteki veritabanından üretilir.
    rm -rf "$BACKUP_DIR"; mkdir -p "$BACKUP_DIR"
    rm -f "$DATA_DIR/noxpkg.db"
    sqlite3 "$DATA_DIR/noxpkg.db" "CREATE TABLE packages (name TEXT PRIMARY KEY, repo TEXT, description TEXT, tags TEXT, created_at_ms INTEGER); CREATE TABLE submissions (id TEXT PRIMARY KEY, name TEXT, repo TEXT, ref TEXT, description TEXT, tags TEXT, submitted_at_ms INTEGER); INSERT INTO packages VALUES ('nyx','github.com/mburakmmm/nyx','web','[\"web\"]',1); INSERT INTO submissions VALUES ('abc','aura','github.com/mburakmmm/aura','main','ui','[\"ui\"]',2);"
    printf '%s\n' '{"packages":[{"name":"gone","repo":"x","description":"","tags":[]}]}' > "$DATA_DIR/index.json"
    printf '%s\n' '{"submissions":[]}' > "$DATA_DIR/inbox.json"
    sh "$HERE/backup_noxpkg.sh" once >/dev/null || fail "katalog yedeği alınamadı"
    mkdir -p "$T/restore-cat"
    sh "$HERE/backup_noxpkg.sh" restore latest "$T/restore-cat" >/dev/null || fail "katalog restore başarısız"
    name=$(jq -r '.packages[0].name' "$T/restore-cat/index.json")
    sid=$(jq -r '.submissions[0].id' "$T/restore-cat/inbox.json")
    [ "$name" = "nyx" ] || fail "bayat JSON arşive girdi: $name"
    [ "$sid" = "abc" ] || fail "gönderi kayboldu: $sid"
    [ "$(sqlite3 "$T/restore-cat/noxpkg.db" "SELECT name FROM packages;")" = "nyx" ] || fail "veritabanındaki paket kayboldu"
    ok "bayat JSON yok sayıldı, katalog veritabanından üretildi"
else
    echo "atlandı - sqlite3 yok"
fi
echo "tüm yedekleme testleri geçti"
