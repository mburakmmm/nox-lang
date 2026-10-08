#!/usr/bin/env python3
"""Dokümantasyon doğrulayıcısı (docs/ ağacı).

Denetimler:
  1. `docs/_toc.yml` ile `docs/**/*.md` birebir örtüşür (yetim sayfa / eksik dosya yok).
  2. Her sayfa `# Başlık` ile başlar.
  3. Göreli bağlantılar (`[x](yol.md#bagla)`) mevcut sayfaya ve mevcut başlık bağlasına çıkar.
  4. ```nox bloklarının HEPSİ `noxc check` (tip denetimi) geçer; hemen ardından ```output bloğu gelen blok `noxc run` ile çalıştırılır ve
     çıktısı birebir eşleşir. ```nox-fragment ve diğer diller derlenmez.
  5. Stdlib kapsamı: `stdlib/nox/<mod>.nox`'un her herkese açık `def`/`class` adı `docs/stdlib/<mod>.md` içinde backtick'li geçer.

Kullanım:  python3 scripts/check_docs.py [--no-run] [--only <dizin-veya-dosya-öneki>]
Çıkış kodu 0 = temiz.
"""
import concurrent.futures
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, "docs")
NOXC = os.path.join(ROOT, "zig-out", "bin", "noxc")
STDLIB = os.path.join(ROOT, "stdlib", "nox")

# Belgelenmesi gerekmeyen iç modüller.
INTERNAL_MODULES = {"core", "testmod", "arch"}

FENCE = re.compile(r"^```(\S*)\s*$")


def slugify(text):
    text = re.sub(r"`", "", text.strip().lower())
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    return re.sub(r"[\s]+", "-", text).strip("-")


def load_toc():
    import yaml

    with open(os.path.join(DOCS, "_toc.yml"), encoding="utf-8") as f:
        data = yaml.safe_load(f)
    pages = []

    def walk(items):
        for it in items:
            if "page" in it:
                pages.append(it["page"])
            for key in ("pages", "children"):
                if key in it:
                    walk(it[key])

    walk(data["toc"])
    return pages


def all_md():
    out = []
    for dp, _, fns in os.walk(DOCS):
        for fn in fns:
            if fn.endswith(".md"):
                out.append(os.path.relpath(os.path.join(dp, fn), DOCS))
    return sorted(out)


def read(rel):
    with open(os.path.join(DOCS, rel), encoding="utf-8") as f:
        return f.read()


def headings(text):
    slugs = set()
    in_code = False
    for line in text.split("\n"):
        if FENCE.match(line.strip()):
            in_code = not in_code
            continue
        if in_code:
            continue
        m = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)
        if m:
            slugs.add(slugify(m.group(2)))
    return slugs


def blocks(text):
    """(lang, code, start_line, following_output_or_None) üretir."""
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i].strip())
        if m and m.group(1):
            lang = m.group(1)
            start = i + 1
            j = i + 1
            body = []
            while j < len(lines) and not FENCE.match(lines[j].strip()):
                body.append(lines[j])
                j += 1
            out.append([lang, "\n".join(body) + "\n", start, None])
            i = j + 1
        else:
            i += 1
    for k, b in enumerate(out):
        if b[0] == "nox" and k + 1 < len(out) and out[k + 1][0] == "output":
            b[3] = out[k + 1][1]
    return out


def run_noxc(args, cwd):
    return subprocess.run([NOXC] + args, capture_output=True, text=True, cwd=cwd, timeout=180)


def check_block(rel, lang, code, line, expected):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "doc_example.nox")
        with open(path, "w", encoding="utf-8") as f:
            f.write(code)
        if expected is None:
            r = run_noxc(["check", path], d)
            if r.returncode != 0:
                return f"{rel}:{line}: nox bloğu tip denetiminden geçmedi:\n    {(r.stdout + r.stderr).strip()}"
            return None
        r = run_noxc(["run", path], d)
        if r.returncode != 0:
            return f"{rel}:{line}: nox bloğu çalışmadı:\n    {(r.stdout + r.stderr).strip()}"
        if r.stdout != expected:
            return f"{rel}:{line}: çıktı uyuşmuyor.\n--- beklenen\n{expected}--- bulunan\n{r.stdout}"
        return None


PUBLIC = re.compile(r"^(?:extern\s+def|def|class)\s+([A-Za-z][A-Za-z0-9_]*)")


def public_names(mod):
    names = []
    with open(os.path.join(STDLIB, mod + ".nox"), encoding="utf-8") as f:
        for line in f:
            m = PUBLIC.match(line)
            if not m:
                continue
            n = m.group(1)
            if n.startswith("_") or n.endswith("_raw") or n.startswith("nox_"):
                continue
            names.append(n)
    return names


def main():
    argv = sys.argv[1:]
    no_run = "--no-run" in argv
    only = None
    if "--only" in argv:
        only = argv[argv.index("--only") + 1]
    errors = []

    toc = load_toc()
    mds = all_md()
    toc_set = set(toc)
    for p in toc:
        if p not in mds:
            errors.append(f"_toc.yml: '{p}' dosyası yok")
    for p in mds:
        if p not in toc_set:
            errors.append(f"{p}: _toc.yml'de listelenmemiş (yetim sayfa)")
    if len(toc) != len(toc_set):
        errors.append("_toc.yml: yinelenen sayfa girdisi var")

    heads_cache = {}
    jobs = []
    for rel in mds:
        text = read(rel)
        first = next((l for l in text.split("\n") if l.strip()), "")
        if not first.startswith("# "):
            errors.append(f"{rel}: ilk satır '# Başlık' olmalı")
        heads_cache[rel] = headings(text)

    link_re = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
    for rel in mds:
        text = read(rel)
        in_code = False
        for ln, line in enumerate(text.split("\n"), 1):
            if FENCE.match(line.strip()):
                in_code = not in_code
                continue
            if in_code:
                continue
            for m in link_re.finditer(re.sub(r"`[^`]*`", "", line)):
                target = m.group(1)
                if re.match(r"^[a-z]+:", target) or target.startswith("#") and False:
                    continue
                if re.match(r"^(https?|mailto):", target):
                    continue
                path, _, frag = target.partition("#")
                if path == "":
                    dest = rel
                else:
                    dest = os.path.normpath(os.path.join(os.path.dirname(rel), path))
                if dest.startswith(".."):
                    continue  # depo dışı (ör. ../AGENTS.md) — burada denetlenmez
                if dest.endswith(".md") and dest not in mds:
                    errors.append(f"{rel}:{ln}: kırık bağlantı → {target}")
                    continue
                if frag and dest in heads_cache and frag not in heads_cache[dest]:
                    errors.append(f"{rel}:{ln}: kırık bağlantı (başlık yok) → {target}")

    for rel in mds:
        if only and not rel.startswith(only):
            continue
        for lang, code, line, expected in blocks(read(rel)):
            if lang == "nox":
                jobs.append((rel, lang, code, line, expected))

    # stdlib kapsamı
    for fn in sorted(os.listdir(STDLIB)):
        if not fn.endswith(".nox"):
            continue
        mod = fn[:-4]
        if mod in INTERNAL_MODULES:
            continue
        page = f"stdlib/{mod}.md"
        if page not in mds:
            errors.append(f"stdlib kapsamı: {page} sayfası yok")
            continue
        text = read(page)
        code_spans = re.findall(r"`([^`]*)`", text)
        for n in public_names(mod):
            if not any(re.search(r"(?<![A-Za-z0-9_])" + re.escape(n) + r"(?![A-Za-z0-9_])", sp) for sp in code_spans) and f"{n}(" not in text:
                errors.append(f"stdlib kapsamı: {page} içinde `{n}` belgelenmemiş")

    if not os.path.exists(NOXC):
        errors.append(f"noxc bulunamadı: {NOXC} (önce `zig build`)")
    elif jobs:
        n = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
            futs = []
            for rel, lang, code, line, expected in jobs:
                if expected is not None and no_run:
                    expected = None
                futs.append(ex.submit(check_block, rel, lang, code, line, expected))
            for f in futs:
                r = f.result()
                n += 1
                if r:
                    errors.append(r)
        print(f"{n} nox bloğu denetlendi")

    print(f"{len(mds)} sayfa, {len(toc)} toc girdisi")
    if only:
        errors = [e for e in errors if e.startswith(only) or e.startswith("stdlib/" + only) or e.startswith("stdlib kapsamı: " + only)]
    if errors:
        print(f"\n{len(errors)} SORUN:")
        for e in errors:
            print(" -", e)
        return 1
    print("docs: temiz")
    return 0


if __name__ == "__main__":
    sys.exit(main())
