#!/usr/bin/env python3
"""noxpkg yayıncı kimliği uçtan uca duman testi (GERÇEK sunucu, SAHTE GitHub).

Sunucuyu (`services/noxpkg/main.nox`) derler, geçici bir dizinde çalıştırır ve GitHub aygıt akışını yerel bir sahte GitHub'a yönlendirir
(`NOXPKG_GITHUB_BASE`/`NOXPKG_GITHUB_API`). Doğruladıkları:
  * girişsiz `POST /api/publish` 401; aygıt akışı pending -> ok, jeton döner; `whoami`; çıkışta jeton iptal;
  * ad ilk yayımlayana rezerve: ikinci bir GitHub hesabı aynı adı yayımlayamaz (403, sahibin adıyla);
  * eski (sahipsiz) kayıtlar yönetici GitHub hesabı girince ona geçer; o zamana kadar başkası alamaz;
  * yönetim panelinde bekleyen gönderinin ve yayında paketin yayıncısı + "Yayıncılar" bölümü; paket sayfasında "Yayınlayan";
  * GERÇEK `noxc` istemcisi: login (0600 credentials), whoami, publish (jetonlu), logout (sunucuda iptal), girişsiz publish reddi.

Kullanım: scripts/noxpkg_auth_smoke.py [--noxc zig-out/bin/noxc]
Hata varsa çıkış kodu 1. `sqlite3` Python standart kütüphanesindedir; sunucu `libsqlite3`ü çalışma zamanında yükler.
"""
import argparse
import http.server
import json
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


# ---- sahte GitHub --------------------------------------------------------------------------------------------------------------------------
USERS = {"gho_alice": (1001, "alice"), "gho_bob": (1002, "bob"), "gho_admin": (1, "AdminUser")}
approved = {}  # device_code -> access_token (kullanıcı github.com/login/device'ta onayladı)
polls = {}


class FakeGithub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, status, obj):
        b = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        form = dict(p.split("=", 1) for p in self.rfile.read(n).decode().split("&") if "=" in p)
        if self.path == "/login/device/code":
            if form.get("client_id") != "test-client":
                return self._send(200, {"error": "incorrect_client_credentials"})
            code = f"dev{len(approved) + len(polls)}"
            polls[code] = 0
            return self._send(200, {"device_code": code, "user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 1})
        if self.path == "/login/oauth/access_token":
            code = form.get("device_code", "")
            polls[code] = polls.get(code, 0) + 1
            if code in approved:
                return self._send(200, {"access_token": approved.pop(code), "token_type": "bearer", "scope": ""})
            return self._send(200, {"error": "authorization_pending"})
        self._send(404, {})

    def do_GET(self):
        if self.path == "/user":
            tok = (self.headers.get("Authorization") or "").replace("Bearer ", "")
            if tok in USERS:
                uid, login = USERS[tok]
                return self._send(200, {"id": uid, "login": login, "avatar_url": "https://avatars.example/u/" + str(uid)})
            return self._send(401, {"message": "Bad credentials"})
        self._send(404, {})


# ---- yardımcılar ---------------------------------------------------------------------------------------------------------------------------
def call(base, method, path, body=None, token=None, headers=None):
    h = dict(headers or {})
    if token:
        h["Authorization"] = "Bearer " + token
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read().decode(), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), e.headers


def jcall(*a, **k):
    st, body, hd = call(*a, **k)
    try:
        return st, json.loads(body)
    except ValueError:
        return st, {"_raw": body}


def login(base, github_token):
    """noxc login'in yaptığının aynısı: start -> (kullanıcı onaylar) -> poll."""
    st, ds = jcall(base, "POST", "/api/auth/device/start")
    assert st == 200 and ds.get("ok"), (st, ds)
    code = ds["device_code"]
    st, p = jcall(base, "POST", "/api/auth/device/poll", {"device_code": code})
    assert p.get("status") == "pending", p
    approved[code] = github_token
    for _ in range(10):
        st, p = jcall(base, "POST", "/api/auth/device/poll", {"device_code": code})
        if p.get("status") == "ok":
            return p
        time.sleep(0.3)
    raise AssertionError(p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--noxc", default=os.path.join(ROOT, "zig-out/bin/noxc"))
    a = ap.parse_args()

    work = tempfile.mkdtemp(prefix="noxpkg-auth-")
    gh = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGithub)
    threading.Thread(target=gh.serve_forever, daemon=True).start()
    gh_base = f"http://127.0.0.1:{gh.server_address[1]}"

    exe = os.path.join(work, "noxpkg")
    r = subprocess.run([a.noxc, "build", os.path.join(ROOT, "services/noxpkg/main.nox"), "-o", exe], capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        return 1
    run_dir = os.path.join(work, "run")
    os.makedirs(os.path.join(run_dir, "data"))
    shutil.copytree(os.path.join(ROOT, "services/noxpkg/static"), os.path.join(run_dir, "static"))
    pw_hash = subprocess.run([a.noxc, "run", os.path.join(ROOT, "services/noxpkg/scripts/gen_admin_hash.nox"), "--", "smoke-pass-123"], capture_output=True, text=True).stdout.strip()

    port = free_port()
    env = dict(os.environ, NOXPKG_PORT=str(port), NOXPKG_SESSION_SECRET="smoke-secret-0123456789abcdef", NOXPKG_ADMIN_PASSWORD_HASH=pw_hash,
               NOXPKG_ADMIN_GITHUB="adminuser", NOXPKG_GITHUB_CLIENT_ID="test-client", NOXPKG_GITHUB_BASE=gh_base, NOXPKG_GITHUB_API=gh_base)
    log = open(os.path.join(work, "server.log"), "w")
    srv = subprocess.Popen([exe], cwd=run_dir, env=env, stdout=log, stderr=subprocess.STDOUT)
    base = f"http://127.0.0.1:{port}"
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            break
        except OSError:
            time.sleep(0.05)

    try:
        # 1) girişsiz yayın kapalı
        st, j = jcall(base, "POST", "/api/publish", {"name": "alpha", "repo": "github.com/alice/alpha"})
        check(st == 401 and "noxc login" in j.get("error", ""), f"girişsiz publish 401 ve yönlendirme ({st} {j})")
        st, j = jcall(base, "POST", "/api/publish", {"name": "alpha", "repo": "github.com/alice/alpha"}, token="nxp_" + "0" * 64)
        check(st == 401, f"geçersiz jeton 401 ({st})")

        # 2) aygıt akışı
        alice = login(base, "gho_alice")
        check(alice.get("login") == "alice" and alice.get("token", "").startswith("nxp_"), f"alice girişi (login={alice.get('login')})")
        st, j = jcall(base, "GET", "/api/auth/whoami", token=alice["token"])
        check(st == 200 and j.get("login") == "alice" and j.get("github_id") == 1001, f"whoami ({st} {j})")

        # 3) yayın + ad rezervi
        st, j = jcall(base, "POST", "/api/publish", {"name": "alpha", "repo": "github.com/alice/alpha", "description": "ilk", "tags": ["a"]}, token=alice["token"])
        check(st == 200 and j.get("ok") and j.get("publisher") == "alice", f"alice 'alpha' gönderir ({st} {j})")
        bob = login(base, "gho_bob")
        st, j = jcall(base, "POST", "/api/publish", {"name": "alpha", "repo": "github.com/bob/alpha"}, token=bob["token"])
        check(st == 403 and "@alice" in j.get("error", ""), f"bob 'alpha' adını alamaz, sahip adı söylenir ({st} {j})")
        st, j = jcall(base, "POST", "/api/publish", {"name": "alpha", "repo": "github.com/alice/alpha", "ref": "v2"}, token=alice["token"])
        check(st == 200, f"alice kendi adını güncelleyebilir ({st})")
        st, j = jcall(base, "POST", "/api/publish", {"name": "beta", "repo": "github.com/bob/beta"}, token=bob["token"])
        check(st == 200, f"bob başka bir ad alabilir ({st})")

        # 3b) onay kuyruğu: tekrarlar tek satıra iner; onaylı paketin aynı sahibi aynı repoyu onaysız günceller; repo değişimi onaya düşer
        for ref in ("v3", "v4"):
            jcall(base, "POST", "/api/publish", {"name": "alpha", "repo": "github.com/alice/alpha", "ref": ref, "description": "son"}, token=alice["token"])
        db = sqlite3.connect(os.path.join(run_dir, "data/noxpkg.db"))
        rows = db.execute("SELECT ref, description FROM submissions WHERE name = 'alpha'").fetchall()
        check(rows == [("v4", "son")], f"aynı paket için tek bekleyen satır, en yeni içerikle ({rows})")
        db.execute("INSERT INTO packages (name, repo, description, tags, created_at_ms, publisher_id) SELECT name, repo, description, tags, 1, publisher_id FROM submissions WHERE name = 'alpha'")
        db.execute("DELETE FROM submissions WHERE name = 'alpha'")
        db.commit()
        db.close()
        st, j = jcall(base, "POST", "/api/publish", {"name": "alpha", "repo": "github.com/alice/alpha", "description": "yeni sürüm", "tags": ["z"]}, token=alice["token"])
        check(st == 200 and j.get("status") == "published" and j.get("id") == "", f"onaylı paketin aynı repo güncellemesi onaysız yayımlanır ({st} {j})")
        db = sqlite3.connect(os.path.join(run_dir, "data/noxpkg.db"))
        pend = db.execute("SELECT COUNT(*) FROM submissions WHERE name = 'alpha'").fetchone()[0]
        desc = db.execute("SELECT description FROM packages WHERE name = 'alpha'").fetchone()[0]
        db.close()
        check(pend == 0 and desc == "yeni sürüm", f"güncelleme katalogda, kuyrukta satır yok ({pend} {desc!r})")
        st, j = jcall(base, "POST", "/api/publish", {"name": "alpha", "repo": "github.com/alice/alpha-fork"}, token=alice["token"])
        check(st == 200 and j.get("status") == "pending" and j.get("id"), f"repo değişimi yine onaya düşer ({st} {j})")
        db = sqlite3.connect(os.path.join(run_dir, "data/noxpkg.db"))
        db.execute("DELETE FROM submissions WHERE name = 'alpha'")
        db.commit()
        db.close()

        # 4) eski (sahipsiz) kayıt: yönetici GitHub hesabı girene kadar başkası alamaz, girince ona geçer
        db = sqlite3.connect(os.path.join(run_dir, "data/noxpkg.db"))
        db.execute("INSERT INTO packages (name, repo, description, tags, created_at_ms) VALUES ('legacy-pkg', 'github.com/old/legacy-pkg', 'eski', '[]', 1)")
        db.commit()
        db.close()
        st, j = jcall(base, "POST", "/api/publish", {"name": "legacy-pkg", "repo": "github.com/bob/legacy-pkg"}, token=bob["token"])
        check(st == 403 and "reserved" in j.get("error", ""), f"eski kayıt başkasına kapalı ({st} {j})")
        adm = login(base, "gho_admin")
        check(adm.get("login") == "AdminUser", "yönetici GitHub hesabı girer (büyük/küçük harf duyarsız eşleşir)")
        db = sqlite3.connect(os.path.join(run_dir, "data/noxpkg.db"))
        owner = db.execute("SELECT u.login FROM packages k JOIN publishers u ON u.id = k.publisher_id WHERE k.name = 'legacy-pkg'").fetchone()
        db.close()
        check(owner == ("AdminUser",), f"eski kayıt yöneticiye atandı ({owner})")
        st, j = jcall(base, "POST", "/api/publish", {"name": "legacy-pkg", "repo": "github.com/bob/legacy-pkg"}, token=bob["token"])
        check(st == 403 and "@AdminUser" in j.get("error", ""), f"atamadan sonra ad yöneticiye aittir ({st} {j})")

        # 5) yönetim paneli + paket sayfası
        st, body, hd = call(base, "POST", "/admin/login", {"username": "admin", "password": "smoke-pass-123"})
        cookie = (hd.get("Set-Cookie") or "").split(";")[0]
        check(st == 200 and cookie, f"admin parola girişi ({st})")
        st, page, _ = call(base, "GET", "/admin", headers={"Cookie": cookie})
        check(st == 200 and "@alice" in page and "@bob" in page and "Publishers" in page, f"panel: bekleyen gönderilerde ve Yayıncılar bölümünde yayıncılar ({st} {page[:200]!r})")
        check("repo sahibi" not in page.split("Published")[0] or "github.com/old" in page, "panel: repo sahibi yayıncıyla aynıysa uyarı yok")
        check("@AdminUser" in page, "panel: yayındaki eski paket yöneticiye atfedilir")
        st, page, _ = call(base, "GET", "/p/legacy-pkg")
        check(st == 200 and "Published by" in page and "@AdminUser" in page, f"paket sayfası: Published by @AdminUser ({st} {page[:200]!r})")
        st, idx, _ = call(base, "GET", "/index.json")
        check(st == 200 and "publisher" not in idx, "index.json şeması değişmedi (yayıncı alanı sızmaz)")

        # 6) çıkış jetonu iptal eder
        st, j = jcall(base, "POST", "/api/auth/logout", token=alice["token"])
        check(st == 200, f"logout ({st})")
        st, j = jcall(base, "GET", "/api/auth/whoami", token=alice["token"])
        check(st == 401, f"çıkıştan sonra jeton geçersiz ({st})")
        st, j = jcall(base, "GET", "/api/auth/whoami", token=bob["token"])
        check(st == 200, "başka bir oturumun jetonu etkilenmez")

        # 7) jeton veritabanında düz metin saklanmaz
        db = sqlite3.connect(os.path.join(run_dir, "data/noxpkg.db"))
        stored = [r[0] for r in db.execute("SELECT token_hash FROM api_tokens")]
        db.close()
        check(all(not t.startswith("nxp_") and len(t) == 64 for t in stored) and bob["token"] not in stored, "jetonlar yalnızca SHA-256 özetiyle saklanır")

        # 8) GERÇEK `noxc` istemcisi: login -> whoami -> publish -> logout (aynı sunucuya, sahte GitHub'a karşı)
        cli_home = os.path.join(work, "nox-home")
        proj = os.path.join(work, "proj")
        os.makedirs(proj)
        open(os.path.join(proj, "nox.json"), "w").write('{"name": "clipkg", "entry": "main.nox"}\n')
        cli_env = dict(os.environ, NOX_HOME=cli_home, NOX_PUBLISH_API_BASE=base, NOX_ALLOW_INSECURE_TRANSPORT="1", NOX_NO_BROWSER="1", NO_COLOR="1")

        def noxc(*args, cwd=None):
            return subprocess.run([a.noxc, *args], env=cli_env, cwd=cwd, capture_output=True, text=True, timeout=120)

        r = noxc("publish", "github.com/carol/clipkg", cwd=proj)
        check(r.returncode != 0 and "noxc login" in r.stderr, f"noxc publish girişsiz reddedilir ve login'i söyler ({r.stderr.strip()!r})")
        r = noxc("whoami")
        check(r.returncode != 0 and "not logged in" in r.stderr, "noxc whoami girişsizken hata verir")

        # `noxc login` sırasında kullanıcı GitHub'da onaylar: sahte GitHub, yeni aygıt kodunu görünce onaylar.
        def approve_when_issued():
            for _ in range(200):
                for code, n in list(polls.items()):
                    if n >= 1 and code not in approved and code not in done_codes:
                        done_codes.add(code)
                        approved[code] = "gho_alice"
                        return
                time.sleep(0.1)

        done_codes = set(polls.keys())
        t = threading.Thread(target=approve_when_issued, daemon=True)
        t.start()
        r = noxc("login")
        t.join(timeout=5)
        check(r.returncode == 0 and "logged in as @alice" in r.stderr and "ABCD-1234" in r.stderr, f"noxc login ({r.returncode}) {r.stderr.strip()[-300:]!r}")
        cred_path = os.path.join(cli_home, "credentials")
        check(os.path.exists(cred_path) and (os.stat(cred_path).st_mode & 0o777) == 0o600, "credentials dosyası 0600")
        saved = json.load(open(cred_path))["servers"][0]
        check(saved["login"] == "alice" and saved["token"].startswith("nxp_") and saved["server"] == base, "credentials: sunucu, login ve nxp_ jetonu kayıtlı")
        check("gho_" not in open(cred_path).read(), "GitHub jetonu istemciye hiç inmez")

        r = noxc("whoami")
        check(r.returncode == 0 and "@alice" in r.stderr, f"noxc whoami (@alice) {r.stderr.strip()!r}")
        r = noxc("publish", "github.com/alice/clipkg", "--description", "cli ile", "--tags", "x,y", cwd=proj)
        check(r.returncode == 0 and "as @alice" in r.stderr, f"noxc publish giriş sonrası kabul edilir ({r.stderr.strip()!r})")
        db = sqlite3.connect(os.path.join(run_dir, "data/noxpkg.db"))
        row = db.execute("SELECT u.login FROM submissions s JOIN publishers u ON u.id = s.publisher_id WHERE s.name = 'clipkg'").fetchone()
        db.close()
        check(row == ("alice",), f"gönderi alice'e bağlı ({row})")

        r = noxc("logout")
        check(r.returncode == 0 and "token revoked" in r.stderr, f"noxc logout jetonu sunucuda iptal eder ({r.stderr.strip()!r})")
        st, j = jcall(base, "GET", "/api/auth/whoami", token=saved["token"])
        check(st == 401, "iptal edilen jeton sunucuda artık geçersiz")
        r = noxc("whoami")
        check(r.returncode != 0, "çıkıştan sonra noxc whoami hata verir")
        r = noxc("publish", "github.com/alice/clipkg", cwd=proj)
        check(r.returncode != 0 and "noxc login" in r.stderr, "çıkıştan sonra noxc publish yine reddedilir")
    finally:
        srv.send_signal(signal.SIGTERM)
        try:
            srv.wait(timeout=10)
        except subprocess.TimeoutExpired:
            srv.kill()
        log.close()
        gh.shutdown()

    if failures:
        print(f"\n{len(failures)} başarısız; günlükler: {work}")
        print(open(os.path.join(work, "server.log")).read()[-2000:])
        return 1
    shutil.rmtree(work, ignore_errors=True)
    print("\nnoxpkg yayıncı kimliği duman testi: temiz")
    return 0


sys.exit(main())
