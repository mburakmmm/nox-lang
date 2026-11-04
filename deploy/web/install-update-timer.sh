#!/bin/bash
# Üretim makinesinde (macOS) otomatik site güncellemesini kurar/kaldırır: launchd her 15 dakikada `update-site.sh` çalıştırır.
#   deploy/web/install-update-timer.sh install     # ~/Library/LaunchAgents/com.noxlang.site-update.plist yazar ve yükler
#   deploy/web/install-update-timer.sh uninstall
#   deploy/web/install-update-timer.sh print        # kurmadan, üretilecek plist'i yazdırır
# Gerekenler: (1) GHCR paketinin GENEL olması, (2) bu depo klasörünün makinede bulunması (compose dosyası ve .env buradan kopyalanır).
#
# macOS koruması (TCC): launchd ajanları ~/Documents, ~/Desktop ve ~/Downloads altındaki dosyalara erişemez ("Operation not permitted", çıkış 126).
# Bu yüzden `install`, çalışmak için gereken dosyaları (update-site.sh, docker-compose.yml, .env) korumasız ~/.nox-site-update/deploy/ altına KOPYALAR
# (.env 0600). Compose dosyasını ya da .env'i değiştirirsen `install`ı yeniden çalıştır; kopya güncellenir. Betik yalnızca `noxlang-site`
# servisini kaldırır/kurar, bu yüzden kopyadaki göreli veri yolları (noxpkg vb.) hiç kullanılmaz.
set -eu
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
label="com.noxlang.site-update"
dest="$HOME/Library/LaunchAgents/$label.plist"
stage="$HOME/.nox-site-update/deploy"

render() { sed -e "s|__DEPLOY__|$stage|g" -e "s|__HOME__|$HOME|g" "$here/$label.plist.in"; }

stage_files() {
  mkdir -p "$stage"
  cp "$here/update-site.sh" "$stage/update-site.sh"
  cp "$here/docker-compose.yml" "$stage/docker-compose.yml"
  chmod 755 "$stage/update-site.sh"
  if [ -f "$here/.env" ]; then
    ( umask 077; cp "$here/.env" "$stage/.env" )
    chmod 600 "$stage/.env"
  else
    echo "uyarı: $here/.env yok; compose değişkenleri (NYX_SECRET_KEY vb.) tanımsızsa güncelleme başarısız olur" >&2
  fi
}

case "${1:-}" in
  print) render ;;
  install)
    stage_files
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    render > "$dest"
    plutil -lint "$dest" >/dev/null
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$dest"
    echo "kuruldu: $dest (15 dakikada bir; günlük: ~/Library/Logs/nox-site-update.log)"
    ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$dest"
    rm -rf "$stage"
    echo "kaldırıldı"
    ;;
  *) echo "kullanım: $0 install|uninstall|print" >&2; exit 2 ;;
esac
