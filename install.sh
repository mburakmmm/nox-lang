#!/usr/bin/env bash
# Nox kurulum betiği — GitHub Releases'ten (bkz. .github/workflows/release.yml)
# önceden derlenmiş bir `noxc`/`noxlsp` + `noxrt.o` + `nox.*` stdlib +
# gömülü `qbe` paketi indirir, $NOX_INSTALL_DIR (varsayılan ~/.nox-lang)
# altına açar. Kullanım:
#
#   curl -fsSL https://raw.githubusercontent.com/mburakmmm/nox-lang/main/install.sh | sh
#
# Ortam değişkenleriyle özelleştirme:
#   NOX_INSTALL_DIR   kurulum kökü (varsayılan: $HOME/.nox-lang)
#   NOX_VERSION       belirli bir sürüm etiketi (ör. v1.0.0) — varsayılan: en son sürüm
#
# `noxc` çalışma zamanında bir C derleyicisi (`cc`) BULMAK ZORUNDADIR
# (linkleme için) — bu betik `qbe`yi PAKETİN İÇİNDE GETİRİR (bkz. release
# workflow'unun belge notu) ama `cc`yi KURMAZ (macOS'ta Xcode Command Line
# Tools, Linux'ta genelde `build-essential`/`gcc` İLE ZATEN gelir).

set -euo pipefail

REPO="mburakmmm/nox-lang"
INSTALL_DIR="${NOX_INSTALL_DIR:-$HOME/.nox-lang}"

log() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1" >&2; }
die() {
    printf '\033[1;31mhata:\033[0m %s\n' "$1" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || die "curl bulunamadı — kurulum için gerekli."
command -v tar >/dev/null 2>&1 || die "tar bulunamadı — kurulum için gerekli."

detect_asset() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os" in
        Darwin)
            case "$arch" in
                arm64) echo "macos-arm64" ;;
                *) die "Desteklenmeyen macOS mimarisi: $arch (yalnızca Apple Silicon/arm64 önceden derlenmiş paket sağlanır — Intel Mac için kaynaktan derleyin: bkz. CONTRIBUTING.md)." ;;
            esac
            ;;
        Linux)
            case "$arch" in
                x86_64) echo "linux-x64" ;;
                aarch64 | arm64) echo "linux-arm64" ;;
                *) die "Desteklenmeyen Linux mimarisi: $arch" ;;
            esac
            ;;
        *)
            die "Desteklenmeyen işletim sistemi: $os (Windows için kaynaktan derleyin: bkz. CONTRIBUTING.md)."
            ;;
    esac
}

resolve_version() {
    if [ -n "${NOX_VERSION:-}" ]; then
        echo "$NOX_VERSION"
        return
    fi
    local tag
    tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
    [ -n "$tag" ] || die "en son sürüm etiketi çözülemedi (GitHub API erişilemez olabilir) — NOX_VERSION ile elle belirtin."
    echo "$tag"
}

ASSET="$(detect_asset)"
VERSION="$(resolve_version)"
STAGE="nox-lang-${VERSION}-${ASSET}"
URL="https://github.com/${REPO}/releases/download/${VERSION}/${STAGE}.tar.gz"

log "Nox ${VERSION} (${ASSET}) indiriliyor..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
curl -fsSL -o "$TMP_DIR/${STAGE}.tar.gz" "$URL" || die "indirilemedi: $URL"

log "Açılıyor -> ${INSTALL_DIR}"
rm -rf "${INSTALL_DIR:?}"
mkdir -p "$INSTALL_DIR"
tar xzf "$TMP_DIR/${STAGE}.tar.gz" -C "$TMP_DIR"
cp -R "$TMP_DIR/${STAGE}/." "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bin/"*

if ! command -v cc >/dev/null 2>&1; then
    warn "'cc' (C derleyicisi) bulunamadı — noxc DERLENEN programları linklerken buna ihtiyaç duyar."
    warn "macOS: xcode-select --install   |   Debian/Ubuntu: sudo apt install build-essential"
fi

log "Kuruldu: ${INSTALL_DIR}"

SHELL_RC=""
case "${SHELL:-}" in
    */zsh) SHELL_RC="$HOME/.zshrc" ;;
    */bash) SHELL_RC="$HOME/.bashrc" ;;
esac

PATH_LINE="export PATH=\"$INSTALL_DIR/bin:\$PATH\""
if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ] && ! grep -qF "$INSTALL_DIR/bin" "$SHELL_RC" 2>/dev/null; then
    printf '\n# Nox (nox-lang)\n%s\n' "$PATH_LINE" >>"$SHELL_RC"
    log "PATH, ${SHELL_RC} dosyasına eklendi — yeni bir terminal açın ya da şunu çalıştırın:"
else
    log "PATH'e eklemek için shell yapılandırmanıza şunu ekleyin:"
fi
printf '\n    %s\n\n' "$PATH_LINE"
log "Doğrulama: noxc --version   (yeni bir terminalde, ya da yukarıdaki komutu çalıştırdıktan sonra)"
