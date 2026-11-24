# Native runtime — bağımlılık manifesti (Zig oracle, geçici shim, kalıcı platform sağlayıcı)

> Görev belgesi Kural 8 ve G.6: **gizli Zig bağımlılığı başarı sayılmaz**; geçici ile kalıcı ayrılır. "Saf Nox" iddiası kaynak-satır oranıyla değil **bağımlılık kapanışıyla** ölçülür. Bu belge readiness anındaki durumdur; her port adımında güncellenir.

## 1. Sınıflandırma

| Sınıf | Anlamı | Başarıyı etkiler mi |
|---|---|---|
| **A. Nox'a taşınacak (port hedefi)** | Nox'a özgü runtime/ABI adaptasyonu: ARC, ASAP, cycle collector, collections çekirdeği, errors, scheduler/fiber mantığı, str/list/dict çekirdekleri | Evet — final iddiası bunların Nox'ta olmasına bağlı |
| **B. Kalıcı platform sağlayıcı** | OS/libc çağrıları (mmap/VirtualAlloc/futex/epoll/kqueue/WSAPoll/…); kernel allocator hook; assembly (`swap_*.S`, `boot.S`) | Hayır — dürüstçe bildirilir |
| **C. Kalıcı üçüncü-taraf kütüphane** | TLS (OpenSSL/vendored `tls_client.zig`), crypto (`std.crypto`), zlib/zstd/gzip, sqlite3, PostgreSQL/MySQL protokol sürücüleri | Hayır — "tüm kriptoyu yeniden yaz" hedefi yok (G.6) |
| **D. Zig oracle (test referansı)** | `DebugAllocator`, mevcut `arc.zig/asap.zig/cycle_detector.zig` referansı | Test/rollback için KORUNUR; üretim bağımlılığı olmaz |
| **E. Geçici shim** | Nox'ta henüz ifade edilemeyen ilkeller için ince C/asm/Zig köprüsü | Evet — kapanmadan "bağımsız" denmez |

## 2. Geçici shim'ler (E) — readiness anında

| Shim | Dosya | Neden | Kapanış yolu |
|---|---|---|---|
| Ham-adres atomikler | `tests/native_runtime/shim/rtcore_atomic_shim.c` | dilde ham atomik yok (GAP-5) | public atomik API (M.3, `native-runtime-abi.md` §6) ya da kalıcı küçük asm |
| TLS worker slot | aynı dosya `rtcore_tls_*` | dilde TLS ilkeli yok (GAP-6) | platform TLS sağlayıcı sözleşmesi (kalıcı B'ye taşınabilir) |
| Platform allocator sağlayıcısı | `shim/rtcore_provider.c` | spike için hosted `mmap` | hedef başına kalıcı sağlayıcı (B): hosted/WASM/freestanding |
| `rt`'siz export thunk'ları | (henüz yok) | GAP-4 | internal export niteliği |

Bunlar `tests/` altındadır; **üretim runtime'ına dahil değildir**, varsayılan derleme yolu değişmemiştir.

## 3. Zig stdlib kullanım ölçüsü (port etkisi)

(`scripts/native_runtime_inventory.py`; satır içi örnekler regex ile sayılmıştır, üst sınırdır.)

| Bağımlılık | Kullanım | Port notu |
|---|---:|---|
| `std.mem.Allocator` / `std.heap.*` / `DebugAllocator` | 924 site | allocator arayüzü Nox'ta **küçük iç arayüz**dir (F.2), Zig `Allocator`'ın tamamı kopyalanmaz |
| `std.Thread/posix/os/net/c/Io` | 1 125 site | **B sınıfı**: sağlayıcıya iner; `async_rt` (217) + `stdlib_shims` (826) |
| `std.atomic` / `@atomic*` | 482 site | GAP-5 (public API) ile kapanır |
| `threadlocal` | 107 site | GAP-6 sağlayıcı/`rt` parametresi |
| `comptime`/`@Type` | 559 site | GAP-11: build-time üretim; `comptime` taşıma yok |
| `asm`/`global_asm` | 69 site | B sınıfı küçük modüller; algoritmik kod asm'a kaçmaz |

## 4. Kalıcı üçüncü-taraf/harici hizmetler (C) — Zig `std` veya dış kütüphane

| Modül | Bağımlılık |
|---|---|
| `stdlib_shims/tls.zig`, `runtime/vendor/tls_client.zig`, `tls_server` | OpenSSL (çalışma zamanı yükleme, bkz. v1.22.x notu) / vendored TLS istemcisi |
| `crypto.zig`, `tcp_native.zig`, `http_client.zig`, `websocket.zig`, `time.zig` | `std.crypto` (hash/AEAD/imza) |
| `gzip/zlib/zstd/zip/tar` | `std.compress` + `runtime/c_glue/zstd_glue.c` |
| `sqlite.zig` | `libsqlite3` (tembel `DynLib`) |
| `postgres.zig`, `mysql*.zig`, `redis.zig` | Nox'a özgü protokol çerçevesi (port hedefi A/C karışık) |
| `hpy_bridge/*`, `foreign_bridge.zig`, NNI/NAPI | public ABI sınırı; **değişmez** (R7) |
| `wasm_bridge/*` (4,2 K LOC) | gömülü WASM yorumlayıcısı — Nox'a özgü ama büyük; port önceliği düşük |

## 5. Araç zinciri bağımlılığı (M.9 — karar kullanıcıda)

Bugün: `zig build` (runtime + derleyici), `clang` (varsayılan LLVM backend), `qbe` (+`cc`), `zig cc` (masaüstü `--target` çapraz derleme; `--selfhost-obj` yoksa `zig cc -c`). Readiness sonucu: runtime'ın Nox'ta yazılması **Zig dilini** bağımlılıktan çıkarmayı hedefleyebilir ama `zig cc` çapraz linker olarak kalabilir. **Kullanıcı kararı (M.9, 2026-11-24): `zig cc` dahil tam toolchain bağımsızlığı BU projenin kapsamındadır** (migration-plan R9). Bu, final kriterini genişletir: R8 (Zig runtime'sız) yeterli değildir; masaüstü `--target` çapraz derlemesi ve `--selfhost-obj` yedek yolu `zig cc`'siz çalışmalıdır. Bugünkü `zig cc` kullanım noktaları (`compiler/main.zig` `ccDriver`, hedef çapraz bağlama) R9 başında envanterlenir.

## 6. Bağımlılık kapanışı nasıl ölçülür (final iddia)

Her port adımında: (1) çıktı runtime nesnesinde `nm -u` ⇒ yalnız manifestte izinli sağlayıcı sembolleri; (2) Zig runtime nesneleri link satırında yok; (3) Zig executable olmayan temiz ortamda build/run (R8, seçilen bağımsızlık kapsamına göre); (4) `runtime_leaf_audit.py` türü kapılar L0–L2 çekirdeği için CI'da. Bu readiness'ta (1)–(2) yalnız leaf kapsamı için P01–P06 ile kanıtlanmıştır; gerçek runtime için henüz **değildir**.
