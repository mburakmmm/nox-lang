#!/usr/bin/env python3
"""nox.postgres hata tanıları, statement_timeout, Transaction ve Pool'u GERÇEK bir PostgreSQL sunucusuna karşı sınar (Ember NL-006/007).

Kullanım: postgres_native_probe.py <noxc>. Geçici bir küme kurulur (scripts/mobile_db_probe.py'nin yardımcısı). Çıkış 0 = başarılı, 77 = PostgreSQL ikilileri/libpq yok (atlandı).
Programlar (`postgres_diagnostics_program`, `postgres_async_program`) iki arka uçta (LLVM ve QBE) çalıştırılır; stdout ilgili `.expected` ile aynı olmalıdır (sunucu uyarıları stderr'e gider).
"""
import glob
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mobile_db_probe as probe  # noqa: E402

if not probe.find_pg_bin("initdb") or not probe.find_pg_bin("pg_ctl"):
    sys.exit(77)

noxc = sys.argv[1]
root = os.path.dirname(HERE)
PROGRAMS = ["postgres_diagnostics_program", "postgres_async_program"]

env = dict(os.environ)
if sys.platform == "darwin":
    libs = sorted(glob.glob("/opt/homebrew/lib/postgresql@*") + glob.glob("/opt/homebrew/opt/libpq/lib"))
    if not libs:
        sys.exit(77)
    env["DYLD_FALLBACK_LIBRARY_PATH"] = ":".join(libs)
elif not glob.glob("/usr/lib/*/libpq.so.5") and not glob.glob("/usr/lib64/libpq.so.5") and not glob.glob("/usr/lib/libpq.so.5"):
    sys.exit(77)

env["NOX_POOL_WORKERS"] = "1"  # postgres_async_program: görevler aynı modül-değişkeni kopyasını (bağlantıları) görsün
pg = probe.Postgres()
try:
    pg.start()
    dsn = f"host=127.0.0.1 port={pg.port} user=postgres password=secret dbname=postgres"
    with tempfile.TemporaryDirectory() as tmp:
        for name in PROGRAMS:
            template = open(os.path.join(root, f"tests/golden/{name}.nox.in")).read()
            expected = open(os.path.join(root, f"tests/golden/{name}.expected")).read()
            path = os.path.join(tmp, f"{name}.nox")
            open(path, "w").write(template.replace("@DSN@", dsn))
            for backend in ("llvm", "qbe"):
                r = subprocess.run([noxc, "run", "--backend", backend, path], capture_output=True, text=True, env=env, timeout=300)
                if r.returncode != 0 or r.stdout != expected:
                    print(f"[{name}/{backend}] beklenmeyen sonuç (çıkış {r.returncode})\n--- stdout\n{r.stdout}\n--- stderr\n{r.stderr}\n--- beklenen\n{expected}")
                    sys.exit(1)
finally:
    pg.stop()
print("ok")
