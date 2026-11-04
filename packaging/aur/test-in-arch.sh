#!/bin/bash
# Arch Linux container'ında (archlinux:base-devel) `noxc-bin` paketini GERÇEKTEN derler (makepkg), kurar, çalıştırır ve kaldırır.
# Kullanım (depo kökünden): docker run --rm -e TAG=v2.0.138 -v "$PWD:/w:ro" archlinux:base-devel bash /w/packaging/aur/test-in-arch.sh
set -euo pipefail
: "${TAG:?TAG (ör. v2.0.138) gerekli}"

pacman -Syu --noconfirm --needed git python sudo >/dev/null
useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder

mkdir -p /home/builder/pkg
python3 /w/scripts/update_aur_package.py --tag "$TAG" --outdir /home/builder/pkg
chown -R builder:builder /home/builder/pkg

echo "== makepkg"
sudo -u builder bash -c 'cd /home/builder/pkg && makepkg -s --noconfirm'

echo "== .SRCINFO makepkg çıktısıyla aynı mı"
sudo -u builder bash -c 'cd /home/builder/pkg && makepkg --printsrcinfo > /tmp/srcinfo.generated'
diff /tmp/srcinfo.generated /home/builder/pkg/.SRCINFO

echo "== kur"
pacman -U --noconfirm /home/builder/pkg/noxc-bin-*.pkg.tar.zst
VER="${TAG#v}"
noxc version 2>&1 | tee /dev/stderr | grep -q "noxc $VER"
command -v noxlsp
printf 'print(6 * 7)\n' > /tmp/hello.nox
test "$(noxc run /tmp/hello.nox)" = "42"
test "$(noxc run --backend qbe /tmp/hello.nox)" = "42"

# `noxc upgrade`in pacman koruması 2.0.139'dan itibaren vardır; daha eski bir release üzerinde (ör. bu betiği geçmiş bir sürümle denerken) atlanır.
if [ "$(printf '%s\n' 2.0.139 "$VER" | sort -V | head -n1)" = "2.0.139" ]; then
  echo "== noxc upgrade paketin dosyalarına dokunmaz"
  if noxc upgrade v99.0.0 2> /tmp/upgrade.err; then echo "upgrade başarılı olmamalıydı"; exit 1; fi
  grep -q "installed by pacman" /tmp/upgrade.err
  grep -q "yay -Syu noxc-bin" /tmp/upgrade.err
  test -x /usr/lib/noxc/bin/noxc
else
  echo "== noxc upgrade koruması atlandı ($VER < 2.0.139)"
fi

echo "== kaldır"
pacman -R --noconfirm noxc-bin
test ! -e /usr/lib/noxc
test ! -e /usr/bin/noxc
echo "aur paketi testi: temiz"
