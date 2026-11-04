// Tarayıcıda (ya da Node'da) çalışan Nox derleyicisi: Nox kaynağı -> `.wasm`, sunucu ve yerel araç GEREKTİRMEDEN (spec §3.353).
//
//   1. Ön yüz  (`noxc-frontend.wasm`, `compiler/wasm_compiler.zig`): kaynak -> LLVM IR + bağlama planı. stdlib modülün içindedir.
//   2. Arka uç (clang + wasm-ld, WASM olarak): IR + çalışma zamanı nesneleri -> `.wasm`. Varsayılan sağlayıcı `@yowasp/clang` (isteğe bağlı bağımlılık, ~25 MiB gzip, ilk
//      kullanımda tembel yüklenir); herhangi bir `runClang(argv, files) -> { 'out.wasm': Uint8Array }` uyumlu işlev verilebilir.
//
//   import { createNoxCompiler } from './wasm_compiler.mjs';
//   const nox = await createNoxCompiler({
//     frontend: await (await fetch('noxc-frontend.wasm')).arrayBuffer(),
//     asset: async (name) => new Uint8Array(await (await fetch(`lib/${name}`)).arrayBuffer()),  // noxrt-wasm32-freestanding.o, ...-sqlite3.o, compiler-rt-wasm32.a
//     clang: () => import('@yowasp/clang'),                                                     // tembel; { runClang } döner
//   });
//   const r = await nox.compile('print("merhaba")\n', { target: 'wasm32-freestanding', deny: ['network'] });
//   if (r.ok) await runNox(r.wasm, io);  // wasm_host.mjs
//   else console.error(r.diagnostics);
//
// `compileToIr` yalnızca ön yüzü çalıştırır (hızlı: ~30 ms; sözdizimi/tip hatalarını denetlemek, IR'ı görmek için). Güvenilmeyen kodu çalıştıran sayfalar (playground)
// `deny` ile yetenekleri derleme zamanında kısıtlar ve `runNox`a `fetch`/`vfs` vermez.

const enc = new TextEncoder();
const dec = new TextDecoder();

/** Bağlama planı metnini (`wasm_link.serialize`) ayrıştırır. */
export function parsePlan(text) {
  const plan = { runtime: '', compilerRt: '', sqlite: false, threadsFeatures: false, asyncify: false, flags: [] };
  for (const line of text.split('\n')) {
    if (line === '') continue;
    const sp = line.indexOf(' ');
    const key = sp < 0 ? line : line.slice(0, sp);
    const val = sp < 0 ? '' : line.slice(sp + 1);
    if (key === 'runtime') plan.runtime = val;
    else if (key === 'compiler_rt') plan.compilerRt = val;
    else if (key === 'sqlite') plan.sqlite = true;
    else if (key === 'threads_features') plan.threadsFeatures = true;
    else if (key === 'asyncify') plan.asyncify = true;
    else if (key === 'flag') plan.flags.push(val);
  }
  return plan;
}

/** Ön yüz örneği: kaynak -> { ok, ir, plan, diagnostics }. */
export async function createFrontend(frontendWasm) {
  const { instance } = await WebAssembly.instantiate(frontendWasm, {});
  const x = instance.exports;
  const mem = () => x.memory.buffer;
  const put = (bytes) => {
    const p = x.nox_fc_alloc(bytes.length);
    if (!p) throw new Error('nox: derleyici belleği tükendi');
    new Uint8Array(mem(), p, bytes.length).set(bytes);
    return p;
  };
  const take = (fn) => {
    const lenPtr = x.nox_fc_alloc(4);
    const ptr = fn(lenPtr);
    const len = new DataView(mem()).getUint32(lenPtr, true);
    x.nox_fc_free(lenPtr, 4);
    return len === 0 ? '' : dec.decode(new Uint8Array(mem(), ptr, len).slice());
  };
  return {
    /** Sanal dosya ekler (kullanıcı modülleri için: `import helpers` -> `/project/helpers.nox` değil; yol tam yoldur, bkz. wasm_compiler.zig). */
    addFile(path, text) {
      const pb = enc.encode(path);
      const db = typeof text === 'string' ? enc.encode(text) : text;
      const pp = put(pb);
      const dp = put(db);
      const rc = x.nox_fc_add_file(pp, pb.length, dp, db.length);
      x.nox_fc_free(pp, pb.length);
      x.nox_fc_free(dp, db.length);
      if (rc !== 0) throw new Error(`nox: dosya eklenemedi: ${path}`);
    },
    compileToIr(source, { target = 'wasm32-freestanding', deny = [], label = 'main.nox' } = {}) {
      const sb = enc.encode(source);
      // Seçenekler satır tabanlı bir metindir: değerlerdeki denetim karakterleri (özellikle `\n`) başka bir seçeneği (örn. `deny=`) enjekte edebilirdi.
      const denyText = Array.isArray(deny) ? deny.join(',') : String(deny);
      for (const [name, value] of [['target', target], ['deny', denyText], ['label', label]]) {
        if (/[\u0000-\u001f\u007f]/.test(String(value))) throw new Error(`nox: geçersiz '${name}' seçeneği (denetim karakteri içeremez)`);
      }
      const optText = `target=${target}\ndeny=${denyText}\nlabel=${label}\n`;
      const ob = enc.encode(optText);
      const sp = put(sb);
      const op = put(ob);
      const rc = x.nox_fc_compile(sp, sb.length, op, ob.length);
      x.nox_fc_free(sp, sb.length);
      x.nox_fc_free(op, ob.length);
      const diagnostics = take((l) => x.nox_fc_result_diag(l));
      if (rc !== 0) return { ok: false, diagnostics };
      return { ok: true, ir: take((l) => x.nox_fc_result_ir(l)), plan: parsePlan(take((l) => x.nox_fc_result_plan(l))), diagnostics };
    },
  };
}

/**
 * Tam derleyici: `compile(source, opts)` `.wasm` üretir. `asset(name)`: çalışma zamanı nesneleri (`noxrt-wasm32-*.o`, `-sqlite3.o`, `compiler-rt-wasm32*.a`) için bayt sağlayıcı.
 * `clang()`: `{ runClang }` döndüren (tembel) sağlayıcı. `optimize(wasmBytes, plan)`: bağlama sonrası işlem (asyncify için `wasm-opt`; verilmezse `--asyncify` hedefleri reddedilir).
 */
export async function createNoxCompiler({ frontend, asset, clang, optimize = null }) {
  const fe = await createFrontend(frontend);
  let clangMod = null;
  const assets = new Map();
  const getAsset = async (name) => {
    if (!assets.has(name)) assets.set(name, await asset(name));
    return assets.get(name);
  };
  return {
    addFile: fe.addFile,
    compileToIr: fe.compileToIr,
    async compile(source, opts = {}) {
      const r = fe.compileToIr(source, opts);
      if (!r.ok) return r;
      if (r.plan.asyncify && !optimize) {
        return { ok: false, ir: r.ir, plan: r.plan, diagnostics: `${r.diagnostics}--asyncify needs a post-link optimizer (wasm-opt/binaryen): pass { optimize } to createNoxCompiler\n` };
      }
      const files = { 'prog.ll': enc.encode(r.ir), 'rt.o': await getAsset(`${r.plan.runtime}.o`), 'crt.a': await getAsset(r.plan.compilerRt) };
      const objs = ['rt.o'];
      if (r.plan.sqlite) {
        files['sqlite.o'] = await getAsset(`${r.plan.runtime}-sqlite3.o`);
        objs.push('sqlite.o');
      }
      objs.push('crt.a');
      if (!clangMod) clangMod = await clang();
      let stderr = '';
      const argv = ['clang', '--target=wasm32', '-nostdlib', '-O2', '-Wno-override-module'];
      if (r.plan.threadsFeatures) argv.push('-matomics', '-mbulk-memory');
      argv.push(...r.plan.flags, 'prog.ll', ...objs, '-o', 'out.wasm');
      let out;
      try {
        out = await clangMod.runClang(argv, files, { stderr: (b) => { if (b) stderr += typeof b === 'string' ? b : dec.decode(b); }, stdout: () => {} });
      } catch (e) {
        return { ok: false, ir: r.ir, plan: r.plan, diagnostics: `${r.diagnostics}${stderr}${e && e.message ? e.message : e}\n` };
      }
      let wasm = out['out.wasm'];
      if (r.plan.asyncify) wasm = await optimize(wasm, r.plan);
      return { ok: true, wasm, ir: r.ir, plan: r.plan, diagnostics: r.diagnostics };
    },
  };
}
