# Tarayıcıda Nox derleyicisi

Nox derleyicisinin tamamı WebAssembly olarak çalışır: kaynak kodu **tarayıcıda** (ya da Node'da) `.wasm`a derlenir ve orada çalıştırılır. Sunucu, `noxc` ikilisi, `zig` ya da `clang` kurulumu gerekmez; kod hiçbir yere gönderilmez (playground, gömülü kod deneme alanları, çevrimdışı araçlar için).

İki parça vardır:

1. **Ön yüz** (`noxc-frontend.wasm`, ~2 MB): lexer, parser, tip denetimi ve LLVM IR üretimi. `nox.*` standart kütüphanesi modülün içine gömülüdür. Yerel `noxc build --target wasm32-*` ile **byte-birebir aynı** IR'ı üretir (aynı kod, `compiler/frontend.zig`). Bir programı ~30 ms'de denetler/derler; sözdizimi ve tip hatalarını okunaklı metin olarak döner.
2. **Arka uç** (clang + wasm-ld, WASM olarak): IR'ı çalışma zamanı nesneleriyle bağlayıp `.wasm` üretir. Varsayılan sağlayıcı [`@yowasp/clang`](https://www.npmjs.com/package/@yowasp/clang) (isteğe bağlı bağımlılık, ~25 MiB gzip, ilk kullanımda tembel yüklenir ve tarayıcı önbelleğinde kalır); `runClang(argv, files)` uyumlu başka bir sağlayıcı da verilebilir.

## Kullanım

```js
import { createNoxCompiler } from './wasm_compiler.mjs';
import { runNox } from './wasm_host.mjs';

const nox = await createNoxCompiler({
  frontend: await (await fetch('noxc-frontend.wasm')).arrayBuffer(),
  // çalışma zamanı nesneleri: noxrt-wasm32-freestanding.o, ...-sqlite3.o, compiler-rt-wasm32.a (sürüm arşivinin lib/ dizini)
  asset: async (name) => new Uint8Array(await (await fetch(`lib/${name}`)).arrayBuffer()),
  clang: () => import('@yowasp/clang'),
});

const r = await nox.compile('print("merhaba", 6 * 7)\n', { target: 'wasm32-freestanding' });
if (!r.ok) console.error(r.diagnostics);              // "main.nox:1:9: syntax error: ..." gibi
else await runNox(r.wasm, io);                         // io: write/read/clockMs/randomFill/sleepMs (bkz. WebAssembly sayfası)
```

- `nox.compileToIr(source, opts)` yalnızca ön yüzü çalıştırır (`{ ok, ir, plan, diagnostics }`): canlı hata denetimi için idealdir.
- `opts.target`: `wasm32-freestanding` (varsayılan), `-asyncify`, `-threads`; `opts.deny`: derleme zamanı yetenek yasakları (`['fs', 'network']`, bkz. `--deny-capability`); `opts.label`: tanılamadaki dosya adı.
- `nox.addFile('/stdlib/...' | yol, metin)`: bellek içi sanal dosya ekler.
- `--asyncify` hedefleri bağlama sonrası `wasm-opt` ister: tarayıcıda `binaryen` (npm, Apache-2.0) ile `import { binaryenAsyncify } from './wasm_asyncify.mjs'; createNoxCompiler({ ..., optimize: binaryenAsyncify(binaryen) })`. Verilmezse açık bir hata döner. `nox.http` istemcisi (`fetch`) yalnızca bu hedefte çalışır.

Çalıştırırken [WebAssembly sayfasındaki](wasm.md) host seçenekleri geçerlidir: bellek içi dosya sistemi, isteğe bağlı kalıcılık (`vfs`) ve yalnızca açıkça verilirse ağ (`fetch`). Güvenilmeyen kodu çalıştıran sayfalarda `deny` ile yetenekleri derleme zamanında kısıtlayın ve `runNox`a `fetch`/`vfs` vermeyin.

## Dağıtım ve sınırlar

- Sürüm arşivinin yanında `nox-web-compiler-<sürüm>.tar.gz` yayımlanır: `noxc-frontend.wasm`, `wasm_compiler.mjs`, `wasm_asyncify.mjs`, `wasm_host.mjs` ve `lib/` (çalışma zamanı nesneleri). Kaynaktan: `zig build wasm-compiler wasm-rt`.
- İlk derleme clang/lld'yi yükler (yüzlerce ms); sonrakiler ~0,3-1 sn sürer. Büyük programlar ve `nox.sqlite` (≈ 800 KB çıktı) biraz daha uzun sürer.
- Yerel `extern def ... from "<kütüphane>"` bildirimleri tarayıcıda bağlanamaz (yerel kütüphane yok); `native`, `plugin`, `hpy` modülleri WASM'da zaten kullanılamaz.
- Doğrulama: `scripts/wasm_frontend_corpus.py` tüm `codegen_cases` korpusunda ön yüz IR'ını yerel `noxc` ile karşılaştırır (467 aynı + 16 aynı nedenle reddedilen); `scripts/web_compiler_e2e.mjs` tam boru hattını (ön yüz -> clang -> çalıştırma) korpusta çalıştırıp `.expected` ile karşılaştırır (`wasm32-freestanding` 453 ok, `wasm32-freestanding-asyncify` binaryen ile 458 ok).
