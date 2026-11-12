#!/usr/bin/env python3
"""tests/golden/codegen_cases/zstd_python_equivalence.{nox,expected}: Python `compression.zstd` (3.14+) ile sıkıştırılmış veriyi `nox.zstd.decompress` ile açıp
SHA-256 ve uzunluğu Python'un özetiyle karşılaştırır (çeşitli düzey/boyut/çok çerçeveli girdiler, hata durumları). Kullanım: scripts/gen_zstd_golden.py"""
import base64, hashlib, os, random
from compression import zstd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/golden/codegen_cases")
rnd = random.Random(20261118)

def text(n):
    words = ["alpha", "beta", "gamma", "çğış", "delta", "€uro", "x", "yy", "zzz", "\n"]
    out = []
    size = 0
    while size < n:
        w = rnd.choice(words)
        out.append(w)
        size += len(w.encode()) + 1
    return (" ".join(out)).encode()[:n]

payloads = [b"", b"a", b"hello hello hello hello", text(1000), text(20000), bytes(rnd.randrange(256) for _ in range(3000)), b"\x00" * 200000, text(150000)]
src = ["# Üretildi: scripts/gen_zstd_golden.py. nox.zstd açma sonuçları Python compression.zstd ile aynı özet/uzunluk.",
       "import nox.base64", "import nox.crypto", "import nox.strings", "import nox.zstd", "from nox.zstd import ZstdError", "",
       "def show(b64: str) -> None:", "    try:", "        raw: str = nox.zstd.decompress(nox.base64.decode(b64))",
       "        print(nox.strings.byte_len(raw), nox.crypto.sha256(raw))", "    except ZstdError as e:", '        print("ZstdError")', ""]
exp = []
def add(blob, expected):
    src.append(f'show("{base64.b64encode(blob).decode()}")')
    exp.append(expected)
for p in payloads:
    for level in (1, 3, 9, 19):
        blob = zstd.compress(p, level=level)
        if len(blob) > 40000:
            continue
        add(blob, f"{len(p)} {hashlib.sha256(p).hexdigest()}")
# çok çerçeve (birleştirilmiş)
a, b = text(5000), text(7000)
add(zstd.compress(a) + zstd.compress(b), f"{len(a) + len(b)} {hashlib.sha256(a + b).hexdigest()}")
# hatalar
good = zstd.compress(text(5000))
add(b"not zstd at all", "ZstdError")
add(good[:len(good) // 2], "ZstdError")
open(os.path.join(OUT, "zstd_python_equivalence.nox"), "w").write("\n".join(src) + "\n")
open(os.path.join(OUT, "zstd_python_equivalence.expected"), "w").write("\n".join(exp) + "\n")
print(len(exp), "satır")
