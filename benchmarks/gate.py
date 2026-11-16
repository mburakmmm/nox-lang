#!/usr/bin/env python3
"""Performans regresyon kapısı (2.2 aşama 12): dil çekirdeği (`lang_perf`) ve stdlib ölçüm kümelerini (`stdlib_perf` 1 ve 2) çalıştırır, taban çizgisiyle karşılaştırır.

  benchmarks/gate.py --check              # taban çizgisine göre `--tolerance` (varsayılan %35) üstü yavaşlayan iş varsa çıkış kodu 1
  benchmarks/gate.py --update             # stdlib taban çizgisini bu makinedeki ölçümle yazar (bilinçli; gözden geçirilerek commit'lenir)
  benchmarks/gate.py --check --repeat 5   # gürültüyü azaltmak için daha çok tekrar

Taban çizgisi MAKİNEDEN BAĞIMSIZ tutulur: C karşılığı olan işler Nox/C ORANI olarak (ölçüt C), olmayanlar ms olarak (yalnızca aynı makinede anlamlı). `lang_perf` kendi taban çizgisini (`lang_perf/baseline.json`) kullanır.
Ek korkuluk: Nox/C oranı `--c-ratio-max` (varsayılan 40x) üstündeki her iş hata sayılır. `--min-ms` altındaki işler gürültü sayılır.
Gerekli: ReleaseFast `zig build -Doptimize=ReleaseFast` (Debug çalışma zamanı ~100x yavaştır; tam test koşusu `zig-out`u Debug yapar, ölçümden önce yeniden kurun)."""
import argparse, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BASELINE = os.path.join(HERE, "baseline.json")
SUITES = [1, 2]

ap = argparse.ArgumentParser()
g = ap.add_mutually_exclusive_group(required=True)
g.add_argument("--check", action="store_true")
g.add_argument("--update", action="store_true")
ap.add_argument("--repeat", type=int, default=3)
ap.add_argument("--tolerance", type=float, default=0.35, help="izin verilen göreli yavaşlama (0.35 = yüzde 35)")
ap.add_argument("--c-ratio-max", type=float, default=40.0)
ap.add_argument("--min-ms", type=float, default=1.0)
ap.add_argument("--no-lang", action="store_true", help="lang_perf kapısını atla")
a = ap.parse_args()

results = {}
for suite in SUITES:
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "r.json")
        r = subprocess.run([sys.executable, os.path.join(HERE, "stdlib_perf", "run.py"), "--suite", str(suite), "--repeat", str(a.repeat), "--json", out],
                           capture_output=True, text=True)
        if not os.path.exists(out):
            sys.stderr.write(r.stdout + r.stderr)
            sys.exit(f"suite {suite}: sonuç üretilemedi")
        results.update(json.load(open(out)))

def metric(v):
    """C varsa Nox/C oranı (makineden bağımsız), yoksa Nox ms."""
    if v.get("c") and v["c"] > 0:
        return "ratio", v["nox"] / v["c"]
    return "ms", v["nox"]

if a.update:
    with open(BASELINE, "w", encoding="utf-8") as fh:
        json.dump({k: dict(zip(("kind", "value"), metric(v))) for k, v in results.items()}, fh, indent=1, sort_keys=True)
    print(f"taban çizgisi yazıldı: {BASELINE} ({len(results)} iş)")
    sys.exit(0)

if not os.path.exists(BASELINE):
    sys.exit("taban çizgisi yok: önce `benchmarks/gate.py --update`")
base = json.load(open(BASELINE))
bad = []
print(f"{'iş':34s} {'ölçü':>5s} {'taban':>9s} {'şimdi':>9s} {'oran':>6s} {'nox ms':>8s}")
for name in sorted(results):
    v = results[name]
    kind, now = metric(v)
    b = base.get(name)
    ref = b["value"] if b and b["kind"] == kind else None
    ratio = now / ref if ref and ref > 0 else float("nan")
    flag = ""
    if ref is not None and v["nox"] >= a.min_ms and ratio > 1 + a.tolerance:
        flag = "  YAVAŞLAMA"
        bad.append(f"{name}: {kind} {ref:.2f} -> {now:.2f} (x{ratio:.2f})")
    if kind == "ratio" and v["nox"] >= a.min_ms and now > a.c_ratio_max:
        flag += "  C'DEN ÇOK GERİDE"
        bad.append(f"{name}: C'nin {now:.0f}x'i (sınır {a.c_ratio_max:.0f}x)")
    print(f"{name:34s} {kind:>5s} {ref if ref is not None else float('nan'):9.2f} {now:9.2f} {ratio:6.2f} {v['nox']:8.1f}{flag}")
new = sorted(n for n in results if n not in base)
if new:
    print("\ntaban çizgisinde olmayan yeni işler:", ", ".join(new))

if not a.no_lang:
    lb = os.path.join(HERE, "lang_perf", "baseline.json")
    if os.path.exists(lb):
        r = subprocess.run([sys.executable, os.path.join(HERE, "lang_perf", "run.py"), "--check", lb, "--no-python", "--no-qbe", "--repeat", str(a.repeat)], capture_output=True, text=True)
        print("\n" + r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "")
        if r.returncode != 0:
            bad.append("lang_perf kapısı başarısız (ayrıntı: benchmarks/lang_perf/run.py --check benchmarks/lang_perf/baseline.json)")
if bad:
    print("\nKAPI BAŞARISIZ:")
    for b in bad:
        print(" -", b)
    sys.exit(1)
print("\nkapı geçti")
