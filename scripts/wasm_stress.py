#!/usr/bin/env python3
"""WASM uzun süreli karma yük testi (Faz 10.9).

`tests/stress/wasm_threads_stress.nox` (kanal fan-in, döngüsel çöp, yarıda bırakılan jeneratörler, `nox.thread` işçileri) önce native derlenip referans çıktı alınır;
sonra her wasm hedefi `--seconds` süresince art arda çalıştırılır ve HER çalıştırmanın çıktısı native ile birebir karşılaştırılır. Bellek sızıntısı, yarış ya da
kilitlenme sessizce geçmez: çıktı farkı, sıfır olmayan çıkış ya da zaman aşımı (`--timeout`) hata sayılır. Ardından tek bir büyük çalıştırma (`--big-rounds`) bellek
büyümesini zorlar (wasm belleği tavanı 1 GiB'dir; sızıntı varsa çöker).

Kullanım:
  scripts/wasm_stress.py [--seconds 60] [--rounds 40] [--big-rounds 1500] [--targets wasm32-wasi-threads,wasm32-freestanding-threads,...]

Çıkış kodu: herhangi bir fark/zaman aşımı varsa 1.
"""
import argparse
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
SRC = os.path.join(ROOT, "tests/stress/wasm_threads_stress.nox")
HOST = os.path.join(ROOT, "compiler/wasm_host.mjs")
DEFAULT_TARGETS = "wasm32-wasi-threads,wasm32-freestanding-threads,wasm32-wasi-asyncify,wasm32-freestanding-asyncify"


def run_native(work, rounds):
    exe = os.path.join(work, "native")
    if not os.path.exists(exe):
        subprocess.run([NOXC, "build", SRC, "-o", exe], check=True, capture_output=True, cwd=work)
    p = subprocess.run([exe], capture_output=True, text=True, timeout=600, input=f"{rounds}\n")
    if p.returncode != 0:
        sys.exit(f"native çalıştırma başarısız: {p.stderr[-300:]}")
    return p.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--rounds", type=int, default=40)
    ap.add_argument("--big-rounds", type=int, default=1500)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--targets", default=DEFAULT_TARGETS)
    args = ap.parse_args()
    failed = False
    with tempfile.TemporaryDirectory(prefix="nox-wasm-stress-") as work:
        ref = run_native(work, args.rounds)
        ref_big = run_native(work, args.big_rounds)
        for target in args.targets.split(","):
            wasm = os.path.join(work, target + ".wasm")
            b = subprocess.run([NOXC, "build", "--target", target, SRC, "-o", wasm], capture_output=True, text=True, cwd=work)
            if b.returncode != 0:
                print(f"== {target}: DERLEME HATASI: {b.stderr[-300:]}")
                failed = True
                continue
            runs, deadline, start = 0, time.time() + args.seconds, time.time()
            ok = True
            while time.time() < deadline:
                try:
                    p = subprocess.run(["node", "--no-warnings", HOST, wasm], capture_output=True, text=True, timeout=args.timeout, input=f"{args.rounds}\n")
                except subprocess.TimeoutExpired:
                    print(f"== {target}: ZAMAN AŞIMI (çalıştırma {runs + 1})")
                    ok = False
                    break
                runs += 1
                if p.returncode != 0 or p.stdout != ref:
                    print(f"== {target}: FARK (çalıştırma {runs}) çıkış={p.returncode}\n  beklenen: {ref!r}\n  gelen:    {p.stdout!r}\n  stderr: {p.stderr[-300:]}")
                    ok = False
                    break
            if ok:
                t0 = time.time()
                try:
                    p = subprocess.run(["node", "--no-warnings", HOST, wasm], capture_output=True, text=True, timeout=args.timeout * 4, input=f"{args.big_rounds}\n")
                    if p.returncode != 0 or p.stdout != ref_big:
                        print(f"== {target}: BÜYÜK ÇALIŞTIRMADA FARK çıkış={p.returncode}\n  beklenen: {ref_big!r}\n  gelen:    {p.stdout!r}\n  stderr: {p.stderr[-300:]}")
                        ok = False
                except subprocess.TimeoutExpired:
                    print(f"== {target}: BÜYÜK ÇALIŞTIRMADA ZAMAN AŞIMI")
                    ok = False
                big = time.time() - t0
            if ok:
                print(f"== {target}: TAMAM — {runs} çalıştırma x {args.rounds} tur ({time.time() - start - big:.0f} sn) + 1 x {args.big_rounds} tur ({big:.0f} sn), hepsi native ile aynı")
            failed = failed or not ok
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
