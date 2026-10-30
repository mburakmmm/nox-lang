#!/usr/bin/env python3
"""`tests/golden/codegen_cases/reserved_symbol_names.{nox,expected}` üretici (v2.0.86 sembol politikası).

`compiler/codegen_qbe/reserved_symbols.zig`deki HER ayrılmış libc/libm/POSIX adı için bir kullanıcı fonksiyonu tanımlar ve çağırır; birkaç ad ayrıca işlev değeri, `spawn` ve
`nox.thread.start` yollarını dener. Nox'un kendi yerleşikleri (`abs`, `round`) ve anahtar sözcükler (`raise`) kullanıcı fonksiyonu olamaz ve atlanır. Liste değişince bu betik yeniden çalıştırılır
(`reserved_symbols.zig`deki birim testi fixture'ın her adı kapsadığını doğrular).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "compiler/codegen_qbe/reserved_symbols.zig")
OUT = os.path.join(ROOT, "tests/golden/codegen_cases/reserved_symbol_names")

NOT_USER_DEFINABLE = {"abs", "round", "raise"}  # Nox yerleşikleri / anahtar sözcükler
ASYNC_SPAWN = ["poll", "select"]  # `spawn` ile
ASYNC_THREAD = ["sleep"]  # `nox.thread.start` ile
AS_VALUE = ["memcpy", "strlen"]  # işlev değeri olarak


def names():
    text = open(SRC, encoding="utf-8").read()
    body = text[text.index("pub const names = [_][]const u8{"):]
    body = body[: body.index("};")]
    seen = []
    for n in re.findall(r'"([^"]+)"', body):
        if n not in seen and n not in NOT_USER_DEFINABLE:
            seen.append(n)
    return seen


def main():
    ns = names()
    special = set(ASYNC_SPAWN + ASYNC_THREAD)
    plain = [n for n in ns if n not in special]
    out = [
        "# v2.0.86 sembol politikası: libc/libm/POSIX adlarını taşıyan kullanıcı fonksiyonları nesne dosyasında `nox_user_` önekiyle yayılır; aksi halde `def printf`/`def getenv`",
        "# çalışma zamanının kendi libc çağrılarını ele geçirirdi. Üretici: scripts/gen_reserved_symbol_fixture.py (reserved_symbols.zig listesinden).",
        "import nox.thread",
        "",
    ]
    for i, n in enumerate(plain):
        out.append(f"def {n}(x: int) -> int:\n    return x + {i}\n")
    for n in ASYNC_SPAWN + ASYNC_THREAD:
        out.append(f"async def {n}(x: int) -> int:\n    return x * 3\n")
    out.append("total: int = 0")
    expected_total = 0
    for i, n in enumerate(plain):
        out.append(f"total = total + {n}(1)")
        expected_total += 1 + i
    out.append("print(total)")
    exp = [str(expected_total)]
    for n in AS_VALUE:
        i = plain.index(n)
        out.append(f"f_{n}: (int) -> int = {n}")
        out.append(f"print(f_{n}(10))")
        exp.append(str(10 + i))
    for k, n in enumerate(ASYNC_SPAWN):
        out.append(f"t{k}: Task[int] = spawn {n}({k + 7})")
        out.append(f"print(await t{k})")
        exp.append(str((k + 7) * 3))
    for k, n in enumerate(ASYNC_THREAD):
        out.append(f"h{k}: ThreadHandle[int] = nox.thread.start({n}, {k + 4})")
        out.append(f"print(await h{k}.join())")
        exp.append(str((k + 4) * 3))
    out.append('print("printf getenv exit ok")')
    exp.append("printf getenv exit ok")
    texts = {OUT + ".nox": "\n".join(out) + "\n", OUT + ".expected": "\n".join(exp) + "\n"}
    if "--check" in sys.argv:
        stale = [p for p, t in texts.items() if not os.path.exists(p) or open(p, encoding="utf-8").read() != t]
        if stale:
            sys.exit("reserved_symbol_names fixture'ı bayat (scripts/gen_reserved_symbol_fixture.py çalıştırın): " + ", ".join(os.path.basename(p) for p in stale))
        print("reserved_symbol_names fixture'ı güncel")
        return
    for p, t in texts.items():
        open(p, "w", encoding="utf-8").write(t)
    print(f"{len(plain)} düz + {len(special)} özel ad yazıldı")


if __name__ == "__main__":
    main()
