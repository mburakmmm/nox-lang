#!/usr/bin/env python3
"""serve_multicore'a FABRİKA fonksiyonu (v2.1.20): her worker fabrikayı kendi RuntimeState'inde bir kez çağırır.

Kullanım: http_factory_probe.py <noxc>. Program iki arka uçta (LLVM ve QBE) 4 worker ile çalıştırılır (LLVM havuz boyutu varsayılanda CPU sayısıyla sınırlıdır: `NOX_POOL_WORKERS=4` ile sabitlenir); fabrika bir günlük dosyasına satır ekler. Beklenen: tam 4 çağrı ve her çalışanın kendi
`hits` sayacının ardışık artması. Çıkış 0 = başarılı.
"""
import collections
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(HERE)
noxc = sys.argv[1]
template = open(os.path.join(root, "tests/golden/http_multicore_factory_program.nox.in")).read()
WORKERS = 4

for backend in ("llvm", "qbe"):
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "app.nox")
        log = os.path.join(tmp, "factory.log")
        open(path, "w").write(template.replace("@PORT@", str(port)))
        open(log, "w").close()
        p = subprocess.Popen([noxc, "run", "--backend", backend, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=dict(os.environ, FAC_LOG=log, NOX_POOL_WORKERS=str(WORKERS)))
        try:
            up = False
            for _ in range(150):
                time.sleep(0.2)
                try:
                    urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1).read()
                    up = True
                    break
                except Exception:
                    if p.poll() is not None:
                        break
            if not up:
                p.kill()
                print(f"[{backend}] sunucu açılmadı\n{p.stderr.read()[:1500]}")
                sys.exit(1)
            seq = collections.defaultdict(list)
            for _ in range(40):
                body = urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=3).read().decode()
                ident, hits = body.split()
                seq[ident].append(int(hits.split(":")[1]))
            time.sleep(0.5)
            calls = open(log).read().count("factory")
            if calls != WORKERS:
                print(f"[{backend}] fabrika {calls} kez çağrıldı, beklenen {WORKERS}")
                sys.exit(1)
            for ident, v in seq.items():
                if v != list(range(v[0], v[0] + len(v))):
                    print(f"[{backend}] worker {ident} sayacı ardışık değil: {v}")
                    sys.exit(1)
        finally:
            p.kill()
print("ok")
