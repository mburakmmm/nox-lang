// `wasm32-freestanding --asyncify` + `nox.mysql` (Zig protokol istemcisi, spec §3.361) testi için sürücü: GERÇEK bir MySQL sunucusuna karşı çalışır.
// Sunucu: `NOX_TEST_MYSQL_PORT` (+ `NOX_TEST_MYSQL_PASSWORD`, `NOX_TEST_MYSQL_DB`) verilirse o; yoksa yerelde zaten bulunan `mysql:8.4` Docker imajından atılabilir bir
// kapsayıcı (`--mysql-native-password=ON`). Docker yok/imaj yok ise "SKIP" yazıp 0 ile çıkar (imaj indirilmez).
// Kullanım: node wasm_mysql_driver.mjs <noxc> <sablon.nox> <wasm_host.mjs>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn, execFileSync } from 'node:child_process';

const [, , noxc, template, host] = process.argv;
const IMAGE = 'mysql:8.4';
const PASSWORD = process.env.NOX_TEST_MYSQL_PASSWORD || 'noxtest';
const DB = process.env.NOX_TEST_MYSQL_DB || 'noxdb';

function docker(args, opts = {}) {
  return execFileSync('docker', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], ...opts });
}

let port = process.env.NOX_TEST_MYSQL_PORT ? Number(process.env.NOX_TEST_MYSQL_PORT) : 0;
let container = null;
if (!port) {
  try {
    docker(['info']);
    docker(['image', 'inspect', IMAGE]);
  } catch {
    console.log('SKIP');
    process.exit(0);
  }
  port = await new Promise((res) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => {
      const p = s.address().port;
      s.close(() => res(p));
    });
  });
  container = docker(['run', '-d', '--rm', '-e', `MYSQL_ROOT_PASSWORD=${PASSWORD}`, '-e', `MYSQL_DATABASE=${DB}`, '-p', `127.0.0.1:${port}:3306`, IMAGE, '--mysql-native-password=ON']).trim();
}
const dir = fs.mkdtempSync(path.join(fs.existsSync('/tmp') ? '/tmp' : os.tmpdir(), 'nox-mysql-'));
try {
  if (container) {
    // Kapsayıcının giriş betiği geçici (ağsız) bir sunucu açıp yeniden başlatır: TCP üzerinden `select 1` çalışana kadar bekle.
    let ready = false;
    for (let i = 0; i < 90 && !ready; i++) {
      try {
        docker(['exec', container, 'mysql', '-h127.0.0.1', '-uroot', `-p${PASSWORD}`, '-e', 'select 1']);
        ready = true;
      } catch {
        await new Promise((r) => setTimeout(r, 2000));
      }
    }
    if (!ready) throw new Error('mysql sunucusu hazir olmadi');
  }
  fs.writeFileSync(path.join(dir, 'prog.nox'), fs.readFileSync(template, 'utf8').replaceAll('__PORT__', String(port)).replaceAll('__ROOT_PASSWORD__', PASSWORD).replaceAll('__DB__', DB));
  execFileSync(noxc, ['build', '--target', 'wasm32-freestanding-asyncify', path.join(dir, 'prog.nox'), '-o', path.join(dir, 'prog.wasm')], { stdio: ['ignore', 'ignore', 'inherit'] });
  const child = spawn('node', ['--no-warnings', host, path.join(dir, 'prog.wasm'), '--allow-net'], { stdio: ['ignore', 'pipe', 'inherit'] });
  let out = '';
  child.stdout.on('data', (d) => (out += d));
  const code = await new Promise((r) => child.on('close', r));
  process.stdout.write(out);
  console.log(`exit ${code}`);
} finally {
  if (container) {
    try {
      docker(['rm', '-f', container]);
    } catch {}
  }
  fs.rmSync(dir, { recursive: true, force: true });
}
