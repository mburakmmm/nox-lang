// Depo kökünü COOP/COEP başlıklarıyla sunar (SharedArrayBuffer için gerekli). Kullanım: node examples/wasm-browser/serve.mjs [port]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const types = { '.html': 'text/html; charset=utf-8', '.mjs': 'text/javascript', '.js': 'text/javascript', '.wasm': 'application/wasm' };
const port = Number(process.argv[2] || 8123);

http.createServer((req, res) => {
  const file = path.join(root, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    res.writeHead(404).end('yok');
    return;
  }
  res.writeHead(200, {
    'content-type': types[path.extname(file)] || 'application/octet-stream',
    'cross-origin-opener-policy': 'same-origin',
    'cross-origin-embedder-policy': 'require-corp',
    'cache-control': 'no-store',
  });
  fs.createReadStream(file).pipe(res);
}).listen(port, '127.0.0.1', () => console.log(`http://127.0.0.1:${port}/examples/wasm-browser/index.html?wasm=hello.wasm`));
