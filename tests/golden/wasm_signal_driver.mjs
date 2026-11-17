// `wasm32-freestanding --asyncify` + `nox.signal` testi için sürücü (2.3 madde 3.9): host, modülün `nox_host_signal(sig)` dışa aktarımıyla SIGTERM/SIGINT iletir; `wait` uykusu host
// zamanlayıcısına askıya alındığı için JS olay döngüsü çalışır ve zamanlayıcıyla gelen sinyal alınır. `sig 2` (SIGINT) modülde `install` edilmediği için 0 döner. Kullanım: node wasm_signal_driver.mjs prog.wasm
import fs from 'node:fs';
import { runNox } from '../../compiler/wasm_host.mjs';

const out = [];
const io = {
  write: (fd, b) => {
    out.push(new TextDecoder().decode(b));
    return b.length;
  },
  read: () => 0,
  clockMs: () => Date.now(),
  randomFill: (b) => crypto.getRandomValues(b),
  sleepMs: () => {},
};
const log = [];
const signalSource = (deliver) => {
  const t1 = setTimeout(() => log.push(`deliver SIGINT -> ${deliver(2)}`), 80);
  const t2 = setTimeout(() => log.push(`deliver SIGTERM -> ${deliver(15)}`), 400);
  return () => {
    clearTimeout(t1);
    clearTimeout(t2);
  };
};
const keepAlive = setInterval(() => {}, 1000);
const code = await runNox(fs.readFileSync(process.argv[2]), io, { signalSource });
clearInterval(keepAlive);
process.stdout.write(out.join(''));
console.log(`exit ${code}`);
for (const l of log) console.log(l);
