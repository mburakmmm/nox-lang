#!/usr/bin/env python3
"""runtime/unicode_data.zig'i Python'un unicodedata/str semantiğinden üretir.

Kullanım:
  python3 scripts/gen_unicode_tables.py > runtime/unicode_data.zig
  python3 scripts/gen_unicode_tables.py ident > compiler/lexer/unicode_ident.zig   (Unicode tanımlayıcı tabloları: XID_Start/XID_Continue)

Üretilen tablolar `str.upper/lower/casefold` (tam eşlemeler) ve `isalpha/isdigit/isdecimal/isnumeric/isspace/isupper/islower` için
Python'un kendi tanımlarını (CPython `str` yöntemleri) birebir yansıtır; Unicode sürümü dosya başlığında yazılır.
"""
import sys
import unicodedata

MAX = 0x110000


def case_table(fn):
    rows = []
    for cp in range(MAX):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        ch = chr(cp)
        out = fn(ch)
        if out != ch:
            cps = [ord(c) for c in out]
            assert len(cps) <= 3
            cps += [0] * (3 - len(cps))
            rows.append((cp, cps))
    return rows


def ranges(pred):
    out = []
    start = None
    for cp in range(MAX):
        ok = False if 0xD800 <= cp <= 0xDFFF else pred(chr(cp))
        if ok and start is None:
            start = cp
        elif not ok and start is not None:
            out.append((start, cp - 1))
            start = None
    if start is not None:
        out.append((start, MAX - 1))
    return out


def emit_case(name, rows):
    print(f"pub const {name} = [_]Case{{")
    for cp, o in rows:
        print(f"    .{{ .cp = 0x{cp:X}, .out = .{{ 0x{o[0]:X}, 0x{o[1]:X}, 0x{o[2]:X} }} }},")
    print("};\n")


def emit_ranges(name, rs):
    print(f"pub const {name} = [_]Range{{")
    line = "   "
    for lo, hi in rs:
        item = f" .{{ .lo = 0x{lo:X}, .hi = 0x{hi:X} }},"
        if len(line) + len(item) > 140:
            print(line)
            line = "   "
        line += item
    print(line)
    print("};\n")


IDENT_TAIL = r'''fn inRanges(table: []const Range, cp: u32) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = table[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

pub fn isStart(cp: u32) bool {
    return inRanges(&start, cp);
}

pub fn isCont(cp: u32) bool {
    return inRanges(&cont, cp);
}'''

if len(sys.argv) > 1 and sys.argv[1] == "ident":
    print("// ÜRETİLMİŞ DOSYA — scripts/gen_unicode_tables.py ident ile üretilir, elle DÜZENLEME.")
    print(f'pub const unicode_version = "{unicodedata.unidata_version}";\n')
    print("pub const Range = struct { lo: u32, hi: u32 };\n")
    emit_ranges("start", [r for r in ranges(lambda c: ord(c) >= 0x80 and c.isidentifier())])
    emit_ranges("cont", [r for r in ranges(lambda c: ord(c) >= 0x80 and ("a" + c).isidentifier())])
    print(IDENT_TAIL)
    sys.exit(0)

print("// ÜRETİLMİŞ DOSYA — scripts/gen_unicode_tables.py ile üretilir, elle DÜZENLEME.")
print(f'pub const unicode_version = "{unicodedata.unidata_version}";\n')
print("pub const Case = struct { cp: u32, out: [3]u32 };")
print("pub const Range = struct { lo: u32, hi: u32 };\n")
emit_case("upper_map", case_table(lambda c: c.upper()))
emit_case("lower_map", case_table(lambda c: c.lower()))
emit_case("casefold_map", case_table(lambda c: c.casefold()))
emit_ranges("alpha", ranges(lambda c: c.isalpha()))
emit_ranges("digit", ranges(lambda c: c.isdigit()))
emit_ranges("decimal", ranges(lambda c: c.isdecimal()))
emit_ranges("numeric", ranges(lambda c: c.isnumeric()))
emit_ranges("space", ranges(lambda c: c.isspace()))
emit_ranges("upper", ranges(lambda c: c.isupper()))
emit_ranges("lower", ranges(lambda c: c.islower()))
emit_ranges("titlecase", ranges(lambda c: c.istitle() and not c.isupper() and not c.islower()))
