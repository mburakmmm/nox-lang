// `wasm32-freestanding --asyncify` + `nox.redis` (v2.1.45): GERÇEK `redis-server` süreçlerine karşı, yerel `redis_program.nox.in` programının AYNISI wasm'a derlenip host TCP üzerinden çalışır
// (komutlar, ikili yük, Streams/tüketici grupları, betik önbelleği + NOSCRIPT, AUTH/ACL, kopan bağlantı + reconnect). Çıktı `redis_program.expected` ile ortaktır; sürücü sonuna "exit N" ekler.
// İki geçici sunucu: parolasız (@PORT@) ve requirepass=secret (@AUTHPORT@). `redis-server` yoksa 77 ile çıkar (test atlanır).
// Ardından `redis_tls_program.nox.in` (özel CA ile TLS + güvenilmeyen sertifikanın reddi; TLS host'ta sonlanır) üçüncü, TLS'li bir sunucuya karşı çalışır.
// `bridge` kipi (v2.1.45): ham TCP, `compiler/wasm_tcp_bridge.mjs` WebSocket→TCP köprüsünden (`--tcp-bridge`, tarayıcı yolunun aynısı) geçer; çıktı AYNIDIR, sonuna köprünün
// izin listesi/token/origin reddi satırları eklenir.
// Kullanım: node wasm_redis_driver.mjs <noxc> <sablon.nox> <tls_sablon.nox> <wasm_host.mjs> [bridge]
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync, execFileSync } from 'node:child_process';
import { startTcpBridge } from '../../compiler/wasm_tcp_bridge.mjs';

const [, , noxc, template, tlsTemplate, host, mode = 'direct'] = process.argv;
const bridgeMode = mode === 'bridge';
if (spawnSync('redis-server', ['--version'], { stdio: 'ignore' }).error) process.exit(77);

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => {
      const p = s.address().port;
      s.close(() => resolve(p));
    });
  });
}

async function startRedis(port, extra, dir, probePort = port) {
  const base = extra.includes('--tls-port') ? [] : ['--port', String(port)];
  const proc = spawn('redis-server', [...base, '--bind', '127.0.0.1', '--save', '', '--appendonly', 'no', '--dir', dir, ...extra], { stdio: 'ignore' });
  for (let i = 0; i < 100; i++) {
    const ok = await new Promise((r) => {
      const c = net.connect(probePort, '127.0.0.1', () => { c.destroy(); r(true); });
      c.on('error', () => r(false));
    });
    if (ok) return proc;
    await new Promise((r) => setTimeout(r, 50));
  }
  proc.kill();
  throw new Error('redis-server başlamadı');
}

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nox-wasm-redis-'));
const procs = [];
let bridge = null;
try {
  if (bridgeMode) bridge = await startTcpBridge({ allow: '127.0.0.1,localhost', tlsFiles: true, token: 'sekret' });
  const port = await freePort();
  const authPort = await freePort();
  procs.push(await startRedis(port, [], dir));
  procs.push(await startRedis(authPort, ['--requirepass', 'secret'], dir));
  async function runProgram(tpl, repl, name) {
    let src = fs.readFileSync(tpl, 'utf8');
    for (const [k, v] of Object.entries(repl)) src = src.replaceAll(k, v);
    fs.writeFileSync(path.join(dir, `${name}.nox`), src);
    const b = spawnSync(noxc, ['build', '--target', 'wasm32-freestanding-asyncify', path.join(dir, `${name}.nox`), '-o', path.join(dir, `${name}.wasm`)], { stdio: ['ignore', 'ignore', 'inherit'] });
    if (b.status !== 0) process.exit(1);
    const child = spawn('node', ['--no-warnings', host, path.join(dir, `${name}.wasm`), bridgeMode ? `--tcp-bridge=ws://127.0.0.1:${bridge.port}/?token=sekret` : '--allow-net'], { stdio: ['ignore', 'pipe', 'inherit'] });
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    const code = await new Promise((r) => child.on('close', r));
    process.stdout.write(out);
    console.log(`exit ${code}`);
  }
  await runProgram(template, { '@PORT@': String(port), '@AUTHPORT@': String(authPort) }, 'plain');

  const key = path.join(dir, 'tls.key');
  const crt = path.join(dir, 'tls.crt');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', key, '-out', crt, '-days', '2', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1'], { stdio: 'ignore' });
  const tport = await freePort();
  procs.push(await startRedis(tport, ['--port', '0', '--tls-port', String(tport), '--tls-cert-file', crt, '--tls-key-file', key, '--tls-ca-cert-file', crt, '--tls-auth-clients', 'no'], dir, tport));
  await runProgram(tlsTemplate, { '@PORT@': String(tport), '@CA@': crt.replaceAll('\\', '\\\\') }, 'tls');

  if (bridgeMode) {
    // Köprü sertifika dosyasını, izin listesini, token'ı ve geçersiz istekleri reddeder (WebSocket yükseltmesinden ÖNCE HTTP durumuyla).
    const probe = (query, headers = {}) =>
      new Promise((resolve) => {
        const req = (async () => (await import('node:http')).request({ host: '127.0.0.1', port: bridge.port, path: `/?${query}`, headers: { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==', ...headers } }))();
        req.then((r) => {
          r.on('upgrade', (res, sock) => { sock.destroy(); resolve(res.statusCode); });
          r.on('response', (res) => { res.resume(); resolve(res.statusCode); });
          r.on('error', () => resolve('error'));
          r.end();
        });
      });
    console.log(`bridge disallowed host: ${await probe(`host=example.org&port=80&tls=0&token=sekret`)}`);
    console.log(`bridge wrong token: ${await probe(`host=127.0.0.1&port=${port}&tls=0&token=nope`)}`);
    console.log(`bridge missing port: ${await probe(`host=127.0.0.1&tls=0&token=sekret`)}`);
    console.log(`bridge allowed: ${await probe(`host=127.0.0.1&port=${port}&tls=0&token=sekret`)}`);
  }
} finally {
  if (bridge) await bridge.close();
  for (const p of procs) p.kill();
  fs.rmSync(dir, { recursive: true, force: true });
}
