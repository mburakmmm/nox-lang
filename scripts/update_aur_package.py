#!/usr/bin/env python3
"""AUR paketini (`packaging/aur/PKGBUILD.in`) bir GitHub Release'in `.sha256` varlıklarından üretir: PKGBUILD ve .SRCINFO.

Kullanım:
    scripts/update_aur_package.py --tag v2.0.138 --outdir /tmp/aur [--repo mburakmmm/nox-lang]
    scripts/update_aur_package.py --tag v2.0.138 --outdir /tmp/aur --sha linux-x64=<hex> linux-arm64=<hex>   (ağsız)

İki Linux arşivi de (linux-x64, linux-arm64) release'te bulunmalıdır. `.SRCINFO`, `makepkg --printsrcinfo` çıktısıyla aynı biçimdedir
(AUR yalnızca onu okur); Arch'ta `makepkg --printsrcinfo | diff - .SRCINFO` ile karşılaştırılır (bkz. `.github/workflows/aur.yml`).
`release.yml`nin `aur` işi bunu her kararlı sürümde çağırır ve çıktıyı AUR'a iter.
"""
import argparse
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = {"linux-x64": "@SHA_LINUX_X64@", "linux-arm64": "@SHA_LINUX_ARM64@"}
REPO_URL = "https://github.com/mburakmmm/nox-lang/releases/download"


def fetch_sha(repo, tag, asset):
    url = f"https://github.com/{repo}/releases/download/{tag}/nox-lang-{tag}-{asset}.tar.gz.sha256"
    with urllib.request.urlopen(url, timeout=30) as r:
        text = r.read().decode().strip()
    m = re.match(r"^([0-9a-fA-F]{64})\b", text)
    if not m:
        raise SystemExit(f"{url}: beklenen '<sha256>  <dosya>' biçimi değil: {text!r}")
    return m.group(1).lower()


def pkgbuild(version, shas):
    out = open(os.path.join(ROOT, "packaging/aur/PKGBUILD.in")).read().replace("@VERSION@", version)
    for asset, placeholder in ASSETS.items():
        out = out.replace(placeholder, shas[asset])
    if re.search(r"@(VERSION|SHA_[A-Z0-9_]+)@", out):
        raise SystemExit("PKGBUILD'de doldurulmamış bir yer tutucu kaldı")
    return out


def srcinfo(version, shas):
    def src(asset):
        return f"nox-lang-v{version}-{asset}.tar.gz::{REPO_URL}/v{version}/nox-lang-v{version}-{asset}.tar.gz"

    lines = [
        "pkgbase = noxc-bin",
        "\tpkgdesc = Compiler and project tool for the Nox programming language (prebuilt release)",
        f"\tpkgver = {version}",
        "\tpkgrel = 1",
        "\turl = https://noxlang.com",
        "\tarch = x86_64",
        "\tarch = aarch64",
        "\tlicense = MIT",
        "\tdepends = glibc",
        "\tdepends = gcc",
        "\toptdepends = clang: default LLVM back end (faster generated code)",
        "\toptdepends = zig: alternative C toolchain for linking and cross targets",
        "\tprovides = noxc",
        "\tconflicts = noxc",
        "\toptions = !strip",
        f"\tsource_x86_64 = {src('linux-x64')}",
        f"\tsha256sums_x86_64 = {shas['linux-x64']}",
        f"\tsource_aarch64 = {src('linux-arm64')}",
        f"\tsha256sums_aarch64 = {shas['linux-arm64']}",
        "",
        "pkgname = noxc-bin",
        "",
    ]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--repo", default="mburakmmm/nox-lang")
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--sha", nargs="*", default=[], help="asset=hex (ağ kullanmadan)")
    a = ap.parse_args()
    if not re.match(r"^v\d+\.\d+\.\d+$", a.tag):
        raise SystemExit(f"yalnızca kararlı sürüm etiketleri (vX.Y.Z) desteklenir: {a.tag}")
    version = a.tag[1:]
    shas = dict(kv.split("=", 1) for kv in a.sha)
    for asset in ASSETS:
        if asset not in shas:
            shas[asset] = fetch_sha(a.repo, a.tag, asset)
        if not re.fullmatch(r"[0-9a-f]{64}", shas[asset]):
            raise SystemExit(f"{asset}: geçersiz sha256 {shas[asset]!r}")
    os.makedirs(a.outdir, exist_ok=True)
    open(os.path.join(a.outdir, "PKGBUILD"), "w").write(pkgbuild(version, shas))
    open(os.path.join(a.outdir, ".SRCINFO"), "w").write(srcinfo(version, shas))
    print(f"{a.outdir}: noxc-bin {version}", file=sys.stderr)


main()
