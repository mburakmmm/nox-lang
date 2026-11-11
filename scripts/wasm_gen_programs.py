#!/usr/bin/env python3
"""tests/compat/wasm_programs/prog.c'yi `zig cc` ile wasm32'ye derler (gerçek derleyici çıktısı: bellek, bulk-memory, i64, f64, dolaylı çağrı, compiler-rt),
`prog.cases` içindeki çağrıları Node/V8'de çalıştırıp beklenen sonuçları `prog.expected` olarak yazar. `tests/compat/wasm_programs_test.zig` aynı çağrıları
Nox yorumlayıcısında oynatır. Kullanım: scripts/wasm_gen_programs.py [--check]   (zig + node gerekir)

`prog.cases` satırı: `<işlev>:<sonuç tipi i32|i64|f32|f64> <argüman>...`; tamsayı argümanlar işlevin imzasına göre i32/i64'e dönüştürülür, ondalıklılar f64/f32."""
import os, subprocess, sys, tempfile, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(ROOT, "tests/compat/wasm_programs")

JS = r"""
const fs = require('fs');
const [wasmPath, casesPath] = process.argv.slice(2);
const inst = new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(wasmPath)), {});
const f32 = new Float32Array(1), u32 = new Uint32Array(f32.buffer);
const f64 = new Float64Array(1), u64 = new BigUint64Array(f64.buffer);
function fromVal(t, v) {
  if (t === 'i32') return (v >>> 0).toString(16).padStart(8, '0');
  if (t === 'i64') return BigInt.asUintN(64, v).toString(16).padStart(16, '0');
  if (Number.isNaN(v)) return 'nan';
  if (t === 'f32') { f32[0] = v; return u32[0].toString(16).padStart(8, '0'); }
  f64[0] = v; return u64[0].toString(16).padStart(16, '0');
}
const out = [];
for (const line of fs.readFileSync(casesPath, 'utf8').split('\n')) {
  if (!line.trim()) continue;
  const [head, ...rest] = line.trim().split(/\s+/);
  const [name, rt] = head.split(':');
  const fn = inst.exports[name];
  // parametre tipleri: i32 fonksiyonları Number, i64 BigInt; imza bilinmediğinden dosyadaki değerden çıkarılır
  const sig = JSON.parse(fs.readFileSync(casesPath + '.sig', 'utf8'))[name];
  const args = rest.map((a, i) => sig[i] === 'i64' ? BigInt(a) : Number(a));
  let r;
  try { r = fromVal(rt, fn(...args)); } catch (e) { if (e instanceof WebAssembly.RuntimeError) r = 'trap'; else throw e; }
  out.push(line.trim() + ' = ' + r);
}
process.stdout.write(out.join('\n') + '\n');
"""

# işlev imzaları (C kaynağıyla elle tutarlı tutulur): parametre tipleri
SIG = {
    "fib": ["i32"], "collatz": ["i32"], "sieve": ["i32"], "sort_check": ["i32"], "modpow": ["i64", "i64", "i64"], "gcd": ["i64", "i64"],
    "mandel": ["i32"], "matmul": ["i32"], "fsum": ["i32"], "crc32": ["i32"], "memops": ["i32"], "dispatch": ["i32", "i32", "i32"],
    "divmod": ["i32", "i32"], "mul128": ["i64", "i64"], "mix": ["i32", "f64", "f32"], "bits": ["i32"],
}


def main():
    with tempfile.TemporaryDirectory() as d:
        wasm = os.path.join(d, "prog.wasm")
        subprocess.check_call(["zig", "cc", "-target", "wasm32-freestanding", "-O2", "-Wl,--no-entry", "-Wl,--strip-all", "-Wl,--gc-sections", "-Wl,--export-dynamic",
                               "-Wl,--initial-memory=2097152", "-Wl,--max-memory=16777216", "-o", wasm, os.path.join(D, "prog.c")], stderr=subprocess.DEVNULL)
        cases = os.path.join(d, "prog.cases")
        open(cases, "w").write(open(os.path.join(D, "prog.cases")).read())
        json.dump(SIG, open(cases + ".sig", "w"))
        js = os.path.join(d, "run.js")
        open(js, "w").write(JS)
        txt = subprocess.check_output(["node", js, wasm, cases], text=True)
        data = open(wasm, "rb").read()
    if "--check" in sys.argv:
        if open(os.path.join(D, "prog.expected")).read() != txt:
            sys.exit("bayat: prog.expected")
        print("wasm_gen_programs: beklenen sonuçlar temiz (prog.wasm derleyici sürümüne bağlıdır, karşılaştırılmaz)")
        return
    open(os.path.join(D, "prog.wasm"), "wb").write(data)
    open(os.path.join(D, "prog.expected"), "w").write(txt)
    print(f"prog.wasm {len(data)} bayt, {len(txt.splitlines())} çağrı")


main()
