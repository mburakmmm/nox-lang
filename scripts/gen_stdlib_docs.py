#!/usr/bin/env python3
"""`stdlib/nox/*.nox` dosyalarından `docs/STDLIB.md` (stdlib API başvurusu) üretir.

Her modül için: modülün başındaki açıklama (ilk yorum bloğunun ilk paragrafı), herkese açık (adı `_` ile BAŞLAMAYAN) `def`/`class`
imzaları ve onlardan hemen önceki yorumun ilk cümlesi. `extern def` (ham FFI) ve `*_raw` işlevleri listelenmez.

Kullanım: python3 scripts/gen_stdlib_docs.py > docs/STDLIB.md
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STD = os.path.join(ROOT, "stdlib", "nox")


ABBREV = ["bkz.", "ör.", "vb.", "ve ark.", "yani", "i.e.", "e.g."]


def first_sentence(comment_lines):
    lines = [l.strip() for l in comment_lines if l.strip() and not re.fullmatch(r"[-=#*\s]+", l.strip())]
    text = " ".join(lines).strip()
    if not text:
        return ""
    prot = text
    for a in ABBREV:
        prot = prot.replace(a, a.replace(".", "\u0001"))
    m = re.search(r"(.+?[.!?])(\s|$)", prot)
    out = (m.group(1) if m else prot).replace("\u0001", ".")
    out = re.sub(r"^[A-Za-z_.0-9]+ — ", "", out)  # "nox.x — " öneki
    return out[:200]


def module_doc(lines):
    out = []
    started = False
    for l in lines:
        if l.startswith("#"):
            started = True
            out.append(l.lstrip("#").strip())
        elif started:
            break
        elif l.strip() == "":
            continue
        else:
            break
    # ilk paragraf
    para = []
    for l in out:
        if l == "" and para:
            break
        if l:
            para.append(l)
    return first_sentence(para)


def parse(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    items = []
    comment = []
    i = 0
    while i < len(lines):
        l = lines[i]
        if l.startswith("#"):
            comment.append(l.lstrip("#").strip())
        elif l.startswith("def ") or l.startswith("async def "):
            sig = l
            # çok satırlı imza
            while not sig.rstrip().endswith(":") and i + 1 < len(lines):
                i += 1
                sig += " " + lines[i].strip()
            name = re.match(r"(?:async )?def\s+([A-Za-z_0-9]+)", sig).group(1)
            if not name.startswith("_") and not name.endswith("_raw"):
                items.append(("def", sig.rstrip(":").strip(), first_sentence(comment)))
            comment = []
        elif l.startswith("class "):
            name = re.match(r"class\s+([A-Za-z_0-9]+)", l).group(1)
            if not name.startswith("_"):
                items.append(("class", l.rstrip(":").strip(), first_sentence(comment)))
            comment = []
        elif l.strip() == "":
            comment = []
        elif l.startswith((" ", "\t")):
            m = re.match(r"    def\s+([A-Za-z_0-9]+)", l)
            if m and items and items[-1][0] == "class" and not m.group(1).startswith("_"):
                sig = l.strip()
                while not sig.rstrip().endswith(":") and i + 1 < len(lines):
                    i += 1
                    sig += " " + lines[i].strip()
                items.append(("method", sig.rstrip(":").strip(), ""))
        else:
            comment = []
        i += 1
    return lines, items


def main():
    mods = sorted(f for f in os.listdir(STD) if f.endswith(".nox"))
    print("# Nox standart kütüphane başvurusu\n")
    print("Bu dosya `scripts/gen_stdlib_docs.py` ile `stdlib/nox/*.nox`ten ÜRETİLİR (elle düzenlemeyin). Her modül `import nox.<ad>` ile kullanılır;")
    print("`nox.core` her programa otomatik dahildir. Ayrıntılar için modülün kaynak dosyasındaki yorumlara bakın.\n")
    print("## İçindekiler\n")
    for f in mods:
        n = f[:-4]
        print(f"- [`nox.{n}`](#nox{n})")
    print()
    for f in mods:
        n = f[:-4]
        lines, items = parse(os.path.join(STD, f))
        print(f"## `nox.{n}`\n")
        d = module_doc(lines)
        if d:
            print(d + "\n")
        if not items:
            print("_Herkese açık tanım yok._\n")
            continue
        for kind, sig, doc in items:
            indent = "  " if kind == "method" else ""
            print(f"{indent}- `{sig}`" + (f" — {doc}" if doc else ""))
        print()


if __name__ == "__main__":
    main()
