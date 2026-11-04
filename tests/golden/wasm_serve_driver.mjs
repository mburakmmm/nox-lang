// `wasm32-freestanding --asyncify` + `nox.http.serve` testi için sürücü (spec §3.360): modül HOST sunucusuyla (`nodeHttpServer`, gerçek `node:http`) çalışır; sürücü istemci olarak
// gerçek HTTP istekleri yollar (sıralı, paralel, handler'ın `nox.http.get` ile süreç içi sahte upstream'e gitmesi, 404, çoklu Set-Cookie), sonra zarifçe kapatır.
// Kullanım: node wasm_serve_driver.mjs prog.wasm
import fs from 'node:fs';
import { runNox, nodeHttpServer } from '../../compiler/wasm_host.mjs';

const ctrl = new AbortController();
const base = await nodeHttpServer();
let port = 0;
const serve = {
  listen: async (p, h) => {
    const l = await base.listen(p, h);
    port = l.port;
    setImmediate(client);
    return l;
  },
};
const lines = [];
const log = (...a) => lines.push(a.join(' '));
async function client() {
  const url = (p) => `http://127.0.0.1:${port}${p}`;
  const r1 = await fetch(url('/echo'), { method: 'POST', body: 'hello', headers: { 'user-agent': 'tester' } });
  log('echo', r1.status, await r1.text(), r1.headers.get('x-echo-method'), JSON.stringify(r1.headers.getSetCookie()));
  const r2 = await fetch(url('/nope'));
  log('missing', r2.status, await r2.text());
  const r3 = await fetch(url('/proxy'));
  log('proxy', r3.status, await r3.text());
  const many = await Promise.all([1, 2, 3, 4].map((i) => fetch(url('/echo'), { method: 'POST', body: `p${i}`, headers: { 'user-agent': 'u' } }).then((r) => r.text())));
  log('parallel', many.sort().join(' | '));
  ctrl.abort();
}
const upstream = [];
const fakeFetch = async (u) => {
  upstream.push(String(u));
  await new Promise((r) => setTimeout(r, 20));
  return new Response('UPSTREAM-DATA', { status: 200 });
};
const out = [];
const io = { write: (fd, b) => { if (fd === 1) out.push(new TextDecoder().decode(b)); return b.length; }, read: () => 0, clockMs: (k) => (k === 0 ? Date.now() : performance.now()), randomFill: (b) => crypto.getRandomValues(b), sleepMs: () => {} };
const keepAlive = setInterval(() => {}, 1000);
const code = await runNox(fs.readFileSync(process.argv[2]), io, { serve, serveSignal: ctrl.signal, fetch: fakeFetch });
clearInterval(keepAlive);
process.stdout.write(out.join(''));
for (const l of lines) console.log(l);
console.log(`exit ${code}`);
for (const u of upstream) console.log(`upstream ${u}`);
