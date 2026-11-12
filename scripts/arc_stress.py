#!/usr/bin/env python3
"""ARC/ASAP stres düzeneği (TODO 4.5.3): `tests/stress/*.nox` programlarını (tahsis fırtınası, döngüsel yapılar, derin zincir/ağaç, istisna yolları, sözlük churn,
kapanış/jeneratör) derleyip iki ölçekte çalıştırır; tepe RSS ve süreyi ölçer, (1) çıktıların LLVM/QBE/gölge-mod (NOX_FORCE_ARC=1) arasında aynı olduğunu,
(2) tepe RSS'in `tests/stress/baseline.json` tavanını aşmadığını, (3) ölçek büyüdükçe RSS'in sınırsız büyümediğini denetler (bilinen büyüme baseline'da işaretlidir).
Kullanım: scripts/arc_stress.py [--scale N] [--save-baseline] [--no-qbe]   (ReleaseFast ile ölçün; Debug runtime'da sızıntı denetimi için ölçek 1 kullanın)"""
import argparse, glob, json, os, platform, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
STRESS = os.path.join(ROOT, "tests/stress")
PROGRAMS = ["alloc_storm", "cycles", "deep_structures", "exceptions_paths", "dict_churn", "closures_gen"]  # tests/stress içinde başka (ağ/wasm) testler de var
BASE = os.path.join(STRESS, "baseline.json")
ap = argparse.ArgumentParser()
ap.add_argument("--scale", type=int, default=10)
ap.add_argument("--save-baseline", action="store_true")
ap.add_argument("--no-qbe", action="store_true")
ap.add_argument("--tolerance", type=float, default=1.5)
a = ap.parse_args()

def timed_run(exe, scale):
    if platform.system() == "Darwin":
        cmd = ["/usr/bin/time", "-l", exe, str(scale)]
    else:
        cmd = ["/usr/bin/time", "-v", exe, str(scale)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=900, stdin=subprocess.DEVNULL)
    err = r.stderr
    rss = 0.0
    if platform.system() == "Darwin":
        m = re.search(r"(\d+)\s+maximum resident set size", err)
        rss = int(m.group(1)) / 1048576.0 if m else 0.0
        t = re.search(r"([\d.]+)\s+real", err)
    else:
        m = re.search(r"Maximum resident set size \(kbytes\): (\d+)", err)
        rss = int(m.group(1)) / 1024.0 if m else 0.0
        t = re.search(r"Elapsed.*: (?:(\d+):)?(\d+):([\d.]+)", err)
    secs = float(t.group(1)) if (t and platform.system() == "Darwin") else 0.0
    return r.returncode, r.stdout, rss, secs

def build(src, exe, backend, env_extra=None):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    b = subprocess.run([NOXC, "build", "--backend", backend, src, "-o", exe], capture_output=True, text=True, env=env, timeout=600)
    if b.returncode:
        sys.exit(f"derleme hatası {src}: {b.stderr[:300]}")

base = json.load(open(BASE)) if os.path.exists(BASE) and not a.save_baseline else {}
results, problems = {}, 0
with tempfile.TemporaryDirectory() as d:
    print(f"{'program':20s} {'süre s':>8s} {'RSS MB':>8s} {'RSS@2x':>8s} {'büyüme':>7s}  durum")
    for name in PROGRAMS:
        src = os.path.join(STRESS, name + ".nox")
        exe = os.path.join(d, name)
        build(src, exe, "llvm")
        rc, out, rss, secs = timed_run(exe, a.scale)
        rc2, out2, rss2, _ = timed_run(exe, a.scale * 2)
        status = []
        if rc != 0:
            status.append(f"ÇIKIŞ {rc}")
        # çıktı eşitliği: qbe ve gölge mod
        exe_arc = os.path.join(d, name + "_arc")
        build(src, exe_arc, "llvm", {"NOX_FORCE_ARC": "1"})
        rca, outa, _, _ = timed_run(exe_arc, a.scale)
        if outa != out:
            status.append("GÖLGE-MOD FARKI")
        if not a.no_qbe:
            exe_q = os.path.join(d, name + "_qbe")
            build(src, exe_q, "qbe")
            rcq, outq, _, _ = timed_run(exe_q, a.scale)
            if outq != out:
                status.append("QBE FARKI")
        growth = rss2 / rss if rss > 0 else 1.0
        b = base.get(name, {})
        if b:
            if rss > b["rss_mb"] * a.tolerance + 2:
                status.append(f"RSS TAVANI AŞILDI (taban {b['rss_mb']:.1f} MB)")
            if growth > 1.5 and rss2 > 32 and not b.get("known_growth"):
                status.append("BEKLENMEDİK BÜYÜME")
        results[name] = {"rss_mb": rss, "rss_2x_mb": rss2, "known_growth": bool(b.get("known_growth", False))}
        if status:
            problems += 1
        print(f"{name:20s} {secs:8.2f} {rss:8.1f} {rss2:8.1f} {growth:6.2f}x  {', '.join(status) or 'ok'}")
if a.save_baseline:
    for k, v in results.items():
        v["known_growth"] = v["rss_2x_mb"] / v["rss_mb"] > 1.5 and v["rss_2x_mb"] > 32 if v["rss_mb"] > 0 else False
    json.dump(results, open(BASE, "w"), indent=1)
    print("baseline yazıldı:", BASE)
sys.exit(1 if problems else 0)
