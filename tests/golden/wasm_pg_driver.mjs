// `wasm32-freestanding --asyncify` + `nox.postgres` (Zig protokol istemcisi, spec §3.358) testi için sürücü: GERÇEK bir PostgreSQL sunucusuna karşı çalışır. Geçici bir küme
// (`initdb`, scram-sha-256) kurar, `pg_ctl` ile başlatır, Nox şablonunu (`__PORT__`) derleyip `wasm_host.mjs --allow-net` ile çalıştırır ve kümeyi durdurup siler.
// `initdb`/`pg_ctl` bulunamazsa "SKIP" yazıp 0 ile çıkar. Kullanım: node wasm_pg_driver.mjs <noxc> <sablon.nox> <wasm_host.mjs>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { spawn, execFileSync } from 'node:child_process';

const [, , noxc, template, host] = process.argv;

function findBin(name) {
  const dirs = (process.env.PATH || '').split(path.delimiter);
  for (const base of ['/opt/homebrew/opt', '/usr/local/opt']) {
    try {
      for (const d of fs.readdirSync(base)) if (d.startsWith('postgresql')) dirs.push(path.join(base, d, 'bin'));
    } catch {}
  }
  try {
    for (const v of fs.readdirSync('/usr/lib/postgresql')) dirs.push(path.join('/usr/lib/postgresql', v, 'bin'));
  } catch {}
  for (const d of dirs) {
    const p = path.join(d, name);
    if (fs.existsSync(p)) return p;
  }
  return null;
}

const initdb = findBin('initdb');
const pgCtl = findBin('pg_ctl');
if (!initdb || !pgCtl) {
  console.log('SKIP');
  process.exit(0);
}
const freePort = await new Promise((res) => {
  const s = net.createServer();
  s.listen(0, '127.0.0.1', () => {
    const p = s.address().port;
    s.close(() => res(p));
  });
});
// Unix soket yolu 104 baytı aşmamalı (macOS): kısa bir dizin kullanılır.
const pgEnv = { ...process.env, LC_ALL: 'C', LANG: 'C' };
const dir = fs.mkdtempSync(path.join(fs.existsSync('/tmp') ? '/tmp' : os.tmpdir(), 'nox-pg-'));
const data = path.join(dir, 'data');
let started = false;
try {
  fs.writeFileSync(path.join(dir, 'pw'), 'secret');
  execFileSync(initdb, ['-D', data, '-U', 'postgres', '--auth=scram-sha-256', '--pwfile', path.join(dir, 'pw'), '-E', 'UTF8', '--locale=C'], { stdio: 'ignore', env: pgEnv });
  try {
    execFileSync(pgCtl, ['-D', data, '-o', `-p ${freePort} -k ${dir} -c listen_addresses=127.0.0.1 -c fsync=off`, '-l', path.join(dir, 'log'), '-w', 'start'], { stdio: 'ignore', env: pgEnv });
  } catch (e) {
    process.stderr.write(`postgres basladi: hayir\n${fs.existsSync(path.join(dir, 'log')) ? fs.readFileSync(path.join(dir, 'log'), 'utf8') : ''}\n`);
    throw e;
  }
  started = true;

  fs.writeFileSync(path.join(dir, 'prog.nox'), fs.readFileSync(template, 'utf8').replaceAll('__PORT__', String(freePort)));
  execFileSync(noxc, ['build', '--target', 'wasm32-freestanding-asyncify', path.join(dir, 'prog.nox'), '-o', path.join(dir, 'prog.wasm')], { stdio: ['ignore', 'ignore', 'inherit'] });
  const child = spawn('node', ['--no-warnings', host, path.join(dir, 'prog.wasm'), '--allow-net'], { stdio: ['ignore', 'pipe', 'inherit'] });
  let out = '';
  child.stdout.on('data', (d) => (out += d));
  const code = await new Promise((r) => child.on('close', r));
  process.stdout.write(out);
  console.log(`exit ${code}`);
} finally {
  if (started) {
    try {
      execFileSync(pgCtl, ['-D', data, '-m', 'immediate', '-w', 'stop'], { stdio: 'ignore', env: pgEnv });
    } catch {}
  }
  fs.rmSync(dir, { recursive: true, force: true });
}
