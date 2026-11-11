// WebSocket → TCP köprüsü (v2.1.45): tarayıcıda ham soket yoktur; `browserTcp({ url })` (wasm_host.mjs) her `tcp.connect` için bu köprüye bir WebSocket açar, köprü hedefe gerçek TCP
// bağlantısı kurar ve baytları iki yönde aktarır. TLS KÖPRÜDE sonlanır (sertifika doğrulaması köprünün TLS yığınındadır; tarayıcıya hiç güvenilir/güvenilmez bilgisi sızmaz).
//
// Protokol (bir WebSocket = bir TCP bağlantısı):
//   bağlanma:  ws://köprü/?host=H&port=P&tls=0|1[&token=T]   (reddedilen istek WebSocket'e yükseltilmeden HTTP 403/400 alır)
//   köprü → istemci:  metin `{"op":"open"}` (TCP bağlandı) | `{"op":"error","message":...}` (sonra kapanır) | `{"op":"tls"}` (startTls bitti)
//   istemci → köprü:  metin `{"op":"starttls","servername":S,"alpn":A,"ca":F,"cert":F,"key":F}`; ikili çerçeveler ham baytlardır (iki yönde).
//   TCP kapanınca köprü WebSocket'i 1000 ile kapatır; WebSocket kapanınca TCP yok edilir.
//
// Güvenlik: köprü AÇIK bir proxy'dir; bu yüzden izin listesi ZORUNLUDUR (`allow`: `wasm_host.mjs`teki `netPolicy` sözdizimi, `*` her şeye izin verir). İsteğe bağlı `origins` (Origin başlığı
// listesi) ve `token` (paylaşılan gizli) vardır. `ca`/`cert`/`key` yolları KÖPRÜ makinesindedir ve yalnızca `tlsFiles: true` ile kabul edilir.
// Sınırlar: geri-basınç yok (bir ileti en çok 16 MiB), bağlantı başına tek TLS yükseltmesi.
//
// Kullanım: node wasm_tcp_bridge.mjs --listen 127.0.0.1:8765 --allow db.internal:5432,*.example.com [--origin https://app.example.com] [--token S] [--tls-files]
import http from 'node:http';
import net from 'node:net';
import tls from 'node:tls';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { netPolicy } from './wasm_host.mjs';

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const MAX_MESSAGE = 16 * 1024 * 1024;

function frame(opcode, payload) {
  const len = payload.length;
  let head;
  if (len < 126) head = Buffer.from([0x80 | opcode, len]);
  else if (len < 65536) {
    head = Buffer.alloc(4);
    head[0] = 0x80 | opcode;
    head[1] = 126;
    head.writeUInt16BE(len, 2);
  } else {
    head = Buffer.alloc(10);
    head[0] = 0x80 | opcode;
    head[1] = 127;
    head.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([head, payload]);
}

/** Tek bir WebSocket bağlantısı için çerçeve ayrıştırıcı + gönderici (RFC 6455: parçalı iletiler, ping/pong, kapatma). */
function wsConnection(sock, { onText, onBinary, onClose }) {
  let buf = Buffer.alloc(0);
  let msgOpcode = 0;
  let parts = [];
  let partsLen = 0;
  let closed = false;
  const finish = (code) => {
    if (closed) return;
    closed = true;
    try {
      const p = Buffer.alloc(2);
      p.writeUInt16BE(code);
      sock.write(frame(8, p));
    } catch {}
    sock.end();
    onClose();
  };
  const drain = () => {
    for (;;) {
      if (buf.length < 2) return;
      const fin = (buf[0] & 0x80) !== 0;
      const opcode = buf[0] & 0x0f;
      const masked = (buf[1] & 0x80) !== 0;
      let len = buf[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        if (buf.length < 4) return;
        len = buf.readUInt16BE(2);
        off = 4;
      } else if (len === 127) {
        if (buf.length < 10) return;
        const big = buf.readBigUInt64BE(2);
        if (big > BigInt(MAX_MESSAGE)) return finish(1009);
        len = Number(big);
        off = 10;
      }
      if (!masked) return finish(1002); // istemci çerçeveleri MASKELİ olmalıdır
      if (len > MAX_MESSAGE) return finish(1009);
      if (buf.length < off + 4 + len) return;
      const mask = buf.subarray(off, off + 4);
      const payload = Buffer.from(buf.subarray(off + 4, off + 4 + len));
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      buf = buf.subarray(off + 4 + len);
      if (opcode >= 8) {
        if (!fin || len > 125) return finish(1002);
        if (opcode === 8) return finish(1000);
        if (opcode === 9) sock.write(frame(10, payload));
        continue;
      }
      if (opcode !== 0) {
        msgOpcode = opcode;
        parts = [];
        partsLen = 0;
      } else if (msgOpcode === 0) {
        return finish(1002);
      }
      parts.push(payload);
      partsLen += payload.length;
      if (partsLen > MAX_MESSAGE) return finish(1009);
      if (fin) {
        const whole = parts.length === 1 ? parts[0] : Buffer.concat(parts);
        const kind = msgOpcode;
        msgOpcode = 0;
        parts = [];
        partsLen = 0;
        if (kind === 1) onText(whole.toString('utf8'));
        else if (kind === 2) onBinary(whole);
        else return finish(1003);
      }
    }
  };
  sock.on('data', (d) => {
    buf = buf.length === 0 ? d : Buffer.concat([buf, d]);
    drain();
  });
  sock.on('close', () => {
    if (!closed) {
      closed = true;
      onClose();
    }
  });
  sock.on('error', () => {});
  return {
    sendText: (s) => !closed && sock.write(frame(1, Buffer.from(s))),
    sendBinary: (b) => !closed && sock.write(frame(2, Buffer.from(b.buffer, b.byteOffset, b.length))),
    close: (code = 1000) => finish(code),
  };
}

/**
 * Köprüyü başlatır. `allow` (zorunlu): izin listesi dizesi/dizisi. Döner: `{ port, host, close() }`.
 */
export async function startTcpBridge({ port = 0, host = '127.0.0.1', allow, origins = null, token = null, tlsFiles = false } = {}) {
  if (allow === undefined || allow === null || String(allow).trim() === '') throw new Error('startTcpBridge: `allow` (the target allow-list) is required; use "*" to allow every target');
  const policy = netPolicy(allow);
  const originSet = origins ? new Set(Array.isArray(origins) ? origins : String(origins).split(',').map((x) => x.trim()).filter(Boolean)) : null;
  const server = http.createServer((req, res) => {
    res.writeHead(426, { 'content-type': 'text/plain' });
    res.end('WebSocket upgrade required');
  });
  const conns = new Set();
  server.on('upgrade', (req, sock) => {
    const reject = (code, text) => {
      sock.end(`HTTP/1.1 ${code} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    };
    sock.on('error', () => {});
    const u = new URL(req.url, 'http://bridge');
    const key = req.headers['sec-websocket-key'];
    if (String(req.headers.upgrade).toLowerCase() !== 'websocket' || !key || req.headers['sec-websocket-version'] !== '13') return reject(400, 'Bad Request');
    if (originSet && !originSet.has(req.headers.origin)) return reject(403, 'Forbidden');
    if (token !== null && u.searchParams.get('token') !== token) return reject(403, 'Forbidden');
    const targetHost = u.searchParams.get('host');
    const targetPort = Number(u.searchParams.get('port'));
    const useTls = u.searchParams.get('tls') === '1';
    if (!targetHost || !Number.isInteger(targetPort) || targetPort < 1 || targetPort > 65535) return reject(400, 'Bad Request');
    if (!policy.allows(targetHost, targetPort)) return reject(403, 'Forbidden');
    const accept = crypto.createHash('sha1').update(key + GUID).digest('base64');
    sock.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    sock.setNoDelay(true);

    let target = null;
    let upgrading = false;
    const attach = (t) => {
      t.on('data', (d) => {
        if (!upgrading) ws.sendBinary(d);
      });
      t.on('end', () => ws.close(1000));
      t.on('close', () => ws.close(1000));
      t.on('error', () => ws.close(1000));
    };
    const ws = wsConnection(sock, {
      onText(text) {
        let msg;
        try {
          msg = JSON.parse(text);
        } catch {
          return ws.close(1003);
        }
        if (msg.op !== 'starttls' || !target) return ws.close(1002);
        const extra = {};
        if (msg.alpn) extra.ALPNProtocols = [String(msg.alpn)];
        try {
          if (msg.ca || msg.cert || msg.key) {
            if (!tlsFiles) throw new Error('TLS certificate files are not allowed by this bridge');
            if (msg.ca) extra.ca = fs.readFileSync(String(msg.ca));
            if (msg.cert) extra.cert = fs.readFileSync(String(msg.cert));
            if (msg.key) extra.key = fs.readFileSync(String(msg.key));
          }
        } catch (e) {
          ws.sendText(JSON.stringify({ op: 'error', message: String(e.message) }));
          return ws.close(1000);
        }
        upgrading = true;
        const raw = target;
        raw.removeAllListeners('data');
        raw.removeAllListeners('end');
        raw.removeAllListeners('close');
        raw.removeAllListeners('error');
        const servername = String(msg.servername || targetHost);
        const t = tls.connect(net.isIP(servername) ? { socket: raw, ...extra } : { socket: raw, servername, ...extra }, () => {
          if (msg.alpn && t.alpnProtocol !== msg.alpn) {
            ws.sendText(JSON.stringify({ op: 'error', message: `the server did not negotiate ${msg.alpn === 'h2' ? 'HTTP/2' : msg.alpn} (ALPN)` }));
            t.destroy();
            return;
          }
          target = t;
          upgrading = false;
          attach(t);
          ws.sendText(JSON.stringify({ op: 'tls' }));
        });
        t.once('error', (e) => {
          ws.sendText(JSON.stringify({ op: 'error', message: String(e.message) }));
          ws.close(1000);
        });
      },
      onBinary(b) {
        if (target && !upgrading) target.write(b);
      },
      onClose() {
        conns.delete(sock);
        if (target) target.destroy();
      },
    });
    conns.add(sock);
    const s = useTls ? tls.connect(net.isIP(targetHost) ? { host: targetHost, port: targetPort } : { host: targetHost, port: targetPort, servername: targetHost }) : net.connect({ host: targetHost, port: targetPort });
    s.once(useTls ? 'secureConnect' : 'connect', () => {
      target = s;
      attach(s);
      ws.sendText(JSON.stringify({ op: 'open' }));
    });
    s.once('error', (e) => {
      if (!target) {
        ws.sendText(JSON.stringify({ op: 'error', message: String(e.message) }));
        ws.close(1000);
      }
    });
  });
  await new Promise((r, j) => {
    server.once('error', j);
    server.listen(port, host, r);
  });
  return {
    port: server.address().port,
    host,
    close: () =>
      new Promise((r) => {
        for (const c of conns) c.destroy();
        server.close(() => r());
      }),
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const opt = { host: '127.0.0.1', port: 8765, allow: null, origins: null, token: null, tlsFiles: false };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--listen') {
      const v = args[++i];
      const c = v.lastIndexOf(':');
      opt.host = v.slice(0, c);
      opt.port = Number(v.slice(c + 1));
    } else if (a === '--allow') opt.allow = args[++i];
    else if (a === '--origin') opt.origins = (opt.origins || []).concat(args[++i]);
    else if (a === '--token') opt.token = args[++i];
    else if (a === '--tls-files') opt.tlsFiles = true;
    else {
      console.error(`unknown argument ${a}\nusage: node wasm_tcp_bridge.mjs --listen HOST:PORT --allow LIST [--origin URL] [--token S] [--tls-files]`);
      process.exit(2);
    }
  }
  if (!opt.allow) {
    console.error('wasm_tcp_bridge: --allow is required (use --allow "*" to allow every target)');
    process.exit(2);
  }
  const b = await startTcpBridge(opt);
  console.log(`tcp bridge listening on ws://${b.host}:${b.port}/`);
}
