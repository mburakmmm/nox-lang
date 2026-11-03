#!/usr/bin/env python3
"""HTTP/2 sunucusu uçtan uca duman testi (gerçek `curl` + nghttp2).

Kendinden imzalı bir sertifika üretir (openssl), küçük bir Nox sunucusunu hem TLS (ALPN `h2`) hem düz TCP (h2c önceden bilinen) olarak çalıştırır ve `curl` ile doğrular:
protokol sürümü, HTTP/1.1 geri dönüşü, POST gövdesi, tek bağlantıda paralel istekler (çoklama), büyük yanıt (akış kontrolü), SSE'nin parça parça gelmesi ve SIGTERM ile temiz kapanış.

Kullanım: scripts/http2_smoke.py [--noxc zig-out/bin/noxc] [--backend qbe|llvm]
`curl` HTTP/2 desteklemiyorsa ya da `openssl` yoksa atlanır (çıkış 0). Hata varsa çıkış kodu 1.
"""
import argparse
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SRC = """import nox.http
import nox.os
from nox.http import HttpRequest, HttpResponse, ResponseStream

def handle(req: HttpRequest) -> HttpResponse:
    if req.target == "/events":
        s: ResponseStream = req.sse()
        i: int = 0
        while i < 3 and s.is_open():
            s.event("tick " + str(i), "tick")
            i = i + 1
            s.sleep_ms(300)
        return s.end()
    if req.target == "/slow":
        w: ResponseStream = req.stream(200, {{}})
        w.sleep_ms(400)
        w.send("slow")
        return w.end()
    if req.target == "/echo":
        return HttpResponse(200, req.method + ":" + str(len(req.body)) + ":" + req.headers["Content-Type"], {{}})
    if req.target == "/big":
        return HttpResponse(200, "x" * 2000000, {{}})
    return HttpResponse(200, "hello", {{"Content-Type": "text/plain"}})

def use_tls() -> bool:
    try:
        return nox.os.getenv("H2_TLS") == "1"
    except Exception:
        return False

if use_tls():
    nox.http.serve_tls({port}, handle, "{cert}", "{key}")
else:
    nox.http.serve({port}, handle)
print("stopped")
"""


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def curl(*args, timeout=30):
    r = subprocess.run(["curl", "-sS", *args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


failures = []


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def run_server(exe, port, env_extra, work, name):
    env = dict(os.environ, **env_extra)
    log = open(os.path.join(work, name + ".log"), "w")
    p = subprocess.Popen([exe], env=env, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            break
        except OSError:
            time.sleep(0.05)
    return p, log


def stop_server(p, log, work, name):
    p.send_signal(signal.SIGTERM)
    try:
        p.wait(timeout=15)
    except subprocess.TimeoutExpired:
        p.kill()
        failures.append(f"[{name}] SIGTERM'e 15 sn içinde yanıt vermedi")
    log.close()
    out = open(os.path.join(work, name + ".log")).read()
    check(p.returncode == 0, f"[{name}] çıkış kodu 0 (gerçek: {p.returncode})")
    check("stopped" in out and "leak" not in out and "panic" not in out, f"[{name}] temiz kapanış, sızıntı/panik yok")


payload_path = ""


def scenarios(base, label, extra):
    """`extra`: curl'e eklenen protokol bayrakları."""
    rc, out, err = curl(*extra, "-w", "%{http_version}", "-o", "/dev/null", base + "/hello")
    check(rc == 0 and out == "2", f"[{label}] GET protokolü HTTP/2 (curl: {out!r} {err.strip()})")
    rc, out, _ = curl(*extra, base + "/hello")
    check(rc == 0 and out == "hello", f"[{label}] GET gövdesi")
    rc, out, _ = curl(*extra, "-X", "POST", "-H", "Content-Type: application/octet-stream", "--data-binary", "@" + payload_path, base + "/echo")
    size = os.path.getsize(payload_path)
    check(rc == 0 and out == f"POST:{size}:application/octet-stream", f"[{label}] POST {size} bayt, başlık adı normalleşmesi ({out!r})")
    rc, out, _ = curl(*extra, "-w", "%{size_download}", "-o", "/dev/null", base + "/big")
    check(rc == 0 and out == "2000000", f"[{label}] 2 MB yanıt (akış kontrolü) ({out})")
    # Çoklama: tek bağlantıda 30 paralel 400 ms'lik istek ≈ 0,5 sn (seri olsa 12 sn).
    t0 = time.time()
    urls = []
    for _ in range(30):
        urls += ["-o", "/dev/null", base + "/slow"]
    rc, out, _ = curl(*extra, "--parallel", "--parallel-max", "30", "-w", "%{http_version} ", *urls)
    dt = time.time() - t0
    check(rc == 0 and out.split() == ["2"] * 30 and dt < 4.0, f"[{label}] 30 paralel istek tek bağlantıda ({dt:.2f} sn)")
    # SSE: ilk olay akış bitmeden gelir.
    p = subprocess.Popen(["curl", "-sS", "-N", *extra, base + "/events"], stdout=subprocess.PIPE, text=True)
    t0 = time.time()
    first = p.stdout.readline()
    t_first = time.time() - t0
    rest = p.stdout.read()
    p.wait(timeout=10)
    check(first.startswith("event: tick") and t_first < 0.6 and rest.count("event: tick") == 2, f"[{label}] SSE parça parça ({t_first:.2f} sn)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--noxc", default=os.path.join(ROOT, "zig-out/bin/noxc"))
    ap.add_argument("--backend", default="")
    a = ap.parse_args()

    if shutil.which("curl") is None or "HTTP2" not in subprocess.run(["curl", "-V"], capture_output=True, text=True).stdout:
        print("curl HTTP/2 desteklemiyor: atlandı")
        return 0
    if shutil.which("openssl") is None:
        print("openssl yok: atlandı")
        return 0

    work = tempfile.mkdtemp(prefix="h2-smoke-")
    cert, key = os.path.join(work, "cert.pem"), os.path.join(work, "key.pem")
    global payload_path
    payload_path = os.path.join(work, "payload.txt")
    with open(payload_path, "w") as f:
        f.write("0123456789abcdef" * 7500)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=localhost"], capture_output=True, check=True)
    port = free_port()
    src = os.path.join(work, "srv.nox")
    open(src, "w").write(SRC.format(port=port, cert=cert.replace("\\", "/"), key=key.replace("\\", "/")))
    exe = os.path.join(work, "srv")
    r = subprocess.run([a.noxc, "build", src, "-o", exe] + (["--backend", a.backend] if a.backend else []), capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        return 1

    # TLS + ALPN
    p, log = run_server(exe, port, {"H2_TLS": "1"}, work, "tls")
    try:
        base = f"https://localhost:{port}"
        scenarios(base, "tls", ["-k", "--http2"])
        rc, out, _ = curl("-k", "--http1.1", "-w", "%{http_version}", "-o", "/dev/null", base + "/hello")
        check(rc == 0 and out == "1.1", f"[tls] --http1.1 istemci HTTP/1.1 alır ({out})")
    finally:
        stop_server(p, log, work, "tls")

    # h2c önceden bilinen + HTTP/1.1 aynı portta
    p, log = run_server(exe, port, {}, work, "h2c")
    try:
        base = f"http://127.0.0.1:{port}"
        scenarios(base, "h2c", ["--http2-prior-knowledge"])
        rc, out, _ = curl("-w", "%{http_version}", "-o", "/dev/null", base + "/hello")
        check(rc == 0 and out == "1.1", f"[h2c] düz HTTP/1.1 istemci aynı portta HTTP/1.1 alır ({out})")
    finally:
        stop_server(p, log, work, "h2c")

    if failures:
        print(f"\n{len(failures)} başarısız; günlükler: {work}")
        return 1
    shutil.rmtree(work, ignore_errors=True)
    print("\nhttp2 duman testi: temiz")
    return 0


sys.exit(main())
