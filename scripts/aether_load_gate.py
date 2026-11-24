#!/usr/bin/env python3
"""R2-L / R1-P3.2: Aether `hello_api` çok-worker yük + sızıntı kapısı (macOS/Linux).
Aether'i noxc ile derler, 4 worker (AETHER_WORKERS + NOX_POOL_WORKERS) ile başlatır, 16 paralel KALICI bağlantıdan (keep-alive; yeni bağlantı başına port tükenmesi yok)
turlar halinde istek atar. Kapılar: (1) hatalı/200-dışı yanıt oranı <= %0.1, (2) sunucu canlı, (3) tepe RSS büyümesi (1. tur sonrası -> son tur) <= max(8 MiB, %50),
(4) SIGTERM ile temiz çıkış (zaman aşımı yok). Çıktı: tur başına RSS/süre/istek-sn. Kullanım: aether_load_gate.py <aether_dizini> [--noxc yol] [--rounds 4] [--per-thread 1500]"""
import argparse, http.client, os, subprocess, sys, tempfile, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("aether")
ap.add_argument("--noxc", default="noxc")
ap.add_argument("--rounds", type=int, default=4)
ap.add_argument("--per-thread", type=int, default=1500)
ap.add_argument("--threads", type=int, default=16)
ap.add_argument("--port", default="3911")
a = ap.parse_args()

exe = os.path.join(tempfile.mkdtemp(prefix="aether_gate_"), "aether_bin")
b = subprocess.run([a.noxc, "build", "examples/hello_api/main.nox", "-o", exe], cwd=a.aether, capture_output=True, text=True)
if b.returncode != 0:
    print("derleme başarısız:", b.stdout[-400:], b.stderr[-400:])
    sys.exit(2)
env = dict(os.environ, AETHER_PORT=a.port, AETHER_WORKERS="4", NOX_POOL_WORKERS="4")
p = subprocess.Popen([exe], cwd=a.aether, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(50):  # hazır olana kadar bekle (en çok 10 sn)
    try:
        c = http.client.HTTPConnection("127.0.0.1", int(a.port), timeout=1)
        c.request("GET", "/api/users/1")
        c.getresponse().read()
        break
    except Exception:
        time.sleep(0.2)
else:
    p.kill()
    print("sunucu başlamadı")
    sys.exit(2)

def rss_mib():
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()
    return int(out) // 1024 if out else -1

ok = bad = 0
lock = threading.Lock()

def worker(n):
    global ok, bad
    conn = http.client.HTTPConnection("127.0.0.1", int(a.port), timeout=10)
    for _ in range(n):
        try:
            conn.request("GET", "/api/users/1")
            r = conn.getresponse()
            good = r.status == 200 and b"ada" in r.read()
        except Exception:
            good = False
            conn.close()
            conn = http.client.HTTPConnection("127.0.0.1", int(a.port), timeout=10)
        with lock:
            if good:
                ok += 1
            else:
                bad += 1

rows = []
for rnd in range(a.rounds):
    ts = [threading.Thread(target=worker, args=(a.per_thread,)) for _ in range(a.threads)]
    t0 = time.time()
    [t.start() for t in ts]
    [t.join() for t in ts]
    dt = time.time() - t0
    rows.append((rnd + 1, rss_mib(), round(dt, 1), int(a.threads * a.per_thread / dt)))
for r in rows:
    print(f"tur {r[0]}: RSS {r[1]} MiB, {r[2]} s, {r[3]} istek/sn")
alive = p.poll() is None
p.terminate()
try:
    p.wait(timeout=10)
    clean = True
except subprocess.TimeoutExpired:
    p.kill()
    clean = False
total = ok + bad
fails = []
if total == 0 or bad / total > 0.001:
    fails.append(f"hatalı yanıt oranı {bad}/{total}")
if not alive:
    fails.append("sunucu yük altında öldü")
growth = rows[-1][1] - rows[0][1]
if growth > max(8, rows[0][1] // 2):
    fails.append(f"RSS büyümesi {growth} MiB (tur1 {rows[0][1]} -> son {rows[-1][1]})")
if not clean:
    fails.append("SIGTERM sonrası 10 sn içinde çıkmadı")
print(f"ok={ok} bad={bad} canlı={alive} temiz_çıkış={clean}")
if fails:
    print("AETHER KAPISI KIRMIZI: " + "; ".join(fails))
    sys.exit(1)
print("AETHER KAPISI YEŞİL")
