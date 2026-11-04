#!/usr/bin/env python3
"""Homebrew formülünü (`packaging/homebrew/noxc.rb.in`) bir GitHub Release'in `.sha256` varlıklarından üretir.

Kullanım:
    scripts/update_homebrew_formula.py --tag v2.0.136 [--repo mburakmmm/nox-lang] [--out Formula/noxc.rb]
    scripts/update_homebrew_formula.py --tag v2.0.136 --sha macos-arm64=<hex> linux-arm64=<hex> linux-x64=<hex>   (ağsız)

Release'te üç arşivin de (macos-arm64, linux-arm64, linux-x64) bulunması gerekir; biri eksikse hata verilir (kısmi bir formül yayımlanmaz).
`release.yml`nin `homebrew` işi bunu her sürümde çağırır ve çıktıyı `mburakmmm/homebrew-nox` deposuna iter.
"""
import argparse
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = {"macos-arm64": "@SHA_MACOS_ARM64@", "linux-arm64": "@SHA_LINUX_ARM64@", "linux-x64": "@SHA_LINUX_X64@"}


def fetch_sha(repo, tag, asset):
    url = f"https://github.com/{repo}/releases/download/{tag}/nox-lang-{tag}-{asset}.tar.gz.sha256"
    with urllib.request.urlopen(url, timeout=30) as r:
        text = r.read().decode().strip()
    m = re.match(r"^([0-9a-fA-F]{64})\b", text)
    if not m:
        raise SystemExit(f"{url}: beklenen '<sha256>  <dosya>' biçimi değil: {text!r}")
    return m.group(1).lower()


def render(version, shas):
    tpl = open(os.path.join(ROOT, "packaging/homebrew/noxc.rb.in")).read()
    out = tpl.replace("@VERSION@", version)
    for asset, placeholder in ASSETS.items():
        out = out.replace(placeholder, shas[asset])
    if re.search(r"@(VERSION|SHA_[A-Z0-9_]+)@", out):
        raise SystemExit("formülde doldurulmamış bir yer tutucu kaldı")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--repo", default="mburakmmm/nox-lang")
    ap.add_argument("--out", default="-")
    ap.add_argument("--sha", nargs="*", default=[], help="asset=hex (ağ kullanmadan)")
    a = ap.parse_args()

    if not re.match(r"^v\d+\.\d+\.\d+$", a.tag):
        raise SystemExit(f"yalnızca kararlı sürüm etiketleri (vX.Y.Z) desteklenir: {a.tag}")
    version = a.tag[1:]
    shas = dict(kv.split("=", 1) for kv in a.sha)
    for asset in ASSETS:
        if asset not in shas:
            shas[asset] = fetch_sha(a.repo, a.tag, asset)
    for asset, v in shas.items():
        if not re.fullmatch(r"[0-9a-f]{64}", v):
            raise SystemExit(f"{asset}: geçersiz sha256 {v!r}")
    text = render(version, shas)
    if a.out == "-":
        sys.stdout.write(text)
    else:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        open(a.out, "w").write(text)
        print(f"{a.out}: noxc {version}", file=sys.stderr)


main()
