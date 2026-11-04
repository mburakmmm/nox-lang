// Çalıştırma işçisi: derlenmiş .wasm'ı çalıştırır. Ayrı bir işçi olduğu için "Stop" onu sonlandırarak sonsuz döngüleri keser.
import { runNox } from "./wasm_host.mjs";

const OUTPUT_CAP = 1 << 20; // 1 MiB: sonsuz yazdıran programlar sayfayı doldurmasın

self.onmessage = async (e) => {
  const { wasm, stdin } = e.data;
  const dec = new TextDecoder();
  const input = new TextEncoder().encode(stdin || "");
  let pos = 0;
  let total = 0;
  let capped = false;
  const io = {
    write: (fd, b) => {
      total += b.length;
      if (total > OUTPUT_CAP) {
        if (!capped) { capped = true; self.postMessage({ t: "out", fd: 2, text: "\n[output truncated at 1 MiB]\n" }); }
        return b.length;
      }
      self.postMessage({ t: "out", fd: fd === 2 ? 2 : 1, text: dec.decode(b) });
      return b.length;
    },
    read: (fd, b) => {
      const n = Math.min(b.length, input.length - pos);
      b.set(input.subarray(pos, pos + n));
      pos += n;
      return n;
    },
    clockMs: (kind) => (kind === 0 ? Date.now() : performance.now()),
    randomFill: (b) => { for (let i = 0; i < b.length; i += 65536) crypto.getRandomValues(b.subarray(i, i + 65536)); },
    // SharedArrayBuffer olmadan uyku: kısa bir meşgul bekleme (en çok 5 sn; zaman aşımını sayfa uygular).
    sleepMs: (ms) => { const end = performance.now() + Math.min(Math.max(ms, 0), 5000); while (performance.now() < end) {} },
  };
  try {
    const code = await runNox(new Uint8Array(wasm), io);
    self.postMessage({ t: "exit", code });
  } catch (err) {
    self.postMessage({ t: "fatal", text: String((err && err.message) || err) });
  }
};
