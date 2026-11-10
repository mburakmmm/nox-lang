#!/usr/bin/env python3
"""serve_multicore + configure(ip_family=...) (v2.1.32): çok çekirdekli IPv6 dinleme.

Kullanım: http_ipv6_probe.py <noxc>. İki arka uçta (LLVM, QBE) iki aile denenir: 1 = dual-stack (::1 ve 127.0.0.1 bağlanır; IPv4 peer `a.b.c.d:port`, IPv6 peer `[::1]:port`),
2 = yalnızca IPv6 (127.0.0.1 reddedilir). Makinede IPv6 loopback yoksa çıkış 0 ile atlanır.
"""
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
template = open(os.path.join(root, "tests/golden/http_multicore_ipv6_program.nox.in")).read()

try:
    t = socket.socket(socket.AF_INET6)
    t.bind(("::1", 0))
    t.close()
except OSError:
    print("skip: IPv6 loopback yok")
    sys.exit(0)


def free_port():
    s = socket.socket(socket.AF_INET6)
    s.bind(("::", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def fetch(url):
    return urllib.request.urlopen(url, timeout=3).read().decode()


for backend in ("llvm", "qbe"):
    for family in (1, 2):
        port = free_port()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "app.nox")
            open(path, "w").write(template.replace("@PORT@", str(port)).replace("@FAMILY@", str(family)))
            p = subprocess.Popen([noxc, "run", "--backend", backend, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=dict(os.environ, NOX_POOL_WORKERS="4"))
            try:
                up = False
                body6 = ""
                for _ in range(150):
                    time.sleep(0.2)
                    try:
                        body6 = fetch(f"http://[::1]:{port}/")
                        up = True
                        break
                    except Exception:
                        if p.poll() is not None:
                            break
                if not up:
                    p.kill()
                    print(f"[{backend} f{family}] sunucu açılmadı\n{p.stderr.read()[:1500]}")
                    sys.exit(1)
                if not body6.startswith("peer:[::1]:"):
                    print(f"[{backend} f{family}] IPv6 peer beklenen biçimde değil: {body6!r}")
                    sys.exit(1)
                # 20 istek, 4 worker'a dağılsa da hepsi cevaplanmalı
                for _ in range(20):
                    if not fetch(f"http://[::1]:{port}/").startswith("peer:[::1]:"):
                        print(f"[{backend} f{family}] tutarsız yanıt")
                        sys.exit(1)
                try:
                    body4 = fetch(f"http://127.0.0.1:{port}/")
                    v4_ok = True
                except Exception:
                    body4 = ""
                    v4_ok = False
                if family == 1 and not (v4_ok and body4.startswith("peer:127.0.0.1:")):
                    print(f"[{backend} f1] dual-stack IPv4 istemci başarısız: {body4!r}")
                    sys.exit(1)
                if family == 2 and v4_ok:
                    print(f"[{backend} f2] yalnızca-IPv6 sunucu IPv4 istemciyi kabul etti: {body4!r}")
                    sys.exit(1)
            finally:
                p.kill()
print("ok")
