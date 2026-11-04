#!/usr/bin/env python3
"""Snap tarifini (`packaging/snap/snapcraft.yaml.in`) bir GitHub Release'ten üretir: `<outdir>/snap/snapcraft.yaml` + ikon.

Kullanım:
    scripts/update_snap_package.py --tag v2.0.140 --arch amd64|arm64 --outdir /tmp/snapproj [--repo mburakmmm/nox-lang]
    scripts/update_snap_package.py --tag v2.0.140 --arch amd64 --outdir /tmp/snapproj --sha <hex>      (ağsız)

Mimariye özel bir tarif üretir (`build-on` tek mimari; `release.yml` her mimariyi kendi runner'ında derler). Yalnızca kararlı etiketler.
Üretilen dizinde `snapcraft pack --destructive-mode` çalıştırılır (bkz. `.github/workflows/snap.yml`).
"""
import argparse
import os
import re
import shutil
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARCHES = {"amd64": "linux-x64", "arm64": "linux-arm64"}


def fetch_sha(repo, tag, asset):
    url = f"https://github.com/{repo}/releases/download/{tag}/nox-lang-{tag}-{asset}.tar.gz.sha256"
    with urllib.request.urlopen(url, timeout=30) as r:
        text = r.read().decode().strip()
    m = re.match(r"^([0-9a-fA-F]{64})\b", text)
    if not m:
        raise SystemExit(f"{url}: beklenen '<sha256>  <dosya>' biçimi değil: {text!r}")
    return m.group(1).lower()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--arch", required=True, choices=sorted(ARCHES))
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--repo", default="mburakmmm/nox-lang")
    ap.add_argument("--sha", default="")
    a = ap.parse_args()
    if not re.match(r"^v\d+\.\d+\.\d+$", a.tag):
        raise SystemExit(f"yalnızca kararlı sürüm etiketleri (vX.Y.Z) desteklenir: {a.tag}")
    asset = ARCHES[a.arch]
    sha = a.sha or fetch_sha(a.repo, a.tag, asset)
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise SystemExit(f"geçersiz sha256 {sha!r}")
    text = open(os.path.join(ROOT, "packaging/snap/snapcraft.yaml.in")).read()
    text = text.replace("@VERSION@", a.tag[1:]).replace("@SNAP_ARCH@", a.arch).replace("@ASSET@", asset).replace("@SHA@", sha)
    if re.search(r"@[A-Z_]+@", text):
        raise SystemExit("tarifte doldurulmamış bir yer tutucu kaldı")
    os.makedirs(os.path.join(a.outdir, "snap", "gui"), exist_ok=True)
    open(os.path.join(a.outdir, "snap", "snapcraft.yaml"), "w").write(text)
    shutil.copyfile(os.path.join(ROOT, "assets/brand/icon-256.png"), os.path.join(a.outdir, "snap", "gui", "noxc.png"))
    print(f"{a.outdir}: noxc {a.tag[1:]} ({a.arch})", file=sys.stderr)


main()
