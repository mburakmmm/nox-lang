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
    if (u.pathname === '/slow') await new Promise((r) => setTimeout(r, 100));
    if (u.pathname === '/refuse') throw new TypeError('fetch failed');
    if (u.pathname === '/timeout') await new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(init.signal.reason)));
    const status = u.pathname === '/missing' ? 404 : 200;
    return new Response(`${init.method}:${u.pathname}:${body}`, { status, headers: { 'content-type': 'text/plain', 'x-reply': 'yes' } });
  } finally {
    active.n--;
  }
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
const code = await runNox(fs.readFileSync(process.argv[2]), io, mode === 'deny' ? { fetch: null } : { fetch: fakeFetch });
clearInterval(keepAlive);
process.stdout.write(out.join(''));
console.log(`exit ${code}`);
console.log(`max concurrent ${active.max}`);
for (const c of calls.sort()) console.log(`fetch ${c}`);
