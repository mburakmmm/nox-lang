# NOX — NATIVE RUNTIME READINESS AUDIT & ROADMAP
## Self-hosting sonrası saf Nox runtime geliştirmesine hazırlık

| Alan | Değer |
|---|---|
| Belge amacı | Agent için teknik inceleme, capability gap analizi ve aşamalı uygulama kuralları |
| Kaynak referansı | `mburakmmm/nox-lang`, `main`, v2.2.44 (`build.zig.zon`) |
| Tarih | 20 Kasım 2026 |
| Önerilen proje adı | Nox Native Runtime / Runtime Readiness |
| Ön koşul | Self-hosting, Technical Hardening ve Engineering & Performance Audit aşamalarının kabul kriterlerinin tamamlanması |
| Durum | Gelecekte uygulanacak plan; bugünkü self-hosting iş akışını değiştirmez |

---

## 1. Amaç ve kapsam

Nox derleyicisinin kendi kendini derleyebilmesi ilk büyük hedeftir. Bunun ardından mevcut Zig runtime'ının mümkün olan en büyük bölümünü Nox ile yeniden yazabilecek dil ve compiler altyapısına ulaşılması hedeflenmektedir.

Bu belge runtime'ın hemen port edilmesi için talimat değildir. Runtime portuna başlamadan önce Nox'un dil, codegen, bellek temsili, ABI, atomik işlemler, platform ve bootstrap altyapısı açısından yeterliliğini kanıtlamayı amaçlar. Bugün mevcut olan özellikler yeniden icat edilmeyecektir. Eksik olduğu varsayılan özellikler önce araştırılacak, minimal reproducer ile sınanacaktır.

Nihai hedef Go benzeri bir kendi kendine yeterlilik düzeyidir: derleyici ve Nox'a özgü runtime kaynakları Nox ile yazılabilir; gerekli mimariye özgü assembly, işletim sistemi ABI'leri, platform kütüphaneleri ve harici backend'ler varlıklarını sürdürebilir. Bu hedef LLVM, QBE, libc, OS veya assembly bağımlılıklarının tamamını ortadan kaldırma zorunluluğu anlamına gelmez.

### 1.1 Üç bağımsız başarı tanımı

| Katman | Başarı tanımı |
|---|---|
| Derleyici self-hosting | Nox ile yazılmış compiler, kendisini önceki Nox compiler ile derleyebilir; bootstrap sabit noktası doğrulanmıştır. |
| Native runtime | Nox'a özgü runtime çekirdeği eski Zig runtime'ına bağımlı olmadan Nox ile derlenip çalışır. Platform/assembly sınırı açıkça tanımlıdır. |
| Toolchain bağımsızlığı | Kurulum, build ve target linking için Zig diline ve gerekiyorsa Zig executable'ına artık ihtiyaç yoktur. LLVM/QBE/clang/lld gibi araçların kalması ayrı bir karardır. |

Bu üç hedef birbirine eşit değildir. Birincinin tamamlanması ikincinin hazır olduğunu, ikincinin tamamlanması üçüncünün sağlandığını kanıtlamaz.

### 1.2 Korunacak tasarım

- Python benzeri sözdizimi, zorunlu statik tip sistemi, otomatik sahiplik yönetimi.
- ASAP, ARC, escape analysis, stack/arena optimizasyonları ve mevcut Bacon–Rajan cycle collector algoritması.
- M:N worker/fiber mimarisi, mevcut paylaşım ve publication kuralları.
- Kaynak uyumluluğu ve desteklenen NNI/NAPI/HPy/FFI sözleşmeleri.
- QBE ve LLVM backend desteği; WASM, freestanding, mobil ve hosted platformlar.
- Performans ve bellek güvenliği. Runtime'ın Nox ile yazılması tek başına performans kazancı değildir.

Kendi native backend'ini, assembler'ını veya linker'ını yazmak, yeni GC algoritmasına geçmek, preemptive scheduling veya büyüyen fiber stack'leri geliştirmek bu belgenin kapsamı dışındadır. Bunlara yalnız ayrı kullanıcı onayı ile başlanır.

---

## 2. Bağlayıcı agent kuralları

1. Güncel `AGENTS.md`, `VERSIONING.md`, spesifikasyon, ABI ve platform sözleşmelerini oku. Bu belge güncel kuralları geçersiz kılmaz.
2. Önceki self-hosting aşamalarının tamamlanmasını bekle. Bu iş için halen geliştirilmekte olan derleyicinin çalışma planını kendiliğinden değiştirme.
3. Çalışmaya başlanacağı gün güncel tag/commit belirle. v2.2.44 incelemesini mutlak güncel gerçek gibi kullanma.
4. Mevcut her capability'yi **mevcut / kısmi / kanıtlanmadı / eksik / gerekli değil** olarak sınıflandır. Çalışan bir özelliği yeniden geliştirme.
5. Yeni keyword, decorator, ownership sözdizimi, genel tip davranışı veya public API eklemeden önce mevcut mekanizmaları dene. Kullanıcı onayı gereken tasarımları öneri olarak sun.
6. Runtime geliştirme yetkisi normal uygulamalara otomatik verilmemelidir. Ayrı, açıkça seçilen internal build profile veya compiler doğrulama kipi tercih edilir.
7. Her aşamada kaynak, ABI, codegen, object-file ve çalıştırma seviyesinde kanıt üret. Sadece başarılı typecheck veya link yeterli değildir.
8. Geçici Zig adapter'ları açık manifestte listelenmeli; geçici ve kalıcı ayrılmalıdır. Gizli Zig bağımlılığı başarı sayılmaz.
9. Ölçüm alınmadan performans optimizasyonu zorunlu tutulmayacak. Güvenlik problemi workaround ile kapatılmayacak.
10. Aynı anda hem runtime davranışını hem algoritmasını hem nesne layout'unu değiştirme. Önce eşdeğer port, sonra ayrı optimizasyon.
11. Zig referans implementasyonunu ve çalışan bootstrap binary'lerini koru; eski runtime'a dönülebilir bir yol bırak.
12. Eksik platform testi, unsupported configuration, skip ve başarısız test ayrı raporlanacak. Ortak crash, ortak timeout veya sahte stub başarı değildir.

---

# BÖLÜM A — MEVCUT NOX YETENEKLERİ VE GERÇEK AÇIKLAR

## A.1 Kaynak incelemesiyle görülen mevcut temel

| Yetenek | v2.2.44'te görülen durum | Runtime açısından değerlendirme |
|---|---|---|
| `u8…u64`, `i8…i64`, `usize`, `isize` | Mevcut | Yeniden ekleme yok; target width, overflow ve bit işlemleri doğrulanmalı. |
| `ptr`, `ptr[T]`, `ptr_read/write/offset`, adres dönüşümleri | Mevcut | Ham runtime verisine erişmek için uygun temel; gizli çağrılar ve alignment doğrulanmalı. |
| `ptr_read_volatile`, `ptr_write_volatile`, `memory_fence`, `compiler_fence` | Mevcut | MMIO ve ordering temeli; volatile atomik erişim değildir. |
| `sizeof`, `alignof`, `offsetof`, `@repr("C")`, `@packed` | Mevcut | C uyumlu layout mevcut; yönetimsiz kayıt, inline aggregate ve raw storage yeterliliği kanıtlanmalı. |
| `lowlevel` | Arena ağırlıklı allocation stratejisi, raw pointer güven sınırı | Runtime'sız yürütme garantisi DEĞİL. |
| `nox.mem.copy/move/set` | Typed pointer yardımcıları | Genel runtime'ı çağırmadan lowering olup olmadığı incelenmeli. |
| `nox.buffer.Buffer` ve `Span` | Mevcut yüksek seviyeli yardımcı sınıflar | Raw allocator primitive veya runtime-free slice ile aynı şey değil. |
| `nox.bits` | Rotasyon, byte swap, endian ve mask yardımcıları | Gerekli işlemlerin compiler lowering ve hızını değerlendir. |
| `nox.atomic` | AtomicInt, AtomicBool, AtomicRef; native shim çağrıları | Arbitrary raw adreste, allocation-free atomics ve explicit memory order gereksinimi ayrıca incelenmeli. |
| `extern def`, FFI callback, `with_rt` | Mevcut | Hosted FFI runtime'sız C/OS export ABI ile aynı şey değil. |
| `--selfhost-obj` | Native LLVM, main'siz object ve lib init/fini | Runtime'ın kendi nesnesini üretmek için gereken standalone/cross-target bootstrap garantisi henüz kanıtlanmış değil. |
| `--profile freestanding` | QBE, harici kernel allocator ve Zig runtime | OS'siz çalışmak runtime'sız çalışmak anlamına gelmez. |
| Assembly fiber context switch | `swap_*.S` | Mevcut kod korunabilir; inline assembly zorunlu değildir. |
| Runtime allocator injection | Freestanding kernel hook ve Zig allocator arayüzleri | Nox tarafında bağımsız allocator interface ve cold start doğrulaması gerekir. |
| RuntimeState / ABI | Hidden runtime parametresi, private layout ve runtime export'ları | Ortak sözleşme var; iki implementasyonun birlikte taşınması için manifest/generation gerekir. |
| Platform boot | x86-64, AArch64, RISC-V QEMU referans zincirleri | Runtime bootstrap için değerli altyapı; güncel testlerle yeniden kanıtlanmalı. |

Bu tablo kısmi kaynak incelemesidir; her compiler özelliğinin bütün varyantlarının bağımsız conformance testi yapılmış değildir.

## A.2 Kanıtlanmış mimari bağımlılıklar

### R0.1 — `lowlevel` ile runtime-free yürütmenin karıştırılması

`docs/language/memory.md`, `compiler/codegen_qbe/stmt.zig` ve `runtime/alloc/lowlevel.zig` incelendiğinde `lowlevel` bloğunun gerektiğinde `nox_arena_create` ve `nox_arena_destroy` çağrıları ürettiği, bazı durumlarda arena'nın compiler tarafından elendiği görülmektedir.

Bunun anlamı: bir allocator'ı `lowlevel` içerisinde yazmak tek başına allocator'ın kendisine ihtiyaç duymayacağını garanti etmez. Bir program belirli optimizasyon altında tesadüfen runtime'sız derlenebilir; bu mimari bir sözleşme değildir.

**Gereken araştırma:** runtime leaf/core fonksiyonlarının transitive call graph boyunca hiçbir yasak runtime bağımlılığı taşımadığını compile-time ve post-link doğrulayacak mekanizma.

### R0.2 — Mevcut atomik API runtime shim'lerine bağlı

`stdlib/nox/atomic.nox` içindeki `nox_atomic_*` extern fonksiyonları `noxrt.o` ile bağlanır. `AtomicInt` ve `AtomicBool` ayrı bir hücre handle'ı kullanır; AtomicRef string snapshot mekanizmasıdır.

Bunları kullanmak, ARC başlığındaki bit alanı, lock word veya scheduler kuyruğundaki mevcut bir alanı allocation-free biçimde atomik güncelleyebilmekle aynı değildir.

**Gereken araştırma:** raw-address atomik primitive'lerin ve ordering kontrolünün mevcut intrinsics/codegen üzerinden mümkün olup olmadığı.

### R0.3 — Object üretimi runtime bootstrap için özel değil

`compiler/main.zig` içindeki `--selfhost-obj`, native LLVM ve hedefsiz nesne üretimine bağlıdır. `nox_lib_init`/`nox_lib_fini` ve mevcut hidden runtime parametresi sözleşmesini kullanır. Bugünkü freestanding profil QBE kullanır ve Zig runtime ile link edilir.

**Gereken araştırma:** entry point, calling convention ve runtime dependency kontrolü içeren internal runtime object üretim kipi. Mevcut object mode mümkün olduğunca genişletilmeli, gereksiz ikinci compiler oluşturulmamalıdır.

### R0.4 — Zig allocator ve platform soyutlamalarına bağlılık

`runtime/alloc/asap.zig` içerisinde `RuntimeState`, `std.mem.Allocator`, `std.heap.page_allocator`, `std.heap.smp_allocator`, `DebugAllocator` ve `threadlocal` durumları kullanılmaktadır.

Saf Nox runtime portu, Zig standard library'nin bu hizmetlerini otomatik olarak kazanmayacaktır. Eşdeğer primitive'ler veya açık platform adaptörleri ve aynı güvenlik gözlemlenebilirliği gerekir.

---

# BÖLÜM B — EN KRİTİK GEREKSİNİM: RUNTIME'DAN BAĞIMSIZ NOX ÇEKİRDEĞİ

## B.1 Önerilen internal runtime build profile

İsimler yalnız öneridir: `--profile runtime-core`, internal `runtime_leaf` veya benzeri capability işaretleri. Yeni public syntax zorunlu değildir. Agent mevcut profile/metadata altyapısını önce değerlendirir.

Hedef iki farklı yürütme düzeyini açıkça ayırmaktır:

| Düzey | İzin verilenler | Bağımlılık |
|---|---|---|
| Leaf/bootstrap | Scalar, raw pointer, açık stack storage, raw atomics, kontrollü platform çağrıları | Hazır Nox runtime yok |
| Runtime core | Leaf fonksiyonları, açık allocator/provider, hazır olduğu kanıtlanmış alt runtime servisleri | Yalnız önceki katmanlar |
| Managed runtime helpers | Normal Nox değerleri, ARC ve standart hata mekanizması | Başlatılmış runtime; reentrancy kurallarına bağlı |
| Normal uygulama | Mevcut dilin tamamı | Mevcut runtime sözleşmesi |

Bu ayrım sayesinde scheduler'ın her satırını yönetimsiz biçimde yazmak gerekmez. Runtime'ın kendisine bağımlı sıcak/başlatma yolları ile güvenle managed kod kullanabilecek yardımcı yollar farklı tutulur.

## B.2 Compile-time kısıt ve effect denetimi

Leaf fonksiyonda aşağıdakiler üretilmemelidir (açıkça onaylanmış bağımlılık hariç):

- Heap allocation, ARC header oluşturma, retain/release, GC root registration.
- Arena create/destroy veya gizli arena allocation.
- RuntimeState gerektiren implicit giriş/çıkış, globals lookup.
- Exception object allocation ve normal exception propagation.
- Managed string oluşturma, string formatting, `print` ve panic'in managed sürümü.
- `list`, `dict`, class, boxed enum, closure veya generic specialization yoluyla gizli heap allocation.
- Async/task/channel runtime girişi, managed callback trampoline.
- Implicit stack growth veya stack guard oluşturma için hazır scheduler çağrısı.
- Runtime'ın henüz hazır olmayan katmanına giden herhangi bir fonksiyon çağrısı.

Yalnız AST syntactic whitelist yeterli değildir. Transitive call graph, generic instantiation, indirect call ve codegen'in sonradan eklediği helper çağrıları da kontrol edilmelidir. Bilinmeyen callback/function pointer varsayılan olarak yasaklanmalı veya doğrulanmış capability sözleşmesi gerektirmelidir. Recursion otomatik yasaklanmak zorunda değildir; bootstrap/fatal yollarında sınırlı stack tüketimi kanıtlanmalıdır.

### B.3 IR/object denetimi

- LLVM IR ve QBE IR'da implicit runtime çağrılarını kontrol et.
- Undefined symbol ve relocation listesi üret (`nm`, `readelf`, `llvm-nm`, `otool` veya platform eşdeğeri).
- `memcpy`, `memset`, compiler-rt/libgcc helper, stack protector, sanitizer, profiling ve division helper'ları belirle.
- Yalnız onaylı platform sembolleri ve önceki katmanlara izin ver.
- TLS, static storage, init array, unwinding ve runtime initializer bağımlılıklarını kontrol et.
- Link-time dead code elimination'a güvenerek yasak çağrıyı source/codegen aşamasında gizleme.
- Her backend'de ve hedefte gerçek objeyi kontrol et. Sadece optimize edilmiş tek konfigürasyonla yeterlilik ilan etme.

**Kabul:** Eski `noxrt.o` bağlanmadan, normal runtime başlatılmadan, basit bir Nox leaf object native harness tarafından çağrılabilir ve doğru sonuç döndürür. Kasıtlı olarak managed allocation eklenen negatif fixture build aşamasında reddedilir.

## B.4 Hata modeli: allocation-free failure path

Allocator, ARC, bootstrap, fatal error ve GC OOM yolları normal exception nesnesi yaratamaz.

Gerekli davranış:

- Açık hata kodu/null dönüşü veya mevcut sözleşmenin fail-stop yolu.
- Allocation ve lock recursion içermeyen fatal diagnostic.
- Bootstrap öncesi de çalışabilen minimal stderr/serial/host callback sink.
- Kısmi init, çift init/fini, init failure ve shutdown durumlarının explicit state machine ile yönetimi.
- Normal Nox exception semantiği üst katmanda korunmalı; leaf kipindeki hata politikası public dil davranışını değiştirmemeli.

---

# BÖLÜM C — RAW VERİ TEMSİLİ, TİP VE BELLEK İŞLEMLERİ

## C.1 Yönetimsiz kayıtlar (raw aggregate) ve kesin layout

Mevcut `@repr("C")` ve `@packed` sınıf desteği tekrar geliştirilmemelidir. Ancak C uyumlu alan ofsetleri ile ARC'siz, doğrudan raw storage içinde yaşayabilen bir değer tipi aynı özellik değildir.

Önce mevcut mekanizmalarla şu kullanım biçimlerini test et:

- Stack veya platform tarafından ayrılan byte storage içine type-safe kayıt yerleştirme.
- Bir kaydı nesne olarak heap'e tahsis etmeden oluşturma/ilklendirme.
- Inline nested record ve sabit uzunluklu array alanları.
- Intrusive linked list, freelist node, queue node ve bit alanları.
- Pointer olarak alanlara erişme; `address_of` ve raw pointer'a uygun layout.
- C struct ABI'ye pointer ile erişim. By-value aggregate ABI ancak gerçekten gerekiyorsa ayrı çalışma.
- Alignment, padding, trailing flexible storage, tagged union/payload layout.

Gerçek bir raw record gap kanıtlanırsa mevcut attribute/type mekanizması genişletme, internal generated accessor veya yeni internal storage temsili alternatiflerini değerlendir. Yeni public `struct`, `union`, `value` keyword'ü otomatik olarak eklenmeyecektir.

**Kabul:** RuntimeState prefix, ARC header, list header, allocator node ve scheduler context kayıtlarını ARC nesnesi yaratmadan ifade edebilmek; Zig/C harness ile `sizeof`, `alignof`, `offsetof`, byte pattern ve roundtrip karşılaştırması. Assembly ile ortak layout için generated assertion zorunlu.

## C.2 Pointer ve adres aritmetiği

Mevcut pointer primitive'lerini koru. Şu alanları doğrula veya kanıtlanan boşluğu kapat:

- Null pointer ve nullable ham adres kontrolü (managed `Optional`'dan ayrı).
- Native `usize/isize`, pointer-width conversion; wasm32 pointer genişliği ile mevcut i64 field slot'larının ayrımı.
- Pointer farkı, kapasite ve offset hesaplarında overflow kontrolü.
- Çeşitli alignment düzeyleri, unaligned load/store sözleşmesi.
- `ptr[u8]` ile byte kopyalama ve pointer alias kuralları.
- Pointer'dan field pointer türetme ve gerekirse intrusive yapıların container-of işlemi.
- Raw pointer ile function pointer tiplerinin ayrımı.
- Buffer reallocation sonrası eski pointer geçersizliği.

Runtime memory manipulation güven sınırı içinde gerçekleştirilir; normal uygulamanın type safety ve ownership kuralları gevşetilmez. LLVM `inbounds`, `nonnull`, `noalias`, alignment metadata gibi varsayımlar sadece kanıtlandığında kullanılır.

## C.3 Aritmetik ve bit primitive'leri

Mevcut fixed-width integer ve `nox.bits` altyapısında aşağıdakileri değerlendir:

- Explicit wrapping, checked ve gerektiğinde saturating arithmetic.
- Unsigned karşılaştırma, shift, rotate, count-leading/trailing zeros, popcount.
- Bitcast (float/integer, pointer-width değerler); mevcut geçici liste kullanımlarını gerçekten gerekiyorsa kaldır.
- Checked `size * count + header`, align-up/align-down, power-of-two, integer narrowing.
- IEEE floating-point bit desenleri, overflow/NaN ve signed-zero davranışı.
- Geniş aritmetik veya multiword işlem yalnız ilgili runtime algoritması gerektiriyorsa.

Mevcut genel integer overflow politikasını değiştirmek yerine gerekiyorsa açık internal primitive kullan. Bütün boyut hesapları için sınır değerleri ve taşma negatif fixture'ları oluştur.

## C.4 Allocation-free çalışma tamponları

`nox.mem`, `Buffer`, `Span`, `list[u8]` mevcut; bunların yeniden eklenmesi istenmemektedir. Ancak runtime bootstrap'ta normal managed Buffer kullanmanın mümkün olduğu varsayılmamalıdır.

Kanıtlanacak kabiliyetler:

- Explicit alignment ile sabit stack alanı.
- Dışarıdan verilen pointer + length/capacity görünümü.
- Stack veya allocator tarafından verilen ham storage'a type-safe erişim.
- Allocation-free `copy`, `move`, `set`, compare ve gerektiğinde zeroization.
- Overlapping bölgelerde `move` doğruluğu.
- Compiler'ın helper çağrısı ürettiği veya loop'u builtin'e indirdiği durumlarda dependency kontrolü.

Dinamik `alloca`, sınırsız stack buffer ve unrestricted stack pointer manipülasyonu başlangıç için gerekli değildir. Sabit stack buffer boyutlarına sınır koy; büyük scratch alanını açık allocator/provider'dan al. Stack yaşam süresi ve pointer escape testleri zorunludur.

---

# BÖLÜM D — ATOMİK İŞLEMLER VE EŞZAMANLILIK

## D.1 Raw-address atomics

Mevcut high-level `nox.atomic` API'sini değiştirmeden önce runtime içi ihtiyaçlara yönelik primitive seti denetlenmelidir.

| Primitive | Gerekçe |
|---|---|
| Atomic load/store | RC header, published pointer, scheduler durum alanı |
| Compare-exchange (strong; gerekirse weak) | Lock-free state transition ve mevcut algoritmalar |
| Fetch-add/sub/and/or/xor | Referans sayacı, bit flag, sayaç ve state |
| Exchange | Kuyruk ve durum değişimi |
| Atomic fence | Thread ve worker publication ordering |
| CPU relax/yield hint | Spinlock ve kısa busy wait |

Gerekli width/alignment desteği (özellikle native pointer, 32 ve 64 bit) mevcut Zig runtime atomik kullanımlarından çıkarılmalıdır. Her tip için indiscriminately atomics eklenmemelidir.

### D.2 Memory ordering sözleşmesi

- Relaxed, acquire, release, acq_rel, seq_cst karşılıkları.
- CAS success/failure ordering kuralları (failure ordering release/acq_rel olamaz; başarıyla uyumlu olmalı).
- Non-atomic erişim ile atomic erişimin karıştırılmaması.
- Atomicity ve volatile arasındaki fark.
- Lock-free olmayan hedefte açık fallback sözleşmesi; sessiz plain load/store fallback yasak.
- Compiler reordering ve CPU reordering etkileri ayrı doğrulanmalı.

LLVM atomic IR, QBE'nin hedefe özgü imkanları ve mevcut Zig/assembly fallback'leri karşılaştırılacak. Backend bir primitive'i doğrudan desteklemiyorsa, küçük ve bağımlılığı açık shim kullanılabilir. Genel amaçlı gizli Zig runtime bağımlılığı bırakılmamalı.

### D.3 Thread-local storage ve runtime-local state

`runtime/alloc/asap.zig` içindeki `g_worker_slot` gibi TLS kullanımları ve task/fiber-local state envanteri çıkarılacaktır.

- TLS access/init/teardown, worker başlangıcı, OS thread girişi.
- Explicit `RuntimeState*` ve TLS arasındaki görev ayrımı.
- Foreign thread callback sözleşmesi mevcut destek sınırlarıyla korunmalı.
- Windows TLS, Linux/macOS TLS, WASM threads ve freestanding single-core farklılıkları.
- Runtime root pointer'ının bootstrap öncesi okunmaması.

Public `threadlocal` keyword'ü zorunlu değildir. Mevcut explicit state, platform TLS provider veya internal intrinsic ile çözüm karşılaştırılmalıdır.

### D.4 Doğrulama

- Tek işçi ve çok işçi altında ARC counter ve publication stress testleri.
- Acquire/release message-passing, CAS contention ve store-buffering litmus testleri; yalnız memory modelin yasakladığı sonuçlar failure sayılır.
- ThreadSanitizer ile desteklenen hosted konfigürasyonlar; sonuçların fiber switch annotation sınırlamaları ayrıca belirtilir.
- ARM64 ve x86-64 gerçek donanım, desteklenen RISC-V ve WASM atomics hedefleri.
- Lock-free ve fallback yollarında linearizability/invariant kontrolleri; stress testi tek başına formal ispat sayılmaz.

---

# BÖLÜM E — ABI, FUNCTION POINTER, LINKING VE TARGET ALTYAPISI

## E.1 Runtime fonksiyonlarının export ABI'si

Normal Nox fonksiyonunda hidden `rt` parametresi bulunabilir. Runtime fonksiyonları ise generated code'un beklediği kesin ABI ile dışarıdan çağrılmalıdır.

İhtiyaç:

- Açık C-ABI export ve exact symbol name.
- Hidden runtime parametresinin açıkça yönetilebilmesi: ihtiyaç duyan fonksiyonda gerçek `rt` ilk argüman, leaf fonksiyonda gizli parametre yok.
- Mangling, visibility, symbol aliases, static/internal linkage ve export retention.
- Raw function pointer invocation, platform çağrı konvansiyonu ve callback trampoline ayrımı.
- Void, pointer, bool/integer, float ve gerekli aggregate ABI doğruluğu.
- Runtime `noreturn` sözleşmesi; compiler'ın unreachable path'i doğru indirmesi.
- Unwind/exception crossing sınırı. Native C sınırına Nox exception'ın kontrolsüz taşınmaması.

`extern def`, `with_rt`, callback ve `--selfhost-obj` mevcut özelliklerdir; export ve runtime-free ABI'yi mümkün kılmak için önce bunların altyapısından yararlan.

## E.2 Runtime object/archive üretimi

Gerekli internal build yolu:

1. Önceki doğrulanmış Nox compiler ile runtime leaf/core kaynaklarını derle.
2. Native object üret; normal program main ve managed lib_init otomatik eklenmesin.
3. Gerekli assembly ve açık platform shim'lerini bağla.
4. Runtime archive/object üret.
5. Runtime manifest ve ABI fingerprint oluştur.
6. Compiler tarafından üretilen uygulamayı seçilen runtime ile bağla.
7. Runtime nesnesinin kendi kendine veya eski Zig object'e gizli bağlı olmadığını doğrula.

İlk PoC hosted native LLVM olabilir. Fakat mevcut QBE freestanding, cross compilation, mobil ve WASM yollarına geçiş planı başlangıçta hazırlanmalıdır. Mevcut `--selfhost-obj` hedef kısıtını doğrudan kaldırmak yeterli çözüm değildir; target-specific ABI ve linking kanıtı gereklidir.

## E.3 ABI tek doğruluk kaynağı

`shared/abi_layout.zig` ve runtime header'ları bugün mevcut düzeni tanımlamaktadır. Örneğin v2.2.44'te ARC header 8 B, list payload header 24 B, data pointer ofseti 16; bunlar güncel committe değişebilir. Hardcode ederek ayrı bir doğruluk kaynağı yaratma.

Tasarım:

- Ortak machine-readable schema: runtime symbol signature, type/field layout, alignment, flags, feature set ve target/profile bilgisi.
- Zig oracle, Nox runtime, Nox compiler, QBE/LLVM ve assembly için ortak generation/check.
- RuntimeState hot prefix ve inline ARC erişimlerinin birebir eşleşmesi.
- List/dict/string/class/closure/task/channel ve tracing metadata sözleşmesi.
- Compiler/runtime uyumsuzluğu link veya init öncesinde belirgin bir hata ile yakalanmalı.
- Private internal ABI ile public NNI/NAPI/HPy ve kernel allocator ABI'si ayrılmalı.

Mevcut private ABI politikası gereği farklı sürümlerdeki object'lerin link edilebilmesi şart değildir. Ama aynı sürümde yanlış runtime object'in seçilmesi sessiz bellek bozulmasına yol açmamalıdır.

## E.4 Target bilgisi ve conditional compilation

Zig `builtin.cpu.arch`, `builtin.os.tag`, `comptime`, type reflection ve allocator vtable'ları port sırasında otomatik karşılık bulmayabilir.

Aşağıdaki yetenekler mevcut dil/driver ile araştırılacaktır:

- Compile-time target OS, arch, endian, pointer width, ABI ve CPU feature bilgisi.
- Hosted/freestanding, wasm threads, mobil ve runtime build-mode capability bilgisi.
- Desteklenmeyen platform dalının typecheck/codegen/link aşamalarına yanlışlıkla girmemesi.
- Target-specific module selection ve generated constants.
- Build-time assert veya eşdeğer generated fixture.
- Function table ve static data initialization.

Zig'in bütün `comptime` dilini Nox'a taşımak hedef değildir. Nox'un daha dar compile-time ihtiyaçları build-time generation, explicit target modules veya mevcut constant folding ile karşılanabiliyorsa bunlar yeterlidir.

## E.5 Assembly stratejisi

Inline assembly bir ön koşul değildir. Mevcut `swap_*.S` ve boot stub'ları korunabilir. `extern def` ile linked assembly nesneleri mevcut altyapıdır.

Gerekli sınır: stack switch, register context, TLS/CPU intrinsic veya boot entry gibi platform işlemleri için küçük, denetlenebilir assembly modülleri; Nox runtime ile açık ABI. Assembly algoritmik runtime kodunu Nox'a taşımaktan kaçınma noktası haline gelmemeli.

---

# BÖLÜM F — ALLOCATOR VE BOOTSTRAP KATMANI

## F.1 Bağımlılık katmanları

```text
L0  Platform ABI + gerekli assembly (Nox runtime yok)
    └─ OS page allocation / kernel provider / WASM linear memory
L1  Raw Nox primitives + fatal diagnostic + cold bootstrap
L2  Raw allocator/state storage + pool/arena altyapısı
L3  ARC/ASAP runtime hooks + object layouts + value operations
L4  Cycle collector + dispatch/trace + exception handling
L5  Scheduler/fiber/worker/IO + managed helpers
L6  Native stdlib shims + embedding/FFI/HPy/NNI
L7  Nox programı ve Nox compiler
```

Bu topolojik sıra kavramsaldır. Mevcut ARC/GC, scheduler/STW ve exception bağımlılıkları nedeniyle bazı bileşenler karşılıklı sözleşmelere ihtiyaç duyabilir. Böyle durumlarda hazır olma fazları, explicit callback table ve allocation-free çekirdek yol tanımlanır. Bir startup bağımlılık döngüsü yalnız fonksiyonlara farklı isim vererek çözülmüş sayılmaz.

## F.2 Raw allocator interface

Bugünkü Zig allocator arayüzünün tümünü public Nox API olarak kopyalama. Gerçek runtime gereksinimlerinden küçük bir internal arayüz belirle:

- alloc(size, alignment), free(pointer, size/alignment gerektiğinde), realloc/remap gerekiyorsa.
- Platform page size, reserve/commit/decommit veya eşdeğer davranış.
- Null/OOM, overflow, zero-size ve alignment sözleşmesi.
- Reallocation başarısızlığı eski bloğun sahipliğini korumalı.
- Explicit allocator context + raw function pointers.
- Host allocator injection ve freestanding kernel provider ile uyumluluk.
- Debug allocator/instrumented provider ve fault injection.
- Thread-safety ve ISR reentrancy ayrı capability.

Platform sağlayıcısının OS/libc çağrısı yapması kabul edilebilir. Nox allocator runtime'ı başka bir yüksek seviyeli Nox nesnesi oluşturarak başlatılmamalıdır.

## F.3 Startup ve shutdown state machine

Öneri: `UNINITIALIZED → BOOTSTRAP → CORE_READY → GC_READY → SCHEDULER_READY → RUNNING → SHUTTING_DOWN → DEAD` (gereksiz durumlar sadeleştirilebilir).

- RuntimeState'in ham storage üzerinden oluşturulması ve init edilmesi.
- Read-only tabloların runtime allocation olmadan hazırlanması.
- Worker ve fiber state init sıralaması.
- Dispatch, callback ve global state publication.
- Kısmi initialization failure ve teardown.
- Bir süreç içinde tekrar runtime oluşturma/yıkma ve embedding.
- Scheduler hazır olmadan ARC/GC'nin çağrılabilen subset'i.
- Shutdown sırasında yeni işler ve external callback girişinin engellenmesi.

## F.4 DebugAllocator yerine güvenlik altyapısı

Zig `std.heap.DebugAllocator` mevcut projedeki kritik leak/double-free oracle'larından biridir. Native runtime'a geçiş bu kabiliyetin kaybına yol açmamalıdır.

- Allocation/free ledger, boyut ve alignment doğrulaması, leak report.
- Double-free, canary/guard, redzone veya uygun harici sanitizer kontrolleri.
- Fault injection: N'inci alloc/realloc başarısızlığı, kapasite sınırları, host allocator hata davranışı.
- Allocation tracing, RC events, GC diagnostics ve gerektiğinde stack trace entegrasyonu.
- Diagnostic yolunun kendi allocation bookkeeping'ini recursively tetiklememesi.
- Debug ve ReleaseFast runtime build çıktılarını ayır; instrumentation performans ölçümüne karışmasın.

Mevcut sanitizer/DebugAllocator harici referans testlerinde korunabilir. Saf Nox core'un debug yeteneği eşdeğer güvenlik kanıtı sunmalıdır; Zig oracle'a bağlı olmak final üretim runtime'ı için zorunluluk oluşturmamalıdır.

---

# BÖLÜM G — RUNTIME BİLEŞENLERİNE ÖZGÜ HAZIRLIK

## G.1 ARC/ASAP çekirdeği

İlgili kaynak: `runtime/alloc/arc.zig`, `asap.zig`, `lowlevel.zig`, `dispatch_registry.zig`, `defer_stack.zig`, compiler ownership/local_escape/inlining ve `shared/abi_layout.zig`.

- Raw RC header ve flags, atomic/non-atomic hızlı yol, worker-local pool ve publication.
- Sıfıra düşen sayacın release dispatch'i, recursion depth limiti ve explicit worklist.
- Allocation-free veya açık allocator kullanan release/trace function pointer tabloları.
- ARC'deki inlined codegen yollarıyla runtime çağrılarının aynı semantic contract'ı.
- Retain/release, consuming clone, borrowed parametre ve owner transfer davranışının korunması.
- Stable list handle ve ayrı eleman tamponunun doğru serbest bırakılması.
- Arena ve stack nesnesi ile ARC nesnesinin karıştırılmaması.
- OOM sırasında yarım oluşturulmuş nesnelerin doğru cleanup'ı.

ASAP'ın önemli bölümü compiler analizidir; runtime portu için ASAP analizini baştan yazma. Mevcut self-hosted compiler'ın sahiplik kararlarını koru.

## G.2 Cycle collector

İlgili kaynak: `runtime/alloc/cycle_detector.zig` ve mevcut STW/worker koordinasyonu.

- Önce mevcut trial-deletion algoritmasını birebir koru; yeni tracing/concurrent GC tasarımı yok.
- Root/candidate tabloları, mark/scan/collect, parallel worklist ve byte pressure muhasebesi.
- RC restoration, object identity ve doğru trace/release dispatch.
- Collector içi tahsislerin collector'ı veya ARC'yi beklenmedik şekilde tekrar tetiklememesi.
- Graph traversal için explicit scratch allocator ve bounded failure path.
- Stop-the-world protokolü; safepoint, lock acquisition order, worker katılımı ve teardown.
- Zig ve Nox collector arasında nesne kimliği bazlı freed set karşılaştırması + bağımsız reachability oracle.
- OOM injection ve çok worker stress. Yalnız serbest bırakılan nesne sayısının eşit olması yeterli değildir.

## G.3 Exception, defer ve fatal path

- Pending exception alanının runtime/fiber/worker isolation sözleşmesi.
- Handler stack, catch matching, class parent chain, defer/finally cleanup.
- Compiler tarafından üretilen exception protocol ile birebir uyum.
- Runtime'ın kendi low-level hata dönüşleri ve normal Nox exception'ları arasında sınır.
- Cross-ABI callback ve host hata çevirileri.
- Stack overflow/OOM durumlarının managed allocation gerektirmeyen tanılaması.

## G.4 String, koleksiyon ve numeric runtime

- Str packed header, ASCII state, UTF-8 index/length ve immutable sharing.
- List stable handle, fixed-width element storage, dict ordered buckets, hashing ve collision handling.
- Float shortest-roundtrip formatting, integer overflow ve numeric edge cases.
- Allocation sınıfları ve alıcıya ait runtime state.
- Pure algorithm leaf fonksiyonları ilk gerçek port adaylarıdır; managed wrapper'lar sonra taşınır.

Mevcut Zig stdlib fonksiyonlarını kullanmak ile algoritmayı Nox ile port etmek aynı şey değildir. Dış bağımlılık her modül için manifestte gösterilmeli. Örneğin gzip/crypto/regex/TLS üçüncü taraf kütüphanelerine dayanabilir; bağımsız runtime amacı bütün kriptografiyi yeniden yazmayı gerektirmez.

## G.5 Fiber/context ve scheduler

Mevcut `runtime/async_rt/fiber.zig` ve `swap_*.S` stackful fiber temel sağlar. Başlangıçta şu davranışlar korunacak:

- Mimariye/ABI'ye özgü callee-saved register, FP/SIMD state, stack alignment, Windows shadow space ve gerekli TLS/platform register kuralları.
- İlk fiber context frame'i, stack allocation/guard page, stack overflow diagnostic.
- Context switch fonksiyonlarının compiler açısından doğru memory/side-effect sözleşmesi.
- Worker-local state, M:N scheduling, task/channel, queue, work stealing ve I/O wakeup.
- Mevcut pinning/migration ve safepoint politikaları; yeni preemption hedef değildir.
- WASM Asyncify ve threads farklılığı; native stack pointer varsayımlarını WASM'a taşımama.
- OS thread start/join, timer, sleep park/unpark, cancellation, epoll/kqueue/WSAPoll ve diğer mevcut platform adaptörleri.

Context layout'u Nox/Zig/assembly ortak schema ile doğrula. ABI register preservation testleri, deeply nested yield, exception through async, channel stress, STW under CPU workload, stack HWM ve guard fault testleri gereklidir.

## G.6 Platform ve stdlib bağımlılık envanteri

`runtime/lib.zig`, `runtime/lib_freestanding.zig`, `runtime/lib_wasm*.zig` ve `runtime/stdlib_shims/*` için iki ayrı harita üret:

1. Nox'a özgü runtime/ABI adaptasyonu (port hedefi).
2. OS veya harici kütüphane hizmeti (kalıcı provider/shim olabilir).

Dosya, socket, reactor, TLS, DNS, HTTP, time, entropy, process, shared memory, database, HPy/WASM/NNI bridge dahil her modülün Zig stdlib ve üçüncü taraf bağımlılıklarını çıkar. Platform headers ve bindgen kullanımı mümkünse mevcut ABI ile uyumlu yürütülmeli.

Güvenlik açısından hassas algoritmaların sırf dil saflığı adına yeniden yazılması zorunlu değildir. Public davranışın ve native ABI'nin eşdeğerliği sağlanmadan runtime modülü tamamlanmış sayılmaz.

---

# BÖLÜM H — PLATFORM STRATEJİSİ

İlk hedef önerisi: elde mevcut macOS ARM64 ve/veya Linux x86-64 ortamında hosted LLVM leaf PoC; ikinci hedef QBE ve native ELF freestanding. Bu seçim kullanıcı tarafından değiştirilmeden önce erişilebilir donanım ve CI imkanları doğrulanacaktır.

| Hedef | Özel gereksinimler |
|---|---|
| Linux x86-64/AArch64 | SysV/AAPCS64, libc/syscall provider, thread/TLS, epoll |
| macOS x86-64/AArch64 | Mach-O, platform register, kqueue, system linking/SDK |
| Windows x86-64 ve mevcut diğer destekli arch | Windows ABI, PE/COFF, TLS, VirtualAlloc, native thread API |
| Hosted RISC-V | LP64D, context layout ve code model |
| Freestanding | Kernel allocator hook, bootstrap, MMIO, guard/sink/halt provider, mevcut QBE profil |
| WASM | Linear memory, wasm32 pointer width, memory.grow, atomics feature, Asyncify/WASI ayrımı |
| iOS/Android | Mevcut static/shared library ABI, SDK/NDK, embedding, platform thread/TLS kuralları |

Güncel resmi target matrix esas alınacaktır. Tablo yeni platform desteği sözü değildir. Hedefe ait unsupported veya deferred özellikler açıkça listelenecektir.

Mevcut freestanding QEMU test zinciri ve `scripts/freestanding_survey.py` kullanılabilir. 11 Kasım'daki tarihsel survey sonuçları güncel başarısızlıklar gibi yorumlanmasın; güncel dokümanda sonradan iyileştirilmiş yollar bulunuyor. Gerçek target smoke ve conformance tekrarları zorunludur.

---

# BÖLÜM I — AŞAMALI UYGULAMA YOL HARİTASI

Bu sıralama öneridir; agent dependency graph ile gerekçelendirerek değiştirebilir. Her faz kendi kapanış kanıtına sahip olacak; büyük mimari/dil değişikliği önceden onaylanacaktır.

## R0 — Envanter ve capability audit (yalnız araştırma)

- [ ] Güncel compiler/runtime sürümü ve referans commit sabitlendi.
- [ ] Runtime export ve native dependency envanteri çıkarıldı.
- [ ] Mevcut lowlevel, atomics, layout, FFI, freestanding ve target yetenekleri örneklerle test edildi.
- [ ] Her eksik için minimal reproducer, etkilenen backend/target, alternatif ve gereklilik raporu oluşturuldu.
- [ ] Private/public ABI ve Zig oracle koruma stratejisi belirlendi.
- [ ] Kullanıcının onaylaması gereken kararlar listelendi.

**Gate:** Boşluk olduğu kanıtlanmamış özelliği implement etme. R0 sonunda runtime portu değil, ölçümlü capability planı teslim edilir.

## R1 — Runtime-free leaf PoC

- [ ] Runtime-free effect/call-graph denetimi.
- [ ] Standalone object export ve hidden rt kontrolü.
- [ ] Raw scalar/pointer işlemleri ve allocation-free fatal sink.
- [ ] Native C veya küçük assembly harness, eski `noxrt.o` olmadan link ve run.
- [ ] Negatif managed allocation, gizli helper ve indirect call fixture'ları.

**Gate:** Source/IR/object seviyesinde runtime recursion bulunmuyor. Eski allocator veya managed runtime gerekli değil.

## R2 — Raw storage, ABI ve atomics yeterliliği

- [ ] Yönetimsiz record/layout prototipleri.
- [ ] Stack/raw buffer ve checked arithmetic.
- [ ] Gerekli raw atomics, ordering ve TLS/provider.
- [ ] ABI schema + generated checks + assembly layout.
- [ ] QBE/LLVM conformance ve target gap raporu.

**Gate:** Raw allocator, RC header ve scheduler context yapıları mevcut runtime olmadan temsil edilebilir. Platformdan bağımsız atomics sözleşmesi kanıtlandı.

## R3 — Bootstrap kernel ve allocator spike

- [ ] Explicit provider interface.
- [ ] RuntimeState ham storage'da init/fini.
- [ ] Basit bump/free-list/pool prototipi (nihai allocator olmak zorunda değil).
- [ ] Allocation-free failure path ve Debug/fault-injection provider.
- [ ] Bir managed nesneye ulaşmadan önce cold-start testi.

**Gate:** Nox ile yazılmış allocator katmanı kendisine veya eski Zig allocator'a çağrı döngüsü kurmadan gerçek bellek ayırıp bırakabilir. PoC performans ve güvenlik sınırları kayıtlı.

## R4 — İlk runtime modüllerinin eşdeğer portu

Bu aşamadan itibaren gerçek runtime portu başlar. R0–R3 readiness işidir; kullanıcı port onayı alınmalıdır.

- [ ] Pure math/hash/byte algoritmaları.
- [ ] Nox ve Zig'in aynı runtime ABI üzerinden birlikte çalışması.
- [ ] Modül bazlı build seçimi; yalnız bir gerçek export sahibi.
- [ ] String/collection helper'ları ve ilgili coverage.
- [ ] Eşdeğer performans ve rollback.

**Gate:** Hybrid runtime ile mevcut uygulamalar bütün davranışlarını koruyor.

## R5 — ARC, allocator, exception ve cycle collector

- [ ] Mevcut algoritmalar eşdeğer port edildi.
- [ ] Inline codegen ve ABI sözleşmesi doğrulandı.
- [ ] Fault injection, leak/double-free, cycle oracle, shared state ve OOM testleri.
- [ ] ARC sıcak yolu, pool, GC pause ve ekosistem performansı eski Zig referansına göre ölçüldü.

**Gate:** Nox managed programları eski Zig allocator/ARC/GC olmadan çalışır. Debug güvenlik altyapısı korunmuştur.

## R6 — Scheduler ve platform runtime

- [ ] Mevcut assembly context switch bağlantısı.
- [ ] Fiber/worker/task/channel, reactor ve thread-local state.
- [ ] Hosted ve freestanding/WASM farklılıkları.
- [ ] Çok worker stress, STW ve gerçek HTTP servis workload.

**Gate:** Nox runtime scheduler semantiği, platform ABI ve concurrency güvenliği referans ile eşdeğer.

## R7 — Native shims ve ABI ekosistemi

- [ ] Nox'a özgü stdlib shim kodu portu.
- [ ] NNI/NAPI/HPy/FFI ve embedding testleri.
- [ ] Kalıcı harici kütüphane/provider manifesti.
- [ ] Tüm destekli dağıtım hedefleri, runtime artifact ve packaging.

**Gate:** Tüm desteklenen runtime özellikleri sağlandı veya kullanıcı tarafından onaylanan istisnalar açıkça listelendi.

## R8 — Final bootstrap ve Zig bağımlılığı denetimi

- [ ] Stage0 doğrulanmış eski Nox compiler; Stage1 Nox-native runtime; Stage2 compiler kendi runtime'ı ile kendisini derler.
- [ ] Stage3 tekrar derleme: deterministik IR/object/binary eşitliği veya belgelenmiş nondeterministic metadata normalizasyonu.
- [ ] Eski Zig runtime kaynakları/nesneleri/Zig executable olmayan temiz ortamda build/run testleri (seçilen bağımsızlık kapsamına göre).
- [ ] Link dependency manifest, build provenance, ABI fingerprint.
- [ ] Native runtime varsayılan yapılmadan önce uzun süreli test ve rollback paketi.

**Gate:** Eski Zig runtime olmadan bağımsız Nox compiler ve Nox runtime çalışıyor. Eğer `zig cc` cross linker olarak kalıyorsa bu gizlenmez; toolchain bağımsızlığı ayrı milestone olarak açık kalır.

---

# BÖLÜM J — ZORUNLU PROTOTİPLER VE TESTLER

Aşağıdaki testler önerilen capability'lerin gerçek kullanımını kanıtlar. Örnek isimler mevcut Nox sözdizimi iddiası değildir; agent geçerli syntax'ı kullanacaktır.

| ID | PoC | Başarı ölçütü |
|---|---|---|
| P01 | Pure scalar export | `noxrt.o` olmadan native harness ile çağır ve checksum doğrula. |
| P02 | Raw buffer fill/copy/move | Alignment, overlap, zero-length, guard/canary ve ASan destekli doğruluk. |
| P03 | Raw record/layout | C/Zig/assembly ile byte ve offset eşitliği; nested aggregate. |
| P04 | Raw atomic counter/CAS | Çok işçi altında doğru sonuç ve ordering invariant kontrolü. |
| P05 | Cold allocator | Runtime olmadan platform provider ile allocate/free; OOM ve overflow. |
| P06 | Forbidden dependency | Leaf fonksiyondan string/list oluşturma veya gizli runtime call reddedilir. |
| P07 | Explicit runtime ABI | Hidden parametre yok/var ayrımı, C symbol ve function pointer doğruluğu. |
| P08 | RuntimeState init/fini | Tekrarlı init, partial failure, deinit; leak yok, double-free yok. |
| P09 | Mini ARC object | Retain/release, publication, trace callback; bağımsız raw allocator. |
| P10 | Stable list-like buffer | Taşınan data pointer + sabit header, alias ve OOM güvenliği. |
| P11 | Fiber context | Register preservation, stack alignment ve yield/resume. |
| P12 | Freestanding/QEMU | Eski Zig managed runtime olmadan minimal Nox core boot ve serial checksum. |
| P13 | Target ABI matrix | Pointer width, endianness, CPU feature ve linking kuralları. |
| P14 | Full managed smoke (sonraki port) | Class/list/dict/exception/async + nox-native runtime. |
| P15 | Bootstrap closure (son faz) | Compiler ve runtime eski Zig runtime olmadan yeniden üretilebiliyor. |

P01–P08 readiness aşamasının zorunlu kanıtlarıdır; P09–P13 hedeflenen capability ve sonraki riskleri kanıtlayacak dar spike'lardır. P14–P15 port tamamlanmadan beklenmez. Her testte seçilen backend/arch ve varsa skip nedeni açıkça yazılır.

### Test ilkeleri

- Debug ve ReleaseFast; LLVM ve QBE uygun kapsamda.
- Hata kodu + stdout + stderr + memory invariants; ortak crash/timeout başarısız.
- ABI fixture'ları, negative compile fixture'ları, object symbol taraması ve actual run.
- ASan/UBSan/TSan veya platforma uygun eşdeğer denetimler; desteklenmeyen sanitizer başarı gibi gösterilmez.
- GC için bağımsız oracle, atomics için memory-model litmus, allocator için fault injection ve randomized stress.
- Normal Nox uygulamasının runtime-core kısıtlarına yanlışlıkla tabi olmadığını gösteren regresyon testleri.

---

# BÖLÜM K — PERFORMANS, UYUMLULUK VE GEÇİŞ GATE'LERİ

Yeni runtime'ın Nox ile yazılmış olması yeterli başarı ölçütü değildir.

1. Self-hosting ve önceki Phase 2.5 tamamlandığında çıkan güncel Nox/C ve Zig runtime baseline'ını kaydet. Tarihsel yaklaşık 1,27× oranı yalnız aynı korpus/flags/donanım ile karşılaştırılabiliyorsa kullan.
2. Aynı emitted IR ile eski Zig runtime ve yeni Nox runtime'ı bağlayarak runtime farkını ayır.
3. Compiler derleme süresi ile oluşan programın çalışma süresini ayrı ölç.
4. Tahsis/serbest bırakma, ARC retain/release, cycle collection pause, list/dict/string, HTTP, scheduler ve gerçek compiler iş yükleri ayrı ölçülmeli.
5. Gerçek peak RSS, heap capacity/live, allocator overhead ve allocation count; farklı bellek metrikleri tek oranmış gibi sunulmasın.
6. Debug allocator ile ReleaseFast değerleri karıştırılmasın; warm-up, median, min, tekrar sayısı ve ortam kaydı.
7. Aynı güvenlik ve doğruluk kontrolleriyle eşdeğer iş yükü. Bir optimizasyon checks kaldırarak kazanılmışsa kabul edilmez.
8. Nox C geomean korunmalı; istatistiksel anlamlı regresyonlar tek tek açıklanmalı. Geomean tek bir kritik iş yükündeki regresyonu gizlememeli.
9. Aether/Nyx request throughput, tail latency; Aura/UI ağaçları, Nova, Noxen, Quartz ve erişilebilir diğer gerçek ekosistem projeleri üzerinde doğrulama.
10. Mobile/HPy/NNI ve eski kaynak uyumluluğu regresyonları; eski binary ile yeni private ABI uyumu ancak mevcut sözleşme garanti ediyorsa talep edilir.

**Önerilen performans politikası:** Kalıcı üretim geçişinden önce referans runtime'a karşı anlamlı gerileme olmaması. Mikrobenchmark için başlangıç hedefi ±%5 ölçüm gürültüsü içinde; iş yüküne özgü tolerans ölçüm varyansı ile önceden belirlenir. Herhangi bir regresyonun kabulü kullanıcı onayı gerektirir. Bu rakam ölçülmüş performans sonucu değildir.

---

# BÖLÜM L — AGENT RAPOR FORMATI VE TESLİMLER

Her capability için şu format:

```text
ID:
Başlık:
Durum: MEVCUT / KISMİ / KANITLANMADI / EKSİK / GEREKLİ DEĞİL
Mevcut kaynak ve commit:
Runtime'daki somut kullanım yeri:
Neden gerekli:
Minimal reproducer:
Mevcut dil imkanlarıyla denenen çözüm:
Kalan gerçek eksiklik:
Alternatifler ve ölçüm:
Önerilen minimal değişiklik:
Public dil/API değişimi:
Kullanıcı onayı gerekiyor mu:
LLVM/QBE etkisi:
Hedef platform etkisi:
ABI etkisi:
Güvenlik ve reentrancy riski:
Test kanıtı:
Performans kanıtı:
Geçici bağımlılıklar:
Kapanış durumu / sonraki adım:
```

### Oluşturulacak proje belgeleri (önerilen isimler)

- `project/native-runtime-capability-audit.md`: doğrulanmış capability matrix, repro ve açıklar.
- `project/native-runtime-architecture.md`: bağımlılık DAG'ı, bootstrap katmanları, ownership ve platform tasarımı.
- `project/native-runtime-abi.md`: symbol/layout/target sözleşmesi, public/private ayrımı.
- `project/native-runtime-migration-plan.md`: fazlar, test gate, rollback, status.
- `project/native-runtime-performance.md`: ölçüm yöntemi, baseline ve sonuçlar.
- `project/native-runtime-dependencies.md`: Zig oracle, geçici shim ve kalıcı platform dependency manifesti.

Her faz raporu değiştirilen dosyaları, test komutlarını, commit/hash bilgilerini, platform sonuçlarını ve açık riskleri içerecektir. Bunlar mevcut plan belgelerinin yerine geçmek zorunda değildir; aynı bilgiler zaten doğru belgede bulunuyorsa tekrar üretmek yerine referans ver.

---

# BÖLÜM M — KULLANICI KARARI GEREKTİREN NOKTALAR

Agent bu kararları kendi başına bağlayıcı hale getirmeyecektir:

1. Runtime-core profilinin mevcut lowlevel/compiler metadata ile mi yoksa yeni internal attribute ile mi ifade edileceği.
2. Gerçek raw record/value storage boşluğu ortaya çıkarsa en küçük dil/compiler çözümü; public syntax gerekliliği.
3. Raw atomics ve memory ordering erişiminin yalnız runtime için mi yoksa public sistem programlama API'si olarak mı sunulacağı.
4. Platform provider sınırı: libc/OS library, minimal C/ASM shim, Zig stage geçişinde geçici adapter.
5. Target önceliği ve parity'nin hangi sırayla sağlanacağı.
6. Private ABI revizyonları, runtime fingerprint ve packaging politikası.
7. Mevcut allocator/provider stratejisinin korunması ya da yeni allocator araştırması (porttan ayrı).
8. Native runtime varsayılan yapılma koşulları ve Zig fallback'in ne kadar süre destekleneceği.
9. `zig cc` dahil tam toolchain bağımsızlığının bu projenin finalinde mi yoksa ayrı bir projede mi hedefleneceği.

---

# BÖLÜM N — READINESS TAMAMLANMA KRİTERLERİ (PORT ÖNCESİ)

- [ ] Self-hosting ve önceki iki audit tamamlandı; güncel baseline ve ABI sözleşmesi sabit.
- [ ] Mevcut özellikler ve doğrulanmış boşluklar kaynak/repro seviyesinde ayrıldı.
- [ ] Runtime-free leaf object eski runtime olmadan link/run ediyor.
- [ ] Yasak implicit allocation/ARC/arena/exception/runtime dependency'ler compile-time ve object seviyesinde yakalanıyor.
- [ ] Gerekli raw storage, layout, pointer, arithmetic ve atomics kabiliyetleri kanıtlandı.
- [ ] Bootstrap allocator spike cycle dependency olmadan çalışıyor.
- [ ] Allocation-free fatal/OOM ve kısmi init/fini yolları test edildi.
- [ ] Mevcut platform/assembly sınırları ve TLS/ABI ihtiyaçları belirlendi.
- [ ] Gerçek runtime'a ait symbol/layout manifesti ve geçiş dependency DAG'ı hazır.
- [ ] QBE/LLVM ve hedef platform açıkları gerekçeli, ölçümlü ve takip edilebilir durumda.
- [ ] Debug güvenlik yaklaşımı ve fault-injection stratejisi hazır.
- [ ] Büyük mimari/dil kararları kullanıcı onayına sunuldu.
- [ ] R4 ve sonrası gerçek runtime portunun plan ve rollback mekanizması hazır.

Bu kriterler tamamlandığında yalnızca **Nox'un runtime yazmaya hazır olduğu** ilan edilir. Runtime'ın gerçekten Nox ile yazılmış olduğu ilan edilmez. İkinci ilan ancak sonraki port fazları ve final bootstrap başarıyla tamamlandığında yapılabilir.

---

## Kaynaklar ve inceleme sınırları

Bu belge aşağıdaki Nox depo kaynaklarının v2.2.44 civarındaki `main` içeriğine ve önceki self-hosting incelemelerine dayanır. Agent işe başladığında tarihsel linklerin güncel olup olmadığını kontrol etmeli, referansı commit/tag ile sabitlemelidir.

- [build.zig.zon](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/build.zig.zon)
- [Memory / lowlevel](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/docs/language/memory.md)
- [FFI ve raw pointers](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/docs/language/ffi.md)
- [Freestanding](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/docs/tools/freestanding.md)
- [Internal ABI](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/docs/apis/internal-abi.md)
- [Runtime internals](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/docs/internals/runtime.md)
- [Lowlevel lowering — stmt.zig](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/compiler/codegen_qbe/stmt.zig)
- [Compiler driver / object emission](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/compiler/main.zig)
- [Atomic API](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/stdlib/nox/atomic.nox)
- [Typed memory helpers](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/stdlib/nox/mem.nox)
- [Buffer / Span](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/stdlib/nox/buffer.nox)
- [Bits helpers](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/stdlib/nox/bits.nox)
- [ABI layout](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/shared/abi_layout.zig)
- [RuntimeState ve allocator](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/runtime/alloc/asap.zig)
- [Fiber / context switch](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/runtime/async_rt/fiber.zig)
- [Freestanding tarihsel survey](https://github.com/mburakmmm/nox-lang/blob/v2.2.44/project/freestanding-kapsam-analizi-2026-11.md)

Bağımsız build, runtime PoC, assembly/IR üretimi, profiler veya CI tekrar koşusu yapılmamıştır. Kaynakta açıkça görülen bağımlılıklar ile henüz doğrulanması gereken capability adayları ayrılmıştır. Önerilen profil isimleri, yeni raw storage tasarımı, atomics kapsamı, öncelik sırası ve performans sınırları mühendislik önerileridir; mevcut dil özelliği veya garanti edilmiş sonuç değildir.

---

## Son talimat

Nox'un runtime'ını yine Nox ile yazmak, bütün yüksek seviyeli dil özelliklerini kaldırarak C benzeri ikinci bir dil oluşturmak anlamına gelmemelidir. Amaç aynı Nox dilinin hem güvenli genel amaçlı programlamayı hem de kendi temel runtime kodunu yazmayı mümkün kılmasıdır.

Runtime'ın en alt katmanı yalnız gerçekten gerekli primitive'leri kullanmalı, üst katmanlar hazır runtime servislerinden güvenli biçimde faydalanmalıdır. Gerekli assembly ve harici platform kodu dürüstçe korunmalıdır. "Saf Nox" iddiası dependency closure ile ölçülmeli, yalnız kaynak satırı oranıyla değerlendirilmemelidir.

**Önce yeterliliği kanıtla. Sonra eşdeğer runtime'ı port et. En son performans ve bağımsızlık optimizasyonlarını yap.**
