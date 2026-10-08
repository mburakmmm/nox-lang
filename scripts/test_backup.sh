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
echo "tüm yedekleme testleri geçti"
