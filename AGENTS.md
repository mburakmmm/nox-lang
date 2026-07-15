# AGENTS.md — Nox Programlama Dili

Bu dosya, Nox derleyicisi ve çalışma zamanı üzerinde çalışan tüm AI kodlama ajanları (Claude Code, Cursor, Fable 5 vb.) için bağlayıcı referanstır. Bir ajan bu depoda herhangi bir değişiklik yapmadan önce bu dosyayı ve `nox-teknik-spesifikasyon.md`'yi (repo kökünde) okumuş olmalıdır. Çelişki durumunda **bu dosyadaki değişmez ilkeler her zaman kazanır.**

---

## 0. Nasıl Kullanılır

- Yeni bir göreve başlamadan önce: §2 (Değişmez İlkeler) ve görevle ilgili implementasyon kılavuzunu (§8-§12) oku.
- Belirsiz bir tasarım kararıyla karşılaşırsan: önce spesifikasyon dosyasına bak, orada da yoksa §16'daki karar prosedürünü izle. **Tahmin yürütüp devam etme.**
- Her PR/görev sonunda §14'teki checklist'i uygula.

---

## 1. Proje Özeti

Nox, Python'a sözdizimsel olarak yakın, **zorunlu statik tipli**, QBE ile AOT makine koduna derlenen, Zig ile yazılmış bir çalışma zamanına sahip bir sistem/genel amaçlı programlama dilidir. Bellek yönetimi tamamen otomatik ve kullanıcıya görünmezdir (ASAP destructor + ARC fallback + döngü çözücü). Python C eklentileri (NumPy, Pandas vb.) HPy esinli izole bir handle sistemi üzerinden desteklenir. WASM modülleri gömülü bir runtime üzerinden native kütüphane gibi import edilebilir.

**Tek cümlelik pusula:** *"Python gibi görünen, hiçbir zaman ownership hissettirmeyen, C kadar hızlı ve deterministik bir dil."*

---

## 2. Değişmez İlkeler (Non-Negotiable Invariants)

Bu kurallar hiçbir görev, optimizasyon veya "geçici çözüm" gerekçesiyle ihlal edilemez. Bir ajan bunlardan birini ihlal etmeden görevi tamamlayamıyorsa, **kod yazmayı durdurup kullanıcıya danışmalıdır.**

1. **Ownership hiçbir zaman kullanıcı sözdiziminde görünmez.** `Annotated[...]`, `mut`/`read`/`owned` benzeri hiçbir açık ownership anahtar kelimesi/sözdizimi eklenmez. Belirsizlik varsa derleyici sessizce ARC'ye (Katman 2) düşer — asla derleme hatası vermez, asla kullanıcıdan ipucu istemez.
2. **Tip sistemi her yerde zorunlu ve statiktir — `lowlevel` blok dahil.** `lowlevel`, yalnızca bellek tahsis stratejisini (Arena/pool/raw pointer) gevşetir; hiçbir zaman bir dinamik tipleme kaçış kapısı olarak kullanılmaz.
3. **QBE çıktısında hiçbir zaman unwind tablosu / landing pad üretilmez.** Hata yayılımı yalnızca örtük error-union dönüş zinciriyle yapılır.
4. **C eklentilerine hiçbir zaman ham `PyObject*` veya Nox nesnesinin bellek adresi verilmez.** Tüm dış erişim opaque handle üzerinden geçer.
5. **WASM entegrasyonu bir derleme hedefi değildir**, yalnızca bir kütüphane içe aktarma mekanizmasıdır. QBE'ye WASM backend'i eklemeye çalışan kod bu depoya kabul edilmez.
6. **Global/gizli mutable state yasak.** Runtime, allocator'ları her zaman açıkça parametre olarak alır (Zig idiomu).
7. **Her yeni dil özelliği, en az bir "golden test" (kaynak → beklenen QBE IR/davranış) ile birlikte gelir.**

---

## 3. Mimari Özet

```
Nox kaynak (.nox)
   │  lexer → parser → AST
   ▼
Zorunlu statik tip denetimi (tüm anotasyonlar doğrulanır)
   ▼
Sahiplik analizi (Katman 1: ASAP mi, Katman 2: ARC mi — örtük karar)
   ▼
QBE IR üretimi (ASAP destructor / ARC retain-release / error-union kontrolleri gömülü)
   ▼
QBE → native assembly (amd64 / arm64 / riscv64 / amd64_win)
   ▼
Zig runtime'a statik bağlama (allocator, ARC, döngü çözücü, HPy köprüsü, WASM köprüsü)
```

Detaylı gerekçeler için: `nox-teknik-spesifikasyon.md` (repo kökünde).

---

## 4. Repo Yapısı

```
/compiler
  /lexer
  /parser
  /typecheck        # zorunlu statik tip denetimi, generic monomorphization
  /ownership         # Katman 1/2 analiz geçişi (bkz. §8)
  /codegen_qbe       # AST/tiplenmiş IR → QBE IR
/runtime             # Zig
  /alloc             # ASAP, ARC, cycle detector (bkz. §8)
  /async_rt          # fiber zamanlayıcı, Task/Channel, nox.thread (M:N)
  /errors            # error-union temsili, exception handle (bkz. §9)
  /hpy_bridge         # opaque handle sistemi (bkz. §10)
  /cpython_compat     # CPython C-API emülasyon katmanı (bkz. §10)
  /wasm_bridge        # gömülü WASM runtime entegrasyonu (bkz. §11)
  /stdlib_shims       # nox.* stdlib modüllerinin Zig tarafı
/stdlib              # .nox ile yazılan standart kütüphane
/tests
  /unit
  /golden            # .nox → beklenen QBE IR / çalışma zamanı çıktısı
  /compat            # gerçek C/WASM/HPy eklentileriyle entegrasyon testleri
  /fuzz
/benchmarks          # Nox/Python/C karşılaştırmalı performans paketi
/examples            # örnek Nox projeleri
/editors             # tree-sitter grameri, VS Code eklentisi
/docs
  uretim-hazirlik-analizi.md   # üretim-hazırlığı yol haritası (Faz Q-Z)
nox-teknik-spesifikasyon.md    # repo kökünde — dilin tam tasarım geçmişi
AGENTS.md                      # repo kökünde — bu dosya
```

Bir ajan bu yapıdan saparsa, sapma gerekçesini PR açıklamasında belirtmelidir.

---

## 5. Sözdizimi Kuralları

- Python 3.x gramerine sözdizimsel olarak sadık kalınır (girinti, `def`, `class`, `for/while/if`, f-string, comprehension'lar).
- **Tüm parametre, değişken ve dönüş tipleri zorunludur.** Tip anotasyonu eksikse derleme hatası — asla `Any`'ye veya dinamik tipe örtük düşüş yoktur.
- Python'ın tam dinamik özellikleri (rastgele `setattr`, `exec`, çalışma zamanında sınıf üretme) **desteklenmez.** Bir ajan bu tür bir Python idiomunu Nox'a taşımak isterse, önce statik olarak ifade edilebilir bir eşdeğer bulmalı, bulamazsa özelliği kapsam dışı bırakmalıdır.

---

## 6. Zig Kodlama Standartları (Runtime ve Derleyici)

- `zig fmt` her commit öncesi zorunlu.
- Fonksiyon imzalarında allocator her zaman açık parametre (`allocator: std.mem.Allocator`); global allocator kullanımı yasak.
- Hata yönetimi Zig idiomlarına uyar: `!T` dönüş tipleri, `try`/`catch`, özel error set'ler modül başına tanımlanır (`const AllocError = error{OutOfMemory};` gibi).
- Yorumlar İngilizce ya da Türkçe olabilir; kod tabanında tutarlılık için mevcut dosyadaki dili takip et.
- Her public fonksiyon en az bir unit test ile gelir (Zig'in `test "..." { ... }` bloğu).
- Bellek güvenliği: `GeneralPurposeAllocator`'ın `.safety = true` modunda testlerin çalıştırılması zorunlu (use-after-free/double-free tespiti).

---

## 7. Derleyici Geliştirme Kuralları

Yeni bir AST düğümü / dil özelliği eklerken sırasıyla:

1. Gramer güncellemesi (parser + AST tipi)
2. Tip denetleyici kuralı (§5'teki zorunlu tipleme ilkesiyle uyumlu)
3. Sahiplik analizi etkisi değerlendirmesi (§8) — yeni düğüm bir kapsam/yaşam ömrü sınırı oluşturuyor mu?
4. QBE IR lowering
5. En az bir golden test (`tests/golden`)
6. Spesifikasyon dosyasında ilgili bölümün güncellenmesi (eğer davranış spesifikasyondan sapıyorsa)

Bu sıra atlanamaz; özellikle **golden test olmadan codegen değişikliği merge edilmez.**

---

## 8. Bellek Yönetimi İmplementasyon Kılavuzu (Sahiplik Piramidi)

### Katman 1 — ASAP (`/compiler/ownership`, `/runtime/alloc/asap.zig`)
- Statik analiz **muhafazakâr** olmalı: sahiplik/yaşam ömrü kanıtlanamıyorsa Katman 2'ye düş, asla yanlış pozitif "güvenli" kararı verme.
- Analiz kapsamı: değişken bazlı escape analysis, fonksiyon sınırı geçen değerler, closure yakalamaları, container içine konan değerler.
- Test gereksinimi: her ASAP kararı için hem "doğru tahsis noktası" hem "doğru serbest bırakma noktası" golden testi.

### Katman 2 — ARC Fallback (`/runtime/alloc/arc.zig`)
- O(1) retain/release, deep copy yok.
- Katman 1'den terfi sessiz olmalı — kullanıcıya hiçbir uyarı/log çıkmaz (bu bir derleyici iç kararıdır, dil semantiğinin parçası değildir).

### Katman 3 — Döngü Çözücü (`/runtime/alloc/cycle_detector.zig`)
- Yalnızca ARC modundaki nesneleri tarar (Nim ORC modeli referans alınır).
- Tarama sıklığı/tetikleyici heuristiği ayarlanabilir olmalı, varsayılan: tahsis baskısı eşiği.

### Katman 4 — `lowlevel` (`/runtime/alloc/lowlevel.zig`)
- Zig'in `ArenaAllocator`, `FixedBufferAllocator`, custom pool allocator'larına doğrudan erişim sağlanır.
- **Tip sistemi burada da tam olarak zorunludur** (bkz. İlke #2). `lowlevel` bloğu yalnızca *hangi allocator'ın* kullanılacağını değiştirir, *tiplerin nasıl kontrol edileceğini* değiştirmez.
- `lowlevel` bloğu içinde C/WASM sınır geçişleri varsa, §9'daki trampoline mekanizması hâlâ devrededir — `lowlevel` hata çevirisini atlamaz.

---

## 9. Hata Yönetimi İmplementasyon Kılavuzu

- İç temsil: her hata verebilecek fonksiyon, Zig'in error union'ına benzer şekilde `{ ok: T } | { err: ExceptionHandle }` biçiminde derlenir. `ExceptionHandle`, sınıf hiyerarşisi bilgisini taşıyan bir opaque handle'dır (tip etiketi + ebeveyn zinciri referansı).
- `except ClassName:` eşleşmesi, `ExceptionHandle` üzerinde runtime'da bir isinstance-zinciri kontrolüne derlenir.
- `finally` ve `with` (context manager `__exit__`) temizliği, ASAP destructor codegen yoluyla **aynı kapsam-çıkışı mekanizmasını** paylaşır — ayrı bir kod yolu yazılmaz.
- **C/WASM sınırı trampoline'ları:** Her `extern`/import edilen sembol için derleyici otomatik bir trampoline fonksiyonu üretir. Trampoline sorumlulukları:
  1. Nox tipli değerleri HPy handle'a veya WASM linear memory temsiline dönüştürmek.
  2. Çağrı dönüşünde ilgili sınırın hata konvansiyonunu kontrol etmek (CPython: `PyErr_Occurred()` eşdeğeri `cpython_compat` katmanı üzerinden; WASM: trap/dönüş kodu konvansiyonu) ve sonucu Nox `ExceptionHandle`'ına çevirmek.
  3. Ham C exception/longjmp'in Nox stack çerçevelerine sızmasını **engellemek** — bu, yalnızca trampoline sınırında savunma amaçlı, izole bir `setjmp`/`longjmp` bariyeriyle yapılır. Bu, İlke #3'ü ihlal etmez çünkü Nox'un kendi kontrol akışı hâlâ unwind tablosu kullanmaz; bariyer yalnızca dışarıdan gelen tehlikeyi izole eder.
- Golden test gereksinimi: her yeni exception sınıfı/hata yolu için hem başarı hem hata senaryosu testi.

---

## 9.5 Güven Sınırı (Trust Boundary) — `extern def` / `lowlevel`

**Faz Q.6 (bkz. `docs/uretim-hazirlik-analizi.md`, P0 bulgusu #10):** Bu
bölüm ÖNCEDEN hiçbir yerde açıkça belgelenmemişti — §5/§6/§8/§9 yalnızca
tip disiplinini ve bellek yönetimi/hata çevirisi MEKANİZMALARINI tartışır,
ama **`extern def`in KULLANICIYA ne kadar geniş bir yetki verdiğini
AÇIKÇA UYARMAZ.**

- **`extern def ... from "<lib>"` ÇIPLAK NATIVE KOD YÜRÜTME yetkisidir.**
  §9'daki trampoline mekanizması yalnızca ARC/hata-çevirisi MUHASEBESİNİ
  yapar — çağrılan native fonksiyonun KENDİSİNİN ne yaptığını (bellek
  güvenliği, yan etkiler, dosya/ağ erişimi) HİÇBİR ŞEKİLDE SINIRLAMAZ ya
  da SANDBOX'LAMAZ. Bir `extern def` bildirimi, Nox'un KENDİ tip/sahiplik
  garantilerinin **DIŞINDA**, C ABI'nin (ve dolayısıyla işletim
  sisteminin) tüm yetkileriyle çalışır.
- **`lowlevel` bloğu da AYNI güven sınırının bir PARÇASIdır** (bkz. §8,
  Katman 4) — yalnızca tahsis STRATEJİSİNİ (arena/pool) gevşetir, ama
  İÇİNDEKİ `extern def` çağrıları YİNE DE tam native yetkiyle çalışır.
- **Bir bağımlılığın (`nox.json`'ın `requires[]`i, bkz. §3.6/Faz O)
  KENDİ `extern def`leri OLABİLİR** — bir üçüncü-taraf paketi projeye
  eklemek, o paketin (VE onun geçişli bağımlılıklarının) `extern def`
  ile bildirdiği HERHANGİ bir native koda güvenmek DEMEKTİR. Nox'un
  paket sistemi (bkz. Faz O §P.5-P.7) bu native kodu DOĞRULAMAZ/
  İMZALAMAZ/SANDBOX'LAMAZ — bu tamamen kullanıcının SORUMLULUĞUNDADIR
  (npm/PyPI/crates.io ile AYNI güven modeli, HENÜZ bir "capability"
  sistemi YOK).
- **`nox.fs`/`nox.os` gibi stdlib modülleri de bu sınırın bir SONUCUDUR:**
  `nox.fs.read_to_string`/`write_string` `path`i hiçbir doğrulama
  yapmadan native `open()`e iletir — path-traversal'a karşı KORUMA
  YOKTUR (bkz. `stdlib/nox/fs.nox`'un KENDİ uyarısı). Bir ajan `nox.fs`yi
  GÜVENİLMEYEN girdiyle (kullanıcı/ağ kaynaklı bir `path`) çağıran kod
  YAZARKEN, doğrulamayı (izin verilen kök dizine göre kanonikleştirme +
  `..` reddi) ÇAĞIRAN TARAFTA elle EKLEMELİDİR — stdlib bunu OTOMATİK
  yapmaz.
- **Bir ajanın bu sınırı İHLAL EDEN bir "kolaylık" EKLEMESİ YASAK:**
  ör. `extern def`e otomatik bir "güvenli mod"/sandbox eklemek gibi bir
  değişiklik, KAPSAMLI bir güvenlik tasarımı gerektirir (bkz. Faz X.3'ün
  ARC atomiklik resmileştirmesiyle AYNI kategori — "gelecekte ele
  alınacak" olarak işaretlenmiş, ŞİMDİ rastgele bir PR'ın parçası olarak
  YARIM yapılmamalı).

---

## 10. HPy / CPython Uyumluluk Katmanı Kılavuzu

Hedef: **mümkün olan en geniş HPy/CPython API desteği**, önceliklendirilmiş katmanlar halinde uygulanır. Bir ajan bu katmanda çalışırken önce bir alttaki tier tamamlanmadan bir üsttekine geçmemelidir (aksi durumda test coverage'ı tutarsızlaşır).

| Tier | Kapsam | Neden öncelikli |
|---|---|---|
| **Tier 0** | Nesne yaşam döngüsü (create/destroy), refcount emülasyonu, temel tip objesi protokolü, modül init (`PyModule_Create` eşdeğeri) | Herhangi bir C eklentisinin yüklenebilmesi için minimum gereksinim |
| **Tier 1** | Buffer protokolü (PEP 3118), sequence/mapping protokolü, number protokolü (aritmetik dunder emülasyonu), iterator protokolü | NumPy/Pandas sınıfı kütüphanelerin **çekirdek** kullanım alanı — proje hedefinin asıl kaldıracı |
| **Tier 2** | GC destek kancaları (`tp_traverse`/`tp_clear` emülasyonu), weakref, alt sınıflama (subclassing) sınır ötesi | Karmaşık nesne grafiği kullanan kütüphaneler için gerekli |
| **Tier 3** | Descriptor protokolü, metaclass, capsule objeleri, gelişmiş buffer stride desteği, async/await protokolü | Uzun kuyruk — talep geldikçe uygulanır |

- Uygulama, gerçek HPy projesinin Universal ABI moduyla mümkün olduğunca hizalanmalı; Nox'a özgü genişletmeler yalnızca HPy'nin karşılamadığı boşluklarda eklenir.
- Her Tier 0/1 API eklemesi, gerçek bir C eklentisiyle (`tests/compat`) entegrasyon testiyle doğrulanmalıdır — sadece unit test yeterli değildir.

---

## 11. WASM Entegrasyon Kılavuzu

- Gömülü WASM runtime seçimi (wasmtime/wasmer C API veya native Zig yorumlayıcı) `/runtime/wasm_bridge` altında izole edilir; derleyici bu seçimden habersizdir.
- WASM modül export'ları, §10'daki aynı opaque handle sistemi üzerinden Nox'a sunulur — **iki ayrı FFI mekanizması yoktur, tek bir handle soyutlaması vardır.**
- QBE'ye WASM backend eklemeye çalışan hiçbir görev kabul edilmez (bkz. İlke #5).

---

## 12. Generics / Polimorfizm İmplementasyon Kılavuzu

**Karar:** Compile-time monomorphization + yapısal (structural) protokoller, kullanıcıya tamamen görünmez bir dispatch stratejisi seçimiyle.

- Bir fonksiyon/tip bir protokolü (Python'ın `typing.Protocol`'üne benzer, `implements` anahtar kelimesi gerektirmeyen yapısal eşleşme) parametre alıyorsa, derleyici çağrı sitesindeki somut tipleri analiz eder:
  - **Tek/az sayıda somut tip, statik olarak biliniyor →** Rust/Zig tarzı monomorphization: her somut tip için ayrı, dispatch'siz QBE IR üretilir (sıfır maliyet).
  - **Gerçekten heterojen koleksiyon (ör. karışık somut tipli `list[Shape]`) →** derleyici örtük olarak fat-pointer (veri işaretçisi + vtable işaretçisi) temsiline düşer.
- Bu seçim tamamen derleyici içi bir karardır; kullanıcı sözdiziminde hiçbir fark yaratmaz (İlke #1 ile aynı felsefe).
- Test gereksinimi: her protokol için hem monomorphize edilmiş hem de heterojen-fallback yol test edilmeli.

---

## 13. Test ve Doğrulama Gereksinimleri (Definition of Done)

Bir görev şu şartları sağlamadan tamamlanmış sayılmaz:

- [ ] `zig build test` yeşil
- [ ] Yeni/değişen dil davranışı için en az bir golden test (`tests/golden`)
- [ ] Bellek yönetimiyle ilgili değişikliklerde: leak testi + double-free testi + `GeneralPurposeAllocator` safety modu yeşil
- [ ] Hata yönetimiyle ilgili değişikliklerde: başarı yolu + hata yolu + (varsa) `finally`/`with` etkileşim testi
- [ ] HPy/CPython katmanı değişikliklerinde: en az bir gerçek eklenti ile `tests/compat` testi
- [ ] Hiçbir Değişmez İlke (§2) ihlal edilmemiş
- [ ] Spesifikasyon dosyası, davranış değişmişse güncellenmiş

---

## 14. PR / Görev Tamamlama Checklist'i

1. Değişiklik hangi bölüm(ler)i etkiliyor? (§8-12'den ilgili olanı işaretle)
2. §13'teki Definition of Done sağlandı mı?
3. Değişmez İlkelerden (§2) hiçbiri ihlal edilmedi mi? (Açıkça "hayır, ihlal yok" diye PR açıklamasına yaz.)
4. Spesifikasyon dosyasıyla tutarlılık kontrol edildi mi?
5. Yeni bir açık tasarım sorusu ortaya çıktıysa, spesifikasyon dosyasının §9 tablosuna eklendi mi?

---

## 15. Terimler Sözlüğü

| Terim | Anlamı |
|---|---|
| **Sahiplik Piramidi** | 4 katmanlı bellek yönetim modeli (ASAP → ARC → Döngü Çözücü → lowlevel) |
| **ASAP Destructor** | Kapsamdan çıkışta, referans sayacı olmadan eklenen sıfır maliyetli temizlik kodu |
| **HPy Handle** | C eklentisine verilen, gerçek bellek adresini gizleyen opaque kimlik |
| **ExceptionHandle** | Nox'un hata yayılım zincirinde taşınan, sınıf hiyerarşi bilgili hata nesnesi referansı |
| **Trampoline** | C/WASM sınırında otomatik üretilen, marshaling + hata çevirisi yapan köprü fonksiyon |
| **Monomorphization** | Generic/protokol tabanlı kodun her somut tip için ayrı, dispatch'siz derlenmesi |
| **Tier 0-3** | HPy/CPython uyumluluk katmanının önceliklendirilmiş uygulama sırası |

---

## 16. Belirsizlik Durumunda Karar Prosedürü

Bir ajan, bu dosyada veya spesifikasyonda karşılığı olmayan bir tasarım kararıyla karşılaşırsa:

1. Değişmez İlkelerle (§2) çelişmeyen en basit, en tutarlı çözümü **öner** ama uygulamaya geçmeden önce görevi veren kişiye kısaca özetle.
2. Küçük, geri alınabilir kararlar (ör. bir yardımcı fonksiyonun iç adlandırması) için durma — makul varsayımla devam et.
3. Mimariyi etkileyen kararlar (yeni bir dil özelliği, bellek modeli davranışı, ABI değişikliği) için **asla sessizce karar verip ilerleme** — önce sor.
