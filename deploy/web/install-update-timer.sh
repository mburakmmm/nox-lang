#!/bin/bash
# Üretim makinesinde (macOS) otomatik site güncellemesini kurar/kaldırır: launchd her 15 dakikada `update-site.sh` çalıştırır.
#   deploy/web/install-update-timer.sh install     # ~/Library/LaunchAgents/com.noxlang.site-update.plist yazar ve yükler
#   deploy/web/install-update-timer.sh uninstall
#   deploy/web/install-update-timer.sh print        # kurmadan, üretilecek plist'i yazdırır
# Gerekenler: (1) GHCR paketinin GENEL olması, (2) bu depo klasörünün makinede bulunması (compose dosyası ve .env buradan okunur).
set -eu
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
label="com.noxlang.site-update"
dest="$HOME/Library/LaunchAgents/$label.plist"

render() { sed -e "s|__REPO__|$repo|g" -e "s|__HOME__|$HOME|g" "$here/$label.plist.in"; }

case "${1:-}" in
  print) render ;;
  install)
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
    echo "kaldırıldı"
    ;;
  *) echo "kullanım: $0 install|uninstall|print" >&2; exit 2 ;;
esac
