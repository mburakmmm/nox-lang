// `wasm32-freestanding --asyncify` + ham TCP (`nox.tls`, `nox.smtp`) testi için sürücü (spec §3.357): yerel bir TLS yankı sunucusu ve STARTTLS destekli sahte bir SMTP sunucusu
// başlatır (kendinden imzalı sertifika `openssl` ile üretilir ve çocuk sürece `NODE_EXTRA_CA_CERTS` olarak verilir), Nox şablonunu (`__TLS_PORT__`, `__SMTP_PORT__`) derleyip
// `wasm_host.mjs` CLI'sıyla çalıştırır. Kullanım: node wasm_tcp_driver.mjs <noxc> <sablon.nox> <wasm_host.mjs> allow|deny
import net from 'node:net';
import tls from 'node:tls';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';

const [, , noxc, template, host, mode = 'allow'] = process.argv;
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nox-tcp-'));
const log = [];
try {
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', path.join(dir, 'key.pem'), '-out', path.join(dir, 'cert.pem'), '-days', '2', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'], { stdio: 'ignore' });
  const key = fs.readFileSync(path.join(dir, 'key.pem'));
  const cert = fs.readFileSync(path.join(dir, 'cert.pem'));

  // TLS yankı: gelen her veriyi büyük harfle geri yollar; "bye" gelince kapatır.
  const tlsSrv = tls.createServer({ key, cert }, (sock) => {
    sock.on('data', (d) => {
      const text = d.toString();
      log.push(`tls recv ${text}`);
      if (text === 'bye') sock.end('BYE');
      else sock.write(text.toUpperCase());
    });
  });
  await new Promise((r) => tlsSrv.listen(0, '127.0.0.1', r));

  // SMTP (STARTTLS destekli): satır tabanlı.
  const smtpSrv = net.createServer((raw) => {
    let sock = raw;
    let inData = false;
    let buf = '';
    const send = (t) => sock.write(t + '\r\n');
    const onData = (d) => {
      buf += d.toString();
      let nl;
      while ((nl = buf.indexOf('\r\n')) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 2);
        if (inData) {
          if (line === '.') {
            inData = false;
            send('250 queued');
          } else {
            log.push(`smtp data ${line}`);
          }
          continue;
        }
        log.push(`smtp ${sock instanceof tls.TLSSocket ? 'tls ' : ''}${line}`);
        if (line.startsWith('EHLO')) send('250-localhost\r\n250 STARTTLS');
        else if (line === 'STARTTLS') {
          send('220 go ahead');
          raw.removeAllListeners('data');
          sock = new tls.TLSSocket(raw, { isServer: true, key, cert });
          sock.on('data', onData);
        } else if (line.startsWith('MAIL') || line.startsWith('RCPT')) send('250 ok');
        else if (line === 'DATA') {
          inData = true;
          send('354 go');
        } else if (line === 'QUIT') {
          send('221 bye');
          sock.end();
        }
      }
    };
    raw.on('data', onData);
    raw.on('error', () => {});
    send('220 mock smtp');
  });
  await new Promise((r) => smtpSrv.listen(0, '127.0.0.1', r));

  const src = fs.readFileSync(template, 'utf8').replaceAll('__TLS_PORT__', String(tlsSrv.address().port)).replaceAll('__SMTP_PORT__', String(smtpSrv.address().port));
  fs.writeFileSync(path.join(dir, 'prog.nox'), src);
  execFileSync(noxc, ['build', '--target', 'wasm32-freestanding-asyncify', path.join(dir, 'prog.nox'), '-o', path.join(dir, 'prog.wasm')], { stdio: ['ignore', 'ignore', 'inherit'] });
  const args = ['--no-warnings', host, path.join(dir, 'prog.wasm')];
  if (mode === 'allow') args.push('--allow-net');
  const child = spawn('node', args, { stdio: ['ignore', 'pipe', 'inherit'], env: { ...process.env, NODE_EXTRA_CA_CERTS: path.join(dir, 'cert.pem') } });
  let out = '';
  child.stdout.on('data', (d) => {
    out += d;
    if (process.env.NOX_DEBUG) process.stderr.write('[child] ' + d);
  });
  const code = await new Promise((r) => child.on('close', r));
  process.stdout.write(out);
  console.log(`exit ${code}`);
  for (const l of log) console.log(`server ${l}`);
  tlsSrv.close();
  smtpSrv.close();
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
