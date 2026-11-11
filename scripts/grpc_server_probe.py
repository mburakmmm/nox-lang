#!/usr/bin/env python3
"""nox.grpc_server'ı GERÇEK bir gRPC istemcisine (grpcio) karşı sınar (v2.1.41): unary, sunucu/istemci akışı, hata durumu (yüzde-kodlu ileti), bilinmeyen yöntem, büyük mesajlar
(akış denetimi), gzip'li istek. Kullanım: grpc_server_probe.py <noxc>. Sunucu iki arka uçta (LLVM, QBE) başlatılır. Çıkış 0 = başarılı, 77 = grpcio yok."""
import os

os.environ.setdefault("GRPC_ENABLE_FORK_SUPPORT", "0")
import socket
import subprocess
import sys
import tempfile
import time

try:
    import grpc
except ImportError:
    print("skip: grpcio yok")
    sys.exit(77)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
noxc = sys.argv[1]
template = open(os.path.join(ROOT, "tests/golden/grpc_server_program.nox.in")).read()
ident = lambda b: b


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def check(cond, what):
    if not cond:
        print("BAŞARISIZ:", what)
        sys.exit(1)


for backend in ("llvm", "qbe"):
    port = free_port()
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "server.nox")
        open(path, "w").write(template.replace("@PORT@", str(port)))
        proc = subprocess.Popen([noxc, "run", "--backend", backend, path], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            up = False
            for _ in range(200):
                if proc.poll() is not None:
                    break
                try:
                    socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                    up = True
                    break
                except OSError:
                    time.sleep(0.1)
            if not up:
                print(f"[{backend}] sunucu açılmadı\n{proc.stderr.read()[:1500]}")
                sys.exit(1)
            ch = grpc.insecure_channel(f"127.0.0.1:{port}", options=[("grpc.max_receive_message_length", 64 * 1024 * 1024), ("grpc.max_send_message_length", 64 * 1024 * 1024)])
            unary = ch.unary_unary("/test.Echo/Unary", request_serializer=ident, response_deserializer=ident)
            check(unary(b"hello", timeout=10) == b"hello", f"[{backend}] unary")
            check(unary(b"", timeout=10) == b"", f"[{backend}] boş mesaj")
            count = ch.unary_stream("/test.Echo/Count", request_serializer=ident, response_deserializer=ident)
            check(list(count(b"3", timeout=10)) == [b"1", b"2", b"3"], f"[{backend}] sunucu akışı")
            collect = ch.stream_unary("/test.Echo/Collect", request_serializer=ident, response_deserializer=ident)
            check(collect(iter([b"a", b"b", b"c"]), timeout=10) == b"abc", f"[{backend}] istemci akışı")
            fail = ch.unary_unary("/test.Echo/Fail", request_serializer=ident, response_deserializer=ident)
            try:
                fail(b"x", timeout=10)
                check(False, f"[{backend}] hata beklenirdi")
            except grpc.RpcError as e:
                check(e.code() == grpc.StatusCode.NOT_FOUND, f"[{backend}] durum kodu {e.code()}")
                check(e.details() == "no such user: 100% ü", f"[{backend}] ileti {e.details()!r}")
            nomethod = ch.unary_unary("/test.Echo/Nope", request_serializer=ident, response_deserializer=ident)
            try:
                nomethod(b"x", timeout=10)
                check(False, f"[{backend}] UNIMPLEMENTED beklenirdi")
            except grpc.RpcError as e:
                check(e.code() == grpc.StatusCode.UNIMPLEMENTED, f"[{backend}] bilinmeyen yöntem {e.code()}")
            big = b"z" * 300000
            check(unary(big, timeout=30) == big, f"[{backend}] büyük istek+yanıt")
            bigr = ch.unary_unary("/test.Echo/Big", request_serializer=ident, response_deserializer=ident)
            check(len(bigr(b"2000000", timeout=30)) == 2000000, f"[{backend}] 2 MB yanıt")
            check(unary(b"gz" * 5000, compression=grpc.Compression.Gzip, timeout=10) == b"gz" * 5000, f"[{backend}] gzip'li istek")
            for i in range(20):
                check(unary(str(i).encode(), timeout=10) == str(i).encode(), f"[{backend}] ardışık çağrı {i}")
            # --- gerçek çift yönlü akış: her yanıt, sonraki istek GÖNDERİLMEDEN gelmeli ---
            bidi = ch.stream_stream("/test.Echo/Bidi", request_serializer=ident, response_deserializer=ident)
            import queue, threading
            q = queue.Queue()
            sentinel = object()

            def requests():
                while True:
                    item = q.get()
                    if item is sentinel:
                        return
                    yield item

            call = bidi(requests(), timeout=30)
            for word in (b"one", b"two", b"three"):
                q.put(word)
                reply = next(call)
                check(reply == b"echo:" + word, f"[{backend}] çift yönlü yanıt {reply!r} (istek {word!r})")
            big_msg = b"b" * 200000
            q.put(big_msg)
            check(next(call) == b"echo:" + big_msg, f"[{backend}] çift yönlü büyük mesaj")
            q.put(sentinel)
            check(list(call) == [], f"[{backend}] çift yönlü akış sonu")
            check(call.code() == grpc.StatusCode.OK, f"[{backend}] çift yönlü durum {call.code()}")
            # akış ortasında hata: ilk yanıt gelir, sonra durum
            bidi_fail = ch.stream_stream("/test.Echo/BidiFail", request_serializer=ident, response_deserializer=ident)
            fcall = bidi_fail(iter([b"x"]), timeout=30)
            got = []
            try:
                for r in fcall:
                    got.append(r)
            except grpc.RpcError as e:
                check(e.code() == grpc.StatusCode.FAILED_PRECONDITION, f"[{backend}] akış içi hata kodu {e.code()}")
            check(got == [b"first:x"], f"[{backend}] akış içi hata öncesi yanıt {got}")
            ch.close()
        finally:
            # `noxc run` sunucuyu alt süreç olarak başlatır: tüm süreç grubunu öldür (yoksa stderr borusu açık kalır).
            try:
                os.killpg(proc.pid, 9)
            except OSError:
                proc.kill()
            err = proc.stderr.read()
            if err.strip():
                print(f"[{backend}] sunucu stderr:\n{err[:1500]}")
                sys.exit(1)
print("ok")
