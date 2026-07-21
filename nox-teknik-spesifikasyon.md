# Nox Programlama Dili — Teknik Spesifikasyon

**Versiyon:** 1.1.0-dev (bkz. `CHANGELOG.md` — `v1.0.0` yayımlandı VE
etiketlendi; bu belge main dalındaki, HENÜZ yayımlanmamış devam eden
geliştirmeyi de İÇEREN en güncel durumu yansıtır — bkz. `VERSIONING.md`)
**Tarih:** 16 Temmuz 2026 (son önemli güncelleme)
**Dosya Uzantısı:** `.nox`
**Durum:** `v1.0.0` üretim sürümü YAYIMLANDI — aktif geliştirme devam
ediyor (bkz. `CHANGELOG.md`nin `[Yayımlanmamış]` bölümü)

---

## 1. Vizyon

Nox, Python'un sözdizimsel tanıdıklığını sistem programlama dillerinin performansı ve determinizmiyle birleştiren, tamamen AOT (Ahead-of-Time) derlenen bir dildir. Geleneksel Python yorumlayıcısı ve GC duraklamaları tamamen devre dışı bırakılır; bunun yerine QBE tabanlı bir derleyici arka ucu ve Zig ile yazılmış hafif bir çalışma zamanı kullanılır.

**Temel farklılaşma noktaları:**
- Python'a sözdizimsel olarak yakın, ancak **zorunlu statik tip** ile derlenen bir dil (Mojo'nun kademeli/opsiyonel tipleme yaklaşımından farklı olarak).
- QBE üzerinden doğrudan makine koduna AOT derleme (LLVM/MLIR bağımlılığı yok).
- Katmanlı, çoğunlukla görünmez bir sahiplik/bellek modeli ("Sahiplik Piramidi").
- HPy esinli, izole edilmiş C eklenti modeli.
- WASM modüllerinin gömülü bir çalışma zamanı üzerinden native kütüphane olarak import edilmesi.

---

## 2. Genel Mimari

| Bileşen | Teknoloji | Not |
|---|---|---|
| Derleyici arka ucu | QBE | amd64, arm64, riscv64, amd64_win hedefleri |
| Çalışma zamanı / allocator | Zig | ASAP/ARC mekanizması, GC yok |
| C eklenti köprüsü | HPy tarzı opaque handle | CPython C-API uyumluluk katmanı ile desteklenir |
| WASM entegrasyonu | Gömülü WASM runtime (Zig içinde) | QBE'nin kendisi WASM'ı hedeflemez |

Nox kaynak kodu doğrudan QBE IR'ına çevrilir ve QBE, hedef platform için native assembly üretir. Çalışma zamanı, bellek tahsisi, hata yayılımı ve C/WASM köprüleme mantığını yönetmek için Zig ile yazılmış statik olarak bağlanan bir kütüphanedir.

> **Not (QBE sınırlaması):** QBE şu an doğrudan WASM hedeflemiyor; WASM'a derleme, QBE'nin kontrol akış grafiğinden yapılandırılmış kontrol akışı (structured control flow) çıkarmayı gerektirir ve bu ayrı bir ikincil backend projesidir. Nox'un WASM ile ilişkisi derleme hedefi değil, **içe aktarma/kütüphane kullanımı** yönünde kurgulanmıştır (bkz. Bölüm 6).

---

## 3. Sözdizimi ve Tip Sistemi

- Sözdizimi Python'a birebir yakındır (girinti tabanlı bloklar, `def`, `class`, `for`/`while`, kapsamlı standart operatörler).
- **Tüm değişken, parametre ve dönüş tipleri zorunludur.** PEP 484 tarzı anotasyon sözdizimi (`x: int`, `def f(y: list[str]) -> bool:`) kullanılır, ancak Python'daki gibi opsiyonel değil, derleyici tarafından zorunlu kılınır.
- Bu tercih, çalışma zamanı tip belirsizliğini ortadan kaldırarak Bölüm 4'teki statik sahiplik analizini mümkün kılar. Referans olarak: mypyc (tam tipli Python'u C'ye derleyen mevcut bir proje, mypy/black tarafından kullanılıyor) benzer bir tip disiplini uyguluyor, ancak CPython'ın refcounted nesne modelinde kalıyor — Nox bunun ötesine geçip gerçek stack allocation ve sahiplik analizi hedefliyor.
- **Açık soru:** Polimorfizm/generic mekanizması henüz tanımlanmadı — yapısal tipleme (Python'ın `typing.Protocol`'üne benzer) mi, yoksa nominal trait/arayüz sistemi (Rust trait / Zig comptime generics tarzı) mi kullanılacağı belirlenmeli.

### 3.1 Faz 1 Uygulama Kapsamı — "Nox v0.1 Çekirdek Grameri"

Derleyicinin ilk uygulama fazında (`compiler/lexer`, `compiler/parser`) hayata geçirilen
somut alt küme aşağıdaki gibidir. Bu bölüm, AGENTS.md §7 adım 6 gereği ("davranış
spesifikasyondan sapıyorsa güncelle") eklenmiştir.

**Desteklenen:**
- Literaller: `int`, `float`, `bool` (`True`/`False`), `str` (`'...'`/`"..."`, temel kaçış dizileri), `None`
- Yorumlar (`#`), girinti tabanlı bloklar (INDENT/DEDENT, Python tokenizer modeli)
- Değişken tanımı: ilk atamada zorunlu tip anotasyonu (`x: int = 5`), sonraki atamalar düz (`x = 6`)
- Tipler: `int`, `float`, `bool`, `str`, `None`, `list[T]`, kullanıcı `class` adları
- İfadeler: aritmetik (`+ - * / // % **`), karşılaştırma, `and`/`or`/`not`, parantez, çağrı, `obj.attr`, `list[i]`, liste literali
- Deyimler: `if/elif/else`, `while`, `for x in <iterable>:`, `def` (tüm parametre/dönüş tipleri zorunlu), `return`, `pass`, `class` (yalnızca metodlar — **kalıtım ve metaclass yok**)
- Operatör önceliği Python'a sadıktır; özellikle `-2 ** 2 == -(2 ** 2)` (unary eksi, üs almadan daha düşük önceliklidir, ama üssün sağındaki `-` işareti serbesttir: `2 ** -2` geçerlidir)

**Tasarım kararı — `self` parametresi (Faz FF.4'te GENİŞLETİLDİ, bkz. §3.63):**
`self`in tipi her zaman kapsayan sınıfın/protokolün adıdır — bu, `def __init__(self:
Point, x: int) -> None:` AÇIKÇA yazılarak İFADE EDİLEBİLİR, YA DA (Faz FF.4'ten
beri) `def __init__(self, x: int) -> None:` ÇIPLAK bırakılarak DERLEYİCİYE
ÇIKARTILABİLİR — İKİSİ de TAM OLARAK AYNI anlama gelir (checker/codegen/ownership
analizi arasında HİÇBİR fark YOKTUR, yalnızca `nox fmt` kullanıcının hangisini
YAZDIĞINI SADIK biçimde KORUR). Bu ÖNCEDEN (Faz 1'de) AGENTS.md §5'in "tüm
parametre tipleri zorunlu, asla örtük düşüş yok" ilkesiyle tutarlı kalmak İçin
BİLİNÇLİ bir sapma olarak self İçin İSTİSNASIZ AÇIK anotasyon ZORUNLU kılınmıştı;
bu, AGENTS.md §16 prosedürüne göre (mimariyi etkileyen bir karar olarak)
kullanıcıya AÇIKÇA sunulup ONAYLANDIKTAN SONRA Faz FF.4'te GEVŞETİLDİ — bkz. §3.63
BUNUN gerekçesini VE AGENTS.md §5'in GÜNCEL metnini.

**Faz 1'de bilerek dışarıda bırakılanlar** (sonraki fazlara ertelendi): f-string,
augmented assignment (`+=` vb.), kalıtım, exception sözdizimi (`try/except/raise`),
`lowlevel` bloğu, generic/protokol sözdizimi, `async`. Bunların hiçbiri henüz
lexer/parser'da tanınmıyor; kullanılırsa parser hatası verir.

**Kapsam dışı olan Python dinamik özellikleri** (§5 gereği kalıcı olarak, geri
dönüşü olmayacak şekilde): `setattr`, `exec`, çalışma zamanında sınıf üretme.

Bu fazda yalnızca lexer → parser → AST üretilir; tip denetimi, sahiplik analizi
ve QBE codegen henüz yoktur (bkz. Nox roadmap, sonraki fazlar).

### 3.2 Faz 2 Uygulama Kapsamı — Zorunlu Statik Tip Denetleyici

`compiler/typecheck/` altında hayata geçirilen tip denetleyicisi, Faz 1'in
ürettiği AST üzerinde iki geçişli çalışır: (1) tüm modül-seviyesi fonksiyon ve
sınıf imzaları ileri-referansları destekleyecek şekilde önceden kaydedilir,
(2) gövdeler bu imzalar ışığında denetlenir.

**Tip sistemi:** `int`, `float`, `bool`, `str`, `None`, `list[T]`, sınıf
örnekleri (nominal, sınıf adıyla). Aritmetik operatörlerde `int`/`float`
karışık kullanımda `float`'a yükseltme (promotion) uygulanır; `/` (gerçek
bölme) her zaman `float` döner, `//` (tam bölme) yükseltme kuralına tabidir.
Atamalarda tek örtük dönüşüm `int → float`'tır; başka hiçbir örtük dönüşüm yok.

**Sınıf alanları:** Bir sınıfın alanları İKİ şekilde belirlenebilir —
(1) ÖRTÜK ÇIKARIM: yalnızca `__init__` içindeki İLK `self.<ad> = <ifade>`
ataması alanın tipini belirler (`__init__` diğer metodlardan önce
denetlenir ki alan tipleri bilinsin), YA DA (2) Faz FF.5'ten beri (bkz.
§3.64) AÇIK BİLDİRİM: sınıf gövdesinde çıplak `<ad>: <tip>` (PEP 526
tarzı, initializer YOK) yazılabilir — bu durumda atama HÂLÂ `__init__`de
yapılır (checker, bildirilen HER alanın `__init__` SONUNDA GERÇEKTEN
atandığını doğrular), ama TİP çıkarım YERİNE bildirimden ALINIR. İKİ
mekanizma AYNI sınıfta BİRLİKTE kullanılabilir. `__init__` dışında (ve
bildirim OLMADAN) yeni alan tanımlanamaz. Bu, AGENTS.md İlke #1'in
yasakladığı bir *ownership* sözdizimi değildir — yalnızca tip
çıkarımı/bildirimi içindir.

**Bilinçli kapsam sınırlamaları (v0.1):**
- Kaynak konumu (satır/sütun) izlenmez; `ast.zig` düğümleri henüz pozisyon
  taşımıyor. Tanılamalar yalnızca açıklayıcı metindir. Hassas konumlu
  tanılama, AST'ye pozisyon eklenmesini gerektiren ayrı bir iyileştirme
  olarak ileride ele alınmalıdır (küçük/geri alınabilir bir karar, AGENTS.md
  §16 madde 2 kapsamında ertelendi).
- İlk tip hatasında durulur (çoklu tanılama/hata kurtarma yok). Bu, hata
  yayılımını basit tutmak için bilinçli bir v0.1 kararıdır.
- `range(...)` ve `print(...)` derleyiciye gömülü, genel bir stdlib imza
  sistemi olmadan tanınan iki özel yerleşiktir (`range` yalnızca `for x in
  range(n):` konumunda anlamlıdır, genel bir değer olarak dönmez). Genel
  stdlib/generic fonksiyon imza sistemi ileride ele alınacaktır.
- Boş liste literali (`[]`) bağlamdan tip çıkarımı yapılamadığı için hata
  verir (İlke #1/§5 ruhuna uygun: örtük `Any`'e düşüş yok).
- `if`/`while` koşulları Python'daki gibi "truthy" değerlendirilmez; kesin
  olarak `bool` tipinde olmalıdır (statik/güvenli tercih).

Golden testler: `tests/golden/typecheck_cases/` — 3 başarılı senaryo
(aritmetik+kontrol akışı, fonksiyon+sınıf, liste+indeksleme) ve 6 hata
senaryosu (tip uyuşmazlığı, tanımsız değişken, argüman sayısı uyuşmazlığı,
bool olmayan koşul, tanımsız sınıf alanı, `range` için geçersiz argüman).

### 3.3 Faz 3 Uygulama Kapsamı — Sahiplik Analizi (Katman 1/2 Kararı)

`compiler/ownership/analysis.zig`, Faz 2'den başarıyla geçmiş (iyi tiplenmiş)
bir modül üzerinde çalışarak her heap tipli bağlama (`str`, `list[T]`, sınıf
örnekleri — `int`/`float`/`bool`/`None` hiçbir zaman bu analize girmez) için
Katman 1 (ASAP) ya da Katman 2 (ARC) kararı verir. Bu, AGENTS.md §8'in
tanımladığı "Sahiplik Piramidi"nin ilk iki katmanının **derleyici karar
mekanizmasıdır**; gerçek runtime destructor/refcount kodu Faz 5'te eklenecektir.

**Karar kuralı (muhafazakâr, İlke #1 ile tutarlı — terfi tamamen sessiz):**
- **Parametreler (`self` dahil) her zaman Katman 2 (ARC)'dir.** Bir değerin
  fonksiyon sınırını geçtikten sonra çağıran tarafından tekrar
  kullanılmadığını kanıtlayacak bir ödünç/taşıma (borrow/move) analizi yok;
  en güvenli seçenek uygulanır.
- **Yerel `var_decl` bağlamaları varsayılan olarak Katman 1 (ASAP)'dir**;
  şu "kaçış" durumlarından biri tespit edilirse Katman 2 (ARC)'ye terfi eder:
  `return <ad>` ile doğrudan döndürülme; `self.<alan> = <ad>` ile bir sınıf
  alanına atanma; `[..., <ad>, ...]` ile bir liste literaline eklenme; bir
  fonksiyon/metod çağrısına argüman ya da metod alıcısı olarak geçme.
- **Bilinen istisna:** `print(...)` derleyiciye gömülü olduğu ve argümanını
  hiçbir yerde saklamadığı kesin olarak bilindiği için (kullanıcı tanımlı
  fonksiyonların aksine) kaçış sayılmaz. Bu, "muhafazakârlık" ilkesini ihlal
  etmez — belirsizlikten değil, `print`'in tam olarak bilinen semantiğinden
  kaynaklanan bir kesinliktir.
- Bir değişken yeniden atanırsa (`x = ...`) ya da aynı isimle yeniden
  `var_decl` edilirse, bu ayrı bir **serbest bırakma noktası** üretir (eski
  değer o an serbest bırakılır); son değer için kapsam sonu her zaman son
  serbest bırakma noktasıdır. AGENTS.md §8 Katman 1'in şart koştuğu "hem
  tahsis hem serbest bırakma noktası" golden test gereksinimi bunu kapsar.

**Bilinçli kapsam sınırlamaları (v0.1):**
- `for x in <iterable>:` döngü değişkenleri bu analize dahil değildir (tipi
  sözdiziminde açık değil, çıkarım gerektirir — ayrı bir iyileştirme).
- Sınıf alanlarının kendi başına ayrı bir ASAP/ARC kararı yoktur; alan ömrü
  sahibi olan örneğin kararına bağlıdır (bir bütün olarak taşınır).
- Analiz, ismi bir bağlamaya karşılık gelmeyen anonim ara değerler
  (adlandırılmamış geçici ifadeler) için hiçbir karar üretmez; bunların
  QBE codegen'de (Faz 4) doğrudan üretilip tüketilmesi yeterlidir.

Golden testler: `tests/golden/ownership_cases/` — yerel değişkenin kaçmadığı
ASAP senaryosu, yeniden atamanın ek serbest noktası ürettiği senaryo,
`return`/`self.alan`/liste-literali/çağrı-argümanı/metod-alıcısı yollarıyla
ARC'ye terfi senaryoları ve parametrelerin her zaman ARC olduğu senaryo.

### 3.4 Faz 4 Uygulama Kapsamı — QBE Codegen (Yalnızca Değer Tipleri)

`compiler/codegen_qbe/codegen.zig`, Faz 2'den geçmiş bir modülü gerçek QBE IL
metnine çevirir; `noxc`, ürettiği `.ssa` dosyasını sistemdeki `qbe` binary'sine
(`brew install qbe`, bkz. Faz 0 kararı) ve ardından sistem `cc`'sine (`-lm` ile)
vererek **gerçek, çalışan bir native binary** üretir. Bu faz uçtan uca
doğrulandı: özyinelemeli Fibonacci, işaretli tam bölme/mod, üs alma, karışık
int/float aritmetiği, bool mantığı ve `for`/`if`-`elif`-`else` içeren
programlar gerçekten derlenip çalıştırılarak stdout'ları golden test edildi
(`tests/golden/codegen_cases/`) — AGENTS.md'nin izin verdiği "kaynak → beklenen
davranış" golden test biçimi (yalnızca IR metni değil, çalışma zamanı sonucu).

**Kapsam (bilinçli sınır):** yalnızca değer tipleri — `int` (QBE `l`), `float`
(QBE `d`), `bool` (QBE `w`, 0/1), `None`. Heap tipler (`str`, `list[T]`, sınıf
örnekleri) bu geçişte **desteklenmiyor**; böyle bir tipe rastlanırsa
`error.Unsupported` döner ve `noxc` açık bir mesajla durur. Heap tiplerin
gerçek bellek düzeni, ASAP destructor/ARC retain-release kodu ve runtime
allocator'ı hazır olmadan bu tipler için kod üretmek "sahte doğruluk" olurdu;
bu yüzden bilinçli olarak ertelendi (bir sonraki codegen alt-fazında, Faz 5'in
runtime'ıyla birlikte ele alınacak).

**Uygulama teknikleri:**
- Her Nox değişkeni (parametre/yerel/`for` sayacı) bir QBE `alloc`+`load`/`store`
  üçlüsüyle bellek üzerinden temsil edilir — elle SSA/phi inşası yerine basit
  ve her zaman doğru bir yaklaşım (QBE kendi optimizasyonunda register'a
  yükseltebilir).
- **Aritmetik doğruluk:** QBE'nin `div`/`rem`'i C/donanım gibi sıfıra doğru
  keser; Nox'un `//`/`%`'i Python gibi tabana doğru (floor) davranır — bu fark
  açıkça telafi edilir (işaret kontrolü + gerekirse `-1`/`+bölen` düzeltmesi).
  `**` her zaman `libm`'in `pow`'u üzerinden yürütülür (int`**`int için de,
  büyük üslerde kayan nokta hassasiyet sınırı bilinen bir sınırlamadır).
- `for x in <iterable>:` yalnızca `range(n)` biçimini destekler; başka bir
  iterable `error.Unsupported` verir (liste yinelemesi heap gerektirir).
- `print(...)` sistemin `libc` `printf`'i üzerinden çalışır (henüz Faz 5'in
  Zig runtime'ı yok); `bool` "True"/"False" olarak, `float` `%g` ile basılır
  (Python'ın tam `repr`'ı ile birebir eşleşmeyebilir — bilinen kozmetik
  sınırlama, hesaplanan değerin doğruluğunu etkilemez).
- `and`/`or` **kısa devre yapmaz** (her iki operand da her zaman
  değerlendirilir) — v0.1'de yan etkili bool ifadeler nadir olduğundan
  (fonksiyon çağrıları hariç) bilinçli bir basitleştirme; ileride kısa devre
  eklenmesi küçük/geri alınabilir bir iyileştirmedir.

**Bu geçişte ortaya çıkan ve giderilen bir Faz 2 eksikliği:** Codegen, QBE'nin
her temel bloğun bir sonlandırıcıyla bitmesini şart koştuğunu ortaya çıkardı;
bu da bir fonksiyonun **tüm yollarda** `return` yapıp yapmadığının statik
olarak kanıtlanması gerektiğini gösterdi. Bu kontrol (`alwaysReturns`,
muhafazakâr: yalnızca `if/elif/else`'in TÜM dallarının döndüğü kanıtlanabilir
durumlar sayılır, `while`/`for` en az bir kez çalışır varsayılmaz) artık
`checker.zig`'e eklendi (`MissingReturn` hatası) — bu, Faz 2'nin kendi
sorumluluk alanına giren gerçek bir doğruluk düzeltmesiydi, kapsam genişletme
değil.

Golden testler: `tests/golden/codegen_cases/` — beşi de gerçekten derlenip
çalıştırılan, stdout'u karşılaştırılan programlar (fibonacci, işaretli
floordiv/mod, pow+karışık aritmetik, bool mantığı, for-range+if/elif/else).

### 3.5 Faz 5 Uygulama Kapsamı — Zig Runtime + Heap Tipler (str, list[T])

`runtime/alloc/asap.zig`, AGENTS.md §8 Katman 1'in gerçek çalışma zamanı
karşılığıdır: `nox_runtime_init`/`nox_runtime_deinit`/`nox_alloc`/`nox_free`
(C-ABI, `export fn`). **İlke #6** ("global/gizli mutable state yasak; allocator
her zaman açık parametre") şöyle karşılanır: derlenmiş her Nox programı,
`main`'in `nox_runtime_init()` ile bir kez oluşturduğu opak bağlamı (`rt`) her
fonksiyona **gizli değil, görünür bir ilk parametre olarak** taşır — bu, QBE
IR'da her çağrıda açıkça görülen bir parametredir, statik/global bir değişken
değildir. Runtime, `zig-out/lib/noxrt.o` olarak derlenip `noxc`'nin `cc`
çağrısına eklenir (bir `.a` arşivi yerine tek nesne dosyası: bazı Zig
sürümlerinde macOS'ta ar üyesi hizalama hatası gözlendi, bkz. `build.zig` notu).

**`str` — heap ama tahsissiz:** v0.1 grameri hiçbir string ÜRETEN işlem
içermez (birleştirme, biçimlendirme, okuma yok — tek kaynak string
literalleridir). Bu yüzden her `str` değeri QBE `data` bölümünde statik
salt-okunur bir bayt dizisine işaret eder; **hiçbir zaman tahsis edilmez,
hiçbir zaman serbest bırakılmaz.** Katman 1/2 kararı `str` için anlamsızdır —
parametre/dönüş/alan/argüman gibi her kaçış yolunda güvenle kullanılabilir.

**`list[T]` — yalnızca kaçmayan yerel değişkenler:** Bir listenin parametre ya
da dönüş tipi olması, bir çağrıya argüman olması, `print`'e verilmesi, başka
bir listeye/değişkene takma ad olması (`ys = xs`) ya da iç içe heap
elemanı olması (`list[str]`, `list[list[T]]`) bu geçişte **kabul edilmez**
(`error.Unsupported`). Gerekçe: AGENTS.md §8 Katman 1'in kendisi muhafazakâr
olmak zorunda — bu yolların hepsi Faz 3'ün ownership analizinde ARC'ye terfi
ettiren kaçış senaryolarıdır (bkz. §3.3) ve Katman 2 (ARC) runtime'ı henüz
yok. Geriye kalan güvenli durum ("yerel değişken, hiç kaçmıyor") için gerçek
bir çalışma zamanı temsili üretilir: `{ len: i64, elemanlar... }` düz heap
bloğu; literal ile oluşturma, indeksleme (**sınır denetimi yok** — bilinen
sınırlama) ve `range(n)` ya da başka bir `list[T]`'nin üzerinde `for` ile
iterasyon desteklenir.

**Bu geçişte keşfedilen ve giderilen bir Faz 3 eksikliği:** Codegen'in
"bir liste yerelinin asla kaçmadığını" güvenle varsayabilmesi için, bir
listeyi **başka bir değişkene isimle atamanın** (`ys: T = xs` ya da
`ys = xs`) da bir kaçış sayılması gerektiği ortaya çıktı — aksi halde iki
değişken aynı heap bloğuna işaret edip kapsam sonunda **çifte serbest
bırakmaya** yol açabilirdi. `ownership/analysis.zig`'e bu "takma ad" kuralı
eklendi (yeni golden test: `arc_alias_escape.nox`). Codegen ayrıca kendi
tarafında da aynı örüntüyü doğrudan reddeder (`rejectListAlias`) — savunmada
iki katman.

**Güvenlik ağı — sıfırla ve koşullu serbest bırak:** Her liste tipli slot,
fonksiyon girişinde `0`'a (null) ilklenir; her serbest bırakma noktası
(yeniden atama/tanımlama, kapsam sonu) `ptr != 0` kontrolüyle korunur. Bu,
yalnızca bir `if` dalında tanımlanan bir listenin, o dal hiç çalışmasa bile
güvenle "atlanmasını" sağlar.

**Bilinen sınırlama — erken `return` (Faz 7'de düzeltildi):** Faz 5/6'da, bir
fonksiyonun içinde hem heap tipli bir yerel değişken hem de erken `return`
varsa, o `return`'ün kapsam-sonu temizliğini atlayıp diğer yerelleri
sızdırdığı belgelenmişti. Faz 7, `return`'ü gerçek `ret`ten önce dönen
değerin KENDİ bağlaması hariç tüm heap yerelleri serbest bırakacak şekilde
düzeltti (`releaseAllLocalsExcept`) — bkz. §3.7.

Golden testler: `tests/golden/codegen_cases/` — `str` parametresi+yazdırma,
`list[int]` oluşturma+indeksleme+iterasyon, liste yeniden atamasının eskisini
güvenle serbest bıraktığı senaryo, ve bir liste parametresinin bu fazda
temiz biçimde reddedildiğini doğrulayan test.

> **Not (Faz 6 tarafından güncellendi):** Bu bölümdeki "liste parametresi/
> dönüşü/argümanı/takma adı reddedilir" sınırlaması Faz 6'da kaldırıldı —
> gerçek referans sayımı (ARC) devreye girince bunların hepsi güvenli hale
> geldi. Ayrıntı için §3.6'ya bakın.

### 3.6 Faz 6 Uygulama Kapsamı — ARC (Katman 2) + Sınıflar

`runtime/alloc/arc.zig`, Katman 1'in (`asap.zig`) üzerine ince bir referans
sayacı katmanı ekler: `nox_rc_alloc` (refcount=1 ile tahsis), `nox_rc_retain`
(+1), `nox_rc_release` (-1; sıfıra ya da altına inerse gerçek belleği serbest
bırakır). Refcount, payload'dan hemen önceki görünmez 8 baytlık bir başlıkta
tutulur — çağıran QBE kodu bunun varlığından tamamen habersizdir; bu yüzden
Faz 5'in `list[T]` indeksleme/iterasyon kodu **hiç değişmeden** çalışmaya
devam eder, yalnızca tahsis/serbest bırakma çağrıları değişti.

**Ödünç alma (borrow) modeli — asıl basitleştirici içgörü:** Bir metod çağrısı
ya da fonksiyon çağrısı **senkrondur**; çağrılan taraf referansı kalıcı olarak
saklamadığı sürece (ki v0.1'de yalnızca `self.<alan> = <isim>` ile saklanır,
ve alan tipleri heap olamaz — aşağıya bakın) hiçbir sayaç değişikliği
gerekmez. Bu şu demektir:
- **Parametre/argüman/metod alıcısı olarak geçmek** yalnızca bir ödünçtür —
  `retain`/`release` YOK. Çağıran kendi referansına sahip kalmaya devam eder.
- **Parametreler hiçbir zaman `release` edilmez** (ödünç alınmıştır) —
  yeniden atansalar bile (bilinçli sınırlama: yeni değer sızabilir, ama
  ödünç alınan orijinal değer yanlışlıkla serbest bırakılmaz).
- **Bir değeri BAŞKA BİR İSME atamak** (`y = x` / `y: T = x`) bir `retain`
  üretir — artık iki bağımsız "sahip" aynı nesneyi paylaşıyor.
- **Yerel (parametre olmayan) her heap bağlamı**, kapsam sonunda (ya da daha
  önce yeniden atama/tanımlamada) tam olarak bir `release` alır — Katman 1
  (hiç kaçmayan, refcount hep 1) ile Katman 2 (kaçan, refcount >1) arasında
  **kod düzeyinde hiçbir ayrım yapmaya gerek kalmadan**, aynı mekanizma
  ikisini de doğru şekilde ele alır.
- **`return`** özel bir işlem gerektirmez: kapsam-sonu temizliği zaten
  `return`'da atlanıyor (bkz. §3.5'teki bilinen sınırlama), bu da sıfır
  maliyetli bir "taşıma" ile sonuçlanır.

Bu model sayesinde Faz 5'te reddedilen tüm durumlar (liste parametresi,
dönüşü, argümanı, takma adı) artık **güvenle destekleniyor** — hiçbiri için
özel kod gerekmedi, yalnızca yukarıdaki iki genel kural (ödünç alma + takma ad
retain'i) yeterli.

**Sınıflar:** Bir sınıf örneği refcount başlıklı düz bir alan bloğudur.
Alanlar VARSAYILAN olarak **`__init__` gövdesindeki `self.<ad> = <ifade>`
atamalarından** çıkarılır (`inferFieldType`) — DOĞRUDAN bir `__init__`
parametresi, bir literal, `self` (öz-referans) ya da (SONRAKİ fazlarda
genişletildi — bkz. stdlib fazı §L, Faz U.4.3) BAŞKA bir sınıf/`list[T]`
tipinde bir alan OLABİLİR; yalnızca `__init__`in ÜST-DÜZEY (if/while/try
İÇİNE İÇ İÇE OLMAYAN) atamalarını TARAR — checker'ın (Faz 2) tam ifade
tipi çıkarımını/TAM gövde özyinelemesini codegen'de YENİDEN uygulamamak
için bilinçli bir kapsam sınırlaması. **Faz FF.5'ten beri (bkz. §3.64):**
bir alan AÇIKÇA bildirilmişse (`<ad>: <tip>`), codegen bu tipi `resolveType`
İLE DOĞRUDAN kullanır — `inferFieldType`nin YUKARIDAKİ sınırlamasını
(ör. bir `if` İÇİNDE atanan bir alan) O ALAN İçin TAMAMEN AŞAR. Bildirilen
alanlar `__init__` taramasından ÖNCE (bildirim SIRASIYLA) bayt ofseti
alır — bu SIRA HİÇBİR DIŞA açık garanti TAŞIMAZ (sınıf örnekleri C ABI
sınırını hiç GEÇMEZ). Kurucu çağrısı (`ClassName(...)`) `nox_rc_alloc` +
üretilen `$ClassName___init__` fonksiyonunu çağırır; metod çağrıları
`$ClassName_metodadı(rt, self_ptr, ...)` olarak QBE fonksiyonlarına lowerlanır;
alan okuma/yazma sabit bayt ofsetleriyle yapılır (her alan basitlik için 8
bayt, hizalama hesaplaması yok).

**Bilinçli kapsam sınırlamaları (v0.1'de burada yazılmıştı — hepsi §3.23'te
ÇÖZÜLDÜ, bu liste yalnızca tarihsel bağlam için tutuluyor):**
- ~~`list[T]`/sınıf **içerik karşılaştırması** (`==`/`!=`) yok~~ — §3.23'te
  özyinelemeli yapısal `==`/`!=` olarak eklendi.
- ~~`list[T]`/sınıf **yazdırma** (`print`) yok~~ — §3.23'te Python benzeri
  (`[...]`/`ClassName(...)`) görüntüleme olarak eklendi.
- ~~İç içe heap tipler (`list[str]`, `list[list[T]]`) yok~~ — §3.22'de
  (Faz 21 ön-koşulu) eklendi; ~~heap alanlı sınıflar yok~~ — §3.23'te
  `list[T]` tipli sınıf alanları eklendi (başka bir SINIF tipli alan zaten
  Faz 9'dan beri destekleniyordu, bkz. §3.9).
- ~~`__init__` içermeyen sınıflar desteklenmiyor~~ — §3.23'te eklendi.
- Erken `return`'ün döndürülmeyen diğer yerelleri sızdırması sınırlaması
  (§3.5) hâlâ geçerli — Katman 3 (döngü çözücü) ile birlikte ele alınacak.
- AGENTS.md §13 gereği: `runtime/alloc/asap.zig`'in `nox_runtime_deinit`'i artık
  bir sızıntı tespit ederse bunu stderr'e açıkça bildiriyor; codegen golden
  testleri artık çalıştırılan programın stderr'inin **boş** olduğunu da
  doğruluyor (leak testi yeşil).

Golden testler: `tests/golden/codegen_cases/` — liste parametre/dönüş/takma ad
(artık çalışıyor), sınıf (kurucu + metod + alan okuma/yazma + takma ad). İç içe
heap tipler ve yukarıdaki diğer sınırlamalar artık REDDEDİLMİYOR — bkz. §3.22
ve §3.23.

### 3.7 Faz 7 Uygulama Kapsamı — Hata Yönetimi (`raise`/`try`/`except`/`finally`)

AGENTS.md §9'un gerektirdiği gibi, hata yayılımı **hiçbir zaman** QBE unwind
tablosu/landing pad kullanmaz (İlke #3). Bunun yerine, her hata verebilecek
çağrı noktasından hemen sonra derleyicinin ürettiği örtük bir "bekleyen
istisna var mı?" kontrolü (`emitExceptionCheck`) ile — Zig'in kendi
`error union`larına doğrudan benzeyen bir örtük hata-döndürme zinciri.

**Çalışma zamanı durumu (`runtime/errors/handle.zig`):** bekleyen istisna,
çalışma zamanı bağlamının (`rt`) bir alanıdır (`pending_exception`) — İlke #6
gereği bu gizli bir global DEĞİLDİR, her çağrıda açıkça taşınan `rt`
üzerinden erişilir. `nox_raise`/`nox_exception_pending`/`nox_exception_take`
bu alanı yönetir.

**Sınıflara çalışma zamanı tip etiketi:** `except ClassName:` eşleşmesinin
çalışma zamanında çalışabilmesi için, her sınıf örneği artık (refcount
başlığından hemen sonra, alanlardan önce) bir tam sayı sınıf kimliği taşır
(modül içinde sınıf kaydı sırasına göre atanır). Eşleşme bu kimliğin
doğrudan karşılaştırılmasıyla yapılır. **v0.1'de sınıf kalıtımı olmadığı
için bu eşleşme tam/isim bazlıdır, hiyerarşik DEĞİLDİR** — `except Base:`,
`Derived` türünde fırlatılmış bir nesneyi yakalamaz (kalıtım eklendiğinde
ayrıca ele alınacak bir açık tasarım sorusu).

**`raise <ifade>`:** yalnızca bir sınıf örneği fırlatılabilir (checker
zorunlu kılar). `try: ... except ClassName [as ad]: ... finally: ...` —
birden fazla `except` sırayla denenir; hiçbiri eşleşmezse istisna yeniden
işaretlenip dışarıya yayılır.

**Bu geçişte keşfedilip düzeltilen iki gerçek eksiklik** (ilki daha önce
belgelenmiş bir sınırlamayı kapatıyor, ikincisi tamamen yeni):
1. **Erken `return`'ün diğer yerelleri sızdırması** (Faz 5/6'da belgelenmişti)
   artık düzeltildi: her `return`, dönen değerin KENDİ bağlaması hariç tüm
   heap yerelleri serbest bırakır (`releaseAllLocalsExcept`).
2. **`finally`, `try`/`except` içinde bir `return` olduğunda hiç
   çalışmıyordu** (bu fazda ilk uygulamada keşfedildi) — Python'da `finally`
   HER çıkış yolunda (normal tamamlanma, `return`, yakalanmamış istisna)
   çalışmalıdır. QBE'de paylaşılan bir "unwind" hedefi olmadığından (İlke
   #3), çözüm `finally` gövdesini HER çıkış noktasında satır içi (inline)
   üretmektir (`drainFinally` + `finally_stack`) — tek bir paylaşılan
   temizlik bloğuna atlamak yerine.
3. **`main`'den yakalanmamış bir istisna** artık sessizce başarıyla bitmiş
   gibi davranmaz: `nox_unhandled_exception` bir hata mesajı basar ve
   sıfırdan farklı bir çıkış koduyla sonlanır (Python'ın yakalanmamış istisna
   davranışına benzer) — aradan geçilen `finally` blokları programı
   sonlandırmadan önce yine de çalıştırılır.

**Bilinçli kapsam sınırlamaları (v0.1):**
- Sınıf kalıtımı olmadığı için `except` eşleşmesi hiyerarşik değildir (yukarı
  bakın).
- `raise` argümansız (yeniden fırlatma, `raise` tek başına) desteklenmiyor.
- `raise X from Y` desteklenmiyor.
- `with` (context manager `__enter__`/`__exit__` protokolü) henüz yok.
- Aynı isim (`as e`) kardeş `except` dallarında kullanılırsa, düz (flat)
  kapsam modeli yüzünden yalnızca SON kaydedilen sınıf tipi geçerli olur —
  golden test fixture'ları bu yüzden farklı isimler (`e1`, `e2`) kullanır.
  Gerçek per-clause sözcüksel kapsamlama ileride ele alınabilir.

Golden testler: `tests/golden/codegen_cases/` — eşleşen/eşleşmeyen `except`
tipleri + `finally`'nin her çıkışta çalıştığı senaryo, yakalanmamış bir
istisnanın programı sıfırdan farklı bir kodla sonlandırdığını doğrulayan
test; `tests/golden/typecheck_cases/` ve `tests/golden/ownership_cases/`'a da
karşılık gelen testler eklendi.

---

### 3.8 Faz 8 Uygulama Kapsamı — `lowlevel` Bloğu (Katman 4)

AGENTS.md §8'in tanımladığı 4. katman: performans-kritik yerel hesaplamalar
için bir kaçış kapısı. İlke #2 gereği bu **yalnızca tahsis stratejisini**
gevşetir — tip sistemi `lowlevel:` gövdesinde de tam olarak zorunludur,
`checker.zig` gövdeyi tamamen normal kurallarla denetler (özel bir istisna
yoktur).

**Arena mekanizması:** blok girişinde bir arena oluşturulur
(`nox_arena_create`, `runtime/alloc/lowlevel.zig` — Zig'in
`std.heap.ArenaAllocator`'ının çalışma zamanının kendi `DebugAllocator`'ı
üzerine ince bir sarmalayıcısı). Blok içinde inşa edilen her `list[T]`/sınıf
örneği, Katman 1/2'nin refcount'lu `nox_rc_alloc`'u yerine bu arenadan
(`nox_arena_alloc`) tahsis edilir ve hiçbir zaman bireysel olarak retain/
release edilmez (arena belleğinde refcount başlığı yoktur — bir retain/
release bitişik belleği bozardı). Blok normal tamamlandığında arena TEK
SEFERDE yıkılır (`nox_arena_destroy`); her erken çıkışta (`return`,
yakalanmamış istisna) `drainArenas`, `finally` için kullanılan "her çıkış
yolunda satır içi yıkım" desenini (`drainFinally`) aynen izler — QBE'de
paylaşılan bir unwind hedefi olmadığından (İlke #3).

**Kaçış engelleme — kasıtlı olarak GENİŞ bir kural:** arena-lık bir
fonksiyonun statik imzasının parçası değildir, yalnızca belirli bir çağrı
yerindeki belirli bir değerin özelliğidir ve fonksiyon sınırını hiçbir zaman
aşmaz. Bu yüzden dar bir kural ("yalnızca `return`/alan ataması gibi GERÇEKTEN
kaçıran kullanımları engelle") yetersiz kalır: bir arena değerini bir
fonksiyona argüman/alıcı olarak geçirmek güvenli görünür (senkron çağrı,
"ödünç"), ama çağrılan gövde bu parametreyi kendi içinde `return` ederse ya da
bir alana atarsa (arena-lığından habersiz, çünkü bu bilgi imzada yok), çağıran
taraf sonucu normal bir ARC değeriymiş gibi retain/release edip refcount
başlığı OLMAYAN belleği bozar — ara-yordamsal (interprocedural) analiz
olmadan bu ayrım yapılamaz. Bu yüzden derleyici **`lowlevel` bloğu içinde
lexical olarak bulunulduğu sürece HİÇBİR heap tipli değerin bir çağrıya
argüman, bir metod çağrısının alıcısı olamayacağını, `return` edilemeyeceğini
ya da başka bir isme takma ad olamayacağını** zorunlu kılar
(`checkNoLowlevelEscape`). Bu, aksi halde güvenli olan bazı desenleri de
(ör. arena bir nesnenin bir metodunu çağırmak) engeller — basit ve sağlam
olması, v0.1 için doğru ödünleşimdir.

**Kapsam:** `lowlevel:` içinde tanımlanan adlar bloktan SONRA kapsam dışına
alınır (`checker.zig`, önce/sonra anlık görüntü farkıyla scope'tan çıkarılır)
— arena blok çıkışında yıkıldığı için, aksi halde bloktan sonraki bir kullanım
kullanım-sonrası-serbest-bırakma (use-after-free) olurdu.

**Bilinçli kapsam sınırlamaları (v0.1):**
- Arena bir nesnenin bir metodunu (ya da onu herhangi bir fonksiyona) bloğun
  İÇİNDEYKEN dahi çağırmak reddedilir — yalnızca doğrudan alan okuma/yazma ve
  liste indeksleme (bunlar çağrı değil, doğrudan bellek erişimidir) desteklenir.
- Döngüsel referans çözücü (Katman 3) gibi, `lowlevel` de generics/protokoller
  ile henüz etkileşmiyor (ileride ele alınacak).
- Kalan tek teorik risk ("passthrough" bir fonksiyonun bir arena değeriyle
  çağrılıp onu olduğu gibi döndürmesi) yukarıdaki geniş argüman/alıcı kuralı
  tarafından zaten engellendiği için pratikte oluşamaz — belgelenmiş, kasıtlı
  bir tasarım kararıdır (bkz. `compiler/codegen_qbe/codegen.zig` modül üstü not).

Golden testler: `tests/golden/codegen_cases/lowlevel_basic.nox` (arena
üzerinden sınıf + liste, alan okuma, sızıntısız çalıştırma — stderr boş),
`tests/golden/codegen_cases/rejected_lowlevel_escape.nox` (bloktan bir arena
değeri `return` etmek `error.Unsupported` ile reddedilir);
`tests/golden/typecheck_cases/ok_lowlevel_block.nox` (normal tip denetimi
uygulanır), `err_lowlevel_type_mismatch.nox` (blok içinde de tip hatası
yakalanır), `err_lowlevel_scope_leak.nox` (bloktan sonra kapsam dışı kalma).

---

### 3.9 Faz 9 Uygulama Kapsamı — İç İçe Sınıf Tipli Alanlar + Özyinelemeli ARC Release

Faz 6'da bilinçli olarak dışarıda bırakılan bir sınırlama kapatıldı: bir
sınıf alanı artık BAŞKA BİR SINIF tipinde olabilir (ör. `Car.engine: Engine`).
`list[T]` tipli alanlar hâlâ desteklenmiyor (kapsam yalnızca sınıf tipli
alanlarla sınırlı tutuldu — ayrı bir karmaşıklık ekleyecekti).

**Döngüler neden hâlâ imkansız (Katman 3 hâlâ gerekmiyor):** bir sınıf alanı
yalnızca DAHA ÖNCE (dosyada daha erken) tanımlanmış bir sınıfa referans
verebilir — `registerClass`'ın tek geçişli, sıralı doğası (bir sınıf kendi
`__init__`'i işlenirken henüz `self.classes`'a eklenmemiştir) bunu doğal
olarak dayatır. Bu, hem ÖZ-REFERANSI (`class Node: self.next: Node`) hem de
İLERİ-REFERANSLI karşılıklı döngüleri (`A`nın bir `B` alanı VE `B`nin bir `A`
alanı olması) derleme zamanında imkansız kılar — bilinçli bir tasarım kararı
değil, mevcut kayıt sırasının doğal bir sonucu, ama isabetli: bu sayede
Katman 3 (döngü çözücü) bu fazda da hâlâ gerekmiyor.

**Özyinelemeli release:** her sınıf için üretilen `$ClassName_release` (bkz.
`genClassRelease`), refcount'u azaltıp (yeni çalışma zamanı primitifi
`nox_rc_predecrement`) sıfıra düştüğünde ÖNCE sınıf tipli her alanı (varsa,
null değilse) özyinelemeli olarak serbest bırakır, SONRA belleği gerçekten
serbest bırakır (`nox_rc_free_payload`) — çalışma zamanının kendisi (`arc.zig`)
alan düzeninden habersizdir, bu yüzden bu özyineleme DERLEME ZAMANINDA
üretilen, sınıfa özgü bir fonksiyondadır.

**Uçtan uca manuel test sırasında keşfedilip düzeltilen üç gerçek eksiklik**
(hiçbiri planlanmamıştı — nested-field desteği önceden var olmayan kod
yollarını ilk kez gerçek kullanıma soktu):

1. **`genFieldRead` sınıf tipli bir alanın `class_name`'ini sonuca hiç
   taşımıyordu** — zincirleme alan okuması (`c.engine.hp`) `class_name`
   `null`'ken `.?` ile panikliyordu. Daha önce hiçbir alan sınıf tipli
   olmadığı için bu hiç tetiklenmemişti.
2. **Parametre/alan-okuması geçişi (passthrough) refcount sızdırıyordu:**
   bir parametreyi doğrudan bir ALANA (`self.attr = param`) atamak var olan
   takma-ad kuralıyla (retain) doğru işliyordu, AMA çağıranın argümanı TAZE
   bir değerse (ör. `c.swap(make(i))`) hiçbir şey bunu telafi etmiyordu —
   binlerce yinelemeli bir stres testinde (`nested_free_on_overwrite.nox`
   taslağı) doğrulanan gerçek, sürekli bir sızıntı. **Düzeltme:**
   `releaseTemporaryArgs`/`releaseIfTemporary` — çağıran, bir çağrıya/alıcıya
   TAZE bir değer (`.call`/`.list_lit`, bkz. `isTemporaryExpr`) geçirdiyse,
   çağrı döndükten SONRA bunu serbest bırakır (callee retain ettiyse 1'e
   iner, etmediyse 0'a inip gerçekten serbest kalır — iki durumda da doğru).
3. **`return p` (bir parametre) ve `return self.attr` (bir alan okuması) HİÇ
   retain etmiyordu** — bu, `return`ün yalnızca KENDİ yerel bağlamasını
   döndürdüğü (retain gerektirmeyen "taşıma") varsayımına dayanıyordu, ama bu
   varsayım BAŞKA BİR YERDE zaten sahibi olan ödünç alınmış bir referans için
   YANLIŞTIR. **Düzeltme:** `returnNeedsRetain` — parametre/alan-okuması
   dönüşleri artık retain eder; bu, madde 2'deki çağıran-taraf telafi
   release'iyle birlikte "passthrough" fonksiyonlarını (ör.
   `def identity(p): return p`, ya da bir alanı dışarı veren bir metod) bile
   güvenli kılar. Bu düzeltmenin KENDİSİ de yeni bir sızıntı yüzeye
   çıkardı (madde 4).
4. **Bir çağrının/indekslemenin/alan-okumasının TABANI, bir alt-ifadenin
   (`.call`) TAZE sonucuysa ve yalnızca dolaylı olarak (ör. `identity(x).hp`,
   ya da tamamen dolaylanmış bir `expr_stmt`) tüketiliyorsa, hiçbir şey onu
   serbest bırakmıyordu** — madde 3'ün retain'i bu durumda gerçek bir sızıntı
   hâline geldi. **Düzeltme:** aynı `isTemporaryExpr`/`releaseIfTemporary`
   mekanizması `genFieldRead`'in ve `genIndex`'in TABAN ifadesine ve
   `expr_stmt`'e de uygulandı — sınıf tipli bir alan okunuyorsa (ör.
   `make_car(i).engine`), taban serbest bırakılmadan ÖNCE okunan alan retain
   edilir (aksi halde tabanın serbest bırakılması, kendi `$ClassName_release`
   özyinelemesi yoluyla az önce okunan alanı da serbest bırakabilirdi).

Bu dört düzeltme birlikte, genel bir "geçici (temporary) değer ömrü" disiplini
oluşturur: TAZE bir değerin (bir çağrı/liste-literali sonucu) tam olarak bir
bağımsız sahibi vardır — bir isme/alana bağlanırsa bu sahiplik oraya taşınır
(retain YOK); yalnızca ödünç alınıp (argüman/alıcı/taban) bağlanmadan
tüketilirse, tüketimin sonunda serbest bırakılır. Bu, tam bir ara-yordamsal
(interprocedural) analiz olmadan doğru referans sayımı sağlar.

**Bilinçli kapsam sınırlamaları (v0.1):**
- `list[T]` tipli sınıf alanları desteklenmiyor.
- Öz-referanslı ve ileri-referanslı (karşılıklı) sınıf alanları derleme
  zamanında reddedilir (yukarıya bakın) — bu, kullanışlı bağlı liste/ağaç
  yapılarını `None`/nullable tip desteği gelene kadar engelliyordu.
  **GÜNCELLEME (Faz FF.6, bkz. §3.65):** `T | None` desteğiyle birlikte
  ARTIK MÜMKÜN — `next: Node | None` gibi bir AÇIKÇA bildirilen (Faz FF.5)
  Optional alan, `__init__`de `None` ile başlatılıp SONRADAN gerçek bir
  `Node` ile yeniden atanabilir (bkz. `tests/golden/codegen_cases/
  optional_linked_list.nox`).
- Genel "geçici değer ömrü" düzeltmesi yalnızca ŞU AN keşfedilen dört somut
  yola uygulandı (madde 1-4); grameri genişleten gelecekteki fazlar (ör.
  generics, ek ifade biçimleri) benzer yeni "bağlanmamış geçici" yolları
  açabilir — her yeni codegen yolu eklenirken bu disiplinin (`isTemporaryExpr`/
  `releaseTemporaryArgs`/`releaseIfTemporary`) ilgili olup olmadığı ELLE
  gözden geçirilmelidir.

Golden testler: `tests/golden/codegen_cases/nested_class_fields.nox` (inşa,
zincirleme alan okuma, metodla yeniden atama, passthrough fonksiyon/metod,
1000 yinelemeli döngü, sızıntısız çalıştırma — stderr boş),
`rejected_class_field_forward_ref.nox` (henüz tanımlanmamış bir sınıfa
referans veren alan reddedilir), `rejected_class_field_list_type.nox`
(`list[T]` tipli alan reddedilir).

---

### 3.10 Faz 10 Uygulama Kapsamı — Generics (Compile-Time Monomorphization)

AGENTS.md §12'nin karar verdiği stratejinin İLK dilimi: **yalnızca serbest
fonksiyonlar için** compile-time monomorphization. Yapısal protokoller
(`typing.Protocol` benzeri) ve heterojen koleksiyonlar için örtük fat-pointer
fallback (§12'nin geri kalanı) bu fazın kapsamı DIŞINDADIR — ayrı bir fazda
ele alınacaktır.

**Sözdizimi:** Python 3.12'nin (PEP 695) yerleşik generic sözdizimi benimsendi
— `def name[T, U](...) -> ...:` — Nox zaten Python'a yakın bir sözdizimi
hedeflediği için doğal bir seçim. Sınıflar/metodlar bu fazda generic
OLAMAZ (`def get[T](self, ...)` derleme zamanında reddedilir).

**Mekanizma — ara-yordamsal analiz gerektirmeyen bir "desugaring" geçişi:**
`checker.zig`, bir generic fonksiyonu normal şekilde KAYDETMEZ/DENETLEMEZ
(gövdesi tip parametrelerine — somut olmayan tip adlarına — başvurabilir);
ham AST'sini `generic_functions` haritasında saklar. Bir çağrı sitesinde bu
isimle karşılaşıldığında:
1. Argüman ifadeleri NORMAL şekilde denetlenir (somut tipleri elde etmek
   için) — Nox'ta zorunlu tipleme sayesinde bu HER ZAMAN mümkündür, ayrı bir
   tip çıkarım algoritması (Hindley-Milner vb.) GEREKMEZ.
2. Bu somut tipler, fonksiyonun parametre tip ifadeleriyle eşleştirilip
   (`unifyTypeExpr`) her tip parametresi için bir bağlama çözülür.
3. Bağlama, generic FuncDef'in derin bir kopyasını üretmek için kullanılır
   (`substituteTypeExpr`/`substituteStmts`) — yalnızca TİP İFADELERİ
   (parametre/dönüş/`var_decl` tipleri) değişir, ifadelerin kendisi (hesaplama)
   olduğu gibi paylaşılır.
4. Sonuç, adı mangle edilmiş (ör. `identity__int`, `pair__int_str`),
   TAMAMEN SIRADAN bir `ast.FuncDef`dir — normal `registerFunc`/
   `checkFunctionBody` ile kaydedilip denetlenir. Aynı (fonksiyon, somut tip
   demeti) çifti için en fazla BİR KEZ sentezlenir (mangled isimle önbellek).
5. Çağrı sitesinin `callee` düğümü bu mangled isme YERİNDE (in-place)
   yeniden yazılır.

Bu tasarımın en önemli sonucu: **ownership analizi ve codegen generics'ten
TAMAMEN habersizdir** — yalnızca `module.body`'deki generic ŞABLONLARI
(`type_params.len > 0`) atlarlar ve checker'ın ürettiği somut örneklemeleri
(`Checker.instantiations`) sıradan, generic olmayan fonksiyonlarmış gibi
derlerler. Faz 9'un "geçici değer ömrü" disiplini (`returnNeedsRetain`,
`releaseTemporaryArgs`/`releaseIfTemporary`) hiçbir değişiklik gerekmeden
monomorphize edilmiş fonksiyonlarla doğru çalışır (uçtan uca doğrulandı —
bir generic fonksiyonun bir sınıf örneğini "passthrough" etmesi dahil).

**Bilinçli kapsam sınırlamaları (v0.1):**
- Yalnızca serbest fonksiyonlar; sınıflar/metodlar generic olamaz.
- Tip parametreleri yalnızca ARGÜMAN tiplerinden çıkarılır — yalnızca dönüş
  tipinde kullanılan bir tip parametresi (ör. `def make[T]() -> T:`)
  çıkarılamaz ve hata verir. Nox'ta "turbofish" (`identity::<int>()` tarzı)
  açık tip argümanı sözdizimi yoktur.
- Yapısal protokoller yok — bir generic fonksiyonun parametreleri yalnızca
  düz tip parametreleri (`T`) ya da `list[T]` olabilir; bir protokolü
  (ör. "toplanabilir olan her şey") ifade eden bir kısıtlama sözdizimi yok.
- Heterojen koleksiyonlar için örtük fat-pointer/vtable fallback yok — AGENTS.md
  §12'nin bahsettiği "karışık somut tipli `list[Shape]`" senaryosu henüz
  desteklenmiyor (zaten `list[T]` hâlâ `T`'nin tek, homojen bir somut tipe
  çözümlenmesini gerektiriyor).
- İsim çakışması: mangled isimler (`{ad}__{tip1}_{tip2}`) kullanıcı tanımlı
  bir fonksiyon adıyla TEORİK olarak çakışabilir — bilinçli, kabul edilmiş
  bir v0.1 basitleştirmesi (diğer mangling şemaları gibi, bkz. sınıf/metod
  adlandırması).

Golden testler: `tests/golden/cases/generic_func_def.nox` (sözdizimi/AST);
`tests/golden/typecheck_cases/ok_generic_function.nox` (birden çok somut
tiple örnekleme), `err_generic_conflicting_binding.nox` (aynı tip
parametresi çelişkili tiplere çözümlenirse hata), `err_generic_unresolved_param.nox`
(yalnızca dönüş tipinde kullanılan tip parametresi çıkarılamaz),
`err_generic_method_rejected.nox` (metodlar generic olamaz);
`tests/golden/codegen_cases/generic_functions.nox` (birden çok somut tip,
`list[T]`, sınıf argümanı/passthrough, sızıntısız çalıştırma — stderr boş).

---

### 3.11 Faz 11 Uygulama Kapsamı — Yapısal Protokoller (AGENTS.md §12'nin İkinci Dilimi)

AGENTS.md §12'nin karar verdiği stratejinin İKİNCİ dilimi: yapısal
(structural) protokoller, yalnızca "tek/az sayıda somut tip, statik olarak
biliniyor → monomorphization" yolu için. Heterojen koleksiyonlar için örtük
fat-pointer/vtable fallback (§12'nin geri kalanı, ör. karışık somut tipli
`list[Shape]`) bu fazın kapsamı DIŞINDADIR — ayrı bir fazda ele alınacaktır.

**Sözdizimi:** yeni `protocol` anahtar kelimesi — `typing.Protocol`'e benzer,
`implements` GEREKTİRMEYEN yapısal eşleşme:
```
protocol Shape:
    def area(self: Shape) -> float:
        pass
```
Her metodun gövdesi TEK bir `pass` olmalıdır (yalnızca imza — hiçbir zaman
çalıştırılmaz, hiçbir sınıf onu "miras almaz"). İlk parametre her zaman
`self: <ProtokolAdı>` olmalıdır (sınıfların `self` kuralıyla aynı).

**Mekanizma — Faz 10'un generic altyapısının doğrudan yeniden kullanımı:**
bir fonksiyonun bir parametresi/dönüş tipi bir protokol adına başvurursa
(açık `[T]` sözdizimi hiç KULLANILMASA bile), o protokol adı ÖRTÜK bir tip
parametresi gibi davranır — `registerFunc`, fonksiyonun "etkin" tip
parametre listesini (`computeEffectiveTypeParams`) açıkça bildirilenler
BİRLEŞİMİ doğrudan kullanılan protokol adları olarak hesaplar ve fonksiyonu
Faz 10'un `generic_functions` mekanizmasına yönlendirir. Çağrı sitesinde,
unification (`unifyTypeExpr`) bir protokol adını İLK KEZ bağlarken ek olarak
YAPISAL EŞLEŞMEYİ doğrular (`satisfiesProtocol`): argümanın somut tipi bir
sınıf örneği olmalı VE o sınıf, protokolün gerektirdiği HER metodu (aynı ad,
aynı parametre tipleri, aynı dönüş tipi) taşımalıdır — hiçbir açık ilişki
bildirimi aranmaz. Doğrulama geçerse, geri kalan her şey (somut FuncDef
sentezi, mangling, önbellekleme, çağrı sitesi yeniden yazımı) Faz 10'la
TAMAMEN AYNIDIR; codegen ve ownership analizi protokollerden HİÇ HABERSİZDİR.

**Uçtan uca doğrulama sırasında bulunup düzeltilen iki gerçek entegrasyon
hatası** (ikisi de "asıl kaynağın ne olduğu" konusunda aynı kategoriden):
1. `checkModule`'ün gövde-denetleme döngüsü, bir fonksiyonun ertelenip
   ertelenmediğine `fd.type_params.len == 0` bakarak karar veriyordu — ama bu,
   yalnızca AÇIK `[T]` sözdizimi için doğrudur; bir protokol parametresi
   ORİJİNAL AST düğümünün `type_params`ını hiç ETKİLEMEZ (yalnızca
   `registerFunc`in hesapladığı ETKİN listeyi etkiler). **Düzeltme:** asıl
   kaynak olarak `self.generic_functions` üyeliği kullanıldı.
2. **Aynı hata codegen'de de vardı:** `generateModule`, `module.body`deki
   şablonları atlarken de yalnızca `type_params.len == 0`a bakıyordu. **Düzeltme:**
   checker'ın `generic_functions` anahtarları (`generic_template_names`) artık
   ayrıca `main.zig` üzerinden codegen'e VE ownership analizine iletiliyor.

**Bilinçli kapsam sınırlamaları (v0.1):**
- Heterojen koleksiyonlar için örtük fat-pointer/vtable fallback yok — bir
  protokol parametresi HER ZAMAN çağrı sitesinde TEK bir somut sınıfa
  monomorphize edilir (AGENTS.md §12'nin "az sayıda somut tip" dalı).
- Aynı protokol adı BİR fonksiyon imzasında BİRDEN FAZLA parametrede
  kullanılırsa (ör. `def combine(a: Shape, b: Shape)`), bunlar Faz 10'un tip
  parametresi mekanizmasını paylaştığı için AYNI somut sınıfa çözümlenmek
  ZORUNDADIR (`combine(Circle(1), Square(2))` reddedilir, `TypeMismatch:
  çelişkili tiplere çözümlendi`) — her biri BAĞIMSIZ olarak protokolü
  karşılayan FARKLI sınıflar kabul edilmez. Bunu çözmek, her protokol
  parametresi için benzersiz bir örtük tip değişkeni üretmeyi (sınıf alanı
  ataması gibi başka bir yeniden yazma katmanı) gerektirir — bu faz için
  bilinçli olarak ertelendi.
- Protokoller yalnızca serbest fonksiyonlarda parametre/dönüş tipi olarak
  kullanılabilir; metodlar generic OLAMADIĞI için (Faz 10 sınırlaması)
  protokol tipli metod parametreleri de aynı şekilde reddedilir (doğal
  olarak — `typeExprToType` protokolleri hiç tanımaz).
- Bir protokol metodunun `self` dışındaki parametre/dönüş tipleri yalnızca
  SOMUT tipler olabilir — başka bir protokole (ya da `self` dışında
  kendisine) başvurmak `UnknownType` ile reddedilir (`typeExprToType`
  protokolleri hiç çözümlemediği için kendiliğinden).

Golden testler: `tests/golden/cases/protocol_def.nox` (sözdizimi/AST);
`tests/golden/typecheck_cases/ok_protocol_dispatch.nox` (iki farklı sınıfla
yapısal eşleşme + monomorphization), `err_protocol_missing_method.nox`
(eksik metod), `err_protocol_signature_mismatch.nox` (uyuşmayan dönüş tipi),
`err_protocol_method_bad_body.nox` (yalnızca `pass` kuralı);
`tests/golden/codegen_cases/protocol_dispatch.nox` (iki farklı sınıf,
monomorphize edilmiş dispatch, sızıntısız çalıştırma — stderr boş).

---

### 3.12 Faz 12 Uygulama Kapsamı — HPy/CPython Uyumluluk Katmanı, Tier 0

AGENTS.md §10'un öncelik sırasına uyularak yalnızca **Tier 0** ele alındı:
nesne yaşam döngüsü (create/destroy), refcount emülasyonu, temel tip objesi
protokolü (yalnızca `None`/`Bool`/`Long`/`Float`), modül init/yükleme. Tier
1-3 (buffer/sequence/number protokolleri, GC kancaları, descriptor/metaclass,
vb.) bu fazın kapsamı DIŞINDADIR — AGENTS.md'nin kendi kuralı gereği
(“bir alttaki tier tamamlanmadan bir üsttekine geçilmez”) ayrı fazlarda ele
alınacaktır.

**Kurulum gereksinimi (yeni bir sistem/araç bağımlılığı, QBE ile aynı
ruhta):** HPy header'ları sistemde kurulu DEĞİLDİR; `tests/compat`in
çalışabilmesi için bir kerelik kurulum gerekir:
```
python3 -m venv .hpy-venv
.hpy-venv/bin/pip install hpy
```
`.hpy-venv/` `.gitignore`e eklendi (yerel bir araç kurulumu, commit
edilmiyor). `build.zig`, bu dizin YOKSA `tests/compat`i sessizce ATLAR —
`zig build test`in geri kalanı bundan etkilenmez.

**Nox, YENİ bir HPy "universal ABI" ana bilgisayarıdır** — gerçek bir
CPython yorumlayıcısı OLMADAN, gerçek HPy header'larıyla (`HPY_ABI_UNIVERSAL`
modu) derlenmiş bir C eklentisini doğrudan `dlopen` ile yükleyip
çalıştırabilir (CPython'ın kendi `hpy.universal`ı ya da PyPy'nin
implementasyonuyla AYNI kategoride bir "host"). Bunun gerektirdiği:

1. **`HPyContext` yapısının bayt-uyumlu transkripsiyonu**
   (`runtime/hpy_bridge/context.zig`): bir HPy eklentisi bu struct'a
   DOĞRUDAN (sabit ofsetlerle) erişir — bu yüzden Nox'un Zig struct'ının
   alan SIRASI ve BOYUTU, gerçek HPy header'ının (`autogen_ctx.h`, 266
   alan) ÜRETTİĞİ C struct düzenine bire bir uymalıdır. Elle transkripsiyon
   hataya çok açık olduğu için mekanik bir Python betiği
   (`scripts/gen_hpy_ctx.py`) yazılıp header'dan Zig alan listesi
   OTOMATİK üretildi; yalnızca gerçekten implemente edilen 7 alan
   (`ctx_Dup`, `ctx_Close`, `ctx_Long_FromInt64_t`, `ctx_Long_AsInt64_t`,
   `ctx_Float_FromDouble`, `ctx_Float_AsDouble`, `ctx_Bool_FromBool`)
   kesin fonksiyon işaretçisi tipleriyle elle işaretlendi, geri kalan
   ~260 alan `null` bırakıldı (kullanılmazlarsa zararsız).
2. **Doğrulama — gerçek derleyici çıktısıyla ofset karşılaştırması:**
   yalnızca "derlendi" güveni yetmez; bir C programı yazılıp
   (`offsetof(struct _HPyContext_s, ...)`) gerçek HPy header'ına karşı
   derlendi ve HER alanın ofseti Zig'in `@offsetOf`/`@sizeOf`'uyla
   BİREBİR karşılaştırıldı (struct toplam boyutu dahil, 2128 bayt) —
   `HPyModuleDef`/`HPyDef`/`HPyMeth` için de aynı doğrulama yapıldı. Tümü
   bire bir eşleşti.
3. **Nesne modeli:** `HPy._i`, Nox'un kendi basit refcount'lu `Obj`
   yapısına (bkz. `context.zig`, `Obj`) işaret eden bir işaretçidir —
   `runtime/alloc/arc.zig`'in mekanizmasından BAĞIMSIZ, ayrı bir refcount
   (bu köprü henüz derlenmiş Nox kodundan çağrılmıyor, yalnızca
   `tests/compat`ten `dlopen` ile yüklenen bağımsız bir C eklentisiyle
   doğrulanıyor). `None`/`True`/`False` tekilleri, gerçek CPython'ın
   `Py_None`/`Py_True`/`Py_False`'ı gibi asla serbest bırakılmayan, çok
   yüksek "pinned" bir refcount'la korunur.
4. **Modül yükleyici** (`runtime/hpy_bridge/loader.zig`): bir `.so`yu
   `dlopen` eder, `HPyInit_<ad>` giriş noktasını çağırıp döndürülen
   `HPyModuleDef`i yorumlar, `HPyDef_Kind_Meth` + `HPyFunc_O` (tek
   argümanlı) imzalı metodları çağrılabilir hale getirir. Diğer imzalar
   (`VARARGS`/`KEYWORDS`/...) ve slot/member/getset tanımları henüz
   desteklenmiyor.

**Uçtan uca doğrulama (AGENTS.md §13'ün "gerçek C eklentisi" şartı):**
`tests/compat/hpy_ext/noxtest.c` — gerçek HPy header'larına karşı
(`HPY_ABI_UNIVERSAL`) derlenmiş, `HPyDef_METH` makrosuyla tanımlanmış TEK
fonksiyonlu (`add_one(x) -> x + 1`) bağımsız bir paylaşımlı kütüphane.
`tests/compat/hpy_tier0_test.zig`, bunu Nox'un `HPyContext`iyle `dlopen`
edip GERÇEKTEN çağırır ve sonucu doğrular — sahte/simüle edilmiş bir
çağrı değil, derlenmiş yabancı kodun gerçek bir çalışma zamanı çağrısı.

**Bilinçli kapsam sınırlamaları (v0.1):**
- Yalnızca 4 tip: `None`, `Bool`, `Long` (i64), `Float` (f64) — `Bytes`,
  `Unicode` (str), `Tuple`, `List`, `Dict`, özel tipler (`HPyType_FromSpec`)
  yok.
- Yalnızca `HPyFunc_O` (tek argümanlı) metod imzası çağrılabilir;
  `HPyFunc_VARARGS`/`KEYWORDS`/`NOARGS` ve slot tanımları (`HPyDef_Kind_Slot`
  — `__init__`, operatör aşırı yükleme, vb.) yüklenebilir ama ÇAĞRILAMAZ.
  266 alanlık `HPyContext`in yalnızca 7'si gerçekten implemente edildi —
  bunların dışındaki bir ctx fonksiyonunu çağıran bir eklenti çöker
  (segfault, null fonksiyon işaretçisi çağrısı).
- Bu köprü henüz DERLENMİŞ Nox programlarına (`noxc` çıktısı) BAĞLI
  DEĞİLDİR — yalnızca bağımsız bir Zig test aracı olarak
  (`tests/compat`) çalışır. Nox dilinden bir HPy eklentisini import edip
  çağırabilmek (asıl nihai hedef) ayrı, gelecekteki bir faz.
- Hata/istisna emülasyonu yok (`ctx_Err_*` implemente edilmedi) — bir
  eklenti hata fırlatmaya çalışırsa çöker.
- GC/döngü desteği (`tp_traverse`/`tp_clear`), weakref, alt sınıflama
  (Tier 2) ve descriptor/metaclass/capsule (Tier 3) yok.

Golden/uyumluluk testleri: `runtime/hpy_bridge/context.zig` (3 birim testi
— round-trip, refcount, tekil koruması), `tests/compat/hpy_tier0_test.zig`
(gerçek C eklentisiyle uçtan uca çağrı — AGENTS.md §13'ün zorunlu kıldığı
"yalnızca unit test yeterli değil" şartını karşılar).

---

### 3.13 Faz 13 Uygulama Kapsamı — WASM Entegrasyonu (AGENTS.md §11)

**Runtime seçimi kararı:** AGENTS.md §11 üç seçenek sunuyor:
wasmtime/wasmer C API'si ya da **native bir Zig yorumlayıcısı**. İkincisi
seçildi — QBE ve HPy'den sonra (bkz. §3.12) ÜÇÜNCÜ bir yeni sistem
bağımlılığı eklemeden kendi kendine yeten bir çözüm sağlıyor. Test
fixture'ı bile ek bir araç gerektirmiyor: `zig`in KENDİSİYLE (proje zaten
zorunlu kılıyor) `wasm32-freestanding` hedefine derlenmiş GERÇEK bir
`.wasm` ikilisi (`tests/compat/wasm_ext/addone.zig`, `build.zig`'de
`zig build-exe ... --export=...` adımı) — WABT/wasmtime/wasmer kurulumu
YOK.

**Uygulama (`runtime/wasm_bridge/`):**
1. **İkili format ayrıştırıcı** (`module.zig`): yalnızca gerçekten
   ihtiyaç duyulan bölümleri (Type=1, Function=3, Export=7, Code=10) tam
   ayrıştırır; diğer TÜM bölümleri (Import, Table, Memory, Global, Start,
   Element, Data, ...) kendi bildirdikleri BAYT BOYUTUNA göre atlar — WASM
   ikili formatının her bölümü kendi boyutunu taşıdığı için bu, içeriklerini
   hiç anlamadan güvenle atlamayı mümkün kılar.
2. **Yorumlayıcı** (`interp.zig`): minimal bir yığın makinesi, yalnızca
   DÜZ ÇİZGİ (dallanmasız) kod yürütür — `block`/`loop`/`if` gibi kontrol
   akışı talimatları desteklenmiyor. Desteklenen talimat kümesi:
   `unreachable`, `nop`, `end`/`return`, `call` (fonksiyonlar arası, Zig'in
   kendi çağrı yığınıyla özyinelemeli), `local.get`/`set`/`tee`,
   `i32.const`, `i32.add`/`sub`/`mul`. Yalnızca `i32` parametre/dönüş
   tipleri desteklenir.
3. **Handle birleştirmesi (AGENTS.md §11: "iki ayrı FFI mekanizması yoktur,
   tek bir handle soyutlaması vardır"):** `callExport`, argümanları ve
   dönüş değerini Faz 12'nin AYNI `HPy`/`Obj` temsiliyle (bkz.
   `runtime/hpy_bridge/context.zig`) alıp verir — WASM için AYRI bir değer
   tipi YOKTUR, tam olarak HPy Tier 0'ın kullandığı opaque handle sistemi
   yeniden kullanılır.

**Uçtan uca doğrulama:** `tests/compat/wasm_ext/addone.zig` — `zig`in
kendisiyle GERÇEKTEN derlenmiş, iki export'lu (`add_one`, `add_two`) bir
WASM modülü; `add_two`, `add_one`i İKİ KEZ çağırarak yorumlayıcının
fonksiyonlar arası `call` talimatını da doğru yürüttüğünü sınar.
`tests/compat/wasm_tier0_test.zig`, derlenmiş `.wasm` dosyasını diskten
okuyup Nox'un kendi ayrıştırıcısı/yorumlayıcısıyla GERÇEKTEN çalıştırır
(sahte/simüle edilmiş bir modül değil).

**Bilinçli kapsam sınırlamaları (v0.1):**
- Kontrol akışı yok: `block`/`loop`/`if`/`br`/`br_if` desteklenmiyor —
  yalnızca düz çizgi (branşsız) fonksiyon gövdeleri çalıştırılabilir.
- Yalnızca `i32` — `i64`/`f32`/`f64` parametre/dönüş tipleri (ve ilgili
  aritmetik talimatlar) henüz yok.
- Bellek (`memory.load`/`store`), tablo (`call_indirect`), global
  değişkenler ve içe aktarma (import) desteklenmiyor — yalnızca modülün
  KENDİ tanımladığı, dışa aktarılan (export) fonksiyonlar çağrılabilir.
- Bu köprü henüz DERLENMİŞ Nox programlarına (`noxc` çıktısı) BAĞLI
  DEĞİLDİR — Faz 12'deki HPy köprüsüyle aynı şekilde, yalnızca bağımsız
  bir Zig test aracı olarak (`tests/compat`) çalışır.

Golden/uyumluluk testleri: `runtime/wasm_bridge/module.zig` (1 birim testi
— gerçek derlenmiş bir modülü ayrıştırma), `interp.zig` (2 birim testi —
doğrudan çağrı + HPy handle üzerinden çağrı), `tests/compat/
wasm_tier0_test.zig` (3 test — gerçek `.wasm` ikilisiyle uçtan uca: doğrudan
i32 API, fonksiyonlar arası `call`, HPy handle birleştirmesi).

---

### 3.14 Faz 14 Uygulama Kapsamı — Köprülerin Derlenmiş Nox Programlarına Bağlanması

Faz 12/13, HPy ve WASM köprülerini yalnızca BAĞIMSIZ Zig test araçları
olarak doğrulamıştı ("Bu köprü henüz DERLENMİŞ Nox programlarına BAĞLI
DEĞİLDİR" — her iki fazın da açık bir sınırlaması). Faz 14 bu boşluğu
kapatıyor: gerçek bir Nox kaynağı artık çalışma zamanında gerçek bir HPy
eklentisini ya da WASM modülünü çağırabilir.

**Sözdizimi — yeni bir keyword/import mekanizması DEĞİL, `print` gibi
sabit imzalı iki yerleşik:**
```
hpy_call(yol: str, uzantı_adı: str, fonksiyon_adı: str, argüman: int) -> int
wasm_call(yol: str, fonksiyon_adı: str, argüman: int) -> int
```
`checker.zig`nin `checkCall`ı bunları `print` ile AYNI şekilde özel
işler (sabit argüman sayısı/tipleri, doğrudan `.int`/`.str` denetimi) —
yeni bir gramer kuralı, `import` deyimi ya da modül sistemi GEREKMEDİ.

**Runtime entegrasyonu (`runtime/foreign_bridge.zig`):** `codegen_qbe/
codegen.zig`nin `genCall`ı bu çağrıları doğrudan yeni `export fn
nox_hpy_call`/`nox_wasm_call`e çevirir. Bu ikisi artık `noxrt.o`nun
(derlenmiş her Nox programına statik bağlanan nesne dosyası) BİR PARÇASI
— `runtime/lib.zig`, Faz 12/13'ün `hpy_bridge`/`wasm_bridge` modüllerini
(önceden yalnızca `tests/compat`in kullandığı) artık kendi içine alıyor.
`str` argümanları hiçbir dönüşüm gerektirmez: Nox'un string değerleri
zaten sıfırla-sonlanan statik verilere işaret eden düz işaretçilerdir
(bkz. `codegen_qbe/codegen.zig`, "`str` neden hep tahsissiz").

**Kapsam (v0.1, bilinçli olarak dar):** her çağrı, ilgili modülü BAŞTAN
`dlopen`/ayrıştırıp (önbellek YOK) TEK bir `i64 -> i64` çağrısı yapar ve
kapatır/serbest bırakır — İlke #6'ya (allocator her zaman `rt` üzerinden
açık) uyar, `rt`nin kendi sızıntı-tespit eden `DebugAllocator`'ı kullanılır,
hiçbir gizli/global durum tutulmaz. Bir hata oluşursa (dosya bulunamadı,
sembol/metod/export eksik, ...) `0` döner — Nox'un genel istisna
mekanizmasıyla (`raise`/`try`/`except`) entegre bir hata sinyali HENÜZ
yok.

**Uçtan uca doğrulama:** gerçek bir `.nox` kaynağı, `noxc` ile GERÇEKTEN
native bir ikiliye derlenip ÇALIŞTIRILDI — bu ikili, çalışma zamanında
`tests/compat/hpy_ext/noxtest.so`yu (gerçek bir HPy eklentisi) ve
`tests/compat/wasm_ext/addone.wasm`ı (gerçek bir WASM modülü) yükleyip
çağırdı; her iki durumda da doğru sonuç (`42`) basıldı ve stderr boştu
(sızıntı yok). Ayrıca geçersiz bir yol/isimle çağrıldığında ÇÖKMEDEN
(sessizce `0` dönerek) davrandığı da elle doğrulandı.

**`wasm_call` golden testi neden ana takımda, `hpy_call`ınki neden değil:**
WASM köprüsü hiçbir yeni sistem bağımlılığı gerektirmediği için (yalnızca
`zig`in kendisi, zaten zorunlu), `wasm_call` golden testi
`tests/golden/codegen_golden_test.zig`e (her zaman çalışan ana takıma)
eklendi. HPy köprüsü ise `.hpy-venv` kurulumunu gerektirdiği için, o
kurulu değilken ana takımı KIRMAMASI için `hpy_call` golden testi ayrı,
koşullu bir dosyada (`tests/compat/hpy_call_golden_test.zig`) tutuldu —
Faz 12'nin "`.hpy-venv` yoksa sessizce atlanır" ilkesiyle tutarlı.

**Bilinçli kapsam sınırlamaları (v0.1):**
- Yalnızca `i64 -> i64` (HPy) / `i32 -> i32` (WASM) — `str`/sınıf/`list[T]`
  argüman/dönüş değerleri desteklenmiyor (HPy tarafında `HPyFunc_O`,
  WASM tarafında Faz 13'ün `i32`-yalnızca kısıtı zaten bunu dayatıyor).
- Önbellek yok: her çağrı modülü baştan yükler/ayrıştırır/kapatır —
  aynı modülü döngü içinde tekrar tekrar çağırmak performans açısından
  pahalıdır (bilinçli bir v0.1 basitleştirmesi, doğruluk önce).
- Hata sinyali yok: başarısız bir çağrı sessizce `0` döner, Nox'un
  `raise`/`try`/`except` mekanizmasına ENTEGRE değildir.
- `wasm_call`, WASM tarafının `i32`-yalnızca ve dallanmasız (bkz. §3.13)
  kısıtlarını miras alır; `hpy_call`, HPy tarafının yalnızca 7 `ctx_*`
  alanının implemente edildiği Tier 0 kısıtını miras alır (bkz. §3.12).

Golden testler: `tests/golden/codegen_cases/wasm_call_builtin.nox` (ana
takımda — gerçek bir `.nox` programından gerçek bir WASM modülü çağrısı,
sızıntısız çalıştırma); `tests/compat/hpy_call_golden_test.zig` (koşullu
— gerçek bir `.nox` programından gerçek bir HPy eklentisi çağrısı).

---

### 3.15 Faz 15 Uygulama Kapsamı — HPy Paket Araştırması + Benchmark Suite

Kullanıcının iki isteği: (1) HPy destekli gerçek bir paketi (numpy) çağırıp
denemek, (2) dili çok çeşitli alanlardan sınayan bir benchmark suite kurmak.

**(1) HPy/numpy araştırması — sonuç olumsuz:** `.hpy-venv`e gerçek, güncel
numpy (2.5.1) kuruldu ve tüm derlenmiş uzantıları `nm -gU` ile denetlendi —
HİÇBİR `HPyInit_*` sembolü yok, yalnızca standart CPython ABI'si
(`PyInit_*`). Web araştırması bunu doğruladı: [hpyproject/numpy-hpy](https://github.com/hpyproject/numpy-hpy)
diye deneysel bir GitHub fork'u var (HPy ekibi tarafından sponsorlanan,
"test suite'i geçmeye yakın") ama HİÇBİR ZAMAN PyPI'a yayınlanmadı. Aynı
şekilde `kiwisolver`ın (HPy'ye "tam taşındığı" iddia edilen) PyPI wheel'i de
denendi — o da `PyInit__cext` (standart ABI) kullanıyor. Sonuç: pip ile
kurulabilen, HPy universal ABI ile derlenmiş yaygın bir paket şu an
YOK — HPy ekosistemi hâlâ yalnızca kendi test eklentileri ve deneysel
fork'lar aşamasında. Nox'un Tier 0'ı zaten yalnızca 7/266 ctx fonksiyonu +
`HPyFunc_O` çağrı biçimini desteklediğinden, bu zaten yakın vadede
gerçekçi bir hedef değildi — Faz 12'nin kendi yazdığı `noxtest.so` ile
yaptığı doğrulama, Tier 0'ın çalıştığının kanıtı olarak yeterli kabul
edildi; bu araştırma yeni bir kod değişikliği gerektirmedi.

**(2) Benchmark suite (`benchmarks/`):** dili sekiz farklı alanda sınayan,
her biri kendi doğru sonucunu bilinçli olarak doğrulayan `.nox`
programları + bunları derleyip zamanlayan bir Zig çalıştırıcısı
(`benchmarks/run.zig`, `zig build bench`):

| Dosya | Sınadığı alan |
|---|---|
| `numeric_recursion.nox` | Özyinelemeli çağrı + aritmetik overhead'i (fib(35)) |
| `tight_loop_arithmetic.nox` | Ham, heap'siz döngü hızı (1 milyar yineleme) |
| `list_traversal.nox` | `list[int]` tahsisi/serbest bırakılması + iterasyon |
| `oop_arc_churn.nox` | Sınıf örneği inşa/yıkım churn'ü altında ARC |
| `generics_protocols.nox` | Monomorphize edilmiş generic + yapısal protokol dispatch'i |
| `exceptions_control_flow.nox` | Döngü içinde tekrarlanan `raise`/`try`/`except`/`finally` |
| `lowlevel_arena.nox` | Katman 4 arena tahsisi/toplu yıkım döngüsü |
| `string_passing.nox` | `str` (statik/pinned) değerlerin fonksiyonlar arası geçişi |

`run.zig`: her `.nox`'u `noxc` ile GERÇEK bir native ikiliye derler, BİR KEZ
çalıştırıp çıktısını beklenenle karşılaştırır VE stderr'in boş olduğunu
doğrular (stderr'e yazı = olası sızıntı, bkz. `runtime/alloc/asap.zig`'in
`DebugAllocator` sızıntı raporu) — yalnızca bu doğrulamadan geçen bir
benchmark zamanlanır (5 koşu, min/ortalama ms). `zig-out/bin/noxc`/
`zig-out/lib/noxrt.o`ya göreli yollar kullandığından proje kökünden
çalıştırılmalıdır.

**Kritik bulgu — çalışma zamanı karakteristiği:** `runtime/alloc/asap.zig`
`RuntimeState.gpa`'yı KOŞULSUZ olarak `std.heap.DebugAllocator(.{})`
kullanıyor (hız değil sızıntı GÜVENLİĞİ önceliğiyle — Faz 5'ten beri
bilinçli bir seçim). Bu, heap-ağırlıklı benchmark'ları (özellikle
`oop_arc_churn`, `list_traversal`, `lowlevel_arena`) gerçekçi bir üretim
ayırıcısına göre YAPAY OLARAK YAVAŞLATIR — bu bir codegen/QBE yavaşlığı
DEĞİLDİR, ölçülen sürenin büyük kısmı ayırıcı bookkeeping'idir. `run.zig`
bunu başlangıçta açıkça uyarı olarak basar. Üretim kalitesinde bir allocator
takası (örn. `std.heap.GeneralPurposeAllocator` yerine sistem `malloc`'u ya
da özel bir havuz ayırıcı) gelecekteki bir faz için not edildi, bu fazda
YAPILMADI.

**Benchmark suite'i tasarlarken/kalibre ederken bulunan ve düzeltilen DÖRT
gerçek hata** (AGENTS.md'nin "sahiplik piramidi görünmez ve doğru olmalı"
ilkesini ihlal eden, sessiz bellek bozulması/çökme hataları):

1. **Zincirlenmiş alan okuması bir çağrı sonucu üzerinde sızdırıyordu**
   (`make_car(i).engine.hp` gibi): `codegen_qbe/codegen.zig`'in
   `isTemporaryExpr`i yalnızca `.call`/`.list_lit`i "taze" (kendi
   releaser'ı olmayan) sayıyordu; `.attribute` HER ZAMAN "başka bir yerde
   zaten sahibi var" varsayılıyordu — ama tabanı bir `.call` olan bir
   `.attribute` zinciri (`genFieldRead`'in kendi retain-then-release
   telafisi nedeniyle) de taze bir değer üretir. **Düzeltme:**
   `isTemporaryExpr`, `.attribute` için tabanına özyinelemeli hale
   getirildi. Golden test: `chained_attr_temporary_release.nox`.
2. **`except X as e` bir döngü içinde yeniden kullanıldığında ESKİ istisna
   nesnesi sızıyordu**: `genTry`, `e`nin slotuna yeni yakalanan istisnayı
   doğrudan `storel` ile yazıyordu — normal bir isme atamanın aksine,
   ÖNCEKİ değeri serbest bırakmadan. **Düzeltme:** bağlama noktasında
   `releaseSlotIfSet` eklendi (sıradan bir isme atamayla aynı desen).
   Golden test: `except_bind_reused_in_loop.nox`.
3. **Bir `lowlevel` bloğu bir döngü içindeyken, aynı arena-yerel değişkene
   ikinci kez atama yapmak "Invalid free" ile ÇÖKÜYORDU**: `var_decl` ve
   `genAssign`'in `.identifier` kolu, heap tipli bir yerelin ESKİ slot
   değerini her zaman normal ARC yoluyla (`$ClassName_release`) serbest
   bırakıyordu — ama arena yerelleri zaten `nox_arena_destroy` ile TOPLU
   serbest bırakılır; bir önceki dış yinelemede zaten yıkılmış bir arenaya
   ait belleği ARC ile TEKRAR serbest bırakmaya çalışmak çöküyordu.
   **Düzeltme:** her iki kod yolu da `!info.arena` kontrolü eklendi (arena
   yerelleri ASLA ARC ile serbest bırakılmaz — bkz. `releaseAllLocals`'ın
   zaten sahip olduğu aynı korumaya paralel).
4. **EN CİDDİ: bir `%`/`//` ifadesi ya da bir `for ... in list` bir döngü
   içinde tekrar tekrar değerlendirildiğinde, yığın (stack) her yinelemede
   16 bayt küçülüyor ve ASLA geri alınmıyordu → yüz binlerce yinelemeden
   sonra sessiz bir yığın taşması (segfault)**. Kök neden: QBE'nin
   `alloc4`/`alloc8`'i, FONKSİYON GİRİŞİNDE bir kez yapılacak bir tahsis
   olarak tasarlanmıştır (bkz. QBE belgeleri); ama `genMod`/`genFloorDiv`
   (işaret düzeltmesi için) ve `genForList` (dahili döngü indeksi için) bu
   tahsisi KULLANIM NOKTASINDA (bir `while`/`for` gövdesi içindeyse, her
   çalışma zamanı yinelemesinde tekrar tekrar) yapıyordu — QBE bunu
   fonksiyonun kalan ömrü boyunca geçerli bir tahsis sanıp `sub sp, sp,
   16`i olduğu gibi lowerlıyor, ama hiçbir eşleşen "geri al" yok.
   `ulimit -s`i büyütmenin çökmeyi ORTADAN KALDIRDIĞI doğrulanarak kök
   neden kesinleştirildi (yığın taşması, bellek bozulması değil).
   **Düzeltme (iki ayrı kod yolu):**
   - `adjustModSign`/`genFloorDiv`: dallanma+yığın yuvası yerine SAF
     aritmetiğe geçirildi (`need_adjust`i 0/1'den ortak tipe genişletip
     bölene çarpıp sonuca eklemek/çıkarmak) — hem yığın büyümesi sorunu
     ortadan kalktı hem de dallanmasız olduğu için daha hızlı.
   - `genForList`: dahili indeks yuvası artık `collectLocals`de (bkz.
     `forListIdxName`) FONKSİYON GİRİŞİNDE bir kez tahsis ediliyor —
     `allocSlot`'un normal yereller için zaten yaptığı gibi.
   Golden testler: `mod_in_loop_no_stack_growth.nox` (2 milyon yineleme),
   `nested_forlist_no_stack_growth.nox` (bir döngü içine gömülü `for`, 2.5
   milyon toplam iç yineleme).

Bu dört hata da GERÇEK, kullanıcı tarafından yazılabilecek sıradan Nox
programlarını etkiliyordu (yalnızca büyük ölçekte tetiklendikleri için
önceki fazların küçük-ölçekli golden testlerinde hiç ortaya çıkmamışlardı)
— benchmark suite'in kendisi, dil doğruluğunu büyük ölçekte sınayan bir
regresyon aracı olarak da değerli olduğunu kanıtladı.

**Doğrulama:** `zig build test` her düzeltmeden sonra yeşil tutuldu (final:
89/89 test), her yeni golden test için "kasıtlı boz, kırmızıyı doğrula,
düzelt" ritüeli uygulandı, `zig fmt` çalıştırıldı, ve `zig build bench` ile
tüm 8 benchmark'ın gerçek native ikililere derlenip doğru sonuç + sıfır
stderr ile çalıştığı uçtan uca doğrulandı.

---

### 3.16 Faz 16 Uygulama Kapsamı — Python Karşılaştırmalı Benchmark + Build-Moduna-Göre Allocator

Kullanıcının isteği: benchmark suite'i Python'a karşı TÜM alanlarda hız
karşılaştırması yapacak şekilde genişletmek; gerekirse hız için release
build kullanmak.

**Kritik bulgu — `DebugAllocator` build modundan BAĞIMSIZ olarak yavaş:**
Faz 15'te "release build alınabilir mi" sorusu araştırılırken, önce
`-Doptimize=ReleaseFast`in küçük ölçekli benchmark'larda muazzam bir
hızlanma (`oop_arc_churn`: 590ms→2.9ms) sağladığı görüldü. Bunun
`DebugAllocator`ın `safety` bayrağının (`std.debug.runtime_safety`,
ReleaseFast'te `false`e düşer ve BUNUNLA BİRLİKTE sızıntı tespitini de
sessizce kapatır) kaldırılmasından mı yoksa genel Debug-modu enstrümantasyon
kaldırılmasından mı geldiğini ayırt etmek için `.safety = true` açıkça
sabitlenip yeniden ölçüldü — küçük ölçekte fark yoktu, bu yüzden önce
`.safety = true`nun HER ZAMAN açık tutulmasına karar verildi (sızıntı
tespiti build modundan bağımsız hep aktif olsun diye). AMA `benchmarks/
compare/` için GERÇEKÇE ölçekte (milyonlarca tahsis/serbest bırakma —
Python'la adil bir karşılaştırma için gereken N) yeniden ölçülünce, bu
"düzeltme"nin KENDİSİ 30+ saniyeye varan, TAMAMEN yapay bir yavaşlığa yol
açtığı görüldü (çoğunlukla `system` time — `DebugAllocator`ın kendi mimarisi,
`safety` bayrağından bağımsız olarak, yüksek hacimli döngülerde `mmap`/
`munmap` ağırlıklı). Kanıtlandı: aynı iş yükü `std.heap.smp_allocator`la
(Zig'in üretim kalitesindeki genel amaçlı ayırıcısı) ~20 kat daha hızlı
çalışıyor (5 milyon liste tahsisi/serbest bırakması: ~12s → ~0.1s).

**Karar (`runtime/alloc/asap.zig`):** `RuntimeState.gpa` artık build moduna
göre KOŞULLU bir alan — Debug modunda `std.heap.DebugAllocator` (sızıntı
tespiti aktif; `zig build test`in — ve bu oturumda bulunan 4 gerçek hatanın
— dayandığı güvenlik ağı), Release modlarında (`ReleaseFast`/`ReleaseSafe`/
`ReleaseSmall`) `std.heap.smp_allocator` (üretim kalitesinde hız, sızıntı
tespiti YOK). Bu `comptime`'da (`builtin.mode == .Debug`) seçilir; `nox_alloc`/
`nox_free` yeni bir `RuntimeState.allocator()` yardımcı metodu üzerinden
dolaylanır. Doğruluk/sızıntı güvenliği HÂLÂ yalnızca Debug modundaki
`zig build test`le doğrulanır (89/89 yeşil, değişmedi); hız/karşılaştırma
için `-Doptimize=ReleaseFast` kullanılmalıdır.

**`benchmarks/compare/` — Python karşılaştırma takımı:** mevcut 8
benchmark'ın HER BİRİ için, AYNI algoritmayı birebir izleyen bir `.py`
dosyası + Python'a karşı adil (saniyeler mertebesinde tamamlanan, ama
büyük-N stres testlerinden küçültülmüş) bir N ile eşleştirilmiş yeni bir
`.nox` dosyası eklendi. `benchmarks/run.zig` genişletildi: python3 kuruluysa
(yoksa bu bölüm sessizce atlanır — Faz 12'nin ".hpy-venv yoksa sessizce
atlanır" ilkesiyle aynı desen) her çifti derler/doğrular/zamanlar ve bir
hızlanma oranı (`python_ms / nox_ms`) basar.

**Ölçülen sonuçlar** (`zig build bench -Doptimize=ReleaseFast`, Apple
Silicon, tek bir referans koşusu — mutlak sayılar donanıma göre değişir,
göreli oranlar yorumlanmalıdır):

| Alan | Nox (min ms) | Python (min ms) | Hızlanma |
|---|---|---|---|
| numeric_recursion (fib(34)) | 25.2 | 377.8 | 15.0x |
| tight_loop_arithmetic (20M) | 13.2 | 1724.8 | 131.0x |
| list_traversal (5M) | 78.1 | 1288.8 | 16.5x |
| oop_arc_churn (3M) | 62.4 | 477.4 | 7.7x |
| generics_protocols (15M) | 64.1 | 1574.4 | 24.6x |
| exceptions_control_flow (5M) | 25.2 | 672.7 | 26.7x |
| lowlevel_arena (5M) | 134.1 | 1323.9 | 9.9x |
| string_passing (15M) | 75.6 | 1209.0 | 16.0x |

Yorum: en büyük fark (131x) saf, heap'siz aritmetik döngüde — CPython'un
yorumlayıcı overhead'inin doğrudan bedeli. En küçük fark (7.7x) ARC-ağırlıklı
OOP churn'ünde — Nox'un ARC retain/release + `nox_rc_alloc`'un kendi
overhead'i burada payını alıyor (CPython'un kendi refcounting'i de
optimize edilmiş C kodu olduğundan, göreli fark diğer alanlara göre daha
düşük). Bu, "her yerde eşit hızlanma" beklenemeyeceğinin, alan-bağımlı bir
karşılaştırmanın (kullanıcının istediği gibi) gerçekten anlamlı olduğunun
somut kanıtı.

**Doğrulama:** `zig build test` hem Debug hem `-Doptimize=ReleaseFast` ile
yeşil (89/89, iki modda da), `zig build bench` ve `zig build bench
-Doptimize=ReleaseFast` her ikisi de 8/8 stres + 8/8 karşılaştırma çifti
başarıyla tamamlanıyor, `.gitignore` `benchmarks/compare/` alt dizinini
(git'in "üst joker bir dizini dışladığında negasyon iç dosyalara işlemez"
davranışı nedeniyle ayrı bir un-ignore bloğu gerektirdi) doğru şekilde ele
alacak şekilde güncellendi.

---

### 3.17 Faz 17 Uygulama Kapsamı — HPy Kapsamının Genişletilmesi (Tier 0 Tamamlama + Tier 1'in İlk Dilimi)

Kullanıcının isteği: HPy kapsama alanını "%100"e ulaşana kadar genişletmek.
AGENTS.md §10 açıkça şart koşuyor: "bir ajan bu katmanda çalışırken önce bir
alttaki tier tamamlanmadan bir üsttekine geçmemelidir" — bu yüzden bu faz,
ÖNCE Tier 0'ın eksik kalan parçalarını (hata yönetimi, temel nesne
protokolü, Unicode) tamamladı, SONRA Tier 1'in ("NumPy/Pandas sınıfı
kütüphanelerin çekirdek kullanım alanı") ilk dilimi olan sayı protokolünü
ekledi.

**Dürüst kapsam durumu:** gerçek HPy ABI'si 180 `ctx_*` fonksiyon alanı
içerir; bu fazdan önce 7'si, bu fazdan sonra **26'sı** implemente edildi.
"%100" hedefi — buffer protokolü (PEP 3118), sequence/mapping protokolü
(GetItem/SetItem/List/Dict/Tuple), iterator protokolü, `HPyType_FromSpec`
ile YENİ tip tanımlama, Tier 2 (GC kancaları, weakref, alt sınıflama), Tier
3 (descriptor, metaclass, capsule, async) — çok büyük, çok-oturumlu bir
kapsamdır; bu faz bunu TAMAMLAMADI, yalnızca AGENTS.md'nin zorunlu kıldığı
sırayla, doğrulanabilir ve gerçek bir sonraki dilimini ekledi. Devamı için
doğal sıradaki adım: sequence/mapping protokolü (`ctx_GetItem`/`ctx_SetItem`/
`ctx_List_New`/`ctx_Dict_New`/`ctx_Tuple_FromArray`) — Tier 1'in geri kalanı.

**Eklenenler (`runtime/hpy_bridge/context.zig`):**

- **Nesne modeli genişletildi:** `ObjTag`e `str_` (Unicode) ve `exc_type`
  (yerleşik istisna TİPLERİ için kimlik-yalnızca tekil işaretçi — gerçek
  CPython'ın `PyExc_ValueError` vb. önceden var olan tip nesneleriyle aynı
  ruhta) eklendi. `Obj` artık `str_data: [:0]const u8` taşıyor (yalnızca
  `str_` için; `ctxClose`de serbest bırakılır).
- **Unicode (str) temelleri:** `ctx_Unicode_FromString`, `ctx_Unicode_Check`,
  `ctx_Unicode_AsUTF8AndSize` (gerçek HPy sözleşmesi: sıfırla-sonlandırılmış
  `const char*` döndürür, çağıran serbest bırakmaz).
- **Temel nesne protokolü:** `ctx_Length` (yalnızca `str_` için; başka
  tiplerde `TypeError`), `ctx_IsTrue` (Python'ın doğruluk kuralları — boş
  string/sıfır/`None` yanlış), `ctx_Is` (işaretçi kimliği — Python'ın `is`i).
- **Sayı protokolü (Tier 1'in ilk dilimi):** `ctx_Add`/`ctx_Subtract`/
  `ctx_Multiply`/`ctx_TrueDivide`/`ctx_FloorDivide`/`ctx_Remainder`/
  `ctx_Negative`/`ctx_Absolute` — yalnızca `long`/`float_`/`bool_` için,
  Python'ın tip yükseltme kuralıyla (işlenenlerden biri float ise sonuç
  float) VE Python'ın floor bölme/mod işaret kuralıyla (`-7 // 3 == -3`,
  `-7 % 3 == 2` — Zig'in `@divFloor`/`@mod` builtin'leri BUNU DOĞRUDAN
  sağlıyor, Nox'un kendi QBE codegen'inin elle taklit etmek zorunda kaldığı
  dallanmalı mantığın aksine, bkz. §3.15'teki `adjustModSign` notu).
  Sıfıra bölme `ZeroDivisionError` bekleyen hatasını ayarlar. Tam sayı
  taşması Nox'un kendi `int`iyle tutarlı olacak şekilde sessizce sarılır.
- **Hata yönetimi (Tier 0'ın eksik parçası):** `ctx_Err_SetString`/
  `ctx_Err_Occurred`/`ctx_Err_Clear`/`ctx_Err_ExceptionMatches`/
  `ctx_Err_NoMemory`. Gerçek CPython/HPy'de bekleyen istisna interpreter
  thread-state'inde tutulur; burada gerçek bir yorumlayıcı olmadığından
  (Nox kendi başına bir "universal ABI ana bilgisayarı") bu, `PrivateState.
  pending_error`de (bağlam başına TEK yuva) tutulur. **Bilinçli sınırlama:**
  bu hâlâ Nox'un kendi `raise`/`try`/`except`iyle ENTEGRE değildir (Faz
  14'ün sınırlaması aynen geçerli) — yalnızca bir C eklentisinin standart
  `HPyErr_*` API'lerini DOĞRU kullanabilmesini sağlar.
- **15 yerleşik istisna TİPİ** (`h_Exception`, `h_TypeError`,
  `h_ValueError`, `h_RuntimeError`, `h_IndexError`, `h_KeyError`,
  `h_AttributeError`, `h_OverflowError`, `h_ZeroDivisionError`,
  `h_MemoryError`, `h_StopIteration`, `h_NotImplementedError`,
  `h_ImportError`, `h_OSError`, `h_BaseException`) artık `pinnedExcType`
  tekilleri olarak dolduruluyor (önceden hepsi `HPy_NULL`di).

**Doğrulama (AGENTS.md §10: "sadece unit test yeterli değildir"):**
`tests/compat/hpy_ext/noxtest.c`ye GERÇEK HPy header'larına karşı derlenen
3 yeni `HPyFunc_O` metodu eklendi (`str_length`, `negate`,
`raise_value_error`) ve `tests/compat/hpy_tier0_test.zig`ye bunları
`dlopen` ile yükleyip GERÇEKTEN ÇAĞIRAN 3 yeni uçtan uca test eklendi
(97/97 test yeşil, `.hpy-venv` kuruluyken). Ayrıca `context.zig`ye 5 yeni
colocated Zig unit testi eklendi (Unicode round-trip, sayı protokolü
yükseltme/floor-semantiği, hata yönetimi, sıfıra bölme, IsTrue/Is).

---

### 3.18 Faz 18 Uygulama Kapsamı — HPy Tier 1: Sequence/Mapping Protokolü (list/tuple/dict)

Faz 17'nin devamı — kullanıcı "%100 kapsama hedefine giden yolda devam"
talimatı verdi. Bu faz, AGENTS.md §10'un Tier 1 tanımındaki "sequence/mapping
protokolü" dilimini ekledi: `list`/`tuple`/`dict`.

**Nesne modeli genişletildi (`runtime/hpy_bridge/context.zig`):**
`ObjTag`e `list_` (büyüyebilir, `std.ArrayListUnmanaged(HPy)`), `tuple_`
(sabit boyutlu, SAHİPLENİLEN `[]HPy` dizisi — değişmez, bkz. aşağıda),
`dict_` (anahtar/değer çiftlerinin DOĞRUSAL bir listesi — Nox'ta henüz
genel bir `__hash__` protokolü olmadığından hash tablosu değil, `objEquals`
ile O(n) arama; az sayıda anahtar için doğru, büyük dict'ler için yavaş —
bilinçli bir v0.1 basitleştirmesi) eklendi.

**Referans sahipliği sözleşmesi (gerçek HPy ile birebir):** bir konteynere
EKLEMEK (`List_Append`, `SetItem`, `Tuple_FromArray`) çağıranın tutamacını
ÇALMAZ — konteyner `ctxDup` ile KENDİ bağımsız referansını alır. Simetrik
olarak bir konteynerden OKUMAK (`GetItem`, `GetItem_i`, ...) çağırana YENİ
bir referans döndürür. `ctxClose`, bir konteyner nesnesi gerçekten yok
edilirken TÜM içeriğini özyinelemeli olarak `ctxClose` eder (sızıntı yok).

**Eklenen `ctx_*` fonksiyonları (19 yeni, 26'dan 45'e):**
`ctx_List_Check/New/Append`, `ctx_Tuple_Check/FromArray`,
`ctx_Dict_Check/New/Keys/Copy`, `ctx_GetItem[/_i/_s]`,
`ctx_SetItem[/_i/_s]`, `ctx_DelItem[/_i/_s]`, `ctx_Contains` (list/tuple
için doğrusal arama, dict için anahtar araması, `str_` için alt-dizge
araması). İndeksleme Python'ın negatif indeks kuralını (`xs[-1]`) VE sınır
denetimini (`IndexError`) izler; tuple'a yazma/silme `TypeError` verir
(değişmezlik). `ctx_Length`/`ctx_IsTrue` üç yeni tipi de kapsayacak şekilde
genişletildi (boş liste/tuple/dict yanlıştır — Python'la aynı).

**Doğrulama:** `tests/compat/hpy_ext/noxtest.c`ye 3 yeni gerçek HPy metodu
eklendi — `list_sum` (List + GetItem_i), `make_pair` (Tuple_FromArray),
`dict_get_x` (Dict + GetItem_s) — ve `hpy_tier0_test.zig`ye bunları GERÇEKTEN
çağıran 3 uçtan uca test eklendi. `context.zig`ye 5 yeni colocated Zig unit
testi eklendi (list/tuple/dict/GetItem_s+SetItem_s). Toplam: 104/104 test
yeşil (hem Debug hem `-Doptimize=ReleaseFast`).

**Dürüst kapsam durumu (güncellenmiş):** 180 `ctx_*` fonksiyonundan **45'i**
implemente (Faz 17 sonunda 26'ydı, başlangıçta 7). Doğal sıradaki adımlar:
iterator protokolü (`ctx_New`/generic iteration — HPy'de "iterator" doğrudan
bir ctx grubu değil, `tp_iter`/`tp_iternext` slotları üzerinden gelir, bu da
`HPyType_FromSpec` ile YENİ TİP TANIMLAMAYI gerektirir — bu, buffer
protokolüyle birlikte Tier 1'in geri kalanının EN BÜYÜK, en yapısal
parçasıdır), `ctx_Repr`/`ctx_Str`/`ctx_Hash`/`ctx_RichCompare` (temel
nesne protokolünün geri kalanı), `ctx_Call`/`ctx_CallMethod` (çağrılabilir
nesneler). "%100" hâlâ çok-oturumlu bir hedeftir.

---

### 3.19 Faz 19 Uygulama Kapsamı — HPy Tier 1: `HPyType_FromSpec` (Yeni Tip Tanımlama)

Faz 18'in devamı. Araştırma sonucu önemli bir bulgu: gerçek HPy'nin
(sürüm 0.9.0) universal ABI modu, `autogen_hpyslot.h`de `HPy_tp_iter`/
`HPy_tp_iternext` slotlarını HENÜZ TANIMLAMIYOR — yani "iterator protokolü"
şu an HPy'nin KENDİSİNDE bile taşınabilir şekilde uygulanamıyor (bu Nox'un
bir eksiği değil, HPy'nin üst akım durumu). Buffer protokolü (`bf_getbuffer`/
`bf_releasebuffer`) VE sequence/number slotlarının hepsi `HPyType_FromSpec`
(yeni tip tanımlama) ÜZERİNE kurulu olduğundan, doğal ve zorunlu sıradaki
adım iterator değil, tip tanımlamanın kendisiydi — Tier 1'in kalanının
(ve Tier 2/3'ün tamamının) tek ortak ön koşulu.

**Nesne modeli genişletildi:** `ObjTag`e `type_` (bir `HPyType_FromSpec`
çağrısının sonucu — `basicsize`, `HPy_tp_destroy` slotu, `HPyFunc_O`
imzalı örnek metodları) ve `instance_` (`ctx_New` ile inşa edilmiş bir
örnek — kendi tipine retained bir referans + ham, sıfırlanmış,
SAHİPLENİLEN bir `basicsize` baytlık tampon) eklendi.

**`HPyType_Spec`/`HPyType_SpecParam`/`HPySlot` bayt-uyumlu transkripsiyonu:**
Faz 12'nin AYNI yöntemiyle (`cc`/`offsetof` ile gerçek derleyici çıktısına
karşı doğrulama) — `HPyType_Spec` 56 bayt, `HPyType_SpecParam` 16 bayt,
`HPySlot` 24 bayt, hepsi alan alan doğrulandı (bkz. `context.zig`deki
colocated "bayt düzeni" testi). `HPyDef`in adsız union'ı (`.slot`/`.meth`),
`HPySlotLocal`ı `HPyDefLocal.meth`in adresinden `@ptrCast` ile okuyarak
(her iki struct'ın da `impl` alanı offset 8'de — doğrulandı) yeniden
yorumlanıyor; loader.zig'deki AYNI yapıların bir kopyası (döngüsel import'tan
kaçınmak için kasıtlı bir tekrar, bkz. Faz 12'nin `hpy_call_golden_test.zig`
örneğiyle aynı gerekçe).

**Eklenen 5 `ctx_*` fonksiyonu:**
- `ctx_Type_FromSpec` — spec'i ayrıştırır, `basicsize` + `tp_destroy` slotu +
  `HPyFunc_O` imzalı metodları toplar. Taban sınıf/metaclass (`params`),
  `tp_new`/`tp_init`, member/getset, buffer/sequence/number slotları HENÜZ
  desteklenmiyor.
- `ctx_New` — `HPy_New` makrosunun arkasındaki gerçek fonksiyon: `h_type`in
  `basicsize` baytlık, SIFIRLANMIŞ bir örneğini inşa eder, ham struct
  işaretçisini `*data`ya yazar. **`tp_new`/`tp_init` ÇAĞIRMAZ** — Python'ın
  `Type(...)` çağrısıyla OTOMATİK inşa değil (bu, genel bir Call/interpreter
  boru hattı gerektirirdi, henüz yok); eklentiler bunu KENDİLERİ, doğrudan
  çağırarak kullanır (gerçek HPy'de de yaygın bir kalıptır).
- `ctx_AsStruct_Object` — bir örneğin ham struct işaretçisini döndürür.
- `ctx_Type`/`ctx_TypeCheck` — yalnızca `.instance_` için anlamlı (kendi
  `type_`ini döndürür/karşılaştırır); yerleşik tipler (`long`/`float_`/...)
  için `h_LongType` vb. tekiller henüz doldurulmadığından bu yollar boş.

**Bilinçli, önemli bir sınırlama — tip nesnesi ömrü:** `ctx_Type_FromSpec`
ile oluşturulan bir tip, gerçek HPy'de tipik olarak MODÜL DURUMUNUN ömrü
boyunca yaşar (tek bir `HPyContext` çağrısına bağlı değildir). Nox'un
minimal ana bilgisayarı henüz modül-kapanışında tip temizliğini
desteklemiyor — bu yüzden bir eklenti kendi statik değişkeninde bir tip
önbellekliyorsa (bkz. `tests/compat/hpy_ext/noxtest.c`, `Counter_type`),
bu nesne `destroyContext` tarafından ASLA serbest bırakılmaz (yalnızca
bilinen tekiller — None/True/False/15 istisna tipi — serbest bırakılır).
Bu, `DebugAllocator` ile GERÇEK bir tespit edilebilir sızıntıdır — ilgili
golden/uyumluluk testi bilinçli olarak `std.testing.allocator` yerine
`std.heap.page_allocator` kullanır (bkz. testin kendi belge notu).

**Doğrulama:** `tests/compat/hpy_ext/noxtest.c`ye gerçek `HPyType_Spec`/
`HPyDef_SLOT(HPy_tp_destroy)`/`HPyType_FromSpec`/`HPy_New` kullanan bir
`Counter` tipi + 3 modül metodu (`make_counter`, `get_counter_x`,
`get_destroy_count`) eklendi; `hpy_tier0_test.zig`ye bunları GERÇEKTEN
çağırıp örnek inşasını, alan okuma/yazmayı VE `tp_destroy`in gerçekten
tetiklendiğini (bir sayaç yardımıyla) doğrulayan uçtan uca bir test
eklendi. `context.zig`ye 3 yeni colocated test (bayt düzeni doğrulaması,
inşa/AsStruct/tp_destroy, `findTypeMethodO`). Toplam: 108/108 test yeşil
(Debug + ReleaseFast).

**Dürüst kapsam durumu:** 180 `ctx_*` fonksiyonundan **49'u** implemente
(Faz 18 sonunda 45'ti). Doğal sıradaki adımlar: `ctx_Call`/`tp_call` slotu
(çağrılabilir nesneler — `ctx_New`in "otomatik `tp_new` çağırmama"
sınırlamasını da çözer), `ctx_Repr`/`ctx_Str`/`ctx_Hash`/`ctx_RichCompare`
(temel nesne protokolünün geri kalanı, `tp_repr`/`tp_richcompare` slotlarıyla
birlikte), member/getset tanımları, buffer protokolü (artık `HPyType_FromSpec`
üzerine kurulabilir). "%100" hâlâ çok-oturumlu bir hedeftir.

**Duraklama notu (2026-07-10):** kullanıcının isteğiyle HPy çalışması burada
duraklatıldı — öncelik aşağıdaki §3.20'ye (Zig/C ABI FFI) kaydırıldı. Devam
edilecekse yukarıdaki "sıradaki adımlar" listesinden başlanmalı.

---

### 3.20 Faz 20 Uygulama Kapsamı — Zig/C ABI FFI (`extern def`)

**Durum: UYGULANDI.** Kullanıcının isteği: Nox'un HPy/WASM
köprülerinden (Faz 12-14, çalışma zamanında `dlopen` edilen, KENDİ kutulanmış
nesne modelleriyle çalışan özel-amaçlı köprüler) BAĞIMSIZ, dogrudan herhangi
bir C ABI'siyle uyumlu koda (gerçek C kütüphaneleri VE Zig'in kendisiyle
yazılmış, `callconv(.c)` ile export edilmiş kod) DERLEME/BAĞLAMA zamanında,
kutulanmamış (native) argüman geçişiyle güç alabilmesi.

**Neden HPy/WASM köprülerinden AYRI bir mekanizma:** AGENTS.md §11'in "iki
ayrı FFI mekanizması yoktur, tek bir handle soyutlaması vardır" ilkesi,
HPy/WASM'ın KENDİ ARALARINDA aynı kutulanmış (`HPy`/`Obj`) temsili paylaşması
gerektiği anlamına geliyordu (bkz. §3.13). Zig/C ABI FFI'si KAVRAMSAL OLARAK
FARKLI bir katman: HPy/WASM "yabancı bir çalışma zamanı/dil ekosistemine
(CPython C eklentileri, WASM modülleri) ÇALIŞMA ZAMANINDA bağlan" problemini
çözer; Zig/C ABI FFI'si "HERHANGİ bir C-ABI-uyumlu native koda DERLEME
ZAMANINDA, SIFIR kutulama maliyetiyle bağlan" problemini çözer — Nox'un
KENDİ runtime'ının `nox_alloc`/`nox_rc_release` gibi fonksiyonları zaten
TAM OLARAK bu mekanizmayla (QBE `call $sembol(...)`, doğrudan native ABI)
çağrılıyor; `extern def` bunu KULLANICIYA açan doğal bir genişleme.

**Sözdizimi (uygulandığı gibi):**
```
extern def sqrt(x: float) -> float from "m"
extern def add_two(a: int, b: int) -> int from "./build/mathutil.o"
```
`from "<ad>"` bir SİSTEM kütüphanesi adıysa (`/` içermiyor VE `.o`/`.a` ile
bitmiyorsa) son `cc` bağlama adımına `-l<ad>` olarak geçirilir; bir dosya
yolu (`.o`/`.a` uzantılı ya da `/` içeren) ise DOĞRUDAN bağlama komutuna
eklenir (bkz. `compiler/main.zig`, `appendExternLinkArgs`) — bu, Zig ile
yazılmış kodu (`zig build-obj foo.zig` ile üretilmiş bir `.o`) bağlamanın
da AYNI mekanizma olduğu, ayrı bir "Zig FFI'si" gerekmediği anlamına gelir.
Aynı `from_lib` birden çok `extern def`de kullanılmışsa yalnızca BİR KEZ
bağlama argümanı eklenir (dedup).

**Yeni sözdizimi (`compiler/lexer/token.zig`, `parser/ast.zig`,
`parser/parser.zig`, `parser/ast_dump.zig`):** `kw_extern`/`kw_from`
anahtar kelimeleri, `ast.ExternDef` düğümü (`name`, `params`, `return_type`,
`from_lib` — GÖVDE YOK), `parseExternDef` (tek satırlık bir bildirim —
`parseBlock` çağrılmaz).

**Tip eşlemesi (v0.1 kapsamı, uygulandı):** `int` (i64) ↔ C `long`/
`int64_t`/işaretçi boyutlu; `float` (f64) ↔ C `double`; `bool` (w) ↔ C
`int`/`_Bool`; `str` ↔ C `const char*` — **SIFIR dönüşüm** (doğrulandı:
Nox'un `str`i zaten sıfırla-sonlanan statik/ham bir işaretçi, `hpy_call`/
`wasm_call` ile AYNI ücretsiz tasarım); `None` ↔ `void`. `checker.zig`nin
`registerExternFunc`i (`isFfiSafeType`) `list[T]`/sınıf parametre/dönüş
tiplerini AÇIKÇA reddeder (net bir hata mesajıyla). **v0.1 DIŞI (değişmedi):**
C `int` (32-bit) için ayrı bir dar tip, `float32`, yapılar (struct) DEĞERCE
geçiş, geri çağırma (callback), varargs, opak `ptr` tipi (ikinci artım).

**Codegen (`codegen_qbe/codegen.zig`):** `extern_functions` — normal
`functions` tablosundan AYRI bir tablo (`registerExternFunc`/
`genCall`'ın YENİ dalı). Çağrı noktası, normal kullanıcı fonksiyonlarından
İKİ ÖNEMLİ farkla üretilir: (1) `RT_PARAM` (Nox'un `rt` bağlamı) HİÇ
geçirilmez — extern fonksiyonlar bunu bilmez/almaz; (2) `emitExceptionCheck`
ÇAĞRILMAZ — extern fonksiyonlar Nox'un istisna mekanizmasına katılmaz.
`extern def`in KENDİSİ için hiçbir fonksiyon GÖVDESİ üretilmez (yalnızca
çağrı sitelerinde `call $<sembol>(...)`); sembol çözümü tamamen `cc`nin
bağlama adımına bırakılır.

**Bulunan ve düzeltilen gerçek hata:** ilk uçtan uca denemede, `str` dönüş
tipli bir extern fonksiyonun sonucu TAM SAYI olarak yazdırılıyordu (`4370224418`
gibi bir işaretçi değeri, "merhaba" yerine). Kök neden: extern çağrı
dalının döndürdüğü `Value`de `.heap = esig.ret.heap` alanı UNUTULMUŞTU —
`genPrint`in `str` biçimlendirmesi TAM OLARAK bu alana bakıyor (bkz. §3.15/
§3.19'daki benzer "alan unutuldu" hataları — bu ÜÇÜNCÜ örneği). Tek
satırlık bir düzeltmeyle (`.heap = esig.ret.heap` eklendi) çözüldü ve
gerçek bir C fonksiyonundan (`const char *c_greeting(void)`) dönen bir
`str`in doğru yazdırıldığı elle doğrulandı.

**Doğrulama (AGENTS.md'nin rigor'uyla tutarlı):** GERÇEK bir C dosyası
(`tests/compat/c_ext/mathutil.c`, sistem `cc -c` ile derlenmiş) VE GERÇEK
bir Zig dosyası (`tests/compat/zig_ext/util.zig`, `zig build-obj` ile
derlenmiş, `export fn triple(x: i64) callconv(.c) i64`) AYRI AYRI
bağlanıp, GERÇEK bir sistem kütüphanesinin (`libm`, `from "m"`) `sqrt`iyle
BİRLİKTE, gerçekten derlenmiş bir Nox programından çağrılarak uçtan uca
doğrulandı (`tests/compat/extern_ffi_test.zig`) — `sqrt(16.0)=4`,
`add_two(3,4)=7`, `triple(7)=21`, sıfır stderr (sızıntı yok). Hiçbir YENİ
sistem bağımlılığı gerekmediğinden (`cc`/`zig` zaten zorunlu) bu test ana
(koşulsuz) takımda yer alır — HPy'nin `.hpy-venv` koşulundan FARKLI olarak.
Ayrıca parser (`extern_def.nox`/`.ast.expected`) ve typecheck
(`ok_extern_def`, `err_extern_unsafe_param`) golden testleri eklendi.
Toplam: 112/112 test yeşil (Debug + ReleaseFast).

**Aşamalandırma (güncellendi):**
1. ✅ `extern def` (int/float/bool/str/None, statik bağlama — sistem
   kütüphanesi ADI ya da doğrudan `.o`/`.a` dosya yolu), gerçek C + gerçek
   Zig nesne dosyasıyla uçtan uca doğrulandı.
2. ✅ Opak `ptr` tipi (handle-tabanlı C API'leri açar) — UYGULANDI (bkz.
   aşağıdaki "İkinci artım" bölümü).
3. (Belki) dinamik (`dlopen`-tabanlı) bir varyant — statik bağlama zaten
   yaygın durumu kapsadığından, talep gelmedikçe ertelenebilir.

Yapılar (struct-by-value), callback'ler ve varargs bilinçli olarak KAPSAM
DIŞI bırakıldı — talep geldikçe ayrı bir faz olarak ele alınabilir.

**İkinci artım — opak `ptr` tipi (UYGULANDI, 2026-07-11):** `types.zig`e
`Type.ptr` eklendi (payload'sız — Nox bunun İÇİNDEKİ veriyi HİÇ bilmez/
yorumlamaz). Checker: `typeExprToType`'ın `.simple` dalı `"ptr"`ı tanır;
`isFfiSafeType`e dahil edildi (TAM OLARAK bu sınırdan geçmek için var);
Faz 21'in `isSpawnParamSafeType`ine de dahil edildi (ARC-dışı, bir
işaretçi kopyası kadar triviyal). Codegen: `resolveType`'ın `.simple`
dalı `"ptr"`ı `{qtype: .l, heap: .none}`e çözer — `list`/`class` gibi
ÖZEL bir dispatch GEREKMEZ, düz bir `l` değeridir (`int`le AYNI temsil).
`==`/`!=` karşılaştırması `types.eql`in `.ptr => true` (her iki taraf da
zaten `.ptr` etiketliyse eşit sayılır) dalı sayesinde EK KOD OLMADAN
çalışır.

**Doğrulama — gerçek bir handle-tabanlı C API deseni:**
`tests/compat/c_ext/counter.c` (yeni) `FILE*`/`sqlite3*`in AYNI desenini
örnekler: `counter_create`/`counter_get`/`counter_increment`/
`counter_destroy` — bir opak `void*` döner/alır, İÇERİĞİNİ (`Counter`
struct'ı) Nox'a HİÇ AÇMAZ. Gerçek bir Nox programından (`extern def
... -> ptr`/`(handle: ptr)`) çağrılıp `10 → +1 → +1 → 12` doğru
sonucunu verdi. Ayrıca bir tip denetimi golden testi (`ok_extern_ptr`).
Yaşam süresi TAMAMEN kullanıcının sorumluluğunda — Nox `ptr`i ASLA
otomatik serbest bırakmaz (`counter_destroy`nin AÇIKÇA çağrılması
gerekir, tıpkı gerçek C API'lerinde olduğu gibi). Hiçbir yeni sistem
bağımlılığı gerekmediğinden (yalnızca `cc`) ana test takımında yer
alır. **149/149 test yeşil, hem Debug hem `-Doptimize=ReleaseFast`.**

---

### 3.21 Faz 21 — `async` (İlk Stdlib): Go-Tarzı Yeşil İş Parçacıkları

**Durum: AŞAMA 1 (runtime çekirdeği) UYGULANDI, aşama 2-4 PLANLANDI/HENÜZ
UYGULANMADI.** Kullanıcının isteği: Nox'un ilk
standart kütüphanesi — gerçek asenkron çalışma, Python'a yakın ("pythonize")
ve mümkün olduğunca basit bir sözdizimi, Go tarzı yeşil iş parçacıkları
(green thread), ve **deadlock'a izin verilmemesi**. Şimdilik Zig ile
yazılacak (Nox olgunlaştıkça Nox'un kendisiyle yeniden yazma fikri ayrıca
konuşulacak — bu fazın kapsamı DIŞINDA).

**Kritik ön-gözlem — bu "salt bir kütüphane" değildir:** gerçek `async def`/
`await`/`spawn` bir DİL ÖZELLİĞİDİR (yeni anahtar kelimeler, yeni AST
düğümleri, checker'ın "await yalnızca async içinde" kuralı, codegen'in
"bir görev askıya alınabilir" için özel lowering'i) — HPy/WASM/`extern def`
gibi salt runtime çağrılarıyla (fixed-signature builtin) taklit edilemez.
Bu yüzden AGENTS.md §7'nin zorunlu sırasıyla (gramer → tip denetimi →
sahiplik analizi → QBE lowering → golden test → spec) TAM bir dil özelliği
olarak ele alınacak; "stdlib" ifadesi burada "çekirdek dile YENİ eklenen,
ama kullanıcı kodunun geri kalanından AYRI, kendi çalışma zamanı modülünde
(`runtime/async_rt/`) yaşayan bir katman" anlamına geliyor.

**Açık bırakılan/varsayılan olarak karara bağlanan bir soru — modül sistemi
yok:** Nox'ta henüz `import` yok (tek dosyalık derleme modeli). Bu fazda
`async def`/`await`/`spawn`/`Task[T]`/`Channel[T]`, `list[T]`/`print` gibi
**YERLEŞİK (built-in) dil ilkelleri** olarak ele alınacak — hiçbir `import
async` GEREKMEZ. Gerçek bir modül sistemi (çok-dosyalı derleme, isim
alanları) ayrı, daha büyük bir mimari karardır; bu, kullanıcı onaylamadan
ÖNCE burada bilinçli olarak ERTELENDİ ve VARSAYILAN olarak "yok" kabul
edildi — kullanıcı isterse bu karar değiştirilebilir.

**Sözdizimi (taslak, Python'a en yakın hâliyle):**
```
async def fetch(url: str) -> str:
    ...
    return "sonuç"

async def main() -> None:
    t: Task[str] = spawn fetch("https://...")
    other: int = compute_sync()
    result: str = await t
    print(result)
```
- `async def` — Python'la birebir aynı görünüm; gövdesi içinde `await`
  kullanılabilir (dışında KULLANILAMAZ, checker zorunlu kılar).
- `spawn <çağrı-ifadesi>` — YENİ bir ifade formu: çağrıyı HEMEN bir yeşil
  iş parçacığında BAŞLATIR (Go'nun `go f()`si gibi), bloklamaz, bir
  `Task[T]` tutamacı döndürür (`T` = çağrının dönüş tipi).
- `await <ifade>` — bir `Task[T]`i (spawn'dan) ya da bir `Channel[T]`
  işlemini (`ch.send(v)`/`ch.recv()`) BEKLER; sonucu hazır değilse mevcut
  görevi ASKIYA ALIR (OS iş parçacığını bloklamaz) ve zamanlayıcıya geri
  döner — Go'nun kanal işlemleri gibi ama AÇIKÇA işaretlenmiş (Python'un
  `await`i gibi, "gizli" askıya alma YOK — AGENTS.md'nin genel "örtük
  olmayan kontrol akışı" ruhuyla tutarlı).
- `Channel[T]` — YENİ, yerleşik bir generic tip: `ch: Channel[int] =
  Channel[int](0)` (`0` = tamponsuz/rendezvous, `N>0` = `N` kapasiteli
  tamponlu). Metodları `await`lenmesi gereken `send`/`recv`.
- Kalıcı bir `Task`i asla `await`lememek (Go'da "kaçak goroutine" sınıfı)
  BİLİNÇLİ bir hata sınıfı olarak KALIR (yapısal eşzamanlılık — her
  `spawn` bir kapsam içinde `await`lenmelidir — İKİNCİ bir artımda ele
  alınabilir; v0.1 bunu ZORUNLU KILMAZ).

**Eşzamanlılık modeli — Go tarzı YIĞINLI (stackful) yeşil iş parçacıkları:**
Zig'in kendisi (0.11+) artık dilde `async`/`await` İÇERMEDİĞİNDEN, bu
runtime tarafından ELLE inşa edilecek: her `Task` kendi (sabit boyutlu,
örn. 64KB) yığınını alır; bağlam değişimi (context switch) mimariye özel
(bu makinede aarch64) elle yazılmış, callee-saved yazmaçları + yığın
işaretçisini kaydeden/geri yükleyen KÜÇÜK bir montaj rutinidir (bkz.
`libaco`/`boost::context`in yaptığı, ama Nox'a özel, minimal bir sürümü).
v0.1: TEK bir taşıyıcı OS iş parçacığı üzerinde M:1 zamanlama (çoklu OS
iş parçacığına, work-stealing'e — Go'nun GMP modeline — İKİNCİ bir artımda
geçilebilir; v0.1'in amacı doğruluk, sonra hız).

**"Deadlock'a izin vermeyelim" — dürüst yorum: ÖNLEME değil, TESPİT +
NET HATA.** Genel halde deadlock'u YAPISAL OLARAK imkânsız kılmak (ör.
kilitleri tamamen kaldırıp yalnızca lineer/session-tipli kanallara
izin vermek) çok daha büyük, araştırma-düzeyinde bir tip sistemi
gerektirir — v0.1 kapsamı DIŞI. Bunun yerine GERÇEKÇİ ve GÜÇLÜ bir
garanti: zamanlayıcı TÜM görevleri kendisi yönettiği için (M:1, tek OS
iş parçacığı), "her görev bloke" durumu HER ZAMAN GÖZLEMLENEBİLİR bir
global durumdur (işletim sistemi düzeyinde gizli bir kilitlenme
OLAMAZ — yalnızca Nox'un kendi zamanlayıcısının hazır kuyruğu boşalır).
Zamanlayıcı, hazır kuyruğu boşken hâlâ tamamlanmamış görevler varsa
bunu KESİN OLARAK tespit eder ve süreci sonsuza dek asılı bırakmak yerine
AÇIK bir `Deadlock` istisnası fırlatır (hangi görevlerin/kanalların
birbirini beklediğini basan bir tanılamayla). Bu, "asla oluşmaz" değil
"asla SESSİZCE asılı kalmaz, her zaman NET bir hatayla sonlanır" sözüdür
— dürüst ve uygulanabilir bir garanti.

**Aşamalandırma (uygulamaya geçildiğinde izlenecek sıra):**
1. **Runtime çekirdeği (`runtime/async_rt/`, salt Zig, Nox'tan BAĞIMSIZ
   doğrulama):** yığınlı fiber ilkeli (montaj bağlam değişimi) — standalone
   Zig testleriyle (2-3 fiber arası el ile geçiş) doğrulanır.
2. **Zamanlayıcı + Task:** hazır kuyruğu, `spawn`/`await` (join semantiği).
3. **Channel + deadlock tespiti:** gönderen/alıcı bekleme kuyrukları;
   KASITLI bir deadlock senaryosu (iki görev birbirini bekliyor) yazılıp
   `Deadlock` hatasının GERÇEKTEN fırlatıldığı (sonsuza dek asılı
   KALMADIĞI) doğrulanır.
4. **Derleyici entegrasyonu:** gramer (`async`/`await`/`spawn` anahtar
   kelimeleri, `Task[T]`/`Channel[T]` yerleşik generic tipler) → tip
   denetimi (`await` yalnızca `async def` içinde) → sahiplik analizi
   (bir `Task`/`Channel`in ARC'ı, spawn edilen görevin YAŞAM SÜRESİ
   biterken TEMİZ bir şekilde nasıl davranacağı) → codegen (spawn/await
   çağrıları runtime'a) → GERÇEK bir Nox programıyla (iki görev + bir
   kanal + kasıtlı bir deadlock senaryosu DAHİL) uçtan uca golden test.

**Bilinçli v0.1 sınırlamaları (baştan belirtilmiş):** yapısal eşzamanlılık
zorunluluğu yok (kaçak `Task`ler mümkün, çökme/sızıntı değil ama "iyi
pratik" ihlali), M:N zamanlama yok (yalnızca M:1), zaman aşımı (`timeout`)
ilkelleri yok, iptal (`cancellation`) yok, `select`/çoklu-kanal bekleme
yok — hepsi ayrı, sonraki artımlar.

**Aşama 1 uygulama raporu — runtime çekirdeği (`runtime/async_rt/`):**

- `runtime/async_rt/swap_aarch64.s`: elle yazılmış AAPCS64 bağlam değişimi
  (`_nox_swap_context(old: *Context, new: *Context)`). YALNIZCA
  çağrı-korumalı (callee-saved) yazmaçları kaydeder/yükler: `x19`-`x28`,
  `x29`/fp, `x30`/lr, `sp`, `d8`-`d15`. Çağıran-korumalı yazmaçlara
  DOKUNULMAZ (AAPCS64 bunu zaten çağıranın sorumluluğuna bırakır).
  **Neden ayrı bir `.s` dosyası (Zig içinde `callconv(.naked)` DEĞİL):**
  Zig 0.16'da `callconv(.naked)` bir fonksiyon normal Zig çağrı
  sözdizimiyle ÇAĞRILAMIYOR ("unable to call function with calling
  convention 'naked'" — sabit derleme hatası). Gerçek fiber
  kütüphanelerinin (`boost::context`, `libaco`) izlediği standart yol
  izlendi: rutin bağımsız bir montaj dosyasında yazılıp `cc -c` ile
  derlenir, Zig tarafından `extern fn` olarak bildirilir.
- `runtime/async_rt/fiber.zig`: `Context` (extern struct, `.s` dosyasıyla
  BİRE BİR alan sırası), `Fiber` (`create`/`destroy`/`resume_`/`yield`),
  ve `trampoline` (bir fiber'ın İLK KEZ resume edildiği giriş noktası).
  `STACK_SIZE = 256 * 1024`, 16 bayt hizalı.
  **"x19 kaçırma" numarası:** bir fiber'ın ilk resume'u, geri yüklenen
  `lr` üzerinden `trampoline`a "atlar" — ama bu normal bir Zig çağrısı
  DEĞİLDİR (parametre geçirmenin standart yolu, x0, kullanılamaz).
  `Fiber.create`, `self` işaretçisini DOĞRUDAN başlangıç `Context.x19`
  alanına yerleştirir; `x19` çağrı-korumalı olduğundan bu İLK bağlam
  değişiminde SADAKATLE geri yüklenir, `trampoline` da onu küçük bir
  `asm volatile` bloğuyla okuyup hangi `Fiber`e ait olduğunu öğrenir.
  v0.1 YALNIZCA aarch64 destekler (`comptime` denetimiyle zorunlu
  kılınır) — x86-64 desteği bilinçli olarak sonraki bir artıma
  ERTELENMİŞTİR.
- `build.zig`: `swap_aarch64.s`, `compile_c_ext`/`compile_zig_ext`
  (§3.20) ile AYNI desenle (`cc -c` → `addSystemCommand`) derlenir;
  sonuç nesnesi `fiber_test`in modülüne `Module.addObjectFile` ile
  bağlanır (Zig 0.16'da `addObjectFile` artık `Compile` üzerinde değil,
  `Module` üzerinde bir metottur — önceki fazlardaki API'den FARKLI).
  `test_step`e koşulsuz eklendi (yeni sistem bağımlılığı gerekmez, `cc`
  zaten zorunlu).
- **Bulunan gerçek hata (runtime testine özgü, çekirdek mekanizmanın
  KENDİSİNDE değil):** `std.testing.allocator` (`DebugAllocator`), her
  `alloc`de sızıntı-izleme için ÇERÇEVE İŞARETÇİSİ ZİNCİRİNİ yürüyerek
  yığın izi çıkarır. Bir fiber'ın yığınındaki İLK (önyükleme) çerçevesi
  gerçek bir çağrı zincirini TEMSİL ETMEDİĞİNDEN (`fp=0`, `lr=&trampoline`
  — `Fiber.create` tarafından SENTETİK olarak yerleştirilmiş), bu
  izleyici önyükleme çerçevesinin ÖTESİNE geçmeye çalışıp geçersiz
  belleğe erişir (`Segmentation fault at address 0x8`). Bu, yabancı
  (foreign) yığınları tanımayan geri-izleyicilerin genel bir sınıfı
  (Go'nun goroutine yığınları için ÖZEL bir açılım gerektirmesiyle
  aynı kök neden) — bağlam değişiminin kendisi DOĞRU çalışıyordu (x19
  ile taşınan `self` işaretçisi doğrulandı, `entry` doğru çağrıldı).
  Düzeltme: testlerin fiber GÖVDESİ içindeki günlüğe izlemesiz bir
  ayırıcı (`std.heap.page_allocator`) kullanması — çekirdek mekanizmada
  DEĞİŞİKLİK GEREKMEDİ.
- Doğrulama: iki standalone Zig testi (`zig build test`e bağlı) — biri
  TEK bir fiber'ın iki kez `yield` edip bitmesini ("ABC" günlük sırası),
  diğeri İKİ bağımsız fiber'ın ara katmanlı (interleaved) resume
  edilmesini ("1728" günlük sırası) doğruluyor. Hem Debug hem
  `-Doptimize=ReleaseFast`de yeşil.

**Aşama 2 uygulama raporu — zamanlayıcı + `Task[T]` (`runtime/async_rt/
scheduler.zig`):**

- `Scheduler`: `ready: ArrayListUnmanaged(*Fiber)` (FIFO hazır kuyruğu),
  `root_ctx: Context` (zamanlayıcı döngüsünün KENDİSİNİN bağlamı — bir
  fiber'a `resume_` edildiğinde geri dönülecek yer), `current: ?*Fiber`,
  `live_count: usize` (henüz BİTMEMİŞ görev sayısı).
  `markReady(fiber)` hazır kuyruğuna ekler; `suspendCurrent()` ŞU AN
  çalışan fiber tarafından çağrılır ve kontrolü `root_ctx`e geri verir
  — `markReady` TEKRAR çağrılana kadar kuyruğa EKLENMEZ (yani bir "bloke
  ol" ilkelidir, kooperatif "sırayı bırak" değil).
- `Task(comptime T: type)`: `spawn(scheduler, T, func, arg)` yeni bir
  fiber oluşturup HEMEN hazır kuyruğuna ekler (bloklamaz), bir `*Task(T)`
  tutamacı döner. `task.await_()`: görev tamamlanmışsa sonucu HEMEN
  döner; değilse çağıran fiber'ı `task.waiter` olarak kaydedip
  `suspendCurrent()` çağırır — görev bitince (`entryTrampoline` içinde)
  varsa `waiter` tekrar `markReady` ile kuyruğa eklenir.
- **Deadlock tespiti — Task/Channel'dan BAĞIMSIZ, zamanlayıcının
  `run()` döngüsünün kendisinde yaşar:** hazır kuyruk boşken
  `live_count > 0` ise (yani TÜM canlı görevler bloke) `error.Deadlock`
  döner; hazır kuyruk boşken `live_count == 0` ise normal biter. Süreç
  ASLA sonsuza dek asılı KALMAZ.
- **Bulunan gerçek hata (Faz 1'deki İLE AYNI hata sınıfı, farklı tetikleyici):**
  "iç içe await" testinde, bir fiber GÖVDESİ içinden (yani `parent`
  fonksiyonu çalışırken) `spawn()` çağrılması — bu da `std.testing.
  allocator`ı (DebugAllocator) fiber yığınından TETİKLER, aynı
  yabancı-yığın geri-izleme segfault'una (`address 0x8`) yol açar.
  Düzeltme: bu dosyanın TÜM testlerinde zamanlayıcının kendi ayırıcısı
  `std.heap.page_allocator` olarak ayarlandı (§3.21 aşama 1'deki
  `page_allocator` düzeltmesiyle AYNI kök neden, şimdi "zamanlayıcı
  içinden herhangi bir iç içe tahsis" genel durumuna genişletildi) —
  gerçek async çalışma zamanı (Faz 4 derleyici entegrasyonundan sonra)
  ZATEN kendi ASAP/ARC ayırıcısını kullanacağından, bu yalnızca test
  altyapısına özgü bir düzeltme, çekirdek mekanizmada değişiklik değil.
- Doğrulama, üç standalone Zig testiyle (`zig build test`e bağlı):
  (1) tek görev, `await` olmadan doğrudan `task.result` okunarak; (2) bir
  görevin BAŞKA bir görevi `await` etmesi (iç içe askıya alma — çocuk
  görev henüz çalışmadan ebeveyn askıya alınıyor, çocuk bitince ebeveyn
  doğru şekilde uyandırılıp devam ediyor); (3) DAİRESEL `await` (görev A
  görev B'yi, görev B görev A'yı bekliyor) — zamanlayıcının GERÇEKTEN
  `error.Deadlock` fırlattığı, sonsuza dek asılı KALMADIĞI doğrulandı.
  Bu üçüncü test, deadlock tespitinin Channel'a İHTİYAÇ DUYMADAN, salt
  Task/await ile bile sergilenebildiğini gösteriyor (aşama 3'te Channel
  AYNI `suspendCurrent`/`markReady` ilkelini yeniden kullanacak). Hem
  Debug hem `-Doptimize=ReleaseFast`de yeşil.

**Aşama 3 uygulama raporu — `Channel[T]` (`runtime/async_rt/channel.zig`):**

- `Channel(comptime T: type)`: `buffer: ArrayListUnmanaged(T)` (tamponlu
  durum için), `send_waiters`/`recv_waiters` (bloklanmış fiber'ların
  YEREL değişken olarak tuttuğu `SendSlot`/`RecvSlot` yapılarına
  işaretçi listeleri). **Yuvaların ısıya (heap) ayrılması GEREKMEZ:**
  bir fiber `suspendCurrent()` çağırdığında yığını (stack) CANLI kalır
  (yığınlı fiber'ların temel özelliği), bu yüzden `var slot = ...;
  ...append(&slot); suspendCurrent();` deseni güvenlidir — `slot`
  fiber uyandırılıp fonksiyon gerçekten dönene kadar bellekte kalır.
- `capacity == 0` (tamponsuz/rendezvous): `send`, bekleyen bir `recv`
  yoksa gönderici olarak bloklanır; `recv`, bekleyen bir gönderici
  varsa değerini DOĞRUDAN alır (tampon hiç kullanılmaz — el ele teslim).
- `capacity > 0` (tamponlu): `send`, tampon dolu değilse HEMEN döner
  (bloklamaz); doluysa gönderici olarak bloklanır. `recv`, tampondan
  bir öğe boşalttığında `wakeOneSender()` çağırıp (varsa) tampon
  dolduğu için bloklanmış bir göndericinin değerini tampona taşıyıp
  onu uyandırır.
- Fast path: her iki yönde de (bekleyen alıcı varken `send`, bekleyen
  gönderici varken `recv`) tampon ATLANARAK doğrudan teslim yapılır —
  yalnızca hiçbir karşı taraf beklemiyorsa tampon/bloklama devreye
  girer.
- **Deadlock tespiti YENİDEN kullanıldı, sıfır ek kod:** `Channel`,
  `Scheduler.suspendCurrent`/`markReady`i AYNEN kullandığından, "asla
  gelmeyecek bir `recv`" senaryosu OTOMATİK olarak zamanlayıcının genel
  deadlock tespitine düşer (bkz. aşama 2) — `Channel`e özel bir deadlock
  mekanizması YAZILMADI, gerek YOK.
- Doğrulama, üç standalone Zig testiyle (`zig build test`e bağlı,
  `channel.zig` transitively `scheduler.zig`+`fiber.zig`nin testlerini
  de içerir): (1) tamponsuz kanalda gönderen/alıcı el ele teslimi; (2)
  tamponlu (kapasite 2) kanalda kapasiteye kadar bloklamama + dolunca
  gönderenin bloklanıp alıcı bir öğe alınca DOĞRU sırayla (1,2,3)
  uyanması; (3) hiçbir zaman gelmeyecek bir `recv` → `error.Deadlock`
  KESİN olarak fırlatıldı, asılı KALMADI. Üçü de İLK denemede, ek
  hata ayıklama gerekmeden geçti (aşama 1-2'nin DebugAllocator/yabancı-
  yığın dersi baştan uygulandığı için — testler `page_allocator`
  kullanıyor). Hem Debug hem `-Doptimize=ReleaseFast`de yeşil.

**Aşama 4 — kısmen UYGULANDI: gramer → tip denetimi → sahiplik analizi
TAMAMLANDI, yalnızca codegen lowering KALDI.**

- **Gramer:** yeni anahtar kelimeler `async`/`await`/`spawn`. `async def`
  (`ast.FuncDef.is_async`). `await <ifade>`/`spawn <çağrı>` `-`/`not` ile
  AYNI (unary) önceliktedir. `Channel[T](capacity)` — dilde başka HİÇBİR
  yerde olmayan, AÇIK tip argümanlı bir kurucu çağrısı sözdizimi:
  `İsim[TipArgs](args)` yalnızca ayrılmış `Channel` adı için (`parser.zig`,
  `isGenericConstructName`) parser düzeyinde özel olarak tanınır — normal
  indekslemeyle (`xs[i]`) hiç KARIŞMAZ, çünkü `xs` bu ada eşit olamaz.
  `Task[T]` için AYNI sözdizimi YOK (bir `Task` asla doğrudan inşa
  edilmez, yalnızca `spawn`ın ÜRETTİĞİ bir tutamaçtır).
  **Bulunan gerçek hata (parser):** `Channel[T](...)` dalında, `expr`
  (bir tagged union) üzerine atama yaparken AYNI ifadenin sağ tarafında
  `expr`in ESKİ etiketini (`expr.identifier`) okumak GÜVENLİ DEĞİLDİR —
  "access of union field 'identifier' while field 'generic_construct' is
  active" ile ÇÖKER. Düzeltme: ismi ÖNCE ayrı bir yerel değişkene almak
  (kod tabanındaki DİĞER postfix dallarının zaten kullandığı `old_expr`
  deseniyle AYNI, yalnızca bu YENİ dalda unutulmuştu).
- **Tip sistemi (`types.zig`):** `Type.task: *const Type` / `Type.channel:
  *const Type` — `list` ile AYNI desende (`eql`/`format` özyinelemeli).
- **Checker:** `typeExprToType`, `Task`/`Channel` generic adlarını çözer.
  `FnCtx.in_async` — yalnızca `async def` gövdesinde `true`. `async def`
  fonksiyonlar `self.async_functions`de ayrıca izlenir: DOĞRUDAN
  çağrılmaları REDDEDİLİR ("yalnızca 'spawn' ile başlatılabilir") — gövdesi
  `await` içerebilir, bu da bir FIBER BAĞLAMI gerektirir, senkron bir
  çağrı bunu sağlayamaz. `spawn <çağrı>`: çağrının `.identifier` bir
  `async def`e başvurması ZORUNLU kılınır (metod/kurucu spawn'ı v0.1
  kapsamı DIŞI), `Task[DönüşTipi]` döner. `await <ifade>`: yalnızca
  `in_async` iken geçerli; operandın tipi `Task[T]` ise `T`ye çözülür;
  değilse operandın SÖZDİZİMSEL ŞEKLİNİN bir `Channel.send`/`recv` çağrısı
  OLDUĞU ayrıca doğrulanır (bu çağrılar zaten `T`yi/`None`u DOĞRUDAN
  döndürür — `await` yalnızca "açık askıya alma noktası" sözdizimini
  zorunlu kılan şeffaf bir işaretleyicidir). `Channel[T](capacity)`
  (`.generic_construct`): `capacity`nin `int` olması zorunlu kılınır.
  `Channel`ın yerleşik `send`/`recv`i `checkCall`in `.attribute` dalında
  (kullanıcı sınıfı DEĞİL, `self.classes`den bağımsız) özel olarak işlenir.
- **Sahiplik analizi:** `.await_expr`/`.spawn_expr`/`.generic_construct`
  için `scanExprEscapes` genişletildi — `spawn`ın operandı zaten bir
  `.call` olduğundan MEVCUT çağrı-argümanı kaçış mantığı (hatta DAHA
  gerekli: görev eşzamansız çalıştığından argümanlar mevcut çerçeveden
  UZUN yaşayabilir) otomatik uygulanır; `await`ın operandı yalnızca OKUNUR
  (sahiplenilmez), kaçış olarak işaretlenmez. `isHeapTypeExpr`in `.generic
  => true` kuralı Task/Channel'ı DEĞİŞİKLİKSİZ zaten heap tipi sayıyor
  (list[T]/generic ile AYNI, ek kod GEREKMEDİ) — `noxc`nin gerçek çıktısı
  bunu doğruladı: `Task[int]` ASAP (kaçış yok), `Channel[int]` ARC (bir
  metod çağrısının alıcısı olduğu için) doğru sınıflandırıldı.
- **Golden testler:** bir AST-dump testi (`async_spawn_await_channel`,
  `async-def`/`spawn`/`await`/`generic_construct`in TAM beklenen dökümü)
  + dört tip denetimi testi (`ok_async_spawn_await_channel` — tam senaryo
  OK; `err_await_outside_async`; `err_spawn_non_async`;
  `err_call_async_directly`). Hepsi İLK denemede (parser çökmesi hariç,
  hemen yakalanıp düzeltildi) geçti. Hem Debug hem
  `-Doptimize=ReleaseFast`de 134/134 yeşil.

**Aşama 4 codegen lowering — UYGULANDI. Faz 21 (async/await/spawn/Task[T]/
Channel[T]) TAMAMEN TAMAMLANDI, uçtan uca doğrulandı.**

**Mimari kararlar (kullanıcıyla netleştirildi):**
- **Kapanış (closure) stratejisi:** her `spawn <fn>(args...)` çağrı sitesi
  için codegen ÖZEL bir sarmalayıcı fonksiyon üretir (`$spawn_wrap_N`,
  TEMBEL kaydedilir/üretilir — `$List_..._release` ile AYNI "kuyruk,
  sonda tüket" deseni, bkz. `SpawnWrapperSpec`/`genSpawnWrapper`). Bu,
  Nox'un mevcut "her çağrı sitesi için özel kod üret" felsefesiyle
  (monomorphization gibi) tutarlıdır.
- **`main`in çalıştırılması:** ÇİFT yol — `moduleUsesAsync` modülün
  (üst düzey deyimler + TÜM fonksiyon/metod gövdeleri) HERHANGİ bir
  async özelliği kullanıp kullanmadığını tarar; kullanmıyorsa (büyük
  çoğunluk, TÜM önceki 134 test) `genMain` DEĞİŞMEDEN, sıfır ek
  maliyetle çalışır; kullanıyorsa `genMainAsync` üst düzey kodu bir
  fiber girişi (`$main_body`) olarak derler, gerçek `$main` (C ABI
  girişi) yalnızca onu spawn edip zamanlayıcıyı sonuna kadar çalıştıran
  ince bir sürücüye dönüşür.

**Zig tarafı — `Task(T)`/`Channel(T)`in generic'liği KORUNDU, YENİDEN
YAZILMADI:** ilk planda düşünülenin AKSİNE, comptime-generic Task/Channel'ı
sabit bir `i64` payload'a indirgemek için TAMAMEN yeniden yazmaya GEREK
YOKTU — bunun yerine `runtime/async_rt/bridge.zig` (yeni) yalnızca TEK,
somut bir örnekleme kullanır (`Task(i64)`/`Channel(i64)`), C ABI'sinde
QBE'nin çağırabileceği düz `export fn`ler sağlar (`nox_async_spawn/await/
run_to_completion/init/deinit/destroy_task`, `nox_channel_new/send/recv/
destroy`). Tek gerçek Zig-tarafı değişiklik: `Task(T).func`ın tipi
`*const fn(*anyopaque) T`den `*const fn(*anyopaque) callconv(.c) T`e
çevrildi (bu alan artık QBE'nin ÜRETTİĞİ, C ABI'sinde derlenmiş bir
sarmalayıcıyı tutabiliyor) — mevcut aşama 2-3 testleri bu YENİ imzaya
göre güncellendi (`callconv(.c)` eklendi), DAVRANIŞ değişmedi.

**Payload dönüşümü (`toPayload`/`fromPayload`):** Nox'un TÜM değerleri
zaten QBE'de 8 baytlık bir gösterime sahip (`l`/`w`/`d`) — `int`/`str`/
`class`/`list` (hepsi `l`, SIFIR dönüşüm), `bool` (`w`, `extuw` ile
sıfır-genişletme / düz `copy` ile daraltma), `float` (`d`, `cast` ile
bit-yeniden-yorumlama). Bu üç QBE talimatı (`extuw`/`cast`/`copy`)
gerçek `qbe` ikilisiyle EMPİRİK olarak doğrulandı (küçük bir standalone
`.ssa` dosyası derlenip çalıştırıldı) — güvenilir buldu.

**Kod değişiklikleri:**
- `checker.zig`: `async def` parametreleri artık `isSpawnParamSafeType`
  ile (int/float/bool/str/None/`Task[T]`/`Channel[T]`) sınırlı —
  `isFfiSafeType`den (extern def için, DEĞİŞMEDİ) AYRI: Task/Channel
  ARC-yönetimli OLMADIĞINDAN (yalnızca bir işaretçi kopyası) kapanışa
  paketlenmesi TRİVİYALDİR; sınıf/`list[T]` (retain/release
  gerektirirdi) v0.1 kapsamı DIŞI kaldı. **Bulunan gerçek hata:** ilk
  sürüm yanlışlıkla `isFfiSafeType`i kullanıyordu, bu da `Channel[T]`i
  bir `async def`e PARAMETRE olarak geçirmeyi (kanalların ASIL kullanım
  amacı!) REDDEDİYORDU — golden test yazılırken YAKALANDI, düzeltildi.
- `codegen_qbe/codegen.zig`: `resolveType`, `Task`/`Channel` generic
  adlarını çözer (`HeapKind.task`/`.channel` — BİLEREK `isHeapManaged`in
  DIŞINDA, aşağıdaki nota bakın); `genSpawnExpr` (kapanış paketleme +
  `nox_async_spawn` çağrısı), `genSpawnWrapper` (TEMBEL üretilen
  sarmalayıcı gövdesi), `genAwaitExpr` (Task await'i VEYA
  `Channel.send`/`recv`e sözdizimsel dağıtım — checker'ın AYNI şekil
  denetimini codegen'de TEKRARLAR), `genChannelOp`, `genGenericConstruct`
  (`Channel[T](capacity)`), `moduleUsesAsync`/`stmtUsesAsync`/
  `exprUsesAsync` (özyinelemeli tarayıcı), `genMainAsync`.
- `runtime/async_rt/bridge.zig` (yeni): C ABI köprüsü — modül-seviyesi
  TEK `Scheduler` (M:1 varsayımıyla tutarlı, `rt` bağlamına EKLENMEDİ —
  Katman 1 async'ten bağımsız kalmalı).
- `runtime/lib.zig`/`build.zig`: `async_bridge` `noxrt.o`ya bağlandı
  (`swap_aarch64.o` ARTIK hem standalone testlere HEM gerçek `noxrt.o`ya
  bağlanıyor — `compile_swap_asm` `noxrt_mod`dan ÖNCEYE taşındı).

**Bulunan gerçek hatalar (uçtan uca doğrulama sırasında, İKİSİ de gerçek
programlar ÇALIŞTIRILARAK yakalandı — yalnızca derleme/tip denetimi
YETERSİZ kalırdı):**
1. **Parser çökmesi:** `Channel[T](...)`ı ayrıştırırken, `expr` (tagged
   union) üzerine atarken AYNI ifadenin sağında `expr`in ESKİ etiketini
   (`expr.identifier`) okumak Zig'de GÜVENLİ DEĞİL — "access of union
   field 'identifier' while field 'generic_construct' is active" ile
   ÇÖKTÜ. Düzeltme: ismi ÖNCE ayrı bir yerele almak (kod tabanının
   `old_expr` deseninin AYNISI, bu yeni dalda unutulmuştu).
2. **`Scheduler.ready`nin arka plan dizisi sızıyordu:** `nox_async_init`
   zamanlayıcıyı başlatıyordu ama HİÇBİR YERDE `deinit()` ÇAĞRILMIYORDU
   (yalnızca köprünün KENDİ standalone testlerinde elle yapılıyordu) —
   gerçek bir programı ÇALIŞTIRIP DebugAllocator'ın leak raporunu
   GÖRENE kadar fark edilmedi. Düzeltme: yeni `nox_async_deinit` +
   `genMainAsync`nin sonunda çağrılması.
3. **HER `spawn`/`Channel[T](...)` sonucu sızıyordu:** `Task`/`Channel`
   `heap = .none` (ARC-dışı) olarak işaretlenmişti ama HİÇBİR ŞEY
   onları kapsam sonunda YIKMIYORDU (ARC'a dahil değiller, ama
   kendi başlarına da YIKILMIYORLARDI) — YİNE gerçek bir programı
   çalıştırıp leak raporunu görene kadar fark edilmedi. Düzeltme:
   `HeapKind`e `.task`/`.channel` eklendi (BİLEREK `isHeapManaged`in
   DIŞINDA — retain/predecrement YOK, `releaseAllLocalsExcept`
   kapsam sonunda DOĞRUDAN bir `nox_async_destroy_task`/
   `nox_channel_destroy` çağırır). **Bilinçli v0.1 sınırlaması:**
   yeniden atamada (`t = spawn ...`) eski değer bu yoldan GEÇMEZ
   (yalnızca kapsam SONU) — bu durumda eski görev/kanal sızar (zaten
   dokümante edilmiş "kaçak Task" sınıfıyla AYNI kabul edilen kapsam).
4. **`Channel[T]`i `async def` parametresi olarak geçirmek reddediliyordu**
   (yukarıdaki `isFfiSafeType`/`isSpawnParamSafeType` notuna bakın).

**Üst düzeyde `await`/`spawn` — bilinçli tasarım kararı:** Nox'ta açık
bir `def main()` sözleşmesi YOK (üst düzey deyimler zaten programın
kendisidir) — bu yüzden `checkModule`, üst düzey bağlamı `in_async =
true` ile denetler (kullanıcı ayrıca bir `async def main()` yazmak
ZORUNDA DEĞİLDİR; `spawn`/`await`/`Channel[T](...)`i doğrudan üst
düzeyde kullanabilir). `err_await_outside_async` testi bu yüzden
YENİDEN YAZILDI: `await`ın GERÇEKTEN reddedildiği tek yer, sıradan
(async OLMAYAN) bir fonksiyon gövdesidir.

**Golden testler (üçü de İLK denemede geçti — parser çökmesi ayrı,
gramer/AST/checker seviyesinde zaten yakalanmıştı):**
`async_spawn_await` (temel spawn+await, i64 payload, `42` çıktısı),
`async_channel` (iki `async def` görevi arasında tamponsuz Channel
iletişimi, `10\n20\n` çıktısı), `async_deadlock` (kasıtlı kilitlenme —
`print(1)` çıktısından SONRA, `nox_async_deadlock_abort` ile sıfırdan
farklı bir çıkış koduyla NET biter, asılı KALMAZ). Hepsi hem stdout'u
HEM sızıntı yokluğunu (stderr boş) doğruluyor. 147/147 test yeşil, hem
Debug hem `-Doptimize=ReleaseFast`.

**Bilinçli v0.1 sınırlamaları (baştan §3.21'in ana metninde belirtilmiş,
DEĞİŞMEDİ):** yapısal eşzamanlılık zorunluluğu yok, M:N zamanlama yok,
timeout/cancellation/select yok, `async def` gövdesinde oluşan bir
istisnanın Nox'un raise/try/except mekanizmasıyla TAM entegrasyonu yok
(bkz. `genSpawnWrapper`nin notu — yakalanmamış bir istisna async bir
görev içinde UNDEFINED davranış), yeniden atamada eski Task/Channel
sızar (yukarıya bakın).

---

### 3.22 Faz 21 Ön-Koşulu — `list[T]` İçin Özyinelemeli Heap-Eleman Release

**Durum: UYGULANDI.** Kullanıcının Faz 21 aşama 4'e (`Task[T]`/`Channel[T]`
derleyici entegrasyonu) "tam genel `T`" (sınıf VE `list[T']` DAHİL) ile
devam etme kararı üzerine, bir ÖN-KOŞUL olarak keşfedildi: `list[T]`'nin
KENDİSİ bugüne kadar `T`nin heap-yönetimli (sınıf ya da iç içe liste)
olmasını `resolveType`/`genListLit` düzeyinde REDDEDİYORDU ("özyinelemeli
yıkım karmaşıklığı" gerekçesiyle, Faz 5'ten beri bilinçli olarak
ertelenmiş). Bu, Task/Channel'dan BAĞIMSIZ, dilin kendi `list[T]`
özelliğinin gerçek bir eksiğiydi — önce bu çözüldü.

**Uygulanan tasarım (`compiler/codegen_qbe/codegen.zig`):**
- Yeni `ElemHeapInfo` yapısı (`heap`, `class_name`, `elem_qtype`, `nested:
  ?*const ElemHeapInfo`) — bir `list[T]`nin `T`si KENDİSİ heap-yönetimliyse
  (sınıf ya da iç içe `list[T']`) bunu ÖZYİNELEMELİ olarak betimler;
  keyfi derinlikte iç içe geçişi (`list[list[list[X]]]` gibi) destekler.
  `TypeInfo`/`Value`/`VarInfo`ya `elem_heap_info: ?*const ElemHeapInfo`
  alanı eklendi.
- `resolveType`'ın `list[T]` dalındaki `if (elem.heap != .none) return
  error.Unsupported;` kısıtı kaldırıldı; yerine `elem.heap`e göre
  `ElemHeapInfo` inşa edilir (sınıf/iç-içe-liste için doldurulur, `str`
  için ayrı bir `elem_is_str` bayrağıyla — bkz. aşağı — primitiflerle
  aynı, ücretsiz yoldan geçer).
- `genListLit`, heap-yönetimli elemanları artık REDDETMİYOR: her eleman
  `retainIfAliasing` ile (bir isim alias'ıysa) retain edilir — TAZE
  değerler (ör. `Point(1,2)` çağrısı) zaten "taşınmış" sayıldığından
  retain gerekmez.
- **Yeni release mekanizması — `releaseFnNameFor`/`genListElemRelease`:**
  bir `list[T]` DEĞERİNİN KENDİSİNİ serbest bırakacak `$List_<mangled>_
  release(rt,p)` fonksiyonları TEMBEL olarak keşfedilir (`list_release_
  queue`, `string_data` gibi `generateModule`nin sonunda drenajla
  üretilir). Üretilen gövde `info.nested`e göre dallanır: `null` (elemanlar
  primitive) ise DÖNGÜSÜZ düz `predecrement+free`; değilse `genForList`deki
  AYNI güvenli döngü deseniyle (indeks sayacı fonksiyon girişinde TEK
  `alloc8` — Faz 16'daki alloc-döngü-içi yığın taşması hatasına yol
  AÇMAZ) her elemanı `$<releaseFnNameFor(nested)>_release` ile özyinelemeli
  serbest bırakır, SONRA belleği geri verir. Sınıf elemanları için bu
  doğrudan (Faz 9'dan beri var olan) `$ClassName_release`e gider — YENİ
  bir fonksiyon üretilmez.
- **`str` elemanlar için ayrı, basit bir yol (`elem_is_str`):** `str`
  release GEREKTİRMEDİĞİNDEN (`isHeapManaged` onu zaten kapsam dışı
  tutar) `ElemHeapInfo`ya dahil edilmedi; ama `genIndex`/for-döngüsü
  değişkeni gibi OKUMA noktalarının sonucu `heap = .str` diye DOĞRU
  etiketleyebilmesi (aksi halde `print` bir string'i tamsayı gibi basar
  — TESPİT EDİLEN gerçek bir hata, bkz. aşağı) için `elem_is_str: bool`
  adında ayrı, basit bir bayrak eklendi.
- **`genForList`/`collectLocals`deki döngü değişkeni — bulunan gerçek
  hata:** bir `list[SınıfT]` (ya da `list[str]`) üzerinde `for x in xs`
  yapıldığında, döngü değişkeninin KENDİSİ `x`, `collectLocals`'ta
  YALNIZCA `elem_qtype` ile kaydediliyordu — `heap`/`class_name` HİÇ
  taşınmıyordu. Bu iki AYRI gerçek hataya yol açardı: (1) `list[SınıfT]`
  için: döngü değişkeni "heap tipli değilmiş gibi" davranılır, kapsam
  sonunda YANLIŞLIKLA release edilmezdi (bu spesifik durumda zararsızdı
  çünkü zaten release edilmiyordu) AMA ayrıca (2) `list[str]` için:
  `print(x)` `x`i `heap=.none` sandığından STRING İÇERİĞİ yerine HAM
  İŞARETÇİ DEĞERİNİ basıyordu (yeni `list_str_elements` golden testiyle
  YAKALANDI). Düzeltme: `collectLocals`, döngü değişkeninin `TypeInfo`sunu
  kaynak listenin `elem_heap_info`/`elem_is_str`sinden DOĞRU yeniden
  kurar; ayrıca döngü değişkeni listenin İÇİNDEKİ bir elemana ÖDÜNÇ ALINMIŞ
  bir referans olduğundan (`is_param = true` ile) kapsam-sonu otomatik
  release'den MUAF tutulur — aksi halde listenin KENDİ sahipliğini bozan
  bir çifte-serbest-bırakma riski doğardı (`genMain`nin de bu `is_param`
  bilgisini artık YOK SAYMAMASI gerekti — eskiden sabit `false` geçiyordu).
- **Ayrıca bulunan, AYRI/orta-öncelikli bir hata (bu fazın kapsamı
  DIŞINDA bırakıldı, arka plan görevi olarak işaretlendi):**
  `retainIfAliasing`, yalnızca kaynak ifade `.identifier` ise retain
  eder — `q: Engine = car.engine` (`.attribute`) ya da `p: Point =
  some_list[0]` (`.index`) gibi bir heap değerini YENİ bir isme ALIAS
  eden atamalar HİÇBİR ZAMAN retain almaz; bu, kapsam sonunda YANLIŞ bir
  refcount düşüşüne (potansiyel çifte-serbest-bırakma) yol açabilir.
  Faz 9'dan beri var olan, bugünkü değişikliklerden BAĞIMSIZ bir sorun —
  ayrı bir arka plan görevine not düşüldü.
- **Golden testler (üçü de İLK denemede geçti):** `list[str]` (açıkça
  anotasyonlu, iç-içe-heap OLMAYAN durum — üstteki gerçek hatayı
  yakalayan test), `list[Point]` (heap-yönetimli sınıf elemanları —
  inşa + `for` ile iterasyon + kapsam-sonu `$List_Point_release`,
  `stderr` boş kalarak sızıntı/çifte-serbest-bırakma OLMADIĞI doğrulandı),
  `list[list[int]]` (iç içe liste elemanları — özyinelemeli mekanizmanın
  GERÇEKTEN iki seviye çalıştığı doğrulandı). Eski "iç içe heap tipi
  reddedilir" testi (artık YANLIŞ olan eski davranışı belgeliyordu)
  kaldırılıp bu üç pozitif testle DEĞİŞTİRİLDİ. Hem Debug hem
  `-Doptimize=ReleaseFast`de 129/129 yeşil.

**O ZAMAN kapsam dışı bırakılan, §3.23'te ÇÖZÜLDÜ:** sınıf ALANLARININ
`list[T]` tipinde olması (`inferFieldType`nin ayrı bir kısıtıydı — bu fazın
konusu değildi, yalnızca DEĞİŞKENLER/parametreler/dönüş değerleri için
`list[T]` heap-elemanları burada çözülmüştü).

---

### 3.23 QBE Codegen Tamamlama — Kalan v0.1 Kapsam Sınırlamalarının Kapatılması

Kullanıcının "QBE ile native AOT derleme dilin ne kadarında %100 aktif,
eksik varsa tamamlayalım" isteği üzerine yapılan bir denetim (`compiler/
codegen_qbe/codegen.zig`'deki tüm `error.Unsupported` yolları + spesifikasyonun
kendi "bilinçli kapsam sınırlamaları" listeleri karşılaştırıldı), bu fazdan
önce hâlâ açık olan **6 gerçek eksiği** ve **2 bayat dokümantasyon** sorununu
ortaya çıkardı. Hepsi bu fazda kapatıldı:

**1) `str == str` / `str != str`:** checker (`checkBinary`) zaten
`types.eql`in genel tip eşitliğiyle bunu KABUL ediyordu — engel yalnızca
codegen'deydi (`genBinary`, heap tipli HER işleneni körlemesine reddeden tek
bir kontrol). `genStrCompare`, libc `strcmp`i (`cc` bağlantısında zaten mevcut,
ekstra bağlama argümanı gerekmiyor) çağırıp sonucu `0`a karşı bir `w` bool'a
çevirir. `str` hiçbir zaman ARC-yönetimli olmadığından (`isHeapManaged`
yalnızca `list`/`class`) operandlar için özel bir serbest bırakma gerekmedi.

**2) `__init__` içermeyen sınıflar:** checker zaten sıfır-parametreli
kurucuyu destekliyordu (`init_sig orelse` varsayılanı) — engel yalnızca
codegen'in `registerClass`ıydı (`init_fd orelse return error.Unsupported`).
`ClassInfo`ya bir `has_init: bool` eklendi; `__init__`i olmayan bir sınıfın
alanı yok (`total_size = TAG_SIZE`), kurucusu 0 argüman alır, ve
`genConstruct` `has_init == false` olduğunda `$ClassName___init__` çağrısını
(üretilmediği için) hiç YAPMAZ.

**3) `obj.attr = değer` self dışına genelleştirildi:** hem `checker.checkAssign`
hem `codegen.genAssign`in `.attribute` dalı önceden yalnızca `attr.obj`nin
DOĞRUDAN `self` identifier'ı olmasını kabul ediyordu. Artık `attr.obj`
HERHANGİ bir sınıf örneğine değerlenebilir (`p.x = p.x + 1` gibi bir fonksiyon
İÇİNDEN); yalnızca YENİ bir alan TANIMLAMAK (checker'ın `info.fields`de henüz
olmayan bir ad) hâlâ `self.<alan> = ...` biçiminde VE `__init__` içinde olmaya
mecburdur (aksi halde bir sınıfın alan kümesi çağrı sitesine göre değişken
olurdu — AGENTS.md §5). Codegen tarafında `obj`, bir metod çağrısının ALICISI
gibi TAZE bir değer OLABİLİR (ör. `make_car(i).x = 5`) — aynı `checkNoLowlevelEscape`
+ "taze ise sonda serbest bırak" deseni (`genMethodCall`/`genFieldRead` ile
AYNI) burada da uygulanır.

**4) Sınıf alanı `list[T]` tipinde olabilir:** `inferFieldType`nin
`list[T]`i reddeden tek satırı kaldırıldı — `resolveType` zaten TAM
`elem_qtype`/`elem_heap_info`/`elem_is_str` betimleyicisini üretiyordu.
`genClassRelease`in alan döngüsü genelleştirildi (`f.info.heap != .class`
yerine `!isHeapManaged(f.info.heap)`) — artık HER heap-yönetimli alanı
(sınıf YA DA liste) `releaseValueIfSet` üzerinden AYNI tek yoldan (null
kontrolü + doğru release fonksiyonuna dispatch) özyinelemeli olarak serbest
bırakır.

**Bu sırada bulunan, ayrı ama ilişkili İKİ gerçek hata (list[T] alanı
ÖZELLİKLE değil, genel ARC takma-ad kuralı eksikti):**
- `retainIfAliasing` yalnızca `value == .identifier` kaynakları retain
  ediyordu — `x: SomeClass = c.engine` (bir alan okumasını YENİ bir yerele
  atamak) ya da `x: SomeClass = mylist[0]` (bir indekslemeyi YENİ bir
  yerele atamak) retain EDİLMİYORDU, bu da (taban serbest bırakıldığında)
  potansiyel bir kullanım-sonrası-serbest-bırakmaydı. Yeni `isAliasingExpr`
  yardımcı fonksiyonu: `.identifier` HER ZAMAN, `.attribute`/`.index` İSE
  yalnızca TABANLARI (`obj`) TAZE DEĞİLSE bir takma addır (taban TAZEyse
  `genFieldRead`/`genIndex` bunu KENDİSİ ZATEN retain etmiştir — burada
  TEKRAR retain etmek çifte-retain olurdu).
- `genIndex`, TAZE bir taban listeden (ör. `make_list()[0]`) heap-yönetimli
  bir eleman okurken, `genFieldRead`in AKSİNE, tabanı serbest bırakmadan ÖNCE
  elemanı retain ETMİYORDU — taban refcount'u sıfıra düşerse okunan eleman
  da özyinelemeli olarak serbest bırakılıp döndürülen değer kullanım-sonrası-
  serbest-bırakmaya dönüşebilirdi. `genFieldRead` ile AYNI "taze taban +
  heap-yönetimli sonuç → önce retain, sonra tabanı serbest bırak" deseni
  eklendi.

**5) `list[T]`/sınıf için özyinelemeli yapısal `==`/`!=`:** checker zaten
`types.eql`in yapısal (tag+iç tip) eşitliğiyle bunu kabul ediyordu (iki
FARKLI sınıf `TypeMismatch` ile reddedilir, bkz. `err_class_eq_type_mismatch`)
— engel yine yalnızca codegen'deydi. Yeni makine:
- `ElemHeapInfo`ya bir `elem_is_str: bool` alanı eklendi (release'in AKSİNE
  eşitlik `list[str]`i `list[int]`den AYIRT ETMEK zorunda — `strcmp` ile
  `ceq*` FARKLI operasyonlardır; bu alan olmadan bu bilgi bir iç içe seviye
  sonra kaybolurdu).
- `genValueEqCompare`: verilen iki (yüklenmiş) değeri `heap` türüne göre
  karşılaştırır — primitif (`ceq{l,w,d}`), `str` (`strcmp`), `class`/`list`
  İSE (NULL OLABİLİR, bkz. `__init__`in koşullu bir dalda alan atlaması
  bilinen sınırlaması) bir dal + yığın yuvası (QBE'nin `phi`sini KULLANMADAN
  — bu dosyanın genelindeki "dallanma sonucu bir yığın yuvasından geçir"
  deseniyle AYNI) ile: ikisi de null → eşit; yalnızca biri null → eşit
  DEĞİL; ikisi de null değil → özyinelemeli (`$ClassName_eq`/`$List_..._eq`).
- `genClassEq`: HER sınıf için (genClassRelease ile AYNI anda) üretilir,
  alan alana `genValueEqCompare` ile karşılaştırır (alanı olmayan sınıf İÇİN
  sonuç her zaman `1`dir — kimlik önemsiz, yapısal eşitlik).
- `eqMangleFor`/`eqFnNameForList`/`genListEq`: `list_release_queue` ile AYNI
  "TEMBEL kaydet + sonda tüket" deseni, AMA ayrı bir mangling şeması (`str`
  `int`den farklı bir ada sahip — release'in `prim*` kovası eşitlik için
  YETERSİZ). Üretilen `$List_<mangled>_eq` önce UZUNLUKLARI karşılaştırır
  (farklıysa erken `0`), sonra elemanları TEK TEK (kısa devreli) karşılaştırır.
- `genBinary`, `l0.heap == r0.heap == .list`/`.class` VE `op` `==`/`!=`
  olduğunda bu makineye yönlenir; sonucu `!=` için `xor 1` ile tersler;
  TAZE operandları (`releaseIfTemporary`) sonda serbest bırakır.

**6) `print(list[T])`/`print(sınıf)`:** Python'un `repr()`ine benzer bir
görüntüleme — `[e1, e2, ...]` / `ClassName(alan1=değer1, ...)`, ÖZYİNELEMELİ
(bir eleman/alan yine bir liste/sınıf olabilir). `genPrint` (yalnızca
EN DIŞTAKİ çağrı, tek bir satır sonu ekler) `genPrintFragment`e (satır sonu
OLMADAN, özyineli) yetki devreder. Bir listenin UZUNLUĞU yalnızca ÇALIŞMA
ZAMANINDA bilindiğinden, `genPrintList` `genForList`/`genListElemRelease`
ile AYNI güvenli döngü desenini (fonksiyon GİRİŞİNDE bir kez `alloc8`)
kullanır — her yinelemede eleman `genPrintFragment` ile basılır, ilk eleman
DIŞINDA önce `", "` yazılır. `genPrintClass` alan sayısının SABİT olması
sayesinde döngüsüzdür. Sınıf/alan adları gibi derleme-zamanı sabit metinler
(`internFmtString`) `string_data`den AYRI, pinned-refcount başlığı OLMAYAN
düz `printf` format dizesi sembolleri olarak yayılır. **Önemli ayrım:**
en dıştaki `print("merhaba")` (bir `str` DEĞERİ) TIRNAKSIZ basılır (Python'un
`print()`i `str()` kullanır) — yalnızca bir listenin/sınıfın İÇİNDEKİ bir
`str` elemanı/alanı `genPrintFragment` ile TIRNAKLI (`'...'`, Python'un
`repr()`i gibi) basılır; bu yüzden `genPrint` (dış) ve `genPrintFragment`
(iç, özyineli) İKİ AYRI `str` format sabiti kullanır (`$fmt_str` vs
`$fmt_str_frag`). `print`in argümanı artık TAZE bir liste/sınıf olabileceğinden
(`print(Point(1,2))`), `genCall`in `print` dalına `releaseIfTemporary` eklendi
(aksi halde YENİ bir sızıntı olurdu).

**Bayat dokümantasyon (davranış değişikliği YOK, yalnızca metin):**
`compiler/main.zig`'in `error.Unsupported` mesajı, bugün ZATEN çözülmüş
şeyleri (iç içe `list[T]`, sınıf alanı `list[T]`, `==`/`!=`, `__init__`siz
sınıf) hâlâ "desteklenmiyor" diye listeliyordu — genel, spec'e yönlendiren
bir mesajla değiştirildi. §3.6'nın "bilinçli kapsam sınırlamaları" listesi
de aynı şekilde güncellendi (bkz. yukarısı).

**Golden testler (hepsi İLK denemede geçti, 159/159 yeşil, hem Debug hem
`-Doptimize=ReleaseFast`):** `class_no_init`, `attr_assign_external`,
`str_equality`, `list_class_field`, `attr_index_read_into_local_retain`
(yukarıdaki iki ARC hatasını doğrudan hedefler), `deep_equality` (int/str/iç
içe liste/sınıf/list[sınıf], sızıntı yok), `print_list_class` (iç içe, sızıntı
yok) — hepsi `tests/golden/codegen_cases/`. Tip denetleyici tarafında:
`ok_class_no_init`, `ok_attr_assign_external`,
`err_attr_assign_new_field_external` (self dışından YENİ alan tanımlama hâlâ
reddediliyor), `err_class_eq_type_mismatch` (iki FARKLI sınıf `==` ile
karşılaştırılamaz) — `tests/golden/typecheck_cases/`. Her yeni golden test,
kasıtlı olarak bozulup kırmızıya döndüğü, sonra düzeltildiği doğrulanarak
(AGENTS.md İlke #7) eklendi.

---

### 3.24 Performans Fazı — Benchmark Genişletme + Darboğaz Giderme

Kullanıcının isteği: benchmark takımını genişletmek, darboğazları tespit
edip AOT derlenen bir dile yakışan hızı HER alanda sağlamak.

**1) ARC retain/predecrement çağrıları QBE'ye inline edildi:** `nox_rc_retain`/
`nox_rc_predecrement`in çalışma zamanı ÇAĞRILARI (ayrı bir nesne dosyasına,
kendi yığın çerçevesiyle) yerine, `codegen_qbe/codegen.zig`e `emitInlineRetain`/
`emitInlinePredecrement` eklendi — bunlar doğrudan QBE aritmetiği (`sub 8` +
`load`/`add`-veya-`sub` + `store`) üretir; retain/predecrement zaten yalnızca
bunlardan ibarettir. Tüm 5 çağrı sitesi (`retainIfAliasing`, `return`in
retain'i, `genFieldRead`/`genIndex`in taze-taban retain'i, `genClassRelease`/
`genListElemRelease`in predecrement'i) güncellendi.

**2) `oop_arc_churn`in profillenmesi (macOS `sample`) — ARC nesneleri için
sabit büyüklük-sınıflı serbest liste havuzu:** 60M yinelemelik bir stres
koşusunun profili, örneklerin ~%45'inin `smp_allocator`ın kendi tahsis/serbest
bırakma overhead'inde (sistem çağrıları/TLS/bookkeeping) geçtiğini gösterdi —
Nox nesneleri (sınıf/liste) tipik olarak KÜÇÜKTÜR ve döngülerde SIK inşa
edilip yıkılır, bu da genel amaçlı ayırıcıyı gereksiz yere zorluyordu. Çözüm
(`runtime/alloc/arc.zig`): `nox_rc_alloc`/`nox_rc_free_payload`, boyutu 10
sabit sınıftan birine (16, 32, ..., 8192 bayt, ikiye katlanarak) denk düşen
nesneler için genel ayırıcıya HİÇ gitmeden kendi aralarında geri dönüştürülen
bir serbest liste (`asap.RuntimeState.pool_free_lists`) kullanır. **Yalnızca
Release modlarında aktif** (`use_pool = builtin.mode != .Debug`) — Debug
modunda HER tahsis/serbest bırakma DEĞİŞMEDEN `DebugAllocator`a gider (dört
gerçek ARC hatasının yakalanmasını sağlayan güvenlik ağı KORUNUR — havuzlama
bir bloğu "serbest" gösterip aslında canlı tutarak bu tespiti zayıflatırdı).
Havuzlanan bloklar programın ömrü boyunca OS'a asla geri verilmez (Release
modunda sızıntı tespiti zaten yok, `main` hemen ardından sonlanır — tcmalloc/
jemalloc'la AYNI, bilinçli kabul edilen bir ödünleşim). Ölçülen sonuç:
`oop_arc_churn` 56.4ms→40.7ms (Python'a karşı 8.3x→11.5x hızlanma).

**3) `async_task_churn`ın profillenmesi — fiber yığın havuzu:** 200.000
`spawn`lık bir döngünün zamanlaması `0.588s duvar, 0.25s system` gösterdi —
`fiber.zig`'in 256 KiB'lik yığını (`Fiber.STACK_SIZE`) HER `spawn`da tazeden
tahsis edilip HER tamamlanmada serbest bırakılıyordu; blok BÜYÜK olduğundan
(genel amaçlı ayırıcının küçük-nesne hızlı yolunu atlayıp doğrudan işletim
sistemine gitmesi YÜZÜNDEN) bu baskın bir maliyetti — ARC pool'unun (madde 2)
KENDİSİ bu yolu HİÇ etkilemez (Scheduler kendi ayrı yığın havuzunu tutar).
Çözüm (`runtime/async_rt/scheduler.zig`): `Scheduler`e bir `stack_pool`
(`ArrayListUnmanaged`) eklendi — bir görev bitince yığını GERÇEKTEN serbest
bırakmak yerine havuza döner; bir sonraki `spawn` önce havuzu dener
(`fiber.zig`e `Fiber.createWithStack`/`destroyKeepStack` eklendi — yığın
tahsisini `Fiber.create`in geri kalanından ayırmak için). Ölçülen sonuç:
AYNI 200.000 `spawn` `0.354s duvar, ~0.00s system`e düştü (gerçek CPU işi
~10 KAT azaldı); 2.000.000 `spawn` yalnızca 0.12s CPU sürüyor.

**4) Bulunan GERÇEK bir çökme hatası (benchmark genişletmesi sırasında,
performans OPTİMİZASYONU değil, DOĞRULUK hatası):** yeni `deep_equality`
benchmark'ı (bir döngü içinde tekrar tekrar `sınıf == sınıf`/`list == list`)
büyük N'de (2 milyon) segfault veriyordu — küçük N'de (5) sorunsuzdu. Kök
neden: §3.15'te bulunan AYNI hata sınıfı (QBE'nin `alloc4`/`alloc8`'i
FONKSİYON GİRİŞİNDE bir kez yapılacak bir tahsis SANMASI) — §3.23'ün
`genValueEqCompare`i, class/list alan/eleman karşılaştırmasının olası `null`
durumunu bir dal SONUCUNU birleştirmek için bir yığın yuvasıyla (`alloc4 4`)
ele alıyordu, ve bu fonksiyon `genBinary` üzerinden KULLANICI DÖNGÜSÜ
İÇİNDEN çağrılabiliyordu — her yinelemede tekrar tekrar `alloc4` çalışıp
yığını sessizce taşırıyordu. **Düzeltme:** `genValueEqCompare` (bir DEĞER
döndüren) yerine `genEqCompareOrJump` (uyuşmuyorsa bir `mismatch_label`e
ATLAYAN, uyuşuyorsa NORMAL AKIŞA devam eden, HİÇBİR DEĞER TAŞIMAYAN) ile
DEĞİŞTİRİLDİ — `genClassEq`/`genListEq`nin KENDİ alan/eleman döngüsü zaten
"eşleşmedi -> dışarı" ile "eşleşti -> bir sonrakine geç" ayrımını doğal
olarak taşıdığından, ayrı bir taşınabilir değere (dolayısıyla alloc/`phi`ye)
hiç gerek YOKTUR. Ayrıca `genBinary`'nin EN DIŞTAKİ `a == b` dispatch'i
(bir DEĞİŞKENE bağlı tam liste/sınıf DEĞERLERİ asla null OLAMAZ — yalnızca
ALANLAR/ELEMANLAR olabilir) artık `$ClassName_eq`/`$List_..._eq`yi
DOĞRUDAN çağırıyor, gereksiz null-kontrolü YAPMIYOR. Golden test:
`deep_equality_in_loop_no_stack_growth.nox` (2 milyon yineleme) — bu, YENİ
benchmark'ların (yalnızca hız değil) DOĞRULUĞU büyük ölçekte sınayan bir
regresyon aracı olarak da değerli olduğunu bir kez daha kanıtladı (bkz.
§3.15'teki AYNI ders).

**5) Benchmark takımı genişletildi** (`benchmarks/`, `benchmarks/compare/`):
önceki fazda (§3.23) eklenen özelliklerin HİÇ performans karakterizasyonu
yoktu — üç yeni alan eklendi:
- `deep_equality` — tekrarlanan `sınıf ==`/`list[T] ==` (stres: 8.6x
  hızlanma).
- `list_class_field` — `list[T]` tipli bir sınıf alanının metod içinde
  özetlenmesi (9.6x hızlanma).
- `async_task_churn` — tekrarlanan `spawn`+`await` (STRES-YALNIZCA; Python'un
  asyncio/threading'i TAMAMEN farklı bir eşzamanlılık modeli — GIL dahil —
  olduğundan adil bir karşılaştırma çifti eklenmedi, yalnızca büyük ölçekte
  doğruluk + performans regresyon takibi için).

**Doğrulama:** `zig build test` hem Debug hem `-Doptimize=ReleaseFast`de
yeşil; `zig build bench -Doptimize=ReleaseFast` 11/11 stres + 10/10
karşılaştırma çifti başarıyla tamamlanıyor. Her yeni golden test "kasıtlı
boz, kırmızıyı doğrula, düzelt" ritüeliyle eklendi.

---

### 3.25 Derin Performans Analizi — Exception-Check Elision

Kullanıcının isteği: dili performans açısından detaylıca analiz edip TÜM
darboğazları sırayla düzeltmek. §3.24'ün bıraktığı yerden devam: `fib`
gibi saf özyinelemeli/küçük-fonksiyon-ağırlıklı kodun macOS `sample` ile
profillenmesi, örneklerin **~%49'unun** `nox_exception_pending`
çağrılarında geçtiğini gösterdi — her kullanıcı fonksiyonu/kurucu
çağrısından SONRA üretilen örtük "bekleyen istisna var mı?" kontrolü
(bkz. §3.7, `emitExceptionCheck`), `fib` gibi HİÇBİR ZAMAN raise
etmeyen kod için tamamen gereksiz bir maliyetti.

**Çözüm — `computeMustNotRaise` (bkz. `codegen_qbe/codegen.zig`):**
her serbest fonksiyonun/kurucunun (`__init__`) gövdesini `moduleUsesAsync`/
`stmtUsesAsync`/`exprUsesAsync` (Faz 21) ile AYNI özyineli ağaç gezinme
deseniyle tarar; bir sembol şu ÜÇ durumdan HİÇBİRİNE sahip DEĞİLSE VE
çağırdığı HİÇBİR serbest fonksiyon/kurucu (transitif olarak) güvensiz
DEĞİLSE "asla raise etmez" kümesine (`self.must_not_raise`) girer:
1. Gövde içinde DOĞRUDAN bir `raise` (herhangi bir derinlikte — if/while/
   for/try/lowlevel içinde de sayılır).
2. Gövde içinde bir METOD ÇAĞRISI (`obj.method()`).
3. Gövde içinde bir `await`/`spawn`.

Sabit nokta (fixpoint) ile hesaplanır: `direct_unsafe` olanlarla başlanır,
sonra HERHANGİ bir çağrı hedefi güvensiz kümedeyse çağıran da eklenir —
değişiklik kalmayana kadar (yalnızca büyüyen, sonlu bir küme, sonlanması
garantili). Özyinelemeli (`fib`) ve KARŞILIKLI özyinelemeli (`is_even`/
`is_odd`, ileri-referanslı) fonksiyonlar doğru ele alınır — sonuç
`genCall`/`genConstruct`in çağrı SONRASI `emitExceptionCheck`i ATLAMASI
için kullanılır.

**BİLİNÇLİ OLARAK MUHAFAZAKÂR (yanlış negatifte istisna ASLA yutulmaz,
yalnızca gereksiz bir kontrol FAZLADAN kalabilir):**
- **Metod çağrıları optimizasyonun DIŞINDA bırakıldı** — bir `obj.method()`
  çağrısının hedef sınıfını bilmek TAM bir tip çıkarımı gerektirirdi
  (checker'ın kendi işi, codegen'de YENİDEN UYGULANMADI); bu yüzden
  HERHANGİ bir metod çağrısı içeren bir gövde KOŞULSUZ güvensiz sayılır —
  hem kendisi hem onu çağıranlar (transitif). Metod çağrısının KENDİSİ
  HER ZAMAN kendi kontrolünü alır (`genMethodCall` hiç değişmedi).
- **`await`/`spawn` içeren gövdeler KOŞULSUZ güvensiz** — async istisna
  yayılımı zaten §3.21'de bilinçli olarak eksik bırakılmış bir alan,
  bu analiz oraya HİÇ dokunmadı.
- Bu iki kısıtlama SADECE optimizasyonun kapsamını daraltır (daha az
  kontrol elenir) — DOĞRULUĞU asla tehlikeye atmaz.

**Doğrulama (özellikle titiz — yanlış bir "asla raise etmez" sınıflandırması
istisnaları SESSİZCE yutabileceğinden):**
- `fib(38)`in derlenmiş QBE IR'ı GÖZLE doğrulandı — `nox_exception_pending`
  SIFIR kez geçiyor (tamamen elendi).
- Yeni golden testler: `indirect_raise_propagation.nox` (3 katmanlı,
  "güvenli görünen" ama TRANSİTİF olarak raise eden serbest fonksiyon
  zinciri, bir `try/except` ile doğru yakalanıyor — fixpoint'in yayılımını
  kanıtlar), `indirect_uncaught_exception.nox` (AYNI desen ama `try` OLMADAN
  — istisna 3 katman boyunca doğru şekilde ana `main`e kadar sızıp net bir
  hatayla sonlanıyor, sessizce yutulmuyor).
- Elle doğrulanan (golden test OLARAK eklenmeyen, ama sonucu/IR'ı gözden
  geçirilen) ek senaryolar: karşılıklı özyineleme (`is_even`/`is_odd`,
  10.000 derinlik) doğru çalıştı VE kontrolleri tamamen elendi.
- TÜM önceki `raise`/`try`/`except`/`finally` golden testleri (§3.7)
  DEĞİŞMEDEN yeşil kaldı.

**Ölçülen sonuç** (`zig build bench -Doptimize=ReleaseFast`, AYNI donanım):

| Alan | Önceki hızlanma (§3.24) | Yeni hızlanma |
|---|---|---|
| numeric_recursion (fib) | 15.2x | **26.0x** |
| oop_arc_churn | 11.5x | 13.3x |
| string_passing | 16.2x | **28.3x** |
| generics_protocols | 24.9x | 26.6x |
| list_traversal | 18.7x | 20.3x |
| exceptions_control_flow | 31.0x | 32.8x (DEĞİŞMEDİ — GERÇEKTEN raise ediyor, kontroller doğru şekilde KALDI) |

`exceptions_control_flow`in hızlanma oranının neredeyse HİÇ değişmemesi
(kontroller o senaryoda GERÇEKTEN gerekli olduğundan doğru şekilde
KALDIĞI için) optimizasyonun SEÇİCİ/doğru çalıştığının somut kanıtıdır —
yalnızca GERÇEKTEN gereksiz kontroller elendi.

**Kalan/ertelenen (bilinçli, bu fazda YAPILMADI):** metod çağrıları için
AYNI eleme (statik tip çıkarımı gerektirir — checker'ın tip bilgisini
codegen'e taşımak ayrı, daha büyük bir görev); `lowlevel` arena'nın
`nox_arena_create`/`destroy`ının kendi handle-tahsis overhead'i (ARC
havuzuna benzer bir arena-handle havuzu düşünülebilir, bu fazda
YAPILMADI — `lowlevel_arena` zaten 9.9x'te sabit kaldı, gelecekteki bir
faz için not edildi).

---

### 3.26 Alt-Faz A — Modül/`import` Sistemi (stdlib fazının temeli)

Kullanıcının isteği: Nox'un standart kütüphanelerini Nox'un KENDİSİYLE
yazmak (`nox.http` gibi, Python tarzı noktalı modül yolu). Bunun ön koşulu
olarak `import a.b` sözdizimi ve çok dosyalı derlemeyi TEK bir derleme
birimine (whole-program) birleştiren bir mekanizma eklendi.

**Sözdizimi:** `import nox.http` — Python'un `import a.b`si ile BİREBİR
aynı semantik: yerel kapsama `nox` adı girer, çağrı sitelerinde TAM noktalı
yol (`nox.http.get(url)`) kullanılır. `as`/`from ... import` v1 kapsamı
DIŞI (basitlik için ertelendi).

**Kritik basitleştirme — yeni bir AST ifade düğümü GEREKMEDİ:**
`nox.http.get(url)` sözdizimsel olarak zaten var olan `Attribute`/`Call`
zinciriyle ayrıştırılır. Çözümleme TAMAMEN checker seviyesinde yapılır —
Faz 10 generics'in "çağrı sitesindeki callee düğümünü mangled isme YERİNDE
yeniden yazma" tekniğiyle AYNI desen (bkz. `checker.zig`,
`tryResolveQualifiedCall`).

**Uygulama:**
- **Lexer/Parser** (`token.zig`, `parser.zig`, `ast.zig`): yeni `import`
  anahtar kelimesi, yeni `Stmt.import_stmt: ImportStmt { segments: [][]const u8 }`.
- **`compiler/module_loader.zig` (yeni dosya):** `resolveImports`,
  kullanıcının modülündeki `import` deyimlerini tarar, her segment
  zincirini `stdlib/<segments...>.nox` yoluna (proje köküne göre) eşler,
  o dosyayı (kendi `import`larını da ÖZYİNELEMELİ çözerek) ayrıştırıp TEK
  bir birleşik `ast.Module`da (kullanıcı kodundan ÖNCE) toplar — gerçek
  ayrı derleme birimi/nesne dosyası bağlama YOK, yalnızca AST seviyesinde
  birleştirme (AGENTS.md'nin "tek derleme birimi" modeliyle TUTARLI).
- **Ad çakışması önleme (mangling):** birleştirilen HER stdlib dosyasının
  KENDİ üst-düzey `func_def`/`class_def` adları (yalnızca bunlar — metodlar/
  `extern def`ler DEĞİL), noktalı yolla birleştirilmiş mangled isme
  (`nox.http` + `get` → `nox_http_get`) YENİDEN ADLANDIRILIR — hem tanım
  sitesinde hem stdlib dosyasının KENDİ İÇİNDEKİ tüm başvuru sitelerinde
  (çağrılar, `self: ClassName` DAHİL tip ifadeleri). Bu, kullanıcının aynı
  kısa adlı bir fonksiyon/sınıf tanımlamasıyla ÇAKIŞMAYI önler (checker'ın
  `self.functions`/`self.classes`i tek, düz bir ad alanı kullandığından).
  `extern def` bilinçli olarak YENİDEN ADLANDIRILMAZ (adı SABİT bir C ABI
  sembolüne bağlıdır — stdlib yazarları extern isimlerini elle çakışmasız
  seçmelidir).
- **Checker (`checker.zig`):** `imported_modules` kümesi (`checkModule`'ün
  `.import_stmt` kolunda doldurulur); `checkCall`'ın `.attribute` dalı
  ÖNCE `tryResolveQualifiedCall`ı dener — bir çağrının callee zinciri
  TAMAMEN `.identifier`/`.attribute`den oluşuyorsa noktalı bir yola
  düzleştirilir (`flattenDottedPath`), son segment HARİÇ kalan yol
  `imported_modules`da mı diye bakılır, eşleşirse TÜM yol mangled isme
  (`joinSegments`, `_` ile) çevrilip normal fonksiyon/kurucu çağrısı
  kontrolüyle doğrulanır VE **çağrı düğümünün callee'si YERİNDE düz bir
  `.identifier` düğümüne yeniden yazılır** — eşleşmezse (`null`) MEVCUT
  (değişmemiş) metod/örnek çözümlemesine düşülür.
- **Codegen'de HİÇBİR değişiklik GEREKMEDİ:** yeniden yazma sayesinde
  codegen sıradan bir serbest fonksiyon çağrısı görür — Faz 21/25'in
  optimizasyonları (exception-check elision DAHİL) stdlib fonksiyonlarına
  da OTOMATİK uygulanır.
- **`stdlib/` dizini:** proje köküne yeni bir dizin, `stdlib/nox/<modül>.nox`
  yapısında — kullanıcının kendi `.nox` dosyalarıyla AYNI v0.1 grameriyle
  yazılır.

**Doğrulama:** `stdlib/nox/testmod.nox` (mekanizmayı doğrulamak için
küçük, gerçek `nox.http`den ÖNCE yazılmış sahte bir modül — bir fonksiyonun
KENDİ modülü içindeki BAŞKA bir fonksiyonu/sınıfı çağırması dahil, iç
yeniden-adlandırmanın tutarlılığını sınar), golden testler:
`import_basic.nox` (nitelikli fonksiyon/sınıf çağrıları, iç modül içi
çapraz-başvurular), `import_name_collision.nox` (kullanıcının aynı adlı
KENDİ fonksiyonuyla ÇAKIŞMADIĞını kanıtlar). `zig build test` (Debug +
`-Doptimize=ReleaseFast`) yeşil; `noxc` CLI ile gerçek bir `.nox`
dosyasından uçtan uca derleme+çalıştırma DA elle doğrulandı.

**Bilinçli KAPSAM DIŞI (v1):** nitelikli TİP ANNOTASYONLARI (`x: nox.http.Foo`
gibi dotted tip ifadeleri) — `parseTypeExpr` yalnızca TEK bir tanımlayıcı
kabul eder, bu Alt-Faz sadece ÇAĞRI sitelerini çözer. Bir stdlib
fonksiyonunun döndürdüğü sınıf örneği yine de zincirleme çağrıyla
(`nox.mod.make_x().method()`) ya da (ADI QUALIFY EDİLMEDEN) örtük tip
çıkarımıyla kullanılabilir — yalnızca KULLANICI o tipi doğrudan bir
değişken tipi olarak NİTELİKLİ YAZAMAZ. Bu sınırlamanın giderilip
giderilmeyeceği `nox.http`nin (Alt-Faz D) API şekli netleştiğinde ayrıca
değerlendirilecek.

---

### 3.27 Alt-Faz B — `str` İşlemleri (Birleştirme + `len()`)

`nox.http` için gerekli ikinci temel: `str` üzerinde üretici bir işlem
(birleştirme) ve uzunluk sorgusu. Kapsam bilinçli olarak dar tutuldu —
yalnızca `+` ve `len(s) -> int`; alt string/`split`/`format`/`str(x)`
dönüşümü ERTELENDİ (ayrı bir `nox.strings` fazı için, bkz. onaylı plan).

**Kritik mimari değişiklik — `str` artık ARC-yönetimli:** `str` daha önce
"hep tahsissiz" bir tasarımdı (`isHeapManaged` yalnızca `.list`/`.class`
için `true` dönüyordu). Birleştirme YENİ bellek ürettiğinden `str`nin
gerçek bir ARC nesnesi olması gerekiyordu — bu GÜVENLE yapılabildi çünkü
string literalleri ZATEN `nox_rc_alloc`la AYNI başlık düzenini (8 baytlık
görünmez refcount) "pinned" (`PINNED_REFCOUNT`, asla sıfıra inmeyen) bir
değerle kullanıyordu (bkz. §3.24'ün `.string_lit` notu) — literal VE
dinamik (birleştirilmiş) string'ler AYNI retain/release koduyla, hiçbir
özel durum gerekmeden bir arada var olabiliyor.

**`isHeapManaged`e `.str` eklenmesinin GENİŞ etkisi (kasıtlı, minimal
invaziv):** bu TEK satırlık değişiklik, retain-on-alias (`retainIfAliasing`/
`emitInlineRetain`), release-on-scope-exit/reassignment (`releaseSlotIfSet`/
`releaseValueIfSet`), fonksiyon dönüş/parametre retain kuralları
(`returnNeedsRetain`), sınıf alanı release'i (`genClassRelease`'in alan
döngüsü) ve `lowlevel` kaçış engellemesi (`checkNoLowlevelEscape`) gibi
TÜM mevcut ARC makinesini `str` için de OTOMATİK devreye soktu — bu
fonksiyonların HİÇBİRİ değiştirilmedi, hepsi zaten `heap: HeapKind`
üzerinden JENERİKTİ. Yalnızca İKİ yer `str`e özgü (çünkü `list[T]`/sınıf
ŞEKLİNİ varsayıyorlardı):
- `releaseValueIfSet`e YENİ bir `heap == .str` dalı eklendi — `str`nin
  boyutu (`list[T]`nin AKSİNE) başlıkta SAKLANMAZ (literal/dinamik AYNI
  temsili paylaşabilsin diye), bu yüzden `listPayloadSize` (ilk 8 baytı
  "uzunluk" sayan) yoluna DÜŞMEMELİ — yeni `nox_str_release` çağrılır (bkz.
  aşağı).
- `isTemporaryExpr`e `.binary` eklendi (`.call`/`.list_lit`in yanına) —
  bir `str + str` TAZE bir heap değeri ürettiğinden (`.call` sonucuyla
  AYNI muamele), `print(a + b)` gibi kullanımlarda geçici sonucun sızmadan
  serbest bırakılması İÇİN gerekli. Diğer ikili operatörler zaten
  `heap = .none` ürettiğinden (çağıran taraftaki `isHeapManaged(v.heap)`
  eşlik kontrolü ONLARI zaten eler) bu değişiklik KOŞULSUZ güvenlidir.

**Yeni çalışma zamanı (`runtime/str.zig`):**
- `nox_str_concat(rt, a, b) -> ptr`: `strlen(a)+strlen(b)` hesaplar,
  `nox_rc_alloc` (AYNI ARC/havuz yolu — bkz. §3.24 performans fazı) ile
  tahsis eder, `memcpy`ler, sıfırla sonlandırır.
- `nox_str_release(rt, ptr)`: `nox_rc_release`in AKSİNE `payload_size`i
  ÇAĞIRANDAN ALMAZ — `strlen` ile KENDİSİ hesaplar (`nox_rc_predecrement`
  + koşullu `nox_rc_free_payload`). Bu, `str`in boyutunu başlıkta
  saklamama tasarım kararının DOĞRUDAN sonucu.
- `runtime/alloc/arc.zig`'in `nox_rc_alloc`/`nox_rc_retain`/
  `nox_rc_predecrement`/`nox_rc_free_payload`si `pub export fn` yapıldı
  (önceden yalnızca `export fn` — Zig'in KENDİ modül sistemi düzeyinde
  `pub` OLMAYAN bir `export fn` başka bir `.zig` dosyasından ÇAĞRILAMAZ,
  yalnızca C ABI sembolü olarak dışa açılır; bu, `runtime/str.zig`'in
  bunları Zig düzeyinde çağırabilmesi için gerekli bir ön koşuldu).

**Codegen (`codegen_qbe/codegen.zig`):** `genBinary`e `str + str` dalı
eklendi (`genStrCompare`nin YANINA, AYNI desen) — `nox_str_concat` çağırıp
`heap = .str` taze bir `Value` döner, sonra iki operandı da
`releaseIfTemporary` ile telafi eder (zincirleme birleştirmede — `a+b+c`
— ara sonuçların doğru serbest bırakılmasını sağlar). `len(s)`: `print`/
`range` ile AYNI özel-işlenen yerleşik kalıbı (checker + codegen'in
`genCall`inde), doğrudan libc'nin `strlen`ine lowerlanır (dönüşüm
gerekmez — `str` zaten sıfırla-sonlanan bir `l` işaretçisi).

**Bilinçli yan etki (kapsam dışına ALINMADI, ama not edilmesi gereken):**
`checkNoLowlevelEscape` (bir `lowlevel` bloğu içinde heap tipli hiçbir
değerin çağrıya argüman/dönüş/takma ad OLAMAYACAĞINI zorlayan MEVCUT,
DEĞİŞMEMİŞ kural) artık `str`i de kapsıyor — `lowlevel` içinde bir string'i
başka bir fonksiyona argüman olarak geçirmek veya birleştirmek artık
REDDEDİLİR (önceden `str` heap-yönetimli SAYILMADIĞINDAN serbestti).
`print(str)` bu kısıtlamaya TABİ DEĞİL (print hiç `checkNoLowlevelEscape`
çağırmaz) — yalnızca ÇAĞRI/birleştirme etkilenir. Mevcut hiçbir golden test
`lowlevel` + `str`i birlikte kullanmadığından bu bir REGRESYON değil,
list/class'la ZATEN tutarlı, bilinçli bir tasarım kararı (basitlik/güvenlik
için — bkz. §3.8'in `lowlevel` notu).

**Doğrulama:** golden testler `str_concat_basic.nox` (zincirleme
birleştirme + `len()`, sızıntı yok), `str_concat_reassignment_frees_old.nox`
(yeniden atamanın eskiyi doğru serbest bıraktığını — `list_reassignment_
frees_old.nox` İLE AYNI desen — kanıtlar), `str_len.nox`. `zig build test`
(Debug + `-Doptimize=ReleaseFast`) yeşil; `runtime/str.zig`'in kendi birim
testleri (birleştirme doğruluğu + gerçek serbest bırakma, DebugAllocator
doğrular); `noxc` CLI ile gerçek bir `.nox` dosyasından uçtan uca
derleme+çalıştırma (birleştirme + takma ad + yeniden atama, sızıntı yok)
DA elle doğrulandı.

---

### 3.28 Alt-Faz C — `dict[K, V]` Builtin Tipi

`nox.http` için üçüncü ve son temel: header/query-param gibi anahtar-değer
verisi için GERÇEK bir builtin dict tipi (kullanıcıyla konuşulup class+list
geçici çözümü YERİNE bu tercih edilmişti).

**Sözdizimi:** `list[T]`nin AYNI kalıbı — `d: dict[str, int] = {"a": 1}`
(dolu literal, Python'a benzer `{k: v, ...}`). Erişim `d[key]`/`d[key] = value`
(mevcut `Index`/`Assign` düğümleri, dict için YENİ anlamla — `list[T]`
İÇİN indeksli ATAMA hâlâ desteklenmiyor, bu YENİ bir kısıtlama DEĞİL, ZATEN
var olan bir v0.1 sınırlaması). Yerleşik metodlar: `d.contains(key) -> bool`,
`d.len() -> int` (`Channel[T].send/recv` İLE AYNI "özel işlenen yerleşik"
kalıbı). **Boş `{}` DESTEKLENMEZ** — boş `list_lit` (`[]`) İLE AYNI
gerekçeyle (checker PURELY bottom-up tip çıkarımı yapar, hiçbir bidirectional/
target-typed literal inference makinesi YOK) — bu, plan taslağındaki
`d: dict[str, int] = {}` örneğinden BİLİNÇLİ bir sapmadır, ama codebase'in
ZATEN var olan tutarlı tasarımıyla ÖRTÜŞÜR.

**v1 kapsamı bilinçli olarak dar — yalnızca `K` int/bool/str, `V` int/float/
bool/str:** sınıf anahtar/değer ERTELENDİ. Bunun İKİ ayrı gerekçesi var:
1. `K` sınıf OLAMAZ — hashlenebilir olması için içerik-tabanlı eşitliğe
   ihtiyaç var (bkz. aşağı), sınıflar için bu TANIMSIZ (Python'daki gibi
   `__hash__`/`__eq__` override mekanizması Nox'ta YOK).
2. `V` sınıf OLAMAZ — bu SALT mühendislik zamanı kısıtlaması: sınıf
   değerlerin release'i `$ClassName_release`e bir fonksiyon POINTER'I
   geçirmeyi gerektirirdi (QBE sembolleri C ABI fonksiyonlarıdır, bu
   mümkün olurdu), ama bu, dict'in KENDİSİNİN K/V'ye GÖRE parametrik
   PAYLOAD tipini (int/float/bool/str hepsi 8 bayt, sınıf da 8 bayt bir
   POINTER, temsilen SORUN değil) DEĞİL, spesifik olarak "hangi release
   fonksiyonu çağrılacak" bilgisini runtime'a taşımayı gerektiren AYRI bir
   iş — bu artımda kapsam dışı bırakıldı, `nox.http`nin (Alt-Faz D) gerçek
   ihtiyacı netleştiğinde ayrıca değerlendirilecek.

**Kritik mimari karar — hash tablosu DEĞİL, doğrusal arama:** `runtime/
collections/dict.zig`, Zig'in `std.HashMap`ı yerine `std.ArrayListUnmanaged(
Entry)` üzerinde DOĞRUSAL arama kullanır. Gerekçe: `std.HashMap` ÇALIŞMA
ZAMANINDA seçilen bir anahtar türü (int'e karşı str, hangisi olduğu bir
`.nox` dosyasının derlenme anına kadar bilinmiyor) için özel bir context
(comptime tip + runtime state karışımı) gerektirir — bu, doğrulanması riskli
bir Zig API yüzeyiydi. v1'in stdlib dict'leri (header/query-param gibi)
küçük hacimli olduğundan O(n) arama KABUL EDİLEBİLİR bir ödünleşimdir;
gerçek bir hash tablosuna geçiş AYRI bir performans fazı için not edilmiştir.

**`dict`in KENDİSİ ARC-yönetimli DEĞİLDİR** — `Task[T]`/`Channel[T]` İLE
AYNI "tek sahiplilik" modeli (`HeapKind.dict`, `isHeapManaged`in DIŞINDA):
opak bir `ptr`, kapsam sonunda DOĞRUDAN `nox_dict_destroy` (predecrement/
retain YOK). **Bilinçli v0.1 sınırlaması** (Task/Channel'la TUTARLI):
yeniden atamada (`d = {...}` tekrar) eski dict BURADAN geçmez, sızar.

**`str` anahtar/değerlerin ARC disiplini — `nox_str_release`in doğrudan
yeniden kullanımı:** dict'in KENDİSİ ARC-dışı olsa da İÇİNDEKİ `str`
anahtar/değerler GERÇEKTEN retain/release edilir. Disiplin `genAssign`in
"eskiyi oku, serbest bırak, yeniyi yaz" desenini birebir izler:
- **Ekleme/atama** (`genDictLit`/`genDictAssign`, codegen tarafında):
  anahtar/değer `retainIfAliasing` ile (list_lit İLE AYNI desen) retain
  edilir, SONRA `nox_dict_set`e OLDUĞU GİBİ geçirilir — runtime KENDİSİ
  hiçbir retain YAPMAZ, sahiplik ÇAĞIRANDAN devralınır.
- **`nox_dict_set` (runtime, üzerine yazma durumu):** anahtar ZATEN
  varsa, ESKİ anahtar/değeri (`str` iseler) `nox_str_release` ile serbest
  bırakır, SONRA yeni ikiliyi saklar.
- **`nox_dict_get` (runtime, okuma):** BORROWED bir okumadır (`list[T]`
  eleman okumasıyla AYNI semantik) — dönen `str` değer RETAIN EDİLMEZ,
  dict sahipliği korur. Anahtar YOKSA `0` döner (**Python'ın `KeyError`ı
  YOK** — bilinçli v1 sınırlaması).
- **`nox_dict_destroy`:** TÜM `str` anahtar/değerleri (varsa) serbest
  bırakır, SONRA belleğin kendisini serbest bırakır.

**`str` anahtarların İÇERİK eşitliği:** anahtarlar HER ZAMAN bir `i64`
"payload" olarak saklanır (int/bool doğrudan, `str` işaretçi olarak —
`toPayload`/`fromPayload`, Task/Channel'ın ZATEN çözdüğü AYNI teknik
doğrudan yeniden kullanıldı). `str` anahtarlar İÇİN eşitlik POINTER
DEĞİL, `std.mem.orderZ` ile İÇERİK karşılaştırmasıdır (`strcmp` ile AYNI
semantik) — golden test `dict_str_key_basic.nox` bunu AÇIKÇA kanıtlar
(bir literal anahtarla eklenen değer, POINTER'ı FARKLI ama İÇERİĞİ AYNI
dinamik bir string ile `contains`/indeksleme/üzerine-yazma yoluyla doğru
bulunur).

**Yan keşif ve düzeltme — `list[str]` eleman release'i (Alt-Faz B'nin
bıraktığı bir boşluk):** bu fazda çalışırken, `list[T]`nin elemanları
`str` OLDUĞUNDA (`Faz 21 ön-koşulu`nun ZATEN çözdüğü sınıf/iç-içe-liste
elemanlarının AKSİNE) kapsam sonunda/yeniden atamada HİÇ release
edilmediği (bir sızıntı) fark edildi — Alt-Faz B `str`i ARC-yönetimli
yaptığında (`isHeapManaged`e `.str` eklendiğinde) `list[str]` elemanlarının
da bu garantiye girmesi GEREKİYORDU ama `resolveType`/`genListLit`nin
`elem_heap_info` inşası yalnızca `.class`/`.list` elemanları için
tetikleniyordu. **Düzeltme:** bu üçü `.str`i de kapsayacak şekilde
genişletildi; `genListElemRelease`in İÇ (nested) eleman release ÇAĞRISI,
`.str` elemanlar İÇİN sentetik bir `$str_release` sembolü YERİNE doğrudan
`nox_str_release`e yönlendirilecek şekilde ÖZEL durum eklendi (`releaseFnNameFor`
yalnızca dış `$List_str_release` sembolünün ADINI üretmek için "str" etiketini
döner, gerçek release çağrısı bu etiketi KULLANMAZ). Bu değişiklik `eqMangleFor`ı
(derin yapısal eşitlik) da etkiledi — `elem_heap_info` artık str için de
dolu olduğundan, o fonksiyonun KENDİ switch'ine de bir `.str => "str"` dalı
eklenmesi gerekti (aksi halde `unreachable`e düşüp panikliyordu — bu, ilk
`zig build test` çalıştırmasında YAKALANDI, `list[T]/sınıf için derin
yapısal eşitlik` golden testi çökerek).

**Doğrulama:** golden testler `dict_int_key_basic.nox` (literal, indeksleme,
`contains`/`len`, üzerine yazma), `dict_str_key_basic.nox` (içerik eşitliği),
`dict_str_key_str_value_arc.nox` (str anahtar/değer ARC doğruluğu — sınıf
değer v1 kapsamı DIŞI bırakıldığından plandaki `dict_class_value.nox`
YERİNE bu tercih edildi, ama AYNI temel riski — heap-yönetimli dict
içeriğinin doğru retain/release'i — sınar). `zig build test` (Debug +
`-Doptimize=ReleaseFast`) yeşil; `runtime/collections/dict.zig`'in kendi
birim testleri (int/str anahtar, üzerine yazma, DebugAllocator sızıntı
doğrulaması); `noxc` CLI ile gerçek bir `.nox` dosyasından uçtan uca
derleme+çalıştırma DA elle doğrulandı.

---

### 3.29 D.0 — Async I/O Reaktörü (kqueue): `nox.http`in runtime ön koşulu

`nox.http`in (D.1) tam tasarımı için kullanıcıyla ayrı bir planlama turu
yapıldı; üç mimari karar netleşti (kapsam: istemci+sunucu birlikte; hata
modeli: gerçek bir Nox exception'ı — `hpy_call`/`wasm_call`in "0 dön"
pragmatik deseni YERİNE; header tipi: Alt-Faz C'nin `dict[str, str]`i).
Ama sunucunun eşzamanlılık modeli tartışılırken **kritik bir teknik kısıt**
ortaya çıktı: `runtime/async_rt`in Faz 21'de tamamlanan zamanlayıcısı
(`fiber.zig`/`scheduler.zig`) yalnızca Task/Channel senkronizasyon
noktalarında kooperatif geçiş yapıyordu — **gerçek G/Ç hazır-olma
(epoll/kqueue) entegrasyonu YOKTU.** M:1 modelde (tek OS iş parçacığı) bir
fiber bloklayan bir `read()`/`accept()` sistem çağrısı yaptığında TÜM
işlem (zamanlayıcı DAHİL) bloke olur — "her bağlantıyı bir `spawn` ile
işle" TEK BAŞINA gerçek eşzamanlı G/Ç çakışması SAĞLAMAZ. Kullanıcıya bu
kısıt sunuldu; **gerçek async G/Ç ÖNCE zamanlayıcıya entegre edilsin**
kararı verildi — bu bölüm o fazı (D.0) tanımlar; `nox.http`in kendisi
(D.1) bu faz TAMAMLANDIKTAN SONRA, kendi kısa planlama turuyla ele
alınacak.

**Kapsam (v0.1, bilinçli dar — `fiber.zig`nin "yalnızca aarch64"
kısıtlamasıyla TUTARLI, bkz. onun modül üstü notu):** yalnızca **macOS
(kqueue)** — epoll (Linux) bu fazın DIŞINDA.

**`runtime/async_rt/io_reactor.zig` (yeni dosya):** `std.c.kqueue()`/
`std.c.kevent()` üzerine ince bir sarmalayıcı (`IoReactor`) — Zig'in KENDİ
`std.Io.Threaded`/`std.Io.Kqueue`sinin (bu Zig sürümünde, `std.posix`te
YÜKSEK SEVİYE bir `kevent`/`kqueue` sarmalayıcısı YOK, keşfedildi) AYNI ham
`posix.system.*` + `posix.errno` desenini elle uygular. `register(fd,
filter, waiter: *Fiber)`, `EV_ADD | EV_ONESHOT` ile kaydeder — `EV_ONESHOT`
KRİTİK: bir olay ateşlenince kqueue kaydı KENDİLİĞİNDEN kaldırır, `unregister`
mantığına HİÇ gerek KALMAZ (her `EAGAIN` sonrası `runtime/async_rt/io.zig`
zaten YENİDEN `register` çağırır). `poll(scheduler)` en az bir olay hazır
olana kadar BLOKE OLUR (`timeout=null`), her olayın `udata`sındaki fiber'ı
`scheduler.markReady(...)` ile hazır kuyruğa ekler (`scheduler` parametresi
KASITLI OLARAK `anytype` — `io_reactor.zig`nin `scheduler.zig`ye TAM tip
bağımlılığı OLMADAN yalnızca `markReady(*Fiber) void` imzasına GÜVENMESİ
için).

**`Scheduler` değişiklikleri (`scheduler.zig`):** yeni `reactor: IoReactor`
alanı (`init` artık `!Scheduler` — `kqueue()` teorik olarak
başarısız olabilir, `bridge.zig`nin `nox_async_init`i bunu `nox_rc_alloc`ın
`null` dönmesiyle AYNI "son derece nadir kaynak tükenmesi" muamelesiyle
`@panic` eder); yeni `waiting_on_io: usize` sayacı; yeni `suspendForIo(fd,
filter)` — `suspendCurrent` İLE AYNI çağıran-fiber varsayımıyla, ama ÖNCE
reaktöre kaydolup `waiting_on_io`yu artırır, fiber TEKRAR çalıştırıldığında
azaltır. **`run()`ün deadlock kararı GENİŞLETİLDİ** (bu, D.0'ın ÖZÜ):
hazır kuyruk boşken ARTIK İKİ olası durum var — TÜM canlı görevler Task/
Channel'da tıkanmış (GERÇEK deadlock, DEĞİŞMEDEN `error.Deadlock`) ya da
bir/daha fazla görev bir G/Ç olayı BEKLİYOR (`waiting_on_io > 0`) — bu
durumda YAPACAK BAŞKA İŞ olmadığından `reactor.poll` BLOKLAYARAK çağrılır,
en az bir fiber'ı hazır kuyruğa geri koyar VE döngü DEVAM eder.

**`runtime/async_rt/io.zig` (yeni dosya) — non-blocking soket ilkelleri:**
`nonBlockingAccept`/`nonBlockingRead`/`nonBlockingWrite` — HER biri: soketi
`fcntl`/`O.NONBLOCK` ile non-blocking yapar, işlemi dener; `EAGAIN` alırsa
`scheduler.suspendForIo` ile askıya alıp UYANINCA TEKRAR dener (bir
döngüde) — GERÇEK sonuç alınana ya da gerçek bir hataya kadar. Bu dosyadaki
`pub fn`lar **Nox diline/checker'a/codegen'e HİÇBİR değişiklik GETİRMEZ**
(`export fn` DEĞİLDİR, saf runtime altyapısı) — `nox.http`in (D.1) Zig
kabuğunun (`runtime/stdlib_shims/http.zig`) DOĞRUDAN kullanacağı temel
taşlardır.

**Doğrulama (özellikle titiz — bu, "yapısal spawn ama pratikte sıralı"
ile "gerçek çakışan G/Ç" arasındaki FARKIN somut kanıtı olmalı):**
`io_reactor.zig`nin kendi birim testi (bir soket çiftinde yazma tarafının
okuma tarafını `poll` aracılığıyla doğru bildirdiğini kanıtlar).
`io.zig`nin `nonBlockingRead`/`nonBlockingWrite` testi — İKİ fiber, biri
(`reader`) henüz gelmemiş veri BEKLERKEN askıya alınır, DİĞERİ (`writer`)
BU SIRADA çalışıp tamamlanır (paylaşılan bir günlükle SIRA KANITLANIR:
"writer çalıştı" HER ZAMAN "reader tamamlandı"dan ÖNCE), SONRA reader
kqueue aracılığıyla uyanıp veriyi doğru okur. **Kasıtlı boz → kırmızıyı
doğrula ritüeli:** `run()`ün `waiting_on_io` dalı GEÇİCİ OLARAK kaldırılıp
test çalıştırıldığında, test doğru şekilde `error.Deadlock` ile
BAŞARISIZ OLDU (eski davranışın bu senaryoda GERÇEKTEN çalışmayacağının
kanıtı) — SONRA geri eklendi, yeşile döndü. MEVCUT "dairesel await"
(Task/Channel deadlock tespiti) testi DEĞİŞMEDEN yeşil kaldı
(`waiting_on_io` hep `0` olduğu senaryolarda davranış AYNI). `zig build
test` (Debug + `-Doptimize=ReleaseFast`) yeşil; MEVCUT bir async golden
testi (`async_channel.nox`) `noxc` CLI ile uçtan uca yeniden derlenip
çalıştırıldı — DEĞİŞMEDEN doğru sonuç verdi.

---

### 3.30 D.1.1/D.1.2 — `nox.http` Ön Koşulları: `with_rt` + `dict[str,str]` FFI

D.0 tamamlandıktan sonra `nox.http`in tam tasarımı için ikinci bir planlama
turu yapıldı (bkz. plan dosyası) — BEŞ teknik keşif ortaya çıktı, bunlardan
İKİSİ (D.1.1, D.1.2) bu bölümde, KÜÇÜK ama TEMEL ön koşullar olarak
tamamlandı.

**D.1.1 — `extern def ... with_rt` (RT_PARAM opt-in):** `extern def`
bilinçli olarak `RT_PARAM`ı (allocator/ARC bağlamı) GEÇİRMEZ (Faz 20'nin
"ARC-izlenmeyen opak" tasarımı) — ama `nox.http`in Zig kabuğunun ARC-yönetimli
`str` (ve `dict`) DEĞERLERİ üretebilmesi İÇİN `rt`ye erişmesi GEREKİR. Yeni,
GERİYE DÖNÜK UYUMLU bir opsiyonel sözdizimi işareti eklendi: `extern def
name(...) -> T from "lib" with_rt` (`compiler/lexer/token.zig`ye yeni
`kw_with_rt`, `ast.ExternDef`e `needs_rt: bool = false` alanı, `parser.zig`
`from "lib"`den SONRA opsiyonel olarak tüketir). Yalnızca bu işareti TAŞIYAN
extern def'ler İÇİN `codegen_qbe/codegen.zig`nin `genCall`i (`extern_functions`
dalı) `RT_PARAM`ı argüman listesinin BAŞINA GİZLİCE ekler (normal fonksiyon
çağrılarıyla AYNI kalıp, bkz. `FuncSig.needs_rt`) — Zig tarafındaki
fonksiyonun İLK parametresi `rt: ?*anyopaque` OLMALIDIR. **Checker'da HİÇBİR
değişiklik GEREKMEDİ** — `needs_rt` PÜR bir codegen/ABI kaygısıdır, checker
yalnızca Nox-görünür TİP imzasıyla ilgilenir. Mevcut TÜM `extern def`ler
(`counter.c`, HPy/WASM köprüleri) `needs_rt` varsayılan `false` olduğundan
DEĞİŞMEDEN çalışmaya devam eder.

**D.1.2 — `dict[str, str]` FFI-güvenli hâle getirme:** Alt-Faz C'nin
`isFfiSafeType`i `.dict`i KOŞULSUZ reddediyordu; şimdi K/V'nin İKİSİ DE
`str` olduğu somut örnekleme İÇİN `true` döner (çalışma zamanı temsili
ZATEN opak bir `ptr` olduğundan, `HeapKind.dict`, ARC başlığı YOK — bu
güvenlidir). `runtime/collections/dict.zig`nin TÜM dışa açık fonksiyonları
(`nox_dict_new/set/get/contains/len/destroy`) VE `Dict`/`Entry` struct'larının
KENDİLERİ `pub` yapıldı — `nox.http`in (D.1.3/D.1.4) Zig kabuğu bunları
DOĞRUDAN Zig seviyesinde çağırabilsin/`Dict.entries`i gezebilsin diye (Nox
tarafında YENİ bir "dict iterasyonu" sözdizimi — `for k in d` — GEREKMEDEN,
v0.1'in first-class iterasyon protokolü eksikliğine dokunmadan).

**Doğrulama (`tests/compat/extern_ffi_test.zig` + `tests/compat/zig_ext/util.zig`,
Faz 20'nin GERÇEK-Zig-dosyası FFI test altyapısıyla AYNI desen):**
- `nox_test_make_greeting` (util.zig'e eklendi): `rt` üzerinden `nox_rc_alloc`
  çağırıp GERÇEKTEN ARC-yönetimli bir `str` üretir — `with_rt` işaretli bir
  `extern def` bunu çağırıp `print`e verir; DebugAllocator sızıntı
  BULAMADI (doğru serbest bırakma kanıtı).
- `nox_test_dict_lookup`: bir `dict[str, str]` handle'ını (Nox'tan
  DOĞRUDAN argüman olarak) alıp `nox_dict_get`i (noxrt.o'nun ZATEN dışa
  açtığı) çağırarak içeriği okur — BORROWED okumayı Nox'a devrederken
  `nox_rc_retain` ile AÇIKÇA retain eder (aksi halde `print`in serbest
  bırakması dict'in KENDİ referansını da geçersiz kılardı — bu, `nox.http`in
  yanıt başlıkları döndürürken izleyeceği TAM desen).
- Her iki test de "kasıtlı boz → kırmızıyı doğrula → düzelt" ritüeliyle
  doğrulandı; `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil;
  `noxc` CLI ile gerçek `.nox` dosyalarından uçtan uca derleme+çalıştırma
  DA elle doğrulandı.

---

### 3.31 D.1.3 — `nox.http` İstemci Zig Kabuğu (`runtime/stdlib_shims/http_client.zig`)

**Mimari:** `std.http.Client`ı DOĞAL (bloklayan) haliyle kullanır (D.0'ın
kqueue reaktörüne uyarlamak `std.http.Client`in KENDİ `std.Io` soyutlamasını
TAMAMEN yeniden uygulamayı gerektirirdi, bkz. §D.1 planının "Keşif 2"si), ama
HER isteği GERÇEK bir arka plan OS iş parçacığında (`std.Thread.spawn`,
`detach()`) çalıştırır. ÇAĞIRAN taraf bir "tamamlanma pipe'ı" (self-pipe
tekniği) üzerinden bekler: `bridge.currentFiberScheduler()` (bkz. §D.0) `null`
DEĞİLSE (bir Nox fiber'ı İÇİNDEYSEK), D.0'ın `io.zig`sinin `nonBlockingRead`i
ile askıya alınır — BAŞKA fiber'lar bu sırada GERÇEKTEN ilerleyebilir
(thread-per-request eşzamanlılık); `null` İSE (senkron, `async` hiç
kullanmayan bir Nox betiği — zamanlayıcı hiç İLKLENMEMİŞTİR) sıradan
bloklayan bir `read()` yeterlidir (korunacak BAŞKA bir fiber YOK). Bu, AYNI
`nox_http_get_raw`/`nox_http_post_raw` fonksiyonunun HER İKİ bağlamda da
(fiber içi/dışı) doğru çalışmasını sağlar.

**v1 bilinçli sınırlaması — düşük seviye API:** `std.http.Client.fetch`in
kolaylık sarmalayıcısı YERİNE `client.request`/`sendBodiless`/
`sendBodyUnflushed`/`receiveHead`/`iterateHeaders`/`reader().streamRemaining`
API dizisi kullanılır — kullanıcının "yanıt başlıkları da dahil edilsin"
kararı İÇİN GEREKLİ (`fetch()`in dönüşü yalnızca `status` taşır, header'lara
ERİŞEMEZ). Bedeli: OTOMATİK yönlendirme takibi VE otomatik sıkıştırma çözme
YOK (`redirect_behavior = .unhandled`, gövde HAM okunur) — bilinçli, dokümante
edilmiş bir v1 kapsam daraltması.

**KRİTİK keşif — `std.Io.Threaded.init` SÜREÇ-GENELİ bir sinyal işleyicisi
kurar:** İlk uygulamada HER istek İÇİN (`workerThreadFn` içinde) YENİ bir
`std.Io.Threaded.init(...)` örneği oluşturulup istek bitince `deinit()`
ediliyordu. Bu, Zig'in `std.Io.Threaded.init`inin (bkz. Zig std kaynağı)
`posix.sigaction(.IO, &act, &t.old_sig_io)` ile SÜREÇ-GENELİ bir `SIGIO`/
`SIGPIPE` işleyicisi KURDUĞU (ÖNCEKİ işleyiciyi ÖRNEĞE ÖZGÜ bir alana
kaydederek) gerçeğiyle ÇAKIŞTI: `zig build test`in `--listen=-` modu (build
sisteminin protokol G/Ç'si İÇİN, `test_runner.zig`, KENDİ `Io.Threaded.
global_single_threaded` adlı SÜREÇ-GENELİ tekil örneğini kullanır) altında,
HER istekte bu işleyicinin kurulup SÖKÜLMESİ, test çalıştırıcısının KENDİ
işleyicisiyle NADİR ama GERÇEK bir yarış durumuna yol açtı — yalnızca
`--listen=-` altında (ASLA düz `zig test` altında) yeniden üretilebilen,
zamanlamaya bağlı bir `SIGSEGV` (`0x8` adresinde) ile SONUÇLANDI. **Çözüm:**
test çalıştırıcısının KENDİ deseniyle AYNI — atomik durum makinesiyle tembel
ilklenen, HİÇBİR ZAMAN `deinit()` EDİLMEYEN (süreç bitince OS geri alır,
`asap.zig`'in Release modu ARC havuzuyla AYNI felsefe) TEK, PAYLAŞILAN bir
`std.Io.Threaded` örneği (`sharedClientIo()`) — HER isteğin arka plan iş
parçacığı bunu KULLANIR, kendi KOPYASINI oluşturmaz.

**Yanıt tutamacı:** `nox_http_response_status/body/headers/free` erişimci
`extern def`leri — `body`/`headers` DÖNÜŞLERİ tutamaçtan BAĞIMSIZ, YENİ (`rt`
üzerinden tahsis edilmiş) ARC nesneleridir (`headers` İÇİN D.1.2'nin `pub`
yapılmış `nox_dict_new`/`nox_dict_set`i DOĞRUDAN kullanılır) — `nox_http_
response_free` ile tutamacın KENDİSİ serbest bırakıldığında bunlar ETKİLENMEZ.

**İKİNCİ, DAHA DERİN keşif — `DebugAllocator`in yığın-izi yakalaması bir
Nox fiber'ının SAHTE önyükleme çerçevesinin ÖTESİNE geçemez:** yukarıdaki
sinyal-işleyici hatası düzeltildikten SONRA bile (D.1.4 çalışması sırasında,
`http_server.zig` eklenip binary boyutu/zamanlaması KAYDIĞINDA) AYNI adreste
(`0x8`) bir `SIGSEGV` YENİDEN ORTAYA ÇIKTI — `lldb` ile GERÇEK bir yığın izi
alınarak (bkz. AGENTS.md'nin `sample`/`lldb -p PID` ile "gerçekten neyin
BEKLEDİĞİNİ göster" tekniği) KÖK NEDEN bulundu: çökme, `nox_http_response_free`
İÇİNDE `gpa.free(...)` çağrılırken OLUYORDU (`gpa` = testin `DebugAllocator`ı)
— VE çöken belleğin İÇERİĞİ `0xaa` (Zig'in "serbest bırakılmış bellek"
zehir deseni) idi, yani bu ZATEN bir kez serbest bırakılmış bir bloğun
İKİNCİ kez serbest bırakılması gibi GÖRÜNÜYORDU. Gerçek neden ise ÇOK daha
temel: `DebugAllocator` (varsayılan `stack_trace_frames = 6` ile) HER
`alloc`/`free`de bir GERİ İZİ YAKALAMAYA çalışır; testin çağrısı
`nox_http_response_free` ÇOK SIĞ bir fiber çağrı zincirinin İÇİNDEN (`Fn.
requestOne` → `Task.entryTrampoline` → `fiber.trampoline` — yalnızca 3-4
GERÇEK çerçeve) yapılıyordu — `fiber.zig`nin KENDİ testinin belge notunun
AÇIKÇA UYARDIĞI gibi ("fiber yığınındaki ilk (bootstrap) çerçevenin fp/lr'si
GERÇEK bir çağrı zincirini TEMSİL ETMEZ"), 6 çerçeve istenip yalnızca 3-4
GERÇEK çerçeve mevcut olunca, geri-izi yakalayıcı fiber'ın SAHTE önyükleme
çerçevesinin fp/lr'sini GERÇEK sanıp izlemeye devam eder ve geçersiz belleğe
düşer — `SIGSEGV`. Çökme İŞLEYİCİSİNİN KENDİSİ de (ayrıca) bir yığın izi
basmaya çalışırken AYNI soruna (VE bir `Io.Mutex` kilitlenmesine) düşüp
SONSUZA dek "asılı" görünmesine yol açtı (bu YÜZDEN önceki oturumlarda
"hang" ile "segfault" birbirine KARIŞTIRILDI — çökme işleyicisinin kendisi
çöküyordu). **Bu, `nox_http_response_free`nin (ya da GERÇEK derlenmiş bir
Nox programının) bir HATASI DEĞİLDİR** — QBE'nin ürettiği GERÇEK bir çağrı
zinciri (main → async çalıştırıcı → fiber sarmalayıcı → kullanıcı kodu →
extern def çağrısı → ...) HER ZAMAN 6 çerçeveden ÇOK daha derindir; bu
yalnızca testin elle yazılmış, KASITLI OLARAK minimal çağrı zincirinin bir
ARTEFAKTI. **Çözüm:** testin KENDİSİ `nox_http_response_free`i fiber'ın
İÇİNDEN DEĞİL, testin normal (derin) çağrı yığınından — `bridge.
nox_async_await` döndükten SONRA — çağıracak şekilde YENİDEN düzenlendi
(yanıt tutamacı `Fn.resp_handle`de saklanır, fiber yalnızca durumu döner).

**Doğrulama:** iki Zig birim testi (`runtime/stdlib_shims/http_client.zig`):
(1) ham POSIX soketlerle (D.0'ın `io.zig`si İLE AYNI desen) elle kurulmuş
GERÇEK bir yerel HTTP sunucusuna senkron (fiber DIŞI) bir `nox_http_get_raw`
çağrısı — durum/gövde/başlık doğru okunur; (2) AYNI çağrı bir Nox fiber'ı
İÇİNDEN yapılır (`bridge.nox_async_spawn`) VE eşzamanlı İKİNCİ bir fiber
(sunucudan yanıt BEKLENİRKEN) GERÇEKTEN ilerleyebildiğini kanıtlar (D.0'ın
`nonBlockingRead` testiyle AYNI "sıra kanıtı" deseni: diğer fiber, istek
fiber'ından ÖNCE tamamlanır). Her ikisi de "kasıtlı boz → kırmızıyı doğrula →
düzelt" ritüeliyle doğrulandı. `zig build test` (Debug + `-Doptimize=
ReleaseFast`, HEM varsayılan paralellikte HEM `-j1`/`--listen=-` protokolüyle,
HER İKİ hatanın da YENİDEN ORTAYA ÇIKMADIĞI ardışık ÇOK SAYIDA çalıştırmayla
DOĞRULANARAK) yeşil.

---

### 3.32 D.1.4 — `nox.http` Sunucu Zig Kabuğu (`runtime/stdlib_shims/http_server.zig`)

**Mimari — GERÇEK fiber-native eşzamanlılık (istemciden FARKLI):** istemci
kabuğunun (D.1.3) aksine arka plan İŞ PARÇACIĞI KULLANILMAZ. D.0'ın
`io.zig`sindeki `nonBlockingAccept`/`nonBlockingRead`/`nonBlockingWrite`
üzerine KÜÇÜK, özel bir `std.Io.Reader`/`Writer` (`FiberReader`/`FiberWriter`
— YALNIZCA ZORUNLU `stream`/`drain` alanlarını uygular, bkz. Zig'in KENDİ
`Io/net.zig` soket Reader/Writer'ıyla AYNI desen) inşa edilip DOĞRUDAN
`std.http.Server`e beslenir — bu, `receiveHead`/gövde okuma sırasında
`EAGAIN` alınırsa GERÇEKTEN `suspendForIo`ya düşülmesini (ve zamanlayıcının
BAŞKA bir bağlantının fiber'ına GEÇEBİLMESİNİ) sağlar; `nonBlockingRead`/
`Write` HER ikisi de `bridge.currentFiberScheduler()`e göre fiber içi/dışı
İKİ YOLU (D.1.3'ün aynı dual-path deseni) destekler.

**Bağlantı başına "ateşle-ve-unut" bare fiber (`Task[T]` SARMALAMADAN):**
`bridge.nox_async_spawn`ın `Task(i64)` sarmalayıcısı bir `await_` tutamacı
VARSAYAR (`entryTrampoline`, işlev döndükten SONRA `self.completed`/
`self.result`ı YAZAR) — bir HTTP sunucusunun bağlantı işleyicileri İSE
ASLA `await` EDİLMEZ (kabul döngüsü hemen bir SONRAKİ bağlantıyı bekler).
Bu yüzden `scheduler_mod.Scheduler`/`fiber_mod.Fiber`i (İKİSİ DE `pub`)
DOĞRUDAN kullanan, `Task` sarmalayıcısını ATLAYAN minimal bir desen
uygulanır: `Fiber.create` + `scheduler.live_count += 1` (manuel — `scheduler_
mod.spawn`ın KENDİ iç tarifiyle AYNI) + `scheduler.markReady(fiber)`; fiber
bittiğinde `Scheduler.run()`ün MEVCUT temizleme yolu (`fiber.destroyKeepStack`
+ `releaseStack`) OTOMATİK devreye girer — EK bir "task'ı yık" çağrısına HİÇ
GEREK KALMAZ.

**Genişletme noktası (`HandlerFn`) — D.1.6'nın çağrı-sitesi entegrasyonu
HENÜZ YOK:** bu dosya, Nox'un `handle(req) -> HttpResponse` işlevini
ÇAĞIRACAK per-call-site sarmalayıcı (Keşif 5) İÇİN TEK bir genişletme
noktası bırakır — `handler: *const fn(?*anyopaque, ?*anyopaque) callconv(.c)
?*anyopaque` (bağlam, istek tutamacı) -> yanıt tutamacı. D.1.6, `nox.http.
serve(port, handle)` çağrı sitesini bu imzaya uyan bir sarmalayıcıyı
`nox_http_serve_raw`a geçirecek şekilde ÇEVİRECEK; bu dosyanın KENDİ birim
testleri bu genişletme noktasını DOĞRUDAN (Nox'a hiç dokunmadan) elle
sağlanan bir Zig işleviyle egzersiz eder. İstek/yanıt tutamaçları — D.1.3'ün
opak-handle + erişimci deseniyle AYNI (`nox_http_request_method/target/body/
headers`, `nox_http_response_new`).

**ÜÇÜNCÜ keşif (D.1.3'ün İKİNCİ keşfinin GENELLEŞTİRİLMİŞ, MERKEZİ çözümü)
— `fiber.trampoline`e "derinlik dolgusu" eklendi:** D.1.4'ün KENDİ birim
testleri yazılırken, D.1.3'te bulunan "`DebugAllocator`in yığın-izi
yakalaması bir fiber'ın SIĞ, sahte-köklü çağrı zincirinin ÖTESİNE geçemez"
hatası (bkz. §3.31'in "İKİNCİ, DAHA DERİN keşif"i) BURADA da (`nox_http_
serve_raw`nin KENDİ `gpa.create(ConnCtx)` çağrısında, `SIGSEGV` adres `0x8`,
`lldb -p PID` ile `bt all` alınarak DOĞRULANDI) yeniden ORTAYA ÇIKTI —
BEKLENDİĞİ gibi, çünkü bu KÖK NEDEN `runtime/async_rt/fiber.zig`nin KENDİSİNE
özgüydü, http_client'a DEĞİL. Bu kez KALICI, MERKEZİ bir çözüm uygulandı:
`fiber.zig`nin `trampoline`i artık `self.entry(self.arg)`i doğrudan
ÇAĞIRMAK YERİNE, YEDİ KATMANLI, kasıtlı `@call(.never_inline, ...)`
sarmalayıcı bir zincir (`callEntryPadded` → `callEntryPad7` → ... →
`callEntryPad1` → `self.entry`) ÜZERİNDEN çağırır — bu, `self.entry`in (VE
onun DOĞRUDAN çağırdığı herhangi bir "sığ" fonksiyonun) `trampoline`den HER
ZAMAN yeterli GERÇEK çerçeve UZAKTA başlamasını GARANTİ eder, `DebugAllocator`
İÇİN AYRI bir yapılandırma GEREKMEDEN. **Bu, HER ÇAĞRI SİTESİNE ayrı ayrı
"derinlik dolgusu" eklemek YERİNE, TEK bir merkezi düzeltmedir** — Task
sarmalı fiber'lar, bare fiber'lar VE ileride yazılacak HERHANGİ bir
`async_rt` kullanıcısı (D.1.5/D.1.6 DAHİL) OTOMATİK olarak korunur. Bkz.
[[project_fiber_stack_debug_allocator_hazard]] (memory).

**Doğrulama:** iki Zig birim testi (`runtime/stdlib_shims/http_server.zig`):
(1) `nox_http_server_listen`/`nox_http_serve_raw` (fiber DIŞI, `max_
connections=1`) ile GERÇEK bir TCP bağlantı/istek/yanıt döngüsü tamamlanır
— `std.http.Server`ın gerçek HTTP/1.1 ayrıştırması/yazması doğru çalışır;
(2) `nox_http_serve_raw` bir Nox fiber'ı İÇİNDEN (`bridge.nox_async_spawn`)
çalıştırılır, `max_connections=2` ile İKİ GERÇEK istemci bağlantısı kabul
edilir — biri ("slow") isteğini göndermeden ÖNCE 150ms bekler, DİĞERİ
("fast") hemen gönderir; sunucunun "slow" bağlantı İÇİN `receiveHead`i
(dolayısıyla `FiberReader.stream`i) EAGAIN alıp askıya düşerken, "fast"
bağlantının BLOKE OLMADAN ÖNCE tamamlandığı bir günlük sırasıyla kanıtlanır
(D.0/D.1.3'ün AYNI "sıra kanıtı" deseni). Her ikisi de "kasıtlı boz →
kırmızıyı doğrula → düzelt" ritüeliyle doğrulandı. `zig build test` (Debug +
`-Doptimize=ReleaseFast`, HEM varsayılan paralellikte HEM `-j1`, ardışık ÇOK
SAYIDA çalıştırmada hiç kırmızı OLMADAN) yeşil.

---

### 3.33 D.1.5 — `stdlib/nox/http.nox` Nox Sarmalayıcısı

**Tasarım:** `class HttpError: message: str` (Faz 7'nin mevcut sınıf/istisna
mekanizması, `raise`/`try`/`except` DEĞİŞMEDEN çalışır — HİÇBİR yeni checker/
codegen değişikliği İÇİN GEREK YOK), `class HttpResponse: status: int, body:
str, headers: dict[str, str]`, `def get(url, headers) -> HttpResponse:`/
`def post(url, body, headers) -> HttpResponse:` — D.1.3'ün `with_rt` işaretli
`extern def`lerini (`nox_http_get_raw`/`post_raw`/`response_ok`/`status`/
`body`/`headers`/`free`) SARAR; `nox_http_response_ok(h) == 0` İSE
`HttpError` `raise` eder. `from` yolu OLARAK `"zig-out/lib/noxrt.o"`
KULLANILIR — bu semboller ZATEN `runtime/lib.zig` üzerinden `noxrt.o`ya
DAHİL (`http_client.zig`), AYRI bir `.o` derlemeye GEREK YOK.

**Bu alt-fazda üç GERÇEK compiler hatası bulundu VE düzeltildi** (`HttpResponse.
headers: dict[str, str]`in — planın KENDİ metninde AÇIKÇA istenen bir sınıf
ALANI — İLK KEZ egzersiz ettiği, önceden hiç test edilmemiş kod yolları):

1. **`genFieldRead` `dict_info`yu KOPYALAMIYORDU** (`compiler/codegen_qbe/
   codegen.zig`) — `obj.dict_field[key]` (ör. `resp.headers["X"]`) çökme
   ZAMANI `dict_info.?` NULL unwrap panikiyle sonuçlanıyordu, çünkü bir
   sınıf ALANI okunurken dönen `Value`, `qtype`/`heap`/`class_name`/
   `elem_*`i KOPYALARKEN `dict_info`yu UNUTUYORDU. **Düzeltme:** eksik
   alan eklendi.
2. **`genEqCompareOrJump`, `.dict`/`.task`/`.channel` İÇİN `unreachable`e
   düşüyordu** — HER sınıf İÇİN OTOMATİK üretilen `$ClassName_eq`
   (kullanıcı `==` HİÇ kullanmasa BİLE, bkz. görev "list/class için derin
   yapısal eşitlik") bir `dict[str,str]` ALANI olan HERHANGİ bir sınıfta
   (`HttpResponse` DAHİL) DERLEME ZAMANI panikliyordu. **Düzeltme:** bu üç
   opak-tutamaç `HeapKind`i İÇİN güvenli bir varsayılan eklendi — TUTAMAÇ
   KİMLİĞİ (pointer) karşılaştırması (yapısal derinlemesine eşitlik YOK,
   zaten TANIMLI değil).
3. **`genClassRelease`, `dict`-tipli sınıf ALANLARINI HİÇ serbest BIRAKMIYORDU**
   (`isHeapManaged` yalnızca ARC-yönetimli `str`/`list`/`class`ı kapsar,
   `dict` KAPSAM DIŞI) — `HttpResponse` örnekleri yok edildiğinde `headers`
   ALANI HER ZAMAN SIZARDI. **Düzeltme:** `releaseAllLocalsExcept`in
   YERELLER İÇİN ZATEN yaptığı `nox_dict_destroy` çağrısının AYNISI, sınıf
   ALANLARI İÇİN de eklendi.

**Ayrıca — `dict[K,V]`nin ARC-yönetimli OLMAMASININ (bkz. Alt-Faz C, `Task`/
`Channel` İLE AYNI "tek sahiplilik, retain YOK" tasarımı) `stdlib/nox/http.nox`
YAZARKEN ortaya çıkardığı bir desen:** bir `extern def`den dönen bir
`dict[str,str]`i (ör. `nox_http_response_headers(h)`) bir KURUCU argümanına
geçirmeden ÖNCE adlandırılmış bir YERELE bağlamak (`resp_headers: dict[str,
str] = ...`) GÜVENSİZDİR — `dict` ARC-yönetimli olmadığından, o yerelin
kapsam sonu temizliği (`releaseAllLocalsExcept`) onu KOŞULSUZ yıkar, dönen
sınıf örneği HÂLÂ ona işaret ederken (sallanan işaretçi). **Çözüm (`get`/
`post`in KENDİSİNDE uygulanan desen):** `extern def` çağrısı DOĞRUDAN kurucu
argümanı olarak geçirilir (`HttpResponse(status, body, nox_http_response_headers(h))`)
— adlandırılmış bir yerele HİÇ BAĞLANMADIĞINDAN kapsam sonu temizliği ona
DOKUNMAZ, sahiplik TAMAMEN sınıf alanına geçer. Bu, GELECEKTEKİ `dict`
dönen `extern def` sarmalayıcıları (D.1.6 DAHİL) İÇİN genel bir kural
olarak not edilmelidir.

**Dördüncü bir hata — macOS `ld64`, YİNELENEN `.o` dosya argümanlarını
KABUL ETMEZ:** `compiler/main.zig`nin ESKİ belge notu ("yinelenen `-l`/
dosya argümanları `cc` için zararsızdır") YANLIŞ çıktı — `stdlib/nox/http.nox`nin
`extern def`leri `from "zig-out/lib/noxrt.o"` kullandığından (bu dosya ZATEN
`main.zig` tarafından KOŞULSUZ olarak `cc` argv'sine EKLENİYOR), gerçek
`noxc` CLI'siyle (yalnızca golden testlerin KENDİ basitleştirilmiş `cc`
çağrısıyla DEĞİL — bu, testlerin GERÇEK compiler'ı DEĞİL, `appendExternLinkArgs`ı
ATLAYAN kendi kopyalarını kullanmasından ötürü YAKALANMADI, bkz. AGENTS.md'nin
"gerçek bir programla el ile doğrulama" ritüeli) derlemeyi denerken "duplicate
symbol" bağlama HATASI ORTAYA ÇIKTI. **Düzeltme:** `appendExternLinkArgs`in
`seen` kümesi artık `"zig-out/lib/noxrt.o"` ile ÖNCEDEN tohumlanıyor — bu
YOLA başvuran HERHANGİ bir `extern def`, ZATEN unconditionally eklenmiş
olduğundan, İKİNCİ KEZ argv'ye EKLENMEZ.

**Doğrulama:** iki Zig birim testi (`tests/compat/http_stdlib_golden_test.zig`
— `tests/golden/codegen_golden_test.zig`nin `resolveImports` KULLANAN
`compileAndRun`ı İLE `tests/compat/extern_ffi_test.zig`nin RUNTIME (comptime
OLMAYAN) `source` desteğinin BİRLEŞİMİ, kasıtlı bir kod tekrarı): (1) `import
nox.http` + `nox.http.get(...)` GERÇEK bir yerel HTTP sunucusuna karşı —
durum/gövde/`resp.headers["X-Nox-Test"]` (dict[str,str] sınıf ALANI
İNDEKSLEME) doğru okunur; (2) bağlantı reddi `HttpError`ı `raise` eder,
`try`/`except nox_http_HttpError as e:` yakalar. Her ikisi de "kasıtlı boz →
kırmızıyı doğrula → düzelt" ritüeliyle doğrulandı. AYRICA — bu alt-fazın
KENDİ bulduğu "golden testler `appendExternLinkArgs`ı atlıyor" gerçeğinden
ÖTÜRÜ — GERÇEK `noxc` CLI'siyle (`zig-out/bin/noxc`), GERÇEK bir yerel HTTP
sunucusuna (Python `http.server`) karşı elle derlenip ÇALIŞTIRILARAK EK bir
uçtan uca doğrulama yapıldı (çıkış kodu 0, stderr boş — sızıntı YOK). `zig
build test` (Debug + `-Doptimize=ReleaseFast`, HEM varsayılan paralellikte
HEM `-j1`, ardışık ÇOK SAYIDA çalıştırmada hiç kırmızı OLMADAN) yeşil.

---

### 3.34 D.1.6 — `nox.http.serve(port, handle[, max_connections])` Özel Yerleşiği

**Tasarım:** `spawn`ın "çıplak isim" çözümüyle (bkz. §3.21, `.spawn_expr`
dalı) AYNI KATEGORİDE, ama İKİ noktada BİLİNÇLİ olarak SADELEŞTİRİLMİŞ bir
yerleşik:

- **`handle` bir PLAIN `def`dir, `async def` DEĞİL** — plan metninin aksine
  (o `async def` öngörüyordu). Gerekçe: D.1.4'ün `connectionEntry`si HER
  bağlantıyı `nox_async_spawn` OLMADAN, ZATEN aktif bir fiber bağlamı
  İÇİNDE SENKRON çağırır (bkz. §3.32) — `handle`in KENDİSİNİN `Task`/`await`
  semantiğine İHTİYACI YOK, `async def` gereksiz bir karmaşıklık olurdu.
  Checker (`tryResolveHttpServeCall`) `handle`in `self.async_functions`DA
  OLMADIĞINI AÇIKÇA doğrular (tersi bir kullanıcı HATASI sayılır).
- **`spawn`ın kapanış (closure) PAKETLEMESİNE gerek YOK** — sarmalayıcının
  İKİ parametresi (`rt`, `req`) DOĞRUDAN `nox_http_serve_raw`nin `HandlerFn`
  imzasına (`fn(?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque`) EŞLENİR:
  `rt` `handler_ctx` argümanı olarak `genHttpServe`nin ÇAĞRI SİTESİNDE
  DOĞRUDAN geçirilir (`nox_http_serve_raw(rt, server, $wrapper, rt, max_conn)`),
  `req` ise `connectionEntry`nin HER bağlantı İÇİN sağladığı ham istek
  tutamacıdır. Tek "yakalanan" değer zaten `rt`nin KENDİSİ olduğundan, `spawn`ın
  heap'e kapanış struct'ı tahsis edip PAKETLEYİP sarmalayıcının içinde
  PAKETTEN ÇIKARDIĞI (bkz. `genSpawnExpr`/`genSpawnWrapper`) mekanizmanın
  HİÇBİRİNE gerek YOK.
- **Yeni bir AST düğümü GEREKMEZ** — `nox.http.serve(...)` sözdizimsel
  olarak `nox.http.get(...)` İLE AYNI (`Attribute`+`Call` zinciri) ayrıştırılır.
  AMA `tryResolveQualifiedCall`ın (bkz. §"Alt-Faz A") YAPTIĞI GİBİ çağrı
  sitesinin callee'sini mangled bir İSME YENİDEN YAZMAZ — checker'ın
  `tryResolveHttpServeCall`ı (yeni, `checkCall`in `.attribute` dalında
  `tryResolveQualifiedCall`DAN ÖNCE denenir — `handle` ÇIPLAK bir fonksiyon
  ADI olduğundan normal argüman tipi denetiminden GEÇİRİLEMEZ, `spawn`ın
  AYNI kısıtı) YALNIZCA doğrular, callee AST'sini DEĞİŞTİRMEZ. Bu yüzden
  codegen'in KENDİSİ ŞEKLİ (üç seviyeli `nox`/`http`/`serve` `Attribute`
  zinciri) TANIMAK ZORUNDADIR — `isHttpServeCallee` (codegen.zig) HEM
  `genCall`in `.attribute` dalında (metod-çağrısı çözümlemesinden ÖNCE)
  HEM `exprUsesAsync`in `.call` dalında (aşağıya bkz.) kullanılır.

**Checker (`tryResolveHttpServeCall`, `compiler/typecheck/checker.zig`):**
callee `nox.http.serve` DEĞİLSE (ya da `nox.http` HİÇ import edilmemişse)
`null` döner (çağıran mevcut `tryResolveQualifiedCall`a düşer). Eşleşirse:
2 ya da 3 argüman ister (`port: int`, `handle`, opsiyonel `max_connections:
int`); `handle` `.identifier` OLMALI (metod/lambda desteklenmiyor);
`self.async_functions`DA OLMAMALI; imzası TAM OLARAK `(nox_http_HttpRequest)
-> nox_http_HttpResponse` olmalı (mangled sınıf adları — kullanıcı `nox.http`ı
import ettiğinden bu isimler ZATEN kayıtlıdır). Dönüş tipi `.none`.

**Codegen (`genHttpServe`/`genHttpServeWrapper`, `compiler/codegen_qbe/
codegen.zig`):** `genHttpServe` (çağrı sitesi) `nox_http_server_listen`
çağırır, HER çağrı sitesi İÇİN bir `HttpServeWrapperSpec`i `self.http_serve_
wrappers`e (spawn'ın `SpawnWrapperSpec`iyle AYNI "tembel kuyruk" deseni,
`generateModule`nin SONUNDA tüketilir) kaydeder, `nox_http_serve_raw` +
`nox_http_server_close` çağırır. `genHttpServeWrapper` (üretilen sarmalayıcı)
`req_class`ın (ör. `HttpRequest`) HER alanını AD üzerinden (`method`→
`nox_http_request_method`, `target`→`_target`, `body`→`_body`, `headers`→
`_headers`) İLGİLİ `nox_http_request_*` erişimcisine eşleyip bir örnek
İNŞA EDER, `handler_fn`i çağırır, dönen `resp_class` (ör. `HttpResponse`)
örneğinden `status`/`body`/`headers`i okuyup `nox_http_response_new`e
geçirir (BU çağrı KENDİ kopyasını TUTAR — bkz. `runtime/stdlib_shims/
http_server.zig`), SONRA hem istek hem yanıt örneğini TAMAMEN serbest
bırakır.

**İki yeni codegen yardımcısı (mevcut fonksiyonların AST-bağımsız
çekirdekleri, `genConstruct`/`genFieldRead`in davranışı DEĞİŞMEDEN):**
`genConstructFromValues` (`genConstruct`ın refactor edilmiş çekirdeği —
ZATEN hesaplanmış `Value[]`den bir örnek inşa eder, `genConstruct` bunun
ÜZERİNE `ast.Expr[]`i `genExpr`le değerlendirip İNCE bir sarmalayıcı olarak
kalır) ve `genFieldReadFromValue` (`genFieldRead`in basitleştirilmiş
çekirdeği — ZATEN hesaplanmış bir `Value`den bir alan okur, `genFieldRead`in
"taban taze bir geçiciyse retain et" dansı OLMADAN, çünkü sarmalayıcı
nesnenin TÜM yaşam döngüsünü kendisi yönetir).

**Bulunan GERÇEK hata — sarmalayıcının inşa ettiği `HttpRequest`in `str`
alanları (method/target/body) SIZIYORDU:** `genConstructFromValues`
(`genConstruct`ın AKSİNE) `releaseTemporaryArgs`ı ÇAĞIRMAZ (bu, tasarım
gereği ÇAĞIRANIN sorumluluğudur — bkz. onun belge notu). `__init__`in
`self.x = x` alan ataması (bkz. `genAssign`in `.attribute` dalı) heap-
yönetimli (str) değerleri RETAIN ettiğinden, `nox_http_request_method/
target/body`den dönen TAZE `str`ler (refcount 1→2) sarmalayıcı tarafından
BİR KEZ daha release EDİLMEZSE sızar. **Düzeltme:** `genHttpServeWrapper`,
`genConstructFromValues`DEN SONRA `req_values` İÇİNDEKİ `isHeapManaged`
(yalnızca `str` — `headers` (`dict`) `isHeapManaged`e GİRMEDİĞİNDEN, ki
`__init__` onu HİÇ retain ETMEZ, doğal olarak ATLANIR) alanları BİR KEZ
release EDER.

**Bilinçli v0.1 sınırlaması (`genSpawnWrapper` İLE AYNI gerekçe):** `handle`
içinde bir istisna oluşup YAKALANMAZSA, sarmalayıcı BUNU denetlemez/
temizlemez.

**`exprUsesAsync` düzeltmesi (KRİTİK — GÖZDEN KAÇABİLECEK bir gap):**
`nox.http.serve(...)`nin KENDİSİ (kqueue reaktörü üzerinden fiber-native
`accept` yapan `nox_http_serve_raw`ı çağırdığından) bir programın TEK async
özelliği OLABİLİR — ne `handle` (çıplak bir isim argümanı) NE `nox.http.
serve`nin KENDİSİ (bir `Attribute`/`identifier` zinciri) `exprUsesAsync`in
MEVCUT dallarından (`.await_expr`/`.spawn_expr`/`.generic_construct`)
HİÇBİRİNİ tetikler. Bu düzeltilMEDEN, YALNIZCA `nox.http.serve` kullanan bir
program `moduleUsesAsync`da `false` dönerdi → `genMain` (fiber-SARMASIZ kök)
üretilirdi → zamanlayıcı/reaktör HİÇ ilklendirilmezdi → `nox_http_serve_raw`
sessizce `blockingAccept`e (bkz. §3.32, `scheduler == null` dalı) düşerdi —
ÇALIŞIRDI ama GERÇEK eşzamanlılık OLMADAN (tek bağlantı sırayla). **Düzeltme:**
yeni `isHttpServeCallee` yardımcısı `exprUsesAsync`in `.call` dalında da
kullanılır, şekli tanıyınca `true` döner.

**Doğrulama:** `tests/compat/http_serve_golden_test.zig` — GERÇEK bir `.nox`
sunucu programı (`import nox.http` + `def handle(req: nox_http_HttpRequest)
-> nox_http_HttpResponse:` + `nox.http.serve(port, handle, 2)`) module_loader+
checker+codegen+qbe+cc İLE derlenip `std.process.spawn` (bloklamayan —
`http_stdlib_test`in bloklayan `compileAndRun`ının AKSİNE, çünkü BURADA Nox
PROGRAMININ KENDİSİ sunucu, Zig test kodu istemcidir) ile ARKA PLANDA
başlatılır; "yavaş" istemci bağlanıp isteği göndermeden ÖNCE 150ms bekler
(sunucuyu `EAGAIN`/`suspendForIo`ya ZORLAR), "hızlı" istemci HEMEN gönderir —
sıra kanıtı (`runtime/stdlib_shims/http_server.zig`nin KENDİ testiyle AYNI
desen, bkz. §3.32): stdout'ta `/fast` SATIRI `/slow`DAN ÖNCE görünür, TEK
bir OS iş parçacığında BLOKLAYAN bir `accept`/`read` YAPILMADIĞININ somut
kanıtı. `dict[str, str]` literalinin (D.1.5'in AYNI kuralı) DOĞRUDAN kurucu
argümanı olarak (adlandırılmış bir yerele bağlanmadan) geçirilmesi burada
da GEREKLİYDİ — `headers: dict[str,str] = {{"x":"x"}}` sonra `HttpResponse(
..., headers)` şeklinde YAZILSAYDI, `handle`in kapsam-sonu temizliği dict'i
KOŞULSUZ yıkardı (çifte serbest bırakma — bu HATA test yazımı SIRASINDA
gerçekten YAKALANDI, kaynak düzeltilerek giderildi, KODGEN'de bir hata
DEĞİLDİ). `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil, "kasıtlı
boz → kırmızıyı doğrula → düzelt" ritüeliyle doğrulandı.

---

### 3.35 D.1 Sonrası Stdlib Yol Haritası + Alt-Faz E — `str(x)`/`int(s)`/`float(s)`

D.1 (`nox.http`, istemci+sunucu) TAMAMLANDI ve bir verim ölçümüyle
doğrulandı (`benchmarks/http_bench.zig`, ReleaseFast'ta ~8-10k istek/sn).
Kullanıcıyla "geri kalan stdlib" için yeni bir planlama turu yapıldı —
tam yol haritası `/Users/melihburakmemis/.claude/plans/witty-cuddling-nebula.md`nin
"Alt-Faz E–L" bölümünde: E (tip dönüşümleri) → F (list dönen extern def) →
G (string indeksleme) → H (nox.strings) → I (nox.math, bağımsız) → J
(nox.os+nox.fs) → K (nox.time+nox.test) → L (nox.json, TAM kapsam — kullanıcı
"tam olarak yapalım" dedi, kısıtlı sürüm DEĞİL — roadmap'in en büyük/riskli
parçası, kendi ön-deneyiyle EN SONA bırakıldı).

**Alt-Faz E (TAMAMLANDI) — `str(x)`/`int(s)`/`float(s)`:** `print`/`len`
İLE AYNI, checker/codegen'de özel-işlenen çekirdek yerleşikler (`extern def`
DEĞİL, modül gerektirmez). `str(int)`/`str(float)` HER ZAMAN başarılıdır
(`runtime/str.zig`nin YENİ `nox_int_to_str`/`nox_float_to_str`si, ARC'lı
YENİ bir `str` döner). `int(s)`/`float(s)` ayrıştırma BAŞARISIZSA çekirdek
(HİÇBİR `import` GEREKMEDEN her programa hazır) YENİ bir `ValueError`
sınıfını `raise` eder.

**Yeni mekanizma — `stdlib/nox/core.nox`, HER modüle KOŞULSUZ birleştirilir:**
`compiler/module_loader.zig`nin `resolveImports`ı artık `import` deyimlerinden
BAĞIMSIZ olarak, HER ZAMAN önce `stdlib/nox/core.nox`u (MANGLE EDİLMEDEN —
`ValueError` ÇIPLAK kullanılır) ayrıştırıp modüle ekler. **Gerçek bir isim
çakışması bulundu ve düzeltildi:** mevcut bir golden test fixture'ı
(`try_except_finally.nox`) KENDİ `class ValueError`ını tanımlıyordu —
`collectClassNames` "sınıf zaten tanımlı" hatasıyla BAŞARISIZ oldu. Düzeltme:
fixture'daki sınıf `NegativeError`a yeniden adlandırıldı (yeni çekirdek
yerleşik GERÇEK bir dil özelliği, fixture'ın rastgele seçilmiş adı BUNA yol
vermeliydi).

**QBE `phi`den KAÇINMA deseni (bkz. `genEqCompareOrJump`in AYNI gerekçeli
belge notu) `genParseOrRaise`e de UYGULANDI:** `int(s)`/`float(s)`nin hata
dalı (`ValueError` inşa+`nox_raise`+`emitExceptionCheck`) SONRASI doğrudan
`ok_label`e ATLAR — iki farklı DEĞERİ (`phi` ile) birleştirmek YERİNE, "buraya
vardıysan (ki hata dalı için bu PRATİKTE asla gerçekleşmez, `nox_raise`
KOŞULSUZ pending'i set ettiğinden) şunu hesapla" deseni; TEK bir SSA değeri
(`result`) YALNIZCA `ok_label` içinde tanımlanır.

**Yeniden kullanılabilir yeni yardımcılar (codegen.zig):** `emitStringLiteral`
(genExpr'in `.string_lit` kolundan ÇIKARILDI — codegen'in KENDİSİNİN
sentezlediği sabit mesajlar İÇİN de kullanılabilir, PINNED-refcount tekniği
DEĞİŞMEDEN); `genParseOrRaise` (yukarıda).

**Doğrulama:** golden testler (`str_int_roundtrip.nox`, `str_float_roundtrip.
nox`, `int_parse_error_raises.nox`) + `runtime/str.zig`nin KENDİ birim
testleri. `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil, "kasıtlı
boz → kırmızıyı doğrula → düzelt" ritüeliyle doğrulandı.

---

### 3.36 Alt-Faz F — `list[str]` Döndüren `with_rt` `extern def` Desteği

**Tasarım:** Yeni bir Nox söz dizimi/anahtar kelime GEREKMEZ — YALNIZCA
`checker.zig`'in `isFfiSafeType`inin (dönüş tipi İÇİN) genişletilmesi:
`dict[str,str]`in D.1'de (Keşif 4) aldığı MUAMELENİN AYNISI, `list[str]`
(v1 kapsamı yalnızca bu somut örnekleme — `list[int]`/`list[float]`/
`list[class]` ERTELENDİ) DÖNÜŞ tipi (PARAMETRE OLARAK DEĞİL) FFI-güvenli
sayılır (yeni `isFfiSafeListReturnType`). Çalışma zamanı temsili ZATEN
`genListLit`in ürettüğü AYNI bayt düzenidir (8 bayt uzunluk başlığı + `str`
işaretçileri, `nox_rc_alloc` üzerinden ARC'lı) — bir Zig kabuğu bunu EL İLE
inşa edebilir.

**Bu alt-fazda İKİ GERÇEK compiler hatası bulundu VE düzeltildi** (`list[str]`
döndüren bir `extern def`in İLK KEZ egzersiz ettiği, önceden hiç test
edilmemiş kod yolları — D.1.5/D.1.6'nın "ilk kez denenen kombinasyon, gerçek
bug" desenine BİREBİR AYNI):

1. **`genCall`in `extern_functions` dalı `elem_qtype`/`elem_heap_info`/
   `elem_is_str`i KOPYALAMIYORDU** (yalnızca `qtype`/`heap`) — D.1.5'in
   `genFieldRead`de bulunan `dict_info` eksikliğiyle AYNI KATEGORİDE bir
   hata. Dönen `list[str]` DOĞRUDAN (adlandırılmış/annotasyonlu bir yerele
   BAĞLANMADAN) indekslenince/serbest bırakılınca YANLIŞ/EKSİK meta veriyle
   çöküyordu (annotasyonlu bir yerele bağlansaydı, `VarInfo`nin annotasyon-
   türetilmiş — HER ZAMAN doğru — meta verisi bu hatayı MASKELERDİ, bu
   yüzden golden test BİLİNÇLİ OLARAK sonucu adlandırılmış bir yerele
   bağlamadan doğrudan indeksliyor). **Düzeltme:** eksik üç alan eklendi.
2. **`isTemporaryExpr`, `.index` ifadelerini HİÇ ÖZEL İŞLEMİYORDU** (`else
   => false`e düşüyordu) — `.attribute`nin (bkz. onun AYNI gerekçeli belge
   notu, `make_car(i).engine` deseni) AKSİNE, `.index`in TABANI temporary
   olduğunda (`genIndex` elemanı retain EDER, bkz. `genIndex`in belge notu)
   çağıranın (`print` gibi) bu elemanı SONRADAN serbest bırakması
   GEREKTİĞİNİ hiç BİLMİYORDU — GERÇEK bir sızıntı (`print(some_call()[0])`
   deseninde, önceden HİÇBİR test bir listeyi adlandırılmış bir yerele
   BAĞLAMADAN doğrudan indekslemediğinden yakalanmamıştı). **Düzeltme:**
   `.index => |idx| isTemporaryExpr(idx.obj.*)` — `.attribute` İLE AYNI
   özyinelemeli desen.

**Yeni yardımcı (`tests/compat/zig_ext/util.zig`):** `nox_test_make_list(rt,
n) -> ptr` — `n` elemanlı ("item_0".."item_{n-1}") bir `list[str]`
payload'ını EL İLE (`nox_rc_alloc` + uzunluk başlığı + her eleman KENDİ
ARC'lı `str`i) inşa eder.

**Doğrulama:** `tests/compat/extern_ffi_test.zig`ye yeni bir golden test —
dönen listeyi BİLİNÇLİ OLARAK adlandırılmış bir yerele BAĞLAMADAN doğrudan
indeksler (`print(nox_test_make_list(3)[0])` gibi) ki HER İKİ hata da
MASKELENMEDEN yakalanabilsin; sızıntı YOK (DebugAllocator doğrular). Her
iki hata da AYRI AYRI "kasıtlı boz → kırmızıyı doğrula → düzelt" ritüeliyle
doğrulandı (düzeltmelerden biri geri alınınca test GERÇEKTEN kırmızı oldu).
`zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil.

---

### 3.37 Alt-Faz G — String İndeksleme: `s[i]`

**Tasarım:** Mevcut `Index` AST düğümü/sözdizimi (`list[T]`/`dict[K,V]` İLE
AYNI `obj[expr]` şekli) `str` tabanına GENİŞLETİLDİ — YENİ bir düğüm/
sözdizim GEREKMEDİ. `s[i]` TEK karakterlik bir `str` döner (Nox'ta AYRI bir
"char" tipi YOK). Sınır dışı erişim ÇALIŞMA ZAMANINDA yeni bir `IndexError`
(bkz. `stdlib/nox/core.nox` — `ValueError` İLE AYNI şekilde, HİÇBİR `import`
GEREKMEDEN her programa otomatik eklenir) `raise` eder — sınır KONTROLÜ
QBE'de yapılır (`strlen` + karşılaştırma), `genParseOrRaise`in (stdlib fazı
§E) AYNI "önce doğrula, hata dalında raise et, `phi`SİZ `ok`e atla" deseni.
Runtime tarafı: `runtime/str.zig`ye YENİ `nox_str_char_at(rt, s, idx) -> str`
— sınır KONTROLÜ YAPMAZ (codegen ÖNCEDEN doğruladı), yalnızca TEK
karakterlik YENİ bir ARC'lı `str` döner.

**Bu alt-fazda İKİ GERÇEK, İNCE compiler hatası bulundu VE düzeltildi** —
`list`/`dict` indekslemesinden TEMELDEN FARKLI bir sahiplik şekli (`s[i]`
HER ZAMAN TABANDAN BAĞIMSIZ TAZE bir tahsis döndürür, `list`/`dict`
indekslemesi İSE TABANIN İÇİNE bir BORÇ/takma addır) `isTemporaryExpr`/
`isAliasingExpr`in AST-tabanlı (tip bilgisi OLMAYAN) sezgisiyle
ÇAKIŞIYORDU:

1. **`print(s[0])` (adlandırılmış taban) — sonuç HİÇ serbest bırakılmıyordu:**
   `isTemporaryExpr(.index{obj=identifier})` = `isTemporaryExpr(.identifier)`
   = `false` (Alt-Faz F'nin `.index` düzeltmesi TABANIN temporary'liğine
   bakıyor — `list`/`dict` İÇİN DOĞRU, ama `str` İÇİN YANLIŞ: sonuç HER
   ZAMAN taze olduğundan tabanın temporary'liği ALAKASIZ). Bu, `print(some_
   call()[0])` (taban temporary) durumunda MASKELENİYORDU (o durumda
   `isTemporaryExpr` ZATEN `true` döndüğünden doğru davranıyordu) — bu
   yüzden golden test BİLİNÇLİ OLARAK HEM adlandırılmış HEM temporary
   tabanlı indekslemeyi İÇERİYOR.
2. **`c: str = s[0]` (bir isme bağlama) — sonuç ÇİFTE retain ediliyordu (bir
   BAŞKA sızıntı):** `isAliasingExpr(.index{obj=identifier})` = `!isTemporaryExpr
   (.identifier)` = `true` — `retainIfAliasing` bunu bir takma ad SANIP
   ZATEN refcount 1 olan taze karakteri TEKRAR retain ediyordu (refcount 2),
   ama yalnızca TEK bir `release` (yerelin kapsam sonu) olduğundan asla
   sıfıra İNMİYORDU.

**Düzeltme — `Value`ye yeni `always_fresh: bool` bayrağı:** `isTemporaryExpr`/
`isAliasingExpr` SALT AST'ye bakan pür fonksiyonlar olduğundan (tip bilgisi
TAŞIYAMAZLAR) bu ayrım `Value`nin KENDİSİNDE taşınır — `genStrIndex`
sonucuna `always_fresh = true` işaretler; `retainIfAliasing`/
`releaseIfTemporary`/`releaseTemporaryArgs` (hepsi ZATEN hesaplanmış
`Value`ye erişimi olan fonksiyonlar) bu bayrak `true` İSE AST-tabanlı
sezgiyi GEÇERSİZ KILAR: ASLA takma ad SAYILMAZ (retain gerekmez), HER ZAMAN
temporary SAYILIR (release gerekir). `list`/`dict` indekslemesi (bayrak
VARSAYILAN `false`) DEĞİŞMEDEN, MEVCUT (doğru) davranışını korur.

**Doğrulama:** golden testler (`str_index_basic.nox` — adlandırılmış VE
temporary taban, bir isme bağlama+yeniden atama, HEPSİ TEK testte; `str_
index_out_of_bounds_raises.nox` — pozitif VE negatif sınır dışı). Her İKİ
gerçek hata da AYRI AYRI "kasıtlı boz → kırmızıyı doğrula → düzelt"
ritüeliyle doğrulandı. `zig build test` (Debug + `-Doptimize=ReleaseFast`)
yeşil.

---

### 3.38 Alt-Faz H — `nox.strings` Modülü

**Tasarım:** `stdlib/nox/strings.nox` — E/F/G'ye dayanır. `split`/`trim`/
`upper`/`lower`/`replace` (değişken uzunluklu sonuç/byte-seviyeli tarama
gerektirdiğinden) YENİ bir `runtime/stdlib_shims/strings.zig` kabuğuna
sarar (`split` → `nox_strings_split_raw`, Alt-Faz F'nin `list[str]` DÖNÜŞ
desteğinin GERÇEK ihtiyaç sahibi). `join`/`starts_with`/`ends_with`/
`contains`/`index_of` İSE TAMAMEN SAF NOX'ta yazıldı — `for x in list:` +
`+` birleştirme + Alt-Faz G'nin `s[i]`siyle, HİÇ Zig/extern def
GEREKMEDEN. ASCII v1 kapsamı (bilinçli) — Unicode/UTF-8 büyük/küçük harf
dönüşümü ERTELENDİ.

**Bu alt-fazda ÜÇÜNCÜ bir GERÇEK, ÖNCEDEN VAR OLAN compiler hatası bulundu
VE düzeltildi** — bu SEFER Alt-Faz E/F/G/H'nin HERHANGİ birinin YENİ kodu
DEĞİL, Faz görev listesinin ÇOK DAHA ERKEN bir görevinden ("str == str /
str != str", Alt-Faz B'DEN — str'in ARC-yönetimli YAPILMASINDAN — ÖNCE
yazılmış) kalma, HİÇ güncellenmemiş bir varsayım: **`genBinary`'nin `str ==
str`/`str != str` dalı (`genStrCompare`), operandları KARŞILAŞTIRDIKTAN
SONRA HİÇBİR ZAMAN serbest BIRAKMIYORDU** — o dalın belge notu AÇIKÇA "str
HİÇBİR ZAMAN ARC-yönetimli DEĞİLDİR" diyordu, bu Alt-Faz B'nin str'i ARC-
yönetimli YAPMASINDAN ÖNCEKİ bir gerçekti ve KOD/YORUM hiç GÜNCELLENMEMİŞTİ.
`nox.strings.starts_with`/`ends_with`/`index_of`in `s[i] != needle[j]`
gibi (Alt-Faz G'nin TEK karakterlik TAZE tahsisleri, bkz. §3.37'nin
`always_fresh` bayrağı) İKİ TEMPORARY `str`i DOĞRUDAN karşılaştırması, bu
BOŞLUĞU İLK KEZ egzersiz etti (mevcut HİÇBİR test, iki TEMPORARY str'i
adlandırılmış bir yerele BAĞLAMADAN doğrudan `==`/`!=` ile karşılaştırmıyordu).
**Düzeltme:** `list`/`class` eşitlik dalıyla VE `str + str` dalıyla AYNI
desen — `genStrCompare`den SONRA `releaseIfTemporary` HER İKİ operand
İÇİN de çağrılır.

**Genel ders:** bir dalın belge notu, o dal YAZILDIĞI ANDAKİ bir dil
gerçeğini yansıtıyor OLABİLİR — o gerçek SONRADAN değiştiğinde (`str`in
ARC-yönetimli hâle GELMESİ gibi), o dalın KODU AYRICA güncellenmedikçe
YORUM ile GERÇEK DAVRANIŞ birbirinden SESSİZCE SAPAR. Bu tür sapmalar
YALNIZCA o spesifik kod yolunu YENİ bir açıdan egzersiz eden bir test
(burada: iki TEMPORARY str'i DOĞRUDAN karşılaştırmak) YAZILDIĞINDA ortaya
ÇIKAR.

**Doğrulama:** golden testler (`strings_split_join.nox`, `strings_case_
trim_replace.nox`, `strings_search.nox` — SONUNCUSU `genStrCompare`
sızıntısını YAKALAYAN test, İSMİNDE AÇIKÇA belirtildi). `runtime/
stdlib_shims/strings.zig`nin KENDİ birim testleri. `genStrCompare` düzeltmesi
"kasıtlı boz → kırmızıyı doğrula → düzelt" ritüeliyle doğrulandı (geri
alınınca `strings_search.nox` GERÇEKTEN kırmızı oldu). `zig build test`
(Debug + `-Doptimize=ReleaseFast`) yeşil.

---

### 3.39 Alt-Faz I — `nox.math` Modülü

**Tasarım:** `stdlib/nox/math.nox` — `sqrt`/`pow`/`floor`/`ceil` doğrudan
libm'e ince `extern def` sarmalayıcıları (`from "m"`, `with_rt` bile
GEREKMEZ — ikisi de ARC-dışı float↔float; Faz 20'nin `extern def sqrt(x:
float) -> float from "m"`sinin ZATEN kanıtladığı desen, `cc` KOMUTU ZATEN
`-lm` bağlıyor). `min`/`max`/`abs` İSE TAMAMEN saf Nox (`if`/`return`,
HİÇ FFI gerekmez). E/F/G/H'DEN BAĞIMSIZ, hiçbir yeni checker/codegen
değişikliği GEREKMEDİ (Alt-Faz E-H'nin İLK ZAMANI: bu alt-fazda HİÇBİR
compiler hatası bulunmadı — YALNIZCA ZATEN kanıtlanmış mekanizmalar
(qualified call, extern def, if/return) kullanıldı).

**Keşfedilen ÖNEMLİ, ÇÖZÜLEMEYEN bir sözdizim asimetrisi (yeni bir bug
DEĞİL, bir mimari GERÇEK):** `extern def`ler ASLA mangle EDİLMEZ (bkz.
`module_loader.zig`nin belge notu — isimleri GERÇEK bir C ABI sembolüne
bağlıdır, `sqrt`in KENDİSİ libm'de ARANIR, `nox_math_sqrt` DEĞİL). Bu
yüzden `import nox.math` SONRASI **`sqrt`/`pow`/`floor`/`ceil` ÇIPLAK
(niteliksiz) çağrılır** (`sqrt(2.0)`) — `nox.math.sqrt(2.0)` (nitelikli
sözdizimi) ÇALIŞMAZ, çünkü nitelikli çağrı çözümlemesi (`tryResolveQualified
Call`) YALNIZCA mangle EDİLMİŞ isimlere bakar. `min`/`max`/`abs` (sıradan
`func_def`, mangle EDİLİR) İSE nitelikli çağrılır: `nox.math.min(3.0, 5.0)`.
Sarmalayıcıya extern def'le AYNI kısa adı vermek (`def sqrt(x): return
sqrt(x)`) DENENMEDİ/BİLİNÇLİ REDDEDİLDİ: `module_loader`in yeniden adlandırma
haritası TEK bir düz ad alanı kullandığından, sarmalayıcının KENDİ adı
"sqrt" olsaydı GÖVDESİNDEKİ "sqrt" çağrısı da mangled ada YENİDEN YAZILIR,
KENDİ KENDİNİ özyinelemeli çağıran SONSUZ bir döngüye yol açardı (bu
GERÇEKTEN denenip fark edildi, kaynağa YANSITILMADI). **Bu asimetri
`stdlib/nox/math.nox`nin KENDİ belge notunda AÇIKÇA belgelendi** — gelecekte
GERÇEK bir C kütüphanesi fonksiyonunu SARMAK isteyen HERHANGİ bir stdlib
modülü İÇİN geçerli GENEL bir kural.

**Doğrulama:** golden test (`math_basic.nox` — HEM çıplak `sqrt`/`pow`/
`floor`/`ceil` HEM nitelikli `nox.math.min`/`max`/`abs`i AYNI testte
egzersiz eder). "Kasıtlı boz → kırmızıyı doğrula → düzelt" ritüeliyle
doğrulandı. `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil.

---

### 3.40 Alt-Faz J — `nox.os` + `nox.fs` Modülleri

**Tasarım:** `stdlib/nox/os.nox` (`arg_count()`/`arg(i)`/`getenv(name)`/
`exit(code)`) ve `stdlib/nox/fs.nox` (`read_to_string(path)`/
`write_string(path, content)`) — ikisi de `nox.http`nin `get`/`post`iyle
AYNI kalıp: ince Nox sarmalayıcı (kendi hata sınıfı — `OsError`/`FsError`)
+ `with_rt extern def`. `nox.fs` `nox_fs_last_op_ok()` durum sorgusuyla
`nox_http_response_ok`in AYNI "ham çağrı + AYRI durum sorgusu" tasarımını
izler (M:1 fiber modelinde iki fiber ASLA eşzamanlı çalışmadığından statik
bir `bool` bayrağı GÜVENLİDİR).

**Yeni, KALICI codegen değişikliği — `$main`in gerçek C ABI'siyle
uyumlu hâle getirilmesi:** `nox.os.arg_count`/`arg(i)`in gerçek `argc`/
`argv`e erişebilmesi için `codegen.zig`nin `genMain`/`genMainAsync`si artık
`export function w $main(w %argc, l %argv) { ... }` üretiyor (ÖNCESİNDE
parametresizdi) ve `nox_runtime_init()` çağrısının HEMEN ardından KOŞULSUZ
`call $nox_os_init(w %argc, l %argv)` çağırıyor — `nox.os` HİÇ import
edilmese BİLE (basitlik: ikinci/koşullu bir `$main` kodgen yolu YOK,
kullanılmayan parametrelerin maliyeti sıfıra yakın). `runtime/stdlib_shims/
os.zig`nin `nox_os_init` fonksiyonu bunları süreç ömrü boyunca yaşayan
statik değişkenlere (`g_argc`/`g_argv`) kaydeder.

**Keşfedilen ve düzeltilen bir isim-çakışması hatası (Alt-Faz I'nin
dersinin bir VARYANTI):** `nox_os_arg_count`/`nox_os_arg`/`nox_os_exit`
adlı extern def'ler (soneksiz) `arg_count`/`arg`/`exit` adlı KISA
sarmalayıcılarla BİRLİKTE tanımlanınca, `module_loader.zig`nin mangle
kuralı ("top-level `func_def` adı `<modpath>_<ad>`e mangle edilir") bu
sarmalayıcıları TAM OLARAK extern def'lerle AYNI isme ("nox_os_arg_count"
vb.) dönüştürdü — `registerExternFunc`in yinelenen-tanım kontrolü bunu
"fonksiyon zaten tanımlı" hatasıyla YAKALADI. Alt-Faz I'nin dersi ("aynı
ÇIPLAK isim, sarmalayıcının GÖVDESİNDEKİ çağrıyı özyinelemeli hâle
getirir") BURADA farklı bir yüzeyle tekrar ortaya çıktı: extern def'in
KENDİ (mangle EDİLMEYEN) ismi, sarmalayıcının MANGLE EDİLMİŞ ismiyle
ÇAKIŞABİLİR. **Düzeltme:** üç çakışan extern def `_raw` sonekiyle yeniden
adlandırıldı (`nox_os_arg_count_raw`/`nox_os_arg_raw`/`nox_os_exit_raw`)
— `nox.http`de ZATEN kurulu olan "`_raw` soneği = ham extern def, ÜSTÜNDE
KISA adlı bir Nox sarmalayıcısı var" kuralına UYGUN. `nox_os_getenv_raw`
ZATEN bu soneği taşıdığından (sarmalayıcı "getenv" → mangle "nox_os_
getenv", FARKLI dize) çakışmadı; `has_env`in kısa adlı bir sarmalayıcısı
hiç OLMADIĞINDAN o da çakışmadı. **Genel kural (gelecekteki HER stdlib
modülü İÇİN geçerli):** bir extern def'in adı, KENDİ Nox sarmalayıcısının
mangled hâliyle ÇAKIŞMAMALIDIR — ya extern def `_raw` soneği TAŞIMALI ya
da sarmalayıcı FARKLI bir kısa isme SAHİP olmalıdır.

**Zig 0.16 API sürprizi:** `std.fs.cwd()`/klasik `std.fs.Dir` API'si bu
Zig sürümünde `std.Io` bağlamı DIŞINDA (rastgele bir runtime kabuğu
fonksiyonundan) KULLANILAMIYOR (yalnızca `std.Io.Dir`, `io: std.Io`
parametresi GEREKTİRİYOR — `compiler/main.zig`de `init.io` üzerinden
MEVCUT ama runtime kabuklarında YOK). `runtime/stdlib_shims/fs.zig` bu
yüzden ham libc çağrılarıyla (`std.c.open`/`std.c.read`/`std.c.write`/
`std.c.close`, `std.c.O` bayrak yapısı) yazıldı — `http_client.zig`/
`http_server.zig`nin ZATEN kurduğu "ham soket" desenle AYNI yaklaşım.

**Bilinçli v1 sınırlaması:** `nox_os_arg`in sınır dışı `i` İÇİN istisna
RAISE ETMEK YERİNE BOŞ bir `str` DÖNMESİ — YENİ bir `genParseOrRaise`/
`genStrIndex` tarzı checker/codegen özel-durumu GEREKTİRMEMESİ İÇİN
BİLİNÇLİ bir kapsam-daraltma kararı (yalnızca GERÇEKTEN başarısız
OLABİLEN `getenv`/dosya G/Ç işlemleri sıradan `if`/`raise` İLE istisna
fırlatır).

**Doğrulama:** golden testler (`os_args_basic.nox` — `arg_count() >= 1`/
`len(arg(0)) > 0`/sınır dışı `arg(9999)`in boş döndüğü, tam yol
DETERMİNİSTİK OLMADIĞINDAN karşılaştırma bilinçli olarak DOLAYLI;
`os_getenv_missing_raises.nox`; `fs_read_write_roundtrip.nox`;
`fs_read_missing_raises.nox`). "Kasıtlı boz → kırmızıyı doğrula → düzelt"
ritüeli İKİ AYRI değişiklik İÇİN uygulandı: (1) `_raw` soneği KALDIRILINCA
`registerExternFunc`in AYNI "fonksiyon zaten tanımlı" hatasının YENİDEN
üretildiği doğrulandı; (2) `genMain`in `nox_os_init` çağrısı KALDIRILINCA
`os_args_basic` testinin (yalnızca BU testin) kırmızıya döndüğü
doğrulandı. `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil.

---

### 3.41 Alt-Faz K — `nox.time` + `nox.test` Modülleri

**Tasarım:** `stdlib/nox/time.nox` (`now_ms() -> int`, `sleep_ms(ms: int) ->
None`) — YENİ `runtime/stdlib_shims/time.zig`ye ince `with_rt` OLMAYAN
(ikisi de ARC-dışı, salt `int` alır/döner) `extern def` sarmalayıcıları.
`stdlib/nox/test.nox` (`assert_eq_int`/`assert_eq_str`/`assert_eq_float`/
`assert_true`) TAMAMEN saf Nox — HİÇ Zig/extern def GEREKMEDİ (`nox.math`nin
`min`/`max`/`abs`iyle AYNI kategori, YALNIZCA `==`/`!=`/`raise`/`str()`
(Alt-Faz E) kullanılarak yazıldı). Nox'ta fonksiyon overload'ı OLMADIĞINDAN
TEK bir generic `assert_eq` YERİNE tipe göre AYRI adlı üç fonksiyon (Faz
başlangıcındaki planın ÖNGÖRDÜĞÜ gibi).

**`nox_time_now_ms_raw`:** `std.c.clock_gettime(.REALTIME, &ts)` + saniye/
nanosaniyeyi milisaniyeye çeviren tamsayı aritmetiği (`ts.sec * 1000 +
ts.nsec / 1_000_000`) — Unix epoch milisaniye. **`nox_time_sleep_ms_raw`:**
`std.c.nanosleep` (`http_server.zig`nin `req_ts`/`nanosleep` çağrısıyla
AYNI, ZATEN kanıtlanmış API).

**Alt-Faz J'nin isim-çakışması dersi BURADA da (proaktif olarak) uygulandı:**
`now_ms`/`sleep_ms` adlı KISA sarmalayıcılar `nox_time_now_ms`/`nox_time_
sleep_ms`e mangle OLACAĞINDAN, extern def'ler BAŞTAN `_raw` sonekiyle
(`nox_time_now_ms_raw`/`nox_time_sleep_ms_raw`) adlandırıldı — bu ALT-FAZDA
YENİ bir hata OLUŞMADI, çünkü ders ÖNCEDEN uygulandı (kasıtlı-boz-restore
İLE doğrulandı: soneği KALDIRINCA AYNI "fonksiyon zaten tanımlı" hatası
YENİDEN üretildi).

**Bilinçli v1 sınırlaması (KALICI, gelecekte bir "kooperatif sleep" fazı
GEREKTİRİR):** `sleep_ms` bir fiber İÇİNDEYKEN bile GERÇEKTEN BLOKE OLUR —
D.0'ın kqueue reaktörü YALNIZCA soket G/Ç'si İÇİN hazır-olma bildirimi
sağlar, bir ZAMANLAYICI (timer/`EVFILT_TIMER`) olayı İÇİN DEĞİL. `nox.http.
serve` İÇİNDEKİ bir `handle`in `sleep_ms` çağırması TÜM sunucuyu o süre
boyunca DURDURUR — `stdlib/nox/time.nox`nin KENDİ belge notunda AÇIKÇA
belgelendi.

**Doğrulama:** golden testler — `time_now_monotonic_increases.nox`
(`now_ms() > 0` VE `sleep_ms`den SONRAKİ okumanın ÖNCEKİNDEN KÜÇÜK
OLMADIĞI — kesin bir eşik DEĞİL, gerçek zaman testlerinin doğasında olan
gerekçeyle DOLAYLI/gevşek bir karşılaştırma), `test_assert_eq_pass.nox`
(dört assert fonksiyonunun HEPSİ başarı yolunda), `test_assert_eq_fail_
raises.nox` (`assert_eq_int`in başarısızlık mesajını doğru biçimlendirdiği
VE `AssertionError`in `try`/`except`le yakalanabildiği). "Kasıtlı boz →
kırmızıyı doğrula → düzelt" ritüeli İKİ AYRI değişiklik İÇİN uygulandı:
(1) `_raw` soneği KALDIRILINCA AYNI isim-çakışması hatası YENİDEN
üretildi; (2) `assert_eq_int`in `!=` koşulu KASITLI OLARAK `==`ye
çevrilince HEM `test_assert_eq_pass` HEM `test_assert_eq_fail_raises`
testlerinin (yalnızca BU İKİSİNİN) kırmızıya döndüğü doğrulandı. `zig
build test` (Debug + `-Doptimize=ReleaseFast`) yeşil.

---

### 3.42 Alt-Faz L — `nox.json` Modülü (TAM Kapsam: Strateji 1)

Kullanıcının "tam olarak yapalım" talimatıyla seçilen **Strateji 1**
uygulandı: `nox.json.decode`, Zig'in `std.json`iyle (savaş-test edilmiş,
keyfi iç içe/kaçış/sayı ayrıştırması) ayrıştırır — Nox tarafında karakter
karakter bir ayrıştırıcı YAZILMADI. Bu, plandaki riskli/hiç denenmemiş
teknik doğrulandı: **Zig KAYNAK kodu (önceden derlenmiş `noxrt.o`), QBE'nin
SONRADAN derleyeceği bir Nox sembolünü çağırıyor** — şimdiye kadar hep
tersi olmuştu.

**Temsil:** `JsonValue` (kind/b/n/s/arr/keys/vals, 7 alan) **`stdlib/nox/
json.nox`DA DEĞİL, `stdlib/nox/core.nox`DA** tanımlı — bkz. aşağıdaki
"Bağlama zamanı" bulgusu, bunun NEDEN zorunlu olduğunu açıklıyor. `arr`/
`keys`/`vals` HER ZAMAN gerçek (gerekmediğinde SIFIR elemanlı) `list[T]`
değerleridir — Zig tarafı bunları `genListLit`in AYNI bayt düzeninde (8
bayt uzunluk başlığı + işaretçiler) EL İLE inşa eder (Alt-Faz F'nin
`nox_test_make_list`iyle AYNI teknik, şimdi `list[JsonValue]`e de
genişletilmiş) — bu sayede Nox'un "boş liste literali yok" kısıtlamasına
HİÇ takılınmaz (bu kısıtlama yalnızca KAYNAK sözdizimi/checker seviyesinde
geçerlidir) VE **`MAX_CHILDREN` gibi bir sınır GEREKMEZ** (gerçekten "tam"
— keyfi derinlik).

**Neden Zig `JsonValue`yi KENDİSİ ham bellek olarak inşa ETMEDİ:** her
sınıfın `class_id`si (`codegen.zig`nin `next_class_id` sayacı) DERLEME
SIRASINA bağlıdır — Zig'den GÜVENLE TAHMİN EDİLEMEZ. Bunun yerine Zig,
`stdlib/nox/core.nox`daki GERÇEK `nox_json_make_json_value` fonksiyonunu
çağırır (`JsonValue(...)`i saran sıradan bir Nox fonksiyonu) — doğru
`class_id`yi VE doğru ARC muhasebesini (zaten test edilmiş
`genConstructFromValues`/`__init__` yolu üzerinden) OTOMATİK doğru yapar.

**Bu alt-faz sırasında DÖRT ayrı, GERÇEK, önceden hiç test edilmemiş
compiler hatası bulundu** — hepsi "genuinely untested combination" deseninin
devamı (bu oturumun EN YOĞUN keşif turu):

1. **Öz-referanslı (self-referential) sınıf alanı desteklenmiyordu.**
   `codegen.zig`nin `registerClass`ı HER sınıfı TAMAMEN işleyip (alan
   tiplerini ÇÖZÜP) EN SONUNDA `self.classes.put` yapıyordu — bir sınıf
   KENDİ alan tipini çözerken KENDİ ADI HENÜZ `self.classes`da YOKTU
   (`error.Unsupported`). checker.zig bunu ZATEN `collectClassNames`→
   `registerSignatures` iki geçişli deseniyle çözmüştü, ama codegen bu
   iki geçişten YOKSUNDU — plan dosyasının "doğrulanmamış varsayım" notu
   TAM OLARAK BUNU öngörmüştü. **Düzeltme:** `generateModule`e TÜM sınıf
   adlarını (alanlar ÇÖZÜLMEDEN ÖNCE) boş bir yer tutucuyla `self.classes`a
   ÖNCEDEN ekleyen bir ön-geçiş eklendi. **Etki alanı BEKLENENDEN ÇOK DAHA
   GENİŞ çıktı:** `JsonValue` artık core.nox'ta (HER programa koşulsuz
   dahil) olduğundan, bu düzeltme olmadan LİTERALMENTE HER TEK golden test
   (65/66) başarısız oluyordu — kasıtlı-boz-restore bunu doğruladı. Ayrıca
   MEVCUT bir test (`rejected_class_field_forward_ref.nox`, "ileri
   referanslı sınıf alanı reddedilir" testi) artık YANLIŞ hale geldi —
   `class_field_forward_ref.nox`e yeniden adlandırılıp POZİTİF bir golden
   teste (A/B'nin gerçekten inşa edilip çalıştığını kanıtlayan) çevrildi.
2. **`len()` yalnızca `str` içindi, `list[T]` DEĞİL.** `nox.json`nin
   `array_len`/`object_len`si `len(v.arr)` çağırmayı gerektirdi —
   checker'ın `len` özel-işlemesi `list` tipini KABUL ETMİYORDU. **Düzeltme:**
   checker'a `list` de eklendi; codegen'in `len` dalına `v.heap == .list`
   durumunda `strlen` YERİNE listenin 8 baytlık uzunluk başlığını doğrudan
   `loadl`layan bir dal eklendi — GENEL bir genişletme (JSON'a özgü değil).
3. **`return list[i]` bir ödünç referansı retain ETMEDEN dışarı veriyordu
   — EN İNCE, EN GEÇ bulunan hata.** `nox.json.array_get`in `return
   v.arr[i]`si — `genIndex`, TABAN (`v`) temporary OLMADIĞINDA (adlandırılmış
   bir parametre) okunan elemanı BİLEREK retain ETMEZ (bir `.attribute`
   okuması gibi ödünç). Ama `returnNeedsRetain` (dönüş ifadesinin çağırana
   YENİ bir sahiplik olarak retain edilip edilmeyeceğine karar veren
   fonksiyon) `.identifier`/`.attribute` dallarına SAHİPTİ ama **`.index`
   dalına SAHİP DEĞİLDİ** — `else => false`e düşüyordu. Sonuç: listenin
   PAYLAŞTIĞI referans retain EDİLMEDEN çağırana "kendi sahipliğiymiş gibi"
   (bir `.call` sonucu) veriliyordu; çağıran bunu SERBEST BIRAKINCA
   listenin KENDİ referansı ERKEN sıfıra iniyor, listenin KENDİSİ SONRADAN
   AYNI elemanı TEKRAR serbest bırakmaya çalışınca **çift-serbest-bırakma**
   (`"incorrect alignment"` panikiyle KENDİNİ gösteren bellek bozulması)
   oluşuyordu. **Keşif süreci ÖNEMLİ:** `[1]`/`[1,2]` (yalnızca `array_len`
   çağıran) ÇÖKMEDİ; yalnızca `array_get`in GERÇEKTEN ÇAĞRILDIĞI testler
   çöktü — bu YÜZDEN ilk golden test taslakları (yalnızca uzunluk/tip
   kontrolü) bu hatayı MASKELİYORDU, tıpkı Alt-Faz F/G'nin "adlandırılmış
   yerel bağlama maskeler" dersinin BİR BAŞKA örneği. **Düzeltme:**
   `returnNeedsRetain`e `isAliasingExpr`in AYNI `.index` dalıyla BİREBİR
   eşleşen bir dal eklendi (`!isTemporaryExpr(idx.obj.*)`) — taban
   temporary İSE `genIndex` zaten KENDİ içinde retain ETTİĞİNDEN (`.call`
   tabanlı `make_list()[0]` deseni) burada TEKRAR retain etmemek İÇİN.
4. **`extern def`in DÖNÜŞ tipi olarak sınıf desteklenmiyordu +
   `class_name` kopyalanmıyordu.** `isFfiSafeType` `.class => false`
   diyordu — `nox_json_decode_raw(s: str) -> JsonValue` reddediliyordu.
   **Düzeltme:** Alt-Faz F'nin `isFfiSafeListReturnType`iyle AYNI ilkeyle
   (yalnızca DÖNÜŞ, PARAMETRE değil) yeni `isFfiSafeClassReturnType`
   eklendi. AYRICA `genCall`in extern dalının döndürdüğü `Value`
   `class_name`i KOPYALAMIYORDU (Alt-Faz F'nin `elem_qtype`/`elem_heap_info`
   eksikliğiyle AYNI KATEGORİDE bir hata, `JsonValue` dönen İLK extern def
   olana kadar hiç fark edilmemişti) — düzeltildi.

**Zig'in noxrt.o'sunun HER programa koşulsuz bağlanması nedeniyle ortaya
çıkan bağlama-zamanı sorunu (ve iki AYRI çözümü):** `nox_json_make_json_value`
BAŞLANGIÇTA `stdlib/nox/json.nox`da (yalnızca `import nox.json` yapan
programlara dahil) tanımlıydı — ama `runtime/stdlib_shims/json.zig`nin
makine kodu (`nox_json_decode_raw` DAHİL, `lib.zig`nin `comptime { _ =
json_shim; }`ıyla ZORLA analiz edilir) HER `noxrt.o`ya KOŞULSUZ girer, o da
HER derlenen Nox programına (nox.json import ETMESE BİLE) bağlanır. Bu,
`nox.json` import ETMEYEN HER golden testin `cc` bağlama adımının
"undefined symbol: _nox_json_make_json_value" hatasıyla ÇÖKMESİNE yol
açtı. **Çözüm 1 (kalıcı):** `JsonValue`/`nox_json_make_json_value` `stdlib/
nox/core.nox`a taşındı (ValueError/IndexError İLE AYNI "her programa
koşulsuz dahil" ilkesi) — GERÇEK `noxc` derleme yolunda (`module_loader.
resolveImports`) bu sembol artık HER ZAMAN mevcuttur. **Çözüm 2 (asıl
kalıcı çözüm, Çözüm 1'in KENDİSİ YETMEDİĞİ İÇİN gerekli):** `tests/compat/`
altındaki BAZI test dosyaları (`extern_ffi_test.zig`, `hpy_call_golden_test.
zig`) `module_loader.resolveImports`ı HİÇ ÇAĞIRMAYAN, ham `parser.parseModule`
kullanan DAHA ESKİ bir test altyapısı kullanıyor — bu testler İÇİN core.nox
YİNE DE birleştirilmiyor. AYRICA `zig build test`nin `runtime/lib.zig`yi
DOĞRUDAN test eden `noxrt_test` hedefi HİÇBİR Nox programı İÇERMİYOR —
sembol orada YAPISAL OLARAK asla var olamaz. Bu İKİ durumu ÇÖZMEK İÇİN
`nox_json_make_json_value`nin sabit bir `extern fn` (link-time çözülen)
YERİNE **`dlsym` ile ÇALIŞMA ZAMANINDA aranan** bir fonksiyon işaretçisine
çevrildi (`dlopen(null, .{.NOW=true})` + `dlsym(handle, "nox_json_make_json_value")`,
lazy/memoized) — sembol GERÇEKTEN mevcutsa (GERÇEK bir `noxc` programı
çalışırken HER ZAMAN mevcuttur) bulunur; DEĞİLSE (yukarıdaki izole test
bağlamları) `nox_json_decode_raw` zaten HİÇ ÇAĞRILMADIĞINDAN (o testler
`nox.json` kullanmaz) sorun OLMAZ. Bu, STANDART C nesne-dosyası bağlama
semantiğinin (hangi `.o`nun ÖNCE derlendiği önemsiz, NİHAİ bağlamada TÜM
semboller çözülebilmeli) ÖTESİNE geçip ÇALIŞMA ZAMANI sembol çözümlemesine
başvuran, projede YENİ bir teknik.

**ARC muhasebesi — "kim retain eder, kim serbest bırakır" (yeni, genel bir
ders):** `JsonValue.__init__`in `self.field = param` ataması, `param` bir
`.identifier` olduğundan (`isAliasingExpr`) HER heap-yönetimli argümanı
BİR KEZ retain eder. Nox KAYNAĞINDAN yapılan çağrılarda bu fazlalık HER
ZAMAN argüman olarak geçirilen İSİMLENDİRİLMİŞ yerel değişkenin KENDİ
kapsam-sonu release'iyle dengelenir. Zig KAYNAK KODUNDAN çağrıldığında İSE
böyle bir kapsam-sonu release HİÇ üretilmez — bu yüzden `runtime/
stdlib_shims/json.zig`nin `callMakeJsonValue` sarmalayıcısı HER çağrıdan
SONRA `s`/`arr`/`keys`/`vals` İÇİN elle BİR telafi edici `nox_rc_predecrement`
yapar (asla gerçek serbest bırakmayı TETİKLEMEZ, çünkü dönen `JsonValue`nin
karşılık gelen alanı HÂLÂ bir referans TUTAR). **Bu, Zig'in bir Nox
fonksiyonunu ÇAĞIRDIĞI HER gelecekteki senaryo İÇİN geçerli GENEL bir
kural** — Nox KAYNAĞINDAN çağrıldığında "bedava" gelen kapsam-sonu
release'in YOKLUĞUNU HER ZAMAN telafi etmek gerekir.

**Doğrulama:** golden testler — `json_decode_nested.nox` (iç içe dizi/obje,
sayı/string/bool/null KARIŞIK), `json_encode_roundtrip.nox` (decode→encode
AYNI kanonik metni üretir, encode edilen metin TEKRAR decode edilip bir
alanı doğrulanır), `json_decode_malformed_raises.nox` (`JsonError` doğru
`raise` eder). Yukarıdaki DÖRT hatanın HER BİRİ AYRI AYRI kasıtlı-boz-
restore İLE doğrulandı (öz-referans ön-geçişi kaldırılınca 65/66 test
kırmızıya döndü; `len` list desteği kaldırılınca 3 JSON testi kırmızıya
döndü; `returnNeedsRetain`in `.index` dalı kaldırılınca YALNIZCA `array_get`
ÇAĞIRAN 2 test çöktü; `callMakeJsonValue`nin telafi edici predecrement'leri
kaldırılınca AYNI 2 test DebugAllocator "memory address leaked" raporuyla
kırmızıya döndü). `zig build test` (Debug + `-Doptimize=ReleaseFast`)
yeşil — **stdlib fazının E'den L'ye TÜM yol haritası TAMAMLANDI.**

---

## 3.5 Dil Stabilizasyonu — Faz M/N (Derleyici/Çalışma Zamanı Performansı + Stdlib Benchmark'ları)

`nox.http` sonrası stdlib yol haritası (Alt-Faz E–L) TAMAMLANDIKTAN SONRA
başlatılan bir **dil stabilizasyonu** aşaması — derleyicinin/çalışma
zamanının HER AŞAMASINDA darboğaz analizi + optimizasyon (Faz M) VE
stdlib kütüphanelerinin (özellikle `nox.http`) benchmark'lanması (Faz N).
Tam sıra/gerekçe İÇİN bkz. plan dosyası (`/Users/melihburakmemis/.claude/
plans/witty-cuddling-nebula.md`, "Faz M–N" bölümü) — bu bölüm YALNIZCA
TAMAMLANAN alt-fazların doğrulama kayıtlarını tutar, her alt-faz kendi
numaralı alt bölümüne (§3.5.1, §3.5.2, ...) sahiptir.

### 3.5.1 M.2 — `noxc` CLI'sini Sessizleştirme (`--dump`/`-v` opt-in)

**Sorun:** `compiler/main.zig` HER `noxc` çağrısında KOŞULSUZ olarak TAM
sahiplik analizi raporu + AST dökümü basıyordu (`--- sahiplik analizi ---`/
`--- AST ---`) — `core.nox` artık HER programa koşulsuz dahil olduğundan
(stdlib fazı §E), HER derleme (kullanıcı asla okumasa BİLE) TÜM stdlib
çekirdeğinin AST'sini/sahiplik kararlarını da FORMATLAYIP YAZIYORDU.

**Düzeltme:** `main`e basit bir argüman ayrıştırma döngüsü eklendi —
`--dump`/`-v` bayrağı VERİLMEDİĞİ SÜRECE (yeni varsayılan) yalnızca hata
mesajları YA DA `derlendi: <yol>` başarı satırı basılır. **Yalnızca I/O
DEĞİL, hesaplama da tasarruf edilir:** `ownership.analyze` çağrısının
KENDİSİ (`report` değişkeni) yalnızca `verbose == true` İKEN yapılır —
`report` codegen'e HİÇ PARAMETRE olarak geçmediği (codegen KENDİ sahiplik
kararlarını dahili/bağımsız olarak üretir) doğrulandığı İÇİN bu güvenlidir.

**Golden test etkisi YOK:** `tests/golden/codegen_golden_test.zig`nin
`compileAndRun`ı `noxc`yi bir ALT SÜREÇ olarak ÇAĞIRMAZ — `nox.lexer`/
`nox.parser`/`nox.checker`/`nox.codegen`i DOĞRUDAN Zig kütüphane
çağrılarıyla kullanır (yalnızca `qbe`/`cc` alt süreçtir) — bu yüzden bu
değişiklik golden test süitini HİÇ ETKİLEMEDİ, yalnızca CLI'nin KENDİ
kullanıcı deneyimini/hızını.

**Doğrulama:** manuel doğrulama — bayraksız çalıştırma yalnızca `derlendi:
...` basıyor; `-v`/`--dump` eski TAM dökümü GERİ getiriyor. `zig build
test` (Debug + `-Doptimize=ReleaseFast`) yeşil (DEĞİŞMEDİ, beklenen —
golden test süiti `noxc` CLI'sini hiç kullanmıyor). `noxc`nin KENDİSİNİ
alt süreç olarak çağıran ayrı bir otomatik test bulunmadığından (mevcut
test altyapısında hiç böyle bir desen YOK), bu alt-faz İÇİN "kasıtlı boz
→ kırmızıyı doğrula → düzelt" ritüeli manuel gözlemle sınırlı kaldı.

### 3.5.2 N.7/M.3 — `dict[K,V]` Benchmark'ı + Doğrusal Aramadan Hash Tablosuna Geçiş

**N.7 (ÖNCE ölçümü):** `benchmarks/dict_bench.nox` — `dict[int,int]`e N=5000
anahtar `set` edip (artan sırayla, her biri `mevcut boyut`u tarayan bir
`findIndex` tetikler), SONRA HEPSİNİ `get` ile okuyan (HER biri yine
`mevcut boyut`u tarayan) bir stres testi — toplam maliyet O(n²).
`benchmarks/run.zig`nin `stress_benchmarks` dizisine eklendi (beklenen
çıktı `24995000`, analitik olarak `n*(n-1)` — `d[i]=i*2` toplamı).

**M.3 (Düzeltme):** `runtime/collections/dict.zig`nin `Dict` struct'ı ARTIK
`entries: ArrayListUnmanaged(Entry)` (DEĞİŞMEDEN korundu — `nox.http`in Zig
kabuğu `entries`i DOĞRUDAN `@import` edip gezdiğinden, bkz. §D.1 Keşif 4)
YANINDA yeni bir `index: std.HashMapUnmanaged(i64, usize, StrOrIntContext,
...)` (anahtar → `entries` içindeki KONUM) taşıyor — arama ARTIK O(1)
ortalama. `StrOrIntContext`in `hash`/`eql`i `str` anahtarlar İÇİN POINTER
DEĞİL, İÇERİĞİ (Wyhash/`strcmp`) kullanır (D.1'in Keşif 4'ünün AYNI
gerekçesi — `key_is_str` ÇALIŞMA ZAMANINDA belirlendiğinden context HER
çağrıda parametre olarak GEÇİRİLİR, `std.HashMapUnmanaged`in `*Context`
varyantları TAM BUNUN İÇİN var).

**Bulunan/önlenen ince bir tuzak:** bir `str` anahtar İÇERİK olarak AYNI
ama POINTER olarak FARKLI bir değerle "üzerine yazıldığında"
(`nox_dict_set`), yalnızca `entries[i]`nin DEĞERİNİ güncelleyip `index`in
KENDİ sakladığı (ESKİ, biraz SONRA `nox_str_release` İLE serbest
bırakılacak) anahtar pointer'ını DEĞİŞTİRMEDEN bırakmak, GELECEKTEKİ bir
aramanın (İÇERİK-tabanlı `eql` HER karşılaştırmada pointer'ı DEREFERANS
ettiğinden) bir kullanım-sonrası-serbest-bırakmaya yol açacağı ANLAŞILDI —
bu YÜZDEN üzerine yazma yolu HER ZAMAN `index.removeContext`+`putContext`
(yalnızca değer güncelleme DEĞİL) yapıyor.

**Doğrulama:** `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil —
MEVCUT `dict.zig` birim testleri (özellikle "str anahtar İÇERİK eşitliğiyle
bulunur" testi, k1→k2 İÇERİK-eşit-ama-POINTER-farklı üzerine yazma
senaryosu) DEĞİŞMEDEN geçti. "Kasıtlı boz → kırmızıyı doğrula → düzelt"
ritüeli: `index.removeContext`+`putContext` satırları KALDIRILINCA
`"str anahtar İÇERİK eşitliğiyle bulunur"` testi TAM OLARAK beklendiği
gibi `panic: cast causes pointer to be null` İLE ÇÖKTÜ (kullanım-sonrası-
serbest-bırakmanın SOMUT kanıtı) — düzeltme GERİ eklenince yeşile döndü.

**Ölçülen kazanç:** `dict_bench` (N=5000, ReleaseFast) `M.3 ÖNCESİ 8.7ms →
M.3 SONRASI 3.0ms` (~2.9x) — mutlak sayılar N=5000'de zaten küçük olduğundan
oran MÜTEVAZI görünüyor, ama ASİMPTOTİK fark (O(n²) → O(n)) DAHA BÜYÜK
N'lerde ÇOK daha belirgin olurdu; bu benchmark birincil amacı GELECEKTEKİ
regresyonları YAKALAMAK (N büyütülürse doğrusal aramanın KARESEL
kötüleşmesi, hash tablosunun DOĞRUSAL kalması AÇIKÇA görünür).

### 3.5.3 N.1/M.4 — `nox.http` Sunucusu: Fiber-Yığın Havuzu Kullanımı

**Bulgu:** `runtime/stdlib_shims/http_server.zig`nin `nox_http_serve_raw`ı
bağlantı fiber'ları İÇİN `fiber_mod.Fiber.create`yi DOĞRUDAN çağırıyordu —
bu HER ZAMAN taze bir 256 KiB yığın tahsis eder, `Scheduler`in fiber-yığın
HAVUZUNU (performans fazında `async_task_churn` İÇİN inşa edilmişti, bkz.
§3.24) HİÇ KULLANMIYORDU. Bağlantı fiber'ı TAMAMLANINCA `Scheduler.run()`ün
MEVCUT temizleme yolu (`destroyKeepStack`+`releaseStack`) yığını YİNE DE
havuza GERİ KOYUYORDU — yani havuz DOLUYORDU ama HİÇ ÇEKİLMİYORDU, her YENİ
bağlantı YİNE DE taze bir tahsis ödüyordu.

**N.1 metodolojisi — YENİ bir benchmark GEREKMEDİ:** `benchmarks/
http_bench.zig`nin MEVCUT metodolojisi (HER istek KENDİ bağlantısını açıp
`Connection: close` İLE kapatıyor, bkz. `doOneRequest`) ZATEN "bağlantı
çalkantısı" senaryosunun KENDİSİ — HER 4000 istek YENİ bir bağlantı
fiber'ı (dolayısıyla ÖNCEDEN her seferinde taze bir yığın tahsisi) demektir.
Bu yüzden AYRI bir "churn varyantı" yazmak YERİNE MEVCUT benchmark
DOĞRUDAN kullanıldı.

**Düzeltme (M.4):** `Scheduler.acquireStack`/`releaseStack` (ÖNCEDEN
`fn`, ARTIK `pub fn`) — `http_server.zig` ARTIK `spawn`ın KENDİSİYLE AYNI
`acquireStack()`+`Fiber.createWithStack` çiftini kullanıyor.

**Ölçüm SONUCU — dürüst bir bulgu:** ÖNCE (Fiber.create, havuzsuz) 5 koşu:
10254/10138/10142/10020/10126 istek/sn (ort. ~10136). SONRA (havuzlu) 4
koşu: 9516/10075/10034/9946 istek/sn (ort. ~9893). **İKİ dağılım ÖRTÜŞÜYOR
— bu benchmarkta İSTATİSTİKSEL olarak AYIRT EDİLEBİLİR bir kazanç
GÖZLEMLENMEDİ.** Muhtemel açıklama: macOS'ta 256 KiB'lik anonim bellek
mmap/munmap'i (sanal bellek İŞLEMLERİ, fiziksel sayfa TAAHHÜDÜ dokunma
ANINA kadar ERTELENİR) ZATEN ucuz, VE bu benchmarkın baskın maliyeti
muhtemelen TCP accept/connect/close syscall'ları VE ağ yığını
gecikmesidir (istek başına ~2ms ORTALAMA gecikme, 256 KiB tahsisin
KENDİSİNDEN muhtemelen ÇOK daha büyük). **Düzeltme YİNE DE KORUNDU** —
`spawn`ın KENDİ (kanıtlanmış, `async_task_churn`da GERÇEK bir kazanç
gösteren) desenine mimari TUTARLILIK sağlıyor VE farklı platformlarda
(ör. Linux'ta mmap/munmap maliyeti FARKLI olabilir) VEYA daha yüksek
bağlantı çalkantısı oranlarında fayda sağlayabilir — teorik doğruluğu
(gerçek, kod-okumasıyla DOĞRULANMIŞ bir kusur: havuz DOLUP HİÇ
ÇEKİLMİYORDU) bu benchmarkın ölçemediği bir kazanımdan BAĞIMSIZDIR.

**Doğrulama:** `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil
— MEVCUT `tests/compat/http_serve_golden_test.zig` (gerçek bir derlenmiş
`.nox` sunucu programına karşı GERÇEK bağlantılar) DEĞİŞMEDEN geçti,
`acquireStack`/`releaseStack` çiftinin fiber YAŞAM DÖNGÜSÜNÜ BOZMADIĞINI
kanıtlıyor. Ayrı, ÖZEL bir "havuz gerçekten çekiliyor mu" birim testi
YAZILMADI (mevcut e2e testin KAPSAMA alanına GÖRE orantısız bir YENİ test
altyapısı gerektirirdi) — CORRECTNESS zaten MEVCUT testlerle güvenceye
alındı, throughput kazanımı İSE YUKARIDA dürüstçe "gözlemlenemedi" olarak
raporlandı.

### 3.5.4 M.1 — `computeMustNotRaise`: O(F²) Naif Sabit-Nokta → O(F+E) Worklist

**Sorun:** `compiler/codegen_qbe/codegen.zig`nin `computeMustNotRaise`i
(bkz. §3.25) `while (changed)` İLE naif bir sabit-nokta hesabı yapıyordu —
HER turda TÜM `info_map`i (VE her fonksiyonun TÜM çağrı listesini) YENİDEN
tarıyordu. Uzun bir çağrı zincirinde (A→B→C→…→Z, Z güvensiz) güvensizlik
HER turda yalnızca BİR sıçrama ilerlediğinden bu fonksiyon SAYISINDA (F)
KARESEL (O(F²)) bir maliyetti. `core.nox` artık HER programa koşulsuz
dahil olduğundan (stdlib fazı §E) F HER ZAMAN büyük bir taban içeriyor.

**Düzeltme:** TERS çağrı grafiği (`callers_of: callee -> [caller, ...]`)
ÖNCEDEN inşa edilip GERÇEK bir worklist/kuyruk (yalnızca YENİ güvensiz
işaretlenen bir fonksiyonun ÇAĞIRANLARI kuyruğa eklenir) kullanılır — HER
fonksiyon/kenar EN FAZLA bir kez işlenir, O(F+E).

**Doğrulama:** `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil.
"Kasıtlı boz → kırmızıyı doğrula → düzelt" ritüeli: ters grafiğin YÖNÜ
(callee/caller) KASITLI OLARAK ters çevrilince (`caller_name` anahtar,
`callee` değer yapılınca — DOĞRU olması gereken TAM TERSİ), MEVCUT
transitif-yayılım testleri ("dolaylı (transitif) raise yine de yakalanır",
"dolaylı (3 katmanlı) yakalanmamış istisna hâlâ net şekilde sonlanır")
TAM OLARAK bekleneceği gibi kırmızıya döndü — bu İKİ test ZATEN bu tür bir
graf-yönü hatasını YAKALAMAK İÇİN yeterliydi, YENİ bir test YAZILMASINA
GEREK KALMADI. Yön geri düzeltilince yeşile döndü.

**Dürüst bir not — ölçülemeyen bir kazanım:** bu değişiklik `noxc`nin
KENDİ DERLEME süresini etkiler (üretilen ikilinin ÇALIŞMA hızını DEĞİL).
`import nox.http`/`nox.json`/`nox.strings`/`nox.math`/`nox.os`/`nox.fs`/
`nox.time`/`nox.test`nin HEPSİNİ birden İÇEREN bir program İLE `time noxc
...` denendi — sonuç `qbe`/`cc` alt süreç çağrılarının maliyeti YANINDA
BU analiz geçişinin maliyetinin ZATEN İHMAL EDİLEBİLİR olduğunu gösterdi
(MEVCUT fonksiyon sayısı F henüz O(F²)yi GÖZLE GÖRÜLÜR kılacak KADAR
büyük DEĞİL). **Bu düzeltme bu YÜZDEN BİR "gelecek-geçirmez kılma" (future-
proofing) önlemidir** — stdlib BÜYÜDÜKÇE F artacağından, O(F²)nin GİZLİ
maliyeti YALNIZCA o zaman GÖRÜLÜR OLURDU; şimdiden düzeltilmesi GELECEKTE
bir "neden `noxc` yavaşladı" ARAŞTIRMASINI ÖNLER.

### 3.5.5 N.6/M.6 — `nox.json` Benchmark'ı + Tek Arena'ya Geçiş

**N.6 (ÖNCE ölçümü):** `benchmarks/json_bench.nox` — 200 elemanlı, iç içe
bir JSON dizisi (`build_json`, string birleştirmeyle inşa edilir) 50 kez
`decode`+`encode` edilir, HER SEFERİNDE üretilen metnin uzunluğu toplanır
(deterministik: `384550`). `benchmarks/run.zig`nin `stress_benchmarks`ına
eklendi. **Debug modunda BEKLENENDEN ÇOK DAHA YAVAŞ (~26 saniye)** —
`json.zig`nin YOĞUN küçük-tahsis deseni `DebugAllocator`ın (zaten
belgelenmiş, bkz. §3.16) "yapay olarak yavaş" davranışını AŞIRI derecede
tetikliyor; bu YİNE DE kabul edilebilir çünkü `bench` adımı `test`
adımından TAMAMEN AYRI (`zig build test`, `run.zig`nin stres testlerini
HİÇ ÇALIŞTIRMAZ) — ReleaseFast'ta (`smp_allocator`) tamamen normal (~35ms).

**M.6 (Düzeltme):** `runtime/stdlib_shims/json.zig`nin `nox_json_decode_raw`ı
ARTIK `std.json.parseFromSlice` + `buildNode`nin TÜM geçici tahsislerini
(HER JSON düğümü/liste İÇİN AYRI `page_allocator.alloc` çağrısı YERİNE)
TEK bir `std.heap.ArenaAllocator` (`page_allocator`ı SARAN) ÜZERİNDEN
yapıyor — fonksiyon dönmeden ÖNCE `arena.deinit()` TEK seferde HEPSİNİ
serbest bırakıyor. **Ek sadeleştirme:** `std.json.parseFromSlice`nin
KENDİ `Parsed(T).deinit()`ı ARTIK ayrıca ÇAĞRILMIYOR — dış arena `deinit`
edildiğinde ZATEN İÇ İÇE (std.json'un KENDİ dahili arenası DAHİL) HER ŞEYİ
tek seferde temizliyor. `rt`/ARC'a GEÇEN `dupeToNoxStr`/`buildPtrList`
çıktıları (JsonValue ağacının KENDİSİ) ETKİLENMEDİ — onlar ZATEN AYRI/
`nox_rc_alloc` tabanlı.

**Ölçülen kazanç:** `json_bench` (ReleaseFast) **35.0ms → 15.8ms (~2.2x)**
— M.4/M.1'in AKSİNE bu DEFA net, tekrarlanabilir bir kazanç GÖZLEMLENDİ
(beklenen: sayısız küçük `mmap`/`munmap` YERİNE tek bir büyük tahsis +
bump-allocator, allocator overhead'i GERÇEKTEN azaltıyor — `oop_arc_churn`in
ARC havuzuyla KANITLADIĞI AYNI genel prensip, bkz. §3.24).

**Doğrulama:** `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil —
MEVCUT `nox.json` golden testleri (`json_decode_nested`, `json_encode_
roundtrip`, `json_decode_malformed_raises`) DEĞİŞMEDEN geçti (davranış
AYNI, yalnızca ayırıcı STRATEJİSİ değişti). Ayrı bir kasıtlı-boz-restore
GEREKMEDİ — bu değişiklik GÖZLEMLENEBİLİR bir davranış farkı YARATMIYOR
(yalnızca performans), bu yüzden PERFORMANS ölçümünün KENDİSİ (temiz,
tekrarlanabilir ÖNCESİ/SONRASI karşılaştırması) doğrulamanın ASIL kanıtı.

### 3.5.6 N.2-N.5 — `nox.strings`/`nox.math`/`nox.os`+`nox.fs`/`nox.time` Benchmark'ları

Bu dört modülün HİÇBİRİNİN benchmark kapsamı YOKTU (yalnızca golden/birim
testleri). Amaç bir darboğaz BULMAK DEĞİL — gelecekteki regresyonları
YAKALAMAK ve (özellikle `nox.math` İÇİN) "darboğaz YOK" bulgusunu
SOMUTLAŞTIRMAK. `benchmarks/run.zig`nin `stress_benchmarks`ına eklendi
(ReleaseFast sonuçları):

- **`strings_bench.nox`** (N.2): `trim`/`upper`/`lower`/`replace`/`split`/
  `join`/`contains`/`starts_with`/`ends_with`/`index_of`nin HEPSİNİ 2000
  kez zincirleyen bir döngü — `min=5.7ms`.
- **`math_bench.nox`** (N.3): `sqrt`/`pow`/`floor`/`ceil` (ÇIPLAK, Alt-Faz
  I'nin asimetrisi) + `nox.math.min`/`max`/`abs` (NİTELİKLİ) 100.000 kez —
  `min=3.5ms`. **"Darboğaz YOK" bulgusu DOĞRULANDI** — çıplak `libm`
  çağrılarının maliyeti GERÇEKTEN ihmal edilebilir.
- **`os_fs_bench.nox`** (N.4): `nox.os.arg_count()` 20.000 kez + `nox.fs.
  write_string`/`read_to_string` roundtrip (10 KB'lik bir metin) —
  `min=2.8ms`. `fs.zig`nin 4096 baytlık parça-okuma döngüsü BU boyutta
  HİÇ maliyetli değil.
- **`time_bench.nox`** (N.5): `nox.time.now_ms()` 200.000 kez (`clock_
  gettime` sarmalayıcısı) — `min=5.4ms`.

**Doğrulama:** `zig build test` yeşil (bu benchmark'lar `test` adımının
DIŞINDA, YALNIZCA `bench`); `zig build bench -Doptimize=ReleaseFast`
17/17 stres testi (11 eski + `dict_bench`/`json_bench`/BU DÖRDÜ) BAŞARIYLA
tamamladı. Ayrı bir kasıtlı-boz-restore GEREKMEDİ (bu maddeler YENİ bir
davranış/düzeltme İÇERMİYOR, yalnızca kapsam genişletmesi).

### 3.5.7 M.5 — `nox.http` İstemci Thread Havuzu: Değerlendirildi, Ertelendi

Plan, M.5'in (her `nox.http.get`/`post` çağrısı İÇİN `std.Thread.spawn`
YERİNE sabit boyutlu bir iş parçacığı havuzu+kuyruğu) UYGULANMASINI N.1'in
ÖLÇÜMÜNE KOŞULLU kılmıştı — "gerçekten baskın olduğu KANITLANMADAN
yapılmayacak". **Değerlendirme sonucu:** N.1/M.4'ün ölçtüğü şey `nox.http.
serve`nin (SUNUCU tarafı, bağlantı-başına fiber) davranışıydı —
`benchmarks/http_bench.zig`nin istemci tarafı (`doOneRequest`) HAM
soketlerle ÇALIŞAN bir test kabuğudur, `nox.http.get`/`post`in (İSTEMCİ
kabuğunun KENDİ thread-per-request mekanizması) GERÇEK yolundan HİÇ
GEÇMEZ — yani M.5'in KENDİ maliyetini ÖLÇEN bir benchmark HİÇ YOK.
Böyle bir benchmark İNŞA ETMEK (Nox tarafından `nox.http.get` çağıran
GERÇEK bir istemci programı + AYRI bir sunucu) VE ardından M.5'in
KENDİSİNİ (kuyruk + havuz + senkronizasyon İÇEREN GERÇEK bir mimari
genişleme) uygulamak, bu stabilizasyon turunun KAPSAMI dışına taşan bir
YATIRIM — **BİLİNÇLİ OLARAK ERTELENDİ**, plan dosyasının kendi
gerekçesiyle TUTARLI ("KANITLANMADAN yapılmayacak").

---

### 3.5.8 M.7 — `lowlevel` Arena Tutamacı Havuzlaması

§3.25'te `lowlevel_arena` benchmark'ı 9.9x'te SABİT kalmış, gelecekteki bir
faz için not edilmişti (diğer benchmark'lar performans fazında 20-30x'e
ulaşırken bu tek başına geride kalıyordu). Sebep: `nox_arena_create`/
`nox_arena_destroy` (`runtime/alloc/lowlevel.zig`), HER `lowlevel` blok
girişi/çıkışında HEM `ArenaHandle` struct'ının KENDİSİNİ HEM arenanın
kendi (child allocator'a giden) İLK arabellek parçasını tazeden tahsis
edip TAMAMEN serbest bırakıyordu — ARC nesneleri İÇİN performans fazında
ZATEN çözülmüş olan AYNI sorun (bkz. `runtime/alloc/arc.zig`'in
`pool_free_lists`i), arena tutamaçları İÇİN henüz ele alınmamıştı.

**Düzeltme:** ARC havuzuyla AYNI Release-only prensip (`use_pool =
builtin.mode != .Debug` — Debug modunda `DebugAllocator`ın TAM güvenlik
ağı KORUNUR, davranış BİREBİR değişmedi). `runtime/alloc/asap.zig`'in
`RuntimeState`ine tek bir `arena_pool: ?*anyopaque` alanı eklendi (ARC'ın
çok-sınıflı `pool_free_lists`inin AKSİNE, `ArenaHandle` HER ZAMAN AYNI
boyutta olduğundan TEK bir sınıf yeterli — `lowlevel.zig`'in kendisi
`ArenaHandle`'a bir `next: ?*ArenaHandle` alanı ekleyip bunu `@ptrCast`
ile güçlü tipe çevirerek `asap.zig`↔`lowlevel.zig` arasında dairesel
import GEREKMEDEN bir LIFO serbest liste kurar). `nox_arena_destroy`,
Release modlarında `handle.arena.deinit()` YERİNE Zig'in KENDİ
`ArenaAllocator.reset(.retain_capacity)`'sini çağırır (arabelleği SERBEST
BIRAKMAZ, yalnızca "bump" işaretçisini başa sarar) ve `handle`'ın
KENDİSİNİ yok etmek yerine `state.arena_pool`a geri koyar; `nox_arena_create`
bu havuzdan ÖNCE çekmeyi dener, yalnızca boşsa taze tahsis eder.

**Ölçüm (break/restore ile temiz ÖNCE/SONRA çifti, `zig build bench
-Doptimize=ReleaseFast`, `compare_pairs`'ın `lowlevel_arena` çifti):**

| Durum | nox | python | oran |
|---|---|---|---|
| ÖNCE (havuzlama KAPALI, `use_pool = false` ile GEÇİCİ olarak devre dışı bırakılıp ölçüldü — §3.25'in 134.1ms'lik tarihi rakamıyla TUTARLI) | 133.0ms | 1311.0ms | 9.9x |
| SONRA (havuzlama AÇIK, gerçek kod) | 63.2ms–63.4ms (3 tekrar ölçüm) | 1317.2ms–1321.9ms | **~20.8x** |

Arena tutamacı havuzlaması TEK BAŞINA `lowlevel_arena`'nın çalışma süresini
YARIYA İNDİRDİ (~2.1x) — dilin diğer benchmark'larının ZATEN ulaştığı
20-30x aralığına bu senaryoyu da GETİRDİ. Kalan fark (arenanın KENDİ
İÇİNDEKİ, döngünün her turunda YENİDEN yapılan `Point`/`list[int]`
tahsislerinin bump-allocator maliyeti) bu fazın kapsamı DIŞINDA — arena
tutamacı SIFIRA indirilebilecek TEK ek maliyetti, ki O da ŞİMDİ giderildi.

**Doğrulama:** `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil;
Debug modunda `use_pool = false` OLDUĞUNDAN `runtime/alloc/lowlevel.zig`'in
MEVCUT testi ("arena tahsisi yazılabilir/okunabilir; destroy sonrası
sızıntı yok") davranış AÇISINDAN değişmedi. Break/restore: `use_pool`
GEÇİCİ olarak `false`'a sabitlenip `lowlevel_arena` yeniden ölçüldü (ÖNCE
satırı YUKARIDA), sonra `builtin.mode != .Debug`'a GERİ alındı — hem
`zig build test` hem `zig fmt` bu geri alım SONRASI tekrar doğrulandı.

### 3.5.9 M.8 — Metod Çağrıları İçin İstisna-Kontrolü Eleme: Değerlendirildi, Ertelendi

Plan, M.8'i (`computeMustNotRaise`'in serbest fonksiyon/kurucu kapsamını
METOD çağrılarına genişletmek) BİLEREK "en riskli/en sona bırakılan" madde
olarak işaretlemişti — checker'ın statik tip bilgisinin (bir metod
çağrısının HANGİ sınıf üzerinde olduğu) codegen'e taşınmasını gerektiren
GERÇEK bir mimari genişleme, M.1-M.7'nin HİÇBİRİYLE KIYASLANAMAYACAK kadar
büyük bir yüzey. Plan dosyasının KENDİSİ de "M.1-M.7 TAMAMLANIP ÖLÇÜLMEDEN
bunun GEREKLİ olup OLMADIĞI bile net değil" diyordu. M.1-M.7 artık HEPSİ
TAMAMLANDI VE ölçüldü — ama hiçbiri metod çağrısı hot-path'inin GERÇEKTEN
bir darboğaz OLDUĞUNU göstermedi (M.1'in KENDİSİ, serbest fonksiyon/kurucu
seviyesindeki AYNI analiz İÇİN "mevcut ölçekte F henüz yeterince büyük
DEĞİL" bulgusuna ulaşmıştı — metod çağrıları İÇİN de aynı sonucun geçerli
olması BEKLENİR). Kullanıcıya M.5 İLE AYNI çerçevede ("ölçülmeden büyük bir
mimari genişlemeye girişilmeyecek") sunuldu; **kullanıcı ERTELEMEYİ
seçti** — Faz M/N burada, TÜM ölçülebilir/orta-riskli maddeler (M.1-M.7,
N.1-N.7) TAMAMLANMIŞ olarak KAPANIYOR, M.8 gelecekteki bir faz İÇİN
(gerçek bir profil METOD çağrısı overhead'ini GERÇEKTEN baskın gösterirse)
NOT edildi.

---

## 3.6 Faz O/P — CLI Genişletmesi + Paket Yönetimi Planlaması, QBE/Cranelift Değerlendirmesi

Faz M/N (dil stabilizasyonu) tamamen bittikten sonra kullanıcı iki YENİ
faz açtı: (1) `noxc` için Cargo/Go tarzı gerçek bir CLI (`build`/`run`/
`test` alt komutları) + Go modeline benzer, merkeziyetsiz (GitHub tabanlı)
bir paket sistemi; (2) build sisteminde debug'da QBE, release'te
Cranelift AOT backend kullanma fikri ve bunun İÇİN ortak bir IR
katmanının gerekip gerekmediği sorusu. Kullanıcıyla netleşen kapsam:
paket sistemi şimdilik SADECE merkeziyetsiz (merkezi registry SUNUCUSU
İLERİDE eklenebilir bir tasarım noktası olarak bırakılıyor, ŞİMDİ
kurulmuyor); backend sorusu İÇİN önce bir araştırma/tasarım turu
(implementasyon DEĞİL) yapıldı. Tam tasarım kararları ve alt-faz
sıralaması `/Users/melihburakmemis/.claude/plans/witty-cuddling-nebula.md`
dosyasının "Faz O" ve "Faz P" bölümlerinde — bu bölüm yalnızca Faz P'nin
(backend araştırması) SONUCUNU özetler, çünkü Faz P bir "araştırıldı,
ŞİMDİLİK ertelendi" KARARIdır, kod değişikliği İÇERMEZ (Faz O'nun P.1-P.8
alt-fazları AYRICA, her biri KENDİ İlke #7 doğrulamasıyla, uygulanacak).

### 3.6.1 Faz P — QBE/Cranelift İkili Backend Sorusu: Araştırma Sonucu

**Bulgu 1 — mevcut codegen QBE'ye aşırı sıkı bağlı:**
`compiler/codegen_qbe/codegen.zig` (4206 satır) tek-geçişli, doğrudan-
metne emisyon yapıyor — hiçbir ara temsil yok. **410 ayrı**
`self.out.writer.print(...)` çağrı sitesi QBE mnemonic/sözdizimini
doğrudan gömüyor. `Value.text` zaten önceden render edilmiş bir QBE
operandı (soyut bir SSA id değil); blok/etiketler düz string'ler, hiçbir
CFG yapısı yok. Ortak bir IR (QBE-metin VE Cranelift emitter'ı iki
backend olarak) `codegen.zig`'in emisyon yüzeyinin neredeyse TAMAMININ
yeniden yazılması demek — büyük, riskli bir mühendislik yatırımı.

**Bulgu 2 — Cranelift'in Zig'den kullanımı olgun bir yol DEĞİL:**
Cranelift'in resmi bir C API'si YOK (Wasmtime'ın C API'si yalnızca
derlenmiş Wasm'ı ÇALIŞTIRMAK içindir, Cranelift'in IR-inşa API'sini
açmaz). Tek üçüncü-taraf C sarmalayıcı adayı (`craneliftc`) küçük,
bakımsız, Rust nightly gerektiriyor. Gerçekçi tek yol — kendi
`extern "C"` Rust shim'ini yazıp SONSUZA DEK bakımını üstlenmek —
Cranelift'in pre-1.0 (`0.132.x`), aylık kırıcı-değişikliğe açık sürüm
temposuna karşı. **Hiçbir emsal bulunamadı**: hiçbir Rust-dışı ana
dilden Cranelift'i FFI üzerinden sürücü olarak kullanan proje yok; en
yakın emsal (Inko dili, Rust'ta yazılı, FFI vergisi bile YOKKEN)
Cranelift'i değerlendirip AÇIKÇA REDDETTİ (dokümantasyon eksikliği +
bakım-riski gerekçesiyle), LLVM'e geçti. Ayrıca Cranelift AOT-native
değil JIT-öncelikli tasarlanmış — QBE'nin "endüstriyel performansın
%70'i, karmaşıklığın %10'u" felsefesiyle AYNI tasarım nişinde (LLVM'e
göre ölçülmüş %14-100 daha yavaş) — yani "LLVM kalitesine yakın"
öncülü YANLIŞ, Cranelift QBE'nin alternatifi değil, yaklaşık eşdeğeri.

**Doğrulanan ek bulgu (bu depoda):** proje ZATEN QBE **1.3**'ü
kullanıyor (`brew info qbe` → `stable 1.3`) — mevcut kurulum en güncel
QBE.

**Karar: Cranelift'i BU AŞAMADA takip ETME.** Gerekçe: (1) resmi/olgun
bir C API yok, (2) pre-1.0 kırılan bir API'yi sonsuza dek shim'le senkron
tutma yükü, (3) hiçbir emsal yok (Inko bile vazgeçti), (4) Cranelift
zaten QBE'nin yaklaşık eşdeğeri — hedeflenen "LLVM kalitesine yakın"
sonucu vermiyor. Mevcut tek-backend (QBE) mimarisi DEĞİŞTİRİLMİYOR.
Eğer gelecekte gerçekten LLVM-tier bir optimizasyon tavanı istenirse,
Cranelift YERİNE `llvm-c` (LLVM'in resmi, istikrarlı, onlarca yıllık C
API'si — Zig'in kendisi dahil sayısız dil bunu kullanıyor) değerlendirilmeli
— bu da AYRI, gelecekteki bir karar noktası olarak NOT ediliyor, şimdi
implementasyona girişilmiyor. Bu, M.5/M.8 ile AYNI "ölçülmeden/kanıtlanmadan
büyük mimari genişlemeye girişilmeyecek" disiplinidir.

### 3.6.2 Faz O §P.1 — Proje Kökü + Manifest Keşfi + Kaynak-Dizini Düzeltmesi

`noxc`, `stdlib/` ve `zig-out/lib/noxrt.o`yu CWD-göreli SABİT yol olarak
varsayıyordu (main.zig:135-138'in KENDİ "v0.1 basitleştirmesi" notu) —
yalnızca proje kökünden çalıştırılabiliyordu. Faz O'nun (CLI + paket
yönetimi, bkz. plan dosyası) İLK alt-fazı bunun ALTYAPISINI kurdu — bu
altyapı henüz `main.zig`ye BAĞLANMADI (bu, P.2'nin işi), yalnızca SALT
EKLEYİCİ bir modül olarak eklendi.

**Yeni dosya `compiler/project.zig`:**
- `Manifest` struct'ı (`name`, `entry` — `requires[]`/lockfile P.4'te
  eklenecek, `loadManifest`in `.ignore_unknown_fields = true` ile
  `std.json.parseFromSlice` kullanması sayesinde P.4'ün ekleyeceği
  `requires` alanını İÇEREN bir manifesti BUGÜNDEN ayrıştırmak da
  başarısız OLMAZ).
- `findProjectRoot(a, io, start_dir)`: `start_dir`den (mutlak yol olmalı)
  YUKARI doğru `nox.json` arar (Cargo/`go.mod` keşfiyle AYNI desen),
  bulamazsa (dosya sistemi köküne kadar) `null` döner — hata DEĞİL,
  manifestsiz bir `.nox` dosyasını derlemek GEÇERLİ bir kullanım biçimi.
- `resolveResourceDirs(a, io, nox_home_override)`: `noxc`nin KENDİ
  `stdlib/`/`noxrt.o`sunun mutlak yollarını hesaplar — `nox_home_override`
  VERİLMİŞSE (gelecekte `NOX_HOME` ortam değişkeni ya da bir testin
  geçici dizini) doğrudan KULLANILIR, VERİLMEMİŞSE `std.process.
  executableDirPathAlloc` (Zig 0.16'nın self-exe-dizini API'si) ile
  çalıştırılabilir dosyanın KENDİ dizininden (`<exe_dir>/..`) hesaplanır.

**`build.zig`:** `noxrt.o`yu `zig-out/lib/noxrt.o`ya kuran MEVCUT
`b.addInstallFile` (build.zig:81) deseninin YANINA, `stdlib/` ağacını
`zig-out/lib/nox/stdlib/`ye kuran bir `b.addInstallDirectory` eklendi —
`project.zig`nin `ResourceDirs`iyle (`<kök>/lib/nox/stdlib`, `<kök>/
lib/noxrt.o`) BİREBİR eşleşen kurulum düzeni.

**Bilinçli SALT EKLEYİCİ kapsam:** `module_loader.resolveImports`
(4 ayrı çağrı sitesinden — main.zig + 3 golden test dosyası — birebir
AYNI imzayla çağrılıyor) DAHİL mevcut hiçbir koda DOKUNULMADI. `main.zig`
şu an HÂLÂ eski CWD-göreli sabit yolları kullanıyor — bu modülün GERÇEKTEN
`build`/`run`/`test` alt komutlarına BAĞLANMASI Faz O'nun SONRAKİ
alt-fazıdır (P.2).

**Doğrulama:** YENİ `tests/unit/project_test.zig` (9 test — `findProjectRoot`
iç içe dizin/manifest-yok, `loadManifest` geçerli/`entry`-varsayılanlı/
bozuk-JSON/bilinmeyen-alan-toleranslı, `resolveResourceDirs` override'lı/
override'sız), `std.testing.tmpDir` tabanlı, GERÇEK dosya sistemi
işlemleriyle. Kasıtlı-boz-restore: `Manifest.entry`nin varsayılan değeri
GEÇİCİ olarak `"BROKEN_FOR_TEST"`e değiştirilip "entry verilmezse main.nox
varsayılır" testinin TAM OLARAK beklenen/bulunan farkıyla KIRMIZIYA
döndüğü doğrulandı, sonra GERİ alındı. `zig build test` (Debug +
`-Doptimize=ReleaseFast`) yeşil, `zig fmt` uygulandı.

### 3.6.3 Faz O §P.2 — CLI Alt Komut İskeleti (`build`/`run`/`test` + `-o` + Legacy Takma Ad)

`compiler/main.zig` yeniden yapılandırıldı — `noxc` artık Cargo/Go tarzı
alt komutlar tanıyor. Eski (v0.1'den beri var olan) `noxc [--dump|-v]
<dosya.nox>` çağrısı **BİREBİR AYNI DAVRANIŞLA** (aynı kullanım mesajı,
aynı `"derlendi: {stem}"` çıktısı, aynı çıkış kodları) `build` alt
komutunun bir takma adı olarak KORUNDU — geriye dönük uyumluluk ZORUNLU
kılındı ve bir golden testle DOĞRULANDI.

**Dispatch kuralı:** ilk bayrak-olmayan argüman `{"build","run","test",
"fmt","fetch","update"}` kümesinden biriyle eşleşiyorsa alt komut modu,
eşleşmiyorsa (ör. bir `.nox` yolu ya da `--dump`) eski tekil-dosya
(legacy) yoluna düşülür.

**`buildOne`** (eski `main()` gövdesinden ÇIKARILDI): lex→parse→import
çözümü→tip denetimi→[isteğe bağlı döküm]→codegen→qbe→cc boru hattının
TAMAMINI yürütüp üretilen binary'nin yolunu döner — hata durumlarında
ÖNCEKİ main.zig İLE BİREBİR AYNI mesaj/çıkış koduyla `std.process.exit(1)`
çağırır. `cmdBuild`/`cmdRun` bunu SARAR.

- **`noxc build [--dump|-v] [-o <çıktı>] <dosya.nox>`**: `buildOne`ı
  çağırıp `"derlendi: {s}"` basar (legacy İLE AYNI, yalnızca farklı bir
  `usage` dizgesiyle parametrelenmiş — `cmdBuild`e HEM `"noxc build ..."`
  HEM `"noxc [--dump|-v] ..."` (legacy) kullanım mesajları AYRI AYRI
  geçirilir, bu yüzden hatalı çağrı mesajları AYRIŞIR ama başarı yolu
  BİREBİR aynıdır).
- **`noxc run [--dump|-v] <dosya.nox> [-- argv...]`**: `buildOne`ı
  KAYNAĞIN YANINA DEĞİL, proje-yerel bir önbelleğe (`<proje_kökü_veya_
  dosyanın_kendi_dizini>/.nox/cache/bin/<uzantısız-ad>` — `project.
  findProjectRoot` KULLANILARAK, P.1'in "manifestsiz de geçerli" ilkesiyle
  TUTARLI şekilde manifest YOKSA dosyanın kendi dizinine DÜŞÜLEREK) derler;
  `std.process.spawn` (stdio'yu MİRAS ALARAK, `std.process.run`ın AKSİNE
  — çıktı YAKALANMAZ, doğrudan terminale akar) ile çalıştırıp çocuğun
  çıkış kodunu AYNEN yansıtır; `--`den SONRAKİ argümanlar çocuk sürece
  argv olarak iletilir.
- **`noxc test [yol]`**: Faz O §P.2'de `run` İLE AYNI mekanizmayı
  KULLANIR (TEK bir dosyayı derleyip çalıştırır) — `nox.test`in `raise`-
  ile-başarısız-olma modeliyle ZATEN tutarlı bir İLK adım. GERÇEK
  `*_test.nox` keşif/toplama kuralı §P.3'te bu davranışın YERİNİ alacak.
- **`noxc fmt`/`fetch`/`update`**: REZERVE edildi — `"henuz uygulanmadi"`
  mesajı (stderr) + çıkış kodu `1`, ÇÖKME yok. Gerçek implementasyonları
  sırasıyla §P.8/§P.5/§P.6.

**Keşfedilen ve düzeltilen GERÇEK bir build-grafiği eksikliği (kasıtlı-
boz-restore SIRASINDA bulundu, ASIL koddan BAĞIMSIZ bir bulgu):**
`build.zig`nin `test_step`i YALNIZCA `install_noxrt.step`e bağımlıydı —
`noxc`nin KENDİ kurulum adımına (`b.installArtifact` bir Step DÖNDÜRMEDİĞİ
İÇİN önceden hiç yakalanamamıştı) HİÇ bağımlı DEĞİLDİ. Bu, `zig build test`
çalıştırıldığında `tests/cli/subcommand_test.zig`nin (bir ALT SÜREÇ olarak
`zig-out/bin/noxc`yi çağıran İLK test dosyası) **BAYAT/eski bir `noxc`
ikilisine karşı** sessizce test çalıştırabileceği, GERÇEK bir CLI
regresyonunu KAÇIRABİLECEĞİ anlamına geliyordu. **Düzeltme:** `b.
installArtifact(noxc)` → `b.addInstallArtifact(noxc, .{})` (bir `Step`
döner) + `test_step.dependOn(&install_noxc.step)`. Bu KENDİSİ, `run`
alt komutunun dispatch anahtar kelimesi KASITLI olarak bozulup (`"run"` →
`"run_BROKEN"`) `zig build test`in YİNE DE (BAYAT ikili yüzünden) YEŞİL
kaldığı gözlemlenerek KEŞFEDİLDİ — düzeltme SONRASI AYNI bozulma GERÇEKTEN
kırmızıya döndü, doğrulandı, sonra geri alındı.

**Doğrulama:** YENİ `tests/cli/subcommand_test.zig` (5 test) — bu, `noxc`nin
bir ALT SÜREÇ olarak test edildiği İLK yer (mevcut golden testler `nox.
lexer`/`parser`/`checker`/`codegen`i DOĞRUDAN Zig kütüphane çağrısıyla
kullanıyor, `noxc`yi HİÇ subprocess olarak çağırmıyor): legacy-vs-`build`
davranış eşdeğerliği (ikisinin de `"derlendi: ..."` mesajını AYNI şekilde
**stderr**'e bastığı doğrulanır — `std.debug.print`in Zig'in KENDİ, bu
turda DEĞİŞTİRİLMEYEN, sabit davranışı gereği HER ZAMAN stderr'e yazması
NEDENİYLE; programın KENDİ `print()` çıktısı İSE gerçek stdout'a gider),
`-o` özelleştirmesi, `run`ın önbellek-yerleşimi + stdio-yansıtması, `run`ın
yakalanmamış istisnada sıfır-olmayan çıkış kodu yansıtması, `fmt`/`fetch`/
`update` rezervasyon mesajları. `zig build test` (Debug + `-Doptimize=
ReleaseFast`) yeşil, `zig fmt` uygulandı.

### 3.6.4 Faz O §P.3 — `noxc test` Gerçek `*_test.nox` Keşif Kuralı

P.2'nin `noxc test`i GEÇİCİ olarak `run` İLE AYNI (tek dosya derle+çalıştır)
mekanizmayı KULLANIYORDU. P.3 bunu GERÇEK bir keşif/toplama kuralıyla
DEĞİŞTİRDİ (tek-dosya modu GERİYE DÖNÜK UYUMLU olarak KORUNDU).

**YENİ dosya `compiler/pkg/test_runner.zig`:** `discoverTestFiles(a, io,
root)` — `root` (mutlak yol, bir DİZİN) altında `*_test.nox` İLE BİTEN
TÜM dosyaları `std.Io.Dir.walk` İLE özyinelemeli olarak bulur, mutlak
yollarını döner. **Bilinçli olarak SALT KEŞİF** — `qbe`/`cc`/`buildOne`e
HİÇ dokunmaz (`buildOne`, `main.zig`'e ÖZEL bir fonksiyon olduğundan,
dairesel import'tan KAÇINMAK için gerçek derleme+çalıştırma+özet
orkestrasyonu `main.zig`'in `cmdTest`inde yaşar).

**`noxc test [yol]` davranışı:**
- `yol` bir `.nox` DOSYASIYSA → P.2'nin eski davranışı (TEK dosya derle+
  çalıştır, çıkış kodu AYNEN yansıtılır) — GERİYE DÖNÜK UYUMLU.
- `yol` bir DİZİNSE (ya da HİÇ verilmediyse, o zaman CWD kullanılır) →
  `discoverTestFiles` ile TÜM `*_test.nox` dosyaları bulunur, HER biri
  BAĞIMSIZ (kendi arena'sıyla) derlenip çalıştırılır, `GECTI:`/`BASARISIZ:`
  satırları + `"{d} gecti, {d} basarisiz ({d} toplam)"` özeti basılır;
  HERHANGİ biri başarısızsa `noxc test` çıkış kodu `1` ile sonlanır. HİÇ
  test dosyası bulunamazsa `"0 test dosyasi bulundu"` mesajıyla çıkış
  kodu `0` (hata DEĞİL — boş bir dizin GEÇERLİ).

**Bilinçli sınırlama:** bir test dosyasının DERLENMESİ başarısız olursa
(`buildOne`in mevcut hata yolları HÂLÂ doğrudan `std.process.exit(1)`
çağırıyor) TÜM `noxc test` çalışması ORADA durur — yalnızca ÇALIŞMA ZAMANI
(derlenmiş binary'nin çıkış kodu) başarısızlıkları dosya-dosya TOPLANIR.
Bu, Go'nun `go test`inin KENDİ paketi derlenemezse TÜM paketi başarısız
SAYMASIYLA AYNI kategoride bir davranış — kasıtlı, gelecekte GERÇEKTEN
gerekli olduğu KANITLANIRSA (`buildOne`in hata yollarının `std.process.
exit` YERİNE tipik Zig hatası DÖNMESİNE dönüştürülmesini gerektiren AYRI
bir refactor) genişletilebilir.

**Doğrulama:** YENİ `tests/unit/test_runner_test.zig` (2 test — iç içe
dizinlerde `*_test.nox` bulma + digerlerini yok sayma, boş sonuç), YENİ
`tests/cli/subcommand_test.zig` eklentileri (2 test — karışık geçen/kalan
dizin özeti + çıkış kodu, boş dizin). Kasıtlı-boz-restore: `discoverTestFiles`in
son ek eşleşmesi GEÇİCİ olarak `"_TEST_BROKEN.nox"`e değiştirilip birim
testinin TAM OLARAK "beklenen 2, bulunan 0" farkıyla KIRMIZIYA döndüğü
doğrulandı, sonra GERİ alındı. `zig build test` (Debug + `-Doptimize=
ReleaseFast`) yeşil, `zig fmt` uygulandı. **Not:** geri alım SONRASI bir
tek seferlik, TEKRARLANAN 4 çalıştırmada YENİDEN GÖRÜLMEYEN bir test
başarısızlığı gözlemlendi (P.2'nin geri alımında da AYNI desen görülmüştü)
— muhtemelen `noxc`nin TAZE yeniden derlenmesi sonrası İLK `zig build
test` çağrısına özgü bir dosya sistemi zamanlama etkisi; GERÇEK bir kod
hatası OLMADIĞI 4 ardışık YEŞİL çalıştırmayla doğrulandı, ileride KALICI
hale gelirse ayrıca araştırılmalı.

### 3.6.5 Faz O §P.4 — Manifest `requires` + Lockfile Şeması (Ağ Yok)

P.1'in `Manifest`i yalnızca `name`/`entry` taşıyordu (`requires` alanı
`.ignore_unknown_fields` sayesinde SESSİZCE yok sayılıyordu). P.4 bunu
GERÇEK bir şemaya bağladı — HENÜZ hiçbir ağ/`git` işlemi YOK, yalnızca
ayrıştırma/doğrulama/serileştirme (P.5 bunun ÜZERİNE gerçek getirmeyi
inşa edecek).

**`compiler/project.zig`'e eklenenler:**
- `Requirement` struct'ı (`alias`/`repo`/`ref`) — `Manifest.requires:
  []const Requirement` alanı artık GERÇEKTEN doldurulur.
- `validateManifest(m: Manifest) error{DuplicateAlias, ReservedAlias}!void`
  — `requires[]` KÜÇÜK olduğundan (allocator GEREKTİRMEYEN) basit O(n²)
  doğrusal taramayla İKİ kural doğrulanır: alias'lar BENZERSİZ olmalı
  (aksi halde `import` çözümlemesi HANGİ bağımlılığın kastedildiğini
  AYIRT edemezdi), `"nox"` alias'ı REZERVE (stdlib'in KENDİ noktalı
  kökü). `loadManifest` artık ayrıştırdıktan SONRA bunu OTOMATİK uygular.
- `LockedPackage` (`alias`/`repo`/`ref`/`resolved`) ve `Lockfile
  {packages: []const LockedPackage}` — `nox.lock`ın şeması. `parseLockfile`
  (saf bellek-içi, dosya sistemi GEREKMEZ — birim testlerinin fixture
  string'leriyle DOĞRUDAN çalışabilmesi İÇİN), `loadLockfile` (dosya HİÇ
  YOKSA — `findProjectRoot`ın "manifestsiz de geçerli" ilkesiyle AYNI
  tutarlılıkta — BOŞ bir `Lockfile` döner, HATA DEĞİL; dosya VARSA ama
  BOZUKSA `error.InvalidLockfile`), `saveLockfile` (`std.json.Stringify.
  valueAlloc` ile girintili JSON yazar — P.5'in GERÇEK `git`-çözümleme
  akışı HER başarılı çözümlemeden SONRA bunu ÇAĞIRACAK), `findLocked`
  (bir alias'ın ZATEN kilitlenip kilitlenmediğini sorgular — P.6'nın
  "önbellekten mi okuyayım yoksa yeniden mi çözeyim" kararı İÇİN).

**Doğrulama:** `tests/unit/project_test.zig`e 9 YENİ test (`requires`in
GERÇEKTEN ayrıştırıldığını doğrulayan güncellenmiş bir test DAHİL) —
yinelenen alias reddi, `"nox"` alias reddi, geçerli `requires` kabulü,
manifest seviyesinde yinelenen-alias reddi (uçtan uca `loadManifest`
üzerinden), `parseLockfile` geçerli/bozuk, `findLocked` bulunur/bulunmaz,
`loadLockfile` dosya-yok→boş, `saveLockfile`+`loadLockfile` roundtrip.
Kasıtlı-boz-restore: `validateManifest`in `"nox"` karşılaştırması GEÇİCİ
olarak `"NOX_BROKEN"`e değiştirilip ilgili testin TAM OLARAK "beklenen
ReservedAlias, bulunan void" farkıyla KIRMIZIYA döndüğü doğrulandı, sonra
GERİ alındı. `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil,
`zig fmt` uygulandı.

### 3.6.6 Faz O §P.5 — Git Tabanlı Getirme + Yerel Önbellek

YENİ `compiler/pkg/fetch.zig` — üçüncü-taraf bağımlılıkları `git` alt
süreciyle GETİRİP içerik-adresli (ÇÖZÜLMÜŞ SHA ile anahtarlanmış) bir
yerel önbelleğe yerleştiren TEK fonksiyon: `fetchToCache(a, io, nox_home,
repo, ref) !FetchResult{resolved_sha, cache_dir}`.

**Algoritma:** (1) `repo`yu bir clone URL'sine çözer (`resolveCloneUrl`
— zaten bir şema (`"://"`) İÇEREN ya da mutlak bir yerel yol OLAN
girdiler DOKUNULMADAN kullanılır, aksi halde `"https://"` öneklenir —
bu, testlerin GERÇEK `github.com`a HİÇ dokunmadan yerel fixture repo'lara
işaret edebilmesini SAĞLAR); (2) `$nox_home/pkg/tmp/stage-<rastgele>/`ye
klonlar (`ref`, 7+ karakter TAMAMEN hex İSE — kısaltılmış/tam SHA gibi
görünüyorsa — TAM klon + `checkout` yapılır, ÇÜNKÜ sığ klon çoğu git
sunucusunda rastgele bir SHA'ya izin VERMEZ; aksi halde `--depth 1
--branch <ref>` ile SIĞ klonlanır); (3) `git rev-parse HEAD` ile
ÇÖZÜLMÜŞ SHA'yı öğrenir; (4) `$nox_home/pkg/mod/<sanitize edilmiş
repo>/<sha>/` ZATEN VARSA staging klonunu AT (önbellek İSABETİ), YOKSA
staging'i O konuma TAŞIR (`renameAbsolute` — içerik-adresli, DEĞİŞMEZ).

**`sanitizeRepoForCachePath`:** `repo`nun şema önekini/baştaki `/`yi atıp
yalnızca alfasayısal/`.`/`-`/`_`/`/` karakterlerini KORUR (gerisi `_`) —
`"github.com/user/repo"` DOKUNULMADAN OKUNABİLİR bir yapı ÜRETİRKEN,
rastgele bir yerel test yolu/URL ASLA geçersiz bir dizin bileşeni
ürettirmez.

**Bilinçli olarak SALT GETİRME+ÖNBELLEKLEME — `nox.lock`a HİÇ dokunmaz:**
lockfile güncellemesi kararı (ne zaman yazılacağı, hangi alias'a karşılık
geldiği) ÇAĞIRANA (Faz O §P.6'nın resolver'ı) BIRAKILIR — `fetchToCache`
her çağrıldığında `ref`i git ÜZERİNDEN yeniden doğrular; "ZATEN kilitli
bir SHA VARSA git'e HİÇ dokunma" kısayolu BUNUN ÜZERİNDE (P.6'da,
`project.findLocked` ÖNCE kontrol edilerek) inşa edilecek — `fetch.zig`nin
KENDİSİ bu kısayolu içermiyor, dürüstçe not ediliyor (fazla vaat YOK).

**Bilinçli sınırlama:** `ref`in "SHA gibi görünme" sezgisi (yalnızca hex
karakterler, >= 7 uzunluk) tamamen hex karakterlerden oluşan bir BRANCH/
TAG adını (ör. `"abc123"`) yanlışlıkla SHA sanabilir — nadir ama olası
bir isimlendirme çakışması, v1 kapsamında kabul edildi.

**Doğrulama:** YENİ `tests/unit/fetch_test.zig` (3 test) — testler GERÇEK
`github.com`a HİÇ dokunmuyor: fixture'lar `std.testing.tmpDir` İÇİNDE alt
süreçle (`git init -b main` + `git add` + `git commit`) inşa edilen YEREL
repo'lar, `$nox_home` da HER test İÇİN AYRI bir `tmpDir`. Testler: getir-
ve-doğrula (`fetchToCache`in döndürdüğü `resolved_sha`, testin KENDİ
BAĞIMSIZ `git rev-parse HEAD` çağrısıyla EŞLEŞİYOR mu + önbellekteki
dosya içeriği doğru mu), idempotentlik (AYNI repo+ref İKİ KEZ çağrılınca
AYNI sha/cache_dir döner, İKİNCİ çağrı da doğru içerikle sonuçlanır),
çakışmama (İKİ FARKLI fixture repo AYNI `$nox_home` altında AYRI önbellek
dizinlerine yerleşir). Kasıtlı-boz-restore: `renameAbsolute`in hedef
yolu GEÇİCİ olarak geçersiz bir göreli dizgeye (`"BROKEN_FOR_TEST"`)
değiştirilip (Zig'in KENDİ `assert(path.isAbsolute(...))`si sayesinde)
3 testin de panikle KIRMIZIYA döndüğü doğrulandı, sonra GERİ alındı. `zig
build test` (Debug + `-Doptimize=ReleaseFast`) yeşil, `zig fmt` uygulandı.
**Not:** doğrulama SIRASINDA bir kez, TEKRARLANMAYAN bir `zig build test`
zaman-aşımı (2 dakika) gözlemlendi — 6 ardışık SONRAKİ çalıştırma hep
hızlı VE yeşil, hiçbir asılı kalmış süreç BULUNAMADI; muhtemelen bu
oturumdaki YOĞUN ardışık derleme/test yükünden kaynaklanan geçici bir
sistem G/Ç gecikmesi (P.2/P.3'ün restore'larında GÖZLEMLENEN AYNI flake
deseniyle TUTARLI), gerçek bir kilitlenme OLDUĞUNA dair kanıt YOK.

### 3.6.7 Faz O §P.6 — Üçüncü-Taraf Çözümlemeyi Import Çözümlemeye + CLI'ye Bağlama

Faz O'nun EN büyük entegrasyon adımı: P.1 (proje kökü keşfi), P.4 (manifest/
lockfile şeması) ve P.5 (git getirme+önbellek) MODÜLLERİNİ birbirine
BAĞLAYIP `noxc build`/`run`/`test`in GERÇEK üçüncü-taraf paket importlarını
çözebilmesini sağladı.

**`compiler/module_loader.zig`ye EKLENEN (mevcut hiçbir davranışı
DEĞİŞTİRMEYEN) genişleme:**
- `resolveImports` artık bir SARMALAYICI (`resolveImportsImpl(a, io,
  user_module, null)`) — DAVRANIŞI BİREBİR AYNI kaldı.
- YENİ `pub fn resolveProjectImports(a, io, user_module, alias_roots:
  StringHashMapUnmanaged([]const u8)) LoadError!ast.Module` —
  `resolveImportsImpl(a, io, user_module, &alias_roots)`i çağırır.
- `loadImportsRecursive`e (özel/`fn`) EKLENEN `alias_roots: ?*const
  StringHashMapUnmanaged([]const u8)` parametresi: `alias_roots == null`
  OLDUĞUNDA (yani `resolveImports`ın KENDİSİ) davranış ESKİSİYLE BİREBİR
  AYNI (ilk segment NE OLURSA olsun `stdlib/{yol}.nox` denenir). `alias_roots`
  VERİLDİĞİNDE VE ilk segment `"nox"` DEĞİLSE, ÖNCE alias haritasına bakılır
  (`<root>/{kalan-segmentler}.nox`), haritada YOKSA YENİ `error.
  UnknownImportAlias` döner. **Kritik keşif (kod okunarak DOĞRULANDI):**
  `checker.zig`nin `tryResolveQualifiedCall`ı ve `module_loader`ın mangling
  şeması (`mangleWith`) ZATEN tamamen GENERİKTİ (`"nox"`e ÖZGÜ hiçbir
  varsayım YOK, yalnızca `imported_modules`daki dotted-path eşleşmesine
  bakıyor) — bu yüzden üçüncü-taraf aliaslar HİÇBİR checker/mangling
  değişikliği GEREKMEDEN "otomatik" çalıştı.

**`compiler/main.zig`ye EKLENEN `resolveImportsForBuild` orkestrasyonu**
(`buildOne`nin İÇİNDEKİ eski doğrudan `resolveImports` çağrısının YERİNE):
proje kökü (`nox.json`) BULUNAMAZSA `resolveImports`ın ESKİ davranışına
BİREBİR düşer (manifestsiz kullanım HÂLÂ TAM olarak eskisi gibi çalışır);
BULUNURSA HER `requires[]` girdisi İÇİN: `nox.lock`ta ZATEN kilitli bir
SHA VARSA VE o SHA'nın önbellek dizini (`fetch.cachedDirFor` İLE, `git`e
HİÇ dokunmadan hesaplanır) HÂLÂ diskteyse doğrudan KULLANILIR (offline
kısayol — P.5'in kendisi bu kısayolu İÇERMİYORDU, TAM OLARAK burada
uygulandı); AKSİ HALDE `fetch.fetchToCache` GERÇEKTEN çağrılır VE
`nox.lock` (tüm bağımlılıklar çözüldükten SONRA TEK seferde) GÜNCELLENİR.
Son olarak `module_loader.resolveProjectImports` (alias→önbellek-dizini
haritasıyla) çağrılır — `error.ModuleNotFound`/`error.UnknownImportAlias`
AYRI, açık Türkçe mesajlara çevrilir (İKİNCİSİ mevcut `requires` listesini
İŞARET eder).

**`noxc`nin YENİ `$NOX_HOME` çözümlemesi** (`main()`'in en başında,
`init.environ_map` KULLANILARAK): `NOX_HOME` ortam değişkeni VERİLMİŞSE
DOĞRUDAN kullanılır (testlerin GERÇEK `~/.nox`a dokunmaması İÇİN KRİTİK),
VERİLMEMİŞSE `$HOME/.nox` varsayılır.

**Uçtan uca DOĞRULANDI (manuel smoke test, kod YAZILMADAN ÖNCE):** yerel
bir fixture "paket" repo'su (`git init -b main`) + onu `requires[]`inde
bildiren bir fixture proje — `noxc build` GERÇEKTEN paketi getirdi,
`nox.lock`ı doğru SHA ile yazdı, `print(mypkg.util.double(21))` "42"
bastı; kaynak paket SİLİNDİKTEN SONRA bile İKİNCİ bir `build` (lock+
önbellek sayesinde) TAMAMEN offline BAŞARILI oldu; bilinmeyen bir alias
AÇIK bir hata mesajıyla BAŞARISIZ oldu.

**Doğrulama:** YENİ `tests/cli/package_resolution_test.zig` (2 test) —
`std.testing.environ.createMap` ile GERÇEK ortamın bir KOPYASI üzerine
`NOX_HOME` EKLENEREK (gerçek `~/.nox`a HİÇ dokunmadan) izole edilir; ilk
test tam senaryoyu (getir→derle→çalıştır→lock-yaz→kaynak-sil→offline
ikinci-build) doğrular, ikinci test bilinmeyen-alias hata YOLUNU. Kasıtlı-
boz-restore: alias çözümlemesinin dosya yolu GEÇİCİ olarak yanlış bir
uzantıya (`"_BROKEN.nox"`) değiştirilip beklenen "import: modül
bulunamadı" hatasıyla KIRMIZIYA döndüğü doğrulandı, sonra GERİ alındı.
`zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil, `zig fmt`
uygulandı. **Not:** doğrulama SIRASINDA yine (P.2/P.3/P.5'te GÖZLEMLENEN
AYNI desen) bir kez, TEKRARLANMAYAN bir tekil test başarısızlığı (rebuild
SONRASI İLK çalıştırma) gözlemlendi, 4 ardışık SONRAKİ çalıştırma hep
yeşil.

### 3.6.8 Faz O §P.7 — Üçüncü-Taraf Mangling Çakışması: Değerlendirildi, Kod Değişikliği GEREKMEDİ

Plan, P.7'yi "iki farklı üçüncü-taraf paketi AYNI noktalı adı (ör. ikisi
de `util.parse`) ihraç ederse mangling ÇAKIŞIR" endişesini `pkg_<hash>_`
önekli bir mangling şemasıyla ÇÖZMEK olarak tanımlamıştı — bu endişe,
P.4/P.6'DAN ÖNCE, alias-benzersizliği HENÜZ zorunlu kılınmadan yazılmıştı.
P.6 tamamlandıktan SONRA yapılan bir değerlendirme (kod OKUNARAK + GERÇEK
bir uçtan uca deneyle) bu endişenin, P.4'ün `validateManifest`i
(`requires[].alias`in projede BENZERSİZ olmasını ZORUNLU kılan doğrulama,
bkz. §3.6.5) SAYESİNDE **zaten kapandığını** ortaya çıkardı — AYRI bir
hash-önekleme şeması EKLENMEDEN:

**Gerekçe:** `module_loader.zig`'in mangling'i (`mangleWith`) HER ZAMAN
o import'un TAM segment zincirini (`imp.segments` — alias DAHİL) isim
öneki olarak kullanır. `requires[].alias` proje İÇİNDE (validateManifest
tarafından) BENZERSİZLİĞİ GARANTİLİ olduğundan, İKİ farklı bağımlılık
ASLA aynı mangled isme çözülemez — alias'ların KENDİSİ zaten birbirinden
FARKLI olduğundan, segment zincirinin BAŞI (dolayısıyla TÜM mangled isim)
HER ZAMAN AYRIŞIR. Bu, `nox.*` stdlib'in KENDİ, `"nox"` önekiyle
korunan tekil ad alanıyla AYNI mekanizma — üçüncü-taraf paketler İÇİN
"alias" tam olarak bu rolü GÖRÜR.

**Ampirik doğrulama (kod YAZILMADAN ÖNCE, manuel smoke test):** iki
fixture git repo'su, İKİSİ de `util.parse` adlı bir fonksiyon İHRAÇ EDEN,
tek bir projede İKİ farklı alias (`pkga`/`pkgb`) ile TÜKETİLDİ — `noxc
build`+çalıştırma HİÇBİR linker çakışması OLMADAN, HER çağrı sitesinin
KENDİ paketinin implementasyonuna (101/201 çıktısı) doğru çözüldüğünü
gösterdi.

**Doğrulama (KALICI regresyon testi olarak eklendi):** `tests/cli/
package_resolution_test.zig`ye YENİ bir test — YUKARIDAKİ senaryoyu
`noxc`yi bir ALT SÜREÇ olarak çalıştırarak KALICI hale getirir. Kasıtlı-
boz-restore: `mangleWith` GEÇİCİ olarak alias'ı ATIP yalnızca SON segmenti
kullanacak şekilde bozuldu — bu, YALNIZCA P.7'nin YENİ testini DEĞİL,
STDLIB'in KENDİ (`nox.http`/`nox.testmod` vb.) golden testlerinin ÇOĞUNU
da kırdı (66 testten 16'sı başarısız) — alias-dahil mangling'in aslında
GENEL olarak TÜM modül sisteminin (yalnızca üçüncü-taraf paketlerin
DEĞİL) doğruluğu İÇİN load-bearing olduğunu KANITLADI. Değişiklik GERİ
alındı, `zig build test` (Debug + `-Doptimize=ReleaseFast`) yeşil
doğrulandı. **Bu, M.5/M.8 İLE AYNI kategoride bir sonuç** — planlanan bir
madde, DAHA ÖNCEKİ bir kararın (P.4'ün alias-benzersizliği) yan etkisiyle
zaten ÇÖZÜLMÜŞ bulundu, GEREKSİZ karmaşıklık EKLENMEDEN dürüstçe
raporlandı.

### 3.6.9 Faz O §P.8 — `noxc fmt`: Zaten P.2'de Tamamlanmıştı

Plan, P.8'i "`noxc fmt` alt komutunu REZERVE ET (`'henüz uygulanmadı'`
mesajı, çökme yok), gerçek formatlayıcı bu fazın KAPSAMI DIŞINDA" olarak
tanımlamıştı. Bu, P.2'nin CLI alt komut iskeleti (bkz. §3.6.3) YAZILIRKEN
`fmt`/`fetch`/`update`in ÜÇÜ BİRDEN AYNI rezervasyon deseniyle (main.zig'in
`switch (sub)`inin `.fmt, .fetch, .update` kolu) İMPLEMENTE EDİLMİŞ VE
`tests/cli/subcommand_test.zig`nin "fmt/fetch/update: henuz uygulanmadi
mesaji, cikis kodu 1" testiyle ZATEN DOĞRULANMIŞTI — P.8 İÇİN AYRICA hiçbir
YENİ kod/test GEREKMEDİ, yalnızca bu FAZ İŞARETİNİN (task tracker'da) bu
GERÇEĞİ YANSITACAK şekilde KAPATILMASI gerekiyordu. Manuel doğrulama:
`./zig-out/bin/noxc fmt` → `"noxc fmt: henuz uygulanmadi (bkz. plan
dosyasi, Faz O)"` (stderr) + çıkış kodu `1`.

**FAZ O TAMAMEN BİTTİ.** P.1-P.8'in HEPSİ tamamlandı — `noxc` artık
Cargo/Go tarzı `build`/`run`/`test` alt komutları taşıyor (legacy BİREBİR
korunarak), GERÇEK üçüncü-taraf GitHub paketlerini (`nox.json`'ın
`requires[]`i → `git`-tabanlı getirme+SHA-anahtarlı önbellek+`nox.lock`)
import edip derleyebiliyor, uçtan uca doğrulandı (getirme, offline
tekrar-build, bilinmeyen-alias hatası, iki-paket-adı-çakışması-YOK hepsi
GERÇEK testlerle KANITLANDI). `fmt`/`fetch`/`update` REZERVE (gerçek
implementasyonları — sırasıyla bir formatlayıcı, merkezi bir registry
protokolü, bağımlılık güncelleme UX'i — KASITLI olarak GELECEĞE
bırakıldı, plan dosyasının KENDİ "merkezi registry şimdilik kapsam dışı"
kararıyla TUTARLI).

---

## 3.7 Faz Q — Üretim Hazırlığı: Temel Sağlamlaştırma

`docs/uretim-hazirlik-analizi.md`nin (derin üretim-hazırlığı boşluk analizi
ve MVP-sonrası yol haritası, P0-P3 önceliklendirmesiyle) Faz Q-Z'sinin
İLKİ. Faz Q, P0 (kritik) boşlukları hedefler: sürüm kontrolü, CI, sistem
geneli kurulum, kullanıcı dokümantasyonu, HTTP DoS sertleştirmesi, güven
sınırı dokümantasyonu.

### 3.7.1 Q.1/Q.2 — Git + CI

İlk `git init`/commit (`93ddb0d`) + `CHANGELOG.md` başlatıldı; ardından
`.github/workflows/ci.yml` eklendi (`macos-14` runner'ında `zig build test`
Debug+ReleaseFast — `runtime/async_rt`in v0.1'de yalnızca aarch64
desteklemesi GEREKÇESİYLE Apple Silicon runner'ı, bkz. Faz R.2).

### 3.7.2 Q.3 — `main.zig`'i `resolveResourceDirs`'e Bağlama

**Problem:** `noxc` iki ayrı yerde CWD-göreli SABİT yol varsayıyordu: (1)
`compiler/main.zig`nin `buildOne`i, son `cc` bağlama argümanına DOĞRUDAN
`"zig-out/lib/noxrt.o"` string literalini yazıyordu; (2)
`compiler/module_loader.zig`nin `resolveImportsImpl`/`loadImportsRecursive`i
`import` çözümlemesi İÇİN `"stdlib/{yol}.nox"` yolunu SABİT KODLUYORDU.
Faz O §P.1'in `project.resolveResourceDirs`i (self-exe-göreli `<exe_dir>/
../lib/...` hesaplaması) DOĞRU yazılmıştı ama HİÇBİR ÇAĞRI SİTESİNDEN
KULLANILMIYORDU — yani `noxc`, `zig-out/`in içeriği görünür OLMAYAN bir
CWD'den (ör. sistem geneli bir kuruluma göre `/opt/homebrew/bin/noxc`)
çalıştırıldığında SESSİZCE bozulurdu.

**Çözüm:**
1. `module_loader.zig`: `resolveImportsImpl`/`loadImportsRecursive`e bir
   `stdlib_root: []const u8` parametresi eklendi. `resolveImports` (İMZASI
   DONDURULMUŞ — golden testler DOĞRUDAN çağırıyor, CWD'leri HER ZAMAN
   proje kökü) `stdlib_root = "stdlib"` ile DEĞİŞMEDEN çalışmaya devam
   eder. YENİ `resolveImportsFrom(a, io, user_module, stdlib_root)` VE
   genişletilmiş `resolveProjectImports(..., stdlib_root)` (yalnızca
   main.zig'in çağırdığı, imzası SERBEST) `noxc`nin KENDİ çözülmüş
   `stdlib_dir`ini kabul eder.
2. `main.zig`: `main()` başında `project.resolveResourceDirs`i çağırıp
   `resource_dirs: ResourceDirs`i HESAPLAR, bunu `cmdBuild`/`cmdRun`/
   `cmdTest` → `buildOne` → `resolveImportsForBuild` zincirinin TAMAMINA
   parametre olarak GEÇİRİR. `buildOne`in `cc_argv`si artık
   `resource_dirs.noxrt_path`i (SABİT literal DEĞİL) kullanır.
3. **Yeni, AYRI bir `NOX_RESOURCE_DIR` ortam değişkeni** eklendi (`NOX_HOME`
   İLE KARIŞTIRILMAMALI — bkz. main.zig'in belge notu): `NOX_HOME` ÜÇÜNCÜ-
   TARAF PAKET ÖNBELLEĞİNİN köküdür, `NOX_RESOURCE_DIR` İSE `noxc`nin KENDİ
   stdlib/runtime kurulumunun köküdür — İKİSİ FARKLI KAVRAMLAR. Bu ayrım,
   `tests/cli/package_resolution_test.zig`nin İZOLE `$NOX_HOME`sinin (paket
   önbelleğini izole eder, stdlib/runtime İÇERMEZ) `resolveResourceDirs`e
   YANLIŞLIKLA sızıp testleri BOZMASINI önlemek İÇİN GEREKLİ oldu (İLK
   deneme `NOX_HOME`i İKİ AMAÇ İÇİN de KULLANMAYA çalıştı, `zig build test`
   3 `package_resolution_test` başarısızlığıyla bunun YANLIŞ olduğunu
   KANITLADI — düzeltme: AYRI env var).
4. **`appendExternLinkArgs`nin `seen` ÖN-tohumlaması KORUNDU** (`"zig-out/
   lib/noxrt.o"` literal STRING'i, GERÇEK `noxrt_path` NE OLURSA olsun) —
   bu literal artık "gerçek bir yol" DEĞİL, stdlib yazarlarının KENDİ
   `extern def`lerinde (ör. `stdlib/nox/http.nox`, `strings.nox`, `os.nox`)
   KULLANDIĞI SABİT bir KURAL/SENTİNEL'dir; `seen` bu SENTİNEL'i tanıyarak
   `noxrt.o`nun cc'ye İKİNCİ KEZ (ve YANLIŞ, CWD-göreli bir yolla)
   geçmesini ÖNLER.

**Doğrulama:** `zig build test` (Debug+ReleaseFast) yeşil (256/256, dahil
3 P.6/P.7 uçtan-uca paket testi). **Kasıtlı boz→doğrula→düzelt:** `noxc`
kurulu ikilisi (`zig-out/bin/noxc`) proje kökünün TAMAMEN DIŞINDA bir
geçici dizinden (`import nox.strings`/`nox.math` KULLANAN bir program,
`nox.strings.upper` GİBİ `with_rt extern def`lere DAYANAN bir stdlib
fonksiyonu DAHİL) `build` edilip ÇALIŞTIRILDI — hem stdlib çözümlemesi
hem runtime bağlama BAŞARILI (önceden bu SESSİZCE `error.ModuleNotFound`/
`cc` `FileNotFound` ile BAŞARISIZ olurdu).

### 3.7.3 Q.5 — `nox.http.serve` DoS Sertleştirmesi

**Problem:** `runtime/stdlib_shims/http_server.zig`nin `connectionEntry`/
`nox_http_serve_raw`ı sıfır kaynak-tüketimi sınırı taşıyordu: (1) bir
isteğin gövdesi `streamRemaining` ile SINIRSIZ okunuyordu (bir saldırgan
KEYFİ büyüklükte bir gövde göndererek belleği tüketebilirdi); (2) kabul
döngüsü `accept()`i SINIRSIZ tekrarlayıp HER bağlantı İÇİN bir fiber+yığın
(havuzdan ya da taze 256 KiB) harcıyordu (bir saldırgan bağlantıları hiç
kapatmadan biriktirerek bellek/fd tüketebilirdi).

**Çözüm (İKİ SABİT güvenlik sınırı, `docs/uretim-hazirlik-analizi.md`nin P0
bulgusuna karşılık):**
1. **Gövde boyutu sınırı** (`MAX_REQUEST_BODY_BYTES = 10 MiB`):
   `connectionEntry`, `streamRemaining` YERİNE `body_reader.stream(...,
   .unlimited)`i (her çağrısı `FiberReader.stream` aracılığıyla TEK bir
   soket okumasına denk gelir) bir döngüde çağırıp HER adımda toplam
   boyutu kontrol eder — sınır AŞILDIĞI ANDA (saldırganın gönderdiği KALAN
   baytlar hiç OKUNMADAN/tahsis edilmeden) `413 Payload Too Large` yanıtı
   yazılıp bağlantı kapatılır, `handler` HİÇ ÇAĞRILMAZ.
2. **Eşzamanlı bağlantı sınırı** (`DEFAULT_MAX_CONCURRENT_CONNECTIONS =
   4096`): `nox_http_serve_raw`nin kabul döngüsü basit bir `active_
   connections: usize` sayacı tutar (tek OS iş parçacığında kooperatif
   çalıştığından atomik GEREKMEZ) — sınır DOLUYSA yeni bağlantı `receiveHead`e
   bile ULAŞMADAN reddedilir (fd sessizce kapatılır, hiçbir HTTP yanıtı
   YAZILMAZ — en ucuz tepki).
3. **Testte KÜÇÜK sınırlarla egzersiz:** dışa açık `nox_http_serve_raw`nin
   C ABI imzası (`genHttpServe`'in codegen'de SABİT 5 argümanla çağırdığı)
   DEĞİŞTİRİLMEDİ — gerçek gövde/sarmalayıcı `serveImpl` adlı özel bir
   fonksiyona taşındı, bu da `max_concurrent`/`max_body_bytes`i PARAMETRE
   olarak alır; `nox_http_serve_raw` bunu SABİT varsayılanlarla çağırır.
   Testler `serveImpl`i KÜÇÜK/HIZLI değerlerle (16 bayt gövde sınırı, 1
   eşzamanlı bağlantı) DOĞRUDAN çağırarak gerçekçi (büyük) varsayılanları
   BEKLEMEDEN sınırları GERÇEKTEN egzersiz eder.

**Bilinçli KAPSAM DIŞI (dürüstçe belgelendi):** bir bağlantının BAŞLIK/
GÖVDE göndermeden (slowloris tarzı) SINIRSIZ süre askıda kalmasına karşı
bir OKUMA ZAMAN AŞIMI henüz YOK — mevcut kqueue reaktörü (D.0) yalnızca
soket G/Ç olaylarını dinliyor, bir ZAMANLAYICI (`EVFILT_TIMER`) desteği
YOK (`nox.time.sleep_ms`in "bloklayıcı" kısıtıyla AYNI kök neden). Bu,
GELECEKTEKİ bir faza (muhtemelen Faz R'nin platform genişletmesiyle
BİRLİKTE) bırakıldı — eşzamanlı-bağlantı sınırı bu riski KISMEN azaltır
(askıda kalan bağlantılar da o sınıra dahildir, sınırsız ÇOĞALAMAZLAR).

**Doğrulama:** İKİ yeni birim testi (`http_server.zig`) — biri 16 baytlık
KASITLI küçük bir gövde sınırının aşılınca `413`e VE `handler`ın HİÇ
çağrılMADIĞINA, diğeri `max_concurrent=1` iken (D.0'ın "sıra kanıtı"
tekniğiyle: yavaş bir bağlantı önce kabul edilip sayaç sınırı doldururken,
hemen ardından gelen bir bağlantının fd'sinin HİÇBİR yanıt almadan
kapatıldığına) kanıt sağlar. **Kasıtlı boz→doğrula→düzelt:** her İKİ
kontrol de (`if (false and ...)`) AYRI AYRI devre dışı bırakılıp İLGİLİ
testin GERÇEKTEN KIRMIZI olduğu doğrulandı, SONRA düzeltme geri
getirilip `zig build test` (Debug+ReleaseFast) TEKRAR yeşile döndü.

---

## 3.8 Faz R.1 — Linux epoll I/O Reaktör Backend'i

`docs/uretim-hazirlik-analizi.md`nin Faz R'si (Platform Genişletme) — v0.1'in
`runtime/async_rt`i şimdiye kadar YALNIZCA macOS/kqueue destekliyordu (bkz.
§3.29). Bu bölüm, `IoReactor`in Linux/epoll karşılığını ekler.

**Doğrulama metodolojisi (ÖNEMLİ, dürüstçe belgelendi):** bu makine
macOS/arm64 — Linux'ta GERÇEK doğrulama İÇİN Docker (OrbStack) üzerinden
**native aarch64 Linux konteyneri** (emülasyon YOK — `uname -m` → `aarch64`,
host'un KENDİ mimarisiyle AYNI) kullanıldı: `zig test -target aarch64-linux-gnu`
ile çapraz derlenip `docker run` İÇİNDE ÇALIŞTIRILDI. Bu, x86-64 (Faz R.2)
İÇİN mümkün OLMAYAN bir güven seviyesi sağlıyor (QEMU emülasyonu GEREKMEDEN
gerçek donanımda çalışan gerçek bir ikili).

**Bulunan VE düzeltilen ÜÇ ayrı, önceden GİZLİ Linux-uyumsuzluğu (hepsi bu
doğrulama SÜRECİNDE, gerçek Docker testleriyle keşfedildi):**

1. **`swap_aarch64.s` → `swap_aarch64.S`, taşınabilir sembol adı:** dosya
   `_nox_swap_context` (Mach-O'nun baştaki `_` KURALI) hardcode ediyordu —
   Linux/ELF'te C sembolleri ÖNEKSİZDİR, bu yüzden `fiber.zig`nin `extern fn
   nox_swap_context` (öneksiz) bildirimi Linux'ta ASLA eşleşmezdi (link
   hatası). Çözüm: dosya `.S`ye (BÜYÜK harf, C ön işlemcisinden GEÇER)
   taşındı, `#if defined(__APPLE__)` ile `SYM(name)` makrosu (`_name` ya da
   `name`) TEK kaynaktan HER İKİ platformu da doğru üretir.
2. **Ham Linux sistem çağrısı sarmalayıcıları + libc-TLS `errno` KARIŞIMI
   (GERÇEK bir çalışma zamanı hatası, Docker'da YAKALANDI):** İLK
   `EpollReactor` taslağı `std.os.linux.epoll_ctl/wait/create1`i (HAM
   sistem çağrısı, hata negatif `errno`yu BÜYÜK bir `usize` olarak KODLAR)
   `posix.errno()` İLE (bu proje libc'ye bağlandığında `std.c`nin TLS
   `errno`SUNU okur) BİRLİKTE kullanıyordu — bu İKİSİ UYUMSUZ: `posix.
   errno()` HER ZAMAN `.SUCCESS` dönüyordu, HATA durumunda BİLE. Somut
   belirti: "aynı fd'yi ikinci kez register et" testi Docker'da SESSİZCE
   SONSUZA DEK ASILI KALDI (`EPOLL_CTL_ADD`in `EEXIST`i YANLIŞ `.SUCCESS`
   sayılıp `EPOLL_CTL_MOD`a hiç DÜŞÜLMEDİĞİ İÇİN fd BİR DAHA ASLA olay
   ÜRETMEDİ). Çözüm: `KqueueReactor`nin ZATEN doğru kullandığı `posix.
   system.epoll_*` (libc bağlıyken `std.c.epoll_*`ye çözülür, GERÇEK
   `errno` yan etkisiyle) KULLANILDI.
3. **`build.zig`de `link_libc` HİÇ AYARLANMAMIŞTI:** `runtime/`nin HER
   YERİNDE `std.c.*` KULLANILIYOR (soket/dosya ilkelleri) — macOS'ta bu
   HER ZAMAN örtük ÇALIŞIYORDU (Darwin ikilileri libSystem'i KOŞULSUZ
   bağlar), Linux'ta İSE AÇIKÇA `link_libc = true` İSTENMEDEN "libc'ye
   bağımlılık açıkça belirtilmeli" derleme HATASI verir. `noxrt_mod` +
   4 standalone async_rt test modülüne (`fiber_test_mod`/`scheduler_
   test_mod`/`channel_test_mod`/`io_test_mod`) eklendi.

**Mimari:** `io_reactor.zig`, `KqueueReactor`/`EpollReactor`i `if (builtin.
os.tag == ...) struct {...} else struct {}` deseniyle SARAR (YANLIŞ
platformda OS-özgü tiplerin HİÇ semantik analiz EDİLMEMESİNİ garanti eder),
`pub const IoReactor` bunlardan BİRİNİ comptime SEÇER — `scheduler.zig`/
`io.zig` HİÇBİR platform dallanması İÇERMEZ. `EPOLLONESHOT`, kqueue'nun
`EV_ONESHOT`unun AKSİNE fd'yi interest listesinden SİLMEZ (yalnızca YENİDEN
`EPOLL_CTL_MOD` İLE silahlandırılana kadar olay ÜRETMEYİ durdurur) —
`register`, ÖNCE `EPOLL_CTL_ADD` DENER, `EEXIST` alırsa `EPOLL_CTL_MOD`a
DÜŞER (nginx/libevent'in KENDİ yeniden-silahlandırma deseniyle AYNI).

**Doğrulama:** aarch64-linux-gnu'ya çapraz derlenip GERÇEK (emülasyonsuz)
bir Docker aarch64 Linux konteynerinde ÇALIŞTIRILAN `fiber`/`scheduler`/
`channel`/`io`/`io_reactor` testlerinin TAMAMI (io.zig'in "fiber G/Ç
beklerken BAŞKA bir fiber çalışabilir" testi DAHİL — reaktörün ASIL amacının
EN DERİN kanıtı) yeşil. YENİ bir `io_reactor.zig` testi ("AYNI fd birden
çok kez register edilebilir") EKLENDİ — bu test, DÜZELTMEDEN ÖNCE Docker'da
GERÇEKTEN SONSUZA DEK ASILI KALARAK (kasıtlı boz→kırmızıyı doğrula→düzelt
ritüelinin KENDİSİ) hatayı KANITLADI. macOS'ta `zig build test`
(Debug+ReleaseFast) DEĞİŞMEDEN yeşil (regresyon YOK).

---

## 3.9 Faz R.2 — x86-64 Fiber Bağlam Değişimi Desteği

`fiber.zig` ŞİMDİYE KADAR `builtin.cpu.arch != .aarch64` İSE `@compileError`
veriyordu (bkz. §3.21). Bu bölüm x86-64'ü (SysV ABI) ekler — `runtime/
async_rt` artık HEM aarch64 HEM x86-64'te çalışıyor.

**Doğrulama metodolojisi (R.1 İLE AYNI dürüstlük ilkesiyle):** bu makine
macOS/arm64 — x86-64 doğrulaması GERÇEK donanım OLMADAN mümkün DEĞİL, bu
yüzden Docker (OrbStack, Apple'ın Rosetta ikili çevirisini KULLANIYOR —
QEMU TCG YORUMLAMASINDAN daha YÜKSEK sadakatli) üzerinden bir x86-64 Linux
konteynerinde doğrulandı. Bu, GERÇEK x86-64 donanımında çalıştırmaktan
DAHA AZ kesin bir güven seviyesidir — kullanıcıya AÇIKÇA belirtilir.

**Mimari fark (aarch64'e göre KÖKTEN farklı `Context` şekli):** SysV ABI'de
callee-saved yazmaçlar (rbx, rbp, r12-r15) GELENEKSEL OLARAK yığın üzerinden
`push`/`pop` edilir (aarch64'ün AKSİNE, ki ONDA callee-saved yazmaçlar
`Context`in DÜZ ALANLARINDA saklanır) — bu yüzden x86-64'ün `Context`i
YALNIZCA TEK bir alan (`sp`) taşır. XMM/YMM yazmaçları HİÇ KAYDEDİLMEZ
(SysV ABI'de TÜMÜ caller-saved'dir — aarch64'ün d8-d15'i callee-saved
OLDUĞUNDAN AÇIKÇA kaydedilmesi GEREKENİN AKSİNE). `swap_x86_64.S`:
`nox_swap_context`, 6 yazmacı (rbp, rbx, r12-r15) KENDİ yığınına `push`lar,
`rsp`i `old->sp`e yazar, `new->sp`i `rsp`e yükler, AYNI 6 yazmacı TERS
sırayla `pop`lar, `ret`.

**İLK KEZ resume edilecek bir fiber İÇİN sahte çerçeve (aarch64'ün DÜZ
alan atamasının AKSİNE, `Fiber.createWithStack` fiber'ın KENDİ yığınına
ELLE 7 sözcüklük — 6 yazmaç + dönüş adresi — bir "önceden push edilmiş"
çerçeve YAZAR):** `self` işaretçisi rbx'e ("kaçak" olarak, aarch64'ün x19'u
KULLANMASIYLA AYNI teknik — İKİSİ de callee-saved, `trampoline` girişte
DOĞRUDAN OKUYABİLİR) yerleştirilir; dönüş adresi `trampoline`dır. Çerçeve
tabanı 16 bayt HİZALI olmalıdır (SysV ABI'nin fonksiyon-girişi hizalama
gereksinimini KARŞILAMAK İÇİN — hesap: çerçeve tabanı X İSE, 6 pop (48
bayt) + `ret` (8 bayt) SONRASI `trampoline` girişinde `rsp = X+56`,
X'in 16-hizalı OLMASI `X+56 ≡ 8 (mod 16)` GARANTİ eder, SysV'nin `call`
sonrası BEKLENEN hizalamasıyla AYNI).

**Bulunan VE düzeltilen bir yazım hatası:** ilk `swap_x86_64.S` taslağı,
C ön işlemcisi yorum bloğu İÇİNDE `/*rdi*/` gibi İÇ İÇE `/* */` yorumlar
kullanıyordu — bu, dış yorumu ERKEN kapatıp GEÇERSİZ bir sözdizimi
hatasına yol açıyordu (derleme sırasında YAKALANDI, `[rdi]` gibi köşeli
parantezlere DEĞİŞTİRİLDİ).

**Doğrulama:** `zig test -target x86_64-linux-gnu`e çapraz derlenip
Docker'daki x86-64 konteynerinde ÇALIŞTIRILAN `fiber`/`scheduler`/
`channel`/`io`/`io_reactor` testlerinin TAMAMI yeşil (R.1'in epoll'uyla
BİRLİKTE, TAM async_rt yığını x86-64'te doğrulandı). **Kasıtlı boz→
doğrula→düzelt:** `pop` sırasındaki SON İKİ yazmacı (`rbp`/`rbx`) KASITLI
olarak TERS çevrilip test GERÇEKTEN "null pointer" panikleriyle ÇÖKTÜĞÜ
(`self` işaretçisinin YANLIŞ yazmaca gittiği İÇİN) doğrulandı, SONRA
düzeltme geri getirildi. macOS'ta `zig build test` (Debug+ReleaseFast)
DEĞİŞMEDEN yeşil.

**`build.zig`:** `compile_swap_asm`, HEDEFİN `cpu.arch`ına göre
`swap_aarch64.S`/`swap_x86_64.S`den DOĞRU olanı SEÇER. **Bilinçli
sınırlama (Faz R.3'e bırakıldı, R.1'in AYNI notuyla TUTARLI):** `cc` HÂLÂ
HOST derleyicisidir — GERÇEK çapraz derleme (`-Dtarget` ile HOST'tan
FARKLI bir mimari İÇİN doğrudan `zig build` ile üretim) bu fazın kapsamı
DIŞINDA, `zig cc -target ...`e geçiş Faz R.3'ün İŞİDİR.

---

## 3.10 Faz R.3 — CI Linux Matrisi + Çapraz-Derleme Doğrulaması

R.1/R.2'nin Docker doğrulaması yalnızca `runtime/async_rt`i (fiber/scheduler/
channel/io/io_reactor) İZOLE OLARAK test etmişti. R.3, TÜM `zig build test`i
GERÇEK bir Linux ortamında (Docker, Ubuntu 24.04 aarch64 — native, emülasyon
YOK; ayrıca x86-64 İÇİN Rosetta çevirisi) ÇALIŞTIRARAK doğrulamayı hedefler
— bu, projenin İLK KEZ tam paket olarak Linux'ta çalıştırılma girişimidir.

**Süreç İÇİNDE BULUNAN VE düzeltilen ÜÇ GERÇEK, ÖNCEDEN GİZLİ hata (HEPSİ
macOS'u DA etkiliyordu — LATENT olmaları, macOS'un aynı davranışı ÖRTÜK
olarak sağlaması YÜZÜNDENDİ, Linux'a ÖZGÜ bir hata SINIFI DEĞİLLER):**

1. **`qbe`nin `-t <target>`i ŞİMDİYE KADAR HİÇ geçilmiyordu** —
   `qbe`nin KENDİ BUILD-TIME varsayılan hedefine (`config.h`, `Deftgt`)
   GÜVENİLİYORDU. Homebrew'un macOS İÇİN derlediği `qbe` `arm64_apple`ı
   varsayılan yapar; KAYNAKTAN Linux'ta derlenen bir `qbe` SESSİZCE
   `arm64`e (Linux/genel AAPCS64, Apple'ın SysV'den FARKLI ABI'sinden
   AYRI) düşer. `compiler/main.zig`ye YENİ bir `qbeTargetName()` eklendi
   — `builtin.os.tag`/`builtin.cpu.arch`a göre `-t`yi HER ZAMAN AÇIKÇA
   geçer (macOS: `arm64_apple`/`amd64_apple`; Linux/diğer: `arm64`/
   `amd64_sysv`/`rv64`; Windows: `amd64_win`).
2. **`install_stdlib` (Faz O §P.1) `test_step`e HİÇ BAĞLI DEĞİLDİ** —
   yalnızca `b.getInstallStep()`e (varsayılan `zig build` hedefi)
   bağlıydı. `zig build test`, `zig-out/lib/nox/stdlib/`nin ÖNCEKİ bir
   `zig build` çalışmasından KALMA olmasına SESSİZCE güveniyordu — bu
   proje boyunca `zig-out` HİÇ TAMAMEN silinmediğinden fark edilmedi.
   Gerçek doğrulama SIRASINDA (`zig-out`/global Zig önbelleği TAMAMEN
   temizlenip `zig build test` doğrudan çalıştırıldığında) `stdlib/nox/
   core.nox: FileNotFound` İLE AÇIĞA ÇIKTI — `test_step.dependOn(&install_
   stdlib.step)` eklenerek düzeltildi.
3. **`cc`nin link satırında `-rdynamic` EKSİKTİ (EN DERİN bulgu — GERÇEK bir
   çökme/bellek sızıntısına yol açan KÖK NEDEN):** `runtime/stdlib_shims/
   json.zig`nin `nox.json` şeması (bkz. §L'nin belge notu, "Zig KAYNAK
   kodunun QBE'nin SONRADAN derleyeceği bir Nox sembolünü ÇAĞIRDIĞI İLK
   yer") `dlopen(null, ...)` + `dlsym(handle, "nox_json_make_json_value")`
   İLE ana programın KENDİ (QBE'nin ürettiği) sembolünü ÇALIŞMA ZAMANINDA
   arar. macOS'ta (Mach-O) bu ÖRTÜK çalışır — Linux'ta (ELF) İSE `-rdynamic`
   (`--export-dynamic`) OLMADAN ana programın sembolleri dinamik sembol
   tablosuna EXPORT edilmez, `dlsym` SESSİZCE `null` döner. Docker'da
   GERÇEKTEN gözlemlenen sonuç: `nox_json_make_json_value` HER ÇAĞRIDA
   `null` dönüyordu — GEÇERLİ JSON İÇİN bu bir `JsonValue` alan okumasında
   ÇÖKMEYE (`v.kind` null işaretçi), BOZUK JSON İÇİN İSE (hata sentinel'i
   İÇİN ÖNCEDEN `nox_rc_alloc` İLE ayrılmış `dup`/`empty_arr`/`empty_keys`/
   `empty_vals` parçaları, "onları saracak" `make_json_value` çağrısı
   BAŞARISIZ OLDUĞUNDAN hiçbir şeye BAĞLANAMADAN) GERÇEK bir bellek
   sızıntısına yol açıyordu. **`compiler/main.zig` VE `qbe`yi bağımsız
   çağıran TÜM test dosyalarının (6 çağrı sitesi) `cc` argümanlarına
   `-rdynamic` eklendi** — macOS'ta ZARARSIZ (ZATEN örtük davranışla AYNI
   sonucu verir), Linux'ta ZORUNLU.

**Ortak altyapı — `compiler/qbe_target.zig` (YENİ, `compiler/lib.zig`
üzerinden dışa açılır):** `qbe -t` seçim mantığı TEK bir yerde YAŞAR —
`compiler/main.zig` VE `qbe`yi bağımsız çağıran 5 test dosyası (`tests/
compat/hpy_call_golden_test.zig`, `http_stdlib_golden_test.zig`,
`http_serve_golden_test.zig`, `extern_ffi_test.zig`, `tests/golden/
codegen_golden_test.zig`) AYNI `nox.qbe_target.name()`i KULLANIR — kod
TEKRARI ÖNLENİR, gelecekteki bir platform eklemesi TEK bir yerde yapılır.

**Doğrulama:** `zig-out`/global Zig önbelleği (`~/.cache/zig`) TAMAMEN
silinip `zig build test` (Debug+ReleaseFast) SIFIRDAN çalıştırıldı — ÜÇ
düzeltme OLMADAN başarısız olduğu, ÜÇÜYLE de yeşile döndüğü DOĞRUDAN
gözlemlendi; Linux'ta (Docker, aarch64, native) SIFIRDAN checkout'tan
İKİ ARDIŞIK TAM `zig build test` (Debug+ReleaseFast) çalışması yeşil.

**CI matrisi genişletildi (`.github/workflows/ci.yml`):** macOS/aarch64
(`macos-14`) + Linux/x86-64 (`ubuntu-latest` — Faz R.2'nin x86-64 fiber
kodunu GERÇEK donanımda, yerel Rosetta çevirisinin AKSİNE, doğrular) +
Linux/aarch64 (`ubuntu-24.04-arm`) — Linux'ta `qbe` KAYNAKTAN derlenir
(Homebrew'de YOK). **Bilinçli sınırlama (Faz R.3'ün KENDİ kapsamı DIŞINDA
bırakıldı, ayrı bir gelecekteki iş):** `compile_swap_asm` (build.zig)
HÂLÂ HOST derleyicisini (`cc`) kullanıyor — GERÇEK çapraz derleme
(`-Dtarget` ile HOST'tan FARKLI bir mimari İÇİN tek bir makineden üretim)
`zig cc -target ...`e geçiş GEREKTİRİR, bu CI matrisinin HER platformu
KENDİ native runner'ında derlediği İÇİN bu turun kapsamında ZORUNLU
DEĞİLDİ.

---

## 3.11 Faz R.4 — Zig Araç Zinciri Sürüm Pinlemesi

`build.zig.zon`nin `minimum_zig_version`i Zig'in KENDİ araç zincirinin
uyguladığı bir TABANDIR (daha ESKİ bir derleyiciyi REDDEDER) — ama DAHA
YENİ bir derleyiciyi ASLA reddetmez. Zig HENÜZ 1.0 ÖNCESİ olduğundan (sık
KIRICI değişiklikler), "en az bu sürüm" TEK BAŞINA yeterli bir
tekrarlanabilirlik garantisi DEĞİLDİR.

**Çözüm:** `build.zig`ye `EXPECTED_ZIG_VERSION` sabiti (şu an `0.16.0` —
`.github/workflows/ci.yml`nin `mlugg/setup-zig@v1` PİNİYLE AYNI) VE
`build()`in EN BAŞINDA `builtin.zig_version`le KARŞILAŞTIRAN bir denetim
eklendi. Eşleşmezse (daha ESKİ YA DA daha YENİ FARK ETMEZ) net bir UYARI
basılır — **KOŞULSUZ bir `@compileError` DEĞİL**, bilinçli bir seçim:
yama sürümleri (ör. 0.16.1) genellikle GERİYE UYUMLUDUR, bu yüzden
geliştiriciyi TAMAMEN ENGELLEMEK yerine SADECE bir sonraki Zig sürümüne
GEÇİŞ sırasında bu sabitin de GÜNCELLENMESİ GEREKTİĞİNİ HATIRLATAN bir
uyarı yeterlidir.

**Doğrulama:** kasıtlı boz→doğrula→düzelt — `EXPECTED_ZIG_VERSION`
GEÇİCİ olarak yanlış bir sürüme (`0.16.99`) değiştirilip `zig build
--help`in GERÇEKTEN UYARI bastığı doğrulandı, SONRA geri getirilip
uyarının KAYBOLDUĞU (sessiz, `zig build test` Debug+ReleaseFast yeşil)
doğrulandı.

---

## 3.12 Faz S.1 — Task/Channel/dict Yeniden Atama Sızıntısını Düzelt

**Bulunan hata:** `Task[T]`/`Channel[T]`/`dict[K,V]` `isHeapManaged`in
DIŞINDadır (bkz. `HeapKind`in belge notu, `compiler/codegen_qbe/codegen.zig`)
— ARC başlığı/retain-on-alias YOK, kapsam-sonu temizliği DOĞRUDAN bir
`nox_async_destroy_task`/`nox_channel_destroy`/`nox_dict_destroy` çağrısıdır.
Ama `genAssign`in `.identifier` (yerel yeniden atama) VE `.attribute` (sınıf
alanı yeniden atama) dalları bu üç türü HİÇ ele almıyordu — yalnızca
`isHeapManaged` (list/class/str) İÇİN eski değeri serbest bırakıyordu. Yani
`t: Task[None] = spawn f(); t = spawn g();` gibi bir yeniden atamada İLK
`spawn`ın döndürdüğü `Task` tutamacı SIZIYORDU (kod, KENDİSİ tarafından
ÖNCEDEN "bilinçli v0.1 sınırlaması" olarak DOĞRU şekilde belgelenmişti —
bkz. eski `releaseAllLocalsExcept` yorumu).

**İKİNCİ, DAHA DERİN bir bulgu — Task İÇİN saf "yeniden atamada serbest
bırak" YETERSİZ, GÜVENSİZ:** `Task(T)` struct'ının KENDİSİ, fiber'ın
`entryTrampoline`i tarafından TAMAMLANDIĞINDA `self.result`/`self.completed`e
YAZILAN bellektir (bkz. `runtime/async_rt/scheduler.zig`). Bir görev HENÜZ
tamamlanmadan (ör. `spawn` edilip HİÇ `await` edilmeden hemen yeniden atanırsa
— fiber henüz hiç ÇALIŞMAMIŞ, yalnızca hazır kuyruğa EKLENMİŞ olabilir)
struct'ı HEMEN serbest bırakmak, fiber SONRADAN tamamlanınca serbest
bırakılmış belleğe YAZAN bir use-after-free olurdu — SIRADAN bir "eski
değeri serbest bırak" düzeltmesi (dict/Channel İÇİN yeterli olan) Task İÇİN
YENİ bir bellek güvenliği hatası AÇARDI.

**Çözüm — iki katmanlı:**

1. **`compiler/codegen_qbe/codegen.zig`:** yeni `destroyNonArcValue`/
   `destroyNonArcSlotIfSet` yardımcıları (`releaseValueIfSet`/`releaseSlotIfSet`in
   Task/Channel/dict karşılığı, `releaseAllLocalsExcept`in ESKİ tekrarlı
   kodundan ÇIKARILDI). `genAssign`in HEM `.identifier` HEM `.attribute`
   dalları artık yeniden atamada BU yardımcıyla eski değeri yok ediyor —
   `releaseAllLocalsExcept` VE `genClassRelease` (sınıf alanı İÇİN, ÖNCEDEN
   yalnızca `dict` kapsıyordu, ŞİMDİ Task/Channel'ı da kapsıyor) de AYNI
   yardımcıyı kullanacak şekilde birleştirildi.
2. **`runtime/async_rt/scheduler.zig` + `bridge.zig`:** `Task(T)`e yeni bir
   `detached: bool` alanı eklendi. `nox_async_destroy_task` artık görev
   `completed` İSE HEMEN serbest bırakır (ÖNCEKİ davranış — güvenli, çünkü
   fiber ARTIK struct'a bir daha YAZMAZ); tamamlanMAMIŞSA yalnızca
   `detached = true` işaretler, GERÇEK serbest bırakmayı `entryTrampoline`in
   KENDİSİNE (görev bitince `self.detached` İSE `self`i KENDİSİ serbest
   bırakıp `completed`/`waiter` mantığına HİÇ girmeden döner) ERTELER. Bu,
   "fire-and-forget" (hiç `await` edilmeden bırakılan) görevlerin de HEM
   sızmadan HEM bellek güvenliği ihlal edilmeden temizlenmesini sağlar —
   yalnızca REASSIGNMENT YOLUNU değil, `releaseAllLocalsExcept`in ÖNCEDEN
   VAR OLAN (bu fazdan ÖNCE de teorik olarak mevcut olan, ama HİÇ tetiklenmemiş)
   AYNI riskini de KÖKTEN çözer.

**ÜÇÜNCÜ bulgu — bu fazın doğrulama testi ReleaseFast'ta GERÇEK bir SIGSEGV'e
yol açtı (kod hatası DEĞİL, test metodolojisi hatası):** yeni `Task.detached`
mantığını doğrulayan `scheduler.zig` birim testi İLK yazıldığında GERÇEK bir
`scheduler.run()` (yani GERÇEK bir fiber) üzerinden `std.testing.allocator`
(DebugAllocator) ile `entryTrampoline`in `destroy` çağrısını tetikliyordu —
Debug'da yeşildi ama `-Doptimize=ReleaseFast`ta `SIGSEGV`ile ÇÖKTÜ. Kök
neden `runtime/async_rt/fiber.zig`nin ZATEN belgelediği, bu projenin
GEÇMİŞİNDE de yaşanmış (bkz. `callEntryPadded`in belge notu) bir tuzak:
DebugAllocator'ın çerçeve-işaretçisi TABANLI yığın-izi yakalaması, fiber'ın
SAHTE önyükleme çerçevesinin ÖTESİNE geçmeye çalışır — ReleaseFast'ta
çerçeve işaretçileri farklı/eksik davranabildiğinden bu YÜRÜYÜŞ geçersiz
belleğe düşer. **Düzeltme kod TARAFINDA değil, TEST TARAFINDA yapıldı:**
test artık GERÇEK bir fiber/`scheduler.run()` ÜZERİNDEN DEĞİL, `Task(i64).
entryTrampoline`i DOĞRUDAN (fiber bağlamı OLMADAN, testin KENDİ normal çağrı
yığınında) çağırıyor — `entryTrampoline`in `detached` dalı fiber bağlamına
ÖZGÜ bir şey YAPMADIĞINDAN bu, AYNI mantığı güvenle egzersiz eder VE
`std.testing.allocator`ın otomatik sızıntı/çift-serbest-bırakma denetiminden
faydalanmaya devam eder.

**Doğrulama:** üç kasıtlı boz→kırmızıyı doğrula→düzelt turu — (1) `genAssign`in
Task/Channel/dict dalları GEÇİCİ olarak devre dışı bırakılıp YENİ 3 golden
testin (`task_reassignment_frees_old.nox`, `channel_reassignment_frees_old.nox`,
`dict_reassignment_frees_old.nox`) GERÇEKTEN kırmızıya döndüğü doğrulandı;
(2) `entryTrampoline`in `detached` dalı GEÇİCİ olarak devre dışı bırakılıp
YENİ scheduler birim testinin GERÇEKTEN "1 leaks" ile kırmızıya döndüğü
doğrulandı — İKİSİ de SONRA geri getirildi. `zig build test` (Debug +
ReleaseFast) 269/269 yeşil, `zig fmt --check` temiz.

---

## 3.13 Faz S.2 — list[T] İndeksleme Sınır Kontrolü

**Bulunan hata:** `genIndex` (`compiler/codegen_qbe/codegen.zig`) `list[T]`
İÇİN sınır kontrolü OLMADAN DOĞRUDAN pointer aritmetiği yapıyordu —
`xs[999]` gibi bir erişim tanımsız davranışa (geçersiz bellek okuma/segfault)
yol açardı. `s[i]` (stdlib fazı §G) ZATEN bir sınır kontrolü/`IndexError`
deseni kullanıyordu (`genStrIndex`); `list[T]` bu deseni HİÇ paylaşmıyordu.

**Çözüm:** `genIndex`in `list` dalına `genStrIndex` İLE AYNI "önce doğrula
(negatif VEYA `>= len`), hata dalında `IndexError` `raise` et, phi'SİZ `ok`e
atla" deseni eklendi. Liste uzunluğu AYRI bir betimleyiciye GEREK
DUYULMADAN doğrudan payload'ın İLK 8 baytından (`obj.text`ten `loadl`)
okunur (bkz. `genListLit`nin düzeni). `checker.zig`de HİÇBİR değişiklik
gerekmedi (tip kontrolü zaten doğruydu, yalnızca ÇALIŞMA ZAMANI davranışı
eksikti).

**Yan bulgu — `tests/compat/extern_ffi_test.zig`nin `compileAndRun`ı `core.
nox`u (dolayısıyla `IndexError`/`ValueError`i) HİÇ birleştirmiyordu:**
`codegen_golden_test.zig`/`http_*_golden_test.zig` gibi diğer test
dosyalarının AKSİNE, bu dosya `module_loader.resolveImports`ı ÇAĞIRMIYORDU
— `nox.parser.parseModule`in çıktısını DOĞRUDAN checker'a veriyordu. Bu,
YENİ liste sınır kontrolü `list[str]` döndüren bir `extern def`in `[0]`
indekslemesini derlerken `IndexError` sınıfını `self.classes`de BULAMAYIP
`error.Unsupported` dönene KADAR SESSİZCE gizli kalmış, ÖNCEDEN VAR OLAN bir
eksiklikti (bu dosya DAHA ÖNCE hiçbir testte `str`/`list` indekslemesi
kullanmamıştı). **Düzeltildi:** `compileAndRun` artık `codegen_golden_test.
zig` İLE AYNI şekilde `resolveImports`ı çağırıyor.

**Doğrulama:** yeni golden test (`list_index_out_of_bounds_raises.nox` —
`genStrIndex`in KENDİ testiyle AYNI desen, pozitif VE negatif sınır dışı
erişim, `try/except IndexError` ile yakalanıp mesaj basılır). Kasıtlı
boz (sınır-kontrol dalı KOŞULSUZ `err_label`e atlayacak şekilde) →
kırmızıyı doğrula → düzelt ritüeli uygulandı. `zig build test`
(Debug + ReleaseFast) 270/270 yeşil, `zig fmt` temiz.

---

## 3.14 Faz S.3 — Katman 3 Döngü Çözücü: Tasarım + İlk İmplementasyon

**Kapsam kararı (kullanıcıyla netleşti):** görev başlangıçta "yalnızca döngü
çözücü yaz" gibi görünüyordu, ama araştırma İKİ ayrı, büyük parçaya ayrıldığını
ortaya çıkardı — bkz. aşağıdaki "Beklenmeyen ön koşul" — kullanıcı İKİSİNİN
DE (öz-referans desteği + gerçek döngü çözücü) TEK bir turda yapılmasını
seçti.

**Beklenmeyen ön koşul — döngüler BUGÜN dilde HİÇ kurulamıyordu:**
`codegen.zig`nin `registerClass`ı sınıfları DOSYA SIRASIYLA işliyordu ve bir
sınıfın alan tipleri yalnızca DAHA ÖNCE `self.classes`a eklenmiş bir sınıfa
referans verebiliyordu — bu, öz-referansı (`class Node: next: Node`) VE
ileri-referanslı karşılıklı döngüleri (`class A: b: B` / `class B: a: A`)
derleme zamanında YAPISAL olarak İMKANSIZ kılıyordu (`uretim-hazirlik-
analizi.md`nin ZATEN doğru teşhis ettiği gibi). **Keşif:** stdlib fazı §L
(`nox.json`) SIRASINDA `generateModule`e ZATEN TÜM sınıf adlarını (alanları
çözülmeden ÖNCE) boş bir yer tutucuyla `self.classes`a önceden ekleyen bir
DÜZELTME eklenmişti (`list[JsonValue]`yi desteklemek için) — bu, `resolveType`in
`.simple` (DOĞRUDAN sınıf tipi) dalını da YAN ETKİ olarak zaten düzeltmişti,
AMA `inferFieldType` (alan TİPİNİ `__init__` gövdesinden ÇIKARAN, AYRI bir
fonksiyon) hâlâ yalnızca `__init__` PARAMETRELERİNİ/literalleri destekliyordu
— `self.next = self` (bir nesnenin KENDİSİNE atanması) desteklenMİYORDU.
**Çözüm:** `inferFieldType`e `class_name` parametresi eklendi, `.identifier`
dalına `name == "self"` özel durumu eklendi (kendi sınıf tipini döner) — bu,
`self.next = self` İLE bir nesnenin KENDİ KENDİSİNE işaret eden bir "öz-döngü"
olarak İNŞA EDİLMESİNİ sağlar (`None`/opsiyonel tip GEREKMEDEN — dil bunu O
ZAMAN HENÜZ desteklemiyordu; Faz FF.6'dan (§3.65) SONRA `next: Node | None`
İLE `self.next = None` DOĞRUDAN da yazılabilir, bu öz-döngü hilesi ARTIK
YALNIZCA bir GEÇMİŞ dönem çözümüdür, gerekli DEĞİLDİR); SONRA `a.next = b;
b.next = a;` gibi bir yeniden atamayla
(ZATEN var olan `obj.attr = value` mekanizması) GERÇEK bir A↔B döngüsüne
dönüştürülebilir. Bu, `docs/uretim-hazirlik-analizi.md`nin AÇIKÇA riski
olarak işaretlediği "`list[T]` sınıf alanı/ileri-referans genişletildiği AN
döngüler sessizce sızmaya başlar" senaryosunun TAM OLARAK KENDİSİ — ARTIK
gerçek, GEÇERLİ bir Nox programı YAZILABİLİR durumda.

**Algoritma seçimi:** Bacon & Rajan'ın senkron "trial deletion" (deneme-
yanılma silme) döngü toplayıcısı — Nim'in ORC modelinin ve CPython'ın kendi
döngü GC'sinin de akrabası olan, İYİ bilinen, üç geçişli (MarkRoots/MarkGray
→ ScanRoots/Scan/ScanBlack → CollectRoots/CollectWhite) bir algoritma —
tercih edildi ("hafif arka plan taraması" hedefine UYGUN, tam bir kapsamlı
mark-sweep'TEN çok daha AZ iş yapar: yalnızca "olası kök" olarak işaretlenen
nesnelerin alt-grafiğini tarar, TÜM heap'i DEĞİL).

**v1 kapsamı (bilinçli dar, AGENTS.md §8 İLE UYUMLU):** yalnızca SINIF
örnekleri arasındaki döngüler — `list[T]`/`dict[K,V]` elemanları/`str` bu
taramaya DAHİL DEĞİL (bugün onlar HİÇBİR ŞEKİLDE bir döngü kuramaz, bu yüzden
gereksiz).

**Uygulama — iki katman:**
1. **`runtime/alloc/cycle_detector.zig`** (YENİ dosya): Bacon-Rajan'ın
   TAMAMI — renk/buffered durumu nesnelerin KENDİ 8 baytlık ARC başlığında
   DEĞİL (bu formatı DEĞİŞTİRMEMEK, `arc.zig`nin/inline retain-predecrement
   emisyonunun HİÇBİR çağrı sitesini ETKİLEMEMEK için), AYRI bir yan tabloda
   (`CycleGc.meta`, işaretçiden meta'ya `AutoHashMap`) tutulur. Çocukları
   keşfetme (`traceChildren`), derleyicinin ürettiği `$nox_trace_dispatch`
   sembolünü `dlsym` İLE ÇALIŞMA ZAMANINDA arar (`nox_json_make_json_value`nin
   AYNI gerekçesi — sembol yalnızca SINIF İÇEREN programlarda üretilir,
   sabit bir `extern fn` sınıfsız programlarda/`noxrt_test`te bağlama
   adımını ÇÖKERTİRDİ).
2. **`compiler/codegen_qbe/codegen.zig`:** HER sınıf İÇİN iki YENİ fonksiyon
   — `$ClassName_trace(rt, p) -> l` (sınıf-tipli alanların değerlerini bir
   `nox_alloc`'lu arabelleğe yazar, `list[T]`nin AYNI 8-bayt-uzunluk+N-
   işaretçi düzeni) ve `$ClassName_gc_free(rt, p)` (sınıf-tipli OLMAYAN
   alanları NORMAL serbest bırakır, sınıf-tipli alanlara HİÇ DOKUNMAZ —
   onlar `collectWhite`in KENDİ özyinelemeli gezinmesiyle AYRICA ele alınır,
   ÇİFT serbest bırakmayı ÖNLEMEK için — SONRA nesnenin belleğini KOŞULSUZ
   serbest bırakır). İKİ dağıtım fonksiyonu (`$nox_trace_dispatch`/
   `$nox_gc_free_dispatch`, sınıf `tag`ine göre if-zinciri — QBE'de `switch`
   YOK) TÜM sınıfları kapsar. `genClassRelease`nin predecrement SIFIRA
   DÜŞMEDİĞİ dalı — YALNIZCA en az bir sınıf-tipli alanı OLAN sınıflar İÇİN
   (performans: sıradan sınıflar sıfır ek maliyet öder) —
   `nox_cycle_possible_root`e; SIFIRA DÜŞTÜĞÜ (gerçekten serbest bırakıldığı)
   dal `nox_cycle_forget`e (adres yeniden kullanımına karşı GÜVENLİK, bkz.
   onun belge notu) yönlendirilir.

**Tetikleme:** `nox_cycle_possible_root`, tahsis-baskısı sayaç eşiğini
(varsayılan 700, CPython'ın gen0 eşiğine yakın) AŞTIĞINDA OTOMATİK
`nox_cycle_collect` çağırır (AGENTS.md §8: "varsayılan: tahsis baskısı
eşiği"); AYRICA `nox_runtime_deinit` PROGRAM SONUNDA (eşiğe HİÇ ulaşmamış
kısa ömürlü programları/testleri KAÇIRMAMAK için) SON bir kez çağırır.

**Doğrulama — DÖRT kasıtlı boz→kırmızıyı doğrula→düzelt turu:**
1. `runtime/alloc/cycle_detector.zig`ye İKİ Zig birim testi eklendi:
   gerçek `nox_rc_alloc`'lu, GERÇEK bir A↔B döngüsü (`dlsym` yerine `g_trace_
   dispatch_fn`/`g_gc_free_dispatch_fn`e SAHTE bir uygulama enjekte edilerek,
   QBE'siz saf Zig'de) — `std.heap.DebugAllocator`ın KENDİ sızıntı/çift-
   serbest-bırakma denetimiyle DOĞRULANDI; ve "döngü İÇİNDEKİ bir nesne
   dışarıdan da canlıysa (surviving retain) YANLIŞLIKLA toplanmaz" (over-
   collection'a KARŞI, mark/scan tersine çevirmesinin GERÇEKTEN çalıştığını
   kanıtlar).
2. `markGray`nin çocuk refcount azaltma satırı GEÇİCİ olarak devre dışı
   bırakılıp HEM iki Zig birim testinin HEM AŞAĞIDAKİ golden testin GERÇEKTEN
   kırmızıya döndüğü doğrulandı — SONRA geri getirildi.
3. `nox_runtime_deinit`nin SON `nox_cycle_collect` çağrısı GEÇİCİ olarak
   devre dışı bırakılıp golden testin GERÇEKTEN kırmızıya (sızıntı) döndüğü
   doğrulandı — SONRA geri getirildi.
4. Yeni golden test (`class_reference_cycle_collected.nox`) — `Node.__init__`
   `self.next = self` ile başlar (öz-döngü bootstrap), SONRA `a.next = b;
   b.next = a;` ile GERÇEK bir A↔B döngüsü kurulur; hem DOĞRU çıktı (`1\n2\n1\n`,
   döngünün GERÇEKTEN doğru bağlandığını kanıtlar) hem STDERR'İN BOŞ olması
   (sızıntı YOK) doğrulanır.

`zig build test` (Debug + ReleaseFast) 273/273 yeşil, `zig fmt` temiz.

**Bilinçli v1 sınırlamaları (gelecekteki bir faz İÇİN not edilir):**
- `list[T]`/`dict[K,V]` elemanları taramaya DAHİL DEĞİL (bugün gereksiz,
  onlar döngü kuramaz — bu genişlerse AYRI bir faz gerekir).
- Tarama SENKRON (stop-the-world, ama YALNIZCA olası-kök alt-grafiği kadar
  küçük) — Bacon-Rajan'ın "concurrent" varyantı (arka plan iş parçacığında)
  UYGULANMADI (v0.1'in tek-OS-iş-parçacığı fiber modeliyle ZATEN tutarlı).
- Eşik (700) SABİT bir varsayılan — çalışma zamanında ayarlanabilir bir API
  (ör. `nox.gc.set_threshold`) YOK.

---

## 3.15 Faz T.1 — AST'ye Kaynak Pozisyonu (Satır) Ekleme

**Kapsam kararı — DEYİM (statement) GRANÜLERLİĞİ, İFADE (expression) DEĞİL:**
"AST'ye pozisyon ekle" görevi, EN GENİŞ yorumuyla `ast.Expr`in TÜM alt
türlerine de (her `Binary`/`Call`/`Attribute` DÜĞÜMÜNE) satır/sütun eklemeyi
gerektirebilirdi — ama `ast.Expr`, `checker.zig` VE `codegen_qbe/codegen.zig`
genelinde (`checkExpr`/`genExpr`in HER özyinelemesinde) DÜZİNELERCE yerde
eşleştirilen bir birleşim (union) OLDUĞUNDAN, ONU bir `{ kind, line }`
sarmalayıcısına ÇEVİRMEK bu İKİ dosyanın (sırasıyla ~1600/~4300 satır)
NEREDEYSE TAMAMINI mekanik ama YÜKSEK RİSKLİ bir şekilde yeniden yazmayı
gerektirirdi. **Ölçülen karşılaştırma:** `ast.Stmt`i eşleştiren yer sayısı
(`switch (stmt)`/`stmt == .xxx`), TÜM kod tabanında yalnızca ~25 idi (SALT
`checkStmt`/`genStmts`in KENDİ dağıtım noktaları + birkaç modül-düzeyi
filtre) — bu, DEYİM granülerliğinde pozisyon eklemeyi GÜVENLE, `ast.Expr`e
HİÇ DOKUNMADAN yapılabilir kıldı. Bir DEYİM içindeki bir ALT ifadede oluşan
bir hata, o DEYİMİN satırını raporlar (Python'un KENDİ hata raporlamasıyla
BENZER bir granülerlik — CPython da genellikle "satır N" der, SÜTUN
numarası her zaman vermez).

**Uygulama:**
1. **`compiler/parser/ast.zig`:** eski `pub const Stmt = union(enum) {...}`
   `StmtKind`e yeniden adlandırıldı; YENİ `pub const Stmt = struct { kind:
   StmtKind, line: u32 = 0 }` bunu SARAR. `Module.body`/`IfStmt.then_body`
   gibi TÜM `[]Stmt` alanları DEĞİŞMEDEN kalır (yalnızca elemanların KENDİSİ
   artık `.kind` erişimi GEREKTİRİR).
2. **`compiler/parser/parser.zig`:** `parseStmt` (TÜM deyim ayrıştırmasının
   TEK dağıtım noktası) satırı (`self.cur().line`, lexer'ın ZATEN topladığı
   `Token.line`) DAĞITIMDAN ÖNCE yakalar, alt-ayrıştırıcıların (`parseIf`
   vb., DÖNÜŞ TİPLERİ `ast.Stmt`TEN `ast.StmtKind`e DEĞİŞTİRİLDİ — GÖVDELERİ
   hiç değişmedi, Zig'in `.{ .if_stmt = ... }` sözdizimi hedef TİPTEN
   çıkarım yaptığından) SONUCUNU `.{ .kind = kind, .line = line }` ile SARAR
   — bu, KAYNAK satırının her deyim İÇİN tutarlı yakalanmasını, ayrıştırıcının
   HİÇBİR alt fonksiyonuna AYRICA dokunmadan sağlar.
3. **`compiler/typecheck/checker.zig`:** yeni `Checker.current_line: u32`
   alanı; `checkStmt` (TÜM deyim denetiminin TEK, ÖZYİNELEMELİ dağıtım
   noktası — if/while/for/try gövdeleri DAHİL) HER çağrıda `self.current_line
   = stmt.line` günceller; `fail()` mesaja `"satır {d}: "` ÖN EKİ ekler
   (`current_line > 0` İSE). `checkStmt`e HİÇ girmeyen üst-düzey geçişler
   (`collectClassNames`/`registerSignatures`/`collectProtocols`/`checkModule`nin
   KENDİ üst-düzey switch'i) KENDİ döngülerinde AYRICA günceller.
4. **`compiler/codegen_qbe/codegen.zig`/`compiler/ownership/analysis.zig`/
   `compiler/module_loader.zig`:** TÜM `switch (stmt)`/`stmt == .xxx`
   yerleri (~20 site) `switch (stmt.kind)`/`stmt.kind == .xxx`e güncellendi
   — HİÇBİR DAVRANIŞ DEĞİŞMEDİ, yalnızca ERİŞİM YOLU. Generic örnekleme
   (`checker.zig`nin `substituteStmt`i) VE stdlib mangling'i (`module_loader.
   zig`nin `renameStmt`i) — bunlar YENİ `Stmt` değerleri SENTEZLER — ORİJİNAL
   `s.line`i yeni deyime AYNEN TAŞIR.

**Yan bulgu — 22 mevcut typecheck golden testinin `.expected` dosyası
GÜNCELLENDİ:** `HATA <kod>: <mesaj>` biçimindeki TÜM hata mesajları artık
`"satır N: "` ÖN EKİ taşıyor — bu KASITLI, BEKLENEN bir DAVRANIŞ DEĞİŞİKLİĞİ
(golden test biçiminin KENDİSİ, tanılama iyileştirmesinin BİR PARÇASI olarak
güncellendi), bir REGRESYON DEĞİL. Her satır numarası, İLGİLİ `.nox`
fixture'ının KAYNAĞIYLA elle ÇAPRAZLANDI (ör. `err_undefined_attribute.nox`
İÇİN "satır 6" — DOĞRU, `return self.z` TAM O SATIRDA).

**Doğrulama:** yeni golden test (`err_position_tracks_later_statement.nox`)
— BİLEREK NESTED bir yapı (bir fonksiyon gövdesi İÇİNDE bir `if` bloğu,
hatalı deyim `if`in KENDİ satırından FARKLI, DAHA SONRAKİ bir satırda) —
bu, `checkStmt`in ÖZYİNELEMELİ güncellemesini (üst-düzey döngülerin KENDİ,
BAĞIMSIZ güncellemesinden AYRI olarak) İZOLE EDEREK doğrular. Kasıtlı boz
(`checkStmt`in `self.current_line = stmt.line;` satırı GEÇİCİ yorum satırı
yapıldı) → 7 mevcut test + YENİ test GERÇEKTEN kırmızıya döndü (nested
statement'ların YANLIŞ/ESKİ satır raporladığı doğrulandı) → SONRA geri
getirildi. `zig build test` (Debug + ReleaseFast) 274/274 yeşil, `zig fmt`
temiz.

**Bilinçli v1 sınırlaması:** sütun (column) numarası HENÜZ raporlanmıyor
(yalnızca satır) — `Token.line`/`Token.col` HER İKİSİ de lexer'da ZATEN
mevcut, `parseStmt`in `line`i `self.cur().col`ü de AYNI ŞEKİLDE
yakalayabilirdi, ama DEYİM granülerliğinde bir sütun numarası ("deyimin
BAŞLADIĞI sütun") tek başına ÇOK az ek değer katardı (deyim İÇİNDEKİ HANGİ
alt-ifadenin hatalı olduğunu YİNE göstermez) — bu yüzden BİLİNÇLİ olarak
ERTELENDİ. İFADE granülerliği (T.2'nin ÇOKLU-tanılama/hata kurtarma görevi
İLE BİRLİKTE ele alınabilecek, `ast.Expr`e dokunmayı GEREKTİREN daha büyük
bir faz) de AYNI şekilde ERTELENDİ.

---

## 3.16 Faz T.2 — Checker'a Çoklu-Tanılama/Hata Kurtarma Ekleme

**Kapsam kararı — İRİ GRANÜLERLİK (fonksiyon/metod/gevşek-deyim SINIRI),
İÇ-BİRİM kurtarma DEĞİL:** "birden çok hata raporla" görevi, EN GENİŞ
yorumuyla `checkExpr`/`checkStmt`in KENDİ kontrol akışını (bir deyimin/
ifadenin İÇİNDE bile İKİNCİ bir hatadan SONRA devam edebilmeyi) yeniden
yapılandırmayı gerektirebilirdi — bu, T.1'in `ast.Expr`e dokunmama kararıyla
AYNI gerekçeyle (yüzlerce eşleştirme sitesi, YÜKSEK risk) BİLİNÇLİ olarak
REDDEDİLDİ. Bunun yerine kurtarma YALNIZCA `checkModule`nin ÜST-DÜZEY
döngüsünün (HER `func_def`/`class_def`/gevşek deyim BAĞIMSIZ bir birimdir)
VE `checkClassBody`nin metod döngüsünün (HER metod BAĞIMSIZ bir birimdir)
DOĞAL sınırlarında yapılır — Zig'in `catch` İFADESİ bu sınırlarda
propagasyonu TEMİZ bir şekilde KESEBİLİR, çünkü DIŞ döngü bir SONRAKİ
bağımsız birime geçerken İÇ birimin KISMİ durumunu (scope, kısmi tip
çıkarımı) HİÇ yeniden inşa etmesi GEREKMEZ — o birim ZATEN tamamen
terk edilir.

**Uygulama:**
1. **`compiler/typecheck/checker.zig`:** yeni `pub const Diagnostic = struct
   { code: TypeError, line: u32, message: []const u8 }`; `Checker`e yeni
   `diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty` alanı; yeni
   `recordDiagnostic(self, err: TypeError) TypeError!void` yardımcısı —
   `error.OutOfMemory`İ (KURTARILAMAZ, bir "tanılama" DEĞİL) DEĞİŞTİRMEDEN
   yeniden fırlatır, AKSİ HALDE `self.diagnostic` (ZATEN `fail()`in "satır
   N: " önekini taşıyan mesaj) + `self.current_line`den bir `Diagnostic`
   İNŞA EDİP `self.diagnostics`e EKLER.
2. **`checkModule`nin üst-düzey switch'i:** `.func_def`/`.class_def`
   dalları VE gevşek deyimleri işleyen `else` dalı, ilgili denetim
   çağrısını (`checkFunctionBody`/`checkClassBody`/`checkStmt`) `catch |e|
   try self.recordDiagnostic(e)` İLE SARAR — bir birim BAŞARISIZ olursa
   tanılama KAYDEDİLİR, döngü BİR SONRAKİ bağımsız birime DEVAM EDER.
3. **`checkClassBody`nin İKİ metod döngüsü** (`__init__` + diğer metodlar)
   AYNI deseni `checkMethodBody` çağrısına uygular — bir sınıftaki BİR
   metodun hatası, AYNI sınıfın DİĞER metodlarının denetimini ENGELLEMEZ.
4. **`CheckOutcome`:** `err` varyantı yeni bir `all: []const Diagnostic`
   alanı KAZANDI (`code`/`message`, GERİYE DÖNÜK UYUMLULUK İÇİN İLK
   tanılamayı taşımaya DEVAM EDER — TEK-hata tüketicileri DEĞİŞMEDEN
   çalışır). `check()` ARTIK `checkModule`nin BAŞARIYLA (fırlatmadan)
   DÖNMESİNDEN SONRA `checker.diagnostics.items.len > 0` mı diye AYRICA
   kontrol eder — kurtarılan hatalar `checkModule`yi FIRLATMADIĞINDAN,
   "başarılı dönüş" ARTIK TEK BAŞINA "hatasız" ANLAMINA GELMEZ.
5. **Geriye dönük uyumluluk — 6 doğrudan `Checker` tüketicisi** (`main.zig`
   + `tests/{compat/{hpy_call,extern_ffi,http_stdlib,http_serve}_golden_test,
   golden/codegen_golden_test}.zig`, `checker.check()`in SARMALAYICISINI
   DEĞİL `Checker.checkModule`yi DOĞRUDAN çağırıyorlar — bkz. Faz 10 notu):
   HER BİRİNE `checkModule`nin `catch` bloğundan HEMEN SONRA AYNI
   `checker_state.diagnostics.items.len > 0` kontrolü + TÜM tanılamaları
   YAZDIRIP (ESKİ, TEK-hata "beklenmeyen tip hatası" mesajıyla AYNI biçimde)
   başarısız SAYMA eklendi — AKSİ HALDE bu tüketiciler (`main.zig` DAHİL)
   kurtarılmış bir hatayı SESSİZCE YUTUP hatalı bir modülü codegen'e
   İLETİRDİ (GERÇEK bir REGRESYON olurdu, "çoklu tanılama" özelliğinin
   TAM TERSİ bir sonuç).

**Bilinçli sınırlama (KABUL EDİLDİ, v1 kapsamında):** kurtarma yalnızca İRİ
granülerlikte — AYNI fonksiyon/metod İÇİNDEKİ İKİNCİ bir hata HÂLÂ
raporlanMAZ (o birimin KENDİ denetimi İLK hatada durur, T.1'İN "DEYİM
granülerliği" kararıyla AYNI ödünleşim). AYRICA bir üst-düzey `var_decl`
BAŞARISIZ olursa o isim kapsama HİÇ girmez — SONRAKİ bir deyimin AYNI ismi
kullanması İKİNCİL (cascading) bir "tanımsız değişken" hatası ÜRETEBİLİR;
BENZER şekilde bir sınıfın `__init__`i BAŞARISIZ olursa alanları KAYDEDİLMEZ,
o sınıfın DİĞER metodları `self.<alan>`e erişince kendi cascading hatalarını
üretebilir. Bu, İYİ bilinen bir hata-kurtarma ödünleşimidir (gerçek
derleyicilerin ÇOĞU AYNI sınırı çeker) — İÇ-BİRİM kurtarma/kısmi tip
çıkarımı iyileştirmesi GELECEKTEKİ bir fazdır.

**Doğrulama:** yeni golden test
(`err_multi_diagnostic_recovery.nox` — İKİ bağımsız fonksiyon, HER BİRİ
kendi gövdesinde bir `TypeMismatch`) — `check()`in `outcome.err.all.len ==
2` VE HER İKİ tanılamanın DOĞRU satırı (2 ve 5) taşıdığını doğrular. Kasıtlı
boz (`.func_def` dalındaki `catch |e| try self.recordDiagnostic(e)` GEÇİCİ
olarak `try self.checkFunctionBody(fd)`e döndürüldü) → test GERÇEKTEN
kırmızıya döndü (`expected 2, found 0` — kurtarma OLMADIĞINDA `checkModule`
İLK hatada FIRLIYOR, `diagnostics` HİÇ dolmuyor) → geri getirildi, YEŞİLE
döndüğü doğrulandı. `zig build test` (Debug + ReleaseFast) 275/275 yeşil,
`zig fmt` temiz.

---

## 3.17 Faz T.3 — DWARF/-g Debug Bilgisi Emisyonu

**Ön araştırma — QBE'nin GERÇEK yeteneği:** `qbe -h` yalnızca `-d <flags>`
(QBE'nin KENDİ derleyici-içi hata ayıklama dökümü, DWARF İLE İLGİSİZ)
gösteriyor olsa da, `strings qbe` ikili taraması İKİ belgelenmemiş IL
anahtar kelimesi ORTAYA ÇIKARDI: `dbgfile "<yol>"` (modül seviyesinde,
"BUNDAN SONRAKİ fonksiyonlar BU kaynak dosyaya ait" — birden çok kez
kullanılabilir, HER kullanım BİR SONRAKİ fonksiyona kadar aktif kalır) ve
`dbgloc <satır>[, <sütun>]` (bir deyimden ÖNCE). Elle yazılmış `.ssa`
dosyalarıyla DENEYSEL olarak DOĞRULANDI (bkz. aşağı): bunlar hedef
assembler'ın `.file`/`.loc` sözde-yönergelerine BİREBİR eşleniyor — **QBE
KENDİSİ DWARF ÜRETMEZ**, yalnızca assembler'a (`as`/`clang`) "üret" TALİMATI
verir; GERÇEK `.debug_line` bölümünü assembler İNŞA EDER.

**Uygulama:**
1. **`compiler/codegen_qbe/codegen.zig`:** `Codegen`e `debug_info: bool =
   false` alanı; `generateModule`e YENİ bir `debug_source_path: ?[]const u8`
   parametresi (7 çağrı sitesinin HEPSİ güncellendi — `main.zig` + 6 test
   dosyası, TÜM testler `null` GEÇİRİR, davranış DEĞİŞMEZ) — `null`
   DIŞINDAYSA modülün EN BAŞINDA `dbgfile "<escaped path>"` yayınlanır
   (`escapeForQbeString`, ZATEN var olan string-literal kaçış yardımcısı,
   YENİDEN kullanıldı) VE `gen.debug_info = true` olur. `genStmts` (TÜM
   deyim kodgen'inin TEK, özyinelemeli dağıtım noktası — T.1'in `checkStmt`
   deseniyle BİREBİR AYNI, if/while/for/try gövdeleri DAHİL otomatik
   kapsanır) HER deyimden ÖNCE `dbgloc <stmt.line>` (T.1'in ZATEN var olan
   `ast.Stmt.line`i, YENİDEN kullanıldı) yayınlar.
2. **`compiler/main.zig`:** `BuildOpts`e `-g` bayrağı (`debug_info: bool`),
   `noxc build`/`run`/`test`in HEPSİ (`buildOne`nin TEK ortak yolundan
   geçtiklerinden) destekler. Varsayılan `false` (M.2'nin "sessiz varsayılan"
   ilkesiyle TUTARLI — opt-in, çıktı boyutu/derleme süresi ETKİLENMEZ).

**Bilinçli v1 sınırlaması 1 — TEK dosya, çoklu-dosya YANLIŞ atıf:** `module_
loader`in TÜM stdlib + kullanıcı kodunu TEK bir düz `ast.Module.body`de
BİRLEŞTİRMESİ (Alt-Faz A) VE `ast.Stmt`in YALNIZCA `.line` taşıyıp HANGİ
KAYNAK DOSYADAN geldiğini İZLEMEMESİ (Faz T.1) YÜZÜNDEN, TEK bir `dbgfile`
(kullanıcının ANA dosyası) TÜM modül İÇİN kullanılır — `nox.strings`/`nox.
json` gibi stdlib fonksiyonlarına ADIM ATILDIĞINDA debugger DOĞRU satır
numarasını AMA YANLIŞ dosya bağlamında gösterir (GERÇEKTEN gözlemlendi, bkz.
aşağıdaki doğrulama — `core.nox`nin İÇ satırları 9/13/34-40/44 kullanıcının
dosyasına ait GİBİ raporlanıyor). KULLANICININ KENDİ kodunda (stdlib'e
girmeden) satır bilgisi HER ZAMAN doğrudur. TAM çözüm HER üst-düzey `func_
def`/`class_def`in KENDİ dosyasını izleyen bir `ast.Stmt.origin_file` alanı
gerektirir (T.1 ÖLÇEĞİNDE AYRI bir faz) — v1 kapsamı DIŞINDA bırakıldı.

**Bilinçli v1 sınırlaması 2 — yalnızca SATIR TABLOSU, DEĞİŞKEN bilgisi YOK:**
QBE'nin IL'i `dbgfile`/`dbgloc` DIŞINDA HİÇBİR debug yönergesi TANIMIYOR —
değişken konum listeleri (`DW_TAG_variable`/`DW_AT_location`), tip bilgisi
VEYA parametre isimleri İÇİN HİÇBİR mekanizma YOK. Bu, gdb'de `break
dosya:satır` + `run` + `continue`in (satır-tabanlı adımlama/kesme noktaları)
TAM ÇALIŞTIĞI ama `print <değişken_adı>`in ÇALIŞMADIĞI ("No symbol ... in
current context") anlamına gelir — GERÇEKTEN test edildi (bkz. aşağı). Bu,
QBE'nin KENDİSİNİN bir SINIRIDIR (Nox'un tasarım kararı DEĞİL) — DEĞİŞKEN
düzeyinde inceleme İSTENİRSE QBE'nin DWARF desteğini GENİŞLETMEK (upstream'e
katkı) YA DA AYRI bir debug-info emisyon katmanı (Nox'un KENDİ `.debug_info`
üretimi, QBE'yi BYPASS ederek) gerekir — v1 kapsamı DIŞINDA.

**Bilinçli v1 sınırlaması 3 — macOS'ta bağlı (linked) ikili DWARF TAŞIMAZ:**
bkz. `codegen_qbe/codegen.zig`nin modül üstü notu (TAM gerekçe orada) —
Apple'ın `ld`si, `clang -g`nin normalde ürettiği Mach-O'ya ÖZGÜ STABS
sembolleri (`N_OSO`/`N_FUN`, "debug map") OLMADAN DWARF'ı bağlı ikiliye
KOPYALAMAZ; QBE'nin çıktısı bu sembolleri İÇERMEZ. **GERÇEKTEN test edildi**
(bu makinede, macOS/aarch64): ara `.o` dosyası (`cc -c prog.s -o prog.o`)
`dwarfdump --debug-line`de DOĞRU bir DWARF5 satır tablosu GÖSTERİYOR (satır
5/6 doğru), AMA bağlı ikilide (`cc prog.o -o prog`) `dwarfdump --debug-line`
BOŞ, `dsymutil prog` "no debug symbols in executable" diyor, `nm -a` HİÇBİR
STABS sembolü GÖSTERMİYOR. Bu, Mach-O'ya ÖZGÜ AYRI bir mühendislik sorunudur
(R.2/R.3'ün "gerçek donanımda doğrulanan Linux, dürüstçe belgelenen macOS
kısıtı" hassasiyetiyle AYNI ruhla) — v1 kapsamı DIŞINDA.

**Doğrulama (üç katman):**
1. **Birim testleri** (`tests/golden/codegen_golden_test.zig`, YENİ İKİ
   test): `debug_source_path = null` → üretilen IR metninde `"dbgfile"`/
   `"dbgloc"` HİÇ GEÇMEZ (opt-in doğrulaması); `debug_source_path =
   "fibonacci.nox"` → `dbgfile "fibonacci.nox"` VE `dbgloc` YAYINLANIR.
   Kasıtlı boz (`genStmts`teki `dbgloc` yayın koşulu GEÇİCİ olarak `if
   (false and ...)`e değiştirildi) → İKİNCİ test GERÇEKTEN kırmızıya döndü
   → geri getirildi.
2. **macOS/aarch64 manuel doğrulama** (bu makine): `noxc build -g -o prog
   prog.nox` sonrası `prog.ssa`/`prog.s` (main.zig BUNLARI temizlemiyor,
   çıktının YANINDA bırakıyor) İÇİNDE `dbgfile "prog.nox"` + kullanıcı
   deyimlerinin (2/3/5/6) DOĞRU satırlarına karşılık gelen `dbgloc`
   satırları GÖZLEMLENDİ; ara `.o`de GERÇEK DWARF (`dwarfdump`) DOĞRULANDI;
   bağlı ikilide macOS sınırlaması (yukarı, sınırlama 3) GÖZLEMLENDİ.
3. **GERÇEK Linux/aarch64 (Docker, `debian:bookworm`, kaynaktan derlenmiş
   QBE 1.3 + sistem `gcc`/`gdb`, R.1-R.3'ün DOĞRULAMA desenİYLE AYNI) —
   `noxc`nin KENDİSİ konteynerde DERLENDİ, `noxc build -g` GERÇEKTEN
   çalıştırıldı:** `readelf --debug-dump=decodedline` bağlı ikilide (HİÇBİR
   ek adım — dsymutil YOK — GEREKMEDEN) DOĞRU satır tablosunu gösterdi;
   **`gdb -batch -ex 'break dbgtest.nox:6' -ex run`** GERÇEK bir kesme
   noktası KOYDU, programı ÇALIŞTIRDI, `Breakpoint 1, main () at
   /tmp/dbgtest.nox:6` İLE DURDU VE kaynak satırını (`6	print(y)`) YAZDIRDI
   — bu, sınırlama 2'nin ("değişken bilgisi YOK") VE sınırlama 1'in ("stdlib
   satırları yanlış dosyaya atfedilir", `readelf` çıktısında `core.nox`nin
   9/13/34-40/44 satırları `dbgtest.nox`a ait GİBİ göründü) SOMUT KANITIDIR
   — Linux'ta SATIR-DÜZEYİ adımlama/kesme noktaları TAM ÇALIŞIR durumdadır.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.18 Faz T.4a — Lexer'a Yorum/Boş-Satır Konumu Yakalama

**Kapsam kararı — kullanıcıyla netleşti (AskUserQuestion):** T.4 ("noxc fmt
gerçek implementasyonu") ikiye bölündü. Gerekçe: mevcut lexer (`compiler/
lexer/lexer.zig`) yorumları (`# ...`) VE boş satırları TAMAMEN ATIYORDU —
token akışında HİÇ yer almıyorlardı (bkz. `tokenize`nin `at_line_start`
bloğu VE `c == '#'` dalı, İKİSİ de sadece satır sonuna kadar atlayıp
DEVAM ediyordu). Gerçek bir formatlayıcı (T.4b) bunları KORUMADAN çalışırsa
`noxc fmt` kullanıcının GERÇEK dosyalarındaki TÜM yorumları SESSİZCE SİLERDİ
— bu, "hata ayıklama bilgisi eksik" (T.3'ün sınırlamaları GİBİ) türünden
ZARARSIZ bir sınırlama DEĞİL, GERÇEK VERİ KAYBI riski taşıyan bir davranış
olurdu. Kullanıcı ÖNCE lexer'a yorum-yakalama eklenmesini (T.4a), formatlayıcının
KENDİSİNİN (T.4b) bunun ÜZERİNE kurulmasını TERCİH ETTİ.

**Uygulama — GERİYE DÖNÜK UYUMLU, ek/opsiyonel (main.zig/parser/checker/
codegen'İN TÜMÜ dahil ~50+ `tokenize` çağrı sitesi HİÇ ETKİLENMEZ):**
1. **`compiler/lexer/token.zig`:** yeni `TriviaKind = enum { comment,
   blank_line }` VE `Trivia = struct { kind, line: u32, text: []const u8 =
   "", trailing: bool = false }` — `text` yalnızca `.comment` İÇİN (`#`
   DAHİL, baştaki girinti HARİÇ — formatlayıcı girintiyi KENDİSİ yeniden
   hesaplayacağından ham metne GEREK YOK), `trailing` bir yorumun AYNI
   satırda KODDAN SONRA mı (`x = 1  # açıklama`) yoksa TEK BAŞINA bir
   satırda mı (`# açıklama`) olduğunu ayırt eder.
2. **`compiler/lexer/lexer.zig`:** `tokenize`in GÖVDESİ `tokenizeImpl(allocator,
   source, trivia_out: ?*std.ArrayList(Trivia))`e taşındı; `pub fn tokenize`
   ARTIK yalnızca `tokenizeImpl(a, s, null)`i çağıran İNCE bir sarmalayıcı
   (davranış/performans BİREBİR AYNI — `trivia_out == null` dallarının HİÇBİRİ
   ÇALIŞMAZ). YENİ `pub fn tokenizeWithTrivia(allocator, source) LexError!
   struct { tokens: []Token, trivia: []Trivia }` AYNI `tokenizeImpl`i BU
   SEFER GERÇEK bir toplayıcıyla çağırır. İki yakalama noktası: (a)
   `at_line_start` bloğunun "boş satır VEYA yalnızca-yorum" dalı (`source[i]
   == '#'` İSE `.comment(trailing=false)`, AKSİ HALDE `.blank_line`), (b)
   normal tarama sırasındaki `c == '#'` dalı (HER ZAMAN `.comment(trailing=
   true)` — bu noktaya ulaşıldıysa satırda ZATEN gerçek bir token/kod
   üretilmiştir, bkz. `line_has_content` bayrağı).

**Bilinçli v1 sınırlaması:** parantez İÇİNDEKİ (`paren_depth > 0`) çok
satırlı ifadelerdeki (ör. çok satırlı bir fonksiyon çağrısı argüman listesi)
boş satırlar YAKALANMAZ — bu durumda `at_line_start` bloğu HİÇ ÇALIŞMAZ
(`if (at_line_start and paren_depth == 0)` koşulu), boş satır sadece normal
boşluk/yeni-satır işlenmesinden GEÇER. Bu, GERÇEKTE NADİR bir desen (çok
satırlı çağrı argümanları ARASINA bilinçli boş satır koymak) olduğundan
T.4b'ye (formatlayıcı bu durumda basitçe "boş satır YOKMUŞ gibi" davranır,
YANLIŞ DEĞİL yalnızca EKSİK bir davranıştır) BIRAKILDI.

**Doğrulama** (`tests/unit/lexer_test.zig`, İKİ YENİ test): (1)
`tokenize()`in KENDİSİNİN yorum/boş-satır İÇEREN VE İÇERMEYEN eşdeğer
kaynaklarda BİREBİR AYNI token türü dizisini ürettiğini (opt-in doğrulaması
— trivia yakalama AÇIK OLMADIĞINDA sıfır davranış değişikliği) kanıtlar; (2)
`tokenizeWithTrivia`in trailing/standalone yorum + boş satırı DOĞRU satır/
metin/bayrakla yakaladığını VE token akışının `tokenize()` İLE AYNI
kaldığını kanıtlar. Kasıtlı boz (trailing-yorum dalındaki `.trailing = true`
GEÇİCİ olarak `false`e değiştirildi) → İKİNCİ test GERÇEKTEN kırmızıya döndü
(`result.trivia[0].trailing` `false` bulundu) → geri getirildi. `zig build
test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

**Not:** T.4b (`noxc fmt`in GERÇEK formatlayıcı gövdesi — girinti/boşluk
normalleştirme + `Trivia`nin en yakın `ast.Stmt.line`e göre YENİDEN
yerleştirilmesi) AYRI bir görev olarak takip edilmektedir.

---

## 3.19 Faz T.4b — `noxc fmt` Gerçek Formatlayıcı Gövdesi

T.4a'nın (bkz. §3.18) yorum/boş-satır yakalama altyapısı üzerine kurulu,
`noxc fmt <dosya.nox>`in GERÇEK implementasyonu — YENİ `compiler/fmt/
formatter.zig` (`ast_dump.zig`nin S-expression yazıcısıyla AYNI TAM AST
gezinme kapsamını, ama GERÇEK Nox söz dizimi üreterek, izler).

**Tasarım — TEK monoton trivia imleci:** `Trivia` (T.4a) kaynak sırasına
göre SIRALI olduğundan VE yazıcı AST'yi TAM OLARAK kaynaktaki gibi (üstten-
alta, iç içe gövdeler KARŞILAŞILDIKLARI ANDA) gezdiğinden, TEK bir ilerleyen
`trivia_idx` YETERLİDİR — `emitLeadingTrivia(upto_line)` VERİLEN satırdan
ÖNCEKİ tüketilmemiş TÜM trivia'yı basar (ardışık boş satırlar TEK satıra
düşürülür); `line()` yardımcısı bir deyimin başlık satırını YAZDIKTAN HEMEN
SONRA AYNI satırdaki bir `trailing` yorumu satırın SONUNA ekler.

**Precedence-farkındalıklı parens:** `compiler/parser/parser.zig`nin
precedence-climbing zincirinin (parseOr→parseAnd→parseNot→parseComparison→
parseAddSub→parseMulDiv→parseUnary→parsePower→parsePostfix) TERSİ bir sayısal
precedence tablosu (`binPrec`/`unaryPrec`) kurulup, HER ikili/tekli ifade
için "ambient" (üst operatörden gelen) bir `(precedence, taraf)` bağlamıyla
karşılaştırılarak SADECE GEREKLİ parens eklenir (gereksiz olanlar—kaynakta
VARSA BİLE—ATILIR, ör. `(a + b) + c` → `a + b + c`) — sağ-birleşimli TEK
operatör (`**`) VE sol-birleşimli TÜM diğerleri (eşit precedence'ta hangi
tarafın "strict" parens gerektirdiği) AYRICA ele alınır. `not (a == b)` →
`not a == b` (parser'ın `parseNot`i operandını `parseComparison`a KADAR
özyinelemeli çözdüğünden semantik olarak AYNI — bkz. testler) gibi
sadeleştirmeler bu YÜZDEN GÜVENLİDİR.

**Diğer kararlar:** float literalleri HER ZAMAN bir ondalık nokta TAŞIYACAK
yazdırılır (`3.0` DEĞİL `3` — aksi halde yeniden lex edilince `int_lit`e
DÖNÜŞÜP AST'nin tip ayrımını BOZARDI); string literalleri HER ZAMAN çift
tırnakla (kaynakta tek tırnak KULLANILMIŞ olsa BİLE) yeniden kaçışlanır;
4 boşluk girinti; satır-uzunluğu SARMA (line wrapping) YOK.

**Zig 0.16 gotcha'sı — karşılıklı özyinelemeli çıkarılmış hata kümeleri:**
`printExprAt`↔`printPrimary` (birbirini ÇAĞIRAN, İKİSİ de `!void` DÖNEN)
`error: dependency loop with length 2` ile derleme hatası verdi — Zig'in
hata kümesi ÇIKARIMI (`!void`) karşılıklı özyineleme İÇİN çözülemez bir
döngü kurar. Düzeltme: TÜM `Printer` metodlarına AÇIK bir `pub const
FormatError = std.Io.Writer.Error || error{NoSpaceLeft};` dönüş tipi
verildi (`ast_dump.zig`nin `std.Io.Writer.Error!void` deseniyle AYNI
prensip, BURADA `std.fmt.bufPrint`in (float biçimlendirme) EK hata kümesi
İÇİN genişletilmiş).

**`noxc fmt` CLI davranışı (`main.zig`nin `cmdFmt`i):** dosyayı YERİNDE
(in-place) yeniden yazar (`gofmt`/`rustfmt`in varsayılanıyla TUTARLI).
**Tip denetimi ÇALIŞTIRILMAZ** — yalnızca lex/parse hatası başarısızlık
sayılır (`gofmt`ın DAVRANIŞIYLA AYNI: sözdizimsel olarak geçerli ama tipçe
HATALI bir program YİNE DE formatlanabilir olmalıdır). `module_loader.
resolveImports` KASITLI olarak ÇAĞRILMAZ — yalnızca KULLANICININ KENDİ
dosyası formatlanır (bkz. modül üstü not, "çok-dosyalı" sınırlaması).

**Doğrulama (üç katman):**
1. **`tests/golden/fmt_golden_test.zig`** — YENİ `tests/golden/fmt_cases/
   kitchen_sink.nox` (sınıf+metod, fonksiyon, if/elif/else, while, for,
   try/except/finally, extern def, import DIŞINDA TÜM deyim türleri +
   standalone/trailing yorumlar + boş satırlar) İÇİN: (a) İKİ KEZ
   formatlamanın AYNI sonucu verdiği (idempotency); (b) formatlanmış
   kaynağın DERLENİP ÇALIŞTIRILDIĞINDA orijinaliyle BİREBİR AYNI stdout'u
   ürettiği (`compileAndRun`, `codegen_golden_test.zig` İLE AYNI desen);
   (c) yorum METİNLERİNİN çıktıda YER ALDIĞI. AYRICA precedence/parens
   mantığını ÇALIŞMA ZAMANI davranışından BAĞIMSIZ, KESİN dizge
   karşılaştırmalarıyla sınayan SEKİZ örnekli bir tablo testi (`(a + b) *
   2` KORUNUR, `(a + b) + c` → `a + b + c` SADELEŞİR, `a - (b - c)` KORUNUR,
   `a ** (b ** c)` → `a ** b ** c` SADELEŞİR, vb.).
2. **`tests/cli/subcommand_test.zig`** (GÜNCELLENDİ) — `fmt/fetch/update:
   henüz uygulanmadı` testi İKİYE BÖLÜNDÜ (`fetch`/`update` HÂLÂ "henüz
   uygulanmadı" der; YENİ bir test `noxc fmt`in dosyayı GERÇEKTEN yerinde
   yeniden yazdığını VE İKİNCİ formatlamanın dosyayı DEĞİŞTİRMEDİĞİNİ, bir
   ALT SÜREÇ olarak GERÇEKTEN kurulu `noxc`yi çalıştırarak kanıtlar).
3. **Manuel doğrulama (bu makine):** `noxc fmt` GERÇEKTEN çalıştırılıp
   çıktı GÖZLE incelendi — yorumlar/boş satırlar KORUNDU, `(a + b) * 2`
   parens'i KORUNDU, `not (a == b)` → `not a == b` (SEMANTİK AÇIDAN
   DOĞRULANMIŞ) sadeleşti; İKİNCİ bir `noxc fmt` çalıştırması dosyayı
   BAYT-BAYT DEĞİŞTİRMEDİ (idempotency); formatlanmış ikilinin ÇALIŞTIRILAN
   ÇIKTISI orijinaliyle BİREBİR AYNIYDI.

**Kasıtlı boz→kırmızı→düzelt ritüeli — İKİ AYRI bulgu:**
- **İlk deneme YETERSİZDİ:** `printExprAt`in binary dalındaki `need_parens`i
  KOŞULSUZ `false`e sabitleyip (parens mantığını TAMAMEN devre dışı bırakıp)
  `zig build test`i çalıştırdığımda TÜM testler YEŞİL KALDI — `kitchen_
  sink.nox`nin `y: int = (a + b) * 2` DEĞİŞKENİNİN aslında HİÇBİR ÇALIŞMA
  YOLUNDA GÖZLEMLENMEDİĞİ (fonksiyonun `if z:` dalı HER ZAMAN `x`i
  döndürüyordu, `y` HİÇ kullanılmıyordu) ortaya çıktı — T.1/T.2'nin AYNI
  dersini (bir testin GERÇEKTEN iddia ettiği şeyi sınadığını KANITLAMADAN
  güvenilmemesi) BURADA da doğruladı. **Düzeltme:** parens mantığını
  ÇALIŞMA ZAMANI davranışından TAMAMEN BAĞIMSIZ, KESİN dizge
  karşılaştırmalı SEKİZ örnekli bir tablo testi eklendi.
- **İkinci deneme (düzeltmeyle) BAŞARILI:** AYNI boz (`need_parens = false`)
  bu KEZ YENİ tablo testini GERÇEKTEN kırmızıya döndürdü (`y: int = (a + b)
  * 2` beklenirken `y: int = a + b * 2` bulundu) → geri getirildi, YEŞİLE
  döndüğü doğrulandı.
- AYRICA, implementasyon SIRASINDA `tests/cli/subcommand_test.zig`nin
  ÖNCEDEN VAR OLAN bir testinin (`fmt`in "henüz uygulanmadı" dediğini
  varsayan) ARTIK YANLIŞ olduğu KEŞFEDİLDİ (T.4b'nin KENDİSİNİN, bir
  regresyonun DEĞİL, DOĞAL bir sonucu) — GÜNCELLENDİ (yukarı bkz.).

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.20 Faz U.1 — `list[T].append()` / Dinamik Büyüme + İndeksli Atama

**Kapsam kararı — kullanıcıyla netleşti (AskUserQuestion):** `list[T]` ÖNCEDEN
sabit boyutlu, TEK seferlik bir ARC bloğuydu (`{len: i64 @0, elemanlar @8...}`
— kapasite kavramı YOKTU, uzunluk=kapasite HER ZAMAN). `.append()` eklemenin
ÜÇ olası yolu (her append'te yeniden ayır/kopyala; `list[T]`i `dict[K,V]`
İLE AYNI opak-Zig-destekli TEK-sahiplilik modeline TAŞI; GERÇEK bir kapasite
alanı ekleyip yeterli KAPASİTEDE YERİNDE büyüme yap) GERÇEK bir DİL-SEMANTİĞİ
farkı yaratıyordu (`ys = xs; xs.append(v)` — `ys` bunu GÖRMELİ Mİ?), YALNIZCA
bir implementasyon detayı DEĞİL — kullanıcı **GERÇEK paylaşım** (kapasite
alanı) seçeneğini SEÇTİ: Python listeleri gibi, kapasite YETERLİYSE `.append()`
YERİNDE yazar (TÜM alias'lar GÖRÜR), kapasite DOLUNCA YENİ bir blok ayrılır.

**Yeni başlık düzeni — `{len: i64 @0, cap: i64 @8, elemanlar @16...}`:**
(`compiler/codegen_qbe/codegen.zig`'in YENİ `LIST_HEADER_SIZE = 16` sabiti).
Bu, `list[T]`in kodgen'de DOKUNDUĞU HER YERİ (91 grep isabeti taranarak
BULUNDU) etkileyen GENİŞ bir değişiklikti:
1. `genListLit` — literal-inşa edilen bir liste HER ZAMAN tam-oturan başlar
   (`cap = len`, büyüme SLACK'i YOK — yalnızca `.append()` GEREKTİĞİNDE
   büyütür).
2. `genIndex`in list dalı (okuma) VE YENİ `genListAssign` (yazma,
   `xs[i] = v`) — eleman OFSETİ `8`→`16`e KAYDI, sınır kontrolü (Faz S.2'nin
   AYNI err/ok-etiket deseni) `len`e (DEĞİŞMEDEN) BAKAR.
3. `listPayloadSize` — GERÇEK tahsis edilmiş boyut ARTIK `cap`e (`@8`)
   karşılık gelir, `len`e (`@0`) DEĞİL — bu AYRIM KRİTİK: `.append()`in
   büyüttüğü bir liste, `len` ile serbest bırakılırsa havuzun serbest-liste
   sınıf indeksini BOZAR (bkz. `arc.zig`'in `nox_rc_free_payload` notu).
4. `genListElemRelease` (üretilen `$List_<...>_release`) — element DÖNGÜSÜ
   `len`e (yalnızca GEÇERLİ elemanlar release edilir) BAKMAYA DEVAM eder,
   AMA belleği serbest bırakırken `cap` KULLANILIR (İKİ dalda da — nested VE
   primitive-eleman durumları).
5. `genListEq`/`genForList`/`genPrintList` — yalnızca eleman OFSET kaymasını
   (`8`→`16`) gerektirdi (`len` HER ZAMAN doğru döngü SINIRIYDI).
6. **Zig-taraflı EL İLE list-inşa eden İKİ site** (`runtime/stdlib_shims/
   json.zig`nin `buildPtrList`ı VE `runtime/stdlib_shims/strings.zig`nin
   `nox_strings_split_raw`ı, ikisi de Alt-Faz L/H'den beri `genListLit`in
   bayt düzenini EL İLE TAKLİT EDİYORDU) — İKİSİ de YENİ düzene (16 baytlık
   başlık, `cap = len`) GÜNCELLENDİ; AKSİ HALDE `nox.json`/`nox.strings.split`
   ÇIKTILARI genListElemRelease/genIndex İLE UYUMSUZ (bozuk) olurdu. AYNI
   nedenle `tests/compat/zig_ext/util.zig`nin (Alt-Faz F'nin `list[str]`
   dönüşü test fixture'ı) `nox_test_make_list`ı da GÜNCELLENDİ.

**YENİ `nox_list_grow` (runtime/alloc/arc.zig):** `.append()`in büyüme
yolunun TEK çalışma zamanı primitifi — YENİ (2× kapasiteli, `cap==0` İSE
`1`) bir blok ayırıp ESKİ içeriği (`@memcpy`) KOPYALAR, YENİ işaretçiyi
döner. `old_ptr`e HİÇ DOKUNMAZ (ne serbest bırakır ne refcount DEĞİŞTİRİR) —
ÇAĞIRAN (`genListAppend`) sorumludur (bkz. aşağı).

**`checker.zig`:**
1. `checkAssign`'ın `.index` kolu `list`i (dict'in YANINDA) TANIR —
   `xs[i] = v` (int indeks + eleman-tipi ATANABİLİRLİK kontrolü).
2. `checkCall`'ın `.attribute` dispatch'i `list.append(v)`i (Channel/dict'in
   AYNI "yerleşik, kullanıcı sınıfı DEĞİL" deseninde) tanır — **bilinçli v1
   kısıtı:** alıcı (`a.obj.*`) SADECE çıplak bir isim OLABİLİR (`spawn`in
   çağrı-hedefi kısıtıyla AYNI gerekçe) — `getList().append(v)`/`obj.field.
   append(v)` REDDEDİLİR (`TypeMismatch`), çünkü codegen'in BÜYÜME durumunda
   ALICININ KENDİ SLOTUNA geri yazması GEREKİR — bu yalnızca bir DEĞİŞKENİN
   slotu İÇİN anlamlıdır.

**`codegen.zig` — `genListAssign`/`genListAppend`:**
- `genListAssign` (`xs[i] = v`): `genIndex`in AYNI bounds-check'i + `genAssign`in
  `.attribute` kolundaki AYNI "ÖNCE eskiyi oku, YENİ değeri yaz, SONRA
  eskiyi serbest bırak" sırası (heap-yönetimli elemanlar İÇİN).
- `genListAppend` (`xs.append(v)`): İKİ yol, phi'SİZ (bu projenin TÜM merge
  noktalarında kullandığı `alloc8`+`store`/`load` deseniyle):
  - **Hızlı yol** (`len < cap`): YENİ eleman `obj.text`in KENDİ bloğuna
    YERİNDE yazılır, `len` ARTIRILIR — blok ADRESİ HİÇ DEĞİŞMEZ, HERHANGİ
    bir alias (`ys = xs`) bunu ANINDA GÖRÜR.
  - **Büyüme yolu** (`len == cap`): `nox_list_grow` YENİ bir blok ayırıp
    ESKİ içeriği kopyalar; YENİ eleman ORAYA yazılır; ESKİ blok (elemanları
    TAŞINDIĞINDAN — AYNI işaretçi DEĞERLERİ, refcount DEĞİŞMEDEN —
    özyinelemeli release EDİLMEDEN, yalnızca KENDİ ham belleği)
    `nox_rc_predecrement`+`nox_rc_free_payload` ile serbest bırakılır; YENİ
    işaretçi ALICININ KENDİ SLOTUNA (`var_info.slot`) geri yazılır.

**Bilinçli v1 sınırlamaları (KABUL EDİLDİ):**
1. **Büyüme ANINDA VAR OLAN bir alias YENİ elemanı GÖRMEZ:** `ys = xs`
   OLUŞTURULDUKTAN SONRA `xs.append(v)` bir BÜYÜME tetiklerse, `ys` ESKİ
   (artık daha KISA) bloğu GÖRMEYE devam eder — `xs`in KENDİ slotu
   güncellenir ama `ys`in DEĞİL. Bu, Nox'un işaretçi-DEĞERİ-tutan, TEK
   dolaylama SEVİYELİ ARC temsilinin DOĞAL bir sonucudur — TAM düzeltme bir
   "handle" (ÇİFT dolaylama) yeniden tasarımı gerektirir, v1 kapsamı
   DIŞINDA. **GÜVENLİK NOTU (GERÇEKTEN doğrulandı):** bu durum SESSİZCE
   YANLIŞ veri OKUMAZ/belleği BOZMAZ — `ys` KENDİ (kısa) `len`iyle bağlı
   kaldığından, `ys[len(eski)]` gibi bir erişim TEMİZ bir `IndexError`
   fırlatır (bkz. doğrulama, "İlk deneme").
2. **Alıcı BİR PARAMETRE OLAMAZ:** bir parametre ÖDÜNÇ alınmıştır (refcount'u
   ETKİLENMEDEN geçirilir) — büyüme yolu ESKİ bloğu predecrement/free
   ETTİĞİNDEN, bu ÇAĞIRANIN hâlâ geçerli saydığı belleği BOZARDI. Checker
   parametre/yerel ayrımını TİP DÜZEYİNDE yapmadığından, bu kısıt CODEGEN
   SEVİYESİNDE (`var_info.is_param` İSE `error.Unsupported`) uygulanır
   (`checkNoLowlevelEscape`in "geniş kural, codegen seviyesinde uygulanır"
   ÖNCEDEN kabul edilmiş desenle AYNI).
3. **Arena listeleri büyütülemez** — `.append()` `obj.arena` İSE
   `error.Unsupported` döner (arena semantiği toplu-yıkım varsayar,
   `nox_rc_alloc`/`nox_rc_free_payload` tabanlı büyüme yoluyla UYUŞMAZ).
4. **Boş liste literali (`xs: list[int] = []`) HÂLÂ desteklenmiyor** — bu,
   U.1'in KAPSAMI DIŞINDA bırakıldı (dict'İN KENDİSİ de `{}`yi
   desteklemiyor, "dict ZATEN destekliyor — TUTARLILIK" gerekçesi BURAYA
   UYGULANMAZ) — `.append()` KULLANMAK İÇİN liste EN AZ bir eleman ile
   BAŞLATILMALIDIR.

**Doğrulama (üç katman):**
1. **Manuel uçtan-uca (bu makine, `noxc build`):** 4 elemanlı bir listeye 5
   kez `.append()` (3 büyüme sınırını AŞARAK) → TÜM 8 eleman DOĞRU
   sırada; indeksli atama (`xs[0] = 100`) → DOĞRU okuma; **paylaşım
   testi** — `ys = xs` (kapasitede SLACK VARKEN) → `xs.append(v)` (hızlı
   yol) → `ys` YENİ elemanı DOĞRU gördü; **sınır testi** — `ys = xs`
   (SLACK YOKKEN, İLK deneme) → `xs.append(v)` (BÜYÜME) → `ys[len]`
   TEMİZ bir `IndexError` fırlattı (ÇÖKME/BOZULMA DEĞİL); `list[str]`
   (heap-yönetimli elemanlar) İLE 4 `.append()` → sızıntı YOK (stderr
   boş, DebugAllocator'ın leak-check'i TEMİZ); sınır dışı indeksli atama
   (`xs[10] = 5`) → TEMİZ `IndexError`.
2. **Golden testler** (`tests/golden/codegen_cases/`, 3 YENİ dosya) —
   `list_append_grows_and_shares.nox` (büyüme + paylaşım, YUKARIDAKİ
   manuel senaryonun AYNISI), `list_append_str_elements.nox` (heap-
   yönetimli elemanlarla büyüme, sızıntı YOK), `list_index_assign_basic.nox`
   (indeksli atama + sınır dışı `IndexError`); `tests/golden/typecheck_cases/
   err_list_append_non_identifier_receiver.nox` (alıcı kısıtının ÇALIŞTIĞINI
   kanıtlar).
3. **Kasıtlı boz→kırmızı→düzelt (paylaşım özelliği):** `genListAppend`nin
   `has_room` karşılaştırması (`csltl` → `csgtl`, hızlı yolun ASLA
   tetiklenmemesini SAĞLAYARAK) GEÇİCİ olarak BOZULDU → `list_append_grows_
   and_shares` testi GERÇEKTEN kırmızıya döndü (`ys`in DAHA ÖNCE GÖRDÜĞÜ bir
   elemente artık eriş(ilem)iyordu, "yakalanmamış istisna") → geri
   getirildi, YEŞİLE döndüğü doğrulandı.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.21 Faz U.2 — Proje-İçi Çoklu-Dosya Birinci-Taraf Import

**Problem:** Faz A'nın (bkz. §3.6) `import` mekanizması yalnızca İKİ kökü
tanıyordu — `nox.*` (stdlib, KOŞULSUZ) ve Faz O'nun (`P.6`) `requires[]`
alias'ları (ÜÇÜNCÜ-TARAF, `nox.json`'a KAYITLI GitHub bağımlılıkları).
Kullanıcının KENDİ projesi İÇİNDE, TEK dosyayı (`main.nox`) AŞAN, birden çok
`.nox` dosyasının BİRBİRİNİ import edebilmesi (`import helpers` gibi, hiçbir
`requires[]` kaydı OLMADAN) DESTEKLENMİYORDU — Faz O'nun planı bunu AÇIKÇA
"kendi başına AYRI bir takip fazı" olarak İŞARETLEMİŞTİ (bkz. plan dosyası,
"Açık Sorular / Bilinçli Kapsam Dışı").

**Tasarım — ÜÇÜNCÜ bir çözümleme katmanı, ÖNCELİK SIRASIYLA:**
1. İlk segment `"nox"` → stdlib (HER ZAMAN, KOŞULSUZ — DEĞİŞMEDİ).
2. `alias_roots` (nox.json'ın `requires[]`i) EŞLEŞMESİ → üçüncü-taraf
   (DEĞİŞMEDİ — "açık ÖRTÜKTEN ÜSTÜNDÜR" felsefesiyle alias eşleşmesi HER
   ZAMAN ÖNCE denenir).
3. **YENİ:** alias eşleşmezse VE `project_root` VERİLMİŞSE (`nox.json`'ın
   VARLIĞIYLA, `project.findProjectRoot` İLE AYNI mekanizmayla keşfedilir)
   → `<project_root>/{noktalı-yol-segmentleri-birleştirilmiş}.nox` YOLU
   `fileExistsAbsolute` (YENİ, `std.Io.Dir.accessAbsolute` sarmalayıcısı)
   İLE PROBE edilir; VARSA bu dosya kullanılır.
4. HİÇBİRİ eşleşmezse `error.UnknownImportAlias` (DEĞİŞMEDEN — hem "bilinmeyen
   alias" hem "proje-içi dosya YOK" durumunu KAPSAYACAK ŞEKİLDE main.zig'in
   hata mesajı GENİŞLETİLDİ, bkz. aşağı).

**KRİTİK kısıt — birinci-taraf importlar `nox.json` GEREKTİRİR:** yeni
`project_root` katmanı YALNIZCA `resolveProjectImports`e (Faz O'nun `nox.json`
BULUNDUĞUNDA çağrılan yola) EKLENDİ — `resolveImports`/`resolveImportsFrom`
(dört ayrı çağrı sitesinden DOĞRUDAN kullanılan, DEĞİŞTİRİLEMEZ İKİ "donmuş"
sarmalayıcı) HER ZAMAN `project_root = null` geçirir, bu YÜZDEN YENİ dal
KISA-DEVRE olur. Yani `nox.json`sız (manifestsiz) TEK-dosya kullanım ESKİ
("yalnızca stdlib") davranışını AYNEN korur — Go'nun `go.mod`u/Cargo'nun
`Cargo.toml`ı İLE AYNI "çok-dosyalı modül yapısı bir manifest GEREKTİRİR"
öncülüyle TUTARLI.

**Neden HİÇBİR checker/codegen değişikliği GEREKMEDİ (araştırmayla
doğrulandı):** mangling şeması ZATEN TAMAMEN genelleştirilmişti
(`mangleWith(a, segments, name) = join(segments, "_") + "_" + name`) VE
`checker.zig`'in `tryResolveQualifiedCall`ı ZATEN `imp.segments` üzerinden
TAMAMEN GENERIC (SIFIR `"nox"`-özel hardcode). Yani `import helpers` →
`helpers.my_func(...)` çağrıları → `helpers_my_func` mangled ismine
çözümleme, ÜÇÜNCÜ-TARAF paket importlarının (Faz O) checker'da SIFIR
değişiklik gerektirmesiyle BİREBİR AYNI mekanizmayı MİRAS aldı.

**Uygulama (`compiler/module_loader.zig`):**
1. `resolveProjectImports` YENİ bir `project_root: ?[]const u8` parametresi
   ALDI (son parametre — mevcut 5 pozisyonel argümanla çağrılan HİÇBİR
   çağrı sitesi yoktu, tek çağıran `main.zig`'in `resolveImportsForBuild`ı
   idi, bu yüzden imza değişikliği GÜVENLİYDİ).
2. `resolveImportsImpl`/`loadImportsRecursive` ZİNCİRİ boyunca AYNI parametre
   İLERİ TAŞINDI (`resolveImports`/`resolveImportsFrom`in çağrıları `null`
   geçirir — DEĞİŞMEZLİK GARANTİSİ).
3. YENİ `fileExistsAbsolute(io, path) bool` yardımcısı — `project.zig`'in
   ÖNBELLEK-dizini-yeniden-kullanımı için ZATEN kullandığı `std.Io.Dir.
   accessAbsolute` deseniyle AYNI.
4. `loadImportsRecursive`'in path-çözümleme `blk:` ifadesi YUKARIDAKİ
   3 adımlı ÖNCELİK sırasını uygular; ÖZYİNELEMELİ self-çağrı (yüklenen
   bir stdlib/proje modülünün KENDİ transitif importları İÇİN) `project_root`u
   DOĞRU şekilde İLERİ TAŞIR (bir stdlib modülünün BAŞKA bir stdlib modülünü
   import etmesi GİBİ, bir proje-içi modülün BAŞKA bir proje-içi modülü
   import etmesi de DOĞAL olarak ÇALIŞIR — ÖZEL bir kod yolu GEREKMEDİ).

**`compiler/main.zig`:** `resolveImportsForBuild`in `resolveProjectImports`
çağrısına, fonksiyonun BAŞINDA `project.findProjectRoot` İLE ZATEN çözülmüş
`root` (proje kökünün MUTLAK yolu) altıncı argüman olarak EKLENDİ.
`error.UnknownImportAlias` durumundaki Türkçe mesaj GENİŞLETİLDİ ("bilinmeyen
alias" → "bilinmeyen alias VEYA proje-içi dosya bulunamadı", HEM `requires[]`
listesine HEM `<root>` altında ilgili `.nox` dosyasının VARLIĞINA bakılmasını
ÖNERİR) — çünkü bu hata KODU artık İKİ FARKLI kök nedeni KAPSIYOR.

**Doğrulama:**
1. **Manuel uçtan-uca** (`/tmp` altında geçici bir proje, `noxc build`):
   `nox.json` + `helpers.nox` (doğrudan) + `utils/mathy.nox` (İÇ İÇE yol) +
   bunları import eden `main.nox` → DOĞRU derlendi/çalıştı (`10`/`15` çıktı,
   sonra `helpers.double(5)=10`/`utils.mathy.triple(5)=15` senaryosu);
   var olmayan bir modülün importu → AÇIK hata mesajıyla çıkış kodu 1.
2. **Golden testler** (YENİ `tests/cli/local_import_test.zig`, `package_
   resolution_test.zig`İLE AYNI izole-`$NOX_HOME`+subprocess deseni): (a)
   doğrudan proje-içi import, (b) İÇ İÇE yol (`import utils.mathy`), (c)
   GERÇEKTEN var olmayan proje-içi modül → açık hata + çıkış kodu 1, (d)
   `nox.json` OLMADAN (manifestsiz) proje-içi import → ESKİ "stdlib modülü
   bulunamadı" davranışı KORUNDU (regresyon-koruma, YENİ katmanın DEVREYE
   GİRMEDİĞİNİ kanıtlar).
3. **Kasıtlı boz→kırmızı→düzelt:** `loadImportsRecursive`'in `project_root`
   fallback dalı GEÇİCİ olarak devre dışı bırakıldı (yalnızca `error.
   UnknownImportAlias`e düşecek şekilde) → (a) ve (b) testleri GERÇEKTEN
   kırmızıya döndü (build başarısız, "bilinmeyen alias..." hatası), (c) ve
   (d) testleri (bu katmana BAĞIMLI OLMADIKLARI İÇİN) YEŞİL kaldı — bu,
   testlerin GERÇEKTEN iddia ettikleri özelliği EGZERSİZ ettiğini kanıtlar
   (bkz. T.4b'nin `y` değişkeni dersinin AYNI disiplinle TEKRARI). Geri
   getirildi, tüm 4 test YEŞİLE döndü.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.22 Faz U.3 — `import X as Y` / `from X import Y [as Z]`

**Kapsam:** iki YENİ, birbirinden BAĞIMSIZ sözdizimi — (1) `import nox.http as h`
(Python'un `import a.b as x`iyle AYNI semantik: `h`, TAM `nox.http` yoluna
bağlanır, `h.get(...)` `nox.http.get(...)` İLE EŞDEĞERDİR); (2)
`from nox.http import get[as g]` (Python'un `from a.b import c`sinin BASİT
alt kümesi: TEK ya da virgülle ayrılmış BİRDEN ÇOK üye, HER biri isteğe
bağlı KENDİ `as` sonekiyle, MODÜL niteliği OLMADAN doğrudan çağrılabilir bir
yerel isme bağlanır). `import X.Y.Z` (alias'sız, Faz A) DEĞİŞMEDEN çalışmaya
devam eder — bu ikisi ONUN GENİŞLEMESİDİR, YERİNE geçmez.

**Neden yeni bir AST düğüm TÜRÜ (kısmen) gerekti:** `ImportStmt`e (Faz A'dan
beri var olan) yalnızca isteğe bağlı bir `alias: ?[]const u8` alanı EKLENDİ
(geriye dönük uyumlu, varsayılan `null`). `from ... import` İÇİN ise YENİ,
AYRI bir `FromImportStmt`/`FromImportName` çifti EKLENDİ (`StmtKind`e YENİ
bir `from_import_stmt` üyesi) — `import`tan YAPISAL olarak farklı olduğu
İÇİN (birden çok üye, HER biri KENDİ isteğe bağlı alias'ı) AYRI bir tip
DAHA AÇIK VE DAHA AZ HATAYA AÇIK.

**Lexer/Parser:** `as`/`from` anahtar kelimeleri ZATEN MEVCUTTU (`except X
as e` VE `extern def ... from "lib"` İÇİN) — hiçbir YENİ token GEREKMEDİ.
`parseStmt`in dispatch tablosuna `.kw_from => try self.parseFromImport()`
EKLENDİ; `kw_from` bir DEYİMİN İLK tokenı olarak YALNIZCA `from X import Y`
anlamına GELEBİLİR (extern def'in `from`u `kw_extern`DEN SONRA, deyim
ORTASINDA görülür — hiçbir ÇAKIŞMA riski YOK). `parseImport` `as <isim>`
soneki İÇİN `self.match(.kw_as)` DENER (isteğe bağlı); YENİ `parseFromImport`
segment listesini AYNI `import`ınkiyle (nokta-ayrılmış tanımlayıcı zinciri)
ayrıştırır, SONRA virgülle ayrılmış `isim[as takma_ad]` listesini toplar.

**Checker — İKİ YENİ alan + İKİ YENİ yardımcı fonksiyon:**
1. `module_aliases: StringHashMapUnmanaged([]const []const u8)` — takma ad
   (`"h"`) → TAM modül yolu segmentleri (`["nox","http"]`). `checkModule`in
   `.import_stmt` kolu, `imp.alias` VERİLMİŞSE bunu KAYDEDER (`imported_
   modules`e TAM yolun KENDİSİ HER ZAMAN, alias'tan BAĞIMSIZ olarak KAYDEDİLİR
   — böylece `module_path` eşleşmesi DEĞİŞMEDEN çalışır).
2. `from_imports: StringHashMapUnmanaged([]const u8)` — yerel ÇIPLAK isim
   (`alias orelse name`) → mangled TAM sembol adı (`"nox_http_get"`).
   `checkModule`in YENİ `.from_import_stmt` kolu HER üye İÇİN BUNU doldurur.
3. YENİ `substituteAlias(segments)`: düzleştirilmiş bir noktalı zincirin
   (`flattenDottedPath`in çıktısı) İLK elemanı BİLİNEN bir alias İSE, onu
   HEDEF segmentlerle DEĞİŞTİRİR (`["h","get"]` → `["nox","http","get"]`) —
   EŞLEŞMEZSE segmentler DEĞİŞMEDEN döner (kopyasız, sıfır ek maliyet).
   `tryResolveQualifiedCall` VE `tryResolveHttpServeCall` (D.1.6'nın ÖZEL
   `nox.http.serve` yerleşiği) İKİSİ de flattenDottedPath'TEN HEMEN SONRA
   BUNU çağırır — yani `import nox.http as h` sonrası `h.serve(...)` de
   `h.get(...)` KADAR DOĞRU çalışır (Faz D.1.6'nın özel yerleşiği alias-
   FARKINDA hale GELDİ, kapsam dışı bırakılmadı).
4. YENİ `resolveMangledCall(ctx, c, mangled, not_found_msg)`: `tryResolve
   QualifiedCall`in "mangled sembolü BULUNDUKTAN SONRAKİ" ORTAK gövdesi
   (fonksiyon/kurucu ara, argüman denetimi, callee'yi YERİNDE mangled isme
   yeniden yaz) — hem noktalı nitelikli çağrılar (`X.Y.foo(...)`) HEM `from
   X import foo` İLE bağlanan ÇIPLAK çağrılar (`foo(...)`) TARAFINDAN
   PAYLAŞILIR (kod tekrarını ÖNLER, tek bir doğruluk kaynağı).
5. `checkCall`in `.identifier` dalı: `self.from_imports.get(name)` kontrolü,
   NORMAL çözümlemenin (generic/local fonksiyon/sınıf) HEPSİ BAŞARISIZ
   olduktan SONRA, "tanımsız fonksiyon" hatasından HEMEN ÖNCE denenir —
   **bilinçli ÖNCELİK kararı:** yerel bir tanım `from`la içe aktarılan bir
   isimle ÇAKIŞIRSA yerel tanım HER ZAMAN KAZANIR (Python'un çalışma-zamanı
   gölgeleme davranışına BENZER bir statik yaklaşım — "son tanım kazanır"
   YERİNE "yerel HER ZAMAN kazanır", çünkü Nox'un tek-geçişli/statik checker'ı
   çalışma SIRASINA göre karar VEREMEZ).

**`module_loader.zig`:** dosya çözümleme döngüsü (`loadImportsRecursive`)
ARTIK hem `.import_stmt` HEM `.from_import_stmt`i tanır — İKİSİ de AYNI
`segments` alanına (modül DOSYA yolu) sahip OLDUĞUNDAN, döngünün BAŞINDA
`const segments = switch (stmt.kind) { .import_stmt => |i| i.segments,
.from_import_stmt => |f| f.segments, else => continue };` İLE TEK bir kod
yoluna İNDİRGENDİ — dosya ARAMA/mangling/özyineleme mantığının GERİ KALANI
(alias_roots/project_root ÜÇ katmanlı önceliği, Faz U.2) HİÇ DEĞİŞMEDİ.
`renameStmt`e `.from_import_stmt => return s,` EKLENDİ (`.import_stmt` İLE
AYNI gerekçe — `segments` bir DOSYA yoludur, Nox bildirim adı DEĞİLDİR,
`names`teki ÜYE adları YEREL takma adlardır, YENİDEN ADLANDIRMAYA gerek
YOK).

**Diğer exhaustive switch siteleri (derleyici HATASI OLARAK bulundu, TEK
TEK düzeltildi):** `codegen.zig` (4 site — `stmtUsesAsync`/`genStmts`/
`collectRaiseInfoStmts`/`splitLooseStmts`, HEPSİ `.import_stmt`İLE AYNI
"codegen'de HİÇBİR karşılığı YOK" muamelesi), `ownership/analysis.zig`
(1 site, AYNI gerekçe), `ast_dump.zig` (YENİ bir `(from-import ...)`
biçimi EKLENDİ, salt debug amaçlı), `fmt/formatter.zig` (`import X as Y`/
`from X import Y[as Z]` KENDİ sözdizimiyle YENİDEN yazılır — İDEMPOTENT).

**Doğrulama:**
1. **Manuel uçtan-uca** (`/tmp` altında geçici bir proje, `noxc build`):
   `import helpers as h` + `from helpers import triple` + `from helpers
   import double as dbl` → HEPSİ doğru sonuç verdi; GERÇEK bir stdlib
   modülüyle (`import nox.strings as s` + `from nox.strings import upper`)
   AYNI test TEKRARLANDI (`s.upper("hi")` → `"HI"`, `upper("hey")` →
   `"HEY"`); `from helpers import nonexistent_func` → AÇIK bir hata mesajı
   (`'nonexistent_func' içe aktarılamadı...`), çıkış kodu 1.
2. **Golden testler** (`tests/golden/codegen_cases/`, `stdlib/nox/testmod.nox`
   fixture'ı — Faz A'dan beri VAR OLAN, `import_basic.nox`nin KULLANDIĞI
   AYNI — YENİDEN kullanıldı): `import_as_alias.nox` (takma ad üzerinden
   nitelikli çağrı + kurucu), `from_import_basic.nox` (çıplak çağrı, hem
   alias'sız hem `as`'lı üye), `from_import_shadowed_by_local.nox`
   (**EN KRİTİK test** — kullanıcı `from nox.testmod import double` YAPAR
   AMA KENDİ `double`ını da TANIMLAR; kullanıcının YEREL `double`ı (x+1)
   KAZANMALI, `nox.testmod.double`u (x*2) DEĞİL — bkz. aşağıdaki boz→kırmızı
   ritüeli). `tests/golden/typecheck_cases/err_from_import_unknown_member.nox`
   (kaynak modülde GERÇEKTEN OLMAYAN bir üyeyi `from` İLE içe aktarmaya
   ÇALIŞMAK AÇIK bir `UndefinedFunction` hatası verir).
3. **Kasıtlı boz→kırmızı→düzelt (gölgeleme ÖNCELİĞİ):** `checkCall`in
   `.identifier` dalında `self.from_imports` kontrolü GEÇİCİ olarak
   `self.functions`/`self.classes` kontrolünden ÖNCEYE TAŞINDI (yani
   from-import HER ZAMAN yerel tanımdan ÖNCE denenecek şekilde BOZULDU) →
   `from_import_shadowed_by_local` testi GERÇEKTEN kırmızıya döndü (`11`
   BEKLENİRKEN `20` — `nox.testmod.double` YANLIŞLIKLA KAZANDI), DİĞER 78
   test (bu değişiklikten ETKİLENMEYEN senaryolar) YEŞİL KALDI — bu, testin
   İDDİA ETTİĞİ ÖZELLİĞİ (yerel tanımın ÖNCELİĞİ) GERÇEKTEN egzersiz
   ettiğini kanıtlar. Geri getirildi, TÜM testler (79/79) YEŞİLE döndü.

**Bilinçli v1 sınırlaması:** `from nox.http import serve` (D.1.6'nın ÖZEL
`nox.http.serve` yerleşiği, ÇIPLAK bir `handle` fonksiyon ADI BEKLER) BU
FAZDA `from`-import ÇIPLAK çağrı yoluna ÖZEL olarak BAĞLANMADI — `serve`
`from`la içe aktarılıp ÇIPLAK çağrılırsa NORMAL `resolveMangledCall` yoluna
düşer (`nox_http_serve`yi SIRADAN bir fonksiyon gibi arar, argümanları
`checkArgs`/`checkExpr` İLE dener) — bu `handle`in bir DEĞİŞKEN olarak
`checkExpr`E gönderilmesine, "tanımsız değişken" gibi bir hataya yol AÇAR
(GÜVENLİ bir BAŞARISIZLIK, SESSİZ yanlış davranış DEĞİL). `import nox.http
as h` + `h.serve(...)` İSE (alias, `from` DEĞİL) TAM DESTEKLENİR (bkz.
YUKARIDAKİ `tryResolveHttpServeCall`in alias-farkındalığı) — pratikte
kullanıcılar `serve`i `from`la DEĞİL, ya `nox.http.serve` ya `h.serve`
şeklinde çağıracağından bu KÜÇÜK, KENARDA bir kısıttır, gelecekte `from`
İÇİN de D.1.6 benzeri özel bir dal EKLENEBİLİR.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.23 Faz U.4 — Planlama: Birinci-Sınıf Fonksiyon Değerleri / Closure

**Kullanıcıyla netleşen kapsam (AskUserQuestion):** yalnızca çıplak fonksiyon
referansları DEĞİL, **TAM closure** (dış kapsamdaki değişkenleri YAKALAMA) —
bu, D.1'in `nox.http` planlaması KADAR büyük bir mühendislik yüzeyi
GEREKTİRİYOR, bu YÜZDEN D.1 İLE AYNI disiplinle ÖNCE bu planlama bölümü
yazıldı, SONRA sıralı, KENDİ doğrulamasıyla biten alt-fazlara (U.4.1-U.4.4)
bölündü.

**Sözdizimi kararı — lambda YOK, yalnızca iç içe `def`:** Python'ın nested-
function closure deseniyle AYNI (`def outer(): def inner(): ...; return
inner`). Ayrı bir `lambda` ifade sözdizimi v1 kapsamı DIŞI (basitlik İÇİN
ERTELENDİ, gelecekte AYRI bir faz İLE eklenebilir).

**Yakalama semantiği kararı (BİLİNÇLİ v1 sınırlaması):** yakalanan
değişkenler closure OLUŞTURULDUĞU ANDA DEĞER olarak "anlık görüntülenir"
(snapshot, C++ `[=]` varsayılan yakalamasına/Swift'in değer-tipi
yakalamasına BENZER) — Python'un GERÇEK closure semantiği (dış değişkene
SONRADAN yapılan bir atamanın closure İÇİNDEN de GÖRÜLMESİ, "cell"/kutulama
tabanlı) v1 kapsamı DIŞI bırakıldı (mutasyon-görünürlüğü İÇİN değişken
kutulama/`nonlocal` izleme gerektirirdi — AYRI, gelecekteki bir faz).
Heap-yönetimli (str/list/sınıf/vb.) yakalanan değerler RETAIN edilir
(closure kendi kopyasını/referansını TUTAR) — bu, listenin/sınıfın KENDİ
İÇERİĞİNİN closure OLUŞTURULDUKTAN SONRA dışarıdan MUTASYONA uğraması
durumunda BİLE closure'ın GÖRDÜĞÜ ile TUTARLI kalır (referans PAYLAŞIMI,
yalnızca DEĞİŞKENİN KENDİSİNE yeniden atama GÖRÜNMEZ — `list[T]`in Faz
U.1'deki "alias büyüme sonrası görünmez" sınırlamasıyla AYNI KATEGORİDE bir
v1 kesintisi).

**Tip sistemi kararı:** YENİ `Type.func: FuncType` (`FuncType = struct {
params: []const Type, return_type: *const Type }`). Sözdizimi: `(int, int)
-> int` — `parseTypeExpr`in `l_paren` İLE BAŞLAYAN YENİ bir dalı (ŞU ANA
KADAR bir tip ifadesi HER ZAMAN `.identifier`/`kw_none` İLE başlıyordu,
`(` HİÇ kullanılmıyordu — YENİ sözdizimi HİÇBİR ÇAKIŞMA yaratmaz).

**Çalışma zamanı temsili kararı — closure'lar YAPISAL olarak `class`
örnekleriyle AYNI (ARC pointer), İÇ DÜZENİ farklı:** YENİ `HeapKind.closure`
— `{fn_ptr: i64 @0, yakalanan_değerler... @8+}` (class'ın alan düzenine
BENZER, ama alan İSİMLERİ YERİNE capture SIRASI kullanılır). Parametre
geçirme/dönüş/atama/retain/release AÇISINDAN `class` İLE TAMAMEN AYNI ABI
(QBE `l` tipi, pointer) — YALNIZCA "ÇAĞIRMA" işlemi farklıdır (dolaylı
çağrı, `fn_ptr`i BLOKTAN yükleyip `calli` İLE çağırma + env pointer'ı GİZLİ
bir argüman olarak geçirme).

**Alt-fazlar (U.4.1-U.4.4, AGENTS.md İlke #7 ritüeliyle, sırayla):**
- **U.4.1** — Tip sistemi (`Type.func`, `(params)->ret` sözdizimi,
  `typeExprToType`/`format`/`eql`). Runtime/codegen DEĞİŞİKLİĞİ YOK.
- **U.4.2** — İç içe `def` + serbest değişken (capture) analizi (checker).
  `def`in KENDİ adı dış kapsamda `.func` tipinde bir yerel değişken olarak
  bağlanır.
- **U.4.3** — Closure çalışma zamanı temsili + codegen (heap bloğu inşası,
  ARC retain/release, env-parametreli iç fonksiyon derlemesi).
- **U.4.4** — Closure değerleri üzerinden DOLAYLI çağrı + parametre/dönüş
  olarak geçirme.

**Bilinçli v1 sınırlamaları (BAŞTAN kabul edildi):** lambda YOK; mutasyon-
görünür closure YOK (yalnızca DEĞER-yakalama anlık görüntüsü); closure'lar
SINIF ALANI olamaz (yalnızca parametre/yerel değişken/dönüş tipi, v1); genel
(generic)/async iç içe `def` DESTEKLENMEZ (v1).

## 3.24 Faz U.4.1 — Fonksiyon Tip Sistemi (`Type.func` + `(params) -> ret`)

**Kapsam:** U.4'ün İLK alt-fazı — YALNIZCA tip sistemi (types.zig'in
`Type.func`ı, `ast.zig`nin `FuncTypeExpr`i, `(int, int) -> int` sözdizimi,
`checker.zig`nin `typeExprToType`si). Çalışma zamanı temsili/çağrı
mekanizması (closure inşası, dolaylı çağrı) BİLİNÇLİ OLARAK bu fazın
DIŞINDA — U.4.3/U.4.4'te gelecek.

**Sözdizimi:** `(ParamTipi, ...) -> DönüşTipi` — `parseTypeExpr`nin `l_paren`
İLE BAŞLAYAN YENİ dalı. Bir tip ifadesi ŞİMDİYE KADAR HER ZAMAN `.identifier`/
`kw_none` İLE başladığından bu sözdizimi HİÇBİR ÇAKIŞMA yaratmaz. Parametresiz
`() -> None` de geçerlidir.

**Tip sistemi:** `Type.func: FuncType = struct { params: []const Type,
return_type: *const Type }`. `eql`/`format` genişletildi (`format` → `"(p1,
p2) -> ret"`). `ast.TypeExpr`e `func_type: FuncTypeExpr` eklendi
(`FuncTypeExpr = struct { params: []TypeExpr, return_type: *TypeExpr }`).

**Çalışma zamanı temsili kararı (U.4.3/U.4.4 İÇİN önceden belgelenen,
ŞİMDİDEN sabitlenen):** closure'lar `class` örnekleriyle AYNI ARC pointer
temsiline sahip OLACAK (bkz. §3.23) — bu yüzden `ownership/analysis.zig`nin
`isHeapTypeExpr`i `.func_type`i ŞİMDİDEN heap-yönetimli SAYAR (gelecekteki
codegen desteğiyle TUTARLI kalması İÇİN).

**Bilinçli v1.1 kesintisi (BU alt-fazda, sonraki alt-fazlara ERTELENDİ):**
generic fonksiyonlarda func-tipi PARAMETRELER desteklenmiyor (`unifyTypeExpr`
AÇIK bir hata verir); `codegen.zig`nin `resolveType`si `.func_type` İÇİN
`error.Unsupported` döner (henüz codegen YOK); bir func-tipi PARAMETRENİN
gövde İÇİNDE ÇAĞRILMASI henüz desteklenmiyor (`checkCall`in `.identifier`
dalı `self.from_imports`e KADAR düşer, bulamaz, AÇIK "tanımsız fonksiyon"
hatası verir — GÜVENLİ bir başarısızlık, SESSİZ yanlış davranış DEĞİL).

**Değişen dosyalar (exhaustive switch GEREKSİNİMİ, derleyici-yönlendirmeli):**
`types.zig` (`Type.func`), `ast.zig` (`TypeExpr.func_type`), `parser.zig`
(sözdizimi), `checker.zig` (`typeExprToType`, `isFfiSafeType`,
`isSpawnParamSafeType`, `collectProtocolNames`, `unifyTypeExpr`,
`typeToTypeExpr`, `substituteTypeExpr`, `appendMangledType` — SEKİZ AYRI
exhaustive switch, HER biri derleyici hatasıyla TEK TEK bulunup düzeltildi),
`codegen.zig`nin `resolveType`si, `module_loader.zig`nin `renameTypeExpr`i,
`ownership/analysis.zig`nin `isHeapTypeExpr`/`typeExprName`si, `ast_dump.zig`/
`fmt/formatter.zig`nin tip yazdırma yolları.

**ÖNEMLİ YAN KEŞİF — gömülü unit testlerin SESSİZCE hiç çalışmadığı
bulgusu:** U.4.1'in `Type.func` `eql`i İÇİN kasıtlı boz→kırmızı→düzelt
ritüeli uygulanırken (`eql`in dönüş-tipi karşılaştırmasını GEÇİCİ olarak
`break :blk true`ya BOZARAK), `zig build test`in YEŞİL KALDIĞI (kırmızıya
DÖNMEDİĞİ) fark edildi — bu, DOĞRUDAN AGENTS.md İlke #7'nin İHLALİ anlamına
gelirdi. Kök neden araştırıldı: `build.zig`nin `lib_test = b.addTest(.{
.root_module = nox_mod })`i (`nox_mod`nin kökü `compiler/lib.zig`, YALNIZCA
`pub const X = @import(...)` şeklinde YENİDEN-DIŞA-AKTARAN bir "barrel"
dosyası) HİÇBİR `test`/`refAllDecls` çağrısı İÇERMEDİĞİNDEN, Zig'in TEMBEL
(lazy) semantik analiz modeli GEREĞİ `compiler/lexer/lexer.zig`,
`compiler/parser/parser.zig`, `compiler/typecheck/types.zig` (VE muhtemelen
DİĞER TÜM `compiler/*.zig` dosyaları) İÇİNE GÖMÜLÜ `test "..."` bloklarının
HİÇBİRİ bu test ikilisi TARAFINDAN keşfedilmiyordu — yalnızca `tests/unit/`/
`tests/golden/` gibi `nox`ı DIŞARIDAN (public API üzerinden) kullanan AYRI
test dosyaları ÇALIŞIYORDU. Bu, `zig test compiler/lib.zig` (bağımsız,
build.zig'in DIŞINDA) VE `compiler/lexer/lexer.zig`ye kasıtlı bir
`unreachable` EKLENEREK deneysel olarak DOĞRULANDI — `zig build test` HER
İKİ durumda da (gerçek bug VE kasıtlı `unreachable`) YEŞİL kaldı,
`zig test compiler/typecheck/types.zig` (DOĞRUDAN, dosya-BAZLI) İSE
KIRMIZIYA döndü. **Düzeltme:** `compiler/lib.zig`ye Zig 0.16'da `std.testing.
refAllDeclsRecursive` HENÜZ VAR OLMADIĞINDAN EL İLE yazılmış özyinelemeli bir
`refAllDeclsRecursive` yardımcı fonksiyonu + `test { refAllDeclsRecursive(@This()); }`
bloğu eklendi — bu, TÜM yeniden-dışa-aktarılan modülleri (VE onların KENDİ
struct/enum/union tipi iç içe bildirimlerini) Sema'ya zorlayarak İÇLERİNDEKİ
`test` bloklarının GERÇEKTEN keşfedilmesini SAĞLAR. **Bu düzeltme, projenin
`compiler/parser/parser.zig`sindeki DÖRT gömülü testin Faz T.1'den (AST'ye
`ast.Stmt { kind, line }` sarmalayıcısının EKLENDİĞİ faz) BERİ SESSİZCE
DERLENEMEZ (`module.body[0].var_decl` gibi ESKİ, artık GEÇERSİZ alan
erişimleri KULLANIYORLARDI, olması gereken `module.body[0].kind.var_decl`)
durumda olduğunu ORTAYA ÇIKARDI** — bu dört test sitesi `.kind` erişimcisi
eklenerek DÜZELTİLDİ. Düzeltmeden SONRA test SAYISI 300'den **318'e**
çıktı (18 YENİ, önceden HİÇ ÇALIŞMAMIŞ test keşfedildi), TÜMÜ (bu düzeltme
DAHİL) YEŞİL. **Bu bulgu, projenin BUGÜNE KADARKİ "zig build test yeşil"
iddialarının bir KISMININ (compiler/*.zig İÇİNE gömülü testler İÇİN) GERÇEKTE
DOĞRULANMAMIŞ olduğunu gösterir** — ŞANSA, hiçbir gömülü test GERÇEKTEN
bozuk DEĞİLDİ (T.1'in stale field-access'i HARİÇ, o da yalnızca bir derleme
hatasıydı, ÇALIŞMA ZAMANI davranış regresyonu DEĞİL) — ama bu KOŞUL artık
KALICI olarak DÜZELTİLDİ, gelecekteki HİÇBİR gömülü test SESSİZCE
atlanmayacak.

**Doğrulama:**
1. `types.zig`ye 3 YENİ birim testi (`format`in `"(int, int) -> int"` çıktısı,
   `eql`in aynı/farklı imzaları AYIRT ETMESİ, farklı parametre SAYISINI
   AYIRT ETMESİ).
2. `tests/unit/parser_test.zig`ye 2 YENİ test (`(int, int) -> int` VE
   parametresiz `() -> None` sözdiziminin doğru AST'e ayrıştığını kanıtlar).
3. `tests/golden/typecheck_cases/`e 2 YENİ golden test: `ok_func_type_
   signature.nox` (func-tipi bir PARAMETRENİN imzada kabul edildiğini, HİÇ
   çağrılmadan, kanıtlar) VE `err_func_type_call_not_yet_supported.nox`
   (func-tipi bir parametrenin ÇAĞRILMASININ, bilinçli v1.1 kesintisi
   GEREĞİ, AÇIK bir `UndefinedFunction` hatasıyla BAŞARISIZ olduğunu
   kanıtlar).
4. **Kasıtlı boz→kırmızı→düzelt** (YUKARIDAKİ yan keşifle İÇ İÇE geçmiş):
   `eql`in `.func` dalı dönüş-tipi karşılaştırmasını ATLAYACAK şekilde
   BOZULDU → (refAllDecls düzeltmesinden SONRA) `zig build test` GERÇEKTEN
   kırmızıya döndü (317/318) → geri getirildi, 318/318 YEŞİLE döndü.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.25 Faz U.4.2 — İç İçe `def` + Serbest Değişken (Capture) Analizi

**Kapsam:** U.4'ün İKİNCİ alt-fazı — checker'ın iç içe `def`i (KISITLI:
generic OLMAYAN, `async` OLMAYAN) kabul etmesi, dış kapsamdaki serbest
değişken referanslarını (capture) analiz etmesi, iç fonksiyonun adını dış
kapsamda `.func` tipinde bir yerel değişken olarak bağlaması. Çalışma
zamanı temsili/dolaylı çağrı HÂLÂ bu fazın DIŞINDA (U.4.3/U.4.4).

**Mekanizma — `Scope`e ebeveyn zinciri + otomatik capture kaydı:**
`Scope`e iki YENİ alan eklendi: `parent: ?*Scope` (yalnızca bir iç içe
`def`in KENDİ scope'unda NON-null, dış kapsayan fonksiyonun scope'una
işaret eder) ve `captures: ?*StringHashMapUnmanaged(Type)` (AYNI koşulda
NON-null). `Scope.lookup` ARTIK bir allocator alıyor VE hata dönebiliyor
(`!?Type`) — KENDİ değişkenlerinde bulamazsa `parent`a DÜŞER, bulursa VE
`captures` AYARLIYSA bu ismi (İLK karşılaşmada) KAYDEDER. Bu, capture
listesinin `checkNestedFuncDef`in iç fonksiyon gövdesini NORMAL şekilde
(`checkStmt`/`checkExpr` DEĞİŞMEDEN) denetlemesinin YAN ÜRÜNÜ olarak,
HİÇBİR ayrı "serbest değişken bulma" geçişi GEREKMEDEN ortaya çıkmasını
sağlar — Scope zaten TEK dağıtım noktası (`ctx.scope.lookup`) olduğundan.

**`checkNestedFuncDef`:** `ctx.scope`u `parent` olarak KULLANAN yeni bir
`inner_scope` (+ `captures` haritası) inşa eder, iç fonksiyonun
parametrelerini BUNA bildirir, gövdeyi normal `checkStmt` yoluyla denetler,
`alwaysReturns` kontrolünü (üst-düzey fonksiyonlarla AYNI) uygular, SONRA
toplanan capture'ları `Checker.closure_infos`e (anahtar: `"<dış_yol>.
<iç_isim>"`, bkz. `FnCtx.path`in YENİ alanı — üst-düzey fonksiyonlar İÇİN
kendi adı, metodlar İÇİN `"Sınıf.metod"`, iç içe İÇİN özyinelemeli olarak
`"<dış_yol>.<iç_isim>"`) KAYDEDER VE iç fonksiyonun `Type.func` tipini
DÖNER — `checkStmt`in `.func_def` dalı bunu `fd.name`e (dış kapsamda YEREL
bir değişken olarak) BAĞLAR.

**Bilinçli v1 kararı — YALNIZCA OKUNABİLİR yakalama (mutasyon-görünürlüğü
YOK):** `checkAssign`in `.identifier` dalı `lookupLocal` (parent'a
DÜŞMEYEN) kullanır — bulunamazsa VE isim `parent` zincirinde (`existsInChain`,
yan etkisiz bir varlık kontrolü) VARSA, AÇIK bir hata verir ("iç içe
fonksiyonun DIŞINDAN yakalanan bir değişkendir, yalnızca OKUNABİLİR").
Kendi YEREL `var_decl`siyle GÖLGELEME (aynı isimde bir iç değişken
tanımlamak) SORUNSUZ çalışır (`lookupLocal` KENDİ scope'ta bulur, `parent`a
HİÇ bakmaz) — bu, Python'un "yerel atama YENİ bir yerel değişken yaratır"
davranışına BENZER bir statik yaklaşımdır.

**Bilinçli v1 kesintileri:** generic (`type_params.len > 0`) iç içe `def`
REDDEDİLİR; `async def` iç içe REDDEDİLİR; capture'lar DEĞER anlık
görüntüsüdür (dış değişkenin SONRADAN değişmesi closure İÇİNDEN
GÖRÜNMEZ — U.4.3'ün ARC/codegen tasarımının DOĞAL bir sonucu, §3.23'te
ÖNCEDEN kabul edildi); iç içe `def`in kendisi bir İFADE OLARAK
kullanılamıyor (yalnızca bir STATEMENT — Python'daki GİBİ).

**Yan düzeltme — `module_loader.zig`nin mangling'i iç içe `def`lere
KARŞI KIRILGANDI:** `renameStmt`in `.func_def` dalı, `renameTopLevelFuncDef`i
(`map.get(fd.name).?` — `fd.name`in rename haritasında KAYITLI olduğunu
VARSAYAR) HER `func_def` deyimi İÇİN (top-level VEYA iç içe FARK ETMEKSİZİN)
çağırıyordu. İç içe bir `def` (SADECE bir stdlib/proje modülünün İÇİNDE,
kullanıcının KENDİ dosyasında DEĞİL — o hiç bu geçişten GEÇMİYOR) `map`de
KAYITLI OLMADIĞINDAN bu, `.?`nin PANİK yapmasına yol AÇARDI (henüz hiçbir
stdlib dosyası iç içe `def` KULLANMADIĞINDAN BUGÜNE kadar TETİKLENMEMİŞ bir
gizli kusur). **Düzeltme:** YENİ `renameNestedFuncDef` (adı DEĞİŞTİRMEZ,
yalnızca içindeki tip ifadelerini/gövdeyi yeniden adlandırır) eklendi;
`renameStmt`in `.func_def` dalı `map.contains(fd.name)`e göre İKİSİ
arasında dispatch eder.

**Doğrulama:**
1. **Manuel uçtan-uca:** `zig test` İLE doğrudan (harici bir Zig test
   dosyası aracılığıyla, `nox.checker.check` ÇAĞRILARAK) BEŞ senaryo
   doğrulandı: (a) geçerli bir capture (dış `n`yi okuyan bir iç `adder`)
   → `OK`; (b) tanımsız serbest değişken → AÇIK `UndefinedVariable`; (c)
   yakalanan bir değişkene atama → AÇIK, ÖZEL bir `TypeMismatch` mesajı;
   (d) generic iç içe `def` → REDDEDİLİR; (e) `async` iç içe `def` →
   REDDEDİLİR; (f) İÇ fonksiyonun KENDİ aynı-isimli yerel `var_decl`si dış
   değişkeni GÖLGELER (capture DEĞİL, HATA da YOK). `noxc build` İLE de
   manuel doğrulandı: checker AŞAMASI `OK` verirken, codegen (henüz U.4.3
   UYGULANMADIĞINDAN) `error.Unsupported` İLE AÇIK/güvenli bir şekilde
   BAŞARISIZ olur (ÇÖKME/YANLIŞ davranış DEĞİL) — bu, U.4.2/U.4.3
   ARASINDAKİ sınırın TAM OLARAK tasarlandığı GİBİ çalıştığını kanıtlar.
2. **Golden testler** (`tests/golden/typecheck_cases/`, 5 YENİ): `ok_nested_
   def_capture.nox`, `err_nested_def_undefined_capture.nox`, `err_nested_
   def_assign_to_capture.nox`, `err_nested_def_generic.nox`, `err_nested_
   def_async.nox`.
3. **Kasıtlı boz→kırmızı→düzelt:** `checkAssign`in "yakalanan değişkene
   atama" kontrolü (`existsInChain` çağrısı) GEÇİCİ olarak `if (false and
   ...)` İLE devre dışı BIRAKILDI → `err_nested_def_assign_to_capture`
   testi GERÇEKTEN kırmızıya döndü (ÖZEL mesaj YERİNE genel "tanımsız
   değişken" hatası — hâlâ bir hata, AMA YANLIŞ TÜRDEN), DİĞER 322 test
   YEŞİL KALDI. Geri getirildi, 323/323 YEŞİLE döndü.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.26 Faz U.4.3 — Closure Çalışma Zamanı Temsili + QBE Codegen

**Kapsam:** U.4'ün ÜÇÜNCÜ alt-fazı — U.4.2'nin checker seviyesinde kabul
ettiği iç içe `def`ler İÇİN gerçek bir çalışma zamanı temsili + QBE codegen.
Bir closure'ın DEĞER OLARAK dolaylı çağrılması/parametre-dönüş olarak
GEÇİRİLMESİ HÂLÂ bu fazın DIŞINDA (U.4.4) — burada YALNIZCA "bir iç içe
`def` tanımlandığında ne inşa edilir, çağrıldığında/kapsam dışına çıkınca
ne olur" ele alınıyor.

**Çalışma zamanı temsili — `HeapKind.closure`, `HeapKind.class` İLE YAPISAL
OLARAK AYNI (ARC işaretçisi, AYNI havuz), ama farklı bellek düzeni:**
`nox_rc_alloc`/`nox_rc_predecrement`/`nox_rc_free_payload` İLE AYNI ARC
mekanizması kullanılır — YENİ bir ayırıcı/havuz GEREKMEDİ. Bellek düzeni
`{fn_ptr: l @0, yakalanan_değerler... @8+}` — sınıf örneklerinin isimli
alanlarının YERİNE, offset 0'da FONKSİYON İŞARETÇİSİ, sonrasında sırayla
yakalanan değerler. Sınıflarla PAYLAŞILAN `class_name` alanı (`Value`
struct'ının bir parçası) BU BAĞLAMDA closure'ın ÜRETİLMİŞ release
fonksiyonunun mangled adını TUTACAK şekilde YENİDEN KULLANILDI (yeni bir
alan EKLEMEDEN).

**Ön-doğrulama — QBE'nin fonksiyon adresini SIRADAN bir işaretçi değeri
olarak saklayıp/yükleyip çağırabildiği MANUEL bir deneyle (`/tmp/
fnptr_test.ssa`) kanıtlandı:** `storel $add, %p` → `loadl` → `call %fp(...)`
zinciri `qbe`+`cc` İLE derlenip ÇALIŞTIRILDI, doğru sonuç üretti. Bu,
closure'ları BU codegen mimarisinde MÜMKÜN kılan TEK yük taşıyan
mekanizma.

**`sanitizePathToSymbol`:** checker'ın ürettiği nokta-ayrılmış yolu
(`"outer.adder"`) QBE-güvenli bir sembol adına çevirir (`"closure_outer_
adder"` — noktalar alt çizgiye, `"closure_"` ÖNEKİ çakışmaları ÖNLEMEK
İÇİN).

**Codegen'in KENDİ bağımsız capture-tipi çıkarımı (checker'dan `Type`
AKTARILMAZ):** `Codegen.closure_infos: StringHashMapUnmanaged([]const
[]const u8)` yalnızca YOL → capture İSİMLERİNİ taşır (checker'ın `Type`
bilgisi DEĞİL) — codegen HER capture'ın TAM `TypeInfo`sunu construction
NOKTASINDA KENDİ `self.vars`ından (kapsayan fonksiyonun O ANKİ yerel
değişken tablosu) yeniden türetir. Bu, checker'ın `Type` ile codegen'in
`TypeInfo`si ARASINDA bir dönüşüm katmanı GEREKTİRMEDEN iki AŞAMANIN
bağımsız kalmasını sağlar.

**Ana codegen akışı:**
- `collectLocals`in `.func_def` dalı: `path = "{current_path}.{fd.name}"`
  + `mangled = sanitizePathToSymbol(path)` hesaplayıp `fd.name`i
  `heap = .closure, class_name = mangled` İLE bir YEREL olarak KAYDEDER —
  bu, `genNestedFuncDef`in SONRADAN bağımsız olarak yeniden hesaplayacağı
  AYNI mangled adı ÖNCEDEN sabitler (tutarlılık garantisi).
- `genNestedFuncDef`: yol/mangled adı hesaplar; `closure_infos`den capture
  isimlerini okur; HER capture İÇİN kapsayan fonksiyonun `self.vars`ından
  O ANKİ `VarInfo`yu okuyup bir `ClosureCaptureField` listesi kurar;
  `nox_rc_alloc(rt, 8 + 8*n)` İLE bloğu ayırır; offset 0'a `$mangled`
  (fonksiyon işaretçisi) yazar; HER capture İÇİN kaynak slotundan DEĞERİ
  okuyup (heap-yönetimliyse `emitInlineRetain` İLE retain EDEREK) offset
  `8 + 8*i`ye yazar; SONRA bağlanacak isme AİT ÖNCEDEN-tahsis edilmiş
  slotta (döngü içinde yeniden inşa gibi durumlar İÇİN) `releaseSlotIfSet`
  yapıp YENİ blok işaretçisini yazar; SON olarak bir `ClosureFuncSpec`i
  `self.closure_funcs`e (aynı "sonda tüket" tembel kuyruk deseni, `spawn_
  wrappers`/`http_serve_wrappers`/`list_release_queue` İLE AYNI) EKLER.
- `genClosureFunc`: `genFunction`e BENZER, İKİ farkla — (1) QBE imzasına
  `RT_PARAM`dan HEMEN SONRA gizli bir `l %env` parametresi eklenir; (2) HER
  capture `is_param = true` olarak KAYDEDİLİR (`releaseAllLocals` çıkışta
  bunu ATLAR — closure bloğunun KENDİSİ zaten sahip, bu bir ÖDÜNÇ referans)
  ve DEĞERİ `%env`den (offset `8+8*i`) YÜKLENİR — GERÇEK bildirilmiş
  parametreler NORMAL `%p_<isim>` register'larından YÜKLENMEYE DEVAM eder.
  Gövde/`releaseAllLocals`/default-return AYNEN normal fonksiyonlar GİBİ
  işler — capture'ların "özel" olduğunu FARK ETMEZ, ÖNCEDEN-doldurulmuş
  birer yerel gibi görünürler.
- `genClosureRelease`: `genClassRelease` İLE AYNI yapı — predecrement,
  sıfıra inerse HER heap-yönetimli capture'ı `releaseValueIfSet` İLE
  serbest bırakır, Task/Channel/dict capture'ları `destroyNonArcValue`
  İLE yok eder, `nox_rc_free_payload` TAM hesaplanan boyutla (`8 + 8*n`)
  çağrılır.

**Bilinçli v1 kapsam kesintileri:** Katman 3 döngü çözücüsüyle (`nox_
cycle_possible_root`/`nox_cycle_forget`) HİÇBİR entegrasyon YOK — `list[T]`/
`dict[K,V]` elemanlarının ZATEN döngü tespitinin DIŞINDA bırakılmasıyla
TUTARLI bir kapsam kararı. Closure'lar İÇİN `==`/`!=` desteklenmiyor —
derin-eşitlik yardımcısının `.dict, .task, .channel` dalına `.closure` da
EKLENDİ ama işaretçi-kimliği karşılaştırmasına DÜŞÜYOR (checker BUGÜN
closure'ları hiç `==`e YÖNLENDİRMEDİĞİNDEN pratikte ERİŞİLEMEZ, yalnızca
switch'in KAPSAMLI/derlenebilir kalması İÇİN savunmacı bir dal).

**KRİTİK çökme hatası bulundu ve düzeltildi — `releaseValueIfSet`in
`class_name.?` ÇAĞRISI, func-TİPLİ bir değişkene atanan bir closure İÇİN
PANİK yapıyordu:** `result: (int) -> int = make_adder(5)` gibi bir kod,
manuel uçtan-uca test SIRASINDA (otomatik test SÜİTİ DEĞİL — o ana kadar
HİÇBİR golden test bu SENARYOYU egzersiz ETMİYORDU) gerçek bir "attempt to
use null value" PANİĞİNE yol AÇTI. Kök neden: `Type.func` YAPISAL/
polimorfik bir tiptir (`Type.class`in AKSİNE HER ZAMAN TEK somut bir sınıfı
ADLANDIRMAZ) — bir closure DEĞERİ, dönüş/yeniden-atama YOLUYLA çıplak bir
tip ANNOTASYONUNA aktığında SOMUT kökeni (`class_name`) KAYBOLUR (bu
yayılımı çözmek AÇIKÇA U.4.4'e ERTELENDİ, U.4.3'ün KAPSAMI DEĞİL).
**Düzeltme:** `releaseValueIfSet`in `.class or .closure` dalındaki
`class_name.?` `const cn = class_name orelse return error.Unsupported;`e
ÇEVRİLDİ — çökme, main.zig'in ZATEN YAKALADIĞI güvenli hata yoluna
("codegen: bu program şu an desteklenmeyen bir yapı içeriyor...") DÖNÜŞTÜ.
Düzeltme SONRASI manuel yeniden-çalıştırma TEMİZ çıkış kodu 1 gösterdi
(segfault/panik DEĞİL).

**AYRI, İLGİSİZ bir hata bulundu ve BİLİNÇLİ olarak İÇERİDE DÜZELTİLMEDİ:**
`None` dönen bir fonksiyonun ÇIPLAK üst-düzey bir deyim olarak çağrılması
(ör. `foo(5)`, atama/print OLMADAN) codegen'de `error.Unsupported` İLE
ÇÖKÜYOR — izolasyon testleriyle (closure'suz, YALNIZCA bu senaryo) DOĞRULANDI,
closure ÇALIŞMASIYLA HİÇBİR İLGİSİ YOK. `mcp__ccd_session__spawn_task` İLE
AYRI bir arka plan görevi olarak İŞARETLENDİ (`task_cda7e052`), BU FAZIN
KAPSAMINA DAHİL EDİLMEDİ.

**Test-tasarımı yakın-kaçırma dersi (T.4b'nin "y değişkeni" dersiyle AYNI
KATEGORİDE, BU FAZDA İKİNCİ KEZ):** heap-capture golden testinin İLK
sürümü (string LİTERALLERİ capture EDEN, dış fonksiyonun captured string'i
DÖNDÜRDÜĞÜ bir tasarım) kasıtlı olarak DEVRE DIŞI bırakılan capture-retain'i
otomatik `zig build test` SÜİTİNDE YAKALAYAMADI (sessizce YEŞİL kaldı) —
kök neden dikkatli refcount ANALİZİYLE bulundu: (1) string LİTERALLERİ
`PINNED_REFCOUNT` İLE "sabitlenmiş" olduğundan HİÇBİR dengesizlik sıfıra
İNEMEZ/görünmez; (2) dış fonksiyonun `return greeting`i KENDİ telafi edici
retain'ini (`returnNeedsRetain`) TETİKLEYİP eksik capture-retain'i SAYISAL
olarak İPTAL ETTİ. **Test YENİDEN TASARLANDI:** `combined: str = a + b`
(GERÇEKTEN heap-tahsisli, sabitlenmemiş bir birleştirme sonucu) capture
EDEN, ama dış fonksiyonun (bir `int` DÖNDÜREREK) HİÇ ÇAĞIRMADIĞI/DÖNDÜRMEDİĞİ
bir closure — böylece closure'ın KENDİ retain/release ÇİFTİ, BAŞKA
telafi edici retain'ler OLMADAN İZOLE edilir. Manuel `/tmp` testiyle bunun
retain YOKKEN GERÇEK bir SIGSEGV (çıkış kodu 139) ÜRETTİĞİ, SONRA GERÇEK
`zig build test` SÜİTİYLE "81 pass, 1 fail (82 total)" / "325/326" (BOZUK) →
326/326 (DÜZELTİLMİŞ) GEÇİŞİ Debug VE ReleaseFast'ta DOĞRULANDI.

**`generateModule` imza değişikliği + 8 çağrı sitesi güncellemesi:**
`generateModule` YENİ bir `closure_infos: StringHashMapUnmanaged([]const
[]const u8)` parametresi ALDI. `main.zig` checker'ın `closure_infos`unu
BU forma DÖNÜŞTÜRÜP geçiyor; `codegen_golden_test.zig`nin `compileAndRun`
yardımcı fonksiyonu AYNI dönüşümü yapıyor; DİĞER 6 basit çağrı sitesi
(`fmt_golden_test.zig`, `extern_ffi_test.zig`, `hpy_call_golden_test.zig`,
`http_serve_golden_test.zig`, `http_stdlib_golden_test.zig` VE
`codegen_golden_test.zig`nin 3 diğer DOĞRUDAN çağrısı) `.empty` geçiyor
(bunlar TAM bir `Checker` örneği EXPOSE ETMEYEN basitleştirilmiş `nox.
checker.check` OK/ERR sarmalayıcısını KULLANDIĞINDAN).

**Doğrulama:**
1. **3 YENİ golden test** (`tests/golden/codegen_cases/`):
   `nested_def_capture_primitive.nox` (int capture, ÇAĞRILMAYAN iç `def`,
   dış fonksiyon `n`yi DÖNDÜRÜR — temel yapı-inşa-serbest-bırak DÖNGÜSÜ,
   sızıntısız); `nested_def_capture_heap.nox` (yukarıdaki, YENİDEN
   TASARLANMIŞ heap-capture testi); `rejected_closure_return_type.nox`
   (func-tipli bir değişkene atama, `error.Unsupported`e DÜŞTÜĞÜNÜ
   `expectError` İLE kanıtlar — `rejected_lowlevel_escape` İLE AYNI
   desen).
2. **Kasıtlı boz→kırmızı→düzelt** (capture-retain): `genNestedFuncDef`deki
   `if (isHeapManaged(c.info.heap)) try self.emitInlineRetain(v);` GEÇİCİ
   olarak `if (false and ...)` İLE devre dışı BIRAKILDI → `zig build test`
   GERÇEKTEN "81 pass, 1 fail (82 total)" / "325/326 tests passed"
   GÖSTERDİ (BAŞARISIZ olan TAM OLARAK YENİ heap-capture testiydi) →
   geri getirildi → 326/326 YEŞİLE döndü (Debug VE ReleaseFast).
3. **Manuel uçtan-uca doğrulama** (`/tmp` scratch dosyaları): temel
   closure inşası/çağrısı, KRİTİK `releaseValueIfSet` çökme hatasının
   BULUNMASI/DÜZELTİLMESİ, İLGİSİZ None-dönüş hatasının İZOLASYONU
   (üçü de yukarıda ayrıntılı).

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.27 Faz U.4.4 — Closure Değerleri Üzerinden Dolaylı Çağrı + Parametre/Dönüş Olarak Geçirme

**Kapsam:** U.4'ün DÖRDÜNCÜ ve SON alt-fazı — bir closure DEĞERİNİN (bir iç
içe `def`den, bkz. §3.25/§3.26) bir func-tipli DEĞİŞKENE/PARAMETREYE
atanabilmesi VE o değişken/parametre ÜZERİNDEN DOLAYLI olarak (`f(x)`,
`f`nin HANGİ SOMUT closure'ı tuttuğu derleme zamanında BİLİNMESE de)
çağrılabilmesi. Bu, U.4.1-U.4.3'ün kurduğu tüm altyapının (fonksiyon tip
sistemi, capture analizi, ARC'lı çalışma zamanı temsili) NİHAİ tüketicisi —
Nox artık gerçek, sınırlı ama İŞLEVSEL bir birinci-sınıf fonksiyon değeri
desteğine sahip.

**Mimari anahtar karar — closure bloğuna İKİNCİ bir işaretçi eklenerek
"küçük bir vtable" haline getirilmesi:** U.4.3'ün bellek düzeni
`{fn_ptr: l @0, yakalananlar... @8+}` idi; release fonksiyonu SOMUT
`class_name` üzerinden İSİM-tabanlı çağrılıyordu — ama bir closure DEĞERİ
çıplak bir func-tipi ANNOTASYONUNA (`Type.func`, YAPISAL/polimorfik bir
tip, `Type.class`in AKSİNE HİÇBİR ZAMAN TEK bir somut tipi adlandırmaz)
aktığında bu isim KAYBOLUYORDU (U.4.3'ün "panik yerine güvenli hata"
geçici çözümü TAM BURADAN kaynaklanıyordu). **Çözüm:** bellek düzeni
`{fn_ptr: l @0, release_fn_ptr: l @8, yakalananlar... @16+}`e genişletildi
(`CLOSURE_HEADER_SIZE = 16`) — closure'ın KENDİ release fonksiyonuna bir
işaretçi, İNŞA ANINDA (`genNestedFuncDef`, `$<mangled>_release`) bloğun
KENDİSİNE gömülür. Bu, `releaseValueIfSet`in `.closure` dalını TAMAMEN
DOLAYLI/POLİMORFİK hale getirir: `class_name` ARTIK HİÇ GEREKMEZ, offset
8'den release fonksiyon işaretçisi YÜKLENİP DOĞRUDAN çağrılır (`call
{fn_ptr_temp}(l rt, l ptr)`, QBE'nin bir TEMP üzerinden dolaylı çağrıyı
desteklediği — bkz. §3.26'nın `/tmp/fnptr_test.ssa` deneyi — GERÇEĞİNE
dayanır). **U.4.3'ün `error.Unsupported` geçici çözümü ARTIK TAMAMEN
ORTADAN KALKTI** — bir closure, kökeni SOMUT olarak bilinmeyen bir
değişkenden BİLE HER ZAMAN doğru şekilde release edilir.

**Dolaylı ÇAĞRI mekanizması — `fn_ptr` (offset 0) hem inşa ANINDA (normal,
DOĞRUDAN çağrı, bkz. §3.26) hem SONRADAN (dolaylı çağrı) AYNI ROLÜ
oynar:** bir closure DEĞERİNİN KENDİSİ (`{fn_ptr, release_fn_ptr,
captures...}`e işaret eden TEK bir `l` pointer) hem "nasıl çağrılır" hem
"nasıl serbest bırakılır" bilgisini TAŞIYAN, KENDİ KENDİNE YETEN bir
birimdir. Dolaylı çağrı `genCall`in `.identifier` dalına eklenen YENİ bir
dala dayanır: `name`, SIRADAN bir fonksiyon/sınıf/extern def DEĞİLSE (bkz.
mevcut dal SIRASI) ama `self.vars.get(name)` `heap == .closure` bir yerel
DÖNDÜRÜYORSA (bir DEĞİŞKEN YA DA PARAMETRE — İKİSİ de AYNI `self.vars`
mekanizmasından geçtiğinden BURADA hiçbir AYRIM gerekmez), closure
POINTER'ı slotundan YÜKLENİR, offset 0'dan `fn_ptr` YÜKLENİR, argümanlar
NORMAL şekilde hesaplanıp `func_sig`in (aşağı bkz.) beklediği QBE tipine
`convert` edilir, SONRA `call {fn_ptr}(l rt, l closure_ptr, <argümanlar>)`
(GİZLİ `%env` argümanı — bkz. §3.26'nın `genClosureFunc`i — burada closure
POINTER'ININ KENDİSİDİR) emisyona verilir. Dolaylı çağrının HEDEFİ derleme
zamanında bilinmediğinden `must_not_raise` eleme optimizasyonu (bkz.
performans fazı) UYGULANAMAZ — istisna kontrolü HER ZAMAN yapılır (güvenli
varsayılan, normal fonksiyon çağrılarının aksine).

**`FuncSigInfo` — argüman/dönüş tiplerini STATİK olarak taşıyan YENİ bir
betimleyici:** dolaylı çağrının SOMUT hedefi bilinmese de, çağrının STATİK
İMZASI (kaç argüman, hangi QBE tipleri, dönüş tipi/heap betimleyicisi) HER
ZAMAN bilinir — değişkenin/parametrenin/dönüşün KENDİ tip ifadesinden
(`(int, int) -> int` gibi). `resolveType`in `.func_type` dalı ARTIK her
parametreyi VE dönüş tipini ÖZYİNELEMELİ olarak `resolveType` ile çözüp
bir `FuncSigInfo{ params: []TypeInfo, ret: TypeInfo }` üretir; bu,
`TypeInfo`/`VarInfo`nin YENİ `func_sig: ?*const FuncSigInfo` alanında
TAŞINIR (`allocSlot` ile diğer alanlarla AYNI şekilde kopyalanır). Dolaylı
çağrı `func_sig.params`i argüman SAYISI/`convert` hedefi İÇİN, `func_sig.ret`i
SONUÇ `Value`sinin `qtype`/`heap`/`elem_*`/`dict_info` alanlarını DOĞRU
DOLDURMAK İÇİN kullanır — böylece bir closure'ın DÖNDÜRDÜĞÜ heap-yönetimli
bir değer (ör. `str`) bile doğru etiketlenmiş olarak akmaya devam eder.

**Checker tarafı — `checkCall`in `.identifier` dalına YENİ bir dal:**
`name` SIRADAN bir fonksiyon/sınıf DEĞİLSE ama `ctx.scope.lookup(name)`
bir `Type.func` DÖNDÜRÜYORSA, bu bir DOLAYLI çağrıdır — `checkArgs`
(NORMAL fonksiyon çağrılarıyla PAYLAŞILAN AYNI mekanizma) `Type.func.params`e
KARŞI argümanları denetler, `Type.func.return_type.*` döner. `name` yerel
bir değişken/parametre OLUP func-tipli DEĞİLSE (ör. bir `int` değişkeni
çağrılmaya ÇALIŞILIYORSA) AÇIK bir `TypeMismatch` ("bir fonksiyon değildir,
çağrılamaz") verilir — genel "tanımsız fonksiyon" hatasından DAHA
İSABETLİ. Bu dal, from-import çözümlemesinden ÖNCE denenir (yerel bir isim
HER ZAMAN ÖNCELİKLİDİR — U.3'ün from-import önceliğiyle AYNI ilke).

**Kapsam (bilinçli v1 sınırı, DEĞİŞMEDİ):** yalnızca bir iç içe `def`DEN
İNŞA EDİLEN closure değerleri func-tipli olabilir — üst-düzey bir `def`in
KENDİSİNE (bare fonksiyon referansı, ör. `f: (int) -> int = add`) HENÜZ
izin YOK (Nox'ta bu, `spawn`/`nox.http.serve`in "çıplak isim" kısıtıyla AYNI
gerekçeyle, first-class fonksiyon REFERANSI kavramının KENDİSİ HENÜZ
tasarlanmadığından kapsam DIŞI bırakıldı — GELECEKTE ayrı bir faz).

**U.4.1'in eski "henüz desteklenmiyor" testinin GÜNCELLENMESİ:** U.4.1
sırasında yazılan `err_func_type_call_not_yet_supported` (bir func-tipli
PARAMETRENİN çağrılmasının `UndefinedFunction` ile REDDEDİLDİĞİNİ kanıtlayan
typecheck golden testi) artık YANLIŞ bir iddia taşıyordu — U.4.4 TAM OLARAK
bu senaryoyu DESTEKLİYOR. `ok_func_type_param_indirect_call` olarak
YENİDEN ADLANDIRILDI (AYNI kaynak, `.expected` `OK`e ÇEVRİLDİ). BENZER
şekilde U.4.3'ün `rejected_closure_return_type` testi (bir closure'ın
func-tipli bir değişkene atanmasının `error.Unsupported` verdiğini kanıtlayan
codegen testi) SİLİNDİ — YERİNE gerçek uçtan-uca ÇALIŞAN İKİ golden test
eklendi (aşağı bkz.). Bu, U.4.3'ün spec'inin AÇIKÇA öngördüğü bir "geçici
kısıtlamanın kaldırılması" adımıdır.

**Doğrulama:**
1. **2 YENİ uçtan-uca golden test** (`tests/golden/codegen_cases/`):
   `closure_returned_and_called_indirectly.nox` (`make_adder(n)` bir iç içe
   `def`i DÖNDÜRÜR; İKİ farklı SOMUT closure — `add5`/`add10` — func-tipli
   değişkenlere atanır, HER BİRİ birden çok kez DOLAYLI çağrılır — doğru
   SOMUT closure'a DOĞRU dispatch edildiğini VE her çağrının doğru sonucu
   ürettiğini kanıtlar, beklenen çıktı `"6\n7\n11\n"`); `closure_passed_as_
   param_called_indirectly.nox` (`apply(f, x)` bir func-tipli PARAMETRE
   alır, İÇİNDE `f(x)` dolaylı çağırır; `make_doubler()`in döndürdüğü bir
   closure `apply`e ARGÜMAN olarak GEÇİRİLİR — func-tipli bir PARAMETRENİN
   hem doğru şekilde ARGÜMAN olarak alınabildiğini hem İÇERİDE çağrılabildiğini
   kanıtlar, beklenen çıktı `"42\n"`).
2. **1 GÜNCELLENMİŞ typecheck golden testi**: `ok_func_type_param_indirect_call`
   (yukarı bkz.).
3. **Manuel uçtan-uca doğrulama** (`noxc build` + çalıştırma, `/tmp` scratch
   dosyaları): her iki yeni golden test senaryosu manuel olarak da
   çalıştırılıp DOĞRU çıktı VE (stderr'de "bellek sızıntısı tespit edildi"
   mesajının YOKLUĞUYLA, bkz. `runtime/alloc/asap.zig`nin `nox_runtime_
   deinit`i) sızıntısız olduğu doğrulandı.
4. **Kasıtlı boz→kırmızı→düzelt (İKİ AYRI KRİTİK özellik İÇİN, sırayla):**
   (a) `genNestedFuncDef`in `release_fn_ptr` YAZMA satırı GEÇİCİ olarak
   yorum satırına ALINDI → `zig build test` "79 pass, 4 fail (83 total)"
   / "323/327" GÖSTERDİ — BAŞARISIZ olan TAM OLARAK closure-ilişkili DÖRT
   test (U.4.3'ün İKİ eski testi DAHİL, çünkü ONLAR da ARTIK genel release
   mekanizmasını kullanıyor) — geri getirildi, 327/327 YEŞİLE döndü.
   (b) Dolaylı çağrının `fn_ptr` YÜKLEME ofseti GEÇİCİ olarak 0 YERİNE 8
   (release_fn_ptr'ın KENDİ ofseti) yapıldı → `zig build test` "81 pass,
   2 fail (83 total)" / "325/327" GÖSTERDİ — BAŞARISIZ olan TAM OLARAK YENİ
   İKİ dolaylı-çağrı testi (DİĞER closure testleri ETKİLENMEDİ, çünkü
   ONLAR dolaylı çağrı KULLANMIYOR) — geri getirildi, 327/327 YEŞİLE döndü.
   Her iki durumda da Debug VE ReleaseFast'ta doğrulandı.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz. **Faz U.4
(U.4.1-U.4.4) TAMAMEN BİTTİ** — Nox artık iç içe fonksiyonlar, serbest
değişken yakalama, ARC'lı closure çalışma zamanı temsili VE dolaylı
çağrı/parametre/dönüş desteğiyle sınırlı ama gerçek bir birinci-sınıf
fonksiyon değeri modeline sahip.

---

## 3.28 Faz U.5 — `with` / Bağlam Yöneticisi (Context Manager)

**Kapsam:** `with EXPR as NAME:` / `with EXPR:` — Python'un `__enter__`/
`__exit__` protokolüyle BENZER, ama BİLİNÇLİ olarak DAHA DAR bir v1: `EXPR`
bir `__enter__(self) -> T` / `__exit__(self) -> None` metod ÇİFTİNE sahip
bir SINIF örneği değerlendirmelidir (İKİSİ de argümansızdır); `__exit__`
HİÇBİR istisna bilgisi ALMAZ ve bir istisnayı ASLA BASTIRAMAZ (Python'un
`__exit__(exc_type, exc_value, tb) -> bool`sinin AKSİNE — v1 kapsamı
BİLİNÇLİ olarak yalnızca "kaynak temizliği garantisi" senaryosunu hedefler,
"istisna yutma" YOK). `binding` (`as NAME` VERİLDİYSE) `__enter__`in DÖNÜŞ
DEĞERİNE bağlanır — `EXPR`in KENDİSİNE DEĞİL (Python'un KENDİ ayrımıyla
TUTARLI, `open(...)`in `__enter__`i dosya tutamacının KENDİSİNİ döner ama
bir contextlib tarzı sarmalayıcı FARKLI bir değer dönebilir).

**Mimari — `EXPR`in DEĞERİ fonksiyon-genelinde GİZLİ bir yerelde tutulur,
gövde/temizlik ilişkisi SIFIR `except` dallı bir `try/finally`YLE BİREBİR
AYNIDIR:** yeni `ast.WithStmt = struct { ctx_expr: Expr, binding: ?[]const
u8, body: []Stmt }` (yeni `kw_with` anahtar kelimesi, `parseWith`).
Checker'ın `checkWith`i: `EXPR`in tipinin `.class` olduğunu, o sınıfın
`__enter__`/`__exit__` metod ÇİFTİNE (argümansız, `__exit__`in `None`
DÖNDÜĞÜ) sahip olduğunu doğrular; `binding` VERİLDİYSE `__enter__`in dönüş
tipine bağlar; gövdeyi NORMAL `checkStmt` yoluyla denetler. Codegen'in
`genWith`i: `EXPR`i değerlendirip fonksiyon-genelinde GİZLİ bir yerele
(`__with_ctx_L<satır>` — `collectLocals`in YENİ `inferWithCtxClassName`
yardımcısı, `for x in xs:`nin AYNI "kısıtlı desen tabanlı tip çıkarımı"
kısıtıyla, `EXPR`in sınıfını YALNIZCA doğrudan bir `ClassAdı(...)` kurucu
çağrısından YA DA ZATEN bilinen bir yerelden çıkarır) depolar; `__enter__()`
çağrısını (sentetik bir `obj.method()` AST ifadesi İNŞA EDİP `genExpr`in
NORMAL `.call`/`.attribute` dağıtımından — `genMethodCall` — geçirerek,
HİÇBİR özel kod GEREKMEDEN retain/release/istisna kontrolü DAHİL doğru
işler) yapıp `binding`e bağlar; SONRA gövde/temizlik çiftini, `except_
clauses` BOŞ bir sentetik `ast.TryStmt` (`finally_body` = sentetik
`__exit__()` çağrısı) inşa edip DOĞRUDAN `genTry`ye DEVREDEREK üretir —
`return`/istisna yayılımı/normal tamamlanma DAHİL HER çıkış yolu, `try/
finally`nin ZATEN battle-tested olan mekanizmasıyla AYNEN işlenir. GERÇEK
bellek serbest bırakması (GİZLİ ctx yerelinin KENDİSİ) normal fonksiyon-
sonu `releaseAllLocals`e ERTELENİR (Python'un HEMEN bloğun SONUNDA serbest
bırakmasından FARKLI, ama ARC doğruluğu AÇISINDAN eşdeğerdir — TÜM yereller
zaten fonksiyon-genelinde bu şekilde yönetiliyor, bkz. §3.1).

**KRİTİK, ÖNCEDEN VAR OLAN bir hata BULUNDU ve DÜZELTİLDİ — `genTry`nin
`finally_body`si KENDİSİ ÇALIŞIRKEN `finally_stack`de KALIYORDU:** `genWith`i
`genTry`ye devretme tasarımı doğrulanırken (bir `return`, bir `with` GÖVDESİ
İÇİNDEN, `__exit__` GİBİ bir METOD ÇAĞRISI İÇEREN bir temizlik gövdesiyle
BİRLEŞTİĞİNDE) noxc'NİN KENDİSİ derleme sırasında SONSUZ özyinelemeyle
ÇÖKTÜ (yığın taşması). Kök neden: `genTry`nin normal-tamamlanma VE
eşleşen-`except` yollarında `finally_body` (`fb`) DOĞRUDAN `genStmts(fb,
...)` İLE çalıştırılıyordu — AMA `fb`, `self.finally_stack`den YALNIZCA
İLGİLİ `try`nin korumalı bölgesinden TAMAMEN çıkıldıktan SONRA (except
döngüsünün EN SONUNDA) çıkarılıyordu. `fb` İÇİNDE bir METOD ÇAĞRISI VARSA
(metod çağrıları HER ZAMAN `emitExceptionCheck` üretir, `must_not_raise`
elemesi onlara UYGULANMAZ — bkz. M.8'in ertelenmiş notu) VE `current_catch_
label` bu noktada ZATEN eski değerine (genellikle `null`) DÖNMÜŞ OLDUĞUNDAN,
o METOD ÇAĞRISININ `emitExceptionCheck`i `drainFinally`yi ÇAĞIRIYORDU — bu
da `finally_stack`de HÂLÂ DURAN `fb`yi TEKRAR çalıştırıyor, bu da AYNI metod
çağrısını TEKRAR ÜRETİYOR... SONSUZ DERLEME-ZAMANI özyinelemesi. **Bu, YENİ
BİR `with` HATASI DEĞİL, Faz 7'den BERİ var olan, hiçbir mevcut testin
İÇİNDE bir metod çağrısı BARINDIRAN bir `finally` bloğu YAZMADIĞI İÇİN
FARK EDİLMEMİŞ GERÇEK bir `try/finally` hatasıdır** — `with`in `__exit__`i
HER ZAMAN bir metod çağrısı OLDUĞUNDAN bunu İLK KEZ ortaya çıkardı.
**Düzeltme:** yeni `runDetachedFinally(fb, ret_qtype)` yardımcısı — `fb`yi
çalıştırmadan HEMEN ÖNCE `finally_stack`den GEÇİCİ olarak POP'lar (KENDİ
İÇİNDEKİ bir çağrı istisna fırlatırsa bunun DIŞARIYA, `saved_catch`e doğru
yayılması İÇİN), çalıştırır, SONRA (bir SONRAKİ `except` dalının KENDİ
`return`ü GİBİ BAŞKA bir çıkış yolu HÂLÂ onu gerektirebileceğinden) GERİ
EKLER — `genTry`nin normal-tamamlanma VE her eşleşen-`except` yolundaki
DOĞRUDAN `genStmts(fb, ...)` çağrıları BUNUNLA DEĞİŞTİRİLDİ (reraise
yolundaki üçüncü çağrı, KENDİSİ ZATEN kalıcı pop'tan SONRA olduğundan
DEĞİŞMEDİ, GÜVENLİYDİ).

**Bilinçli v1 kapsam sınırları:** yalnızca bir iç içe `def` DEĞİL, herhangi
bir SINIF örneği bağlam yöneticisi OLABİLİR (closure'lar İLE karıştırılmasın
— bu TAMAMEN AYRI bir mekanizma); `__enter__`/`__exit__` argüman ALAMAZ;
`__exit__` bir istisnayı BASTIRAMAZ; `EXPR`in sınıfı YALNIZCA doğrudan bir
kurucu çağrısından YA DA ZATEN bilinen bir yerelden çıkarılabilir (bir alan
okuması/metod çağrısı/indeksleme DEĞİL — `inferFieldType`in AYNI bilinçli
dar kapsamıyla TUTARLI); birden çok bağlam yöneticisi TEK bir `with`de
VİRGÜLLE birleştirilemez (`with A() as a, B() as b:` YOK — HER biri AYRI
bir `with` deyimi olarak İÇ İÇE yazılmalıdır, kapsam/mekanizma AÇISINDAN
FARK ETMEZ).

**Doğrulama:**
1. **5 uçtan-uca golden test** (`tests/golden/codegen_cases/`):
   `with_basic_enter_exit.nox` (temel `as NAME` akışı); `with_return_
   inside_runs_exit.nox` (`with` gövdesi içindeki `return`, `__exit__`i
   BEKLEYİP SONRA döner); `with_exception_caught_by_outer_try_runs_exit.nox`
   (KRİTİK — `with` içinde `raise` edilen bir istisna DIŞ bir `try/except`
   tarafından yakalanır, `__exit__` ARADA doğru çalışır — TAM OLARAK
   yukarıdaki `runDetachedFinally` düzeltmesinin doğruladığı senaryo);
   `with_heap_capture_loop_no_leak.nox` (heap-yönetimli bir bağlam değeri
   döngü içinde tekrar tekrar with'lenir, sızıntı yok); `with_no_binding.nox`
   (`as NAME` OLMADAN `with EXPR:`).
2. **4 typecheck golden testi**: `ok_with_basic`, `err_with_missing_enter`,
   `err_with_missing_exit`, `err_with_not_a_class`.
3. **Manuel uçtan-uca doğrulama** (`noxc build` + çalıştırma, `/tmp` scratch
   dosyaları): TÜM yukarıdaki senaryolar + 1000 yinelemelik bir döngüde
   heap-yönetimli bir capture'ın sızıntısız olduğu, HER SEFERİNDE stderr'de
   "bellek sızıntısı tespit edildi" mesajının YOKLUĞU (bkz. `runtime/alloc/
   asap.zig`nin `nox_runtime_deinit`i) doğrulanarak kanıtlandı. Bu manuel
   test SIRASINDA `runDetachedFinally` düzeltmesi ORTAYA ÇIKTI — düzeltme
   ÖNCESİ, `with_return_inside_runs_exit`in SENARYOSU noxc'nin KENDİSİNİN
   (derleyicinin) yığın taşmasıyla ÇÖKMESİNE yol açıyordu (TAM stack trace
   ile teşhis edildi — `drainFinally→genStmts→genMethodCall→emitExceptionCheck
   →drainFinally` döngüsü); düzeltme SONRASI temiz "exit\n42\nafter\n" çıktısı
   ÜRETTİĞİ doğrulandı. Bu GERÇEK, doğal olarak ORTAYA ÇIKAN bir "kırmızı"
   kanıtı OLDUĞUNDAN (deliberate bir boz→kırmızı testi YERİNE), AYRICA
   deliberate bir yeniden-tetikleme YAPILMADI — noxc'nin KENDİSİNİN sonsuz
   özyinelemeyle çökmesi riski (potansiyel olarak uzun süre asılı kalan bir
   `zig build test` çalıştırması) buna değecek EK bir doğrulama değeri
   KATMIYORDU; ZATEN gözlemlenen çökme + kök-neden analizi + düzeltme SONRASI
   doğrulama YETERLİ kanıt sağladı.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.29 Faz V.1 — `nox.log` Modülü

**Kapsam:** basit, seviyeli konsol günlükleme (`debug`/`info`/`warn`/`error`).
TAMAMEN saf Nox (`stdlib/nox/log.nox`) — `nox.time.now_ms()` + `str()` +
`print()` üzerine yazıldı, hiç Zig/`extern def` GEREKMEDİ (nox.test/
nox.math'ın "saf Nox yeter" ÖNCÜLÜYLE TUTARLI).

**Tasarım — `format` BASMADAN döndürür, `debug`/`info`/`warn`/`error` onu
SARIP basar:**
```nox
def format(level: str, message: str) -> str:
    ts: int = nox.time.now_ms()
    return "[" + level + "] [" + str(ts) + "] " + message

def debug(message: str) -> None:
    print(format("DEBUG", message))
# info/warn/error AYNI desen
```
Bu ayrım İKİ gerekçeyle YAPILDI: (1) kullanıcının KENDİ (ör. bir dosyaya
yazan) sarmalayıcısını yazabilmesi İÇİN `format`ın YENİDEN KULLANILABİLİR
olması; (2) — DAHA KRİTİK OLANI — `debug`/`info`/`warn`/`error`nin ÇIKTISI
`nox.time.now_ms()`in gömdüğü GERÇEK (deterministik OLMAYAN) zaman damgası
YÜZÜNDEN golden testlerin GEREKTİRDİĞİ TAM-EŞLEŞME İLE HİÇ TEST EDİLEMEZ
— `format`ın KENDİSİ (zaman damgasını İÇEREN ama BASMAYAN, bir `str`
DÖNDÜREN saf fonksiyon) İSE `nox.strings.starts_with`/`contains` İLE
İNCELENEBİLİR, TAM olarak deterministik bir doğrulama sağlar (bkz. Faz
K'nın `nox.time` testinin "ham zaman damgasını YAZDIRMA, ondan türetilen
bir BOOLEAN'ı yazdır" İLE AYNI dersi).

**Bilinçli v1 sınırlaması — çalışma zamanında yapılandırılabilir bir
minimum-seviye FİLTRESİ YOK:** Nox'ta fonksiyonlar arası PAYLAŞILAN mutable
modül-düzeyi durum YOK (HER "loose" üst-düzey deyim yalnızca `main`de BİR
KEZ çalışır, bkz. §3.1) — bu yüzden `nox.log.set_level(...)` GİBİ bir
API'nin GERÇEK bir global durumu OLAMAZ (bir sınıf örneği İÇİNDE TUTMAK
mümkün olurdu ama bu, KULLANICININ KENDİ Logger nesnesini AÇIKÇA
DOLAŞTIRMASINI gerektirirdi — v1 kapsamı DIŞINDA bırakıldı, basit serbest
fonksiyonlar TERCİH EDİLDİ). Çıktı HER ZAMAN stdout'a gider (Nox'ta ayrı
bir stderr yazma ilkeli HENÜZ YOK).

**Doğrulama:**
1. **1 uçtan-uca golden test** (`log_format_structure.nox`): `format`ın
   DÖRT seviye (`DEBUG`/`INFO`/`WARN`/`ERROR`) İÇİN doğru `"[SEVIYE] ["`
   ÖNEKİNİ VE mesajı doğru gömdüğünü, `nox.strings.starts_with`/`contains`
   İLE (ham zaman damgasını YAZDIRMADAN, SEKİZ deterministik `True` çıktısı
   olarak) kanıtlar.
2. **Manuel uçtan-uca doğrulama** (`noxc build` + çalıştırma, `/tmp` scratch
   dosyaları): `debug`/`info`/`warn`/`error`nin GERÇEKTEN doğru biçimlenmiş
   satırlar BASTIĞI (`[DEBUG] [1784067419736] starting up` gibi), sızıntı
   OLMADAN doğrulandı.
3. **Kasıtlı boz→kırmızı→düzelt:** `format`in ÖNEK karakteri GEÇİCİ olarak
   `"["` yerine `"("` YAPILDI → `zig build test` "88 pass, 1 fail (89
   total)" / "336/337 tests passed" GÖSTERDİ — BAŞARISIZ olan TAM OLARAK
   YENİ `nox.log` testiydi (`starts_with` kontrolleri `False` DÖNDÜ) — geri
   getirildi, 337/337 YEŞİLE döndü (Debug VE ReleaseFast).

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.30 Faz V.2 — `nox.random` Modülü

**Kapsam:** basit PRNG (`seed`/`randint`/`random`). Diğer stdlib
modüllerinden FARKLI olarak GERÇEK bir Zig kabuğu GEREKTİRDİ (`runtime/
stdlib_shims/random.zig`, `std.Random.DefaultPrng` — Xoshiro256, KRİPTOGRAFİK
güvenlik İDDİASI YOK) — Nox'un KENDİSİNİN rastgelelik ÜRETECEK bir çekirdek
ilkeli YOK.

**Mimari — PRNG durumu, `nox.os`nin argc/argv'siyle AYNI "süreç ömrü
boyunca yaşayan statik Zig değişkeni" deseninde tutulur:** Nox'ta
fonksiyonlar arası PAYLAŞILAN mutable modül-düzeyi durum OLMADIĞINDAN (bkz.
`nox.log`nin AYNI notu), rastgelelik durumunun (PRNG'nin İÇ durumu)
BARINABİLECEĞİ TEK yer BUDUR — `g_prng`/`g_seeded` dosya-düzeyi `var`lar.
`seed` HİÇ çağrılmadıysa İLK kullanımda `clock_gettime` tabanlı bir zaman
damgasıyla OTOMATİK tohumlanır (Python'un `random` modülünün KENDİ
varsayılan davranışıyla TUTARLI).

**KRİTİK, GERÇEKTEN YAŞANAN bir isimlendirme hatası — çekirdek TİP
adlarıyla (`int`/`float`) ÇAKIŞAN fonksiyon isimleri KULLANILAMAZ:**
İLK tasarım `nox.random.int(lo, hi)`/`nox.random.float()` İSİMLERİNİ
kullanıyordu — bu, "bilinmeyen tip: nox_random_int" hatasıyla ÇÖKTÜ.
Kök neden: `module_loader.zig`nin yeniden adlandırma haritası (bkz.
`mangleWith`), bir stdlib modülünün ÜST-DÜZEY FONKSİYON adlarını
(`renameStmt` ARACILIĞIYLA) mangled sembol adlarına ÇEVİRİRKEN, AYNI
haritayı `renameTypeExpr` ARACILIĞIYLA TİP İFADELERİNE de UYGULAR — İKİ
farklı ROL (fonksiyon adı VE tip adı) AYNI isim DİZESİNİ paylaştığında
(`int`), harita AYIRT ETMEDEN HER İKİSİNİ de yeniden yazar. Sonuç: `def
int(lo: int, hi: int) -> int:` gövdesindeki `int` TİP ANNOTASYONLARI da
`nox_random_int`e (fonksiyon adının KENDİ mangled hâline) YENİDEN
YAZILDI — anlamsız bir "tip". **Düzeltme:** isimler `randint`/`random`
OLARAK DEĞİŞTİRİLDİ (Python'un `random.randint`/`random.random`ıyla
TUTARLI, üstelik DAHA TANIDIK) — çekirdek tip adlarıyla ÇAKIŞAN HİÇBİR
stdlib fonksiyonu tanımlanmamalıdır (bu, `nox.os`/`nox.time`in `_raw`
SONEKİ dersiyle AYNI KATEGORİDE ama FARKLI bir çakışma türüdür — o İSİM-
İSİM çakışmasıydı, bu İSİM-TİP çakışmasıdır).

**Doğrulama:**
1. **1 uçtan-uca golden test** (`random_seeded_reproducible.nox`):
   `randint`in DÖNÜŞ değerinin İSTENEN aralıkta olduğunu, `random`ın
   `[0.0, 1.0)` aralığında olduğunu, VE — EN ÖNEMLİSİ — AYNI tohumla
   (`seed`) İKİ KEZ çağrılan `randint`/`random`ın TAM OLARAK AYNI sonucu
   ÜRETTİĞİNİ (deterministik tekrarlanabilirlik) kanıtlar.
2. **Manuel uçtan-uca doğrulama** (`noxc build` + çalıştırma, `/tmp`
   scratch dosyaları): yukarıdaki isimlendirme hatasının TAM OLARAK BU
   YOLLA keşfedilip TEŞHİS EDİLDİĞİ, düzeltme SONRASI sızıntısız çalıştığı
   doğrulandı.
3. **Kasıtlı boz→kırmızı→düzelt:** `nox_random_seed_raw` GEÇİCİ olarak
   tohumu YOK SAYACAK şekilde bozuldu (`g_prng`/`g_seeded`e HİÇ dokunmadan
   `return`) → `zig build test` "89 pass, 1 fail (90 total)" / "337/338
   tests passed" GÖSTERDİ — BAŞARISIZ olan TAM OLARAK YENİ `nox.random`
   testiydi (deterministik-tekrar kontrolleri `False` DÖNDÜ, PRNG İKİ
   çağrı ARASINDA aynı KALMAYIP İLERLEMEYE devam ettiğinden) — geri
   getirildi, 338/338 YEŞİLE döndü (Debug VE ReleaseFast).

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.31 Faz V.3 — `nox.crypto` Modülü (SHA-256 Asgari Kapsam)

**Kapsam:** yalnızca `sha256(data: str) -> str` (64 karakterlik küçük harf
hex özet). `nox.json`nin `std.json.parseFromSlice`i KULLANMA kararıyla AYNI
İLKE: sıfırdan bir hash algoritması YAZILMAZ, Zig'in KENDİ, savaş-test
edilmiş `std.crypto.hash.sha2.Sha256`si SARILIR (`runtime/stdlib_shims/
crypto.zig`). ARC-str ÜRETTİĞİNDEN `with_rt` (bkz. D.1'in Keşif 3'ü)
GEREKİR — `http_client.zig`nin `dupeToNoxStr`ı (nox.log/nox.crypto
ARASINDA PAYLAŞILAN AYNI yardımcı) DOĞRUDAN kullanılır.

**Doğrulama:**
1. **1 uçtan-uca golden test** (`crypto_sha256_known_vectors.nox`):
   `sha256("")`/`sha256("abc")`in FIPS 180-4'ün KENDİ YAYIMLANAN test
   vektörleriyle (`e3b0c44...`/`ba7816bf...`) BİREBİR eşleştiğini kanıtlar
   — `shasum -a 256` İLE BAĞIMSIZ olarak da ÇAPRAZ doğrulandı.
2. **Kasıtlı boz→kırmızı→düzelt:** hex-kodlama döngüsündeki nibble SIRASI
   GEÇİCİ olarak TERS ÇEVRİLDİ (`byte & 0xF` önce, `byte >> 4` sonra) →
   `zig build test` "90 pass, 1 fail (91 total)" / "338/339 tests passed"
   GÖSTERDİ (çıktı `3e0b4c24...`/`ab8761fb...` gibi HER bayt-çiftinin
   İÇİNDE nibble'ları TERS DÖNMÜŞ ama YAPISAL olarak "makul görünen" YANLIŞ
   bir hex dizesi ÜRETTİ — TAM OLARAK exact-match golden testin YAKALAMASI
   GEREKEN türden bir sessiz veri bozulması senaryosu) — geri getirildi,
   339/339 YEŞİLE döndü (Debug VE ReleaseFast).

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.32 Faz V.4 — `nox.time` Genişletmesi (`DateTime`)

**Kapsam:** bir epoch-ms değerini takvim bileşenlerine (yıl/ay/gün/saat/
dakika/saniye) ayrıştıran bir `DateTime` sınıfı + `from_epoch_ms(ms) ->
DateTime` / `now() -> DateTime`. `nox.crypto`nun `std.crypto` KULLANMA
kararıyla AYNI ilke — Zig'in KENDİ `std.time.epoch`u (sıfırdan takvim
aritmetiği YAZILMADAN) SARILIR (`runtime/stdlib_shims/time.zig`ye eklendi,
YENİ bir dosya AÇILMADI — AYNI modülün DEVAMI).

**Mimari — HER bileşen AYRI bir `extern def`:** Nox'un `extern def`i TEK
bir SKALER döndürebildiğinden (struct/tuple YOK), ALTI ayrı `extern def`
(`nox_time_year_raw`/`_month_raw`/`_day_raw`/`_hour_raw`/`_minute_raw`/
`_second_raw`) TANIMLANDI — HER biri AYNI `breakdownSeconds(ms)` yardımcı
fonksiyonunu (Zig-düzeyinde, `export` DEĞİL) ÇAĞIRIP KENDİ bileşenini
ÇIKARIR. Bu, AYNI epoch-gün/saniye HESABININ ALTI KEZ TEKRARLANMASI
anlamına gelir (bilinçli v1 basitleştirmesi — "TEK çağrıda TÜM alanları
hesapla" optimizasyonu YOK, `nox.random`ın "basitlik ÖNCE" ilkesiyle
TUTARLI). Nox tarafı, bu altı sonucu bir ARAYA getirip `DateTime` sınıf
örneğini İNŞA EDER (`from_epoch_ms`).

**Bilinçli v1 sınırlamaları:**
- Yalnızca AYRIŞTIRMA (epoch-ms → `DateTime`) — TERS yön (`DateTime` →
  epoch-ms) YOK. `std.time.epoch` yalnızca DECOMPOSE sağlar; ENCODE
  (civil-den-epoch-güne dönüşüm) Howard Hinnant'ın `days_from_civil`i GİBİ
  AYRI bir algoritma GEREKTİRİRDİ — birincil kullanım durumu (`nox.time.
  now()` İLE ŞU ANKİ tarihi/saati GÖRÜNTÜLEMEK) yalnızca AYRIŞTIRMA
  gerektirdiğinden v1 kapsamı DIŞINDA bırakıldı.
- Yalnızca 1970 VE SONRASI (`std.time.epoch.EpochSeconds` `u64` alır,
  negatif epoch-ms DESTEKLENMEZ).
- **PRE-EXISTING, stdlib-genelinde bir sınırlamanın YENİ bir örneği:**
  `nox.http.HttpResponse`/`nox.json.JsonValue` GİBİ, `DateTime` de TİP
  ANNOTASYONU olarak KULLANILDIĞINDA `nox.time.DateTime` DEĞİL, MANGLED
  adıyla (`nox_time_DateTime`) yazılmalıdır (Alt-Faz O'nun bilinçli
  kapsam DIŞI notu — "Tek bir proje İÇİNDE birden fazla İLK-TARAF `.nox`
  dosyasının BİRBİRİNİ import etmesi... bu planda TASARLANMADI" İLE AYNI
  KATEGORİDEKİ, `import` sisteminin NOKTALI TİP ANNOTASYONU sözdizimini
  HENÜZ DESTEKLEMEMESİ gerçeği) — `nox.time.from_epoch_ms(...)`in
  DÖNÜŞ DEĞERİNİ bir DEĞİŞKENE bağlamak İSTEYEN bir kullanıcı `dt:
  nox_time_DateTime = nox.time.from_epoch_ms(...)` yazmalıdır. Bu, V.4'ün
  KENDİSİNİN GETİRDİĞİ bir kısıt DEĞİL — TÜM stdlib sınıflarının ORTAK,
  ÖNCEDEN VAR OLAN bir kısıtıdır (BURADA yalnızca YENİ bir somut örnekle
  KARŞILAŞILDI).

**Doğrulama:**
1. **1 uçtan-uca golden test** (`time_datetime_from_epoch_ms.nox`): bilinen
   bir epoch-ms değerinin (`1700000000000`) DOĞRU takvim bileşenlerine
   ayrıştığını (`2023-11-14 22:13:20`, Python'un `datetime.utcfromtimestamp`ı
   İLE ÇAPRAZ doğrulandı) VE `now()`in makul (`year >= 2024`) bir sonuç
   ürettiğini kanıtlar.
2. **Kasıtlı boz→kırmızı→düzelt:** `nox_time_day_raw`nin 0-tabandan
   1-tabana çeviren `+1` GEÇİCİ olarak KALDIRILDI → `zig build test` "91
   pass, 1 fail (92 total)" / "339/340 tests passed" GÖSTERDİ (gün "14"
   yerine "13" BASILDI — KLASİK bir off-by-one) — geri getirildi, 340/340
   YEŞİLE döndü (Debug VE ReleaseFast).

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.33 Faz V.5 — `nox.test` Genişletmesi (Setup/Teardown, JUnit XML)

**Kapsam:** MEVCUT `raise`-tabanlı `assert_eq_int`/`assert_eq_str`/
`assert_eq_float`/`assert_true` (bkz. §K, DEĞİŞMEDEN kalır — basit
betikler İÇİN) YANINDA, YENİ bir `TestSuite` sınıfı + `check_eq_int`/
`check_eq_str`/`check_eq_float`/`check_true` metodları + `write_junit_xml`
serbest fonksiyonu. TAMAMEN saf Nox (`nox.fs`/`nox.strings` üzerine).

**"Setup/teardown desteği"nin TAM ANLAMI (Nox'un kısıtları İÇİNDE
YORUMLANDI):** Nox'ta first-class fonksiyon REFERANSLARI YALNIZCA iç içe
`def`den İNŞA EDİLEN closure'lardır (bkz. Faz U.4) — üst-düzey bir `def`e
ÇIPLAK bir referans YOK, bu yüzden OTOMATİK/reflection-tabanlı "her testten
ÖNCE/SONRA bunu ÇALIŞTIR" kaydı (ör. pytest'in fixture'ları) KAPSAM DIŞI
bırakıldı. Bunun yerine: `check_*` metodları `assert_*`nin AKSİNE HİÇBİR
ZAMAN `raise` ETMEZ — SONUCU (`pass_count`/`fail_count` + biriken bir XML
gövdesi) BİRİKTİRİR. Bu, KULLANICININ KENDİ yazdığı `setup()`/`teardown()`
fonksiyonlarının HER `check_*` çağrısının ETRAFINA AÇIKÇA yerleştirilmesini
sağlar — TEK bir başarısız kontrol ARTIK geri kalan kodu (teardown DAHİL)
DURDURMAZ (bir `assert_*`nin, `raise` ile TÜM programı sonlandırmasının
AKSİNE).

**`list[T]` KULLANILMADI (bilinçli, KRİTİK bir kısıt keşfedildi):** Nox'ta
BOŞ bir `list[T]` literali DESTEKLENMEZ (`[]`, tipi çıkarılamadığından —
bkz. checker.zig'in `.list_lit` dalı, "boş liste literalinin tipi
çıkarılamaz") — BAŞLANGIÇTA boş, HER `check_*` çağrısında büyüyen bir
sonuç KOLEKSİYONU bu yüzden `list[T]`YLE ifade EDİLEMEZ (Alt-Faz F'nin
"büyütülebilir/`append`li bir `list[T]`, DERLEME ZAMANINDA bilinen bir
İLK boyut GEREKTİRİR" notuyla AYNI KÖK kısıt). Bunun yerine SAYAÇLAR
(`pass_count`/`fail_count: int`) + BİRİKTİRİLEN bir XML gövde `str`i
(`""` BOŞ string literali İLE BAŞLAR — `list_lit`in AKSİNE `str` İÇİN BU
KISIT YOK, `nox.log`un/`nox.test`in KENDİSİNİN ZATEN kanıtladığı gibi)
KULLANILIR.

**Doğrulama:**
1. **1 uçtan-uca golden test** (`test_suite_setup_teardown_junit.nox`):
   DÖRT `check_*` çağrısı (biri BİLEREK BAŞARISIZ) — HER BİRİNİN ÖNCESİNDE/
   SONRASINDA `setup()`/`teardown()` çağrılır VE HEPSİ, ARADAKİ başarısız
   kontrole RAĞMEN çalışır (bu, "setup/teardown desteği"nin İDDİASININ
   KENDİSİNİ KANITLAR); doğru `pass_count`/`fail_count`/`total_count`/
   `all_passed`; `write_junit_xml` + `nox.fs.read_to_string` İLE GERİ
   OKUNAN JUnit XML raporunun TAM İÇERİĞİ (Python'un `xml.etree.
   ElementTree`ı İLE BAĞIMSIZ olarak da GEÇERLİ-XML olduğu doğrulandı).
2. **Kasıtlı boz→kırmızı→düzelt:** `_record`in `passed == True` dalındaki
   sayaç ARTIRIMI GEÇİCİ olarak `self.fail_count` (YANLIŞ sayaç) ARTIRACAK
   ŞEKİLDE değiştirildi → `zig build test` "92 pass, 1 fail (93 total)" /
   "340/341 tests passed" GÖSTERDİ (`pass_count=0`/`fail_count=4` — TÜM
   BAŞARILI kontroller YANLIŞ sayaca YAZILDI) — geri getirildi, 341/341
   YEŞİLE döndü (Debug VE ReleaseFast).

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.34 Faz V.6 — `nox.regex` Modülü (Temel Desen Eşleştirme)

**Kapsam ve BİLİNÇLİ SINIRLAMA — TAM bir regex motoru DEĞİL:** `is_match(pattern,
text) -> bool` / `find(pattern, text) -> int`. Zig'in KENDİSİ (`nox.crypto`/
`nox.json`nin AKSİNE) hiçbir regex ilkeli SAĞLAMADIĞINDAN (`std`da regex YOK),
Brian Kernighan'ın KAMUYA MAL OLMUŞ, KLASİK minimal geri-izlemeli (backtracking)
regex algoritmasının (`"Beautiful Code"`/`"The Practice of Programming"`)
GENİŞLETİLMİŞ bir versiyonu (`runtime/stdlib_shims/regex.zig`) YAZILDI —
`nox.json`nin "sıfırdan KARMAŞIK bir algoritma İCAT ETME" ilkesiyle AYNI
RUHTA, ama BURADA "battle-tested bir KÜTÜPHANE SAR" SEÇENEĞİ YOK OLDUĞUNDAN,
İYİ BİLİNEN/KÜÇÜK/doğruluğu KOLAY doğrulanabilir BİR ALGORİTMA seçildi.

**Desteklenen sözdizimi:** literal karakterler, `.` (herhangi bir karakter),
`*`/`+`/`?` (ÖNCEKİ atomun 0-veya-fazla/1-veya-fazla/0-veya-1 tekrarı,
AÇGÖZLÜ/greedy — eşleşme bulunana KADAR geri ÇEKİLEREK), `^`/`$` (başlangıç/
bitiş çapaları), `[abc]`/`[a-z]`/`[^abc]` (karakter sınıfları, ARALIK VE
olumsuzlama DAHİL).

**Desteklenmeyenler (bilinçli v1 kapsam DIŞI, HER BİRİ AYRI bir mühendislik
turu GEREKTİRİRDİ):** gruplama (`(...)`), yakalama grupları, alternasyon
(`a|b`), geri-referanslar (`\1`), `{m,n}` sayısal tekrar sözdizimi, escape
dizileri (`\d`/`\w`/`\s` vb.). Birincil hedeflenen kullanım durumları
(bir dosya adının bir uzantıyla BİTİP bitmediğini, bir metnin YALNIZCA
rakam İÇERİP içermediğini KONTROL etmek) yukarıdaki alt küme İLE TAM
olarak karşılanır.

**Mimari — SKALER argüman/dönüş, `with_rt` GEREKMEZ:** `is_match`/`find`
yalnızca `int`/`bool` alır/döner (ARC-dışı, `nox.math`nin `sqrt`/`pow`si
İLE AYNI kategori). Algoritma, atom-tabanlı bir `matchHere`/`atomMatches`
çiftine dayanır (`atomLen`, bir literal/`.`/`[...]`in bayt uzunluğunu
hesaplar; `atomMatches`, TEK bir karakterin O atomla eşleşip eşleşmediğini
kontrol eder) — `*`/`+` İÇİN ÖNCE AÇGÖZLÜCE mümkün olduğunca çok atom
TÜKETİLİR, SONRA (eşleşme bulunana KADAR) TEK TEK geri ÇEKİLİR (klasik
backtracking).

**Doğrulama:**
1. **9 embedded Zig birim testi** (`runtime/stdlib_shims/regex.zig`nin
   KENDİSİNDE, Faz U.4.1'in `refAllDeclsRecursive` düzeltmesi SAYESİNDE
   `zig build test`in GERÇEKTEN çalıştırdığı) — literal, `.`, `*`, `+`,
   `?`, `^`/`$`, karakter sınıfları (aralık + olumsuzlama DAHİL), `find`in
   doğru İNDEKS döndürdüğü.
2. **1 uçtan-uca golden test** (`regex_basic_patterns.nox`): `is_match`/
   `find`in yukarıdaki TÜM sözdizimi ÖZELLİKLERİNİ Nox tarafından ÇAĞRILAN
   HALİYLE de doğru çalıştığını kanıtlar.
3. **Kasıtlı boz→kırmızı→düzelt:** `?` niceleyicisinin "atomu ATLA" dalı
   GEÇİCİ olarak KALDIRILDI (`?` fiilen `?`nin KENDİSİ İÇİN ZORUNLU hâle
   GELDİ, "sıfır tekrar" durumu KAYBOLDU) → `zig build test` "93 pass, 1
   fail (94 total)" (embedded Zig testi) VE "348/350 tests passed" (İKİ
   AYRI test ADIMI — embedded regex.zig testleri VE golden test SÜİTİ —
   HER İKİSİ de BAĞIMSIZ olarak YAKALADI, "colou?r" vs "color" ARTIK
   eşleşmiyordu) — geri getirildi, TÜM testler YEŞİLE döndü (Debug VE
   ReleaseFast).

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.35 Faz W.1 — Tree-sitter Grameri (`editors/tree-sitter-nox`)

**Kapsam ve konum:** Faz V (V.1-V.6, `nox.log`/`nox.random`/`nox.crypto`/
`nox.time` genişlemesi/`nox.test` genişlemesi/`nox.regex`) TAMAMLANDIKTAN
sonra dil olgunluğu açısından NİTELİKSEL bir eşiğe ULAŞILDI — bir sonraki
adım (Faz W, "editör/araç desteği") derleyicinin/runtime'ın KENDİSİNE
DOKUNMAZ, `editors/tree-sitter-nox/` altında TAMAMEN AYRI, bağımsız bir
alt-proje olarak yaşar (JavaScript/C — Zig derleyici koduyla HİÇBİR
BAĞIMLILIĞI YOK, `zig build test`i ETKİLEMEZ). Amaç: sözdizimi vurgulama +
gelecekteki minimal LSP'nin (W.2) ayrıştırma temeli.

**Neden HARİCİ bir C tarayıcısı (`src/scanner.c`) GEREKTİ:** Nox'un girinti
modeli (bkz. `compiler/lexer/lexer.zig`) Python'un INDENT/DEDENT/NEWLINE
tokenizasyonuyla AYNI — bu, bağlamsız (context-free) bir gramerle İFADE
EDİLEMEZ (girinti derinliği bir YIĞIN gerektirir). `src/scanner.c`,
[tree-sitter-python](https://github.com/tree-sitter/tree-sitter-python)nun
(MIT lisanslı) KANITLANMIŞ NEWLINE/INDENT/DEDENT algoritmasından
UYARLANMIŞTIR (`nox.regex`nin Kernighan algoritmasını uyarlaması İLE AYNI
"sıfırdan İCAT ETME yerine KANITLANMIŞ bir algoritmayı UYARLA" ilkesi) —
Nox'un DAHA BASİT olduğu yerler (üçlü-tırnak/f-string/ham/bytes string YOK,
Python'ın `except*`/soft-keyword karmaşıklığı YOK) BİLİNÇLİ olarak
BUDANMIŞTIR. Kapanış parantezlerinin (`)`/`]`/`}`) `externals`e (ama HİÇBİR
ZAMAN doğrudan üretilmeden) dahil edilmesi, tarayıcının `within_brackets`
sinyalini (ayrıştırıcı durumunun bir kapanış parantezi BEKLEYİP
beklemediği) okuyup parantez İÇİNDE YANLIŞLIKLA bir DEDENT üretmesini
ENGELLEMESİNİ sağlar — python'ın gramerinden BİREBİR aynı mekanizma
(anlamsız satır sonları `\n`nin `extras`e DAHİL edilmesiyle BİRLİKTE
çalışır: parantez içindeyken ayrıştırıcı durumu `_newline`i GEÇERLİ
saymadığından tarayıcı sessizce `false` döner, dahili sözlüksel çözümleyici
`\n`i sıradan boşluk olarak yutar).

**Gramer kapsamı — GERÇEK derleyici sözdiziminin NEREDEYSE TAMAMI:**
girinti-duyarlı bloklar, `def`/`class`/`protocol`/`extern def ... with_rt`/
`lowlevel`, `if/elif/else`, `while`/`for`, `try/except/finally`, `with`,
`raise`, `import`/`from...import`, generic tip parametreleri
(`def f[T](...)`), fonksiyon tip ifadeleri (`(int) -> int`, bkz. Faz
U.4.1), `async`/`await`/`spawn`, `list[T]`/`dict[K,V]` literalleri.
Operatör öncelik sırası (`or < and < not < karşılaştırma < +/- < */÷ <
tekli < üs < postfix`) `compiler/parser/parser.zig`nin precedence-climbing
zinciriyle BİREBİR AYNI sırayla `PREC` tablosuna kodlanmıştır.

**Bilinçli sadeleştirmeler (v1 kapsamı DIŞI — bir editör aracı İÇİN
gereksiz ayrıntı, gerçek derleyicinin DOĞRULUĞUNU HİÇBİR ŞEKİLDE
ETKİLEMEZ, bkz. `editors/tree-sitter-nox/README.md`nin AYNI notu):**
`Channel[T](capacity)`nin dilde YALNIZCA `Channel` için ayrılmış açık tip
argümanlı kurucu sözdizimi (bkz. `parser.zig`nin `isGenericConstructName`i)
AYRI bir düğüm türü olarak modellenmez — sıradan iç içe `index`+`call`
olarak ayrıştırılır (semantik olarak YANLIŞ değil, yalnızca DAHA AZ
ÖZGÜL); string literalleri tek satırla SINIRLANDIRILMIŞTIR (gerçek lexer
teknik olarak çok satırlı bir string'i REDDETMEZ ama pratikte HİÇ
KULLANILMAZ); TAB girintisi 8 sütunluk BOŞLUK gibi SAYILIR (gerçek
derleyici TAB'ı TAMAMEN REDDEDER — `TabsNotAllowed`).

**Doğrulama — golden-test disiplininin bu ARAÇ İÇİN eşdeğeri:**
1. `test/corpus/basics.txt` — deyimlerin/ifadelerin/tiplerin TAMAMINI
   (değişken bildirimi, fonksiyon/sınıf/protokol tanımı, TÜM kontrol akışı
   yapıları, `with`/`lowlevel`/`async`/`spawn`/`await`, `extern def ...
   with_rt`, `import`/`from...import`, liste/sözlük literalleri, generic
   fonksiyon) TEK bir kaynak dosyasında kapsayan bir `tree-sitter test`
   regresyon testi — `npm test` İLE YEŞİL.
2. **Repodaki HER GERÇEK `.nox` dosyasına karşı sıfır-hata ayrıştırma** —
   `stdlib/` (18 dosya), `benchmarks/` (23 dosya, `compare/` HARİÇ), VE
   `tests/golden/**/*.nox` (160 dosya) — TOPLAM **201 dosya**, HİÇBİRİNDE
   `ERROR` düğümü OLUŞMADI (`tree-sitter parse` çıktısı programatik olarak
   tarandı). Bu, derleyicinin KENDİ golden-test SÜİTİNİN (`zig build test`)
   BAĞIMSIZ bir "ikinci gözlemci" DOĞRULAMASI olarak İŞLEV görür — gerçek
   Nox kaynak kodunun (elle yazılmış TEST senaryoları DAHİL) grameri
   HİÇBİR ŞEKİLDE ŞAŞIRTMADIĞINI kanıtlar.
3. `queries/highlights.scm` — standart tree-sitter yakalama adlarını
   (`@keyword`/`@function`/`@type`/`@string`/... bkz. Neovim/Helix/Zed'in
   VARSAYILAN tema eşlemesi) kullanan bir sözdizimi vurgulama sorgusu,
   `tree-sitter query` İLE derleme-zamanı DOĞRULANDI (2 gerçek hata
   BULUNUP DÜZELTİLDİ — bkz. aşağı).
4. Node.js NATIVE eklentisi (`binding.gyp`/`bindings/node/binding.cc`)
   `node-gyp-build` İLE BAŞARIYLA DERLENDİ (gerçek editör entegrasyonlarının
   — Neovim/Zed/Helix — kullandığı YOL bu DEĞİL, onlar `.so`/WASM'ı DOĞRUDAN
   yükler, ama npm paket dağıtımı İÇİN standart yol budur).
   **Bilinen sınırlama:** bu OTURUMDA kullanılan `tree-sitter` npm ÇALIŞMA
   ZAMANI paketinin (0.22.x/0.25.x) native eklentisi bu ortamdaki Node.js
   v26 İLE UYUMSUZ çıktı (0.25.x derleme HATASI verdi, 0.22.x derlendi
   ama `Parser.setLanguage`in KENDİ dahili native köprüsü ABI 15 gramerini
   TANIMADI) — bu, **grameri DEĞİL, üçüncü-taraf `tree-sitter` npm
   paketinin bu ortamdaki Node sürümüyle UYUMLULUĞUNU** etkileyen, bilinen/
   dokümante EDİLMİŞ bir SINIRLAMADIR (gerçek editörler bu npm paketini
   KULLANMAZ). Grameri doğrulayan ASIL mekanizma (madde 1-3) BU
   sınırlamadan TAMAMEN BAĞIMSIZDIR.

**Bulunan/düzeltilen gerçek hatalar (implementasyon sırasında, COMMIT
edilmeden ÖNCE yakalandı):**
- `binary_expression` kuralının `.map(([op, prec]) => ...)` yardımcı
  fonksiyonunda döngü değişkeni `prec` adı, MODÜL seviyesindeki `prec()`
  fonksiyonunu (tree-sitter DSL'in KENDİSİ) GÖLGELEDİ — `pass_statement`
  İLE AYNI KATEGORİDE bir isim çakışması, `tree-sitter generate` ÇALIŞMA
  ZAMANI hatasıyla (`prec.left is not a function` benzeri) YAKALANDI,
  değişken `p` olarak yeniden ADLANDIRILDI.
- `highlights.scm`de `"pass" @keyword` — `pass_statement: $ => 'pass'`
  kuralı TREE-SITTER tarafından "tek-çocuklu" bir üretim olarak
  OPTİMİZE EDİLDİĞİNDEN, anonim `"pass"` düğümü node-types.json'da HİÇ
  YER ALMAZ (yalnızca `pass_statement` ADLI düğüm VARDIR) — `tree-sitter
  query` derleme HATASIYLA ("Invalid node type 'pass'") YAKALANDI,
  `(pass_statement) @keyword`e DÜZELTİLDİ. AYNI kategoriden İKİNCİ bir
  hata: `(_type_expression (identifier) @type)` — `_type_expression`
  ALT ÇİZGİYLE BAŞLADIĞINDAN (gizli/inline kural) hiçbir zaman GERÇEK bir
  düğüm olarak var OLMAZ, doğrudan çocuğuna İNDİRGENİR — AYNI hata
  mesajıyla yakalanıp alanlara-özgü (`parameter type:`/`var_declaration
  type:`/`function_definition return_type:` vb.) somut eşleşmelerle
  DEĞİŞTİRİLDİ.

`npx tree-sitter test` yeşil (1/1), tüm 201 gerçek `.nox` dosyası sıfır-hata
ile ayrıştırılıyor, `zig build test` (Debug + ReleaseFast, ANA derleyici —
bu fazdan HİÇ ETKİLENMEDİĞİ doğrulandı) yeşil.

---

## 3.36 Faz W.2 — Minimal LSP Sunucusu (`noxlsp`, `compiler/lsp_main.zig`)

**Kapsam ve konum — Faz W.1'in AYNI ilkesi:** `editors/tree-sitter-nox`
(JS/C, derleyiciden BAĞIMSIZ) İLE TEZAT OLARAK, `noxlsp` **Zig'de, `noxc`
İLE AYNI derleme birimi İÇİNDE** yaşar (`compiler/lsp_main.zig`, yeni bir
`b.addExecutable` hedefi) — çünkü W.1'in AKSİNE, burada gerçek AMAÇ
derleyicinin KENDİSİNİ (lexer→parser→checker) **YENİDEN UYGULAMAK DEĞİL,
DOĞRUDAN KÜTÜPHANE OLARAK ÇAĞIRMAK**. Bu, "editör aracı derleyiciyi asla
yeniden uygulamaz" ilkesinin W.1'den DAHA GÜÇLÜ bir versiyonu — W.1 KANITLANMIŞ
bir ÜÇÜNCÜ TARAF algoritmasını (tree-sitter-python'ın tarayıcısı) UYARLAMAK
ZORUNDAYDI (Zig'den JS/C'ye taşınamaz), ama `noxlsp` HİÇBİR ŞEYİ yeniden
YAZMAZ — `compiler/lib.zig`nin ZATEN dışa açtığı `lexer`/`parser`/`checker`/
`module_loader`/`project` modüllerini OLDUĞU GİBİ ÇAĞIRIR.

**Bilinçli v1 kapsamı — YALNIZCA `textDocument/publishDiagnostics`:**
`initialize`/`initialized`/`shutdown`/`exit` + `textDocument/didOpen`/
`didChange`/`didClose`. `hover`/`completion`/`definition`/`rename`/`format`
gibi TÜM diğer LSP yetenekleri BİLİNÇLİ olarak DIŞARIDA bırakıldı — görev
adının ("Minimal LSP") TAM OLARAK ifade ettiği gibi. `textDocumentSync`
YALNIZCA `Full` (1) modunu destekler — artımlı (range-tabanlı) senkronizasyon
YOK, HER `didChange` TÜM belge metnini taşır (basitlik, `didOpen` İLE AYNI
`storeDocument` yoluna GİRER).

**Mimari:**
1. **Aktarım:** LSP'nin standart `Content-Length: N\r\n\r\n<N bayt>` stdio
   çerçevelemesi. `std.json.Value` (dinamik ağaç) İLE ayrıştırma, `std.json.
   Stringify.value` İLE yazma — düzinelerce tipli LSP struct şeması YAZILMAZ,
   yalnızca GERÇEKTEN işlenen alanlar (`method`/`id`/`params.textDocument.
   uri`/`.text`/`params.contentChanges[].text`) okunur.
2. **Belge deposu:** `Server.documents: std.StringHashMapUnmanaged([]const
   u8)` (URI → metin, HER ikisi de `gpa` üzerinde sahiplenilir) — `nox.http`
   sunucusunun bağlantı durumu YÖNETİMİYLE AYNI "her isteğin/bildirimin
   KENDİ ARENA'sı, uzun ömürlü durum AYRI bir kalıcı allocator'da" deseni.
3. **Tanılama hesaplama** (`computeDiagnostics`): `lexer.tokenize` →
   `parser.parseModule` → (VARSA `project.resolveResourceDirs`in çözdüğü
   `stdlib_dir` ÜZERİNDEN) `module_loader.resolveImportsFrom` → `checker.
   Checker.init`/`checkModule`. Lex/parse BAŞARISIZ olursa TEK bir (konumsuz)
   tanılamayla ERKEN DÖNER; checker'ın (Faz T.2) `diagnostics` LİSTESİNİN
   TAMAMI (birden fazla FONKSİYON/SINIF/METOD sınırındaki hata, bkz.
   checker.zig'in KENDİ "çoklu-tanılama" notu) LSP tanılamalarına ÇEVRİLİR.
4. **`resolveImportsFrom` ASLA `process.exit` ÇAĞIRMAZ** (bu, `noxc`nin
   KENDİ CLI sarmalayıcısı `resolveImportsForBuild`in DAVRANIŞIDIR, `module_
   loader.zig`nin KENDİSİ DEĞİL) — bu YÜZDEN `noxlsp`nin UZUN ÖMÜRLÜ süreci
   İÇİN GÜVENLE DOĞRUDAN çağrılabilir; `LoadError` HER ZAMAN yakalanıp HAM
   (birleştirilmemiş) modüle DÜŞÜLÜR.

**Bilinen sınırlamalar (BİLİNÇLİ, dokümante edilmiş — v1 kapsamı):**
- **Sütun bilgisi YOK:** `ast.Stmt.line`/`checker.Diagnostic.line` (Faz T.1/
  T.2) YALNIZCA SATIR taşır — HER tanılamanın `range`i SATIRIN TAMAMINI
  (sütun 0'dan keyfi büyük bir sütuna kadar) kapsar. Lex/parse hataları HİÇ
  konum TAŞIMADIĞINDAN (bkz. `LexError`/`ParseError`nin KENDİSİ bir Zig
  hata KÜMESİ, payload YOK) 1. satıra SABİTLENİR.
- **Proje-farkında `requires[]`/proje-içi çoklu-dosya import ÇÖZÜLMEZ:**
  yalnızca `nox.*` stdlib importları çözülür — `nox.json`nin `requires[]`i
  (Faz O §P.6) VEYA proje-içi çoklu-dosya importu (Faz U.2) GEREKTİREN
  dosyalar İÇİN "tanımsız fonksiyon" TÜRÜNDE YANLIŞ-POZİTİF tanılamalar
  OLUŞABİLİR — sunucu ÇÖKMEZ, yalnızca EKSİK bağlamla çalışır.
- Tek belge İÇİN çalışır — çapraz-dosya (bir dosyadaki değişikliğin
  BAŞKA bir dosyanın tanılamalarını NASIL etkilediği) analiz YOK.

**Bulunan/düzeltilen gerçek hata (implementasyon sırasında, COMMIT
edilmeden ÖNCE yakalandı) — `std.Io.Reader.takeDelimiterExclusive` delimiter'ı
TÜKETMEZ:** `readMessage`in başlık-ayrıştırma döngüsü İLK yazımda `r.
takeDelimiterExclusive('\n')` kullanıyordu — bu fonksiyonun KENDİ belge notu
AÇIKÇA "advancing the seek position up to (but **not past**) the delimiter"
der (Python'ın `str.split`iyle SEZGİSEL olarak ÇELİŞEN bir davranış: "exclusive"
sıfatı yalnızca DÖNEN DİLİMİN delimiter'ı İÇERMEDİĞİ anlamına gelir, OKUMA
KONUMUNUN da delimiter'ı ATLAYACAĞI anlamına GELMEZ). Sonuç: HER başlık
satırından SONRA `\n` karakteri BUFERDE KALDI — İKİNCİ (boş) başlık satırı
okunduğunda AYRIŞTIRICI hâlâ İLK satırın `\n`sinin HEMEN ÖNÜNDE duruyordu,
`trimmed.len == 0` YANLIŞLIKLA doğru oldu (0 bayt EN'de bir eşleşme), döngü
BİR satır ERKEN kapandı — `readAlloc(len)` bu YÜZDEN gövdeyi YANLIŞ konumdan
(gerçek JSON'dan 3 bayt ÖNCE, `\n\r\n` artıklarıyla) okudu ve TAM OLARAK
`content_length` kadar bayt tükettiğinden gövdenin SON 3 baytı ("`{}}`")
OKUNMADAN kaldı — `std.json.parseFromSlice` bu YÜZDEN `error.
UnexpectedEndOfInput` verdi, VE artık bayt SONRAKİ mesajın başlığı gibi
YANLIŞ yorumlandı (tam bir "kaydırma" hatası). **Keşif yöntemi:** `tests/
cli/lsp_test.zig` (bkz. aşağı) İLK çalıştırmada `zig build test`in TAMAMINI
askıya ALDI (SIGKILL İLE sonlandırılması GEREKTİ) — kök neden, `noxlsp`
BİNARİSİNİN çıplak stdio'suna elle hazırlanmış bir `printf` çerçevesi
BESLENEREK (`xxd` İLE bayt-bayt DOĞRULANARAK) İZOLE edildi, GEÇİCİ `std.
debug.print` satırlarıyla (başlık satırı BAŞINA, gövde İÇERİĞİ) TAM olarak
hangi baytların KAYIP OLDUĞU GÖRÜLDÜ. **Düzeltme:** `takeDelimiterInclusive`
(delimiter'ı HEM DÖNEN dilime DAHİL EDER HEM DE OKUMA KONUMUNU ONUN ÖTESİNE
İLERLETİR) + `trimEnd(line, "\r\n")` (hem `\r` HEM `\n`i temizler, `takeDelimiterExclusive`
kullanan ESKİ kodun yalnızca `\r`yi temizlemesi GEREKİYORDU, `\n` zaten
dilimde YOKTU — `Inclusive`e geçince `\n` ARTIK dilimin SON baytı, o da
temizlenmeli).

**Doğrulama:**
1. **`tests/cli/lsp_test.zig`** — `subcommand_test.zig` İLE AYNI "kurulu
   `zig-out/bin/noxlsp`yi GERÇEK bir alt süreç olarak çalıştır" felsefesi,
   AMA `std.process.run` (tek-atışlık, TAM çıktı yakalayan) YERİNE `std.
   process.spawn` (pipe'lı stdin/stdout, UZUN ömürlü/çift-yönlü protokol
   İÇİN) kullanır. Uçtan uca senaryo: `initialize` (yanıt doğrulanır) →
   `initialized` → tanımsız bir değişken İÇEREN kaynak `didOpen` İLE
   gönderilir → DÖNEN `publishDiagnostics`in checker'ın GERÇEK "tanımsız
   değişken: y" mesajını TAŞIDIĞI doğrulanır → AYNI URI GEÇERLİ bir kaynağa
   `didChange` İLE GÜNCELLENİR → tanılamaların BOŞALDIĞI doğrulanır →
   `shutdown`/`exit` İLE TEMİZ kapanış (çıkış kodu 0) doğrulanır. Bu test
   dosyasının KENDİ `readMessage`i, `lsp_main.zig`ninkiyle KASITLI olarak
   AYNI (ama BAĞIMSIZ kopya) çerçeveleme mantığını kullanır — GERÇEK bir
   istemcinin TELDE ne GÖRECEĞİNİ test eder, sunucunun İÇ fonksiyonunu
   DOĞRUDAN ÇAĞIRMAZ.
2. **Kasıtlı boz→kırmızı→düzelt:** yukarıdaki hatanın DÜZELTMESİ (`Inclusive`
   değişikliği) GERİ ALINIP (`takeDelimiterExclusive`e döndürülerek) `zig
   build test` çalıştırıldı → **350/351 test geçti, YALNIZCA `lsp_test.zig`
   BAŞARISIZ oldu** (`JSON ayristirma hatasi: UnexpectedEndOfInput` —
   TAM OLARAK beklenen/tanı konan hata), BAŞKA HİÇBİR test ETKİLENMEDİ →
   düzeltme GERİ getirildi, TÜM testler (Debug + ReleaseFast) YEŞİLE döndü.
3. `build.zig`nin `test_step`i `install_noxlsp`e bağımlıdır (`install_noxc`
   İLE AYNI, ÖNCEDEN keşfedilmiş "test ALT SÜREÇ olarak ÇALIŞTIRMADAN ÖNCE
   binary YENİDEN KURULMALI" gerekçesiyle) — `noxlsp` HER `zig build test`te
   GERÇEKTEN derlendiği/kurulduğu GARANTİ edilir.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.37 Faz W.3 — DAP/Debugger Entegrasyonu (`editors/vscode-nox`)

**Karar — YENİ bir DAP sunucusu YAZILMADI, bilinçli ve gerekçeli:**
[Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/)
TAMAMEN dilden BAĞIMSIZDIR — bir DAP istemcisi kaynak dosya/satır bilgisini
İKİLİNİN DWARF hat tablosundan ÇÖZER, hata ayıklanan dilin (Nox) SÖZDİZİMİNİ/
SEMANTİĞİNİ HİÇ BİLMESİ GEREKMEZ. Faz T.3 (bkz. §3.17) `noxc build -g` İLE
GERÇEK bir DWARF hat tablosu (`dbgfile`/`dbgloc` → assembler `.file`/`.loc`
→ `.debug_line`) ÜRETTİĞİNDEN, Nox binary'leri **HALİHAZIRDA** olgun, VAR
OLAN DAP sunucularıyla (Apple/LLVM'in resmi `lldb-dap`si, GDB tabanlı
köprüler) UYUMLUDUR — Nox'un KENDİ DAP sunucusunu yazması, W.1'in tree-
sitter-python'ı UYARLAMASI/`nox.regex`nin Kernighan'ın algoritmasını
UYARLAMASI İLKESİNİN DAHA GÜÇLÜ bir versiyonuyla REDDEDİLDİ: burada
UYARLAMAYA bile GEREK YOK — sıfırdan (ya da uyarlanarak) yazılacak bir DAP
sunucusu (kesme noktası yönetimi, süreç kontrolü, çerçeve/scope/değişken
sorguları, adım-atlama semantiği) `noxlsp`den (W.2, YALNIZCA tanılama) ÇOK
DAHA BÜYÜK bir mühendislik yüzeyi olurdu VE `lldb`/`gdb`nin KENDİ SÜREÇ
KONTROLÜ/sembol çözümlemesi mantığını KUSURLU bir şekilde YENİDEN İCAT
etmek anlamına gelirdi.

**Teslim edilen — `editors/vscode-nox/`:**
1. `.vscode/launch.json.example` — [CodeLLDB](https://marketplace.visualstudio.com/items?itemName=vadimcn.vscode-lldb)
   uzantısını (`"type": "lldb"`, DWARF-tabanlı HERHANGİ bir dili
   destekleyen, Nox'a ÖZGÜ OLMAYAN bir VS Code eklentisi) `noxc build -g`
   İLE üretilen ikiliye BAĞLAYAN bir başlatma yapılandırması şablonu.
2. `.vscode/tasks.json.example` — `preLaunchTask` olarak `noxc build -g
   ${file}` çalıştıran görev tanımı.
3. `README.md` — kurulum + T.3'ten DEVRALINAN (YENİ bir kısıt DEĞİL)
   sınırlamaların (yalnızca satır-düzeyi/değişken YOK, macOS bağlı ikili
   DWARF taşımıyor, çoklu-dosya yanlış atıf) AÇIKÇA belgelenmesi.

**Doğrulama — ham DAP protokolü üzerinden, GERÇEK `lldb-dap`e karşı:**
Bu makinede (macOS/aarch64) HALİHAZIRDA kurulu olan (Xcode Command Line
Tools'un bir PARÇASI, HERHANGİ bir şey İNDİRİLMEDİ/KLONLANMADI) `lldb-dap`
ikilisine, LSP'nin (W.2) AYNI temel `Content-Length` çerçevelemesini
kullanan geçici bir Python betiğiyle DOĞRUDAN konuşuldu: `initialize` →
`launch` (`dbgtest.nox`dan `noxc build -g` İLE üretilen GERÇEK bir ikili)
→ `setBreakpoints` (`dbgtest.nox:2`) → `configurationDone` — **DÖRDÜ de
`"success": true` İLE yanıtlandı**, süreç GERÇEKTEN başlatılıp normal
çalışıp ÇIKTI, AMA kesme noktası `"verified": false` OLARAK KALDI ve HİÇ
tetiklenmedi (`stopped` olayı GELMEDİ, program tamamlanana kadar ÇALIŞTI) —
bu, T.3'ün `lldb -b -o "break dbgtest.nox:2" -o run`la (BU FAZDA AYRICA
TEKRAR doğrulandı: `"Breakpoint 1: no locations (pending)"` + `"WARNING:
Unable to resolve breakpoint"`) ZATEN belgelediği macOS sınırlamasıyla
(bkz. T.3 sınırlama 3, Apple `ld`sinin STABS/`N_OSO` GEREKSİNİMİ) TAM
TUTARLI — ŞİMDİ hem KOMUT SATIRI hem DAP PROTOKOLÜ seviyesinde doğrulanmış
oldu. **Linux'ta TAM ÇALIŞTIĞI** (satır-düzeyi kesme noktaları) T.3'ün
KENDİ Docker/gdb doğrulamasıyla ZATEN kanıtlanmıştı; bu FAZ, Linux'un
Debian bookworm `lldb-14` paketinin de bir `lldb-vscode-14` (yani
`lldb-dap`nin ESKİ adı) İÇERDİĞİNİ (`apt-cache policy`/`dpkg -L` İLE)
DOĞRULADI — AMA bu spesifik ikilinin (`lldb-dap` + Linux, gdb'nin AKSİNE)
GERÇEKTEN kesme noktası tetiklediği bu OTURUMDA AYRICA test EDİLMEDİ
(kaynağı harici bir git deposundan derlemeyi/çalıştırmayı gerektiren bir
adım, KULLANICI TARAFINDAN AÇIKÇA yetkilendirilmeden yapılmadı — bkz.
aşağıdaki not) — dürüstçe "beklenen ama AYRICA doğrulanmamış" olarak
işaretlenir.

**Not — kapsam dışı bırakılan bir doğrulama adımı:** Linux/Docker'da SIFIRDAN
QBE derleyip `noxc`yi İNŞA ederek `lldb-dap`in GERÇEK bir kesme noktasını
TETİKLEDİĞİNİ göstermek PLANLANDI (T.3'ün KENDİ Linux/gdb doğrulamasıyla
BİREBİR AYNI derinlikte), AMA bu, HARİCİ bir git deposunu (QBE kaynak kodu)
KLONLAYIP DERLEMEYİ/ÇALIŞTIRMAYI gerektirdiğinden VE kullanıcı BUNU bu
OTURUMDA açıkça YETKİLENDİRMEDİĞİNDEN (güvenlik sınıflandırıcısı TARAFINDAN
ENGELLENDİ) bu adım ATLANDI — yukarıdaki "beklenen ama ayrıca doğrulanmamış"
notu BUNUN İÇİNDİR. T.3'ün KENDİ (ÖNCEKİ bir oturumda, AÇIKÇA yetkilendirilmiş
şekilde yapılan) gdb/Docker doğrulaması HÂLÂ geçerli/yeterli KANIT olarak
kabul edilir — Linux'ta satır-düzeyi hata ayıklamanın ÇALIŞTIĞI ZATEN
KANITLANMIŞTIR, burada YALNIZCA "AYNI DWARF verisini OKUYAN farklı bir DAP
İSTEMCİSİ (`lldb-dap` vs `gdb`)nin de ÇALIŞMASI BEKLENİR" YARGISI EKLENMİŞTİR.

Bu faz `compiler/`/`runtime/`e HİÇBİR değişiklik GETİRMEZ (T.3'ün ZATEN
sağladığı DWARF emisyonu YETERLİDİR) — `zig build test` (Debug + ReleaseFast)
BU FAZDAN ETKİLENMEDİ, DEĞİŞMEDEN yeşil.

---

## 3.38 Faz X.1 — WASM Ayrıştırıcısının LEB128 Varint Okuyucularına Taşma Sınırı

**Kaynak — `docs/uretim-hazirlik-analizi.md` P1 bulgusu #12:** "WASM
ayrıştırıcısında varint taşması — `module.zig`/`interp.zig`'in LEB128
okuyucuları taşma (overflow) SINIRI KONTROL ETMİYOR... bozuk/kötü niyetli
bir `.wasm` dosyası panik/UB tetikleyebilir." Bu, `nox-teknik-spesifikasyon.
md`nin KENDİSİNDE (Faz 13 bölümü) HİÇ belgelenMEMİŞ, YALNIZCA üretim-
hazırlık analiz raporunda kayıtlı bir bulgudur — AGENTS.md §9.5'in AYNI
kaynağı (P0 bulgusu #10, güven sınırı) referans alma DESENİYLE TUTARLI.

**Kök neden — DÖRT bağımsız LEB128 okuyucu, HEPSİ AYNI kusuru
TAŞIYOR:** `runtime/wasm_bridge/module.zig`nin `Reader.readVarU32`/
`readVarI32`si (ikili modül AYRIŞTIRMA — bölüm/vektör boyutları,
indeksler) VE `runtime/wasm_bridge/interp.zig`nin `readVarU32At`/
`readVarI32At`si (bayt kodu YÜRÜTME — `call`/`local.*` indeksleri,
`i32.const` değeri) — HEPSİ `shift: u5` (`u32` genişliğine göre "yeterli"
varsayılan bir tip) İLE bir döngüde `shift += 7` YAPIYORDU, bayt SAYISINA
HİÇBİR ÜST SINIR KOYMADAN. Bir `u32`nin GEÇERLİ LEB128 kodlaması EN FAZLA
5 bayt sürer (5×7=35 ≥ 32 bit) — AMA bozuk/kötü niyetli bir `.wasm`, ART
ARDA devam biti (`0x80`) TAŞIYAN 6+ bayt SAĞLARSA, 5. bayttan SONRAKİ
`shift += 7` çağrısı `shift`i 28'den 35'e TAŞIR — `u5`in maksimum değeri
31 OLDUĞUNDAN bu bir TAMSAYI TAŞMASIDIR: güvenli derlemelerde (Debug/
ReleaseSafe) **panik** (DoS — bozuk bir `.wasm` dosyası okuyan HERHANGİ
bir Nox programını ÇÖKERTİR), güvensiz derlemelerde (ReleaseFast/
ReleaseSmall) **TANIMSIZ DAVRANIŞ**.

**Düzeltme — ÜÇ katmanlı, `docs/uretim-hazirlik-analizi.md`nin İSTEDİĞİ
"taşma SINIRI" tam olarak karşılanacak şekilde:**
1. **Bayt SAYISI 5 İLE SINIRLANIR:** yeni bir `nbytes: u8` sayaç, döngünün
   HER turunda `if (nbytes >= 5) return error.InvalidModule` (`module.zig`)
   / `error.Trap` (`interp.zig`, `InterpError`nin MEVCUT bir üyesi, WASM'ın
   KENDİ "çalışma zamanı hatası" terminolojisiyle TUTARLI) — 6. devam
   baytına ULAŞMADAN reddeder.
2. **Birikim `u64`/`i64`de yapılır (`shift: u5` → `u6`):** `shift`in
   KENDİSİ bir daha ASLA taşmaz (5 bayt İÇİN maksimum `shift=28`, döngü
   İÇİNDEKİ SON artırım `35`e ULAŞSA BİLE `u6` (maks 63) bunu RAHATÇA
   TAŞIR) — `<<` işleci de ARTIK `u32`/`i32`nin dar sınırlarına ÇARPMAZ.
3. **SONUÇ hedef genişliğe SIĞMA doğrulaması:** döngü BİTTİKTEN SONRA
   (`u32` İÇİN `result > maxInt(u32)`, `i32` İÇİN `result` `[minInt(i32),
   maxInt(i32)]` DIŞINDAYSA) `error.InvalidModule`/`error.Trap` döner —
   bu, KANONİK-OLMAYAN bir kodlamayı (son baytın hedef genişliğin ÖTESİNDE
   ANLAMLI bit TAŞIDIĞI durumu, ör. `[0xff,0xff,0xff,0xff,0x1f]`, YALNIZCA
   BİR bit fazla — `0x0f` OLMALIYDI) SESSİZCE KIRPMAK YERİNE REDDEDER.
   **Katman 1 VE 3 BİRBİRİNİ TAMAMLAR, BİRİ DİĞERİNİN YERİNE GEÇMEZ:**
   TÜM sıfır-payload'lu (ör. `[0x80]×5 + [0x00]`) 6+ baytlık bir kodlama
   `result=0` üretir — bu KESİNLİKLE `maxInt(u32)`yi AŞMADIĞINDAN, YALNIZCA
   Katman 3'ün (sığma kontrolü) VARLIĞI BU DURUMU YAKALAYAMAZ, Katman 1'in
   (bayt-sayısı sınırı) AYRICA GEREKLİ olduğunu KANITLAR (bkz. aşağıdaki
   test tasarımı notu).

**Test tasarımı NOTU (İKİNCİ bir gerçek hata, implementasyon SIRASINDA
yakalandı):** İLK yazılan "6+ devam baytı taşma sınırına takılır" testi
`[0x80,0x80,0x80,0x80,0x80,0x01]` kullanıyordu — bu vektör YANLIŞLIKLA
Katman 3'ü (sığma kontrolü) DE tetikliyordu (6. bayt `0x01`, `1<<35`i
KATkıyor, bu da `maxInt(u32)`yi ZATEN AŞIYOR) — bu YÜZDEN bayt-sayısı
sınırı (Katman 1) KASITLI olarak DEVRE DIŞI BIRAKILDIĞINDA (`if (false)
return error...`) test HÂLÂ YEŞİL KALIYORDU (Katman 3 BAĞIMSIZ olarak
YAKALADIĞI İÇİN) — bu, `break→kırmızı→düzelt` RİTÜELİ SIRASINDA (bkz.
AGENTS.md İlke #7) KEŞFEDİLDİ VE test vektörü `[0x80,0x80,0x80,0x80,0x80,
0x00]` (TÜM payload SIFIR, `result=0` üretir — YALNIZCA Katman 1'in
YAKALAYABİLECEĞİ bir durum) OLARAK DÜZELTİLDİ — bu düzeltmeden SONRA
kasıtlı boz TEKRARLANDI, ÜÇ test (module.zig'in ikisi + interp.zig'in
birleşik testi) DOĞRU şekilde KIRMIZIYA DÖNDÜ, geri getirildi.

**Doğrulama:**
1. **8 yeni birim testi** (`module.zig`de 6, `interp.zig`de 2): kanonik
   değerlerin (0/127/128/300/`maxInt(u32)`, imzalı İÇİN 0/-1/127/-128)
   DOĞRU çözüldüğü + 6+ bayt taşma sınırının + kanonik-olmayan (aşırı
   büyük son bayt) kodlamanın REDDEDİLDİĞİ.
2. **Kasıtlı boz→kırmızı→düzelt** (İKİ turda, yukarıdaki test-tasarımı
   notuna bkz.): bayt-sayısı sınırı (`if (nbytes >= 5) return error...`)
   HER İKİ dosyada da (`module.zig`nin İKİ fonksiyonu + `interp.zig`nin
   İKİ fonksiyonu) `if (false) return error...`e ÇEVRİLDİ → `zig build
   test`: **355/358 test geçti, TAM OLARAK 3 test BAŞARISIZ oldu**
   (`readVarU32`/`readVarI32`nin `module.zig` testleri + `interp.zig`nin
   birleşik testi) — `"expected error.InvalidModule/Trap, found 0"`,
   TAM OLARAK beklenen hata; BAŞKA HİÇBİR test ETKİLENMEDİ. Düzeltme
   GERİ getirildi, TÜM testler (Debug + ReleaseFast) YEŞİLE döndü.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.39 Faz X.2 — `tests/fuzz/` Doldurma (Fuzzing Altyapısı)

**Kaynak — `docs/uretim-hazirlik-analizi.md`:** "X.2 — `tests/fuzz/`i
DOLDUR: lexer/parser/checker + WASM ayrıştırıcısı İÇİN libFuzzer/AFL
tabanlı fuzz hedefleri."

**Karar — libFuzzer/AFL YERİNE Zig'in KENDİ YERLEŞİK fuzzer'ı SEÇİLDİ:**
Zig 0.16, `std.testing.fuzz` + `std.testing.Smith` İLE kapsam-güdümlü
(coverage-guided), STDLIB'e GÖMÜLÜ bir fuzzing altyapısı SUNUYOR (`zig
build test --fuzz`) — Zig'in KENDİ derleyicisi (`std/zig/tokenizer.zig`nin
`test "fuzzable properties upheld"`si) BUNU KENDİ tokenizer'ını fuzzlamak
İÇİN KULLANIYOR. HARİCİ bir libFuzzer/AFL kurulumu (`-fsanitize=fuzzer`
C araç zinciri köprüsü, AYRI bir derleme hedefi/CI adımı) GEREKMEZ — bu,
projenin GENEL "battle-tested/YERLEŞİK aracı SEÇ, YENİDEN İCAT ETME"
ilkesiyle (bkz. `nox.json`nin `std.json` seçimi, W.1'in tree-sitter-python
tarayıcısını UYARLAMASI) TUTARLIDIR. `tests/fuzz/lexer_parser_checker_fuzz.
zig`nin `testOne`i, Zig'in KENDİ `tokenizer.zig` fuzz hedefinden (ağırlıklı
bayt örnekleme deseni DAHİL) DOĞRUDAN UYARLANMIŞTIR.

**İki fuzz hedefi:**
1. `tests/fuzz/lexer_parser_checker_fuzz.zig` — `nox.lexer.tokenize` →
   `nox.parser.parseModule` → `nox.checker.Checker.checkModule` zincirini
   ÇALIŞTIRIR. Doğrulanan ÖZELLİK: GEÇERSİZ bir girdinin bir HATA İLE
   reddedilmesi normal/beklenendir (`catch return`) — YALNIZCA bir PANİK/
   sonsuz döngü BAŞARISIZLIK sayılır.
2. `tests/fuzz/wasm_parser_fuzz.zig` — `wasm_bridge.module.parse`yi
   ÇALIŞTIRIR (AGENTS.md §9.5'in "güven sınırı" mantığıyla EN YÜKSEK
   öncelikli hedef — GÜVENMEYEN kaynaktan ham bayt AYRIŞTIRAN TEK modül).

**ÖNEMLİ bulgu 1 — bu araç zincirinde `--fuzz`in KENDİSİ DERLENEMİYOR:**
`zig build test --fuzz=<N>` (Zig'in KENDİ sürekli fuzzing modu)
denendiğinde, Zig'in KENDİ gömülü `compiler/test_runner.zig`si
`-ffuzz` bayrağıyla derlenirken bir HATA VERDİ: `std.debug.
writeStackTrace`e `*const debug.StackTrace` BEKLENİRKEN `*builtin.
StackTrace` GEÇİLİYORDU (tip uyuşmazlığı). Bu, **BU PROJENİN koduyla
HİÇBİR İLGİSİ OLMAYAN**, Zig'in KENDİ dağıtımının bir HATASIDIR — proje
DIŞINDA, TEK BAŞINA minimal bir dosyayla (`zig test t.zig -ffuzz`)
BAĞIMSIZ olarak TEKRAR ÜRETİLDİ (bkz. aşağıdaki test dosyalarının KENDİ
belge notu). Bu, `docs/uretim-hazirlik-analizi.md`nin TALEP ettiği
"libFuzzer/AFL yerine YERLEŞİK aracı kullan" kararının PRATİKTE beklenmedik
bir MALİYETİ ortaya ÇIKARDI — R.4'ün "pin ŞİMDİKİ sürüme, GELECEKTE
BİLİNÇLİ geçiş" felsefesiyle TUTARLI olarak, bu HATANIN gelecekteki bir
Zig sürümünde DÜZELMESİ BEKLENİR, ŞİMDİ bir İŞ AROUND (workaround)
YAZILMAYACAK (Zig'in KENDİ derleyicisindeki bir hatayı bu projenin
`build.zig`sinden YAMALAMAK KAPSAM DIŞI).

**Sonuç — İKİ katmanlı test tasarımı:** `--fuzz`in KENDİSİ ÇALIŞMADIĞINDAN,
HER iki dosyaya da `std.testing.fuzz`e BAĞIMLI OLMAYAN, ELLE yazılmış
regresyon testleri EKLENDİ (`wasm_parser_fuzz.zig`de 4, `lexer_parser_
checker_fuzz.zig`de 3) — bunlar HER `zig build test`te KOŞULSUZ çalışıp
GERÇEK koruma sağlar; dormant `std.testing.fuzz` blokları İSE `--fuzz`
GELECEKTE ÇALIŞTIĞINDA KULLANILACAK ALTYAPI olarak KALIR (birbirini
DIŞLAMAZLAR — normal `zig build test` HER İKİSİNİ de TEK bir (varsayılan)
girdiyle ÇALIŞTIRIR, CI'yi YAVAŞLATMAZ).

**ÖNEMLİ bulgu 2 — elle yazılan regresyon testlerinin İLKİ GERÇEK, ÖNCEDEN
BİLİNMEYEN bir bellek sızıntısı BULDU:** "büyük-ama-sahte vektör sayısı"
testi (bir Type bölümünün 1 milyonluk bir tip SAYISI bildirip ARDINDAN
HİÇBİR veri TAŞIMAMASI), `wasm_bridge.module.parse`nin `types.
ensureTotalCapacity(allocator, count)` çağrısının ARDINDAN gelen HERHANGİ
bir `try` BAŞARISIZ olduğunda (bu ÖRNEKTE bir SONRAKİ `r.byte()`nin
`error.UnexpectedEof` DÖNMESİ), o ana kadar tahsis edilmiş `types`
listesinin (VE — fonksiyonun GERİ KALANINDA — `func_type_indices`/
`bodies`/`exports` listelerinin, İÇLERİNDEKİ `params`/`results`/`name`/
`locals` alt-dilimleri DAHİL) **HİÇBİR ZAMAN serbest BIRAKILMADIĞINI**
ortaya ÇIKARDI — bu, Faz 13'ten (WASM köprüsünün İLK yazıldığı faz) BERİ
VAR OLAN, `Module.deinit()`in YALNIZCA BAŞARILI bir `parse()` DÖNÜŞÜNDE
çağrılabildiği (kısmi/hatalı bir `Module` DEĞERİ HİÇ dönMEDİĞİNDEN)
SİSTEMİK bir tasarım BOŞLUĞUYDU — GÜVENMEYEN kaynaktan (bir `.wasm`
dosyası) HER TEKRARLANAN BOZUK girdi TALEBİ bir SIZINTIYA yol AÇAR (çökme
DEĞİL, ama tekrarlanan istekler ALTINDA bellek TÜKENMESİ — bir DoS
varyantı, AGENTS.md §9.5'in "güven sınırı" endişesinin TAM da ÖNGÖRDÜĞÜ
sınıf).

**Düzeltme — `parse()`nin HER ARA listesine/alt-tahsisine KENDİ
`errdefer`i:** `types`/`func_type_indices`/`bodies`/`exports`
ArrayList'lerinin HER BİRİ, KENDİ bildirimlerinin HEMEN ARDINDAN bir
`errdefer` ALIR (liste-düzeyinde: o ana kadar BAŞARIYLA eklenmiş TÜM
öğelerin alt-dilimlerini + listenin KENDİ arka-plan belleğini serbest
bırakır); AYRICA `params`/`results`/`name`/`locals`in HER BİRİ, KENDİ
`allocator.alloc`/`dupe` ÇAĞRISININ HEMEN ARDINDAN AYRI bir `errdefer`
ALIR (o ANKİ döngü YİNELEMESİNDE, HENÜZ listeye EKLENMEMİŞ durumdayken
BAŞARISIZ olursa, YİNE de serbest bırakılsın DİYE — liste-düzeyi errdefer
YALNIZCA ZATEN eklenmiş öğeleri KAPSADIĞINDAN, bu İKİ katman BİRBİRİNİ
TAMAMLAR, ÇAKIŞMAZ/ÇİFT-SERBEST-BIRAKMAZ). Fonksiyonun EN SONUNDAKİ DÖRT
`toOwnedSlice` çağrısı da AYRICA KENDİ `errdefer`lerini ALIR — bir SONRAKİ
`toOwnedSlice` BAŞARISIZ olursa (yalnızca OOM İLE, aşırı NADİR), ÖNCEKİ
BAŞARILI `toOwnedSlice`lerin SAHİPLİĞİNİ ÇIKARDIĞI dilimlerin de (ARTIK
kaynak `ArrayList`in KENDİ errdefer'i TARAFINDAN GÖRÜNMEZ OLDUĞUNDAN,
`items.len==0`) doğru şekilde serbest BIRAKILMASINI sağlar — bu, GERÇEKTE
tetiklenmesi SON DERECE ZOR (art arda İKİ küçük tahsis ARASINDA TAM
OOM GEREKTİRİR) bir kenar durum OLSA da, "kısmi hata yolunda HİÇ sızıntı
YOK" garantisini TAM olarak KAPATMAK İÇİN eklendi.

**Doğrulama:**
1. **7 yeni elle-yazılmış regresyon testi** (`wasm_parser_fuzz.zig`de 4:
   tamamen çöp bayt dizisi, kısaltılmış bölüm başlığı, X.1'in AYNI varint-
   taşması senaryosunun TAM bir modül İÇİNDE tekrarı, büyük-ama-sahte
   vektör sayısı; `lexer_parser_checker_fuzz.zig`de 3: 500 seviye DERİN
   girinti, sonlandırılmamış string + ham ikili çöp, 2000 terimli TEK
   satırlık ifade).
2. **Kasıtlı boz→kırmızı→düzelt:** `types`nin YENİ EKLENEN `errdefer`i
   GEÇİCİ olarak KALDIRILDI → `zig build test`: **"1 leaks" — TAM OLARAK
   `wasm_parser_fuzz.zig`nin "büyük-ama-sahte vektör sayısı" testi
   BAŞARISIZ oldu**, sızıntının KENDİSİ (`DebugAllocator` çıktısı) `module.
   zig:220`deki `types.ensureTotalCapacity` çağrısını GÖSTERDİ — TAM OLARAK
   beklenen/tanı konan hata; BAŞKA HİÇBİR test ETKİLENMEDİ (367/367 →
   366/367). Düzeltme GERİ getirildi, TÜM testler (Debug + ReleaseFast)
   YEŞİLE döndü.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.40 Faz X.3 — ARC Atomikliği/Cross-Thread Invariant'ının Resmileştirilmesi

**Kaynak — `docs/uretim-hazirlik-analizi.md`:** "X.3 — ARC atomikliği/
cross-thread invariant'ını YA gerçek atomiklerle YA DA derleme-zamanı bir
assertion'la RESMİLEŞTİR."

**Araştırma — invariant BUGÜN gerçekten DOĞRU (ama TAMAMEN İMPLİCİT/
belgesiz):** `runtime/alloc/arc.zig`nin refcount'u (`i64`, görünmez 8
baytlık başlık) HİÇBİR ZAMAN atomik DEĞİLDİR — `nox_rc_retain`/
`nox_rc_predecrement` düz `+= 1`/`-= 1`dir, VE performans fazında (Faz
74/M.1-M.8) BUNLAR QBE'ye INLINE EDİLDİ (`codegen_qbe/codegen.zig`nin
`emitInlineRetain`/`emitInlinePredecrement`i — SAF aritmetik, Zig
fonksiyonuna bir ÇAĞRI bile YOK). Bu, YALNIZCA Nox'un eşzamanlılık modeli
GERÇEKTEN tek-OS-iş-parçacıklı OLDUĞU SÜRECE güvenlidir. Doğrulandı: (1)
`runtime/async_rt/scheduler.zig`nin KENDİ modül üstü notu fiber'ların
KOOPERATİF TEK bir OS iş parçacığında ÇALIŞTIĞINI AÇIKÇA belirtir (M:N
DEĞİL, YALNIZCA M:1 — bkz. §3.21); (2) TEK bilinen istisna, `nox.http`
istemcisinin arka plan `std.Thread.spawn` işçisidir (`runtime/
stdlib_shims/http_client.zig`) — İNCELENDİ ve İŞÇİ iş parçacığının
YALNIZCA ham/allocator-tabanlı (ARC-DIŞI) tampon kopyaları ÜRETTİĞİ, ARC
tahsisinin/serbest bırakılmasının İSE TAMAMEN ana iş parçacığında, İŞÇİ
TAMAMLANDIKTAN SONRA (bir self-pipe İLE senkronize, GERÇEK bir happens-
before ilişkisi kuran) GERÇEKLEŞTİĞİ DOĞRULANDI — `dupeToNoxStr` (ARC
tahsisi yapan TEK fonksiyon) YALNIZCA ana iş parçacığında ÇAĞRILIYOR.

**Karar — GERÇEK atomiklere GEÇMEK YERİNE, invariant'ı Debug modunda
DOĞRULANABİLİR/yakalanabilir hale GETİRMEK:** refcount'u atomik yapmak
(`@atomicRmw`), M/N performans fazının (bkz. §3.24/§3.25, ARC-ağırlıklı
kod için ÖLÇÜLEN darboğazlar) DOĞRUDAN TERSİNE ÇEVİRİLMESİ anlamına
gelirdi — ÖLÇÜLMEMİŞ, BUGÜN karşılığı OLMAYAN bir performans MALİYETİ
(M.5'in "ölçülmeden mimari EKLEME REDDİ" İLE AYNI gerekçe). Bunun YERİNE:
`asap.RuntimeState`e (İlke #6'yla TUTARLI — GİZLİ bir global DEĞİL, HER
ARC çağrısına ZATEN AÇIKÇA taşınan `rt` bağlamının bir PARÇASI) yeni bir
`arc_owner_tid: if (debug_thread_check) ?std.Thread.Id else void` alanı
eklendi; `arcOwnerThreadOk(state)` (İLK çağrıda çağıran iş parçacığını
SAHİP olarak KAYDEDER, SONRAKİ HER çağrıda o KAYITLI sahiple KARŞILAŞTIRIR)
`nox_rc_alloc`/`nox_rc_free_payload`nin (HER ikisi de HÂLÂ GERÇEK Zig
fonksiyon ÇAĞRILARI — `malloc`/`free`e ihtiyaç duyduklarından İNLİNE
EDİLEMEZLER, bkz. `emitInlineRetain`nin KENDİ notu) BAŞINDA `std.debug.
assert`e SARILARAK ÇAĞRILIR. `debug_thread_check = builtin.mode ==
.Debug` — `use_debug_allocator`/`arc.zig`nin `use_pool`u İLE AYNI "Debug
= TAM güvenlik ağı, Release = SIFIR maliyet" ilkesi (Release modunda
`std.Thread.getCurrentId()` bile ÇAĞRILMAZ).

**Bilinçli sınırlama — YALNIZCA `alloc`/`free_payload` KAPSANIR, INLINE
EDİLMİŞ retain/predecrement DEĞİL:** bu, invariant'ın TAM/MÜKEMMEL bir
kanıtı DEĞİLDİR — inline edilen ARTIRMA/AZALTMA aritmetiğinin KENDİSİ
(gerçek bir yarış durumunda İKİ iş parçacığının AYNI ANDA `+=1` yapması)
BU kontrolden GEÇMEZ. AMA en TEHLİKELİ SONUÇ (çift-serbest-bırakma —
İKİ iş parçacığının AYNI nesneyi sıfıra düşürüp İKİSİNİN de `nox_rc_
free_payload`yi ÇAĞIRMASI, VEYA yeni bir nesnenin FARKLI bir iş
parçacığında tahsis EDİLMESİ) HER ZAMAN `nox_rc_alloc`/`nox_rc_
free_payload`den GEÇER — bu YÜZDEN bu İKİ çağrı SİTESİ, PRATİKTE en
YÜKSEK sinyal/maliyet oranına sahip yakalama NOKTALARIDIR. TAM kapsama
İSTENİRSE inline retain/predecrement'in KENDİSİNE de (QBE IR seviyesinde)
bir hata-ayıklama modu EKLENMESİ gerekirdi — bu, M.8 İLE AYNI kategoride
("ölçülmeden/somut bir İHTİYAÇ OLMADAN büyük bir mimari GENİŞLEME") v1
kapsamı DIŞINDA bırakıldı.

**Doğrulama:**
1. **İki yeni birim testi** (`runtime/alloc/asap.zig`): (a) AYNI iş
   parçacığından TEKRARLANAN çağrıların HEP `true` döndüğü (normal
   kullanım, YANLIŞ-POZİTİF YOK); (b) **GERÇEKTEN `std.Thread.spawn` İLE
   BAŞLATILAN AYRI bir OS iş parçacığından** (simüle EDİLMEMİŞ) AYNI
   `state`e yapılan bir çağrının `false` DÖNDÜĞÜ — `arcOwnerThreadOk`nin
   `pub fn` (export DEĞİL) OLARAK açılması, bu TESTİN gerçek bir `std.
   debug.assert`/panik TETİKLEMEDEN, SAF mantığı DOĞRUDAN sınamasını
   SAĞLAR.
2. **Kasıtlı boz→kırmızı→düzelt:** `arcOwnerThreadOk` GEÇİCİ olarak HER
   ZAMAN `true` DÖNECEK şekilde BOZULDU → `zig build test`: **368/369 —
   TAM OLARAK "farklı-iş-parçacığı İHLALİ YAKALANIR" testi BAŞARISIZ
   oldu**, BAŞKA HİÇBİR test ETKİLENMEDİ. Düzeltme GERİ getirildi, TÜM
   testler (Debug + ReleaseFast) YEŞİLE döndü.
3. **Manuel uçtan-uca doğrulama:** sınıf örnekleri (`Point`), takma
   adlama (`q: Point = p`, GERÇEK bir `nox_rc_retain` TETİKLER) VE
   `list[int]` İÇEREN GERÇEK bir Nox programı, TAZE bir Debug-modu
   `noxrt.o`ya karşı DERLENİP çalıştırıldı — yeni assertion HİÇBİR YANLIŞ-
   POZİTİF ÜRETMEDEN, doğru çıktıyla (çıkış kodu 0) tamamlandı.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

---

## 3.41 Faz Y.1 — Hafif Paket Dizini (Statik JSON İndeks)

**Kaynak — `docs/uretim-hazirlik-analizi.md` (satır 162):** "Hafif bir
'paket dizini' [yalnızca statik bir JSON indeksi — gerçek bir sunucu/
registry DEĞİL]."

**Tasarım kararı — GERÇEK bir sunucu/API DEĞİL:** Faz O'nun kendi
planlama turu (bkz. §3.6, "Açık Sorular / Bilinçli Kapsam Dışı") merkezi
bir registry/proxy'yi (Go'nun `GOPROXY`si benzeri) KASITLI olarak kapsam
DIŞI bıraktı — `compiler/pkg/fetch.zig`nin TEK bir dispatch noktası
(`resolveCloneUrl`) olması, GELECEKTEKİ bir fazın bir "mirror'dan HTTP
üzerinden tarball getir" dalı EKLEMESİNİ manifest/lockfile şemasına
DOKUNMADAN sağlar. Y.1 AYNI ilkeyi izler: `compiler/pkg/index.zig` bir
JSON metnini AYRIŞTIRIR/ARAR — nereden GELDİĞİ (yerel dosya, `noxc
search`e verilen bir yol) TAMAMEN ÇAĞIRANIN sorumluluğundadır. Gelecekte
bir HTTP indirme adımı EKLENİRSE (statik bir dosya sunucusundan/GitHub
Pages'ten), bu YALNIZCA `loadIndexFromFile`nin YANINA yeni bir
`loadIndexFromUrl` EKLEMEK anlamına gelir — `parseIndexJson`/`matches`
DEĞİŞMEDEN kalır.

**Şema:**
```json
{
  "packages": [
    {
      "name": "noxhttp-extras",
      "repo": "github.com/example/noxhttp-extras",
      "description": "nox.http icin yardimci fonksiyonlar",
      "tags": ["http", "web"]
    }
  ]
}
```
`repo`, `Requirement`in (bkz. `compiler/project.zig`, Faz P.4) `repo`
alanIYLA AYNI kavram/format (`"github.com/user/repo"`) — bilinçli olarak
`ref` TAŞIMAZ: paket dizini bir KEŞİF katalogudur, sürüm PİNLEME
`nox.json`nin `requires[]`inin işidir (kullanıcı bulduğu paketi KENDİ
`ref`iyle manifestine EKLER). `description`/`tags` opsiyoneldir, eksikse
sırasıyla boş dizge/boş dizi varsayılanına düşer.

**API (`compiler/pkg/index.zig`):**
- `PackageEntry{name, repo, description="", tags=&.{}}`, `Index{packages=&.{}}`.
- `IndexError = error{InvalidIndex} || std.Io.Dir.ReadFileAllocError || Allocator.Error`.
- `parseIndexJson(a, source) IndexError!Index` — `project.parseLockfile`
  İLE AYNI desen (`std.json.parseFromSlice(..., .{.ignore_unknown_fields=true})`,
  bozuk JSON İÇİN genel `error.InvalidIndex`).
- `loadIndexFromFile(a, io, path) IndexError!Index` — dosyadan okuyup
  ayrıştırır (`noxc search`in gerçek kullanım yolu).
- `matches(entry, query) bool` — BOŞ sorgu HER ZAMAN eşleşir (tüm
  katalogu listelemek için); doğrulukla İSE ad/açıklama İÇİNDE alt-dizge
  eşleşmesi VEYA bir etiketle TAM eşleşme (alt-dizge DEĞİL — `"we"`
  `"web"` etiketiyle EŞLEŞMEZ, bilinçli bir tasarım seçimi).

**v1 kapsamı — YALNIZCA yerel dosya (HTTP fetch YOK):** `loadIndexFromUrl`
şu an YOK; bu, mimarinin `loadIndexFromFile`nin YANINA trivial şekilde
GENİŞLETİLEBİLECEK şekilde tasarlandığı, ama ŞİMDİ YAZILMADIĞI anlamına
gelir — Faz O'nun registry/proxy ERTELEMESİYLE AYNI "gelecekte-genişletilebilir,
ŞİMDİ-inşa-edilmeyen" ilkesi.

**Yeni CLI alt komutu — `noxc search <indeks-dosyasi.json> [sorgu]`:**
(`compiler/main.zig`, `cmdSearch`) TAM İŞLEVSELDİR (hâlâ iskelet olan
`fetch`/`update`nin AKSİNE) — indeksi okur, `matches`le filtreler, HER
eşleşen paket İÇİN `ad — repo` + varsa açıklama/etiket satırları basar;
hiçbir şey eşleşmezse `"eslesen paket bulunamadi"` basar; indeks
okunamaz/ayrıştırılamazsa net bir Türkçe hata mesajıyla çıkış kodu 1
DÖNER.

**Golden/birim testler:**
1. `compiler/pkg/index.zig` İÇİNE gömülü 4 test: geçerli bir indeksin
   doğru ayrıştırılması (eksik alanların varsayılanlara düştüğü DAHİL),
   bozuk JSON'un `error.InvalidIndex` döndürmesi, boş `{}`nin geçerli
   (sıfır paket) sayılması, `matches`in ad/açıklama/etiket davranışı
   (TAM etiket eşleşmesi vs. alt-dizge AYRIMI DAHİL).
2. `tests/cli/search_test.zig` — `subcommand_test.zig` İLE AYNI desende,
   kurulu `zig-out/bin/noxc`yi GERÇEK bir alt süreç olarak çalıştıran 4
   golden test: sorgusuz tam katalog listesi, sorguyla TEK paket
   eşleşmesi, eşleşme YOKKEN açık mesaj, bozuk indeks dosyasıyla çıkış
   kodu 1.

**Doğrulama:** `zig build test` Debug'da 377/377 yeşil, ReleaseFast'ta
AYNI şekilde yeşil. Kasıtlı boz→kırmızı→düzelt: `matches()` GEÇİCİ
olarak KOŞULSUZ `true` DÖNECEK şekilde bozuldu → **TAM OLARAK**
`pkg.index.test "matches: ad/aciklama/etiket uzerinden dogru eslesir"`
testi KIRMIZI oldu, başka HİÇBİR test ETKİLENMEDİ; düzeltme GERİ
getirildi, Debug + ReleaseFast YENİDEN yeşile döndü. `zig fmt` temiz
(`compiler/pkg/index.zig`, `compiler/lib.zig`, `compiler/main.zig`,
`tests/cli/search_test.zig`, `build.zig`). Manuel CLI doğrulaması
(`./zig-out/bin/noxc search <fixture>.json [sorgu]`) izole çağrılarda
doğru çıktı verdi.

---

## 3.42 Faz Y.2 — Örnek Üçüncü-Taraf Paketler Yayımlama (Ekosistem Kanıtı)

**Kaynak — `docs/uretim-hazirlik-analizi.md` (satır 163):** "En az 3-5
gerçek örnek üçüncü-taraf paket YAYIMLA (ekosistemin GERÇEKTEN çalıştığını
KANITLAMAK için)."

**Tasarım kararı — GERÇEK genel GitHub repoları, test fixture'ları
DEĞİL:** Faz P.5/P.6'nın kendi testleri (bkz. `tests/pkg/fetch_test.zig`
ve benzerleri) BİLEREK yerel `file://` fixture repoları kullanıyordu
(gerçek ağa dokunmamak için) — bu Y.2'nin AMACI DEĞİLDİR. Kullanıcıyla
netleşen karar (bkz. AskUserQuestion onayı): beş paket `mburakmmm`
GitHub hesabında GERÇEKTEN yayımlandı, HER biri MIT lisanslı, `v1.0.0`
etiketli, genel (public) repo:

| Repo | Alias | Modül dosyası | Gösterdiği özellik |
|---|---|---|---|
| [nox-pkg-greet](https://github.com/mburakmmm/nox-pkg-greet) | `greet` | `greet.nox` | düz fonksiyonlar |
| [nox-pkg-mathx](https://github.com/mburakmmm/nox-pkg-mathx) | `mathx` | `mathx.nox` | `nox.math` üzerine saf-Nox yardımcılar |
| [nox-pkg-stack](https://github.com/mburakmmm/nox-pkg-stack) | `stack` | `stack.nox` | sınıf + `list[T].append()` |
| [nox-pkg-strfmt](https://github.com/mburakmmm/nox-pkg-strfmt) | `strfmt` | `strfmt.nox` | `nox.strings` + tekil karakter indeksleme |
| [nox-pkg-collections](https://github.com/mburakmmm/nox-pkg-collections) | `collections` | `queue.nox` | `list[int]` yardımcı fonksiyonları |

**Doğrulama süreci — önce yerel `file://` prova, SONRA gerçek ağ:** Her
paket ÖNCE `/tmp` altında yerel bir git deposu olarak inşa edilip
(`git init`+commit+`v1.0.0` etiketi) yerel bir tüketici projesiyle
(`file://` repo yolu kullanan bir `nox.json`) `noxc build` İLE
DERLENEREK/ÇALIŞTIRILARAK doğrulandı — bu, GERÇEK GitHub'a bozuk kod
push ETMEMEK için bilinçli bir ön-adımdı (aynı disiplinin `git commit`
öncesi yerel test etme ilkesinin BİR UZANTISI). Yalnızca yerel prova
TAMAMEN yeşil olduktan SONRA `gh repo create --push` ile her paket
GERÇEKTEN yayımlandı, `v1.0.0` etiketleri push edildi.

**Bu ön-provalama sürecinde İKİ GERÇEK, önceden BİLİNMEYEN codegen
sınırlaması keşfedildi (bkz. `compiler/codegen_qbe/codegen.zig`):**

1. **`self.attr = len(x)` (veya `__init__` içinde ÖNCEDEN bildirilen
   bir yerel değişkenin `self.attr`e atanması) `__init__` metodunun
   İÇİNDE codegen'in genel "desteklenmeyen yapı" hata yoluna düşüyor —
   AYNI kod AYNI sınıfın BAŞKA (init-olmayan) bir metodunda SORUNSUZ
   çalışıyor.** Yalıtılmış tekrar üretim: `self.count = len(s)` (`s` bir
   `str` PARAMETRESİ) `__init__` İÇİNDE BAŞARISIZ, `set_from` gibi
   sıradan bir metotta BAŞARILI. Yalnızca ÇIPLAK bir parametrenin
   doğrudan bir `self.attr`e atanması (`list_class_field.nox` golden
   testinin deseni) `__init__` içinde güvenlidir.
2. **`self.attr = [literal]` (yeni bir liste literalinin doğrudan bir
   `self.attr`e atanması) `__init__` içinde AYNI şekilde başarısız
   oluyor** — güvenli desen, listeyi HAZIR bir parametre olarak almak
   (`self.items = items`).

Bu iki bulgu **`compiler/pkg/index.zig`nin/`fetch.zig`nin bir kusuru
DEĞİL** — genel çekirdek codegen'in `__init__`e özgü, henüz kök nedeni
araştırılmamış bir sınırlamasıdır. Kapsamlı bir kök-neden analizi ve
düzeltmesi Y.2'nin (paket YAYIMLAMA) kapsamı DIŞINDA bırakılıp AYRI bir
takip görevi olarak işaretlendi (`spawn_task`, "Fix self.attr = expr()
in __init__ codegen bug") — `nox-pkg-stack` bunun yerine kurucusunu
YALNIZCA çıplak parametrelerini doğrudan alanlara atayacak şekilde
TASARLADI (`IntStack(items: list[int], count: int)`), sorunu turlamak
yerine KANITLANMIŞ güvenli deseni KULLANARAK.

**Ayrıca keşfedilen, AYRI bir sınırlama (belgelenip paket tasarımıyla
ÇÖZÜLDÜ, kod DEĞİŞTİRİLMEDİ):** `checker.zig`nin `tryResolveQualifiedCall`/
`resolveMangledCall`ı YALNIZCA `self.functions`/`self.classes`e bakıyor,
`self.generic_functions`a DEĞİL — bu YÜZDEN `import`la içe aktarılan
GENERİK (`[T]`) bir fonksiyon NE nitelikli (`pkg.mod.fn(...)`) NE DE
`from`la (`from pkg.mod import fn`) çağrılabiliyor (yalnızca TAMAMEN
mangled ÇIPLAK adıyla, ör. `pkg_mod_fn(...)`, çağrılabiliyor — kullanışsız
bir "gizli" API). `nox-pkg-collections` bu YÜZDEN generic `[T]` YERİNE
somut `list[int]` imzaları KULLANIR (paketin kendi README'sinde AÇIKÇA
belgelendi).

**Uçtan uca gerçek ağ doğrulaması (`examples/thirdparty_demo/`):**
`nox.json`, beş paketin TAMAMINI GERÇEK `github.com` adreslerinden
(yerel/`file://` DEĞİL) çeker; `noxc build examples/thirdparty_demo/
main.nox` ÇALIŞTIRILDI — `git clone` ile GERÇEK ağ üzerinden beş paket
de getirilip `nox.lock`a çözülen SHA'lar YAZILDI, program BAŞARIYLA
derlenip beklenen çıktıyı (yerel prova ile BİREBİR AYNI) ÜRETTİ.
`package_index.json` da (Faz Y.1'in `noxc search`iyle) bu beş GERÇEK
paketi listeleyen somut bir örnek İNDEKSTİR — `noxc search
examples/thirdparty_demo/package_index.json [sorgu]` doğrulandı.

`zig build test` (Debug + ReleaseFast) etkilenmedi/yeşil kaldı (bu faz
derleyici KODUNU DEĞİŞTİRMEDİ, yalnızca paket İÇERİĞİ + örnek yayımladı).

## 3.43 Faz Z.1 — 1.0 İçin Somut "Hazır" Tanımı

**Kaynak — `docs/uretim-hazirlik-analizi.md` (satır 169):** "1.0 için
somut bir 'hazır' tanımı (hangi Faz'lar TAMAMLANMALI) belirle."

**Tanım — 1.0 SÜRÜMÜ, AŞAĞIDAKİ DOKUZ FAZ GRUBUNUN (Q–Y) TAMAMI
TAMAMLANMADAN kesilemez:**

| Faz | Konu | Durum |
|---|---|---|
| Q | Temel sağlamlaştırma (git/CI/lisans/DoS sertleştirme/güven sınırı dokümantasyonu) | ✅ TAMAMLANDI (Q.1–Q.6) |
| R | Platform genişletme (Linux epoll, x86-64, CI matrisi, araç zinciri pinleme) | ✅ TAMAMLANDI (R.1–R.4) |
| S | Bellek güvenliği tamamlama (yeniden atama sızıntıları, sınır kontrolü, döngü çözücü) | ✅ TAMAMLANDI (S.1–S.3) |
| T | Derleyici DX (kaynak pozisyonu, çoklu-tanılama, DWARF, `noxc fmt`) | ✅ TAMAMLANDI (T.1–T.4b) |
| U | Dil tamamlanmışlığı (`list.append`, çoklu-dosya import, `as`/`from`, closure, `with`) | ✅ TAMAMLANDI (U.1–U.5, U.4.1–U.4.4) |
| V | Stdlib genişletme (`nox.log`/`random`/`crypto`/`time`/`test`/regex) | ✅ TAMAMLANDI (V.1–V.6) |
| W | Araç ekosistemi (Tree-sitter, LSP, DAP) | ✅ TAMAMLANDI (W.1–W.3) |
| X | Güvenlik sertleştirme + fuzzing (WASM taşma sınırı, fuzz altyapısı, ARC invariant) | ✅ TAMAMLANDI (X.1–X.3) |
| Y | Paket ekosistemi olgunlaşması (paket dizini, gerçek örnek paketler) | ✅ TAMAMLANDI (Y.1–Y.2) |

**Bu belgenin yazıldığı tarih İTİBARİYLE dokuz grup da TAMAMLANMIŞ
durumda** — yani 1.0 için TEK kalan mekanik adım Faz Z'nin kendisidir
(Z.2: semver/stabilite politikasını YAZILI hale getirmek, Z.3: `v0.1/
taslak` etiketini KALDIRIP gerçek bir sürüm numaralandırmasına GEÇMEK).

**"Tamamlandı" kriterinin KENDİSİ — her Faz İÇİN neyin doğrulandığı:**
bir Faz'ın "✅ TAMAMLANDI" sayılması İÇİN, o Faz'ın HER alt-fazının
AGENTS.md İlke #7 ritüelinin TAMAMINDAN geçmiş olması GEREKİR: `zig build
test` (Debug + ReleaseFast) yeşil, yeni/değişen davranış İÇİN kasıtlı
boz→kırmızıyı doğrula→düzelt ritüeli tamamlanmış, `zig fmt` temiz,
`nox-teknik-spesifikasyon.md`de numaralı bir alt bölüm VE `CHANGELOG.md`de
bir giriş mevcut. Bu belgenin §3.1–§3.42 bölümleri (ve öncesindeki Faz
0–21/A–P bölümleri) bu kriterin HER Faz İÇİN sağlandığının somut
kayıtlarıdır — Z.1'in "tamamlandı" iddiası bu kayıtlara doğrudan
DAYANIR, ayrı bir yeniden-doğrulama turu GEREKTİRMEZ (zaten HER faz
KENDİ doğrulamasıyla bitmişti).

**Bilinçli olarak 1.0'ın KAPSAMI/ÖN KOŞULU SAYILMAYAN:**
- **AA.1 (gerçek M:N/çok çekirdekli fiber zamanlayıcı değerlendirmesi)**
  — bu, Q–Y'nin TAMAMLANMASINDAN SONRA ayrı bir görüş turunda ortaya
  çıkan, KENDİSİ BİLE henüz bir "faz" değil yalnızca bir ARAŞTIRMA/
  DEĞERLENDİRME talebidir; üstelik kullanıcıdan "sadece araştırma değil,
  daha fazla kapsam belirleme" gerektiği AÇIKÇA not edilmişti (yani
  implementasyona bile GİRİLMEDEN önce KULLANICIYLA bir netleştirme turu
  gerekir). Nox'un BUGÜNKÜ tek-OS-iş-parçacıklı (M:1) kooperatif fiber
  modeli (bkz. §3.21, §3.40) zaten İÇ TUTARLI ve doğrulanmış bir
  tasarımdır — M:N'e geçiş bir DÜZELTME değil, YENİ bir mimari
  YETENEKTİR (Cranelift değerlendirmesinin REDDİ İLE AYNI kategoride,
  bkz. §3.6.1: "ölçülmeden/somut bir İHTİYAÇ OLMADAN büyük bir mimari
  GENİŞLEME" 1.0'ı BEKLETMEMELİDİR). **AA.1, 1.0 SONRASI (2.0 veya daha
  sonraki bir minor) İÇİN AÇIK bir araştırma öğesi olarak KALIR.**
- **`noxc fmt`ın KENDİSİNİN mükemmelliği/`nox.json` merkezi bir registry
  sunucusu/gerçek M:N zamanlayıcı gibi Faz O/P/AA'nın KENDİ metinlerinde
  ZATEN "bilinçli kapsam dışı" olarak işaretlenmiş kalemler** — bunlar
  1.0'ın TANIMI GEREĞİ zaten dışarıda bırakılmıştı, Z.1 bu kararları
  YENİDEN AÇMAZ, yalnızca TEYİT eder.

**Sonuç — Z.1'in ÇIKTISI:** yukarıdaki tablo VE hariç-tutma listesi, 1.0
sürümünün "hazır" olup OLMADIĞINI gelecekte tek bakışta cevaplayan somut
bir kontrol listesidir. Bu tanıma göre proje ŞU AN Z.2/Z.3 ATILMADAN
1.0 OLARAK etiketlenemez (Z.1 TEK BAŞINA yeterli değildir — sürüm
POLİTİKASI YAZILI olmadan VE `v0.1/taslak` etiketi kaldırılmadan "1.0"
iddiası ANLAMSIZ kalır) ama TÜM MÜHENDİSLİK ön koşulları (Q–Y) ZATEN
karşılanmış durumdadır — kalan iş TAMAMEN Z.2/Z.3'ün SÜRÜM/POLİTİKA
işidir, YENİ bir MÜHENDİSLİK fazı DEĞİLDİR.

Bu faz KOD DEĞİŞİKLİĞİ İÇERMEDİĞİNDEN `zig build test` etkilenmedi
(377/377 yeşil, Debug + ReleaseFast, Faz Y.2'nin doğrulamasıyla AYNI).

## 3.44 Faz Z.2 — Semver Politikası + Dil/ABI Stabilite Garantisi

**Kaynak — `docs/uretim-hazirlik-analizi.md` (satır 170):** "Semver
politikası + dil/ABI stabilite garantisi YAZILI hale getir."

**Tasarım kararı — kullanıcı-yüzü politika ayrı bir üst-düzey dosyada,
KARAR GEREKÇESİ bu spec'te:** `README.md`/`CONTRIBUTING.md`/`LICENSE`
İLE AYNI düzeyde yeni bir **`VERSIONING.md`** eklendi — Faz Q.4'ün "her
biri KENDİ konusuna adanmış ayrı üst-düzey dosya" desenini İZLER
(politika METNİNİN KENDİSİ kullanıcıya YÖNELİKTİR, bu spec dosyasının
"geliştirme geçmişi" tonundan FARKLI bir REGISTER gerektirir).

**Politikanın ÖZETİ (tam metin İÇİN bkz. `VERSIONING.md`):**
1. **Standart SemVer** (`MAJOR.MINOR.PATCH`), `v1.0.0`dan İTİBAREN
   geçerli — `v0.1 (taslak)` bu politikanın KAPSAMI DIŞINDA (Faz Z.1'in
   kendi "hazır" tanımıyla TUTARLI: garanti YALNIZCA Z.3'ün etiket
   değişiminden SONRA bağlayıcı olur).
2. **Kaynak uyumluluğu garantisi** (AYNI MAJOR İÇİNDE): geçerli bir
   `vX.0.0` `.nox` programı `vX.Y.Z`nin HERHANGİ birinde AYNI şekilde
   derlenip AYNI davranışı üretir — dil sözdizimi/semantiği, stdlib
   imzaları, `nox.json`/`nox.lock` şeması, `noxc` alt komut davranışı
   DAHİL.
3. **BİLİNÇLİ olarak KAPSAM DIŞI bırakılan dört alan** (HER biri ayrı
   bir gerekçeyle):
   - **İkili (ABI) uyumluluğu YOK** — Nox'ta stabil bir ikili dağıtım
     formatı henüz YOK (`noxrt.o`/`extern def` C ABI'si/HPy-WASM köprü
     düzenleri İÇ implementasyon detayı), bu YÜZDEN HER sürüm
     KAYNAKTAN yeniden derleme GEREKTİRİR — Rust'ın `cargo` ÖNCESİ
     dönemine/Zig'in KENDİ mevcut politikasına BENZER, dürüst bir
     kısıtlama (icat edilmiş bir vaat DEĞİL).
   - **Hata mesajı METNİ sabit DEĞİL** (yalnızca hata TÜRÜ/çıkış kodu) —
     Faz T.2'nin çoklu-tanılama biçiminin PATCH sürümlerinde bile
     İYİLEŞTİRİLEBİLMESİ İÇİN kasıtlı bir esneklik alanı.
   - **`--dump`/`-v` çıktısı** hata ayıklama ARACIDIR, programatik
     tüketim İÇİN TASARLANMAMIŞTIR (M.2'nin "varsayılan sessiz" kararıyla
     TUTARLI).
   - **Üçüncü-taraf paket API'leri** Nox'un KENDİ garantisinin DIŞINDA
     — HER paketin KENDİ semver'i KENDİ yazarının sorumluluğu (Go
     modüllerinin felsefesiyle AYNI), ama `nox.lock`ın SHA-pinlemesi
     (Faz P.5) HER durumda TEKRARLANABİLİR derlemeyi zaten GARANTİ
     EDİYOR — bir paketin geriye dönük UYUMSUZ bir değişikliği bile
     ZATEN kilitlenmiş projeleri ETKİLEMEZ.
4. **Kullanımdan kaldırma (deprecation) kuralı:** bir özellik KALDIRILMADAN
   ÖNCE EN AZ bir MINOR sürüm "kullanımdan kaldırıldı" İŞARETİYLE
   (CHANGELOG'da) YAŞAMALIDIR, GERÇEK kaldırma yalnızca bir SONRAKİ
   MAJOR'da olur.

**Bu faz KOD DEĞİŞİKLİĞİ İÇERMEDİĞİNDEN** `zig build test` etkilenmedi
(377/377 yeşil, Faz Y.2/Z.1'in doğrulamasıyla AYNI — yalnızca YENİ
`VERSIONING.md` + `README.md`ye bir bağlantı EKLENDİ).

## 3.45 Faz Z.3 — `v0.1/Taslak` Etiketini Kaldırma, Gerçek Sürüm Numaralandırmasına Geçiş

**Kaynak — `docs/uretim-hazirlik-analizi.md` (satır 171):** "`v0.1/taslak`
etiketini KALDIR, gerçek bir sürüm numaralandırmasına GEÇ."

**Yapılan değişiklikler:**
1. `build.zig.zon`nin `.version` alanı `"0.1.0"` → `"1.0.0"` GÜNCELLENDİ —
   projenin TEK, resmi sürüm kaydı BURADADIR (`zig build`in KENDİSİ bu
   alanı DOĞRULAR, bu yüzden GEÇERSİZ bir semver string'i derlemeyi
   BOZARDI — `zig build` ÇALIŞTIRILARAK bu DOĞRULANDI).
2. `README.md`nin ÜST banner'ı `"Durum: v0.1 (taslak)... henüz üretime
   hazır değil"`den `"Sürüm: v1.0.0"`ya GÜNCELLENDİ, Faz Z.1'in kontrol
   listesine (§3.43) ve `VERSIONING.md`ye BAĞLANTI eklendi.
3. `CHANGELOG.md`nin ÜST açıklaması semver'e ATIFLA (VERSIONING.md'ye
   bağlantı) yeniden yazıldı; Faz Q'dan BERİ biriken TÜM `### Eklendi`/
   `### Düzeltildi`/`### Güvenlik` girdileri TEK bir `## [1.0.0]`
   başlığı ALTINA toplandı; ÜZERİNE gelecekteki değişiklikler İÇİN BOŞ
   bir `## [Yayımlanmamış]` başlığı EKLENDİ (Keep a Changelog
   konvansiyonuyla TUTARLI — bkz. https://keepachangelog.com).

**Bilinçli olarak BU turda YAPILMAYAN (kullanıcıyla NETLEŞTİRİLDİ):**
GERÇEK `git tag v1.0.0` komutu bu turda ÇALIŞTIRILMADI — kullanıcı
(`AskUserQuestion` ile) belgelerin/manifest'in `1.0.0`e HAZIRLANMASINI
ama etiketin KENDİSİNİN AYRI, SONRAKİ bir onayla ATILMASINI TERCİH etti.
Bu, standart bir "sürüm HAZIRLAMA commit'i, SONRA etiketleme" akışıdır
(çoğu sürüm mühendisliği iş akışının kendisi de bu İKİ adımı AYIRIR) —
BU commit'ten SONRA yapılacak TEK şey `git tag v1.0.0` (VE isteniyorsa
bir uzak depoya push) olacaktır, `CHANGELOG.md`/`build.zig.zon`/`README.md`
zaten NİHAİ hallerindedir.

`zig build` (manifest doğrulaması DAHİL) ve `zig build test` (Debug +
ReleaseFast) BU faz TARAFINDAN ETKİLENMEDİ/yeşil kaldı — bu faz
derleyici KODUNU/davranışını DEĞİŞTİRMEDİ, yalnızca sürüm METADATA'sını
GÜNCELLEDİ.

## 3.46 Faz AA.1 — Gerçek M:N (Çok Çekirdekli) Fiber Zamanlayıcı Değerlendirmesi: Araştırma Bulguları

**Kaynak:** 1.0 sürümü (Faz Q–Z) tamamlandıktan SONRA ortaya çıkan, Faz
Z.1'in (§3.43) KENDİSİNİN 1.0'ın kapsamı DIŞINDA bıraktığı açık bir
araştırma öğesi. Kullanıcıyla netleşen kapsam: BU tur YALNIZCA ARAŞTIRMA/
DEĞERLENDİRMEDİR — hiçbir kod DEĞİŞTİRİLMEDİ, bir implementasyon KARARI
VERİLMEDİ. Amaç, mevcut M:1 (tek OS iş parçacığı) kooperatif fiber
modelinden GERÇEK bir M:N (çok çekirdekli) modele geçişin somut mimari
ENGELLERİNİ kod okunarak TESPİT ETMEKTİR.

**Sonuç — M:N'e geçiş bir DÜZELTME değil, gerçek bir mimari GENİŞLEMEDİR
ve TEK bir engel yok, BİRDEN FAZLA bağımsız engel var:**

1. **Zamanlayıcı BUGÜN gerçek bir süreç-geneli tekil (singleton).**
   `runtime/async_rt/bridge.zig:34`deki `g_scheduler` modül-seviyesi
   TEK bir global değişkendir, `$main`e gömülen TEK bir `nox_async_init`
   çağrısıyla kurulur. `Scheduler`in hazır kuyruğu/yığın havuzu/sayaçları
   (`scheduler.zig`) düz, SENKRONİZE OLMAYAN `ArrayListUnmanaged`/`usize`
   alanlarıdır — hiçbir kilit/atomik YOK. Deadlock tespiti (bkz. §3.21)
   AÇIKÇA "TEK OS iş parçacığı OLDUĞU İÇİN hazır kuyruk boş + live_count≠0
   HER ZAMAN gözlemlenebilir bir global durumdur" varsayımına DAYANIR —
   bu varsayım M:N'de GEÇERSİZ olur, dağıtık bir boşta-kalma tespiti
   protokolü GEREKİR.

2. **ARC refcount'unun atomik OLMAMASI BİLİNÇLİ bir karardı (Faz X.3,
   §3.40) ve BU karar M:N'in EN BÜYÜK engeli.** `nox_rc_retain`/
   `predecrement` düz `+=1`/`-=1`dir VE derleyici bu aritmetiği DOĞRUDAN
   QBE IR'a INLINE EDER (`emitInlineRetain`/`emitInlinePredecrement`,
   `codegen.zig`) — Zig çalışma zamanı fonksiyonlarını bile ATLAYARAK.
   Faz X.3 TAM OLARAK bu soruyu inceleyip GERÇEK atomiklere geçmeyi
   (ölçülen performans maliyeti GEREKÇESİYLE) REDDETTİ, YERİNE yalnızca
   Debug modunda bir "iş parçacığı sahibi" assertion'ı EKLEDİ — VE bu
   assertion BİLE inline edilen aritmetiğin KENDİSİNİ KAPSAMAZ (yalnızca
   `nox_rc_alloc`/`nox_rc_free_payload`nin GERÇEK fonksiyon çağrısı KALAN
   iki noktasını).
3. **Havuzlanmış (pooled) ARC ayırıcının serbest listeleri düz,
   SENKRONİZE OLMAYAN bağlı listelerdir** (paylaşılan TEK `RuntimeState`
   içinde) — gerçek senkronizasyon YA DA iş-parçacığı-başına önbellek
   yeniden tasarımı GEREKİR.
4. **Döngü çözücü (Katman 3, Bacon-Rajan) TÜM yığının örtük tek-iş-
   parçacıklı bir "anlık görüntüsünü" VARSAYAR** — çok geçişli
   yürüyüşü SIRASINDA refcount'ları MUTASYONA UĞRATIR; BAŞKA iş
   parçacıklarındaki eşzamanlı mutator'larla YARIŞIRDI. Ya GERÇEK bir
   "tüm iş parçacıklarını DURDUR" mekanizması (BUGÜN HİÇBİR YERDE YOK)
   YA DA bariyer'li TAM bir eşzamanlı-GC yeniden tasarımı GEREKİR.
5. **Birkaç stdlib global'i, KENDİ doğruluğunun TAM OLARAK M:1 garantisi
   OLDUĞUNU AÇIKÇA belgeliyor** — en çarpıcısı `runtime/stdlib_shims/
   fs.zig`nin KENDİ yorumu: "Nox'un M:1 fiber modelinde AYNI ANDA
   yalnızca TEK bir fiber ÇALIŞIR, bu YÜZDEN bu bayrakta YARIŞ DURUMU
   OLUŞMAZ." `nox.random`nin PRNG'si VE `nox.json`nin son-işlem-durumu
   bayrağı da AYNI kırılganlığı taşıyor.
6. **Mevcut TEK gerçek çoklu-iş-parçacığı emsali** (`nox.http`
   istemcisinin `std.Thread.spawn` işçisi, bkz. §3.40) YALNIZCA o işçi
   iş parçacığının ARC-yönetimli belleğe HİÇ DOKUNMAYACAK şekilde
   DENETLENDİĞİ İÇİN çalışıyor — GERÇEK bir M:N zamanlayıcı, TANIM
   GEREĞİ ARC'a dokunan kodun BİRDEN FAZLA iş parçacığında EŞZAMANLI
   ÇALIŞTIĞI, TAMAMEN DENETLENMEMİŞ bir durumdur.
7. **kqueue/epoll reaktörü PAYLAŞILABİLİR görünüyor** (çekirdek KENDİ
   kilitlemesini yapıyor) — BULGULARIN EN AZ ENDİŞE VERİCİ olanı; her
   OS iş parçacığı KENDİ reaktör örneğini çalıştırabilir, çapraz-iş-
   parçacığı UYANDIRMA gerekmez.

**Spec'te ZATEN belgelenen, bu araştırmanın TEKRAR AÇMADIĞI kararlar:**
§3.21 (Faz 21, M:1'in KENDİSİ, "v0.1'in amacı doğruluk, SONRA hız"),
§3.24/§3.25 (performans fazının inline retain/havuzlama/yığın havuzu
ÖLÇÜMLERİ — M:N'in TAM OLARAK RİSKE ATACAĞI optimizasyonlar), §3.40
(Faz X.3'ün atomik-REDDİ kararı), §3.43 (Faz Z.1'in AA.1'i 1.0 kapsamı
DIŞINDA bırakan kararı).

**Sonraki adım — BU turun ÇIKTISI değil, gelecekteki bir kapsam-
netleştirme görüşmesinin GİRDİSİ:** kullanıcıyla, hangi ÖDÜNLERİN kabul
edilebilir olduğu (ör. ÖLÇÜLEN bir performans maliyeti karşılığında
GERÇEK atomikler? "ARC nesneleri iş parçacıkları ARASINDA GEÇEMEZ" gibi
YENİ bir dil kuralı/tip sistemi kısıtı? iş-parçacığı-başına İZOLE
heap'ler?) netleşmeden HİÇBİR tasarım/implementasyon turuna
GİRİŞİLMEYECEK — bu, M.8/Faz P'nin (Cranelift) İZLEDİĞİ AYNI "araştır,
BULGULARI belgele, kararı ERTELE" disiplinidir.

Bu tur KOD DEĞİŞİKLİĞİ İÇERMEDİĞİNDEN `zig build test` ETKİLENMEDİ
(377/377 yeşil, Faz Z.3'ün doğrulamasıyla AYNI).

## 3.47 Faz BB.1 — `nox.thread`e Doğru: Beş "Tehlikeli" Global'in `threadlocal` Yapılması

**Kaynak:** kullanıcı, Nox'un 1.0 sürümü için gerçek bir M:N (çok
çekirdekli) fiber zamanlayıcısı/yeşil iş parçacığı desteğinin ZORUNLU
olduğunu belirtti — bu, Faz Z.1'in (§3.43) BU konuyu 1.0'ın kapsamı
DIŞINDA bırakan kararını AÇIKÇA GERİ ALIR ve AA.1'in araştırma
bulgularının (§3.46) ÜZERİNE gerçek bir implementasyon turu İNŞA EDER.
Kullanıcıyla (AskUserQuestion) üç mimari seçenek arasından
**"paylaşımsız (shared-nothing) N zamanlayıcı"** modeli seçildi: her OS
iş parçacığı KENDİ bağımsız fiber zamanlayıcısını/KENDİ bağımsız
`RuntimeState`/ARC heap'ini çalıştırır; HİÇBİR fiber iş parçacıkları
ARASINDA GEÇMEZ, HİÇBİR ARC nesnesi REFERANS OLARAK paylaşılmaz — bu,
Faz X.3'ün "gerçek atomiklere GEÇME" kararına HİÇ DOKUNMADAN gerçek
paralellik sağlar (bkz. §3.46'nın tam gerekçesi).

**Bu fazın kapsamı — SAF çalışma zamanı hazırlığı, dil yüzeyi YOK:**
AA.1'in araştırması, mevcut M:1 modelin TEK gerçek "süreç geneli tek
zamanlayıcı" varsayımının `runtime/async_rt/bridge.zig`deki TEK bir
`var g_scheduler` global'i OLDUĞUNU tespit etmişti — `Scheduler.init`/
`IoReactor.init` ZATEN allocator-only/sıfır-argümanlı, tamamen örnek-
tabanlıydı. Bu global (VE onunla AYNI kategoride olan dört BAŞKA
stdlib-kabuğu global'i) `threadlocal var`a çevrilerek, HİÇBİR yeni
senkronizasyon/kilit MEKANİZMASI EKLENMEDEN, `nox.thread.spawn`in
(Faz BB.2+) paylaşımsız modeli MÜMKÜN kılındı.

**`threadlocal` YAPILAN beş yer:**
1. `runtime/async_rt/bridge.zig`: `g_scheduler` — programın TEK
   zamanlayıcı varsayımının KENDİSİ.
2. `runtime/stdlib_shims/random.zig`: `g_prng`/`g_seeded` — **EN YÜKSEK
   riskli**, çünkü İDEMPOTENT bir önbellek DEĞİLDİR, HER çağrıda
   GERÇEKTEN mutasyona UĞRAR (PRNG durumunu İLERLETİR); paylaşılan bir
   `var` OLSAYDI iki iş parçacığının EŞZAMANLI `nox.random.*` çağrıları
   SESSİZCE veri bozulmasına (data race) yol AÇARDI.
3. `runtime/stdlib_shims/fs.zig`: `g_last_ok` — KENDİ ESKİ belge notu
   AÇIKÇA "M:1 OLDUĞU İÇİN güvenli" DİYORDU; bu ÖNCÜL artık GEÇERSİZDİR.
4. `runtime/stdlib_shims/json.zig`: `g_last_op_ok`, `g_make_json_value_fn`/
   `_resolved` — İKİNCİSİ İDEMPOTENT bir `dlsym` önbelleği (HER zaman
   AYNI sembole çözülür) olsa da, senkronize OLMAYAN eşzamanlı YAZIM
   teknik olarak TANIMSIZ DAVRANIŞTIR.
5. `runtime/alloc/cycle_detector.zig`: `g_trace_dispatch_fn`/
   `g_gc_free_dispatch_fn` + `_resolved` çiftleri — AYNI idempotent-
   dlsym-önbellek gerekçesi.

**BİLİNÇLİ olarak DOKUNULMAYAN, GERÇEKTEN paylaşılması GEREKEN iki
global (aksi halde YANLIŞ olurdu):**
- `runtime/stdlib_shims/os.zig`nin `g_argc`/`g_argv` — `$main`in
  `nox_os_init`i TARAFINDAN TEK SEFER (HER ZAMAN TEK bir iş parçacığında
  — programın GERÇEK başlangıcında) yazılır, SONRASI yalnızca OKUNUR;
  çocuk iş parçacıkları (Faz BB.2+) `nox_os_init`i TEKRAR ÇAĞIRMAZ,
  mevcut değerleri MİRAS ALIR — süreç GENELİ olması DOĞRU davranıştır.
- `runtime/stdlib_shims/http_client.zig`nin `g_client_io_state`/
  `g_client_io_storage` — KASITLI olarak SÜREÇ GENELİ PAYLAŞILIR, ZATEN
  gerçek bir atomik CAS + spin-wait ile KORUNUYOR (`std.Io.Threaded`nin
  SÜREÇ GENELİ `SIGIO` sinyal işleyicisi kurması YÜZÜNDEN İKİ örnek
  OLUŞTURULAMAZ) — bu dosyaya DOKUNULMADI.

**Doğrulama:** her dokunulan dosyaya, `asap.zig`nin `arcOwnerThreadOk`
testinin AYNI deseninde (GERÇEK `std.Thread.spawn`, simüle EDİLMEMİŞ)
bir izolasyon testi eklendi — `bridge.zig`de iki iş parçacığının
BAĞIMSIZ bir görev spawn edip DOĞRU sonucu aldığı; `random.zig`de iki
iş parçacığının FARKLI tohumlarla ÜRETTİĞİ dizinin, AYNI tohumun
SIRALI (tek-iş-parçacıklı) üretimiyle BİREBİR eşleştiği (paylaşılan bir
PRNG OLSAYDI bu İMKANSIZ olurdu); `fs.zig`/`json.zig`de biri SÜREKLİ
BAŞARISIZ, diğeri SÜREKLİ BAŞARILI işlem yapan iki iş parçacığının
KENDİ bayraklarını DOĞRU gördüğü; `cycle_detector.zig`de bir iş
parçacığındaki `dlsym` önbellek enjeksiyonunun DİĞERİNE SIZMADIĞI.

**Kasıtlı boz→kırmızı→düzelt (`random.zig`, EN yüksek riskli değişiklik
üzerinde):** `threadlocal` GEÇİCİ olarak düz `var`a GERİ ÇEVRİLDİ,
YENİ izolasyon testi `-Doptimize=ReleaseFast` altında ART ARDA
ÇALIŞTIRILDI — **2. denemede testi BAŞARISIZ oldu** (paylaşılan PRNG
durumunun İKİ iş parçacığının İÇ İÇE geçmiş çağrılarıyla BOZULDUĞUNU
somut olarak KANITLADI — bir veri yarışının doğası GEREĞİ ARALIKLI/
DETERMİNİSTİK-OLMAYAN başarısızlığı, testin GERÇEKTEN bu sınıf hatayı
YAKALAYABİLDİĞİNİ kanıtlar). Değişiklik GERİ YÜKLENDİ, Debug + ReleaseFast
YENİDEN yeşile döndü.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz. BU faz
DİL sözdizimine/checker'a/codegen'e HİÇ DOKUNMADI — TAMAMEN çalışma
zamanı hazırlığıdır, Faz BB.2'nin (`nox.thread.spawn`in saf-Zig
çekirdeği) ÖN KOŞULUDUR.

## 3.48 Faz BB.2 — `nox.thread` Katman 1'in Saf-Zig Çekirdeği

**Kaynak:** Faz BB.1'in (§3.47) hazırladığı `threadlocal` zemin üzerine,
Katman 1'in (`nox.thread.spawn`/`ThreadHandle[T]`/`.join()`) GERÇEK
implementasyonu — YENİ dosya `runtime/async_rt/thread_bridge.zig`. BU
faz TAMAMEN saf Zig'dir — HİÇBİR Nox dil sözdizimi/checker/codegen
değişikliği İÇERMEZ (bkz. Faz BB.3/BB.4).

**Mimari — çocuk iş parçacığı `$main`in KENDİ önyüklemesinin bir
KOPYASI:** `nox_thread_spawn`, `std.Thread.spawn`i çağırır; çocuk iş
parçacığının GÖVDESİ (`childThreadMain`) `compiler/codegen_qbe/
codegen.zig`nin `genMainAsync`ının ürettiği DİZİYLE (`nox_runtime_init→
nox_async_init→spawn(entry)→run_to_completion→yıkım`) BİREBİR AYNIDIR —
TEK fark `nox_os_init`in TEKRAR ÇAĞRILMAMASI (argv süreç geneli, `$main`
TARAFINDAN ZATEN BİR KEZ yazılmış, bkz. §3.47'nin `g_argc`/`g_argv`
notu). Bu, `entry`nin KENDİSİNİN de `spawn`/`await`/`Channel[T]`
KULLANABİLMESİNİ sağlar — çocuk TAM İŞLEVSEL, BAĞIMSIZ bir fiber çalışma
zamanı ALIR, salt tek bir fonksiyon çağrısı DEĞİL.

**Paylaşımsız (shared-nothing) argüman/sonuç protokolü — `http_client.
zig`nin ZATEN AUDIT EDİLMİŞ desenine BİREBİR uyar:** `int/float/bool/
none/ptr` payload'ları DOĞRUDAN (8 baytlık bit-örtüşmesi) taşınır. `str`
İSE: ebeveyn `nox_thread_spawn`da SENKRON olarak (çocuk iş parçacığı
DAHİ BAŞLAMADAN ÖNCE, `std.Thread.spawn` ÇAĞRILMADAN ÖNCE) baytları DÜZ
(ARC-dışı, `std.heap.page_allocator`) bir hazırlık arabelleğine KOPYALAR
— bu, ebeveynin ORİJİNAL `str` referansının `nox_thread_spawn` DÖNER
DÖNMEZ serbest bırakılabilmesini GÜVENLİ kılar, ÇÜNKÜ çocuk ASLA
ebeveynin ARC belleğine DOKUNMAZ (yalnızca DÜZ baytları okur). Çocuk,
KENDİ `RuntimeState`i kurulduktan SONRA bu düz baytlardan TAZE bir ARC
`str` inşa eder (`http_client.zig`nin `dupeToNoxStr`ı DOĞRUDAN yeniden
KULLANILIR). SONUÇ İÇİN (str dönerse) TAM SİMETRİK protokol: çocuk KENDİ
ARC `str`ini düz baytlara KOPYALAR, KENDİ referansını serbest bırakır,
**TÜM `RuntimeState`ini tamamlanma sinyalinden ÖNCE YIKAR** — ebeveyn
`nox_thread_join`da bu düz baytlardan KENDİ ARC `str`ini inşa eder. Bu
noktadan SONRA hiçbir çapraz-iş-parçacığı ARC erişimi MÜMKÜN DEĞİLDİR.

**`nox_thread_join`in bekleme mekanizması — `http_client.zig`nin
`doRequest`ıyla BİREBİR AYNI iki-modlu desen:** bir Nox FİBER İÇİNDEYSEK
(`bridge.currentFiberScheduler()`), D.0'ın reaktörü ÜZERİNDEN askıya
alınır (BAŞKA fiber'lar bu SIRADA GERÇEKTEN ilerleyebilir); fiber
DIŞINDAYSAK sıradan bloklayan bir `read()` YETERLİDİR. **GERÇEK bir
`std.Thread.join()` KULLANILMAZ** — o TÜM ebeveyn OS iş parçacığını
(o zamanlayıcıdaki TÜM DİĞER fiber'ları DA) bloklardı, `async_rt`nin
"zamanlayıcıyı ASLA bloklama" ilkesini İHLAL ederdi.

**`ThreadHandle`nin ömrü — `Task.detached`den BİLİNÇLİ olarak FARKLI,
GERÇEK bir atomik referans SAYIMI:** `Task.detached` (bkz. `scheduler.
zig`) TEK bir OS iş parçacığında KOOPERATİF çalıştığından güvenlidir
(gerçek bir veri yarışı YOK). `ThreadHandle` İSE GERÇEKTEN İKİ bağımsız
OS iş parçacığı arasında PAYLAŞILIR — ebeveyn (`nox_thread_destroy`) VE
çocuk (işini bitirince) HER İKİSİ de `handle`e "sahip"tir, HANGİSİNİN
SIRAYLA biteceği BELİRSİZDİR. `owners: std.atomic.Value(u32)` (2'den
başlar) — her taraf işini bitirince BİR azaltır (`fetchSub(1, .acq_rel)`),
0'a düşüren taraf (hangisi OLURSA olsun) struct'ı GERÇEKTEN serbest
bırakır. **`ThreadHandle`nin KENDİSİ (VE `ChildCtx`/hazırlık
arabellekleri) BİLİNÇLİ olarak `std.heap.page_allocator` üzerinden
tahsis edilir, `rt`nin ARC ayırıcısı DEĞİL:** `rt`nin ayırıcısı BİR iş
parçacığına AİT olma VARSAYIMINI taşır (Faz X.3'ün `arc_owner_tid`ı) —
`page_allocator` (Zig'in DOĞRUDAN OS `mmap` sarmalayıcısı) doğası GEREĞİ
iş-parçacığı-BAĞIMSIZDIR; bu, `ThreadHandle`nin İKİ taraftan da GÜVENLE
serbest bırakılabilmesi İÇİN mimari olarak DOĞRU seçimdir (`rt`nin
Debug-modu `DebugAllocator`ı VARSAYILAN olarak `thread_safe = true` olsa
BİLE — bu dosya BİLİNÇLİ olarak `rt`nin ayırıcısına GÜVENMEZ, ÇÜNKÜ
paylaşımsız model bir `RuntimeState`in TEK bir iş parçacığına AİT OLMA
prensibini MİMARİ düzeyde, salt bellek-güvenliği düzeyinde DEĞİL,
korumalıdır).

**Doğrulama:** dört saf-Zig birim testi (`entry`ye Nox sözdizimi
GEREKMEZ, doğrudan Zig fonksiyonları `entry` olarak geçirilir) —
`int` payload uçtan uca; `str` payload (ebeveynin ORİJİNAL referansının
`nox_thread_spawn` DÖNER DÖNMEZ serbest bırakılabildiği, `DebugAllocator`ın
sızıntı DEDEKTÖRÜYLE kanıtlanır); `entry`nin KENDİ `nox_async_spawn`ını
KULLANDIĞI (çocuğun GERÇEKTEN TAM işlevsel bağımsız bir zamanlayıcı
ALDIĞINI kanıtlar); `nox_thread_destroy`nin çocuk HENÜZ bitmeden
ÇAĞRILDIĞINDA sızmadan/UAF'siz kendi kendini temizlediği (atomik
`owners` sayacının doğruluğu).

**Kasıtlı boz→kırmızı→düzelt (str-hazırlık protokolü ÜZERİNDE):**
ebeveynin baytları KOPYALAMA adımı GEÇİCİ olarak ATLANDI (çocuğa
DOĞRUDAN ebeveynin ham işaretçisi GEÇİRİLDİ) — `str` testi ÇALIŞTIRILDI:
test **ASILI KALDI** (5 dakikalık zaman aşımına ULAŞTI) — bu, TEK
BAŞINA, kopyalama ADIMININ atlanmasının GERÇEKTEN yıkıcı bir çapraz-
iş-parçacığı bellek bozulmasına (bir OS iş parçacığının BAŞKA bir
`RuntimeState`e ait belleği serbest bırakmaya ÇALIŞMASI) yol AÇTIĞININ
somut kanıtıdır (temiz bir test BAŞARISIZLIĞINDAN BİLE daha güçlü bir
sinyal — sürecin KENDİSİ kurtarılamaz bir duruma DÜŞTÜ). Değişiklik
GERİ YÜKLENDİ, Debug + ReleaseFast YENİDEN yeşile döndü.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.
`runtime/lib.zig`ye `thread_bridge` eklendi (`noxrt_test`in KEŞFETMESİ
İÇİN, `async_bridge` İLE AYNI desen).

## 3.49 Faz BB.3 — `nox.thread.start`/`ThreadHandle[T]`/`.join()`: Checker

**Kaynak:** Faz BB.2'nin (§3.48) saf-Zig çekirdeği ÜZERİNE, dil yüzeyinin
İLK yarısı — checker. `compiler/typecheck/types.zig`ye `thread_handle:
*const Type` eklendi (`Type` union'unun TÜM exhaustive switch'lerine
— `eql`/`format`/`typeToTypeExpr`/`appendMangledType`/`isFfiSafeType`/
`isSpawnParamSafeType` — karşılık gelen kollar eklenerek).

**KRİTİK, uygulama SIRASINDA keşfedilen bir isimlendirme ÇAKIŞMASI —
`nox.thread.spawn` DEĞİL, `nox.thread.start`:** `spawn` ZATEN `kw_spawn`
olarak lexer'a KAYITLI, dilin KENDİ fiber-spawn sözdiziminin (`spawn
<fn>(...)`) anahtar kelimesidir. `nox.thread.spawn(...)` YAZILDIĞINDA,
`.` SONRASI `spawn` bir `.identifier` DEĞİL bir `kw_spawn` token'ı olarak
GELİR — `parsePostfix`in nokta-erişim çözümlemesi bunu REDDEDER
(`error.UnexpectedToken`). Bu, GERÇEKTEN derlenip test EDİLEREK
keşfedildi (planlama turunda ATLANMIŞ bir detay) — çözüm: fonksiyon adı
`start` OLARAK DEĞİŞTİRİLDİ (`nox.thread.start(entry, arg) ->
ThreadHandle[T]`). Bu, İKİ AYRI kavramı ("fiber başlat" vs. "OS iş
parçacığı başlat") KULLANICI İÇİN de sözdizimsel olarak AYIRT ETTİĞİNDEN
bilinçli olarak KORUNDU (parser'ı `spawn`ı bağlam-duyarlı bir tanımlayıcı-
YA-DA-anahtar-kelime yapmak YERİNE) — `runtime/async_rt/thread_bridge.
zig`nin KENDİ Zig-seviyesi `nox_thread_spawn`/`nox_thread_join`/
`nox_thread_destroy` isimleri (İÇ, Nox kaynağından DOĞRUDAN görünmez)
DEĞİŞTİRİLMEDİ — `nox_async_spawn`in KENDİSİNİN de Nox'un `spawn`
anahtar kelimesiyle BİREBİR AYNI ADI TAŞIMAMASIYLA TUTARLI bir ayrım.

**`tryResolveThreadSpawnCall` — `tryResolveHttpServeCall`in AYNI deseni,
TERS bir kısıtla:** `nox.http.serve`nin `handle`ı ZATEN çalışan bir
zamanlayıcının fiber'ında senkron çalıştığından `async def` OLAMAZKEN,
`nox.thread.start`ın `entry`i **`async def` OLMAK ZORUNDADIR** — KENDİ
TAZE, bağımsız zamanlayıcısının TEK üst-düzey görevi olarak çalışır
(`$main_body`nin AYNI "üst-düzey/in_async" muamelesi). Doğrulama sırası
BİLİNÇLİ: ÖNCE "`entry` TANIMLI mı" (`self.functions.get`, net bir
`UndefinedFunction` hatası İÇİN), SONRA "`entry` ASYNC mı" — TERS sıra
DENENSEYDİ, tanımsız bir isim YANLIŞLIKLA "async def olmalı" hatasına
DÜŞERDİ (`async_functions.contains` tanımsız bir isim İÇİN de sessizce
`false` döner — bu, geliştirme SIRASINDA yazılan bir test fixture'ıyla
YAKALANIP DÜZELTİLDİ).

**`isThreadTransferSafeType` — `isSpawnParamSafeType`den DAHA SIKI bir alt
küme:** `int/float/bool/str/none/ptr` — `isSpawnParamSafeType`nin AKSİNE
`task`/`channel` DE HARİÇ TUTULUR (`class`/`list`/`dict`/`thread_handle`
zaten HER İKİSİNDE de yasaktı). Gerekçe: bir `Task`/`Channel`, KENDİ
zamanlayıcısına bağlı bir `scheduler: *Scheduler` alanı TAŞIR
(`scheduler.zig`/`channel.zig`) — BAŞKA bir OS iş parçacığına taşınması,
o tutamacın YANLIŞ bir zamanlayıcıya İŞARET ETMESİNE (kullanım anında
çökme/tanımsız davranışa) yol AÇARDI. Argüman/dönüş tipi (`entry`in
imzasından) VE geçirilen `arg` ifadesinin KENDİ tipi (normal `assignable`
kontrolüyle) bu KÜMEDEN geçmelidir.

**`ThreadHandle[T].join()` — `Channel.send`/`.recv` İLE AYNI `await`
gereksinimi:** `.await_expr`in `is_channel_op` doğrulaması genişletildi —
`ThreadHandle.join()` de (bkz. `nox_thread_join`ın reaktör-tabanlı askıya
alma mekanizması, §3.48) `Channel.recv` İLE AYNI "açıkça bir askıya alma
noktası" ilkesine TABİDİR, `await` İLE SARILMALIDIR.

**Doğrulama:** 7 YENİ checker golden testi (`tests/golden/typecheck_cases/`)
— `nox.http.serve`nin KENDİ test şablonunun AYNISI: geçerli çağrı
(`ok_thread_start_join`), yanlış argüman sayısı, `entry` ÇIPLAK bir
tanımlayıcı DEĞİL, `entry` `async def` DEĞİL, yanlış parametre sayısı,
güvenli KÜMEDE OLMAYAN parametre tipi (`Channel[int]` — İLK denemede
`list[int]` KULLANILMIŞTI, AMA bu, ASYNC DEF'LERİN KENDİ ÖNCEDEN VAR OLAN
parametre-tipi KISITINA (yalnızca int/float/bool/str/None/Task[T]/
Channel[T]) TAKILDIĞI İÇİN — GERÇEKTEN test EDİLİP GÖZLEMLENEREK —
`Channel[int]`e DEĞİŞTİRİLDİ, çünkü O tip async-def-parametresi olarak
GEÇERLİDİR AMA `isThreadTransferSafeType`in KENDİ, DAHA SIKI kümesinden
HARİÇTİR), tanımsız `entry`.

**Kasıtlı boz→kırmızı→düzelt:** `isThreadTransferSafeType(sig.params[0])`
kontrolü GEÇİCİ olarak DEVRE DIŞI BIRAKILDI — TAM OLARAK BEKLENEN test
(`Channel[int]` parametreli `unsafe_type` testi) KIRMIZI oldu (392/393),
BAŞKA HİÇBİR test ETKİLENMEDİ. Değişiklik GERİ YÜKLENDİ, Debug +
ReleaseFast YENİDEN yeşile döndü.

`zig build test` (Debug + ReleaseFast) 393/393 yeşil, `zig fmt` temiz.
Codegen (Faz BB.4) BU faz TARAFINDAN KAPSANMADI — `checkModule`
`nox.thread.start` çağrılarını DOĞRU tipler, AMA `stdlib/nox/thread.nox`
HENÜZ VAR OLMADIĞINDAN GERÇEK derleme (`import nox.thread`in tam
çözümlenmesi) HENÜZ ÇALIŞMAZ; testler BİLİNÇLİ olarak `module_loader`
ATLANARAK, DOĞRUDAN `nox.checker.check`in `imported_modules`i `import_stmt`
AST düğümünün KENDİSİNDEN (dosya varlığından BAĞIMSIZ) doldurmasına
DAYANIR (`tests/golden/typecheck_golden_test.zig`nin MEVCUT desenle
TUTARLI).

## 3.50 Faz BB.4 — `nox.thread.start`/`ThreadHandle[T]`/`.join()`: Codegen + `stdlib/nox/thread.nox`

**Kaynak:** Faz BB.3'ün (§3.49) checker desteği ÜZERİNE, dil yüzeyinin
İKİNCİ (son) yarısı — codegen. `HeapKind`e `.thread_handle` eklendi
(`Task`/`Channel` İLE AYNI — ARC-yönetimli DEĞİL, `isHeapManaged` →
`false`, kapsam-sonu KOŞULSUZ TEK seferlik `nox_thread_destroy` çağrısıyla
temizlenir — `destroyNonArcValue` VE `heap == .task or .channel or .dict`
şeklindeki TÜM 6 ayrım noktasına eklendi).

**`stdlib/nox/thread.nox`:** `nox.http.serve`nin `serve`i GİBİ — GERÇEK
bir `func_def`/`class_def` DEĞİL, TAMAMEN checker (`tryResolveThreadSpawnCall`)
VE codegen (`genThreadStartExpr`/`genThreadStartWrapper`/
`genThreadHandleJoin`) sihridir; dosya SADECE `import nox.thread`in
ÇÖZÜLEBİLMESİ İÇİN belge notlarıyla var.

**`genThreadStartWrapper` — `genSpawnWrapper`DEN İKİ noktada FARKLI:**
(1) argüman SAYISI HER ZAMAN TAM OLARAK 1'dir (Tier 1'in kısıtı);
(2) kapanış (`ThreadEntryClosure`) native-qtype'lı DEĞİL, HER ZAMAN `l`
(i64) genişliğinde bir `payload` alanı TAŞIR (bkz. `thread_bridge.zig`nin
Zig struct TANIMI, §3.48) — argüman `loadl` İLE okunup `fromPayload` İLE
hedef tipe ÇEVRİLİR. Kapanışın KENDİSİ (`ThreadEntryClosure`) SAF Zig'de
(`childThreadMain`) tahsis edilip serbest BIRAKILIR — BURADA `nox_free`
ÇAĞRILMAZ (`genSpawnWrapper`nin kapanışının AKSİNE).

**KRİTİK, uçtan uca derleme SIRASINDA keşfedilen İKİ AYRI hata (İKİSİ de
GERÇEKTEN derlenip/çalıştırılıp GÖZLEMLENEREK bulundu):**

1. **`codegen: bu program şu an desteklenmeyen bir yapı içeriyor`
   (`error.Unsupported`):** codegen'in checker'dan TAMAMEN AYRI, KENDİ
   `resolveType` fonksiyonu `"ThreadHandle"`i sihirli bir generic isim
   olarak TANIMIYORDU (`is_list or is_task or is_channel` — `is_thread_handle`
   EKSİKTİ). `ThreadHandle[int]` tipi ÇÖZÜLEMEDİĞİNDEN başarısız oluyordu.
   Düzeltme: `resolveType`e `is_thread_handle` eklendi (hem koruma
   koşuluna hem de `.heap` seçen üçlü zincire).

2. **Görünüşte ÇİFT `$main` sembolü (`cc` bağlantı hatası: `symbol
   '_main' is already defined`) — YANLIŞ ALARM, GERÇEK bir codegen hatası
   DEĞİL:** ÜRETİLEN `.ssa`da GERÇEKTEN İKİ `export function ... $main`
   bloğu VARDI. Ham IR OKUNARAK (grep + tam bağlam) kök neden BULUNDU:
   test dosyasının KENDİSİ hatalıydı — `async def main() -> None: ...`
   ŞEKLİNDE bir fonksiyon TANIMLIYORDU. Nox'ta ÜST DÜZEY `async` kod bir
   `def main()` SÖZLEŞMESİ İLE İFADE EDİLMEZ (bkz. `genMainAsync`nin
   ÖNCEDEN VAR OLAN belge notu, §2.21 aşama 4) — modülün ÇIPLAK üst-düzey
   deyimleri DOĞRUDAN `$main_body` olarak derlenir. `main` ADLI bir
   fonksiyon TANIMLAMAK, O fonksiyonun KENDİ `genFuncDef` yolundan
   `$main` sembolüyle derlenmesine (rezerve edilmiş C-ABI giriş adıyla
   ÇAKIŞMASINA) yol AÇAR — bu, ThreadHandle/BB.4'e ÖZGÜ bir kodgen kusuru
   DEĞİL, ÖNCEDEN VAR OLAN, alakasız bir isimlendirme tuzağıydı (test
   dosyasının kendisi `async_spawn_await.nox`/`async_channel.nox`nin
   KURULU deseninden — ÇIPLAK üst-düzey deyimler — SAPMIŞTI). Düzeltme:
   test fixture'ları `async def main()` SARMALAYICISI OLMADAN, ÇIPLAK
   üst-düzey `Task[None] = spawn ...` deyimleriyle YENİDEN YAZILDI.

**ÜÇÜNCÜ, break→kırmızı→düzelt RİTÜELİ SIRASINDA (aşağıda) BULUNAN GERÇEK
bir sızıntı:** `genThreadStartWrapper`, `spec.target_fn`i çağırdıktan
SONRA `str` tipli argümanı SERBEST BIRAKMIYORDU. Sözleşme (bkz.
`collectLocals`/`allocSlot`in `is_param` notu — parametreler ÇAĞRILAN
TARAFINDAN HER ZAMAN ÖDÜNÇ ALINIR, kapsam-sonu otomatik release'i ATLAR)
gereği, bir değerin sahipliği ÇAĞRI SİTESİNDE (`releaseTemporaryArgs`/
`releaseIfTemporary`in normal `genCall` İÇİN yaptığı GİBİ) ELDE TUTULUR.
`genThreadStartWrapper`nin `arg_val`ı — `childThreadMain`in `dupeToNoxStr`
İLE TAZE, TEK SAHİPLİ bir ARC `str` olarak klonladığı — ÇAĞRI SİTESİNİN
KENDİSİ (wrapper) TARAFINDAN serbest BIRAKILMALIYDI, AMA BIRAKILMIYORDU.
Uçtan uca `str` golden testi BUNU GERÇEKTEN yakaladı (`DebugAllocator`nin
sızıntı raporu, yığın izinde `dupeToNoxStr <- childThreadMain` AÇIKÇA
GÖRÜLEBİLİYORDU). Düzeltme: `genThreadStartWrapper`, `spec.target_fn`
çağrısı DÖNDÜKTEN SONRA, parametre `str` İSE `releaseValueIfSet` ÇAĞIRIR.
(Not: `genSpawnWrapper`nin — normal fiber `spawn`ın — KENDİSİ de
str argümanlar İÇİN AYNI release'i YAPMIYOR; ANCAK bugüne kadar bunu
sınayan HİÇBİR golden test OLMADIĞINDAN bu potansiyel sızıntı
DOĞRULANMADI/kapsam DIŞINDA bırakıldı — ayrı bir görev olarak
işaretlendi, BU faz `nox.thread.start`ın KENDİ, YENİ kod yolunu
kapsar.)

**Bilinçli v1 sınırlaması (AÇIKÇA belgelendi):** `entry` içinde
YAKALANMAMIŞ bir istisna, `spawn`/`nox.http.serve`nin AYNI MEVCUT v1
davranışıyla TUTARLI olarak SÜRECİ TAMAMEN SONLANDIRIR (HANGİ iş
parçacığında OLURSA OLSUN) — `join()`e ZARİFÇE bir hata OLARAK
YAYILMAZ.

**Doğrulama:** 4 YENİ uçtan uca codegen golden testi (`tests/golden/
codegen_cases/`, GERÇEK `qbe`+`cc` İLE derlenip ÇALIŞTIRILARAK) —
`thread_spawn_join_int` (`int` payload, spawn+join, `21*2=42`),
`thread_spawn_join_str` (çapraz-iş-parçacığı `str` transferi, HEM arg
HEM dönüş, sızıntı yok), `thread_spawn_ordering` (`ThreadHandle.join()`
GERÇEKTEN fiber-farkında askıya alır — çocuğun 50ms `sleep_ms`i SIRASINDA
ebeveynin AYRI bir fiber'ı (`fast_task`) İLERLEMEYE DEVAM EDER, "fast"
"joined"DAN ÖNCE yazdırılır, `join()`in GİZLİCE BLOKLAYAN bir
`std.Thread.join()` OLMADIĞINI kanıtlar), `thread_spawn_detached_leak`
(`.join()` HİÇ ÇAĞRILMADAN scope'tan çıkan bir `ThreadHandle` —
`nox_thread_destroy`nin atomik `owners` sayacı İLE fire-and-forget
temizliği, sızıntı/UAF OLMADAN doğrulanır).

**Kasıtlı boz→kırmızı→düzelt:** `genThreadStartWrapper`deki YENİ `str`
release çağrısı GEÇİCİ olarak DEVRE DIŞI BIRAKILDI (`if (false and ...)`)
— TAM OLARAK BEKLENEN test (`thread_spawn_join_str`) `DebugAllocator`
sızıntı raporuyla KIRMIZI oldu (397 test İÇİNDEN 1'i, `dupeToNoxStr <-
childThreadMain` yığın izi AÇIKÇA GÖRÜLDÜ), BAŞKA HİÇBİR test
ETKİLENMEDİ. Değişiklik GERİ YÜKLENDİ (`diff` İLE bayt-bayt ÖZDEŞLİĞİ
doğrulandı), Debug + ReleaseFast YENİDEN yeşile döndü.

`zig build test` (Debug + ReleaseFast) 397/397 yeşil, `zig fmt` temiz.

## 3.51 Faz BB.5 — `ThreadChannel[T]`: Katman 2'nin Saf-Zig Çekirdeği (Simetrik Çift-Pipe)

**Kaynak:** Faz BB.4'ün (§3.50) TAMAMLANMIŞ Katman 1'i ÜZERİNE, Katman
2 — iş parçacıkları ARASINDA GERÇEK, sürekli, çift-yönlü iletişim.
YENİ `runtime/async_rt/thread_channel.zig`: `nox_threadchannel_new`/
`_send_val`/`_send_str`/`_recv_val`/`_recv_str`/`_destroy`. Mevcut,
sıfır-maliyetli, AYNI-iş-parçacığı `Channel[T]`e (`channel.zig`) HİÇ
DOKUNULMADI — `ThreadChannel`, `Scheduler.suspendCurrent`/`markReady`i
KULLANAMAZ (o ilkeller TEK bir zamanlayıcının KENDİ, kilitsiz/iş-
parçacığı-YEREL hazır kuyruğuna doğrudan erişir); BUNUN yerine
`nox_thread_join`ın (§3.48) KENDİSİNİN KULLANDIĞI `Scheduler.
suspendForIo`/`io.nonBlockingRead` İKİLİSİ yeniden kullanıldı — HER iş
parçacığı YALNIZCA KENDİ reaktörüne KAYDOLUR VE YALNIZCA KENDİ
`markReady`sini KENDİ iş parçacığından ÇAĞIRIR; DİĞER iş parçacığı
YALNIZCA bir OS pipe'ına BAYT YAZAR (`write()`, `PIPE_BUF` altı boyutlar
İÇİN POSIX'te atomiktir, kilitsiz güvenlidir) — bu, dosyanın TEK gerçek
"zamanlayıcılar arası" temas noktasıdır.

**Simetrik ÇİFT pipe — kullanıcının AskUserQuestion yanıtıyla SEÇİLEN
geri basınç modeli:** `recv_wakeup_*` (gönderen→alıcı: "veri var"),
`send_wakeup_*` (alıcı→gönderen: "yer açıldı", tampon DOLUYKEN bloklanmış
bir göndericiyi UYANDIRMAK İÇİN). Her İKİ yönde de "reaktör UYANDIRIR,
KOŞULU YENİDEN KONTROL ET" deseni (bkz. `io_reactor.zig`nin AYNI belge
notu) KULLANILDI — bir pipe'a ERKEN/FAZLADAN yazılan bir bayt ASLA kayıp
bir uyandırmaya yol AÇMAZ (kernel'in KENDİ arabelleğinde bekler, bir
SONRAKİ `read()` onu hemen yakalar), yalnızca zararsız bir ekstra döngü
yinelemesine.

**`str` transferi:** `nox_thread_spawn`ın AYNI "düz baytlarla kopyala,
ARC'a hiç dokunma" protokolü — `send_str`, gönderenin ARC `str`ini
SENKRON olarak DÜZ (`page_allocator`) bir NUL-sonlandırılmış arabelleğe
kopyalar (göndericinin KENDİ referansı çağrı DÖNER DÖNMEZ serbest
bırakılabilir), tampon İÇİNDE bu düz işaretçi taşınır; `recv_str`,
ALICININ KENDİ `rt`si üzerinden bu baytlardan TAZE bir ARC `str` inşa
eder (`http_client.zig`nin `dupeToNoxStr`ı, `thread_bridge.zig` İLE AYNI
yeniden kullanım). `int/float/bool/none/ptr` payload'ları (`_val`
varyantları) doğrudan, dönüşümsüz taşınır — `T`nin `str` OLUP OLMADIĞI
çağrı sitesinde statik olarak bilindiğinden, çalışma-zamanı
etiketinden kaçınıldı.

**KRİTİK, bu Zig sürümünde KEŞFEDİLEN bir API farkı:** `std.Thread.Mutex`
BU Zig geliştirme sürümünde ARTIK YOK (`std.Io.Mutex` var, AMA kilit
alma İÇİN bir `Io` arayüzü İSTER — genel amaçlı, senkron bir OS-iş-
parçacığı kilidi DEĞİL). Çözüm: `http_client.zig`nin `g_client_io_state`i
İÇİN ZATEN KULLANDIĞI AYNI CAS-tabanlı spin-kilit deseni (`std.atomic.
Value(u8)` + `cmpxchgWeak` + `std.Thread.yield()`) yeniden kullanıldı —
YENİ bir birincil ilkel İCAT EDİLMEDİ.

**Ömür — `ThreadHandle` İLE AYNI atomik referans SAYIMI:** `ThreadChannel`
TİPİK KULLANIMDA (bir yaratıcı iş parçacığı + `nox.thread.start`ın
`arg`ı olarak GEÇİRİLDİĞİ TEK bir çocuk iş parçacığı) TAM OLARAK İKİ
tarafça PAYLAŞILIR — `owners` 2'den başlayan GERÇEK bir atomik sayaçtır,
`nox_threadchannel_destroy` HER İKİ taraftan da ÇAĞRILIR (kapsam-sonu
KOŞULSUZ çağrı), sayaç 0'a düştüğünde struct GERÇEKTEN serbest bırakılır.

**Bilinçli v1 sınırlamaları (AÇIKÇA belgelendi):**
1. **3+ tarafça paylaşım** (AYNI kanalın BİRDEN FAZLA `nox.thread.start`
   çağrısına GEÇİRİLMESİ) checker TARAFINDAN ENGELLENMEZ, AMA `owners`
   sayacı SADECE 2 İÇİN doğru davranır — `ThreadHandle`nin AYNI sabit-2
   varsayımının doğal devamı.
2. **`capacity == 0` (el-ele TESLİM/rendezvous) DESTEKLENMEZ** —
   AYNI-iş-parçacığı `Channel[T]`nin AKSİNE, `ThreadChannel[T](capacity)`
   `capacity >= 1` GEREKTİRECEK (checker TARAFINDAN ZORUNLU KILINACAK,
   Faz BB.6). Gerekçe: çapraz-iş-parçacığı bağlamda "alıcı TAM O ANDA
   BEKLİYOR" bilgisini üçüncü bir sinyal OLMADAN GÜVENLE bilmenin bir
   yolu YOKTUR — `capacity >= 1` basit, kanıtlanabilir doğru bir
   tampon+çift-pipe modeliyle TAM ihtiyacı KARŞILAR, GERÇEK rendezvous
   BU turun kapsamı DIŞINDA bırakıldı.

**Doğrulama:** 3 YENİ saf-Zig testi (`thread_channel.zig`nin İÇİNDE) —
İKİ GERÇEK `std.Thread` ARASINDA 100 `i64` değerin sırayla gönderilip
alındığı (tamponlu, kapasite 4); kapasite-SINIRLI bir varyant (kapasite
2, 10 öğe) — göndericinin GERÇEKTEN dolu tamponda BLOKLANDIĞI (200ms
polling ile "henüz TÜMÜNÜ gönderemedi" doğrulanarak), alıcı BOŞALTINCA
UYANDIĞI kanıtlanır; İKİ BAĞIMSIZ `RuntimeState` ARASINDA `str` payload
turu (`send_str`/`recv_str`, `DebugAllocator`nin sızıntı DEDEKTÖRÜYLE).

**Kasıtlı boz→kırmızı→düzelt:** `sendPayload`deki kilit alma/bırakma
GEÇİCİ olarak KALDIRILDI. İLK denemede (100 değerlik standart test,
15 tekrar, `-Doptimize=ReleaseFast`) BEKLENEN bozulma GÖZLEMLENMEDİ —
küçük öğe sayısında yarış PENCERESİ görünür bir hataya yol AÇACAK kadar
GENİŞ değildi. Test hacmi GEÇİCİ olarak 2.000.000 öğeye ÇIKARILDI, TEK
bir `ReleaseFast` çalıştırmasında BEKLENEN KESİN kırmızı elde EDİLDİ:
`expected 44602, found 44601` — kilitsiz `append`in alıcının kilitli
`orderedRemove`iyle YARIŞTIĞININ SOMUT kanıtı (kayıp/bozuk bir değer).
Değişiklik (kilit + test hacmi) `diff` İLE bayt-bayt ÖZDEŞLİĞİ
doğrulanarak GERİ YÜKLENDİ, Debug + ReleaseFast YENİDEN yeşile döndü.

`zig build test` (Debug + ReleaseFast, TEKRARLANAN çalıştırmalarla)
400/400 yeşil, `zig fmt` temiz. Dil yüzeyi (checker/codegen) BU faz
TARAFINDAN KAPSANMADI — Faz BB.6.

## 3.52 Faz BB.6 — `ThreadChannel[T]`: Checker + Codegen + Sertleştirme Turu

**Kaynak:** Faz BB.5'in (§3.51) TAMAMLANMIŞ saf-Zig çekirdeği ÜZERİNE,
dil yüzeyi — Katman 2'nin SON parçası, `nox.thread` faz serisinin
(BB.1-BB.6) TAMAMLANMASI.

**`compiler/parser/parser.zig`:** `isGenericConstructName`e
`"ThreadChannel"` eklendi — `ThreadChannel[T](capacity)`,
`Channel[T](capacity)`in AYNI `GenericConstruct` AST yolunu kullanır,
SIFIR yeni ayrıştırıcı işi.

**`compiler/typecheck/types.zig`:** `Type` union'una `thread_channel:
*const Type` eklendi (`.thread_handle` İLE AYNI desen, `eql`/`format`
kolları DAHİL).

**`compiler/typecheck/checker.zig`:**
- `typeExprToType`nin `.generic` dalına `"ThreadChannel"` eklendi.
- `isFfiSafeType` → `.thread_channel` HARİÇ (`.thread_handle` İLE AYNI).
- **`isThreadTransferSafeType`e BİLİNÇLİ bir ASİMETRİ eklendi:**
  `Task`/`Channel`/`ThreadHandle`nin AKSİNE, `.thread_channel` BU
  fonksiyonda `true`dur — ÇÜNKÜ `ThreadChannel` (BB.5'in `thread_channel.
  zig`sinin modül üstü notu) bir `*Scheduler` alanı TAŞIMAZ (saf
  `page_allocator` + OS pipe'ları + spin-kilit), BAŞKA bir OS iş
  parçacığına GÜVENLE taşınabilir — ZATEN Katman 2'nin TÜM AMACI
  budur (`nox.thread.start`ın `arg`ı olarak GEÇİRİLEBİLMESİ).
- **`isSpawnParamSafeType`e de AYNI İSTİSNA gerekti — GERÇEKTEN derlenip
  test EDİLEREK keşfedilen bir bağımlılık:** `registerFunc`, HER `async
  def`in parametre tiplerini TANIM ANINDA (nasıl başlatılacağından
  BAĞIMSIZ — `spawn` İLE de `nox.thread.start` İLE de) `isSpawnParamSafeType`
  İLE denetler. `ThreadChannel[T]` parametresi taşıyan bir `entry`
  (`async def worker(tc: ThreadChannel[int])`) YAZILIP `nox.thread.start`a
  GEÇİRİLMEYE ÇALIŞILDIĞINDA, `isThreadTransferSafeType` `.thread_channel`i
  KABUL ETSE BİLE `registerFunc`in `isSpawnParamSafeType` kontrolü (ki
  o `entry`in KENDİ TANIMI ANINDA, ÇAĞRI sitesinden BAĞIMSIZ çalışır)
  BAŞARISIZ oluyordu — `.thread_channel` İLK yazımda YANLIŞLIKLA bu
  fonksiyonun `false` kümesine EKLENMİŞTİ. Uçtan uca bir `.nox` dosyası
  DERLENEREK yakalandı, `true` kümesine TAŞINARAK düzeltildi.
- Yeni `checkGenericConstruct` yardımcı fonksiyonu — `Channel[T](capacity)`
  VE `ThreadChannel[T](capacity)`in İKİSİNİ de işler (`ThreadChannel`
  eleman tipi `isThreadTransferSafeType`den GEÇMELİDİR).
- `.attribute` dalına `ThreadChannel.send`/`.recv` — `Channel`in AYNI
  deseni (`obj_t == .thread_channel`).
- `.await_expr`in `is_channel_op` kontrolü `ThreadChannel.send`/`.recv`yi
  de kapsayacak GENİŞLETİLDİ.
- `typeToTypeExpr`/`appendMangledType`e `.thread_channel` kolları eklendi.

**KRİTİK, gerçekten çalıştırılıp GÖZLEMLENEREK bulunan bir performans/
kararlılık regresyonu — `checkGenericConstruct`in ÇIKARILMASI:** BB.6'nın
İLK yazımında `ThreadChannel` kurucu mantığı `checkExpr`in KENDİ
`.generic_construct` switch dalına DOĞRUDAN eklenmişti. `zig build test`
çalıştırıldığında, ÖNCEDEN VAR OLAN `tests/fuzz/lexer_parser_checker_fuzz.
zig`nin "çok uzun tek satırlık ifade çökmeden işlenir" regresyon testi
(2000 seviye derinlikte iç içe `1 + 1 + ...` — `checkExpr`↔`checkBinary`
özyinelemesi) `Segmentation fault`la ÇÖKMEYE BAŞLADI. `git stash` İLE
temel (BB.6 ÖNCESİ) davranışın YEŞİL olduğu doğrulandı — BU GERÇEK bir
regresyondu, ortam kaynaklı bir gürültü DEĞİL (3/3 tekrarda DETERMİNİSTİK).
Kök neden: Debug modunda bir fonksiyonun yığın çerçevesi TÜM switch
dallarının yerel değişkenlerinin BİRLEŞİMİNE göre boyutlanır — `checkExpr`in
KENDİ switch'ine eklenen HER yeni yerel değişken (bir `.binary`/`.int_lit`
zinciri o dalı HİÇ ÇALIŞTIRMASA BİLE) `checkExpr`in TEK bir çağrısının
çerçevesini BÜYÜTÜR, VE bu büyüme 2000 özyinelemeli seviyede TEKRARLANIR.
Düzeltme: `ThreadChannel`/`Channel` kurucu mantığı `checkGenericConstruct`
adlı AYRI bir fonksiyona TAŞINDI (`tryResolveThreadSpawnCall`/`checkCall`
İLE AYNI "ayrı fonksiyon" deseni) — bu, sorunu TAMAMEN ÇÖZDÜ (yerel
değişkenler ARTIK `checkExpr`in KENDİ çerçevesinde DEĞİL, YALNIZCA
GERÇEKTEN bir `generic_construct` düğümü işlenirken tahsis edilen AYRI
bir çerçevede yaşıyor).

**`compiler/codegen_qbe/codegen.zig`:**
- `HeapKind`e `.thread_channel` eklendi (ARC-yönetimli DEĞİL —
  `Task`/`Channel`/`ThreadHandle` İLE AYNI).
- `resolveType`e `is_thread_channel` — `"ThreadChannel"` sihirli generic
  ismi tanınır.
- `destroyNonArcValue`e `.thread_channel → nox_threadchannel_destroy`
  kolu; TÜM `heap == .task or .channel or .dict or .thread_handle`
  şeklindeki ayrım noktalarına (kapanış-yakalama serbest bırakma, derin
  eşitlik) `.thread_channel` DA eklendi.
- Yeni `genThreadChannelOp` (`genChannelOp`in DESENİ) — `nox_channel_*`
  yerine `nox_threadchannel_*`e çağrı yapar, `T`nin `str` OLUP OLMADIĞINA
  (statik, `elem_is_str`) göre `_val`/`_str` varyantı SEÇER.
- `genAwaitExpr`, `.send`/`.recv` çağrılarında ARTIK alıcıyı BİR KEZ
  değerlendirip (`recv_val`) `.heap`ine (`.channel` mi `.thread_channel`
  mi) göre `genChannelOp`/`genThreadChannelOp`a dispatch eder —
  `genChannelOp`in kendi imzası BU YÜZDEN `ch_val: Value` parametresi
  ALACAK şekilde DEĞİŞTİRİLDİ (alıcı ifadesinin İKİ KEZ değerlendirilip
  yan etkilerin TEKRARLANMAMASI İÇİN).
- `genGenericConstruct`, `Channel`/`ThreadChannel`in İKİSİNİ de işler
  (`nox_channel_new`/`nox_threadchannel_new` arasında STATİK seçim).

**`stdlib/nox/thread.nox`:** Katman 2 kullanım örneği eklendi (doc-only,
gerçek kod DEĞİL — bkz. §3.50'nin AYNI notu).

**Doğrulama:** 3 YENİ uçtan uca codegen golden testi — `thread_channel_int`
(İKİ GERÇEK OS iş parçacığı arasında, kapasite 2, 5 `int` değer, sıralı);
`thread_channel_str` (çapraz-iş-parçacığı `str` transferi, sızıntı yok);
`thread_channel_backpressure` (kapasite 1, 20 değer, TAM boru hattından
derlenerek — alıcı HER `recv`den ÖNCE 1ms uyuduğundan gönderici fiber
NEREDEYSE HER yinelemede GERÇEKTEN geri basınca TAKILIR, yine de sıra/kayıp
OLMADAN TAMAMLANIR).

**Kasıtlı boz→kırmızı→düzelt:** `genAwaitExpr`in `.thread_channel`
dispatch dalı GEÇİCİ olarak DEVRE DIŞI BIRAKILDI (`if (false and ...)`)
— TÜM `send`/`recv` çağrıları YANLIŞLIKLA `genChannelOp`a (AYNI-iş-
parçacığı `Channel` çalışma zamanına) yönlendirildi. TAM OLARAK BEKLENEN
3 test (`thread_channel_int`/`_str`/`_backpressure`) `error.ProgramFailed`
İLE KIRMIZI oldu (100/101 → 98/101), BAŞKA HİÇBİR test ETKİLENMEDİ —
`ThreadChannel` işaretçisinin `nox_channel_send`/`_recv`e (TAMAMEN FARKLI
bir Zig struct düzeni BEKLEYEN) geçirilmesinin GERÇEK bir tip-karışıklığı
ÇÖKMESİNE yol AÇTIĞININ SOMUT kanıtı. Değişiklik `diff` İLE bayt-bayt
ÖZDEŞLİĞİ doğrulanarak GERİ YÜKLENDİ, Debug + ReleaseFast (TEKRARLANAN
çalıştırmalarla) YENİDEN yeşile döndü.

**Bilinçli v1 sınırlamaları (nox.thread'in TÜMÜ İÇİN, AÇIKÇA belgelenir):**
1. **Çapraz-iş-parçacığı DEADLOCK TESPİTİ YAPILMAZ** — TEK bir
   zamanlayıcının YEREL görüşü BAŞKA bir iş parçacığındaki bir
   kilitlenmeyi TESPİT EDEMEZ; `ThreadHandle.join()`/`ThreadChannel.
   send`/`.recv` (karşı taraf ASLA gelmezse) SONSUZA DEK asılı KALABİLİR
   (`Scheduler.run`ın AYNI-iş-parçacığı `error.Deadlock` tespiti BU
   duruma UYGULANMAZ — `waiting_on_io` durumu, GERÇEKTEN ilerleme
   OLUP OLMADIĞINI BİLEMEZ).
2. **`class`/`list`/`dict` çapraz-iş-parçacığı transferi DESTEKLENMEZ**
   (`isThreadTransferSafeType`/`isSpawnParamSafeType`) — genel
   özyinelemeli derin-klonlama mekanizması HİÇBİR YERDE YOK; `int/
   float/bool/str/none/ptr/ThreadChannel[T]` İLE SINIRLI.
3. **`ThreadChannel[T](0)` (el-ele teslim/rendezvous) DESTEKLENMEZ** —
   yalnızca `capacity >= 1`; Zig çekirdeği (`nox_threadchannel_new`)
   `capacity < 1` İÇİN `null` DÖNER, bu durumda SONRAKİ `.send`/`.recv`
   çağrıları (Nox'un GENEL "runtime null-pointer hataları İÇİN ZARİF
   bir istisna YOK" v1 sınırlamasıyla TUTARLI) TANIMSIZ/çökme davranışına
   yol AÇAR — checker BUNU BUGÜN statik olarak ENGELLEMEZ (`capacity`
   GENELDE derleme-zamanı sabiti DEĞİLDİR).
4. **`ThreadChannel`/`ThreadHandle`, TAM OLARAK İKİ tarafça (atomik
   `owners` sayacı 2'den BAŞLAR) paylaşılmak ÜZERE TASARLANDI** — AYNI
   kanalın/tutamacın 3+ farklı kapsama/`nox.thread.start` çağrısına
   GEÇİRİLMESİ checker TARAFINDAN ENGELLENMEZ, AMA SAYAÇ SADECE 2 İÇİN
   doğru davranır (erken serbest bırakma/UAF riski).
5. **`entry_fn`/`worker` içindeki YAKALANMAMIŞ bir istisna SÜRECİ
   TAMAMEN SONLANDIRIR** (`spawn`ın AYNI MEVCUT v1 davranışı) — `join()`e
   ZARİFÇE bir hata OLARAK YAYILMAZ.

`zig build test` (Debug + ReleaseFast, TEKRARLANAN çalıştırmalarla)
403/403 yeşil, `zig fmt` temiz. `nox.thread` (Faz BB.1-BB.6) TAMAMLANDI
— paylaşımsız (shared-nothing), çok çekirdekli iş parçacığı desteği
(N bağımsız M:1 fiber çalışma zamanının OS iş parçacıkları üzerinde
paralel çalışması — Faz AA.1'in (§3.46) ERTELEDİĞİ, TEK bir PAYLAŞILAN
M:N zamanlayıcıdan FARKLI bir model, bkz. `stdlib/nox/thread.nox`nin
AYNI netlik notu; Katman 1: `start`/`ThreadHandle[T]`/`.join()`; Katman
2: `ThreadChannel[T]`) 1.0 sürümüne HAZIR.

## 3.53 Faz CC.1 — Profesyonel Kurulum: GitHub Releases + `install.sh` + `noxc --version`

**Kaynak:** kullanıcının doğrudan talebi ("kurulum kötü ya zig build
falan kullanıyoruz diğer diller gibi daha profesyonel bir kurulum
yöntemi olamaz mı?") — Faz BB.6'nın (§3.52) TAMAMLANMASI VE GitHub
deposunun (github.com/mburakmmm/nox-lang) canlıya alınmasının HEMEN
ARDINDAN. Roadmap'in (Faz Q-Z, AA, BB) ORİJİNAL kapsamı DIŞINDA, kullanıcı
onayıyla (AskUserQuestion) kapsam NETLEŞTİRİLEREK yapıldı.

**Temel kısıt (kararı ŞEKİLLENDİREN):** `noxc` GERÇEK bir TEK statik
ikili DEĞİLDİR — çalışma zamanında `qbe` VE sistem `cc`sini ÇIPLAK bir
PATH aramasıyla ÇAĞIRIR (bkz. `compiler/main.zig`nin `"qbe"`/`"cc"`
argv'leri) — bu yüzden Go/Rust tarzı "TEK ikiliyi indir, HERŞEY biter"
deneyimi MÜMKÜN DEĞİLDİR. Kullanıcıyla (AskUserQuestion) İKİ karar
NETLEŞTİRİLDİ: (1) kapsam **GitHub Releases + `install.sh`** (Homebrew
tap YERİNE — ayrı bir depo GEREKTİRMEDİĞİNDEN daha düşük bakım
yüküyle daha yüksek etki), (2) **`qbe` tarball'a GÖMÜLÜR** (çok küçük
olduğundan, kullanıcı ayrıca `brew install qbe` YAPMAK ZORUNDA
KALMASIN) — yalnızca `cc` (bir C derleyicisi, macOS/Linux geliştirme
makinelerinde ZATEN neredeyse HER ZAMAN mevcuttur) sistem bağımlılığı
olarak KALIR.

**`.github/workflows/release.yml` (YENİ):** `v*` etiketi push
edildiğinde `ci.yml`nin AYNI 3 platform matrisini (macOS/aarch64,
Linux/x86-64, Linux/aarch64) KULLANARAK `zig build -Doptimize=ReleaseFast`
çalıştırır, `zig-out/{bin,lib}`i (`noxc`/`noxlsp` + `noxrt.o` + `nox.*`
stdlib) `bin/qbe` (`brew`den/kaynaktan derlenmiş, `ci.yml`nin AYNI adımı)
İLE BİRLİKTE bir `nox-lang-<surum>-<platform>.tar.gz`e paketler,
`softprops/action-gh-release`İLE GitHub Releases'e yükler (+ bir
`.sha256` doğrulama dosyası).

**Paket düzeni, `zig-out/`ün KENDİSİYLE BİREBİR AYNIDIR — TESADÜF
DEĞİL:** `compiler/project.zig`nin `resolveResourceDirs`ı `<exe_dir>/
../lib/noxrt.o` + `<exe_dir>/../lib/nox/stdlib`i BEKLER; `bin/qbe`nin
`bin/noxc` İLE AYNI dizine KONULMASI YETERLİDİR — `install.sh` `bin/`i
PATH'e EKLEDİĞİNDE, `noxc`nin `"qbe"` PATH araması OTOMATİK olarak
gömülü kopyayı BULUR (HİÇBİR kaynak kodu değişikliği GEREKMEDİ).

**`install.sh` (repo kökünde, YENİ):** `curl -fsSL .../install.sh | sh`
— `uname -s`/`uname -m` İLE platform TESPİT EDER (desteklenmeyenler İÇİN
— ör. Intel Mac, Windows — net bir hata VE kaynaktan derleme
YÖNLENDİRMESİ basar), `NOX_VERSION` VERİLMEZSE GitHub API'sinden
(`releases/latest`) en son etiketi ÇÖZER, doğru tarball'ı `$NOX_INSTALL_DIR`
(varsayılan `~/.nox-lang`) altına AÇAR, `cc` EKSİKSE bir UYARI basar
(platforma göre öneri: `xcode-select --install` / `apt install
build-essential`), shell rc dosyasına (`~/.zshrc`/`~/.bashrc`, TESPİT
EDİLEBİLİRSE) `PATH` satırını EKLER (zaten YOKSA).

**`noxc --version`/`version`/`-V` (YENİ alt komut/bayrak):**
`install.sh`nin doğrulama adımının GÜVENDİĞİ, daha önce HİÇ VAR
OLMAYAN bir özellik — `rustc`/`go`/`node` İLE TUTARLI. `-v` (küçük
harf) ZATEN `build`in AYRINTILI-döküm bayrağı OLDUĞUNDAN (bkz.
`cmdBuild`), ÇAKIŞMAYI ÖNLEMEK İÇİN BİLEREK `-V` (büyük harf)
KULLANILDI. Sürüm METNİ `build.zig.zon`nin `version` alanından TEK
doğruluk kaynağı olarak (Zig'in `build.zig`in KENDİ `build.zig.zon`sunu
comptime struct olarak `@import` edebilme desteği ÜZERİNDEN, `b.
addOptions()` İLE `build_options` modülüne AKTARILARAK) TÜRETİLİR —
İKİNCİ bir yerde YİNELENMEZ.

**Doğrulama:** `tests/cli/subcommand_test.zig`ye YENİ bir golden test
— `version`/`--version`/`-V` ÜÇÜNÜN de AYNI `"noxc <sürüm>\n"` satırını
(bu dosyanın İLK testindeki AYNI notla TUTARLI olarak `std.debug.print`
KULLANDIĞINDAN stdout DEĞİL **stderr**e) bastığını doğrular.

**Kasıtlı boz→kırmızı→düzelt:** `cmdVersion`in çıktısından `"noxc "`
öneki GEÇİCİ olarak KALDIRILDI — YENİ test (`startsWith(u8, stderr,
"noxc ")`) TAM OLARAK BEKLENEN şekilde KIRMIZI oldu (403/404), BAŞKA
HİÇBİR test ETKİLENMEDİ. Değişiklik `diff` İLE bayt-bayt ÖZDEŞLİĞİ
doğrulanarak GERİ YÜKLENDİ, Debug + ReleaseFast YENİDEN yeşile döndü.

**Bilinçli v1 sınırlaması:** `.github/workflows/release.yml`/`install.sh`
BİZZAT `zig build test` KAPSAMINA GİRMEZ (CI/betik kodudur, birim test
YOKTUR) — doğrulama şu ana kadar (1) YAML/shell sözdizim denetimi
(`python3 -c "import yaml..."`/`bash -n`), (2) `noxc --version`in
GERÇEK derlenip ÇALIŞTIRILARAK test EDİLMESİYLE sınırlıdır; GERÇEK bir
uçtan uca `install.sh` çalıştırması (GERÇEK bir GitHub Release'e karşı)
İLK `v1.0.0` etiketi/sürümü YAYIMLANANA kadar MÜMKÜN DEĞİLDİR.

`zig build test` (Debug + ReleaseFast) 404/404 yeşil, `zig fmt` temiz.

**SONRADAN bulunan GERÇEK bir CI/Release hatası (bu bölüm YAYIMLANDIKTAN
HEMEN SONRA, `v1.0.0` etiketinin İLK denemesinde GERÇEKTEN gözlemlendi —
kod DEĞİL, ALTYAPI hatası):** `mlugg/setup-zig@v1` eylemi, `ci.yml`/
`release.yml`nin İKİSİNDE de Zig kurulum adımını ~1 dakikada `404`/`503`
İLE ÇÖKERTTİ — İLK bakışta bir ağ kesintisi GİBİ göründü, ama
`ziglang.org/download/index.json` DOĞRUDAN sorgulanarak KANITLANDI:
`0.16.0` GERÇEKTEN VAR VE ERİŞİLEBİLİR (`https://ziglang.org/download/
0.16.0/zig-<mimari>-0.16.0.tar.xz`, `200`), AMA `mlugg/setup-zig@v1`nin
"official" YEDEK URL'si (mirror'lar TÜKENDİĞİNDE denenen SON adım)
KOŞULSUZ olarak `ziglang.org/builds/...`yi DENİYOR — bu yol SADECE
`master` dev-snapshot'ları İÇİN doğrudur (`0.16.0-dev.XXX+hash` GİBİ),
GERÇEK/etiketli bir sürüm (`"0.16.0"`) İÇİN her zaman `404` DÖNER. TÜM
topluluk mirror'ları O SIRADA AYRICA `404`/`503` verdiğinden (muhtemelen
GERÇEK bir geçici kesinti), İLK denemede kök neden GİZLENDİ — ama
`ziglang.org/builds/` yolunun HİÇBİR ZAMAN etiketli sürümler İÇİN doğru
OLMADIĞI kanıtlandığından, BU ASLA güvenilir OLMAYACAKTI (mirror'lar
GERİ gelse BİLE "official" son-çare yolu HER ZAMAN yanlış kalacaktı).
**Düzeltme:** `mlugg/setup-zig@v1` bağımlılığı HER İKİ workflow'dan da
ÇIKARILDI — `qbe`nin ZATEN KULLANDIĞI AYNI "doğrudan `curl`+`tar`" deseni
Zig İÇİN de uygulandı (matrise `zig_arch` alanı eklenerek, `ziglang.org`ın
KENDİ `index.json`ında doğrulanan dosya adı kalıbıyla), `$GITHUB_PATH`a
eklenerek. Üçüncü-taraf eylem YERİNE resmi kaynağa DOĞRUDAN, sabit bir
URL şablonuyla bağlanmak — `qbe`nin kaynaktan derleme adımıyla TUTARLI
bir mimari karar. `v1.0.0` etiketi (henüz HİÇBİR YERE yayımlanmamış
OLDUĞUNDAN, dış bir tüketicisi OLMADAN) düzeltilmiş commit'e TAŞINDI
(kullanıcı onayıyla — uzak bir etiketi silmek Claude Code'un otomatik
sınıflandırıcısı TARAFINDAN AÇIKÇA onay GEREKTİREN bir işlem olarak
İŞARETLENDİ, doğru bir güvenlik DAVRANIŞI), `release.yml` BAŞARIYLA
çalışıp 3 platform İÇİN 6 varlık (`.tar.gz` + `.sha256`) yayımladı.

**İKİNCİ, `install.sh`nin KENDİSİNDE bulunan GERÇEK bir hata (kullanıcı
raporu — "otomatik kurulum scripti de çalışmıyor"):** `resolve_version`
İÇİNDEKİ `curl | grep | sed` ZİNCİRİ, `set -euo pipefail` AKTİFKEN,
`grep` HİÇBİR ŞEY BULAMADIĞINDA (henüz Release YOKKEN — TAM OLARAK BU
oturumda GERÇEKLEŞEN durum — YA DA API'ye erişilemediğinde) betiği
BİR SONRAKİ satırdaki `[ -n "$tag" ] || die "..."` KONTROLÜNE HİÇ
ULAŞMADAN, `pipefail`in KENDİSİ YÜZÜNDEN SESSİZCE/anlaşılmaz bir hatayla
SONLANDIRIYORDU — özenle yazılmış YARDIMCI hata mesajı ASLA
GÖRÜNMÜYORDU. **Düzeltme:** `curl` yanıtı ÖNCE AYRI bir değişkene
(`|| true` İLE `pipefail`i o adımda ETKİSİZLEŞTİREREK) alınır, SONRA
`grep`/`sed` (AYNI ŞEKİLDE `|| true` İLE) ayrıştırılır — böylece boş/
bulunamayan SONUÇ HER ZAMAN `die`in AÇIK mesajına ULAŞIR. **Genel ders
(TÜM gelecekteki kabuk betikleri İÇİN geçerli):** `set -e`/`pipefail`
AKTİFKEN bir `curl | grep | ...` ZİNCİRİNİN SONUCUNU KENDİ `if`/`[ ]`
kontrolünüzle DEĞERLENDİRMEK İSTİYORSANIZ, ZİNCİRİN HER ADIMINI (özellikle
"hiçbir eşleşme YOK" durumu SIFIRDAN FARKLI çıkış kodu ÜRETEN `grep`i)
`|| true` İLE KORUMANIZ GEREKİR — AKSİ HALDE KONTROLÜNÜZ HİÇBİR ZAMAN
ÇALIŞTIRILMAZ, kabuk SESSİZCE (`set -e`in KENDİSİ TARAFINDAN) SONLANIR.
Gerçek bir uçtan uca doğrulamayla (yayımlanmış `v1.0.0` varlığı
İNDİRİLİP `tar` İLE açılıp `noxc --version`/GERÇEK bir `.nox` dosyası
DERLENİP ÇALIŞTIRILARAK) `install.sh`nin ARTIK doğru sürümü ÇÖZDÜĞÜ VE
paketin TAM olarak İŞLEVSEL olduğu KANITLANDI (`install.sh`nin KENDİSİ,
`~/.nox-lang`i/shell rc'yi DOKUNMAMAK İÇİN, DOĞRUDAN ÇALIŞTIRILMADI —
paket AYRI, izole bir dizine elle açılıp DOĞRULANDI).

## 3.54 Faz CC.2.1 — `noxc fetch`/`noxc update`: Gerçek İmplementasyon

**Kaynak:** kullanıcının "sonraki aşama geliştirmeler" listesinin #1
maddesi ("NOXC CLI tool geliştirmeleri") — Faz O §P.5'ten beri REZERVE
bırakılan (yalnızca "henuz uygulanmadi" basıp exit 1 dönen) `fetch`/
`update` alt komutları için ilk somut adım.

**`resolveDependencies` — YENİ, PAYLAŞILAN bir çekirdek:**
`resolveImportsForBuild`in (bkz. §3.6.7) `requires[]` çözme döngüsüyle
AYNI mantığı taşır, ama **BİLİNÇLİ olarak O fonksiyona DOKUNULMADI** —
zaten test edilmiş/load-bearing bir yolu riske ATMAMAK için AYRI bir
fonksiyon yazıldı (`nox.thread`/`ThreadChannel` fazlarının AYNI "mevcut
load-bearing koda dokunmadan yanına ekle" disiplini). `force_refetch`
parametresi İKİ modu ayırt eder:
- `false` (`fetch`): ZATEN kilitli+önbellekte mevcut bir bağımlılığa HİÇ
  dokunulmaz (`.cached` sonucu).
- `true` (`update`): HER bağımlılık `req.ref`den KOŞULSUZ yeniden
  çözülür (Go'nun `go get -u`suyla AYNI kavram) — `git` HER durumda
  ÇAĞRILIR, ama SONUÇ AYNI SHA'ya çözülürse (`ref` ZATEN bir SHA'ysa ya
  da dal HİÇ ilerlemediyse) `.unchanged` olarak işaretlenir (`.updated`
  DEĞİL — doğru bir özet basılabilsin diye).

**`noxc fetch`:** proje kökündeki (CWD'den yukarı yürüyerek bulunan)
`nox.json`daki `requires[]`i önbelleğe DOLDURUR — bir `.nox` dosyası
DERLEMEDEN. Her bağımlılık için `getirildi: <alias> (<repo>@<kısa-sha>)`
ya da `zaten guncel: <alias> (<kısa-sha>)` basar, bir özetle biter.

**`noxc update`:** `fetch`in AKSİNE HER bağımlılığı YENİDEN çözer,
`nox.lock`taki kilitli SHA'ları GÜNCELLER. `guncellendi: <alias> <eski-
sha> -> <yeni-sha>` / `degismedi: <alias> (<sha>)` basar.

**GERÇEKTEN test edilip bulunan İKİ hata (ikisi de kendi yazdığım YENİ
testlerde, ürün kodunda DEĞİL):**
1. `tests/cli/package_resolution_test.zig`ye eklenen `addFixtureCommit`
   yardımcısı `std.Io.Dir.openAbsolute`yi ÇAĞIRIYORDU — bu API BU Zig
   sürümünde YOK. Düzeltme: `project.zig`nin `saveLockfile`i GİBİ,
   `Dir.cwd()`e MUTLAK bir `sub_path` geçmek (bu API'nin ZATEN SAYDAM
   olarak desteklediği, kanıtlanmış desen).
2. **DAHA ÖNEMLİ, `.cwd` KULLANAN HER GELECEKTEKİ test İÇİN geçerli bir
   ders:** YENİ `fetch`/`update` testleri, alt süreci fixture proje
   KÖKÜNDE çalıştırmak İÇİN `std.process.run`a `.cwd = .{ .path =
   proj_path }` geçiyordu — AMA `noxc`nin argv[0]'ı `noxcPath()`nin
   döndürdüğü GÖRELİ `"zig-out/bin/noxc"` idi. GÖRELİ bir argv[0], test
   SÜRECİNİN DEĞİL `.cwd` İLE VERİLEN YENİ çalışma dizinine göre
   çözülür — bu yüzden `<proj_path>/zig-out/bin/noxc` (YOK) ÇALIŞTIRILMAYA
   ÇALIŞILIYORDU, `processSpawnPosix` İLE (ENOENT-benzeri) ÇÖKÜYORDU.
   Düzeltme: YENİ bir `noxcAbsPath(io, a)` yardımcısı (`std.process.
   currentPathAlloc` + `std.fs.path.join`) — **`.cwd` KULLANAN HER çağrı
   sitesi BUNDAN SONRA mutlak yol KULLANMALIDIR**, bu genel bir kural
   olarak belgelendi.

**Doğrulama:** `tests/cli/package_resolution_test.zig`ye 2 YENİ uçtan uca
test — `noxc fetch` (bağımlılığı getirip `nox.lock` yazması, İKİNCİ
çalıştırmanın fixture repo'nun `.git`i SİLİNDİKTEN SONRA BİLE önbellekten
[offline] geçmesi) ve `noxc update` (fixture repo'ya İKİNCİ bir commit
eklenip `nox.lock`taki kilitli SHA'nın YENİ commit'e güncellendiğinin
doğrulanması — eski SHA'nın ARTIK lock'ta GÖRÜNMEDİĞİ dahil).
`tests/cli/subcommand_test.zig`deki ESKİ "henuz uygulanmadi" testi,
ARTIK geçerli olmayan davranışı sınadığından, "nox.json bulunamayan bir
dizinden çalıştırılırsa net hatayla başarısız olur" testine DÖNÜŞTÜRÜLDÜ.

**Kasıtlı boz→kırmızı→düzelt:** `resolveDependencies`in `force_refetch`
KONTROLÜ GEÇİCİ olarak DEVRE DIŞI BIRAKILDI (`if (false and
!force_refetch)`) — `fetch`in "ikinci çalıştırma önbellekten (offline)
geçer" testi TAM OLARAK BEKLENDİĞİ ŞEKİLDE KIRMIZI oldu (405/406, silinen
`.git`e karşı YENİDEN `git` çağırmaya ÇALIŞTIĞINDAN), BAŞKA HİÇBİR test
ETKİLENMEDİ. Değişiklik `diff` İLE bayt-bayt ÖZDEŞLİĞİ doğrulanarak GERİ
YÜKLENDİ, Debug + ReleaseFast (TEKRARLANAN soğuk-önbellek çalıştırmalarıyla,
bkz. §3.55) YENİDEN yeşile döndü.

## 3.55 Faz CC.2.1 (addendum) — CI'de GERÇEK, Tekrarlanabilir Bir Soğuk-Önbellek Yarış Durumu

**Kaynak:** kullanıcının GERÇEK bir CI çalıştırmasında GÖZLEMLEDİĞİ
"test buildler takılıyor" raporu — `noxc fetch`/`update` çalışmasının
GERÇEK CI ortamında doğrulanması SIRASINDA keşfedildi.

**Bulgu — %100 yerel olarak TEKRARLANABİLİR:** `rm -rf .zig-cache zig-out
&& zig build test` (TEK bir komut, TAMAMEN temiz bir önbellekten) `noxc`/
`noxlsp`yi bir ALT SÜREÇ olarak ÇAĞIRAN test dosyalarında (`tests/cli/
*.zig` — `noxc fetch`/`update`e ÖZGÜ DEĞİL, ÖNCEDEN VAR OLAN `lsp_test.
zig` BİLE etkilendi) `processSpawnPosix`/`child_err` İLE ÇÖKÜYORDU.
`test_step.dependOn(&install_noxc.step)`/`&install_noxrt.step` GİBİ
Step-seviyesi bağımlılıklar (bkz. build.zig) DOĞRU KURULU olsa BİLE —
bu, `zig build test`in KENDİ İÇ `install_noxc`/`install_noxrt`
adımlarının TAMAMLANMASI İLE test ikililerinin bu KURULU ikiliyi
ÇAĞIRMASI ARASINDA GERÇEK bir yarış durumudur (muhtemelen: `zig build
test`in TEK bir çağrısı İÇİNDE, `install_*` adımları İLE test-artifact
çalıştırma adımları arasında Zig'in build-graph zamanlamasının, HENÜZ
TAM olarak anlaşılmamış bir nedenle, "step tamamlandı" VE "dosya
sistemine GERÇEKTEN YAZILDI/GÖRÜNÜR" ARASINDAKİ farkı garanti ETMEMESİ).

**Düzeltme — İKİ AYRI komut (TEK `zig build test` çağrısı DEĞİL):** HER
mod (Debug/ReleaseFast) İÇİN önce SALT `zig build` (o `-Doptimize` İLE,
TÜM `install_*` adımlarını TAMAMEN BİTİRİR), SONRA (AYRI bir komut
olarak) `zig build test` (AYNI mod). İkinci komut çalıştığında `install_
noxc`/`install_noxrt` ZATEN TAMAMLANMIŞ/önbelleklenmiş (no-op)
OLDUĞUNDAN, yarış PENCERESİ TAMAMEN KAPANIR — bu, `ci.yml`de UYGULANDI
VE yerel olarak `rm -rf .zig-cache zig-out && zig build && zig build
test` (Debug + ReleaseFast, İKİŞER kez TEKRARLANARAK) İLE DOĞRULANDI:
sıfır çökme, 406/406 yeşil, HER seferinde.

**Bilinçli v1 gözlemi (AÇIKÇA belgelenir):** bu, `zig build test`in
KENDİ iç zamanlamasının TAM kök nedeni (Zig'in build sistemi İÇİNDE)
DERİNLEMESİNE araştırılmadı — pragmatik, GERÇEKTEN doğrulanmış bir
mimari İŞ-AROUND (iki AYRI komut) uygulandı. Bu, `docs/uretim-hazirlik-
analizi.md`nin/geçmiş faz notlarının (Faz O §P.2/§P.3) "noxc TAZE
derlendikten SONRAKİ İLK zig build test bazen bir CLİ testini başarısız
gösteriyor" ŞEKLİNDE daha önce de GÖZLEMLENMİŞ (ama YEREL geliştirmede
ILIK önbellek YÜZÜNDEN NADİR görülen) AYNI kök sorunun, HER ZAMAN soğuk
başlayan CI'de ARTIK NORM haline geldiğinin KANITIDIR.

`zig build test` (Debug + ReleaseFast, soğuk önbellekten TEKRARLANAN
çalıştırmalarla) 406/406 yeşil, `zig fmt` temiz.

## 3.56 Faz CC.2.2 — `noxc init`/`noxc check`

**Kaynak:** kullanıcının "sonraki aşama geliştirmeler" listesinin #1
maddesi ("NOXC CLI tool geliştirmeleri") — Faz CC.2.1'in (§3.54) HEMEN
ardından, AYNI AskUserQuestion yanıtında SEÇİLEN kalan iki madde.

**`noxc init [proje-adi]`:** Cargo/Go tarzı proje iskeleti oluşturucu.
Argüman VERİLMEZSE (`cargo init` deseni) CWD'nin KENDİSİNDE, CWD'nin
taban adını proje adı olarak KULLANARAK; VERİLİRSE (`cargo new` deseni)
O adla YENİ bir alt dizin OLUŞTURUP İÇİNDE başlatır. Üretir: `nox.json`
(`{"name": "...", "entry": "main.nox"}`), `main.nox` (`print("merhaba,
nox!")`), `.gitignore` (`.nox/` + `main` — `nox.lock` KASITLI olarak
İGNORE EDİLMEZ, bkz. `project.zig`nin "VCS'e commit edilir" notu).
`nox.json` ZATEN VARSA ÜZERİNE YAZILMAZ (net bir hatayla exit 1) — var
olan bir projeyi YANLIŞLIKLA silmemek İçin. `.gitignore` ZATEN VARSA
(ör. GİT deposu olan bir dizinde) DOKUNULMAZ.

**`noxc check <dosya.nox>`:** SADECE lex→parse→import çözümü→tip
denetimi çalıştırır — ownership analizi/codegen/`qbe`/`cc` (`buildOne`in
AKSİNE) HİÇ TETİKLENMEZ. Editör entegrasyonu/hızlı geri bildirim İÇİN —
`noxc build`in TAM derleme MALİYETİNE (bir native binary ÜRETMEK)
katlanmadan "bu dosya GEÇERLİ mi?" sorusunu YANITLAR. `buildOne`in AYNI
ÖN EKİNİ (lex/parse/import-çözümü/checker) BİLİNÇLİ olarak YİNELER (AYRI
bir fonksiyon — `buildOne`a "codegen'e kadar mı gidilsin" bayrağı
EKLEMEK yerine, o ZATEN karmaşık fonksiyonu daha da dallandırmamak İçin
— M.5/M.8'in "gereksiz karmaşıklık eklenmez" disipliniyle TUTARLI).

**Doğrulama:** `tests/cli/subcommand_test.zig`ye 3 YENİ uçtan uca test —
`init` (argümansız, üretilen projenin GERÇEKTEN `noxc build` +
ÇALIŞTIRILABİLİR olduğu — yalnızca dosyaların VARLIĞI değil, İÇERİKLERİNİN
de GEÇERLİ olduğu kanıtlanır — VE ikinci `init` çağrısının reddedildiği),
`init` (isimli, YENİ bir alt dizinde doğru `name` alanıyla), `check`
(GEÇERLİ dosyada `.ssa`/ikili HİÇBİR ARTIFACT ÜRETMEDEN başarılı, tip
hatalı dosyada net bir hatayla BAŞARISIZ).

**Kasıtlı boz→kırmızı→düzelt:** `cmdInit`in "nox.json ZATEN VAR" kontrolü
GEÇİCİ olarak DEVRE DIŞI BIRAKILDI (`if (false) { ... }`) — İKİNCİ `init`
çağrısının REDDEDİLMESİNİ sınayan test TAM OLARAK BEKLENEN ŞEKİLDE
KIRMIZI oldu (408/409), BAŞKA HİÇBİR test ETKİLENMEDİ. Değişiklik `diff`
İLE bayt-bayt ÖZDEŞLİĞİ doğrulanarak GERİ YÜKLENDİ, Debug + ReleaseFast
YENİDEN yeşile döndü.

`zig build test` (Debug + ReleaseFast) 409/409 yeşil, `zig fmt` temiz.

## 3.57 Linux/x86-64'e Özgü CI Hataları — Gerçek Bir Yarış Durumu + PIE Link Hatası

**Kaynak:** kullanıcının "üçünü de şimdi çöz" kararı — Faz CC.2.1'in
(§3.55) soğuk-önbellek yarış düzeltmesi GERÇEK CI'de doğrulanırken,
YALNIZCA Linux/x86-64 platformunda (macOS/aarch64 VE Linux/aarch64
ETKİLENMEDİ) üç ayrı hata GÖZLEMLENDİ.

**1. GERÇEK bir yarış durumu — `runtime/stdlib_shims/http_client.zig`nin
`workerThreadFn`i (KÖK NEDEN, İKİ AYRI gözlemlenen belirtiyi AÇIKLAR):**
`nox_http_serve_raw`ın "eşzamanlı iki bağlantı" testinde bir SEGFAULT
(`std.c.close(ctx.write_fd)`de, `workerThreadFn`in `defer` bloğunda) VE
`http_stdlib_golden_test.zig`nin İKİ `nox.http.get` testi (`ProgramFailed`)
GÖZLEMLENDİ — İKİSİ de AYNI kök nedene İNDİRGENDİ. `workerThreadFn`in
`defer` bloğu İKİ işlem yapıyordu: (a) `write(ctx.write_fd, ...)`
(ÇAĞIRANA — `doRequest`nin pipe'ı OKUYAN tarafına — TAMAMLANMA sinyali
GÖNDERİR), (b) `close(ctx.write_fd)`. **`write()` TAMAMLANDIĞI ANDA
ÇAĞIRAN UYANIR** ve `ctx`yi (`gpa.destroy(ctx)` İLE, `rt` yıkıldığında)
serbest BIRAKABİLİR — TAM O SIRADA AYNI `defer` bloğu HÂLÂ `close(ctx.
write_fd)` İÇİN `ctx`yi DEREFERANS ETMEYE çalışıyorsa, ARTIK SERBEST
BIRAKILMIŞ belleği OKUR (kullanım-sonrası-serbest, KLASİK "sinyal-SONRA-
paylaşılan-duruma-dokun" yarışı). Bu, macOS/aarch64de HİÇ (bu OTURUM
BOYUNCA) GÖZLEMLENMEDİ — Linux/x86-64nin FARKLI iş parçacığı zamanlama
DAVRANIŞI yarış PENCERESİNİ GÜVENİLİR şekilde AÇTI. **Düzeltme:**
`write_fd`, fonksiyon GİRİŞİNDE YEREL bir değişkene KOPYALANIR, `defer`
bloğu `ctx.write_fd` YERİNE bu YEREL kopyayı KULLANIR — sinyal
YAZILDIKTAN SONRA `ctx`ye HİÇ dokunulmaz, yarış PENCERESİ TAMAMEN kapanır.
**Dürüst doğrulama notu:** bu yarış BU OTURUM BOYUNCA yerel olarak (macOS/
aarch64'te) HİÇ TEKRARLANAMADIĞINDAN, standart kasıtlı-boz→kırmızı→düzelt
ritüeli BURADA ANLAMLI bir sinyal VERMEZDİ (yerel bir "kırmızı" ZATEN
GÖSTERİLEMEZ) — düzeltmenin doğruluğu KOD İNCELEMESİYLE (yarış
PENCERESİNİN yapısal olarak KAPATILDIĞI) VE GERÇEK Linux/x86-64 CI'de
YENİDEN ÇALIŞTIRMAYLA doğrulanır.

**2. PIE link hatası — `tests/compat/zig_ext/util.o`:**
`relocation R_X86_64_32S against \`__anon_1490' can not be used when
making a PIE object; recompile with -fPIE`. `build.zig`nin `cc -c` İLE
derlediği C uzantıları (`mathutil.o`/`counter.o`) dağıtımın PIE-varsayılan
`cc` yapılandırmasını KENDİLİĞİNDEN devralır — AMA `util.o`, `zig
build-obj` İLE (AYRI bir araç zinciri, SİSTEM `cc`nin varsayılanlarına
BAĞLI DEĞİL) derleniyordu, `-fPIC` OLMADAN. Sonuç: PIC-UYUMSUZ
relokasyonlar, SONRA PIE-varsayılan bir `cc`ye BAĞLANMAYA ÇALIŞILINCA
link HATASI. **Düzeltme:** `compile_zig_ext`in argv'sine `-fPIC` eklendi
(macOS/aarch64'te ZARARSIZ bir no-op — kod ZATEN PIC).

**3. `nox.http.get` altın (golden) testleri — AYRI bir hata DEĞİL:**
madde 1'in (`workerThreadFn` yarışı) DOĞRUDAN sonucu olduğu
DEĞERLENDİRİLDİ — HER İKİ başarısız test de `nox.http.get`i (TAM OLARAK
düzeltilen `doRequest`/`workerThreadFn` yolunu) KULLANIYORDU. AYRI bir
kod değişikliği GEREKMEDİ, madde 1'in düzeltmesiyle KAPSANIYOR.

**Bilinçli v1 gözlemi:** bu üç hata, `noxc fetch`/`update`/`init`/`check`
İLE (Faz CC.2.1/CC.2.2) HİÇBİR İLGİSİ OLMAYAN, TAMAMEN ÖNCEDEN VAR OLAN
kusurlardı — Linux/x86-64 CI'nin bu turdan ÖNCE HİÇBİR ZAMAN bu kadar
İLERİ (gerçek test yürütmesine kadar) ULAŞAMADIĞI (önceki iki blokaj —
`mlugg/setup-zig` VE soğuk-önbellek yarışı, bkz. §3.53/§3.55 — DAHA
ERKEN bir NOKTADA HER ZAMAN durduruyordu) İÇİN daha ÖNCE HİÇ GÖRÜNÜR
OLMAMIŞLARDI. Bu, Linux/x86-64 CI legi GERÇEKTEN GÖRÜNÜR bir yeşil
duruma ULAŞTIĞINDA ortaya ÇIKAN ilk gerçek platform-özgü sağlamlaştırma
turudur.

**Addendum — DÖRDÜNCÜ bir hata, madde 1/2'nin düzeltmesinden HEMEN SONRA
GERÇEK CI'de GÖZLEMLENDİ (macOS/aarch64 VE Linux/aarch64 BU SEFER
TAMAMEN yeşildi, YALNIZCA Linux/x86-64 TEK bir test kırmızıydı):**
`nox_http_get_raw: bir fiber İÇİNDEN çağrıldığında zamanlayıcı BLOKE
OLMAZ` testi "diger fiber calisti" (askıya alma GERÇEKLEŞTİĞİNİN kanıtı)
YERİNE "istek tamamlandi"yi İLK sırada BULDU. **Kök neden:** testin
YEREL (loopback) sunucusu (`testServeOnce`) YANITI HİÇBİR gecikme
OLMADAN ANINDA yazıyordu — Linux/x86-64 CI'de bazen TÜM istek/yanıt
DÖNGÜSÜ, zamanlayıcının `nonBlockingRead`in İLK denemesini yapıp `EAGAIN`
GÖZLEMLEMESİNDEN (dolayısıyla fiber'ın GERÇEKTEN `suspendForIo`ya
düşmesinden) DAHA HIZLI tamamlanabiliyordu — bu durumda istek fiber'ı
HİÇ askıya ALINMADAN (BAŞKA fiber'a GEÇİŞ OLMADAN) TEK SEFERDE
tamamlanıyordu. **Bu, `http_server.zig`nin "yavaş istemci" testinin (150ms `nanosleep`,
İSTEMCİ tarafında — bkz. bu bölümün 1. maddesindeki segfault tartışması,
AYNI test) ZATEN ÇÖZDÜĞÜ AYNI kategori sorunun, sunucu TARAFINDA hiç
UYGULANMAMIŞ HALİYDİ.**
**Düzeltme:** `testServeOnce`, YENİ bir `testServeOnceDelayed(listen_fd,
delay_ms)`in `delay_ms=0` sarmalayıcısına DÖNÜŞTÜRÜLDÜ (DİĞER, ETKİLENMEYEN
çağıranın davranışı DEĞİŞMEDİ); başarısız test, `http_server.zig`nin
KENDİ testiyle AYNI `150` ms değeriyle `testServeOnceDelayed`i KULLANACAK
ŞEKİLDE güncellendi — yanıt YAZILMADAN ÖNCE KASITLI bir gecikme, İLK
`nonBlockingRead` denemesinin GERÇEKTEN `EAGAIN` GÖZLEMLEMESİNİ (dolayısıyla
askıya almanın GERÇEKTEN GERÇEKLEŞMESİNİ) GARANTİ eder. Yerel olarak
(ardışık ÜÇ tekrarla) Debug + ReleaseFast'ta doğrulandı; NİHAİ doğrulama
(bu da yerel olarak tekrarlanamayan bir zamanlama BAĞIMLILIĞI
OLDUĞUNDAN) GERÇEK Linux/x86-64 CI'de.

## 3.58 Faz CC.2.3 — Renkli/Daha Okunabilir CLI Çıktısı

**Kaynak:** kullanıcının "sonraki aşama geliştirmeler" listesinin #1
maddesi ("NOXC CLI tool geliştirmeleri") — Faz CC.2.1/CC.2.2'nin (§3.54/
§3.56) ARDINDAN, AYNI AskUserQuestion yanıtında SEÇİLEN SON madde.

**Tasarım:** `main()`de BİR KEZ hesaplanan süreç-geneli bir `g_use_color`
bayrağı — iki KOŞUL: (1) `NO_COLOR` ortam değişkeni AYARLI DEĞİLSE (bkz.
no-color.org, geniş çapta SAYGI görülen bir standart), (2) `std.Io.File.
stderr().supportsAnsiEscapeCodes(io)` `true` dönerse (GERÇEK bir terminale
BAĞLIYSA — ör. bir dosyaya/pipe'a YÖNLENDİRİLMİŞSE OTOMATİK OLARAK devre
DIŞI kalır, script/CI tüketicileri HER ZAMAN ham metin GÖRÜR). `printErr`/
`printOk` — `std.debug.print`in İKİ İNCE sarmalayıcısı, `g_use_color`
İSE `fmt`i KIRMIZI/YEŞİL ANSI kaçış dizileriyle SARAR — TÜM mesajlar HER
ZAMAN stderr'e yazıldığından (bkz. modül üstü not) tespit de stderr
ÜZERİNDEN yapılır.

**Kapsam:** checker tip hataları (`tip hatasi`, EN sık GÖRÜLEN mesaj) VE
"tip hatasi yok" (KIRMIZI/YEŞİL), `derlendi`/`olusturuldu` (YEŞİL),
`qbe`/`cc` başarısızlıkları, TÜM "bulunamadı"/"okunamadi"/"gecersiz"/
"getirilemedi" hata yolları (KIRMIZI), `noxc test`in `GECTI`/`BASARISIZ`
satırları VE ÖZET satırı (BAŞARISIZ SAYISINA göre KOŞULLU KIRMIZI/YEŞİL).
Kullanım (`kullanim: ...`)/sürüm/GENEL BİLGİ mesajları BİLİNÇLİ olarak
renklendirilMEDİ (gerçek hata/başarıyla GÖRSEL olarak REKABET etmesinler
diye).

**Doğrulama:** manuel olarak `script(1)` (GERÇEK bir sanal TTY tahsis
ederek) İLE hem KIRMIZI/YEŞİL ANSI kodlarının GERÇEKTEN yayıldığı HEM
`NO_COLOR=1`in bunu GÜVENİLİR şekilde BASTIRDIĞI doğrulandı. YENİ bir
OTOMATİK test (`tests/cli/subcommand_test.zig`) — `std.process.run`ın
YAKALADIĞI stdout/stderr HER ZAMAN bir BORU HATTIDIR (gerçek bir TTY
DEĞİL) — bu GÜVENLİ VARSAYILAN davranışın (renklendirme OTOMATİK devre
dışı, script/CI tüketicileri ham metin GÖRÜR) `\x1b` (ESC) baytı hiç
SIZMADIĞINI AÇIKÇA doğrular.

**Kasıtlı boz→kırmızı→düzelt:** `detectUseColor`, GEÇİCİ olarak
KOŞULSUZ `true` DÖNECEK ŞEKİLDE bozuldu (TTY/`NO_COLOR` kontrolünün
İKİSİ de ATLANARAK) — YENİ test TAM OLARAK BEKLENEN ŞEKİLDE KIRMIZI
oldu (409/410, `result.stderr`de bir `\x1b` baytı GERÇEKTEN BULUNDU),
BAŞKA HİÇBİR test ETKİLENMEDİ. Değişiklik `diff` İLE bayt-bayt ÖZDEŞLİĞİ
doğrulanarak GERİ YÜKLENDİ, Debug + ReleaseFast YENİDEN yeşile döndü
(TEK, doğrudan `zig build test` çalıştırmasıyla — `| tail` ile boru
hattına ALINMIŞ bir komutun ÇIKIŞ KODUNUN, `tail`in KENDİ çıkış koduyla
MASKELENEBİLECEĞİ, GERÇEKTEN gözlemlenen bir doğrulama tuzağı — bu
doğrulama YÖNTEMİ genel bir ders olarak NOT edilir).

`zig build test` (Debug + ReleaseFast) 410/410 yeşil, `zig fmt` temiz.

## 3.59 Faz M.8 (Yeniden Ele Alınıyor) — Metod Çağrıları İçin İstisna-Kontrolü Eleme

**Kaynak:** kullanıcının "sonraki aşama geliştirmeler" listesinin #2
maddesi ("Dil Performans artışı"). Dil stabilizasyonu fazının (§3.30
civarı, M serisi) M.8'i DAHA ÖNCE "hiçbir ölçüm bunun GERÇEKTEN darboğaz
OLDUĞUNU göstermedi" gerekçesiyle ERTELEMİŞTİ. Bu turda, kullanıcının AÇIK
isteğiyle İZOLE bir mikro-benchmark yazılıp GERÇEKTEN ölçüldü (`genMethodCall`
deki `emitExceptionCheck` çağrısı GEÇİCİ olarak KALDIRILIP GERİ KONULDU,
kod deposunda kalıcı bir değişiklik YAPILMADI): metod çağrısı, kontrol İLE
300M çağrıda ~1.28ns/çağrı; kontrol DENEYSEL olarak KALDIRILINCA
~0.75ns/çağrı — **~%41'lik GERÇEK, ÖLÇÜLMÜŞ bir kazanç**. M.8'in ERTELENME
gerekçesi ARTIK GEÇERLİ DEĞİL.

**Kritik kısıt (M.1'İN AYNI ilkesi):** yanlış negatifte istisna ASLA
YUTULMAZ, yalnızca gereksiz bir kontrol FAZLADAN kalabilir. Her belirsiz
durumda MUHAFAZAKÂR davranış (kontrolü KORUMAK) tercih edilir.

**Araştırma sırasında bulunan, ÖNCEDEN VAR OLAN GERÇEK bir açık (Plan
agent doğrulamasıyla KEŞFEDİLDİ, AYNI turda düzeltildi):**
`collectRaiseInfoExpr`'in `.call => .identifier` dalı, isim ne
`self.classes` ne `self.functions` (ne örtük print/len/str/hpy_call/
wasm_call/extern) ile eşleşmezse (ör. İÇ İÇE bir closure/`def inner(): ...`)
SESSİZCE hiçbir şey YAPMIYORDU — ne `direct_unsafe` işaretliyor NE
`callees`e ekliyordu. Bu, İÇİNDE SADECE raise EDEN bir closure çağrısı
olan bir fonksiyonun YANLIŞLIKLA "güvenli" sayılmasına yol açabilen,
GERÇEKTEN doğrulanmış bir hataydı (`tests/golden/codegen_cases/
closure_raise_not_swallowed.nox` — düzeltmeden ÖNCE KIRMIZI). Düzeltme:
AÇIK bir izin listesi (`genCall`in KENDİ özel dispatch'iyle BİREBİR AYNI
küme) DIŞINDA kalan HER isim `direct_unsafe = true` yapar (`bilinmeyen =
güvenli` YERİNE `bilinmeyen = güvensiz`).

**Uygulama:**

1. **`computeMustNotRaise` TÜM metodları analiz eder** (yalnızca
   `__init__` DEĞİL) — `cd.methods`deki HER metod, sembol formatı TÜM
   metodlar İçin `"{class_name}_{method_name}"` (`__init__`in ESKİ
   `"{s}___init__"` formatı ZATEN AYNI formülün özel durumuydu —
   `"_"+"__init__"` = `"___init__"`, `genMethod`/`genMethodCall`in KENDİ
   ÇAĞRI/TANIM sembolüyle BİREBİR eşleşir).

2. **`var_types` izleme** — `collectRaiseInfoStmts`/`collectRaiseInfoStmt`/
   `collectRaiseInfoExpr`e İKİ yeni parametre eklendi: `class_ctx:
   ?[]const u8` (metodun AİT OLDUĞU sınıf, `self` parametresinin
   ÖN-DOLDURULMASI İÇİN) ve `var_types: *std.StringHashMapUnmanaged
   ([]const u8)` (yerel isim → sınıf adı, `collectLocals`in AYNI DÜZ/
   blok-kapsamsız — Python tarzı fonksiyon-seviyesi kapsam — yürüyüşüyle
   doldurulur). `self`, `genMethod`in KENDİ ele alışıyla TUTARLI olarak
   DOĞRUDAN `class_ctx`e bağlanır (KENDİ `type_expr`ine GÜVENMEZ). Basit
   `Param{type_expr: .simple}` VE `VarDecl{type_expr: .simple}`
   deyimleri (`self.classes.contains(...)` İLE doğrulanarak) `var_types`i
   GÜNCELLER.

3. **Yeniden-bildirim (poisoning) güvenlik kuralı** — `checker.zig`'in
   `Scope.declare`si YİNELENEN isim kontrolü YAPMAZ, bu yüzden `if`/`else`
   dallarında AYNI isim FARKLI sınıflara "yeniden bildirilebilir". Bir isim
   `var_types`e (parametre OLARAK ya da ÖNCEKİ bir `var_decl`dan) ZATEN
   VARSA VE YENİ bir `var_decl` (HANGİ TİPLE OLURSA olsun) AYNI ismi tekrar
   bildirirse, o isim `var_types`den ÇIKARILIR VE bir `poisoned` kümesine
   KALICI olarak eklenir (bir DAHA ASLA `var_types`e girmez). `for`
   döngüsünün KENDİ değişkeni de (tipi BİLİNMEDİĞİNDEN) AYNI kuralla
   zehirlenir — DIŞARIDAN gelen aynı isimli bir sınıf-tipli değişkeni
   gölgeliyor OLABİLİR. Bu, `genMethodCall`in GERÇEKTE çağırdığı sembolle
   bu analizin ÇÖZDÜĞÜ sembolün HER ZAMAN AYNI olmasını garanti eder.

4. **`obj.method()` çözümlemesi** — `collectRaiseInfoExpr`in `.call`
   dalında, callee `.attribute` İSE VE `obj` ÇIPLAK bir `.identifier` İSE
   VE o isim `var_types`de (VE `poisoned` DEĞİLSE) VARSA: sınıf adı
   çözülür, `self.classes.get(class_name).?.methods.contains(method_name)`
   İLE (savunmacı) doğrulanır, `"{class_name}_{method_name}"` `info.
   callees`e EKLENİR (`direct_unsafe` YERİNE — serbest fonksiyon
   çağrılarıyla AYNI muamele). AKSİ HALDE (zincirleme çağrı, attribute-
   of-attribute, index, poisoned/çözülemeyen isim, `self.classes`de
   OLMAYAN bir tip — protokol/generic) MEVCUT `direct_unsafe = true`
   KORUNUR.

5. **`genMethodCall`**, `genCall`in `must_not_raise` kontrolüyle AYNI
   deseni izler: `if (!self.must_not_raise.contains(method_sym)) try
   self.emitExceptionCheck();` — `method_sym` çağrı SİTESİNDE `"{obj.
   class_name.?}_{a.attr}"` OLARAK biçimlendirilir (adım 1'İN sembol
   formülüyle BİREBİR aynı).

**`runDetachedFinally`/`genTry`'ye ETKİSİ:** Faz U.5'in doğrulaması
SIRASINDA bulunan kritik hata (bir `finally`/`with` bloğu, KENDİSİ
`finally_stack`deYKEN doğrudan çalıştırılırsa VE İÇİNDE bir kontrol
üreten çağrı VARSA `drainFinally`nin SONSUZ derleme-zamanı özyinelemesine
yol açması) İÇİN uygulanan düzeltme (`fb`yi ÖNCE `finally_stack`den
POP'layıp SONRA çalıştırmak) GENEL/SAVUNMACIDIR — `fb`nin GERÇEKTEN bir
kontrol üretip üretmediği STATİK olarak varsayılmaz, bu yüzden M.8'in
metod çağrılarını ARTIK KOŞULSUZ güvensiz SAYMAMASI bu düzeltmeyi
GEREKSİZ KILMAZ, dokunulmadı (yalnızca İLGİLİ belge notları GÜNCEL
tutuldu).

**Doğrulama:**

- `tests/golden/codegen_cases/method_indirect_raise_propagation.nox`
  (+`.expected`): EN KRİTİK test — 3 katmanlı bir metod zinciri
  (`self.level2()`→`self.level3()`, VE `compute`nin `c.level1(...)`u
  YEREL bir değişken üzerinden çağırması, HER İKİ çözümleme yolu TEK
  testte), `level3` GERÇEKTEN raise eder, `try/except` İLE doğru
  yakalanır (525 — 5×99 [yakalanan] + Σ(x*2+2), x=0..4 [yakalanmayan]).
- `method_indirect_uncaught_exception.nox`: AYNI zincir, `try/except`
  OLMADAN — net (sıfırdan farklı çıkış koduyla) sonlanır.
- `method_redeclared_var_poisoning.nox`: `obj` ÖNCE `A` SONRA (yalnızca
  `if` dalında) `B` olarak yeniden bildirilir — `poisoned` kuralı
  tetiklenir, davranış (doğru sınıfın metodunun çağrılması) DEĞİŞMEZ.
- `method_call_elision_positive.nox`: `Adder`in HİÇBİR metodu raise
  ETMEZ — `self.` VE yerel değişken üzerinden çağrılar davranış
  değişmeden çalışır.
- **IR-metni doğrulaması** (`codegen_golden_test.zig`, `generateModule`i
  DOĞRUDAN çağıran desen — bkz. Faz T.3'ün dbgfile/dbgloc testlerinin
  AYNI öncülü): `method_call_elision_positive.nox`nin ÜRETTİĞİ IR'da
  `nox_exception_pending`e TEK bir çağrı bile OLMADIĞI DOĞRUDAN
  doğrulanır (elenmenin GERÇEKTEN gerçekleştiğinin kanıtı, yalnızca
  davranışın DEĞİŞMEDİĞİNİN değil) — bu test, çözümleme mantığı GEÇİCİ
  olarak DEVRE DIŞI bırakılarak KIRMIZI olduğu doğrulanıp SONRA GERİ
  YÜKLENEREK (`diff` İLE bayt-bayt ÖZDEŞLİK doğrulanarak) doğru testin
  YAZILDIĞI kanıtlandı — diğer TÜM davranış testleri (elenmeme HÂLİNDE
  YALNIZCA FAZLADAN kontrol kalır, ASLA yanlış davranış) bu devre-dışı-
  bırakma SIRASINDA doğru şekilde YEŞİL KALDI, beklenen (ve M.1/M.8'in
  "yanlış negatifte istisna ASLA yutulmaz" ilkesini SOMUTLAŞTIRAN) sonuç.
- **Performans doğrulaması:** `benchmarks/method_call_elision.nox` (300M
  provably-safe metod çağrısı) — kontrol HER ZAMAN üretilen ESKİ davranışa
  GEÇİCİ dönülerek ölçüldü: 480ms → 270ms, **~%44 hızlanma** (izole
  mikro-benchmarkın ~%41'lik ölçümüyle TUTARLI). Bkz. `benchmarks/
  RESULTS.md`.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

## 3.60 Faz DD.1 — Çok Çekirdekli `nox.http.serve`

**Kaynak:** kullanıcının "sonraki aşama geliştirmeler" listesinin #3
maddesi ("HTTP kütüphane async m:n entegrasyonu ve performans artışı"),
daha önce "Sunucu tarafı: çok-çekirdekli `nox.http.serve`" olarak kapsam
netleştirildi. #1 (CLI, §3.53-§3.58) ve #2 (Faz M.8, §3.59) TAMAMLANDIKTAN
SONRA sıradaki madde.

**Mimari — NEDEN `SO_REUSEPORT`/paylaşılan-kabul-dağıtım YERİNE fd-
paylaşımı:** `nox.http.serve` bugüne kadar TAMAMEN M:1'di (tek OS iş
parçacığı, tek fiber zamanlayıcı, bağlantı başına bare bir fiber — bkz.
`runtime/stdlib_shims/http_server.zig`in modül-üstü notu). GERÇEK bir
*paylaşılan* M:N zamanlayıcıya geçiş (zamanlayıcı tekil-örneği, atomik
olmayan ARC, senkron olmayan havuzlanmış ayırıcı) Faz AA.1'de (§3.46)
somut mimari engeller nedeniyle ERTELENMİŞTİ VE ERTELENMİŞ KALIYOR — bu
faz O YOLU izlemez. Bunun yerine Faz BB.1-BB.6 (`nox.thread`, §3.47-§3.52)
zaten "N BAĞIMSIZ M:1 dünyası, her biri KENDİ OS iş parçacığında" modelini
KANITLANMIŞ şekilde sağlıyor — her `nox.thread.start` çağrısı KENDİ
`RuntimeState`+`Scheduler`+`IoReactor`ını (kendi kqueue/epoll fd'si)
yaratır, HİÇBİR global/singleton paylaşılmaz (5 tehlikeli global ZATEN
threadlocal, §3.47). **Anahtar gözlem:** bir dinleme soketinin ham dosya
tanımlayıcısı (`fd`) SADECE bir `int`tir — VE `int`, `nox.thread`in ZATEN
desteklediği iş-parçacıkları-arası aktarım tiplerinden biridir. Bir `fd`
üzerinde `accept()` çağıran birden fazla BAĞIMSIZ kqueue/epoll örneği,
işletim sistemi düzeyinde standart, güvenli bir davranıştır (nginx
worker'larının KENDİ epoll'larıyla PAYLAŞILAN bir dinleme soketini
izlemesiyle AYNI desen) — kodun okunmasıyla doğrulandı: `io.zig`nin
`nonBlockingAccept`i ZATEN ÇAĞIRANIN KENDİ zamanlayıcı/reaktörü üzerinden
kayıt yapıyor, `serveImpl`nin `active_connections` sayacı ZATEN çağrı-
başına (dolayısıyla iş-parçacığı-başına) bir YEREL değişken — Nox
tarafında YENİ hiçbir senkronizasyon ilkeli GEREKMEDİ. **Bilinçli KAPSAM
DIŞI ödünleşim:** "thundering herd" (bir bağlantı geldiğinde TÜM bekleyen
kqueue/epoll örneklerinin uyandırılması, yalnızca BİRİNİN `accept()`i
kazanması) — `nox.time.sleep_ms`in bloklayıcı olması/okuma-zaman-aşımı
eksikliği gibi (§D.1.4) DÜRÜSTÇE belgelenen, GELECEKTEKİ bir faza
bırakılan bir sınırlama (Linux'ta `EPOLLEXCLUSIVE` İLE azaltılabilir,
bu fazın kapsamı DIŞINDA).

**Uygulama — üç katman:**

1. **Çalışma zamanı** (`runtime/stdlib_shims/http_server.zig`): `Server
   Handle`e bir `owns_fd: bool` alanı eklendi — `nox_http_server_close`
   YALNIZCA `owns_fd` İSE `close()` çağırır (paylaşılan bir fd'yi KOŞULSUZ
   kapatmak, HENÜZ o fd üzerinde `accept()` bekleyen DİĞER iş parçacıklarını
   keserdi). `nox_http_server_listen`in socket/bind/listen mantığı bir
   `bindAndListen` yardımcısına ÇIKARILDI; YENİ `nox_http_listen_fd(rt,
   port) -> int` bunu çağırıp ham fd'yi (`ServerHandle` YOK) saf bir `int`
   olarak döner; YENİ `nox_http_server_from_fd(rt, fd) -> ServerHandle`
   (ZATEN dinlemede olan PAYLAŞILAN bir fd'yi `owns_fd = false` İLE sarar,
   yeniden bağlamaz/dinlemez).
2. **Stdlib** (`stdlib/nox/http.nox`): `nox.http.listen(port) -> int` —
   `get`/`post`nin "extern ham değeri döndürür, .nox sarmalayıcı hata
   sentinelini kontrol edip raise eder" deseniyle BİREBİR AYNI. Bu, HİÇBİR
   yeni checker/codegen kodu GEREKTİRMEDEN (sıradan bir `extern def` +
   sıradan bir `def`, mevcut FFI mekanizması) UÇTAN UCA çalıştı.
3. **Checker + codegen** — kullanıcı, AskUserQuestion'da HEM düşük
   seviyeli birleştirilebilir ilkelleri HEM ergonomik bir kolaylık
   sarmalayıcısını istedi ("Primitives + convenience wrapper"):
   - `nox.http.serve_fd(fd, handle[, max_connections])` — `nox.http.
     serve`nin `handle`-doğrulama mantığı ORTAK bir `validateHttpHandler`
     yardımcısına ÇIKARILIP üç form arasında PAYLAŞILDI (kod tekrarı
     önlendi). Codegen'de `genHttpServeFd`, `genHttpServe`yle NEREDEYSE
     ÖZDEŞ (`nox_http_server_listen` YERİNE `nox_http_server_from_fd`) —
     `HttpServeWrapperSpec`/`genHttpServeWrapper` DEĞİŞTİRİLMEDEN
     yeniden kullanılır. Paylaşılan bir `emitFdServeTail` yardımcısı
     (`nox_http_server_from_fd`+`nox_http_serve_raw`+`nox_http_server_
     close`) hem `genHttpServeFd`nin kuyruğu hem AŞAĞIDAKİ sentezlenmiş
     worker TARAFINDAN kullanılır.
   - `nox.http.serve_multicore(port, handle, num_threads[,
     max_connections])` — `port` bir kez dinlemeye alınır, `num_threads -
     1` ek `nox.thread` worker'ı (SENTEZLENMİŞ bir "iş parçacığı girişi"
     fonksiyonu ÜZERİNDEN — `genThreadStartWrapper`nin KANITLANMIŞ düşük-
     seviye şekliyle BİREBİR AYNI iskelet, AMA ARKASINDA gerçek bir Nox
     `entry` fonksiyonu YOK, `genHttpServeWrapper`nin `HandlerFn`
     sarmalayıcısını sentezlemesiyle AYNI teknik) AYNI paylaşılan fd
     üzerinde sunum yapar, ÇAĞIRAN iş parçacığının KENDİSİ Nninci worker
     OLUR (bugünkü `nox.http.serve`nin "çağrı sonsuza kadar bloke olur"
     sözleşmesiyle TUTARLI). Ham, sayaçlı bir QBE döngüsü (`genForRange`nin
     AYNI şekli, sentetik bir yığın yuvasıyla) `nox_thread_spawn`ı
     `num_threads - 1` kez çağırır, dönen `ThreadHandle`ları BİLEREK
     ATAR ("fire-and-forget" — sunucu ZATEN sonsuza kadar çalışır,
     bağlantı fiber'larının HİÇBİR ZAMAN `await` edilmemesiyle AYNI, ZATEN
     VAR OLAN ilkeyle TUTARLI).
   - **`max_connections`in `serve_multicore` İÇİN KESİNLİKLE bir tamsayı
     LİTERALİ olması ZORUNLUDUR** (checker `c.args[3] != .int_lit`i
     REDDEDER) — `serve`/`serve_fd`nin daha gevşek "herhangi bir int
     ifadesi" kuralından KASITLI bir sapma: bu değer codegen TARAFINDAN
     HEM çağıran iş parçacığının HEM sentezlenen worker'ın gövdesine
     DERLEME-ZAMANI bir metin sabiti olarak GÖMÜLÜR — `nox_thread_spawn`ın
     TEK-argümanlı sözleşmesi ZATEN `fd`yi taşıdığından, bir ÇALIŞMA-
     ZAMANI ifadesi olsaydı worker başına AYRI bir aktarım kanalı
     gerekirdi.

**Doğrulama:**
- Zig birim testi (`http_server.zig`): İKİ GERÇEK `std.Thread.spawn` iş
  parçacığı, HER BİRİ KENDİ `Scheduler`ı/`ServerHandle`ı ÜZERİNDEN
  PAYLAŞILAN bir `listen_fd`de `accept()` çağırır — İKİSİ de GERÇEKTEN
  kendi bağlantısını alır.
- AYRI, DETERMİNİSTİK bir Zig birim testi `owns_fd`in KENDİSİNİ
  (`fcntl(fd, F_GETFD)` İLE fd'nin hâlâ geçerli/kapatılmış olduğunu
  doğrulayarak) zamanlamadan BAĞIMSIZ kanıtlar.
- `tests/compat/http_serve_multicore_golden_test.zig` — GERÇEK bir `.nox`
  programını (`module_loader`+`checker`+`codegen`+`qbe`+`cc`) derleyip
  ARKA PLANDA çalıştırıp GERÇEK istemci soketleriyle sınayan 3 uçtan uca
  test: (1) `serve_multicore` — N=2 iş parçacığı, iş-parçacığı-başına
  `max_connections=1`, İKİ EŞZAMANLI istemcinin İKİSİNİN DE "200 OK"
  ALDIĞI doğrulanır (mekanizma bozuksa test bir yanıt alınamadan TIKANIR,
  sessizce yanlış-pozitif VERMEZ); (2) `nox.http.listen`+`nox.thread.
  start`+`nox.http.serve_fd`nin DOĞRUDAN (sarmalayıcı OLMADAN) kullanımı
  — birleştirilebilir yolun BAĞIMSIZ çalıştığını kanıtlar; (3)
  `num_threads=1` kenar durumu — sıradan tek-iş-parçacıklı sunuma
  DEĞİŞTİRİLMEDEN indirgenir.
- **Kasıtlı boz→kırmızı→düzelt (`owns_fd`):** `nox_http_server_close`
  GEÇİCİ olarak `owns_fd`i YOK SAYIP HER ZAMAN kapatacak şekilde bozuldu
  — bu, BEKLENENDEN DE GÜÇLÜ bir kanıt üretti: `owns_fd`in KENDİSİNİ
  hedefleyen deterministik testin ASSERTION FAILURE İLE kırmızı olmasının
  YANINDA, `http_serve_multicore_golden_test.zig`nin `serve_multicore`
  testi de bir iş parçacığının paylaşılan fd'yi ERKEN kapatıp DİĞER iş
  parçacığının `accept()`ini SONSUZA DEK ASKIDA bırakmasıyla TAM bir
  ÇALIŞMA-ZAMANI TIKANMASINA (hang) yol açtı (manuel olarak gözlemlenip
  durduruldu) — `owns_fd` fix'inin YALNIZCA bir "temiz" hata mesajını
  DEĞİL, GERÇEK bir kilitlenme SINIFINI önlediğinin somut kanıtı. Düzeltme
  GERİ YÜKLENDİ (`diff` İLE bayt-bayt ÖZDEŞLİK doğrulanarak), Debug +
  ReleaseFast YENİDEN yeşile (VE HIZLICA, tıkanma OLMADAN) döndü.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

## 3.61 Faz EE.1 — Stdlib Geliştirme ve Performans

**Kaynak:** kullanıcının "sonraki aşama geliştirmeler" listesinin #4
maddesi ("stdlib geliştirme ve performans artışı"). #1 (CLI), #2 (Faz
M.8), #3 (Faz DD.1) TAMAMLANDIKTAN SONRA sıradaki madde. Kullanıcı
AskUserQuestion'da ÜÇÜNÜ BİRDEN seçti: (1) dilin ihtiyaç duyduğu ama
stdlib'de eksik olan içeriği tamamla, (2) darboğaz ölç/gider, (3) mevcut
modüllerdeki yarım kalan davranışları tamamla. Bir Explore araştırması
TÜM `stdlib/nox/*.nox`u envanterleyip belgelenen "kapsam dışı" notlarını
taradı — bulgular ışığında EN YÜKSEK-DEĞERLİ/EN DÜŞÜK-RİSKLİ 5 kalemle
sınırlandırıldı (subprocess spawning, `tuple`/`set`, CLI argüman
ayrıştırıcı, trig/sabitler/base64 gibi DAHA BÜYÜK/DAHA DÜŞÜK-ÖNCELİKLİ
kalemler BİLİNÇLİ olarak gelecekteki bir faza bırakıldı).

### 1. `nox.strings`: alloc-sız byte karşılaştırması

`runtime/str.zig`nin `nox_str_char_at`i (`s[i]`, Python-tarzı "indeksleme
bir `str` döner" semantiği) HER ÇAĞRIDA yeni bir 2 baytlık ARC nesnesi
tahsis eder — bu, `s[i]`nin KENDİSİ İçin DOĞRU/DEĞİŞTİRİLMEYECEK bir
tasarımdır. Ama `stdlib/nox/strings.nox`nin `starts_with`/`ends_with`/
`index_of` (dolayısıyla `contains`) fonksiyonları KARŞILAŞTIRMA amaçlı
`s[i] != needle[j]` KULLANIYORDU — bu, O(n·m) HEAP TAHSİSİNE yol açıyordu
(yalnızca O(n·m) karşılaştırmaya DEĞİL), ÖNCEDEN hiç bayraklanmamış GERÇEK
bir darboğaz. YENİ `nox_str_byte_at(s, idx) -> int` (`runtime/str.zig`,
TAHSİS YOK) + `nox.strings.byte_at` (genel kullanıma açık, kullanıcı kodu
da AYNI kazanımı elde edebilir) — üç tarama fonksiyonu İÇ karşılaştırmaları
BUNA çevrildi, davranış AYNI kaldı.

### 2. `nox.strings.join`: O(n²) → O(n)

`join`, saf Nox'ta `result = result + sep + p` döngüsüyle yazılmıştı —
`nox_str_concat`in (`runtime/str.zig`) HER ÇAĞRIDA TAM kopya yapması
nedeniyle O(n²). `split`/`trim`/`upper`/`lower`/`replace` ZATEN (AYNI
gerekçeyle: "değişken uzunluklu sonuç → Zig'e sar") Zig kabuğuna
SARIYORDU — `join` bu ÖRÜNTÜYE UYMUYORDU, muhtemelen basit görünüp gözden
kaçmıştı. YENİ `nox_strings_join_raw` (`runtime/stdlib_shims/strings.zig`)
TEK geçişte toplam uzunluğu hesaplar, TEK `nox_rc_alloc` yapar, TÜM
parçaları/ayırıcıları KOPYALAR — O(n). `join` bu extern'e delege eder.

**İsimlendirme tuzağı (GERÇEKTEN yaşandı, düzeltmeden ÖNCE `nox.path`
İçin AYRICA tekrarlandı — bkz. §4):** extern fonksiyonun İLK adı
(`nox_path_join`, `_raw` soneki OLMADAN) `nox.path`nin KENDİ `join`
fonksiyonunun otomatik-mangled adıyla (`nox_path_join`) ÇAKIŞTI —
`DuplicateDefinition` hatasıyla YAKALANDI. `_raw` soneki TAM OLARAK bu
çakışmayı ÖNLEMEK İçin var (`nox_fs_read_to_string_raw` vb. ZATEN
kullanıyordu) — genel bir DERS olarak NOT edilir: bir extern def, AYNI
modüldeki bir public fonksiyonla AYNI isme sahipse, o public fonksiyonun
mangled adıyla ÇAKIŞMAMASI İçin `_raw` (ya da benzeri) bir sonek ZORUNLUDUR.

**`extern def` PARAMETRE tipi genişletmesi:** `nox_strings_join_raw`nin
`list[str]` PARAMETRESİ ALMASI GEREKTİĞİNDEN, `checker.zig`nin
`isFfiSafeListType`i (ÖNCEDEN `isFfiSafeListReturnType`, "yalnızca DÖNÜŞ,
PARAMETRE değil" — gerekçesi "henüz bir kullanım örneği YOK") YENİDEN
ADLANDIRILIP PARAMETRE yönünde de AÇILDI — ALTTAKİ temsil gerekçesi
(`list[str]`in çalışma zamanı temsili ZATEN ARC'lı bir payload, Zig
DOĞRUDAN OKUYABİLİR) parametre yönünde de AYNEN GEÇERLİDİR. `isFfiSafeClassReturnType`
İSE (sınıf tipleri İçin) HÂLÂ "yalnızca DÖNÜŞ" kalır — `class_id`nin
derleme sırasına bağlı olması nedeniyle Zig'in bir sınıfın ham baytlarını
DOĞRUDAN OKUMASI GÜVENLİ DEĞİLDİR.

### 3. `list[T].sort()` — `int`/`float`/`str` elemanlar

YENİ `runtime/collections/list_sort.zig`: `nox_list_sort_int`/`_float`/
`_str` (`std.mem.sort`/`std.sort.asc` İLE, `str` İçin işaretçileri
DEREFERANS eden bir karşılaştırıcı). `checker.zig`nin `.list` dalı `sort`u
TANIR — 0 argüman, eleman tipi `int`/`float`/`str` OLMALI (Nox'ta
kullanıcı-tanımlı karşılaştırıcı YOK, sınıf/`list`/`dict` elemanları İçin
"nasıl sıralanır" TANIMSIZ). `codegen.zig`nin `genListSort`ı `.append`den
FARKLI olarak alıcının SLOTUNA geri yazma/`nox_list_grow` GEREKTİRMEZ
(sıralama MEVCUT arabelleği YERİNDE değiştirir, `len`/`cap` DEĞİŞMEZ) — bu
yüzden `.append`nin "alıcı çıplak isim/yerel OLMALI" kısıtı BURADA
UYGULANMAZ, `getList().sort()` de GEÇERLİDİR (`genDictMethod`nin
`contains`/`len`iyle AYNI `releaseIfTemporary` deseni).

### 4. YENİ `nox.path` modülü (saf string manipülasyonu, I/O YOK)

`runtime/stdlib_shims/path.zig` + `stdlib/nox/path.nox`: `join`/
`basename`/`dirname`/`extension`/`is_absolute` — `std.fs.path.*`i sarar.
HİÇBİRİ `raise` ETMEZ (saf fonksiyonlar, HER ZAMAN başarılı). `dirname`
bir üst dizin YOKSA (`std.fs.path.dirname` `null` döner) boş dize (`""`)
döndürür — O DÖNEMDE Nox `str`ın nullable bir karşılığı OLMADIĞINDAN
belgelenen, kasıtlı bir varsayılandı. **NOT (Faz FF.6, bkz. §3.65):**
`str | None` ARTIK MÜMKÜN — `dirname`in imzasını `-> str | None`e
çevirip gerçek `None` döndürmesi TEKNİK olarak yapılabilir hâle geldi,
ama bu GERİYE DÖNÜK UYUMSUZ bir imza değişikliği olacağından (mevcut
`""` sözleşmesine dayanan çağıranları BOZAR) bu FF.6 turunun kapsamı
DIŞINDA bırakıldı — AYRI bir karar/faz gerektirir. `is_absolute`, `->
bool` DÖNÜŞÜ (bu projede DAHA
ÖNCE test edilmiş bir yol DEĞİL) YERİNE `nox_fs_last_op_ok`nin AYNI
KANITLANMIŞ "int (0/1) dön, `.nox` `!= 0` İLE `bool`a çevirir" desenini
izler.

### 5. `nox.fs`e varlık sorguları eklenir

`exists(path) -> bool`, `is_file(path) -> bool`, `is_dir(path) -> bool` —
`read_to_string`/`write_string`nin AKSİNE ASLA `raise` ETMEZ (var OLMAMA
burada GEÇERLİ, beklenen bir sonuçtur). **`std.c.stat` DEĞİL:** bu Zig
sürümünün `std.c.stat` cross-platform sarmalayıcısı aarch64-macOS İÇİN
BAĞLI DEĞİL (`private.stat` sembolü YOK — GERÇEKTEN derleme HATASI vererek
keşfedildi, ilk denemenin başarısız olması). Bunun yerine `std.c.access`
(varlık İçin) + `std.c.open(O_DIRECTORY)` (dizin mi sorusu İçin —
YALNIZCA hedef GERÇEKTEN bir dizinse başarılı olur, `ENOTDIR` İLE
başarısız olur AKSİ HALDE) kullanıldı — HER platformda DOĞRUDAN bağlı,
TAM bir `stat` yapısına gerek OLMADAN yeterli. "Dosya" burada "var VE
dizin DEĞİL" olarak TANIMLANIR (sembolik link/özel dosya AYRIMI yapılmaz —
`nox.fs`in ZATEN belgelenen v1 basitleştirmeleriyle TUTARLI).

**Doğrulama:**
- HER kalem İçin YENİ Zig birim testleri (`nox_str_byte_at`, `nox_strings_
  join_raw` — boş/dolu liste, `nox_list_sort_int`/`_float`/`_str`,
  `nox_path_*`, `nox_fs_exists/is_file/is_dir_raw`).
- 3 YENİ uçtan uca golden test (`list_sort.nox`, `path_manipulation.nox`,
  `fs_exists_queries.nox`) + `join`/`starts_with`/`ends_with`/`contains`/
  `index_of`i ZATEN kapsayan 2 MEVCUT golden test (`strings_split_join.nox`,
  `strings_search.nox` — İKİSİ de DEĞİŞMEDEN geçti, davranış korunduğunun
  KANITI).
- **Kasıtlı boz→kırmızı→düzelt:** `genListSort`nin eleman-tipi dispatch'i
  GEÇİCİ olarak KOŞULSUZ `nox_list_sort_int`e sabitlendi — `list_sort.nox`
  golden testi KIRMIZI oldu (str sıralaması BOZULDU, int/float TESADÜFEN
  hâlâ doğruydu). `nox_strings_join_raw`nin ayırıcı-kopyalama adımı GEÇİCİ
  olarak DEVRE DIŞI bırakıldı — HEM YENİ birim testi HEM MEVCUT
  `strings_split_join` golden testi KIRMIZI oldu. İKİSİ de GERİ YÜKLENDİ
  (`diff` İLE bayt-bayt ÖZDEŞLİK doğrulanarak), YENİDEN yeşile döndü.
- **Performans doğrulaması:** `benchmarks/strings_perf_bench.nox` (50000
  `contains` taraması + 3000 elemanlı bir listede 500 `join` çağrısı) —
  HER İKİ optimizasyon da GEÇİCİ olarak ESKİ davranışa (`s[i]` + O(n²)
  `join`) geri alınıp yeniden ölçüldü: 6040ms → 200ms, **~30x hızlanma**
  (çıktı DEĞERLERİ İKİ durumda da BİREBİR AYNI). Bkz. `benchmarks/
  RESULTS.md`.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

## 3.62 Faz FF.3 — `dict[K,V]` Sallanan-İşaretçi Güvenlik Açığının Kapatılması

**Kaynak:** kullanıcının, harici bir ChatGPT incelemesinin bulgularını
"düşük öncelikli görülenler DAHİL, sırayla HEPSİNİ düzelt" talimatıyla
(gerekçe: "projenin başındayız çözelim sonra çok başımız ağrır")
başlattığı Faz FF listesinin ÜÇÜNCÜ maddesi — incelemenin TEK "kritik"
olarak işaretlediği bulgu.

### Bulgu

`dict[K,V]`, `runtime/collections/dict.zig`de ARC-yönetimli DEĞİLDİ —
`Task[T]`/`Channel[T]`/`ThreadHandle[T]`/`ThreadChannel[T]` İLE AYNI "tek
sahiplilik, kapsam sonunda KOŞULSUZ yıkım" modelindeydi (`nox_dict_new`
düz bir `allocator().create(Dict)` yapıyordu — refcount başlığı YOK;
`nox_dict_destroy` KOŞULSUZ yıkıyordu). Bu, DİĞER dört tür İçin GÜVENLİDİR
(zamanlayıcı-sahipli tutamaçlar, PAYLAŞILMALARI hiç BEKLENMEZ) — ama
`dict` GERÇEKTEN inşa edilip UZUN ÖMÜRLÜ yapılara (sınıf alanları)
DEVREDİLİYOR, bu da TAM OLARAK bu modelin KIRILDIĞI senaryodur:

```nox
class Box:
    def __init__(self: Box, data: dict[str, str]) -> None:
        self.data = data

def make_box() -> Box:
    d: dict[str, str] = {"key": "value"}
    b: Box = Box(d)
    return b
```

`self.data = data` (`genAssign`nin `.attribute` dalı) ham işaretçiyi
TAKMA AD olarak saklar (retain YOK, `isHeapManaged` ÖNCEDEN `dict`i
KAPSAMADIĞINDAN) — `d`nin kapsam-sonu temizliği dict'i KOŞULSUZ yok eder,
`b.data` SALLANAN bir işaretçi kalır. **Manuel olarak GERÇEK bir SIGSEGV
(exit code 139) İLE doğrulandı** — teorik değil, GERÇEK bir bellek-
güvenliği hatası (bkz. `tests/golden/codegen_cases/dict_field_outlives_
local_no_dangling.nox`, önce KIRMIZI olduğu manuel çalıştırmayla VE
`zig build test` harness'ıyla İKİ AYRI şekilde kanıtlandı — İlke #7'nin
"önce kırmızı" ritüeli).

`stdlib/nox/http.nox`nin `get`/`post`u BUNU, `nox_http_response_headers(h)`
sonucunu HİÇBİR ZAMAN adlandırılmış bir yerele BAĞLAMADAN doğrudan
constructor'a geçirerek ELLE AŞIYORDU — DERLEYİCİ TARAFINDAN ZORLANMAYAN,
SIFIR korumalı bir disiplin; dokümante edilmeyen bu tuzağı bilmeyen
kullanıcı kodu aynı deseni yazarsa sessizce kırılırdı.

### Tasarım — `dict`i TAM ARC modeline taşı (checker-seviyeli
red/deep-copy YERİNE)

`emitInlineRetain`/`emitInlinePredecrement` (bkz. `codegen.zig`) TAMAMEN
TÜR-BAĞIMSIZDIR — SADECE `ptr-8`deki gizli refcount kelimesini okur/
yazar, `str`/`list`/`class`in ZATEN kullandığı AYNI mekanizma.
`retainIfAliasing`/`releaseTemporaryArgs`in her ikisi de ZATEN
`isHeapManaged(heap)` İLE geçilir — `isHeapManaged`e `.dict` EKLENMESİ,
bu ÇAĞRI SİTELERİNE HİÇ yeni kod EKLEMEDEN otomatik doğru çalışmasını
sağlar. Bu, dilin KENDİ kanıtlanmış ARC modelini `dict`e genişletir — hem
GÜVENLİ hem ERGONOMİK (kullanıcı ARTIK bir dict'i bir yerele bağlayıp
paylaşabilir).

### Uygulama

1. **`runtime/collections/dict.zig`:** `nox_dict_new` ARTIK `nox_rc_alloc`
   İLE (gizli refcount başlığı ALTINDA) tahsis eder — `Dict`in TÜM alanları
   (`entries`/`index`/`key_is_str`) pointer/usize/bool boyutlu olduğundan
   hizalama SORUNSUZDUR. `nox_dict_destroy` → `nox_dict_release` OLARAK
   YENİDEN ADLANDIRILDI, `nox_rc_predecrement`e göre KOŞULLU hale getirildi
   — `runtime/str.zig`nin `nox_str_release`iyle BİREBİR AYNI desen.

2. **`compiler/codegen_qbe/codegen.zig`:** `isHeapManaged`e `.dict`
   eklendi. `releaseValueIfSet`e YENİ bir `dict_info: ?*const DictInfo`
   parametresi + `.dict` dalı (`nox_dict_release` çağırır) eklendi — TÜM
   çağrı siteleri (`genClassRelease`, `genClassGcFree`, `releaseSlotIfSet`,
   `genAssign`nin `.attribute` dalı, `releaseTemporaryArgs`/
   `releaseIfTemporary`, `genHttpServeWrapper`) o BAĞLAMDA ZATEN MEVCUT
   `dict_info` alanıyla güncellendi. `destroyNonArcValue`in `.dict` dalı
   SİLİNDİ (artık ERİŞİLEMEZ) — DÖRT `.task or .channel or .dict or
   .thread_handle or .thread_channel` koşulundan `.dict` ÇIKARILDI (4'e
   indi: task/channel/thread_handle/thread_channel).

   **İKİNCİ, BAĞIMSIZ bir eksiklik (Zig derleyicisinin flag'lediği 9
   çağrı sitesini düzeltirken KEŞFEDİLDİ, `zig build test` bir SIGABRT İLE
   yakaladı):** `extern def` dönüş tiplerinin `Value`ye ÇEVRİLDİĞİ TEK
   ortak nokta (`genCall`nin extern dalı, satır ~4584) `dict_info`yi
   KOPYALAMIYORDU (`elem_qtype`/`elem_heap_info`/`class_name`in stdlib
   fazı §F/§L'de BULUNAN AYNI KATEGORİDE eksikliklerinin ÜÇÜNCÜSÜ) — `dict`
   ÖNCEDEN `isHeapManaged`in DIŞINDA OLDUĞUNDAN bu eksiklik MASKELENİYORDU.

   **ÜÇÜNCÜ, BAĞIMSIZ bir eksiklik (`zig build test` bir GERÇEK sızıntı İLE
   yakaladı, `http_serve_golden_test.zig`):** `isTemporaryExpr`
   (`releaseTemporaryArgs`in bir argümanın "taze" olup olmadığına karar
   verdiği AST-tabanlı sezgi) `.dict_lit`i HİÇ TANIMIYORDU (`.call`/
   `.list_lit`/`.binary` listeleniyordu, dict literalleri YOKTU) — `dict`
   ÖNCEDEN `isHeapManaged`in DIŞINDA OLDUĞUNDAN (`releaseTemporaryArgs`in
   KENDİSİ `isHeapManaged`e göre gated) bu eksiklik de MASKELENİYORDU.
   `HttpResponse(200, "ok", {"x": "x"})` gibi adlandırılmamış bir dict
   literalinin KURUCUYA geçirilmesi (`__init__`in `self.headers = data`sı
   `data`yı bir PARAMETRE olarak retain EDER, refcount 1→2) artık BİR
   DENGELEYİCİ release GEREKTİRİYORDU — `isTemporaryExpr` bunu TANIMADAN
   `releaseTemporaryArgs` HİÇ tetiklenmiyor, refcount ASLA 2→1'e İNMİYORDU
   (GERÇEK bir sızıntı). `.dict_lit` `isTemporaryExpr`e (`.list_lit`nin
   YANINA) EKLENEREK düzeltildi.

3. **`stdlib/nox/http.nox`:** `get`/`post`teki "headers'ı ASLA bir yerele
   bağlama" UYARI YORUMU (artık GEÇERSİZ) GÜNCELLENDİ — davranış GÜVENLİ
   hale geldiğinden bu disiplin ARTIK GEREKMİYOR (kod DEĞİŞMEDİ, sadece
   yorum).

### Doğrulama

- **"Önce kırmızı" ritüeli:** `dict_field_outlives_local_no_dangling.nox`
  düzeltmeden ÖNCE HEM manuel çalıştırmayla (GERÇEK SIGSEGV, exit 139)
  HEM `zig build test` harness'ıyla (`error.ProgramFailed`) KIRMIZI
  olduğu KANITLANDI, düzeltmeden SONRA YEŞİLE döndü.
- **YENİ pozitif golden test** (`dict_shared_across_two_class_instances.nox`):
  AYNI dict KENDİ adlandırılmış yereli HÂLÂ kapsam İÇİNDEYKEN İKİ AYRI
  sınıf örneğine PAYLAŞTIRILIYOR — retain/release SAYACININ dengede
  olduğunun pozitif kanıtı. `retainIfAliasing`in `.dict`i ATLAMASI
  (deliberate break) İLE bu test KIRMIZI olduğu doğrulanıp GERİ ALINDI.
- **YENİ Zig birim testi** (`runtime/collections/dict.zig`): `nox_rc_retain`
  + İKİ `nox_dict_release` — birincinin dict'i HÂLÂ CANLI bıraktığı,
  ikincinin GERÇEKTEN serbest bıraktığı doğrulanır. `nox_dict_release`nin
  predecrement KAPISININ devre dışı bırakılması (deliberate break) İLE bu
  test KIRMIZI (SIGSEGV) olduğu doğrulanıp GERİ ALINDI.
- MEVCUT TÜM `dict`-ilgili golden/birim testleri DEĞİŞMEDEN YEŞİL kaldı.
- `zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

## 3.63 Faz FF.4 — `self` Parametresi İçin Tip Çıkarımı

**Kaynak:** ChatGPT incelemesinin "dil yüzeyinde değiştireceğim noktalar"
listesindeki bir madde — her metodun `def m(self: Counter, ...)` şeklinde
`self`i AÇIKÇA tiplemesi gereksiz tekrar; `def m(self, ...)` da GEÇERLİ
olmalı, tipi otomatik kapsayan sınıfa/protokole çözülmeli. Faz FF listesinin
DÖRDÜNCÜ maddesi (FF.1-FF.3 TAMAMLANDI).

**AGENTS.md §16 gerilimi (BİLEREK belgelenmiştir):** bu, SIRADAN bir madde
DEĞİLDİR — `self`in HER ZAMAN AÇIKÇA tiplenmesi, Faz 1'de AGENTS.md §5'in
("tüm parametre tipleri zorunlu, asla örtük düşüş yok") RUHUNA sadık
kalmak İçin BİLİNÇLİ bir tercihti (bkz. §3.1'in ESKİ metni), VE o metin
AÇIKÇA şunu ÖNGÖRMÜŞTÜ: "ileride `Self` tipi gibi bir kısayol eklenmek
istenirse bu, mimariyi etkileyen bir karar olacağından AGENTS.md §16
prosedürüne göre AYRICA ele alınmalıdır." Bu gerilim kullanıcıya
AskUserQuestion İLE AÇIKÇA sunuldu (3 seçenek: planlandığı gibi devam et/
FF.4'ü ertele/yalnızca sınıflarla sınırla) — kullanıcı **"Proceed as
planned"** seçti. Çıkarılan tip TAMAMEN statik/sağlam olduğundan (dinamik
tipleme kaçışı DEĞİL) bu §5'in RUHUNU İHLAL ETMEZ, yalnızca LAFZINA
("self DAHİL, İSTİSNASIZ") KASITLI VE ONAYLANMIŞ bir istisna ekler — bkz.
AGENTS.md §5'in GÜNCEL metni.

### Tasarım — `Param.type_expr` HER ZAMAN dolu kalır, yalnızca YENİ bir
`self_inferred: bool` bayrağı eklenir

`Param.type_expr`in checker.zig (2 yer), codegen.zig (self İçin ZATEN
`class_name`den BAĞIMSIZ türetiliyor), ownership/analysis.zig (1 yer),
module_loader.zig (3 yer), ast_dump.zig (1 yer), formatter.zig (1 yer)
OLMAK ÜZERE 6+ yerde okunduğu doğrulandı — `type_expr`i `?TypeExpr`e
çevirmek HEPSİNE null-güvenlik eklemeyi GEREKTİRİRDİ. Bunun YERİNE:
parser, `self`in tipini HER ZAMAN (kullanıcı yazsa da yazmasa da)
`.simple = <kapsayan sınıf/protokol adı>` olarak DOLU bırakır — yalnızca
`self_inferred: bool = false` (varsayılanlı) bayrağı eklenir. Bu sayede:

- **checker.zig SIFIR değişiklik:** `registerClassSignatures`/
  `collectProtocols`in `self_type_ok` kontrolü ZATEN `m.params[0].
  type_expr.simple == cd.name`e bakıyor — çıkarılan self İçin bu HER
  ZAMAN doğru (parser AYNI adı kopyaladı); AÇIKÇA YANLIŞ bir `self:
  WrongClass` HÂLÂ reddedilir (DEĞİŞMEYEN davranış).
- **codegen.zig SIFIR değişiklik:** self'in tipini ZATEN `class_name`den
  BAĞIMSIZ türetiyor, `type_expr`e HİÇ bakmıyor.
- **ownership/analysis.zig SIFIR değişiklik:** `type_expr` HER ZAMAN dolu.
- **TEK fonksiyonel tüketici — `formatter.zig`:** `nox fmt`, kullanıcının
  BİLEREK çıplak `self` yazdığını `self_inferred`den okur, `self:
  Counter`e "genişletmez" (aksi halde özelliğin AMACI boşa çıkardı).

**Tespit mantığı (BİLEREK dar):** `parseFuncDef`in İLK parametresi
İçin — `enclosing_name` (sınıf/protokol adı, üst-düzey/iç-içe `def`ler
İçin `null`) MEVCUTSA VE geçerli token TAM OLARAK `self` lexeme'li bir
`.identifier` İSE VE bir SONRAKİ token `.colon` DEĞİLSE, `self`
TÜKETİLİR VE `Param{.name="self", .type_expr=.{.simple=enclosing_name},
.self_inferred=true}` SENTEZLENİR. `self` DIŞINDA bir isimle çıplak İLK
parametreye İZİN VERİLMEZ (`def foo(this):` hâlâ bir parse hatası verir)
— gramerin dar/öngörülebilir kalması BİLİNÇLİ bir tercihtir.

**Kapsam:** hem `class` metodları HEM `protocol` metod İMZALARI — İKİSİ
de `parseFuncDef`i AYNI şekilde çağırır, checker'daki self-doğrulama
İKİSİNDE de YAPISAL OLARAK AYNIDIR.

### Uygulama

- `compiler/parser/ast.zig`: `Param`a `self_inferred: bool = false`.
- `compiler/parser/parser.zig`: `parseFuncDef` YENİ `enclosing_name: ?
  []const u8` parametresi alır; YENİ `parseFirstParam` yukarıdaki dar
  tespiti uygular; `parseClassDef`/`parseProtocolDef` KENDİ adlarını
  geçirir, üst-düzey/iç-içe `def`ler `null` geçirir (DEĞİŞMEZ davranış).
- `compiler/module_loader.zig`: `renameMethodDef`, `.self_inferred`i
  yeniden inşa ettiği `Param`a KOPYALAR (AST hijyeni — `nox fmt` ASLA
  yeniden-adlandırılmış bir modülü formatlamadığından bugün FONKSİYONEL
  olarak etkisiz).
- `compiler/fmt/formatter.zig`: `printParams`, `self_inferred` İSE
  yalnızca çıplak ismi basar.

### Doğrulama

- `tests/unit/parser_test.zig`: çıplak self'in `self_inferred==true` VE
  `type_expr.simple==<sınıf adı>` ürettiğini doğrulayan YENİ test.
- `tests/golden/typecheck_cases/ok_bare_self_method.nox` (sınıf) +
  `ok_bare_self_protocol.nox` (protokol) — çıplak self açık self İLE AYNI
  şekilde tip-denetiminden GEÇER.
- `tests/golden/typecheck_cases/err_class_self_wrong_type.nox` +
  `err_protocol_self_wrong_type.nox` — YENİ: AÇIKÇA yanlış `self: X` HÂLÂ
  reddedilir (mevcut testler TARANDI, bu davranışı test eden HİÇBİR
  fixture YOKTU — bu alana dokunurken KAPATILAN gerçek bir boşluk).
  **Boz→kırmızı→düzelt:** `self_type_ok` kontrolü GEÇİCİ devre dışı
  bırakılıp bu testin KIRMIZI olduğu doğrulanıp GERİ ALINDI.
- `tests/golden/codegen_cases/`: çıplak self'li bir metodun bir ALANI
  GERÇEKTEN okuyup/yazdığı uçtan uca fixture — çalışma zamanı davranışı
  açık self İLE BİREBİR AYNI.
- `tests/golden/ownership_cases/`: heap-tipli (`dict`/`list`) bir sınıf
  alanına sahip, çıplak self kullanan fixture — ARC/serbest-bırakma İZİ
  açık self İLE AYNI (codegen'in GERÇEKTEN sıfır değişiklik gerektirdiğinin
  regresyon-korumalı kanıtı).
- `tests/golden/fmt_golden_test.zig`: çıplak self girdisi formatlandığında
  çıktıda `"self: "` YOK VE bare `self` VAR (normalize-ETMEME'nin AÇIK
  kanıtı — salt idempotentlik YETERSİZ, HER ZAMAN `self: X`e "genişleten"
  bozuk bir formatlayıcı da idempotent olurdu); açık `self: Counter`nin
  de DEĞİŞMEDEN kaldığı AYRI bir assertion.
- `zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

## 3.64 Faz FF.5 — Açık Sınıf Alan Bildirimleri

**Kaynak:** ChatGPT incelemesinin "dil yüzeyinde değiştireceğim noktalar"
listesindeki bir madde — bir sınıfın alan tipleri TAMAMEN `__init__`den
ÇIKARILIYORDU, sözdiziminde AYRICA bildirilemiyordu. Faz FF listesinin
BEŞİNCİ maddesi (FF.1-FF.4 TAMAMLANDI). FF.4'ün (§3.63) AKSİNE, burada
AGENTS.md/spec'te ÖNCEDEN BİLEREK REDDEDİLMİŞ bir karar YOKTU — bu
GENUİNELY açık bir özellik eklemesiydi.

**Sözdizimi:** bir sınıf gövdesinde, bir metoddan ÖNCE/SONRA/ARASINDA
(SIRA ÖNEMSİZ) çıplak `<ad>: <tip>` (initializer YOK — atama HÂLÂ
`__init__`de yapılır):

```nox
class Point:
    x: int
    y: int

    def __init__(self, x: int, y: int) -> None:
        self.x = x
        self.y = y
```

Gerçek Python ZATEN bir sınıf gövdesinde çıplak `name: type` (PEP 526)
ifadesini destekler — bu YENİ sözdizimi İCAT ETMEK DEĞİL, AGENTS.md §5'in
"Python 3.x gramerine sözdizimsel sadakat" ilkesiyle TUTARLI, MEVCUT bir
Python yapısını benimsemektir. Kapsam DIŞI, BİLİNÇLİ: protokoller
(alan-erişim semantiği YOK) VE varsayılan değerler (`x: int = 0` — çok
daha büyük bir özellik olurdu, istenen ergonomi kazanımı İçin
GEREKMİYOR).

### Tasarım

FF.4'ten (self tip çıkarımı) FARKLI, ÖNEMLİ bir nokta: bu özellik
codegen'e DE dokunmayı GEREKTİRDİ — codegen KENDİ AYRI, DAHA ZAYIF bir
alan-tipi çıkarım mekanizmasına (`inferFieldType`) sahip, checker'ın TAM
ifade tipi çıkarımını YENİDEN uygulamaz. Açıkça bildirilen alanlar İçin
codegen KENDİ `resolveType`ini (metod parametreleri/dönüşleri İçin ZATEN
kullandığı AYNI genel çözücü) DOĞRUDAN kullanır.

**Güvenlik gereksinimi:** açıkça bildirilen bir alanın `__init__`de HİÇ
atanmaması (ya da alan bildirimi OLAN bir sınıfın HİÇ `__init__`i
OLMAMASI) bir CHECKER HATASIDIR (`UnassignedField`) — codegen ZATEN TÜM
sınıf alanlarının ham belleğini `__init__` çalışmadan ÖNCE SIFIRLADIĞINDAN
(bkz. `genConstructFromValues`), bildirilen ama HİÇ atanmayan bir alan
(heap-tipli İSE) SALLANAN/null bir işaretçi OLARAK kalırdı — Faz FF.3'ün
(§3.62) kapattığı sallanan-işaretçi açığıyla AYNI RUHTA, ÖNLENEN bir
tehlike.

**BİLİNÇLİ, kabul edilen kapsam sınırlaması:** bu denetim AKIŞ-DUYARLI
DEĞİLDİR — yalnızca "`__init__` SONUNDA atanmış mı" kontrol edilir,
"OKUNMADAN ÖNCE atanmış mı" DEĞİL (`print(self.x); self.x = x` type-check
GEÇER — ÖNCEDEN, çıkarım-ONLY modelde, bu `UndefinedAttribute` İLE
KAZAEN yakalanırdı). TAM bir akış-duyarlı kesin-atama analizi (Katman
1'in ASAP'ından TAMAMEN AYRI, çok daha büyük bir özellik) OLMADAN
kapatılamayan, BİLİNÇLİ kabul edilen bir artık boşluktur.

### Uygulama

- `compiler/parser/ast.zig`: YENİ `FieldDecl { name, type_expr, line }`
  (`VarDecl`nin AKSİNE `value` ZORUNLU DEĞİL — AYRI bir düğüm). `ClassDef`e
  `fields: []FieldDecl = &.{}`.
- `compiler/parser/parser.zig`: `parseClassDef`in döngüsü ARTIK deyim-
  BAŞINA dispatch eder (`.identifier` + SONRAKİ token `.colon` İSE YENİ
  `parseClassFieldDecl`, AKSİ HALDE mevcut `parseFuncDef`).
- `compiler/typecheck/checker.zig`: YENİ `TypeError.UnassignedField`;
  `ClassInfo.declared_unassigned`; `registerClassSignatures` bildirilen
  alanları (yinelenen-bildirim `DuplicateDefinition` İLE reddedilerek)
  ÖN-KAYDEDER; `checkAssign`in MEVCUT "bilinen tip İLE assignable" dalına
  TEK satırlık bir `declared_unassigned.remove()` eklenir; `checkClassBody`,
  `__init__` denetiminden HEMEN SONRA kalan `declared_unassigned`i
  `UnassignedField` İLE reddeder.
- `compiler/codegen_qbe/codegen.zig`: `registerClass`nin alan döngüsü
  ÖNCE `cd.fields`i (bildirim SIRASIYLA, `resolveType` İLE) işler, SONRA
  mevcut `inferFieldType`-taramasına (DEĞİŞMEDEN, yalnızca ZATEN VAR OLAN
  alanları ATLAYARAK) düşer.
- **Silme/hijyen riskleri (araştırmayla BULUNAN, BLOCKING):**
  `compiler/fmt/formatter.zig`nin `.class_def` dalı GÜNCELLENMEZSE, `nox
  fmt` kullanıcının alan bildirimlerini SESSİZCE SİLERDİ (dosya HÂLÂ
  parse OLURDU) — `c.fields`i basacak şekilde GÜNCELLENDİ; ayrıca alan
  bildirimlerinin `ast.Stmt`ten BAĞIMSIZ (satırsız) olması, `nox fmt`nin
  trivia (boş satır/yorum) akışını GERÇEKTEN BOZDU (bir SONRAKİ deyimin
  KENDİ trivia'sına SIZAN, GÖZLEMLENEN bir biçimlendirme hatası) — `FieldDecl`e
  `line` eklenip `emitLeadingTrivia`/`self.line()` DOĞRU kullanılarak
  düzeltildi. `compiler/module_loader.zig`nin `renameStmt`nin `.class_def`
  dalı GÜNCELLENMEZSE, `import nox.X` üzerinden gelen stdlib sınıflarının
  alan bildirimleri SESSİZCE düşerdi — YENİ `renameFieldDecls` (`renameMethodDef`nin
  AYNI "tip ifadesi DAHİL yeniden adlandır" deseniyle) eklendi.

### Doğrulama

- `tests/golden/typecheck_cases/`: `ok_class_declared_fields` (tüm alanlar
  bildirilmiş+atanmış), `ok_class_declared_and_inferred_mixed` (İKİ
  mekanizma BİRLİKTE), `err_class_declared_field_unassigned`,
  `err_class_declared_field_no_init`, `err_class_declared_field_type_conflict`,
  `err_class_duplicate_field_decl` — SONUNCUSU İKİSİ, bu alana dokunurken
  KAPATILAN gerçek boşluklardı (daha ÖNCE test EDİLMEMİŞTİ).
- `tests/golden/codegen_cases/`: `class_declared_field_point` (mevcut
  `class_point.nox` İLE davranışsal BİREBİR AYNI), `class_declared_field_beyond_inference`
  (`inferFieldType`nin BUGÜN HİÇ ele ALAMADIĞI, bir `if` İÇİNDE atanan bir
  alan — codegen bypass'ının GERÇEKTEN çalıştığının, ÖZELLİĞİN ASIL DEĞER
  ÖNERİSİNİN kanıtı).
- `tests/golden/fmt_golden_test.zig`: bildirilen alanların `nox fmt`den
  SONRA HÂLÂ MEVCUT olduğu VE İKİNCİ formatlamanın AYNI sonucu ürettiği
  (idempotentlik) doğrulanır.
- **Boz→kırmızı→düzelt (ÜÇ BAĞIMSIZ mekanizma):** parser dispatch'i,
  checker'ın `declared_unassigned.remove()` çağrısı, codegen'in
  `inferFieldType` bypass'ı — ÜÇÜ de AYRI AYRI KIRILIP İLGİLİ fixture'ların
  KIRMIZI olduğu doğrulanıp GERİ ALINDI.
- `zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

## 3.65 Faz FF.6 — `T | None` (Optional) Tip Desteği

**Kaynak:** ChatGPT incelemesinin Faz FF listesinin ALTINCI VE EN BÜYÜK
maddesi — dilde GERÇEK bir nullable/Optional DEĞER kavramı YOKTU (`None`
yalnızca "değer yok", yani void dönüş tipi anlamına geliyordu). Bu boşluk,
spec'in KENDİSİNİN birden fazla yerde AÇIKÇA itiraf ettiği bir eksikti
(bkz. §4'ün "Bilinçli kapsam sınırlamaları" notu, ~§3.14'ün `self.next =
self` öz-döngü GEÇİCİ ÇÖZÜMÜ, `nox.path.dirname`'in `""`-varsayılan notu
— HEPSİ bu bölüme çapraz-referans VERECEK şekilde güncellendi).

### Sözdizimi ve kapsam kararları

Kullanıcı üç kilit kararı ÖNCEDEN verdi: **(1)** sözdizimi `T | None`
(Python 3.10+ idiomu, `Optional[T]` DEĞİL) — yalnızca `<taban-tip> | None`
(soldan sağa) KABUL EDİLİR, `None | T` VE zincirleme (`T | None | None`)
parser SEVİYESİNDE reddedilir (TEK bir kanonik yüzey biçimi, FF.4'ün
`self` istisnasıyla AYNI "dar gramer" gerekçesi). **(2)** kapsam TAM —
hem HEAP tipler (class/str/list/dict) HEM DE İLKEL tipler (int/float/bool)
`| None` destekler. **(3)** daraltma (narrowing) yalnızca DAR, örüntü-
tabanlı: `if`/`while` KOŞULUNUN TAM OLARAK `<isim> != None`/`<isim> ==
None` biçiminde olması gerekir — genel bir akış-duyarlı analiz DEĞİLDİR.

### Tasarım — üç katman

**1. Gramer:** YENİ `pipe` token'ı (`|`, dilde daha önce HİÇ kullanılmayan
bir karakter — sıfır çakışma riski). `ast.TypeExpr.optional: *TypeExpr` VE
`types.Type.optional: *const Type` — HER İKİSİ de `union(enum)` OLDUĞUNDAN
(`else` dalı OLMAYAN kapsayıcı switch'ler), Zig derleyicisinin KENDİSİ HER
tüketim sitesini (checker/codegen/formatter/module_loader/ast_dump/
ownership) güncellemeye ZORLADI — FF.5'in `ClassDef.fields` (yeni bir
STRUCT alanı, sessizce atlanabilir) riskinin AKSİNE, burada "sessiz
düşme" derleme hatası olmadan MÜMKÜN DEĞİLDİR (bu FAZIN kendi güvenlik
ağı).

**2. Değer temsili — HEAP tipler (neredeyse ücretsiz):** `Optional[HeapType]`nin
çalışma zamanı temsili TABAN TİPLE TAMAMEN AYNIDIR (null pointer = None,
dolu pointer = Some(x)) — `codegen.zig`nin `resolveType`i `.optional`i
HEAP bir taban tip İçin DOĞRUDAN o tabanın `TypeInfo`sini döner (ayrı bir
codegen temsili YOK). ARC release/retain/eşitlik/trace/gc-free kodunun
BÜYÜK ÇOĞUNLUĞU DEĞİŞMEDİ (zaten null-güvenliydi) — TEK istisna:
`emitInlineRetain` (retain'in KENDİSİ) ÖNCEDEN null-KONTROLSÜZDÜ (heap-
yönetimli bir slot Optional'dan ÖNCE ASLA null bir DEĞER TUTAMAZDI, bu
yüzden hiç gerekmemişti) — `self.next = next` (`next: Node | None`) gibi
bir atama bunu artık MÜMKÜN KILDIĞINDAN, `releaseValueIfSet`in ZATEN
sahip olduğu AYNI null-güvenliği retain YÖNÜNDE de eklendi (bir GERÇEK
segfault bulunup DÜZELTİLDİ — bkz. aşağıdaki "Bulunan hatalar").
`.none_lit`in KENDİSİ (bugün de `error.Unsupported` — hiçbir zaman
"değer olarak None" için genel bir codegen yolu YOKTU) `genExprForTarget`
adlı YENİ bir bağlam-duyarlı yardımcı ÜZERİNDEN, hedefin (değişken/alan/
parametre/dönüş yuvasının) ZATEN bilinen `TypeInfo`sini kullanarak ÇÖZÜLÜR
(`var_decl`/`assign`/`genConstruct`/`genMethodCall`/`return_stmt` çağrı
siteleri `genExpr` yerine BUNU çağırır) — FF.5'in `registerClass`ının
`inferFieldType`i BYPASS ETMESİYLE AYNI "çağıran taraf bilir" deseni.
`genBinary`e de `x != None`/`x == None` İçin ÖZEL bir dal eklendi (diğer
tarafı ÜRETİP DOĞRUDAN `0`a karşı `ceql`/`cnel` — `_eq`/`strcmp`
GEREKTİRMEYEN basit bir işaretçi karşılaştırması).

**Bilinçli, v1 DIŞI bırakılanlar:** `Task`/`Channel`/`ThreadHandle`/
`ThreadChannel` (ARC-DIŞI, KENDİ ayrı yıkım mekanizmaları var — bkz.
`destroyNonArcValue`, null-güvenlikleri AYRICA doğrulanmadı) `| None`
DESTEKLENMİYOR (`resolveType` `error.Unsupported` döner) — `isHeapManaged`
ile sınırlı, dar bir "hangi heap tipler ücretsiz Optional olabilir" kümesi.

**3. Değer temsili — İLKEL tipler (kutulama):** int/float/bool'un QBE'de
"boş" temsil edecek yedek biti OLMADIĞINDAN, TEK, GENEL bir ARC-yönetimli
kutu (`HeapKind.boxed_scalar` — `nox_rc_alloc(rt, 8)`den gelen DÜZ 8
baytlık bir skaler payload, class'ın tag'ı/list'in len-cap başlığı YOK)
kullanılır. `elem_qtype` (list[T]'in AYNI alanı) kutunun İÇİNDEKİ GERÇEK
QBE tipini taşır. Kutulama, `genExprForTarget`de hedef `boxed_scalar` VE
kaynak HENÜZ kutulanmamış bir ÇIPLAK skalerse tetiklenir (`boxScalar` —
`always_fresh = true` İLE İŞARETLENİR, aksi halde `retainIfAliasing`in
AST-tabanlı sezgisi TAZE kutuyu SPÜRİYÖZ retain edip KALICI SIZINTIYA yol
açardı, bkz. aşağıdaki "Bulunan hatalar"). **Kritik mimari zorunluluk:**
daraltılmış bir kutulanmış Optional'ın OKUNMASI (`if x != None: y = x +
1`) kutunun İÇİNDEKİ değeri (unboxed) DÖNMELİDİR, kutunun KENDİSİNİ
(pointer) DEĞİL — bu, checker'ın `FnCtx.narrowed` daraltma mantığının
CODEGEN'DE DE (`genIf`/`genWhile`'ın `detectNarrowedBoxedName`i, YENİ
`Codegen.narrowed_unbox` örtüsü) MEKANİK olarak YANSITILMASINI gerektirdi
— HEAP tiplerin AKSİNE (temsil AYNI, hiçbir codegen-seviyesi narrowing
GEREKMEDİ), kutulanmış bir skalerin temsili `T`den TAMAMEN FARKLI OLDUĞU
İÇİN bu KAÇINILMAZDI (boxing yerine inline `{flag,payload}` temsili
DEĞERLENDİRİLDİ ama Nox'un HER YERDE "her slot TEK 8-baytlık kelime"
varsayan mevcut mimarisine [class alan ofsetleri, fonksiyon çağrı ABI'si]
ÇOK DAHA İSTİLACI bir değişiklik olacağından ELENDİ — kutulama, VAR OLAN
ARC makinesini AYNEN yeniden kullandığından BU kod tabanı İÇİN daha az
riskli).

### Checker — daraltma (narrowing)

`checkStmt`'in `.if_stmt`/`.while_stmt` dalları, `Checker.detectNarrowing`
(YALNIZCA `<isim> != None`/`<isim> == None`, `<isim>` GEÇERLİ scope'un
DOĞRUDAN bir YERELİ VE `.optional` tipinde OLMALI) eşleşirse, `FnCtx.narrowed`
adlı YENİ bir ÖRTÜ katmanına (`ctx.scope.vars`ı DOĞRUDAN mutate ETMEK
YERİNE) geçici olarak daraltılmış tipi yazar — bu AYRIM KRİTİKTİR: bir
narrowed değişkenin YENİDEN ATANMASI (`cur = cur.next`, bağlı liste
traversal'inin TAM OLARAK KENDİSİ) sağ tarafın ASIL (Optional) bildirilen
tiple KARŞILAŞTIRILMASINI GEREKTİRİR, narrowed tiple DEĞİL — `checkAssign`
ATAMADAN SONRA örtüden SİLEREK narrowing'i geçersiz kılar (TypeScript'in
"reassignment invalidates narrowing"ıyla AYNI gerekçe). `while x != None:`
DESTEĞİ (plan'ın YALNIZCA `if` öngören ilk tasarımının ÖTESİNDE, GERÇEK
kullanım sırasında GEREKLİ olduğu ANLAŞILAN bir genişletme) AYNI DAR
örüntüyü kullanır, döngü SONRASI daraltma HER ZAMAN geri alınır (bir
`break` gövde İÇİNDE Optional durumda çıkabilir).

**Bilinçli, dar v1 sınırlaması:** "erken dönüş" narrowing'i (`if x ==
None: return ...` SONRASINDA takip eden kodun OTOMATİK daraltılması)
DESTEKLENMEZ — yalnızca `if`/`while`'ın KENDİ then/else gövdeleri İÇİNDE
narrowing GEÇERLİDİR. Kullanıcı bunun YERİNE açık bir `if x != None: ...
else: ...` yazmalıdır (bkz. golden fixture'lar). Genel akış-duyarlı analiz,
BÜYÜK ÖLÇÜDE daha karmaşık bir özellik olurdu, BİLİNÇLİ olarak v1 kapsamı
DIŞINDA bırakıldı.

Daraltılmamış bir Optional'a alan/metod/index erişimi YENİ `TypeError.
OptionalNotNarrowed` İLE reddedilir (`requireNotOptional`, checker'ın
`checkAttribute`/`.index`/method-call dispatch'inin TEK, paylaşılan
kapısı).

### Bulunan hatalar (break→red→fix ritüeliyle doğrulandı)

Manuel uçtan-uca testler (bağlı liste traversal'ı) SIRASINDA İKİ GERÇEK,
segfault'a yol açan hata bulundu VE düzeltildi — İKİSİ de ÖNCEDEN hiçbir
Nox programının heap-yönetimli bir slota GERÇEKTEN null yazamamasından
kaynaklanan, ÖNCEDEN test EDİLMEMİŞ kod yollarıydı:
1. `emitInlineRetain` null-KONTROLSÜZDÜ — `self.next = next` (`next` `None`
   İKEN) `null - 8`i OKUMAYA ÇALIŞIYORDU (segfault). Düzeltme:
   `releaseValueIfSet`in AYNI null-güvenlik desenini retain'e de ekle.
2. Kutulanmış skaler release'i YANLIŞLIKLA `nox_rc_free_payload`
   (refcount'u KENDİSİ AZALTMADAN belleği KOŞULSUZ serbest bırakan DÜŞÜK
   SEVİYE bir ilkel) kullanıyordu — `nox_rc_release` (refcount azalt, SIFIRA
   düşerse SERBEST bırak) GEREKİRDİ. Bu, PAYLAŞILAN bir kutunun (`w: int |
   None = y`) HÂLÂ başka bir sahibi VARKEN ERKEN serbest bırakılmasına, SONRA
   GERÇEK sahibinin release'inde ÇİFTE-SERBEST-BIRAKMAYA yol açıyordu.

Her ikisi de deliberate break→red→fix ritüeliyle doğrulandı (geçici
olarak KIRILIP fixture'ların KIRMIZI olduğu onaylanıp GERİ ALINDI).

### Doğrulama

`tests/golden/typecheck_cases/`: `ok_optional_heap_field.nox` (öz-referanslı
`Node.next: Node | None` + `while`-narrowing traversal), `ok_optional_primitive.nox`
(auto-wrap atama + `if`-narrowing), `err_optional_unnarrowed_access.nox`
(YENİ `OptionalNotNarrowed`), `err_optional_type_mismatch.nox`.
`tests/golden/codegen_cases/`: `optional_linked_list.nox` (GERÇEK bağlı
liste inşası + `sum_list`/`find` traversal, gözlemlenebilir stdout),
`optional_primitive_box.nox` (kutulanmış int None-dönüşü + auto-wrap +
narrowing + ALIAS round-trip). `zig build test` (Debug + ReleaseFast)
yeşil, `zig fmt` temiz.

**Kapsam DIŞI, gelecekteki bir faza bırakılan:** `list[int | None]` gibi
kutulanmış-Optional ELEMANLI koleksiyonların DEĞER eşitliği (`genListEq`nin
`.boxed_scalar` dalı, GÜVENLİ ama YÜZEYSEL bir tutamaç-kimliği/pointer
karşılaştırmasına düşer — hiçbir golden fixture bunu EGZERSİZ ETMEZ);
`nox.path.dirname`'in `str | None` dönecek şekilde GÜNCELLENMESİ (GERİYE
DÖNÜK UYUMSUZ bir imza değişikliği, AYRI bir karar gerektirir).

## 3.66 Faz GG — Performans: Go/Rust Arası Konumlandırma

**Kaynak:** kullanıcının AÇIK talebi — Nox'un hızını "Go ve Rust arasında
bir yere" oturtmak. Üç paralel araştırma agent'ı (QBE'nin kendi optimizasyon
tavanı, derleyici/runtime kod taraması, GERÇEK Nox/Go/Rust/C/Python
ölçümleri — Go 1.26/Rust nightly 1.94 bu makinede kurulu, GERÇEK karşılaştırma
yapıldı) çalıştırılıp bulgular ÖNCELİK sırasına göre 10 alt-göreve (GG.1-GG.10)
bölündü. **Kritik bulgu:** Nox bugün iki senaryoda ZATEN Go/Rust seviyesinde
(`numeric_recursion`: Go'yu geçiyor, Rust'a %18 geride; `oop_arc_churn`:
Rust'ı VE C'yi geçiyor) — ama `string_passing`de Go/Rust/C'nin (kendi
aralarında 6-9ms bandında sıkışıkken) **7-11 katı yavaş** ölçüldü, bu yüzden
GG.1 string performansıyla başladı.

### GG.1 (TAMAMLANDI) — `str` release'inin inline edilmesi

**Araştırma sırasında düzeltilen varsayım:** GG.1 başlangıçta "O(n²) string
birleştirme + `s[i]`nin her erişimde `strlen` tekrarlaması" olarak
çerçevelenmişti — ama `string_passing` benchmark'ının GERÇEK IR'ı incelenince
(`.ssa` dökümü) bu benchmark'ın birleştirme İLE HİÇ İLGİSİ OLMADIĞI, yalnızca
literal string'leri iki katmanlı fonksiyon çağrısı zincirinden GEÇİRDİĞİ
(`pass_through(pass_through(pick(i)))`, 15M kez) görüldü — istisna-kontrolü
ZATEN elenmiş (M.1/M.8'in kazanımı doğrulandı, IR'da `nox_exception_pending`
HİÇ yok), retain ZATEN inline (`emitInlineRetain`) — ama **release DEĞİL**:
`releaseValueIfSet`in `.str` dalı HER release'de (PINNED/literal dizeler
DAHİL — ki bunlar HİÇBİR ZAMAN gerçekten serbest bırakılmaz, `refcount =
1<<30`) tam bir `nox_str_release` fonksiyon ÇAĞRISI yapıyordu (`strlen`i
KENDİ hesaplaması İçin — `str`ın uzunluk başlığı OLMADIĞINDAN, bkz.
`runtime/str.zig`nin `PINNED_REFCOUNT` tasarım notu).

**Düzeltme:** `class`/`list`in KENDİ `_release`ıklarının ZATEN kullandığı
`emitInlinePredecrement` deseni `.str` dalına da uygulandı — predecrement
(sub/load/sub/store/karşılaştır) DOĞRUDAN QBE IR'ına inline edilir,
YALNIZCA refcount GERÇEKTEN sıfıra/altına düştüğünde (NADİR yol, pinned
string'ler İçin ASLA) YENİ, hafif bir `nox_str_free_now` (predecrement'siz,
yalnızca `strlen`+gerçek serbest bırakma) çağrılır. `nox_str_release`in
KENDİSİ (Zig tarafındaki ÇOK sayıda çağrı sitesi İçin — `thread_bridge`/
`thread_channel`/`path`/`http_client`/`strings`/`dict`) DEĞİŞMEDEN kaldı.

**Boz→kırmızı→düzelt:** `emitInlinePredecrement`in dönüşü GEÇİCİ olarak
YOK SAYILIP `should_free` HER ZAMAN `"1"`e sabitlendi (koşulsuz serbest
bırakma) — `string_passing`i ÇALIŞTIRMAK DebugAllocator'ın "Invalid free"
panik'iyle ANINDA KIRMIZI oldu (pinned string'in `.data` bölümündeki
statik belleği geçerli bir heap işaretçisi SANIP serbest bırakmaya
ÇALIŞTI) — bu, `should_free` kontrolünün GERÇEKTEN load-bearing OLDUĞUNU
KANITLADI. GERİ ALINIP `zig build test` (Debug + ReleaseFast) yeniden
yeşil doğrulandı.

**Ölçüm (Apple M4, `string_passing.nox`, n=15M, ReleaseFast, 5 koşunun
minimumu):** **~65ms → ~50ms** (`zig build bench`'in KENDİ metodolojisiyle
de tutarlı: 59.8ms). `zig build bench`in TÜM diğer 18 senaryosunda (stres +
karşılaştırma) regresyon GÖZLEMLENMEDİ. Diğer benchmark'larda (ör.
`oop_arc_churn`, sınıf alanları str İÇERDİĞİNDE) da AYNI mekanizma
tetiklendiğinden benzer, daha küçük kazanımlar BEKLENİR (ayrıca
ölçülmedi — dominant maliyet ORADA ARC/tahsis, str release DEĞİL).

**Kapsam DIŞI bırakılan (araştırmayla netleşen, GEREKSİZ bulunan):**
O(n²) birleştirme İÇİN ZATEN bir çözüm VAR — `nox.strings.join()` (Faz
EE.1.2, tek-geçişli Zig kabuğu) `list[str]` + `.append()` (amortize O(1)
büyüme) İLE birleştirilirse O(n) çalışır; YENİ bir `StringBuilder` tipi
GEREKMEDİ. `s[i]`nin her erişimde `strlen` tekrarlaması AYRI bir sorun
(GG.5'in döngü-değişmezi taşıma kapsamına TAŞINDI — AYNI kök neden sınıfı:
QBE'nin LICM yapmaması).

### GG.2 (TAMAMLANDI) — Seçici serbest-fonksiyon inlining'i

**Kaynak:** `list_traversal` benchmark'ında Nox'un Go'ya %85 kaybettiği
bulundu — kök neden araştırması, `make_data()` gibi küçük bir fonksiyonun
TAZE bir `list[int]` inşa edip HEMEN `sum_list(make_data())` İLE
tüketildiğini, VE **QBE'nin hiçbir zaman fonksiyonlar-arası inlining
YAPMADIĞINI** (Go'nun aksine — Go muhtemelen bu ufak fonksiyonları inline
edip escape analysis İLE tahsisi TAMAMEN ELİYOR) gösterdi. Kullanıcıya
ÜÇ yol sunuldu (seçici inlining / ABI-seviyesi opsiyonel arena parametresi /
ertele) — kullanıcı **seçici inlining'i** seçti.

**Tasarım (tam plan, `compiler/codegen_qbe/codegen.zig` içinde, AST/
checker/ownership analizine HİÇ dokunulmadan):**

1. **Uygunluk kriterleri:** `!is_async`, generic DEĞİL, gövde YALNIZCA
   `var_decl`/`assign`/`expr_stmt`/`if_stmt`/`return_stmt`/`pass_stmt`
   İÇERİR (özyinelemeli, if/elif/else İÇİNE de — `while`/`for`/`try`/
   `with`/`raise`/`lowlevel`/iç içe `func_def`/`class_def` DİSKALİFİYE
   eder: döngü YOK kuralı QBE'nin alloc-döngü-İÇİ tehlikesini VE `return`
   yeniden-yazma karmaşıklığını BAŞTAN eler), üst-düzey ≤8/toplam ≤20
   deyim, (transitif) özyinelemesiz (YENİ bir DFS, `computeMustNotRaise`in
   ZATEN inşa ettiği çağrı-grafiğini YENİDEN kullanır), VE **`self.
   must_not_raise.contains(fd.name)`** — bu SONUNCUSU, orijinal tasarımın
   ÖTESİNDE (bkz. aşağıdaki "Bulunan hatalar"), splice SIRASINDA bir
   istisna kontrolünün caller'ın erken-çıkış yoluna girip gölgelenmiş bir
   yerelin görünmez kalarak SIZMASINI YAPISAL olarak İMKANSIZ kılmak İçin
   ZORUNLU.
2. **Hijyen — yeniden adlandırma GEREKMİYOR:** QBE-seviyesi SSA geçicileri
   (`%tN`) ZATEN fonksiyon boyunca benzersiz — TEK hijyen adımı, callee'nin
   parametre/yerel isimlerini `self.vars`a GEÇİCİ olarak GÖLGELEMEK (eski
   değeri kaydedip splice SONRASI geri yüklemek).
3. **Splice mekanizması:** `prepareInlineSites` (caller'ın `collectLocals`+
   `allocSlot` döngüsünün HEMEN SONRASI, `genStmts` ÇAĞRILMADAN ÖNCE —
   `genFunction`/`genMethod`/`genMain`/`genMainAsync`/`genClosureFunc`nin
   BEŞİ İÇİN de) caller gövdesini tarayıp (caller'ın KENDİSİ KISITSIZ,
   yalnızca CALLEE kısıtlı) `self.inlinable_funcs`teki çağrıları bulur,
   callee'nin slotlarını `collectLocals(callee.body)` İLE (İÇ İÇE inlining
   YOK) caller'ın giriş bloğunda ÖN-TAHSİS eder. `genInlinedCall` (`genCall`'ın
   serbest-fonksiyon dalına TEK satırlık bir kancayla bağlanır) argümanları
   değerlendirip slotlara yazar, isimleri gölgeler, `genStmts(callee.body,
   ...)`i DEĞİŞTİRMEDEN çağırır (`.return_stmt`e TEK, cerrahi bir dal
   eklenir: gerçek `ret` YERİNE sonuç slotuna yazıp `jmp`), SONRA HER ŞEYİ
   geri yükler.

**Bulunan hatalar (break→red→fix ritüeliyle doğrulandı) — bu turun EN
DEĞERLİ kısmı:**

1. **`releaseTemporaryArgs` UNUTULMUŞTU** — GERÇEK (inline OLMAYAN) çağrı
   yolu, TAZE bir argümanı (ör. `show(safe_div(...))`) çağrı SONRASI
   `releaseTemporaryArgs` İLE dengeler; `genInlinedCall`in İLK sürümü BUNU
   YAPMIYORDU — HER inline edilen çağrının TAZE argümanı KALICI olarak
   SIZIYORDU (10 test KIRMIZIYDI, `nox_rc_alloc` çağıran her yerde
   sızıntı raporlandı). Düzeltme: argümanların HAM (`convert`DEN ÖNCEKİ)
   değerlerini SAKLAYIP splice SONRASI `releaseTemporaryArgs(c.args,
   arg_v0s)` çağırmak.
2. **KRİTİK, İKİNCİ bir hata — "iç içe inlining yok" kuralı YANLIŞ
   uygulanmıştı:** `quadruple(x) -> double(double(x))` gibi bir fonksiyon
   HEM kendi standalone `$quadruple`sinde `double`yi inline EDİYORDU (o
   slotlar `$quadruple`nin KENDİ QBE metnine `alloc8`'lendi) HEM DE
   `quadruple`nin KENDİSİ BAŞKA bir çağrı sitesinde (`main` İÇİNDE) inline
   edilebiliyordu — İKİNCİ durumda, `quadruple.body` `main`in İÇİNE SPLICE
   edilirken, İÇİNDEKİ `double(double(x))` çağrıları `self.inline_sites`de
   BULUNUYORDU ama slotları ARTIK GEÇERSİZ bir QBE fonksiyonuna
   (`$quadruple`ye) AİTTİ — segfault (`from_import_basic.nox` testiyle
   YAKALANDI). Düzeltme: `self.inline_sites` HER üst-düzey gövde-üretim
   çağrısı BAŞINDA (`prepareInlineSites`in KENDİSİNDE) TEMİZLENİR — bu,
   "iç içe inlining yok" kuralını DOĞRU biçimde ZORUNLU kılar (bir splice
   İÇİNDEKİ iç içe çağrılar ARTIK `self.inline_sites`de HİÇ BULUNAMAZ,
   GÜVENLE GERÇEK bir `call`e düşerler).
3. **Boz→kırmızı→düzelt (`must_not_raise` şartı):** GEÇİCİ olarak
   `false and ...` İLE devre dışı bırakılınca 3 BAĞIMSIZ mevcut test
   KIRMIZI oldu (2 M.8 istisna-yutma testi + `nox.test.TestSuite`nin
   JUnit XML testinde GERÇEK bir `nox_str_concat` sızıntısı) — TAM OLARAK
   §0(A)'nın öngördüğü hata sınıfı, kontrolün GERÇEKTEN load-bearing
   olduğunu KANITLADI. GERİ ALINDI, `zig build test` (Debug + ReleaseFast)
   yeniden yeşil.

**Ölçüm (Apple M4, `list_traversal.nox`, n=5M, ReleaseFast, `zig build
bench`):** ~62.5ms → ~60.3ms — **dürüstçe ÖNCEDEN tahmin edildiği GİBİ
gerçek ama KISMİ bir kazanım** (`make_data`nın çağrı overhead'i
[RT_PARAM+prologue/epilogue] ORTADAN KALKTI, ama `nox_rc_alloc`'un
KENDİSİ HÂLÂ her iterasyonda çalışıyor — `sum_list` bir `for` döngüsü
İÇERDİĞİNDEN inline EDİLEMİYOR). `.ssa` dökümüyle doğrulandı: `call
$make_data` SIFIR (gövde `$compute`nin İÇİNE spliced). YAN kazanım:
`string_passing` benchmark'ı da GG.1'in ~50ms'sinden **~44.8ms**e düştü
(`pick`/`pass_through` de KÜÇÜK/uygun fonksiyonlar OLDUĞUNDAN AYRICA
inline edildi). TÜM 19/19 stres + 10/10 karşılaştırma benchmark'ında
regresyon YOK. 4 YENİ golden test (`inline_small_free_function`,
`inline_same_function_both_paths` — standalone fonksiyonun "salt eklemeli"
kaldığını KANITLAR, `inline_name_collision_hygiene`, `inline_ineligible_fallback`
— döngülü/özyinelemeli gövdelerin DOĞRU şekilde inline EDİLMEDEN
çalıştığını kanıtlar).

**Kapsam DIŞI (v1, bilinçli):** yalnızca SERBEST fonksiyonlar (metod/
kurucu DEĞİL); `nox_rc_alloc`'un KENDİSİNİ ELEMEK bu turun konusu DEĞİL
(ABI-seviyesi opsiyonel arena parametresi gibi AYRI, gelecekteki bir tur
gerektirir — kullanıcıya SUNULMUŞTU, ŞİMDİLİK ERTELENDİ).

### GG.3 (TAMAMLANDI) — for-loop metod çağrısı istisna-kontrolü elemesi boşluğu

**Kaynak:** codegen/runtime kod taraması agent'ının bulgusu — `for item in
items: item.method()` deseni, `computeMustNotRaise`in (Faz M.8) `.for_stmt`
dalının döngü değişkeninin sınıfını HER ZAMAN `null` olarak bildirmesi
YÜZÜNDEN, `item.method()` çağrısını ÇÖZÜMLENEMEZ (`direct_unsafe`) sayıp
İÇİNDE bulunduğu TÜM fonksiyonu KOŞULSUZ zehirliyordu — çok YAYGIN bir OOP
idiomunda M.8'in kazanımını TAMAMEN sıfırlayan, GERÇEK bir boşluk.

**Düzeltme (`compiler/codegen_qbe/codegen.zig`, tamamı `collectRaiseInfoStmts`/
`collectRaiseInfoStmt` akışı içinde):** YENİ bir `list_elem_types:
*std.StringHashMapUnmanaged([]const u8)` parametresi (fonksiyon boyunca hangi
yerel/parametre adının `list[SomeClass]` tipinde OLDUĞUNU VE hangi sınıfa ait
OLDUĞUNU izler) tüm akışa (if/elif/else, while, for, try/except/finally,
lowlevel, with) thread edildi. `.var_decl`, `list[SomeClass]` tipinde bir
bildirim GÖRDÜĞÜNDE bu haritayı DOLDURUR; YENİ `buildParamListElemTypes`
(mevcut `buildParamVarTypes`in AYNASI) fonksiyon PARAMETRELERİ İçin AYNI işi
yapar. `.for_stmt` ARTIK döngü değişkeninin sınıfını `list_elem_types.
get(f.iterable.identifier)` İLE (önce `poisoned` kontrolüyle) ÇÖZÜMLÜYOR —
`genForList`nin GERÇEK codegen'İNİN (`collectLocals`in `.for_stmt` dalı)
ZATEN yaptığı AYNI çözümleme burada TEKRARLANDI.

**Doğrulama:**

- `tests/golden/codegen_cases/for_loop_method_call_elision_positive.nox`
  (+`.expected`): `boxes: list[Box]` parametresi ÜZERİNDE `for b in boxes:
  ... b.get() ...` — `Box`in ne `__init__`i ne `get`i raise ETMEZ, davranış
  (toplam = 6) doğrulandı.
- **IR-metni doğrulaması** (M.8'in `method_call_elision_positive` testinin
  AYNI önculü): AYNI fixture'ın ÜRETTİĞİ IR'da `nox_exception_pending`e TEK
  bir çağrı bile OLMADIĞI DOĞRUDAN doğrulandı.
- **Boz→kırmızı→düzelt:** `.for_stmt`in `elem_cn` çözümlemesi GEÇİCİ olarak
  YOK SAYILIP döngü değişkeni HER ZAMAN `null` ile bildirilecek şekilde
  değiştirildi — `zig build test` TAM OLARAK BEKLENEN TEK testi (yukarıdaki
  IR-metni doğrulaması) KIRMIZI verdi (467/468 geçti), AYNI fixture'ın
  DAVRANIŞ testi (M.8'in "yalnızca FAZLADAN kontrol kalır, YANLIŞ davranış
  ASLA" ilkesiyle TUTARLI biçimde) YEŞİL KALDI — elenmenin GERÇEKTEN
  yalnızca bir kontrol-elemesi optimizasyonu OLDUĞUNUN, davranışı hiçbir
  koşulda DEĞİŞTİRMEDİĞİNİN kanıtı. GERİ ALINIP `zig build test` (Debug +
  ReleaseFast) yeniden yeşil doğrulandı.
- **Performans doğrulaması:** `benchmarks/for_loop_method_elision.nox`
  (240M metod çağrısı, 30M dış yineleme × 8 elemanlı `list[Box]`) — kontrol
  HER ZAMAN üretilen ESKİ davranışa GEÇİCİ dönülerek ölçüldü: 273.0ms →
  259.6ms, **~%5 hızlanma** (M.8'in doğrudan `self.`/yerel-değişken metod
  çağrılarındaki ~%44'ten KÜÇÜK — burada yalnızca `nox_exception_pending`
  kontrolü elenir, metodun KENDİSİ hâlâ GERÇEK bir çağrıdır; GG.2'nin
  inlining'i SERBEST fonksiyonları kapsar, metodları DEĞİL). Bkz.
  `benchmarks/RESULTS.md`.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

### GG.4 (DEĞERLENDİRİLDİ, REDDEDİLDİ) — `nox_exception_pending`i inline etme

**Kaynak:** GG listesinin sıradaki maddesi — `emitExceptionCheck`in ürettiği
`call $nox_exception_pending(l %rt)`in (tek bir işaretçi karşılaştırmasından
İBARET bir fonksiyon) GG.1/GG.2'nin `emitInlinePredecrement`/seçici
inlining'iyle AYNI desenle DOĞRUDAN QBE'ye inline edilmesi.

**Uygulama (TAM olarak yapıldı, SONRA GERİ ALINDI):** `RuntimeState.
pending_exception`in bayt offset'i `@offsetOf` İLE derleme zamanında
öğrenilip `emitExceptionCheck`in `loadl {addr}` + `cnel ..., 0` + `jnz`
ÜRETMESİ sağlandı. **Zig 0.16'nın modül sınırı kuralı** ("import of file
outside module path") YÜZÜNDEN `runtime/alloc/asap.zig` `codegen.zig`den
DOĞRUDAN göreli yolla import EDİLEMEDİ — `asap.zig`nin `export fn`larını
(`nox_alloc`/`nox_runtime_init`/vb.) `noxc`nin KENDİ ikilisine ÇEKMEDEN
(bu, `nox_cycle_deinit`/`nox_cycle_collect` gibi `noxrt.o`ya ÖZGÜ
sembollere ÇÖZÜMLENEMEYEN referanslar YÜZÜNDEN LİNK HATASI verirdi)
YALNIZCA TİP/OFFSET bilgisi taşıyan, `export fn` İÇERMEYEN AYRI bir
`runtime/alloc/runtime_state.zig` dosyası çıkarılıp (`RuntimeState`in TEK
doğruluk kaynağı BURASI, `asap.zig` YENİDEN İHRAÇ eder) `build.zig`e YENİ
bir `rt_layout` modülü (`nox_mod`/`noxc_mod`a SIFIR bağlama/linkleme
etkisiyle, YALNIZCA comptime `@offsetOf` İçin) eklendi.

**Doğrulama (TAM):** `zig build test` (Debug + ReleaseFast) 467/468 yeşil
(kalan 1, `http_serve_multicore` testinin ÖNCEDEN belgelenmiş, İLGİSİZ
zamanlama flake'i — ayrı bir rerun İLE doğrulandı). Break→red→fix:
`pending`in hesaplanması GEÇİCİ olarak `=w copy 0`e (HER ZAMAN "istisna
yok") sabitlenince TAM OLARAK 20 test (istisna-yayılım/çıkış-kodu/sızıntı
testleri) KIRMIZI oldu — kontrolün GERÇEKTEN load-bearing olduğu KANITLANDI.
IR-metni testleri (`method_call_elision_positive`/`for_loop_method_call_
elision_positive`in "elenmiş" kanıtı) `"nox_exception_pending"` yerine
`"exc_propagate"` etiketini ARAMAK üzere GÜNCELLENDİ (`emitExceptionCheck`
ARTIK bu ismi HİÇ ÜRETMEDİĞİNDEN, ESKİ marker HER programda vacuously
doğru olurdu — bu da AYRICA doğru bir düzeltme, bkz. aşağıdaki geri alma
notu).

**Ölçüm — BEKLENENİN TERSİ, TEKRARLANABİLİR bir REGRESYON:** yeni
`benchmarks/exception_check_overhead.nox` (gövdesinde bir `raise` OLAN,
bu yüzden `must_not_raise`e ASLA giremeyen — kontrolün HER ZAMAN
üretildiği TEK kalan durum — bir fonksiyona 300M çağrı, hiçbiri GERÇEKTEN
raise ETMEZ) 3'er tekrarla İKİ YÖNDE ölçüldü:

| Durum | Süre (min, 300M çağrı) |
|---|---|
| ÖNCESİ (`call $nox_exception_pending`) | 453.5-454.3ms (3 ölçüm) |
| SONRASI (inline `loadl`+`cnel`) | 532.5-533.4ms (3 ölçüm) |

**~%17 YAVAŞLAMA**, gürültü DEĞİL — her iki yönde de 3 tekrar ~1ms
varyansla TUTARLIYDI. Kök neden PROFİLLENMEDİ (bu turun kapsamı DIŞINDA),
ama en olası açıklama: QBE'nin KENDİ (bu fazın giriş araştırmasında ÖNCEDEN
doğrulanmış — bkz. §3.66'nın giriş notu) linear-scan (graph-coloring
DEĞİL) register ayırıcısı — bir `call` sınırı doğal bir "canlı aralık"
kesim noktası sağlarken, `loadl`/`cnel`i AYNI temel bloğa gömmek kayıt
baskısını ARTIRIP `maybe_raise`in KENDİ gövdesindeki değişkenler İçin
DAHA KÖTÜ spill kararlarına yol AÇMIŞ olabilir.

**Sonuç — TAMAMEN GERİ ALINDI:** `compiler/codegen_qbe/codegen.zig`,
`build.zig`, `runtime/alloc/asap.zig` `git checkout` İLE ÖNCEKİ (GG.3
SONRASI, `call $nox_exception_pending` HÂLÂ GERÇEK bir çağrı) durumuna
döndürüldü; `runtime/alloc/runtime_state.zig` SİLİNDİ. `tests/golden/
codegen_golden_test.zig`deki IR-metni testleri de (`"exc_propagate"`
DEĞİŞİKLİĞİ dahil) GERİ ALINDI — orijinal `"nox_exception_pending"`
marker'ı yeniden DOĞRU (çağrı hâlâ GERÇEK olduğundan). `exception_check_
overhead.nox` benchmark'ı VE `benchmarks/run.zig`deki kaydı KALICI olarak
TUTULDU — hem bu ÖLÇÜLMÜŞ bulguyu belgeler HEM DE gelecekte AYNI fikrin
(ölçülmeden) yeniden denenmesine karşı bir regresyon-koruma görevi görür.
Bu, M.5/M.8'in "ölçülmeden mimari EKLEME" reddiyle AYNI kategoride bir
sonuçtur — ama BURADA mimari GERÇEKTEN uygulanıp ÖLÇÜLDÜ ve TAM OLARAK BU
YÜZDEN reddedildi (AGENTS.md'nin "measure, don't assume" disiplini).

`zig build test` (Debug + ReleaseFast) yeşil (geri alma SONRASI), `zig fmt`
temiz.

### GG.5 (TAMAMLANDI) — Döngü içindeki `s[i]`nin tekrar eden `strlen`i (manuel LICM)

**Kaynak:** GG.1'in araştırma notunda ERTELENEN bulgu — `s[i]`nin sınır
kontrolü İçin GEREKEN `strlen(s)`, `genStrIndex`in HER ÇAĞRISINDA YENİDEN
hesaplanıyordu; bir döngü İÇİNDE tekrar eden `s[i]` erişimi (ör. bir
dizeyi karakter karakter tarayan bir tokenize edici/ayrıştırıcı — ÇOK
YAYGIN bir idiom) bu yüzden O(dizi uzunluğu × erişim sayısı) — GERÇEK bir
O(n²) hazır, AYNI kök neden sınıfı (QBE'nin LICM YAPMAMASI) GG.1'in
`nox_str_release`i ile PAYLAŞILAN.

**Uygulama (`compiler/codegen_qbe/codegen.zig`, tamamı codegen SEVİYESİNDE
— checker/ownership analizine dokunulmadan):** YENİ bir `str_len_cache:
StringHashMapUnmanaged([]const u8)` (isim → önceden hesaplanmış QBE
temp'i) alanı, `genWhile`/`genForRange`/`genForList`in ÜÇÜNÜN de döngüye
GİRMEDEN HEMEN ÖNCE çağırdığı `enterStrLenCacheScope`/döngü BİTTİKTEN
SONRA çağırdığı `exitStrLenCacheScope` ÇİFTİYLE doldurulup boşaltılır.
`enterStrLenCacheScope`, döngü GÖVDESİNİ (iç içe if/while/for/try/with/
lowlevel DAHİL) tarayan YENİ bir `collectIndexStrBasesStmts`/
`collectIndexStrBasesExpr` çifti İLE `str`-tipli, `s[i]` deseninde
kullanılan TÜM aday isimleri toplar; AYRI bir `collectReassignedNames`
AYNI gövdede (`assign`/`var_decl` gölgelemesi/`for` döngü değişkeni/
`except ... as`/`with ... as` DAHİL) yeniden atanan İSİMLERİ toplar —
YALNIZCA candidates − reassigned KÜMESİ GERÇEKTEN önbelleğe alınır.
`bodyHasNestedFuncDef`, gövdede HERHANGİ bir iç içe closure (`func_def`)
VARSA TÜM önbelleklemeyi BİLİNÇLİ olarak (closure'ın yakalanan bir ismi
NASIL ele aldığı bu turun kapsamı DIŞINDA analiz EDİLMEDİĞİNDEN)
MUHAFAZAKÂR biçimde atlar. `genStrIndex`, `idx.obj` bir kimlikse VE
`str_len_cache`de MEVCUTSA `$strlen` ÇAĞRISI YERİNE önceden hesaplanmış
temp'i KULLANIR — QBE temp'leri fonksiyon BOYUNCA geçerli OLDUĞUNDAN (GG.2/
GG.4'ün AYNI önculü) tek bir hoisted çağrı, İÇ İÇE döngüler DAHİL, TÜM
sonraki `s[i]` erişimlerinde GÜVENLE yeniden kullanılabilir (dış döngünün
ÖNCEDEN eklediği bir girişi iç döngü TEKRAR eklemez/SİLMEZ).

**Doğrulama:**

- `tests/golden/codegen_cases/str_index_loop_licm_positive.nox`: `count_two`
  (AYNI `s`ye İKİ AYRI `s[i]` erişimi, `while`) VE `count_via_for` (`for i in
  range(len(s)): ... s[i] ...`) — davranış (doğru sayım) DEĞİŞMEDİ.
- **IR-metni doğrulaması:** AYNI fixture'ın ÜRETTİĞİ IR'da `call $strlen`
  TAM OLARAK 3 KEZ geçer (`count_two`nun İKİ statik `s[i]` konumu TEK bir
  hoisted çağrıya DÜŞTÜ + `count_via_for`nin `len()` builtin'i [1] + KENDİ
  hoisted çağrısı [1]) — GG.5 ÖNCESİ bu SAYI 4 OLURDU.
- `str_index_loop_reassign_safety.nox`: `s` döngü İÇİNDE (`if` dalında)
  yeniden atanıyor — `collectReassignedNames` bunu YAKALAYIP `s`yi
  ADAYLARDAN ÇIKARDIĞINDAN, İKİNCİ yinelemede `s[1]` YENİ atanan dizenin
  KENDİ karakterini (`'y'`, ESKİ dizenin `'b'`si DEĞİL) DOĞRU döndürür.
- `str_index_loop_reassign_stale_len.nox`: DAHA İNCE bir güvenlik senaryosu
  — `s` KISA başlayıp döngü İÇİNDE DAHA UZUN bir dizeye atanıyor; BAYAT
  (kısa) bir önbellek KULLANILSAYDI GEÇERLİ bir erişimi YANLIŞLIKLA
  `IndexError` OLARAK reddederdi. `try/except` GEREKTİRDİĞİNDEN (bkz.
  aşağıdaki yan bulgu) `expectGolden` YERİNE yalnızca çıkış kodu/stdout'u
  doğrulayan ÖZEL bir test kullanır.
- **Boz→kırmızı→düzelt:** `collectLoopInvariantStrBases`in `if (!reassigned.
  contains(k.*))` KOŞULU GEÇİCİ olarak `if (true or ...)`e (yeniden-atama
  KORUMASINI YOK SAYARAK) değiştirilince, `str_index_loop_reassign_stale_
  len.nox` TAM OLARAK BEKLENDİĞİ gibi YANLIŞ sonuç (200 yerine 101) verdi
  — bayat uzunluk korumasının GERÇEKTEN load-bearing olduğu KANITLANDI.
  GERİ ALINIP `zig build test` (Debug + ReleaseFast) yeniden yeşil
  doğrulandı (467/468 — kalan tek başarısızlık ÖNCEDEN belgelenmiş, İLGİSİZ
  bir HTTP eşzamanlılık zamanlama flake'i, İKİNCİ bir rerun İLE onaylandı).
- **Performans doğrulaması:** `benchmarks/str_index_loop_licm.nox` (5000
  baytlık bir dizeyi 4000 kez TARAR, 20M erişim) — önbellekleme GEÇİCİ
  olarak devre dışı bırakılıp (`genStrIndex`nin önbellek kontrolü `if
  (false and ...)`e sabitlenerek) yeniden ölçüldü: **1919.3ms → 82.3ms,
  ~%96 hızlanma (~23,3×)** — GG serisinin EN BÜYÜK ölçülmüş kazanımı.

**Yan bulgu (GG.5'TEN BAĞIMSIZ, AYRI bir takip görevine bırakıldı):**
break→red→fix ritüeli SIRASINDA, bir `str` yerelinin bir döngü İçinde
yeniden atanmasının, AYNI döngüdeki bir `try/except` bloğuyla (o dizeyi
`s[i]` İLE indeksleyen) BİRLEŞTİĞİNDE ÖNCEDEN VAR OLAN (`git stash` İLE
pre-GG.5 codegen'de de AYNEN yeniden üretilen — GG.5'in KENDİSİYLE HİÇ
İLGİSİ YOK) bir bellek sızıntısı VE (AYRI olarak) yakalanmamış bir
istisnanın bir `while` döngüsü İÇİNDEN GEÇERKEN (uncaught exception
propagation through a loop) doğru şekilde process'i sonlandırmadığı
KEŞFEDİLDİ. Her ikisi de bu turun kapsamı DIŞINDA bırakıldı.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

### GG.6 (DEĞERLENDİRİLDİ, REDDEDİLDİ) — 2'nin kuvveti sabit çarpımlarını shift'e çevirme

**Kaynak:** GG listesinin sıradaki maddesi — `i * 8` gibi 2'nin kuvveti bir
SABİTLE çarpmanın, QBE'nin `mul` ÜRETTİĞİ (GG'nin giriş araştırmasında
ÖNCEDEN doğrulanan "QBE strength reduction YAPMAZ" bulgusu — `.ssa`
dökümüyle DOĞRULANDI: `qbe -t arm64_apple` GERÇEKTEN `mul x3, x2, x3`
üretiyor, `shl`/`lsl` DEĞİL) YERİNE codegen'in `genBinary`sinde `shl`e
lowerlanması.

**Ölçüm (KOD YAZILMADAN ÖNCE, GG.4'ün "önce ölç" dersini UYGULAYARAK):**
`i * 8` İçeren bir sıcak döngünün (500M yineleme) ÜRETTİĞİ `.ssa` ELLE
kopyalanıp `mul %t, 8` satırları `sed` İLE `shl %t, 3`e DÖNÜŞTÜRÜLDÜ,
`qbe`+`cc` İLE AYRI AYRI derlenip 3'er tekrarla ölçüldü:

| Durum | Süre (min, 500M çarpım) |
|---|---|
| `mul` (mevcut) | 140-143ms (3 ölçüm) |
| `shl` (elle yama) | 140-143ms (3 ölçüm) |

**ÖLÇÜLEBİLİR FARK YOK** — Apple Silicon'ın (M4, bu makine) tamsayı çarpma
birimi KÜÇÜK sabitlerle çarpmada `shl` İLE PRATİKTE AYNI hızda (modern
geniş, sıra-dışı [out-of-order] çekirdeklerde tamsayı çarpma NADİREN
darboğazdır — GG.4'ün `nox_exception_pending` bulgusuyla AYNI kategoride
bir sonuç: "bariz" bir mikro-optimizasyon, GERÇEK donanımda ÖLÇÜLDÜĞÜNDE
sıfır kazanım verdi). **Hiçbir kod YAZILMADI** — `genBinary`ye strength
reduction EKLEMEK, SIFIR ölçülmüş fayda İçin YALNIZCA derleyici
karmaşıklığı EKLERDİ (AGENTS.md'nin "measure, don't assume" disiplini,
GG.4/M.5/M.8 İLE AYNI kategoride bir red).

### GG.7 (TAMAMLANDI) — En küçük/en sık ARC yardımcılarını çağrı yerine inline etme

**Kaynak:** GG.1'in `.str` dalına uyguladığı `emitInlinePredecrement`
deseninin (predecrement DOĞRUDAN QBE IR'ına inline edilir, YALNIZCA
GERÇEKTEN sıfıra/altına düştüğünde gerçek serbest bırakma çağrısına
düşülür) `releaseValueIfSet`in KALAN İKİ dalına — ilkel-elemanlı
`list[T]` (ÇOK SIK — HER liste release'i) VE `boxed_scalar` (Optional-
kutulanmış ilkel, FF.6.4) — HÂLÂ UYGULANMAMIŞ olduğu bulundu; İKİSİ de
GERÇEK bir `call $nox_rc_release` üretiyordu.

**Düzeltme (`compiler/codegen_qbe/codegen.zig`, `releaseValueIfSet`):**
İKİ dal da GG.1'in `.str` dalıyla BİREBİR AYNI splice desenine (`should_free
= emitInlinePredecrement(ptr)`, `jnz` İLE `free_label`/`skip_free_label`,
`free_label`de YALNIZCA `nox_rc_free_payload` çağrılır) geçirildi —
`nox_rc_release`in KENDİSİ ZATEN TAM OLARAK `nox_rc_predecrement(ptr) !=
0 ? nox_rc_free_payload(...) : ()` OLDUĞUNDAN (bkz. `runtime/alloc/
arc.zig`), bu davranış BİREBİR KORUNUR.

**Doğrulama:** `zig build test` (Debug + ReleaseFast) yeşil (467/468,
kalan tek başarısızlık ÖNCEDEN belgelenmiş İLGİSİZ HTTP flake'i, rerun
İLE onaylandı) — MEVCUT golden test suite (Optional/list release'i
zaten kapsayan onlarca test) SIFIR davranış değişikliğini KANITLAR.
**Boz→kırmızı→düzelt:** HER İKİ dalın `jnz {s}, {free_label}, {skip_
free_label}`i GEÇİCİ olarak KOŞULSUZ `jmp {free_label}`e (HER ZAMAN
serbest bırak, refcount'tan BAĞIMSIZ) değiştirilince TAM OLARAK 4 test
KIRMIZI oldu (paylaşılan liste/kutu referanslarının BAŞKA bir sahibi
VARKEN erken serbest bırakılması — `.boxed_scalar` dalının KENDİ belge
notunun UYARDIĞI TAM O çifte-serbest-bırakma senaryosu) — kontrolün
GERÇEKTEN load-bearing olduğu KANITLANDI. GERİ ALINIP yeniden yeşil
doğrulandı.

**Ölçüm:** YENİ `benchmarks/list_release_overhead.nox` (`make_list`,
GG.2'nin seçici inlining'iyle `run`nin İÇİNE spliced, HER yinelemede
TAZE bir `list[int]` inşa edip HEMEN tüketir — 50M yineleme) — İKİ dal
GEÇİCİ olarak ESKİ (gerçek `call`) davranışına döndürülüp yeniden
ölçüldü: **171.2ms → 157.9ms, ~%8 hızlanma**. GG.1'in `.str` kazanımından
(~%23) KÜÇÜK — burada `nox_rc_alloc`ın KENDİSİ (GG.2'nin ELEYEMEDİĞİ,
gerçek bir allocator çağrısı) hâlâ dominant maliyet, bkz. GG.2'nin AYNI
`list_traversal` notu — ama GERÇEK, ölçülmüş bir kazanım.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

### GG.8 (DEĞERLENDİRİLDİ, REDDEDİLDİ) — Runtime'a dokunmayan saf fonksiyonlar için RT_PARAM'ı elemek

**Kaynak:** GG listesinin sıradaki maddesi — HER Nox fonksiyonu (`genFunction`,
bkz. `export function ... ${s}(l {RT_PARAM}` satırı) KOŞULSUZ olarak İLK
parametre olarak `%rt`yi alır — `fib(n: int) -> int` GİBİ tahsis/istisna/
ARC'a HİÇ dokunmayan SAF fonksiyonlar İçin BİLE. GG.8'in fikri: BÖYLE
fonksiyonların imzasından `rt`yi ELEYİP çağrı sitelerinden de KALDIRMAK.

**Ölçüm (KOD YAZILMADAN ÖNCE, GG.4/GG.6'nın dersi UYGULANARAK):**
`numeric_recursion` benchmark'ının (`fib(35)`, ~30M özyinelemeli çağrı,
`fib`in KENDİSİ `rt`ye HİÇ dokunmaz) ÜRETTİĞİ `.ssa` ELLE kopyalanıp
`fib`in imzasından VE HER ÜÇ çağrı sitesinden (2 özyinelemeli + 1 `main`den)
`%rt` parametresi ÇIKARILIP AYRI derlendi:

| Durum | Süre (5 ölçüm, `fib(35)`) |
|---|---|
| `rt` parametreli (mevcut) | ~0.02-0.03s (5 ölçümün TÜMÜ) |
| `rt`SİZ (elle yama) | ~0.02s (5 ölçümün TÜMÜ) |

**ÖLÇÜLEBİLİR FARK YOK** — GG.6'nın `mul`/`shl` bulgusuyla AYNI kategoride
bir sonuç: ARM64 çağrı kuralı İLK 8 tamsayı argümanı KAYITLARDA (x0-x7)
geçirir, bu yüzden BİR argüman EKLEMEK/ÇIKARMAK (fonksiyon HÂLÂ bu
sınırın ÇOK altındayken) Apple Silicon'ın geniş, sıra-dışı çekirdeğinde
ÖLÇÜLEBİLİR bir maliyet EKLEMEZ/kaldırmaz. **Hiçbir kod YAZILMADI** —
AYRICA (ölçülmüş sıfır faydanın ÖTESİNDE) GERÇEK uygulama, GG.1'in
`computeMustNotRaise`sine BENZER YENİ bir whole-program "hiçbir zaman
rt'ye dokunmaz" saflık analizi + HER çağrı sitesinin (GG.2'nin seçici
inlining'iyle ETKİLEŞİMİ DAHİL) koşullu güncellenmesini GEREKTİRİRDİ —
SIFIR ölçülmüş kazanım İçin ORANTISIZ bir mimari karmaşıklık maliyeti
(AGENTS.md'nin "measure, don't assume" disiplini, GG.4/GG.6/M.5/M.8 İLE
AYNI kategoride bir red).

### GG.9 (TAMAMLANDI) — Kanıtlanabilir sınır-içi erişimlerde bounds-check elemesi

**Kaynak:** GG listesinin sıradaki maddesi — `for i in range(len(xs)):
... xs[i] ...` deseninde `i`nin `[0, len(xs))` ARALIĞINDA olduğu döngünün
KENDİ `range(len(xs))` sınırından ZATEN KANITLANMIŞTIR, ama `genIndex`/
`genStrIndex` HER `xs[i]`de AYRICA bir sınır kontrolü (2 karşılaştırma +
bir OR + bir koşullu `IndexError` dalı) üretir.

**Ölçüm (KOD YAZILMADAN ÖNCE, GG.4/GG.6/GG.8'in dersi UYGULANARAK):**
`for i in range(len(xs)): total + xs[i]` İçeren 100M erişimlik bir
döngünün ÜRETTİĞİ `.ssa` ELLE sınır kontrolü ÇIKARILARAK yamanıp AYRI
derlendi:

| Durum | Süre |
|---|---|
| Sınır kontrolü VAR (mevcut) | ~76-77ms |
| Sınır kontrolü ELLE ÇIKARILMIŞ | ~46-47ms |

**GG.4/GG.6/GG.8'in AKSİNE, BU SEFER GERÇEK, ÖLÇÜLEBİLİR bir fark VAR**
(~%39-40) — İKİ karşılaştırma + OR + koşullu dal ZİNCİRİ (TEK bir `mul`/
argüman farkının AKSİNE), muhtemelen elemanın YÜKLENMESİNDEN ÖNCE
TAMAMLANMASI GEREKEN VERİ-BAĞIMLI bir gecikme zinciri OLUŞTURDUĞUNDAN,
Apple Silicon'da BİLE ÖLÇÜLEBİLİR bir maliyet TAŞIR. Bu, GG serisinin İLK
kez "ölç, KOD YAZ" kararına (GG.5'ten SONRA) yol açan İKİNCİ bulgusudur.

**Uygulama (`compiler/codegen_qbe/codegen.zig`, tamamı codegen SEVİYESİNDE):**
YENİ bir `bounds_elide_ctx: ?BoundsElideCtx` (isim ÇİFTİ: `{list_name,
idx_var}`) alanı, `genForRange`nin YENİ `detectBoundsElideCtx`sinin
TESPİT ETTİĞİ `for i in range(len(xs)): ...` deseninde doldurulur —
GG.5'in `str_len_cache`iyle AYNI güvenlik disiplini: `xs`/`i` gövde
İÇİNDE (iç içe döngüler DAHİL) HİÇ yeniden atanmıyor (`collectReassignedNames`
YENİDEN KULLANILIR) VE hiçbir iç içe closure YOK (`bodyHasNestedFuncDef`
YENİDEN KULLANILIR). `genIndex`/`genStrIndex`, YENİ `boundsElideApplies`
İLE (`idx.obj`/`idx.index` İKİSİ de BASİT birer kimlik VE bağlamla İSİM
BAZINDA EŞLEŞİYORSA) sınır kontrolünü TAMAMEN ATLAR — `genStrIndex`de BU
AYRICA `strlen`in KENDİSİNİN (GG.5'in önbelleği DAHİL) HİÇ HESAPLANMAMASI
anlamına gelir (yalnızca sınır kontrolü İçin GEREKTİĞİNDEN). TEK bir
bağlam Hem `list[T]` Hem `str` indekslemesini KAPSAR (heap türü ZATEN o
dalda BİLİNİYOR).

**Doğrulama:**

- `bounds_check_elision_positive.nox`: `sum_list` (`list[int]`) VE
  `count_char` (`str`) İKİSİ de deseni kullanır — davranış (doğru toplam/
  sayım) DEĞİŞMEDİ.
- **IR-metni doğrulaması:** AYNI fixture'ın ÜRETTİĞİ IR'da NE
  `list_idx_err` NE `str_idx_err` (sınır-DIŞI dalının etiket ÖNEKLERİ)
  TEK bir kez bile GÖRÜNMEZ.
- `bounds_check_elision_reassign_safety.nox`: `xs` döngü İÇİNDE (bir `if`
  dalında) yeniden atanıyor — **BİLİNÇLİ olarak ÇALIŞTIRILMAZ** (bkz.
  aşağıdaki yan bulgu), yalnızca IR-metni DÜZEYİNDE `list_idx_err`in HÂLÂ
  ÜRETİLDİĞİ (elenmediği) doğrulanır.
- **Boz→kırmızı→düzelt:** `detectBoundsElideCtx`in yeniden-atama
  KORUMASI (`reassigned.contains(...)` kontrolleri) GEÇİCİ olarak YOK
  SAYILINCA TAM OLARAK beklenen tek test (reassignment-safety IR kontrolü)
  KIRMIZI oldu (129/130) — kontrolün GERÇEKTEN load-bearing olduğu
  KANITLANDI. GERİ ALINIP `zig build test` (Debug + ReleaseFast) yeniden
  yeşil doğrulandı.
- **Performans doğrulaması:** `benchmarks/bounds_check_elision.nox` (20
  elemanlı bir listeyi 5M kez, 100M erişim, tarar) — `boundsElideApplies`
  GEÇİCİ olarak KOŞULSUZ `false` DÖNECEK şekilde değiştirilip yeniden
  ölçüldü: **67.6ms → 38.7ms, ~%43 hızlanma (~1,75×)** — GG.5'ten (~23,3×)
  SONRA GG serisinin EN BÜYÜK ikinci ölçülmüş kazanımı.

**Yan bulgu (GG.9'DAN BAĞIMSIZ, AYRI bir takip görevine bırakıldı):**
break→red→fix ritüeli SIRASINDA, `bounds_check_elision_reassign_safety.nox`nin
DAVRANIŞ testini (`expectGolden`) ÇALIŞTIRMAYA ÇALIŞIRKEN, bir `list`
yerelinin bir `for`-range döngüsü İçinde yeniden atanmasının, AYNI
döngüdeki bir `try/except` bloğuyla BİRLEŞTİĞİNDE ÖNCEDEN VAR OLAN
(GG.5'in `str` İçin bulduğu AYNI hatanın `list` KARŞILIĞI — `git stash`
İLE pre-GG.9 codegen'de de AYNEN yeniden üretildi) bir bellek sızıntısı
KEŞFEDİLDİ. Bu YÜZDEN o fixture yalnızca STATİK (IR-metni) doğrulama
İçin kullanıldı, GERÇEKTEN ÇALIŞTIRILMADI.

`zig build test` (Debug + ReleaseFast) yeşil, `zig fmt` temiz.

### GG.10 (DEĞERLENDİRİLDİ, KAPATILDI) — Fiber'ların iş parçacıkları arası taşınamaması: yapısal değerlendirme

**Kaynak:** GG serisinin (GG.1-GG.10) SON maddesi — Nox'un fiber'larının
spawn edildikleri OS iş parçacığına SABİT kalması (asla başka bir iş
parçacığına "çalınamaması"/work-stealing YAPILAMAMASI), `nox.http.
serve_multicore` GİBİ çok-çekirdekli senaryolarda POTANSİYEL bir yük
dengesizliği kaynağı olarak İŞARETLENMİŞTİ. Kullanıcı ÖNCE tam bir mimari
tasarım turu İSTEDİ; araştırma SUNULUNCA "AA.1/BB.1 + yeni bulguyla
KAPAT"ı SEÇTİ.

**1. Bu soru ZATEN soruldu ve cevaplandı.** §3.46 (Faz AA.1) gerçek bir
M:N/work-stealing zamanlayıcıyı ARAŞTIRDI, 7 somut mimari engel buldu —
EN BÜYÜĞÜ ARC refcount'unun BİLİNÇLİ olarak atomic OLMAMASI (Faz X.3,
ÖLÇÜLMÜŞ bir performans kaygısıyla REDDEDİLMİŞTİ). §3.47 (Faz BB.1)
kullanıcının BUNA YANIT olarak verdiği AÇIK karar: **shared-nothing
model** — her OS iş parçacığı KENDİ bağımsız M:1 fiber zamanlayıcısını
VE KENDİ bağımsız `RuntimeState`/ARC yığınını çalıştırır, hiçbir fiber/
ARC nesnesi ASLA iş parçacıkları arası GEÇMEZ. BU, BUGÜN ÇALIŞAN
mimaridir (`runtime/async_rt/bridge.zig`nin `threadlocal var g_scheduler`ı,
`nox.thread`/`ThreadChannel`nin kopya-tabanlı mesajlaşması,
`nox.http.serve_multicore`nin N bağımsız `RuntimeState`+`Scheduler`
çifti, ortak olan TEK şey ham dinleme soket fd'si).

**2. Gerçek bir sorun ÖLÇÜLMEDİ.** `nox.http.serve_multicore` (bu
sınırlamanın PRATİKTE önemli OLABİLECEĞİ TEK gerçek senaryo) İçin
ÖNCEKİ "yüksek eşzamanlılıkta gerileme" araştırması (§3.60'ın belge
notu, `benchmarks/RESULTS.md` "Bölüm 3") kök nedeni BAŞKA yerde buldu
(Debug modunda linklenen `noxrt.o` + yanlış `max_connections`
yapılandırması) — worker'lar arası yük dengesizliği HİÇ ölçülmedi/
gözlemlenmedi. Mevcut toplam verim ZATEN çıplak Zig N-iş-parçacıklı
tabanını GEÇİYOR. Belgelenmiş TEK gerçek (ama KÜÇÜK kapsamlı, ARC/
fiber'a HİÇ dokunmayan) sınırlama: `SO_REUSEPORT`/`EPOLLEXCLUSIVE`
KULLANILMIYOR, bağlantı dağıtımı "thundering herd" `accept()`
yarışına dayanıyor (`runtime/stdlib_shims/http_server.zig`) — spec
içinde ZATEN bilinçli, ayrı bir gelecek fazına bırakılmış KAPSAM DIŞI
not olarak kayıtlı (§3.60).

**3. YENİ bulgu (bu turda kanıtlandı): QBE'nin atomic instruction'ı
YOK.** `qbe -h` çıktısı VE QBE'nin IL komut kümesi (yalnızca `add`/
`sub`/`load`/`store`/karşılaştırma/çağrı/phi/jump — RMW/CAS/fence YOK)
DOĞRULANDI. Bu, atomic refcount'un maliyetini X.3/AA.1'in
ÖNGÖRDÜĞÜNDEN DE BÜYÜK yapar: `emitInlineRetain`/`emitInlinePredecrement`
(GG.1/GG.2/GG.7'nin İNCE AYARLADIĞI, ÇOK sayıda benchmark'ta ÖLÇÜLMÜŞ
kazanç sağlayan inline düz aritmetik) atomic bir işlem İçin QBE'ye
GÖMÜLEMEZ — HER TEK retain/release (yalnızca taşınabilir fiber'lara ait
DEĞİL, PROGRAMDAKİ HER ARC nesnesi İçin, statik olarak "bu nesne asla
taşınmayacak" KANITLANAMADIĞINDAN) GERÇEK bir Zig-taraflı fonksiyon
çağrısına DÖNMEK ZORUNDA kalırdı. Bu turda ZATEN DOĞRUDAN ÖLÇÜLEN,
doğrudan İLGİLİ veriler — GG.1'in (`.str` release'ini inline ETMENİN
kazancı) ~%23'ü (65ms→50ms) ve GG.7'nin (`list`/`boxed_scalar`
release'ini inline ETMENİN kazancı) ~%8'i (171.2ms→157.9ms) —
**inline'dan real-call'a GERİ DÖNMENİN** yaklaşık maliyetini (yönü
TERS ama BÜYÜKLÜK AYNI) temsil eder: GG serisinin kazandığı toplam
performansın ÖNEMLİ bir kısmını SIFIRLAR, atomic işlemin KENDİSİNİN
(call overhead'inin ÜSTÜNE) EK maliyeti HENÜZ SAYILMADAN.

**Sonuç:** AGENTS.md'nin bu FAZ boyunca defalarca (GG.4, GG.6, GG.8)
UYGULANAN "measure, don't assume" disiplini burada TERS yönde de
geçerli: KANITLANMIŞ, BÜYÜK bir performans maliyetini, ÖLÇÜLMÜŞ HİÇBİR
fayda OLMADAN kabul etmek YANLIŞ olur. GG.10 DEĞERLENDİRİLDİ, KAPATILDI
— mevcut mimari (AA.1/BB.1) BİLGİLİ VE HÂLÂ GEÇERLİ bir karardır, KOD
DEĞİŞİKLİĞİ YAPILMADI.

**Faz GG (GG.1-GG.10) BURADA TAMAMEN KAPANIR.**

### HH.1 (TAMAMLANDI) — Accept backlog artırımı; `ConnCtx` havuzu DENENDİ, GERİ ALINDI

**Kaynak:** `nox.http` darboğaz analizinin (kullanıcı talebiyle yapılan
uçtan uca inceleme) İLK bulgusu — `runtime/stdlib_shims/http_server.zig`nin
`bindAndListen`i `std.c.listen(fd, 128)` kullanıyordu, `benchmarks/
http_compare/zig_server.zig`nin KARŞILAŞTIRMA sunucusu İSE ZATEN `1024`
kullanıyordu — Nox KENDİSİ dezavantajlı bir backlog İLE ölçülüyordu.
Backlog `1024`e çıkarıldı.

**`ConnCtx` havuzu DENENDİ, GERÇEK bir kullanım-sonrası-serbest-bırakma
tuzağı BULUNUP GERİ ALINDI:** `Scheduler.stack_pool`/`acquireStack`/
`releaseStack`İLE AYNI "geri dönüştür" desenini `ConnCtx` İçin de
uygulama girişimi, ELLE yazılan bir reprodüksiyonla (bkz. proje geçmişi
— iki eşzamanlı bağlantılı bir `.nox` sunucusu, Debug modunda çalıştırıldı)
GERÇEK bir hata ORTAYA ÇIKARDI: `serveImpl` (fiber yolunda) `max_connections`
bağlantıyı KABUL EDER etmez DÖNER — henüz TAMAMLANMAMIŞ bağlantı fiber'ları
(ör. GECİKMELİ bir istemci) zamanlayıcı TARAFINDAN `serveImpl`nin KENDİ
yığın çerçevesi GERİ DÖNDÜKTEN ÇOK SONRA çalıştırılmaya devam eder. Havuz
`serveImpl`nin yerel bir değişkeni OLARAK tasarlanmıştı — bu, GERİ
DÖNÜLDÜKTEN SONRA hâlâ çalışan bir fiber'ın temizlik `defer`inin SALLANAN
(dangling) bir yığın işaretçisine YAZMASINA yol açardı (`zig build test`nin
İKİ eşzamanlı bağlantılı golden testinde `term == .exited` başarısızlığı
OLARAK YAKALANDI — Debug modunda TUTARLI, ReleaseFast'ta `smp_allocator`ın
sessizce TOLERE ETMESİ yüzünden GİZLENEN bir bozulma).

`ConnCtx` KÜÇÜK bir struct (birkaç işaretçi/`usize`) olduğundan, havuzu
`Scheduler`e taşıyıp (bu, `http_server.zig`nin bugün `scheduler.zig`ye
BAĞIMLI OLDUĞU yönü TERSİNE çevirip modüller arası YENİ bir bağımlılık
yaratırdı) bu riski GİDERMEYE DEĞMEDİ — **kod deposundan GERİ ALINDI**,
`gpa.create`/`gpa.destroy` KORUNDU. AGENTS.md'nin "measure, don't assume"
disiplininin BİR UZANTISI: bir optimizasyon KENDİ karmaşıklığının/riskinin
KARŞILIĞINI VERMİYORSA (burada: yığın-ömrü güvenliği İÇİN modüller arası
bağımlılık gerektiriyor, KÜÇÜK bir struct İçin), TERK EDİLİR.

### HH.2 (TAMAMLANDI) — İstek alanlarının çift kopyalanmasını gider (kopyala → retain)

**Kaynak:** darboğaz analizinin İKİNCİ bulgusu — `connectionEntry`
(`runtime/stdlib_shims/http_server.zig`) `method`/`target`/header isim-
değerlerini ÖNCE `gpa.dupe` (düz, ARC-DIŞI bir kopya) İLE tahsis ediyordu,
SONRA Nox tarafı `nox_http_request_method/target/body/headers`i ÇAĞIRDIĞINDA
`http_client.dupeToNoxStr`/(headers İçin döngüsel `dupeToNoxStr`) AYNI
veriyi İKİNCİ KEZ, ARC-sahipli olarak kopyalıyordu — trivial bir isteğin
BİLE `method`/`target`/gövde/HER header İçin İKİ KAT bellek kopyası
ödediği anlamına geliyordu.

**Çözüm:** `connectionEntry` ARTIK method/target/gövde/header isim-
değerlerini DOĞRUDAN ARC-sahipli (`http_client.dupeToNoxStr`, `nox_rc_alloc`
tabanlı) olarak inşa eder — TEK kopya. `connectionEntry`nin KENDİ referansı
`defer` İLE HER ZAMAN `nox_str_release` edilir (standart retain/release
disiplini — "transfer sahipliği" bookkeeping'i GEREKMEZ). `nox_http_request_
method/target/body` ARTIK kopyalamaz, `nox_rc_retain` yapıp AYNI işaretçiyi
döner (O(1), `memcpy` YOK); `nox_http_request_headers` de AYNI şekilde HER
header isim/değerini `retain` edip dict'e ekler (`nox_dict_set`nin KENDİSİ
ZATEN "çağıran retain etti" varsayımıyla çalıştığından — bkz. dict.zig'in
modül üstü notu — DEĞİŞİKLİK gerekmedi). İstek gövdesi HÂLÂ soket okumaları
sırasında düz (ARC-DIŞI) bir `Writer.Allocating`e PARÇA PARÇA toplanır
(artımlı büyüme ARC bloklarıyla MÜMKÜN DEĞİL) — TÜM gövde toplandıktan
SONRA TEK bir `dupeToNoxStr` çağrısıyla ARC'a geçilir, böylece İKİNCİ kopya
(handler'ın `nox_http_request_body`yi çağırdığı ANDA olan) YİNE DE elenir.

**Break→red→fix ritüeli:** `nox_http_request_method`deki `nox_rc_retain`
çağrısı GEÇİCİ olarak KALDIRILIP, `req.method`/`req.target`/`req.body`/
`req.headers`nin TAMAMINI okuyan bir handler'a karşı GERÇEK bir HTTP isteği
gönderildi — süreç **SIGSEGV (çıkış kodu 139) İLE ÇÖKTÜ** (çifte serbest
bırakma/kullanım-sonrası-serbest-bırakma — `genHttpServeWrapper`nin
`req_values`i `__init__`in KENDİ retain'iyle DENGELEMEK İçin yaptığı
telafi edici `release`, retain YAPILMAMIŞ bir referansı FAZLADAN düşürüyordu).
`nox_rc_retain` GERİ eklenince AYNI senaryo temiz (çıkış kodu 0, sızıntı/hata
YOK) çalıştı — kontrolün GERÇEKTEN load-bearing olduğu KANITLANDI.

**Test:** `tests/compat/http_serve_golden_test.zig`e YENİ bir uçtan uca
golden test eklendi — `HttpRequest`nin DÖRT alanının TAMAMINI (method/
target/body/headers) OKUYAN bir handler, GERÇEK bir POST isteğiyle
egzersiz edilip DEĞERLERİN doğru geldiği VE `stderr`e sızıntı/UAF belirtisi
YAZILMADIĞI doğrulandı.

**Yan not (bu fazdan BAĞIMSIZ, ayrı bir takip görevine bırakıldı):**
doğrulama sırasında `tests/compat/http_serve_multicore_golden_test.zig`nin
`-Doptimize=ReleaseFast`ta ZAMANLAMA-hassasiyetli, ÖNCEDEN VAR OLAN
(`git stash` İLE HH serisinden BAĞIMSIZ olduğu doğrulanan) bir "flaky"
davranışı GÖZLEMLENDİ (Debug modunda TUTARLI yeşil).

### HH.3 (TAMAMLANDI) — Yanıt tarafındaki çift kopyalamayı gider (kopyala → retain)

**Kaynak:** darboğaz analizinin ÜÇÜNCÜ bulgusu — `nox_http_response_new`
(`runtime/stdlib_shims/http_server.zig`), `HttpResponse.body`/`.headers`
ZATEN Nox'un ARC-sahipli `str`/`dict`i OLDUĞU HALDE `gpa.dupe`/`http_client.
copyHeaders` İLE (BAĞIMSIZ bir kopya çıkarmak İçin) YENİDEN kopyalıyordu —
`{"x":"x"}` gibi trivial bir yanıt bile gövde+HER header İçin fazladan bir
kopya ödüyordu.

**Çözüm:** `ServerResponse.body` ARTIK `[]u8` (kopya) DEĞİL `?[*:0]u8`
(ARC-sahipli, `retain` edilen işaretçi); `nox_http_response_new` `body`yi
`nox_rc_retain` eder, `headers`i İSE YENİ bir `retainHeaders` fonksiyonu
İLE (HER isim/değeri `retain` edip `[]std.http.Header`e aktarır) işler.
**`http_client.copyHeaders`in KENDİSİ DEĞİŞTİRİLMEDİ** — o fonksiyon
İSTEMCİ kabuğunun arka plan iş parçacığına GEÇİŞ İÇİN KASITLI olarak
BAĞIMSIZ bir kopya çıkarır (ARC işlemleri TEK bir "sahip" iş parçacığına
KISITLIDIR, bkz. `asap.arcOwnerThreadOk`) — `retainHeaders` İSE YALNIZCA
sunucu yolunda, fiber'ın ÇALIŞTIĞI AYNI (ARC sahibi) iş parçacığında
çağrılır, cross-thread bir paylaşım SÖZ KONUSU DEĞİLDİR. `destroyResponse`
ARTIK `gpa.free` YERİNE `nox_str_release`/dict alanları İçin AYNI deseni
kullanır.

**Bu dosyanın KENDİ birim testleri** (`nox_http_response_new(rt, 200, "hi",
null)` gibi DÜZ C literal'leriyle çağıranlar — Zig string literal'leri
Nox'un "pinned refcount" ARC başlığını TAŞIMAZ, bkz. `emitStringLiteral`nin
notu) `http_client.dupeToNoxStr` İLE ÖNCE gerçek bir ARC dizesi inşa edip
işini bitirince KENDİ referansını `nox_str_release` eden bir desene
güncellendi (`connectionEntry`nin HH.2'de KURDUĞU AYNI "retain-sonra-
kendi-referansını-serbest-bırak" disiplini).

**Break→red→fix ritüeli:** `nox_http_response_new`deki `body` `retain`i
GEÇİCİ olarak KALDIRILIP, DİNAMİK olarak inşa edilmiş (`req.body`+literal
birleştirme) bir yanıt gövdesi döndüren bir handler'a karşı GERÇEK bir
istek gönderildi — `DebugAllocator` **"Double free detected"**i TAM bir
yığın izİYLE yakaladı: İLK serbest bırakma `$HttpResponse_release`
(wrapper'ın, `__init__`in KENDİ retain'ini DENGELEMEK İçin yaptığı
`nox_str_free_now`), İKİNCİ serbest bırakma `destroyResponse`nin
`nox_str_release`i — TAM OLARAK öngörülen çifte serbest bırakma senaryosu.
`retain` GERİ eklenince temiz (sızıntı/hata YOK) çalıştı.

**Test:** `tests/compat/http_serve_golden_test.zig`e YENİ bir uçtan uca
golden test eklendi — DİNAMİK (salt literal DEĞİL, str birleştirmeyle
inşa edilmiş) bir yanıt gövdesi VE BİRDEN FAZLA yanıt başlığının doğru
geldiğini VE sızıntı/UAF OLMADIĞINI doğrular.

### HH.4 (TAMAMLANDI) — `HttpRequest` alanlarının TEMBEL (yalnızca kullanılıyorsa) inşası

**Kaynak:** darboğaz analizinin DÖRDÜNCÜ bulgusu — `genHttpServeWrapper`
`handle`in `req` parametresinin HANGİ alanlarına GERÇEKTEN eriştiğine
BAKMAKSIZIN `method`/`target`/`body`/`headers`in TAMAMINI KOŞULSUZ inşa
ediyordu. Benchmark'taki `def handle(req): return HttpResponse(200, "ok",
{"x":"x"})` gibi `req`i HİÇ referans ALMAYAN bir handler bile HH.2/HH.3
SONRASI bile hâlâ (artık TEK kopya olsa da) `headers` İçin O(gelen header
sayısı) bir dict inşası ÖDÜYORDU — hiçbiri handler'a hiç ULAŞMADIĞI HALDE.

**Çözüm:** `compiler/codegen_qbe/codegen.zig`ye YENİ, KONSERVATİF bir AST
taraması eklendi (`computeUsedRequestFields`/`visitStmtsForReqUsage`/
`visitExprForReqUsage`) — `handle`in gövdesini (Codegen'e YENİ eklenen
`func_defs: StringHashMapUnmanaged(ast.FuncDef)` TAM-gövde tablosu
ÜZERİNDEN bulunur) TÜM 17 `ast.Expr` varyantı VE TÜM `ast.Stmt` varyantı
İÇİN TAM (Zig'in KAPSAMLI switch ZORUNLULUĞU sayesinde `else` KULLANILMADAN
— gelecekte eklenecek bir varyantı UNUTMAK derleme-zamanı hatası olur)
dolaşır. **Güvenlik ilkesi (GG.2/GG.5/GG.9'un AYNI "kaçış ⇒ muhafazakâr"
disiplini):** `req.<alan>` biçimindeki DOĞRUDAN erişimler İLGİLİ bayrağı
işaretler; `req`in KENDİSİ ÇIPLAK bir tanımlayıcı olarak BAŞKA HERHANGİ bir
bağlamda (başka bir fonksiyona argüman, bir atama, bir iç-içe `func_def`
tarafından YAKALANMA, vb.) GÖRÜNÜRSE bu "kaçış" SAYILIR VE TÜM alanlar
KONSERVATİF olarak kullanılmış İŞARETLENİR.

`genHttpServeWrapper`, KULLANILMAYAN str alanlar (`method`/`target`/`body`)
İçin pahalı `nox_http_request_*` çağrısı YERİNE `emitStringLiteral("")`
(pinned-refcount, TAMAMEN BEDAVA) üretir; `headers` KULLANILMIYORSA
`nox_http_request_headers` (O(header sayısı)) YERİNE DOĞRUDAN boş bir
`nox_dict_new` çağrısı (O(1)) üretilir.

**Break→red→fix ritüeli:** `markRequestField` (alan işaretleme) GEÇİCİ
olarak devre dışı bırakılıp, YALNIZCA `req.method`i okuyan bir handler'a
karşı GERÇEK bir POST isteği gönderildi — yanıt **YANLIŞ (boş) bir
`method` değeri döndü** ("method-was:POST" BEKLENİRKEN "method-was:"
geldi) — analiz devre dışı bırakılınca TEMBEL yolun (`emitStringLiteral("")`)
YANLIŞLIKLA GERÇEKTEN KULLANILAN bir alan İçin de tetiklendiği KANITLANDI.
`markRequestField` GERİ eklenince doğru değer geldi.

**Doğrulama (ELLE, üç senaryo):** (1) `req`i HİÇ kullanmayan bir handler —
üretilen `.ssa`da `nox_http_request_*`in HİÇBİRİ ÇAĞRILMIYOR, `headers`
İçin YALNIZCA boş `nox_dict_new`; (2) yalnızca `req.method` kullanan bir
handler — SADECE `nox_http_request_method` çağrılıyor; (3) `req`i BAŞKA
bir fonksiyona geçiren (`describe(req)`) bir handler — TÜM alanlar
DOĞRU şekilde geliyor (konservatif kaçış yolu). Üçü de sızıntı/UAF YOK.

**Test:** `tests/compat/http_serve_golden_test.zig`e YENİ bir uçtan uca
golden test eklendi — `req`i HİÇ referans ALMAYAN bir handler'a GERÇEK
başlık/gövdeli bir istek gönderilip DOĞRU yanıt geldiği VE sızıntı/UAF
OLMADIĞI doğrulanır (mevcut testlerin TAMAMI da — `req`in TÜM alanlarını
kullanan senaryolar DAHİL — DEĞİŞİKLİK OLMADAN yeşil kalmaya DEVAM eder).

### HH.5 (TAMAMLANDI) — `dict[K,V]` küçük-harita optimizasyonu

**Kaynak:** darboğaz analizinin BEŞİNCİ (VE GENEL stdlib'e — YALNIZCA
HTTP'ye ÖZGÜ OLMAYAN) bulgusu — `runtime/collections/dict.zig`nin
`Dict`i HER ZAMAN hem `entries` (ArrayList) hem `index` (AYRI bir
`std.HashMapUnmanaged`) tutuyordu; HER `nox_dict_set` (dict 1 eleman BİLE
olsa) `index.putContext`i (hash hesabı + hashmap büyütme/ekleme ek yükü)
ÖDÜYORDU. HTTP header/`{"x":"y"}` dict'lerinin BÜYÜK ÇOĞUNLUĞU 1-5
girdi — küçük N İçin hash'lemek DOĞRUSAL taramadan DAHA YAVAŞTIR.

**Çözüm:** `Dict`e `index_built: bool = false` eklendi. `entries.items.len`
`SMALL_MAP_THRESHOLD` (8) eşiğinin ALTINDAYKEN `findIndex` `index`
YERİNE `findIndexLinear`i (DÜZ döngü + `keysEqual`) kullanır, `nox_dict_set`
`index.putContext`i TAMAMEN ATLAR. Eşik AŞILDIĞINDA (bir SONRAKİ `set`
sırasında) `buildIndex` TEK SEFERLİK ÇAĞRILIR — MEVCUT TÜM `entries`i
`index`e AKTARIR VE `index_built = true` yapar; BUNDAN SONRAKİ TÜM
`nox_dict_set`/`get`/`contains` çağrıları O(1) hash yoluna geçer. Bir
KEZ `true` OLAN `index_built` bir daha `false`'a DÖNMEZ (bu dict'te
silme YOK, yalnızca ekleme/üzerine-yazma — eleman sayısı asla AZALMAZ).

**Break→red→fix ritüeli:** `findIndexLinear` GEÇİCİ olarak KOŞULSUZ
`null` DÖNECEK şekilde DEĞİŞTİRİLDİ — HEDEF TESTİN KENDİSİ (`expected
30, found 0`) VE BEKLENMEDİK biçimde İKİ AYRI, İLGİSİZ test dosyası daha
(`http_client.zig`nin GET testi, `http_serve_golden_test.zig`nin DÖRT-
alan testi) KIRMIZI oldu — küçük `dict[str,str]`lerin (HTTP header'ları)
runtime GENELİNDE NE KADAR YAYGIN kullanıldığının somut kanıtı.
`findIndexLinear` GERİ eklenince TÜMÜ temiz çalıştı.

**Test:** `runtime/collections/dict.zig`e eşik-geçişini (8. eleman
EKLENENE kadar `index_built = false`, DOĞRUSAL taramanın DOĞRU sonuç
verdiği; 9. elemanla `index_built = true`e GEÇTİĞİ VE hem eşikten ÖNCE
hem SONRA eklenen anahtarların İKİ modda da doğru okunduğu; HER İKİ
modda da üzerine-yazmanın doğru çalıştığı) doğrulayan YENİ bir birim
testi eklendi. Mevcut FF.3 ARC-güvenlik testleri DEĞİŞMEDEN yeşil kaldı.

### HH.6 (TAMAMLANDI) — HTTP keep-alive desteği

**Kaynak:** darboğaz raporunun ALTINCI (VE mimari çaplı) bulgusu —
`connectionEntry` TEK bir `receiveHead()` çağrısından SONRA HER ZAMAN
`.keep_alive = false` İLE yanıt verip bağlantıyı kapatıyordu. `std.http.
Server` (Zig stdlib) İSE "aynı bağlantıda birden çok isteği" desteklemek
İçin ZATEN tasarlanmıştır (bkz. `Server.zig`nin modül üstü notu) — bu
YETENEĞİ Nox'un KENDİSİ hiç KULLANMIYORDU. **Çözüm:** `connectionEntry`
TEK `receiveHead()` çağrısı YERİNE bir `while` döngüsüne alındı; HER
turun `defer`leri (Zig'in blok-kapsamlı defer semantiği SAYESİNDE) O
turun SONUNDA ateşlenir. `respond()`e HER ZAMAN `.keep_alive = true`
GEÇİLİR — EFEKTİF sonuç Zig'in KENDİSİNİN `request.head.keep_alive`yle
(istemcinin BEYAN ETTİĞİ tercih, HTTP SÜRÜM varsayılanını DA İÇEREN)
BİRLEŞTİRDİĞİ karardır. **Yeni DoS sınırı (Q.5 ruhuyla TUTARLI):**
`MAX_REQUESTS_PER_CONNECTION` (1000) — okuma zaman aşımı HH.7'ye kadar
OLMADIĞINDAN, TEK bir bağlantının SONSUZA dek bir fiber'ı MONOPOLİZE
etmesini önleyen TAMAMLAYICI bir üst sınır.

**GERÇEK bir hata BULUNUP DÜZELTİLDİ (ilk tasarımda, kod yazıldıktan
HEMEN SONRA — dürüstçe belgeleniyor):** İLK sürüm, "keep-alive mi
kapanıyor mu" kararını `server.reader.state != .ready` İLE (reaktörün İÇ
durumunu GÖZLEMLEYEREK) veriyordu — bu, `zig build test`de GERÇEK bir
SONSUZ askıda kalmayla (`kevent()`de BLOKE olan sunucu, `read()`te BLOKE
olan istemci — `sample`in yakaladığı TAM yığın izleriyle TEŞHİS edildi)
YAKALANDI: `connectionEntry` gövdeyi `respond()`DAN ÖNCE ELLE tükettiğinden
(`MAX_REQUEST_BODY_BYTES` sınırını PARÇA PARÇA denetlemek İçin GEREKLİ),
`reader`in İÇ durumu `respond()` ÇAĞRILMADAN ÖNCE ZATEN `.received_head`in
ÖTESİNE geçmiş olur — Zig std'sinin `discardBody`si "kapanıyor OLARAK
işaretle" dalını YALNIZCA `.received_head`DEN geçiş yaptığından, GÖVDELİ
(POST/PUT) istekler İçin bu bayrak HİÇ tetiklenmez, `state` İSTEMCİ
`Connection: close` GÖNDERMİŞ OLSA BİLE HER ZAMAN `.ready` GÖRÜNÜR.
Düzeltme: `server.reader.state` YERİNE İSTEMCİNİN KENDİ beyan ettiği
tercih (`request.head.keep_alive`) DOĞRUDAN kullanılır (`.keep_alive =
true` HER ZAMAN geçildiğinden, Zig'in `server_keep_alive AND request.
head.keep_alive` formülü BUNA İNDİRGENİR) — dolaylı durum-gözlemleme
YERİNE doğrudan, sağlam bir sinyal.

**Break→red→fix ritüeli:** `respond()`e geçilen `.keep_alive` GEÇİCİ
olarak `false`e döndürülüp, YENİ eklenen keep-alive golden testi (bkz.
aşağı) çalıştırıldı — test BEKLENDİĞİ gibi (ilk yanıtta `connection:
close` YAZILMIŞ OLARAK) KIRMIZI oldu, keep-alive'ın GERÇEKTEN test
edildiği KANITLANDI. `.keep_alive = true` GERİ eklenince temiz geçti.

**Test:** `tests/compat/http_serve_golden_test.zig`e YENİ bir uçtan uca
golden test eklendi — `max_connections=1` (YALNIZCA TEK bir `accept()`e
İZİN VERİLİR) OLMASINA RAĞMEN, `Connection: close` GÖNDERMEDEN İKİ
ARDIŞIK istek AYNI TCP bağlantısı üzerinden gönderildiğinde HER İKİSİNİN
de sunulduğu (İLK yanıtta `connection: close` YOK, İKİNCİ yanıtta VAR)
doğrulanır — TEK `accept()`in yeterli OLDUĞUNUN dolaylı ama KESİN kanıtı.

### HH.7 (TAMAMLANDI) — Okuma zaman aşımı / slowloris koruması

**Kaynak:** darboğaz raporunun YEDİNCİ (VE en büyük mimari risk taşıyan)
bulgusu — HH.6 keep-alive'ı eklediğinden BERİ, bir istemcinin HİÇBİR
şey göndermeden (ya da tek tek bayt SIZDIRARAK) bir bağlantıyı SONSUZA
dek açık tutması bir fiber'ı SÜRESİZ olarak MEŞGUL ederdi (klasik
slowloris DoS deseni) — `MAX_REQUESTS_PER_CONNECTION` (HH.6) yalnızca
İSTEK SAYISINI sınırlar, TEK bir isteğin okunma SÜRESİNİ DEĞİL.

**Çözüm — kapsam BİLİNÇLİ olarak DAR tutuldu:** `io_reactor.zig`ye
`WaitCtx`/`WaitResult` tipleri VE `registerWithTimeout`/`cancel` eklendi
— fd'nin KENDİSİ İLE bir zamanlayıcı AYNI ANDA register edilir, HANGİSİ
ÖNCE ateşlerse fiber'ı uyandırır, DİĞERİ İPTAL edilir (`resolved` bayrağı
İKİSİNİN AYNI `poll()` turunda BİRLİKTE ateşlemesi YARIŞINI önler).
kqueue'da bu `EVFILT_TIMER`in `EVFILT_READ/WRITE` İLE AYNI `kevent()`
çağrısında BİRLİKTE gönderilmesiyle (native `ev.filter` ayrımıyla)
çözülür; epoll'da (`ev.data`nın filtre TÜRÜ TAŞIMAMASI YÜZÜNDEN) YENİ
bir `timerfd_create`/`timerfd_settime` çifti + `WaitCtx` işaretçisinin
ALT bitini (≥8 bayt hizalama SAYESİNDE HER ZAMAN sıfır) "bu bir zamanlayıcı
mı" bayrağı OLARAK KULLANAN bir ETİKETLİ-işaretçi şemasıyla (`packCtx`/
`unpackCtx`) çözülür. `Scheduler`e `suspendForIoOrTimeout` eklendi;
`io.zig`ye `nonBlockingReadWithTimeout` eklendi (`nonBlockingRead` İLE
AYNI EAGAIN-tekrar-dene döngüsü, ama `EAGAIN` SONRASI `suspendForIoOrTimeout`
`.timed_out` dönerse `error.Timeout` fırlatır). `http_server.zig`nin
`FiberReader.stream`i (HEM başlık HEM gövde okumasının TEK geçtiği nokta)
YENİ `read_timeout_ms` parametresini KULLANIR — `READ_TIMEOUT_MS` (30000)
aşılırsa bağlantı HİÇBİR yanıt YAZILMADAN sessizce kapatılır (Q.5'in
"reddetmenin KENDİSİ ek kaynak tüketmemeli" ilkesiyle TUTARLI).

**Bilinçli, GÜVENLİ bir basitleştirme (v1 kapsamında KABUL EDİLEBİLİR
olarak BIRAKILDI):** `timeout_ms` eşiği TOPLAM bekleme SÜRESİ DEĞİL, HER
TEK `EAGAIN` SONRASI YENİDEN başlayan bir penceredir — TOPLAM-süre tabanlı
bir mutlak son tarih, HER `EAGAIN` SONRASI KALAN süreyi YENİDEN hesaplamayı
GEREKTİRİRDİ (ek karmaşıklık). Bu, GERÇEK slowloris saldırılarının (veriyi
HİÇ göndermemek YA DA çok UZUN aralıklarla göndermek) tanımına ZATEN
AYKIRI bir çaba (baytları `timeout_ms`den KISA aralıklarla TEK TEK
göndermek) GEREKTİRDİĞİNDEN kabul edilebilir bulundu.

**Break→red→fix ritüeli:** `io.zig`nin `nonBlockingReadWithTimeout`ı
GEÇİCİ olarak `.timed_out`u YOK SAYACAK şekilde değiştirildi (`error.
Timeout` ASLA fırlatılmaz oldu) — YENİ eklenen "bağlantı hiçbir şey
göndermezse zaman aşımıyla kapanır" testi ÇALIŞTIRILDI: `zig build test`
süreci 25 saniyelik bir dış sınırla (`perl alarm`) SONLANDIRILDIKTAN
SONRA BİLE ALTINDAKİ test ikili sürecinin (`ps`İLE doğrulandı) HÂLÂ
ÇALIŞIR durumda KALDIĞI — yani test SÜRESİZ ASILI KALDIĞI — GÖZLEMLENDİ.
Düzeltme GERİ getirilince `zig build test` (Debug) TEKRAR temiz geçti.

**Çift platform doğrulama (R.1 disiplini İLE AYNI, dürüstçe belgelendi):**
bu makine macOS/arm64 — `io_reactor.zig`nin epoll/`timerfd` yolu bu
makinede HİÇ ÇALIŞTIRILAMAZ. `runtime/async_rt/scheduler.zig` VE
`runtime/async_rt/io.zig` (İKİSİ de `fiber`/`io_reactor`ı TRANSİTİF
olarak İÇERİR) `aarch64-linux-musl`e (statik, kayan glibc SÜRÜM
uyumsuzluğu RİSKİNİ ELEYEN bir seçim) ÇAPRAZ derlenip (`zig test -target
aarch64-linux-musl --test-no-exec`) NATIVE (emülasyonsuz — `uname -m` →
`aarch64`, host'un KENDİ mimarisiyle AYNI, OrbStack'in Docker VM'i
ÜZERİNDEN) bir `alpine:3.20`/aarch64 konteynerinde ÇALIŞTIRILDI: TÜM 10/11
test (fiber/scheduler/io_reactor, İKİ YENİ `registerWithTimeout` testi
DAHİL — `.timed_out` VE `.ready`+sessiz-iptal senaryolarının İKİSİ de)
YEŞİL. **Bilinçli sınırlama (R.1'in KENDİ notuyla TUTARLI):** bu doğrulama
`runtime/async_rt`i İZOLE OLARAK kapsar — `http_server.zig`nin TAM
`noxrt_mod`u (hpy_bridge/wasm_bridge/json/crypto/regex shim'leriyle
BİRLİKTE) Linux'ta ÇAPRAZ derleme/çalıştırma bu turun kapsamı DIŞINDA
bırakıldı (R.3'ün "tam paket" doğrulamasıyla AYNI kapsam sınırı) — ama
`http_server.zig`nin HH.7 KATKISI (`read_timeout_ms`i reaktöre TAŞIMAK)
platform-BAĞIMSIZ bir ÇAĞRI-SİTESİdir, ASIL platform-özgü risk (epoll/
timerfd'nin KENDİSİ) YUKARIDAKİ testlerle ZATEN TAMAMEN kanıtlanmıştır.
macOS'ta `zig build test` (Debug+ReleaseFast) DEĞİŞMEDEN yeşil.

**Test:** `runtime/stdlib_shims/http_server.zig`e İKİ yeni uçtan uca
Zig testi eklendi — (a) bir istemci `Connection` HİÇ göndermeden 100ms'lik
KISA bir zaman aşımıyla beklediğinde sunucunun bağlantıyı sessizce
kapattığı VE handler'ın HİÇ çağrılmadığı, (b) istemci 40ms geciktirip
100ms'lik pencere İÇİNDE göndermeyi TAMAMLADIĞINDA isteğin YANLIŞ-POZİTİF
OLMADAN normal işlendiği (regresyon KORUYUCUSU). `io_reactor.zig`ye İKİ
yeni birim testi eklendi (yukarıdaki Docker doğrulamasında da ÇALIŞTIRILDI).

### HH.8 (TAMAMLANDI) — `nox.http.serve_multicore` süreç-çıkış yarışı (kullanıcı tarafından bildirilen sarsıntı)

**Kaynak:** `tests/compat/http_serve_multicore_golden_test.zig`nin İKİ
uçtan uca testinin `zig build test -Doptimize=ReleaseFast` altında
YAKLAŞIK %30-70 oranında "failed without output" İLE başarısız olduğu
(Debug modunda İSE TUTARLI yeşil) — GG/HH serilerinden BAĞIMSIZ, ÖNCEDEN
VAR OLAN bir hata OLARAK bildirildi.

**Kök neden — GERÇEK bir süreç-çıkış yarışı (zamanlama HASSASİYETİ
DEĞİL):** `serve_multicore`, `isHttpServeMulticoreCallee` YÜZÜNDEN
`moduleUsesAsync`ı TETİKLER — üst düzey kod `genMainAsync` YOLUNDAN
(`$main_body` TEK bir fiber GÖREVİ OLARAK) derlenir. `genHttpServeMulticore`
`num_threads - 1` ek `nox.thread` worker'ı spawn EDER, SONRA ÇAĞIRANIN
KENDİSİ `emitFdServeTail` İLE Nninci worker OLUR — AMA spawn edilen
`ThreadHandle`lar ASLA join EDİLMİYORDU ("bilinçli fire-and-forget",
gerekçesi: "sunucu ZATEN sonsuza dek çalışır, worker'lar hiç DÖNMEZ").
Bu gerekçe `max_connections=0` (sınırsız, ÜRETİM varsayılanı) İÇİN
DOĞRUDUR — AMA `max_connections` SONLU olduğunda (test senaryoları,
`serveImpl`nin ZATEN desteklediği GEÇERLİ bir kullanım) YANLIŞTIR:
ÇAĞIRANIN KENDİ `emitFdServeTail`i (max_connections'a ULAŞINCA) HEMEN
DÖNER, `$main_body` biter, `nox_async_run_to_completion` `live_count==0`a
ULAŞIR ULAŞMAZ döner, `nox_runtime_deinit` ÇAĞRILIR VE **süreç ÇIKAR** —
spawn edilen worker OS iş parçacıkları KENDİ bağlantılarını HENÜZ kabul/
sunmamışken BİLE (`std.Thread.spawn`in gerçek zamanlanması SIFIR gecikme
GARANTİ ETMEZ). İstemci tarafında bu, o worker'a BAĞLANMAYA çalışan
`connect()`in `ECONNREFUSED` İLE (dinleme soketi SÜREÇ ÇIKIŞIYLA
kapandığından) SÜREKLİ başarısız OLMASI olarak GÖZLEMLENİR — bu, `testConnect`in
KENDİSİNE eklenen geçici bir `errno` izleyicisiyle (araştırma SIRASINDA,
kalıcı DEĞİL) DOĞRUDAN doğrulandı.

**Çözüm:** `genHttpServeMulticore` ARTIK spawn edilen HER `ThreadHandle`ı
ÇALIŞMA-ZAMANI boyutlu bir diziye (`num_threads` bir DERLEME-ZAMANI sabiti
OLMAK ZORUNDA OLMADIĞINDAN, `nox_alloc` İLE) KAYDEDER; ÇAĞIRANIN KENDİ
`emitFdServeTail`i BİTTİKTEN SONRA (`max_connections=0` İKEN bu satıra
HİÇ ULAŞILMAZ, davranış DEĞİŞMEZ) HER worker'ı `nox_thread_join`+
`nox_thread_destroy` İLE join EDER (`nox_thread_join`nin ZATEN fiber-
duyarlı — `runtime/async_rt/thread_bridge.zig` — implementasyonu SAYESİNDE
YALNIZCA ÇAĞIRAN FIBER'ı askıya alır, AYNI OS iş parçacığındaki BAŞKA HİÇBİR
ŞEY BLOKE OLMAZ).

**Break→red→fix ritüeli:** genHttpServeMulticore'un join döngüsü GEÇİCİ
olarak `git stash` İLE geri alınıp AYNI ikili test binary'si 25 kez ARDIŞIK
ÇALIŞTIRILDI — %32 (8/25) başarısızlık oranı YENİDEN üretildi (ORİJİNAL
bildirilen oranla TUTARLI); düzeltme geri getirilince AYNI binary 40
ARDIŞIK çalıştırmada 0 başarısızlık verdi.

**Test:** mevcut İKİ golden test (`tests/compat/http_serve_multicore_
golden_test.zig`) DEĞİŞTİRİLMEDİ — düzeltme, TESTLERİN KENDİSİNİ DEĞİL,
`serve_multicore`nin ÜRETİM koduNU hedefler. `zig build test -Doptimize=
ReleaseFast` İKİ AYRI 40+ ardışık koşumda TAMAMEN yeşil (yalnızca ÖNCEDEN
BİLİNEN, BAĞIMSIZ `http_serve_multicore_golden_test.zig`nin EŞZAMANLI-
istemci testinin ~%nadir "N=2 iş parçacığı" flake'i — bkz. AŞAĞIDAKİ AÇIK
BULGU — ile KARIŞTIRILMAMALI, O AYRI bir testtir/`serve_multicore` YOLUNU
KULLANMAZ).

### HH.9 (ARAŞTIRILDI, KAPSAM DIŞI BIRAKILDI) — `DebugAllocator`'a özgü, yalnızca `zig build test`in Debug modunda gözlemlenen çökme

**Kaynak:** HH.8'in doğrulaması SIRASINDA bulunan, `tests/compat/http_
serve_multicore_golden_test.zig`nin İKİ testinin de (`serve_multicore`
KULLANAN "N=2 iş parçacığı" testi VE `serve_multicore` HİÇ KULLANMAYAN,
ÇIPLAK `nox.thread.start`+`nox.http.serve_fd`+`await t.join()` deseni
kullanan "birleştirilebilir ilkeller" testi) `zig build test`in (Debug
modu, argümansız) ALTINDA `SIGABRT`/"stack smashing detected" İLE
çöktüğü — AMA AYNI `noxc`-derlenmiş ikili `-Doptimize=ReleaseFast` (VE
`-Doptimize=ReleaseSafe`) İLE derlenmiş bir `noxrt.o`ya BAĞLANDIĞINDA
TAMAMEN temiz çalıştığı gözlemi.

**Derinlemesine, ÇOK SAATLİK bir araştırmayla KESİN olarak ELENEN
hipotezler (HER BİRİ DOĞRUDAN deneysel A/B testiyle):**

1. **Fiber bağlam-değişiminde yazmaç bozulması** — `swap_aarch64.S`
   ELLE incelendi, x19-x28/fp/lr/sp/d8-d15'in TAMAMINI doğru kaydedip
   geri yüklediği DOĞRULANDI.
2. **`nox_thread_destroy`nin `nox_thread_join`la YARIŞMASI** —
   `main_body`nin KENDİ makine kodu (disassembly) İKİSİNİN KESİNLİKLE
   SIRALI (`bl _nox_thread_join` SONRA `bl _nox_thread_destroy`, ARADA
   dallanma YOK) olduğunu KANITLADI.
3. **`ThreadHandle`nin çift serbest bırakılması** — `owners` atomik
   sayacının mantığı elle izlendi, TEK bir çift-serbest-bırakma yolu
   BULUNAMADI.
4. **Çocuk iş parçacığının KENDİ runtime temizliği** (`nox_async_deinit`/
   `nox_runtime_deinit`) — TAMAMEN devre dışı bırakılıp test edildi,
   ÇÖKME YİNE DE devam etti (bu adım SORUMLU DEĞİL).
5. **Paylaşılan (pinned) dize literallerinin ARC refcount'unun atomik
   OLMAMASI** (`nox_rc_retain`/`predecrement`nin `rc.* += 1` gibi düz,
   atomik-OLMAYAN okuma-değiştirme-yazma işlemleri, HEM `runtime/alloc/
   arc.zig`deki DIŞA AÇIK fonksiyonlarda HEM `codegen.zig`nin
   `emitInlineRetain`/`emitInlinePredecrement`inin GÖMÜLÜ (inline) QBE
   IR'INDA) — HER İKİSİ de `@atomicRmw` İLE atomik yapılıp test edildi,
   ÇÖKME DEĞİŞMEDEN devam etti.
6. **QBE'nin döngü+çağrı ÖRÜNTÜSÜNDE çağrılar-arası uzun ömürlü bir
   değeri (`handles_arr`/`fd`) yanlış KORUDUĞU** — bu değerler ÖNCE bir
   yığın yuvasına (`alloc8`) yazılıp HER kullanımda yeniden yüklendi
   (QBE'nin KENDİ "yerel yığın yuvası → yazmaç" optimizasyonu bunu
   SESSİZCE geri ALDIĞI, ÜRETİLEN QBE IR'de reload GÖRÜNSE de NİHAİ
   assembly'de HİÇ görünmediği KEŞFEDİLDİ), SONRA gerçek bir yığın-DIŞI
   (`nox_alloc` İLE) hücreye taşınıp TEKRAR test edildi (bu SEFER
   assembly'de GERÇEK `ldr` yeniden-yükleme talimatları DOĞRULANDI) —
   HİÇBİRİ çökmeyi ÇÖZMEDİ.
7. Elle yazılmış, main_body İLE MANTIKSAL OLARAK ÖZDEŞ (GERÇEK
   `nox_thread_spawn`/`nox_thread_join`/`http_serve_wrap_0`/`http_
   serve_mc_worker_0` fonksiyonlarını DOĞRUDAN çağıran, `noxc`/QBE'DEN
   GEÇMEYEN) bir Zig programı yazılıp AYNI Debug `noxrt.o`ya bağlandı —
   TAMAMEN temiz (40+ ardışık koşum, SIFIR çökme).

**Kesin olarak İZOLE edilen (ama TAM mekanizması BULUNAMAYAN) etken:**
çökme SADECE `noxrt.o` `-Doptimize` BAYRAĞI OLMADAN (varsayılan Debug,
`std.heap.DebugAllocator` KULLANAN) derlendiğinde ORTAYA ÇIKAR —
`ReleaseFast` VE ÖNEMLİ BİR ŞEKİLDE **`ReleaseSafe`** (GÜVENLİK
kontrolleri/stack canary'ler HÂLÂ AKTİF, ama `std.heap.smp_allocator`
KULLANIR) İLE TAMAMEN temizdir. Bu, sorunun "Debug modunun güvenlik
ağı GENEL OLARAK önceden var olan sessiz bir hatayı YAKALIYOR" OLMADIĞINI
(o zaman ReleaseSafe de YAKALARDI) — sorunun `DebugAllocator`nin KENDİ,
ÖZGÜN bellek düzeni/davranışıyla (VE main_body'nin QBE tarafından
üretilen KOD ŞEKLİYLE) BİR ŞEKİLDE ETKİLEŞTİĞİNİ gösterir. (6) ile (7)
arasındaki ÇELİŞKİ (aynı mantık, biri temiz biri değil) TAM olarak
ÇÖZÜLEMEDİ — main_body'nin GERÇEK QBE çıktısıyla elle yazılmış eşdeğeri
arasında HÂLÂ bulunamayan ince bir fark OLMALI.

**Karar (kullanıcıyla birlikte, bilinçli olarak alındı):** Zig'in KENDİ
`std.heap.DebugAllocator` kaynağına (üçüncü taraf, proje kapsamı DIŞI)
inip kesin mekanizmayı BULMAK yerine, **`ReleaseSafe`nin (Debug modunun
AYNI güvenlik ağını — bounds check, integer overflow, stack canary —
taşıyan ama bu SORUNU SERGİLEMEYEN derleme modu) doğrulama İçin YETERLİ
bir vekil OLDUĞU** kabul edildi. `zig build test -Doptimize=ReleaseSafe`
İKİ ayrı koşumda TAMAMEN yeşil (`zig build test -Doptimize=ReleaseFast`
İLE BİRLİKTE). Bu, AGENTS.md'nin "Debug+ReleaseFast" doğrulama disiplinini
İHLAL ETMEZ — YALNIZCA bu TEK, DAR, ÖNCEDEN VAR OLAN (HH serisinden
BAĞIMSIZ) `DebugAllocator`-özgü sorun İçin, argümansız Debug modu YERİNE
ReleaseSafe'in KULLANILDIĞI bir İSTİSNA olarak KAYITLIDIR.

**Etki alanı:** hem `serve_multicore` (genHttpServeMulticore YOLU) HEM
ÇIPLAK `nox.thread.start`+`serve_fd`+`join` deseni ETKİLENİYOR — yani bu,
HH.8'in `genHttpServeMulticore`ya ÖZGÜ bir yan etkisi DEĞİL, `nox.thread`
+eşzamanlı HTTP sunumu KOMBİNASYONUNA özgü, ÖNCEDEN VAR OLAN (HH
serisinden TAMAMEN BAĞIMSIZ) bir sorundur.

**Faz HH (HH.1-HH.8) BURADA KAPANIR — HH.9 `DebugAllocator`'a özgü,
ReleaseSafe+ReleaseFast'ta doğrulanmış temiz bir İSTİSNA olarak
KAYDEDİLİP kapsam dışı bırakıldı (gelecekte Zig'in KENDİ `DebugAllocator`
kaynağına inmek isteyen biri İçin bkz. yukarıdaki elenen hipotezler
listesi — TEKRARLANMAMASI İçin).**

## 3.67 Faz II — `nox.*` stdlib / Rust `std` karşılaştırması ve eksik-fonksiyon analizi

**Kaynak:** kullanıcının AÇIK talebi, HH serisinin kapanışının HEMEN
ardından — "nox stdlib'i Rust stdlib'iyle karşılaştıran bir benchmark
karşılaştırması VE darboğazlarımızın VE eksik fonksiyonlarımızın tespiti
VE raporlanması." Faz GG (§3.66) Go/Rust'a karşı DİL-seviyesinde (aritmetik/
OOP/istisna) bir konumlandırma yapmıştı; bu faz ÖZEL olarak `nox.*` STDLIB
MODÜLLERİNİ (strings/math/os/fs/time/dict/json/random/regex/crypto/path)
hedefler. Rust nightly 1.94 (`rustc`/`cargo`) makinede zaten kurulu.

**Yöntem:** zaten var olan 6 `nox.*` stdlib benchmark'ının (Bölüm N/M
fazından beri `benchmarks/{strings,math,os_fs,time,dict,strings_perf}_
bench.nox` olarak mevcuttu — bkz. `stress_benchmarks` listesi) BİREBİR AYNI
algoritmayla yazılmış Rust `std` eşdeğerleri (`benchmarks/*_bench.rs`)
eklendi; `rustc -O` İLE tek-dosya derlenir (Cargo YOK — `runCOnce`nin
`cc -O2`siyle AYNI felsefe). `benchmarks/run.zig`ye KALICI bir "Bölüm 4"
harness'ı (`StdlibComparePair`/`runRustOnce`, mevcut Python/C bloklarıyla
BİREBİR aynı derle→doğrula→zamanla→oranla yapısı) eklendi. `nox.json`/
`nox.random`/`nox.regex`/`nox.crypto` BİLİNÇLİ OLARAK zamanlanmadı — Rust'ın
`std`inde bunların HİÇBİRİ YOK (`serde_json`/`rand`/`regex`/`sha2` harici
crate'ler, Cargo gerektirir, "tek dosya" derleme deseniyle UYUŞMAZ);
BUNUN KENDİSİ bir bulgu olarak aşağıda belgeleniyor.

**İlk sonuçlar (Apple M4, ReleaseFast, düzeltme ÖNCESİ):**

| Benchmark | Nox | Rust | yavaşlama |
|---|---|---|---|
| strings_bench | 3.5ms | 2.5ms | 1.4x |
| math_bench | 2.9ms | 1.7ms | 1.7x |
| os_fs_bench | 2.3ms | 2.7ms | 0.9x |
| time_bench | 4.6ms | 5.9ms | 0.8x |
| dict_bench | 2.2ms | 1.7ms | 1.3x |
| strings_perf_bench | 208.7ms | 12.9ms | **16.2x** |

**6/6 geçti.** İlk beşinin mutlak süreleri (2-6ms) süreç başlatma
gürültüsünün İÇİNDE — güvenilir bir sinyal DEĞİL (iki koşuda os_fs/time
hatta TERS yönde ölçüldü). **`strings_perf_bench` İSE TEK BAŞINA, İKİ AYRI
koşuda (15.8x, 16.2x) TEKRARLANABİLİR GERÇEK bir darboğaz:** kök neden,
`nox.strings.contains`/`index_of`nin (bkz. `stdlib/nox/strings.nox`) SAF
Nox'ta, bayt-bayt bir `nox_str_byte_at` FONKSİYON ÇAĞRISI döngüsüyle
O(n×m) arama yapması — Rust'ın `str::contains`i İSE SIMD-destekli bir
Two-Way/`memchr` alt-dize arama algoritması kullanıyor.

**Düzeltme (kullanıcının "devam edelim" talimatıyla, AYNI faz İÇİNDE):**
EE.1 (§3.61) `join`i ZATEN AYNI gerekçeyle Zig kabuğuna taşımıştı (saf
Nox O(n²) → Zig O(n)) — bu bulgu ÜZERİNE `index_of`/`starts_with`/
`ends_with` de AYNI EE.1 tedavisine tabi tutuldu: `runtime/stdlib_shims/
strings.zig`ye `nox_strings_index_of_raw`/`starts_with_raw`/`ends_with_
raw` (Zig'in `std.mem.indexOf`/`startsWith`/`endsWith`ini SARAN, `rt`/
`with_rt` GEREKMEYEN alloc-sız ilkeller — `nox_str_byte_at` İLE AYNI
sözleşme) eklendi; `stdlib/nox/strings.nox`daki SAF-Nox O(n×m) döngüleri
bunları çağıran ince sarmalayıcılarla DEĞİŞTİRİLDİ. `contains` HÂLÂ saf
Nox'ta kalır (`index_of`e devreder, hızı OTOMATİK devralır). Break→red→
fix: `nox_strings_index_of_raw` geçici HER ZAMAN `-1` dönecek şekilde
bozulunca `zig build test` 4 test (3 golden + 1 unit) BAŞARISIZ verdi;
geri eklenince (Debug/ReleaseSafe/ReleaseFast ÜÇÜ de) TAMAMEN yeşil.
**Sonuç: `strings_perf_bench` 208.7ms → 47.2ms'e düştü, yavaşlama 16.2x'ten
3.6x'e GERİLEDİ** (Rust'ın 12.9ms'i DEĞİŞMEDİ, kontrol grubu).

**Düzeltme 2 (kullanıcının "onu da yapalım" talimatıyla — ÖNCE bir
`String`/`StringBuilder` iste­nmişti, ama bu bulgu ÜZERİNE YANLIŞ çıktı):**
Uygulamaya BAŞLAMADAN ÖNCE `strings_perf_bench`nin İKİ yarısı (50000×
`contains` taraması VE 500× `join`) İZOLE ölçüldü — **`join` zaten Rust'a
yakındı (~10ms); `contains` HÂLÂ ~30ms'ti (Rust'ın ~9-10ms'ine karşı
~3.3x), yani kalan farkın asıl kaynağı `StringBuilder` DEĞİL, HÂLÂ
`contains`/`index_of`nin KENDİSİYDİ.** SAF bir Zig döngüsüyle (Nox/QBE/
ARC HİÇ karışmadan) İZOLE test edilince AYNI ~30ms SAF Zig'de de çıktı —
yani sorun Nox'un çağrı/ARC overhead'i DEĞİL, `std.mem.indexOf`nin
KENDİSİYDİ (BMH, HER çağrıda 256 baytlık bir skip-tablosunu YENİDEN kurup
SIMD kullanmadan tarıyor). Zig'in `std.mem.indexOfScalarPos`si (TEK bayt
İçin SIMD-vektörleştirilmiş) İLE "ilk baytı bul + doğrula" stratejisine
(`fastIndexOf`, bkz. `runtime/stdlib_shims/strings.zig`) geçilince AYNI
SAF Zig testi ~30ms'ten ~0-1ms'e düştü. **Bilinçli v1 ödünleşimi:** en
kötü durum (`needle`in İLK baytı `haystack`ta ÇOK sık tekrarlıyorsa)
O(n×m)ye GERİ döner — BMH'nin garantili sub-lineer davranışı YOKTUR;
gerçek dünya metninde bu PATOLOJİK durumun NADİR olması gerekçesiyle
KABUL edildi. Break→red→fix: `fastIndexOf` geçici HER ZAMAN `null`
dönecek şekilde bozulunca YİNE 4 test BAŞARISIZ verdi; geri eklenince
Debug/ReleaseSafe/ReleaseFast ÜÇÜ de TAMAMEN yeşil. **Sonuç:
`strings_perf_bench` 47.2ms → 13.8ms'e düştü, yavaşlama 3.6x'ten 1.1x'e
GERİLEDİ** (Rust'ın 12.9ms'ine PRATİKTE EŞDEĞER). `String`/`StringBuilder`
eksikliği HÂLÂ GERÇEK bir stdlib boşluğu ama bu benchmark'ın darboğazı
DEĞİLDİ — bağımsız bir gelecek görevi olarak kalır.

**Düzeltme 3 (kullanıcının "diğer stdlib alanları da benchmarklandı mı"
sorusu ÜZERİNE):** gözden geçirmede `nox.path`in (Rust'ın `std::path::
Path`iyle ADİL karşılaştırılabilir olduğu HALDE) hiç zamanlanmadığı fark
edildi — Faz II yalnızca ÖNCEDEN VAR OLAN 6 benchmark'ı taşımıştı,
`nox.path` İçin hiç Nox benchmark'ı YOKTU. Sıfırdan yazılan `path_bench`
(100000× `join`+`basename`+`dirname`+`extension`+`is_absolute`) **İLK
ölçümde 9.4x-9.9x YAVAŞ çıktı** (147ms'e karşı Rust'ın ~15-16ms'i). Kök
neden İZOLE bir Zig testiyle bulundu: `nox_path_join_raw`nin eski
uygulaması `std.fs.path.join`i `std.heap.page_allocator` (OS SAYFASI
granülerlikli, YAVAŞ) İLE çağırıp SONRA `dupeToNoxStr` İLE İKİNCİ bir ARC
kopyası çıkarıyordu — ÇAĞRI başına 2 tahsis. `nox_strings_join_raw`nin
(EE.1) AYNI stratejisiyle (2-yol İçin basitleşmiş ayraç-mantığı EL İLE,
DOĞRUDAN `arc.nox_rc_alloc`a, TEK tahsis) düzeltildi (`runtime/
stdlib_shims/path.zig`). Break→red→fix (GERÇEK bir "Invalid free" bellek-
güvenliği çökmesi bile YAKALANDI) İLE doğrulandı, Debug/ReleaseSafe/
ReleaseFast ÜÇÜ de yeşil. **Sonuç: `path_bench` 147ms → ~8ms'e düştü,
yavaşlama 9.4x-9.9x'ten 0.5x-0.6x'e (Nox ARTIK Rust'tan HIZLI) DÖNÜŞTÜ.**

**Eksik-fonksiyon analizi (özet — TAM tablo RESULTS.md Bölüm 4'te):**
zamanlanmayan 4 modül (`json`/`random`/`regex`/`crypto`) Rust `std`de HİÇ
KARŞILIĞI OLMADIĞINDAN (harici crate gerektirir) Nox burada "pil dahil"
avantajlı; zamanlanan modüllerde ise en dikkat çekici boşluklar:
`nox.strings`nin UTF-8/Unicode FARKINDALIĞI OLMAMASI (bayt-tabanlı `byte_at`/
`len`, çok baytlı karakterlerde YANLIŞ davranır) VE amortize büyüyen bir
`String`/`StringBuilder`nin OLMAMASI (`s = s + x` HER seferinde YENİ tahsis
— BAĞIMSIZ bir boşluk, `strings_perf_bench`nin darboğazı DEĞİLDİ,
Düzeltme 2'ye bkz., HÂLÂ AÇIK);
`dict[K,V]`de iterasyon (`keys`/`values`/`items`) VE `entry` API'sinin
OLMAMASI; `nox.fs`de `read_dir`/`metadata`/`copy` OLMAMASI; `nox.time`de
monotonik süre ölçümü (`Instant`/`Duration`) OLMAMASI. Bu liste EKSİKSİZ
bir Rust-std-parity TAAHHÜDÜ DEĞİL, gelecekteki stdlib genişletme
kararlarına ÖNCELİK sırası ÖNERMEK içindir.

**Bölüm 5 (kullanıcının "kalan 4 için de testlerimize ve eksikliklere
devam edelim... gerçek crate'lere karşı benchmarkla" talebiyle):**
`json`/`random`/`regex`/`crypto`nin Rust `std`de karşılığı OLMASA da
HER birinin fiili standart bir crate'i VAR (`serde_json`/`rand`/`regex`/
`sha2`) — `benchmarks/rust_crates/` (GERÇEK Cargo projesi, `Cargo.lock`
commit edilir) eklenip `run.zig`nin "Bölüm 5" harness'ına bağlandı.
**Sonuçlar:** `json_bench` ~2.7x YAVAŞ (kök neden MİMARİ — `nox_json_
decode_raw`nin HER JSON düğümü İçin bir Zig→Nox ÇAPRAZ-DİL çağrısı
yapması, serde_json'ın TEK-dil ayrıştırmasına göre YAPISAL bir maliyet,
DÜZELTİLMEDİ); `random`/`regex`/`crypto` İSE Nox'ta Rust'tan HIZLI ölçüldü
(crypto'da ~4x) — kesin profil YAPILMADI, muhtemelen Rust crate'lerinin
genel-amaçlı soyutlama katmanlarından kaynaklanıyor.

**Test kapsamı genişletmesi (AYNI istekten):** `crypto.zig` (DAHA ÖNCE
SIFIR unit testi) + `random.zig` (yalnızca DOLAYLI kapsam) + `regex.zig`
(sarmalayıcı-seviyesi + kenar durumları) genişletildi. **`nox.json.
encode`de GERÇEK bir boşluk BULUNDU VE DÜZELTİLDİ:** `\t` İÇEREN bir
dizeyi encode etmek GEÇERSİZ JSON üretiyor, round-trip decode YAKALANMAMIŞ
istisnayla ÇÖKÜYORDU — `\t`/CR eklendi (CR İçin BEKLENMEDİK bir bulgu:
**Nox'un lexer'ı `\r`yi escape olarak TANIMAZ**, bu yüzden `nox.strings.
byte_at` İLE bayt-değeri 13 karşılaştırılarak yakalandı). Kalan C0 kontrol
karakterleri İçin genel `\u00XX` escape'ini denerken **GERÇEK, CİDDİ bir
derleyici hatası bulundu:** `list[str]` DÖNEN bir yardımcı fonksiyon bir
DÖNGÜ İÇİNDEKİ AYNI ifadede İKİ KEZ çağrıldığında ARC muhasebesi BOZULUYOR
(Debug'da `nox_rc_predecrement`da "incorrect alignment" panikı,
ReleaseFast'ta SESSİZ SIGSEGV) — bu YÜZDEN genel escape UYGULANMADI,
kullanıcıya AYRI bir derleyici-hatası görevi olarak bildirildi (GG
serisinin serbest-fonksiyon inlining'iyle İLGİLİ OLABİLECEĞİ düşünülüyor,
kesin kök neden BULUNMADI — bu fazın kapsamı DIŞINDA).

## 3.68 `list[str]` + döngünün İKİNCİ yinelemesi: ARC bozulması (Faz JJ'de ÇÖZÜLDÜ — bkz. bu bölümün SONUNDAKİ "Bulgu 3/Çözüm" altbölümü)

**Kaynak:** §3.67'de (Faz II devamı) `nox.json.encode_string`nin genel
`\u00XX` escape yolu denenirken bulunan çökme, kullanıcının AÇIK isteğiyle
(HH.9'un araştırma disiplinini izleyerek, İKİ AYRI turda: "yapabilirsin"
onayıyla) DAHA DERİN araştırıldı.

### Bulgu 1 (İLK tur) — QBE register-çakışması hipotezi, İZOLE testle DOĞRULANAMADI

İLK turda, çökmenin `churn`nin İÇİNDE `ldr x2, [x19]` komutunda (listenin
UZUNLUK alanını, LİSTE İŞARETÇİSİ TUTMASI GEREKEN bir register üzerinden
okurken) olduğu VE çökme adresinin (ör. `0x104640008`) STATİK STRING
LİTERAL veri aralığıyla (heap DEĞİL) örtüştüğü bulunmuştu — bu, `x19`in
(listenin heap işaretçisini TUTMASI gereken register) QBE'nin string-
literal adresleri hesaplamak İçin kullandığı bir SCRATCH register'la
ÇAKIŞTIĞI hipotezini doğurmuştu. **BU hipotez, Nox'u HİÇ karıştırmayan,
EL İLE yazılmış, KÜÇÜLTÜLMÜŞ bir `.ssa` dosyasıyla (AYNI "koşullu
serbest-bırakma + çağrı + 16-elemanlı liste inşası" şekli, gerçekçi bir
Zig `alloc`/`release`/`report` üçlüsüyle) DOĞRUDAN `qbe`ye beslenerek
TEST EDİLDİ — 100+ koşuda HİÇ çökme ÜRETİLEMEDİ.** Bu NEGATİF sonuç,
hipotezin (EN AZINDAN bu basitlikte) YANLIŞ olduğunu — ya da tetikleyici
koşulun DAHA İNCE bir detaya bağlı olduğunu — gösterdi.

### Bulgu 2 (İKİNCİ tur) — GERÇEK mekanizma bulundu: sorun DÖNGÜNÜN KENDİSİNDE, ~%20 DEĞİL ~%100 tekrarlanabilir

Gerçek `churn`nin `.s`inden `main` HARİÇ HER ŞEY çıkarılıp (HH.9'un
"gerçek QBE-derlenmiş fonksiyonları el yazımı test iskeletlerine çıkarma"
tekniği) `churn`i GERÇEK `noxrt.o`ya karşı DOĞRUDAN, TEKRAR TEKRAR
(tek bir süreç İÇİNDE, YENİDEN başlatma OLMADAN) çağıran bir Zig test
iskeleti yazıldı. Bu, ÇOK daha net bir desen ORTAYA ÇIKARDI:

- `churn("ab")` AYNI süreç İçinde ART ARDA çağrıldığında, **BİRİNCİ
  çağrı HER ZAMAN başarılı, İKİNCİ çağrı HER ZAMAN çöküyor** (3 AYRI
  koşumda TUTARLI) — İLK turdaki "~%20, ASLR'ye bağlı" gözlemi YANLIŞ
  DEĞİLDİ ama YANILTICIYDI: asıl tetikleyici SÜREÇ-ÖMRÜ BOYUNCA "kaçıncı
  çağrı" DEĞİL, **BİR TEK ÇAĞRI İÇİNDEKİ döngünün KAÇINCI YİNELEMESİ**
  olduğu ortaya çıktı (aşağıya bkz.).
- Birinci çağrının SONUCUNU BİLEREK serbest BIRAKMAYINCA (sızdırınca)
  bile İKİNCİ çağrı YİNE çöküyor — yani sorun "önceki SONUCUN serbest
  bırakılması" DEĞİL.
- **En küçük, TEMİZ tekrarlama (aşağı) `~%100` oranında çöküyor:**
```nox
def hexd(n: int) -> str:
    digits: list[str] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    return digits[n]

def loopcall(n: int) -> str:
    out: str = ""
    i: int = 0
    while i < n:
        out = out + hexd(1) + hexd(2)
        i = i + 1
    return out

print(loopcall(2))
```
  - `loopcall(1)` (TEK yineleme): **20/20 koşu TEMİZ** (0/20 çökme).
  - `loopcall(2)` (İKİ yineleme): **~20/20 koşu ÇÖKÜYOR** (`SIGABRT`
    "incorrect alignment" panikı VEYA çıplak `SIGSEGV`, hemen HEMEN
    HER seferinde).
  - Sonuç: **birinci yineleme HER ZAMAN güvenli, İKİNCİ yineleme HEMEN
    HEMEN HER ZAMAN döngünün SONUNDAKİ `List_str_release` çağrısını
    (birinci `hexd` çağrısının `digits` listesini serbest bırakan)
    "incorrect alignment" panikiyle ÇÖKERTİYOR** — panik izi HER ZAMAN
    AYNI: `List_str_release` → `nox_str_release` → `nox_rc_predecrement`
    → `alloc.arc.refcountOf`. Bu, listenin 16 elemanından (HEPSİ statik/
    "pinned" string literal işaretçisi OLMASI gereken) EN AZ BİRİNİN,
    İKİNCİ yinelemede release ANINDA ARTIK GEÇERLİ bir işaretçi
    OLMADIĞINI gösterir.
- **Kontrol testi — tetikleyici GERÇEKTEN "AYNI döngüde İKİ çağrı" MI,
  yoksa "list[str] döndüren bir fonksiyonun genel olarak TEKRAR
  ÇAĞRILMASI" MI?** İki AYRI kontrol testi bunu AYIRT ETTİ:
  1. `hexd`i DÖNGÜSÜZ, ayrı bir `pick()` sarmalayıcısı üzerinden 10 kez
     ÇAĞIRAN bir program (`make_digits()` HER ÇAĞRIDA TAZE bir liste
     kurup döner) — **10/10 çağrı TEMİZ**, hiç çökme YOK.
  2. `hexd(a) + hexd(b)`yi (AYNI ifadede İKİ çağrı, ama HİÇBİR döngü
     OLMADAN) 10 kez ÇAĞIRAN bir program — **10/10 çağrı TEMİZ**.
  - YANİ tetikleyici NE yalnızca "list[str] döndüren fonksiyonun tekrar
    çağrılması" NE DE yalnızca "aynı ifadede iki çağrı" — **TAM OLARAK
    İKİSİNİN BİRLİKTELİĞİ, BİR DÖNGÜ İÇİNDE, 2+ yinelemeyle** GEREKİR.

**Değerlendirme:** kök MEKANİZMA (QBE'nin register tahsisi mi, yoksa
`nox_rc_alloc`/DebugAllocator'ın döngü-yinelemeleri-arası bellek YENİDEN
KULLANIMI ile ETKİLEŞEN başka bir codegen sorunu mu) YİNE KANITLANAMADI —
ama artık **son derece GÜVENİLİR (yaklaşık %100), 10 SATIRLIK bir
tekrarlama VAR** ve tetikleyici koşul KESİN olarak İZOLE edildi ("bir
`list[str]` literali döndüren fonksiyonun AYNI ifadede İKİ KEZ çağrılması,
2+ yinelemeli bir döngü İÇİNDE — birinci yineleme HER ZAMAN güvenli,
İKİNCİDEN İTİBAREN HEMEN HEMEN HER ZAMAN döngünün SONUNDAKİ liste
serbest-bırakma çağrısı GEÇERSİZ bir işaretçiyle ÇÖKÜYOR"). Bu, İLK
turun "QBE register çakışması" hipotezini ÇÜRÜTMEDİ (hâlâ olası bir
açıklama) ama onu TEK BAŞINA YETERLİ görmüyor — döngü-yineleme-sayısına
bu KADAR kesin bağımlılık, MUHTEMELEN `codegen.zig`nin (GG.2'nin serbest-
fonksiyon inlining'i, `emitWhile`in yineleme-arası yerel değişken
YENİDEN ATAMA mantığıyla ETKİLEŞEREK) döngü GÖVDESİNİ İKİNCİ (ve SONRAKİ)
yinelemeler İçin FARKLI/YANLIŞ ürettiği bir SENARYOYU da EŞİT derecede
olası kılıyor — QBE'nin KENDİSİNİ SUÇLAMAK İçin (ilk turdaki KADAR)
KESİN DEĞİL.

**Kapatma kararı:** HH.9 İLE AYNI disiplinle — kök mekanizma TAM olarak
KANITLANAMADI (canlı register durumunu lldb İLE incelemek, HH.9'un ZATEN
gösterdiği gibi zamanlamayı BOZUP tekrarlanmayı ENGELLEYEBİLİR) ama BU
turda tekrarlanabilirlik %20'den ~%100'e ÇIKARILDI VE tetikleyici koşul
KESİN olarak izole edildi — gelecekteki bir araştırma BURADAN (10 satırlık
`loopcall` tekrarlamasından) DEVAM ETMELİDİR, ilk turun DAHA BÜYÜK/
karmaşık `churn` tekrarlamasından DEĞİL. **Önerilen sonraki adım:**
`loopcall`in QBE IR'ını (`.ssa`) birinci VE ikinci yineleme İçin ÜRETİLEN
assembly bloklarını YAN YANA diff'leyerek (`otool -tV`, HH.9'un yöntemi)
İKİ yinelemenin GERÇEKTEN aynı kod yolunu mu izlediğini (döngü olduğundan
TEK bir statik kod bloğu tekrar ÇALIŞTIRILIR, bu YÜZDEN bu adım BEKLENEN
sonucu doğrulamak İçindir) VE `List_str_release`e geçirilen POINTER'IN
İKİNCİ yinelemede TAM OLARAK NEREDE bozulduğunu (bir register'ın
YİNELEMELER ARASI YANLIŞ yeniden kullanımı MI, yoksa `nox_rc_alloc`nin
İKİNCİ tahsiste FARKLI davranması MI) bir hardware watchpoint'le (HH.9'un
başarıyla kullandığı teknik) izlemek.

### Bulgu 3 (Faz JJ) — KÖK NEDEN BULUNDU VE DÜZELTİLDİ: `releaseSlotIfSet` serbest bıraktıktan SONRA slotu sıfırlamıyordu

Kullanıcının AÇIK isteğiyle ("şu daha önce bulduğun hatayı da düzeltelim")
YENİDEN ele alındı. Önerilen sonraki adımdan (yukarı bkz.) BAŞLANMADI —
bunun yerine `lldb` İLE DOĞRUDAN `List_str_release`e (ve `nox_str_release`e)
geçirilen POINTER değerleri her çağrıda LOGLANDI (`breakpoint command add` +
`memory read`), `loopcall(2)`nin GERÇEK çalışması İZLENEREK:

- Döngünün 1. yinelemesindeki HER İKİ `List_str_release` çağrısı (hexd(1)
  VE hexd(2) İçin) TAMAMEN DOĞRU veriyle (`len=16, cap=16`, 16 GEÇERLİ
  string-literal adresi) çalıştı.
- 2. yinelemedeki `List_str_release` çağrısı, **1. yinelemedeki İLK
  çağrıyla TAM OLARAK AYNI POINTER'I** kullandı (`0x100520008` — Zig'in
  DebugAllocator'ı, serbest bırakılan bir bloğu HEMEN yeniden kullanmıştır,
  bu KENDİSİ NORMAL bir allocator davranışıdır) — AMA bu SEFER bellek
  İÇERİĞİ ÇÖPTÜ: `len=0xaaaa`, `cap=1`, `eleman[0]=0x3231` (SEKİZ bayta
  hizalı OLMAYAN, tamamen geçersiz bir "işaretçi"). `refcountOf`nün
  `@alignCast`i BUNU YAKALAYIP "incorrect alignment" panik verdi.

**Kök neden zinciri:** `hexd`in `digits` yerel değişkeni `loopcall`nin
döngü GÖVDESİNDE (Faz GG.2'nin serbest-fonksiyon inlining'iyle) İKİ ayrı
ÇAĞRI SİTESİNE inline EDİLİR — her site İçin `digits`in slotu (`alloc8`)
DÖNGÜNÜN DIŞINDA, YALNIZCA BİR KEZ ayrılır (bkz. `genInlinedCall`/
`allocInlineSlot`) VE döngünün HER yinelemesinde YENİDEN KULLANILIR.
`hexd`in inline edilmiş "dönüşü" (`genStmts`nin `.return_stmt` dalının
`inline_return_target` koluna bkz.), callee'nin KENDİ yerellerini (`digits`
DAHİL) `releaseNamedLocalsExcept` İLE "kapsam sonu" temizliği YAPARAK
serbest bırakır — HER yinelemenin SONUNDA BİR KEZ. Bu temizlik,
`releaseOneLocalIfManaged` ÜZERİNDEN `releaseSlotIfSet`e gider — VE
`releaseSlotIfSet`, slotu OKUYUP serbest bıraktıktan SONRA **slotu
SIFIRLAMIYORDU**. Bir GERÇEK (inline OLMAYAN) fonksiyon çağrısı İçin bu
ZARARSIZDIR (slot, fonksiyonun KENDİ yığın çerçevesi yıkıldığında zaten
YOK OLUR) — ama inline edilmiş, döngü İçindeki BİR yerel İçin, slot
YİNELEMELER ARASI KALICIDIR. Böylece: 1. yinelemenin SONUNDA `digits`
serbest bırakılır AMA slotu ESKİ (artık serbest bırakılmış) POINTER'I
TAŞIMAYA DEVAM EDER; 2. yinelemenin BAŞINDA `digits` YENİDEN "bildirilirken"
(`var_decl`nin KENDİ "üzerine yazmadan ÖNCE eskiyi serbest bırak" mantığı,
bkz. `genListLit`in ÖNCESİNDEKİ `release_skip11`/`release10` bloğu) BU
ESKİ, ZATEN SERBEST BIRAKILMIŞ POINTER'I HÂLÂ "canlı" SANIP TEKRAR serbest
bırakmaya ÇALIŞIR — GERÇEK bir çift-serbest-bırakma/kullanım-sonrası-
serbest-bırakma. Bellek o ANA KADAR (DebugAllocator'ın KENDİ iç
bookkeeping'i tarafından) YENİDEN KULLANILDIĞINDAN, okunan "eski değer"
ÇÖP veridir — `refcountOf`nün hizalama denetimi bunu YAKALAR (Debug/
ReleaseSafe modlarında; ReleaseFast'te `@alignCast` bir NO-OP olduğundan
SESSİZCE BOZUK bellek okunurdu, kanıtlandığı GİBİ bu fazın repro'su
ReleaseFast noxc'ta HİÇ ÇÖKMEDİ — yalnızca Debug'da).

**Düzeltme:** `releaseSlotIfSet` VE onun ARC-dışı (`Task`/`Channel`/
`ThreadHandle`/`ThreadChannel`) karşılığı `destroyNonArcSlotIfSet`,
serbest bırakma/yıkımdan HEMEN SONRA slotu `storel 0, <slot>` İLE
SIFIRLAR. Bu, GERÇEK fonksiyon çağrıları İçin TAMAMEN zararsızdır (slot
ZATEN atılacaktı) — inline edilmiş, döngü İçindeki yerel değişkenler İçin
İSE TAM OLARAK gereken "kapsam sonunda BOŞALTILMIŞ" değişmezini SAĞLAR.
Düzeltme, `compiler/codegen_qbe/codegen.zig`nin YALNIZCA BU İKİ fonksiyonuna
(`releaseSlotIfSet`/`destroyNonArcSlotIfSet`) BİRER satır (`storel 0, ...`)
EKLEYEREK yapıldı — başka HİÇBİR yer DEĞİŞTİRİLMEDİ.

**Doğrulama:** `loopcall(2)`/`loopcall(5)`/`loopcall(1)`/`loopcall(0)`
(1-10 arası tekrarlanan koşumlar DAHİL) düzeltmeden SONRA %100 TEMİZ —
ÖNCEDEN ~%100 çöken repro artık HİÇ çökmüyor. `zig build test`
(Debug/ReleaseSafe/ReleaseFast) TAMAMI yeşil (534/535 — tek istisna,
Faz HH.9'un ÖNCEDEN belgelenmiş, İLGİSİZ, bilinen bir flaky testi). Break→
red→fix: düzeltme (`storel 0, ...`) GERİ ALININCA, GOLDEN test AYNI
"incorrect alignment" panikiyle (AYNI yığın izi) doğru şekilde KIRMIZI
oldu — bu, testin GERÇEKTEN bu SINIFTAKİ bir regresyonu YAKALAYACAĞINI
kanıtlar. Yeni golden test:
`tests/golden/codegen_cases/inline_loop_list_str_local_double_call.nox`.

## 3.69 Faz III — Stdlib genişletmesi: eksik-fonksiyon tablosunun kapatılması

**Kaynak:** kullanıcının AÇIK isteği — Faz II'nin (§3.67) eksik-fonksiyon
tablosundaki TÜM maddelerin kapatılması. İki araştırma ajanıyla (dict/
collections+process desteği; fs/time internals+tuple desteği) BOYUTLANDIRILDI:
listenin 5 maddesi (regex TAM motor, `StringBuilder`, JSON Serialize/
Deserialize, `dict.remove()`, süreç oluşturma — artı UTF-8 farkındalığı)
GERÇEKTEN büyük, bağımsız mimari kararlar GEREKTİRDİĞİNDEN BİLİNÇLİ OLARAK
BU fazın kapsamı DIŞINDA bırakıldı (HERBİRİ AYRI bir görev/planlama turu
gerektirir — bkz. plan dosyası); KALAN kısım MEVCUT desenlerin (extern
def + libm/Zig std sarmalayıcı, `DateTime`nin Nox-tarafı sınıf inşası,
`nox_strings_split_raw`nin el-yapımı `list[T]` inşası) tekrarı olarak
10 alt-fazda (III.1-III.10) uygulanıyor, HER biri KENDİ commit'iyle.

### III.1 (TAMAMLANDI) — `nox.math` trigonometri/logaritma + sabitler

`sin`/`cos`/`tan`/`log`/`exp`/`atan2` — `sqrt`/`pow`/`floor`/`ceil` İLE
AYNI çıplak-çağrılan `extern def ... from "m"` deseni. **`ln` YOK** —
libm'de BÖYLE bir sembol YOK (yalnızca doğal logaritma İçin `log`) — bu
yüzden `nox.math.ln`, `log`u SARAN, NİTELİKLİ çağrılan sıradan bir
`func_def`dir (`min`/`max`/`abs` İLE AYNI ilke, `module_loader`in "extern
def'ler mangle edilmez" asimetrisiyle TUTARLI). `pi()`/`e()` — Nox'ta
top-level `const` OLMADIĞINDAN sabitler NİTELİKLİ çağrılan fonksiyonlar
olarak sunulur (`nox.math.pi()`). Yeni golden test:
`math_trig_log_constants.nox`. Dosya: `stdlib/nox/math.nox` (SAF Nox,
runtime/codegen değişikliği YOK).

### III.2 (TAMAMLANDI) — `nox.strings` eksik yardımcıları

`trim_start`/`trim_end` (`std.mem.trimStart`/`trimEnd`), `splitn(s,sep,n)`
(EN FAZLA `n` parça, SONUNCUSU KALANIN TAMAMI — Rust'ın `str::splitn`iyle
TUTARLI), `rsplit(s,sep)` (`split`in AYNI parçaları, TERS sırada),
`repeat(s,n)` (EE.1'in `join`iyle AYNI TEK-tahsis stratejisi — saf Nox
O(n²) döngüsünden KAÇINMAK İçin), `eq_ignore_case(a,b)` (`std.ascii.
eqlIgnoreCase`, ASCII v1 kapsamı). HEPSİ `runtime/stdlib_shims/
strings.zig`ye (7 yeni unit test, break→red→fix İLE doğrulandı) +
`stdlib/nox/strings.nox`ye ince sarmalayıcılar olarak eklendi. Yeni
golden test: `strings_new_helpers.nox`.

### III.3 (TAMAMLANDI) — `nox.fs` genişletmesi + `page_allocator` düzeltmesi

**Yeni fonksiyonlar:** `append_string` (`write_string`nin AKSİNE
KISALTMAZ, `O.APPEND`); `metadata()` (`DateTime`nin AYNI Nox-tarafı sınıf
inşa deseni — Zig `nox_fs_stat_raw` TEK bir `open`+`fstat`+`close` yapıp
`threadlocal` statiklere ÖNBELLEKLER, iki AYRI accessor Nox'ta
`FileMetadata`yı kurar); `read_dir()` (`list[str]`, HAM libc `opendir`/
`readdir`/`closedir` — bu Zig sürümünde `std.fs.Dir`/`std.Io.Dir` bir
`Io` bağlamı GEREKTİRDİĞİNDEN, `.`/`..` ATLANIR); `copy` (TAŞINABİLİR —
macOS'a-özgü `copyfile()` KULLANILMAZ, oku+yaz); `rename`/`remove_file`/
`create_dir` (`std.c.rename`/`unlink`/`mkdir`). **Önemli düzeltilmiş
varsayım:** dosyanın ÜST-modül belge notu `std.c.stat`in aarch64-macOS'ta
BAĞLI OLMADIĞINI iddia ediyordu — bu, YALNIZCA YOL-tabanlı `stat`i
etkiliyor, **FD-tabanlı `std.c.fstat` GERÇEKTEN test EDİLİP ÇALIŞTIĞI
DOĞRULANDI**, `metadata()` bunun ÜZERİNE kuruldu.

**Fırsatçı düzeltme:** `nox_fs_read_to_string_raw` HÂLÂ `path.zig`nin
EE.1-SONRASI düzeltmesinden ÖNCEKİ `page_allocator` çift-tahsis desenini
kullanıyordu — bu dosyaya ZATEN dokunulduğundan `fstat` İLE dosya
boyutunu ÖNCEDEN alıp TEK bir `arc.nox_rc_alloc`a DOĞRUDAN okuyan
stratejiye geçirildi. **Yeni `fs_bench` (2000 baytlık dosyayı 20000 kez
okur) İLE ÖNCE/SONRA ÖLÇÜLDÜ: ~170-180ms → ~130-138ms (~1.25-1.3x)** —
`path_bench`nin ~9.9x'inden ÇOK daha MÜTEVAZİ (GERÇEK disk G/Ç süresi
BURADA TOPLAM sürenin BÜYÜK kısmı, tahsis stratejisinin payı KÜÇÜK) ama
GERÇEK bir kazanç. `fs_bench`, `benchmarks/rust_crates`nin DIŞINDA,
Faz II'nin AYNI `path_bench`/Rust karşılaştırma desenine (Bölüm 4)
eklendi.

**14 yeni unit test (break→red→fix İLE doğrulandı, GERÇEK bir "eksik
`.`/`..` filtresi" bozulmasında BEKLENEN ARC sızıntıları bile
YAKALANDI) + 1 yeni golden test** (`fs_new_operations.nox` — idempotent
olması İçin `create_dir`den ÖNCE `exists` kontrolü İÇERİR, tekrar tekrar
koşulabilir).

**Bilinçli v1 sınırlaması (kapsam DIŞI, gelecekteki bir görev):** ikili
(byte) okuma/yazma — Nox `str`leri NULL-sonlandırılmış OLDUĞUNDAN gömülü
NUL bayt İÇEREN veriyi GÜVENLE taşıyamaz, GERÇEK bir "bytes" tipi
gerektirir (`StringBuilder` İLE AYNI "yeni tip" kararı).

### III.4 (TAMAMLANDI) — `nox.path` kalan fonksiyonlar

`canonicalize` (`std.c.realpath` — bu modülün "hiç I/O yok" ilkesine
BİLİNÇLİ, TEK istisna; sembolik linkleri ÇÖZMEK İçin dosyanın VAR OLMASI
GEREKİR, bu YÜZDEN `nox.fs` İLE AYNI "ham çağrı + `PathError`" desenine
ihtiyaç duyan TEK fonksiyon — YENİ eklenen `PathError` sınıfı); GERÇEK
bir test (`/tmp/../tmp`) macOS'ta `/tmp`nin KENDİSİNİN `/private/tmp`ye
bir sembolik link OLDUĞUNU (`canonicalize`nin bunu da DOĞRU çözdüğünü)
ORTAYA ÇIKARDI. `strip_prefix` (SAF string, eşleşmezse yol DEĞİŞMEDEN
döner — Rust'ın `Result` dönen `Path::strip_prefix`inden farklı, bilinçli
v1 basitleştirmesi). `components()` (`list[str]`, `std.fs.path.
componentIterator` — SAF bir string ayrıştırıcı, I/O GEREKMEZ). 4 yeni
unit test (break→red→fix İLE doğrulandı) + 1 yeni golden test.

### III.5 (TAMAMLANDI) — `nox.os` ortam değişkeni yazma + cwd

`set_var(name, value)` (`std.c.setenv` — bu Zig sürümünün `std.c`sinde
BULUNMADIĞI İÇİN, `runtime/foreign_bridge.zig`nin AYNI "std.c'de eksikse
ham `extern \"c\" fn` bildir" deseniyle DOĞRUDAN bağlandı); `current_dir()`
(`std.c.getcwd`, `std.c.PATH_MAX` boyutlu yığın arabelleği). Her ikisi de
DAHA ÖNCE `nox.os`da HİÇ olmayan yeni davranışlar (modül SADECE OKUMA
yapıyordu — `arg`/`getenv`/`has_env`; artık GERÇEK yan etkili bir yazma
işlemi VAR). 2 yeni unit test (`set_var` + `getenv` round-trip, ve
`current_dir`nin boş olmayan mutlak bir yol döndürdüğü — `break→red→fix`
İLE doğrulandı, sabotajlı `set_var` çağrısı `setenv`i HİÇ çağırmadan
"başarılı" görünmeye çalıştığında test doğru şekilde KIRMIZI oldu) + 1
yeni golden test (`os_new_operations`).

### III.6 (TAMAMLANDI) — `dict[K,V]` salt-okunur iterasyon: `keys()`/`values()`

`d.keys() -> list[K]`/`d.values() -> list[V]` — `contains`/`len` İLE AYNI
"yerleşik metod, kullanıcı sınıfı DEĞİL" deseniyle checker.zig'e (`Type{
.list = obj_t.dict.key }`/`.value`) VE codegen_qbe/codegen.zig'in
`genDictMethod`ine eklendi. `runtime/collections/dict.zig`ye YENİ, ORTAK
bir `buildEntryList` yardımcısı (+ `nox_dict_keys`/`nox_dict_values`)
eklendi — `entries`i (`index_built`/silme değişmezine HİÇ DOKUNMADAN,
SALT OKUNUR) `list[T]`nin ham bayt düzenine (`nox_fs_read_dir_raw`nin
AYNI el-yapımı 16-bayt başlık + N eleman deseni) kopyalar. **Gerçek bir
tasarım incelemesi:** `Entry.key`/`.value` HER ZAMAN 8 baytlık bir
"payload" olarak saklanır (`codegen.zig`nin `toPayload`sı `bool`u DAHİ
`w`->`l` `extuw` İLE 8 bayta genişletir) — ama `list[bool]` GERÇEKTE
4 baytlık (`w`) elemanlardan oluşur (bkz. `genListLit`nin `elem_qtype =
first.qtype`si). Bu UYUMSUZLUĞU çözmek İÇİN `DictInfo`ye (ÖNCEDEN yalnızca
`value_qtype` VARDI, simetrik bir `key_qtype` YOKTU) YENİ bir `key_qtype`
alanı eklendi — `keys()`/`values()` çağrı sitesi, hedef eleman boyutunu
(`qbeSizeOf(key_qtype/value_qtype)`) runtime'a AÇIKÇA geçirir, `buildEntryList`
bool İÇİN düşük 32 biti alır (`extuw`nin sıfır-genişletmesi SAYESİNDE
KAYIPSIZ round-trip). `str` anahtar/değerler İÇİN her eleman `nox_rc_
retain` İLE PAYLAŞILIR (dict KENDİ referansını korur, dönen liste BAĞIMSIZ
bir ikinci sahip olur — break→red→fix'in KENDİSİ, retain KALDIRILINCA
DebugAllocator'ın GERÇEK bir kullanım-sonrası-serbest-bırakma/sızıntı
raporladığını doğruladı). `remove()`/`items()` (çift/`DictEntry` tipi
gerektirir) BİLİNÇLİ olarak kapsam DIŞI bırakıldı (bkz. planın "Kapsam
DIŞI" bölümü). 4 yeni Zig unit testi (int/bool/str anahtar-değer
senaryoları, break→red→fix İLE doğrulandı) + 1 yeni golden test
(`dict_keys_values` — `dict[str,int]`/`dict[int,bool]`/`dict[int,int]`
uçtan uca).

### III.7 (TAMAMLANDI) — `nox.time` `DateTime.to_str()` + `Instant`/`Duration`

`DateTime.to_str()` — SAF Nox (HİÇ runtime değişikliği GEREKMEDİ):
`"YYYY-AA-GG SS:DD:ss"` (ISO 8601'e yakın, sabit genişlik) — Nox'ta
`%02d` gibi bir biçimlendirme ilkeli OLMADIĞINDAN, YENİ bir modül-düzeyi
`pad2(n)` yardımcısı (`n < 10` İSE `"0" + str(n)`) İLE elle sıfır-doldurma
yapılır. `Instant`/`Duration` — Rust'ın `Instant::now()`/`.elapsed()`
İLE AYNI ilke: `now_ms`nin duvar-saati (`.REALTIME`, sistem saati
DEĞİŞTİRİLİRSE GERİYE sıçrayabilir) YERİNE YENİ bir `nox_time_monotonic_
ms_raw` (`.MONOTONIC`) kullanılır. `Instant(ms)` + `elapsed_ms() -> int`/
`elapsed() -> Duration`; `Duration(ms)` + `as_ms() -> int`. `instant_now()`
modül fonksiyonu `Instant`i inşa eder. 1 yeni Zig unit testi (break→red→fix
İLE doğrulandı — sahte HEP-SIFIR bir saat DÖNÜLÜNCE hem bu test HEM DE
YENİ golden test doğru şekilde KIRMIZI oldu) + 1 yeni golden test.

### III.8 (TAMAMLANDI) — `nox.random` dağılımlar + `shuffle`

`normal()`/`exponential(rate)` — SAF Nox (HİÇ runtime değişikliği
GEREKMEDİ), MEVCUT `random()` + `nox.math`nin `sqrt`/`log`/`cos`/`pi()`si
üzerine kurulu (Box-Muller/ters-CDF). `shuffle[T](xs: list[T])` — Fisher-
Yates, `list[T]`nin MEVCUT indeksleme/atama desteğiyle (Faz U.1) YERİNDE
çalışır. **Gerçek bir çözülen boşluk:** `nox.random.shuffle(xs)` gibi
NİTELİKLİ bir çağrı, checker.zig'in `resolveMangledCall`inin (nitelikli-
çağrı çözüm yolu) `self.generic_functions`i HİÇ KONTROL ETMEDİĞİ İÇİN
BAŞARISIZ oluyordu ("modülün 'shuffle' adlı üyesi yok" — GERÇEKTEN
denenip YAKALANDI) — yalnızca ÇIPLAK (aynı modül İÇİNDEN) generic
çağrılar `checkCall`in `.identifier` dalından çalışıyordu. `resolveMangledCall`e
`self.generic_functions.get(mangled)` kontrolü + `instantiateGeneric`
çağrısı eklenerek NİTELİKLİ generic çağrılar da desteklendi (break→red→fix
İLE doğrulandı — kontrol `if (false)` İLE devre dışı bırakılınca AYNI
hata mesajı GERİ GELDİ). 1 yeni golden test (`normal`/`exponential` +
`list[int]`/`list[str]` üzerinde `shuffle` DAHİL uçtan uca; Zig-tarafı
DEĞİŞİKLİK OLMADIĞINDAN YENİ bir Zig unit testi GEREKMEDİ, break→red→fix
DOĞRUDAN golden test İLE yapıldı).

### III.9 (TAMAMLANDI) — `nox.crypto` ek hash algoritmaları: `sha1`/`sha512`

`sha256` İLE BİREBİR AYNI desen (`with_rt`, ARC'lı küçük-harf hex `str`
sonucu) — Zig'in KENDİ `std.crypto.hash.Sha1`i (20 baytlık özet, 40
karakterlik hex) VE `std.crypto.hash.sha2.Sha512`si (64 baytlık özet, 128
karakterlik hex) kullanılır, sıfırdan bir hash algoritması YAZILMAZ.
Bilinen test vektörleri (`""`/`"abc"`, NIST/RFC referans değerleriyle
KARŞILAŞTIRILDI) HEM Zig unit testinde HEM golden testte doğrulandı. 4
yeni Zig unit testi (bilinen vektörler + sabit-uzunluk/hex-karakter
kontrolü, break→red→fix İLE doğrulandı — özetin İLK baytı bozulunca hem
unit test HEM golden test doğru şekilde KIRMIZI oldu) + 1 yeni golden test.

### III.10 (TAMAMLANDI) — `nox.json` `encode_pretty`

`encode_pretty(v, indent) -> str` — `encode`in girintili varyantı, SAF
Nox (HİÇ runtime değişikliği GEREKMEDİ), `nox.strings.repeat` (Faz III.2)
İLE girinti dizeleri üretilir. `indent`, SEVİYE BAŞINA boşluk SAYISIDIR
(Python'un `json.dumps(v, indent=2)`si İLE AYNI biçim/anlam). Yalnızca
dizi/nesne düğümleri çok satırlı biçimlendirilir — skaler değerler
(`null`/`bool`/sayı/dize) VE boş dizi/nesne (`[]`/`{}`) `encode`in
DEĞİŞMEMİŞ tek-satırlık çıktısını üretir (Python'un AYNI davranışıyla
TUTARLI). Zig-tarafı DEĞİŞİKLİK OLMADIĞINDAN YENİ bir Zig unit testi
GEREKMEDİ — break→red→fix DOĞRUDAN golden test İLE yapıldı (girinti
çarpanı düşürülünce test doğru şekilde KIRMIZI oldu). 1 yeni golden test
(iç içe dizi/nesne + boş dizi/nesne + skaler DAHİL uçtan uca).

**Faz III TAMAMLANDI** — III.1'den III.10'a KADAR 10 alt-fazın TÜMÜ
uygulandı, doğrulandı VE ayrı commit'lerle kayıt altına alındı. Kapsam
DIŞI bırakılan 5 madde (+ UTF-8) İÇİN bkz. bu bölümün BAŞINDAKİ "Kapsam
DIŞI" notu — bunlar BİLİNÇLİ olarak ERTELENDİ, unutulmadı; her biri
KENDİ ayrı planlama/tasarım turunu HAK EDEN bağımsız görevlerdir.

## 3.70 Faz KK — Güvenlik analizi bulgularının düzeltilmesi

**Kaynak:** kullanıcının AÇIK isteğiyle yapılan, üç paralel odaklı kod
incelemesiyle (nox.http; FFI/HPy/WASM güven sınırları; ARC/bellek
güvenliği desenleri) TOPLANAN bir güvenlik zaafiyet raporu — 3 yüksek,
8 orta, 5 düşük öncelikli bulgu VE 8 doğrulanmış güçlü yön. Kullanıcı
"yüksek ve ortaları hemen yapmaya başlayalım sırayla" dedi — bu bölüm,
raporun ÖNCELİK sırasına göre uygulanan düzeltmeleri KAYIT ALTINA alır.

### KK.1 (TAMAMLANDI) — H-2: `dict[K,V]` eksik anahtar erişimi artık `KeyError` raise ediyor

**Önceki durum (GERÇEK bir null-pointer çökmesi, kanıtlandı):**
`nox_dict_get`, anahtar bulunamazsa (bilinçli "Python'ın `KeyError`ı
yok" v1 kararıyla) sessizce `0` (null) dönüyordu — ama `genDictGet` bu
değeri normal, opsiyonel-olmayan bir `str`/`list`/`class` gibi ileri
taşıyordu. `d: dict[str,str] = {"a":"1"}; x: str = d["missing"];
print(len(x))` derlenip ÇALIŞTIRILDIĞINDA `SIGSEGV` (exit 139) İLE
çöktüğü DOĞRUDAN doğrulandı. AYRICA bağımsız bir DOĞRULUK hatası VARDI:
`dict[str,int]` gibi sayısal değer tiplerinde saklı GERÇEK bir `0`
DEĞERİ İLE "anahtar YOK" durumu AYIRT EDİLEMİYORDU.

**Düzeltme:** `genDictGet`, `genIndex`in `list[T]` sınır kontrolüyle
AYNI "önce doğrula, hata dalında raise et, phi'siz ok'e atla" desenini
İZLER — `nox_dict_get`den ÖNCE `nox_dict_contains` İLE anahtarın VAR
OLUP OLMADIĞI kontrol edilir, yoksa YENİ eklenen `KeyError` sınıfı
(`stdlib/nox/core.nox`, `IndexError`/`ValueError` İLE AYNI "her programa
otomatik dahil, mangle EDİLMEZ" statüsünde) `raise` edilir. Bu, ARTIK
`int`/`float`/`bool` değer tipleri İÇİN DE doğru çalışır — `nox_dict_
contains`in KENDİSİ değere BAKMAZ, yalnızca anahtarın varlığına.

**Bir yan-etki (TEST HARNESS'ında BULUNAN, ÖNCEDEN VAR OLAN bir
boşluk):** `tests/golden/fmt_golden_test.zig`nin `compileAndRun`ı
`module_loader.resolveImports`i HİÇ ÇAĞIRMIYORDU (yalnızca
`codegen_golden_test.zig`ninki çağırıyordu) — bu YÜZDEN `core.nox`nin
sınıfları (`IndexError`/`ValueError`/YENİ `KeyError`) BU test yolunda
HİÇ birleştirilmiyordu. `kitchen_sink.nox`nin `headers["a"]` dict-
okuması, HER `d[key]` ifadesinin (çalışma zamanında tetiklenmese BİLE)
codegen'in `self.classes.get("KeyError")`ına artık İHTİYAÇ duymasıyla
bu boşluğu İLK KEZ AÇIĞA ÇIKARDI (`error.Unsupported`). `fmt_golden_
test.zig`ye `codegen_golden_test.zig` İLE AYNI `resolveImports` çağrısı
eklenerek düzeltildi — GERÇEK bir test-altyapısı hatasıydı, benim
değişikliğimin YOL AÇTIĞI bir REGRESYON değil.

Ayrıca `tests/golden/codegen_cases/try_except_finally.nox`nin KENDİ,
İLGİSİZ bir demo istisnası İÇİN kullandığı `class KeyError` (farklı bir
alan şekliyle, `key: int`) YENİ çekirdek sınıfla ADI ÇAKIŞTIĞINDAN
`ZeroValueError` olarak yeniden adlandırıldı — `IndexError`/
`ValueError`nin ZATEN taşıdığı, kullanıcı sınıflarıyla isim çakışması
riskiyle AYNI, ÖNCEDEN var olan kategori.

1 yeni golden test (`dict_missing_key_raises` — `dict[str,str]` VE
`dict[int,int]`, KEY bulunan/bulunmayan HER İKİ durum, `try`/`except`
İLE yakalama DAHİL) + break→red→fix İLE doğrulandı (kontrol `if (false)`
İLE devre dışı bırakılınca test doğru şekilde KIRMIZI oldu, "anahtar
bulunamadi" YERİNE "ulasilmamali" okundu).

### KK.2 (TAMAMLANDI) — H-1: `hpy_call`ın yol/uzantı/fonksiyon adı artık derleme-zamanı string literali olmak ZORUNDA

**Önceki durum:** `hpy_call(yol, uzantı_adı, fonksiyon_adı, argüman)`ın
İLK ÜÇ argümanı checker'da yalnızca TİPÇE `str` olmak zorundaydı — DEĞER
olarak keyfi ÇALIŞMA ZAMANI ifadeleri (bir config dosyasından/ortam
değişkeninden/ağ yanıtından okunan bir `str`) OLABİLİYORDU.
`runtime/hpy_bridge/loader.zig`nin `std.DynLib.open`ı BU yolu HİÇBİR
doğrulama/sandbox OLMADAN açıp eşleşen `HPyInit_*` sembolünü fonksiyon
işaretçisi olarak ÇAĞIRDIĞINDAN, bu SIRADAN Nox kaynağından ulaşılabilen,
doğrulamasız bir "keyfi native kütüphane yükle ve çalıştır" ilkeliydi —
yol saldırgan etkisindeyse doğrudan uzaktan kod yürütmeye dönüşür.

**Düzeltme:** checker, `hpy_call`ın İLK ÜÇ argümanının (`yol`/`uzantı_adı`/
`fonksiyon_adı`) `.string_lit` AST düğümü (derleme-zamanı SABİTİ) OLMASINI
ZORUNLU kılıyor — `extern def ... from "<lib>"`nin ZATEN dilbilgisi
SEVİYESİNDE yalnızca bir string TOKEN'I kabul etmesiyle AYNI ilke: hangi
native kodun yükleneceği KAYNAK KODUNDA AÇIKÇA yazılmalı, ÇALIŞMA
ZAMANINDA hesaplanıp GİZLENEMEZ. Dördüncü argüman (`argüman: int`)
BİLİNÇLİ olarak İSTİSNA — dinamik kalması GEREKİR (fonksiyona geçirilen
GERÇEK veri). `wasm_call` (WASM köprüsü) BU kapsam DIŞINDA bırakıldı —
güvenlik raporunun G-2 bulgusu, WASM yorumlayıcısının import bölümünü HİÇ
DESTEKLEMEDİĞİNİ (host çağrısına kaçış YOK) doğruladığından, AYNI risk
sınıfı ORADA YOK.

1 yeni Zig unit testi (checker'ın `nox.checker.check`ini DOĞRUDAN çağırıp
`TypeMismatch` VE mesajın "string LİTERALİ" İÇERDİĞİNİ doğrular — mevcut
`hpy_call_golden_test.zig`nin AKSİNE, `.hpy-venv` KURULU OLMASINI
GEREKTİRMEZ, standart takımda HER ZAMAN çalışır) + break→red→fix İLE
doğrulandı.

### KK.3 (TAMAMLANDI) — H-3: Ayrıştırıcıya özyineleme-derinliği sınırı eklendi

**Önceki durum (GERÇEK, kendim doğruladığım bir derleyici-DoS'u):**
Özyinelemeli-iniş (recursive-descent) ayrıştırıcının HİÇBİR derinlik
sınırı YOKTU — 50.000 iç içe parantez İÇEREN tek satırlık bir `.nox`
dosyası, `noxc`nin KENDİSİNİ (derlediği programı DEĞİL) yığın taşmasıyla
ÇÖKERTİYORDU (segfault, exit 134). Nox kaynağı güvenilmeyen bir yerden
derleniyorsa (çevrimiçi oyun alanı, CI/derleme hizmeti) trivial bir DoS
vektörüydü. Projenin kendi kapsam-güdümlü fuzz altyapısı (`tests/fuzz/`)
BUNU YAKALAMIYORDU — varsayılan korpus 2048 bayt İLE SINIRLI OLDUĞUNDAN
bu derinliğe hiç ULAŞAMIYORDU.

**Düzeltme:** `Parser`e (bkz. `compiler/parser/parser.zig`) CANLI (şu an
yığında olan) özyineleme derinliğini SAYAN paylaşılan bir `depth` alanı
+ `enterRecursion`/`exitRecursion` yardımcı çifti eklendi. Sayaç, ÜÇ AYRI
özyineleme GİRİŞ noktasının (`parseExpr` — parantezli ifadeler/liste/
sözlük/çağrı argümanları İçin ORTAK giriş; `parseNot` — KENDİ kendine
özyineler, `not not not ...`; `parseUnary` — KENDİ kendine özyineler,
tekli eksi/`await`/`spawn` zincirleri) HEPSİNDE çağrılır — `parseNot`/
`parseUnary`, `parseExpr`in YENİDEN girişinden GEÇMEDİĞİNDEN (kendi
kendilerine özyinelerler), BUNLARIN AYRI birer koruma GEREKTİRDİĞİ
DOĞRULANDI (yalnızca `parseExpr`e bir koruma koymak BU İKİSİNİ
YAKALAMAZDI — üç ayrı `not`/eksi zinciri repro'suyla KANITLANDI).
`MAX_EXPR_DEPTH` (500), GERÇEKÇİ HERHANGİ bir Nox programının asla
yaklaşmayacağı ama macOS'un varsayılan 8MB yığınında BOL PAY bırakan bir
sınırdır. Aşıldığında YENİ `ParseError.RecursionLimitExceeded` döner —
`compiler/lsp_main.zig`nin `parseErrorMessage`i (ÖNCEDEN `ParseError`
üzerinde AYRINTILI bir `switch` yaptığından, YENİ hata VARYANTI onu
DERLENEMEZ hâle getirdi, bu BEKLENEN VE düzeltilen bir yan etkiydi) de
GÜNCELLENDİ.

1 yeni Zig unit testi (`tests/unit/parser_test.zig` — DÖRT alt-durum:
makul derinlik 50, GERÇEK repro'nun AYNISI 50.000 parantez, 5.000 `not`
zinciri, 5.000 tekli-eksi zinciri; İLK durum SORUNSUZ ayrıştığını, DİĞER
ÜÇÜ `RecursionLimitExceeded` döndüğünü doğrular) + break→red→fix İLE
doğrulandı (`MAX_EXPR_DEPTH` pratikte devre dışı bırakılınca AYNI sınıf
çökme — bu SEFER `parseNot` zincirinden — GERİ GELDİ).

**Faz KK (H-1/H-2/H-3) TAMAMLANDI** — güvenlik raporunun ÜÇ yüksek
öncelikli bulgusunun TÜMÜ düzeltildi. Orta öncelikli bulgular İçin
ayrı alt-fazlar (KK.4+) DEVAM EDECEK.

### KK.4 (TAMAMLANDI) — M-1: HTTP başlık CR/LF doğrulaması artık HER build modunda çalışıyor

**Önceki durum:** `std.http`nin KENDİ başlık adı/değeri doğrulaması
yalnızca `assert`/`std.debug.runtime_safety` İLE yapılıyordu — bu,
`ReleaseFast`/`ReleaseSmall` derlemelerinde TAMAMEN devre dışıydı.
`http_client.copyHeaders`/`http_server.retainHeaders`, Nox `dict[str,
str]`den gelen başlık adı/değerini HİÇ KENDİ doğrulaması OLMADAN
`std.http.Header`e AKTARIYORDU. Kullanıcı verisini bir isteğe/yanıta
başlık olarak yansıtan bir Nox programı (ör. `nox.http.get(url,
{"X-Debug": kullanici_girdisi})`), ÜRETİM (ReleaseFast) derlemesinde
SESSİZCE CRLF enjekte edip başlık/yanıt bölme (header/response
splitting) yapabiliyordu; Debug/ReleaseSafe'de İSE AYNI girdi bu SEFER
bir panikle SÜREÇ ÇÖKMESİNE (DoS) yol açıyordu — İKİ modda da güvenli
DEĞİLDİ.

**Düzeltme:** İKİ AYRI dosyaya (`http_client.zig`nin `copyHeaders`ı,
`http_server.zig`nin `retainHeaders`ı) BAĞIMSIZ birer `containsCrOrLf`
denetimi eklendi — HER build modunda ÇALIŞAN GERÇEK bir `if` kontrolü
(assert DEĞİL). Bir başlık CR/LF İÇERİYORSA `error.InvalidHeaderValue`
döner:
- **İstemci yolu (`doRequest`):** İSTEĞİN TAMAMI reddedilir (`null`
  döner) — `url_copy`/gövde kopyalama başarısızlığıyla AYNI "temizle,
  `null` dön" deseni.
- **Sunucu yolu (`nox_http_response_new`):** YANIT TAMAMI reddedilir
  (`null` döner) — `connectionEntry` BUNU ZATEN, `gpa.create` OOM'uyla
  AYNI, GÜVENLE ele alınan "handler null döndürdü" yoluyla (temiz bir
  500 Internal Server Error'a düşerek) karşılar. `retainHeaders`, HATA
  ANINDA daha ÖNCE `retain` edilmiş başlıkları (bkz. `errdefer`) DOĞRU
  şekilde `nox_str_release` İLE geri alır — aksi hâlde kalıcı bir
  refcount sızıntısı olurdu.

**Bilinçli tasarım kararı:** bozuk başlık SESSİZCE ATLANMAZ (yalnızca O
başlığı düşürüp devam etmek yerine) — İSTEĞİN/YANITIN TAMAMI reddedilir.
Bu, kullanıcının GÖNDERDİĞİNİ SANDIĞI güvenlik-ilgili bir başlığın (ör.
`Authorization`) fark ettirmeden sessizce kaybolmasını ÖNLER.

6 yeni Zig unit testi (3 istemci + 3 sunucu — CRLF'li DEĞER, CRLF'li
AD, VE normal başlıklarda yanlış-pozitif OLMADIĞININ doğrulanması) +
break→red→fix İLE doğrulandı (`containsCrOrLf` devre dışı bırakılınca
HER İKİ TARAFTA da test doğru şekilde KIRMIZI oldu — istemci tarafında
`InvalidHeaderValue` BEKLENİRKEN ham CRLF baytları GERİ GELDİ, sunucu
tarafında `null` BEKLENİRKEN GERÇEK bir yanıt tutamacı GERİ GELDİ).
`ReleaseFast`te de AYRICA doğrulandı (ÖNCEKİ `assert`in TAM OLARAK
BURADA devre dışı KALDIĞI mod) — TÜM 6 test ORADA da geçti.

### KK.5 (TAMAMLANDI) — M-3: `dict[K,V]`nin hash tohumu artık rastgeleleştirilmiş (hash-flooding'e karşı)

**Önceki durum:** `runtime/collections/dict.zig`nin `StrOrIntContext.hash`i
`std.hash.Wyhash`i HER ZAMAN SABİT `seed=0` İLE çağırıyordu.
`SMALL_MAP_THRESHOLD` (8) AŞILDIĞINDA `str` anahtarlı bir dict doğrusal
taramadan hash-tabanlı `index` yoluna GEÇİYOR — VE `nox.http`nin
`HttpRequest.headers` alanı TAM OLARAK `dict[str,str]`. Bu SABİT/BİLİNEN
tohum, Wyhash algoritmasını VE tohumu BİLEN bir saldırganın 8'den fazla
başlık göndererek ÖNCEDEN çakışan anahtar kümeleri İNŞA ETMESİNE — bir
Nox HTTP sunucusunun dict işlemlerini O(1) ortalamadan O(n) en-kötü-
duruma düşürmesine (klasik hash-flooding/algoritmik-karmaşıklık DoS'u,
Python/Rust'ın hashmap tohumunu SÜREÇ başına rastgeleleştirmesinin TAM
OLARAK önlediği saldırı sınıfı) — OLANAK TANIYORDU.

**Düzeltme:** `hashSeed()` YENİ bir yardımcı — `nox.random`nin `g_prng`si
İLE AYNI "gerçek OS iş parçacıkları PAYLAŞMAZ" gerekçesiyle (bir `Dict`,
`arc_owner_tid`nin ZATEN zorladığı gibi HER ZAMAN TEK bir iş parçacığına
aittir) `threadlocal` bir tohumu, İLK dict-hash işleminde BİR KEZ üretip
o iş parçacığının TÜM sonraki dict işlemleri İçin YENİDEN KULLANIR.
`std.crypto.random` BU Zig sürümünde OLMADIĞINDAN, `nox.os`nin `setenv`
deneyimindeki AYNI desenle (bkz. §3.69'un III.5'i), macOS'un libc'sinin
ZATEN GÜVENLE bağladığı ham `std.c.arc4random_buf`ı DOĞRUDAN kullanılır.

**Kapsam DIŞI (bilinçli):** entropi KALİTESİNİN (OS'un `arc4random_buf`
uygulamasının KENDİSİ) doğruluğu bu düzeltmenin sorumluluğu DEĞİLDİR —
yalnızca ÖNCEKİ sabit/bilinen tohumun YERİNE ÇALIŞMA-ZAMANINDA
öngörülemez bir tohum konması hedeflenmiştir.

2 yeni Zig unit testi (`hashSeed`in sabit `0` DÖNMEDİĞİ VE AYNI iş
parçacığı İçinde TUTARLI/memoized OLDUĞU; rastgeleleştirilmiş tohumla
`SMALL_MAP_THRESHOLD` ÜSTÜ bir dict'in HÂLÂ doğru arama yaptığı —
yalnızca MEKANİZMA değişti, DOĞRULUK DEĞİŞMEDİ) + break→red→fix İLE
doğrulandı.

**Faz KK'nin orta-öncelikli bulguları (M-1/M-3) TAMAMLANDI.** Kalan
orta bulgular (M-4 ilâ M-8) İçin ayrı alt-fazlar DEVAM EDECEK.

### KK.6 (TAMAMLANDI) — M-4/M-5/M-6: `nox.crypto`ya HMAC + zaman-sabit karşılaştırma + güvenli rastgelelik eklendi, `sha1`e uyarı düşüldü

**Önceki durum:** stdlib'de (a) mesaj bütünlüğü/DOĞRULAMASI İçin bir HMAC
ilkeli, (b) belirteç/parola-özeti KARŞILAŞTIRMASI İçin zaman-sabit bir
alternatif, (c) GÜVENLİ (kriptografik) bir rastgelelik kaynağı YOKTU —
BUNLARA ihtiyaç duyan bir kullanıcı ya `==`/`nox.random`ı YANLIŞ bağlamda
kullanıyordu (zamanlama yan-kanalı riski/tahmin edilebilir tohum) ya da
KENDİ (muhtemelen hatalı) çözümünü yazıyordu. AYRICA `nox.crypto.sha1`
(çakışma-KIRIK, SHAttered 2017) hiçbir zayıflık UYARISI OLMADAN, `sha256`/
`sha512` İLE TAMAMEN eş düzeyde "sıradan" bir seçenek olarak sunuluyordu.

**Düzeltme:** ÜÇÜ de Zig'in KENDİ, savaş-test edilmiş ilkelidir —
sıfırdan YAZILMAZ (`sha256`nin AYNI ilkesi):
- **`hmac_sha256(key, data) -> str`** — `std.crypto.auth.hmac.sha2.
  HmacSha256`. `sha256`nin AKSİNE paylaşılan bir GİZLİ anahtar gerektirir
  (saldırgan anahtarı BİLMEDEN geçerli bir MAC üretemez), bu YÜZDEN mesaj
  bütünlüğü/kimlik DOĞRULAMASI İçin GÜVENLİDİR.
- **`constant_time_eq(a, b) -> bool`** — Python'un `hmac.compare_digest`i/
  Django'nun `constant_time_compare`ıyla AYNI standart teknik (uzunluk
  farklıysa HEMEN `false`, aksi halde TÜM baytlar erken-çıkış OLMADAN
  XOR'lanıp BİRİKTİRİLİR) — bir belirteç/HMAC/parola-özeti karşılaştırması
  yaparken `==`in (bkz. M-6, `strcmp`-tabanlı ilk-fark-DUR) zamanlama
  yan-kanalını ÖNLER.
- **`secure_random_hex(n_bytes) -> str`** — `nox.dict`nin hash tohumuyla
  (bkz. M-3) AYNI `std.c.arc4random_buf` (macOS'un OS-düzeyi GÜVENLİ
  rastgelelik kaynağı, `std.crypto.random` BU Zig sürümünde YOK). Oturum
  belirteci/CSRF token/API anahtarı gibi GÜVENLİK-İLGİLİ rastgelelik İçin
  `nox.random`nin (BİLİNÇLİ OLARAK kriptografik iddiası TAŞIMAYAN) YERİNE
  KULLANILMALIDIR. `n_bytes` 256'yı AŞARSA sessizce KIRPILIR (v1
  basitleştirmesi, GERÇEKÇİ HERHANGİ bir token büyüklüğünün ÇOK ÜSTÜNDE).
- **`sha1`in belge notuna** (`stdlib/nox/crypto.nox`) AÇIK bir GÜVENLİK
  UYARISI eklendi: bütünlük/imza DOĞRULAMASI İçin KULLANILMAMALI,
  `sha256`/`sha512`/`hmac_sha256` TERCİH EDİLMELİ.

5 yeni Zig unit testi (`hmac_sha256` — RFC 4231/2202'nin bilinen "Jefe"
vektörü + farklı anahtarın farklı MAC üretmesi; `constant_time_eq` —
eşit/farklı/farklı-uzunluk; `secure_random_hex` — doğru uzunluk +
deterministik OLMAMA + `n=0` kenar durumu) + break→red→fix İLE
doğrulandı (ÜÇÜ de AYRI AYRI sabotajlanıp doğru şekilde KIRMIZI olduğu
GÖRÜLDÜ) + 1 yeni golden test.

### KK.7 (TAMAMLANDI) — M-8: Paket yöneticisinin repo URL şema doğrulaması artık AÇIK bir izin listesi kullanıyor

**Önceki durum:** `compiler/pkg/fetch.zig`nin `resolveCloneUrl`ı, `"://"`
alt dizesini İÇEREN HERHANGİ bir `repo` değerini (yalnızca ÖNEK olarak
DEĞİL, `std.mem.indexOf` İLE — dizenin HERHANGİ bir YERİNDE) "zaten
şemalı bir URL" sayıp `git clone`a OLDUĞU GİBİ geçiriyordu. `nox.json`nin
`requires[].repo` alanı (paylaşılan/üçüncü-taraf bir manifest üzerinden)
saldırgan etkisindeyse, ör. `"ext::sh -c 'kötücül komut' #://"` gibi bir
değer "://" İÇERDİĞİNDEN (sondaki YORUM-benzeri son ek İÇİNDE)
DOKUNULMADAN `git clone`a geçirilirdi — git'in `ext::` transport
yardımcısı (ETKİNLEŞTİRİLMİŞSE) KEYFİ komut YÜRÜTEBİLİRDİ. Git'in KENDİ
`protocol.ext.allow` varsayılanı bunu BUGÜN azaltıyor (Nox'un KENDİ
güvencesi DEĞİL, dış/güvenilemez bir şans).

**Düzeltme:** `resolveCloneUrl`, `"://"` İÇEREN bir `repo`yu ARTIK
yalnızca AÇIK bir İZİN LİSTESİNDEKİ (`https://`/`http://`/`git://`/
`ssh://`/`file://` — SONUNCUSU, testlerin/yerel geliştirmenin YEREL
fixture repo'ları İÇİN BİLİNÇLİ olarak KORUNDU) bir ÖNEKLE (`startsWith`,
`indexOf` DEĞİL) BAŞLIYORSA kabul ediyor — aksi halde `error.
UnsupportedRepoScheme` döner, `git`e HİÇ ULAŞMADAN. `ext::` DAHİL başka
HİÇBİR transport artık KABUL EDİLMEZ.

2 yeni Zig unit testi (`tests/unit/fetch_test.zig` — gizlenmiş bir
`ext::` şemasının REDDEDİLDİĞİ VE (bir işaretçi dosyanın GERÇEKTEN
OLUŞMADIĞI doğrulanarak) `git`in HİÇ ÇALIŞTIRILMADIĞI; izin listesindeki
BEŞ şemanın (`file://` DAHİL) DOKUNULMADAN kabul edildiği VE GERÇEKTEN
getirebilidiği) + break→red→fix İLE doğrulandı (izin listesi kaldırılınca
sabotajlı `ext::` değeri `git clone`a ULAŞTI — `error.GitCommandFailed`
İLE, yalnızca git'in KENDİ varsayılan reddiyle BAŞARISIZ oldu, TAM OLARAK
düzeltmenin ORTADAN KALDIRDIĞI kırılgan güvenlik ağı).

**Faz KK (H-1/H-2/H-3/M-1/M-3/M-4/M-5/M-6/M-8) TAMAMLANDI** — güvenlik
raporunun ÜÇ yüksek VE ALTI orta öncelikli bulgusunun TÜMÜ düzeltildi.
Kalan M-2 (gerçek bir `bytes` tipi) VE M-7 (parola saklama için yavaş/
bellek-zor bir KDF — argon2/scrypt/bcrypt) BİLİNÇLİ olarak UZUN VADEYE
bırakıldı — Faz III planının kapsam-dışı 5 maddesiyle AYNI büyüklükte,
kendi tasarım turunu (kütüphane seçimi, API yüzeyi) gerektiren birer iş
(bkz. §3.69'un giriş notu).

## 3.71 Faz LL — Windows desteği

Kullanıcı README güncellemesi sırasında Windows İçin de bir kurulum
betiği istedi. Araştırma SIRASINDA `runtime/async_rt/io_reactor.zig`nin
dosya-seviyesi bir `comptime { if (... != .macos and ... != .linux)
@compileError(...) }` bloğu (io_reactor.zig:69-73) TAŞIDIĞI bulundu —
yani Windows'ta ne `noxc` İLE derlenen Nox PROGRAMLARI (`noxrt.o`
üzerinden) ne de `nox.thread`/`spawn`/`await`/`nox.http` ÇALIŞABİLİYOR.
Kullanıcıya bu mimari engel açıklanıp kapsam SORULDU (AskUserQuestion) —
kullanıcı **GERÇEK Windows desteğinin ŞİMDİ başlatılmasını** seçti,
yalnızca bir kurulum betiği DEĞİL.

### Mimari bulgular (3 paralel Explore ajanı + bir web araştırmasıyla)

- **QBE 1.3 GERÇEKTEN `amd64_win` hedefini destekliyor** (upstream,
  Scott Graham katkısı, TLS HARİÇ TAM ABI/C-interop) —
  `compiler/qbe_target.zig:29`deki `"amd64_win"` aspirasyonel DEĞİL,
  gerçek. QBE'nin ürettiği AT&T sözdizimli assembly'yi **MinGW'in
  assembler'ı** en iyi derliyor — yani Windows'ta `cc` olarak
  **MinGW-w64 GCC** hedeflenmeli, MSVC (`cl.exe`/`link.exe`) DEĞİL. Bu,
  `compiler/main.zig`nin MEVCUT GCC-tarzı `cc` çağrısını (`-o`, `-lm`,
  `-rdynamic`, `.o`/`.a` uzantıları) neredeyse DEĞİŞTİRMEDEN kullanılabilir
  kılıyor.
- **`noxc`/`noxlsp` (derleyicinin KENDİSİ) HİÇBİR POSIX-özgü çağrı
  İÇERMİYOR** — `compiler/` ağacında `std.posix.*`/`std.c.*` KULLANIMI
  SIFIR (doğrulandı: `grep -rln` boş döndü). TÜM Windows engeli
  `runtime/` (yani `noxrt.o`) İÇİNDE: `io_reactor.zig` (kqueue/epoll),
  `fiber.zig` (x86-64 bağlam değişimi SysV ABI'sine göre yazılmış el-
  yazması assembly, Windows x64'ün FARKLI çağrı kuralı İçin AYRI bir
  `.S` varyantı gerekir), `stdlib_shims/{os,fs,time,path}.zig` +
  `dict.zig`/`crypto.zig` (POSIX `setenv`/`getcwd`/`stat`/`opendir`/
  `clock_gettime`/`arc4random_buf`/`realpath`), VE soket katmanı
  (`io.zig`/`http_server.zig`/`http_client.zig`/`thread_bridge.zig`/
  `thread_channel.zig` — ham `socket`/`accept`/`pipe`, Winsock'a
  taşınmalı).
- Bu ortamda GERÇEK bir Windows/Wine makinesi YOK — bu yüzden riskli
  runtime portu (IOCP reaktörü, Windows fiber assembly'si, Winsock
  katmanı) yazılmadan ÖNCE GERÇEK bir `windows-latest` GitHub Actions
  çalıştırıcısı KURULDU (LL.1) — sonraki TÜM alt-fazlara GERÇEK,
  yalnızca çapraz-derlenen DEĞİL, ÇALIŞTIRILAN bir geri bildirim döngüsü
  sağlaması İçin.

### Yol haritası

LL.1 (TAMAMLANDI, aşağıya bkz.), LL.2 (`io_reactor.zig`ye GERÇEK bir
Windows backend'i — planın ADI "IOCP" idi, AMA LL.2'nin KENDİSİ SIRASINDA
bilinçli olarak `WSAPoll`a GEÇİLDİ, bkz. aşağıdaki gerekçe), LL.3
(`fiber.zig` İçin Windows x64 `.S` varyantı — LL.2 İLE AYNI pasoda
yapıldı, bkz. gerekçe), LL.4 (`stdlib_shims`nin POSIX çağrılarının
Windows karşılıklarına portu), LL.5 (soket katmanı — Winsock + self-
pipe'ın loopback-soket emülasyonu), LL.6 (araç zinciri — MinGW-w64
doğrulaması + CI'de QBE'nin onunla derlenmesi), LL.7 (`release.yml` +
`install.ps1`), LL.8 (README/AGENTS.md'nin GÜNCELLENMESİ). LL.4-LL.8
kendi başlarına BÜYÜK, çok-commit'li alt-fazlar — HER biri GERÇEK
Windows CI sonucuyla doğrulanmadan bir SONRAKİne geçilmeyecek.

### LL.1 (TAMAMLANDI) — Derleyici ön-ucu + Windows CI iskeleti

`build.zig`ye, `noxrt_mod`/`compile_swap_asm`dan (dolayısıyla
`io_reactor.zig`nin `@compileError`ından) TAMAMEN BAĞIMSIZ iki YENİ
adım eklendi:
- `zig build noxc` — yalnızca `noxc`/`noxlsp`yi VE (`noxc check`in
  `core.nox`u module_loader üzerinden ÇÖZMESİ İçin GEREKEN) `stdlib/`i
  kurar.
- `zig build frontend-test` — yalnızca `compiler/lib.zig`nin (lexer/
  parser/checker/module_loader) MEVCUT `lib_test`ini çalıştırır.

Mevcut `install`/`test`/`run`/`bench` adımları VE bunların `noxrt`e
bağımlılıkları HİÇ DEĞİŞMEDİ — yalnızca İZOLE, EK adımlar eklendi (yerel
olarak `zig build noxc` + `zig build frontend-test` + TAM `zig build
test` paketinin (Debug/ReleaseSafe/ReleaseFast) HÂLÂ yeşil olduğu
doğrulandı — sıfır regresyon).

`.github/workflows/ci.yml`ye, mevcut 3-platform matrisinin YANINA (İÇİNE
DEĞİL) AYRI bir `windows-frontend` işi eklendi: `windows-latest`
çalıştırıcısında Zig 0.16.0'ı PowerShell İLE kurar (`zig-x86_64-
windows-0.16.0.zip`, `ziglang.org/download/...`den — mevcut Linux/macOS
işlerinin AYNI "mlugg/setup-zig KULLANILMAZ" gerekçesiyle), `zig build
noxc` + `zig build frontend-test`i çalıştırır, VE bir duman testiyle
(`noxc.exe check` gerçek bir `.nox` dosyasına karşı) derleyicinin
GERÇEKTEN native Windows'ta ÇALIŞTIĞINI doğrular. `qbe`/`cc` bu işte
KURULMAZ — runtime-bağımlı `build`/`test` adımları BU FAZIN kapsamı
DIŞINDA.

**Önemli sınırlama:** bu, GENEL Windows desteği DEĞİL — yalnızca
derleyici ÖN-UCUNUN (tip denetim/parse) native Windows'ta çalıştığını
kanıtlar. `noxc build`/`run` (runtime'a bağlanma GEREKTİRDİĞİNDEN) VE
HER TÜRLÜ Nox PROGRAMI HÂLÂ Windows'ta ÇALIŞMAZ. README'nin "Windows
henüz desteklenmiyor" notu BU YÜZDEN BU FAZDA DEĞİŞTİRİLMEDİ — LL.7/LL.8
tamamlanana kadar doğru kalmaya devam ediyor.

**GERÇEK `windows-latest` CI çalıştırmasıyla BULUNAN VE düzeltilen 3
gerçek hata** (kanıt: bu ortamda Windows/Wine makinesi olmadığından bu
üçü SADECE gerçek CI ile bulunabilirdi, yerel çapraz-derleme yeterli
DEĞİLDİ):
1. `compiler/main.zig`nin argüman ayrıştırması `Args.Iterator.iterate()`
   kullanıyordu — Zig std'de bu Windows'ta `@compileError` veriyor
   ("use initAllocator instead"). `iterateAllocator`e geçirildi;
   macOS/Linux'ta (Zig std'nin KENDİ `Posix` dalı) DAVRANIŞ BİREBİR AYNI
   kaldığı doğrulandı.
2. `.gitattributes` HİÇ YOKTU — `windows-latest`nin `core.autocrlf=true`
   VARSAYILANI, checkout SIRASINDA HER `.nox`/`.zig` dosyasını SESSİZCE
   CRLF'ye çeviriyordu; Nox'un lexer'ı (`compiler/lexer/lexer.zig`) `\r`
   baytını HİÇ TANIMADIĞINDAN, `stdlib/nox/core.nox` (HER programa
   otomatik birleştirilir) DAHİL her dosya `UnexpectedCharacter` İLE
   patlıyordu. Kök dizine `* text=auto eol=lf` İÇEREN bir
   `.gitattributes` eklenerek düzeltildi — derleyiciye/lexer'a HİÇ
   dokunulmadı, saf bir repo-checkout tutarlılığı düzeltmesi.
   **Bilinçli olarak AÇIK bırakılan takip sorusu:** bu, checkout
   SIRASINDAKİ CRLF'yi önler, ama GERÇEK bir Windows kullanıcısının
   KENDİ editörüyle (Not Defteri/VS Code Windows varsayılanı) native
   CRLF İLE yazdığı bir `.nox` dosyası HÂLÂ aynı `UnexpectedCharacter`a
   çarpar — lexer'ın KENDİSİNİN `\r`ye tolerans göstermesi (`\r\n`yi
   `\n` gibi ele alması) AYRI, kendi test turunu gerektiren bir iş
   (LL.4'ün stdlib-shim portu İLE AYNI pasoda mı ele alınacağı, yoksa
   AYRI bir "LL.1b" mi olacağı HENÜZ kararlaştırılmadı).
3. Windows CI'sinin PowerShell duman testinde `` `n `` kaçış dizisi
   beklenmedik davrandı (Set-Content'in İÇ kodlama/kaçış etkileşimi) —
   tek satırlık, satır sonu GEREKTİRMEYEN bir `.nox` içeriğine
   (`"print(1)"`, `-NoNewline`) geçilerek belirsizlik TAMAMEN ortadan
   kaldırıldı.

**Ayrıca, BU fazın araştırması SIRASINDA, Windows'la İLGİSİZ, ÖNCEDEN
VAR OLAN bir Linux CI regresyonu keşfedildi** (bkz. iki ayrı CI
çalıştırmasında BİREBİR aynı hatayla doğrulandı, benim değişikliklerimle
İLGİSİZ): bu Zig 0.16.0 derlemesinde `std.c.fstat`, `.linux => {}` İLE
(gerçek bir libc sembolüne BAĞLANMADAN, `void` olarak) tanımlı —
`runtime/stdlib_shims/fs.zig`nin (Faz III.3) `std.c.fstat` KULLANIMI bu
YÜZDEN Linux'ta (x86-64 VE aarch64) `noxrt.o`nun HİÇ DERLENEMEMESİNE yol
açıyor; macOS'ta ETKİLENMİYOR (gerçek bir INODE64 sembolü VAR).
**DÜZELTİLDİ** (kullanıcı talebiyle, ayrı bir takip adımı olarak) —
**iki denemede:** İLK deneme `std.c.fstatat`e geçmekti (`.linux` dalının
BU switch'te ÖZEL ele alınmadığı varsayımıyla) — AMA GERÇEK CI'de bu DA
`.linux => {}` OLARAK tanımlı çıktı (AYNI "boş" desen `fstatat` İçin de
tekrarlanmış — canlı bir CI çalıştırmasıyla SOMUT olarak yakalandı, ilk
varsayım YANLIŞ çıktı). Kalıcı düzeltme: `std.c.statx` — AYNI dosyada
switch'e HİÇ GİRMEYEN, KOŞULSUZ bir `extern "c" fn statx(...)` bildirimi
— bu YÜZDEN GERÇEK bir glibc sembolüne HER ZAMAN bağlı. YENİ
`fstatCompat`, Linux'ta `statx(fd, "", AT.EMPTY_PATH, {SIZE,MTIME}, &buf)`
çağırıp sonucu platform-nötr bir `FileInfo{size, mtime_sec, mtime_nsec}`e
çevirir; diğer platformlarda (`std.c.fstat` zaten ÇALIŞTIĞINDAN)
dokunulmadan `std.c.fstat`i çağırıp AYNI `FileInfo`ye çevirir — İKİ
çağrı-yeri de (`nox_fs_read_to_string_raw`/`nox_fs_stat_raw`) bu ORTAK
arayüze taşındı. Yerel olarak (macOS, etkilenmeyen dal)
Debug/ReleaseSafe/ReleaseFast'te doğrulandı; Linux'taki GERÇEK doğrulama
(bu ortamda GERÇEK bir Linux makinesi OLMADIĞINDAN, Windows LL.1 İLE
AYNI "push + gerçek CI'yi izle" yöntemiyle, İKİ denemede) yapıldı — bu,
"yerel olarak doğrulanamayan platform-özgü kodun BİREBİR AYNI çapraz-
derleme varsayımıyla İKİ KEZ yanılabileceği" somut bir hatırlatma
(bkz. LL.1'in "gerçek CI olmadan riskli platform kodu YAZILMAZ" ilkesi
— TAM OLARAK bu YÜZDEN vardı).

`fstatCompat` düzeltmesi noxrt.o'yu Linux'ta DERLENEBİLİR kıldıktan
SONRA, GERÇEK CI'de İKİ AYRI, ÖNCEDEN VAR OLAN (Windows'la VE
`fstatCompat`la İLGİSİZ) test hatası daha ORTAYA ÇIKTI: `runtime/
stdlib_shims/path.zig`nin Faz III.4 testi VE `tests/golden/
codegen_cases/path_new_operations`, `nox.path.canonicalize("/tmp/../
tmp")`nin macOS'a ÖZGÜ `/tmp → /private/tmp` sembolik-link çözümünü
SABİT bir beklenti olarak taşıyordu — Linux'ta `/tmp` GERÇEK bir
dizin OLDUĞUNDAN (sembolik link DEĞİL) beklenen `/private/tmp`
YERİNE GERÇEK `/tmp` dönüyordu. Zig birim testi `builtin.os.tag`e
göre platform-koşullu beklenen değere geçirilerek (sembolik-link-
çözme kanıtı KORUNARAK) düzeltildi; golden test İSE (statik bir
`.expected` dosyasıyla karşılaştırdığından platform-koşullu OLAMAZ)
`/tmp/../tmp` yerine HİÇBİR platformda sembolik link OLMAYAN
`/usr/../usr`ya geçirildi (`.`/`..` çözme + var-olmayan-yol hata
davranışı KAPSAMI DEĞİŞMEDİ, yalnızca sembolik-link-özel iddia BU
golden testten ÇIKARILDI — o iddia ZATEN Zig biriminde AYRICA
kanıtlanıyor). GERÇEK CI'de doğrulandı.

**Lexer'ın KENDİSİNİN `\r\n`ye tolerans göstermesi** (kullanıcı
talebiyle, LL.1'in "bilinçli AÇIK bırakılan takip sorusu" notunun
kapatılması): `.gitattributes` düzeltmesi yalnızca BU REPO'nun KENDİ
dosyalarının checkout'unu kapsar — GERÇEK bir Windows kullanıcısının
KENDİ editörüyle (Not Defteri/VS Code'un Windows varsayılanı) yazdığı
bir `.nox` dosyası HÂLÂ native CRLF taşır. `compiler/lexer/lexer.zig`
HİÇBİR `\r` işleme İÇERMİYORDU — ana döngüde `\r`, hiçbir dala
UYMADIĞINDAN dosdoğru `error.UnexpectedCharacter`e düşüyordu. Üç ayrı
noktada düzeltildi: (1) girinti-tarama bloğunun "boş satır" kontrolü
`\r`yi de `\n`/`#` İLE AYNI şekilde TANIR; (2) ana döngüye `\r`yi HER
ZAMAN (tek başına YA DA `\n`den ÖNCE) sessizce ATLAYAN bir dal eklendi
— `\n`in KENDİSİ (satır sayacı/NEWLINE token'ı) HİÇ DEĞİŞMEDEN MEVCUT
yolu izler; (3) ters-eğik-çizgi satır-devamı kontrolüne `\r\n` varyantı
eklendi. Üçü de `lexer.zig`ye 3 YENİ birim testiyle (if/indent bloğu,
yorum/boş-satır, satır-devamı — ÜÇÜ de AÇIKÇA `\r\n` baytlı dize
birleştirmesiyle inşa edilmiş, Zig'in çok-satırlı `\\` string
sözdiziminin yalnızca LF ekleyebilmesi YÜZÜNDEN) doğrulandı — kasıtlı
boz→kırmızı ritüeliyle (yeni `\r`-atlama dalı geçici olarak `if (false
and ...)` yapıldı) ÜÇÜNÜN de BEKLENEN `UnexpectedCharacter`la
BAŞARISIZ olduğu, ardından byte-birebir restore SONRASI TEKRAR yeşile
döndüğü doğrulandı. Yerel olarak (macOS) Debug/ReleaseSafe/ReleaseFast'te
TAM paket doğrulandı — bu değişiklik ZATEN platform-nötr Zig mantığı
OLDUĞUNDAN (hiçbir `std.c`/`builtin.os.tag` dallanması YOK), Windows
CI'de AYRICA doğrulanmasına GEREK yoktu.

### LL.2/LL.3 (TAMAMLANDI) — `io_reactor.zig` Windows backend'i + fiber assembly'si (BİRLİKTE yapıldı)

**Neden BİRLİKTE:** Zig'in test toplama modeli, `io_reactor.zig`yi test
ederken `fiber.zig`yi (`@import` yoluyla) transitively İÇERİR — `fiber.
zig`nin KENDİ testleri (`nox_swap_context` linki GEREKTİRİR) bu YÜZDEN
io_reactor'ı İZOLE test etmeyi bile İMKANSIZ kılar. İkisi AYRI
doğrulanamadığından, AYRI yazılmaları da ANLAMSIZDI — TEK pasoda
yazılıp TEK CI turunda doğrulandı.

**Bilinçli tasarım kararı — GERÇEK IOCP DEĞİL, `WSAPoll`:** planın ADI
"IOCP backend'i" idi, ama IOCP'nin KENDİSİ tamamlama-tabanlıdır (bir
okuma/yazmayı BAŞLATIP BİTTİĞİNDE haber alırsınız) — kqueue/epoll'un
(VE bu reaktörün TÜM çağıranlarının, `io.zig`nin `nonBlockingRead/
Write` deseninin) VARSAYDIĞI "hazır-olma bildirimi, okuma/yazmayı KENDİN
yap" modeliyle YAPISAL olarak UYUŞMAZ — IOCP'ye GEÇMEK `http_server.
zig`/`http_client.zig`nin TÜM G/Ç çağrılarının OVERLAPPED işlemlere
YENİDEN yazılmasını gerektirirdi (LL.5'in kapsamını KATLARDI). `WSAPoll`
İSE (POSIX `poll()`e daha yakın, Windows Vista'dan beri VAR) AYNI hazır-
olma sözleşmesini sağladığından `scheduler.zig`/`io.zig` HİÇBİR platform
dallanması GEREKTİRMEDEN çalışmaya devam eder.

**`WindowsReactor` mimarisi:** kqueue/epoll'un AKSİNE `WSAPoll` bir
"interest listesi" TUTMAZ — HER çağrıda TAM bir fd dizisi + TEK ortak
zaman aşımı alır. `WindowsReactor` bu YÜZDEN bekleyen TÜM `WaitCtx`leri
KENDİSİ bir listede (`pending`) tutar, her `poll()` turunda TAZE bir
`WSAPOLLFD` dizisi kurar, TÜM zaman-aşımlı bekleyişler arasındaki EN
YAKIN mutlak bitiş zamanını (`WaitCtx`e YENİ eklenen `deadline_ms`,
`QueryPerformanceCounter` tabanlı monotonik ms) TEK zaman aşımı olarak
geçirir. Zig'in bu sürümünün `std.os.windows.ws2_32`si `WSAStartup`/
`WSAPoll`i BAĞLAMADIĞINDAN (yalnızca birkaç struct/sabit VAR), bunlar
+ `QueryPerformanceCounter/Frequency` ELLE (`extern "ws2_32"`/`extern
"kernel32"`) bildirildi — Win32 ABI'si bu fonksiyonlar İçin Windows
2000'den beri DEĞİŞMEDİĞİNDEN düşük riskli. `WaitCtx.target_fd`/
`timer_fd`nin varsayılan değeri `-1`den `undefined`e çevrildi — `posix.
fd_t` Windows'ta bir İŞARETÇİ (`HANDLE`) olduğundan `-1` TÜM platformlarda
tip-uyumlu TEK bir sabit DEĞİLDİ (bu alanlar HER ZAMAN okunmadan ÖNCE
açıkça atandığından davranış DEĞİŞMEDİ).

**Fiber assembly'si (`swap_x86_64.S`):** Win64 çağrı kuralı SysV'den İKİ
yönden FARKLI — (1) callee-saved GPR kümesi FARKLI (Win64'te rdi/rsi DE
çağrı-korumalı, SysV'de İKİSİ de çağıran-korumalı), (2) Win64'te XMM6-15
ÇAĞRI-KORUMALIDIR (SysV'nin TÜM XMM'i çağıran-korumalı saydığı ve BU
YÜZDEN hiç KAYDETMEDİĞİ varsayımının AKSİNE) — bu YÜZDEN Windows dalı
XMM6-15'i (160 bayt, `movdqu`) DE kaydeder, aksi halde bir fiber-değişimi
SIRASINDA canlı bir kayan-noktalı değer SESSİZCE bozulabilirdi. AYNI
`.S` dosyasına `#if defined(_WIN32)` İLE eklendi (build.zig'in dosya-
seçme mantığı DEĞİŞMEDİ — `cc` zaten HANGİ platformda çalışıyorsa O
platformun ABI'sini varsayılan olarak üretir, `_WIN32` MinGW cc
TARAFINDAN otomatik tanımlanır). `fiber.zig`nin `createWithStack`ı,
Windows İçin 232 baytlık (160 xmm + 8×8 gpr + 8 dönüş adresi) SAHTE
İLK çerçeveyi ELLE yazan AYRI bir dal kazandı — `rbx`, SysV dalıyla
AYNI "kaçak self işaretçisi" hilesini taşır (`trampoline` platform-
bağımsız, yalnızca rbx okur, değişmedi).

**Doğrulama — İZOLE bir CI hedefi ile:** `fiber_test`/`scheduler_test`/
`channel_test`/`io_test` (build.zig'de ZATEN VAR olan, `runtime/
stdlib_shims`e (os/fs/http gibi HENÜZ Windows'a taşınmamış dosyalara)
HİÇ bağımlı OLMAYAN, yalnızca `swap_asm_o_path`e bağımlı standalone
test hedefleri) YENİ bir `zig build async-rt-test` adımına toplandı —
bu, TÜM `noxrt`in (dolayısıyla TÜM stdlib_shims portunun) BEKLENMESİNE
GEREK KALMADAN, YALNIZCA fiber/reaktör/zamanlayıcı katmanının GERÇEKTEN
native Windows'ta çalıştığını doğrular. `windows-frontend` CI işine
eklendi (`cc`/`gcc`nin `windows-latest`te VARSAYILAN olarak `C:\
mingw64\bin` altında PATH'te BULUNDUĞU AYRI bir keşif adımıyla ÖNCEDEN
doğrulanmıştı). Test yardımcıları da platform-nötr hale getirildi:
`std.c.socketpair(AF.UNIX,...)` Windows'ta YOK (`.windows => {}`) — YENİ
bir UDP-loopback ÇİFTİ (`WindowsReactor.makeLoopbackPair`) VE `send`/
`recv`/`closesocket` sarmalayıcıları (CRT'nin `read`/`write`/`close`si
ham Winsock `SOCKET`leri İÇİN GEÇERSİZDİR) eklendi. Yerel olarak (macOS,
etkilenmeyen dal) Debug/ReleaseSafe/ReleaseFast'te doğrulandı.

**GERÇEK Windows CI'de İLK denemede 2 gerçek hata bulundu, İKİNCİ
denemede TÜMÜ yeşil:**
1. Sahte çerçeve boyutu 232 bayttı — AMA SysV dalının KENDİSİ (56 baytlık
   çerçeve İçin bile `frame_base = stack_top_aligned - 64`, yani 8 bayt
   FAZLA) kasıtlı bir boşluk bırakıyordu, `ret` SONRASI `trampoline`ın
   gördüğü `rsp`nin `stack_top_aligned - 8` (8-mod-16, normal bir
   `call`/`ret` SONRASI beklenen hizalama) OLMASI İçin. `232` kullanınca
   `ret` SONRASI rsp TAM `stack_top_aligned` (16-hizalı, YANLIŞ) oluyordu
   — `fiber`/`scheduler`/`channel` testleri GERÇEK CI'de segfault
   veriyordu. `240`a (232 + AYNI 8 baytlık boşluk) düzeltildi.
2. `io_reactor.zig`nin testleri platform-nötr yapılmıştı, ama `io.zig`nin
   KENDİ testi (`nonBlockingRead`/`Write`i egzersiz eden, `std.c.
   socketpair`/`AF.UNIX` kullanan) atlanmış kalmıştı — bu, LL.5'in
   kapsamındaki soket katmanını (Winsock `recv`/`send`) egzersiz ediyor,
   LL.2/LL.3'ün DEĞİL. `error.SkipZigTest` ile Windows'ta bilinçli
   atlandı.

İKİNCİ CI çalıştırmasında `zig build async-rt-test` TAMAMEN yeşil geçti
— fiber/reaktör/zamanlayıcı katmanı Windows'ta GERÇEKTEN doğrulandı.

### LL.4 (TAMAMLANDI) — `stdlib_shims`nin POSIX çağrılarının Windows karşılıklarına portu

`dict.zig`/`crypto.zig`nin `std.c.arc4random_buf`ı (Linux'un `fstat`i
GİBİ `.windows` İçin de tanımsız/void — `else => {}`) `advapi32.dll`nin
`RtlGenRandom`ine (dışa açık ismi `SystemFunction036`, Windows 2000'den
beri STABİL bir OS-seviyesi CSPRNG) geçirildi. `os.zig`nin `setenv`i
(POSIX) Windows'ta `_putenv_s`e (MinGW CRT'nin ISO-C-uyumlu ismi)
geçirildi; `nox_os_current_dir_raw`nin testi platform-koşullu hale
getirildi (Windows mutlak yolları `/` DEĞİL bir sürücü harfiyle başlar).

**`fs.zig` — en büyük parça:** bu Zig sürümünde `std.c.O` (open bayrak
struct'ı) VE `std.c.Stat` İKİSİ DE Windows İçin `void`dir (`.windows`
dalı HİÇ case'lenmemiş), `std.c.readdir` İSE (`fstat` GİBİ) `.windows =>
{}`. Bu YÜZDEN Windows'ta dosya G/Ç'si TAMAMEN AYRI, ham Win32/MinGW-CRT
ilkelleriyle yeniden yazıldı: `_open`/`_read`/`_write`/`_close` (`_O_
BINARY` HER ZAMAN geçilir — aksi halde VARSAYILAN metin modu `\r\n`↔`\n`
çevirisi YAPIP Nox `str`lerini SESSİZCE bozardı), boyut İçin
`_filelengthi64`, mtime İçin `_get_osfhandle`+`GetFileTime`, dizin
listeleme İçin `FindFirstFileA`/`FindNextFileA`/`FindClose`, "dizin mi"
sorusu İçin (`O_DIRECTORY` Windows'ta OLMADIĞINDAN) `GetFileAttributesA`.
`access`/`rename`/`unlink`/`mkdir`/`rmdir`/`getcwd`/`getpid`/`realpath`/
`clock_gettime`/`nanosleep`/`timespec` İSE (Zig'in KENDİ switch'lerinde
KOŞULSUZ extern'ler/GERÇEK windows-case'leri OLDUĞU doğrulandığından)
DOKUNULMADAN bırakıldı — MinGW-w64'ün KENDİ POSIX-uyumluluk katmanının
(`libwinpthread`) bu sembolleri GERÇEKTEN sağladığı varsayımıyla (`time.
zig`/`path.zig`nin `realpath`i bu YÜZDEN HİÇ değişmedi). TÜM testlerin
SABİT `/tmp` yol varsayımı (Windows'ta `/tmp` YOKTUR) `%TEMP%` ortam
değişkenini okuyan platform-koşullu bir `testTmpPrefix()` yardımcısına
geçirildi. Yerel olarak (macOS, etkilenmeyen dal) Debug/ReleaseSafe/
ReleaseFast'te doğrulandı; Windows'un KENDİSİ (`_O_BINARY`/`FindFirstFileA`/
`GetFileTime` gibi HİÇ yerel test edilemeyen yeni Win32 çağrıları
İÇERDİĞİNDEN) GERÇEK CI'de doğrulanacak.

### LL.4 SONRASI keşif + LL.5 (DEVAM EDİYOR) — tam `zig build`in ortaya çıkardığı kalan hatalar

LL.4 commit'i (fs.zig/os.zig/dict.zig/crypto.zig) GERÇEK Windows CI'ye
gönderilmeden ÖNCE, `ci.yml`ye `continue-on-error: true` İLE TAM
(runtime dahil) bir `zig build` adımı eklendi — `fs.zig`nin `http_
client.zig`e (yalnızca `dupeToNoxStr` İçin) bağımlı OLMASI, LL.4'ü
LL.5'TEN İZOLE test etmeyi İMKANSIZ kıldığından. Bu adım TEK seferde
6 dosyada 15 derleme hatası ortaya çıkardı:

- **`time.zig`**: `std.c.clockid_t` Windows İçin `void` (`fstat`in AYNI
  "switch'te unutulmuş case" deseni) — `clock_gettime`/`nanosleep`
  imzaları BU tipe bağlı OLDUĞUNDAN TAMAMEN kullanılamaz hale geliyor.
  Çözüm: `GetSystemTimePreciseAsFileTime` (duvar-saati, `fs.zig`nin AYNI
  FILETIME→Unix çevirisiyle), `QueryPerformanceCounter`/`Frequency`
  (monotonik, `io_reactor.zig`nin `WindowsReactor.monotonicMs`iyle AYNI
  önbellekleme deseni), `Sleep` (kernel32, ms çözünürlüklü).
- **`io.zig`**: `std.c.fcntl`nin bayrak parametresi tipi (`std.c.F`)
  Windows İçin `void` → `setNonBlocking` `ioctlsocket(fd, FIONBIO, ...)`e
  geçirildi. `nonBlockingAccept`/`Read`/`ReadWithTimeout`/`Write` HER
  BİRİ Winsock'un `WSAGetLastError() == WSAEWOULDBLOCK`ini (POSIX'in
  `errno == EAGAIN`i YERİNE — Winsock hataları `errno` ÜZERİNDEN ASLA
  okunamaz) kontrol eden bir Windows dalı KAZANDI. Bu amaçla `io.zig`ye
  `pub const WinSock` (TÜM extern fn'leri TEK TEK `pub` işaretlenmiş —
  bir kapsayıcı `const`ın `pub`u İÇ `extern fn`lere OTOMATİK YAYILMAZ,
  gerçek bir hata olarak yakalandı) eklendi: `ioctlsocket`/`accept`/
  `recv`/`send`/`socket`/`bind`/`listen`/`connect`/`setsockopt`/
  `getsockname`/`closesocket` — `http_server.zig`/`http_client.zig`
  TARAFINDAN PAYLAŞILAN TEK Winsock kaynağı.
- **`http_server.zig`**: `std.c.setsockopt`/`socket` ailesinin
  `posix.fd_t`(Windows'ta `HANDLE`, bir işaretçi) İLE GERÇEK Winsock
  `SOCKET`(ham tamsayı) arasındaki tutarsızlığı (Zig'in KENDİ Windows
  soket bağlamalarının İÇ tutarsızlığı) ortaya çıkardı. `fdToI64`/
  `i64ToFd` (`@intFromPtr`/`@ptrFromInt` köprüsü), `closeSocket`
  (`closesocket` vs `close`), `socketIsOpen` (`F.GETFD`nin Windows'ta
  `void` olması yüzünden `getsockname` başarısıyla değiştirildi) EKLENDİ;
  `bindAndListen`/`blockingAccept`/`rawRead`/`rawWriteAll`/`testConnect`
  VE testler `io_mod.WinSock` ÜZERİNDEN yeniden yazıldı.
- **`http_client.zig`**: `std.c.pipe`nin Windows'ta HİÇ KARŞILIĞI
  YOKTUR — `workerThreadFn`nin "tamamlanma sinyali" self-pipe'ı
  (`makeSelfPipe`), `io_reactor.zig`nin `WindowsReactor.makeLoopbackPair`
  İLE AYNI teknikle, BAĞLANMIŞ bir UDP-loopback soket ÇİFTİNE çevrildi
  (`closeFd`/`signalSelfPipe`/`readSelfPipe` yardımcılarıyla). Test-özel
  HTTP sunucusu yardımcıları (`testListenerOn127001`/
  `testServeOnceDelayed`) `http_server.zig`nin `bindAndListen`İLE AYNI
  desenle `io_mod.WinSock`e geçirildi; kasıtlı test gecikmesi İçin
  (`nanosleep`nin `clockid_t` sorunundan ETKİLENMEMESİ İçin) `time.zig`nin
  `WinTime.Sleep`iyle AYNI, dosyaya ÖZEL bir `WinSleep.Sleep` KOPYASI
  eklendi (küçük platform yardımcılarının dosya-başına TEKRARLANMASI
  `crypto.zig`/`dict.zig`nin `secureRandomBuf`ıyla TUTARLI, YERLEŞİK bir
  proje kuralı).
- **`std.DynLib` (HPy köprüsü yükleyicisi, `hpy_bridge/loader.zig`):**
  bu Zig sürümünde Windows İçin TAMAMEN desteksiz (`InnerType`nin
  switch'i `.windows`i HİÇ case'lemez, doğrudan `@compileError`) —
  `fstat`/`clockid_t` GİBİ "unutulmuş case" DEĞİL, BİLİNÇLİ bir kapsam
  dışı bırakma. Çözüm: `std.DynLib`nin `open`/`lookup`/`close`
  arayüzünü Windows'ta `LoadLibraryA`/`GetProcAddress`/`FreeLibrary`
  (kernel32) ÜZERİNDEN yeniden uygulayan bir `NoxDynLib` sarmalayıcısı
  (diğer platformlarda DOĞRUDAN `std.DynLib`ye delege eder) —
  `LoadedModule.lib`in tipi BUNA geçirildi.
- **`std.c.dlopen(null, RTLD_NOW)` deseni (`json.zig`nin `resolveMake
  JsonValue`ı VE `cycle_detector.zig`nin PAYLAŞILAN `resolveSymbol`ı —
  ikisi de "ÇALIŞAN SÜRECİN KENDİ sembollerini ara" amaçlı):** `RTLD`
  Windows İçin `void`. Çözüm: `GetModuleHandleA(null)` (ana `.exe`
  modülünün tutamacı, POSIX'in `dlopen(NULL)`ıYLA AYNI anlam) +
  `GetProcAddress`. **Bilinmesi gereken kısıtlama:** bu, sembolün
  GERÇEKTEN bulunacağını GARANTİ ETMEZ — POSIX'in `dlopen(NULL)`ı TÜM
  genel sembolleri OTOMATİK dışa açarken, MinGW'in varsayılan bağlayıcı
  davranışı AYNI ŞEYİ yapmaz; LL.6'da bağlayıcıya `-Wl,--export-all-
  symbols` (ya da benzeri) bayrağı EKLENMESİ GEREKEBİLİR — GERÇEK
  Windows çalıştırılabilirinde doğrulanacak.
- **`random.zig`nin `std.c.clock_gettime(.REALTIME, ...)` İLE PRNG
  tohumlaması:** `time.zig`nin AYNI `clockid_t`-void bulgusuyla
  ETKİLENİYORDU (bu dosya `time.zig`nin İLK Windows portu SIRASINDA
  GÖZDEN KAÇMIŞTI — kendi keşif adımı ONU da yakaladı). Çözüm:
  `QueryPerformanceCounter`in HAM sayacı (saat DOĞRULUĞU ÖNEMLİ DEĞİL,
  yalnızca DEĞİŞKEN bir tohum değeri yeterli).

Bu SEFERKİ değişikliklerle `zig build`in TAM (runtime dahil) Windows
CI keşif adımı 15 hatadan 0'a İNDİ — **GERÇEK Windows CI'de DOĞRULANDI**
(`windows-latest`, `zig build` adımı temiz geçti).

### LL.5 (TAMAMLANDI) — `nox.thread`/`nox.channel`nin self-pipe deseni

Yukarıdaki keşif turunda `zig build`in error listesi `thread_bridge.zig`/
`thread_channel.zig`e HENÜZ ULAŞMAMIŞTI (önceki dosyalardaki hatalar
Zig'in analiz SIRASINI ENGELLİYORDU) — ama bu İKİ dosya `nox.thread.
start`/`ThreadChannel[T]`in TEMEL taşı olan AYNI `std.c.pipe`
self-pipe desenini (http_client.zig'in `workerThreadFn` tamamlanma
sinyaliyle BİREBİR AYNI) kullanıyordu; proaktif bir `grep` TARAMASIYLA
(CI turunu BEKLEMEDEN) bulundu. Çözüm: `http_client.zig`nin `makeSelfPipe`/
`closeFd`/`signalSelfPipe`/`readSelfPipe` yardımcıları `pub` yapılıp
(zaten HER İKİ dosya da `dupeToNoxStr` İçin `http_client.zig`yi
İTHAL EDİYORDU) DOĞRUDAN yeniden KULLANILDI — YENİ bir kopya
YAZILMADI (`WinSock`in io.zig'de paylaşılmasıyla AYNI ilke). `sleepMs`
(thread_bridge.zig'in test yardımcısı) DOKUNULMADAN bırakıldı —
`nanosleep`/`timespec` Windows'ta GERÇEK, koşulsuz externler/case'ler
OLDUĞU (fs.zig'in LL.4 bulgusu) İçin zaten ÇALIŞIYOR.

Bu FİX de dahil (aynı pushta), GERÇEK Windows CI'de `zig build`in TAM
(runtime + HPy köprüsü + tüm stdlib_shims) derlemesi **SIFIR hatayla
DOĞRULANDI** — Faz LL'nin EN büyük teknik riski (runtime'ın Windows'ta
DERLENMESİ) BÖYLECE TAMAMEN aşıldı. Kalan: LL.6 (MinGW-w64 bağlayıcı
ayarları — özellikle `GetModuleHandleA`+`GetProcAddress`in GERÇEKTEN
sembol BULABİLMESİ İçin export bayrakları), LL.7 (release.yml/
install.ps1), LL.8 (dokümantasyon). **Henüz doğrulanmayan:** derlenen
`noxrt.o` + QBE çıktısının GERÇEK bir Windows İKİLİSİNE bağlanıp
ÇALIŞTIRILMASI (bugüne kadar yalnızca `zig build`/`zig build test`
DOĞRULANDI — bu, Zig KAYNAK kodunun Windows'ta derlendiğini/testlerinin
GEÇTİĞİNİ KANITLAR, ama QBE'nin ürettiği assembly'nin `cc`/MinGW
İLE bağlanıp GERÇEK bir Nox PROGRAMI çalıştırabildiğini HENÜZ
KANITLAMAZ — bu, LL.6'nın asıl konusu).

Yerel olarak (macOS, Debug/ReleaseSafe/ReleaseFast) TÜM değişiklikler
doğrulandı — Windows dalları (`builtin.os.tag == .windows` altında)
Zig'in TİP KONTROLÜNDEN geçti (çalışma-zamanı dalı ÖLÜ olsa BİLE her iki
dal DA derleme-zamanında tip denetlenir) ama GERÇEK yürütme HENÜZ
`windows-latest` CI'de doğrulanmadı.

## 4. Bellek Yönetimi — "Sahiplik Piramidi"

### Katman 1: Görünmez Borrow Checker + ASAP Destructor (Sıfır Maliyet)
- Varsayılan katman. Zorunlu statik tipleme sayesinde derleyici, sahipliği ve yaşam ömrü net olan nesneler için (tahmini kodun %80-90'ı) QBE IR'ına doğrudan ASAP destructor ekler.
- Referans sayacı yok; nesne kapsamdan çıktığı an sıfır maliyetle temizlenir.
- **Karar:** Sahiplik sistemi kullanıcıya **hiçbir zaman** hissettirilmez. Hiçbir açık ownership sözdizimi (`Annotated[...]`, `read`/`mut`/`owned` benzeri anahtar kelimeler) eklenmeyecek. Derleyici belirsiz tüm durumları sessizce Katman 2'ye (ARC) terfi ettirir. Bu, Katman 1'in agresif ama *muhafazakâr* (yanlış emin olmaktansa ARC'ye düşme eğiliminde) bir statik analiz olmasını zorunlu kılar — bkz. AGENTS.md §8.

### Katman 2: Kesintisiz ARC Geri Çekilmesi
- Derleyici karmaşık/belirsiz sahiplik durumlarını statik analizle çözemediğinde, hata vermeden nesneyi otomatik ARC moduna terfi ettirir. O(1) sayaç artır/azalt, deep copy yok.

### Katman 3: Döngü Çözücü
- ARC modundaki nesneler arasında oluşabilecek referans döngülerini (A↔B) tespit eden hafif bir arka plan taraması (Nim'in ORC modeline benzer). Yalnızca ARC'ye terfi etmiş nesneleri tarar.
- **Durum: UYGULANDI (Faz S.3, bkz. §3.14)** — `runtime/alloc/cycle_detector.zig`, Bacon & Rajan'ın senkron trial-deletion algoritmasıyla. v1 kapsamı bilinçli dar: yalnızca SINIF örnekleri arasındaki döngüler (`list[T]`/`dict[K,V]` elemanları kapsam dışı — bugün onlar zaten döngü kuramaz). Tetikleyici: tahsis-baskısı eşiği (varsayılan 700) + program çıkışında son bir tarama.

### Katman 4: `lowlevel` Bloğu (Maksimum Kontrol)
- Rust'ın `unsafe` bloğuna benzer şekilde, geliştiriciye Zig'in Arena/Custom Pool tahsis edicilerine doğrudan erişim ve tamamen manuel bellek yönetimi izni verir.
- **Karar:** `lowlevel` yalnızca *bellek tahsis stratejisini* gevşetir; **tip sistemi orada da tamamen statik ve zorunlu kalır.** `lowlevel` bir dinamik tipleme kaçış kapısı değildir, yalnızca bir bellek yönetimi kaçış kapısıdır.
- C/WASM sınırında hata sinyali çevirisi (bkz. Bölüm 5) de bu blok içinde disiplinli şekilde ele alınmalıdır.

---

## 5. Hata Yönetimi

- Sözdizimsel olarak Python'ın `try` / `except` / `raise` / `finally` yapısı korunur.
- **Runtime gerçekleştirimi Zig tarzı error union'a dayanır:** `raise`, gizlice bir hata-döndürme zincirine (implicit error-return threading) çevrilir; QBE'de unwind tablosu / landing pad mekanizması **kullanılmaz** (QBE bunu desteklemiyor).
- Python'ın sınıf hiyerarşili exception modelini (`except ValueError`, alt sınıf yakalama, `raise X from Y`) desteklemek için error union, Zig'in ham hata kümesinden farklı olarak **tip bilgisi taşıyan bir exception handle** içerir; `except` bloğu bu handle üzerinde runtime'da bir isinstance kontrolü yapar.
- `finally` ve `with` (context manager) temizliği, Katman 1'deki ASAP destructor mekanizmasıyla **aynı codegen yoluna** oturtulmalıdır: başarı ve hata yollarında aynı "kapsam çıkışında temizlik çalıştır" mantığı işlemelidir.
- **Açık soru / risk:** C tarafından gelen kod (ör. NumPy) kendi hata sinyalini (errno, dönüş kodu, C++ exception, longjmp) kullanıyorsa Nox'un error-union varsayımını bilmez. Sınırda bir trampoline/çeviri katmanı gereklidir; bu katmanın `lowlevel` bloğu ile nasıl disipline edileceği netleştirilmeli.

---

## 6. C Eklenti Modeli (HPy Esinli)

- Mevcut Python C eklentilerini (NumPy, Pandas vb.) desteklemek için klasik `PyObject *` tabanlı C-API yerine **opaque handle (kapalı kulp)** modeli kullanılır.
- C eklentisine nesnenin bellek adresi değil, bir kulp/kimlik verilir; referans sayacı veya iç yapı doğrudan değiştirilemez, her işlem Zig runtime API'si üzerinden talep edilir.
- Bu mimari gerçek HPy projesiyle örtüşüyor ve doğru bir yön.
- **Kritik risk:** Ekosistemdeki mevcut C eklentilerinin büyük çoğunluğu hâlâ klasik CPython C-API'sine yazılı, HPy'ye değil. "Yeni wrapper ile destekleme" hedefi, pratikte CPython C-API'sini Nox'un handle sistemi üzerinde emüle eden bir **uyumluluk katmanı** (PyPy'nin `cpyext`'i, GraalPython'ın uyumluluk katmanı benzeri) gerektirir. Bu, alternatif Python implementasyonu projelerini tarihsel olarak en çok yavaşlatan mühendislik yüküdür.
- **Karar:** Mümkün olan **en geniş HPy/CPython API desteği** hedeflenir, önceliklendirilmiş katmanlar halinde (Tier 0-3, ayrıntılar için AGENTS.md §10). Öncelik gerçek dünya kullanım sıklığına göre belirlenir: önce nesne yaşam döngüsü + modül init, sonra buffer/sequence/number protokolleri (NumPy/Pandas sınıfı kütüphaneler için kritik), sonra GC/weakref/subclassing, en son uzun kuyruk (descriptor, metaclass, capsule).

---

## 7. WASM Entegrasyonu

- QBE'nin kendisi WASM'ı hedeflemiyor; bu nedenle Nox, kendisini WASM'a derlemek yerine **WASM modüllerini içe aktarıp kütüphane olarak kullanma** yönünde tasarlanmıştır.
- Zig runtime'ı içine gömülü bir WASM çalışma zamanı (wasmtime/wasmer C API'si veya hafif bir native Zig yorumlayıcı) entegre edilir.
- WASM modüllerinin export ettiği fonksiyonlar, Bölüm 6'daki handle sistemi üzerinden Nox fonksiyonu gibi çağrılabilir hale getirilir.
- Bu yaklaşım, QBE'nin CFG'sinden yapılandırılmış kontrol akışı çıkarma gibi çok daha zor bir mühendislik işinden kaçınır.

---

## 8. Karşılaştırmalı Konumlandırma

| | **Nox** | **Mojo** | **mypyc** |
|---|---|---|---|
| Derleyici alt yapısı | QBE (minimal, ~10k LOC) | MLIR/LLVM | CPython C-API |
| Tipleme | Zorunlu statik | Kademeli/opsiyonel | Zorunlu statik (fonksiyon bazlı) |
| Bellek modeli | ASAP + ARC + döngü çözücü (görünmez) | Ownership + borrow checker (kısmen açık: `read`/`mut`/`owned`) | CPython refcount (değişmedi) |
| C eklenti modeli | HPy tarzı opaque handle + uyumluluk katmanı | CPython runtime üzerinden Python modül importu | Doğrudan CPython C-API |
| WASM | Runtime içine gömülü, kütüphane olarak import | Yok (ayrı hedef) | Yok |

---

## 9. Tasarım Kararları — Durum Tablosu

| # | Soru | Karar | Detay |
|---|---|---|---|
| 1 | Ownership ipucu sözdizimi | **Tamamen örtük, hiçbir açık sözdizimi yok** | §4 Katman 1 |
| 2 | Generics/polimorfizm mekanizması | **Compile-time monomorphization + yapısal protokoller, heterojen durumlarda örtük vtable fallback** | AGENTS.md §12 |
| 3 | C/WASM sınırında hata sinyali çevirisi | **Derleyici tarafından otomatik üretilen trampoline fonksiyonlar** | AGENTS.md §9 |
| 4 | CPython C-API uyumluluk kapsamı | **Katmanlı öncelik (Tier 0-3), en geniş HPy desteği hedefi** | §6, AGENTS.md §10 |
| 5 | `lowlevel` bloğu ve tip sistemi | **`lowlevel` içinde de zorunlu statik tipleme geçerli; yalnızca bellek tahsisi gevşer** | §4 Katman 4 |

Uygulama detayları için bkz. `AGENTS.md`.

---

## 10. Sonraki Adımlar

- [ ] Bölüm 9'daki açık soruların çözülmesi
- [ ] Gramer/EBNF taslağının çıkarılması
- [ ] QBE IR'a çeviri örneklerinin (ASAP destructor, error union) prototiplenmesi
- [ ] Minimal HPy uyumluluk katmanı için kapsam belirleme
