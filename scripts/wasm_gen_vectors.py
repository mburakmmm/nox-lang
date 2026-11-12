#!/usr/bin/env python3
"""WASM yorumlayıcısı için farksal test vektörlerini üretir: her sayısal komut için bir işlev içeren bir modül (`ops.wat` -> `ops.wasm`) kurar, Node'un
yerleşik `WebAssembly` motoruyla (V8) uç değerler üzerinde çalıştırır ve beklenen sonuçları `tests/compat/wasm_ops/vectors.txt` olarak yazar.
`tests/compat/wasm_ops_test.zig` aynı vektörleri Nox yorumlayıcısında yeniden oynatır (Node/wasm-as CI'de gerekmez).

Kullanım:  scripts/wasm_gen_vectors.py          # dosyaları yeniden yazar
           scripts/wasm_gen_vectors.py --check  # üretilenin depodakiyle aynı olduğunu doğrular (Node + binaryen `wasm-as` gerekir)
Gereksinimler: `node`, binaryen `wasm-as`.

Satır biçimi: `<komut> <hex arg>... = <hex sonuç | nan | trap>`  (i32 değerleri 32 bit, i64/f64 64 bit, f32 32 bit ham desen; NaN için yalnızca `nan` karşılaştırılır).
"""
import os, subprocess, sys, tempfile, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/compat/wasm_ops")

I32 = [0, 1, 2, 7, 0xFFFFFFFF, 0xFFFFFFF9, 0x7FFFFFFF, 0x80000000, 0x80000001, 0x12345678, 0x1F, 0x20, 0x21, 0xFF, 0xFFFF, 0xFFFF8000]
I64 = [0, 1, 2, 7, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFF9, 0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0x8000000000000001, 0x123456789ABCDEF0, 0x3F, 0x40, 0x41, 0xFFFFFFFF, 0x80000000, 0xFFFFFFFF80000000]
F32 = [0x00000000, 0x80000000, 0x3F800000, 0xBF800000, 0x3F000000, 0xBF000000, 0x3FC00000, 0x40200000, 0xC0200000, 0x40600000, 0x4F000000, 0xCF000000,
       0x4F800000, 0x5F000000, 0xDF000000, 0x5F800000, 0x7F800000, 0xFF800000, 0x7FC00000, 0x7F7FFFFF, 0x00000001, 0x4EFFFFFF, 0xCF000001, 0x4B000000,
       0x4B000001, 0x3DCCCCCD, 0xBF7FFFFF, 0x3F7FFFFF]
F64 = [0x0000000000000000, 0x8000000000000000, 0x3FF0000000000000, 0xBFF0000000000000, 0x3FE0000000000000, 0xBFE0000000000000, 0x3FF8000000000000,
       0x4004000000000000, 0xC004000000000000, 0x400C000000000000, 0x41E0000000000000, 0xC1E0000000000000, 0x43E0000000000000, 0xC3E0000000000000,
       0x43F0000000000000, 0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000000, 0x7FEFFFFFFFFFFFFF, 0x0000000000000001, 0x41DFFFFFFFC00000,
       0xC1E0000000200000, 0x41EFFFFFFFE00000, 0x4340000000000000, 0x4340000000000001, 0x3FB999999999999A, 0xBFEFFFFFFFFFFFFF, 0x3FEFFFFFFFFFFFFF,
       0xC1E00000001FFFFF, 0x43DFFFFFFFFFFFFF, 0xC3E0000000000001]
VALS = {"i32": I32, "i64": I64, "f32": F32, "f64": F64}
HEX = {"i32": 8, "i64": 16, "f32": 8, "f64": 16}

ops = []  # (mnemonic, [param types], result type)

def add(name, params, res):
    ops.append((name, params, res))

for t in ("i32", "i64"):
    add(f"{t}.eqz", [t], "i32")
    for c in ("eq", "ne", "lt_s", "lt_u", "gt_s", "gt_u", "le_s", "le_u", "ge_s", "ge_u"):
        add(f"{t}.{c}", [t, t], "i32")
    for u in ("clz", "ctz", "popcnt"):
        add(f"{t}.{u}", [t], t)
    for b in ("add", "sub", "mul", "div_s", "div_u", "rem_s", "rem_u", "and", "or", "xor", "shl", "shr_s", "shr_u", "rotl", "rotr"):
        add(f"{t}.{b}", [t, t], t)
for t in ("f32", "f64"):
    for c in ("eq", "ne", "lt", "gt", "le", "ge"):
        add(f"{t}.{c}", [t, t], "i32")
    for u in ("abs", "neg", "ceil", "floor", "trunc", "nearest", "sqrt"):
        add(f"{t}.{u}", [t], t)
    for b in ("add", "sub", "mul", "div", "min", "max", "copysign"):
        add(f"{t}.{b}", [t, t], t)
conv = [
    ("i32.wrap_i64", "i64", "i32"), ("i32.trunc_f32_s", "f32", "i32"), ("i32.trunc_f32_u", "f32", "i32"), ("i32.trunc_f64_s", "f64", "i32"),
    ("i32.trunc_f64_u", "f64", "i32"), ("i64.extend_i32_s", "i32", "i64"), ("i64.extend_i32_u", "i32", "i64"), ("i64.trunc_f32_s", "f32", "i64"),
    ("i64.trunc_f32_u", "f32", "i64"), ("i64.trunc_f64_s", "f64", "i64"), ("i64.trunc_f64_u", "f64", "i64"), ("f32.convert_i32_s", "i32", "f32"),
    ("f32.convert_i32_u", "i32", "f32"), ("f32.convert_i64_s", "i64", "f32"), ("f32.convert_i64_u", "i64", "f32"), ("f32.demote_f64", "f64", "f32"),
    ("f64.convert_i32_s", "i32", "f64"), ("f64.convert_i32_u", "i32", "f64"), ("f64.convert_i64_s", "i64", "f64"), ("f64.convert_i64_u", "i64", "f64"),
    ("f64.promote_f32", "f32", "f64"), ("i32.reinterpret_f32", "f32", "i32"), ("i64.reinterpret_f64", "f64", "i64"), ("f32.reinterpret_i32", "i32", "f32"),
    ("f64.reinterpret_i64", "i64", "f64"),
    ("i32.extend8_s", "i32", "i32"), ("i32.extend16_s", "i32", "i32"), ("i64.extend8_s", "i64", "i64"), ("i64.extend16_s", "i64", "i64"),
    ("i64.extend32_s", "i64", "i64"),
    ("i32.trunc_sat_f32_s", "f32", "i32"), ("i32.trunc_sat_f32_u", "f32", "i32"), ("i32.trunc_sat_f64_s", "f64", "i32"), ("i32.trunc_sat_f64_u", "f64", "i32"),
    ("i64.trunc_sat_f32_s", "f32", "i64"), ("i64.trunc_sat_f32_u", "f32", "i64"), ("i64.trunc_sat_f64_s", "f64", "i64"), ("i64.trunc_sat_f64_u", "f64", "i64"),
]
for n, i, o in conv:
    add(n, [i], o)


def wat():
    lines = ["(module"]
    for name, params, res in ops:
        ps = " ".join(f"(param {p})" for p in params)
        body = " ".join(f"local.get {i}" for i in range(len(params)))
        lines.append(f'  (func (export "{name}") {ps} (result {res}) {body} {name})')
    lines.append(")")
    return "\n".join(lines) + "\n"


def cases():
    out = []
    for name, params, res in ops:
        if len(params) == 1:
            for a in VALS[params[0]]:
                out.append((name, params, res, [a]))
        else:
            for a in VALS[params[0]]:
                for b in VALS[params[1]]:
                    out.append((name, params, res, [a, b]))
    return out


JS = r"""
const fs = require('fs');
const [wasmPath, casesPath] = process.argv.slice(2);
const mod = new WebAssembly.Module(fs.readFileSync(wasmPath));
const inst = new WebAssembly.Instance(mod, {});
const cases = JSON.parse(fs.readFileSync(casesPath, 'utf8'));
const f32 = new Float32Array(1), u32 = new Uint32Array(f32.buffer);
const f64 = new Float64Array(1), u64 = new BigUint64Array(f64.buffer);
function toVal(t, hex) {
  const b = BigInt('0x' + hex);
  if (t === 'i32') return Number(BigInt.asIntN(32, b));
  if (t === 'i64') return BigInt.asIntN(64, b);
  if (t === 'f32') { u32[0] = Number(b); return f32[0]; }
  u64[0] = b; return f64[0];
}
function fromVal(t, v) {
  if (t === 'i32') return (v >>> 0).toString(16).padStart(8, '0');
  if (t === 'i64') return BigInt.asUintN(64, v).toString(16).padStart(16, '0');
  if (Number.isNaN(v)) return 'nan';
  if (t === 'f32') { f32[0] = v; return u32[0].toString(16).padStart(8, '0'); }
  f64[0] = v; return u64[0].toString(16).padStart(16, '0');
}
const out = [];
for (const [name, params, res, args] of cases) {
  let r;
  try { r = fromVal(res, inst.exports[name](...args.map((h, i) => toVal(params[i], h)))); }
  catch (e) { if (e instanceof WebAssembly.RuntimeError) r = 'trap'; else throw e; }
  out.push(name + ' ' + args.join(' ') + ' = ' + r);
}
process.stdout.write(out.join('\n') + '\n');
"""


def generate(check=False):
    with tempfile.TemporaryDirectory() as d:
        watp = os.path.join(d, "ops.wat")
        wasmp = os.path.join(d, "ops.wasm")
        open(watp, "w").write(wat())
        if check:
            # --check: depodaki ops.wasm'ı kullan (eski binaryen sürümleri bu WAT'ı ayrıştıramayabilir); yalnızca Node gerekir.
            open(wasmp, "wb").write(open(os.path.join(OUT, "ops.wasm"), "rb").read())
        else:
            subprocess.check_call(["wasm-as", "--enable-sign-ext", "--enable-nontrapping-float-to-int", "--enable-bulk-memory", "--enable-reference-types", "--enable-multivalue", "--enable-mutable-globals", watp, "-o", wasmp])
        cs = cases()
        jc = [[n, p, r, [format(a, "0%dx" % HEX[p[i]]) for i, a in enumerate(args)]] for n, p, r, args in cs]
        cj = os.path.join(d, "cases.json")
        json.dump(jc, open(cj, "w"))
        jsp = os.path.join(d, "run.js")
        open(jsp, "w").write(JS)
        txt = subprocess.check_output(["node", jsp, wasmp, cj], text=True)
        return wat(), open(wasmp, "rb").read(), txt


def main():
    w, wasm, txt = generate("--check" in sys.argv)
    if "--check" in sys.argv:
        bad = []
        # ops.wasm baytları binaryen sürümüne göre değişebilir; anlamsal olarak önemli olan beklenen sonuçlardır.
        for n, data, mode in (("vectors.txt", txt, "r"),):
            cur = open(os.path.join(OUT, n), mode).read()
            if cur != data:
                bad.append(n)
        if bad:
            sys.exit("bayat: " + ", ".join(bad) + " (scripts/wasm_gen_vectors.py ile yeniden üretin)")
        print("wasm_gen_vectors: temiz")
        return
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "ops.wat"), "w").write(w)
    open(os.path.join(OUT, "ops.wasm"), "wb").write(wasm)
    open(os.path.join(OUT, "vectors.txt"), "w").write(txt)
    print(f"{len(txt.splitlines())} vektör yazıldı ({len(ops)} komut)")


main()
