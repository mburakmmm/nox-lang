#!/usr/bin/env python3
"""tests/golden/codegen_cases/tar_python_equivalence.{nox,expected} dosyalarını üretir.
 1) Yazma: Nox `nox.tar.pack` çıktısı (base64) Python `tarfile` ustar çıktısıyla (mtime=0, mode 0644/0755) bayt-bayt aynı olmalı.
 2) Okuma: Python'un ürettiği arşivler (ustar, PAX ve GNU uzun ad biçimleri) Nox ile açılıp ad/veri doğrulanır.
Kullanım: scripts/gen_tar_golden.py"""
import base64, io, os, random, tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/golden/codegen_cases")
rnd = random.Random(20261117)

def make_tar(entries, fmt):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=fmt) as t:
        for name, data in entries:
            if name.endswith("/"):
                ti = tarfile.TarInfo(name[:-1])
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
            else:
                ti = tarfile.TarInfo(name)
                ti.size = len(data)
                ti.mode = 0o644
            ti.mtime = 0
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            t.addfile(ti, io.BytesIO(data) if not name.endswith("/") else None)
    return buf.getvalue()

def lit(b):
    return '"' + b.decode().replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'

ENTRY_SETS = [
    [("a.txt", b"hello")],
    [("dir/", b""), ("dir/b.txt", b"x" * 511), ("dir/c.txt", b"y" * 512), ("dir/d.txt", b"z" * 513)],
    [("empty.txt", b""), ("sub/", b""), ("sub/deep/", b""), ("sub/deep/file.bin", "çğış €😀 satır\nikinci satır".encode())],
    [("n" * 100, b"exactly100"), ("p" * 60 + "/" + "q" * 90, b"prefix split"), ("one/" * 30 + "f.txt", b"long path")],
    [(f"f{i}.txt", ("data %d " % i).encode() * rnd.randrange(1, 200)) for i in range(12)],
]

src = ["# Üretildi: scripts/gen_tar_golden.py. nox.tar yazma çıktısı Python tarfile ustar ile bayt-bayt aynı; Python arşivleri okunabilir.",
       "import nox.base64", "import nox.strings", "import nox.tar", "from nox.tar import TarEntry, TarError, file_entry, dir_entry, pack, unpack", ""]
exp = []

# 1) yazma
for k, es in enumerate(ENTRY_SETS):
    src.append(f"e{k}: list[TarEntry] = []")
    for name, data in es:
        if name.endswith("/"):
            src.append(f"e{k}.append(dir_entry({lit(name.encode())}))")
        else:
            src.append(f"e{k}.append(file_entry({lit(name.encode())}, {lit(data)}))")
    src.append(f"print(nox.base64.encode(pack(e{k})))")
    exp.append(base64.b64encode(make_tar(es, tarfile.USTAR_FORMAT)).decode())

# 2) okuma (ustar, PAX, GNU)
src += ["", "def show(b64: str) -> None:", "    for e in unpack(nox.base64.decode(b64)):", '        print(e.name, e.is_dir(), nox.strings.byte_len(e.data), e.data[0:12])', ""]
for k, es in enumerate(ENTRY_SETS):
    for fmt in (tarfile.USTAR_FORMAT, tarfile.GNU_FORMAT, tarfile.PAX_FORMAT):
        try:
            blob = make_tar(es, fmt)
        except ValueError:
            continue
        src.append(f'show("{base64.b64encode(blob).decode()}")')
        for name, data in es:
            isd = name.endswith("/")
            txt = data.decode()
            exp.append(f"{name} {isd} {len(data)} {txt[0:12]}" if not isd else f"{name} True 0 ")

# 3) hata: bozuk sağlama toplamı ve kısaltılmış arşiv
good = make_tar([("a.txt", b"hello")], tarfile.USTAR_FORMAT)
bad = bytearray(good); bad[0] ^= 0x55
src += ["", "def check(b64: str) -> None:", "    try:", "        unpack(nox.base64.decode(b64))", '        print("ok")', "    except TarError as e:", '        print("TarError")', ""]
src.append(f'check("{base64.b64encode(bytes(bad)).decode()}")')
exp.append("TarError")
src.append(f'check("{base64.b64encode(good[:300]).decode()}")')
exp.append("TarError")
src.append(f'check("{base64.b64encode(good).decode()}")')
exp.append("ok")
open(os.path.join(OUT, "tar_python_equivalence.nox"), "w").write("\n".join(src) + "\n")
open(os.path.join(OUT, "tar_python_equivalence.expected"), "w").write("\n".join(exp) + "\n")
print(len(exp), "satır")
