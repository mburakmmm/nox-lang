#!/usr/bin/env python3
"""WASM SIMD (v128) yorumlayıcısı için farksal test vektörleri (v2.1.98, TODO 4.6).

Her SIMD komutu için bir işlev içeren modül (`simd.wat` -> `simd.wasm`) kurar, Node'un `WebAssembly` motoruyla (V8) uç değerler üzerinde çalıştırır ve
beklenen sonuçları `tests/compat/wasm_simd/vectors.txt` olarak yazar. `tests/compat/wasm_simd_test.zig` aynı vektörleri Nox yorumlayıcısında yeniden
oynatır (Node/wasm-as CI'de gerekmez).

v128 değerleri host sınırından geçemediği için her işlev v128 operandlarını `i64 lo, i64 hi` çiftlerinden kurar ve sonucu `(i64 lo, i64 hi)` olarak döndürür.

Kullanım:  scripts/wasm_gen_simd_vectors.py          # dosyaları yeniden yazar (Node + binaryen `wasm-as` gerekir)
           scripts/wasm_gen_simd_vectors.py --check  # üretilenin depodakiyle aynı olduğunu doğrular (yalnızca Node gerekir)

Satır biçimi: `<işlev> <hex arg>... = <hex sonuç>... [~f32|~f64] | trap` (i32 8, i64 16 hane; `~f32/~f64`: sonuç lane'leri float, NaN lane'ler "NaN mı" olarak karşılaştırılır).
"""
import os, subprocess, sys, tempfile, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/compat/wasm_simd")

# ---- 128-bit işlenen havuzları: (lo, hi) i64 çiftleri
INT_POOL = [
    (0, 0),
    (0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF),
    (0x8080808080808080, 0x7F7F7F7F7F7F7F7F),
    (0xFFFF00017FFF8000, 0x00FF7FFE80010000),
    (0x7FFFFFFF80000000, 0x00000001FFFFFFFF),
    (0x8000000000000000, 0x7FFFFFFFFFFFFFFF),
    (0x123456789ABCDEF0, 0xFEDCBA9876543210),
]


def f32pair(a, b, c, d):
    return ((b << 32) | a, (d << 32) | c)


F32_POOL = [
    f32pair(0x3F800000, 0xBF800000, 0x3F000000, 0x80000000),  # 1, -1, .5, -0
    f32pair(0x00000000, 0x7FC00000, 0x7F800000, 0xFF800000),  # 0, nan, inf, -inf
    f32pair(0x40200000, 0xC0200000, 0x40600000, 0xC0600000),  # 2.5, -2.5, 3.5, -3.5
    f32pair(0x4F000000, 0xCF000000, 0x4F800000, 0xCF800001),  # 2^31, -2^31, 2^32, -2^31-ulp
    f32pair(0x00000001, 0x7F7FFFFF, 0x3DCCCCCD, 0xBF7FFFFF),  # denormal, max, .1, -.99999994
    f32pair(0x3FC00000, 0xBFC00000, 0x40000000, 0xC0000000),  # 1.5, -1.5, 2, -2
]
F64_POOL = [
    (0x3FF0000000000000, 0xBFF0000000000000),
    (0x0000000000000000, 0x8000000000000000),
    (0x7FF8000000000000, 0x7FF0000000000000),
    (0xFFF0000000000000, 0x4004000000000000),
    (0xC004000000000000, 0x3FE0000000000000),
    (0x3FF8000000000000, 0x43E0000000000000),
    (0x41E0000000000000, 0xC1E0000000000000),
]
I32_SC = [0, 1, 0x7F, 0x80, 0xFF, 0x7FFF, 0x8000, 0xFFFF, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x12345678]
I64_SC = [0, 1, 0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF, 0x123456789ABCDEF0]
F32_SC = [0x3F800000, 0xBFC00000, 0x80000000, 0x7F800000, 0x00000001]
F64_SC = [0x3FF0000000000000, 0xBFF8000000000000, 0x8000000000000000, 0x7FF0000000000000, 0x0000000000000001]
SHIFT_COUNTS = [0, 1, 3, 7, 8, 15, 16, 31, 33, 64, 0xFFFFFFFF]

POOLS = {"int": INT_POOL, "f32": F32_POOL, "f64": F64_POOL}

funcs = []  # dict(name, params:[types], results:[types], body:str, cases:[args], flag:str)


def vec(i):
    """Parametre i (lo), i+1 (hi) çiftinden v128 kuran WAT parçası."""
    return f"local.get {i} i64x2.splat local.get {i + 1} i64x2.replace_lane 1"


TAIL = "local.tee {t} i64x2.extract_lane 0 local.get {t} i64x2.extract_lane 1"


def pairs(pool):
    return [list(p) for p in pool]


def add_vec(name, op, nin, domain, flag="", extra=None):
    """nin v128 girişli, v128 sonuçlu komut. extra: ('shift') ek i32 sayacı."""
    pool = POOLS[domain]
    params = ["i64"] * (2 * nin)
    body = " ".join(vec(2 * k) for k in range(nin))
    cases = []
    if extra == "shift":
        params.append("i32")
        body += " local.get %d" % (2 * nin)
    body += f" {op} " + TAIL.format(t=len(params))
    if extra == "shift":
        for a in pool:
            for c in SHIFT_COUNTS:
                cases.append([a[0], a[1], c])
    elif nin == 1:
        for a in pool:
            cases.append([a[0], a[1]])
    elif nin == 2:
        for a in pool:
            for b in pool:
                cases.append([a[0], a[1], b[0], b[1]])
    else:
        for a in pool[:5]:
            for b in pool[:4]:
                for c in pool[:4]:
                    cases.append([a[0], a[1], b[0], b[1], c[0], c[1]])
    funcs.append(dict(name=name, params=params, results=["i64", "i64"], body=body, cases=cases, flag=flag, local="v128"))


def add_test(name, op, domain="int"):
    """v128 -> i32"""
    pool = POOLS[domain]
    funcs.append(dict(name=name, params=["i64", "i64"], results=["i32"], body=f"{vec(0)} {op}", cases=[[a[0], a[1]] for a in pool], flag="", local=None))


# ---------------------------------------------------------------- komut tabloları
def int_lane_group(shape, ops_bin, ops_un=(), ops_test=("all_true", "bitmask"), ops_shift=("shl", "shr_s", "shr_u")):
    for o in ops_bin:
        add_vec(f"{shape}.{o}", f"{shape}.{o}", 2, "int")
    for o in ops_un:
        add_vec(f"{shape}.{o}", f"{shape}.{o}", 1, "int")
    for o in ops_test:
        add_test(f"{shape}.{o}", f"{shape}.{o}")
    for o in ops_shift:
        add_vec(f"{shape}.{o}", f"{shape}.{o}", 1, "int", extra="shift")


CMP_I = ["eq", "ne", "lt_s", "lt_u", "gt_s", "gt_u", "le_s", "le_u", "ge_s", "ge_u"]
int_lane_group("i8x16", ["add", "add_sat_s", "add_sat_u", "sub", "sub_sat_s", "sub_sat_u", "min_s", "min_u", "max_s", "max_u", "avgr_u", "swizzle",
                         "narrow_i16x8_s", "narrow_i16x8_u"] + CMP_I, ["abs", "neg", "popcnt"])
int_lane_group("i16x8", ["add", "add_sat_s", "add_sat_u", "sub", "sub_sat_s", "sub_sat_u", "mul", "min_s", "min_u", "max_s", "max_u", "avgr_u", "q15mulr_sat_s",
                         "narrow_i32x4_s", "narrow_i32x4_u", "extmul_low_i8x16_s", "extmul_high_i8x16_s", "extmul_low_i8x16_u", "extmul_high_i8x16_u"] + CMP_I,
               ["abs", "neg", "extadd_pairwise_i8x16_s", "extadd_pairwise_i8x16_u", "extend_low_i8x16_s", "extend_high_i8x16_s", "extend_low_i8x16_u", "extend_high_i8x16_u"])
int_lane_group("i32x4", ["add", "sub", "mul", "min_s", "min_u", "max_s", "max_u", "dot_i16x8_s", "extmul_low_i16x8_s", "extmul_high_i16x8_s",
                         "extmul_low_i16x8_u", "extmul_high_i16x8_u"] + CMP_I,
               ["abs", "neg", "extadd_pairwise_i16x8_s", "extadd_pairwise_i16x8_u", "extend_low_i16x8_s", "extend_high_i16x8_s", "extend_low_i16x8_u", "extend_high_i16x8_u"])
int_lane_group("i64x2", ["add", "sub", "mul", "eq", "ne", "lt_s", "gt_s", "le_s", "ge_s", "extmul_low_i32x4_s", "extmul_high_i32x4_s", "extmul_low_i32x4_u",
                         "extmul_high_i32x4_u"], ["abs", "neg", "extend_low_i32x4_s", "extend_high_i32x4_s", "extend_low_i32x4_u", "extend_high_i32x4_u"], ops_test=("all_true", "bitmask"))
add_vec("v128.not", "v128.not", 1, "int")
for o in ("and", "andnot", "or", "xor"):
    add_vec(f"v128.{o}", f"v128.{o}", 2, "int")
add_vec("v128.bitselect", "v128.bitselect", 3, "int")
add_test("v128.any_true", "v128.any_true")

for shape, dom, fl in (("f32x4", "f32", "~f32"), ("f64x2", "f64", "~f64")):
    for o in ("add", "sub", "mul", "div", "min", "max", "pmin", "pmax"):
        add_vec(f"{shape}.{o}", f"{shape}.{o}", 2, dom, flag=fl)
    for o in ("eq", "ne", "lt", "gt", "le", "ge"):
        add_vec(f"{shape}.{o}", f"{shape}.{o}", 2, dom)
    for o in ("abs", "neg", "sqrt", "ceil", "floor", "trunc", "nearest"):
        add_vec(f"{shape}.{o}", f"{shape}.{o}", 1, dom, flag=fl)

add_vec("i32x4.trunc_sat_f32x4_s", "i32x4.trunc_sat_f32x4_s", 1, "f32")
add_vec("i32x4.trunc_sat_f32x4_u", "i32x4.trunc_sat_f32x4_u", 1, "f32")
add_vec("f32x4.convert_i32x4_s", "f32x4.convert_i32x4_s", 1, "int", flag="~f32")
add_vec("f32x4.convert_i32x4_u", "f32x4.convert_i32x4_u", 1, "int", flag="~f32")
add_vec("i32x4.trunc_sat_f64x2_s_zero", "i32x4.trunc_sat_f64x2_s_zero", 1, "f64")
add_vec("i32x4.trunc_sat_f64x2_u_zero", "i32x4.trunc_sat_f64x2_u_zero", 1, "f64")
add_vec("f64x2.convert_low_i32x4_s", "f64x2.convert_low_i32x4_s", 1, "int", flag="~f64")
add_vec("f64x2.convert_low_i32x4_u", "f64x2.convert_low_i32x4_u", 1, "int", flag="~f64")
add_vec("f32x4.demote_f64x2_zero", "f32x4.demote_f64x2_zero", 1, "f64", flag="~f32")
add_vec("f64x2.promote_low_f32x4", "f64x2.promote_low_f32x4", 1, "f32", flag="~f64")

# ---- splat / extract / replace
def add_scalar(name, params, results, body, cases, flag="", local=None):
    funcs.append(dict(name=name, params=params, results=results, body=body, cases=cases, flag=flag, local=local))


for shape, pt, sc, conv in (("i8x16", "i32", I32_SC, ""), ("i16x8", "i32", I32_SC, ""), ("i32x4", "i32", I32_SC, ""), ("i64x2", "i64", I64_SC, ""),
                             ("f32x4", "i32", F32_SC, "f32.reinterpret_i32"), ("f64x2", "i64", F64_SC, "f64.reinterpret_i64")):
    fl = "~f32" if shape == "f32x4" else ("~f64" if shape == "f64x2" else "")
    add_scalar(f"{shape}.splat", [pt], ["i64", "i64"], f"local.get 0 {conv} {shape}.splat " + TAIL.format(t=1), [[x] for x in sc], flag="", local="v128")
    lanes = {"i8x16": 16, "i16x8": 8, "i32x4": 4, "i64x2": 2, "f32x4": 4, "f64x2": 2}[shape]
    ex = {"i8x16": ["extract_lane_s", "extract_lane_u"], "i16x8": ["extract_lane_s", "extract_lane_u"]}.get(shape, ["extract_lane"])
    back = {"f32x4": "i32.reinterpret_f32", "f64x2": "i64.reinterpret_f64"}.get(shape, "")
    rt = "i64" if shape in ("i64x2", "f64x2") else "i32"
    for e in ex:
        for ln in range(lanes):
            add_scalar(f"{shape}.{e}@{ln}", ["i64", "i64"], [rt], f"{vec(0)} {shape}.{e} {ln} {back}", [[a[0], a[1]] for a in INT_POOL])
    for ln in range(lanes):
        add_scalar(f"{shape}.replace_lane@{ln}", ["i64", "i64", pt], ["i64", "i64"], f"{vec(0)} local.get 2 {conv} {shape}.replace_lane {ln} " + TAIL.format(t=3),
                   [[a[0], a[1], s] for a in INT_POOL[:4] for s in sc[:5]], local="v128")

# ---- shuffle
SHUF = [
    list(range(16)), list(range(16, 32)), list(range(15, -1, -1)), [i // 2 + (16 if i % 2 else 0) for i in range(16)],
    [8 + i // 2 + (16 if i % 2 else 0) for i in range(16)], [31, 0, 15, 16, 7, 24, 3, 28, 12, 19, 1, 30, 14, 17, 2, 29], [0] * 16, [16] * 16,
]
for k, m in enumerate(SHUF):
    funcs.append(dict(name=f"i8x16.shuffle@{k}", params=["i64"] * 4, results=["i64", "i64"],
                      body=f"{vec(0)} {vec(2)} i8x16.shuffle {' '.join(map(str, m))} " + TAIL.format(t=4),
                      cases=[[a[0], a[1], b[0], b[1]] for a in INT_POOL[:5] for b in INT_POOL[3:]], flag="", local="v128"))

# ---- v128.const
for k, c in enumerate([(0, 0), (0xFFFFFFFFFFFFFFFF, 0x0123456789ABCDEF), (0x8000000000000000, 1)]):
    lo, hi = c
    b = (lo | (hi << 64)).to_bytes(16, "little")
    funcs.append(dict(name=f"v128.const@{k}", params=[], results=["i64", "i64"], body=f"v128.const i8x16 {' '.join(map(str, b))} " + TAIL.format(t=0),
                      cases=[[]], flag="", local="v128"))

# ---- bellek
MEM_ADDRS = [0, 1, 17, 240, 4000, 65520, 65521, 65528, 65535]
LOADS = [("v128.load", 1), ("v128.load8x8_s", 1), ("v128.load8x8_u", 1), ("v128.load16x4_s", 1), ("v128.load16x4_u", 1), ("v128.load32x2_s", 1),
         ("v128.load32x2_u", 1), ("v128.load8_splat", 1), ("v128.load16_splat", 1), ("v128.load32_splat", 1), ("v128.load64_splat", 1),
         ("v128.load32_zero", 1), ("v128.load64_zero", 1)]
for n, _ in LOADS:
    for off in (0, 3):
        funcs.append(dict(name=f"{n}+{off}", params=["i32"], results=["i64", "i64"], body=f"local.get 0 {n} offset={off} align=1 " + TAIL.format(t=1),
                          cases=[[a] for a in MEM_ADDRS], flag="", local="v128"))
for bits, lanes in ((8, 16), (16, 8), (32, 4), (64, 2)):
    for ln in sorted(set([0, lanes // 2, lanes - 1])):
        funcs.append(dict(name=f"v128.load{bits}_lane@{ln}", params=["i32", "i64", "i64"], results=["i64", "i64"],
                          body=f"local.get 0 {vec(1)} v128.load{bits}_lane offset=2 align=1 {ln} " + TAIL.format(t=3),
                          cases=[[a, p[0], p[1]] for a in (0, 17, 65520, 65535) for p in INT_POOL[:3]], flag="", local="v128"))
        funcs.append(dict(name=f"v128.store{bits}_lane@{ln}", params=["i32", "i64", "i64"], results=["i64", "i64"],
                          body=f"local.get 0 {vec(1)} v128.store{bits}_lane offset=0 align=1 {ln} i64.const 0 i64.const 0",
                          cases=[[a, p[0], p[1]] for a in (1024, 1031, 65535, 65529) for p in INT_POOL[3:]], flag="", local=None))
for off in (0, 5):
    funcs.append(dict(name=f"v128.store+{off}", params=["i32", "i64", "i64"], results=["i64", "i64"],
                      body=f"local.get 0 {vec(1)} v128.store offset={off} align=1 i32.const 1024 i64.load i32.const 1032 i64.load",
                      cases=[[a, p[0], p[1]] for a in (1024, 1030, 65520, 65521) for p in INT_POOL[3:]], flag="", local=None))
# store_lane işlevlerindeki yer tutucu gövdeyi düzelt: sonuç = 1024 civarı iki i64
for f in funcs:
    if "_lane@" in f["name"] and "store" in f["name"]:
        f["body"] = f["body"].replace("i64.const 0 i64.const 0", "i32.const 1024 i64.load i32.const 1032 i64.load")


# ---- denetim akışı / çağrı / yerel: v128 değerlerinin gölge yığınında taşınması
HELPERS = """
  (type $vv (func (param v128) (result v128)))
  (table 3 funcref)
  (elem (i32.const 0) $neg $abs8 $dbl)
  (func $addv (param v128 v128) (result v128) local.get 0 local.get 1 i32x4.add)
  (func $mv (param v128 i32 v128) (result i32 v128 v128) local.get 1 local.get 2 local.get 0)
  (func $neg (type $vv) local.get 0 i32x4.neg)
  (func $abs8 (type $vv) local.get 0 i8x16.abs)
  (func $dbl (type $vv) local.get 0 local.get 0 i32x4.add)
  (func $rec (param v128 i32) (result v128)
    local.get 1 i32.eqz
    if (result v128) local.get 0
    else local.get 0 local.get 0 i32x4.add local.get 1 i32.const 1 i32.sub call $rec end)
"""
CN = [[a[0], a[1], n] for a in INT_POOL[:4] for n in (0, 1, 2, 3, 5)]
V3 = ["i64", "i64", "i32"]


def ctl(name, body, local=None, cases=None, params=None, results=None):
    funcs.append(dict(name="ctl." + name, params=params or V3, results=results or ["i64", "i64"], body=body, cases=cases or CN, flag="", local=local))


T = TAIL.format(t=3)
ctl("loop_acc", f"loop $l local.get 3 {vec(0)} i32x4.add local.set 3 local.get 4 i32.const 1 i32.add local.tee 4 local.get 2 i32.lt_u br_if $l end local.get 3 i64x2.extract_lane 0 local.get 3 i64x2.extract_lane 1", local="v128 i32")
ctl("select", f"{vec(0)} {vec(0)} i8x16.not_NOP".replace("i8x16.not_NOP", "v128.not") + f" local.get 2 select {T}", local="v128")
ctl("select_typed", f"{vec(0)} {vec(0)} v128.not local.get 2 select (result v128) {T}", local="v128")
ctl("block_result", f"block (result v128) {vec(0)} local.get 2 br_if 0 drop {vec(0)} i32x4.neg end {T}", local="v128")
ctl("br_table", f"block (result v128) block (result v128) block (result v128) {vec(0)} local.get 2 br_table 0 1 2 end i32x4.neg end i8x16.abs end {T}", local="v128")
ctl("if", f"local.get 2 if (result v128) {vec(0)} else {vec(0)} v128.not end {T}", local="v128")
ctl("call", f"{vec(0)} {vec(0)} v128.not call $addv {T}", local="v128")
ctl("multivalue", f"{vec(0)} local.get 2 {vec(0)} v128.not call $mv local.set 3 local.set 4 drop local.get 3 i64x2.extract_lane 0 local.get 4 i64x2.extract_lane 1", local="v128 v128")
ctl("recursion", f"{vec(0)} local.get 2 call $rec {T}", local="v128")
ctl("call_indirect", f"{vec(0)} local.get 2 i32.const 3 i32.rem_u call_indirect (type $vv) {T}", local="v128")
ctl("return", f"block {vec(0)} local.get 2 br_if 0 {vec(0)} i32x4.neg local.set 3 local.get 3 i64x2.extract_lane 0 local.get 3 i64x2.extract_lane 1 return end {vec(0)} {vec(0)} v128.xor local.set 3 local.get 3 i64x2.extract_lane 0 local.get 3 i64x2.extract_lane 1", local="v128")
ctl("tee", f"{vec(0)} local.tee 3 local.get 3 i32x4.add local.get 3 i8x16.sub {T}", local="v128")
ctl("local_default_zero", f"local.get 3 i64x2.extract_lane 0 local.get 3 i64x2.extract_lane 1", local="v128")
ctl("loop_param", f"{vec(0)} loop (param v128) (result v128) i32x4.neg local.get 2 i32.const 1 i32.sub local.tee 2 br_if 0 end {T}", local="v128", cases=[c for c in CN if c[2] > 0])
ctl("nested_keep", f"{vec(0)} block (param v128) (result v128) {vec(0)} v128.not local.get 2 br_if 0 drop end {T}", local="v128")


def wat():
    lines = ["(module", HELPERS, "  (memory (export \"mem\") 1)",
             "  (data (i32.const 0) \"" + "".join("\\%02x" % ((i * 37 + 11) & 0xFF) for i in range(256)) + "\")"]
    for f in funcs:
        ps = "".join(f" (param {p})" for p in f["params"])
        rs = " ".join(f["results"])
        loc = f" (local {f['local']})" if f["local"] else ""
        lines.append(f'  (func (export "{f["name"]}"){ps} (result {rs}){loc} {f["body"]})')
    lines.append(")")
    return "\n".join(lines) + "\n"


WIDTH = {"i32": 8, "i64": 16}

JS = r"""
const fs = require('fs');
const [wasmPath, casesPath] = process.argv.slice(2);
const mod = new WebAssembly.Module(fs.readFileSync(wasmPath));
const inst = new WebAssembly.Instance(mod, {});
const cases = JSON.parse(fs.readFileSync(casesPath, 'utf8'));
const out = [];
for (const [name, params, results, args, flag] of cases) {
  const a = args.map((h, i) => params[i] === 'i32' ? Number(BigInt.asIntN(32, BigInt('0x' + h))) : BigInt.asIntN(64, BigInt('0x' + h)));
  let r;
  try {
    let v = inst.exports[name](...a);
    if (!Array.isArray(v)) v = [v];
    r = v.map((x, i) => results[i] === 'i32' ? (x >>> 0).toString(16).padStart(8, '0') : BigInt.asUintN(64, x).toString(16).padStart(16, '0')).join(' ');
    if (flag) r += ' ' + flag;
  } catch (e) { if (e instanceof WebAssembly.RuntimeError) r = 'trap'; else throw e; }
  out.push(name + (args.length ? ' ' + args.join(' ') : '') + ' = ' + r);
}
process.stdout.write(out.join('\n') + '\n');
"""


def generate(check=False):
    with tempfile.TemporaryDirectory() as d:
        watp = os.path.join(d, "simd.wat")
        wasmp = os.path.join(d, "simd.wasm")
        open(watp, "w").write(wat())
        if check:
            open(wasmp, "wb").write(open(os.path.join(OUT, "simd.wasm"), "rb").read())
        else:
            subprocess.check_call(["wasm-as", "--enable-simd", "--enable-sign-ext", "--enable-nontrapping-float-to-int", "--enable-bulk-memory", "--enable-multivalue", watp, "-o", wasmp])
        jc = []
        for f in funcs:
            for args in f["cases"]:
                jc.append([f["name"], f["params"], f["results"], [format(a, "0%dx" % WIDTH[f["params"][i]]) for i, a in enumerate(args)], f["flag"]])
        cj = os.path.join(d, "cases.json")
        json.dump(jc, open(cj, "w"))
        jsp = os.path.join(d, "run.js")
        open(jsp, "w").write(JS)
        txt = subprocess.check_output(["node", jsp, wasmp, cj], text=True)
        return wat(), open(wasmp, "rb").read(), txt


def main():
    w, wasm, txt = generate("--check" in sys.argv)
    if "--check" in sys.argv:
        cur = open(os.path.join(OUT, "vectors.txt")).read()
        if cur != txt:
            sys.exit("bayat: vectors.txt (scripts/wasm_gen_simd_vectors.py ile yeniden üretin)")
        print("wasm_gen_simd_vectors: temiz")
        return
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "simd.wat"), "w").write(w)
    open(os.path.join(OUT, "simd.wasm"), "wb").write(wasm)
    open(os.path.join(OUT, "vectors.txt"), "w").write(txt)
    print(f"{len(txt.splitlines())} vektör yazıldı ({len(funcs)} işlev)")


main()
