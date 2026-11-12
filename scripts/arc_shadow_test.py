#!/usr/bin/env python3
"""ASAP "gölge mod" fark testi (TODO 4.5.3): korpustaki her program normal ve `NOX_FORCE_ARC=1` (yığın/arena yükseltmesi kapalı, her yerel ARC) ile derlenip çalıştırılır;
çıktı (stdout + çıkış kodu) AYNI olmalıdır. Programın normal çalıştırması iki kez farklı çıktı veriyorsa (zaman, rastgelelik, iş parçacığı) deterministik olmadığından atlanır.
Kullanım: scripts/arc_shadow_test.py [dizin] [--jobs N] [--backend llvm|qbe] [--only ad,ad]   (ReleaseFast ya da Debug noxc; çıkış kodu 1 = fark var)"""
import argparse, concurrent.futures, glob, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
ap = argparse.ArgumentParser()
ap.add_argument("dir", nargs="?", default=os.path.join(ROOT, "tests/golden/codegen_cases"))
ap.add_argument("--jobs", type=int, default=6)
ap.add_argument("--backend", default="llvm")
ap.add_argument("--only")
a = ap.parse_args()

SKIP_IMPORTS = ("nox.http", "nox.grpc", "nox.websocket", "nox.tls", "nox.smtp", "nox.redis", "nox.postgres", "nox.mysql", "nox.udp", "nox.thread", "nox.sharedmem",
                "nox.process", "nox.signal", "nox.terminal", "nox.native", "nox.plugin", "nox.hpy", "nox.sqlite", "nox.time", "nox.random", "nox.uuid", "nox.tempfile", "nox.log")

def build_run(path, env_arc, workdir):
    exe = os.path.join(workdir, "arc" if env_arc else "norm")
    env = dict(os.environ)
    if env_arc:
        env["NOX_FORCE_ARC"] = "1"
    b = subprocess.run([NOXC, "build", "--backend", a.backend, path, "-o", exe], capture_output=True, text=True, env=env, timeout=300)
    if b.returncode:
        return ("buildfail", b.stderr[:200], 0)
    try:
        r = subprocess.run([exe], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return ("timeout", "", 0)
    return ("ok", r.stdout + "\n--stderr--\n" + r.stderr, r.returncode)

def one(path):
    name = os.path.basename(path)
    src = open(path, encoding="utf-8", errors="replace").read()
    if any(("import " + m) in src or ("from " + m) in src for m in SKIP_IMPORTS) or "spawn" in src:
        return name, "skip", "yakın dış bağımlılık/eşzamanlılık"
    with tempfile.TemporaryDirectory() as d:
        norm = build_run(path, False, d)
        if norm[0] != "ok":
            return name, "skip", "normal derleme/çalışma: " + norm[0]
        norm2 = build_run(path, False, d)
        if norm2 != norm:
            return name, "skip", "deterministik değil"
        arc = build_run(path, True, d)
        if arc != norm:
            return name, "FARK", f"normal={norm[0]}/{norm[2]} arc={arc[0]}/{arc[2]} | {str(arc[1])[:160]!r}"
        return name, "ok", ""

files = sorted(glob.glob(os.path.join(a.dir, "*.nox")))
if a.only:
    want = set(a.only.split(","))
    files = [f for f in files if os.path.basename(f)[:-4] in want]
counts = {"ok": 0, "skip": 0, "FARK": 0}
with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as ex:
    for name, st, info in ex.map(one, files):
        counts[st] += 1
        if st == "FARK":
            print(f"FARK  {name}: {info}")
print(f"gölge mod: {counts['ok']} aynı, {counts['FARK']} fark, {counts['skip']} atlandı ({len(files)} program)")
sys.exit(1 if counts["FARK"] else 0)
