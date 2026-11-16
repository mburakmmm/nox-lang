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
ap.add_argument("--json", default="", help="sonuçları {ad: {nox, c, py}} (ms) olarak bu dosyaya yaz")
ap.add_argument("--suite", type=int, default=1, help="1: stdlib_perf (metin/json/regex/...), 2: stdlib_perf2 (koleksiyon/özet/bigint/toml/...)")
a = ap.parse_args()
with tempfile.TemporaryDirectory() as d:
    exe = d + "/bench"
    b = subprocess.run([ROOT + "/zig-out/bin/noxc", "build", "--backend", a.backend, HERE + f"/stdlib_perf{'' if a.suite == 1 else a.suite}.nox", "-o", exe], capture_output=True, text=True)
    if b.returncode:
        sys.stderr.write(b.stderr)
        sys.exit(1)
    nox_runs = [run([exe]) for _ in range(a.repeat)]
    py_runs = [run([sys.executable, HERE + f"/stdlib_perf{'' if a.suite == 1 else a.suite}.py"]) for _ in range(max(1, a.repeat - 1))]
    # C referansı (ölçüt C): varsa stdlib_perfN.c clang -O2 ile derlenir (Linux'ta OpenSSL için -lcrypto).
    c_runs = []
    c_src = HERE + f"/stdlib_perf{'' if a.suite == 1 else a.suite}.c"
    if os.path.exists(c_src):
        cexe = d + "/bench_c"
        cflags = ["-O2", "-Wno-deprecated-declarations"]
        clibs = ["-lz"] + ([] if sys.platform == "darwin" else ["-lcrypto"])  # kütüphaneler kaynaktan SONRA gelmelidir
        cb = subprocess.run(["clang", *cflags, "-o", cexe, c_src, *clibs], capture_output=True, text=True)
        if cb.returncode == 0:
            c_runs = [run([cexe]) for _ in range(a.repeat)]
        else:
            sys.stderr.write("C referansı derlenemedi:\n" + cb.stderr)
names = list(nox_runs[0].keys())
print(f"{'benchmark':32s} {'nox ms':>9s} {'C ms':>8s} {'python ms':>10s} {'nox/C':>7s} {'nox/py':>7s}  check")
bad = 0
ratios = []
cratios = []
for n in names:
    nm = statistics.median(r[n][0] for r in nox_runs)
    pm = statistics.median(r[n][0] for r in py_runs) if n in py_runs[0] else float("nan")
    nc, pc = nox_runs[0][n][1], py_runs[0].get(n, (0, "?"))[1]
    ok = "ok" if nc == pc or pc == "n/a" else f"MISMATCH nox={nc} py={pc}"
    if ok != "ok" and pc != "n/a":
        bad += 1
    ratio = nm / pm if pm == pm and pm > 0 else float("nan")
    ratios.append(ratio)
    cm = statistics.median(r[n][0] for r in c_runs) if c_runs and n in c_runs[0] else float("nan")
    if c_runs and n in c_runs[0] and c_runs[0][n][1] != nc:
        ok += f" C-MISMATCH c={c_runs[0][n][1]}"
        bad += 1
    cratio = nm / cm if cm == cm and cm > 0 else float("nan")
    cratios.append(cratio)
    print(f"{n:32s} {nm:9.1f} {cm:8.1f} {pm:10.1f} {cratio:7.2f} {ratio:7.2f}  {ok}")
valid = [r for r in ratios if r == r and r > 0]
if valid:
    import math
    print(f"\ngeometrik ortalama nox/python: {math.exp(sum(math.log(r) for r in valid) / len(valid)):.2f}  (1.0 = Python ile aynı; <1 Nox daha hızlı)")
if a.json:
    import json as _json
    dump = {}
    for n in names:
        entry = {"nox": statistics.median(r[n][0] for r in nox_runs)}
        if c_runs and n in c_runs[0]:
            entry["c"] = statistics.median(r[n][0] for r in c_runs)
        if n in py_runs[0]:
            entry["py"] = statistics.median(r[n][0] for r in py_runs)
        dump[n] = entry
    with open(a.json, "w", encoding="utf-8") as fh:
        _json.dump(dump, fh, indent=1, sort_keys=True)
cvalid = [r for r in cratios if r == r and r > 0]
if cvalid:
    import math
    print(f"geometrik ortalama nox/C: {math.exp(sum(math.log(r) for r in cvalid) / len(cvalid)):.2f}  (1.0 = C ile aynı; {len(cvalid)} işte C referansı var)")
sys.exit(1 if bad else 0)
