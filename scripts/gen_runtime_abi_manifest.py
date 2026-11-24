#!/usr/bin/env python3
"""Native-runtime readiness: runtime sembol + layout MANIFESTI (makine-okunur; E.3 "ABI tek doğruluk kaynağı" ön koşulu).

  runtime/**/*.zig   `export fn` imzalari  -> project/native-runtime-symbols.tsv
  shared/abi_layout.zig  `pub const` degerleri -> project/native-runtime-layout.tsv

Kaynak DOGRULUK KAYNAGI Zig dosyalaridir; manifest URETILMIS bir izdustur (elle duzenlenmez). `--check` committeki manifestin
kaynakla ayni oldugunu dogrular (precheck/CI'da surukleme tespiti). Imza cikarimi sezgiseldir (regex): ic ice parantezli
fonksiyon-isaretci parametreleri `params` sutununda kaba kalabilir; `rt_first` (ilk parametre `rt`) ve sembol listesi guvenilirdir.

  python3 scripts/gen_runtime_abi_manifest.py [--write|--check|--summary]
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SYM_OUT = os.path.join(ROOT, "project", "native-runtime-symbols.tsv")
LAY_OUT = os.path.join(ROOT, "project", "native-runtime-layout.tsv")

EXPORT_RE = re.compile(r"(?:pub\s+)?export\s+fn\s+(\w+)\s*\((.*?)\)\s*([^{;]*?)\s*\{", re.S)
CONST_RE = re.compile(r"^pub\s+const\s+(\w+)\s*(?::\s*([\w\[\]\*\.]+))?\s*=\s*(.+?);\s*(?://.*)?$", re.M)


def collapse(s):
    return re.sub(r"\s+", " ", s.strip())


def scan_symbols():
    rows = []
    for dp, dn, fns in os.walk(os.path.join(ROOT, "runtime")):
        dn[:] = sorted(d for d in dn if d not in ("vendor", ".zig-cache"))
        for fn in sorted(fns):
            if not fn.endswith(".zig"):
                continue
            path = os.path.join(dp, fn)
            txt = open(path, encoding="utf-8", errors="replace").read()
            for m in EXPORT_RE.finditer(txt):
                line = txt.count("\n", 0, m.start()) + 1
                params = collapse(m.group(2))
                first = params.split(":")[0].strip() if params else ""
                nparams = 0 if not params else params.count(":")
                rows.append((m.group(1), os.path.relpath(path, ROOT), line, "1" if first == "rt" else "0", nparams, collapse(m.group(3)), params))
    rows.sort(key=lambda r: (r[0], r[1], r[2]))
    return rows


def scan_layout():
    txt = open(os.path.join(ROOT, "shared", "abi_layout.zig"), encoding="utf-8").read()
    env, rows = {}, []
    for m in CONST_RE.finditer(txt):
        name, ty, expr = m.group(1), m.group(2) or "", m.group(3).strip()
        line = txt.count("\n", 0, m.start()) + 1
        py = re.sub(r"@as\([^,]+,\s*", "(", expr)
        py = py.replace("@intCast", "int").replace("@intFromBool", "int")
        val = "?"
        try:
            v = eval(py, {"__builtins__": {}, "int": int}, dict(env))
            if isinstance(v, int):
                env[name] = v
                val = str(v)
        except Exception:
            pass
        rows.append((name, ty, val, expr, line))
    return rows


def tsv(header, rows):
    return "\n".join(["\t".join(header)] + ["\t".join(str(c) for c in r) for r in rows]) + "\n"


def render():
    sym = tsv(("symbol", "file", "line", "rt_first", "nparams", "ret", "params"), scan_symbols())
    lay = tsv(("name", "type", "value", "expr", "line"), scan_layout())
    return sym, lay


def main(argv):
    sym, lay = render()
    mode = argv[0] if argv else "--summary"
    if mode == "--write":
        open(SYM_OUT, "w", encoding="utf-8").write(sym)
        open(LAY_OUT, "w", encoding="utf-8").write(lay)
        print(f"yazildi: {os.path.relpath(SYM_OUT, ROOT)} ({sym.count(chr(10)) - 1} sembol), {os.path.relpath(LAY_OUT, ROOT)} ({lay.count(chr(10)) - 1} sabit)")
        return 0
    if mode == "--check":
        ok = True
        for path, cur in ((SYM_OUT, sym), (LAY_OUT, lay)):
            old = open(path, encoding="utf-8").read() if os.path.exists(path) else None
            if old != cur:
                ok = False
                print(f"SURUKLEME: {os.path.relpath(path, ROOT)} guncel degil -> python3 scripts/gen_runtime_abi_manifest.py --write")
        print("runtime ABI manifesti guncel" if ok else "runtime ABI manifesti ESKI")
        return 0 if ok else 1
    rows = scan_symbols()
    rt_first = sum(1 for r in rows if r[3] == "1")
    uniq = {r[0] for r in rows}
    print(f"export fn: {len(rows)} (benzersiz sembol {len(uniq)}), ilk parametre `rt`: {rt_first}, rt'siz: {len(rows) - rt_first}")
    by_dir = {}
    for r in rows:
        d = os.path.dirname(r[1])
        by_dir.setdefault(d, [0, 0])
        by_dir[d][0] += 1
        by_dir[d][1] += int(r[3])
    for d in sorted(by_dir):
        print(f"  {d:<28} export={by_dir[d][0]:>4}  rt-first={by_dir[d][1]:>4}")
    print(f"layout sabitleri: {len(scan_layout())}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
