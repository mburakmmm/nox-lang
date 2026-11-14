#!/usr/bin/env python3
"""nox.regex / nox.pcre2 (yorumlayıcı, JIT) / C PCRE2 / CPython re kıyası. Eşleşme sayıları (sağlama) EŞİT olmalıdır. Kullanım: NOXC=<noxc> benchmarks/pcre2/run.py [--repeat N]
Ölçüm için `zig build -Doptimize=ReleaseFast` ile derlenmiş noxc gerekir."""
import argparse, glob, os, statistics, subprocess, sys, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))
NOXC = os.environ.get("NOXC", ROOT + "/zig-out/bin/noxc")
def sh(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.stderr.write(r.stdout + r.stderr); sys.exit(1)
    return r.stdout
def parse(out):
    res = {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) == 3: res[p[0]] = (float(p[1]), p[2])
    return res
ap = argparse.ArgumentParser(); ap.add_argument("--repeat", type=int, default=3); a = ap.parse_args()
src = ROOT + "/third_party/pcre2"
files = [f for f in sorted(glob.glob(src + "/src/pcre2_*.c"))]
flags = ["-O2", "-DHAVE_CONFIG_H", "-DPCRE2_CODE_UNIT_WIDTH=8", "-DSUPPORT_PCRE2_8", "-DSUPPORT_UNICODE", "-DSUPPORT_JIT", "-DPCRE2_STATIC", "-I", src + "/src", "-I", src + "/deps/sljit"]
with tempfile.TemporaryDirectory() as d:
    sh(["cc"] + flags + [HERE + "/bench.c"] + files + ["-o", d + "/bench_c"])
    sh([NOXC, "build", HERE + "/bench.nox", "-o", d + "/bench_nox"])
    runs = []
    for _ in range(a.repeat):
        res = {}
        res.update(parse(sh([d + "/bench_nox"]))); res.update(parse(sh([d + "/bench_c"]))); res.update(parse(sh([sys.executable, HERE + "/bench.py"])))
        runs.append(res)
print(f"{'benchmark':44s} {'ms/rep':>10s}  matches")
for n in runs[0]:
    print(f"{n:44s} {statistics.median(r[n][0] for r in runs):10.2f}  {runs[0][n][1]}")
bad = 0
for kind in ("digits", "words", "email"):
    cks = {v[1] for n, v in runs[0].items() if n.startswith(kind + " count")}
    if len(cks) != 1: print("SAĞLAMA UYUŞMAZLIĞI", kind, sorted(cks)); bad = 1
sys.exit(bad)
