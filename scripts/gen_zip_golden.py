#!/usr/bin/env python3
"""tests/golden/codegen_cases/zip_python_equivalence.{nox,expected}: Python `zipfile` ile üretilen arşivler (depolanmış + deflate, dizin, UTF-8 ad, boş dosya, 150 KB veri)
`nox.zip.unpack` ile açılıp ad/boyut/SHA-256 doğrulanır; `pack` -> `unpack` gidiş-dönüşü ve hata durumları (bozuk CRC, kısaltılmış) sınanır.
Nox'un yazdığı arşivin Python tarafından okunabilirliği ayrıca `scripts/verify_zip_interop.py` ile doğrulanır. Kullanım: scripts/gen_zip_golden.py"""
import base64, hashlib, io, os, random, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/golden/codegen_cases")
rnd = random.Random(20261119)

def text(n):
    words = ["alpha", "beta", "gamma", "çğış", "delta", "€uro", "x", "yy", "zzz", "\n"]
    out, size = [], 0
    while size < n:
        w = rnd.choice(words); out.append(w); size += len(w.encode()) + 1
    return (" ".join(out)).encode()[:n]

SETS = [
    [("a.txt", b"hello")],
    [("dir/", b""), ("dir/b.txt", text(3000)), ("dir/c.bin", bytes(rnd.randrange(256) for _ in range(500)))],
    [("empty", b""), ("büyük/çğış.txt", text(150000)), ("sıfır.bin", b"\x00" * 70000)],
]

def make_zip(entries, comp):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=comp) as z:
        for name, data in entries:
            zi = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            zi.compress_type = comp
            if name.endswith("/"):
                zi.external_attr = (0o40755 << 16) | 0x10
            else:
                zi.external_attr = 0o100644 << 16
            z.writestr(zi, data)
    return buf.getvalue()

src = ["# Üretildi: scripts/gen_zip_golden.py. nox.zip, Python zipfile ile aynı içeriği okur; pack/unpack gidiş-dönüşü ve hatalar.",
       "import nox.base64", "import nox.crypto", "import nox.strings", "import nox.zip", "from nox.zip import ZipEntry, ZipError, file_entry, dir_entry, pack, unpack", "",
       "def show(b64: str) -> None:", "    try:", "        for e in unpack(nox.base64.decode(b64)):",
       "            h: str = nox.crypto.sha256(e.data)",
       "            print(e.name, e.is_dir(), nox.strings.byte_len(e.data), h[0:16])",
       "    except ZipError as err:", '        print("ZipError")', ""]
exp = []
for es in SETS:
    for comp in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        blob = make_zip(es, comp)
        src.append(f'show("{base64.b64encode(blob).decode()}")')
        for name, data in es:
            exp.append(f"{name} {name.endswith('/')} {len(data)} {hashlib.sha256(data).hexdigest()[:16]}")

# hatalar
good = make_zip([("a.txt", b"hello hello hello")], zipfile.ZIP_STORED)
bad = bytearray(good); bad[30 + 5 + 2] ^= 0x01   # veri baytı bozulur -> CRC uyuşmaz
for blob in (bytes(bad), good[:len(good) - 10], b"PK" + b"\x00" * 30, b"not a zip at all, definitely not"):
    src.append(f'show("{base64.b64encode(blob).decode()}")')
    exp.append("ZipError")

# gidiş-dönüş (Nox pack -> Nox unpack), sıkıştırmalı ve sıkıştırmasız
src += ["", "def roundtrip(compress: bool) -> None:", "    entries: list[ZipEntry] = []",
        '    entries.append(dir_entry("d"))', '    entries.append(file_entry("d/a.txt", "abc " * 500))', '    entries.append(file_entry("empty", ""))',
        '    entries.append(file_entry("ünï/çğ.bin", "\\x01\\x02 çğış"))',
        "    blob: str = pack(entries, compress)", "    for e in unpack(blob):",
        "        h: str = nox.crypto.sha256(e.data)",
        "        print(e.name, e.is_dir(), nox.strings.byte_len(e.data), h[0:16])", "",
        "roundtrip(True)", "roundtrip(False)"]
rt = [("d/", b""), ("d/a.txt", ("abc " * 500).encode()), ("empty", b""), ("ünï/çğ.bin", "\x01\x02 çğış".encode())]
for _ in range(2):
    for name, data in rt:
        exp.append(f"{name} {name.endswith('/')} {len(data)} {hashlib.sha256(data).hexdigest()[:16]}")
open(os.path.join(OUT, "zip_python_equivalence.nox"), "w").write("\n".join(src) + "\n")
open(os.path.join(OUT, "zip_python_equivalence.expected"), "w").write("\n".join(exp) + "\n")
print(len(exp), "satır")
