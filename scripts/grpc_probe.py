#!/usr/bin/env python3
"""nox.grpc'yi GERÇEK bir gRPC sunucusuna (grpcio) karşı sınar (v2.1.33): unary, sunucu/istemci akışı, hata durumu + yüzde-kodlu ileti, üst veri/trailer, akış denetimi (300 KB istek,
2 MB yanıt), bilinmeyen metot. Kullanım: grpc_probe.py <noxc>. İki arka uçta (LLVM, QBE) çalıştırılır; stdout `tests/golden/grpc_program.expected` ile aynı olmalıdır.
Çıkış 0 = başarılı, 77 = grpcio yok (atlandı)."""
import os

os.environ.setdefault("GRPC_ENABLE_FORK_SUPPORT", "0")  # grpcio'nun fork işleyicisi alt süreçlerin stderr'ine gürültü yazar
import subprocess
import sys
import tempfile
from concurrent import futures

try:
    import grpc
except ImportError:
    print("skip: grpcio yok")
    sys.exit(77)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
noxc = sys.argv[1]


class Handler(grpc.GenericRpcHandler):
    def service(self, details):
        m = details.method
        ident = lambda b: b
        if m == "/test.Echo/Unary":
            return grpc.unary_unary_rpc_method_handler(lambda req, ctx: req, request_deserializer=ident, response_serializer=ident)
        if m == "/test.Echo/Count":
            def count(req, ctx):
                for i in range(int(req.decode())):
                    yield str(i + 1).encode()
            return grpc.unary_stream_rpc_method_handler(count, request_deserializer=ident, response_serializer=ident)
        if m == "/test.Echo/Collect":
            def collect(it, ctx):
                return b"".join(it)
            return grpc.stream_unary_rpc_method_handler(collect, request_deserializer=ident, response_serializer=ident)
        if m == "/test.Echo/Fail":
            def fail(req, ctx):
                ctx.abort(grpc.StatusCode.NOT_FOUND, "no such user")
            return grpc.unary_unary_rpc_method_handler(fail, request_deserializer=ident, response_serializer=ident)
        if m == "/test.Echo/Meta":
            def meta(req, ctx):
                md = dict(ctx.invocation_metadata())
                ctx.send_initial_metadata((("x-reply", md.get("x-token", "")),))
                ctx.set_trailing_metadata((("x-trailer", "trailer-val"),))
                return req
            return grpc.unary_unary_rpc_method_handler(meta, request_deserializer=ident, response_serializer=ident)
        if m == "/test.Echo/Bidi":
            def bidi(it, ctx):
                for req in it:
                    yield b"echo:" + req
            return grpc.stream_stream_rpc_method_handler(bidi, request_deserializer=ident, response_serializer=ident)
        if m == "/test.Echo/Big":
            return grpc.unary_unary_rpc_method_handler(lambda req, ctx: b"y" * int(req.decode()), request_deserializer=ident, response_serializer=ident)
        return None


server = grpc.server(futures.ThreadPoolExecutor(max_workers=4), compression=grpc.Compression.Gzip, options=[("grpc.max_send_message_length", 64 * 1024 * 1024), ("grpc.max_receive_message_length", 64 * 1024 * 1024)])
server.add_generic_rpc_handlers((Handler(),))
port = server.add_insecure_port("127.0.0.1:0")
server.start()
expected = open(os.path.join(ROOT, "tests/golden/grpc_program.expected")).read()
template = open(os.path.join(ROOT, "tests/golden/grpc_program.nox.in")).read()
rc = 0
for backend in ("llvm", "qbe"):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "app.nox")
        open(path, "w").write(template.replace("@PORT@", str(port)))
        r = subprocess.run([noxc, "run", "--backend", backend, path], capture_output=True, text=True, timeout=120)
        if r.returncode != 0 or r.stdout != expected or r.stderr.strip():
            print(f"[{backend}] başarısız rc={r.returncode}\n--- stdout\n{r.stdout}\n--- beklenen\n{expected}\n--- stderr\n{r.stderr[:1500]}")
            rc = 1
server.stop(0)

# --- TLS (ALPN h2): kendinden imzalı sertifika + özel CA ---
import shutil

if shutil.which("openssl"):
    with tempfile.TemporaryDirectory() as tdir:
        key, cert = os.path.join(tdir, "key.pem"), os.path.join(tdir, "cert.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "2", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"], check=True, capture_output=True)
        tserver = grpc.server(futures.ThreadPoolExecutor(max_workers=4), options=[("grpc.max_receive_message_length", 64 * 1024 * 1024)])
        tserver.add_generic_rpc_handlers((Handler(),))
        creds = grpc.ssl_server_credentials([(open(key, "rb").read(), open(cert, "rb").read())])
        tport = tserver.add_secure_port("127.0.0.1:0", creds)
        tserver.start()
        ttemplate = open(os.path.join(ROOT, "tests/golden/grpc_tls_program.nox.in")).read()
        texpected = open(os.path.join(ROOT, "tests/golden/grpc_tls_program.expected")).read()
        for backend in ("llvm", "qbe"):
            path = os.path.join(tdir, "tls_app.nox")
            open(path, "w").write(ttemplate.replace("@PORT@", str(tport)).replace("@CA@", cert))
            r = subprocess.run([noxc, "run", "--backend", backend, path], capture_output=True, text=True, timeout=120)
            if r.returncode != 0 or r.stdout != texpected or r.stderr.strip():
                print(f"[tls {backend}] başarısız rc={r.returncode}\n--- stdout\n{r.stdout}\n--- beklenen\n{texpected}\n--- stderr\n{r.stderr[:1500]}")
                rc = 1
        tserver.stop(0)
print("ok" if rc == 0 else "FAIL")
sys.exit(rc)
