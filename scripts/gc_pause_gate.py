#!/usr/bin/env python3
"""R2-L (v2.2.60): döngü çözücü (GC) duraklama kapısı — benchmarks/cycle_gc_pause.nox.

Program her döngü yinelemesinin süresini ölçer; en uzun yineleme ≈ en uzun toplama duraklaması. Ölçüm (macOS aarch64, ReleaseFast): ort. ≈ 145 ns/yineleme (±%3), en kötü ≈ 9–10 ms @ 500 bin canlı düğüm.
Eşikler CI koşucusu yavaşlığı için cömerttir (ort. ≤ 400 ns, en kötü ≤ 40 ms): bir algoritmik gerileme (ör. toplayıcının her yinelemede çalışması, paralel yolun bozulması) bunu aşar.
Gerekli: ReleaseFast `zig-out/bin/noxc` + çalışma zamanı.   Kullanım: python3 scripts/gc_pause_gate.py
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
SRC = os.path.join(ROOT, "benchmarks/cycle_gc_pause.nox")
MAX_AVG_NS = 400
MAX_WORST_US = 40000


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        exe = os.path.join(tmp, "gcp")
        b = subprocess.run([NOXC, "build", SRC, "-o", exe], capture_output=True, text=True)
        if b.returncode != 0:
            print(b.stdout + b.stderr)
            return 2
        out = subprocess.run([exe], capture_output=True, text=True, timeout=600)
    bad = 0
    rows = re.findall(r"live (\d+) iters (\d+) worst_us (\d+) over1ms (\d+) avg_ns (\d+)", out.stdout)
    if not rows:
        print("gc_pause_gate: çıktı çözümlenemedi:\n" + out.stdout + out.stderr)
        return 2
    for live, iters, worst, over, avg in rows:
        ok = int(avg) <= MAX_AVG_NS and int(worst) <= MAX_WORST_US
        print(f"live={live:>7} worst_us={worst:>6} over1ms={over} avg_ns={avg:>4}  {'tamam' if ok else 'GERİLEME'}")
        bad += 0 if ok else 1
    print(f"gc_pause_gate: eşikler ort. ≤ {MAX_AVG_NS} ns, en kötü ≤ {MAX_WORST_US} µs → {'GEÇTİ' if not bad else 'KALDI'}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
