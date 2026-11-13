#!/usr/bin/env python3
"""yyjson kabul testi + kıyas (TODO 3.4/5.1 F5, v2.1.105): `noxc bindgen` ile yyjson.h'den binding üretir, aynı belgede nox.json, yyjson (Nox binding), yyjson (C) ve
CPython json'u kıyaslar. Sağlama toplamları EŞİT olmalıdır (aksi halde çıkış kodu 1). Kullanım: benchmarks/yyjson/run.py [--backend llvm|qbe] [--repeat N]
Ölçüm için `zig build -Doptimize=ReleaseFast` ile derlenmiş noxc/çalışma zamanı gerekir."""
import argparse, os, statistics, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))
NOXC = ROOT + "/zig-out/bin/noxc"


def sh(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(1)
    return r.stdout


def parse(out):
    res = {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) == 3:
            res[p[0]] = (float(p[1]), p[2])
    return res


ap = argparse.ArgumentParser()
ap.add_argument("--backend", default="llvm")
ap.add_argument("--repeat", type=int, default=3)
a = ap.parse_args()
with tempfile.TemporaryDirectory() as d:
    sh(["cc", "-O2", "-fPIC", "-c", HERE + "/yyjson.c", "-o", d + "/yyjson.o"])
    sh([NOXC, "bindgen", HERE + "/yyjson.h", "--lib", d + "/yyjson.o", "--prefix", "yyjson", "-o", d + "/yyjson.nox", "--shim", d + "/yyjson_shim.c", "--shim-lib", d + "/yyjson_shim.o"])
    binding = open(d + "/yyjson.nox").read()
    bench = open(HERE + "/bench.nox").read()
    # `import` satırları dosyanın başında kalmalı: bench'in importlarını öne al
    imports = "".join(l + "\n" for l in bench.splitlines() if l.startswith("import "))
    body = "\n".join(l for l in bench.splitlines() if not l.startswith("import "))
    open(d + "/all.nox", "w").write(imports + binding + "\n" + body + "\n")
    sh([NOXC, "build", "--backend", a.backend, d + "/all.nox", "-o", d + "/bench_nox"])
    sh(["cc", "-O2", "-I", HERE, HERE + "/bench.c", HERE + "/yyjson.c", "-o", d + "/bench_c"])
    runs = []
    for _ in range(a.repeat):
        res = {}
        res.update(parse(sh([d + "/bench_nox"])))
        res.update(parse(sh([d + "/bench_c"])))
        res.update(parse(sh([sys.executable, HERE + "/bench.py"])))
        runs.append(res)
names = list(runs[0].keys())
rows = []
for n in names:
    rows.append((n, statistics.median(r[n][0] for r in runs), runs[0][n][1]))
print(f"{'benchmark':40s} {'ms/rep':>10s}  checksum")
for n, ms, ck in rows:
    print(f"{n:40s} {ms:10.2f}  {ck}")
bad = 0
for kind in ("parse+walk", "parse+write"):
    checks = {ck for n, _, ck in rows if n.startswith(kind)}
    # parse+write: nox.json ve python boşluksuz yazar; yyjson da -> uzunluklar eşit olmalı
    if len(checks) != 1:
        print(f"SAĞLAMA UYUŞMAZLIĞI ({kind}): {sorted(checks)}")
        bad = 1
sys.exit(bad)
