#!/usr/bin/env python3
"""`nox.http.serve` HTTP/2 (h2c) sunucusu için dayanıklılık / bozuk-girdi (fuzz) testi.

Gerçek bir Nox sunucusu derlenip başlatılır; ham soketlerle bilerek bozuk çerçeveler, hatalı HPACK blokları, çelişkili ayarlar ve geçerli bir konuşmanın rastgele mutasyonları gönderilir.
DEĞİŞMEZLER (her vaka sonrası): (1) sunucu süreci ölmemiş olmalı, (2) hemen ardından YENİ bir HTTP/2 bağlantısında geçerli bir `GET /health` 200 dönmeli ve bir HTTP/1.1 `GET /health`
de 200 dönmeli, (3) hiçbir vaka `--case-timeout` içinde askıda kalmamalı. Sunucunun yanıtı (GOAWAY, RST_STREAM, bağlantı kapanışı) serbesttir.

Kullanım: scripts/http2_server_fuzz.py [--noxc zig-out/bin/noxc] [--iterations 1000] [--seed 1] [--backend qbe|llvm]
Çıkış kodu: herhangi bir değişmez bozulduysa 1.
"""
import argparse
import os
import random
import socket
import struct
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

PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
DATA, HEADERS, PRIORITY, RST, SETTINGS, PUSH, PING, GOAWAY, WINDOW, CONT = range(10)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def frame(kind, flags, sid, payload=b""):
    n = len(payload)
    return bytes([(n >> 16) & 255, (n >> 8) & 255, n & 255, kind, flags]) + struct.pack(">I", sid & 0x7FFFFFFF) + payload


def lit(name, value):
    """HPACK: değişmez ad + değer, dizinsiz (RFC 7541 §6.2.2), Huffman'sız."""
    return b"\x00" + bytes([len(name)]) + name + bytes([len(value)]) + value


def request_block(path=b"/health", method=b"GET"):
    return lit(b":method", method) + lit(b":scheme", b"http") + lit(b":path", path) + lit(b":authority", b"localhost")


def read_frames(s, wait):
    """Zaman aşımına/kapanışa dek çerçeveleri okur: [(tür, bayraklar, akış, yük)]; ikinci değer 'closed'/'timeout'."""
    out = []
    buf = b""
    end = time.time() + wait
    why = "timeout"
    while time.time() < end:
        s.settimeout(max(0.05, end - time.time()))
        try:
            d = s.recv(65536)
        except socket.timeout:
            break
        except OSError:
            why = "closed"
            break
        if not d:
            why = "closed"
            break
        buf += d
        while len(buf) >= 9:
            n = (buf[0] << 16) | (buf[1] << 8) | buf[2]
            if len(buf) < 9 + n:
                break
            out.append((buf[3], buf[4], struct.unpack(">I", buf[5:9])[0] & 0x7FFFFFFF, buf[9 : 9 + n]))
            buf = buf[9 + n :]
    return out, why


def exchange(port, payload, wait=1.5):
    s = socket.create_connection(("127.0.0.1", port), timeout=wait)
    try:
        try:
            s.sendall(payload)
        except OSError:
            pass
        return read_frames(s, wait)
    finally:
        s.close()


def h2_health(port, tries=3):
    """Taze bir h2c bağlantısında GET /health → 200 (gövde 'ok')."""
    for _ in range(tries):
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=3)
            s.sendall(PREFACE + frame(SETTINGS, 0, 0) + frame(HEADERS, 5, 1, request_block()))
            frames, _ = read_frames(s, 3)
            s.close()
            ok = any(k == HEADERS and sid == 1 and p[:1] == b"\x88" for k, f, sid, p in frames)
            body = b"".join(p for k, f, sid, p in frames if k == DATA and sid == 1)
            if ok and body == b"ok":
                return True
        except OSError:
            pass
        time.sleep(0.2)
    return False


def h1_health(port):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=3)
        s.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        data = b""
        while True:
            d = s.recv(4096)
            if not d:
                break
            data += d
        s.close()
        return data.startswith(b"HTTP/1.1 200")
    except OSError:
        return False


HANDSHAKE = PREFACE + frame(SETTINGS, 0, 0)


def cases():
    big = lambda n: b"x" * n
    hdr = lambda blk, flags=5, sid=1: frame(HEADERS, flags, sid, blk)
    yield "bozuk ön ek (kısa)", b"PRI * HTTP/2.0\r\n\r\nSM"
    yield "bozuk ön ek (yanlış)", b"PRI * HTTP/2.0\r\n\r\nXX\r\n\r\n" + frame(SETTINGS, 0, 0)
    yield "yalnızca PRI", b"PRI"
    yield "ön ek + kesik çerçeve başlığı", PREFACE + b"\x00\x00"
    yield "çerçeve uzunluğu > MAX_FRAME_SIZE", HANDSHAKE + b"\xff\xff\xff" + bytes([DATA, 0]) + struct.pack(">I", 1)
    yield "yük kesik", HANDSHAKE + frame(DATA, 0, 1, b"abc")[:-1]
    yield "SETTINGS ACK yüklü", HANDSHAKE + frame(SETTINGS, 1, 0, b"\x00" * 6)
    yield "SETTINGS uzunluk 5", HANDSHAKE + frame(SETTINGS, 0, 0, b"\x00" * 5)
    yield "SETTINGS INITIAL_WINDOW > 2^31-1", HANDSHAKE + frame(SETTINGS, 0, 0, struct.pack(">HI", 4, 0x80000000))
    yield "SETTINGS MAX_FRAME_SIZE geçersiz", HANDSHAKE + frame(SETTINGS, 0, 0, struct.pack(">HI", 5, 100))
    yield "SETTINGS ENABLE_PUSH=2", HANDSHAKE + frame(SETTINGS, 0, 0, struct.pack(">HI", 2, 2))
    yield "WINDOW_UPDATE taşması", HANDSHAKE + frame(WINDOW, 0, 0, struct.pack(">I", 0x7FFFFFFF)) * 2
    yield "WINDOW_UPDATE boş akış 0 artış", HANDSHAKE + hdr(request_block(b"/slow"), 4, 1) + frame(WINDOW, 0, 1, struct.pack(">I", 0))
    yield "HEADERS akış 0", HANDSHAKE + hdr(request_block(), 5, 0)
    yield "HEADERS çift numaralı akış", HANDSHAKE + hdr(request_block(), 5, 2)
    yield "HEADERS geriye giden akış kimliği", HANDSHAKE + hdr(request_block(), 5, 5) + hdr(request_block(), 5, 3)
    yield "HEADERS kendine bağımlı öncelik", HANDSHAKE + frame(HEADERS, 0x25, 1, struct.pack(">IB", 1, 0) + request_block())
    yield "HEADERS PADDED dolgu > yük", HANDSHAKE + frame(HEADERS, 0xD, 1, b"\xff" + request_block())
    yield "HEADERS boş blok", HANDSHAKE + hdr(b"", 5, 1)
    yield "HPACK indeks 0", HANDSHAKE + hdr(b"\x80", 5, 1)
    yield "HPACK tablo dışı indeks", HANDSHAKE + hdr(b"\xff\xff\xff\x7f", 5, 1)
    yield "HPACK kesik tamsayı", HANDSHAKE + hdr(b"\xff\x80", 5, 1)
    yield "HPACK kesik dize", HANDSHAKE + hdr(b"\x40\x7f" + b"a", 5, 1)
    yield "HPACK geçersiz Huffman", HANDSHAKE + hdr(b"\x40\x82\xff\xff\x01a", 5, 1)
    yield "HPACK tablo boyutu güncellemesi sonda", HANDSHAKE + hdr(request_block() + b"\x3f\xe1\x1f", 5, 1)
    yield "HPACK tablo boyutu > sınır", HANDSHAKE + hdr(b"\x3f\xff\xff\xff\x0f" + request_block(), 5, 1)
    yield "HPACK devasa dize uzunluğu", HANDSHAKE + hdr(b"\x00\x7f\xff\xff\xff\x07", 5, 1)
    yield "büyük harfli başlık adı", HANDSHAKE + hdr(request_block() + lit(b"X-Big", b"1"), 5, 1)
    yield "bağlantıya özgü başlık", HANDSHAKE + hdr(request_block() + lit(b"connection", b"close"), 5, 1)
    yield "te: gzip", HANDSHAKE + hdr(request_block() + lit(b"te", b"gzip"), 5, 1)
    yield "pseudo-header sonra normal sonra pseudo", HANDSHAKE + hdr(lit(b":method", b"GET") + lit(b"a", b"b") + lit(b":path", b"/"), 5, 1)
    yield "yinelenen :method", HANDSHAKE + hdr(request_block() + lit(b":method", b"GET"), 5, 1)
    yield "bilinmeyen pseudo-header", HANDSHAKE + hdr(request_block() + lit(b":foo", b"x"), 5, 1)
    yield ":path boş", HANDSHAKE + hdr(request_block(b""), 5, 1)
    yield ":path / ile başlamıyor", HANDSHAKE + hdr(request_block(b"x"), 5, 1)
    yield "CRLF içeren değer", HANDSHAKE + hdr(request_block() + lit(b"x", b"a\r\nb"), 5, 1)
    yield "content-length uyuşmazlığı", HANDSHAKE + hdr(request_block(b"/x", b"POST") + lit(b"content-length", b"5"), 4, 1) + frame(DATA, 1, 1, b"ab")
    yield "content-length sayı değil", HANDSHAKE + hdr(request_block() + lit(b"content-length", b"abc"), 5, 1)
    yield "CONTINUATION akışsız", HANDSHAKE + frame(CONT, 4, 1, request_block())
    yield "CONTINUATION yanlış akış", HANDSHAKE + hdr(request_block(), 0, 1) + frame(CONT, 4, 3, b"")
    yield "HEADERS sonrası araya PING", HANDSHAKE + hdr(request_block(), 0, 1) + frame(PING, 0, 0, b"12345678")
    yield "CONTINUATION seli (asla END_HEADERS)", HANDSHAKE + hdr(b"", 0, 1) + b"".join(frame(CONT, 0, 1, big(16000)) for _ in range(40))
    yield "DATA akış 0", HANDSHAKE + frame(DATA, 0, 0, b"x")
    yield "DATA idle akış", HANDSHAKE + frame(DATA, 1, 7, b"x")
    yield "DATA padding > yük", HANDSHAKE + hdr(request_block(b"/x", b"POST"), 4, 1) + frame(DATA, 0x9, 1, b"\xff")
    yield "DATA END_STREAM sonrası DATA", HANDSHAKE + hdr(request_block(b"/x", b"POST"), 4, 1) + frame(DATA, 1, 1, b"a") + frame(DATA, 0, 1, b"b")
    yield "pencereyi aşan DATA", HANDSHAKE + hdr(request_block(b"/x", b"POST"), 4, 1) + b"".join(frame(DATA, 0, 1, big(16384)) for _ in range(80))
    yield "RST_STREAM akış 0", HANDSHAKE + frame(RST, 0, 0, struct.pack(">I", 8))
    yield "RST_STREAM idle akış", HANDSHAKE + frame(RST, 0, 9, struct.pack(">I", 8))
    yield "RST_STREAM uzunluk 3", HANDSHAKE + frame(RST, 0, 1, b"abc")
    yield "PRIORITY akış 0", HANDSHAKE + frame(PRIORITY, 0, 0, b"\x00" * 5)
    yield "PUSH_PROMISE", HANDSHAKE + frame(PUSH, 4, 1, struct.pack(">I", 2) + b"")
    yield "PING akış 1", HANDSHAKE + frame(PING, 0, 1, b"12345678")
    yield "GOAWAY kısa", HANDSHAKE + frame(GOAWAY, 0, 0, b"abc")
    yield "GOAWAY sonrası istek", HANDSHAKE + frame(GOAWAY, 0, 0, struct.pack(">II", 0, 0)) + hdr(request_block(), 5, 1)
    yield "bilinmeyen çerçeve türleri", HANDSHAKE + b"".join(frame(t, 0xFF, 0, b"zz") for t in range(10, 40)) + hdr(request_block(), 5, 1)
    yield "çok sayıda SETTINGS", HANDSHAKE + frame(SETTINGS, 0, 0) * 6000
    yield "çok sayıda PING", HANDSHAKE + frame(PING, 0, 0, b"12345678") * 6000
    yield "çok sayıda PRIORITY", HANDSHAKE + frame(PRIORITY, 0, 1, b"\x00\x00\x00\x00\x10") * 6000
    yield "boş DATA seli", HANDSHAKE + hdr(request_block(b"/x", b"POST"), 4, 1) + frame(DATA, 0, 1) * 6000
    sid = 1
    rr = b""
    for _ in range(800):
        rr += hdr(request_block(b"/slow"), 5, sid) + frame(RST, 0, sid, struct.pack(">I", 8))
        sid += 2
    yield "rapid reset (800 akış)", HANDSHAKE + rr
    many = b""
    for i in range(300):
        many += hdr(request_block(b"/health"), 5, 1 + 2 * i)
    yield "300 eşzamanlı istek", HANDSHAKE + many


def mutate(rng, base):
    b = bytearray(base)
    for _ in range(rng.randint(1, 8)):
        op = rng.random()
        if op < 0.5 and b:
            b[rng.randrange(len(b))] = rng.randrange(256)
        elif op < 0.65 and b:
            i = rng.randrange(len(b))
            del b[i : i + rng.randint(1, 12)]
        elif op < 0.85:
            i = rng.randrange(len(b) + 1)
            b[i:i] = bytes(rng.randrange(256) for _ in range(rng.randint(1, 20)))
        elif b:
            i = rng.randrange(len(b))
            b[i:i] = b[i : i + rng.randint(1, 60)]
    if rng.random() < 0.2 and b:
        del b[rng.randrange(len(b)) :]
    return bytes(b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--noxc", default=os.path.join(ROOT, "zig-out/bin/noxc"))
    ap.add_argument("--iterations", type=int, default=1000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--backend", default="")
    ap.add_argument("--case-timeout", type=float, default=6.0)
    a = ap.parse_args()

    work = tempfile.mkdtemp(prefix="h2-fuzz-")
    port = free_port()
    src = os.path.join(work, "srv.nox")
    open(src, "w").write(SERVER_SRC.format(port=port))
    exe = os.path.join(work, "srv")
    cmd = [a.noxc, "build", src, "-o", exe] + (["--backend", a.backend] if a.backend else [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        return 1
    log = open(os.path.join(work, "server.log"), "w")
    srv = subprocess.Popen([exe], stdout=log, stderr=subprocess.STDOUT)
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            break
        except OSError:
            time.sleep(0.05)

    failures = []

    def verify(label):
        if srv.poll() is not None:
            failures.append((label, f"sunucu öldü (kod {srv.returncode})"))
            return False
        if not h2_health(port):
            failures.append((label, "taze h2 bağlantısında /health 200 dönmedi"))
            return False
        if not h1_health(port):
            failures.append((label, "HTTP/1.1 /health 200 dönmedi"))
            return False
        return True

    rng = random.Random(a.seed)
    allc = list(cases())
    count = 0
    for name, payload in allc:
        t0 = time.time()
        exchange(port, payload, wait=1.5)
        if time.time() - t0 > a.case_timeout:
            failures.append((name, "askıda kaldı"))
        if not verify(name):
            break
        count += 1
    # Geçerli konuşmanın mutasyonları.
    base = HANDSHAKE + frame(HEADERS, 5, 1, request_block()) + frame(HEADERS, 4, 3, request_block(b"/x", b"POST")) + frame(DATA, 1, 3, b"hello") + frame(PING, 0, 0, b"12345678")
    it = 0
    while not failures and it < a.iterations:
        payload = mutate(rng, rng.choice([base, b"".join(p for _, p in rng.sample(allc, 3))]))
        exchange(port, payload, wait=0.4)
        if it % 25 == 24 and not verify(f"mutasyon #{it} (tohum {a.seed})"):
            break
        it += 1
    if not failures:
        verify("son")

    srv.terminate()
    try:
        srv.wait(timeout=15)
    except subprocess.TimeoutExpired:
        srv.kill()
        failures.append(("kapanış", "SIGTERM'e 15 sn içinde yanıt vermedi"))
    log.close()
    out = open(os.path.join(work, "server.log")).read()
    if "leak detected" in out or "panic" in out or "Segmentation" in out:
        failures.append(("günlük", "sızıntı/panik raporu: " + out[:300]))
    if failures:
        for label, why in failures:
            print(f"FAIL {label}: {why}")
        print(f"günlük: {work}/server.log")
        return 1
    import shutil

    shutil.rmtree(work, ignore_errors=True)
    print(f"http2 fuzz: temiz ({count} yapısal vaka, {it} mutasyon)")
    return 0


sys.exit(main())
