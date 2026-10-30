// Nox WASM çalıştırıcısı (Faz 10, ADR-012/ADR-013). Tek dosya, bağımlılıksız:
//   * Node'da CLI:        node wasm_host.mjs prog.wasm [argümanlar...]
//   * Kütüphane (Node/tarayıcı): import { createHost, runNox } from './wasm_host.mjs'
//
// İki modül türünü çalıştırır:
//   - `wasm32-wasi`        → Node'un `node:wasi`si (preview1); dosya, saat, rastgelelik, argv/env.
//   - `wasm32-wasi-threads` → paylaşımlı bellek + `wasi::thread-spawn` (ADR-015): her yeni iş parçacığı bir Node Worker'ıdır; Worker'lar aynı `SharedArrayBuffer` belleğini
//       paylaşır ve `wasi_thread_start(tid, arg)`ı çağırır. Başka bir host aynı iki parçayı uygular (paylaşımlı `env.memory` + `wasi.thread-spawn`).
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
export function createHost(io, sharedMemory = null) {
  let memory = sharedMemory;
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
      memory = sharedMemory ?? instance.exports.memory;
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

/** Node'da `nox_host` G/Ç'si (eşzamanlı fs, crypto, Atomics.wait ile uyku). */
async function makeNodeIo() {
  const fs = await import('node:fs');
  const crypto = await import('node:crypto');
  const sab = new Int32Array(new SharedArrayBuffer(4));
  return {
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
}

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
    const memImportNox = findMemoryImport(bytes);
    if (memImportNox && memImportNox.shared) {
      process.exitCode = await runThreaded(file, mod, memImportNox, argv.slice(3), 'nox');
      return;
    }
    process.exitCode = await runNox(bytes, await makeNodeIo());
    return;
  }

  // wasm32-wasi (+ iş parçacıklı varyant: paylaşımlı bellek içe aktarımı varsa)
  const memImport = findMemoryImport(bytes);
  if (memImport && memImport.shared) {
    process.exitCode = await runThreaded(file, mod, memImport, argv.slice(3));
    return;
  }
  const { WASI } = await import('node:wasi');
  const wasi = new WASI({
    version: 'preview1',
    args: [file, ...argv.slice(3)],
    env: process.env,
    preopens: await wasiPreopens(),
    returnOnExit: true,
  });
  const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
  process.exitCode = wasi.start(inst);
}

// ---- Paylaşımlı bellek / iş parçacıkları (ADR-015) ---------------------------------------------------------------------------------------

function readLeb(b, pos) {
  let result = 0, shift = 0, byte;
  do {
    byte = b[pos.i++];
    result |= (byte & 0x7f) << shift;
    shift += 7;
  } while (byte & 0x80);
  return result >>> 0;
}

/** İçe aktarılan belleğin sınırlarını (min/max/shared) okur; WebAssembly.Module.imports sınırları vermez. */
function findMemoryImport(bytes) {
  const b = new Uint8Array(bytes);
  const pos = { i: 8 };
  while (pos.i < b.length) {
    const id = b[pos.i++];
    const size = readLeb(b, pos);
    const end = pos.i + size;
    if (id === 2) {
      const count = readLeb(b, pos);
      for (let n = 0; n < count; n++) {
        const ml = readLeb(b, pos); pos.i += ml;
        const fl = readLeb(b, pos); pos.i += fl;
        const kind = b[pos.i++];
        if (kind === 0) readLeb(b, pos);
        else if (kind === 1) { pos.i++; const f = b[pos.i++]; readLeb(b, pos); if (f & 1) readLeb(b, pos); }
        else if (kind === 2) {
          const flags = b[pos.i++];
          const min = readLeb(b, pos);
          const max = (flags & 1) ? readLeb(b, pos) : undefined;
          return { min, max, shared: !!(flags & 2) };
        } else if (kind === 3) pos.i += 2;
      }
    }
    pos.i = end;
  }
  return null;
}

/**
 * Gözetmen (Node ana iş parçacığı): programın ana iş parçacığı da bir Worker'dır, böylece herhangi bir wasm iş parçacığı `atomic.wait` içinde bloke olsa bile gözetmenin
 * olay döngüsü açık kalır ve HERHANGİ bir iş parçacığının `proc_exit`ini (BroadcastChannel ile) alıp süreci sonlandırabilir.
 */
async function runThreaded(file, mod, memImport, args, kind = 'wasi') {
  const { Worker } = await import('node:worker_threads');
  const memory = new WebAssembly.Memory({ initial: memImport.min, maximum: memImport.max ?? memImport.min, shared: true });
  const chan = new BroadcastChannel(EXIT_CHANNEL);
  const done = new Promise((resolve) => {
    chan.onmessage = (ev) => resolve(ev.data.exit);
  });
  const w = new Worker(new URL(import.meta.url), { workerData: { main: true, kind, mod, memory, tid: 0, arg: 0, file, args, tids: new Int32Array(new SharedArrayBuffer(4)) }, argv: [file] });
  w.on('error', (e) => {
    console.error(e);
    process.exit(1);
  });
  const code = await done;
  chan.close();
  process.exit(code);
}

const EXIT_CHANNEL = 'nox-wasm-exit';

/** WASI ön-açımları: çalışma dizini ve geçici dizin (`/tmp` olarak). Windows'ta `/tmp` yoktur; gerçek geçici dizine eşlenir. */
async function wasiPreopens() {
  const os = await import('node:os');
  return { '.': '.', '/tmp': os.tmpdir() };
}

/** Worker iş parçacığı (ana wasm iş parçacığı ya da `thread-spawn` ile açılan): paylaşımlı belleğe bağlanan bir örnek kurar. */
async function workerMain() {
  const { workerData, Worker } = await import('node:worker_threads');
  const nodeFs = await import('node:fs');
  const { mod, memory, tid, arg, file, args, tids, kind } = workerData;
  const chan = new BroadcastChannel(EXIT_CHANNEL);
  const exitAll = (code) => {
    chan.postMessage({ exit: code });
    chan.close();
  };
  const spawnThread = (a) => {
    const t = Atomics.add(tids, 0, 1) + 1; // iş parçacıkları arasında benzersiz, > 0
    const w = new Worker(new URL(import.meta.url), { workerData: { main: false, kind, mod, memory, tid: t, arg: a, file, args, tids }, argv: [file] });
    w.on('error', (e) => {
      // Worker başlatma/çalışma hatası: sessizce yutulursa `join` sonsuza dek bekler.
      nodeFs.writeSync(2, `wasm iş parçacığı hatası: ${e && e.stack ? e.stack : e}\n`);
      exitAll(1);
    });
    return t;
  };

  let inst;
  let startName;
  if (kind === 'nox') {
    // wasm32-freestanding-threads: `nox_host` import'ları + `thread_spawn`; iş parçacığı girişi `nox_host_thread_start`.
    const host = createHost(await makeNodeIo(), memory);
    host.imports.nox_host.thread_spawn = spawnThread;
    host.imports.nox_host.exit = (code) => {
      exitAll(code);
      throw new NoxExit(code);
    };
    host.imports.env = { memory };
    inst = await WebAssembly.instantiate(mod, host.imports);
    host.bind(inst);
    startName = 'nox_host_thread_start';
  } else {
    const { WASI } = await import('node:wasi');
    const wasi = new WASI({ version: 'preview1', args: [file, ...(args ?? [])], env: process.env, preopens: await wasiPreopens(), returnOnExit: true });
    const imp = { ...wasi.getImportObject(), env: { memory }, wasi: { 'thread-spawn': spawnThread } };
    imp.wasi_snapshot_preview1.proc_exit = (code) => {
      exitAll(code);
      throw new NoxExit(code);
    };
    inst = await WebAssembly.instantiate(mod, imp);
    wasi.finalizeBindings(inst, { memory });
    startName = 'wasi_thread_start';
  }
  try {
    if (workerData.main) {
      inst.exports._start();
      exitAll(0); // `_start` proc_exit olmadan döndü
    } else {
      inst.exports[startName](tid, arg);
    }
  } catch (e) {
    if (!(e instanceof NoxExit)) {
      nodeFs.writeSync(2, `${e && e.stack ? e.stack : e}\n`); // eşzamanlı: gözetmen süreci hemen sonlandırabilir
      exitAll(1);
    }
  }
}

if (typeof process !== 'undefined' && process.argv) {
  const wt = await import('node:worker_threads').catch(() => null);
  if (wt && !wt.isMainThread && wt.workerData && wt.workerData.tid !== undefined && wt.workerData.mod) {
    await workerMain();
  } else if (import.meta.url === new URL(`file://${process.argv[1]}`).href) {
    await nodeMain();
  }
}
