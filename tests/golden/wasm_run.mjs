// Faz 10 (WASM): `noxc build --target wasm32-wasi` çıktısını Node'un WASI'siyle çalıştırır. Kullanım: node wasm_run.mjs prog.wasm [args...]
// stdout/stderr ana sürecinkine bağlanır; çıkış kodu WASI `proc_exit` koduyla aynıdır. Çalışma dizini `.` ve `/tmp` ön-açılır (nox.fs testleri için).
import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';

const file = process.argv[2];
const wasi = new WASI({
  version: 'preview1',
  args: [file, ...process.argv.slice(3)],
  env: process.env,
  preopens: { '.': '.', '/tmp': '/tmp' },
  returnOnExit: true,
});
const mod = await WebAssembly.compile(await readFile(file));
const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
process.exitCode = wasi.start(inst);
