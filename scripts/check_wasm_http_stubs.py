#!/usr/bin/env python3
"""WASM `nox.http` stub'larının (`runtime/stdlib_shims/http_wasm.zig`) gerçek çalışma zamanıyla (`http_client.zig`, `http_server.zig`, `http_stream.zig`)
SEMBOL ADI ve İMZA olarak birebir aynı olduğunu denetler.

Neden: stub'lar yalnızca bir WASM programı gerçekten bir `nox_http_*` işlevi çağırdığında bağlanır; imza kayması (parametre ekleme/çıkarma, i32/i64 farkı)
derleyicinin ürettiği çağrıyla uyuşmaz ve wasm-ld hatasına ya da sessiz ABI bozulmasına yol açar. Gerçek bir sembol eklenir/değişirse bu betik kırmızı olur.

Kullanım: scripts/check_wasm_http_stubs.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REAL = ["http_client.zig", "http_server.zig", "http_stream.zig"]
STUB = "http_wasm.zig"
# Gerçek çalışma zamanında olup WASM'da bilerek bulunmayanlar: sunucu iç ayrıntıları, TLS/WebSocket sunucusu. (Şu an boş: hepsi stub'lanır.)
EXEMPT = set()


def signatures(path):
    text = open(os.path.join(ROOT, "runtime/stdlib_shims", path)).read()
    out = {}
    for m in re.finditer(r"^export fn (nox_http_[a-z0-9_]+)\((.*?)\)\s*callconv\(\.c\)\s*([^{]+?)\s*\{", text, re.M | re.S):
        name, params, ret = m.group(1), m.group(2), m.group(3)
        # parametre ADLARI önemsiz; yalnızca tür dizisi karşılaştırılır
        types = []
        for p in re.split(r",\s*(?![^()\[\]]*[\)\]])", params.strip()):
            p = p.strip().rstrip(",")
            if not p:
                continue
            ty = p.split(":", 1)[1].strip() if ":" in p else p
            types.append(re.sub(r"\s+", " ", ty))
        out[name] = (tuple(types), re.sub(r"\s+", " ", ret.strip()))
    return out


def normalize(sig):
    types, ret = sig
    # Gerçek sunucu işlevleri `HandlerFn`/`websocket_server.WsHandlerFn` gibi adlandırılmış işlev işaretçisi türleri alır; stub bunları `?*const anyopaque` yapar (aynı wasm32 ABI'si: i32).
    types = tuple("?*const anyopaque" if re.fullmatch(r"(HandlerFn|websocket_server\.WsHandlerFn)", t) else t for t in types)
    return types, ret


def main():
    real = {}
    for f in REAL:
        for k, v in signatures(f).items():
            real[k] = (f, v)
    stub = signatures(STUB)
    errors = []
    for name, (f, sig) in sorted(real.items()):
        if name in EXEMPT:
            continue
        if name not in stub:
            errors.append(f"eksik stub: {name} ({f})")
        elif normalize(sig) != normalize(stub[name]):
            errors.append(f"imza farkı: {name}\n    gerçek ({f}): {sig}\n    stub: {stub[name]}")
    for name in sorted(stub):
        if name not in real:
            errors.append(f"gerçek karşılığı olmayan stub: {name}")
    if errors:
        print("\n".join(errors))
        print(f"\n{len(errors)} sorun")
        return 1
    print(f"wasm http stub'ları gerçek çalışma zamanıyla uyumlu ({len(stub)} sembol)")
    return 0


sys.exit(main())
