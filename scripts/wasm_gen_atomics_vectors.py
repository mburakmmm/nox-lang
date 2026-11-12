#!/usr/bin/env python3
"""WASM threads (atomik komutlar + paylaşımlı bellek) için farksal test vektörleri (v2.1.99, TODO 4.6).

Her atomik komut için bir işlev içeren modül (`atomics.wat` -> `atomics.wasm`, paylaşımlı bellek) kurar, Node'un `WebAssembly` motoruyla (V8) uç değerler ve
hizalı/hizasız/sınır dışı adresler üzerinde çalıştırır, beklenen sonuçları `tests/compat/wasm_atomics/vectors.txt` olarak yazar.
`tests/compat/wasm_atomics_test.zig` aynı vektörleri Nox yorumlayıcısında yeniden oynatır (Node/wasm-as CI'de gerekmez).

Her işlev önce 0 adresine sabit bir 64-bit desen yazar, atomik komutu çalıştırır, (varsa) sonucu i64'e genişletip VE 0 adresindeki 64 biti geri okuyup döndürür.

Kullanım:  scripts/wasm_gen_atomics_vectors.py          # dosyaları yeniden yazar (Node + binaryen `wasm-as` gerekir)
           scripts/wasm_gen_atomics_vectors.py --check  # üretilenin depodakiyle aynı olduğunu doğrular (yalnızca Node gerekir)
Satır biçimi: `<işlev> <hex arg>... = <hex sonuç>... | trap` (i32 8, i64 16 hane).
"""
import os, subprocess, sys, tempfile, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/compat/wasm_atomics")
PATTERN = 0xF0E1D2C3B4A59687
ADDRS = [0, 1, 2, 3, 4, 6, 8, 65528, 65532, 65536]
V32 = [0, 1, 0x7F, 0xFF, 0xFFFF, 0x80000000, 0xFFFFFFFF, 0xB4A59687, 0x87, 0x9687, 0xA5]
V64 = [0, 1, 0xFF, 0xFFFFFFFF, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF, PATTERN, 0xB4A59687, 0x87, 0x9687]

NAMES = ["i32", "i64", "i32_8u", "i32_16u", "i64_8u", "i64_16u", "i64_32u"]
TYPES = ["i32", "i64", "i32", "i32", "i64", "i64", "i64"]
WIDTH = [4, 8, 1, 2, 1, 2, 4]


def load_name(i):
    t = TYPES[i]; w = WIDTH[i]
    return f"{t}.atomic.load" if w == (4 if t == "i32" else 8) else f"{t}.atomic.load{w * 8}_u"


def store_name(i):
    t = TYPES[i]; w = WIDTH[i]
    return f"{t}.atomic.store" if w == (4 if t == "i32" else 8) else f"{t}.atomic.store{w * 8}"


def rmw_name(i, op):
    t = TYPES[i]; w = WIDTH[i]
    return f"{t}.atomic.rmw.{op}" if w == (4 if t == "i32" else 8) else f"{t}.atomic.rmw{w * 8}.{op}_u"


def cmpxchg_name(i):
    t = TYPES[i]; w = WIDTH[i]
    return f"{t}.atomic.rmw.cmpxchg" if w == (4 if t == "i32" else 8) else f"{t}.atomic.rmw{w * 8}.cmpxchg_u"


funcs = []
PRE = f"i32.const 0 i64.const {PATTERN} i64.store"
POST = "i32.const 0 i64.load"
EXT = {"i32": "i64.extend_i32_u", "i64": ""}


def add(name, params, body, cases, has_result=True, res_ty=None):
    funcs.append(dict(name=name, params=params, body=body, cases=cases, res=res_ty if has_result else None))


for i in range(7):
    t = TYPES[i]
    ln, sn = load_name(i), store_name(i)
    add(ln, ["i32"], f"{PRE} local.get 0 {ln} {EXT[t]} {POST}", [[a] for a in ADDRS], res_ty=t)
    vals = V32 if t == "i32" else V64
    add(sn, ["i32", t], f"{PRE} local.get 0 local.get 1 {sn} {POST}", [[a, v] for a in ADDRS for v in vals[:8]], has_result=False)
    for op in ("add", "sub", "and", "or", "xor", "xchg"):
        rn = rmw_name(i, op)
        add(rn, ["i32", t], f"{PRE} local.get 0 local.get 1 {rn} {EXT[t]} {POST}", [[a, v] for a in ADDRS for v in vals[:9]], res_ty=t)
    cn = cmpxchg_name(i)
    add(cn, ["i32", t, t], f"{PRE} local.get 0 local.get 1 local.get 2 {cn} {EXT[t]} {POST}", [[a, e, r] for a in ADDRS[:8] for e in vals[5:] for r in vals[:2]], res_ty=t)

add("memory.atomic.notify", ["i32", "i32"], f"{PRE} local.get 0 local.get 1 memory.atomic.notify i64.extend_i32_u {POST}", [[a, c] for a in ADDRS for c in (0, 1, 0xFFFFFFFF)], res_ty="i32")
add("memory.atomic.wait32", ["i32", "i32", "i64"], f"{PRE} local.get 0 local.get 1 local.get 2 memory.atomic.wait32 i64.extend_i32_u {POST}",
    [[a, e, 0] for a in ADDRS for e in (0xB4A59687, 0, 1)], res_ty="i32")
add("memory.atomic.wait64", ["i32", "i64", "i64"], f"{PRE} local.get 0 local.get 1 local.get 2 memory.atomic.wait64 i64.extend_i32_u {POST}",
    [[a, e, 0] for a in ADDRS for e in (PATTERN, 0, 1)], res_ty="i32")
add("atomic.fence", [], f"{PRE} atomic.fence {POST}", [[]], has_result=False)


def wat():
    lines = ["(module", '  (memory (export "mem") 1 1 shared)']
    for f in funcs:
        ps = "".join(f" (param {p})" for p in f["params"])
        rs = "i64 i64" if f["res"] is not None else "i64"
        # sonuç i32 ise EXT ile i64'e genişletilmiştir; işlev her zaman i64 döndürür
        lines.append(f'  (func (export "{f["name"]}"){ps} (result {rs}) {f["body"]})')
    lines.append(")")
    return "\n".join(lines) + "\n"


WIDTHH = {"i32": 8, "i64": 16}

JS = r"""
const fs = require('fs');
const [wasmPath, casesPath] = process.argv.slice(2);
const mod = new WebAssembly.Module(fs.readFileSync(wasmPath));
const inst = new WebAssembly.Instance(mod, {});
const cases = JSON.parse(fs.readFileSync(casesPath, 'utf8'));
const out = [];
for (const [name, params, results, args] of cases) {
  const a = args.map((h, i) => params[i] === 'i32' ? Number(BigInt.asIntN(32, BigInt('0x' + h))) : BigInt.asIntN(64, BigInt('0x' + h)));
  let r;
  try {
    let v = inst.exports[name](...a);
    if (!Array.isArray(v)) v = [v];
    r = v.map((x) => BigInt.asUintN(64, x).toString(16).padStart(16, '0')).join(' ');
  } catch (e) { if (e instanceof WebAssembly.RuntimeError) r = 'trap'; else throw e; }
  out.push(name + (args.length ? ' ' + args.join(' ') : '') + ' = ' + r);
}
process.stdout.write(out.join('\n') + '\n');
"""


def generate(check=False):
    with tempfile.TemporaryDirectory() as d:
        watp = os.path.join(d, "atomics.wat")
        wasmp = os.path.join(d, "atomics.wasm")
        open(watp, "w").write(wat())
        if check:
            open(wasmp, "wb").write(open(os.path.join(OUT, "atomics.wasm"), "rb").read())
        else:
            subprocess.check_call(["wasm-as", "--enable-threads", "--enable-bulk-memory", "--enable-multivalue", "--enable-sign-ext", watp, "-o", wasmp])
        jc = []
        for f in funcs:
            results = ["i64", "i64"] if f["res"] is not None else ["i64"]
            for args in f["cases"]:
                jc.append([f["name"], f["params"], results, [format(a, "0%dx" % WIDTHH[f["params"][i]]) for i, a in enumerate(args)]])
        cj = os.path.join(d, "cases.json")
        json.dump(jc, open(cj, "w"))
        jsp = os.path.join(d, "run.js")
        open(jsp, "w").write(JS)
        txt = subprocess.check_output(["node", jsp, wasmp, cj], text=True)
        return wat(), open(wasmp, "rb").read(), txt


def main():
    w, wasm, txt = generate("--check" in sys.argv)
    if "--check" in sys.argv:
        if open(os.path.join(OUT, "vectors.txt")).read() != txt:
            sys.exit("bayat: vectors.txt (scripts/wasm_gen_atomics_vectors.py ile yeniden üretin)")
        print("wasm_gen_atomics_vectors: temiz")
        return
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "atomics.wat"), "w").write(w)
    open(os.path.join(OUT, "atomics.wasm"), "wb").write(wasm)
    open(os.path.join(OUT, "vectors.txt"), "w").write(txt)
    print(f"{len(txt.splitlines())} vektör yazıldı ({len(funcs)} işlev)")


main()
