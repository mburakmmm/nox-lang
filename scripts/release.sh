#!/usr/bin/env bash
# Sürüm kapısı: etiket (tag) YALNIZCA tüm kontroller geçtikten SONRA oluşturulur ve itilir.
# Sıra (v2.0 hazırlık maddesi 8): sürüm tutarlılığı -> zig fmt -> zig build -> zig build test ->
# QBE/LLVM fark testi -> (isteğe bağlı) yoğun testler -> tag -> push. CI (Linux/macOS zorunlu) etiketten
# SONRA `release.yml`in `ci-gate`i tarafından yeniden doğrulanır; kırmızı CI release yayımlamaz.
#
# Kullanım:
#   scripts/release.sh              # sürüm = build.zig.zon, yalnızca kontroller (etiket/itme YOK, kuru koşu)
#   scripts/release.sh --tag        # kontroller yeşilse `vX.Y.Z` etiketler ve `main` + etiketi iter
#   scripts/release.sh --tag --stress   # ek olarak opt-in stres/torture/soak adımlarını çalıştırır
set -euo pipefail
cd "$(dirname "$0")/.."

do_tag=0
do_stress=0
for a in "$@"; do
    case "$a" in
        --tag) do_tag=1 ;;
        --stress) do_stress=1 ;;
        *) echo "bilinmeyen bayrak: $a" >&2; exit 2 ;;
    esac
done

fail() { echo "SÜRÜM KAPISI KIRMIZI: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

step "1/7 sürüm tutarlılığı"
version="$(grep -o '\.version = "[^"]*"' build.zig.zon | sed -E 's/\.version = "([^"]*)"/\1/')"
[ -n "$version" ] || fail "build.zig.zon'da .version yok"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail "geçersiz semver: $version"
grep -q "^## \[$version\]" CHANGELOG.md || fail "CHANGELOG.md'de '## [$version]' bölümü yok"
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then fail "v$version etiketi zaten var"; fi
[ -z "$(git status --porcelain)" ] || fail "çalışma ağacı temiz değil (önce commit edin)"
echo "sürüm: $version"

step "2/7 zig fmt --check"
zig fmt --check compiler runtime tests build.zig || fail "zig fmt"

step "3/7 zig build"
zig build || fail "zig build"

step "4/7 zig build test (IR anlık görüntüleri değişirse ilk koşu onları yeniden üretir, ikinci koşu doğrular)"
zig build test --summary all || fail "zig build test"
[ -z "$(git status --porcelain tests/golden/ir_snapshots)" ] || fail "IR anlık görüntüleri değişti; inceleyip commit edin"

step "5/7 QBE/LLVM fark testi"
zig build backend-differential-corpus-test || fail "backend fark testi"

if [ "$do_stress" = 1 ]; then
    step "6/7 yoğun testler (opt-in)"
    zig build stress-test || fail "stress-test"
    zig build concurrency-torture-test || fail "concurrency-torture-test"
    zig build concurrency-torture2-test || fail "concurrency-torture2-test"
    zig build http-soak-test || fail "http-soak-test"
else
    step "6/7 yoğun testler ATLANDI (--stress ile çalıştırın)"
fi

step "7/7 etiket"
if [ "$do_tag" = 1 ]; then
    git tag "v$version"
    git push origin main
    git push origin "v$version"
    echo "v$version etiketlendi ve itildi. release.yml ci-gate, CI yeşil olunca yayımlar."
else
    echo "kuru koşu: tüm kontroller yeşil. Etiketlemek için: scripts/release.sh --tag"
fi
