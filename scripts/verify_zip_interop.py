#!/usr/bin/env python3
"""`nox.zip.pack` çıktısının Python `zipfile` ile okunabildiğini doğrular: küçük bir Nox programı iki arşiv (sıkıştırmalı / sıkıştırmasız) yazar, Python
`testzip()` + içerik karşılaştırması yapar. Kullanım: scripts/verify_zip_interop.py [noxc yolu]   (python3 + noxc gerekir)"""
import os, subprocess, sys, tempfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
noxc = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "zig-out/bin/noxc")
PROG = r'''
import nox.fs
import nox.zip
from nox.zip import ZipEntry, file_entry, dir_entry, pack

def build(path: str, compress: bool) -> None:
    entries: list[ZipEntry] = []
    entries.append(dir_entry("d"))
    entries.append(file_entry("d/a.txt", "abc " * 2000))
    entries.append(file_entry("empty", ""))
    entries.append(file_entry("ünï/çğ.txt", "çğış €"))
    nox.fs.write_string(path, pack(entries, compress))

build("OUT_C", True)
build("OUT_S", False)
'''
with tempfile.TemporaryDirectory() as td:
    oc, os_ = os.path.join(td, "c.zip"), os.path.join(td, "s.zip")
    prog = os.path.join(td, "p.nox")
    open(prog, "w").write(PROG.replace("OUT_C", oc).replace("OUT_S", os_))
    subprocess.check_call([noxc, "run", prog])
    expect = {"d/": b"", "d/a.txt": ("abc " * 2000).encode(), "empty": b"", "ünï/çğ.txt": "çğış €".encode()}
    for path, label in ((oc, "sıkıştırmalı"), (os_, "depolanmış")):
        with zipfile.ZipFile(path) as z:
            assert z.testzip() is None, f"{label}: testzip başarısız"
            got = {i.filename: z.read(i) for i in z.infolist()}
            assert got == expect, f"{label}: içerik farklı: {sorted(got)}"
            methods = {i.filename: i.compress_type for i in z.infolist()}
            if label == "sıkıştırmalı":
                assert methods["d/a.txt"] == zipfile.ZIP_DEFLATED, methods
            else:
                assert all(m == zipfile.ZIP_STORED for m in methods.values()), methods
    print("verify_zip_interop: tamam")
