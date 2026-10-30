#!/usr/bin/env python3
"""Çalışma zamanı nesnelerinin libc'den çözdüğü TÜM sembollerin `compiler/codegen_qbe/reserved_symbols.zig` listesinde olduğunu doğrular (v2.0.86 sembol politikası).

Çalışma zamanı yarın yeni bir libc işlevine bağlanırsa (ör. `getrandom`) ve o ad listede yoksa, aynı adı taşıyan bir kullanıcı fonksiyonu onu ele geçirebilir. `nm -u` ile
`zig-out/lib/noxrt*.o`nun tanımsız sembolleri okunur (Mach-O/ELF; wasm nesneleri atlanır). `nox_*`, derleyici/bağlayıcı iç adları (`__`/`_tlv`/`dyld`) ve Darwin `$`
sonekleri (`close$NOCANCEL`) ayrılmış sayılmaz.

Kullanım: python3 scripts/check_reserved_symbols.py   (önce `zig build` ile çalışma zamanı nesnelerini üretin)
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
text = open(os.path.join(ROOT, "compiler/codegen_qbe/reserved_symbols.zig"), encoding="utf-8").read()
body = text[text.index("pub const names = [_][]const u8{"):]
reserved = set(re.findall(r'"([^"]+)"', body[: body.index("};")]))

missing = {}
objs = [o for o in sorted(glob.glob(os.path.join(ROOT, "zig-out/lib/noxrt*.o"))) if "wasm" not in o and "freestanding" not in o]
if not objs:
    sys.exit("zig-out/lib/noxrt*.o yok: önce `zig build` çalıştırın")
checked = 0
for o in objs:
    p = subprocess.run(["nm", "-u", o], capture_output=True, text=True)
    if p.returncode != 0:
        continue  # nm bu biçimi (ör. çapraz ELF) okuyamıyor
    checked += 1
    macho = any(k in os.path.basename(o) for k in ("macos", "ios")) or os.path.basename(o) == "noxrt.o" and sys.platform == "darwin"
    for line in p.stdout.splitlines():
        sym = line.strip().split()[-1] if line.strip() else ""
        sym = re.sub(r"\$.*$", "", sym)  # close$NOCANCEL, realpath$DARWIN_EXTSN
        if macho and sym.startswith("_") and not sym.startswith("__"):
            sym = sym[1:]  # Mach-O alt çizgi öneki
        if not sym or sym.startswith("nox_") or sym.startswith("__") or sym.startswith("_tlv") or "dyld" in sym:
            continue
        if sym not in reserved:
            missing.setdefault(sym, set()).add(os.path.basename(o))
if missing:
    for s, objs_ in sorted(missing.items()):
        print(f"ayrılmamış libc sembolü: {s} ({', '.join(sorted(objs_))})")
    sys.exit("reserved_symbols.zig'ye ekleyin ve scripts/gen_reserved_symbol_fixture.py çalıştırın")
print(f"ayrılmış semboller: {checked} çalışma zamanı nesnesi için tam")
