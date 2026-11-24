#!/usr/bin/env python3
"""Runtime-free "leaf" denetimi (native-runtime readiness R1; bkz. project/native-runtime-capability-audit.md).

Bir Nox kaynagini `noxc build --selfhost-obj` ile (LLVM, main'siz nesne) derler ve belirtilen KOK (leaf) fonksiyonlarin
TRANSITIF bagimlilik kapanisini uc seviyede denetler:

  1. LLVM IR: kok -> ... -> yasak sembol zinciri (dogrudan + dolayli cagri + fonksiyon adresi + global baslaticilari),
     gizli `rt` durumuna erisim (cagri DISINDA `%rt` kullanimi). Siniflar: arena, arc, exception, checked-arith-trap,
     managed-str, collection, io, runtime, libcall, platform, indirect, rt-state.
  2. Nesne: `nm` ile tanimsiz semboller (bilgi amacli; prelude her nesneye girdigi icin tek basina karar vermez).
  3. Link/calistirma: C harness'i `noxrt.o` OLMADAN `-dead_strip`/`--gc-sections` ile baglar, calistirir, ciktiyi dogrular ve
     son ikilide yasak (`nox_*`) sembol kalmadigini dogrular.

Kullanim:
  runtime_leaf_audit.py audit  SRC.nox --leaf f1,f2 [--allow sym,..] [--harness H.c --expect-out TXT]
  runtime_leaf_audit.py suite  [DIR]          # tests/native_runtime/leaf/*.nox yonergelerine gore (CI/precheck)

Fixture yonergeleri (kaynak dosyada `# anahtar: deger` satirlari):
  leaf: a,b            denetlenecek kok fonksiyonlar (olumlu fixture: HICBIR ihlal olmamali)
  forbid: f=cat1|cat2  olumsuz fixture: f kokunun ihlal siniflari BUNLARI icermeli (kapi onu reddetmeli)
  allow: sym,sym       onayli platform sembolleri
  harness: x.c         link+calistirma harness'i (olumlu fixture)
  link: a.c,b.c        harness'e eklenen C kaynaklari (tests/native_runtime/ koke gore; gecici saglayici shim'leri)
  expect-out: metin    harness stdout'u (strip edilmis) bu olmali

Salt-okunur araclar: kaynak/runtime davranisini DEGISTIRMEZ. Cikis kodu: 0 = beklenen sonuc, 1 = sapma.
"""
import fnmatch
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (regex, sinif) — SIRA onemli (ilk eslesen kazanir). Adlar LLVM IR'daki (onekli olmayan) adlardir.
CLASSES = [
    (r"^nox_arena_", "arena"),
    (r"^nox_(rc_|cycle_)|_(release|gc_free|trace)$|^nox_.*(retain|release)", "arc"),
    (r"^nox_(raise|exception_|throw)|Exception|Error|_vtable$", "exception"),
    (r"^nox_int_overflow_trap$", "checked-arith-trap"),
    (r"^nox_(str_|int_to_str|float_to_str|float_round|format_|chr_|ord_)|^__nox_format", "managed-str"),
    (r"^nox_(list_|dict_|set_|tuple_)", "collection"),
    (r"^(print|nox_print|nox_stdin|nox_write|input)", "io"),
    (r"^llvm\.(memcpy|memmove|memset)", "libcall"),
    (r"^llvm\.", "intrinsic-ok"),
    (r"^nox_", "runtime"),
]
ALLOWED_CLASSES = {"intrinsic-ok"}

DEFINE_RE = re.compile(r"^define\b[^@\n]*@([\w.$]+)\(", re.M)
DECLARE_RE = re.compile(r"^declare\b[^@\n]*@([\w.$]+)\(", re.M)
GLOBAL_RE = re.compile(r"^@([\w.$]+)\s*=\s*(.*)$", re.M)
TOKEN_RE = re.compile(r"@([\w.$]+)")
INDIRECT_RE = re.compile(r"\bcall\b[^\n(]*?\s%[\w.]+\(")


def is_allowed(sym, allow):
    return any(fnmatch.fnmatchcase(sym, a) for a in allow)


def classify(name):
    for rx, cls in CLASSES:
        if re.search(rx, name):
            return cls
    return None


class Module:
    def __init__(self, text):
        self.defs = {}
        self.decls = set(DECLARE_RE.findall(text))
        spans = [(m.group(1), m.start()) for m in DEFINE_RE.finditer(text)]
        for i, (name, start) in enumerate(spans):
            end = text.find("\n}\n", start)
            self.defs[name] = text[start:end if end != -1 else len(text)]
        self.globals = {m.group(1): m.group(2) for m in GLOBAL_RE.finditer(text)}


def audit_ir(mod, roots, allow):
    """-> {root: [(sinif, sembol, zincir)]}"""
    result = {}
    for root in roots:
        viol = []
        if root not in mod.defs:
            viol.append(("missing", root, [root]))
            result[root] = viol
            continue
        seen = {root}
        stack = [(root, [root])]
        while stack:
            cur, chain = stack.pop()
            if cur in mod.globals:
                body, is_fn = mod.globals[cur], False
            else:
                body, is_fn = mod.defs.get(cur, ""), True
            if is_fn:
                for line in body.splitlines()[1:]:
                    if "%rt" in line and not re.search(r"\bcall\b", line):
                        viol.append(("rt-state", "%rt", chain))
                        break
                if INDIRECT_RE.search(body):
                    viol.append(("indirect", "<indirect call>", chain))
            for tok in set(TOKEN_RE.findall(body)):
                if tok == cur or tok in seen:
                    continue
                seen.add(tok)
                sub = chain + [tok]
                if tok in mod.defs or tok in mod.globals:
                    cls = classify(tok) if tok in mod.defs else None
                    if cls == "runtime":  # Nox'ta tanimli (stdlib/prelude jenerik) -> govdesi ayrica denetlenir
                        cls = None
                    if cls and cls not in ALLOWED_CLASSES and not is_allowed(tok, allow):
                        viol.append((cls, tok, sub))  # prelude/stdlib tanimli ama yasak sinif: ayrica inme
                    else:
                        stack.append((tok, sub))
                elif tok in mod.decls:
                    cls = classify(tok) or "platform"
                    if cls not in ALLOWED_CLASSES and not is_allowed(tok, allow):
                        viol.append((cls, tok, sub))
        result[root] = viol
    return result


def run(argv, **kw):
    return subprocess.run(argv, capture_output=True, text=True, **kw)


def build_obj(noxc, src, outdir):
    out_o = os.path.join(outdir, "leaf.o")
    env = dict(os.environ)
    # ELF'te --gc-sections icin fonksiyon basina bolum; Mach-O'da zararsiz.
    env["NOX_CLANG_EXTRA"] = "-ffunction-sections -fdata-sections"
    p = run([noxc, "build", "--selfhost-obj", src, "-o", out_o], env=env, cwd=outdir)
    if p.returncode != 0:
        raise RuntimeError("noxc --selfhost-obj basarisiz:\n" + p.stdout + p.stderr)
    return out_o, os.path.join(outdir, "leaf.ll")


def strip_us(sym):
    return sym[1:] if sym.startswith("_") and sys.platform == "darwin" else sym


def link_and_run(obj, harness, outdir, expect_out, allow, extra=()):
    exe = os.path.join(outdir, "leaf_harness")
    gc = "-Wl,-dead_strip" if sys.platform == "darwin" else "-Wl,--gc-sections"
    cc = shutil.which("clang") or shutil.which("cc")
    argv = [cc, "-O1", "-pthread", harness, *extra, obj, gc, "-o", exe]
    assert not any("noxrt" in a for a in argv), "noxrt.o link satirina girmemeli"
    p = run(argv)
    if p.returncode != 0:
        return False, "link basarisiz (noxrt.o olmadan):\n" + p.stderr[-1200:], []
    r = run([exe])
    out = r.stdout.strip()
    if r.returncode != 0:
        return False, f"harness cikis kodu {r.returncode}: {r.stderr[-300:]}", []
    if expect_out is not None and out != expect_out.strip():
        return False, f"cikti sapmasi: beklenen {expect_out!r}, gelen {out!r}", []
    nm = run(["nm", exe]).stdout.splitlines()
    leaked = []
    for ln in nm:
        parts = ln.split()
        if not parts:
            continue
        sym = strip_us(parts[-1])
        if re.match(r"^(nox_|Exception|__nox_)", sym) and not is_allowed(sym, allow) and not is_allowed(sym.split(".")[0], allow):
            leaked.append(sym)
    if leaked:
        return False, "son ikilide runtime sembolu kaldi: " + ",".join(sorted(set(leaked))[:8]), leaked
    return True, "link+run OK (noxrt.o yok), cikti=" + repr(out), []


def audit(noxc, src, leaf, allow, harness=None, expect_out=None, extra=()):
    with tempfile.TemporaryDirectory(prefix="leafaudit_") as td:
        obj, ll = build_obj(noxc, os.path.abspath(src), td)
        mod = Module(open(ll, encoding="utf-8", errors="replace").read())
        viol = audit_ir(mod, leaf, set(allow))
        und = [ln.split()[-1] for ln in run(["nm", "-u", obj]).stdout.splitlines() if ln.strip()]
        link = None
        if harness:
            link = link_and_run(obj, os.path.abspath(harness), td, expect_out, allow, [os.path.abspath(e) for e in extra])
        return viol, und, link


def audit_safe(*a, **k):
    try:
        return audit(*a, **k)
    except RuntimeError as e:  # derleme hatasi: fixture FAIL (traceback degil)
        return None, [], (False, str(e)[-600:], [])


def parse_directives(path):
    d = {}
    for ln in open(path, encoding="utf-8"):
        m = re.match(r"#\s*(leaf|forbid|allow|harness|expect-out|link)\s*:\s*(.*)$", ln.rstrip("\n"))
        if m:
            d.setdefault(m.group(1), []).append(re.sub(r"\s*,\s*", ",", m.group(2).strip()) if m.group(1) != "expect-out" else m.group(2).strip())
    return d


def cats(v):
    return {c for c, _s, _ch in v}


def fmt_chain(ch):
    return " -> ".join(ch)


def cmd_suite(noxc, folder):
    files = sorted(f for f in os.listdir(folder) if f.endswith(".nox"))
    bad = 0
    for f in files:
        path = os.path.join(folder, f)
        d = parse_directives(path)
        allow = [s for x in d.get("allow", []) for s in x.split(",") if s]
        if "forbid" in d:
            exp = {}
            for item in d["forbid"]:
                name, _, cl = item.partition("=")
                exp[name.strip()] = set(cl.split("|"))
            viol, _und, err = audit_safe(noxc, path, list(exp), allow)
            ok = True
            if viol is None:
                print(f"FAIL {f}: {err[1]}")
                bad += 1
                continue
            for r, want in exp.items():
                got = cats(viol[r])
                if not want <= got:
                    ok = False
                    print(f"  FAIL {f}:{r}: beklenen yasak sinif {sorted(want)}, yakalanan {sorted(got)}")
            print(f"{'PASS' if ok else 'FAIL'} {f} (olumsuz: kapi reddetti: {sorted(exp)})")
            bad += 0 if ok else 1
        else:
            leaf = [s for x in d.get("leaf", []) for s in x.split(",") if s]
            harness = os.path.join(folder, d["harness"][0]) if "harness" in d else None
            exp_out = d["expect-out"][0] if "expect-out" in d else None
            extra = [os.path.join(folder, "..", e) for x in d.get("link", []) for e in x.split(",") if e]
            viol, _und, link = audit_safe(noxc, path, leaf, allow, harness, exp_out, extra)
            ok = True
            if viol is None:
                print(f"FAIL {f}: {link[1]}")
                bad += 1
                continue
            for r in leaf:
                if viol[r]:
                    ok = False
                    for c, s, ch in viol[r]:
                        print(f"  FAIL {f}:{r}: {c} `{s}` via {fmt_chain(ch)}")
            if link is not None and not link[0]:
                ok = False
                print(f"  FAIL {f}: {link[1]}")
            tail = (" | " + link[1]) if link and link[0] else ""
            print(f"{'PASS' if ok else 'FAIL'} {f} (olumlu: {','.join(leaf)}){tail}")
            bad += 0 if ok else 1
    print(f"VERDICT: {'GREEN' if bad == 0 else 'RED'} ({len(files)} fixture, {bad} sapma)")
    return 1 if bad else 0


def cmd_audit(noxc, argv):
    src = argv[0]
    opt = dict(zip(argv[1::2], argv[2::2]))
    leaf = [s for s in opt.get("--leaf", "").split(",") if s]
    allow = [s for s in opt.get("--allow", "").split(",") if s]
    viol, und, link = audit(noxc, src, leaf, allow, opt.get("--harness"), opt.get("--expect-out"))
    rc = 0
    for r in leaf:
        if viol[r]:
            rc = 1
            print(f"{r}: ihlal")
            for c, s, ch in viol[r]:
                print(f"  {c:<20} {s}   [{fmt_chain(ch)}]")
        else:
            print(f"{r}: temiz (yasak bagimlilik yok)")
    if link is not None:
        print(("link: " if link[0] else "link FAIL: ") + link[1])
        rc = rc or (0 if link[0] else 1)
    print(f"(nesnede {len(und)} tanimsiz sembol; prelude dahil, kapanis disi sayilir)")
    return rc


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("audit", "suite"):
        print(__doc__)
        return 2
    noxc = os.environ.get("NOXC", os.path.join(ROOT, "zig-out", "bin", "noxc"))
    if not os.path.exists(noxc):
        print(f"noxc yok: {noxc} (once `zig build`)", file=sys.stderr)
        return 2
    if sys.argv[1] == "suite":
        folder = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "tests", "native_runtime", "leaf")
        return cmd_suite(noxc, folder)
    return cmd_audit(noxc, sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
