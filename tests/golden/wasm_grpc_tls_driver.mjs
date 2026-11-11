// `wasm32-freestanding --asyncify` + `nox.grpc.connect_tls` (v2.1.44): TLS HOST'ta sonlanır; ALPN `h2`, özel CA (`ca_file`) ve istemci sertifikası (mTLS) host'a aktarılır.
// Sürücü, ALPN `h2` bildiren ve istemci sertifikası İSTEYEN yerel bir Node TLS sunucusu başlatır (sunucu sertifikası RSA, istemci sertifikası EC P-256; ikisi de `openssl` ile üretilir),
// Nox şablonunu (`__PORT__`, `__CA__`, `__CERT__`, `__KEY__`) derleyip `wasm_host.mjs` CLI'sıyla çalıştırır ve sunucunun gördüklerini yazar.
// Kullanım: node wasm_grpc_tls_driver.mjs <noxc> <sablon.nox> <wasm_host.mjs>
import tls from 'node:tls';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';

const [, , noxc, template, host] = process.argv;
// Windows yolları (`C:\\Users\\...`) Nox string sabitine yazılırken ters bölüler kaçırılmalıdır (aksi halde `\\U` kaçış hatası olur).
const nx = (p) => p.replaceAll('\\', '\\\\');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'nox-grpc-tls-'));
const log = [];
try {
  const sk = path.join(dir, 'server.key');
  const sc = path.join(dir, 'server.crt');
  const ck = path.join(dir, 'client.key');
  const cc = path.join(dir, 'client.crt');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', sk, '-out', sc, '-days', '2', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'], { stdio: 'ignore' });
  execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-keyout', ck, '-out', cc, '-days', '2', '-subj', '/CN=nox-client'], { stdio: 'ignore' });

  const srv = tls.createServer({ key: fs.readFileSync(sk), cert: fs.readFileSync(sc), ca: [fs.readFileSync(cc)], requestCert: true, rejectUnauthorized: true, ALPNProtocols: ['h2'] }, (sock) => {
    log.push(`alpn=${sock.alpnProtocol} client=${sock.getPeerCertificate().subject.CN}`);
    // HTTP/2 konuşmaz: ilk veriyi (gRPC istemcisinin HTTP/2 ön eki) görünce bağlantıyı kapatır.
    sock.once('data', () => sock.end());
    sock.on('error', () => {});
  });
  srv.on('tlsClientError', (e) => log.push(`handshake error: ${e.message}`));
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));

  const src = fs.readFileSync(template, 'utf8').replaceAll('__PORT__', String(srv.address().port)).replaceAll('__CA__', nx(sc)).replaceAll('__CERT__', nx(cc)).replaceAll('__KEY__', nx(ck));
  fs.writeFileSync(path.join(dir, 'prog.nox'), src);
  execFileSync(noxc, ['build', '--target', 'wasm32-freestanding-asyncify', path.join(dir, 'prog.nox'), '-o', path.join(dir, 'prog.wasm')], { stdio: ['ignore', 'ignore', 'inherit'] });
  const child = spawn('node', ['--no-warnings', host, path.join(dir, 'prog.wasm'), '--allow-net'], { stdio: ['ignore', 'pipe', 'inherit'] });
  let out = '';
  child.stdout.on('data', (d) => (out += d));
  const code = await new Promise((r) => child.on('close', r));
  process.stdout.write(out);
  console.log(`exit ${code}`);
  // Sunucu günlüğünün geç gelmesini bekle.
  await new Promise((r) => setTimeout(r, 200));
  for (const l of log) console.log(`server ${l}`);
  srv.close();
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
