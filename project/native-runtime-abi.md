# Native runtime — ABI sözleşmesi: sembol/layout manifesti, public/private ayrımı, öneriler

> Readiness çıktısı (görev belgesi Bölüm E). **Bu belge öneri + ölçüm içerir; dil/ABI değişikliği UYGULANMAZ** — onay gerektirenler ayrıca işaretlidir.
> Mevcut kural: iç ABI **özeldir** (`docs/apis/internal-abi.md`); sürümler arası uyum garanti edilmez. Aynı sürümde yanlış runtime nesnesi seçilirse sessiz bozulma OLMAMALIDIR (§5).

## 1. Üç ayrı ABI yüzeyi (karıştırma)

| Yüzey | Kapsam | Kararlılık | Port'ta |
|---|---|---|---|
| **Private iç ABI** | `nox_*` runtime export'ları (compiler üretimi kodun çağırdıkları), `RuntimeState` sıcak öneki, ARC/str/list/closure/trace düzenleri | sürüme özel | Nox'a taşınır; manifestle sabitlenir |
| **Public NNI / NAPI / HPy / FFI** | `docs/apis/*`; opak handle, `extern def`, `@ffi.callback` | kararlı | **değişmez**; port sonrası aynı testler (R7) |
| **Kernel allocator ABI** | `nox_allocator_install` (freestanding, AGENTS §9.5) | kararlı + güven sınırı | aynı kalır; allocator spike'ı (P06) bu ABI'den bağımsız bir link-zamanı sağlayıcı kullanır |

## 2. Makine-okunur manifest (üretilmiş, drift denetimli)

`python3 scripts/gen_runtime_abi_manifest.py --write` →

- `project/native-runtime-symbols.tsv`: **1014** `export fn` satırı (847 benzersiz sembol; kalan satırlar native/WASM/mobil alternatifleri). Sütunlar: `symbol, file, line, rt_first, nparams, ret, params`.
- `project/native-runtime-layout.tsv`: `shared/abi_layout.zig`'in **39** `pub const` değeri (`ARC_HEADER_SIZE=8`, `LIST_DATA_OFF=16`, `LIST_HEADER_SIZE=24`, `STR_LENGTH_BITS=52`, `RT_HOT_SIZE=64`, …) hesaplanmış biçimde.
- `--check` kaynağa göre eskiyse çıkış kodu 1 (precheck'e bağlı). Zig dosyaları hâlâ **tek doğruluk kaynağıdır**; manifest türetilmiştir, elle düzenlenmez.

**Ölçüm (rt çağrı sözleşmesi):** 1014 export'un **440**'ı ilk parametre `rt` alır, **574**'ü almaz (`stdlib_shims`: 692 export / 278 rt'li). Nox `def`'i her zaman `rt` ilk argümanıyla derlenir (`define i64 @f(i64 %rt, …)`) ⇒ **rt'li export'lar bire bir üretilebilir** (`nox_rc_alloc(rt, size)`), rt'sizler için bir mekanizma gerekir (GAP-4, §4).

## 3. Hidden `rt`: ABI sonuçları (kanıt: P01–P06)

- Leaf/yaprak fonksiyon da `rt` alır; harness `0` geçer. Gövde `%rt`'yi **kullanmamalıdır** (kapı "rt-state" ihlalini yakalar; `nox_exception_pending` sıcak-blok okuması `%rt - N` yapar ⇒ `rt = 0` çökertir).
- `extern def` çağrısına `rt` **geçmez** (yalnız `with_rt` ile); sağlayıcı fonksiyonlar (`rtcore_*`) `rt`'siz C ABI'dır.
- Sembol adı üst düzey `def` için **mangle edilmez** (Mach-O'da tek alt çizgi öneki); jenerik örnekler `nox_mem_copy__u8` biçiminde.
- Dönüş/parametre eşlemesi: `int→i64`, `usize→i64/u64`, `ptr[T]→ptr`, `u32→i32`, `None→void`; küçük aggregate-by-value **yok** (ihtiyaç doğarsa ayrı iş, görev belgesi E.1).

## 4. Zorunlu ek yetenekler (öneri; hiçbiri uygulanmadı)

| ID | İhtiyaç | Önerilen biçim | Public? | Onay |
|---|---|---|---|---|
| GAP-4 | `rt`'siz tam-sembol export | internal niteliği (yeni public sözdizimi DEĞİL) ya da rt düşüren ince thunk (C/asm) ara çözüm | hayır | evet (R4 öncesi) |
| GAP-9 | `noreturn` | aynı internal niteliğe bağlı | hayır | evet |
| GAP-10 | rt'siz C ABI işaretçi çağrısı | runtime-core'da kullanılmaz (link-zamanı sağlayıcı); dispatch tabloları için ayrı değerlendirme | hayır | R5 |
| GAP-2 | kayıpsız dönüşümde denetim yok + wrapping iç ilkelleri | codegen iyileştirme + iç ilkeller | hayır | evet |

## 5. ABI parmak izi (fingerprint) ve yanlış runtime tespiti — tasarım önerisi (M.6 kararı bekler)

Amaç: derleyici/runtime uyumsuzluğunun sessiz bozulma yerine **link veya init öncesi** hata olması.

1. `native-runtime-layout.tsv` + sembol imzaları (`symbols.tsv` yalnız `symbol, rt_first, nparams, ret, params`) + özellik kümesi (`profile`, `target`) → **SHA-256 → 64 bit** `NOX_ABI_FINGERPRINT`.
2. Derleyici bu değeri üretilen nesneye **veri sembolü** olarak gömer (`__nox_abi_fingerprint`); runtime nesnesi/arşivi aynı sembolü **tanımlar**. Link-zamanı `extern` referansı ile eşleşme zorunlu; sapma = çözülemeyen/çift sembol (link hatası).
3. `nox_runtime_init` ilk iş değeri karşılaştırır; sapma ⇒ `rtcore_fatal(abi-mismatch)` (tahsissiz).
4. Public ABI'ler (NNI/NAPI/HPy) parmak izine **girmez**; kendi sürüm anahtarları vardır.

Not: bugün `shared/hpy_host_contract.zig` ve sürüm artırma `build.zig.zon` ile birlikte değişir; parmak izi **ek** bir koruma olur, onların yerini almaz.

## 6. Ham-adres atomikler — PUBLIC API tasarım önerisi (kullanıcı kararı M.3; UYGULANMADI)

Kanıt (P05): extern shim üzerinden 4 iş parçacığı sayaç/CAS/acquire-release/SB litmus doğru. **Önerilen yüzey** (`nox.atomic` genişlemesi veya `nox.sync.raw`; ad kullanıcıda):

- Ordering: `RELAXED, ACQUIRE, RELEASE, ACQ_REL, SEQ_CST` (int sabit). **Yükte** ACQ_REL/RELEASE, **depoda** ACQUIRE/ACQ_REL, **CAS başarısızlıkta** RELEASE/ACQ_REL **derleme/çalışma zamanı hatası** (shim'de fail-stop; P05).
- İşlemler: `load, store, exchange, compare_exchange(strong), fetch_add/sub/and/or/xor`, `fence(order)`, `cpu_relax()`; `compare_exchange_weak` ölçümle (runtime 18 weak site).
- Genişlikler: `u32`, `u64`/`usize` (native pointer); `u8/bool` yalnız gerektiğinde; hizalama ihlali tanımsız (belgelenir).
- Kilitsiz değilse **sessiz plain fallback YASAK**: derleme hatası veya açık kilit sözleşmesi.
- Düşürme: LLVM `atomicrmw/cmpxchg/load atomic/store atomic/fence` (zaten `fence` ve imm `atomicrmw` var, `llvm_emit.zig:571-806`); QBE'de hedefe özgü (yoksa küçük bağımlılığı açık asm/C shim); WASM atomics özellik bayrağı.
- Test: `tests/native_runtime/leaf/p05_atomics` kalıbı + her iki backend + TSan (hosted) + gerçek ARM64/x86-64.
- **Gerekli süreç:** spesifikasyon bölümü + AGENTS onayı + golden IR (dil davranışı). Bu readiness turunda yapılmadı.

## 7. Başlıksız ham layout (`@raw`) — INTERNAL öneri (kullanıcı kararı M.2; UYGULANMADI)

Gap kanıtı: `@repr("C")` sınıf nesnesi her zaman `[8 B ARC başlığı | alanlar]`; `ptr` alanı codegen'de yok (P03/`v3`). RuntimeState sıcak öneki, ARC başlığı, list başlığı, allocator düğümü, scheduler bağlam çerçevesi **başlıksız** kayıtlardır.

Öneri (public sözdizimi eklemeden):

```text
@raw                         # internal niteliği; yalnız runtime-core derlemesinde etkin
class RcHeader:
    flags: u32
    rc: u32
```

- Anlamı: `sizeof/alignof/offsetof` **başlıksız** C düzenini verir; örnek **yaratılamaz** (kurucu yok); yalnızca `ptr[RcHeader]` üzerinden alan erişimi (`p.rc`, `ptr_offset`), derleyici ofsetleri sabitler — elle indeks (`ptr_offset(p, 2)`) ve ayrı sabit tablosu **ortadan kalkar**.
- `ptr`/`ptr[T]` alan tipi desteklenir (şimdi `usize`). İç içe kayıt ve sabit dizi alanı aynı niteliğin parçası.
- Üretilmiş doğrulama: her `@raw` bildirimi için `offsetof/sizeof` sabitleri `abi_layout.zig` manifestiyle derleme zamanında karşılaştırılır (E.3).
- Seçenek (daha az değişiklik): derleyici değişikliği olmadan **generator**: `native-runtime-layout.tsv`'den `ptr_offset` erişimci `.nox` modülü ve C/Zig assertion üretmek (`gen_*` betiği). Bu, P03'ün elle yaptığını otomatikleştirir; ilk adım olarak önerilir.
- Karar bekler; kapsam: `compiler/typecheck` + `codegen` + golden + spesifikasyon.

## 8. Sembol sahipliği (R4+ için kural)

Her `nox_*` sembolün **tek** sahibi vardır (Zig *veya* Nox, hibrit modül-bazlı build seçimi). Çift tanım link hatasıdır; manifest `owner` sütunu R4'te eklenir; Zig sahibi referans/oracle olarak yedek kalır (migration-plan §Rollback).
