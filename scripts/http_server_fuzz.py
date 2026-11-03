#!/usr/bin/env python3
"""`nox.http.serve` sunucusu için dayanıklılık / bozuk-girdi (fuzz) testi.

Gerçek bir Nox sunucusu derlenip başlatılır; ham soketlerle bilerek bozuk, aşırı büyük, çelişkili (request-smuggling) ve rastgele mutasyona uğramış istekler gönderilir.
DEĞİŞMEZLER (her vaka sonrası): (1) sunucu süreci ölmemiş olmalı, (2) hemen ardından normal bir `GET /health` istek 200 dönmeli, (3) hiçbir vaka
`--case-timeout` içinde askıda kalmamalı. Yanıt kodu serbesttir (200/4xx/5xx ya da bağlantı kapanışı); amaç çökme/askı/sızma olmamasıdır.

Kullanım: scripts/http_server_fuzz.py [--noxc zig-out/bin/noxc] [--iterations 1500] [--seed 1]
Çıkış kodu: herhangi bir değişmez bozulduysa 1.
"""
import argparse
import os
import random
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SERVER_SRC = """import nox.http

def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
    if req.target == "/health":
        return nox_http_HttpResponse(200, "ok", {{}})
    return nox_http_HttpResponse(200, str(len(req.body)), {{}})

nox.http.serve({port}, handle)
"""


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def exchange(port, payload, wait=2.0, read_limit=65536, half_close=False):
    """payload'u gönderip yanıtı (ya da kapanışı) okur. Döner: (durum, ham)."""
    s = socket.create_connection(("127.0.0.1", port), timeout=wait)
    try:
        try:
            s.sendall(payload)
            if half_close:
                s.shutdown(socket.SHUT_WR)
        except (BrokenPipeError, ConnectionResetError):
            pass
        data = b""
        end = time.time() + wait
        while time.time() < end and len(data) < read_limit:
            try:
                chunk = s.recv(8192)
            except socket.timeout:
                return ("timeout", data)
            except (ConnectionResetError, OSError):
                return ("reset", data)
            if not chunk:
                break
            data += chunk
        return ("closed" if not data else "data", data)
    finally:
        s.close()


def status_of(data):
    if data.startswith(b"HTTP/1.") and len(data) >= 12:
        try:
            return int(data[9:12])
        except ValueError:
            return None
    return None


def health(port, tries=3):
    for _ in range(tries):
        try:
            kind, data = exchange(port, b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", wait=3.0)
            if status_of(data) == 200 and data.endswith(b"ok"):
                return True
        except OSError:
            pass
        time.sleep(0.2)
    return False


GET = b"GET /x HTTP/1.1\r\nHost: x\r\n"


def cases():
    big = b"A" * 100_000
    yield "geçerli GET", GET + b"Connection: close\r\n\r\n"
    yield "rastgele çöp", b"\x00\x01\x02GARBAGE\xff\xfe\r\n\r\n"
    yield "bilinmeyen metod", b"FOOBAR /x HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    # v2.0.127: geçerli ön ek artık h2c olarak kabul edilir (sonrasında çerçeve beklenir); geçersiz çerçeve gelirse GOAWAY + kapanış. HTTP/2'ye özgü sınamalar: scripts/http2_server_fuzz.py.
    yield "HTTP/2 ön ek + geçersiz çerçeve", b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + b"\xff\xff\xff\x00\x00\x00\x00\x00\x01"
    yield "HTTP/0.9 stili", b"GET /x\r\n\r\n"
    yield "HTTP/9.9", b"GET /x HTTP/9.9\r\nHost: x\r\nConnection: close\r\n\r\n"
    yield "Host yok (1.1)", b"GET /x HTTP/1.1\r\nConnection: close\r\n\r\n"
    yield "100 KB URL", b"GET /" + big + b" HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    yield "100 KB başlık değeri", GET + b"X-Big: " + big + b"\r\nConnection: close\r\n\r\n"
    yield "5000 başlık", GET + b"".join(b"X-H%d: v\r\n" % i for i in range(5000)) + b"Connection: close\r\n\r\n"
    yield "satır sonu yalnız LF", b"GET /x HTTP/1.1\nHost: x\nConnection: close\n\n"
    yield "CR tek başına", b"GET /x HTTP/1.1\rHost: x\r\rConnection: close\r\r"
    yield "başlıkta NUL", GET + b"X-A: a\x00b\r\nConnection: close\r\n\r\n"
    yield "obs-fold devam satırı", GET + b"X-A: a\r\n  folded\r\nConnection: close\r\n\r\n"
    yield "boşluklu başlık adı", GET + b"X A: v\r\nConnection: close\r\n\r\n"
    yield "başlık adında iki nokta yok", GET + b"NoColonHeader\r\nConnection: close\r\n\r\n"
    yield "CL ve TE birlikte (smuggling)", b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\nGET /smuggled HTTP/1.1\r\nHost: x\r\n\r\n"
    yield "çift farklı Content-Length", b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nContent-Length: 10\r\nConnection: close\r\n\r\nabcdefghij"
    yield "negatif Content-Length", b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\nConnection: close\r\n\r\nabc"
    yield "sayısal olmayan Content-Length", b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\nConnection: close\r\n\r\nabc"
    yield "taşan Content-Length", b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 99999999999999999999\r\nConnection: close\r\n\r\nabc"
    yield "Content-Length 11 MiB (limit aşımı)", b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 11534336\r\nConnection: close\r\n\r\n" + b"z" * 11_534_336
    yield "chunked 11 MiB (limit aşımı)", b"POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" + (b"100000\r\n" + b"z" * 0x100000 + b"\r\n") * 11 + b"0\r\n\r\n"
    yield "chunked: uzantı + artçı başlık (geçerli)", b"POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5;ext=1\r\nhello\r\n0\r\nX-Trailer: v\r\n\r\n"
    yield "chunked: boyut satırı çok uzun", b"POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" + b"1" * 20000 + b"\r\n"
    yield "kesik gövde", b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort"
    yield "chunked: geçersiz boyut", b"POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nZZ\r\nabc\r\n0\r\n\r\n"
    yield "chunked: dev boyut", b"POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nFFFFFFFFFFFFFFFF\r\nabc\r\n"
    yield "chunked: sonlandırıcı yok", b"POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n"
    yield "chunked: bilinmeyen kodlama", b"POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\nConnection: close\r\n\r\n0\r\n\r\n"
    yield "Expect: 100-continue", b"POST /x HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc"
    yield "100 pipeline istek", (GET + b"\r\n") * 100 + GET + b"Connection: close\r\n\r\n"
    yield "yarım başlık + kapanış", b"GET /x HTTP/1.1\r\nHost: x\r\nX-Part"
    yield "yalnız boş satırlar", b"\r\n" * 5000
    yield "çok uzun tek satır (başlık sonu yok)", b"GET /x HTTP/1.1\r\nHost: " + b"h" * 1_000_000


# Doğası gereği eksik istekler: sunucunun daha fazla veri beklemesi (okuma zaman aşımına kadar) meşrudur; yalnız sağlık kontrolü geçmeli.
MAY_WAIT = {"CR tek başına", "yarım başlık + kapanış", "çok uzun tek satır (başlık sonu yok)", "yalnız boş satırlar", "chunked: sonlandırıcı yok", "kesik gövde"}


def mutate(rng, base):
    b = bytearray(base)
    for _ in range(rng.randint(1, 6)):
        op = rng.randint(0, 5)
        if not b:
            break
        i = rng.randrange(len(b))
        if op == 0:
            b[i] = rng.randrange(256)
        elif op == 1:
            del b[i:i + rng.randint(1, 20)]
        elif op == 2:
            b[i:i] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 20)))
        elif op == 3:
            b[i:i] = b"\r\n" * rng.randint(1, 4)
        elif op == 4:
            b = b[: rng.randrange(1, len(b) + 1)]
        else:
            j = rng.randrange(len(b))
            b[i:i] = b[j:j + rng.randint(1, 30)]
    return bytes(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--noxc", default=os.path.join(ROOT, "zig-out/bin/noxc"))
    ap.add_argument("--iterations", type=int, default=1500)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--case-timeout", type=float, default=6.0)
    args = ap.parse_args()

    work = tempfile.mkdtemp(prefix="nox-fuzz-")
    port = free_port()
    src = os.path.join(work, "srv.nox")
    open(src, "w").write(SERVER_SRC.format(port=port))
    exe = os.path.join(work, "srv")
    subprocess.run([args.noxc, "build", src, "-o", exe], check=True, capture_output=True)
    proc = subprocess.Popen([exe], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    failures = []
    try:
        for _ in range(60):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        if not health(port):
            print("FAIL: sunucu başlamadı")
            return 1

        def check(name, payload, wait=None, **kw):
            t0 = time.time()
            wait = wait or args.case_timeout
            try:
                kind, data = exchange(port, payload, wait=wait, **kw)
            except OSError as e:
                kind, data = ("oserror:" + str(e), b"")
            dt = time.time() - t0
            alive = proc.poll() is None
            healthy = alive and health(port)
            st = status_of(data)
            note = ""
            if not alive:
                note = f"SUNUCU ÖLDÜ (çıkış {proc.returncode})"
            elif not healthy:
                note = "SAĞLIK KONTROLÜ BAŞARISIZ"
            elif kind == "timeout" and dt >= wait - 0.5 and name not in MAY_WAIT:
                note = "ASKIDA (sunucu bağlantıyı bırakmadı)"
            if note:
                failures.append((name, note))
            return kind, st, dt, note

        print(f"{'vaka':45} {'sonuç':14} {'süre':>6}")
        for name, payload in cases():
            kind, st, dt, note = check(name, payload, half_close=name.startswith(("kesik", "yarım")))
            res = f"HTTP {st}" if st else kind
            print(f"{name:45} {res:14} {dt:5.2f}s {note}")
            if proc.poll() is not None:
                break

        if proc.poll() is None:
            rng = random.Random(args.seed)
            bases = [GET + b"Connection: close\r\n\r\n",
                     b"POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello",
                     b"POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n"]
            bad = 0
            for i in range(args.iterations):
                payload = mutate(rng, rng.choice(bases))
                # Yazma tarafı kapatılır (EOF): eksik mutasyonlarda sunucu okuma zaman aşımını beklemeden bağlantıyı bırakmalıdır.
                kind, st, dt, note = check(f"mutasyon#{i}", payload, half_close=True, wait=2.0)
                if note:
                    bad += 1
                    print(f"mutasyon#{i}: {note} payload={payload[:120]!r}")
                    if proc.poll() is not None or bad >= 5:
                        break
            print(f"mutasyon: {args.iterations} yineleme (seed {args.seed}), sorun: {bad}")
    finally:
        if proc.poll() is None:
            proc.kill()
        err = proc.stderr.read().decode("utf-8", "replace")
        proc.wait()
        if err.strip():
            print("--- sunucu stderr (ilk 600 bayt) ---")
            print(err[:600])
    if failures:
        print(f"\nBAŞARISIZ: {len(failures)} değişmez bozuldu")
        for name, note in failures[:20]:
            print(f"  - {name}: {note}")
        return 1
    print("\nTÜM değişmezler korundu (sunucu yaşadı, sağlık kontrolü geçti, askı yok)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
