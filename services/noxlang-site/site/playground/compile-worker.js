// Derleyici işçisi: ön yüz (noxc-frontend.wasm) + clang/wasm-ld (WebAssembly olarak, @yowasp/clang) burada çalışır; sayfa donmaz.
import { createNoxCompiler } from "./wasm_compiler.mjs";

// Pinli sürüm: paket içeriği değişmez (jsDelivr npm sürümleri değişmezdir).
const CLANG_URL = "https://cdn.jsdelivr.net/npm/@yowasp/clang@22.0.0-git20542-10/gen/bundle.js";
const DENY = ["network", "process", "shared_memory", "dynamic_code"];

let nox = null;
let ready = null;

function status(text) { self.postMessage({ op: "status", text }); }

async function init() {
  status("Loading the compiler front end…");
  const fe = await (await fetch("/playground/lib/noxc-frontend.wasm")).arrayBuffer();
  nox = await createNoxCompiler({
    frontend: fe,
    asset: async (name) => new Uint8Array(await (await fetch("/playground/lib/" + name)).arrayBuffer()),
    clang: () => import(CLANG_URL),
  });
  self.postMessage({ op: "frontend-ready" });
  // Isınma: clang/lld'yi indirip bir kez çalıştırır; ilk "Run" bekletmez (sonuç tarayıcı önbelleğinde kalır).
  status("Downloading the compiler back end (first visit only, ~25 MB)…");
  const warm = await nox.compile('print("ok")\n', { target: "wasm32-freestanding", deny: DENY, label: "warmup.nox" });
  if (!warm.ok) throw new Error("warm-up failed: " + warm.diagnostics);
  self.postMessage({ op: "ready" });
}

ready = init().catch((e) => self.postMessage({ op: "fatal", text: String((e && e.message) || e) }));

self.onmessage = async (e) => {
  const { id, op, source } = e.data;
  await ready;
  if (!nox) return;
  try {
    if (op === "check") {
      const r = nox.compileToIr(source, { target: "wasm32-freestanding", deny: DENY, label: "main.nox" });
      self.postMessage({ id, ok: r.ok, diagnostics: r.diagnostics });
    } else if (op === "compile") {
      const t0 = performance.now();
      const r = await nox.compile(source, { target: "wasm32-freestanding", deny: DENY, label: "main.nox" });
      if (!r.ok) { self.postMessage({ id, ok: false, diagnostics: r.diagnostics }); return; }
      const bytes = r.wasm.buffer.slice(r.wasm.byteOffset, r.wasm.byteOffset + r.wasm.byteLength);
      self.postMessage({ id, ok: true, wasm: bytes, ms: Math.round(performance.now() - t0), diagnostics: r.diagnostics }, [bytes]);
    }
  } catch (err) {
    self.postMessage({ id, ok: false, diagnostics: "internal error: " + String((err && err.message) || err) + "\n" });
  }
};
