// Host güvenlik politikaları (spec §3.362): ağ/süreç izin listeleri ve `nodeHttpServer` kaynak kotaları. WASM modülü gerekmez; `wasm_host.mjs` sağlayıcıları doğrudan sınanır.
// Kullanım: node wasm_policy_driver.mjs <wasm_host.mjs>
import assert from 'node:assert/strict';
import http from 'node:http';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const host = await import(pathToFileURL(path.resolve(process.argv[2])).href);
const { netPolicy, restrictFetch, restrictTcp, restrictProcess, restrictWebSocket, nodeHttpServer, nodeProcess } = host;

// --- ağ izin listesi ---
const np = netPolicy('db.internal:5432, *.example.com, api.test:*, 127.0.0.1:8080');
assert.equal(np.allows('db.internal', 5432), true);
assert.equal(np.allows('db.internal', 5433), false);
assert.equal(np.allows('DB.INTERNAL.', 5432), true);
assert.equal(np.allows('a.example.com', 443), true);
assert.equal(np.allows('example.com', 443), false, '*.example.com apex alan adını kapsamaz');
assert.equal(np.allows('evilexample.com', 443), false);
assert.equal(np.allows('api.test', 9999), true);
assert.equal(np.allows('127.0.0.1', 8080), true);
assert.equal(np.allows('10.0.0.1', 80), false);

// fetch: izinsiz host reddedilir; yönlendirme izinsiz bir hedefe giderse reddedilir; izinli yönlendirme izlenir.
const calls = [];
const fake = async (url, init) => {
  calls.push(`${init.method || 'GET'} ${url}`);
  if (url.startsWith('http://a.example.com/redir-bad')) return new Response(null, { status: 302, headers: { location: 'http://10.0.0.1/secret' } });
  if (url.startsWith('http://a.example.com/redir-ok')) return new Response(null, { status: 302, headers: { location: 'http://b.example.com/final' } });
  return new Response('ok', { status: 200 });
};
const rf = restrictFetch(fake, np);
await assert.rejects(rf('http://10.0.0.1/'), /network policy/);
await assert.rejects(rf('http://a.example.com/redir-bad'), /network policy: 10\.0\.0\.1/);
assert.equal(await (await rf('http://a.example.com/redir-ok')).text(), 'ok');
assert.ok(calls.includes('GET http://b.example.com/final'));
assert.ok(!calls.some((c) => c.includes('10.0.0.1')), 'izinsiz hedefe istek gönderilmemeli');

// tcp / websocket / process
const tcp = restrictTcp({ connect: async (h, p) => `${h}:${p}` }, np);
assert.equal(await tcp.connect('db.internal', 5432, false), 'db.internal:5432');
await assert.rejects(tcp.connect('db.internal', 22, false), /network policy/);
class FakeWS { constructor(u) { this.url = u; } }
const RWS = restrictWebSocket(FakeWS, np);
assert.equal(new RWS('wss://a.example.com/x').url, 'wss://a.example.com/x');
assert.throws(() => new RWS('ws://10.0.0.1/x'), /network policy/);
const proc = restrictProcess({ run: async (p) => `ran ${p}` }, 'git,/usr/bin/env');
assert.equal(await proc.run('git', [], '', 0), 'ran git');
await assert.rejects(proc.run('rm', [], '', 0), /process policy/);
await assert.rejects(proc.run('/bin/git', [], '', 0), /process policy/);

// süreç çıktı sınırı
const np2 = await nodeProcess({ maxOutputBytes: 1000 });
await assert.rejects(np2.run(process.execPath, ['-e', "process.stdout.write('x'.repeat(100000))"], '', 0), /output exceeded/);
const small = await np2.run(process.execPath, ['-e', "process.stdout.write('hi')"], '', 0);
assert.equal(new TextDecoder().decode(small.stdout), 'hi');

// --- HTTP sunucu kotaları ---
function request(port, { method = 'GET', body = null, path: p = '/' } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path: p, agent: false }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString() }));
    });
    req.on('error', (e) => resolve({ status: 0, error: e.code }));
    if (body) req.write(body);
    req.end();
  });
}
const srvProvider = await nodeHttpServer({ maxBodyBytes: 100, maxResponseBytes: 50, requestTimeoutMs: 300, maxConcurrent: 2 });
let release = null;
const gate = new Promise((r) => (release = r));
const l = await srvProvider.listen(0, async (req) => {
  if (req.target === '/slow') await gate;
  if (req.target === '/hang') await new Promise(() => {});
  if (req.target === '/big') return { status: 200, headers: '', body: new Uint8Array(51) };
  return { status: 200, headers: 'X-Test: 1\n', body: new TextEncoder().encode(`echo:${req.body.length}`) };
});
assert.deepEqual(await request(l.port, { method: 'POST', body: 'x'.repeat(10) }), { status: 200, body: 'echo:10' });
const big = await request(l.port, { method: 'POST', body: 'x'.repeat(101) });
assert.ok(big.status === 413 || big.status === 0, `govde siniri: ${big.status}`);
assert.equal((await request(l.port, { path: '/big' })).status, 500);
assert.equal((await request(l.port, { path: '/hang' })).status, 504);
// eşzamanlılık: iki yavaş istek slotları doldurur, üçüncü 503 alır
const s1 = request(l.port, { path: '/slow' });
const s2 = request(l.port, { path: '/slow' });
await new Promise((r) => setTimeout(r, 100));
assert.equal((await request(l.port, { path: '/third' })).status, 503);
release();
assert.equal((await s1).status, 200);
assert.equal((await s2).status, 200);
l.close();
console.log('policy ok');
process.exit(0);
