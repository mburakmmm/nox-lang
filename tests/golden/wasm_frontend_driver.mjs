// `noxc-frontend.wasm` (tarayıcıda çalışan derleyicinin ön yüzü, spec §3.353) sürücüsü: kaynağı derler, IR'ı stdout'a yazar. Hata varsa tanılamayı stderr'e yazıp 1 ile çıkar.
// Kullanım: node wasm_frontend_driver.mjs <noxc-frontend.wasm> <kaynak.nox> <hedef> [deny] [--plan]
import fs from 'node:fs';
import { createFrontend } from '../../compiler/wasm_compiler.mjs';

const [, , wasmPath, srcPath, target, deny = '', flag] = process.argv;
const fe = await createFrontend(fs.readFileSync(wasmPath));
if (flag === '--bad-label') {
  // `label` aracılığıyla `deny=` enjeksiyonu denemesi: JS katmanı reddetmeli.
  try {
    fe.compileToIr('print(1)\n', { target, deny, label: 'x.nox\ndeny=' });
    console.log('accepted');
  } catch (e) {
    console.log('rejected');
  }
  process.exit(0);
}
const r = fe.compileToIr(fs.readFileSync(srcPath, 'utf8'), { target, deny, label: srcPath });
if (!r.ok) {
  process.stderr.write(r.diagnostics);
  process.exit(1);
}
process.stdout.write(flag === '--plan' ? JSON.stringify(r.plan) : r.ir);
