# WebAssembly (wasm32-wasi)

Nox programları WebAssembly'ye derlenebilir:

```bash
noxc build --target wasm32-wasi hello.nox -o hello.wasm
node --no-warnings tests/golden/wasm_run.mjs hello.wasm   # ya da wasmtime, wasmer, ...
```

Çıktı bir WASI komutudur (`_start`). Derleme yolu LLVM'dir: `.ll` dosyası `zig cc -target wasm32-wasi` ile wasi-libc ve `noxrt-wasm32-wasi.o` çalışma zamanına bağlanır. `zig` PATH'te olmalıdır; `--backend qbe`, `--emit-asm` ve `-g` bu hedefte hatadır. Çalışma zamanı nesneleri (`lib/noxrt-wasm32-*.o`, `-sqlite3.o` ve compiler-rt arşivleri `lib/compiler-rt-wasm32*.a`) `zig build wasm-rt` ile üretilir; v2.0.150'den itibaren sürüm arşivlerinde (macOS, Linux, Windows) hazır gelir, yani yayımlanmış bir `noxc` ile `--target wasm32-*` kaynak derlemeden çalışır (`zig` PATH'te olmalı; `--asyncify` için ayrıca `wasm-opt`).

## Nelerin çalıştığı

Dilin tamamı: sınıflar, kalıtım (çoklu dahil), jeneratörler, `async`/`await`/`Channel`, istisnalar, `with`, `__del__`, comprehension'lar, f-string, `lowlevel`. Standart kütüphaneden: `nox.strings`, `math`, `mathx`, `os`, `path`, `time`, `random`, `json`, `yaml`, `toml`, `csv`, `unicode`, `bytes`, `buffer`, `base64`, `bits`, `atomic`, `collections`, `url`, `uuid`, `validate`, `template`, `log`, `test`, `io`, **`fs`** (WASI ön-açılan dizinler), **`regex`**, **`gzip`**, **`crypto`** (hash/HMAC/parola özetleri, WASI `random_get`), **`http`**, **`router`**, **`web`**, **`reflect`**, **`transfer`** (yönlendirme, çerezler, CORS, istek/yanıt sınıfları ve bir handler'ın doğrudan çağrılarak sınanması çalışır; ağ çağrıları için aşağıdaki [yetenek modeline](#yetenek-modeli-ve---deny-capability) bakın).

## Destek matrisi

| Kip | Bayrak | `spawn`/`await`/`Channel` | Gerçek fiber | Gerçek paralellik (`nox.thread`, M:N) | Bilinen sınır |
|---|---|---|---|---|---|
| Varsayılan | (yok) | iç içe çalıştırma benzetimi | hayır | hayır | altındaki bir görevi bekleyen görev deadlock sayılır |
| Asyncify | `--asyncify` | fiber (M:1) | evet | hayır | Asyncify'ın boyut ve hız maliyeti ([ADR-014](../internals/adr/014-wasm-asyncify.md)) |
| Threads | `--threads` | fiber + iş çalan havuz (M:N) | evet (Asyncify ile) | evet | paylaşımlı bellek gerekir; dosya tanıtıcıları iş parçacığı başınadır ([ADR-015](../internals/adr/015-wasm-threads.md)) |

Her kip `wasm32-wasi` ve `wasm32-freestanding` için vardır. Dil ve standart kütüphane davranışı kipler arasında aynıdır; fark yalnızca eşzamanlılık modelidir. Bu eşdeğerlik `zig build wasm-corpus-test` ile sekiz hedefte de fixture korpusuyla doğrulanır; bilinen farklar (libm'in son basamağı, kipe özgü zamanlama sırası) korpus listelerinde belgelidir.

## Sınırlar

- **Eşzamanlılık kipe bağlıdır** (yukarıdaki tabloya bakın). Varsayılan kipte iş parçacığı yoktur ve `spawn`/`await` iç içe çalıştırma benzetimiyle çalışır: bir görev, onu bekleyen görevin yığınında sonuna kadar çalışır; altındaki bir görevin sonucunu bekleyen görev "deadlock" olarak bildirilir. `--asyncify` gerçek fiber verir (tek iş parçacığı, M:1); `--threads` gerçek paralellik verir (M:N).
- **Henüz desteklenmeyen modüller.** `sharedmem`, `native`, `plugin`, `hpy` ve `hpy_*` / `wasm_call` yerleşikleri derleme sırasında şu iletiyle reddedilir: `module 'nox.tls' cannot be used on the wasm32-wasi target (it needs sockets)`. Bunların çoğu için yol bellidir (host yeteneği olarak sağlanması; aşağıdaki modele bakın), `native`, `plugin` ve `hpy` ise WASM'da hiçbir zaman mümkün değildir (dinamik yükleme yok).
- **Ağ host'a bağlıdır.** `nox.http` WASM'da derlenir, ama gerçek bir soket (istemci `get`/`post`/`request`/akışlı istemci, sunucu `serve*`) bir host yeteneği olmadan çalışmaz: istemci çağrıları yakalanabilir bir `HttpCapabilityError` (`HttpError`ın alt sınıfı) fırlatır; `serve` bir tanı mesajı yazıp gerçek bir bind hatasındaki gibi hemen döner.
- **Windows'ta Node WASI ile `read_dir`.** `wasm32-wasi` modülünü Windows'ta Node'un `node:wasi`si ile çalıştırırken `nox.fs.read_dir` (ve onu kullanan `remove_dir_all`) `FsError` verir: Node'un WASI'si Windows'ta `fd_readdir`i uygulamaz (ENOSYS). Linux/macOS'ta ve `wasm32-freestanding`'de (sanal dosya sistemi) sorun yoktur; Wasmtime gibi başka bir WASI motoru da etkilenmez.
- **Yerel kütüphane yok.** `extern def ... from "lib"` ile bir `.wasm`a native kütüphane bağlanamaz.
- **Dosya sistemi** çalıştırıcının WASI ön-açımlarına bağlıdır (`wasm_run.mjs` `.` ve `/tmp` açar).
- **Matematik** işlevleri (`exp`, `sin`, ...) wasi-libc'den gelir; son basamakta platform libm'den ayrılabilir (ör. `exp(1.0)`).

Ayrıntı ve gerekçe: [ADR-012](../internals/adr/012-wasm-target.md). Bir WASM modülünü Nox'a *içe aktarmak* (`wasm_call`) ayrı bir mekanizmadır: [HPy ve WebAssembly](../internals/hpy-wasm.md).

## Yetenek modeli ve `--deny-capability`

WASM genel amaçlı bir derleme hedefidir: modüller, ihtiyaç duydukları şey bir *yetenek* (`network`, `filesystem`, `clock`, `entropy`, ...) olduğu sürece derlenir. Yeteneği sağlamak host'un işidir (WASI, `nox_host` import'ları ya da bir tarayıcı sayfası); sağlamıyorsa çağrı anında açık bir hata alırsınız, link hatası ya da çökme değil. Bugün bu `nox.http` istemcisi (ağ), `nox.fs` ve `nox.sqlite` (sanal dosya sistemi) için geçerlidir; kalan yetenekler aynı modelle eklenecektir ([ADR-016](../internals/adr/016-wasm-capabilities.md)).

Güvenilmeyen kodu derleyen ortamlar (ör. tarayıcıda bir kod deneme alanı) yetenekleri **derleme zamanında** da kısıtlayabilir; bu bayrak yalnızca WASM'da değil, her hedefte çalışır:

```bash
noxc build --target wasm32-freestanding --deny-capability fs,net,process prog.nox -o prog.wasm
NOX_DENY_CAPABILITY=net noxc check prog.nox       # ortam değişkeni de olur
```

Liste virgülle ayrılır: `filesystem`/`fs`, `network`/`net`, `clock`, `entropy`/`random`, `threads`, `shared_memory`/`shm`, `libc_math`, `dynamic_code`/`dynamic`. Yasaklanan bir yeteneği isteyen modülü içe aktaran ya da `@capability.requires` ile işaretli bir işlevi çağıran program reddedilir: `module 'nox.http' cannot be used: the capability 'network' is denied (--deny-capability)`. Bilinmeyen bir ad hata verir (yanlış yazılmış bir yasak sessizce yok sayılmaz). İkinci katman host'tur: ilgili `nox_host` import'larını hiç sağlamayan bir host, yasaklanmamış olsa bile o yeteneği vermez.

## `wasm32-freestanding` ve `nox_host`

```bash
noxc build --target wasm32-freestanding prog.nox -o prog.wasm
noxc run   --target wasm32-freestanding prog.nox          # node ile (compiler/wasm_host.mjs)
```

WASI ve libc olmadan, tarayıcıya ya da gömülü bir host'a uygun bir modül üretir. Modül dış dünyayı yalnızca `nox_host` import'larıyla görür: `write`, `read`, `clock_ms`, `random_fill`, `sleep_ms`, `exit` ([ADR-013](../internals/adr/013-wasm-host.md)). Dil ve stdlib `wasm32-wasi` ile aynıdır; farklar: `nox.fs` gerçek diske değil, çalışma zamanının bellek içi sanal dosya sistemine yazar (aşağıya bakın), ortam değişkenleri boş başlar (`set_var` modüle özel), `arg(0)` `"nox"`.

Tarayıcıda ya da kendi host'unda çalıştırmak için `compiler/wasm_host.mjs` içindeki `createHost` kullanılır:

```js
import { runNox } from './wasm_host.mjs';
const code = await runNox(await (await fetch('prog.wasm')).arrayBuffer(), {
  write: (fd, bytes) => { (fd === 2 ? console.error : console.log)(new TextDecoder().decode(bytes)); return bytes.length; },
  read: () => 0,
  clockMs: (kind) => (kind === 0 ? Date.now() : performance.now()),
  randomFill: (bytes) => crypto.getRandomValues(bytes),
  sleepMs: () => {},
});
```

### Doğrulama araçları

`scripts/wasm_corpus.py` fixture korpusunu paralel ve motor seçilebilir koşar (`--target`, `--engine node|wasmtime`); `scripts/wasm_stress.py` karma yükü (kanal fan-in, döngüsel çöp, terk edilen jeneratörler, `nox.thread`) dört hedefte süre boyunca tekrar koşup native çıktıyla birebir karşılaştırır.

### Maliyet

Ölçümler `benchmarks/wasm/RESULTS.md` içindedir (`benchmarks/wasm_bench.py` ile yeniden üretilir). Özet (Apple M4, Node 26): wasm, native LLVM'e göre CPU-bağımlı kodda 1,4x, bellek-yoğun kodda 3-5x yavaştır; `--asyncify` CPU-bağımlı kodda varsayılan kipe göre +0-4% ekler ama çok sık askıya alan yüklerde (500 bin `spawn`/`await`) 2,6x yavaşlatır; `--threads` dört eşit görevde Asyncify'a göre 2,7x hızlıdır ama tek işçide atomik ARC maliyeti taşır. Modüller 60-125 KB'dır.

### Tarayıcıda

`createHost`/`runNox` tarayıcıda olduğu gibi çalışır; `--asyncify` modülleri de (saf wasm). İş parçacıklı `wasm32-freestanding-threads` modülleri için `runNoxThreads(bytes, io)` kullanılır: ana wasm iş parçacığı bir Worker olarak çalışır (sayfa `Atomics.wait` yapamaz), tüm Worker'ları sayfa oluşturur ve çıktı/çıkış kodu sayfaya iletilir. Sayfa `crossOriginIsolated` olmalıdır (`Cross-Origin-Opener-Policy: same-origin` ve `Cross-Origin-Embedder-Policy: require-corp`). `examples/wasm-browser/` bir örnek sayfa ve bu başlıkları ekleyen küçük bir sunucu içerir:

```bash
noxc build --target wasm32-freestanding-threads prog.nox -o examples/wasm-browser/prog.wasm
node examples/wasm-browser/serve.mjs      # http://127.0.0.1:8123/examples/wasm-browser/index.html?wasm=prog.wasm
```

Chromium'da doğrulandı: varsayılan, `--asyncify` ve `--threads` kipleri (200 iş parçacıklı `thread_spawn_stress` ve paylaşımlı atomik sayaç dahil) native ile aynı çıktıyı verir. Firefox ve Safari denenmedi. `wasm32-wasi` modülleri tarayıcıda bir WASI dolgusu gerektirir (`nox_host` yerine WASI import'ları); `wasm_host.mjs` WASI'yi yalnızca Node'da sağlar.

### Başka motorlar

`wasm32-wasi` ve `wasm32-wasi-asyncify` modülleri `wasmtime` ile de çalışır (`noxc run` zaten onu tercih eder): tüm fixture korpusu `scripts/wasm_corpus.py --target wasm32-wasi --engine wasmtime` ile sıfır farkla geçer. İş parçacıklı modüller wasmtime/wasmer'da çalışmaz (wasi-threads kaldırıldı); onlar için `wasm_host.mjs` ya da `thread_spawn` sözleşmesini uygulayan bir host gerekir.

## `--asyncify`: gerçek fiber

```bash
noxc build --target wasm32-wasi --asyncify prog.nox -o prog.wasm     # wasm-opt (binaryen) gerekir
noxc run   --target wasm32-freestanding --asyncify prog.nox
```

`--asyncify` göreve bekleyen görevleri gerçekten askıya alır (yığın değiştirme): karşılıklı kanal beklemeleri, `nox.thread`/`sleep` sırası ve `async` kalıpları native zamanlayıcıyla aynı sırada çalışır, deadlock sınırı kalkar. Çıktı modül host'tan ek import istemez; her WASM motorunda çalışır. Maliyet: yaklaşık %30–50 yavaşlık/boyut ve `wasm-opt` bağımlılığı ([ADR-014](../internals/adr/014-wasm-asyncify.md)). Paralel çalışma değildir (tek iş parçacığı).

## `--threads`: gerçek paralel M:N

```bash
noxc build --target wasm32-wasi --threads prog.nox -o prog.wasm       # wasm-opt (binaryen) ve node gerekir
NOX_POOL_WORKERS=4 noxc run --target wasm32-wasi --threads prog.nox
```

`--threads`, yerel `--release` çalışma zamanının iş çalan M:N havuzunu WASM'a taşır: `spawn`/`await`, `Channel`, `nox.thread` birden çok iş parçacığında GERÇEKTEN paralel çalışır (paylaşımlı bellek + atomikler). Modül `env.memory` (paylaşımlı) ve `wasi::thread-spawn` içe aktarır; `compiler/wasm_host.mjs` bunları Node Worker'larıyla sağlar (wasmtime 50 `-Sthreads`ı kaldırdığından `noxc run` bu hedefte yalnızca Node kullanır). Başka bir host aynı iki içe aktarımı sağlayarak modülü çalıştırabilir. İşçi sayısı `NOX_POOL_WORKERS` ile ayarlanır. Sınırlar ve gerekçe: [ADR-015](../internals/adr/015-wasm-threads.md); `wasm32-freestanding` için de `--threads` vardır: host `nox_host.thread_spawn(arg) -> tid` sağlar ve her yeni iş parçacığında `nox_host_thread_start(tid, arg)`ı çağırır (paylaşımlı `env.memory` ile).

## SQLite

`nox.sqlite` her WASM hedefinde derlenir; SQLite kütüphanesi programa statik bağlanır (yalnızca `nox.sqlite` kullanan programlar ~700 KB büyür). `wasm32-wasi`'de dosya tabanlı veritabanları host'un ön-açtığı dizinlerde çalışır (`wasmtime run --dir=. app.wasm`) ve çalıştırmalar arasında kalıcıdır; kilitleme yoktur (tek süreç varsayımı). `wasm32-freestanding`'de şimdilik dosya tabanlı veritabanları sanal dosya sisteminde yaşar (aşağıya bakın).

## Sanal dosya sistemi (wasm32-freestanding)

`wasm32-freestanding` modülünde işletim sistemi yoktur; `nox.fs` ve dosya tabanlı `nox.sqlite` çalışma zamanının doğrusal belleğinde yaşayan bir **bellek içi sanal dosya sistemine** gider. Host'a hiçbir import eklenmez, gerçek diske ya da sunucuya hiçbir şey yazılmaz (playground için güvenli). Başlangıçta `/` ve `/tmp` vardır; göreli yollar `/` altında çözülür, `..` kökün üstüne çıkmaz. Varsayılan olarak dosya sistemi program ömrü boyunca yaşar ve çıkışta kaybolur; `--threads` kipinde iş parçacıkları arasında paylaşılır. Kalıcı kılmak için bir sonraki bölüme bakın. `remove_file` açık bir tanıtıcı varken bile güvenlidir (POSIX `unlink` gibi). Sınırlar: sembolik bağ, izin biti ve dizin silme yoktur (`nox.fs` zaten sunmaz); `rename` bir dizini başka bir dizinin üstüne taşıyamaz.

Kalıcılık ya da gerçek bir dizine eşleme gerektiren host'lar için ileride `nox_host`a isteğe bağlı `fs_*` import'ları eklenebilir; bu kırıcı olmaz. `wasm32-wasi`'de dosya işlemleri ise WASI'nin ön-açılmış dizinlerine (`.` ve `/tmp`) gider.

### Kalıcı sanal dosya sistemi

Sanal dosya sistemi **isteğe bağlı olarak kalıcı** yapılabilir: host, modül başlamadan önce ağacı doldurur ve çıkışta anlık görüntüsünü saklar. Bunun için modüle hiçbir import eklenmez; modül (yalnızca `nox.fs`/`nox.sqlite` kullanıyorsa) `nox_vfs_host_alloc/free/put/mkdir/snapshot` dışa aktarımlarını sunar ve host belleği doğrudan okur/yazar. `/tmp` geçici sayılır: hosta yansıtılmaz ve kaydedilmez.

- **Komut satırı (Node):** `noxc run --target wasm32-freestanding --vfs-dir veri/ prog.nox` ya da derlenmiş modülle `node wasm_host.mjs prog.wasm --vfs-dir=veri/` (veya `NOX_VFS_DIR`). Dizin başlangıçta sanal dosya sistemine yüklenir (sembolik bağlar atlanır, en çok 512 MiB), çıkışta geri yazılır: değişen dosyalar geçici dosya + `rename` ile yazılır, değişmeyenlere dokunulmaz, programın sildiği dosyalar diskten silinir. Dosya sistemini kullanmayan bir program dizine dokunmaz.
- **Tarayıcı / kendi host'un:** `runNox(bytes, io, { vfs: { files, onSave } })`; `files` `[{ path, data? }]` (`data` yoksa dizin) ve `onSave(entries)` çıkışta aynı biçimde anlık görüntüyle çağrılır; kaydı IndexedDB/OPFS'e yazmak sana kalmıştır. İş parçacıklı modüller için `runNoxThreads(bytes, io, { vfs: { files, onSave } })` aynı sözleşmeyi uygular. Alt düzey: `vfsPreload(instance, entries)` ve `vfsSnapshot(instance)`.

```js
import { runNox } from './wasm_host.mjs';
const saved = JSON.parse(localStorage.getItem('nox-vfs') ?? '[]').map((e) => ({ path: e.path, data: e.b64 && Uint8Array.from(atob(e.b64), (c) => c.charCodeAt(0)) }));
await runNox(bytes, io, { vfs: {
  files: saved,
  onSave: (entries) => localStorage.setItem('nox-vfs', JSON.stringify(entries.filter((e) => !e.path.startsWith('/tmp')).map((e) => ({ path: e.path, b64: e.data && btoa(String.fromCharCode(...e.data)) })))),
} });
```

Kalıcılık çıkışta yazılır: program çökerse (tuzak) anlık görüntü yine alınır, ama süreç öldürülürse (kill) alınmaz.

## Ağ: `nox.http` istemcisi host `fetch`i ile (wasm32-freestanding --asyncify)

`wasm32-freestanding-asyncify` hedefinde `nox.http.get/post/request` host'un `fetch`ine dayanır (tarayıcıda `window.fetch`, Node'da `globalThis.fetch`, ya da host'un verdiği herhangi bir `fetch` uyumlu işlev). Yetenek **varsayılan olarak kapalıdır**: host açıkça vermedikçe istemci çağrıları yakalanabilir bir `HttpCapabilityError` fırlatır.

```js
import { runNox } from './wasm_host.mjs';
await runNox(bytes, io, { fetch: globalThis.fetch });   // ağ açık
await runNox(bytes, io, { fetch: null });               // ağ kapalı (varsayılan): HttpCapabilityError
```

Komut satırında Node için `noxc run --target wasm32-freestanding-asyncify --allow-net prog.nox` (ya da `NOX_ALLOW_NET=1`). Derleme zamanında `--deny-capability network` modülün ağ kullanmasını tümden yasaklar (playground).

- **Nasıl çalışır.** Ağ çağrısı yapan fiber bekletilir, başka fiber'lar çalışır (`spawn` ile istekler paralel gider); hazır fiber kalmayınca modül çıkış bildirmeden host'a döner, host `fetch`leri bekler, sonuçları iletir ve `nox_host_resume()` ile programı sürdürür. Modüle hiçbir import eklenmez; host yalnızca dışa aktarımları (`nox_host_caps_set`, `nox_host_fetch_pending`, `nox_host_fetch_complete`, `nox_host_status`, `nox_host_resume`, `nox_host_alloc/free`) çağırır. Ayrıntı: spec §3.351. Kendi host'unu yazıyorsan `compiler/wasm_host.mjs`teki `runNox` döngüsü referanstır.
- **Sınırlar.** Yalnızca `--asyncify` freestanding (askıya almak için fiber gerekir); düz freestanding, `--threads` ve `wasm32-wasi` kiplerinde istemci eskisi gibi `HttpCapabilityError` verir. Akışlı istemci (`stream`, `stream_upload`, `nox.transfer`) desteklenir: indirme `fetch` yanıtının okuyucusundan parça parça (yalnızca `read_chunk` çağrıldıkça, geri basınçlı) okunur, `timeout_ms` boşta kalma zaman aşımıdır; yükleme çalışma zamanında tamponlanır ve `finish()` ile tek istek olarak gönderilir (`fetch` yükleme akışı her tarayıcıda yoktur). `get/post/request` yanıtı tümüyle tamponlar. Yönlendirmeleri `fetch` izler. Başlık adları `fetch`in verdiği gibi küçük harflidir. Tarayıcıda CORS ve karışık-içerik kuralları sayfaya aittir. Zaman aşımı `AbortSignal.timeout` ile uygulanır.

## Tarayıcıda derleme

Derleyicinin kendisi de WASM olarak çalışır (sunucusuz playground, gömülü kod deneme alanı): bkz. [Tarayıcıda Nox derleyicisi](browser-compiler.md).

### WebSocket istemcisi

`nox.websocket` (`connect`, `send_text`, `recv`, `is_open`, `close`) tüm WASM hedeflerinde derlenir. `wasm32-freestanding-asyncify`'da host'un `WebSocket`ine dayanır (tarayıcıda `window.WebSocket`, Node 22+ `globalThis.WebSocket`); ağ yeteneği `fetch` ile aynı anahtarla açılır (`runNox(bytes, io, { fetch, WebSocket })`, `--allow-net`). `send_text` yanıtsızdır, `recv` fiber'ı bekletir (diğer fiber'lar çalışır), kapanışta boş `str` döner ve `is_open()` yanlış olur; `wss://` host tarafından yönetilir. Diğer kiplerde ya da yetenek yokken `connect` "network capability" iletisiyle `WebSocketError` fırlatır. İkili iletiler `str` olarak ham baytlarla gelir. Sunucu tarafı (`serve_ws`) WASM'da yoktur.

### Ham TCP: `nox.tls` ve `nox.smtp`

`nox.tls` ve `nox.smtp` tüm WASM hedeflerinde derlenir. `wasm32-freestanding-asyncify`'da gerçek bağlantılar için host **TCP yeteneği** verir: `runNox(bytes, io, { tcp: await nodeTcp() })` (`nodeTcp` Node'un `net`/`tls` modüllerine dayanır; `wasm_host.mjs`ten dışa aktarılır) ya da Node komut satırında `--allow-net`. Tarayıcıda ham soket yoktur: orada `tcp` verilmez ve `connect` "tcp capability" iletisiyle `TlsError`/`SmtpError` verir (kendi `{ connect(host, port, useTls) }` sağlayıcınızı, ör. bir WebSocket-TCP köprüsü, verebilirsiniz). **TLS host'ta sonlanır**: modülde CA paketi ya da el sıkışma kodu yoktur, sertifika doğrulaması (ad dahil) host'un TLS yığınındadır (Node: sistem CA'ları + `NODE_EXTRA_CA_CERTS`). `smtp` STARTTLS yükseltmesi de host'ta yapılır. Akış, `fetch` ile aynı askıya alma mekanizmasıyla çalışır (okuma fiber'ı bekletir, yazma yanıtsızdır). Sınır: `--threads`, düz freestanding ve `wasm32-wasi*` kiplerinde yetenek yoktur.

### PostgreSQL

`nox.postgres` WASM'da `libpq` yerine Zig'de yazılmış bir PostgreSQL protokol 3.0 istemcisiyle çalışır (host TCP yeteneği gerekir, bkz. yukarıdaki "Ham TCP"). Kimlik doğrulama: trust, cleartext, MD5, SCRAM-SHA-256; sorgular: basit protokol (`execute`/`query`) ve genişletilmiş protokol (`prepare` + `bind_*`, metin biçimli parametreler/sonuçlar, `$n` ve `?` yer tutucuları). Bağlantı dizesi hem `host=... port=... user=... password=... dbname=...` hem `postgres://kullanıcı:parola@host:port/db?sslmode=require` biçimindedir. `sslmode=require|verify-ca|verify-full` SSLRequest + host TLS'ini kullanır (sertifikayı host doğrular); diğer kipler düz metindir (libpq'nun `prefer` varsayılanından bilinçli sapma). Sınırlar: `COPY`, `LISTEN/NOTIFY`, ikili biçim ve `PQprepare` adlandırılmış ifadeler yok (yerel sürücüyle aynı kapsam).

### MySQL / MariaDB

`nox.mysql` WASM'da `libmysqlclient` yerine Zig'de yazılmış bir MySQL istemci protokolüyle çalışır (host TCP yeteneği gerekir, bkz. "Ham TCP"). Kimlik doğrulama: `mysql_native_password` ve `caching_sha2_password` (MySQL 8'in varsayılanı: hızlı yol ve, sunucu önbelleği boşken, sunucunun RSA anahtarıyla OAEP şifrelenmiş parolayla tam kimlik doğrulama; TLS gerekmez), kimlik doğrulama eklentisi değiştirme dahil. Sorgular metin protokolüyle (`COM_QUERY`) gider; `prepare` + `bind_*` yerel sürücüyle aynı biçimde istemci tarafında kaçışlanarak (`NO_BACKSLASH_ESCAPES` kipine duyarlı) SQL'e gömülür. `last_insert_rowid()`, `changes()` ve `NULL` ayrımı çalışır. GERÇEK MySQL 8.4 ve MariaDB 11 sunucularına karşı doğrulandı. Sınırlar: TLS yok (`open_url` ayrıca TLS seçeneği taşımaz), `localhost` için de unix soketi yerine TCP kullanılır, `CALL` gibi çoklu sonuç kümelerinde yalnızca ilk sonuç döner, `LOCAL INFILE` yok.

### Alt süreçler (`nox.process`)

`nox.process` tüm WASM hedeflerinde derlenir; çalıştırma bir **host yeteneğidir**. `wasm32-freestanding-asyncify`'da host bir süreç sağlayıcısı verirse (`runNox(bytes, io, { process: await nodeProcess() })` ya da Node komut satırında `--allow-process`, `noxc run --target wasm32-freestanding-asyncify --allow-process`) `Command(...).run()` çalışır; aksi halde `ProcessError` ("could not run the process") verir. Varsayılan Node sağlayıcısı `child_process.spawn`ı KABUKSUZ çağırır (argümanlar kabuk yorumundan geçmez, enjeksiyon yok); çıktı tamponlanır, `set_timeout` aşılırsa süreç öldürülür. Tarayıcıda süreç yoktur (sağlayıcı verilmez). `--allow-net` süreç yeteneğini AÇMAZ: ağ ve süreç ayrı anahtarlardır.

### HTTP sunucusu (`nox.http.serve`)

Sunucu da bir **host yeteneğidir**: modül soket açmaz. `wasm32-freestanding-asyncify`'da host bir `serve` sağlayıcısı verirse (`runNox(bytes, io, { serve: await nodeHttpServer(), serveSignal })`, Node komut satırında `--allow-serve`, `noxc run --target wasm32-freestanding-asyncify --allow-serve`) `nox.http.serve(port, handler)` host üzerinde dinler (`port` 0: host seçer; Node sağlayıcısı varsayılan olarak yalnızca `127.0.0.1`de dinler, `NOX_SERVE_HOST` ile değişir), gelen her isteği modüle iletir ve modül `handler`ı her istek için ayrı bir fiber'da çalıştırır. Handler'lar diğer fiber'lar gibi `nox.http.get` (host `fetch`i), `nox.sqlite`, `nox.fs` kullanabilir; `nox.router`/`nox.web` yapı taşları olduğu gibi çalışır. Sağlayıcı arayüzü: `listen(port, handle) -> Promise<{ port, close() }>`, `handle({ method, target, headers, body, peer }) -> Promise<{ status, headers, body }>`: Node'un `node:http`si yerine Nexus Engine, bir service worker ya da kendi sunucunuz bağlanabilir. `serveSignal` (AbortSignal) abort edilince (`Ctrl-C`/SIGTERM'de CLI bunu yapar) dinleyiciler kapanır, `serve` döner ve program normal biter. Yetenek yoksa `serve` eskisi gibi bir tanı yazıp hemen döner.

Sınırlar: işleyici turları toplu çalışır (bir turdaki istekler eşzamanlıdır; tur bitene kadar gelen yeni istekler sıraya girer); akışlı yanıt (`stream`/`respstream_*`), WebSocket upgrade (`serve_ws`), TLS (host sonlandırır), HTTP/2 ve çok çekirdekli (`serve_multicore`) yoktur; yalnızca `wasm32-freestanding-asyncify`.

## Host güvenlik politikaları

Yetenekler varsayılan olarak kapalıdır; açıldıklarında da host'un `node` sağlayıcıları şu sınırları uygular. Güvenilmeyen kod barındıran bir host (ör. çok kiracılı bir platform) bunları sıkılaştırmalı ya da kendi sağlayıcılarını vermelidir.

- **Ağ izin listesi:** `--net-allow=host[:port],*.alan[:port],...` (ya da `NOX_NET_ALLOW`; `noxc run` ile de verilebilir) `--allow-net` ile birlikte `fetch`, WebSocket ve ham TCP bağlantılarını yalnızca listedeki hedeflerle sınırlar (port yoksa ya da `*` ise her port; `*.alan` apex alan adını kapsamaz). `fetch` yönlendirmeleri elle izlenir ve her hedef yeniden denetlenir. Host adı, modülün verdiği haliyle eşlenir: DNS çözümlemesi sonrası IP denetimi yapılmaz, yani izinli bir adın özel bir IP'ye çözülmesi operatörün sorumluluğundadır. `--threads` modüllerinde desteklenmez (açıkça reddedilir). Programatik karşılıkları: `netPolicy`, `restrictFetch`, `restrictTcp`, `restrictWebSocket`.
- **Süreç izin listesi:** `--allow-process=git,/usr/bin/env` yalnızca listedeki programlara izin verir (yalın `--allow-process` hepsine; program, modülün verdiği haliyle eşlenir, yol araması yapılmaz). `nodeProcess` stdout + stderr toplamını `maxOutputBytes` (varsayılan 16 MiB) ile sınırlar; aşılırsa süreç öldürülür. Programatik karşılığı: `restrictProcess`.
- **HTTP sunucu kotaları:** `nodeHttpServer({ maxBodyBytes: 10 MiB, maxResponseBytes: 64 MiB, requestTimeoutMs: 30000, maxConcurrent: 64 })`. Aşıldığında istemci 413 (gövde), 500 (yanıt), 504 (işleyici süresi) ya da 503 (eşzamanlılık) alır; zaman aşımına uğrayan ya da istemcisi kopan isteklerin yanıtı atılır.
- **`--vfs-dir`:** kök altında bir sembolik bağ varsa çıkışta o yola yazılmaz/silinmez (kök dışına taşma engellenir).
- **Tarayıcıda derleyici:** `compileToIr` seçenekleri (`target`, `deny`, `label`) denetim karakteri içeremez; aksi halde bir `label` içindeki `\ndeny=` ile yetenek kısıtı atlatılabilirdi.
