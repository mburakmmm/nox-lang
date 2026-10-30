#!/usr/bin/env python3
"""wasm32 ABI tablosu üretici (Faz 10).

Nox'un derlenmiş kodu HER yerde 64-bit tamsayı kullanır (işaretçiler dahil). wasm32'de runtime'ın `export fn` imzalarındaki işaretçiler `i32`dir; derleyici
çağrı noktasında argümanları daraltır / sonucu genişletir. Bu betik runtime kaynaklarındaki `export fn` imzalarını tarar ve `compiler/codegen_qbe/wasm_abi_table.zig`
dosyasını yazar (sürüm kontrolünde tutulur; `--check` ile CI'da güncelliği doğrulanır).

Tür sınıfları: P = işaretçi (i32), U = usize/isize/c_long (i32), L = 64-bit tamsayı, W = 32-bit ve daha küçük tamsayı/bool (i32), D = f64, F = f32.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC_DIRS = ["runtime"]
OUT = ROOT / "compiler/codegen_qbe/wasm_abi_table.zig"
# libc yerine geçen `wasm_libc.zig` (printf/strcmp/_start) ve lib_*.zig kökleri tabloya girmez: libc imzaları `llvm_emit.zig`nin `libc_abi` tablosundadır.
SKIP_FILES = {"wasm_libc.zig", "wasm_threads_libc.zig", "lib_wasm.zig", "lib_wasm_freestanding.zig", "lib_freestanding.zig", "lib_freestanding_kernel.zig"}
SKIP_DIRS = {"vendor", "freestanding", "mobile", "hpy_bridge", "wasm_bridge", "cpython_compat"}

def split_params(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{": depth += 1
        if ch in ")]}": depth -= 1
        if ch == "," and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    if cur.strip(): out.append(cur)
    return [p.strip() for p in out if p.strip()]

def classify(t):
    t = t.strip()
    if t == "...": return "V"
    if t.startswith("?"): t = t[1:]
    if t.startswith("*") or t.startswith("[*") or t.startswith("[:") or t.startswith("@") and False: return "P"
    if t in ("anyopaque",): return "P"
    if t in ("i64", "u64", "c_longlong", "c_ulonglong"): return "L"
    if t in ("usize", "isize", "c_long", "c_ulong"): return "U"
    if t in ("i32", "u32", "c_int", "c_uint", "bool", "i16", "u16", "i8", "u8", "c_short", "c_ushort", "u1", "u3"): return "W"
    if t in ("f64", "c_double"): return "D"
    if t in ("f32",): return "F"
    if t in ("void", "noreturn"): return "v"
    if t.startswith("abi_ptr.Arg") or t == "Arg": return "L"
    if re.fullmatch(r"\w*Fn", t): return "P"  # TraceFn/TaskFn gibi fonksiyon işaretçisi takma adları
    return "?"

sig_re = re.compile(r"(?:pub\s+)?export\s+fn\s+(\w+)\s*\(")

def parse_file(path):
    text = path.read_text()
    # satır yorumlarını at (imzaları bozmasın)
    text = "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))
    entries = []
    for m in sig_re.finditer(text):
        name = m.group(1)
        i = m.end()
        depth, j = 1, i
        while depth:
            c = text[j]
            if c == "(": depth += 1
            elif c == ")": depth -= 1
            j += 1
        params_txt = text[i:j - 1]
        rest = text[j:text.index("{", j)]
        rest = re.sub(r"callconv\([^)]*\)", "", rest).strip()
        ret = rest
        params = []
        for p in split_params(params_txt):
            if p == "...": params.append("V"); continue
            ty = p.split(":", 1)[1].strip() if ":" in p else p
            params.append(classify(ty))
        entries.append((name, "".join(params), classify(ret) if ret else "v", str(path.relative_to(ROOT))))
    return entries

def main():
    all_entries = {}
    bad = []
    for d in SRC_DIRS:
        for p in sorted((ROOT / d).rglob("*.zig")):
            if SKIP_DIRS & set(p.relative_to(ROOT / d).parts): continue
            if p.name in SKIP_FILES: continue
            if p.name.endswith("_test.zig") or p.name == "lib_freestanding.zig" or p.name == "lib_freestanding_kernel.zig": continue
            for name, params, ret, src in parse_file(p):
                if "?" in params or ret == "?":
                    bad.append((name, params, ret, src)); continue
                all_entries[name] = (params, ret)
    lines = ["//! OTOMATİK ÜRETİLDİ — `scripts/gen_wasm_abi.py` (elle düzenleme). wasm32 çalışma zamanı ABI tablosu: ad -> (parametre sınıfları, dönüş sınıfı).",
             "//! P = işaretçi (i32), U = usize (i32), L = i64, W = i32, D = f64, F = f32, V = değişken argüman, v = void.", "",
             "pub const Entry = struct { params: []const u8, ret: u8 };", "",
             "pub const table = std.StaticStringMap(Entry).initComptime(.{"]
    for name in sorted(all_entries):
        params, ret = all_entries[name]
        lines.append(f'    .{{ "{name}", Entry{{ .params = "{params}", .ret = \'{ret}\' }} }},')
    lines.append("});")
    lines.append("")
    lines.append('const std = @import("std");')
    out = "\n".join(lines) + "\n"
    if "--check" in sys.argv:
        if OUT.read_text() != out:
            print("wasm_abi_table.zig bayat: scripts/gen_wasm_abi.py çalıştırın"); sys.exit(1)
        print("wasm ABI tablosu güncel"); return
    OUT.write_text(out)
    print(f"{len(all_entries)} export yazıldı; çözülemeyen: {len(bad)}")
    for b in bad[:40]: print("  ?", b)

main()
