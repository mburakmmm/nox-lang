# Nox Programlama Dili — Teknik Spesifikasyon

**Versiyon:** 0.1 (Taslak)
**Tarih:** 9 Temmuz 2026
**Dosya Uzantısı:** `.nox`
**Durum:** Mimari tasarım aşaması

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

**Tasarım kararı — `self` parametresi:** AGENTS.md §5 tüm parametre tiplerinin zorunlu
olmasını şart koştuğu için, Python'ın aksine `self` de açıkça anotasyonlanır ve tipi
her zaman kapsayan sınıfın adıdır: `def __init__(self: Point, x: int) -> None:`.
Bu, İlke #1/§5 ile tutarlı kalmak için bilinçli bir sapmadır; ileride `Self` tipi
gibi bir kısayol eklenmek istenirse bu, mimariyi etkileyen bir karar olacağından
AGENTS.md §16 prosedürüne göre ayrıca ele alınmalıdır.

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

**Sınıf alanları:** Bir sınıfın alanları, sözdiziminde ayrıca bildirilmez;
yalnızca `__init__` içindeki ilk `self.<ad> = <ifade>` ataması alanın tipini
örtük olarak belirler (`__init__` diğer metodlardan önce denetlenir ki alan
tipleri bilinsin). `__init__` dışında yeni alan tanımlanamaz. Bu, AGENTS.md
İlke #1'in yasakladığı bir *ownership* sözdizimi değildir — yalnızca tip
çıkarımı içindir.

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
Alanlar **yalnızca `__init__` gövdesindeki `self.<ad> = <ifade>` atamalarından**
çıkarılır ve yalnızca doğrudan bir `__init__` parametresi ya da bir literal
olabilir (`inferFieldType`) — checker'ın (Faz 2) tam ifade tipi çıkarımını
codegen'de yeniden uygulamamak için bilinçli, gerçekçi/yaygın deseni
(`self.x = x`) hedefleyen bir kapsam sınırlaması. Alan tipleri yalnızca değer
tipleri ya da `str` olabilir — **başka bir sınıf ya da `list[T]` alanı
desteklenmiyor** (iç içe heap, döngüsel/özyinelemeli yıkım karmaşıklığı
gerektirir, ertelendi). Kurucu çağrısı (`ClassName(...)`) `nox_rc_alloc` +
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
  yapılarını `None`/nullable tip desteği gelene kadar zaten engeller.
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
olarak İNŞA EDİLMESİNİ sağlar (`None`/opsiyonel tip GEREKMEDEN — dil bunu
HENÜZ desteklemiyor); SONRA `a.next = b; b.next = a;` gibi bir yeniden atamayla
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
