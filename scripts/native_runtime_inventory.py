#!/usr/bin/env python3
"""Native-runtime readiness R0 envanteri (project/native-runtime-readiness-gorev-belgesi-2026-11.md).

Zig runtime kaynaklarini (runtime/**/*.zig + shared/*.zig) tarar; dosya basina:
  loc, export fn, @export, atomik (@atomic*, std.atomic), threadlocal, extern/@cImport,
  std.mem.Allocator / std.heap, std.Thread / std.posix / std.os / std.net, std.Io, comptime.
Cikti: Markdown tablosu (stdout) ya da --json. Salt-okunur; kaynak degistirmez.

  python3 scripts/native_runtime_inventory.py [--json] [--root DIR]
  python3 scripts/native_runtime_inventory.py --dag [--root DIR]   # @import bagimlilik grafi: SCC'ler + katmanlar (gecis DAG'i)
"""
import json
import os
import re
import sys

PATTERNS = {
    "export_fn": re.compile(r"\bexport\s+fn\b|\bpub\s+export\s+fn\b"),
    "at_export": re.compile(r"@export\("),
    "atomic": re.compile(r"@atomic(?:Load|Store|Rmw)|std\.atomic\.|\.cmpxchg(?:Strong|Weak)\b|\.fetch(?:Add|Sub|And|Or|Xor)\b"),
    "threadlocal": re.compile(r"\bthreadlocal\b"),
    "extern_c": re.compile(r"\bextern\s+(?:\"c\"\s+)?fn\b|@cImport|\bextern\s+\"c\"|\bextern\s+\"kernel32\""),
    "alloc": re.compile(r"std\.mem\.Allocator|std\.heap\.|DebugAllocator|page_allocator|smp_allocator"),
    "os": re.compile(r"std\.Thread\b|std\.posix\.|std\.os\.|std\.net\.|std\.c\.|std\.Io\b"),
    "comptime": re.compile(r"\bcomptime\b|@Type\(|@typeInfo\("),
    "asm": re.compile(r"\basm\s+volatile|\basm\s*\(|global_asm|\.S\b"),
}


def scan(root: str):
    rows = []
    for base in ("runtime", "shared"):
        for dp, _dn, fns in os.walk(os.path.join(root, base)):
            if "/vendor" in dp or "/.zig-cache" in dp:
                continue
            for fn in sorted(fns):
                if not (fn.endswith(".zig") or fn.endswith(".S")):
                    continue
                p = os.path.join(dp, fn)
                try:
                    txt = open(p, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                row = {"file": os.path.relpath(p, root), "loc": txt.count("\n") + 1}
                for k, rx in PATTERNS.items():
                    row[k] = len(rx.findall(txt))
                rows.append(row)
    return rows


IMPORT_RE = re.compile(r'@import\("([^"]+\.zig)"\)')


def import_graph(root):
    """runtime/** ve shared/** icindeki .zig dosyalari arasi @import kenarlari (goreli yollar cozulur; vendor haric)."""
    files = {}
    for base in ("runtime", "shared"):
        for dp, dn, fns in os.walk(os.path.join(root, base)):
            dn[:] = [d for d in dn if d not in ("vendor", ".zig-cache")]
            for fn in fns:
                if fn.endswith(".zig"):
                    files[os.path.relpath(os.path.join(dp, fn), root)] = os.path.join(dp, fn)
    g = {f: set() for f in files}
    for f, p in files.items():
        txt = open(p, encoding="utf-8", errors="replace").read()
        for imp in IMPORT_RE.findall(txt):
            tgt = os.path.relpath(os.path.normpath(os.path.join(os.path.dirname(p), imp)), root)
            if tgt in g and tgt != f:
                g[f].add(tgt)
    return g


def sccs(g):
    idx, low, on, st, out, c = {}, {}, set(), [], [], [0]

    def go(v):
        idx[v] = low[v] = c[0]; c[0] += 1; st.append(v); on.add(v)
        for w in g[v]:
            if w not in idx:
                go(w); low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], idx[w])
        if low[v] == idx[v]:
            comp = []
            while True:
                w = st.pop(); on.discard(w); comp.append(w)
                if w == v:
                    break
            out.append(sorted(comp))
    import sys as _s
    _s.setrecursionlimit(10000)
    for v in sorted(g):
        if v not in idx:
            go(v)
    return out


def cmd_dag(root):
    g = import_graph(root)
    comps = sccs(g)
    which = {f: i for i, comp in enumerate(comps) for f in comp}
    cg = {i: set() for i in range(len(comps))}
    for f, outs in g.items():
        for t in outs:
            if which[f] != which[t]:
                cg[which[f]].add(which[t])
    depth = {}

    def d(i):
        if i not in depth:
            depth[i] = 0 if not cg[i] else 1 + max(d(j) for j in cg[i])
        return depth[i]
    for i in cg:
        d(i)
    big = [c for c in comps if len(c) > 1]
    print(f"dosya={len(g)} kenar={sum(len(v) for v in g.values())} SCC={len(comps)} (dongulu bilesen: {len(big)})")
    for c in sorted(big, key=len, reverse=True):
        print(f"DONGU({len(c)}): " + ", ".join(c))
    layers = {}
    for i, comp in enumerate(comps):
        layers.setdefault(depth[i], []).extend(comp)
    for k in sorted(layers):
        fs = sorted(layers[k])
        print(f"L{k} ({len(fs)} dosya): " + ", ".join(os.path.basename(f) for f in fs[:14]) + (" ..." if len(fs) > 14 else ""))
    return 0


def main(argv):
    root = "."
    as_json = "--json" in argv
    if "--root" in argv:
        root = argv[argv.index("--root") + 1]
    if "--dag" in argv:
        return cmd_dag(root)
    rows = scan(root)
    if as_json:
        json.dump(rows, sys.stdout, indent=1)
        return 0
    keys = list(PATTERNS)
    print("| dosya | loc | " + " | ".join(keys) + " |")
    print("|---|---:|" + "---:|" * len(keys))
    tot = {k: 0 for k in keys}
    tl = 0
    for r in sorted(rows, key=lambda r: r["file"]):
        tl += r["loc"]
        for k in keys:
            tot[k] += r[k]
        print(f"| {r['file']} | {r['loc']} | " + " | ".join(str(r[k]) for k in keys) + " |")
    print(f"| **TOPLAM ({len(rows)} dosya)** | {tl} | " + " | ".join(str(tot[k]) for k in keys) + " |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
