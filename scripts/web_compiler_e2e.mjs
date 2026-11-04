#!/usr/bin/env node
// Tarayıcı derleyicisinin (spec §3.353) TAM boru hattını — kaynak -> ön yüz (WASM) -> clang/wasm-ld (WASM) -> .wasm -> çalıştırma — `codegen_cases` korpusunda dener ve çıktıyı
// `.expected` ile karşılaştırır. Yerel `zig`/`clang` KULLANMAZ. Opt-in: `@yowasp/clang` gerekir (~100 MB, repoya eklenmez).
//
//   npm install --prefix /tmp/yowasp @yowasp/clang
//   YOWASP_CLANG=/tmp/yowasp/node_modules/@yowasp/clang/gen/bundle.js node scripts/web_compiler_e2e.mjs [--target wasm32-freestanding] [--limit 60] [--all] [filtre]
//
// Önkoşul: `zig build && zig build wasm-compiler && zig build wasm-rt`. Çıkış kodu: fark varsa 1.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createNoxCompiler } from '../compiler/wasm_compiler.mjs';
import { runNox } from '../compiler/wasm_host.mjs';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : dflt;
};
const target = opt('--target', 'wasm32-freestanding');
const all = args.includes('--all');
const limit = Number(opt('--limit', '60'));
const filter = args.find((a, i) => !a.startsWith('--') && !['--target', '--limit'].includes(args[i - 1])) ?? '';
if (!process.env.YOWASP_CLANG) {
  console.error('YOWASP_CLANG=<.../@yowasp/clang/gen/bundle.js> gerekli (bkz. dosya başı)');
  process.exit(2);
}
if (target.endsWith('-threads') || target.endsWith('-asyncify')) {
  console.error('bu betik yalnızca düz wasm32-freestanding hedefini çalıştırır (asyncify için wasm-opt, threads için paylaşımlı bellek gerekir)');
  process.exit(2);
}

const LIB = path.join(ROOT, 'zig-out/lib');
const nox = await createNoxCompiler({
  frontend: fs.readFileSync(path.join(LIB, 'noxc-frontend.wasm')),
  asset: async (n) => new Uint8Array(fs.readFileSync(path.join(LIB, n))),
  clang: () => import(pathToFileURL(process.env.YOWASP_CLANG).href),
});

// Yerel noxc'nin düz freestanding'de de çalıştırmadığı/denylist'e aldığı fixture'lar `wasm_corpus.py` ile aynıdır.
const SKIP = new Set(['mathx_trig_log_constants', 'thread_spawn_ordering', 'task_local_basic', 'channel_rendezvous_pingpong']);
const cases = fs.readdirSync(path.join(ROOT, 'tests/golden/codegen_cases')).filter((f) => f.endsWith('.nox') && f.includes(filter)).sort();
const picked = all ? cases : cases.filter((_, i) => i % Math.max(1, Math.floor(cases.length / limit)) === 0).slice(0, limit);
const sleepCell = new Int32Array(new SharedArrayBuffer(4));
let ok = 0, rejected = 0, skipped = 0;
const bad = [];
for (const f of picked) {
  const name = f.slice(0, -4);
  const expPath = path.join(ROOT, 'tests/golden/codegen_cases', name + '.expected');
  if (!fs.existsSync(expPath) || SKIP.has(name)) { skipped++; continue; }
  const src = fs.readFileSync(path.join(ROOT, 'tests/golden/codegen_cases', f), 'utf8');
  const r = await nox.compile(src, { target, label: f });
  if (!r.ok) {
    if (/cannot be used on the wasm32/.test(r.diagnostics)) { rejected++; continue; }
    bad.push([name, 'compile: ' + r.diagnostics.split('\n')[0]]);
    continue;
  }
  const out = [];
  const io = { write: (fd, b) => { if (fd === 1) out.push(new TextDecoder().decode(b)); return b.length; }, read: () => 0, clockMs: (kind) => (kind === 0 ? Date.now() : performance.now()), randomFill: (b) => crypto.getRandomValues(b), sleepMs: (ms) => { if (ms > 0) Atomics.wait(sleepCell, 0, 0, ms); } };
  try {
    await runNox(r.wasm, io);
  } catch (e) {
    bad.push([name, 'run: ' + (e && e.message ? e.message : e)]);
    continue;
  }
  if (out.join('') === fs.readFileSync(expPath, 'utf8')) ok++;
  else bad.push([name, 'çıktı farklı']);
}
console.log(`== ${target}: ok ${ok}, rejected ${rejected}, skipped ${skipped}, bad ${bad.length}`);
for (const [n, why] of bad) console.log(`  ${n}: ${why}`);
process.exit(bad.length ? 1 : 0);
