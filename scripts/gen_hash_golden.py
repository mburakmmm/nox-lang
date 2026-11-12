#!/usr/bin/env python3
"""tests/golden/codegen_cases/crypto_hashes_python_equivalence.{nox,expected} dosyalarını üretir: `nox.crypto` md5/sha1/sha256/sha384/sha512/sha3_256/sha3_512 özetleri Python `hashlib`
ile (çeşitli uzunluk/UTF-8 girdilerde) aynı olmalı; blake3 için resmî test vektörleri. Kullanım: scripts/gen_hash_golden.py"""
import hashlib, os, random

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/golden/codegen_cases")
rnd = random.Random(20261116)
POOL = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,;:-_/\\\"'çğıöşüÇĞİÖŞÜ€😀"
inputs = ["", "a", "abc", "message digest", "The quick brown fox jumps over the lazy dog"]
for n in [55, 56, 57, 63, 64, 65, 111, 112, 113, 127, 128, 129, 135, 136, 137, 200, 255, 256, 1000, 1023, 1024, 1025]:
    inputs.append("".join(rnd.choice(POOL) for _ in range(n)))
def lit(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
src = ["# Üretildi: scripts/gen_hash_golden.py. nox.crypto özetleri Python hashlib ile aynı olmalı.", "import nox.crypto", ""]
exp = []
algos = [("md5", hashlib.md5), ("sha1", hashlib.sha1), ("sha256", hashlib.sha256), ("sha384", hashlib.sha384), ("sha512", hashlib.sha512), ("sha3_256", hashlib.sha3_256), ("sha3_512", hashlib.sha3_512)]
for s in inputs:
    for name, h in algos:
        src.append(f"print(nox.crypto.{name}({lit(s)}))")
        exp.append(h(s.encode()).hexdigest())
# blake3 resmî vektörleri (BLAKE3 test_vectors: boş girdi ve "abc")
for s, want in [("", "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"), ("abc", "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")]:
    src.append(f"print(nox.crypto.blake3({lit(s)}))")
    exp.append(want)
open(os.path.join(OUT, "crypto_hashes_python_equivalence.nox"), "w").write("\n".join(src) + "\n")
open(os.path.join(OUT, "crypto_hashes_python_equivalence.expected"), "w").write("\n".join(exp) + "\n")
print(len(exp), "satır")
