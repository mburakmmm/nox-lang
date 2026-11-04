// Nox WASM çalıştırıcısı (Faz 10, ADR-012/ADR-013). Tek dosya, bağımlılıksız:
//   * Node'da CLI:        node wasm_host.mjs prog.wasm [argümanlar...]
//   * Kütüphane (Node/tarayıcı): import { createHost, runNox, runNoxThreads } from './wasm_host.mjs'
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
//
// Kalıcı dosya sistemi (wasm32-freestanding, spec §3.350): `nox.fs`/`nox.sqlite` modülün içindeki bellek içi sanal dosya sistemine yazar. Kalıcılık istiyorsan
// `runNox(bytes, io, { vfs: { files, onSave } })`: `files` ([{ path, data? }]; `data` yoksa dizin) modül başlamadan yüklenir, `onSave(entries)` çıkışta anlık görüntüyle
// çağrılır. Node CLI: `node wasm_host.mjs prog.wasm --vfs-dir=DIR` (ya da `NOX_VFS_DIR`) DIR'i yükler ve çıkışta geri yazar (`/tmp` geçicidir, kaydedilmez).
//
// Ağ yeteneği (wasm32-freestanding --asyncify, spec §3.351): `runNox(bytes, io, { fetch })`; `fetch` verilmezse `nox.http` istemcisi `HttpCapabilityError` verir. Node CLI:
// `--allow-net` (ya da `NOX_ALLOW_NET=1`) `globalThis.fetch`i verir.

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


// ---- Kalıcı sanal dosya sistemi (spec §3.350) ----------------------------------------------------------------------------------------------

const VFS_EXPORTS = ['nox_vfs_host_alloc', 'nox_vfs_host_free', 'nox_vfs_host_put', 'nox_vfs_host_mkdir', 'nox_vfs_host_snapshot'];

/** Modül sanal dosya sistemini kullanıyor mu (dışa aktarımlar yalnızca `nox.fs`/`nox.sqlite` kullanan programlarda vardır)? */
export function vfsAvailable(instance) {
  return VFS_EXPORTS.every((n) => typeof instance.exports[n] === 'function');
}

function vfsMemory(instance, memory) {
  return memory ?? instance.exports.memory;
}

/** `entries`: [{ path, data? }] (`data` bir Uint8Array; yoksa dizin). Üst dizinler kendiliğinden oluşur. Modül sanal dosya sistemini kullanmıyorsa hiçbir şey yapmaz (false). */
export function vfsPreload(instance, entries, memory = null) {
  if (!vfsAvailable(instance)) return false;
  const mem = vfsMemory(instance, memory);
  const x = instance.exports;
  const enc = new TextEncoder();
  const put = (bytes) => {
    const ptr = x.nox_vfs_host_alloc(bytes.length);
    if (!ptr) throw new Error('sanal dosya sistemi: bellek ayrılamadı');
    new Uint8Array(mem.buffer, ptr, bytes.length).set(bytes);
    return ptr;
  };
  for (const e of entries) {
    const pb = enc.encode(e.path);
    const pp = put(pb);
    let rc;
    if (e.data === undefined) {
      rc = x.nox_vfs_host_mkdir(pp, pb.length);
    } else {
      const dp = put(e.data);
      rc = x.nox_vfs_host_put(pp, pb.length, dp, e.data.length);
      x.nox_vfs_host_free(dp, e.data.length);
    }
    x.nox_vfs_host_free(pp, pb.length);
    if (rc !== 0) throw new Error(`sanal dosya sistemi önyüklemesi başarısız: ${e.path}`);
  }
  return true;
}

/** Sanal dosya sisteminin anlık görüntüsü: [{ path, data? }] (yola göre sıralı; ebeveyn çocuktan önce). Kullanılmıyorsa `null`. */
export function vfsSnapshot(instance, memory = null) {
  if (!vfsAvailable(instance)) return null;
  const mem = vfsMemory(instance, memory);
  const x = instance.exports;
  const lenPtr = x.nox_vfs_host_alloc(4);
  const ptr = x.nox_vfs_host_snapshot(lenPtr);
  if (!ptr) {
    x.nox_vfs_host_free(lenPtr, 4);
    throw new Error('sanal dosya sistemi: anlık görüntü alınamadı');
  }
  const len = new DataView(mem.buffer).getUint32(lenPtr, true);
  const buf = new Uint8Array(mem.buffer, ptr, len).slice();
  x.nox_vfs_host_free(ptr, len);
  x.nox_vfs_host_free(lenPtr, 4);
  const dec = new TextDecoder();
  const dv = new DataView(buf.buffer);
  const out = [];
  let i = 0;
  while (i < buf.length) {
    const kind = buf[i];
    const plen = dv.getUint32(i + 1, true);
    const path = dec.decode(buf.subarray(i + 5, i + 5 + plen));
    const dlen = dv.getUint32(i + 5 + plen, true);
    const start = i + 9 + plen;
    out.push(kind === 1 ? { path, data: buf.slice(start, start + dlen) } : { path });
    i = start + dlen;
  }
  return out;
}

// ---- Ağ yeteneği: `fetch` (wasm32-freestanding --asyncify, spec §3.351) ------------------------------------------------------------------------

/** "Ad: değer\n" satırlarını bir başlık nesnesine çevirir (yinelenen adlar `, ` ile birleşir). */
function parseHeaderLines(text) {
  const h = {};
  for (const line of text.split('\n')) {
    const i = line.indexOf(': ');
    if (i <= 0) continue;
    const k = line.slice(0, i);
    h[k] = k in h ? `${h[k]}, ${line.slice(i + 2)}` : line.slice(i + 2);
  }
  return h;
}

/** `nox_host_fetch_pending` çıktısını ayrıştırır: [{ id, timeoutMs, hasBody, method, url, headers, body }]. */
function parsePendingRequests(buf) {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const dec = new TextDecoder();
  const out = [];
  let i = 0;
  const u32 = () => {
    const v = dv.getUint32(i, true);
    i += 4;
    return v;
  };
  const bytes = () => {
    const n = u32();
    const b = buf.subarray(i, i + n);
    i += n;
    return b;
  };
  while (i < buf.length) {
    const id = u32();
    const timeoutMs = u32();
    const hasBody = u32() !== 0;
    out.push({ id, timeoutMs, hasBody, method: dec.decode(bytes()), url: dec.decode(bytes()), headers: dec.decode(bytes()), body: bytes().slice() });
  }
  return out;
}

async function doFetch(fetchFn, req) {
  const init = { method: req.method, headers: parseHeaderLines(req.headers) };
  if (req.hasBody) init.body = req.body;
  if (req.timeoutMs > 0) init.signal = AbortSignal.timeout(req.timeoutMs);
  try {
    const res = await fetchFn(req.url, init);
    const body = new Uint8Array(await res.arrayBuffer());
    let headers = '';
    res.headers.forEach((v, k) => {
      headers += `${k}: ${v}\n`;
    });
    return { id: req.id, status: res.status, errorKind: -1, headers: new TextEncoder().encode(headers), body };
  } catch (e) {
    const timeout = e && (e.name === 'TimeoutError' || e.name === 'AbortError');
    return { id: req.id, status: 0, errorKind: timeout ? 1 : 0, headers: new Uint8Array(0), body: new Uint8Array(0) };
  }
}

/** Askıdaki modülün yeni isteklerini başlatır, bir tanesi bitene kadar bekler ve sonucunu modüle iletir. */
async function pumpFetches(instance, fetchFn, inflight) {
  const x = instance.exports;
  const mem = x.memory;
  const lenPtr = x.nox_host_alloc(4);
  const ptr = x.nox_host_fetch_pending(lenPtr);
  const len = new DataView(mem.buffer).getUint32(lenPtr, true);
  const pending = ptr ? parsePendingRequests(new Uint8Array(mem.buffer, ptr, len).slice()) : [];
  if (ptr) x.nox_host_free(ptr, len);
  x.nox_host_free(lenPtr, 4);
  for (const req of pending) inflight.set(req.id, doFetch(fetchFn, req));
  if (inflight.size === 0) throw new Error('nox: program host için askıda ama bekleyen istek yok');
  const done = await Promise.race([...inflight.entries()].map(([id, p]) => p.then((r) => r)));
  inflight.delete(done.id);
  const put = (b) => {
    const p = x.nox_host_alloc(b.length);
    new Uint8Array(mem.buffer, p, b.length).set(b);
    return p;
  };
  const hp = put(done.headers);
  const bp = put(done.body);
  x.nox_host_fetch_complete(done.id, done.status, done.errorKind, hp, done.headers.length, bp, done.body.length);
  x.nox_host_free(hp, done.headers.length);
  x.nox_host_free(bp, done.body.length);
}

/**
 * `wasm32-freestanding` modülünü çalıştırır; çıkış kodunu döner. `opts.vfs` = { files, onSave } kalıcı dosya sistemi içindir (dosyanın başındaki nota bak); modül
 * dosya sistemini kullanmıyorsa yok sayılır (böylece `onSave` boş bir görüntüyle diski silmez). `opts.fetch`: `--asyncify` ile derlenmiş ve `nox.http` kullanan modüller için
 * ağ yeteneği: bir `fetch` işlevi (ör. `globalThis.fetch` ya da süreç içi sahte) verilmezse ağ yeteneği KAPALIDIR ve istemci çağrıları `HttpCapabilityError` verir (en az ayrıcalık).
 */
export async function runNox(wasmBytes, io, opts = {}) {
  const host = createHost(io);
  const { instance } = await WebAssembly.instantiate(wasmBytes, host.imports);
  host.bind(instance);
  const x = instance.exports;
  const vfs = opts.vfs && vfsAvailable(instance) ? opts.vfs : null;
  if (vfs && vfs.files) vfsPreload(instance, vfs.files);
  const asyncHost = typeof x.nox_host_resume === 'function' && typeof x.nox_host_caps_set === 'function';
  const fetchFn = opts.fetch || null;
  if (asyncHost && fetchFn) x.nox_host_caps_set(1);
  let code = 0;
  try {
    let step = () => x._start();
    const inflight = new Map();
    for (;;) {
      try {
        step();
      } catch (e) {
        if (e instanceof NoxExit) {
          code = e.code;
          break;
        }
        throw e;
      }
      if (!asyncHost || x.nox_host_status() !== 1) break;
      await pumpFetches(instance, fetchFn.bind(globalThis), inflight);
      step = () => x.nox_host_resume();
    }
  } finally {
    if (vfs && vfs.onSave) await vfs.onSave(vfsSnapshot(instance));
  }
  return code;
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


// ---- Node: dizin <-> sanal dosya sistemi -----------------------------------------------------------------------------------------------------

const VFS_DIR_MAX_BYTES = 512 * 1024 * 1024;

/** Sanal yol bileşenleri diske güvenle eşlenebilir mi (normalleştirilmiş yollarda `..` olmaz; ayrıca ters bölü, `:` ve NUL reddedilir). */
function vfsSafePath(p) {
  return p.startsWith('/') && p.split('/').slice(1).every((c) => c.length > 0 && !/[\\:\0]/.test(c) && c !== '.' && c !== '..');
}

const vfsIsTmp = (rel) => rel === '/tmp' || rel.startsWith('/tmp/');

/**
 * `dir` dizinini sanal dosya sistemine eşler: `load()` dizini okur (sembolik bağlar ve üst düzey `tmp` atlanır), `save(snapshot)` sonucu geri yazar. Yalnızca YÜKLENEN
 * yollardan programın sildikleri diskten silinir (başka bir süreç aynı sırada dosya eklediyse dokunulmaz); değişmeyen dosyalar yeniden yazılmaz; yazma geçici dosya + rename ile yapılır.
 */
async function makeNodeVfs(dir, loadedInit = null) {
  const fs = await import('node:fs');
  const pathMod = await import('node:path');
  const root = pathMod.resolve(dir);
  if (root === pathMod.parse(root).root) throw new Error('--vfs-dir bir dosya sistemi kökü olamaz');
  const abs = (rel) => pathMod.join(root, ...rel.split('/').slice(1));
  const api = {
    loaded: loadedInit ?? [],
    load() {
      fs.mkdirSync(root, { recursive: true });
      const entries = [];
      let total = 0;
      const walk = (absDir, rel) => {
        for (const d of fs.readdirSync(absDir, { withFileTypes: true })) {
          if (d.isSymbolicLink()) continue;
          const r = `${rel}/${d.name}`;
          if (vfsIsTmp(r) || !vfsSafePath(r)) continue;
          const full = pathMod.join(absDir, d.name);
          if (d.isDirectory()) {
            entries.push({ path: r });
            walk(full, r);
          } else if (d.isFile()) {
            const data = new Uint8Array(fs.readFileSync(full));
            total += data.length;
            if (total > VFS_DIR_MAX_BYTES) throw new Error(`--vfs-dir çok büyük (en çok ${VFS_DIR_MAX_BYTES} bayt yüklenir)`);
            entries.push({ path: r, data });
          }
        }
      };
      walk(root, '');
      api.loaded = entries.map((e) => e.path);
      return entries;
    },
    save(snapshot) {
      const want = new Map();
      for (const e of snapshot) {
        if (vfsIsTmp(e.path)) continue;
        if (!vfsSafePath(e.path)) {
          process.stderr.write(`nox: --vfs-dir: '${e.path}' diske eşlenemez, kaydedilmedi\n`);
          continue;
        }
        want.set(e.path, e);
      }
      // Programın sildiği ya da türünü değiştirdiği (dosya <-> dizin) yüklenmiş yollar diskten kaldırılır.
      for (const rel of [...api.loaded].sort((a, b) => b.length - a.length)) {
        const w = want.get(rel);
        const p = abs(rel);
        let st;
        try {
          st = fs.lstatSync(p);
        } catch {
          continue;
        }
        if (st.isSymbolicLink()) continue;
        if (!w || (w.data !== undefined && st.isDirectory()) || (w.data === undefined && st.isFile())) fs.rmSync(p, { recursive: true, force: true });
      }
      for (const [rel, e] of [...want].sort((a, b) => a[0].length - b[0].length)) {
        const p = abs(rel);
        if (e.data === undefined) {
          fs.mkdirSync(p, { recursive: true });
          continue;
        }
        fs.mkdirSync(pathMod.dirname(p), { recursive: true });
        try {
          if (Buffer.compare(fs.readFileSync(p), e.data) === 0) continue;
        } catch {}
        const tmp = `${p}.nox-tmp-${process.pid}`;
        fs.writeFileSync(tmp, e.data);
        fs.renameSync(tmp, p);
      }
      api.loaded = [...want.keys()];
    },
  };
  return api;
}

/** `--vfs-dir=DIR` / `--vfs-dir DIR` (ve `NOX_VFS_DIR`) ile `--allow-net` (ve `NOX_ALLOW_NET=1`) argümanlarını ayıklar. */
function takeHostFlags(args) {
  let dir = process.env.NOX_VFS_DIR || null;
  let allowNet = process.env.NOX_ALLOW_NET === '1';
  const rest = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith('--vfs-dir=')) dir = a.slice('--vfs-dir='.length);
    else if (a === '--vfs-dir' && i + 1 < args.length) dir = args[++i];
    else if (a === '--allow-net') allowNet = true;
    else rest.push(a);
  }
  return { dir, allowNet, rest };
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
  const { dir: vfsDir, allowNet, rest: progArgs } = takeHostFlags(argv.slice(3));
  const mod = await WebAssembly.compile(bytes);
  const modules = new Set(WebAssembly.Module.imports(mod).map((i) => i.module));

  if (modules.has('nox_host')) {
    const memImportNox = findMemoryImport(bytes);
    if (memImportNox && memImportNox.shared) {
      process.exitCode = await runThreaded(file, mod, memImportNox, progArgs, 'nox', vfsDir);
      return;
    }
    let vfs;
    if (vfsDir) {
      const nv = await makeNodeVfs(vfsDir);
      vfs = { files: nv.load(), onSave: (snap) => nv.save(snap) };
    }
    process.exitCode = await runNox(bytes, await makeNodeIo(), { vfs, fetch: allowNet ? globalThis.fetch : null });
    return;
  }

  // wasm32-wasi (+ iş parçacıklı varyant: paylaşımlı bellek içe aktarımı varsa)
  const memImport = findMemoryImport(bytes);
  if (memImport && memImport.shared) {
    process.exitCode = await runThreaded(file, mod, memImport, progArgs);
    return;
  }
  const { WASI } = await import('node:wasi');
  const wasi = new WASI({
    version: 'preview1',
    args: [file, ...progArgs],
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
async function runThreaded(file, mod, memImport, args, kind = 'wasi', vfsDir = null) {
  const { Worker } = await import('node:worker_threads');
  const memory = new WebAssembly.Memory({ initial: memImport.min, maximum: memImport.max ?? memImport.min, shared: true });
  const chan = new BroadcastChannel(EXIT_CHANNEL);
  const done = new Promise((resolve) => {
    chan.onmessage = (ev) => resolve(ev.data.exit);
  });
  const w = new Worker(new URL(import.meta.url), { workerData: { main: true, kind, mod, memory, tid: 0, arg: 0, file, args, vfsDir, tids: new Int32Array(new SharedArrayBuffer(4)) }, argv: [file] });
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

/** `wasm32-freestanding-threads` örneği: `nox_host` + `thread_spawn` + paylaşımlı `env.memory`. Node ve tarayıcı Worker'ları ortak kullanır. */
async function instantiateNoxThread(mod, memory, io, spawnThread, exitAll, beforeExit = null) {
  const host = createHost(io, memory);
  host.imports.nox_host.thread_spawn = spawnThread;
  host.imports.nox_host.exit = (code) => {
    if (beforeExit) beforeExit();
    exitAll(code);
    throw new NoxExit(code);
  };
  host.imports.env = { memory };
  const inst = await WebAssembly.instantiate(mod, host.imports);
  host.bind(inst);
  return inst;
}

/** Worker iş parçacığı (ana wasm iş parçacığı ya da `thread-spawn` ile açılan): paylaşımlı belleğe bağlanan bir örnek kurar. */
async function workerMain() {
  const { workerData, Worker } = await import('node:worker_threads');
  const nodeFs = await import('node:fs');
  const { mod, memory, tid, arg, file, args, tids, kind, vfsDir } = workerData;
  let vfsLoaded = workerData.vfsLoaded;
  const chan = new BroadcastChannel(EXIT_CHANNEL);
  const exitAll = (code) => {
    chan.postMessage({ exit: code });
    chan.close();
  };
  const spawnThread = (a) => {
    const t = Atomics.add(tids, 0, 1) + 1; // iş parçacıkları arasında benzersiz, > 0
    const w = new Worker(new URL(import.meta.url), { workerData: { main: false, kind, mod, memory, tid: t, arg: a, file, args, tids, vfsDir, vfsLoaded }, argv: [file] });
    w.on('error', (e) => {
      // Worker başlatma/çalışma hatası: sessizce yutulursa `join` sonsuza dek bekler.
      nodeFs.writeSync(2, `wasm iş parçacığı hatası: ${e && e.stack ? e.stack : e}\n`);
      exitAll(1);
    });
    return t;
  };

  let inst;
  let startName;
  let onMainReturn = null;
  if (kind === 'nox') {
    // wasm32-freestanding-threads: `nox_host` import'ları + `thread_spawn`; iş parçacığı girişi `nox_host_thread_start`.
    // Kalıcı dosya sistemi (`--vfs-dir`): ana iş parçacığı dizini yükler; çıkışı hangi iş parçacığı tetiklerse o anlık görüntüyü yazar (bellek paylaşımlıdır).
    const nv = vfsDir ? await makeNodeVfs(vfsDir, vfsLoaded) : null;
    let self = null;
    const saveVfs = nv
      ? () => {
          if (!self || !vfsAvailable(self)) return;
          nv.save(vfsSnapshot(self, memory));
        }
      : null;
    inst = await instantiateNoxThread(mod, memory, await makeNodeIo(), spawnThread, exitAll, saveVfs);
    self = inst;
    if (nv && workerData.main) {
      vfsPreload(inst, nv.load(), memory);
      vfsLoaded = nv.loaded;
    }
    onMainReturn = saveVfs;
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
      if (onMainReturn) onMainReturn();
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

// ---- Tarayıcı iş parçacıkları (wasm32-freestanding-threads) ---------------------------------------------------------------------------------

const BROWSER_CHANNEL = 'nox-wasm-browser';

/**
 * Tarayıcıda `wasm32-freestanding-threads` modülünü çalıştırır; çıkış kodunu döner. Sayfa `crossOriginIsolated` olmalıdır (COOP/COEP başlıkları).
 * Sayfanın ana iş parçacığı `Atomics.wait` yapamadığından ANA wasm iş parçacığı bir Worker'dır. TÜM Worker'ları SAYFA oluşturur (iç içe Worker DEĞİL): tarayıcılar iç içe
 * bir Worker'ın betiğini ebeveynin olay döngüsü üzerinden yükler; ebeveyn `atomic.wait`te bloke olunca çocuk hiç başlamaz (kilitlenme). Bir wasm iş parçacığı
 * `thread_spawn` çağırınca benzersiz kimliği hemen alır ve sayfaya bir "başlat" isteği yollar (Node'daki gibi iş parçacığı eşzamansız başlar). Worker'lar G/Ç'yi
 * (yalnızca `write`) ve çıkışı tek bir BroadcastChannel ile iletir, böylece çıktı ile çıkış kodu sıralı gelir. `io.write` sayfada çalışır; diğer `io` alanları
 * Worker içinde varsayılanlarla değiştirilir (okuma yok, `crypto`, `performance`).
 */
export async function runNoxThreads(wasmBytes, io, { workerUrl = import.meta.url, vfs = null } = {}) {
  if (!globalThis.crossOriginIsolated) {
    throw new Error('SharedArrayBuffer için sayfa COOP/COEP ile sunulmalı (crossOriginIsolated)');
  }
  const memImport = findMemoryImport(wasmBytes);
  if (!memImport || !memImport.shared) {
    throw new Error('modül paylaşımlı bellek içe aktarmıyor (wasm32-freestanding-threads değil)');
  }
  const mod = await WebAssembly.compile(wasmBytes);
  const memory = new WebAssembly.Memory({ initial: memImport.min, maximum: memImport.max ?? memImport.min, shared: true });
  const chan = new BroadcastChannel(BROWSER_CHANNEL);
  const tids = new Int32Array(new SharedArrayBuffer(4));
  const workers = [];
  let settle;
  const done = new Promise((resolve, reject) => {
    settle = { resolve, reject };
  });
  const start = (main, tid, arg) => {
    const w = new Worker(workerUrl, { type: 'module' });
    workers.push(w);
    w.onerror = (e) => settle.reject(new Error(`wasm iş parçacığı hatası: ${e.message}`));
    w.postMessage({ noxThread: { main, mod, memory, tid, arg, tids, vfs: !!vfs, vfsFiles: main && vfs ? vfs.files : undefined } });
  };
  let vfsEntries = null;
  chan.onmessage = (ev) => {
    const m = ev.data;
    if (m.type === 'write') io.write(m.fd, m.bytes);
    else if (m.type === 'vfs') vfsEntries = m.entries;
    else if (m.type === 'exit') settle.resolve(m.code);
    else if (m.type === 'spawn') start(false, m.tid, m.arg);
  };
  try {
    start(true, 0, 0);
    const code = await done;
    // Çıkışı tetikleyen iş parçacığı anlık görüntüyü, çıkış iletisinden ÖNCE gönderir (aynı kanalda sıra korunur).
    if (vfs && vfs.onSave && vfsEntries) await vfs.onSave(vfsEntries);
    return code;
  } finally {
    for (const w of workers) w.terminate();
    chan.close();
  }
}

/** Tarayıcı Worker'ı: ana ya da `thread_spawn` ile açılan bir wasm iş parçacığı. */
async function browserWorkerMain({ main, mod, memory, tid, arg, tids, vfs, vfsFiles }) {
  const chan = new BroadcastChannel(BROWSER_CHANNEL);
  const enc = new TextEncoder();
  const sleepCell = new Int32Array(new SharedArrayBuffer(4));
  const io = {
    // Paylaşımlı bellek üzerindeki görünüm `postMessage`/`getRandomValues`a doğrudan verilemez: kopyalanır.
    write: (fd, b) => {
      chan.postMessage({ type: 'write', fd, bytes: b.slice() });
      return b.length;
    },
    read: () => 0,
    clockMs: (kind) => (kind === 0 ? Date.now() : performance.now()),
    randomFill: (b) => {
      const tmp = new Uint8Array(b.length);
      crypto.getRandomValues(tmp);
      b.set(tmp);
    },
    sleepMs: (ms) => {
      if (ms > 0) Atomics.wait(sleepCell, 0, 0, ms);
    },
  };
  let self = null;
  const exitAll = (code) => {
    if (vfs && self && vfsAvailable(self)) chan.postMessage({ type: 'vfs', entries: vfsSnapshot(self, memory) });
    chan.postMessage({ type: 'exit', code });
  };
  const fail = (text) => {
    io.write(2, enc.encode(`${text}\n`));
    exitAll(1);
  };
  const spawnThread = (a) => {
    const t = Atomics.add(tids, 0, 1) + 1; // iş parçacıkları arasında benzersiz, > 0
    chan.postMessage({ type: 'spawn', tid: t, arg: a }); // Worker'ı sayfa oluşturur (bkz. `runNoxThreads`)
    return t;
  };
  try {
    const inst = await instantiateNoxThread(mod, memory, io, spawnThread, (code) => exitAll(code));
    self = inst;
    if (main && vfsFiles) vfsPreload(inst, vfsFiles, memory);
    if (main) {
      inst.exports._start();
      exitAll(0); // `_start` exit olmadan döndü
    } else {
      inst.exports.nox_host_thread_start(tid, arg);
    }
  } catch (e) {
    if (!(e instanceof NoxExit)) fail(e && e.stack ? e.stack : String(e));
  }
}

if (typeof WorkerGlobalScope !== 'undefined' && globalThis instanceof WorkerGlobalScope) {
  globalThis.onmessage = (ev) => {
    if (ev.data && ev.data.noxThread) browserWorkerMain(ev.data.noxThread);
  };
}

if (typeof process !== 'undefined' && process.argv) {
  const wt = await import('node:worker_threads').catch(() => null);
  if (wt && !wt.isMainThread && wt.workerData && wt.workerData.tid !== undefined && wt.workerData.mod) {
    await workerMain();
  } else if (import.meta.url === new URL(`file://${process.argv[1]}`).href) {
    await nodeMain();
  }
}
