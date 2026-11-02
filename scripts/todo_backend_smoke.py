#!/usr/bin/env python3
"""examples/todo-backend uçtan uca duman + hafif yük testi.

Kullanım: scripts/todo_backend_smoke.py [--noxc zig-out/bin/noxc] [--backend qbe|llvm] [--requests 400]
Uygulamayı derler, çalıştırır; kayıt/giriş/CRUD/yetki/CORS/hız sınırı yalıtımını sınar, eşzamanlı /health yükü gönderir,
SIGTERM verir ve temiz kapanışı ("stopped cleanly") doğrular. Hata varsa çıkış kodu 1.
"""
import argparse, json, os, signal, socket, subprocess, sys, tempfile, threading, time
import urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def call(base, method, path, body=None, token=None, headers=None):
    h = dict(headers or {})
    if token:
        h["Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw and r.headers.get("Content-Type", "").startswith("application/json") else raw), r.headers
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw), e.headers
        except ValueError:
            return e.code, raw, e.headers


failures = []


def start_server(exe, work, port, extra_env, name):
    env = dict(os.environ, PORT=str(port), TODO_DB=os.path.join(work, name + ".db"), **extra_env)
    log = open(os.path.join(work, name + ".log"), "w")
    srv = subprocess.Popen([exe], env=env, stdout=log, stderr=subprocess.STDOUT)
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            break
        except OSError:
            time.sleep(0.05)
    return srv, log


def stop_server(srv, log, work, name):
    srv.send_signal(signal.SIGTERM)
    try:
        srv.wait(timeout=15)
    except subprocess.TimeoutExpired:
        srv.kill()
        failures.append("sunucu SIGTERM'e 15 sn içinde yanıt vermedi")
    log.close()
    out = open(os.path.join(work, name + ".log")).read()
    check(srv.returncode == 0, f"[{name}] çıkış kodu 0 (gerçek: {srv.returncode})")
    check("stopped cleanly" in out, f"[{name}] graceful shutdown sonrası temizlik kodu çalıştı")
    check("uncaught exception" not in out, f"[{name}] yakalanmamış istisna yok")
    check("leak detected" not in out, f"[{name}] bellek sızıntısı raporu yok")


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--noxc", default=os.path.join(ROOT, "zig-out/bin/noxc"))
    ap.add_argument("--backend", default="")
    ap.add_argument("--requests", type=int, default=400)
    a = ap.parse_args()

    work = tempfile.mkdtemp(prefix="todo-smoke-")
    exe = os.path.join(work, "todo")
    cmd = [a.noxc, "build", os.path.join(ROOT, "examples/todo-backend/app.nox"), "-o", exe]
    if a.backend:
        cmd += ["--backend", a.backend]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        return 1

    port = free_port()
    base = f"http://127.0.0.1:{port}"
    srv, log = start_server(exe, work, port, {"RATE_LIMIT": "100000"}, "main")
    try:
        st, body, hdr = call(base, "GET", "/health")
        check(st == 200 and body == "ok", "GET /health -> 200 ok")
        check(bool(hdr.get("X-Request-Id")) and hdr.get("X-Content-Type-Options") == "nosniff", "istek kimliği + güvenlik başlıkları")
        st, _, hdr = call(base, "GET", "/health", headers={"X-Request-Id": "abc-123"})
        check(hdr.get("X-Request-Id") == "abc-123", "güvenli X-Request-Id yansıtılır")

        st, body, _ = call(base, "POST", "/register", {"user": "alice", "password": "hunter2hunter2"})
        check(st == 201, "alice kaydı 201")
        st, _, _ = call(base, "POST", "/register", {"user": "alice", "password": "hunter2hunter2"})
        check(st == 409, "yinelenen kayıt 409")
        st, _, _ = call(base, "POST", "/register", {"user": "x", "password": "short"})
        check(st == 400, "geçersiz kayıt 400")
        st, _, _ = call(base, "POST", "/register", None)
        check(st == 400, "gövdesiz kayıt 400")
        call(base, "POST", "/register", {"user": "bob", "password": "correct horse battery"})

        st, _, _ = call(base, "POST", "/login", {"user": "alice", "password": "nope-nope-nope"})
        check(st == 401, "yanlış parola 401")
        st, body, _ = call(base, "POST", "/login", {"user": "alice", "password": "hunter2hunter2"})
        check(st == 200 and "token" in body, "alice girişi token verir")
        ta = body["token"]
        st, body, _ = call(base, "POST", "/login", {"user": "bob", "password": "correct horse battery"})
        tb = body["token"]

        st, _, _ = call(base, "GET", "/todos")
        check(st == 401, "token'sız /todos 401")
        st, _, _ = call(base, "GET", "/todos", token=ta[:-3] + "xxx")
        check(st == 401, "bozuk imzalı token 401")

        st, body, _ = call(base, "POST", "/todos", {"title": "buy milk"}, ta)
        check(st == 201, "todo oluştur 201")
        tid = body["id"]
        call(base, "POST", "/todos", {"title": "write nox"}, ta)
        st, _, _ = call(base, "POST", "/todos", {"title": ""}, ta)
        check(st == 400, "boş başlık 400")
        st, _, _ = call(base, "PUT", f"/todos/{tid}", {"done": True}, ta)
        check(st == 200, "todo güncelle 200")
        st, body, _ = call(base, "GET", "/todos", token=ta)
        check(st == 200 and [t["done"] for t in body] == [True, False] and body[0]["title"] == "buy milk", "liste alice'in iki todosunu döner")
        st, body, _ = call(base, "GET", "/todos", token=tb)
        check(st == 200 and body == [], "bob alice'in todolarını GÖRMEZ")
        st, _, _ = call(base, "PUT", f"/todos/{tid}", {"done": False}, tb)
        check(st == 404, "bob alice'in todosunu güncelleyemez (404)")
        st, _, _ = call(base, "DELETE", f"/todos/{tid}", token=tb)
        check(st == 404, "bob alice'in todosunu silemez (404)")
        st, _, _ = call(base, "PUT", "/todos/abc", {"done": True}, ta)
        check(st == 400, "sayısal olmayan kimlik 400")
        st, _, _ = call(base, "DELETE", f"/todos/{tid}", token=ta)
        check(st == 204, "todo sil 204")
        st, _, _ = call(base, "GET", "/nope", token=ta)
        check(st == 404, "bilinmeyen yol 404")

        st, _, hdr = call(base, "OPTIONS", "/todos", headers={"Origin": "http://localhost:3000", "Access-Control-Request-Method": "POST"})
        check(st == 204 and hdr.get("Access-Control-Allow-Origin") == "http://localhost:3000", "CORS ön uçuş izinli kaynak 204")
        st, _, _ = call(base, "OPTIONS", "/todos", headers={"Origin": "http://evil.example", "Access-Control-Request-Method": "POST"})
        check(st == 403, "CORS ön uçuş yabancı kaynak 403")

        # Eşzamanlı yük: 8 istemci aynı anda /health (varsayılan LLVM'de bağlantılar farklı işçilerde çalışır; hepsi 200 olmalı).
        ok = [0]
        lock = threading.Lock()
        per = max(1, a.requests // 8)

        def worker():
            for _ in range(per):
                s, _, _ = call(base, "GET", "/health")
                if s == 200:
                    with lock:
                        ok[0] += 1

        ts = [threading.Thread(target=worker) for _ in range(8)]
        t0 = time.time()
        [t.start() for t in ts]
        [t.join() for t in ts]
        check(ok[0] == per * 8, f"{per * 8} eşzamanlı istek yanıtlandı ({time.time() - t0:.1f} sn)")
    finally:
        stop_server(srv, log, work, "main")

    # Hız sınırı: işçi başına sayaç olduğundan küçük limit + çok sıralı istek (güvercin yuvası: birkaç işçiden biri mutlaka aşar).
    port2 = free_port()
    srv2, log2 = start_server(exe, work, port2, {"RATE_LIMIT": "3"}, "limited")
    try:
        results = [call(f"http://127.0.0.1:{port2}", "GET", "/health") for _ in range(80)]
        limited = [h for st, _, h in results if st == 429]
        check(len(limited) > 0, f"hız sınırı aşılınca 429 döner ({len(limited)}/80)")
        check(all(int(h.get("Retry-After", "0")) >= 1 for h in limited), "429 yanıtları Retry-After taşır")
        check(all(st in (200, 429) for st, _, _ in results), "sınırlı örnekte yalnızca 200/429 döner")
    finally:
        stop_server(srv2, log2, work, "limited")
    if failures:
        print(f"\n{len(failures)} başarısız; günlükler: {work}")
        return 1
    import shutil
    shutil.rmtree(work, ignore_errors=True)
    print("\ntodo-backend duman testi: temiz")
    return 0


sys.exit(main())
