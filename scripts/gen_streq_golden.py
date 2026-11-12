#!/usr/bin/env python3
"""tests/golden/codegen_cases/str_eq_literal_inline.{nox,expected}: `s == "lit"` / `"lit" == s` / `s != "lit"` satır içi karşılaştırmasının (v2.1.76) `strcmp` anlamıyla
(ilk NUL baytta durur) birebir aynı olduğunu sınar. Beklenen çıktı bu anlamı Python'da yeniden uygulayarak üretilir. Kullanım: scripts/gen_streq_golden.py"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/golden/codegen_cases")

def cstr(b):  # strcmp görünümü: ilk NUL'a kadar
    i = b.find(b"\x00")
    return b if i < 0 else b[:i]

LITS = ["", "a", "ab", "abc", "hello", "hello world!", "0123456789abcdef", "0123456789abcdefg", "\\n", "\\t", "é", "çğ", "x y", " ", "A", "a-b_c"]
def lit_bytes(l):
    return l.replace("\\n", "\n").replace("\\t", "\t").encode()

SUBJECTS = []
for l in LITS:
    lb = lit_bytes(l)
    SUBJECTS.append(lb)                                   # eşit
    SUBJECTS.append(lb + b"x")                            # literal + ek
    if lb: SUBJECTS.append(lb[:-1])                       # kısaltılmış
    if lb: SUBJECTS.append(bytes([lb[0] ^ 1]) + lb[1:])   # ilk bayt farklı
    if len(lb) > 1: SUBJECTS.append(lb[:-1] + bytes([lb[-1] ^ 1]))  # son bayt farklı
    SUBJECTS.append(lb + b"\x00junk")                     # NUL sonrası çöp: strcmp'ye göre eşit
    SUBJECTS.append(b"\x00" + lb)                         # baştan NUL: boş görünür
SUBJECTS += [b"", b"zzz", "aé".encode(), "éa".encode()]

def nox_expr(b):
    """Baytları Nox ifadesine çevirir: yazdırılabilir ASCII düz metin, diğerleri `char_from_byte(n)`."""
    parts, run = [], ""
    for ch in b:
        if 32 <= ch < 127 and ch not in (34, 92):
            run += chr(ch)
        else:
            if run:
                parts.append('"' + run + '"'); run = ""
            parts.append(f"nox.strings.char_from_byte({ch})")
    if run:
        parts.append('"' + run + '"')
    return " + ".join(parts) if parts else '""'

src = ["# Üretildi: scripts/gen_streq_golden.py. Satır içi `s == \"lit\"` karşılaştırması strcmp anlamıyla (ilk NUL'da durur) birebir aynı olmalı.", "import nox.strings", ""]
for idx, l in enumerate(LITS):
    src.append(f'def f{idx}(s: str) -> str:\n    r: str = ""\n    if s == "{l}":\n        r = r + "E"\n    if "{l}" == s:\n        r = r + "L"\n    if s != "{l}":\n        r = r + "N"\n    return r\n')
exp = []
src.append("subjects: list[str] = [")
for sb in SUBJECTS:
    src.append(f"    {nox_expr(sb)},")
src.append("]")
for idx, l in enumerate(LITS):
    lb = lit_bytes(l)
    src.append(f"for subj{idx} in subjects:")
    src.append(f"    print(f{idx}(subj{idx}))")
    for sb in SUBJECTS:
        exp.append("EL" if cstr(sb) == lb else "N")
open(os.path.join(OUT, "str_eq_literal_inline.nox"), "w").write("\n".join(src) + "\n")
open(os.path.join(OUT, "str_eq_literal_inline.expected"), "w").write("\n".join(exp) + "\n")
print(len(exp), "satır,", len(SUBJECTS), "konu")
