#!/usr/bin/env python3
"""WASM ABI tablosu eksiksizlik denetimi (2.3 madde 5.5): IR anlık görüntü korpusunda (`tests/golden/ir_snapshots/codegen_cases/*.ssa`) çağrılan her harici `nox_*` çalışma zamanı
sembolü `compiler/codegen_qbe/wasm_abi_table.zig`de olmalı; yoksa wasm32'de çağrı imzası bilinmediği için `unreachable`/imza uyuşmazlığı saplamasına dönüşür (v1.142.20'den beri
`nox.collections` Set/Counter/OrderedDict/LRUCache WASM'da çalışmıyordu: `nox_hash_*` tabloda yoktu). WASM'da bilerek bulunmayan yerel-özel önekler izin listesindedir.
Kullanım: scripts/check_wasm_abi_table.py  (çıkış 1 = tabloda olmayan, izin listesinde de olmayan sembol var)."""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# WASM'da çalışma zamanı tarafından SAĞLANMAYAN (derleyici açık iletiyle reddeder) yerel-özel aileler.
NATIVE_ONLY_PREFIXES = ("nox_cb_", "nox_evq_", "nox_ffi", "nox_wasm_", "nox_signal_service_", "nox_test_")
table = open(os.path.join(ROOT, "compiler/codegen_qbe/wasm_abi_table.zig"), encoding="utf-8").read()
in_table = set(re.findall(r'\.\{ "([A-Za-z0-9_]+)", Entry', table))
ext = {}
for f in glob.glob(os.path.join(ROOT, "tests/golden/ir_snapshots/codegen_cases/*.ssa")):
    t = open(f, encoding="utf-8", errors="ignore").read()
    defined = set(re.findall(r"function[^$\n]*\$([A-Za-z0-9_]+)\(", t))
    for m in re.findall(r"\$(nox_[A-Za-z0-9_]+)\(", t):
        if m not in defined:
            ext.setdefault(m, os.path.basename(f))
missing = sorted(n for n in ext if n not in in_table and not n.startswith(NATIVE_ONLY_PREFIXES))
if missing:
    print("wasm_abi_table.zig'de olmayan çalışma zamanı sembolleri (WASM'da imza saplamasına dönüşür):")
    for n in missing:
        print(f"  {n}  (örnek: {ext[n]})")
    print("Ekleyin: scripts/gen_wasm_abi.py çıktısındaki imzayı wasm_abi_table.zig'e elle taşıyın (betik tabloyu baştan yazar, elle eklenmiş girdileri siler) ya da yerel-özelse NATIVE_ONLY_PREFIXES'e ekleyin.")
    sys.exit(1)
print(f"wasm abi tablosu: temiz ({len(ext)} harici çalışma zamanı sembolü, {len(in_table)} tablo girdisi)")
