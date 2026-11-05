#!/bin/bash
# update-site.sh'in sınaması: sahte bir `docker`/`curl` ile (gerçek konteyner/ağ yok) şu senaryoları doğrular:
#   1) hiç çalışan site yok -> yeni imaj çekilir ve başlatılır
#   2) imaj değişmedi -> hiçbir şey yapılmaz
#   3) yeni sürüm sağlıklı -> güncellenir, `:previous` saklanır
#   4) yeni sürüm sağlıksız -> önceki imaja geri dönülür, kötü imaj bir sonraki çalıştırmada atlanır
#   5) çekme başarısız -> site olduğu gibi kalır
#   6) --check değişiklik yapmaz; kilit tutuluyorsa atlanır
#   7) temizlik (prune-docker.sh): eski sürüm etiketleri silinir, latest/previous korunur; güncelleme/geri dönüşten sonra hemen, aksi halde günde en çok bir kez çalışır
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

mkdir -p "$work/bin" "$work/state"
# --- sahte docker: durum dosyalarda (images/<ref> = id, running = id, versions/<id>) ---
cat > "$work/bin/docker" <<'SH'
#!/bin/bash
S="${FAKE_STATE:?}"
args="$*"
echo "$args" >> "$S/calls"
case "$1" in
  images) cat "$S/tag_list" 2>/dev/null; exit 0 ;;
  pull)
    [ -f "$S/pull_fail" ] && exit 1
    ref="${@: -1}"
    echo "$(cat "$S/registry_id")" > "$S/images/$(echo "$ref" | tr '/:' '__')"
    exit 0 ;;
  tag)
    src="$2"; dst="$3"
    id="$src"; [ -f "$S/images/$(echo "$src" | tr '/:' '__')" ] && id="$(cat "$S/images/$(echo "$src" | tr '/:' '__')")"
    echo "$id" > "$S/images/$(echo "$dst" | tr '/:' '__')"; exit 0 ;;
  image)
    ref="${@: -1}"; f="$S/images/$(echo "$ref" | tr '/:' '__')"
    [ -f "$f" ] || exit 1
    id="$(cat "$f")"
    case "$args" in
      *Labels*) cat "$S/version_of_$id" 2>/dev/null ;;
      *) echo "$id" ;;
    esac; exit 0 ;;
  inspect)
    case "$args" in
      *State.Health*) [ -f "$S/running" ] || exit 1; if [ "$(cat "$S/running")" = "$(cat "$S/bad_id" 2>/dev/null)" ]; then echo unhealthy; else echo healthy; fi ;;
      *) cat "$S/running" ;;
    esac; exit 0 ;;
  compose)
    case "$args" in
      *" ps -q"*) [ -f "$S/running" ] && echo container123 ;;
      *" up "*)
        ref="${NOXLANG_SITE_IMAGE:?}"
        cp "$S/images/$(echo "$ref" | tr '/:' '__')" "$S/running"
        echo "up" >> "$S/up_calls" ;;
    esac; exit 0 ;;
esac
exit 0
SH
cat > "$work/bin/curl" <<'SH'
#!/bin/bash
S="${FAKE_STATE:?}"
[ -f "$S/running" ] || exit 22
id="$(cat "$S/running")"
[ "$id" = "$(cat "$S/bad_id" 2>/dev/null)" ] && exit 22
cat "$S/version_of_$id"
SH
chmod +x "$work/bin/docker" "$work/bin/curl"

run() {  # run <args...>; çıktı $work/out
  FAKE_STATE="$work/state" DOCKER="$work/bin/docker" CURL="$work/bin/curl" SITE_URL=http://fake \
    NOXLANG_SITE_IMAGE=ghcr.io/o/noxlang-site:latest COMPOSE_FILE=/dev/null ENV_FILE=/nonexistent HEALTH_TIMEOUT_S=6 \
    LOCK_DIR="$work/lock" STATE_DIR="$work/state/upd" "$here/update-site.sh" "$@" > "$work/out" 2>&1
  return $?
}
reset() { rm -rf "$work/state" "$work/lock"; mkdir -p "$work/state/images"; }
version() { printf '%s\n' "$2" > "$work/state/version_of_$1"; }

# 1) hiç çalışan site yok
reset; echo sha256:aaa > "$work/state/registry_id"; version sha256:aaa 2.0.1
run; rc=$?
{ [ $rc = 0 ] && [ "$(cat "$work/state/running")" = sha256:aaa ]; } && ok "ilk kurulum yeni imajı başlatır" || { fail "ilk kurulum (rc=$rc)"; cat "$work/out"; }

# 2) değişiklik yok
rm -f "$work/state/up_calls"
run; rc=$?
{ [ $rc = 0 ] && [ ! -f "$work/state/up_calls" ] && grep -q "güncel" "$work/out"; } && ok "imaj aynıysa hiçbir şey yapılmaz" || { fail "değişiklik yok (rc=$rc)"; cat "$work/out"; }

# 6a) --check yeni imaj varken değişiklik yapmaz, 10 döner
echo sha256:bbb > "$work/state/registry_id"; version sha256:bbb 2.0.2
run --check; rc=$?
{ [ $rc = 10 ] && [ "$(cat "$work/state/running")" = sha256:aaa ]; } && ok "--check güncelleme olduğunu bildirir ama dokunmaz" || { fail "--check (rc=$rc)"; cat "$work/out"; }

# 6b) kilit tutuluyor
mkdir "$work/lock"
run; rc=$?
{ [ $rc = 0 ] && grep -q "başka bir güncelleme" "$work/out" && [ "$(cat "$work/state/running")" = sha256:aaa ]; } && ok "kilit varken atlanır" || { fail "kilit (rc=$rc)"; cat "$work/out"; }
rmdir "$work/lock"

# 3) sağlıklı güncelleme
run; rc=$?
{ [ $rc = 0 ] && [ "$(cat "$work/state/running")" = sha256:bbb ] && [ "$(cat "$work/state/images/ghcr.io_o_noxlang-site_previous")" = sha256:aaa ]; } && ok "sağlıklı yeni imaj yayına alınır, önceki saklanır" || { fail "güncelleme (rc=$rc)"; cat "$work/out"; }

# 4) sağlıksız yeni imaj -> geri dönüş, sonra atlanır
echo sha256:ccc > "$work/state/registry_id"; version sha256:ccc 2.0.3; echo sha256:ccc > "$work/state/bad_id"
run; rc=$?
{ [ $rc = 1 ] && [ "$(cat "$work/state/running")" = sha256:bbb ] && grep -q "geri dönüldü" "$work/out"; } && ok "sağlıksız imaj geri alınır" || { fail "geri dönüş (rc=$rc)"; cat "$work/out"; }
rm -f "$work/state/up_calls"
run; rc=$?
{ [ $rc = 0 ] && [ ! -f "$work/state/up_calls" ] && grep -q "atlandı" "$work/out"; } && ok "geri alınmış imaj tekrar tekrar denenmez" || { fail "kötü imajı atla (rc=$rc)"; cat "$work/out"; }

# yeni, düzeltilmiş sürüm gelince yeniden denenir
echo sha256:ddd > "$work/state/registry_id"; version sha256:ddd 2.0.4
run; rc=$?
{ [ $rc = 0 ] && [ "$(cat "$work/state/running")" = sha256:ddd ] && [ ! -f "$work/state/upd/bad-image" ]; } && ok "düzeltilmiş sürüm yeniden denenir" || { fail "düzeltilmiş sürüm (rc=$rc)"; cat "$work/out"; }

# 5) çekme başarısız
touch "$work/state/pull_fail"; echo sha256:eee > "$work/state/registry_id"
run; rc=$?
{ [ $rc = 1 ] && [ "$(cat "$work/state/running")" = sha256:ddd ] && grep -q "çekilemedi" "$work/out"; } && ok "çekme başarısızsa site olduğu gibi kalır" || { fail "çekme hatası (rc=$rc)"; cat "$work/out"; }

# 7) temizlik
export NOXLANG_SITE_REPO=ghcr.io/o/noxlang-site
reset
printf '%s\n' ghcr.io/o/noxlang-site:latest ghcr.io/o/noxlang-site:previous ghcr.io/o/noxlang-site:2.0.1 ghcr.io/o/noxlang-site:2.0.2 > "$work/state/tag_list"
FAKE_STATE="$work/state" DOCKER="$work/bin/docker" "$here/prune-docker.sh" > "$work/out" 2>&1; rc=$?
{ [ $rc = 0 ] && grep -q "^rmi ghcr.io/o/noxlang-site:2.0.1$" "$work/state/calls" && grep -q "^rmi ghcr.io/o/noxlang-site:2.0.2$" "$work/state/calls" \
  && ! grep -q "^rmi .*:latest" "$work/state/calls" && ! grep -q "^rmi .*:previous" "$work/state/calls" \
  && grep -q "^builder prune" "$work/state/calls" && grep -q "^image prune" "$work/state/calls"; } \
  && ok "prune eski sürüm etiketlerini siler, latest/previous korunur, önbellek temizlenir" || { fail "prune (rc=$rc)"; cat "$work/out" "$work/state/calls"; }

# güncelleme sonrası hemen temizlik; hemen ardından gelen "güncel" çalıştırması (24 saat dolmadan) temizlemez
reset; echo sha256:aaa > "$work/state/registry_id"; version sha256:aaa 2.0.1
run; rc=$?
{ [ $rc = 0 ] && grep -q "^builder prune" "$work/state/calls"; } && ok "güncellemeden sonra temizlik hemen çalışır" || { fail "güncelleme sonrası prune (rc=$rc)"; cat "$work/out"; }
: > "$work/state/calls"
run; rc=$?
{ [ $rc = 0 ] && ! grep -q "^builder prune" "$work/state/calls"; } && ok "güncel çalıştırma 24 saat dolmadan temizlik yapmaz" || { fail "gereksiz prune (rc=$rc)"; cat "$work/state/calls"; }
PRUNE_INTERVAL_S=0 run; rc=$?
{ [ $rc = 0 ] && grep -q "^builder prune" "$work/state/calls"; } && ok "süre dolunca güncel çalıştırma da temizler" || { fail "süreli prune (rc=$rc)"; cat "$work/state/calls"; }
# sağlıksız imaj geri alınınca da temizlenir
echo sha256:fff > "$work/state/registry_id"; version sha256:fff 2.0.9; echo sha256:fff > "$work/state/bad_id"; : > "$work/state/calls"
run; rc=$?
{ [ $rc = 1 ] && grep -q "geri dönüldü" "$work/out" && grep -q "^builder prune" "$work/state/calls"; } && ok "geri dönüşten sonra da temizlik çalışır" || { fail "geri dönüş prune (rc=$rc)"; cat "$work/out"; }

[ "$fails" = 0 ] && echo "update-site.sh testi: temiz" || { echo "$fails hata"; exit 1; }
