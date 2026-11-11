#!/usr/bin/env python3
"""tests/golden/codegen_cases/{decimal,fraction}_python_equivalence.{nox,expected} dosyalarını üretir: rastgele (tohumlu) girdilerde `nox.decimal` ve `nox.fraction`
sonuçları Python'un `decimal.Decimal` ve `fractions.Fraction` sınıflarıyla hesaplanır. Kullanım: scripts/gen_decimal_golden.py"""
import os, random, decimal, fractions, math

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/golden/codegen_cases")
rnd = random.Random(20261113)
D = decimal.Decimal
decimal.getcontext().prec = 4000
decimal.getcontext().Emax = decimal.MAX_EMAX
decimal.getcontext().Emin = decimal.MIN_EMIN
MODES = {"half_even": decimal.ROUND_HALF_EVEN, "half_up": decimal.ROUND_HALF_UP, "half_down": decimal.ROUND_HALF_DOWN, "down": decimal.ROUND_DOWN,
         "up": decimal.ROUND_UP, "floor": decimal.ROUND_FLOOR, "ceiling": decimal.ROUND_CEILING}


def plain(d):
    s = format(d, "f")
    # nox.decimal işaretli sıfır tutmaz ("-0.00" yerine "0.00")
    if s.startswith("-") and d == 0:
        s = s[1:]
    return s


def rand_dec():
    digits = rnd.choice([1, 2, 3, 5, 8, 15, 30])
    coef = rnd.randrange(0, 10 ** digits)
    exp = rnd.randrange(-8, 3)
    if rnd.random() < 0.15:
        coef = rnd.choice([5, 25, 125, 15, 35]) * 10 ** rnd.randrange(0, 3)  # eşitlik (tie) üretmeye yatkın
    sign = "-" if rnd.random() < 0.45 else ""
    return D(f"{sign}{coef}E{exp}")


def lit(d):
    sign, digs, exp = d.as_tuple()
    s = "".join(map(str, digs)) or "0"
    return ("-" if sign else "") + s + ("e%d" % exp if exp else "")


# ---------------------------------------------------------------- decimal
src = ["# Üretildi: scripts/gen_decimal_golden.py. nox.decimal, Python decimal.Decimal ile aynı sonucu vermeli.",
       "import nox.decimal", "from nox.decimal import Decimal, parse", ""]
exp = []

def emit(code, value):
    src.append(f"print({code})")
    exp.append(str(value))

for i in range(60):
    a, b = rand_dec(), rand_dec()
    src.append(f'a{i}: Decimal = parse("{lit(a)}")')
    src.append(f'b{i}: Decimal = parse("{lit(b)}")')
    emit(f"a{i}", plain(a))
    emit(f"a{i} + b{i}", plain(a + b))
    emit(f"a{i} - b{i}", plain(a - b))
    emit(f"a{i} * b{i}", plain(a * b))
    emit(f"a{i}.compare(b{i}), a{i} == b{i}, a{i} < b{i}", f"{(a > b) - (a < b)} {a == b} {a < b}")
    for mode, py in rnd.sample(sorted(MODES.items()), 3):
        places = rnd.randrange(-2, 7)
        q = a.quantize(D(1).scaleb(-places), rounding=py)
        emit(f'a{i}.quantize({places}, "{mode}")', plain(q) if places >= 0 else str(int(q)))
    if b != 0:
        mode, py = rnd.choice(sorted(MODES.items()))
        places = rnd.randrange(0, 12)
        q = (a / b).quantize(D(1).scaleb(-places), rounding=py)
        emit(f'a{i}.div(b{i}, {places}, "{mode}")', plain(q))
    emit(f"a{i}.normalize()", plain(a.normalize()) if a != 0 else "0")
    emit(f"a{i}.to_bigint()", int(a))
open(os.path.join(OUT, "decimal_python_equivalence.nox"), "w").write("\n".join(src) + "\n")
open(os.path.join(OUT, "decimal_python_equivalence.expected"), "w").write("\n".join(exp) + "\n")
print("decimal:", len(exp), "satır")

# ---------------------------------------------------------------- fraction
F = fractions.Fraction
src = ["# Üretildi: scripts/gen_decimal_golden.py. nox.fraction, Python fractions.Fraction ile aynı sonucu vermeli.",
       "import nox.fraction", "from nox.bigint import parse as bp", "from nox.fraction import Fraction, make, parse_fraction", ""]
exp = []

def fstr(f):
    return str(f.numerator) if f.denominator == 1 else f"{f.numerator}/{f.denominator}"

for i in range(60):
    p1, q1 = rnd.randrange(-10 ** rnd.choice([1, 3, 9, 20]), 10 ** rnd.choice([1, 3, 9, 20])), rnd.randrange(1, 10 ** rnd.choice([1, 3, 9, 20]))
    p2, q2 = rnd.randrange(-10 ** 6, 10 ** 6), rnd.randrange(1, 10 ** 6)
    if rnd.random() < 0.2:
        p1, q1 = rnd.randrange(-9, 10), 2 * rnd.randrange(1, 4)  # yarımlar: round() eşitlikleri
    a, b = F(p1, q1), F(p2, q2)
    src.append(f'a{i}: Fraction = make(bp("{p1}"), bp("{q1}"))')
    src.append(f'b{i}: Fraction = make(bp("{p2}"), bp("{q2}"))')
    emit(f"a{i}", fstr(a))
    emit(f"a{i} + b{i}", fstr(a + b))
    emit(f"a{i} - b{i}", fstr(a - b))
    emit(f"a{i} * b{i}", fstr(a * b))
    if b != 0:
        emit(f"a{i} / b{i}", fstr(a / b))
    emit(f"a{i} < b{i}, a{i} == b{i}, a{i} >= b{i}", f"{a < b} {a == b} {a >= b}")
    emit(f"a{i}.floor(), a{i}.ceil(), a{i}.trunc(), a{i}.round()", f"{math.floor(a)} {math.ceil(a)} {int(a)} {round(a)}")
    e = rnd.randrange(-3, 4)
    if a != 0 or e > 0:
        emit(f"a{i} ** {e}", fstr(a ** e))
    dec = str(rnd.randrange(-10 ** 8, 10 ** 8)) + "." + str(rnd.randrange(0, 10 ** 6)).zfill(6)
    emit(f'parse_fraction("{dec}")', fstr(F(dec)))
open(os.path.join(OUT, "fraction_python_equivalence.nox"), "w").write("\n".join(src) + "\n")
open(os.path.join(OUT, "fraction_python_equivalence.expected"), "w").write("\n".join(exp) + "\n")
print("fraction:", len(exp), "satır")
