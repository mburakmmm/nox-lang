#!/usr/bin/env python3
"""Tarayıcı derleyicisinin ön yüzünü (`zig-out/lib/noxc-frontend.wasm`, spec §3.353) TÜM `codegen_cases` korpusunda yerel `noxc build --target <hedef>` ile karşılaştırır:
iki yolun ürettiği LLVM IR byte-birebir aynı olmalıdır (ya da ikisi de aynı nedenle reddetmelidir).

Kullanım: scripts/wasm_frontend_corpus.py [--target wasm32-freestanding] [--jobs 8] [filtre]
Önkoşul: `zig build && zig build wasm-compiler`. Çıkış kodu: fark varsa 1.
"""
import argparse
import concurrent.futures as cf
import glob
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES = os.path.join(ROOT, "tests/golden/codegen_cases")
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
FRONTEND = os.path.join(ROOT, "zig-out/lib/noxc-frontend.wasm")
DRIVER = os.path.join(ROOT, "tests/golden/wasm_frontend_driver.mjs")


def one(args, work, case):
    name = os.path.basename(case)[:-4]
    d = os.path.join(work, name)
    os.makedirs(d, exist_ok=True)
    src = os.path.join(d, name + ".nox")
    with open(case, "rb") as f, open(src, "wb") as g:
        g.write(f.read())
    out = os.path.join(d, "out.wasm")
    nat = subprocess.run([NOXC, "build", "--target", args.target, src, "-o", out], capture_output=True, text=True)
    ll = os.path.join(d, "out.ll")
    native_ok = os.path.exists(ll)
    fe = subprocess.run(["node", "--no-warnings", DRIVER, FRONTEND, src, args.target], capture_output=True)
    if native_ok and fe.returncode == 0:
        with open(ll, "rb") as f:
            return name, ("same" if f.read() == fe.stdout else "DIFF"), ""
    if not native_ok and fe.returncode != 0:
        # İkisi de reddetti: neden (ilk satır) aynı olmalı.
        n = (nat.stderr.strip().splitlines() or [""])[0]
        f = (fe.stderr.decode().strip().splitlines() or [""])[0]
        return name, ("both-rejected" if n.split(": ", 1)[-1][:60] == f.split(": ", 1)[-1][:60] or "cannot be used" in n else "REJECT-DIFFERS"), f"native={n[:100]!r} frontend={f[:100]!r}"
    return name, "MISMATCH", f"native_ok={native_ok} frontend_rc={fe.returncode} {fe.stderr.decode()[:160]!r}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="wasm32-freestanding")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("filter", nargs="?", default="")
    args = ap.parse_args()
    cases = sorted(c for c in glob.glob(os.path.join(CASES, "*.nox")) if args.filter in os.path.basename(c))
    counts, bad = {}, []
    with tempfile.TemporaryDirectory() as work, cf.ThreadPoolExecutor(args.jobs) as ex:
        for name, status, detail in ex.map(lambda c: one(args, work, c), cases):
            counts[status] = counts.get(status, 0) + 1
            if status in ("DIFF", "MISMATCH", "REJECT-DIFFERS"):
                bad.append((name, status, detail))
    print(f"== {args.target}: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    for name, status, detail in bad:
        print(f"  {status}: {name} {detail}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
