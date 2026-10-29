#!/usr/bin/env python3
"""runtime/unicode_data.zig'i Python'un unicodedata/str semantiğinden üretir.

Kullanım:
  python3 scripts/gen_unicode_tables.py > runtime/unicode_data.zig
  python3 scripts/gen_unicode_tables.py norm > runtime/unicode_norm_data.zig   (NFC/NFD/NFKC/NFKD: ccc, ayrışım, birleştirme çiftleri)
  python3 scripts/gen_unicode_tables.py ident | zig fmt --stdin > compiler/lexer/unicode_ident.zig   (Unicode tanımlayıcı tabloları: XID_Start/XID_Continue)

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


NORM_TAIL = r'''
fn bsearch(comptime T: type, table: []const T, key: u32, comptime field: []const u8) ?usize {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const k = @field(table[mid], field);
        if (key < k) {
            hi = mid;
        } else if (key > k) {
            lo = mid + 1;
        } else return mid;
    }
    return null;
}

pub fn combiningClass(cp: u32) u8 {
    const i = bsearch(Ccc, &ccc, cp, "cp") orelse return 0;
    return ccc[i].v;
}

/// Tam (özyinelemeli) kanonik ya da (compat=true) uyumluluk ayrışımı; yoksa null.
pub fn decomposition(cp: u32, compat: bool) ?[]const u32 {
    if (compat) {
        if (bsearch(Decomp, &compat_map, cp, "cp")) |i| return data[compat_map[i].off..][0..compat_map[i].len];
    }
    if (bsearch(Decomp, &canon_map, cp, "cp")) |i| return data[canon_map[i].off..][0..canon_map[i].len];
    return null;
}

pub fn composePair(a: u32, b: u32) ?u32 {
    var lo: usize = 0;
    var hi: usize = pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const p = pairs[mid];
        if (a < p.a or (a == p.a and b < p.b)) {
            hi = mid;
        } else if (a > p.a or (a == p.a and b > p.b)) {
            lo = mid + 1;
        } else return p.c;
    }
    return null;
}
'''

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

if len(sys.argv) > 1 and sys.argv[1] == "norm":
    print("// ÜRETİLMİŞ DOSYA — scripts/gen_unicode_tables.py norm ile üretilir, elle DÜZENLEME.")
    print(f'pub const unicode_version = "{unicodedata.unidata_version}";\n')
    print("pub const Ccc = struct { cp: u32, v: u8 };")
    print("pub const Decomp = struct { cp: u32, off: u32, len: u32 };")
    print("pub const Pair = struct { a: u32, b: u32, c: u32 };\n")
    flat = []
    canon = []
    compat = []
    cccs = []
    pairs = []
    for cp in range(MAX):
        if 0xD800 <= cp <= 0xDFFF or 0xAC00 <= cp <= 0xD7A3:
            continue
        ch = chr(cp)
        c = unicodedata.combining(ch)
        if c:
            cccs.append((cp, c))
        d = unicodedata.normalize("NFD", ch)
        k = unicodedata.normalize("NFKD", ch)
        if d != ch:
            canon.append((cp, len(flat), len(d)))
            flat.extend(ord(x) for x in d)
        if k != d:
            compat.append((cp, len(flat), len(k)))
            flat.extend(ord(x) for x in k)
        dec = unicodedata.decomposition(ch)
        if dec and not dec.startswith("<"):
            parts = dec.split()
            if len(parts) == 2 and unicodedata.normalize("NFC", ch) == ch:
                pairs.append((int(parts[0], 16), int(parts[1], 16), cp))
    pairs.sort()
    print("pub const data = [_]u32{")
    line = "   "
    for v in flat:
        item = f" 0x{v:X},"
        if len(line) + len(item) > 140:
            print(line)
            line = "   "
        line += item
    print(line)
    print("};\n")
    print("pub const ccc = [_]Ccc{")
    for cp, v in cccs:
        print(f"    .{{ .cp = 0x{cp:X}, .v = {v} }},")
    print("};\n")
    for name, rows in (("canon_map", canon), ("compat_map", compat)):
        print(f"pub const {name} = [_]Decomp{{")
        for cp, off, ln in rows:
            print(f"    .{{ .cp = 0x{cp:X}, .off = {off}, .len = {ln} }},")
        print("};\n")
    print("pub const pairs = [_]Pair{")
    for a_, b_, c_ in pairs:
        print(f"    .{{ .a = 0x{a_:X}, .b = 0x{b_:X}, .c = 0x{c_:X} }},")
    print("};\n")
    print(NORM_TAIL)
    sys.exit(0)

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
