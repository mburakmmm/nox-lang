#!/usr/bin/env python3
"""FFI maliyet karşılaştırması: Nox (LLVM, QBE) vs C tabanı vs Python ctypes; ns/çağrı. Kullanım: benchmarks/ffi_perf/run.py [--repeat N]
Gerekli: cc, ReleaseFast noxc/çalışma zamanı (`zig build -Doptimize=ReleaseFast`). Sağlama toplamları Nox ile C arasında eşleşmelidir."""
import argparse, ctypes, os, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

def parse(out):
    d = {}
    for l in out.splitlines():
        p = l.split("\t")
        if len(p) == 3:
            d[p[0]] = (float(p[1]), p[2])
    return d

def sh(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(1)
    return r.stdout

ap = argparse.ArgumentParser()
ap.add_argument("--repeat", type=int, default=3)
a = ap.parse_args()
with tempfile.TemporaryDirectory() as d:
    sh(["cc", "-O2", "-c", HERE + "/ffi_bench.c", "-o", d + "/ffi_bench.o"])
    sh(["cc", "-O2", "-shared", "-fPIC", HERE + "/ffi_bench.c", "-o", d + "/libffi_bench.so"])
    sh(["cc", "-O2", HERE + "/harness.c", d + "/ffi_bench.o", "-o", d + "/harness_c"])
    exes = {}
    for be in ("llvm", "qbe"):
        sh([ROOT + "/zig-out/bin/noxc", "build", "--backend", be, HERE + "/ffi_perf.nox", "-o", d + "/nox_" + be], cwd=d)
        exes[be] = d + "/nox_" + be
    res = {"c": [], "llvm": [], "qbe": []}
    for _ in range(a.repeat):
        res["c"].append(parse(sh([d + "/harness_c"])))
        for be in ("llvm", "qbe"):
            res[be].append(parse(sh([exes[be]], cwd=d)))
    # Python ctypes: aynı çağrılar, az yineleme (ns/çağrı).
    lib = ctypes.CDLL(d + "/libffi_bench.so")
    lib.c_add.argtypes = [ctypes.c_int64, ctypes.c_int64]; lib.c_add.restype = ctypes.c_int64
    lib.c_fmul.argtypes = [ctypes.c_double, ctypes.c_double]; lib.c_fmul.restype = ctypes.c_double
    lib.c_first.argtypes = [ctypes.c_char_p]; lib.c_first.restype = ctypes.c_int64
    M = 1000000
    def pyt(fn):
        best = 1e18
        for _ in range(a.repeat):
            t = time.perf_counter(); fn(); best = min(best, (time.perf_counter() - t) * 1e9 / M)
        return best
    def f_add():
        add = lib.c_add
        for i in range(M): add(i, 1)
    def f_mul():
        mul = lib.c_fmul; x = 1.0
        for i in range(M): x = mul(x, 1.0000001)
    s = b"a" * 1024
    def f_first():
        first = lib.c_first
        for i in range(M): first(s)
    py = {"ffi_scalar_int": pyt(f_add), "ffi_scalar_float": pyt(f_mul), "ffi_str_arg_1KB": pyt(f_first)}
def med(runs, n): return statistics.median(r[n][0] for r in runs) if n in runs[0] else float("nan")
names = list(res["llvm"][0].keys())
print(f"{'benchmark (ns/çağrı)':26s} {'C':>9s} {'Nox LLVM':>9s} {'Nox QBE':>9s} {'ctypes':>9s}  Nox/C  check")
bad = 0
for n in names:
    c, l, q = med(res["c"], n), med(res["llvm"], n), med(res["qbe"], n)
    chk_n = res["llvm"][0][n][1]; chk_c = res["c"][0].get(n, (0, None))[1]
    ok = "ok" if chk_c in (None, chk_n) or n.startswith("nox_") else f"MISMATCH nox={chk_n} c={chk_c}"
    if ok != "ok": bad += 1
    pc = f"{py[n]:9.1f}" if n in py else f"{'-':>9s}"
    ratio = f"{l / c:6.2f}" if c == c and c > 0 else f"{'-':>6s}"
    print(f"{n:26s} {c:9.2f} {l:9.2f} {q:9.2f} {pc}  {ratio}  {ok}")
sys.exit(1 if bad else 0)
