#!/usr/bin/env python3
"""stdlib_perf.nox ve stdlib_perf.py'yi çalıştırıp süreleri ve sağlama toplamlarını karşılaştırır. Kullanım: benchmarks/stdlib_perf/run.py [--backend llvm|qbe] [--repeat N]
Ölçüm için `zig build -Doptimize=ReleaseFast` ile derlenmiş noxc/çalışma zamanı gerekir (Debug runtime ~100x yavaştır)."""
import argparse, os, subprocess, sys, tempfile, statistics

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))

def parse(out):
    res = {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) == 3:
            res[p[0]] = (float(p[1]), p[2])
    return res

def run(cmd, timeout=900):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(1)
    return parse(r.stdout)

ap = argparse.ArgumentParser()
ap.add_argument("--backend", default="llvm")
ap.add_argument("--repeat", type=int, default=3)
a = ap.parse_args()
with tempfile.TemporaryDirectory() as d:
    exe = d + "/bench"
    b = subprocess.run([ROOT + "/zig-out/bin/noxc", "build", "--backend", a.backend, HERE + "/stdlib_perf.nox", "-o", exe], capture_output=True, text=True)
    if b.returncode:
        sys.stderr.write(b.stderr)
        sys.exit(1)
    nox_runs = [run([exe]) for _ in range(a.repeat)]
    py_runs = [run([sys.executable, HERE + "/stdlib_perf.py"]) for _ in range(max(1, a.repeat - 1))]
names = list(nox_runs[0].keys())
print(f"{'benchmark':32s} {'nox ms':>9s} {'python ms':>10s} {'nox/py':>7s}  check")
bad = 0
ratios = []
for n in names:
    nm = statistics.median(r[n][0] for r in nox_runs)
    pm = statistics.median(r[n][0] for r in py_runs) if n in py_runs[0] else float("nan")
    nc, pc = nox_runs[0][n][1], py_runs[0].get(n, (0, "?"))[1]
    ok = "ok" if nc == pc or pc == "n/a" else f"MISMATCH nox={nc} py={pc}"
    if ok != "ok" and pc != "n/a":
        bad += 1
    ratio = nm / pm if pm == pm and pm > 0 else float("nan")
    ratios.append(ratio)
    print(f"{n:32s} {nm:9.1f} {pm:10.1f} {ratio:7.2f}  {ok}")
valid = [r for r in ratios if r == r and r > 0]
if valid:
    import math
    print(f"\ngeometrik ortalama nox/python: {math.exp(sum(math.log(r) for r in valid) / len(valid)):.2f}  (1.0 = Python ile aynı; <1 Nox daha hızlı)")
sys.exit(1 if bad else 0)
