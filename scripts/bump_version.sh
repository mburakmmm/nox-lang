#!/usr/bin/env bash
# `build.zig.zon`'un `version` alanını semver kuralına göre artırır (bkz.
# VERSIONING.md "Sürüm Artış Otomasyonu" — HER commit'te bir sürüm artışı +
# git tag + push politikası). `-dev` son eki artık KULLANILMIYOR: her
# commit KENDİ BAŞINA gerçek/tag'lenebilir bir sürümdür, "geliştirme
# aşamasında" ayrı bir ara durum yok.
#
# Kullanım: scripts/bump_version.sh {patch|minor|major}
#   patch — hata düzeltmesi/performans/dokümantasyon (VERSIONING.md §1)
#   minor — geriye dönük UYUMLU yeni özellik (yeni sözdizimi/stdlib/CLI)
#   major — geriye dönük UYUMSUZ bir değişiklik
#
# Yeni sürümü stdout'a yazar (ör. "1.1.1") — çağıran bunu `git tag
# v$(...)` İçin kullanabilir. `-dev` son eki İÇEREN eski bir sürüm
# görürse önce onu ATAR (ör. "1.1.0-dev" -> "1.1.0" temel al, SONRA
# istenen bileşeni artır).

set -euo pipefail

kind="${1:-}"
case "$kind" in
    patch|minor|major) ;;
    *)
        echo "kullanım: $0 {patch|minor|major}" >&2
        exit 1
        ;;
esac

zon_file="$(dirname "$0")/../build.zig.zon"
current="$(grep -o '\.version = "[^"]*"' "$zon_file" | sed -E 's/\.version = "([^"]*)"/\1/')"
[ -n "$current" ] || { echo "build.zig.zon'da .version alanı bulunamadı" >&2; exit 1; }

# `-dev`/herhangi bir `-...` ön-sürüm son ekini at, TEMEL X.Y.Z'yi al.
base="${current%%-*}"
IFS='.' read -r major minor patch <<< "$base"

case "$kind" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
esac

new_version="${major}.${minor}.${patch}"

# macOS (BSD sed) VE Linux (GNU sed) İKİSİNDE de çalışan yerinde düzenleme.
tmp_file="$(mktemp)"
sed -E "s/\.version = \"[^\"]*\"/.version = \"${new_version}\"/" "$zon_file" > "$tmp_file"
mv "$tmp_file" "$zon_file"

echo "$new_version"
