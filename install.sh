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
    printf '\033[1;31merror:\033[0m %s\n' "$1" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || die "curl not found — it is required for installation."
command -v tar >/dev/null 2>&1 || die "tar not found — it is required for installation."

detect_asset() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "$os" in
        Darwin)
            case "$arch" in
                arm64) echo "macos-arm64" ;;
                *) die "Unsupported macOS architecture: $arch (a prebuilt package is provided only for Apple silicon/arm64 — on an Intel Mac, build from source: see https://noxlang.com/docs/internals/contributing/)." ;;
            esac
            ;;
        Linux)
            case "$arch" in
                x86_64) echo "linux-x64" ;;
                aarch64 | arm64) echo "linux-arm64" ;;
                *) die "Unsupported Linux architecture: $arch" ;;
            esac
            ;;
        *)
            die "Unsupported operating system: $os (on Windows use install.ps1: irm https://noxlang.com/install.ps1 | iex)."
            ;;
    esac
}

resolve_version() {
    if [ -n "${NOX_VERSION:-}" ]; then
        echo "$NOX_VERSION"
        return
    fi
    # `set -e`/`pipefail` AKTİFKEN `curl | grep | sed` ZİNCİRİ, `grep`
    # HİÇBİR ŞEY BULAMAZSA (ör. henüz hiç Release YOKSA, YA DA API'ye
    # erişilemiyorsa) betiği AŞAĞIDAKİ `die` ÇAĞRISINA HİÇ ULAŞMADAN,
    # SESSİZCE/anlaşılmaz bir hatayla SONLANDIRIR — GERÇEK bir kurulum
    # denemesinde BULUNDU (kullanıcı raporu). Düzeltme: yanıtı ÖNCE
    # AYRI bir değişkene AL (`|| true` İLE pipefail'İ ETKİSİZLEŞTİR),
    # SONRA ayrıştır — böylece boş/bulunamayan sonuç HER ZAMAN
    # `die`in AÇIK/YARDIMCI mesajına ULAŞIR.
    local response tag
    response="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)"
    tag="$(printf '%s' "$response" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)"
    [ -n "$tag" ] || die "could not resolve the latest release tag — no GitHub Release may have been published yet, or the GitHub API is unreachable. To install a specific version by hand: NOX_VERSION=v1.0.0 sh install.sh (or set NOX_VERSION=... on the shell that runs it)."
    echo "$tag"
}

ASSET="$(detect_asset)"
VERSION="$(resolve_version)"
STAGE="nox-lang-${VERSION}-${ASSET}"
URL="https://github.com/${REPO}/releases/download/${VERSION}/${STAGE}.tar.gz"

log "Downloading Nox ${VERSION} (${ASSET})..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
curl -fsSL -o "$TMP_DIR/${STAGE}.tar.gz" "$URL" || die "download failed: $URL"

log "Unpacking -> ${INSTALL_DIR}"
rm -rf "${INSTALL_DIR:?}"
mkdir -p "$INSTALL_DIR"
tar xzf "$TMP_DIR/${STAGE}.tar.gz" -C "$TMP_DIR"
cp -R "$TMP_DIR/${STAGE}/." "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bin/"*

if ! command -v cc >/dev/null 2>&1; then
    warn "'cc' (a C compiler) not found — noxc needs it to link the programs it compiles."
    warn "macOS: xcode-select --install   |   Debian/Ubuntu: sudo apt install build-essential"
fi

log "Installed: ${INSTALL_DIR}"

SHELL_RC=""
case "${SHELL:-}" in
    */zsh) SHELL_RC="$HOME/.zshrc" ;;
    */bash) SHELL_RC="$HOME/.bashrc" ;;
esac

PATH_LINE="export PATH=\"$INSTALL_DIR/bin:\$PATH\""
if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ] && ! grep -qF "$INSTALL_DIR/bin" "$SHELL_RC" 2>/dev/null; then
    printf '\n# Nox (nox-lang)\n%s\n' "$PATH_LINE" >>"$SHELL_RC"
    log "PATH was added to ${SHELL_RC} — open a new terminal or run:"
else
    log "To add it to your PATH, add this to your shell configuration:"
fi
printf '\n    %s\n\n' "$PATH_LINE"
log "Verify with: noxc --version   (in a new terminal, or after running the command above)"
