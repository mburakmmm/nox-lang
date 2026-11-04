// `wasm32-freestanding --asyncify` + `nox.http` testi için sürücü (spec §3.351). Gerçek ağ yok: `opts.fetch` ile süreç içi sahte bir `fetch` verilir, böylece protokol
// (askıya alma, paralel istekler, zaman aşımı, hata eşlemesi, yetenek reddi) deterministik sınanır. Kullanım: node wasm_fetch_driver.mjs prog.wasm allow|deny
import fs from 'node:fs';
import { runNox } from '../../compiler/wasm_host.mjs';

const mode = process.argv[3] ?? 'allow';
const calls = [];
const active = { n: 0, max: 0 };

const fakeFetch = async (url, init) => {
  const u = new URL(url);
  const body = init.body ? new TextDecoder().decode(init.body) : '-';
  calls.push(`${init.method} ${u.pathname} x-test=${init.headers['X-Test'] ?? '-'} body=${body}`);
  active.n++;
  active.max = Math.max(active.max, active.n);
  try {
    if (u.pathname === '/chunks' || u.pathname === '/stall') {
      // Akışlı yanıt: /chunks üç parça verip biter, /stall bir parça verip sonsuza dek bekler (boşta kalma zaman aşımı sınanır).
      const parts = u.pathname === '/chunks' ? ['aaaa', 'bbbbbb', 'cc'] : ['first'];
      let n = 0;
      const stream = new ReadableStream({
        async pull(controller) {
          if (n < parts.length) {
            await new Promise((r) => setTimeout(r, 10));
            controller.enqueue(new TextEncoder().encode(parts[n++]));
          } else if (u.pathname === '/chunks') {
            controller.close();
          } else {
            await new Promise((_, rej) => init.signal && init.signal.addEventListener('abort', () => rej(init.signal.reason)));
          }
        },
      });
      return new Response(stream, { status: 200, headers: { 'x-reply': 'streamed' } });
    }
    if (u.pathname === '/slow') await new Promise((r) => setTimeout(r, 100));
    if (u.pathname === '/refuse') throw new TypeError('fetch failed');
    if (u.pathname === '/timeout') await new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(init.signal.reason)));
    const status = u.pathname === '/missing' ? 404 : 200;
    return new Response(`${init.method}:${u.pathname}:${body}`, { status, headers: { 'content-type': 'text/plain', 'x-reply': 'yes' } });
  } finally {
    active.n--;
  }
};

// Süreç içi sahte WebSocket: /echo her iletiyi "echo:<ileti>" olarak geri yollar, /close-after-2 iki ileti yollayıp kapanır, /refuse bağlanamaz.
const wsLog = [];
class FakeWebSocket {
  constructor(url) {
    this.url = url;
    this.path = new URL(url.replace(/^ws/, 'http')).pathname;
    wsLog.push(`open ${url}`);
    setTimeout(() => {
      if (this.path === '/refuse') return this.onerror && this.onerror(new Error('refused'));
      this.onopen && this.onopen();
      if (this.path === '/close-after-2') {
        setTimeout(() => this.onmessage && this.onmessage({ data: 'a' }), 5);
        setTimeout(() => this.onmessage && this.onmessage({ data: 'b' }), 10);
        setTimeout(() => this.onclose && this.onclose(), 15);
      }
    }, 5);
  }
  send(data) {
    wsLog.push(`send ${data}`);
    if (this.path === '/echo') setTimeout(() => this.onmessage && this.onmessage({ data: `echo:${data}` }), 5);
  }
  close() {
    wsLog.push('close');
  }
}

const out = [];
const io = {
  write: (fd, b) => {
    out.push(new TextDecoder().decode(b));
    return b.length;
  },
  read: () => 0,
  clockMs: () => Date.now(),
  randomFill: (b) => crypto.getRandomValues(b),
  sleepMs: () => {},
};
// `AbortSignal.timeout` zamanlayıcısı Node'da unref edilir; bekleyen bir söz tek başına olay döngüsünü açık tutmaz.
const keepAlive = setInterval(() => {}, 1000);
const code = await runNox(fs.readFileSync(process.argv[2]), io, mode === 'deny' ? { fetch: null } : { fetch: fakeFetch, WebSocket: FakeWebSocket });
clearInterval(keepAlive);
process.stdout.write(out.join(''));
console.log(`exit ${code}`);
console.log(`max concurrent ${active.max}`);
for (const c of calls.sort()) console.log(`fetch ${c}`);
for (const w of wsLog) console.log(`ws ${w}`);
