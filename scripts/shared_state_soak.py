#!/usr/bin/env python3
"""Faz 9.12: paylaşılan modül durumu (M:N) için RSS büyüme denetimi. `tests/stress/mn_shared_churn.nox.in`yi 1x ve 4x tur sayısıyla derleyip çalıştırır ve tepe RSS'i
karşılaştırır; 4x çalıştırma 1x'e göre `--max-ratio` (varsayılan 1.5) katından fazla büyürse sızıntı vardır. Kullanım: scripts/shared_state_soak.py [--rounds 40000] [--workers 4] [--backend llvm]"""
import argparse, os, resource, subprocess, sys, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ap = argparse.ArgumentParser()
ap.add_argument("--rounds", type=int, default=40000)
ap.add_argument("--workers", default="4")
ap.add_argument("--backend", default="llvm")
ap.add_argument("--max-ratio", type=float, default=1.5)
a = ap.parse_args()
noxc = os.environ.get("NOXC", os.path.join(ROOT, "zig-out/bin/noxc"))
tmpl = open(os.path.join(ROOT, "tests/stress/mn_shared_churn.nox.in")).read()
res = {}
with tempfile.TemporaryDirectory() as d:
    for mult in (1, 4):
        src = os.path.join(d, f"churn{mult}.nox")
        open(src, "w").write(tmpl.replace("@ROUNDS@", str(a.rounds * mult)))
        exe = os.path.join(d, f"churn{mult}")
        subprocess.run([noxc, "build", "--backend", a.backend, "-o", exe, src], check=True, capture_output=True)
        before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        p = subprocess.run([exe], env=dict(os.environ, NOX_POOL_WORKERS=a.workers), capture_output=True, text=True, timeout=900)
        if p.returncode != 0 or p.stderr.strip():
            print(f"BAŞARISIZ ({mult}x): rc={p.returncode} stderr={p.stderr[:300]}")
            sys.exit(1)
        # RUSAGE_CHILDREN tepe değeri birikimli en büyük çocuğu verir: her çalıştırma bir öncekinden büyükse yeni tepe okunur.
        res[mult] = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
unit = 1 if sys.platform == "darwin" else 1024
mb = {k: v * unit / 1048576 for k, v in res.items()}
ratio = mb[4] / mb[1] if mb[1] else 1.0
print(f"tepe RSS: 1x={mb[1]:.1f} MiB, 4x={mb[4]:.1f} MiB, oran={ratio:.2f}")
if ratio > a.max_ratio:
    print(f"SIZINTI ŞÜPHESİ: 4x tur RSS'i {a.max_ratio} katından fazla büyüttü")
    sys.exit(1)
