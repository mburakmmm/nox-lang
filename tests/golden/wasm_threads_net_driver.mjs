// `wasm32-freestanding-threads` + `nox.http` testi için sürücü (spec §3.355): gerçek bir yerel HTTP sunucusu başlatır, `__PORT__` yer tutuculu Nox kaynağını derler ve modülü
// `wasm_host.mjs` CLI'sıyla (`--allow-net` ile ya da onsuz) çalıştırır. Kullanım: node wasm_threads_net_driver.mjs <noxc> <sablon.nox> <wasm_host.mjs> allow|deny
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';

const [, , noxc, template, host, mode = 'allow'] = process.argv;
const calls = [];
const srv = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString();
    calls.push(`${req.method} ${req.url} x-test=${req.headers['x-test'] ?? '-'} body=${body || '-'}`);
    if (req.url === '/slow') return void setTimeout(() => res.end('late'), 400);
    res.setHeader('x-reply', 'yes');
    res.end(`${req.method}:${req.url}:${body}`);
  });
});
await new Promise((r) => srv.listen(0, '127.0.0.1', r));
const port = srv.address().port;
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nox-threads-net-'));
try {
  fs.writeFileSync(path.join(dir, 'prog.nox'), fs.readFileSync(template, 'utf8').replaceAll('__PORT__', String(port)));
  execFileSync(noxc, ['build', '--target', 'wasm32-freestanding-threads', path.join(dir, 'prog.nox'), '-o', path.join(dir, 'prog.wasm')], { stdio: ['ignore', 'ignore', 'inherit'] });
  const args = ['--no-warnings', host, path.join(dir, 'prog.wasm')];
  if (mode === 'allow') args.push('--allow-net');
  const child = spawn('node', args, { stdio: ['ignore', 'pipe', 'inherit'] });
  let out = '';
  child.stdout.on('data', (d) => (out += d));
  const code = await new Promise((r) => child.on('close', r));
  process.stdout.write(out);
  console.log(`exit ${code}`);
  for (const c of calls.sort()) console.log(`server ${c}`);
} finally {
  srv.close();
  fs.rmSync(dir, { recursive: true, force: true });
}
