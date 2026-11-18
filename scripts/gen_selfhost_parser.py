#!/usr/bin/env python3
"""noxc-nightly Aşama 2.C: `selfhost/parser.nox.in` şablonundan `selfhost/parser.nox` üretir.

Tek kaynaktan türetilenler (elle çoğaltılmaz; ast.zig/token.zig değişince `--check` kırılır):
  {{K:ad}}          `compiler/lexer/token.zig` `TokenKind` sayısı
  {{T:Birlesim.v}}  birleşim (union) varyant etiketi (ör. `{{T:Expr.binary}}`, `{{T:StmtKind.if_stmt}}`)
  {{O:Yapi.alan}}   yapı düğümünde alanın sözcük ofseti (ör. `{{O:Binary.left}}`)
  {{E:Enum.v}}      enum sıra sayısı (ör. `{{E:BinaryOp.add}}`)
  {{SZ:Yapi}}       yapı düğümünün sözcük sayısı (kopyalama için)
  {{FROM_AST}}      şablonda kullanılan `mk_*`/`Ast`/yazıcı adlarının `from ast_schema import ...` satırı
  {{NONE}}          `opt(str)`/`opt(slice)` "yok" işareti

Kullanım: scripts/gen_selfhost_parser.py          (selfhost/parser.nox'u yazar)
          scripts/gen_selfhost_parser.py --check  (güncel değilse çıkış 1; precheck/CI)
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_selfhost_ast as ga  # noqa: E402
import gen_selfhost_lexer as gl  # noqa: E402

ROOT = ga.ROOT
TEMPLATE = os.path.join(ROOT, "selfhost/parser.nox.in")
OUTPUT = os.path.join(ROOT, "selfhost/parser.nox")

HEADER = """# ÜRETİLMİŞ DOSYA: elle DÜZENLEMEYİN. Kaynak: selfhost/parser.nox.in (+ compiler/lexer/token.zig, compiler/parser/ast.zig şeması).
# Yeniden üretmek için: scripts/gen_selfhost_parser.py   (güncel mi: --check)
"""


def build_tables(types):
    gen = ga.Gen(types)
    tags = {}
    offs = {}
    enums = {}
    sizes = {}
    for name, ty in types.items():
        if ty["kind"] == "enum":
            for i, n in enumerate(ty["names"]):
                enums[f"{name}.{n}"] = i
        elif ty["kind"] == "union":
            for i, (vname, _, _) in enumerate(ty["fields"]):
                tags[f"{name}.{vname}"] = i
        elif ty["kind"] == "struct" and name != "Module":
            off = 0
            for fname, ftype, _ in ty["fields"]:
                t = ga.parse_type(ftype)
                if t[0] == "skip":
                    continue
                offs[f"{name}.{fname}"] = off
                off += gen.size(t)
            sizes[name] = off
    return tags, offs, enums, sizes


def generate():
    types = ga.load_schema()
    tags, offs, enums, sizes = build_tables(types)
    kinds = gl.token_kinds()
    tpl = open(TEMPLATE, encoding="utf-8").read()

    def sub(table, label):
        def f(m):
            key = m.group(1)
            if key not in table:
                raise SystemExit(f"gen_selfhost_parser: bilinmeyen {label} {key!r}")
            return str(table[key])
        return f

    out = re.sub(r"\{\{K:([a-z_]+)\}\}", sub(kinds, "token türü"), tpl)
    out = re.sub(r"\{\{T:([A-Za-z_.]+)\}\}", sub(tags, "birleşim varyantı"), out)
    out = re.sub(r"\{\{O:([A-Za-z_.]+)\}\}", sub(offs, "alan ofseti"), out)
    out = re.sub(r"\{\{SZ:([A-Za-z_.]+)\}\}", sub(sizes, "yapı boyutu"), out)
    out = re.sub(r"\{\{E:([A-Za-z_.]+)\}\}", sub(enums, "enum değeri"), out)
    out = out.replace("{{NONE}}", str(ga.NONE))
    names = sorted(set(re.findall(r"\b(mk_[A-Za-z_]+)\b", out)))
    names += ["Ast", "dump_module", "put", "at"]
    out = out.replace("{{FROM_AST}}", "from ast_schema import " + ", ".join(sorted(set(names))))
    if "{{" in out:
        raise SystemExit("gen_selfhost_parser: çözülmemiş yer tutucu kaldı: " + out[out.index("{{"):][:40])
    return HEADER + out


def main():
    text = generate()
    if "--check" in sys.argv:
        cur = open(OUTPUT, encoding="utf-8").read() if os.path.exists(OUTPUT) else ""
        if cur != text:
            print("selfhost/parser.nox güncel değil: scripts/gen_selfhost_parser.py çalıştırın", file=sys.stderr)
            return 1
        print("selfhost/parser.nox güncel")
        return 0
    open(OUTPUT, "w", encoding="utf-8").write(text)
    print(f"yazıldı: {os.path.relpath(OUTPUT, ROOT)} ({len(text.splitlines())} satır)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
