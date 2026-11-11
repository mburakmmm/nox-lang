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

    # --- TLS: özel CA (ca_file) ile güvenilir bağlantı ve güvenilmeyen kendinden imzalı sertifikanın reddi (v2.1.39). redis-server TLS'siz derlenmişse ya da openssl yoksa atlanır. ---
    if shutil.which("openssl"):
        with tempfile.TemporaryDirectory() as tdir:
            key, cert = os.path.join(tdir, "key.pem"), os.path.join(tdir, "cert.pem")
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"], check=True, capture_output=True)
            tport = free_port()
            tproc = subprocess.Popen([server, "--port", "0", "--tls-port", str(tport), "--bind", "127.0.0.1", "--tls-cert-file", cert, "--tls-key-file", key, "--tls-ca-cert-file", cert, "--tls-auth-clients", "no", "--save", "", "--appendonly", "no", "--dir", tdir], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            procs.append(tproc)
            up = False
            for _ in range(60):
                if tproc.poll() is not None:
                    break
                try:
                    socket.create_connection(("127.0.0.1", tport), timeout=0.2).close()
                    up = True
                    break
                except OSError:
                    time.sleep(0.05)
            if up:
                ttemplate = open(os.path.join(ROOT, "tests/golden/redis_tls_program.nox.in")).read()
                texpected = open(os.path.join(ROOT, "tests/golden/redis_tls_program.expected")).read()
                tpath = os.path.join(tdir, "tls_program.nox")
                open(tpath, "w").write(ttemplate.replace("@PORT@", str(tport)).replace("@CA@", cert))
                for backend in ("llvm", "qbe"):
                    r = subprocess.run([noxc, "run", "--backend", backend, tpath], capture_output=True, text=True, timeout=300)
                    if r.returncode != 0 or r.stdout != texpected or r.stderr.strip():
                        print(f"[tls {backend}] beklenmeyen sonuç (çıkış {r.returncode})\n--- stdout\n{r.stdout}\n--- stderr\n{r.stderr}\n--- beklenen\n{texpected}")
                        sys.exit(1)
            else:
                print("skip: redis-server TLS desteği yok")
finally:
    for p in procs:
        p.kill()
        p.wait()
print("ok")
