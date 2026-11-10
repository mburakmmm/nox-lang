#!/usr/bin/env python3
"""nox.redis'i GERÇEK redis-server'lara karşı sınar (Ember NL-001): komutlar, ikili yük, Streams, betik/NOSCRIPT, AUTH/ACL, kopan bağlantı.

Kullanım: redis_probe.py <noxc>. İki geçici sunucu başlatılır (biri `requirepass secret`). Çıkış 0 = başarılı, 77 = redis-server yok (atlandı).
Program iki arka uçta (LLVM ve QBE) çalıştırılır; stdout `tests/golden/redis_program.expected` ile aynı olmalıdır.
"""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
server = shutil.which("redis-server") or shutil.which("valkey-server")
if not server:
    sys.exit(77)
noxc = sys.argv[1]


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def start(port, tmp, extra=()):
    args = [server, "--port", str(port), "--bind", "127.0.0.1", "--save", "", "--appendonly", "no", "--dir", tmp, *extra]
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return proc
        except OSError:
            time.sleep(0.05)
    proc.kill()
    sys.exit("redis-server başlamadı")


procs = []
try:
    with tempfile.TemporaryDirectory() as tmp:
        port, auth_port = free_port(), free_port()
        procs.append(start(port, tmp))
        procs.append(start(auth_port, tmp, ("--requirepass", "secret")))
        template = open(os.path.join(ROOT, "tests/golden/redis_program.nox.in")).read()
        expected = open(os.path.join(ROOT, "tests/golden/redis_program.expected")).read()
        path = os.path.join(tmp, "program.nox")
        open(path, "w").write(template.replace("@PORT@", str(port)).replace("@AUTHPORT@", str(auth_port)))
        for backend in ("llvm", "qbe"):
            r = subprocess.run([noxc, "run", "--backend", backend, path], capture_output=True, text=True, timeout=300)
            if r.returncode != 0 or r.stdout != expected:
                print(f"[{backend}] beklenmeyen sonuç (çıkış {r.returncode})\n--- stdout\n{r.stdout}\n--- stderr\n{r.stderr}\n--- beklenen\n{expected}")
                sys.exit(1)
finally:
    for p in procs:
        p.kill()
        p.wait()
print("ok")
