#!/usr/bin/env python3
"""noxc-nightly Aşama 1.1: `selfhost/lexer.nox.in` şablonundan `selfhost/lexer.nox` üretir.

Tek kaynaktan türetilenler (elle çoğaltılmaz, sıra/anlam uyumu `--check` ile kilitlenir):
  {{K:ad}}          `compiler/lexer/token.zig` `TokenKind` bildirim sırası (Zig `@enumFromInt` ile aynı sayı)
  {{KEYWORD_FN}}    `keyword_table`dan `kw_lookup(base, start, end)` (uzunluğa göre gruplanmış bayt karşılaştırmaları)
  {{UNI_TABLES}}    `compiler/lexer/unicode_ident.zig` `start`/`cont` aralıkları (lo, hi çiftleri, düz `list[int]`)

Kullanım: scripts/gen_selfhost_lexer.py            (selfhost/lexer.nox'u yazar)
          scripts/gen_selfhost_lexer.py --check    (güncel değilse çıkış 1; precheck/CI)
"""
import re, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN_ZIG = os.path.join(ROOT, "compiler/lexer/token.zig")
UNI_ZIG = os.path.join(ROOT, "compiler/lexer/unicode_ident.zig")
TEMPLATE = os.path.join(ROOT, "selfhost/lexer.nox.in")
OUTPUT = os.path.join(ROOT, "selfhost/lexer.nox")

HEADER = """# ÜRETİLMİŞ DOSYA: elle DÜZENLEMEYİN. Kaynak: selfhost/lexer.nox.in (+ compiler/lexer/token.zig, compiler/lexer/unicode_ident.zig).
# Yeniden üretmek için: scripts/gen_selfhost_lexer.py   (güncel mi: --check)
"""


def token_kinds():
    src = open(TOKEN_ZIG, encoding="utf-8").read()
    body = src[src.index("pub const TokenKind = enum {"):]
    body = body[: body.index("\n};")]
    names = []
    for line in body.split("\n")[1:]:
        s = line.strip()
        if not s or s.startswith("//"):
            continue
        m = re.match(r"([a-z_]+),", s)
        if m:
            names.append(m.group(1))
    return {n: i for i, n in enumerate(names)}


def keyword_table():
    src = open(TOKEN_ZIG, encoding="utf-8").read()
    out = []
    for m in re.finditer(r'\.\{ "([^"]+)", TokenKind\.([a-z_]+) \}', src):
        out.append((m.group(1), m.group(2)))
    return out


def keyword_fn(kinds):
    kws = keyword_table()
    by_len = {}
    for word, kind in kws:
        by_len.setdefault(len(word), []).append((word, kind))
    lines = ["# `base[start:end]` anahtar sözcükse türünü, değilse -1 döner (üretilmiş: uzunluğa göre bayt karşılaştırmaları).",
             "def kw_lookup(base: int, start: int, end: int) -> int:",
             "    ln: int = end - start"]
    for ln in sorted(by_len):
        lines.append(f"    if ln == {ln}:")
        lines.append("        b0: int = at(base, start)")
        for word, kind in by_len[ln]:
            conds = [f"b0 == {ord(word[0])}"] + [f"at(base, start + {k}) == {ord(ch)}" for k, ch in enumerate(word[1:], 1)]
            lines.append(f"        if {' and '.join(conds)}:")
            lines.append(f"            return {kinds[kind]}")
    lines.append("    return -1")
    return "\n".join(lines)


def uni_tables():
    src = open(UNI_ZIG, encoding="utf-8").read()
    res = []
    for name in ("start", "cont"):
        m = re.search(r"pub const %s = \[_\]Range\{(.*?)\n\};" % name, src, re.S)
        pairs = re.findall(r"\.lo = (0x[0-9A-Fa-f]+), \.hi = (0x[0-9A-Fa-f]+)", m.group(1))
        flat = []
        for lo, hi in pairs:
            flat += [int(lo, 16), int(hi, 16)]
        rows = []
        for i in range(0, len(flat), 16):
            rows.append("    " + ", ".join(str(x) for x in flat[i:i + 16]) + ",")
        res.append(f"UNI_{name.upper()}: list[int] = [\n" + "\n".join(rows) + "\n]")
    return "\n\n".join(res)


def generate():
    kinds = token_kinds()
    tpl = open(TEMPLATE, encoding="utf-8").read()
    out = tpl.replace("{{KEYWORD_FN}}", keyword_fn(kinds)).replace("{{UNI_TABLES}}", uni_tables())

    def sub(m):
        name = m.group(1)
        if name not in kinds:
            raise SystemExit(f"gen_selfhost_lexer: bilinmeyen token türü {{{{K:{name}}}}}")
        return str(kinds[name])

    out = re.sub(r"\{\{K:([a-z_]+)\}\}", sub, out)
    if "{{" in out:
        raise SystemExit("gen_selfhost_lexer: çözülmemiş yer tutucu kaldı: " + out[out.index("{{"):][:40])
    return HEADER + out


def main():
    text = generate()
    if "--check" in sys.argv:
        cur = open(OUTPUT, encoding="utf-8").read() if os.path.exists(OUTPUT) else ""
        if cur != text:
            print("selfhost/lexer.nox güncel değil: scripts/gen_selfhost_lexer.py çalıştırın", file=sys.stderr)
            return 1
        print(f"selfhost/lexer.nox güncel ({len(token_kinds())} token türü, {len(keyword_table())} anahtar sözcük)")
        return 0
    open(OUTPUT, "w", encoding="utf-8").write(text)
    print(f"yazıldı: {os.path.relpath(OUTPUT, ROOT)} ({len(text.splitlines())} satır)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
