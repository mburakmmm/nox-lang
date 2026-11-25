# Native runtime — mimari: katmanlar, bağımlılık DAG'ı, bootstrap, güvenlik, platform

> Readiness çıktısı (R0–R3). Görev belgesi Bölüm F/G/H. Rakamlar `scripts/native_runtime_inventory.py` ve `--dag` çıktısındandır (v2.2.64 öncesi `main`).

## 1. Zig runtime'ın bugünkü boyutu (envanter)

| Dizin | Dosya | LOC | export fn | atomik | TLS | extern | allocator | OS | comptime | asm |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `runtime/` (kök) | 31 | 21 630 | 134 | 9 | 5 | 12 | 75 | 20 | 60 | 14 |
| `runtime/alloc` | 8 | 5 057 | 50 | 59 | 14 | 14 | 104 | 23 | 39 | 4 |
| `runtime/async_rt` | 28 | 11 794 | 71 | 198 | 37 | 30 | 253 | 217 | 105 | 30 |
| `runtime/collections` | 4 | 2 364 | 53 | 3 | 1 | 0 | 10 | 11 | 11 | 0 |
| `runtime/errors` | 2 | 381 | 8 | 8 | 1 | 0 | 1 | 4 | 8 | 0 |
| `runtime/freestanding/*` | 7 | 1 133 | 15 | 0 | 1 | 2 | 0 | 0 | 0 | 19 |
| ~~`runtime/hpy_bridge`~~ | — | — | — | — | — | — | — | — | — | — | (v2.2.69'da KALDIRILDI: ~5 800 satır port kapsamı dışı)
| `runtime/stdlib_shims` | 72 | 41 191 | 692 | 160 | 46 | 110 | 419 | 826 | 267 | 2 |
| `runtime/wasm_bridge` | 7 | 4 243 | 0 | 45 | 0 | 3 | 25 | 7 | 63 | 0 |
| `shared/` | 3 | 1 682 | 0 | 0 | 0 | 5 | 15 | 8 | 3 | 0 |
| **Toplam** | **166** | **95 262** | **1 023** | **482** | **107** | **180** | **924** | **1 125** | **559** | **69** |

Okuma: portun gerçek konusu **ARC/alloc/errors/collections (≈7,8 K LOC, 119 export)** ile **async_rt (11,8 K)**'dir; `stdlib_shims` (41 K LOC, 692 export) büyük ölçüde OS/üçüncü-taraf sağlayıcı sınırıdır ve "kalıcı dış bağımlılık" manifestine girer (`native-runtime-dependencies.md`). `comptime` yoğunluğu (559) Zig-özgü hedef/tip yansıtmanın bir Nox karşılığı gerektirdiğini gösterir (GAP-11: build-time üretim, `comptime` taşıma YOK).

## 2. Katmanlar (görev belgesi F.1) → bugünkü dosyalar

```text
L0  Platform ABI + assembly        swap_{x86_64,aarch64,riscv64}.S, freestanding/*/boot.S + kernel.ld, OS syscalls (mmap/VirtualAlloc/kernel hook)
L1  Ham ilkeller + fatal + cold    errors/handle.zig (pending), lib_freestanding early_init, diag_sink.zig
L2  Ham allocator/state            alloc/asap.zig (RuntimeState, rawAlloc), size_class_heap.zig (freestanding), alloc/lowlevel.zig (arena)
L3  ARC/ASAP kancaları             alloc/arc.zig, dispatch_registry.zig, defer_stack.zig, shared/abi_layout.zig
L4  Döngü toplayıcı + dispatch     alloc/cycle_detector.zig, collections/{list_ops,dict,…}.zig, errors/
L5  Scheduler/fiber/worker/IO      async_rt/{fiber,scheduler,worker_pool,io,io_reactor,channel,…}.zig
L6  Native stdlib shim + köprüler  stdlib_shims/* (692 export), wasm_bridge, wasm_call, NNI (hpy_bridge v2.2.69'da kaldırıldı)
L7  Nox programı / derleyici
```

**Readiness'ta kanıtlanan aşağıdan-yukarı kapsam:** L0 sağlayıcısı (P04/P06 `rtcore_provider.c`), L1 fatal sink (P04, `rtcore_fatal`), L2 raw allocator + durum makinesi (P06). L3 (ARC) için P09 (mini ARC), L5 için P11 (fiber bağlamı), P12 (QEMU), R3b/R6 öncesi spike'lar olarak planlanmıştır (bkz. migration-plan; bu turda koşulmadı, başarı sayılmadı).

## 3. `@import` bağımlılık DAG'ı (kanıt; `--dag`)

`python3 scripts/native_runtime_inventory.py --dag`:

- 160 Zig dosyası, 714 kenar. **Yalnız 3 döngülü bileşen**: `async_rt/{io,io_reactor,scheduler}.zig`, `wasm_bridge/{compile,interp,simd}.zig`, `stdlib_shims/{fiber_net,net_dial}.zig`. Geri kalanı DAG'dır (155 SCC).
- Topolojik katmanlama (derinlik): taban L0 (33 dosya: `abi_ptr`, `ptr_map`, `atomic64`, `chase_lev_deque`, `size_class_heap`, `diag_sink`, …) → `asap.zig` (L3) → `arc.zig` (L5) → `cycle_detector.zig`, `str.zig`, `shared_obj.zig` (L6) → collections/format/json (L7) → … → `lib.zig` (L20).
- **Önemli:** dosya-seviyeli `@import` DAG'ı, fonksiyon-seviyeli bağımlılık döngülerinin yokluğunu KANITLAMAZ. `asap.zig` (L3) scheduler döngüsüyle (L3) aynı katmandadır ve `arc.zig` hem `asap` hem scheduler tarafını çağırır; port sırası bu yüzden **fonksiyon-seviyeli** gerçek döngülere göre (§4) belirlenir, dosya sırasına göre DEĞİL.

### Port bağımlılık sırası (öneri; her adımın kapısı migration-plan'da)

1. **Yaprak algoritmalar** (hash, bayt/sayısal yardımcılar, dict/list saf çekirdekleri) — L0 yaprak dosyaları; ARC'ye bağımlı DEĞİL.
2. **L2 allocator** (asap `rawAlloc` ailesi + `size_class_heap`) — P06 spike'ı bu katmanın kanıtıdır.
3. **L3 ARC çekirdeği** (`arc.zig`: retain/release/header/pool) — allocator'a bağımlı; döngü yok ama `cycle_detector` ile karşılıklı sözleşme (`nox_cycle_possible_root`) → hazır-olma fazları (§4).
4. **L4** cycle_detector (aynı algoritma), errors/handle (pending exception: yalnız `rt` alanı + açık fatal).
5. **L5** scheduler/fiber (assembly bağlantısı korunur; P11 önkoşul).
6. **L6** shim'ler modül-modül; üçüncü-taraf (TLS/crypto/regex/sqlite/zstd) kalıcı sağlayıcı.

## 4. Bootstrap ve durum makinesi

`UNINITIALIZED → BOOTSTRAP → CORE_READY → (GC_READY → SCHEDULER_READY →) RUNNING → SHUTTING_DOWN → DEAD`.

P06 bunun L2 kısmını gerçekleştirir ve test eder: `rt_init` (0 / −1 çift init, durum değişmez / −2 platform OOM, 0 durumuna **geri alındı**), `rt_fini` (sızıntı sayısını döner; hazır değilken −1 ⇒ çift fini reddedilir; tüm chunk'lar platforma iade; DEAD'de tahsis yok), aynı süreçte tekrar yarat/yık ×3, `g_mapped_bytes == 0` doğrulaması.

**Döngü çözme ilkesi (F.1):** her katmanın başka bir yüksek katmana ihtiyacı **link-zamanı sembol sağlayıcıyla** (indirect çağrı yok; derleyici kapısı doğrular) ya da **açık hazır-olma fazı** ile çözülür:

| Döngü | Çözüm |
|---|---|
| allocator ⇄ platform | allocator yalnız `rtcore_os_map/unmap/fatal` (L0 sağlayıcı) çağırır; platform allocator'a ihtiyaç duymaz (P06) |
| ARC ⇄ cycle collector | `CORE_READY`'de ARC yalnız `possible_root` kuyruğuna yazar (tahsissiz iç liste); toplayıcı `GC_READY`'de açılır; erken fazda kök biriktirme sınırlı + OOM = fail-stop |
| ARC/alloc ⇄ scheduler (STW) | `SCHEDULER_READY` öncesi tek-iş-parçacıklı alt küme; worker kaydı `g_worker_slot` TLS sağlayıcısı (GAP-6) |
| errors ⇄ alloc | leaf/L1-L2 yolları **istisna nesnesi yaratmaz** (B.4): kod dönüşü / `rtcore_fatal`; yönetilen istisna L3+ |

**Allocation-free fatal:** `rtcore_fatal(kod)` yalnız `write`+`_exit` (P04/P06); `fatal` yolu allocator/lock/ARC çağırmaz. Freestanding'de aynı sembol seri sink + halt ile sağlanır (kernel sağlayıcısı).

## 5. Debug güvenlik stratejisi ve fault injection (F.4)

Kayıp riski: `std.heap.DebugAllocator` bugün sızıntı/double-free/use-after-free oracle'ıdır. Nox-native core'un eşdeğer yetenekleri **katmanlı** ve **performans ölçümünden ayrı build** olarak planlanır:

| Yetenek | Spike'ta | Plan |
|---|---|---|
| Ledger (canlı sayaç/bayt), çıkışta sızıntı raporu | ✅ P06 (`ra_live_count/bytes`, `rt_fini` dönüşü, dış `mapped==0`) | kalıcı: tahsis-başına site kimliği (opsiyonel) |
| Double-free / geçersiz başlık | ✅ P06 (magic `LIVE`→`DEAD`, `rtcore_fatal(2)`) | + serbest listede magic taraması (Debug) |
| Canary / taşma tespiti | ✅ P06 (`flags&1`, 16 B kuyruk) | + öncü canary, redzone/quarantine |
| Fault injection (N'inci map OOM) | ✅ sağlayıcı `g_fail_after` | + allocator-içi N'inci tahsis/realloc, kapasite sınırı, fuzz sürücüsü |
| Use-after-free | ❌ | quarantine + poison deseni (Debug); ASan harici oracle |
| Allocation/RC tracing, stack trace | ❌ | Debug-only, **kendi bookkeeping'ini yeniden tetiklemeyen** statik halka tampon |
| Harici oracle | Zig `DebugAllocator` (referans runtime) | **Zig oracle test sürelerinde korunur**; üretim runtime'ı ona bağımlı olmaz (görev belgesi F.4) |

Debug ve ReleaseFast ayrı derlenir; ölçümler yalnız ReleaseFast ile alınır (`native-runtime-performance.md`).

## 6. Platform, assembly, TLS sınırı

- **Assembly (korunur, küçük, denetlenebilir):** `async_rt/swap_{x86_64,aarch64,riscv64}.S` (bağlam anahtarı; callee-saved/FP durumu/stack hizası), `freestanding/*/boot.S` + `kernel.ld`; satır-içi `asm volatile`: `fiber.zig` (3), `alloc/lowlevel.zig` (4), `freestanding/*/kernel.zig` (9), `thread_spawn.zig`, `wasm_*`. Inline assembly Nox'ta **gerekli değildir**; bu dosyalar `extern def` + bağlı nesne ile kullanılır (bağlama P11 spike'ı R6 öncesi).
- **TLS:** 107 `threadlocal` site; en kritik `asap.zig:782 g_worker_slot`, `scheduler.zig:159`, `bridge_native.zig:88`, `thread_spawn.zig:47`. Strateji: açık `RuntimeState*` (zaten hidden `rt`) + yalnız **worker slot** için `rtcore_tls_*` sağlayıcısı (P05 kanıtı). Windows TLS, WASM threads (`asyncify.zig` TLS), freestanding tek çekirdek ayrı sağlayıcı gerçekleştirimleri.
- **Platform sağlayıcı sınırı (M.4 önerisi — karar kullanıcıda):** libc/OS çağrıları kabul edilebilir kalıcı sağlayıcıdır (mmap/VirtualAlloc/kernel hook, write, futex/WaitOnAddress, epoll/kqueue/WSAPoll); Nox allocator'ı başka yönetilen Nox nesnesiyle başlatılmaz.

## 7. İki yönlü yaşayan doğruluk kaynakları

ABI tek doğruluk kaynağı: `shared/abi_layout.zig` → makine-okunur `project/native-runtime-layout.tsv` (+ sembol manifesti `native-runtime-symbols.tsv`); `--check` drift denetler (bkz. `native-runtime-abi.md`). Layout için Zig/Nox/C/asm ortak üretilmiş assertion R2b'de (P03 kalıbı: `offsetof/sizeof` Nox ↔ C struct).
