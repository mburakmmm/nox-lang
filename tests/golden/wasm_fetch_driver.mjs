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
    if (u.pathname === '/dns-query') {
      // DoH (`application/dns-json`) sahte çözümleyici: a.example -> A, v6.example -> AAAA, both.example -> ikisi, bozuk.example -> JSON olmayan gövde, diğerleri NXDOMAIN (Status 3).
      const name = u.searchParams.get('name');
      const type = u.searchParams.get('type');
      const table = { 'a.example': { A: '192.0.2.7' }, 'v6.example': { AAAA: '2001:db8::7' }, 'both.example': { A: '192.0.2.9', AAAA: '2001:db8::9' } };
      if (name === 'bozuk.example') return new Response('<html>', { status: 200 });
      if (name === 'slow.example') await new Promise((_, rej) => init.signal && init.signal.addEventListener('abort', () => rej(init.signal.reason)));
      const hit = table[name] && table[name][type];
      const answer = hit ? [{ name, type: type === 'A' ? 1 : 28, TTL: 60, data: hit }] : [];
      return new Response(JSON.stringify({ Status: hit || table[name] ? 0 : 3, Answer: answer }), { status: 200, headers: { 'content-type': 'application/dns-json' } });
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

// Süreç içi sahte süreç sağlayıcısı: "echo-tool" argümanlarını stdout'a yazar, "fails" 3 ile çıkar, "missing" bulunamaz, "slow" zaman aşımına uğrar.
const procLog = [];
const fakeProc = {
  async run(program, args, cwd, timeoutMs) {
    procLog.push(`${program} [${args.join('|')}] cwd=${cwd || '-'} timeout=${timeoutMs}`);
    const enc = new TextEncoder();
    if (program === 'missing') throw new Error('spawn missing ENOENT');
    if (program === 'slow') {
      await new Promise((r) => setTimeout(r, 50));
      throw new Error('process timed out');
    }
    if (program === 'fails') return { status: 3, stdout: enc.encode('partial'), stderr: enc.encode('boom') };
    return { status: 0, stdout: enc.encode(args.join(',')), stderr: enc.encode('warn') };
  },
};

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
const code = await runNox(fs.readFileSync(process.argv[2]), io, mode === 'deny' ? { fetch: null } : { fetch: fakeFetch, WebSocket: FakeWebSocket, process: fakeProc });
clearInterval(keepAlive);
process.stdout.write(out.join(''));
console.log(`exit ${code}`);
console.log(`max concurrent ${active.max}`);
for (const c of calls.sort()) console.log(`fetch ${c}`);
for (const w of wsLog) console.log(`ws ${w}`);
for (const p of procLog) console.log(`proc ${p}`);
