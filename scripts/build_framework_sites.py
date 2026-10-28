#!/usr/bin/env python3
"""Nyx, Aether ve Aura sitelerini üretir.

Çıktı, services/frameworks-site uygulamasının okuduğu üç ağaçtır:

    <out>/nyx/     nyx.noxlang.com
    <out>/aether/  aether.noxlang.com
    <out>/aura/    aura.noxlang.com

Her ağaç noxlang.com ile aynı kabuğu kullanır (site.css, app.js, yazı tipleri).
Renk, <html data-site> üzerinden themes.css ile değişir. Üst çubukta Nox'a
dönen bir bağlantı her sayfada vardır.
"""

import html
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTENT = os.path.join(ROOT, "services", "frameworks-site", "content")
CHROME = os.path.join(ROOT, "services", "noxlang-site", "site")
NOX_HOME = "https://noxlang.com"

SITES = {
    "nyx": {
        "name": "Nyx",
        "host": "nyx.noxlang.com",
        "repo": "https://github.com/mburakmmm/nyx",
        "slug": "mburakmmm/nyx",
        "version": "",
        "install_at": "noxc install github.com/mburakmmm/nyx@",
        "kicker": "Web framework",
        "lede": "Rails-scoped web apps, written in Nox.",
        "sub": "Application lifecycle, models, sessions, jobs and mail. Typed APIs, one SQLite file by default, the same deploy path as noxlang.com.",
        "blurb": "Nyx is the full-stack web framework for Nox. It covers the Rails problem space: boot, routing, views, models, security and background work.",
        "install": "",
        "requires": "Nox ≥ 2.0.7",
        "principles": [
            ("One package", "Nyx is a Nox package, not a second compiler. Add it under requires, then import nyx.app."),
            ("Typed records", "New code builds rows with Attributes. JSON-string create and update stay for older apps."),
            ("Boot once", "Call nyx.app.boot at module scope and close handlers over the Application inside setup."),
        ],
        "areas": [
            ("Lifecycle", "nyx.app, config, runtime, ctx"),
            ("HTTP", "routes, views, forms, params"),
            ("Data", "SQLite, Postgres and MySQL models"),
            ("Security", "sessions, CSRF, auth, JWT, CSP"),
        ],
    },
    "aether": {
        "name": "Aether",
        "host": "aether.noxlang.com",
        "repo": "https://github.com/mburakmmm/aether",
        "slug": "mburakmmm/aether",
        "version": "",
        "install_at": "noxc install github.com/mburakmmm/aether@",
        "kicker": "API framework",
        "lede": "Nest-inspired HTTP APIs, written in Nox.",
        "sub": "Modules, closure injection, guards, pipes, DTO validation, OpenAPI, WebSocket gateways and a SQLite job queue. Independent of Nyx.",
        "blurb": "Aether is the API and backend framework for Nox. Use it for JSON services. Use Nyx when the app is a monolith of HTML pages.",
        "install": "",
        "requires": "Nox ≥ 2.0.7",
        "principles": [
            ("Modules", "A class with configure(self, m) owns its routes. Prefixes and imports compose the tree."),
            ("Closures, not subclasses", "Nox cannot subclass an imported base. Services live in fields and are captured by handlers."),
            ("One pipeline", "Guard, pipe, interceptor, handler, interceptor, then an exception filter. OpenAPI is built at boot."),
        ],
        "areas": [
            ("HTTP", "routes, guards, pipes, filters"),
            ("Contracts", "DTOs, OpenAPI and Swagger UI"),
            ("Realtime", "WebSocket rooms and a job queue"),
            ("Process", "worker-local state, graceful drain"),
        ],
    },
    "aura": {
        "name": "Aura",
        "host": "aura.noxlang.com",
        "repo": "https://github.com/mburakmmm/aura",
        "slug": "mburakmmm/aura",
        "version": "",
        "install_at": "",
        "kicker": "Desktop UI",
        "lede": "Declarative desktop interfaces, written in Nox.",
        "sub": "A widget tree becomes elements, then a render tree, then a scene the shell paints. The same self-check runs on macOS, Windows, X11 and Wayland.",
        "blurb": "Aura is the desktop UI framework for Nox. Version 1.0 freezes the public API: Text stays, rich text is inline, and the three desktop shells are the supported targets.",
        "install": "noxc run examples/counter/main.nox",
        "requires": "Nox 2.0",
        "principles": [
            ("Three trees", "A widget is configuration. An element owns identity and lifecycle. A RenderObject lays out, paints and hit-tests."),
            ("One UI thread", "The shell owns the window. Reading files off the UI thread is a later, explicit step, not a hidden thread."),
            ("Frozen at 1.0", "Text, TextRun and RichText stay. Web, hot reload and slivers are outside the 1.0 contract."),
        ],
        "areas": [
            ("Widgets", "StatelessWidget, State, Key, Signal"),
            ("Layout", "Row, Column, Stack, Align, virtual list"),
            ("Text", "Text, TextRun, RichText, fields"),
            ("Shells", "macOS, Win32, X11 and Wayland"),
        ],
    },
}


def github_json(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": "noxlang-frameworks",
        "Accept": "application/vnd.github+json",
    })
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return None
        raise


def latest_version(slug):
    """En güncel GitHub Release. Release yoksa (Aura) en yeni etiket."""
    latest = github_json(f"https://api.github.com/repos/{slug}/releases/latest")
    tag = ""
    if isinstance(latest, dict) and latest.get("tag_name"):
        tag = latest["tag_name"]
    if not tag:
        tags = github_json(f"https://api.github.com/repos/{slug}/tags?per_page=1")
        if isinstance(tags, list) and tags and tags[0].get("name"):
            tag = tags[0]["name"]
    if not tag:
        sys.exit(f"{slug}: GitHub release veya etiket okunamadı")
    return tag[1:] if tag.startswith("v") else tag


def load_releases():
    for key, site in SITES.items():
        site["version"] = latest_version(site["slug"])
        if site["install_at"]:
            site["install"] = site["install_at"] + "v" + site["version"]
        print(f"{key}: GitHub {site['version']}")


def stamp(site, text):
    ver = html.escape(SITES[site]["version"])
    return (text
            .replace("@@VERSION@@", f'<span data-release="{site}">{ver}</span>')
            .replace("@@TAG@@", f'<span data-release-tag="{site}">v{ver}</span>'))


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def parse_toc(site):
    pages = []
    for line in read(os.path.join(CONTENT, site, "toc.txt")).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        section, title, fn = line.split("|")
        body = read(os.path.join(CONTENT, site, fn)).replace("\r\n", "\n")
        slug = fn[:-3] if fn.endswith(".md") else fn
        url = "/docs/" if slug == "index" else f"/docs/{slug}/"
        pages.append({"section": section, "title": title, "slug": slug, "url": url, "body": body.strip() + "\n"})
    return pages


def inline(text):
    out = []
    i = 0
    while i < len(text):
        if text.startswith("**", i):
            j = text.find("**", i + 2)
            if j != -1:
                out.append("<strong>" + inline(text[i + 2:j]) + "</strong>")
                i = j + 2
                continue
        if text.startswith("`", i):
            j = text.find("`", i + 1)
            if j != -1:
                out.append("<code>" + html.escape(text[i + 1:j]) + "</code>")
                i = j + 1
                continue
        if text.startswith("[", i):
            m = re.match(r"\[([^\]]+)\]\(([^)]+)\)", text[i:])
            if m:
                href = html.escape(m.group(2), quote=True)
                out.append(f'<a href="{href}">{inline(m.group(1))}</a>')
                i += m.end()
                continue
        out.append(html.escape(text[i]))
        i += 1
    return "".join(out)


NOX_KW = {"def", "class", "import", "from", "return", "if", "elif", "else", "for", "while",
          "try", "except", "finally", "and", "or", "not", "in", "None", "True", "False", "as"}


def highlight(code, lang):
    if lang not in ("nox", "python"):
        return html.escape(code)
    parts = []
    for tok in re.split(r'(\s+|"""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\'|"[^"\n]*"|\'[^\'\n]*\'|#.*)', code):
        if not tok:
            continue
        if tok.startswith("#"):
            parts.append(f'<span class="t-c">{html.escape(tok)}</span>')
        elif tok.startswith(('"', "'")):
            parts.append(f'<span class="t-s">{html.escape(tok)}</span>')
        elif tok in NOX_KW:
            parts.append(f'<span class="t-k">{html.escape(tok)}</span>')
        else:
            parts.append(html.escape(tok))
    return "".join(parts)


def render_markdown(src):
    lines = src.split("\n")
    html_out = []
    headings = []
    plain = []
    i = 0
    counts = {}

    def slug(title):
        base = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-") or "section"
        n = counts.get(base, 0)
        counts[base] = n + 1
        return base if n == 0 else f"{base}-{n}"

    while i < len(lines):
        line = lines[i]
        if line.startswith("```"):
            lang = line[3:].strip() or "text"
            buf = []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            code = "\n".join(buf)
            plain.append(code)
            html_out.append(
                f'<div class="code"><div class="code-head"><span class="code-lang">{html.escape(lang)}</span>'
                f'<button class="code-copy" type="button">Copy</button></div>'
                f'<pre><code>{highlight(code, lang)}</code></pre></div>'
            )
            continue
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|\s*-+", lines[i + 1]):
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                i += 1
            head, body = rows[0], rows[2:]
            plain.append(" ".join(c for row in body for c in row))
            thead = "".join(f"<th>{inline(c)}</th>" for c in head)
            tbody = "".join("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>" for row in body)
            html_out.append(f'<div class="table-wrap"><table><thead><tr>{thead}</tr></thead><tbody>{tbody}</tbody></table></div>')
            continue
        if line.startswith("#"):
            level = len(line) - len(line.lstrip("#"))
            title = line[level:].strip()
            if level == 1:
                i += 1
                continue
            sid = slug(title)
            headings.append((level, sid, title))
            plain.append(title)
            html_out.append(f'<h{level} id="{sid}">{inline(title)}<a class="anchor" href="#{sid}">#</a></h{level}>')
            i += 1
            continue
        if line.strip() in ("---", "***"):
            html_out.append("<hr>")
            i += 1
            continue
        if line.startswith(">"):
            buf = []
            while i < len(lines) and lines[i].startswith(">"):
                buf.append(lines[i][1:].strip())
                i += 1
            plain.append(" ".join(buf))
            html_out.append("<blockquote><p>" + inline(" ".join(buf)) + "</p></blockquote>")
            continue
        if re.match(r"^(\s*)[-*] ", line) or re.match(r"^\s*\d+\. ", line):
            ordered = bool(re.match(r"^\s*\d+\. ", line))
            tag = "ol" if ordered else "ul"
            items = []
            while i < len(lines) and (re.match(r"^(\s*)[-*] ", lines[i]) or re.match(r"^\s*\d+\. ", lines[i])):
                item = re.sub(r"^(\s*)([-*]|\d+\.)\s+", "", lines[i])
                items.append(item)
                plain.append(item)
                i += 1
            html_out.append(f"<{tag}>" + "".join(f"<li>{inline(it)}</li>" for it in items) + f"</{tag}>")
            continue
        if not line.strip():
            i += 1
            continue
        buf = [line]
        i += 1
        while i < len(lines) and lines[i].strip() and not lines[i].startswith(("#", "```", ">", "|", "- ", "* ")) and not re.match(r"^\d+\. ", lines[i]):
            buf.append(lines[i])
            i += 1
        text = " ".join(x.strip() for x in buf)
        plain.append(text)
        html_out.append("<p>" + inline(text) + "</p>")
    return "\n".join(html_out), headings, " ".join(plain)


def frameworks_menu(current):
    items = []
    for key in ("nyx", "aether", "aura"):
        s = SITES[key]
        cur = ' aria-current="page"' if key == current else ""
        items.append(
            f'<a role="menuitem" href="https://{s["host"]}"{cur}><strong>{s["name"]}</strong><span>{html.escape(s["kicker"])}</span></a>'
        )
    return (
        '<div class="navdrop" data-navdrop>'
        '<button class="navdrop-btn" type="button" aria-expanded="false" aria-haspopup="true">Frameworks'
        '<svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true"><path d="M2.2 4.2L6 8l3.8-3.8" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>'
        '</button><div class="navdrop-panel" role="menu" hidden>' + "".join(items) + "</div></div>"
    )


def chrome(site, title, description, canonical):
    s = SITES[site]
    t = html.escape(title)
    d = html.escape(description, quote=True)
    menu = frameworks_menu(site)
    header = f"""<header class="topbar">
  <a class="brand" href="/" aria-label="{s["name"]} home"><span>{s["name"]}</span></a>
  <nav class="topnav" aria-label="Primary">
    <a class="nox-return" href="{NOX_HOME}">Nox</a>
    <a href="/docs/">Guide</a>
    <a href="/docs/install/">Install</a>
    {menu}
    <a href="{s["repo"]}" rel="noopener">GitHub</a>
  </nav>
  <div class="topright">
    <button class="search-open" type="button" aria-label="Search the docs" data-search-open><svg viewBox="0 0 20 20" width="16" height="16" aria-hidden="true"><circle cx="8.5" cy="8.5" r="5.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M13 13l4.5 4.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg><span>Search</span><kbd>/</kbd></button>
    <button class="theme-toggle" type="button" aria-label="Toggle colour theme" data-theme-toggle><svg viewBox="0 0 20 20" width="18" height="18" aria-hidden="true"><path class="i-moon" d="M16.5 12.2A7 7 0 017.8 3.5a7 7 0 108.7 8.7z" fill="currentColor"/><g class="i-sun" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="10" cy="10" r="3.6" fill="currentColor"/><path d="M10 1.5v2M10 16.5v2M1.5 10h2M16.5 10h2M4 4l1.4 1.4M14.6 14.6L16 16M16 4l-1.4 1.4M5.4 14.6L4 16"/></g></svg></button>
    <button class="menu-toggle" type="button" aria-label="Open navigation" data-menu-toggle><span></span><span></span><span></span></button>
  </div>
</header>
<div class="search-modal" id="search-modal" hidden>
  <div class="search-backdrop" data-search-close></div>
  <div class="search-panel" role="dialog" aria-modal="true" aria-label="Search">
    <input id="search-input" type="search" placeholder="Search the {s["name"]} guide…" autocomplete="off" spellcheck="false">
    <ul id="search-results" role="listbox"></ul>
    <p class="search-hint"><kbd>↑</kbd><kbd>↓</kbd> to move · <kbd>Enter</kbd> to open · <kbd>Esc</kbd> to close</p>
  </div>
</div>"""
    footer = f"""<footer class="footer">
  <div class="footer-inner">
    <div class="footer-brand">
      <a class="brand" href="/"><span>{s["name"]}</span></a>
      <p>{html.escape(s["lede"])}</p>
    </div>
    <nav class="footer-cols" aria-label="Footer">
      <div><h4>This framework</h4><a href="/docs/">Guide</a><a href="/docs/install/">Install</a><a href="{s["repo"]}" rel="noopener">Source</a></div>
      <div><h4>Frameworks</h4><a href="https://nyx.noxlang.com">Nyx</a><a href="https://aether.noxlang.com">Aether</a><a href="https://aura.noxlang.com">Aura</a></div>
      <div><h4>Nox</h4><a href="{NOX_HOME}">noxlang.com</a><a href="{NOX_HOME}/docs/">Language docs</a><a href="{NOX_HOME}/docs/install/">Install Nox</a></div>
    </nav>
  </div>
  <div class="footer-base"><span>{s["name"]} <span data-release="{site}">{html.escape(s["version"])}</span> · {html.escape(s["requires"])}</span><span>Served by a Nyx app on the Nox tunnel.</span></div>
</footer>"""
    head = f"""<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{t}</title>
<meta name="description" content="{d}">
<meta name="color-scheme" content="dark light">
<link rel="canonical" href="{html.escape(canonical, quote=True)}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<meta property="og:type" content="website">
<meta property="og:site_name" content="{s["name"]}">
<meta property="og:title" content="{t}">
<meta property="og:description" content="{d}">
<meta property="og:url" content="{html.escape(canonical, quote=True)}">
<link rel="preload" href="/assets/fonts/unbounded-latin-700-normal.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/assets/fonts/ibm-plex-sans-latin-400-normal.woff2" as="font" type="font/woff2" crossorigin>
<script src="/assets/js/theme-init.js"></script>
<link rel="stylesheet" href="/assets/css/site.css?v=4">
<link rel="stylesheet" href="/assets/css/themes.css?v=4">"""
    return head, header, footer


def sidebar(pages, current):
    sections = []
    for p in pages:
        if not sections or sections[-1][0] != p["section"]:
            sections.append((p["section"], []))
        sections[-1][1].append(p)
    out = ['<nav class="sidebar" aria-label="Documentation" id="sidebar">']
    for name, items in sections:
        open_attr = " open" if any(i["url"] == current for i in items) else ""
        out.append(f'<details class="side-sec"{open_attr}><summary>{html.escape(name)}</summary><ul>')
        for p in items:
            cur = ' aria-current="page"' if p["url"] == current else ""
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


def doc_page(site, pages, idx):
    page = pages[idx]
    body, headings, plain = render_markdown(page["body"])
    desc = plain[:170].rsplit(" ", 1)[0] + "…" if len(plain) > 170 else plain
    prev_p = pages[idx - 1] if idx else None
    next_p = pages[idx + 1] if idx + 1 < len(pages) else None
    pager = '<nav class="pager" aria-label="Previous and next page">'
    pager += (f'<a class="prev" href="{prev_p["url"]}"><small>Previous</small><span>{html.escape(prev_p["title"])}</span></a>' if prev_p else "<span></span>")
    pager += (f'<a class="next" href="{next_p["url"]}"><small>Next</small><span>{html.escape(next_p["title"])}</span></a>' if next_p else "<span></span>")
    pager += "</nav>"
    s = SITES[site]
    title = f'{page["title"]} · {s["name"]}'
    canonical = f'https://{s["host"]}{page["url"]}'
    head, header, footer = chrome(site, title, desc or page["title"], canonical)
    edit = f'{s["repo"]}'
    doc = f"""<!doctype html>
<html lang="en" data-site="{site}">
<head>
{head}
</head>
<body class="doc-body">
<a class="skip" href="#content">Skip to content</a>
{header}
<div class="doc-shell">
{sidebar(pages, page["url"])}
<main class="doc-main" id="content">
<article class="prose">
<p class="eyebrow">{html.escape(page["section"])}</p>
<h1>{html.escape(page["title"])}</h1>
{body}
<p class="edit-link"><a href="{edit}" rel="noopener">Source repository</a></p>
{pager}
</article>
</main>
{toc_html(headings)}
</div>
{footer}
<script src="/assets/js/app.js" defer></script>
</body>
</html>
"""
    doc = stamp(site, doc)
    search = {
        "t": page["title"],
        "u": page["url"],
        "s": page["section"],
        "d": desc or page["title"],
        "x": plain.replace("@@VERSION@@", SITES[site]["version"]).replace("@@TAG@@", "v" + SITES[site]["version"]).lower()[:4000],
        "h": [{"t": t, "i": i} for (l, i, t) in headings if l in (2, 3)],
    }
    return doc, search


def landing(site, pages):
    s = SITES[site]
    head, header, footer = chrome(site, f'{s["name"]} · a Nox framework', s["blurb"], f'https://{s["host"]}/')
    principles = "".join(
        f'<article class="principle"><div class="hexicon" aria-hidden="true"></div><h3>{html.escape(t)}</h3><p>{html.escape(p)}</p></article>'
        for t, p in s["principles"]
    )
    areas = "".join(f'<article class="battery"><h3>{html.escape(t)}</h3><p>{html.escape(p)}</p></article>' for t, p in s["areas"])
    links = "".join(f'<a class="chip" href="{p["url"]}">{html.escape(p["title"])}</a>' for p in pages)
    hero = read(os.path.join(CONTENT, site, "hero.nox")).rstrip("\n")
    code = highlight(hero, "nox")
    if s["install_at"]:
        install_html = (
            f'<div class="install" data-copy="{html.escape(s["install"], quote=True)}">'
            f'<span class="prompt">$</span><code>{html.escape(s["install_at"])}'
            f'<span data-release-tag="{site}">v{html.escape(s["version"])}</span></code></div>'
        )
    else:
        install_html = (
            f'<div class="install" data-copy="{html.escape(s["install"], quote=True)}">'
            f'<span class="prompt">$</span><code>{html.escape(s["install"])}</code></div>'
        )
    return stamp(site, f"""<!doctype html>
<html lang="en" data-site="{site}">
<head>
{head}
</head>
<body>
<a class="skip" href="#content">Skip to content</a>
{header}
<div class="hero-art hero-mark">
  <div class="hero-word">
    <h1>{html.escape(s["name"])}</h1>
    <p class="hero-version" data-release="{site}">{html.escape(s["version"])}</p>
  </div>
</div>
<main id="content">
<section class="wrap hero-grid">
  <div>
    <p class="kicker">{html.escape(s["kicker"])}</p>
    <p class="lede">{html.escape(s["lede"])}</p>
    <p class="lede-sub">{html.escape(s["sub"])}</p>
    <div class="hero-actions"><a class="btn btn-primary" href="/docs/">Read the guide</a><a class="btn" href="{NOX_HOME}">Nox language</a></div>
    {install_html}
    <p class="install-note">{html.escape(s["requires"])}. The language itself is documented at noxlang.com.</p>
  </div>
  <div class="hero-code"><div class="code"><div class="code-head"><span class="code-lang">nox</span><button class="code-copy" type="button">Copy</button></div><pre><code>{code}</code></pre></div></div>
</section>
<section class="section"><div class="wrap">
  <div class="section-head"><p class="kicker">Shape</p><h2>The same idea, three different jobs.</h2><p>{html.escape(s["blurb"])}</p></div>
  <div class="principles">{principles}</div>
</div></section>
<section class="section"><div class="wrap">
  <div class="section-head"><p class="kicker">Surface</p><h2>What you actually import.</h2></div>
  <div class="battery-grid">{areas}</div>
  <div class="chips">{links}</div>
</div></section>
<section class="section"><div class="wrap cta"><div class="cta-box">
  <div><h2>Built on Nox, served next to it.</h2><p>This site is a Nyx application on the same Cloudflare tunnel as noxlang.com. The language reference stays on the Nox site.</p></div>
  <div class="hero-actions"><a class="btn btn-primary" href="{NOX_HOME}">Open noxlang.com</a><a class="btn" href="/docs/install/">Install {s["name"]}</a></div>
</div></div></section>
</main>
{footer}
<script src="/assets/js/app.js" defer></script>
</body>
</html>
""")


def not_found(site):
    s = SITES[site]
    head, header, footer = chrome(site, f"Not found · {s['name']}", "That page is not on this site.", f"https://{s['host']}/404.html")
    return f"""<!doctype html>
<html lang="en" data-site="{site}">
<head>
{head}
</head>
<body class="nf-body">
{header}
<main class="nf"><h1>404</h1><p>This page is not part of the {s["name"]} guide.</p>
<p><a class="btn btn-primary" href="/">Back home</a> <a class="btn" href="{NOX_HOME}">Nox</a></p></main>
{footer}
</body></html>
"""


def favicon(site):
    colors = {"nyx": "#e23b6a", "aether": "#7c5cff", "aura": "#1f9d6a"}
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="{colors[site]}"/><text x="16" y="21" text-anchor="middle" font-family="sans-serif" font-size="16" font-weight="700" fill="#fff">{SITES[site]["name"][:1]}</text></svg>\n'


THEMES = """/* Çerçeve siteleri noxlang.com kabuğunu paylaşır; yalnızca marka renkleri değişir. */
html[data-site="nyx"] {
  --brand: #e23b6a; --brand-2: #ffb15a; --brand-ink: #ff8aa8; --on-brand: #fff;
  --glow: linear-gradient(135deg, #c81e4a 0%, #ffb15a 100%);
  --t-kw: #ff8aa8; --t-cls: #ffd08a;
}
html[data-site="nyx"][data-theme="light"] {
  --brand: #c01748; --brand-2: #b86a12; --brand-ink: #c01748;
  --glow: linear-gradient(135deg, #c01748 0%, #d8872a 100%);
  --bg: #fbf6f7; --bg-raise: #fff; --bg-sunk: #f6ebee; --line: #ead5dc; --line-soft: #f3e4e8;
  --text: #2a1020; --text-dim: #6d4054; --text-faint: #947088;
}
html[data-site="aether"] {
  --brand: #7c5cff; --brand-2: #5ce1ff; --brand-ink: #c4b5fd; --on-brand: #fff;
  --glow: linear-gradient(135deg, #6d4aff 0%, #5ce1ff 100%);
  --t-kw: #c4b5fd; --t-cls: #7ee7ff;
}
html[data-site="aether"][data-theme="light"] {
  --brand: #5b3df5; --brand-2: #0b7ea0; --brand-ink: #5b3df5;
  --glow: linear-gradient(135deg, #5b3df5 0%, #1493c4 100%);
  --bg: #f5f4fc; --bg-raise: #fff; --bg-sunk: #ece9f8; --line: #d9d4f0; --line-soft: #e7e3f6;
  --text: #16122e; --text-dim: #4c4578; --text-faint: #746ea0;
}
html[data-site="aura"] {
  --brand: #1f9d6a; --brand-2: #d6f25c; --brand-ink: #8ee0b5; --on-brand: #042117;
  --glow: linear-gradient(135deg, #128a58 0%, #d6f25c 100%);
  --t-kw: #8ee0b5; --t-cls: #e7f59a;
}
html[data-site="aura"][data-theme="light"] {
  --brand: #0e7a4e; --brand-2: #5c7a12; --brand-ink: #0e7a4e; --on-brand: #fff;
  --glow: linear-gradient(135deg, #0e7a4e 0%, #8aaa22 100%);
  --bg: #f4f8f5; --bg-raise: #fff; --bg-sunk: #e7f1ea; --line: #cfe0d4; --line-soft: #e1eee6;
  --text: #10261a; --text-dim: #3d5c4a; --text-faint: #6d8a7a;
}
@media (prefers-color-scheme: light) {
  html[data-site="nyx"]:not([data-theme="dark"]) {
    --brand: #c01748; --brand-2: #b86a12; --brand-ink: #c01748;
    --glow: linear-gradient(135deg, #c01748 0%, #d8872a 100%);
    --bg: #fbf6f7; --bg-raise: #fff; --bg-sunk: #f6ebee; --line: #ead5dc; --line-soft: #f3e4e8;
    --text: #2a1020; --text-dim: #6d4054; --text-faint: #947088;
  }
  html[data-site="aether"]:not([data-theme="dark"]) {
    --brand: #5b3df5; --brand-2: #0b7ea0; --brand-ink: #5b3df5;
    --glow: linear-gradient(135deg, #5b3df5 0%, #1493c4 100%);
    --bg: #f5f4fc; --bg-raise: #fff; --bg-sunk: #ece9f8; --line: #d9d4f0; --line-soft: #e7e3f6;
    --text: #16122e; --text-dim: #4c4578; --text-faint: #746ea0;
  }
  html[data-site="aura"]:not([data-theme="dark"]) {
    --brand: #0e7a4e; --brand-2: #5c7a12; --brand-ink: #0e7a4e; --on-brand: #fff;
    --glow: linear-gradient(135deg, #0e7a4e 0%, #8aaa22 100%);
    --bg: #f4f8f5; --bg-raise: #fff; --bg-sunk: #e7f1ea; --line: #cfe0d4; --line-soft: #e1eee6;
    --text: #10261a; --text-dim: #3d5c4a; --text-faint: #6d8a7a;
  }
}
"""


def build(out):
    load_releases()
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out)
    write(os.path.join(out, "releases.json"), json.dumps(
        {key: SITES[key]["version"] for key in SITES}, ensure_ascii=True))
    for key in SITES:
        dest = os.path.join(out, key)
        os.makedirs(os.path.join(dest, "assets", "css"))
        os.makedirs(os.path.join(dest, "assets", "js"))
        shutil.copytree(os.path.join(CHROME, "fonts"), os.path.join(dest, "assets", "fonts"))
        shutil.copy(os.path.join(CHROME, "css", "site.css"), os.path.join(dest, "assets", "css", "site.css"))
        write(os.path.join(dest, "assets", "css", "themes.css"), THEMES)
        shutil.copy(os.path.join(CHROME, "js", "app.js"), os.path.join(dest, "assets", "js", "app.js"))
        shutil.copy(os.path.join(CHROME, "js", "theme-init.js"), os.path.join(dest, "assets", "js", "theme-init.js"))
        pages = parse_toc(key)
        search = []
        for idx, page in enumerate(pages):
            doc, entry = doc_page(key, pages, idx)
            search.append(entry)
            rel = page["url"].strip("/")
            write(os.path.join(dest, rel, "index.html"), doc)
        write(os.path.join(dest, "index.html"), landing(key, pages))
        write(os.path.join(dest, "404.html"), not_found(key))
        write(os.path.join(dest, "search-index.json"), json.dumps(search, ensure_ascii=False))
        write(os.path.join(dest, "favicon.svg"), favicon(key))
        write(os.path.join(dest, "robots.txt"), f"User-agent: *\nAllow: /\nSitemap: https://{SITES[key]['host']}/sitemap.xml\n")
        locs = [f"https://{SITES[key]['host']}/"] + [f"https://{SITES[key]['host']}{p['url']}" for p in pages]
        write(os.path.join(dest, "sitemap.xml"),
              '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
              + "".join(f"<url><loc>{u}</loc></url>\n" for u in locs) + "</urlset>\n")
        for dp, dns, fns in os.walk(dest):
            os.chmod(dp, 0o755)
            for fn in fns:
                os.chmod(os.path.join(dp, fn), 0o644)
        rows = []
        for dp, _, fns in os.walk(dest):
            for fn in sorted(fns):
                full = os.path.join(dp, fn)
                rel = os.path.relpath(full, dest).replace(os.sep, "/")
                ext = os.path.splitext(fn)[1]
                ctype = {
                    ".html": "text/html; charset=utf-8",
                    ".css": "text/css; charset=utf-8",
                    ".js": "text/javascript; charset=utf-8",
                    ".json": "application/json; charset=utf-8",
                    ".svg": "image/svg+xml",
                    ".woff2": "font/woff2",
                    ".txt": "text/plain; charset=utf-8",
                    ".xml": "application/xml; charset=utf-8",
                }.get(ext, "application/octet-stream")
                if fn == "index.html":
                    d = os.path.dirname(rel)
                    url = "/" if d == "" else "/" + d + "/"
                    cache = "public, max-age=300"
                else:
                    url = "/" + rel
                    cache = "public, max-age=31536000, immutable" if rel.startswith("assets/fonts/") else "public, max-age=3600"
                rows.append((url, rel, ctype, cache))
        write(os.path.join(dest, "manifest.tsv"), "".join("\t".join(r) + "\n" for r in rows))
        os.chmod(os.path.join(dest, "manifest.tsv"), 0o644)
        print(f"{key}: {len(pages)} sayfa, {len(rows)} dosya")


def main():
    out = os.path.join(ROOT, "services", "frameworks-site", "public")
    if len(sys.argv) == 3 and sys.argv[1] == "--out":
        out = os.path.abspath(sys.argv[2])
    elif len(sys.argv) != 1:
        sys.exit("kullanım: build_framework_sites.py [--out DIZIN]")
    build(out)


if __name__ == "__main__":
    main()
