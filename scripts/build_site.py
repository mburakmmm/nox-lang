#!/usr/bin/env python3
"""noxlang.com sitesini üretir: `docs/` (Markdown) + `services/noxlang-site/site/` (şablon/varlık) -> `public/`.

Çıktı düzeni (Nyx uygulaması `manifest.tsv` ile bunu olduğu gibi sunar):

  public/index.html                  landing sayfası
  public/docs/<yol>/index.html       her doküman sayfası (docs/index.md -> /docs/)
  public/assets/{css,js,fonts,img}/  statik varlıklar
  public/search-index.json           istemci tarafı arama indeksi
  public/{404.html,robots.txt,sitemap.xml,install.sh,install.ps1,site.webmanifest}
  public/manifest.tsv                url<TAB>dosya<TAB>içerik-türü<TAB>cache (Nyx okur)

Kullanım:
  python3 scripts/build_site.py [--out DIR] [--verify]

  --verify  landing sayfasındaki kod örneklerini `zig-out/bin/noxc` ile derleyip çıktılarını doğrular.

Bağımlılıklar: Markdown, Pygments, PyYAML (.docs-venv veya Docker aşaması).
"""
import argparse
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import markdown
import yaml
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexer import RegexLexer, bygroups, include, words
from pygments.lexers import get_lexer_by_name
from pygments.token import (Comment, Keyword, Name, Number, Operator, Punctuation,
                            String, Text)
from pygments.util import ClassNotFound

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, "docs")
SITE_SRC = os.path.join(ROOT, "services", "noxlang-site", "site")
BRAND = os.path.join(ROOT, "assets", "brand")
BASE_URL = "https://noxlang.com"
REPO_URL = "https://github.com/mburakmmm/nox-lang"
PKG_URL = "https://noxpkg.noxlang.com"


# --------------------------------------------------------------------------------------
# Nox sözdizimi renklendirici (compiler/lexer/token.zig anahtar kelimeleri)
# --------------------------------------------------------------------------------------
class NoxLexer(RegexLexer):
    name = "Nox"
    aliases = ["nox", "nox-fragment"]
    filenames = ["*.nox"]

    KEYWORDS = ("def", "class", "if", "elif", "else", "while", "for", "in", "return", "pass", "break",
                "continue", "del", "and", "or", "not", "raise", "try", "except", "finally", "as",
                "lowlevel", "protocol", "extern", "from", "async", "await", "spawn", "import", "retains",
                "with", "defer", "lambda", "is")
    CONSTANTS = ("True", "False", "None")
    BUILTINS = ("print", "len", "range", "str", "int", "float", "bool", "list", "dict", "set", "tuple",
                "abs", "min", "max", "sum", "round", "input", "repr", "sorted", "enumerate", "zip",
                "super", "sizeof", "alignof", "offsetof", "ptr_read", "ptr_write", "ptr_offset",
                "ptr_to_int", "ptr_from_int", "detach", "adopt", "u8", "u16", "u32", "u64", "i8", "i16",
                "i32", "i64", "usize", "isize", "ptr", "self")

    tokens = {
        "root": [
            (r"\n", Text),
            (r"[^\S\n]+", Text),
            (r"#.*$", Comment.Single),
            (r'[fF](?=["\'])', String.Affix),
            (r'"""', String.Double, "tdq"),
            (r"'''", String.Single, "tsq"),
            (r'"', String.Double, "dq"),
            (r"'", String.Single, "sq"),
            (r"(@)([A-Za-z_][\w.]*)", bygroups(Name.Decorator, Name.Decorator)),
            (r"(def)(\s+)([A-Za-z_]\w*)", bygroups(Keyword, Text, Name.Function)),
            (r"(class|protocol)(\s+)([A-Za-z_]\w*)", bygroups(Keyword, Text, Name.Class)),
            (words(KEYWORDS, suffix=r"\b"), Keyword),
            (words(CONSTANTS, suffix=r"\b"), Keyword.Constant),
            (words(BUILTINS, prefix=r"\b", suffix=r"\b"), Name.Builtin),
            (r"\b[A-Z][A-Za-z0-9_]*(?:Error|Exception)\b", Name.Exception),
            (r"\b[A-Z][A-Za-z0-9_]*\b", Name.Class),
            (r"0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+", Number.Integer),
            (r"\d[\d_]*\.\d[\d_]*(?:[eE][+-]?\d+)?|\d[\d_]*[eE][+-]?\d+", Number.Float),
            (r"\d[\d_]*", Number.Integer),
            (r"->|\*\*=?|//=?|<<=?|>>=?|[+\-*/%&|^<>=!]=?|~", Operator),
            (r"[()\[\]{},:.;]", Punctuation),
            (r"[A-Za-z_]\w*", Name),
            (r".", Text),
        ],
        "dq": [(r'\\.', String.Escape), (r"\{\{|\}\}", String.Escape), (r"[{}]", String.Interpol),
               (r'"', String.Double, "#pop"), (r'[^"\\{}\n]+', String.Double), (r"\n", String.Double, "#pop")],
        "sq": [(r"\\.", String.Escape), (r"\{\{|\}\}", String.Escape), (r"[{}]", String.Interpol),
               (r"'", String.Single, "#pop"), (r"[^'\\{}\n]+", String.Single), (r"\n", String.Single, "#pop")],
        "tdq": [(r'"""', String.Double, "#pop"), (r'[^"]+|"', String.Double)],
        "tsq": [(r"'''", String.Single, "#pop"), (r"[^']+|'", String.Single)],
    }


FORMATTER = HtmlFormatter(nowrap=True, classprefix="t-")
LANG_LABEL = {"nox": "Nox", "nox-fragment": "Nox", "sh": "Shell", "bash": "Shell", "text": "Text",
              "json": "JSON", "output": "Output", "yaml": "YAML", "toml": "TOML", "c": "C", "zig": "Zig",
              "powershell": "PowerShell", "ps1": "PowerShell", "python": "Python", "html": "HTML"}


def highlight_code(code, lang):
    if lang in ("nox", "nox-fragment"):
        lexer = NoxLexer()
    elif lang in ("output", "text", ""):
        return html.escape(code)
    else:
        try:
            lexer = get_lexer_by_name({"sh": "bash", "ps1": "powershell"}.get(lang, lang))
        except ClassNotFound:
            return html.escape(code)
    return highlight(code, lexer, FORMATTER).rstrip("\n")


# --------------------------------------------------------------------------------------
# Markdown -> HTML
# --------------------------------------------------------------------------------------
def slugify(text, sep="-"):
    """scripts/check_docs.py `slugify` ile birebir aynı (bağlantı kontrolü bu başlık bağalarına dayanır)."""
    text = re.sub(r"`", "", text.strip().lower())
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    return re.sub(r"[\s]+", sep, text).strip(sep)


def page_url(rel):
    """docs-göreli .md yolu -> site URL'si."""
    rel = rel.replace("\\", "/")
    if rel == "index.md":
        return "/docs/"
    if rel.endswith("/index.md"):
        return "/docs/" + rel[: -len("index.md")]
    return "/docs/" + rel[:-3] + "/"


def load_toc():
    with open(os.path.join(DOCS, "_toc.yml"), encoding="utf-8") as fh:
        toc = yaml.safe_load(fh)["toc"]
    sections, order = [], []
    for sec in toc:
        pages = []
        for p in sec["pages"]:
            rel = p["page"]
            with open(os.path.join(DOCS, rel), encoding="utf-8") as fh:
                src = fh.read()
            m = re.match(r"#\s+(.+?)\s*\n", src)
            if not m:
                sys.exit(f"{rel}: '# Başlık' ile başlamıyor")
            pages.append({"rel": rel, "url": page_url(rel), "title": m.group(1).strip(), "src": src[m.end():],
                          "section": sec["section"], "slug": sec["slug"]})
        sections.append({"section": sec["section"], "slug": sec["slug"], "pages": pages})
        order.extend(pages)
    return sections, order


def resolve_link(href, cur_rel, known):
    """Göreli .md bağlantısını site URL'sine çevirir; dış/#/mailto bağlantılarına dokunmaz."""
    if re.match(r"^(https?:|mailto:|#|/)", href):
        return href
    path, _, frag = href.partition("#")
    if not path.endswith(".md"):
        return href
    target = os.path.normpath(os.path.join(os.path.dirname(cur_rel), path)).replace("\\", "/")
    if target not in known:
        sys.exit(f"{cur_rel}: bilinmeyen bağlantı hedefi {href}")
    return known[target] + ("#" + frag if frag else "")


CODE_RE = re.compile(r'<pre><code(?: class="language-([\w+-]+)")?>(.*?)</code></pre>', re.S)


def render_code_block(m):
    lang = m.group(1) or ""
    code = html.unescape(m.group(2))
    if code.endswith("\n"):
        code = code[:-1]
    body = highlight_code(code, lang)
    label = LANG_LABEL.get(lang, lang.upper() if lang else "")
    cls = "code code-out" if lang == "output" else "code"
    fragment = ' data-fragment="1"' if lang == "nox-fragment" else ""
    head = f'<div class="code-head"><span class="code-lang">{html.escape(label)}</span>'
    if lang != "output":
        head += '<button class="code-copy" type="button" aria-label="Copy code">Copy</button>'
    head += "</div>"
    return f'<div class="{cls}"{fragment}>{head}<pre><code>{body}</code></pre></div>'


H_RE = re.compile(r'<h([2-4]) id="([^"]+)">(.*?)</h\1>', re.S)


def render_markdown(page, known):
    md = markdown.Markdown(extensions=["tables", "fenced_code", "toc", "sane_lists"],
                           extension_configs={"toc": {"slugify": slugify, "permalink": False}})
    body = md.convert(page["src"])
    body = CODE_RE.sub(render_code_block, body)
    body = re.sub(r"<table>", '<div class="table-wrap"><table>', body)
    body = body.replace("</table>", "</table></div>")

    def link_sub(m):
        href = resolve_link(html.unescape(m.group(1)), page["rel"], known)
        external = href.startswith("http")
        extra = ' rel="noopener" target="_blank"' if external and "noxlang.com" not in href else ""
        return f'<a href="{html.escape(href, quote=True)}"{extra}'

    body = re.sub(r'<a href="([^"]*)"', link_sub, body)

    headings = []

    def head_sub(m):
        level, hid, inner = int(m.group(1)), m.group(2), m.group(3)
        text = html.unescape(re.sub(r"<[^>]+>", "", inner))
        headings.append((level, hid, text))
        return f'<h{level} id="{hid}">{inner}<a class="anchor" href="#{hid}" aria-label="Link to this section">#</a></h{level}>'

    body = H_RE.sub(head_sub, body)
    plain = html.unescape(re.sub(r"<[^>]+>", " ", re.sub(r"<pre>.*?</pre>", " ", body, flags=re.S)))
    plain = re.sub(r"\s+", " ", plain).strip()
    return body, headings, plain


# --------------------------------------------------------------------------------------
# Sayfa kabukları
# --------------------------------------------------------------------------------------
def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write(path, data, binary=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if binary else "w", **({} if binary else {"encoding": "utf-8"})) as fh:
        fh.write(data)


def asset_hash(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()[:10]


def head_html(title, description, canonical, og_image, extra=""):
    t = html.escape(title)
    d = html.escape(description, quote=True)
    return f"""<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t}</title>
<meta name="description" content="{d}">
<meta name="color-scheme" content="dark light">
<meta name="theme-color" content="#04070D">
<link rel="canonical" href="{canonical}">
<link rel="icon" type="image/png" sizes="32x32" href="/assets/img/icon-32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/assets/img/icon-16.png">
<link rel="apple-touch-icon" href="/assets/img/icon-180.png">
<link rel="manifest" href="/site.webmanifest">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Nox">
<meta property="og:title" content="{t}">
<meta property="og:description" content="{d}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{og_image}">
<meta name="twitter:card" content="summary_large_image">
<link rel="preload" href="/assets/fonts/unbounded-latin-700-normal.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/assets/fonts/ibm-plex-sans-latin-400-normal.woff2" as="font" type="font/woff2" crossorigin>
<script src="/assets/js/theme-init.js"></script>
<link rel="stylesheet" href="/assets/css/site.css?v={{CSSV}}">
{extra}"""


HEADER = """<header class="topbar">
  <a class="brand" href="/" aria-label="Nox home"><img src="/assets/img/icon-64.png" width="30" height="30" alt=""><span>Nox</span></a>
  <nav class="topnav" aria-label="Primary">
    <a href="/docs/tutorial/">Tutorial</a>
    <a href="/docs/language/">Language</a>
    <a href="/docs/stdlib/">Stdlib</a>
    <a href="/docs/apis/">APIs</a>
    <a href="/docs/tools/noxc/">Tools</a>
    <a href="{pkg}" rel="noopener">Packages</a>
  </nav>
  <div class="topright">
    <button class="search-open" type="button" aria-label="Search the docs" data-search-open><svg viewBox="0 0 20 20" width="16" height="16" aria-hidden="true"><circle cx="8.5" cy="8.5" r="5.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M13 13l4.5 4.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg><span>Search</span><kbd>/</kbd></button>
    <a class="gh" href="{repo}" rel="noopener" aria-label="Nox on GitHub"><svg viewBox="0 0 16 16" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M8 0C3.58 0 0 3.58 0 8a8 8 0 005.47 7.59c.4.07.55-.17.55-.38v-1.33c-2.23.48-2.7-1.07-2.7-1.07-.36-.92-.89-1.17-.89-1.17-.73-.5.05-.49.05-.49.8.06 1.23.83 1.23.83.71 1.22 1.87.87 2.33.66.07-.52.28-.87.5-1.07-1.78-.2-3.65-.89-3.65-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.6 7.6 0 014 0c1.53-1.03 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.28.82 2.15 0 3.07-1.87 3.75-3.66 3.95.29.25.54.73.54 1.48v2.2c0 .21.15.46.55.38A8 8 0 0016 8c0-4.42-3.58-8-8-8z"/></svg></a>
    <button class="theme-toggle" type="button" aria-label="Toggle colour theme" data-theme-toggle><svg viewBox="0 0 20 20" width="18" height="18" aria-hidden="true"><path class="i-moon" d="M16.5 12.2A7 7 0 017.8 3.5a7 7 0 108.7 8.7z" fill="currentColor"/><g class="i-sun" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="10" cy="10" r="3.6" fill="currentColor"/><path d="M10 1.5v2M10 16.5v2M1.5 10h2M16.5 10h2M4 4l1.4 1.4M14.6 14.6L16 16M16 4l-1.4 1.4M5.4 14.6L4 16"/></g></svg></button>
    <button class="menu-toggle" type="button" aria-label="Open navigation" data-menu-toggle><span></span><span></span><span></span></button>
  </div>
</header>
<div class="search-modal" id="search-modal" hidden>
  <div class="search-backdrop" data-search-close></div>
  <div class="search-panel" role="dialog" aria-modal="true" aria-label="Search">
    <input id="search-input" type="search" placeholder="Search docs, functions, modules…" autocomplete="off" spellcheck="false">
    <ul id="search-results" role="listbox"></ul>
    <p class="search-hint"><kbd>↑</kbd><kbd>↓</kbd> to move · <kbd>Enter</kbd> to open · <kbd>Esc</kbd> to close</p>
  </div>
</div>
""".replace("{pkg}", PKG_URL).replace("{repo}", REPO_URL)


FOOTER = """<footer class="footer">
  <div class="footer-inner">
    <div class="footer-brand">
      <a class="brand" href="/"><img src="/assets/img/icon-64.png" width="28" height="28" alt=""><span>Nox</span></a>
      <p>Native without the ownership noise.</p>
    </div>
    <nav class="footer-cols" aria-label="Footer">
      <div><h4>Learn</h4><a href="/docs/install/">Install</a><a href="/docs/tutorial/">Tutorial</a><a href="/docs/language/">Language reference</a><a href="/docs/stdlib/">Standard library</a></div>
      <div><h4>Build on Nox</h4><a href="/docs/apis/">The three APIs</a><a href="/docs/apis/nni/">Native interface (NNI)</a><a href="/docs/apis/plugin-api/">Plugin API</a><a href="/docs/tools/noxpkg/">Publish a package</a></div>
      <div><h4>Project</h4><a href="{repo}" rel="noopener">GitHub</a><a href="{pkg}" rel="noopener">noxpkg registry</a><a href="/docs/whatsnew/2.0/">What’s new in 2.0</a><a href="/docs/reference/versioning/">Versioning policy</a></div>
    </nav>
  </div>
  <div class="footer-base"><span>© Melih Burak Memiş and Nox contributors · MIT License</span><span>noxlang.com is served by a Nyx app written in Nox.</span></div>
</footer>
""".replace("{repo}", REPO_URL).replace("{pkg}", PKG_URL)


def sidebar_html(sections, current_url):
    out = ['<nav class="sidebar" aria-label="Documentation" id="sidebar">']
    for sec in sections:
        active_sec = any(p["url"] == current_url for p in sec["pages"])
        out.append(f'<details class="side-sec"{" open" if active_sec else ""}><summary>{html.escape(sec["section"])}</summary><ul>')
        for p in sec["pages"]:
            cur = ' aria-current="page"' if p["url"] == current_url else ""
            out.append(f'<li><a href="{p["url"]}"{cur}>{html.escape(p["title"])}</a></li>')
        out.append("</ul></details>")
    out.append("</nav>")
    return "\n".join(out)


def toc_html(headings):
    items = [(l, i, t) for (l, i, t) in headings if l in (2, 3)]
    if len(items) < 2:
        return '<aside class="toc" aria-hidden="true"></aside>'
    lis = "".join(f'<li class="l{l}"><a href="#{i}">{html.escape(t)}</a></li>' for (l, i, t) in items)
    return f'<aside class="toc" aria-label="On this page"><h4>On this page</h4><ul>{lis}</ul></aside>'


def first_paragraph(plain, limit=170):
    text = plain[:400]
    cut = text.find(". ")
    if 60 < cut < limit:
        return text[: cut + 1]
    return (text[:limit].rsplit(" ", 1)[0] + "…") if len(text) > limit else text


def build_doc_page(page, idx, order, sections, known, css_v):
    body, headings, plain = render_markdown(page, known)
    prev_p = order[idx - 1] if idx > 0 else None
    next_p = order[idx + 1] if idx + 1 < len(order) else None
    desc = first_paragraph(plain) or page["title"]
    pager = '<nav class="pager" aria-label="Previous and next page">'
    pager += (f'<a class="prev" href="{prev_p["url"]}"><small>Previous</small><span>{html.escape(prev_p["title"])}</span></a>'
              if prev_p else "<span></span>")
    pager += (f'<a class="next" href="{next_p["url"]}"><small>Next</small><span>{html.escape(next_p["title"])}</span></a>'
              if next_p else "<span></span>")
    pager += "</nav>"
    edit = f'{REPO_URL}/blob/main/docs/{page["rel"]}'
    title = f'{page["title"]} · Nox docs' if page["rel"] != "index.md" else "Nox documentation"
    head = head_html(title, desc, BASE_URL + page["url"], BASE_URL + "/assets/img/social-preview.png").replace("{CSSV}", css_v)
    return f"""<!doctype html>
<html lang="en">
<head>
{head}
</head>
<body class="doc-body">
<a class="skip" href="#content">Skip to content</a>
{HEADER}
<div class="doc-shell">
{sidebar_html(sections, page["url"])}
<main class="doc-main" id="content">
<article class="prose">
<p class="eyebrow">{html.escape(page["section"])}</p>
<h1>{html.escape(page["title"])}</h1>
{body}
<p class="edit-link"><a href="{edit}" rel="noopener">Edit this page on GitHub</a></p>
{pager}
</article>
</main>
{toc_html(headings)}
</div>
{FOOTER}
<script src="/assets/js/app.js?v={css_v}" defer></script>
</body>
</html>
""", headings, plain, desc


# --------------------------------------------------------------------------------------
# Landing sayfası
# --------------------------------------------------------------------------------------
def load_snippets():
    """site/snippets/*.nox (+ .out) -> sözlük. `--verify` ile derleyiciyle doğrulanır."""
    sd = os.path.join(SITE_SRC, "snippets")
    snips = {}
    for fn in sorted(os.listdir(sd)):
        if fn.endswith(".nox") and os.path.isfile(os.path.join(sd, fn)):
            name = fn[:-4]
            code = read(os.path.join(sd, fn)).rstrip("\n")
            outp = os.path.join(sd, name + ".out")
            snips[name] = {"code": code, "out": read(outp).rstrip("\n") if os.path.exists(outp) else None,
                           "path": os.path.join(sd, fn)}
    return snips


def verify_snippets(snips):
    noxc = os.path.join(ROOT, "zig-out", "bin", "noxc")
    if not os.path.exists(noxc):
        sys.exit("--verify için zig-out/bin/noxc gerekir (zig build)")
    tmp = tempfile.mkdtemp(prefix="nox-site-verify-")
    for name, s in snips.items():
        if s["out"] is None:
            r = subprocess.run([noxc, "check", s["path"]], capture_output=True, text=True, timeout=120, cwd=tmp)
            if r.returncode != 0:
                sys.exit(f"snippet {name}: noxc check başarısız:\n{r.stdout}{r.stderr}")
        else:
            r = subprocess.run([noxc, "run", s["path"]], capture_output=True, text=True, timeout=120, cwd=tmp)
            if r.returncode != 0 or r.stdout.rstrip("\n") != s["out"]:
                sys.exit(f"snippet {name}: çıktı uyuşmuyor\n beklenen: {s['out']!r}\n gelen:    {r.stdout!r}\n{r.stderr}")
    print(f"landing örnekleri doğrulandı ({len(snips)})")


def code_card(code, lang="nox", label=None, out=None):
    body = highlight_code(code, lang)
    lab = label or LANG_LABEL.get(lang, lang)
    h = (f'<div class="code"><div class="code-head"><span class="code-lang">{html.escape(lab)}</span>'
         f'<button class="code-copy" type="button" aria-label="Copy code">Copy</button></div><pre><code>{body}</code></pre></div>')
    if out is not None:
        h += (f'<div class="code code-out"><div class="code-head"><span class="code-lang">Output</span></div>'
              f'<pre><code>{html.escape(out)}</code></pre></div>')
    return h


def build_landing(sections, snips, css_v, stdlib_pages):
    tpl = read(os.path.join(SITE_SRC, "landing.html"))
    head = head_html("Nox — native without the ownership noise",
                     "Nox is a statically typed language with Python's syntax, compiled ahead of time to native code, "
                     "with automatic memory management and no ownership annotations.",
                     BASE_URL + "/", BASE_URL + "/assets/img/social-preview.png").replace("{CSSV}", css_v)
    tabs = [("classes", "Classes & types"), ("tasks", "Concurrency"), ("web", "A web service"), ("native", "Native code")]
    tab_btns = "".join(f'<button role="tab" class="tab" id="tab-{k}" aria-controls="panel-{k}" aria-selected="{"true" if i == 0 else "false"}" tabindex="{0 if i == 0 else -1}">{html.escape(t)}</button>'
                       for i, (k, t) in enumerate(tabs))
    panels = "".join(f'<div role="tabpanel" class="panel" id="panel-{k}" aria-labelledby="tab-{k}"{"" if i == 0 else " hidden"}>'
                     f'{code_card(snips[k]["code"], "nox", out=snips[k]["out"])}</div>'
                     for i, (k, _) in enumerate(tabs))
    chips = "".join(f'<a class="chip" href="{p["url"]}">{html.escape(p["title"].replace("nox.", ""))}</a>' for p in stdlib_pages)
    html_out = (tpl.replace("{{HEAD}}", head).replace("{{HEADER}}", HEADER).replace("{{FOOTER}}", FOOTER)
                .replace("{{TABS}}", tab_btns).replace("{{PANELS}}", panels).replace("{{CHIPS}}", chips)
                .replace("{{MODULE_COUNT}}", str(len(stdlib_pages))).replace("{{CSSV}}", css_v)
                .replace("{{HERO_SNIPPET}}", code_card(snips["hero"]["code"], "nox", out=snips["hero"]["out"])))
    return html_out


# --------------------------------------------------------------------------------------
# Derleme
# --------------------------------------------------------------------------------------
CONTENT_TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
                 ".js": "text/javascript; charset=utf-8", ".json": "application/json; charset=utf-8",
                 ".png": "image/png", ".woff2": "font/woff2", ".txt": "text/plain; charset=utf-8",
                 ".xml": "application/xml; charset=utf-8", ".webmanifest": "application/manifest+json",
                 ".sh": "text/x-shellscript; charset=utf-8", ".ps1": "text/plain; charset=utf-8",
                 ".svg": "image/svg+xml", ".ico": "image/x-icon"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "services", "noxlang-site", "public"))
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out)

    snips = load_snippets()
    if args.verify:
        verify_snippets(snips)

    sections, order = load_toc()
    known = {p["rel"]: p["url"] for p in order}

    # varlıklar
    for sub in ("css", "js", "fonts"):
        shutil.copytree(os.path.join(SITE_SRC, sub), os.path.join(out, "assets", sub))
    shutil.copytree(os.path.join(SITE_SRC, "img"), os.path.join(out, "assets", "img"), dirs_exist_ok=True) \
        if os.path.isdir(os.path.join(SITE_SRC, "img")) else os.makedirs(os.path.join(out, "assets", "img"))
    for n in ("icon-16", "icon-32", "icon-64", "icon-180", "icon-256", "icon-512", "banner-1000", "release-2.0-1400",
              "social-preview", "title"):
        shutil.copy(os.path.join(BRAND, n + ".png"), os.path.join(out, "assets", "img", n + ".png"))
    css_v = asset_hash(os.path.join(out, "assets", "css", "site.css"))

    search = []
    for idx, page in enumerate(order):
        doc_html, headings, plain, desc = build_doc_page(page, idx, order, sections, known, css_v)
        rel_dir = page["url"].strip("/")
        write(os.path.join(out, rel_dir, "index.html"), doc_html)
        words_seen, body_words = set(), []
        for w in re.findall(r"[A-Za-z_][A-Za-z0-9_.]{2,}", plain):
            lw = w.lower()
            if lw not in words_seen:
                words_seen.add(lw)
                body_words.append(lw)
        search.append({"t": page["title"], "u": page["url"], "s": page["section"], "d": desc,
                       "h": [{"t": t, "i": i} for (l, i, t) in headings if l in (2, 3)],
                       "x": " ".join(body_words)[:3500]})

    stdlib_pages = [p for p in order if p["rel"].startswith("stdlib/") and p["rel"] != "stdlib/index.md"]
    write(os.path.join(out, "index.html"), build_landing(sections, snips, css_v, stdlib_pages))
    write(os.path.join(out, "search-index.json"), json.dumps(search, ensure_ascii=False, separators=(",", ":")))

    css_v_page = css_v
    write(os.path.join(out, "404.html"), f"""<!doctype html>
<html lang="en"><head>
{head_html("Page not found · Nox", "That page does not exist.", BASE_URL + "/", BASE_URL + "/assets/img/social-preview.png").replace("{CSSV}", css_v_page)}
</head><body class="nf-body">
{HEADER}
<main class="nf"><img src="/assets/img/icon-256.png" width="128" height="128" alt="">
<h1>404</h1><p>This page drifted out of orbit.</p>
<p><a class="btn btn-primary" href="/">Back home</a> <a class="btn" href="/docs/">Read the docs</a></p></main>
<script src="/assets/js/app.js?v={css_v_page}" defer></script>
</body></html>
""")
    write(os.path.join(out, "robots.txt"), f"User-agent: *\nAllow: /\nSitemap: {BASE_URL}/sitemap.xml\n")
    urls = [BASE_URL + "/"] + [BASE_URL + p["url"] for p in order]
    write(os.path.join(out, "sitemap.xml"),
          '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
          + "".join(f"<url><loc>{u}</loc></url>\n" for u in urls) + "</urlset>\n")
    write(os.path.join(out, "site.webmanifest"), json.dumps({
        "name": "Nox", "short_name": "Nox", "start_url": "/", "display": "standalone",
        "background_color": "#04070D", "theme_color": "#04070D",
        "icons": [{"src": "/assets/img/icon-256.png", "sizes": "256x256", "type": "image/png"},
                  {"src": "/assets/img/icon-512.png", "sizes": "512x512", "type": "image/png"}]}, indent=2))
    for n in ("install.sh", "install.ps1"):
        shutil.copy(os.path.join(ROOT, n), os.path.join(out, n))

    # İzinleri normalleştir: kaynak dosyaların kısıtlayıcı modları (ör. 0600) çıktıya taşınırsa, root olmayan kullanıcıyla
    # çalışan konteyner onları okuyamaz (v2.0.0-rc.3 dağıtımında yakalandı).
    for dp, dns, fns in os.walk(out):
        os.chmod(dp, 0o755)
        for fn in fns:
            os.chmod(os.path.join(dp, fn), 0o644)

    # Nyx'in okuduğu manifest: url TAB dosya TAB tür TAB cache
    rows = []
    for dp, _, fns in os.walk(out):
        for fn in sorted(fns):
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, out).replace(os.sep, "/")
            if rel == "manifest.tsv":
                continue
            ext = os.path.splitext(fn)[1]
            ctype = CONTENT_TYPES.get(ext, "application/octet-stream")
            if fn == "index.html":
                d = os.path.dirname(rel)
                url = "/" + (d + "/" if d else "")
                cache = "public, max-age=300"
            else:
                url = "/" + rel
                cache = ("public, max-age=31536000, immutable" if rel.startswith("assets/fonts/") or rel.startswith("assets/img/")
                         else "public, max-age=300")
            rows.append((url, rel, ctype, cache))
    rows.sort()
    write(os.path.join(out, "manifest.tsv"), "".join("\t".join(r) + "\n" for r in rows))
    size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(out) for f in fs)
    print(f"{len(order)} doküman sayfası, {len(rows)} dosya, {size/1e6:.1f} MB -> {out}")


if __name__ == "__main__":
    main()
