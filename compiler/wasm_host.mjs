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

/** `nox_host_fetch_pending` çıktısını ayrıştırır: [{ id, kind, stream, arg, hasBody, method, url, headers, body }]. `kind`: 0 fetch, 1 stream_open, 2 stream_read, 3 stream_close. */
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
    const kind = u32();
    const stream = u32();
    const arg = u32();
    const hasBody = u32() !== 0;
    out.push({ id, kind, stream, arg, hasBody, method: dec.decode(bytes()), url: dec.decode(bytes()), headers: dec.decode(bytes()), body: bytes().slice() });
  }
  return out;
}

const emptyBytes = new Uint8Array(0);
const errorKindOf = (e) => (e && (e.name === 'TimeoutError' || e.name === 'AbortError') ? 1 : 0);
const failed = (id, kind) => ({ id, status: 0, errorKind: kind, headers: emptyBytes, body: emptyBytes });

function headerText(res) {
  let headers = '';
  res.headers.forEach((v, k) => {
    headers += `${k}: ${v}\n`;
  });
  return new TextEncoder().encode(headers);
}

/** Tam yanıtlı `fetch` (kind 0). */
async function doFetch(fetchFn, req) {
  const init = { method: req.method, headers: parseHeaderLines(req.headers) };
  if (req.hasBody) init.body = req.body;
  if (req.arg > 0) init.signal = AbortSignal.timeout(req.arg);
  try {
    const res = await fetchFn(req.url, init);
    const body = new Uint8Array(await res.arrayBuffer());
    return { id: req.id, status: res.status, errorKind: -1, headers: headerText(res), body };
  } catch (e) {
    return failed(req.id, errorKindOf(e));
  }
}

/** Zaman aşımlı bekleme: `ms > 0` iken söz `ms` içinde bitmezse akış iptal edilir ve `TimeoutError` fırlar (boşta kalma zaman aşımı, toplam süre değil). */
function withIdleTimeout(promise, ms, onTimeout) {
  if (!(ms > 0)) return promise;
  let timer;
  const timeout = new Promise((_, rej) => {
    timer = setTimeout(() => {
      onTimeout();
      const e = new Error('timeout');
      e.name = 'TimeoutError';
      rej(e);
    }, ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/** Akışlı istemci (kind 1/2/3): `streams` açık yanıt okuyucularını tutar (anahtar: açan isteğin kimliği). */
async function doStream(fetchFn, req, streams) {
  if (req.kind === 3) {
    const st = streams.get(req.stream);
    streams.delete(req.stream);
    if (st && st.reader) st.reader.cancel().catch(() => {});
    return null; // yanıt beklenmez
  }
  if (req.kind === 2) {
    const st = streams.get(req.stream);
    if (!st) return failed(req.id, 0);
    try {
      if (!st.reader) {
        streams.delete(req.stream);
        return { id: req.id, status: 0, errorKind: -1, headers: emptyBytes, body: emptyBytes };
      }
      const { done, value } = await withIdleTimeout(st.reader.read(), st.timeoutMs, () => st.ctrl.abort());
      if (done) streams.delete(req.stream);
      return { id: req.id, status: 0, errorKind: -1, headers: emptyBytes, body: done ? emptyBytes : value };
    } catch (e) {
      streams.delete(req.stream);
      if (st.reader) st.reader.cancel().catch(() => {});
      return failed(req.id, errorKindOf(e));
    }
  }
  // kind 1: akışı aç — başlıklar gelince döner, gövde okuyucuda kalır.
  const ctrl = new AbortController();
  const init = { method: req.method, headers: parseHeaderLines(req.headers), signal: ctrl.signal };
  if (req.hasBody) init.body = req.body;
  try {
    const res = await withIdleTimeout(fetchFn(req.url, init), req.arg, () => ctrl.abort());
    streams.set(req.id, { reader: res.body ? res.body.getReader() : null, ctrl, timeoutMs: req.arg });
    return { id: req.id, status: res.status, errorKind: -1, headers: headerText(res), body: emptyBytes };
  } catch (e) {
    return failed(req.id, errorKindOf(e));
  }
}

/**
 * WebSocket (kind 4-7, `websocket_wasm.zig`): `streams` haritasında { ws, queue, waiter, closed, error } tutulur. `ws_open` bağlantı kurulunca (ya da hata) döner; gelen iletiler
 * kuyruğa yazılır, `ws_recv` sıradaki iletiyi (ya da kapanışı: durum 1) verir; `ws_send`/`ws_close` yanıtsızdır.
 */
async function doSocket(req, streams, WebSocketCtor) {
  if (req.kind === 5) {
    const st = streams.get(req.stream);
    if (st && !st.closed) st.ws.send(new TextDecoder().decode(req.body));
    return null;
  }
  if (req.kind === 7) {
    const st = streams.get(req.stream);
    streams.delete(req.stream);
    if (st && !st.closed) st.ws.close();
    return null;
  }
  if (req.kind === 6) {
    const st = streams.get(req.stream);
    if (!st) return { id: req.id, status: 1, errorKind: -1, headers: emptyBytes, body: emptyBytes };
    if (st.queue.length === 0 && !st.closed) await new Promise((resolve) => (st.waiter = resolve));
    st.waiter = null;
    if (st.queue.length > 0) return { id: req.id, status: 0, errorKind: -1, headers: emptyBytes, body: st.queue.shift() };
    streams.delete(req.stream);
    return { id: req.id, status: 1, errorKind: -1, headers: emptyBytes, body: emptyBytes }; // kapandı
  }
  // kind 4: aç
  if (!WebSocketCtor) return { ...failed(req.id, 0), body: new TextEncoder().encode('WebSocket is not available in this host') };
  return new Promise((resolve) => {
    let ws;
    try {
      ws = new WebSocketCtor(req.url);
    } catch (e) {
      resolve({ ...failed(req.id, 0), body: new TextEncoder().encode(String(e && e.message ? e.message : e)) });
      return;
    }
    ws.binaryType = 'arraybuffer';
    const st = { ws, queue: [], waiter: null, closed: false };
    let opened = false;
    ws.onopen = () => {
      opened = true;
      streams.set(req.id, st);
      resolve({ id: req.id, status: 0, errorKind: -1, headers: emptyBytes, body: emptyBytes });
    };
    ws.onmessage = (ev) => {
      st.queue.push(typeof ev.data === 'string' ? new TextEncoder().encode(ev.data) : new Uint8Array(ev.data));
      if (st.waiter) st.waiter();
    };
    const onEnd = (msg) => {
      st.closed = true;
      if (st.waiter) st.waiter();
      if (!opened) resolve({ ...failed(req.id, 0), body: new TextEncoder().encode(msg) });
    };
    ws.onerror = () => onEnd('WebSocket connection failed');
    ws.onclose = () => onEnd('WebSocket closed before the handshake completed');
  });
}

/**
 * Ham TCP (kind 8-12, `tcp_host.zig`; `smtp`/`tls` modülleri): `tcp.connect(host, port, useTls) -> Promise<{ write(bytes), read(max) -> Promise<Uint8Array|null>, startTls(servername) -> Promise,
 * close() }>` sağlayıcısı üzerinden. TLS host'ta sonlanır (sertifika doğrulaması dahil). Node için varsayılan: `nodeTcp()`. Tarayıcıda ham soket yoktur (sağlayıcı verilmez).
 */
async function doTcp(req, streams, tcp) {
  const dec = new TextDecoder();
  const enc = new TextEncoder();
  const err = (id, e) => ({ ...failed(id, 0), body: enc.encode(String(e && e.message ? e.message : e)) });
  if (req.kind === 9) {
    const st = streams.get(req.stream);
    if (st) st.write(req.body);
    return null;
  }
  if (req.kind === 12) {
    const st = streams.get(req.stream);
    streams.delete(req.stream);
    if (st) st.close();
    return null;
  }
  if (req.kind === 10) {
    const st = streams.get(req.stream);
    if (!st) return { id: req.id, status: 1, errorKind: -1, headers: emptyBytes, body: emptyBytes };
    try {
      const chunk = await st.read(req.arg);
      if (chunk === null) return { id: req.id, status: 1, errorKind: -1, headers: emptyBytes, body: emptyBytes };
      return { id: req.id, status: 0, errorKind: -1, headers: emptyBytes, body: chunk };
    } catch (e) {
      return err(req.id, e);
    }
  }
  if (req.kind === 11) {
    const st = streams.get(req.stream);
    if (!st) return err(req.id, 'no such connection');
    try {
      // Seçenekler (`headers`): `alpn=h2`, `ca=<yol>`, `cert=<yol>`, `key=<yol>` satırları (v2.1.44).
      const opts = {};
      for (const line of String(req.headers).split('\n')) {
        const eq = line.indexOf('=');
        if (eq > 0) opts[line.slice(0, eq)] = line.slice(eq + 1);
      }
      await st.startTls(req.url, opts);
      return { id: req.id, status: 0, errorKind: -1, headers: emptyBytes, body: emptyBytes };
    } catch (e) {
      return err(req.id, e);
    }
  }
  // kind 8: aç ("host:port", method === "tls" ise bağlantı anında TLS)
  if (!tcp) return err(req.id, 'TCP is not available in this host');
  const colon = req.url.lastIndexOf(':');
  try {
    const sock = await tcp.connect(req.url.slice(0, colon), Number(req.url.slice(colon + 1)), req.method === 'tls');
    streams.set(req.id, sock);
    return { id: req.id, status: 0, errorKind: -1, headers: emptyBytes, body: emptyBytes };
  } catch (e) {
    return err(req.id, e);
  }
}

/** Node'un `net`/`tls` modüllerine dayanan varsayılan TCP sağlayıcısı (bkz. `doTcp`). */
export async function nodeTcp({ tlsFiles = false } = {}) {
  const net = await import('node:net');
  const tls = await import('node:tls');
  const fsmod = await import('node:fs');
  const wrap = (sock0) => {
    let sock = sock0;
    let queue = [];
    let ended = false;
    let error = null;
    let waiter = null;
    const wake = () => {
      if (waiter) {
        const w = waiter;
        waiter = null;
        w();
      }
    };
    const attach = (s) => {
      s.on('data', (d) => {
        queue.push(new Uint8Array(d));
        wake();
      });
      s.on('end', () => {
        ended = true;
        wake();
      });
      s.on('close', () => {
        ended = true;
        wake();
      });
      s.on('error', (e) => {
        error = e;
        ended = true;
        wake();
      });
    };
    attach(sock);
    return {
      write: (bytes) => {
        try {
          sock.write(bytes);
        } catch (e) {
          error = e;
        }
      },
      async read(max) {
        while (queue.length === 0 && !ended) await new Promise((r) => (waiter = r));
        if (queue.length === 0) {
          if (error) throw error;
          return null;
        }
        const head = queue[0];
        if (head.length <= max) return queue.shift();
        queue[0] = head.subarray(max);
        return head.subarray(0, max);
      },
      async startTls(servername, opts = {}) {
        // v2.1.44: ALPN `h2`, özel CA ve istemci sertifikası. Dosyaları host okur ve yalnızca `tlsFiles` izniyle (CLI `--allow-net` ile açar; gömen host varsayılan olarak kapalı).
        const extra = {};
        if (opts.alpn) extra.ALPNProtocols = [opts.alpn];
        if (opts.ca || opts.cert || opts.key) {
          if (!tlsFiles) throw new Error('TLS certificate files are not allowed by this host');
          if (opts.ca) extra.ca = fsmod.readFileSync(opts.ca);
          if (opts.cert) extra.cert = fsmod.readFileSync(opts.cert);
          if (opts.key) extra.key = fsmod.readFileSync(opts.key);
        }
        queue = [];
        sock.removeAllListeners('data');
        sock.removeAllListeners('end');
        sock.removeAllListeners('close');
        sock.removeAllListeners('error');
        const upgraded = await new Promise((resolve, reject) => {
          // Node, IP adresini SNI olarak kabul etmez; IP ile bağlanıldıysa sertifika adı doğrulaması IP SAN'ına göre yapılır.
          const t = tls.connect(net.isIP(servername) ? { socket: sock, ...extra } : { socket: sock, servername, ...extra }, () => {
            if (opts.alpn && t.alpnProtocol !== opts.alpn) {
              t.destroy();
              reject(new Error(`the server did not negotiate ${opts.alpn === 'h2' ? 'HTTP/2' : opts.alpn} (ALPN)`));
              return;
            }
            resolve(t);
          });
          t.once('error', reject);
        });
        sock = upgraded;
        ended = false;
        attach(sock);
      },
      close: () => sock.destroy(),
    };
  };
  return {
    connect: (host, port, useTls) =>
      new Promise((resolve, reject) => {
        const s = useTls ? tls.connect(net.isIP(host) ? { host, port } : { host, port, servername: host }, () => resolve(wrap(s))) : net.connect({ host, port }, () => resolve(wrap(s)));
        s.once('error', reject);
      }),
  };
}

/**
 * Alt süreç (kind 13, `process_wasm.zig`): `proc.run(program, args, cwd, timeoutMs) -> Promise<{ status, stdout, stderr }>` sağlayıcısı. Node için varsayılan: `nodeProcess()`
 * (`child_process.spawn`, KABUKSUZ: argümanlar kabuk yorumundan geçmez). Yetenek açıkça verilmedikçe kapalıdır.
 */
async function doProc(req, proc) {
  const enc = new TextEncoder();
  const err = (e) => ({ ...failed(req.id, 0), body: enc.encode(String(e && e.message ? e.message : e)) });
  if (!proc) return err('process capability is not available in this host');
  try {
    const args = req.body.length === 0 ? [] : new TextDecoder().decode(req.body).split('\0');
    const r = await proc.run(req.method, args, req.url, req.arg);
    return { id: req.id, status: r.status, errorKind: -1, headers: r.stderr, body: r.stdout };
  } catch (e) {
    return err(e);
  }
}

/** Node'un `child_process.spawn`ına dayanan varsayılan süreç sağlayıcısı (kabuksuz; çıktı tamponlanır; `timeoutMs > 0` aşılırsa süreç öldürülür ve hata verilir). */
export async function nodeProcess({ maxOutputBytes = 16 * 1024 * 1024 } = {}) {
  const cp = await import('node:child_process');
  return {
    run: (program, args, cwd, timeoutMs) =>
      new Promise((resolve, reject) => {
        const child = cp.spawn(program, args, { cwd: cwd || undefined, stdio: ['ignore', 'pipe', 'pipe'], shell: false });
        const out = [];
        const errc = [];
        let timedOut = false;
        let total = 0;
        let tooBig = false;
        const timer = timeoutMs > 0 ? setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, timeoutMs) : null;
        // stdout + stderr toplamı sınırlanır: sınırsız çıktı veren bir alt süreç host belleğini tüketemez.
        const collect = (list) => (d) => {
          total += d.length;
          if (total > maxOutputBytes) {
            tooBig = true;
            child.kill('SIGKILL');
            return;
          }
          list.push(d);
        };
        child.stdout.on('data', collect(out));
        child.stderr.on('data', collect(errc));
        child.on('error', (e) => { if (timer) clearTimeout(timer); reject(e); });
        child.on('close', (code) => {
          if (timer) clearTimeout(timer);
          if (tooBig) return reject(new Error(`process output exceeded ${maxOutputBytes} bytes`));
          if (timedOut) return reject(new Error('process timed out'));
          resolve({ status: code === null ? -1 : code, stdout: new Uint8Array(Buffer.concat(out)), stderr: new Uint8Array(Buffer.concat(errc)) });
        });
      }),
  };
}

/**
 * HTTP sunucusu (kind 14/15, `http_server_wasm.zig`; `nox.http.serve`): `serve.listen(port, handle) -> Promise<{ port, close() }>` sağlayıcısı; `handle(req) -> Promise<resp>` her gelen
 * isteği modüle iletir. `req` = { method, target, headers ("Ad: değer\n" metni), body (Uint8Array), peer }; `resp` = { status, headers (aynı metin), body }. Node için varsayılan:
 * `nodeHttpServer()` (`node:http`, varsayılan olarak yalnızca 127.0.0.1\'de dinler; `NOX_SERVE_HOST` ile değişir).
 */
export async function nodeHttpServer({ maxBodyBytes = 10 * 1024 * 1024, maxResponseBytes = 64 * 1024 * 1024, requestTimeoutMs = 30000, maxConcurrent = 64 } = {}) {
  const http = await import('node:http');
  return {
    listen: (port, handle) =>
      new Promise((resolve, reject) => {
        let active = 0;
        const reply = (res, status, text) => {
          if (res.writableEnded || res.headersSent) return;
          res.statusCode = status;
          res.setHeader('Connection', 'close');
          res.end(text);
        };
        const srv = http.createServer((req, res) => {
          // Kaynak kotaları: eşzamanlı istek sayısı, gövde boyutu, işleyici süresi, yanıt boyutu (aşıldığında 503/413/504/500).
          if (active >= maxConcurrent) {
            res.setHeader('Retry-After', '1');
            reply(res, 503, 'Service Unavailable');
            req.resume();
            return;
          }
          if (Number(req.headers['content-length'] || 0) > maxBodyBytes) {
            reply(res, 413, 'Payload Too Large');
            res.once('finish', () => req.destroy());
            return;
          }
          active++;
          let closed = false;
          res.once('close', () => {
            closed = true;
            active--;
          });
          const chunks = [];
          let received = 0;
          let rejected = false;
          req.on('data', (c) => {
            if (rejected) return;
            received += c.length;
            if (received > maxBodyBytes) {
              rejected = true;
              chunks.length = 0;
              reply(res, 413, 'Payload Too Large');
              res.once('finish', () => req.destroy());
              return;
            }
            chunks.push(c);
          });
          req.on('end', async () => {
            if (rejected || closed) return;
            let headers = '';
            for (let i = 0; i < req.rawHeaders.length; i += 2) headers += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\n`;
            const timer = setTimeout(() => reply(res, 504, 'Gateway Timeout'), requestTimeoutMs);
            try {
              const r = await handle({ method: req.method, target: req.url, headers, body: new Uint8Array(Buffer.concat(chunks)), peer: `${req.socket.remoteAddress}:${req.socket.remotePort}` });
              clearTimeout(timer);
              if (res.writableEnded || closed) return; // zaman aşımı ya da istemci kopması: yanıt atılır
              if (r.body.length > maxResponseBytes) return reply(res, 500, 'Response Too Large');
              res.statusCode = r.status;
              for (const line of r.headers.split('\n')) {
                const i = line.indexOf(': ');
                if (i > 0) res.appendHeader(line.slice(0, i), line.slice(i + 2));
              }
              res.end(Buffer.from(r.body));
            } catch {
              clearTimeout(timer);
              reply(res, 500, 'Internal Server Error');
            }
          });
        });
        srv.once('error', reject);
        srv.listen(port, process.env.NOX_SERVE_HOST || '127.0.0.1', () => resolve({ port: srv.address().port, close: () => srv.close() }));
      }),
  };
}


/**
 * Ağ izin listesi: `"host[:port],*.alan[:port]"` (port yoksa ya da `*` ise her port). Host adı, modülün verdiği haliyle eşlenir (DNS çözümlemesi sonrası IP denetimi YAPILMAZ: izinli bir adın
 * özel bir IP'ye çözülmesi operatörün sorumluluğundadır). `fetch` yönlendirmeleri elle izlenir ve her hedef yeniden denetlenir.
 */
export function netPolicy(spec) {
  const entries = (Array.isArray(spec) ? spec : String(spec).split(','))
    .map((x) => String(x).trim().toLowerCase())
    .filter(Boolean)
    .map((p) => {
      const m = /^(.*?)(?::(\d+|\*))?$/.exec(p);
      return { host: m[1].replace(/^\[|\]$/g, ''), port: m[2] === undefined || m[2] === '*' ? null : Number(m[2]) };
    });
  return {
    allows(host, port) {
      const h = String(host).toLowerCase().replace(/\.$/, '').replace(/^\[|\]$/g, '');
      return entries.some((e) => (e.port === null || e.port === Number(port)) && (e.host === '*' || e.host === h || (e.host.startsWith('*.') && h.endsWith(e.host.slice(1)) && h.length > e.host.length - 1)));
    },
  };
}

function urlPort(u) {
  return u.port ? Number(u.port) : u.protocol === 'https:' || u.protocol === 'wss:' ? 443 : 80;
}

export function restrictFetch(fetchFn, policy) {
  return async (url, init = {}) => {
    let cur = new URL(url);
    let opts = { ...init };
    const follow = (init.redirect ?? 'follow') === 'follow';
    for (let hop = 0; hop < 10; hop++) {
      if (!policy.allows(cur.hostname, urlPort(cur))) throw new TypeError(`network policy: ${cur.host} is not in the allowed list`);
      const res = await fetchFn(cur.href, { ...opts, redirect: 'manual' });
      const loc = res.headers.get('location');
      if (follow && res.status >= 300 && res.status < 400 && loc) {
        cur = new URL(loc, cur);
        if (res.status === 303 || ((res.status === 301 || res.status === 302) && String(opts.method || 'GET').toUpperCase() === 'POST')) {
          opts = { ...opts, method: 'GET', body: undefined };
        }
        continue;
      }
      return res;
    }
    throw new TypeError('network policy: too many redirects');
  };
}

export function restrictTcp(tcp, policy) {
  return {
    ...tcp,
    connect: (host, port, useTls) => (policy.allows(host, port) ? tcp.connect(host, port, useTls) : Promise.reject(new Error(`network policy: ${host}:${port} is not in the allowed list`))),
  };
}

export function restrictWebSocket(Ctor, policy) {
  if (!Ctor) return Ctor;
  return class extends Ctor {
    constructor(url, ...rest) {
      const u = new URL(url);
      if (!policy.allows(u.hostname, urlPort(u))) throw new Error(`network policy: ${u.host} is not in the allowed list`);
      super(url, ...rest);
    }
  };
}

/** Alt süreç izin listesi: yalnızca listedeki program adları (ya da mutlak yollar) çalıştırılabilir; program, modülün verdiği haliyle eşlenir. */
export function restrictProcess(proc, allowed) {
  const set = new Set((Array.isArray(allowed) ? allowed : String(allowed).split(',')).map((x) => String(x).trim()).filter(Boolean));
  return {
    ...proc,
    run: (program, ...rest) => (set.has(program) ? proc.run(program, ...rest) : Promise.reject(new Error(`process policy: '${program}' is not in the allowed list`))),
  };
}

const SERVER_EVENT = Symbol('server-event');

/** `http_listen` (kind 14): sağlayıcıdan bir dinleyici açar; gerçek port `status` alanında döner. */
async function doListen(req, server) {
  if (!server.provider) return { ...failed(req.id, 0), body: new TextEncoder().encode('serve capability is not available in this host') };
  try {
    const l = await server.provider.listen(req.arg, (r) => {
      return new Promise((resolve) => {
        const id = server.nextId++;
        server.pending.set(id, resolve);
        server.queue.push({ id, ...r });
        if (server.waiter) server.waiter();
      });
    });
    server.listeners.set(req.id, l);
    return { id: req.id, status: l.port, errorKind: -1, headers: emptyBytes, body: emptyBytes };
  } catch (e) {
    return { ...failed(req.id, 0), body: new TextEncoder().encode(String(e && e.message ? e.message : e)) };
  }
}

/** Askıdaki modülün yeni isteklerini başlatır, bir tanesi bitene kadar bekler ve sonucunu modüle iletir. */
async function pumpFetches(instance, fetchFn, inflight, streams, wsCtor, tcpImpl, procImpl, server) {
  const x = instance.exports;
  const mem = x.memory;
  const lenPtr = x.nox_host_alloc(4);
  const ptr = x.nox_host_fetch_pending(lenPtr);
  const len = new DataView(mem.buffer).getUint32(lenPtr, true);
  const pending = ptr ? parsePendingRequests(new Uint8Array(mem.buffer, ptr, len).slice()) : [];
  if (ptr) x.nox_host_free(ptr, len);
  x.nox_host_free(lenPtr, 4);
  for (const req of pending) {
    if (req.kind === 0) {
      inflight.set(req.id, doFetch(fetchFn, req));
    } else if (req.kind === 14) {
      inflight.set(req.id, doListen(req, server));
    } else if (req.kind === 15) {
      const l = server.listeners.get(req.stream);
      server.listeners.delete(req.stream);
      if (l) l.close();
    } else if (req.kind === 13) {
      inflight.set(req.id, doProc(req, procImpl));
    } else if (req.kind >= 8) {
      const p = doTcp(req, streams, tcpImpl);
      if (req.kind === 8 || req.kind === 10 || req.kind === 11) inflight.set(req.id, p);
      else p.catch(() => {});
    } else if (req.kind >= 4) {
      const p = doSocket(req, streams, wsCtor);
      if (req.kind === 4 || req.kind === 6) inflight.set(req.id, p);
      else p.catch(() => {});
    } else {
      const p = doStream(fetchFn, req, streams);
      if (req.kind !== 3) inflight.set(req.id, p);
      else p.catch(() => {});
    }
  }
  // Sunucu: tamamlanan yanıtları host\'a ver, kuyruktaki istekleri modüle ilet.
  if (typeof x.nox_host_http_take_responses === 'function') {
    const rl = x.nox_host_alloc(4);
    const rp = x.nox_host_http_take_responses(rl);
    const rn = new DataView(mem.buffer).getUint32(rl, true);
    const rb = rp ? new Uint8Array(mem.buffer, rp, rn).slice() : emptyBytes;
    if (rp) x.nox_host_free(rp, rn);
    x.nox_host_free(rl, 4);
    const rdv = new DataView(rb.buffer, rb.byteOffset, rb.byteLength);
    for (let i = 0; i < rb.length; ) {
      const id = rdv.getUint32(i, true);
      const status = rdv.getUint32(i + 4, true);
      const hl = rdv.getUint32(i + 8, true);
      const headers = new TextDecoder().decode(rb.subarray(i + 12, i + 12 + hl));
      const bl = rdv.getUint32(i + 12 + hl, true);
      const body = rb.slice(i + 16 + hl, i + 16 + hl + bl);
      i += 16 + hl + bl;
      const resolve = server.pending.get(id);
      server.pending.delete(id);
      if (resolve) resolve({ status, headers, body });
    }
    if (server.stopRequested) {
      x.nox_host_http_stop();
      for (const l of server.listeners.values()) l.close();
      server.listeners.clear();
      return;
    }
    if (server.queue.length > 0) {
      const enc = new TextEncoder();
      const putB = (b) => {
        const p = x.nox_host_alloc(b.length);
        new Uint8Array(mem.buffer, p, b.length).set(b);
        return [p, b.length];
      };
      while (server.queue.length > 0) {
        const q = server.queue.shift();
        const fields = [enc.encode(q.method), enc.encode(q.target), enc.encode(q.headers), q.body, enc.encode(q.peer)].map(putB);
        x.nox_host_http_dispatch(q.id, ...fields.flat());
        for (const [p, n] of fields) x.nox_host_free(p, n);
      }
      return; // modül sürdürülüp istekleri işlesin
    }
  }
  const serverEvent = server.listeners.size > 0 ? new Promise((res) => (server.waiter = () => res(SERVER_EVENT))) : null;
  if (inflight.size === 0 && !serverEvent) {
    if (pending.length === 0) throw new Error('nox: program host için askıda ama bekleyen istek yok');
    return; // yalnızca yanıtsız (kapatma) istekleri vardı: bekleyecek bir şey yok, programı sürdür
  }
  const racers = [...inflight.entries()].map(([id, p]) => p.then((r) => r));
  if (serverEvent) racers.push(serverEvent);
  const done = await Promise.race(racers);
  server.waiter = null;
  if (done === SERVER_EVENT) return;
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

// ---- Ağ: iş parçacıklı modüller (`--threads`, spec §3.355) --------------------------------------------------------------------------------------------
// Bir wasm iş parçacığı `nox_host.net_fetch` içinde BLOKE olur; sonuç eşzamanlı alınır. Tarayıcı Worker'ında eşzamanlı XHR, Node'da yardımcı bir Worker (fetch'i o çalıştırır,
// çağıran `Atomics.wait` ile bekler ve sonucu `receiveMessageOnPort` ile alır) kullanılır. Host yeteneği vermezse `syncFetch` null'dır ve `net_fetch` -1 döner (HttpCapabilityError).

/** `net_fetch`/`net_read` import'ları. `syncFetch(req) -> { status, errorKind, headers, body }` (eşzamanlı) ya da null. */
function makeNetImports(syncFetch, getMemory) {
  let last = null;
  return {
    net_fetch: (ptr, len) => {
      if (!syncFetch) return -1;
      const req = parsePendingRequests(new Uint8Array(getMemory().buffer, ptr, len).slice())[0];
      const r = syncFetch(req);
      if (r.errorKind >= 0) return r.errorKind === 1 ? -3 : r.errorKind === 0 ? -2 : -4;
      const out = new Uint8Array(8 + r.headers.length + r.body.length);
      const dv = new DataView(out.buffer);
      dv.setUint32(0, r.status, true);
      dv.setUint32(4, r.headers.length, true);
      out.set(r.headers, 8);
      out.set(r.body, 8 + r.headers.length);
      last = out;
      return out.length;
    },
    net_read: (ptr, cap) => {
      if (!last) return 0;
      const n = Math.min(cap, last.length);
      new Uint8Array(getMemory().buffer, ptr, n).set(last.subarray(0, n));
      last = null;
      return n;
    },
  };
}

/** Tarayıcı Worker'ı: eşzamanlı XHR (Worker'larda izinlidir; `responseType` ve `timeout` desteklenir). */
function xhrSync(req) {
  const x = new XMLHttpRequest();
  try {
    x.open(req.method, req.url, false);
    if (req.arg > 0) x.timeout = req.arg;
    x.responseType = 'arraybuffer';
    for (const [k, v] of Object.entries(parseHeaderLines(req.headers))) {
      try {
        x.setRequestHeader(k, v);
      } catch {}
    }
    x.send(req.hasBody ? req.body : null);
  } catch (e) {
    return failed(req.id, e && e.name === 'TimeoutError' ? 1 : 0);
  }
  if (x.status === 0) return failed(req.id, 0);
  const headers = new TextEncoder().encode(x.getAllResponseHeaders().replace(/\r\n/g, '\n'));
  return { id: req.id, status: x.status, errorKind: -1, headers, body: new Uint8Array(x.response) };
}

/** Node: bu iş parçacığına özel bir yardımcı Worker (tembel) fetch'i çalıştırır. */
function makeNodeSyncFetch(wt) {
  let st = null;
  return (req) => {
    if (!st) {
      const { port1, port2 } = new wt.MessageChannel();
      const cell = new Int32Array(new SharedArrayBuffer(4));
      const w = new wt.Worker(new URL(import.meta.url), { workerData: { netHelper: true, port: port2, cell }, transferList: [port2] });
      w.unref();
      st = { port1, cell, w };
    }
    Atomics.store(st.cell, 0, 0);
    st.port1.postMessage(req);
    Atomics.wait(st.cell, 0, 0);
    const m = wt.receiveMessageOnPort(st.port1);
    return m ? m.message : failed(req.id, 2);
  };
}

/** Yardımcı Worker gövdesi (Node). */
async function netHelperMain() {
  const { workerData } = await import('node:worker_threads');
  const { port, cell } = workerData;
  port.on('message', async (req) => {
    const r = await doFetch(globalThis.fetch.bind(globalThis), req);
    port.postMessage(r);
    Atomics.store(cell, 0, 1);
    Atomics.notify(cell, 0);
  });
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
  if (asyncHost && (fetchFn || opts.tcp || opts.process || opts.serve)) x.nox_host_caps_set((fetchFn ? 1 : 0) | (opts.tcp ? 2 : 0) | (opts.process ? 4 : 0) | (opts.serve ? 8 : 0));
  let code = 0;
  const streams = new Map();
  const server = { provider: opts.serve || null, queue: [], pending: new Map(), listeners: new Map(), nextId: 1, waiter: null, stopRequested: false };
  if (opts.serveSignal) opts.serveSignal.addEventListener('abort', () => { server.stopRequested = true; if (server.waiter) server.waiter(); });
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
      await pumpFetches(instance, (fetchFn || globalThis.fetch).bind(globalThis), inflight, streams, opts.WebSocket === undefined ? globalThis.WebSocket : opts.WebSocket, opts.tcp || null, opts.process || null, server);
      step = () => x.nox_host_resume();
    }
  } finally {
    // Program çıkarken kapatılmamış akışlar/soketler/WebSocket'ler bırakılır (aksi halde Node olay döngüsü açık kalır).
    for (const st of streams.values()) {
      try {
        if (st.close) st.close();
        else if (st.ws) st.ws.close();
        else if (st.reader) st.reader.cancel().catch(() => {});
      } catch {}
    }
    for (const l of server.listeners.values()) l.close();
    streams.clear();
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
      // Kök altında (hedef dahil) bir sembolik bağ varsa, yazma/silme kök dışına taşabilir: bu yollar atlanır (yükleme zaten sembolik bağları atlar).
      const underSymlink = (rel) => {
        let cur = root;
        for (const part of rel.split('/').slice(1)) {
          cur = pathMod.join(cur, part);
          let st;
          try {
            st = fs.lstatSync(cur);
          } catch {
            return false; // yok: altındaki hiçbir bileşen bağ olamaz
          }
          if (st.isSymbolicLink()) return true;
        }
        return false;
      };
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
        if (underSymlink(rel)) continue;
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
        if (underSymlink(rel)) {
          process.stderr.write(`nox: --vfs-dir: '${rel}' bir sembolik bağın altında, kaydedilmedi\n`);
          continue;
        }
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
  let allowProcess = process.env.NOX_ALLOW_PROCESS === '1';
  let allowServe = process.env.NOX_ALLOW_SERVE === '1';
  let netAllow = process.env.NOX_NET_ALLOW || null;
  let processAllow = process.env.NOX_PROCESS_ALLOW || null;
  const rest = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith('--vfs-dir=')) dir = a.slice('--vfs-dir='.length);
    else if (a === '--vfs-dir' && i + 1 < args.length) dir = args[++i];
    else if (a === '--allow-net') allowNet = true;
    else if (a === '--allow-process') allowProcess = true;
    else if (a.startsWith('--allow-process=')) {
      allowProcess = true;
      processAllow = a.slice('--allow-process='.length);
    } else if (a.startsWith('--net-allow=')) netAllow = a.slice('--net-allow='.length);
    else if (a === '--allow-serve') allowServe = true;
    else rest.push(a);
  }
  return { dir, allowNet, allowProcess, allowServe, netAllow, processAllow, rest };
}

/** SIGINT/SIGTERM'de zarif kapanış için AbortSignal (sunucu modülü `serve` döngüsünden çıkar, program normal biter). */
function shutdownSignal() {
  const ctrl = new AbortController();
  for (const sig of ['SIGINT', 'SIGTERM']) process.once(sig, () => ctrl.abort());
  return ctrl.signal;
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
  const { dir: vfsDir, allowNet, allowProcess, allowServe, netAllow, processAllow, rest: progArgs } = takeHostFlags(argv.slice(3));
  const mod = await WebAssembly.compile(bytes);
  const modules = new Set(WebAssembly.Module.imports(mod).map((i) => i.module));

  if (modules.has('nox_host')) {
    const memImportNox = findMemoryImport(bytes);
    if (memImportNox && memImportNox.shared) {
      if (netAllow) {
        console.error('nox: --net-allow is not supported with shared-memory (--threads) modules; use the asyncify target');
        process.exit(2);
      }
      process.exitCode = await runThreaded(file, mod, memImportNox, progArgs, 'nox', vfsDir, allowNet);
      return;
    }
    let vfs;
    if (vfsDir) {
      const nv = await makeNodeVfs(vfsDir);
      vfs = { files: nv.load(), onSave: (snap) => nv.save(snap) };
    }
    const np = netAllow ? netPolicy(netAllow) : null;
    let tcpImpl = allowNet ? await nodeTcp({ tlsFiles: true }) : null;
    let procImpl = allowProcess ? await nodeProcess() : null;
    let fetchImpl = allowNet ? globalThis.fetch : null;
    let wsImpl = globalThis.WebSocket;
    if (np) {
      if (fetchImpl) fetchImpl = restrictFetch(fetchImpl.bind(globalThis), np);
      if (tcpImpl) tcpImpl = restrictTcp(tcpImpl, np);
      wsImpl = restrictWebSocket(wsImpl, np);
    }
    if (processAllow && procImpl) procImpl = restrictProcess(procImpl, processAllow);
    process.exitCode = await runNox(bytes, await makeNodeIo(), { vfs, fetch: fetchImpl, WebSocket: wsImpl, tcp: tcpImpl, process: procImpl, serve: allowServe ? await nodeHttpServer() : null, serveSignal: allowServe ? shutdownSignal() : undefined });
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
async function runThreaded(file, mod, memImport, args, kind = 'wasi', vfsDir = null, allowNet = false) {
  const { Worker } = await import('node:worker_threads');
  const memory = new WebAssembly.Memory({ initial: memImport.min, maximum: memImport.max ?? memImport.min, shared: true });
  const chan = new BroadcastChannel(EXIT_CHANNEL);
  const done = new Promise((resolve) => {
    chan.onmessage = (ev) => resolve(ev.data.exit);
  });
  const w = new Worker(new URL(import.meta.url), { workerData: { main: true, kind, mod, memory, tid: 0, arg: 0, file, args, vfsDir, allowNet, tids: new Int32Array(new SharedArrayBuffer(4)) }, argv: [file] });
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
async function instantiateNoxThread(mod, memory, io, spawnThread, exitAll, beforeExit = null, syncFetch = null) {
  const host = createHost(io, memory);
  Object.assign(host.imports.nox_host, makeNetImports(syncFetch, () => memory));
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
  const { mod, memory, tid, arg, file, args, tids, kind, vfsDir, allowNet } = workerData;
  let vfsLoaded = workerData.vfsLoaded;
  const chan = new BroadcastChannel(EXIT_CHANNEL);
  const exitAll = (code) => {
    chan.postMessage({ exit: code });
    chan.close();
  };
  const spawnThread = (a) => {
    const t = Atomics.add(tids, 0, 1) + 1; // iş parçacıkları arasında benzersiz, > 0
    const w = new Worker(new URL(import.meta.url), { workerData: { main: false, kind, mod, memory, tid: t, arg: a, file, args, tids, vfsDir, vfsLoaded, allowNet }, argv: [file] });
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
    const wtMod = allowNet ? await import('node:worker_threads') : null;
    inst = await instantiateNoxThread(mod, memory, await makeNodeIo(), spawnThread, exitAll, saveVfs, allowNet ? makeNodeSyncFetch(wtMod) : null);
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
    // `finalizeBindings` yeni Node sürümlerindedir (v24.4+); eskilerde bellek, `_initialize` dışa aktarımı olan bir örnek yüzeyiyle verilir.
    if (typeof wasi.finalizeBindings === 'function') wasi.finalizeBindings(inst, { memory });
    else wasi.initialize({ exports: { memory, _initialize() {} } });
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
export async function runNoxThreads(wasmBytes, io, { workerUrl = import.meta.url, vfs = null, net = false } = {}) {
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
    w.postMessage({ noxThread: { main, mod, memory, tid, arg, tids, vfs: !!vfs, vfsFiles: main && vfs ? vfs.files : undefined, net: !!net } });
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
async function browserWorkerMain({ main, mod, memory, tid, arg, tids, vfs, vfsFiles, net }) {
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
    const inst = await instantiateNoxThread(mod, memory, io, spawnThread, (code) => exitAll(code), null, net ? xhrSync : null);
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
  if (wt && !wt.isMainThread && wt.workerData && wt.workerData.netHelper) {
    await netHelperMain();
  } else if (wt && !wt.isMainThread && wt.workerData && wt.workerData.tid !== undefined && wt.workerData.mod) {
    await workerMain();
  } else if (import.meta.url === new URL(`file://${process.argv[1]}`).href) {
    await nodeMain();
  }
}
