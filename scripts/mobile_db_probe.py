#!/usr/bin/env python3
"""Mobil veritabanı istemcisi sınaması: `nox.postgres` (ve MySQL, `mysql` argümanıyla) iOS simülatöründe / Android emülatöründe GERÇEK bir sunucuya karşı çalışır.
Kullanım: scripts/mobile_db_probe.py ios <simülatör-UDID> [pg|mysql|tls] | scripts/mobile_db_probe.py android [pg|mysql|tls]   (argümansız: hepsi)

`pg`: geçici bir PostgreSQL kümesi (initdb, scram-sha-256) kurulur; `tests/golden/wasm_pg_program.nox.in` (WASM testiyle ortak) mobilde çalıştırılır, çıktı `wasm_pg_program.expected` ile karşılaştırılır.
`mysql`: yerelde bulunan `mysql:8.4` Docker imajından atılabilir bir kapsayıcı (imaj YOKSA atlanır, indirilmez); `tests/golden/wasm_mysql_program.nox.in` ile `wasm_mysql_program.expected`.
`tls`: aynı sunucuda SSL açık ve sertifika kendinden imzalıdır; `sslmode=require` bağlantısının sertifika doğrulanamadığı için REDDEDİLMESİ gerekir (TLS sessizce doğrulamasız kabul edilmemeli).
Android'de sunucuya `adb reverse` ile erişilir. Hepsi geçici dizinlerde çalışır ve bitince temizlenir.
"""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mobile_run  # noqa: E402

ROOT = mobile_run.ROOT
GOLDEN = ROOT / "tests/golden"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def find_pg_bin(name):
    found = shutil.which(name)
    if found:
        return found
    dirs = sorted(Path("/opt/homebrew/opt").glob("postgresql@*/bin")) + sorted(Path("/usr/lib/postgresql").glob("*/bin"))
    for d in reversed(dirs):
        if (d / name).exists():
            return str(d / name)
    return None


class Postgres:
    """Geçici bir PostgreSQL kümesi (parola: sınama değeri 'secret', yalnızca bu geçici kümede)."""

    def __init__(self, ssl=False):
        self.initdb = find_pg_bin("initdb")
        self.pg_ctl = find_pg_bin("pg_ctl")
        if not self.initdb or not self.pg_ctl:
            sys.exit("PostgreSQL ikilileri (initdb/pg_ctl) bulunamadı")
        self.dir = Path(tempfile.mkdtemp(prefix="nox-pg-", dir="/tmp" if Path("/tmp").exists() else None))
        self.data = self.dir / "data"
        self.port = free_port()
        self.ssl = ssl
        self.started = False

    def start(self):
        env = dict(os.environ, LC_ALL="C", LANG="C")
        (self.dir / "pw").write_text("secret")
        subprocess.run([self.initdb, "-D", str(self.data), "-U", "postgres", "--auth=scram-sha-256", "--pwfile", str(self.dir / "pw"), "-E", "UTF8", "--locale=C"],
                       check=True, capture_output=True, env=env)
        opts = f"-p {self.port} -k {self.dir} -c listen_addresses=127.0.0.1 -c fsync=off"
        if self.ssl:
            key, crt = self.data / "server.key", self.data / "server.crt"
            subprocess.run(["openssl", "req", "-new", "-x509", "-days", "1", "-nodes", "-subj", "/CN=localhost", "-out", str(crt), "-keyout", str(key)],
                           check=True, capture_output=True)
            key.chmod(0o600)
            opts += f" -c ssl=on -c ssl_cert_file={crt} -c ssl_key_file={key}"
        r = subprocess.run([self.pg_ctl, "-D", str(self.data), "-o", opts, "-l", str(self.dir / "log"), "-w", "start"], capture_output=True, text=True, env=env)
        if r.returncode != 0:
            log = (self.dir / "log").read_text() if (self.dir / "log").exists() else ""
            sys.exit("postgres başlamadı:\n" + r.stderr + log)
        self.started = True

    def stop(self):
        if self.started:
            subprocess.run([self.pg_ctl, "-D", str(self.data), "-m", "immediate", "-w", "stop"], capture_output=True)
        shutil.rmtree(self.dir, ignore_errors=True)


def forward(ctx, port):
    if ctx["platform"] == "android":
        mobile_run.run([ctx["adb"], "reverse", f"tcp:{port}", f"tcp:{port}"])


def unforward(ctx, port):
    if ctx["platform"] == "android":
        mobile_run.run([ctx["adb"], "reverse", "--remove", f"tcp:{port}"])


def check(label, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + label + (f": {detail}" if detail and not ok else ""), flush=True)
    return ok


def run_nox(ctx, work, name, source):
    src = work / f"{name}.nox"
    src.write_text(source, encoding="utf-8")
    r = mobile_run.run_program(ctx, name, src, work)
    src.unlink(missing_ok=True)
    return r


def probe_pg(ctx, work):
    pg = Postgres()
    ok = True
    try:
        pg.start()
        forward(ctx, pg.port)
        source = (GOLDEN / "wasm_pg_program.nox.in").read_text(encoding="utf-8").replace("__PORT__", str(pg.port))
        r = run_nox(ctx, work, "pg_program", source)
        expected = (GOLDEN / "wasm_pg_program.expected").read_text(encoding="utf-8")
        ok = check("postgres: SCRAM kimlik doğrulama + basit/genişletilmiş protokol", r.status == "ran" and r.stdout == expected,
                   r.detail or f"çıkış {r.returncode}\n--- stdout\n{r.stdout}\n--- stderr\n{r.stderr[:400]}")
    finally:
        unforward(ctx, pg.port)
        pg.stop()
    return ok


TLS_PROGRAM = '''import nox.postgres
from nox.postgres import Connection, PostgresError

# Sunucu SSL açık ama sertifikası kendinden imzalı: sistem CA deposu onu DOĞRULAYAMAZ, bağlantı kurulmamalıdır.
try:
    conn: Connection = nox.postgres.open("host=localhost port=__PORT__ user=postgres password=secret dbname=postgres sslmode=require")
    print("unreachable: TLS dogrulanmadan baglandi")
    conn.close()
except PostgresError as e:
    print("refused: " + e.message)
'''

TLS_UNSUPPORTED_PROGRAM = '''import nox.postgres
from nox.postgres import Connection, PostgresError

# Sunucu SSL desteklemiyor ama sslmode=require: düz metne düşülmemeli.
try:
    conn: Connection = nox.postgres.open("host=127.0.0.1 port=__PORT__ user=postgres password=secret dbname=postgres sslmode=require")
    print("unreachable: TLS olmadan baglandi")
    conn.close()
except PostgresError as e:
    print("refused: " + e.message)
'''


def probe_tls(ctx, work):
    ok = True
    pg = Postgres(ssl=True)
    try:
        pg.start()
        forward(ctx, pg.port)
        r = run_nox(ctx, work, "pg_tls_selfsigned", TLS_PROGRAM.replace("__PORT__", str(pg.port)))
        ok &= check("postgres+TLS: kendinden imzalı sertifika REDDEDİLİR", r.status == "ran" and r.stdout.startswith("refused: ") and "Certificate" in r.stdout, r.detail or f"stdout={r.stdout!r} stderr={r.stderr[:300]}")
        print("     neden:", r.stdout.strip(), flush=True)
    finally:
        unforward(ctx, pg.port)
        pg.stop()
    pg2 = Postgres(ssl=False)
    try:
        pg2.start()
        forward(ctx, pg2.port)
        r = run_nox(ctx, work, "pg_tls_unsupported", TLS_UNSUPPORTED_PROGRAM.replace("__PORT__", str(pg2.port)))
        ok &= check("postgres+TLS: sslmode=require ve sunucu TLS'siz iken düz metne DÜŞÜLMEZ", r.status == "ran" and r.stdout.startswith("refused: ") and "does not support TLS" in r.stdout, r.detail or f"stdout={r.stdout!r} stderr={r.stderr[:300]}")
        print("     neden:", r.stdout.strip(), flush=True)
    finally:
        unforward(ctx, pg2.port)
        pg2.stop()
    return ok


MYSQL_IMAGE = "mysql:8.4"
MYSQL_PASSWORD = "noxtest"  # yalnızca bu atılabilir kapsayıcıda geçerli sınama değeri
MYSQL_DB = "noxdb"


def docker(*args, **kw):
    return subprocess.run(["docker", *args], capture_output=True, text=True, **kw)


def probe_mysql(ctx, work):
    import time

    if docker("info").returncode != 0:
        print("atlandı: mysql (Docker yok)", flush=True)
        return True
    if docker("image", "inspect", MYSQL_IMAGE).returncode != 0:
        if os.environ.get("NOX_PROBE_PULL") == "1":  # yalnızca CI: temiz koşucuda imaj yoktur
            if docker("pull", "--quiet", MYSQL_IMAGE).returncode != 0:
                sys.exit(f"{MYSQL_IMAGE} indirilemedi")
        else:
            print(f"atlandı: mysql ({MYSQL_IMAGE} imajı yok; yerelde imaj indirilmez, CI'da NOX_PROBE_PULL=1)", flush=True)
            return True
    port = free_port()
    r = docker("run", "-d", "--rm", "-e", f"MYSQL_ROOT_PASSWORD={MYSQL_PASSWORD}", "-e", f"MYSQL_DATABASE={MYSQL_DB}", "-p", f"127.0.0.1:{port}:3306", MYSQL_IMAGE, "--mysql-native-password=ON")
    if r.returncode != 0:
        sys.exit("mysql kapsayıcısı başlamadı:\n" + r.stderr)
    container = r.stdout.strip()
    ok = False
    try:
        for _ in range(90):
            if docker("exec", container, "mysql", "-h127.0.0.1", "-uroot", f"-p{MYSQL_PASSWORD}", "-e", "select 1").returncode == 0:
                break
            time.sleep(2)
        else:
            sys.exit("mysql sunucusu hazır olmadı")
        forward(ctx, port)
        source = ((GOLDEN / "wasm_mysql_program.nox.in").read_text(encoding="utf-8")
                  .replace("__PORT__", str(port)).replace("__ROOT_PASSWORD__", MYSQL_PASSWORD).replace("__DB__", MYSQL_DB))
        r = run_nox(ctx, work, "mysql_program", source)
        expected = (GOLDEN / "wasm_mysql_program.expected").read_text(encoding="utf-8")
        ok = check("mysql: caching_sha2 (tam + hızlı yol), native parola, kaçışlama, hata yolları", r.status == "ran" and r.stdout == expected,
                   r.detail or f"çıkış {r.returncode}\n--- stdout\n{r.stdout}\n--- stderr\n{r.stderr[:400]}")
    finally:
        unforward(ctx, port)
        docker("rm", "-f", container)
    return ok


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("ios", "android") or (args[0] == "ios" and len(args) < 2):
        sys.exit(__doc__)
    platform = args[0]
    udid = args[1] if platform == "ios" else ""
    which = args[2] if platform == "ios" and len(args) > 2 else (args[1] if platform == "android" and len(args) > 1 else "all")
    ok = True
    with tempfile.TemporaryDirectory(prefix="nox-mobile-db-") as w:
        work = Path(w)
        ctx = mobile_run.setup(platform, work, udid)
        if which in ("pg", "all"):
            ok &= probe_pg(ctx, work)
        if which in ("mysql", "all"):
            ok &= probe_mysql(ctx, work)
        if which in ("tls", "all"):
            ok &= probe_tls(ctx, work)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
