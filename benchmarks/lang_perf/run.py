#!/usr/bin/env python3
"""Dil çekirdeği kıyas paketini çalıştırır (TODO 3.5.1): Nox (LLVM ve QBE backend), C (cc -O2) ve Python; sağlama toplamlarını doğrular, ms/ölçek oranlarını yazar.
Kullanım: benchmarks/lang_perf/run.py [--scale N] [--repeat R] [--py-scale M] [--no-python] [--no-qbe] [--json out.json]
Ölçüm için `zig build -Doptimize=ReleaseFast` ile derlenmiş noxc/çalışma zamanı gerekir (Debug runtime ~100x yavaştır). Sağlama toplamı doğrulaması ölçek 1'de yapılır
(üç dil AYNI sağlamayı üretmelidir); zamanlama `--scale` (varsayılan 10) ile yapılır. Python `--py-scale` (varsayılan 1) ile çalışır ve ms/ölçek olarak normalize edilir."""
import argparse, json, math, os, statistics, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")

def parse(out):
    res = {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) == 3:
            res[p[0]] = (float(p[1]), p[2])
    return res

def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(1)
    return parse(r.stdout)

def med(runs, name, scale):
    vals = [r[name][0] for r in runs if name in r]
    return statistics.median(vals) / scale if vals else float("nan")

ap = argparse.ArgumentParser()
ap.add_argument("--scale", type=int, default=10)
ap.add_argument("--repeat", type=int, default=3)
ap.add_argument("--py-scale", type=int, default=1)
ap.add_argument("--no-python", action="store_true")
ap.add_argument("--no-qbe", action="store_true")
ap.add_argument("--json")
ap.add_argument("--save-baseline", help="llvm/c oranlarını (C karşılığı olmayanlar için llvm ms) bu dosyaya yazar")
ap.add_argument("--check", help="baseline dosyasıyla karşılaştırır; --tolerance'dan fazla yavaşlayan çekirdek varsa çıkış kodu 1")
ap.add_argument("--tolerance", type=float, default=1.30)
a = ap.parse_args()

with tempfile.TemporaryDirectory() as d:
    exes = {}
    for backend in ("llvm",) + (() if a.no_qbe else ("qbe",)):
        exe = f"{d}/nox_{backend}"
        b = subprocess.run([NOXC, "build", "--backend", backend, f"{HERE}/lang_perf.nox", "-o", exe], capture_output=True, text=True)
        if b.returncode:
            sys.stderr.write(b.stderr); sys.exit(1)
        exes[backend] = exe
    cexe = f"{d}/c"
    cb = subprocess.run(["cc", "-O2", "-o", cexe, f"{HERE}/lang_perf.c"], capture_output=True, text=True)
    if cb.returncode:
        sys.stderr.write(cb.stderr); sys.exit(1)

    # 1) sağlama doğrulaması (ölçek 1)
    ref_py = run([sys.executable, f"{HERE}/lang_perf.py", "1"]) if not a.no_python else None
    chk = {"c": run([cexe, "1"])}
    for k, e in exes.items():
        chk[f"nox_{k}"] = run([e, "1"])
    bad = 0
    names = list(chk["nox_llvm"].keys())
    for n in names:
        sums = {k: v[n][1] for k, v in chk.items() if n in v}
        if ref_py and n in ref_py:
            sums["python"] = ref_py[n][1]
        if len(set(sums.values())) != 1:
            bad += 1
            print(f"SAĞLAMA UYUŞMAZLIĞI {n}: {sums}")

    # 2) zamanlama
    s = a.scale
    t_nox = {k: [run([e, str(s)]) for _ in range(a.repeat)] for k, e in exes.items()}
    t_c = [run([cexe, str(s)]) for _ in range(a.repeat)]
    t_py = [run([sys.executable, f"{HERE}/lang_perf.py", str(a.py_scale)]) for _ in range(max(1, a.repeat - 1))] if not a.no_python else []

rows = []
hdr = f"{'kernel':26s} {'llvm':>9s} " + ("" if a.no_qbe else f"{'qbe':>9s} ") + f"{'c -O2':>9s} {'python':>9s}  llvm/c  qbe/c  llvm/py   (ms / ölçek)"
print(hdr)
ratios_c, ratios_py, ratios_q = [], [], []
for n in names:
    ll = med(t_nox["llvm"], n, s)
    qb = med(t_nox["qbe"], n, s) if "qbe" in t_nox else float("nan")
    cc = med(t_c, n, s)
    py = med(t_py, n, a.py_scale) if t_py else float("nan")
    rc = ll / cc if cc == cc and cc > 0 else float("nan")
    rq = qb / cc if cc == cc and cc > 0 and qb == qb else float("nan")
    rp = ll / py if py == py and py > 0 else float("nan")
    for lst, r in ((ratios_c, rc), (ratios_q, rq), (ratios_py, rp)):
        if r == r and r > 0:
            lst.append(r)
    rows.append({"kernel": n, "llvm_ms": ll, "qbe_ms": qb, "c_ms": cc, "py_ms": py})
    print(f"{n:26s} {ll:9.2f} " + ("" if a.no_qbe else f"{qb:9.2f} ") + f"{cc:9.2f} {py:9.2f}  {rc:6.2f} {rq:6.2f} {rp:8.3f}")
def gm(xs): return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float("nan")
print(f"\ngeometrik ortalama: llvm/c = {gm(ratios_c):.2f}   qbe/c = {gm(ratios_q):.2f}   llvm/python = {gm(ratios_py):.3f}   (1.0 = eşit; < 1 Nox daha hızlı)")
if a.json:
    json.dump(rows, open(a.json, "w"), indent=1)

def metric(r):
    """Donanımdan bağımsız ölçüt: C karşılığı varsa llvm/c oranı, yoksa llvm ms (aynı makinede karşılaştırılmalı)."""
    return ("ratio", r["llvm_ms"] / r["c_ms"]) if r["c_ms"] == r["c_ms"] and r["c_ms"] > 0 else ("ms", r["llvm_ms"])

if a.save_baseline:
    json.dump({r["kernel"]: dict(zip(("kind", "value"), metric(r))) for r in rows}, open(a.save_baseline, "w"), indent=1)
    print(f"baseline yazıldı: {a.save_baseline}")
regress = 0
if a.check:
    base = json.load(open(a.check))
    print(f"\nbaseline karşılaştırması (tolerans {a.tolerance:.2f}x):")
    for r in rows:
        b = base.get(r["kernel"])
        if not b:
            continue
        kind, val = metric(r)
        if kind != b["kind"] or b["value"] <= 0:
            continue
        rel = val / b["value"]
        flag = "GERİLEME" if rel > a.tolerance else ("iyileşme" if rel < 1 / a.tolerance else "")
        if rel > a.tolerance:
            regress += 1
        if flag:
            print(f"  {r['kernel']:26s} {kind}: {b['value']:.3f} -> {val:.3f}  ({rel:.2f}x) {flag}")
    print("  gerileme yok" if not regress else f"  {regress} çekirdek gerilemiş")
sys.exit(1 if (bad or regress) else 0)
