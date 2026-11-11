#!/usr/bin/env python3
"""tests/golden/codegen_cases/bigint_python_equivalence.{nox,expected} dosyalarını üretir: rastgele (tohumlu) büyük sayılar üzerinde `nox.bigint` işlemlerinin sonuçları
Python'un kendi `int`i ile hesaplanır (beklenen çıktı). Kullanım: scripts/gen_bigint_golden.py"""
import os, random, math

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/golden/codegen_cases")
rnd = random.Random(20261112)

def rand_int():
    bits = rnd.choice([1, 5, 31, 63, 64, 65, 100, 200, 500, 1200])
    v = rnd.getrandbits(bits)
    return -v if rnd.random() < 0.4 else v

pairs = [(rand_int(), rand_int()) for _ in range(40)]
pairs += [(0, 7), (7, 0), (-1, 1), (2**64, 2**64), (-(2**63), -1), (2**127 - 1, 2**61 - 1), (10**40, -(10**20))]

src = ["# Üretildi: scripts/gen_bigint_golden.py. Rastgele büyük sayılarda nox.bigint, Python int ile aynı sonucu vermeli.",
       "import nox.bigint", "from nox.bigint import BigInt, parse", ""]
exp = []
def emit(code, value):
    src.append(f"print({code})")
    exp.append(str(value))

for i, (a, b) in enumerate(pairs):
    src.append(f"a{i}: BigInt = parse(\"{a}\")")
    src.append(f"b{i}: BigInt = parse(\"{b}\")")
    emit(f"a{i} + b{i}", a + b)
    emit(f"a{i} - b{i}", a - b)
    emit(f"a{i} * b{i}", a * b)
    if b != 0:
        emit(f"a{i} // b{i}", a // b)
        emit(f"a{i} % b{i}", a % b)
    emit(f"a{i} & b{i}", a & b)
    emit(f"a{i} | b{i}", a | b)
    emit(f"a{i} ^ b{i}", a ^ b)
    emit(f"a{i} < b{i}, a{i} == b{i}, a{i} > b{i}", f"{a < b} {a == b} {a > b}")
    emit(f"a{i}.gcd(b{i})", math.gcd(a, b))
    emit(f"a{i}.bit_length(), a{i}.sign()", f"{abs(a).bit_length()} {(a > 0) - (a < 0)}")
    k = rnd.randrange(0, 130)
    emit(f"a{i} >> {k}", a >> k)
    emit(f"a{i} << {k}", a << k)
    emit(f"a{i}.to_str(16)", format(abs(a), "x") if a >= 0 else "-" + format(abs(a), "x"))
    emit(f"a{i}.abs().isqrt()", math.isqrt(abs(a)))
    if b != 0:
        qd, rd = divmod(a, b)
        src.append(f"q{i}, r{i} = a{i}.divmod(b{i})")
        emit(f"q{i} * b{i} + r{i} == a{i}", True)
    if abs(b) > 1:
        m = abs(b)
        e = rnd.randrange(0, 300)
        emit(f"a{i}.pow_mod(parse(\"{e}\"), b{i}.abs())", pow(a, e, m))
    pw = rnd.randrange(0, 6)
    emit(f"a{i} ** {pw}", a ** pw)
open(os.path.join(OUT, "bigint_python_equivalence.nox"), "w").write("\n".join(src) + "\n")
open(os.path.join(OUT, "bigint_python_equivalence.expected"), "w").write("\n".join(exp) + "\n")
print(len(exp), "satır")
