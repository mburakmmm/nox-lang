// Nox WASM çalıştırıcısı (Faz 10, ADR-012/ADR-013). Tek dosya, bağımlılıksız:
//   * Node'da CLI:        node wasm_host.mjs prog.wasm [argümanlar...]
//   * Kütüphane (Node/tarayıcı): import { createHost, runNox } from './wasm_host.mjs'
//
// İki modül türünü çalıştırır:
//   - `wasm32-wasi`        → Node'un `node:wasi`si (preview1); dosya, saat, rastgelelik, argv/env.
//   - `wasm32-freestanding` → `nox_host` import ad alanı (ADR-013). Host sözleşmesi `runtime/wasm_host.zig`de belgelidir:
//       write(fd, ptr, len) -> i32      read(fd, ptr, len) -> i32      clock_ms(kind) -> i64 (BigInt)
//       random_fill(ptr, len)           sleep_ms(ms)                   exit(code)  (dönmez)
//     Modül `_start` ve `nox_host_abi_version` dışa aktarır; host sürüm uyuşmazsa yüklemeyi reddeder.
//
// Tarayıcıda `createHost({ write, read, clockMs, randomFill, sleepMs })` ile kendi G/Ç'ni ver; Node CLI'si bunları fs/crypto ile bağlar.

export const NOX_HOST_ABI_VERSION = 1;

export class NoxExit extends Error {
  constructor(code) {
    super(`nox exit ${code}`);
    this.code = code;
  }
}

/** `io`: { write(fd, bytes) -> n, read(fd, bytes) -> n, clockMs(kind) -> number, randomFill(bytes), sleepMs(ms) } */
export function createHost(io) {
  let memory = null;
  const bytes = (ptr, len) => new Uint8Array(memory.buffer, ptr, len);
  const imports = {
    nox_host: {
      write: (fd, ptr, len) => io.write(fd, bytes(ptr, len)),
      read: (fd, ptr, len) => io.read(fd, bytes(ptr, len)),
      clock_ms: (kind) => BigInt(Math.trunc(io.clockMs(kind))),
      random_fill: (ptr, len) => io.randomFill(bytes(ptr, len)),
      sleep_ms: (ms) => io.sleepMs(Number(ms)),
      exit: (code) => {
        throw new NoxExit(code);
      },
    },
  };
  return {
    imports,
    /** Örnekleme sonrası çağır: bellek bağlanır ve ABI sürümü doğrulanır. */
    bind(instance) {
      memory = instance.exports.memory;
      const v = instance.exports.nox_host_abi_version ? instance.exports.nox_host_abi_version() : 0;
      if (v !== NOX_HOST_ABI_VERSION) {
        throw new Error(`nox_host ABI sürümü uyuşmuyor: modül ${v}, host ${NOX_HOST_ABI_VERSION}`);
      }
    },
  };
}

/** `wasm32-freestanding` modülünü çalıştırır; çıkış kodunu döner. */
export async function runNox(wasmBytes, io) {
  const host = createHost(io);
  const { instance } = await WebAssembly.instantiate(wasmBytes, host.imports);
  host.bind(instance);
  try {
    instance.exports._start();
  } catch (e) {
    if (e instanceof NoxExit) return e.code;
    throw e;
  }
  return 0;
}

// ---- Node CLI ----------------------------------------------------------------------------------------------------------------------------

async function nodeMain() {
  const fs = await import('node:fs');
  const { argv } = await import('node:process');
  const file = argv[2];
  if (!file) {
    console.error('usage: node wasm_host.mjs prog.wasm [args...]');
    process.exit(2);
  }
  const bytes = fs.readFileSync(file);
  const mod = await WebAssembly.compile(bytes);
  const modules = new Set(WebAssembly.Module.imports(mod).map((i) => i.module));

  if (modules.has('nox_host')) {
    const crypto = await import('node:crypto');
    const sab = new Int32Array(new SharedArrayBuffer(4));
    const io = {
      write: (fd, b) => fs.writeSync(fd === 2 ? 2 : 1, b),
      read: (fd, b) => {
        try {
          return fs.readSync(0, b, 0, b.length, null);
        } catch (e) {
          return e.code === 'EOF' ? 0 : -1;
        }
      },
      clockMs: (kind) => (kind === 0 ? Date.now() : performance.now()),
      randomFill: (b) => crypto.randomFillSync(b),
      sleepMs: (ms) => {
        if (ms > 0) Atomics.wait(sab, 0, 0, ms);
      },
    };
    process.exitCode = await runNox(bytes, io);
    return;
  }

  // wasm32-wasi
  const { WASI } = await import('node:wasi');
  const wasi = new WASI({
    version: 'preview1',
    args: [file, ...argv.slice(3)],
    env: process.env,
    preopens: { '.': '.', '/tmp': '/tmp' },
    returnOnExit: true,
  });
  const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
  process.exitCode = wasi.start(inst);
}

if (typeof process !== 'undefined' && process.argv && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  await nodeMain();
}
