//! Nox QBE IR codegen — AGENTS.md §7 adım 4.
//!
//! **Kapsam (bu geçiş):** değer tipleri (`int`/`float`/`bool`/`None`) + iki
//! heap tipi (`str`, `list[T]`, yalnızca `T` bir değer tipiyken) + sınıflar.
//!
//! **`str` neden hep tahsissiz:** v0.1 grameri hiçbir string ÜRETEN işlem
//! (birleştirme, biçimlendirme, okuma) içermiyor — tek kaynak string
//! LİTERALLERİdir. Her `str` değeri statik salt-okunur veriye (QBE `data`)
//! işaret eder; hiçbir zaman tahsis edilmez, hiçbir zaman serbest bırakılmaz.
//!
//! **`list[T]` ve sınıflar — ödünç alma (borrow) + referans sayımı:**
//! Her ikisi de `runtime/alloc/arc.zig`'in görünmez refcount başlığıyla
//! tahsis edilir (refcount 1 ile başlar). Kural seti:
//!   - Bir fonksiyona/metoda PARAMETRE olarak ya da bir çağrıya ARGÜMAN
//!     olarak ya da bir metod çağrısının ALICISI olarak geçmek yalnızca bir
//!     "ödünç"tür — refcount'u ETKİLEMEZ (çağrı senkron, çağrılan referansı
//!     kalıcı olarak saklamıyorsa hiçbir sayaç değişikliği gerekmez).
//!   - Bir değeri BAŞKA BİR İSME atamak (`y = x` / `y: T = x`, `x` zaten
//!     izlenen bir heap bağlamıysa) bir `nox_rc_retain` üretir — iki bağımsız
//!     "sahip" artık aynı nesneyi paylaşıyor.
//!   - Bir yerel değişkeni (parametre DEĞİL) `return` etmek özel bir işlem
//!     GEREKTİRMEZ: bu fonksiyonun kapsam-sonu temizliği zaten `return`'da
//!     atlanıyor (aşağıdaki bilinen sınırlamaya bakın), bu da net bir
//!     "taşıma" (sıfır maliyetli sahiplik devri) ile sonuçlanır.
//!   - Yerel (parametre olmayan) her heap bağlamı, kapsam sonunda (ya da
//!     yeniden atama/tanımlamada, önce) tam olarak bir `nox_rc_release` alır.
//!     Sıfıra inen refcount gerçek belleği serbest bırakır; inmeyen (başka
//!     bir yerde retain edilmiş) yalnızca sayacı azaltır.
//!   - Parametreler HİÇBİR ZAMAN release edilmez (ödünç alınmıştır); yeniden
//!     atanırlarsa bile (bilinçli, muhafazakâr bir sınırlama — bkz. aşağı).
//!
//! **Sınıflar:** Alanlar yalnızca `__init__` gövdesindeki `self.<ad> = <ifade>`
//! atamalarından çıkarılır ve yalnızca doğrudan bir parametre ya da bir
//! literal olabilirler (bkz. `inferFieldType`) — bu, checker'ın (Faz 2) tam
//! ifade tipi çıkarımını burada yeniden uygulamadan gerçekçi/yaygın deseni
//! (`self.x = x`) kapsayan bilinçli bir kapsam sınırlamasıdır. Alan tipleri
//! değer tipleri, `str` ya da (Faz 9'dan beri) BAŞKA BİR SINIF olabilir;
//! `list[T]` alanı henüz desteklenmiyor.
//!
//! **İç içe sınıf tipli alanlar ve özyinelemeli release (Faz 9):** bir sınıf
//! alanı başka bir sınıf tipinde olabilir (ör. `Car.engine: Engine`), AMA
//! yalnızca DAHA ÖNCE kaydedilmiş bir sınıfa referans verebilir —
//! `resolveType`/`registerClass`'ın tek geçişli, sıralı doğası (bir sınıf
//! kendi `__init__`'i işlenirken henüz `self.classes`'a eklenmemiştir) bunu
//! doğal olarak dayatır. Bu, ÖZ-REFERANSI (`class Node: self.next: Node`) ve
//! İLERİ-REFERANSLI karşılıklı döngüleri (`A`nın bir `B` alanı VE `B`nin bir
//! `A` alanı olması) derleme zamanında imkansız kılar — yani bu fazda hiçbir
//! referans DÖNGÜSÜ kurulamaz, bu yüzden Katman 3 (döngü çözücü) hâlâ
//! gerekmiyor. Her sınıf için üretilen `$ClassName_release` (bkz.
//! `genClassRelease`), refcount'u azaltıp (`nox_rc_predecrement`) sıfıra
//! düştüğünde ÖNCE sınıf tipli her alanı (varsa, null değilse) özyinelemeli
//! olarak serbest bırakır, SONRA belleği gerçekten serbest bırakır
//! (`nox_rc_free_payload`) — çalışma zamanının (`arc.zig`) aksine bu, derleme
//! zamanında bilinen alan düzenini kullanabilir. Bir alanın üzerine yeniden
//! yazmak (`self.attr = ...`) önce YENİ değeri (takma ad ise) retain eder,
//! SONRA eski değeri (varsa) serbest bırakır — sıra, eskiyle yeni AYNI nesne
//! olduğunda (`self.attr = self.attr`) bile doğru çalışır. Taze inşa edilen
//! bir örneğin alanları, `__init__` çalışmadan ÖNCE sıfırlanır (bkz.
//! `genConstruct`) — aksi halde ilk atamada "eskiyi serbest bırak" mantığı
//! çöp bir işaretçiyi release etmeye çalışırdı.
//!
//! **Ödünç alma artık her zaman zaman-uyumsuz DEĞİL — "geçici" (temporary)
//! değerler için istisna:** parametre geçişi hâlâ bir ödünçtür, ama bir
//! callee artık parametreyi (Faz 9'dan beri) bir ALANA ya da yeni bir yerele
//! atayarak KALICI hale getirebilir. Çağıranın bir ÇAĞRI/LİSTE-LİTERALİ
//! sonucunu (`.call`/`.list_lit` — TAZE, hiçbir bağımsız sahibi olmayan bir
//! değer, bkz. `isTemporaryExpr`) argüman/alıcı olarak geçirdiği durumlarda,
//! çağrı DÖNDÜKTEN SONRA bu değer serbest bırakılır (`releaseTemporaryArgs`/
//! `releaseIfTemporary`) — callee onu retain ettiyse (kalıcı kıldıysa) bu,
//! refcount'u doğru şekilde 1'e indirir; etmediyse zaten 1 olan refcount'u
//! 0'a indirip gerçekten serbest bırakır. AYNI mekanizma bir alan
//! okumasının/indekslemenin TABANI (`genFieldRead`/`genIndex`, ör.
//! `make_car(i).engine`) ve tamamen dolaylanmış bir deyim (`expr_stmt`) için
//! de geçerlidir. Simetrik olarak, `return`, KENDİ münhasır yerel
//! bağlamasını (parametre DEĞİL) döndürüyorsa hâlâ retain GEREKTİRMEZ (sıfır
//! maliyetli taşıma), ama bir PARAMETREYİ olduğu gibi (`return p`) ya da bir
//! ALAN OKUMASINI (`return self.attr`) döndürüyorsa retain GEREKİR (bkz.
//! `returnNeedsRetain`) — bu, "passthrough" fonksiyonları (ör.
//! `def identity(p): return p`, ya da bir alanı dışarı veren bir metod) bile
//! yukarıdaki çağıran-taraf telafi release'iyle birlikte güvenli kılar.
//!
//! **Erken `return` artık güvenli (Faz 7'de düzeltildi):** her `return`,
//! gerçek `ret`ten hemen önce dönen değerin KENDİ bağlaması HARİÇ tüm heap
//! tipli yerelleri serbest bırakır (`releaseAllLocalsExcept`) — böylece aynı
//! kapsamdaki başka bir heap yerel artık sızmaz. `finally` blokları da her
//! çıkış yolunda (normal tamamlanma, `return`, yakalanmamış istisna) satır
//! içi üretilerek çalıştırılır (`drainFinally`/`finally_stack`) — Python'daki
//! gibi, QBE'de paylaşılan bir "unwind" hedefi olmadan (İlke #3).
//!
//! **Hata yayılımı (`raise`/`try`/`except`/`finally`, AGENTS.md §9):** QBE
//! hiçbir zaman unwind tablosu üretmediği için, her kullanıcı fonksiyonu/
//! metodu/kurucu çağrısından hemen sonra derleyici örtük bir "bekleyen
//! istisna var mı?" kontrolü (`emitExceptionCheck`) üretir — Zig'in error
//! union'larına benzer bir örtük hata-döndürme zinciri. Sınıf örnekleri artık
//! (refcount başlığından sonra) çalışma zamanında bir tip etiketi taşır;
//! `except ClassName:` eşleşmesi bu etiketin doğrudan (tam/isim bazlı,
//! kalıtım olmadığı için hiyerarşik DEĞİL) karşılaştırılmasıyla yapılır.
//! `main`'den yakalanmamış bir istisna sessizce başarıyla bitmiş gibi
//! davranmaz — `nox_unhandled_exception` bir hata mesajı basıp sıfırdan
//! farklı bir kodla sonlanır.
//!
//! **Çalışma zamanı bağlamı (`rt`):** İlke #6 gereği, her Nox fonksiyonu
//! (main hariç) gizli bir ilk parametre olarak `%rt` alır ve bunu ihtiyaç
//! duyan her çağrıya açıkça taşır — bu bir "gizli global" değildir.
//!
//! **`lowlevel` bloğu (Katman 4, Faz 8, AGENTS.md §8):** İlke #2 gereği bu
//! yalnızca tahsis STRATEJİSİNİ değiştirir, tip sistemini DEĞİL — gövde
//! `checker.zig`'de tamamen normal kurallarla denetlenir. Blok girişinde
//! `nox_arena_create` çağrılır (sonucu `arena_stack`'e itilir); bu blok
//! içinde inşa edilen her `list[T]`/sınıf örneği (bkz. `currentArena`,
//! `genConstruct`/`genListLit`) ARC yerine bu arenadan (`nox_arena_alloc`)
//! tahsis edilir — hiçbir bireysel `nox_rc_retain`/`nox_rc_release` ASLA
//! çağrılmaz (arena belleğinde refcount başlığı yoktur; bir retain/release
//! bitişik belleği bozardı). Blok normal tamamlandığında arena TEK SEFERDE
//! yıkılır (`nox_arena_destroy`); her erken çıkışta (`return`, yakalanmamış
//! istisna) `drainArenas` aynı işi `drainFinally` ile aynı "her çıkışta satır
//! içi yıkım" desenini izleyerek yapar.
//!
//! **Kaçış engelleme — bilinçli olarak GENİŞ bir kural:** arena-lık
//! (`.arena`), bir fonksiyonun statik imzasının bir parçası DEĞİLDİR —
//! yalnızca belirli bir ÇAĞRI YERİNDEKİ belirli bir DEĞERİN özelliğidir ve
//! fonksiyon sınırını asla aşmaz (bir parametrenin `VarInfo.arena`'sı çağıran
//! ne geçirirse geçirsin her zaman `false`'dur). Bu yüzden ADAY olarak daha
//! dar bir kural ("yalnızca dönüş/`self.alan=` gibi GERÇEKTEN kaçıran
//! kullanımları engelle") YETERSİZDİR: bir arena değerini bir fonksiyona
//! argüman/alıcı olarak geçirmek güvenli GÖRÜNÜR (çağrı senkron, "ödünç"),
//! ama çağrılan gövde bu parametreyi `return`/bir alana atama yoluyla kaçırırsa
//! (arena-lığından HABERSİZ olarak, çünkü bu bilgi imzada yok) çağıran taraf
//! sonucu normal bir ARC değeriymiş gibi retain/release edip refcount başlığı
//! OLMAYAN belleği bozar. Ara-yordamsal (interprocedural) analiz olmadan bunu
//! ayırt edemeyiz; bu yüzden `checkNoLowlevelEscape` KASITLI olarak geniş bir
//! kural uygular: bir `lowlevel` bloğunun içinde lexical olarak bulunulduğu
//! SÜRECE (`in_lowlevel_depth > 0`) ya da değer zaten `.arena` işaretliyken,
//! heap tipli hiçbir değer bir çağrıya ARGÜMAN, bir metod çağrısının ALICISI
//! olamaz, `return` edilemez ya da başka bir isme takma ad olamaz. Bu, aksi
//! halde güvenli olan bazı desenleri (ör. arena bir nesnenin bir metodunu
//! çağırmak) da engeller — ama basit ve SAĞLAMDIR; v0.1 için doğru ödünleşim.
//!
//! **Kapsam:** `lowlevel` içinde tanımlanan adlar bloktan SONRA kapsam dışına
//! alınır (bkz. `checker.zig`, `.lowlevel_stmt` — önce/sonra anlık görüntü
//! farkıyla scope'tan çıkarılır), çünkü arena blok çıkışında yıkılır; aksi
//! halde bloktan sonraki bir kullanım kullanım-sonrası-serbest-bırakma olurdu.
//!
//! **Bilinen sınırlama (kabul edildi, çözülmedi):** yukarıdaki geniş kural,
//! bir arena değerinin BİZZAT KENDİSİNİN herhangi bir çağrı sınırını aşmasını
//! engeller — ama teorik olarak kalan tek risk, `lowlevel` DIŞINDA tanımlı
//! "passthrough" bir fonksiyonun (ör. `def identity(p: Point) -> Point: return
//! p`) `lowlevel` dışından ARC bir değerle çağrılıp normal davranmasıdır; bu
//! zaten güvenlidir çünkü `identity` kendi içinde `lowlevel`de değildir ve
//! aldığı değer zaten ARC'tır. Geniş kuralımız bu fonksiyonun bir ARENA
//! değeriyle çağrılmasını zaten YASAKLADIĞI için (argüman kontrolü) bu
//! senaryo pratikte oluşamaz — ara-yordamsal analiz gerektiren tek durum, bir
//! `lowlevel` bloğunun DIŞINDAN çağrılamayacağı için bu tasarımda ortaya
//! çıkmaz. Belgelenmiş, kasıtlı bir tasarım kararıdır.
//!
//! **Faz T.3 — DWARF/-g debug bilgisi emisyonu:** QBE 1.3 IL'i iki debug
//! yönergesi TANIR: `dbgfile "<yol>"` (modül seviyesinde, "şu andan itibaren
//! üretilen kod BU kaynak dosyaya ait" der — GEREKTİĞİNDE birden çok kez
//! kullanılabilir, HER `dbgfile` bir SONRAKİ fonksiyona kadar aktif kalır) ve
//! `dbgloc <satır>[, <sütun>]` (bir deyimden ÖNCE, "şu andan itibaren üretilen
//! makine kodu KAYNAKTA bu satıra karşılık gelir" der). Bunlar, hedef
//! assembler'ın (`as`/`clang`) `.file`/`.loc` sözde-yönergelerine BİREBİR
//! eşlenir — QBE'NİN KENDİSİ DWARF ÜRETMEZ, YALNIZCA assembler'a "üret" der
//! (assembler GERÇEK `.debug_line` bölümünü inşa eder). `generateModule`e
//! `debug_source_path: ?[]const u8` VERİLİRSE (`noxc build -g`, bkz.
//! `main.zig`) `gen.debug_info = true` olur VE `genStmts` (TÜM deyim
//! kodgen'inin TEK dağıtım noktası — T.1'in `checkStmt`iyle AYNI desen) HER
//! deyimden ÖNCE `dbgloc <stmt.line>` yayınlar.
//!
//! **Bilinçli v1 sınırlaması — TEK dosya, ÇOKLU-DOSYA YANLIŞ ATIF:** TEK BİR
//! `dbgfile` (kullanıcının ANA giriş dosyası) modülün BAŞINDA yayınlanır —
//! `module_loader.resolveImportsImpl`in TÜM stdlib'i + kullanıcı kodunu TEK
//! bir düz `ast.Module.body`de BİRLEŞTİRMESİ (bkz. Alt-Faz A) YÜZÜNDEN, `ast.
//! Stmt` HENÜZ HANGİ KAYNAK DOSYADAN geldiğini İZLEMİYOR (yalnızca `.line`,
//! bkz. Faz T.1) — bu YÜZDEN `nox.strings`/`nox.json` gibi stdlib
//! fonksiyonlarına ADIM ATILDIĞINDA (step into) debugger YANLIŞ dosyada
//! (kullanıcının dosyasında) YANLIŞ bir satır gösterebilir (DOĞRU satır
//! NUMARASI ama YANLIŞ DOSYA bağlamında). KULLANICININ KENDİ fonksiyonlarında
//! (arada stdlib'e girmeden) satır bilgisi HER ZAMAN DOĞRUDUR. TAM çok-dosya
//! doğruluğu, HER üst-düzey `func_def`/`class_def`in KENDİ kaynak dosyasını
//! izleyen bir `ast.Stmt.origin_file` alanı (T.1'in `.line` alanıyla AYNI
//! ölçekte bir genişleme) GEREKTİRİR — v1 kapsamı DIŞINDA BIRAKILDI (bkz.
//! nox-teknik-spesifikasyon.md §3.17).
//!
//! **Bilinçli v1 sınırlaması — macOS'ta bağlı (linked) ikili TAM DWARF
//! TAŞIMAZ:** Linux'ta (ELF) `.loc`/`.file` yönergeleriyle üretilen DWARF,
//! DOĞRUDAN bağlı (linked) çalıştırılabilir dosyaya GÖMÜLÜR (ek bir adım
//! GEREKMEZ, `gdb`/`objdump --dwarf=decodedline` DOĞRUDAN çalışır — GERÇEK
//! bir Linux/x86-64 Docker konteynerinde DOĞRULANDI, bkz. §3.17). macOS'ta
//! (Mach-O) İSE ara `.o` dosyası GERÇEK DWARF taşısa BİLE (dwarfdump ile
//! DOĞRULANABİLİR), Apple'ın `ld`si son çalıştırılabilir dosyaya DWARF'ı
//! KOPYALAMAZ — bunun yerine derleyicinin (`clang -g`) ayrıca ürettiği,
//! elle yazılmış assembly'de BULUNMAYAN STABS sembolleriyle (`N_OSO`/`N_FUN`)
//! kurulan bir "debug map" ÜZERİNDEN `dsymutil`in ayrı bir `.dSYM` paketi
//! inşa etmesine GÜVENİR. QBE'nin çıktısı bu STABS sembollerini İÇERMEDİĞİNDEN
//! `dsymutil` "no debug symbols in executable" der VE macOS'ta `lldb`
//! kaynak-satırı adımlama ÇALIŞMAZ (GERÇEKTEN denenip DOĞRULANDI). Bu, Mach-O'ya
//! ÖZGÜ, AYRI bir mühendislik sorunudur (R.2/R.3'ün "gerçek donanıkta
//! doğrulanan Linux, dürüstçe belgelenen macOS kısıtı" hassasiyetiyle AYNI
//! ruhla) — v1 kapsamı DIŞINDA BIRAKILDI.

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub const CodegenError = error{
    OutOfMemory,
    Unsupported,
} || std.Io.Writer.Error;

const QbeType = enum { l, d, w, none };
/// `task`/`channel`: Faz 21 aşama 4'ün `Task[T]`/`Channel[T]`si — BİLEREK
/// `isHeapManaged`in DIŞINDA tutulur (ARC/refcount başlığı YOK, zamanlayıcı
/// kendi ömrünü kendi yönetir, bkz. `runtime/async_rt/bridge.zig`) — ama
/// `.none`den AYRI bir etiket olmaları, kapsam-sonu temizliğinin (bkz.
/// `releaseAllLocalsExcept`) onları `nox_async_destroy_task`/
/// `nox_channel_destroy` ile (predecrement/retain OLMADAN, doğrudan bir
/// kez) serbest bırakabilmesi için GEREKLİDİR — aksi halde her `spawn`/
/// `Channel[T](...)` sızardı (bkz. spec, bulunan gerçek hata).
/// `dict`: stdlib fazı §C (bkz. nox-teknik-spesifikasyon.md). Faz FF.3'e
/// (bkz. §3.62) KADAR `task`/`channel` İLE AYNI gerekçeyle BİLEREK
/// `isHeapManaged`in DIŞINDA tutuluyordu — bu, bir `dict`in bir sınıf
/// alanına DEVREDİLİP kaynak yerelinin kapsam-sonunda YIKILMASI durumunda
/// GERÇEK bir sallanan-işaretçi/çift-serbest-bırakma açığıydı (bkz.
/// `runtime/collections/dict.zig`nin modül-üstü notu). ARTIK `str`/`list`/
/// `class` İLE AYNI TAM ARC modelindedir (`isHeapManaged`in İÇİNDEdir) —
/// `nox_dict_new` `nox_rc_alloc` ile tahsis eder, kapsam-sonu temizliği
/// `nox_dict_release` (predecrement'e göre koşullu) ÜZERİNDEN GEÇER (bkz.
/// `releaseValueIfSet`in `.dict` dalı).
/// Faz U.4.3/U.4.4: `closure` — bir iç içe `def`in ARC'lı çalışma zamanı
/// temsili. `class` İLE YAPISAL OLARAK AYNIDIR (ARC pointer, `nox_rc_alloc`/
/// `nox_rc_predecrement`/`nox_rc_free_payload` AYNI havuzu kullanır) —
/// TEK FARK İÇ DÜZENİ: `{fn_ptr: l @0, release_fn_ptr: l @8, yakalanan_
/// değerler... @16+}` (sınıfın isimli ALANLARI yerine, checker'ın capture
/// SIRASINA göre; bkz. `CLOSURE_HEADER_SIZE`). Faz U.4.4'ün eklediği
/// `release_fn_ptr`, closure'ın SOMUT release fonksiyonunu bir DEĞİŞKENİN/
/// DÖNÜŞÜN çıplak tip ANNOTASYONUNDAN (`Type.func` yapısal/POLİMORFİK
/// olduğundan, bkz. `resolveType`in `.func_type` dalı) STATİK olarak
/// bilinemediği durumlarda BİLE (bkz. `releaseValueIfSet`in `.closure`
/// dalı) DOĞRU release fonksiyonuna DOLAYLI olarak dispatch edebilmek
/// içindir — bu, `class`ın (HER ZAMAN somut/nominal bir tip olduğundan
/// `class_name` üzerinden İSİM-tabanlı dispatch YETERLİ olan) AKSİNE,
/// closure'ın polimorfik doğasının GEREKTİRDİĞİ bir "küçük vtable"dır.
/// `fn_ptr` (offset 0) AYRICA dolaylı ÇAĞRI İÇİN de kullanılır (bkz.
/// `genCall`in `.closure` dalı) — bir closure DEĞERİNİN KENDİSİ, hem
/// "nasıl çağrılır" hem "nasıl serbest bırakılır" bilgisini TAŞIYAN, kendi
/// kendine yeten TEK bir işaretçidir.
const HeapKind = enum { none, str, list, class, task, channel, dict, closure, thread_handle, thread_channel, boxed_scalar };

/// Faz U.4.4: bir closure heap bloğunun başlık boyutu (bkz. `HeapKind.closure`in
/// belge notu) — `fn_ptr` + `release_fn_ptr`, HER İKİSİ de `l` (8 bayt).
/// Yakalanan değerler bu OFSETTEN itibaren sırayla YERLEŞTİRİLİR.
const CLOSURE_HEADER_SIZE: usize = 16;

/// `list[T]`nin elemanları KENDİLERİ heap-yönetimliyse (sınıf ya da iç içe
/// `list[T']`) bunu ÖZYİNELEMELİ olarak betimler (bkz. modül üstü not, "Faz 21
/// ön-koşulu: list[T] için özyinelemeli release"). `heap` yalnızca `.class`
/// ya da `.list` olabilir (çağıran garanti eder) — elemanlar int/float/bool/
/// str/None ise bu yapı hiç YOK (`null`), DEĞİŞMEMİŞ eski yol kullanılır.
const ElemHeapInfo = struct {
    heap: HeapKind,
    /// `heap == .class` ise sınıfın adı.
    class_name: ?[]const u8 = null,
    /// `heap == .list` ise BU (iç) listenin KENDİ elemanlarının QBE tipi
    /// (`TypeInfo.elem_qtype`nin özyineli karşılığı — bir döngü değişkeni
    /// gibi yerlerde tam `TypeInfo`yu yeniden kurabilmek için gerekir).
    elem_qtype: QbeType = .none,
    /// `heap == .list` ise İÇ listenin KENDİ elemanının açıklayıcısı — `null`:
    /// iç eleman primitive (int/float/bool/None); `str` DAHİL heap-yönetimli
    /// (`class`/`list`/`str`) TÜM eleman tipleri için `non-null`dur (bkz.
    /// stdlib fazı §B — `str` ARC-yönetimli olduktan SONRA `list[str]`
    /// elemanlarının da özyinelemeli release'e girmesi GEREKTİ, `genListElemRelease`in
    /// `info.nested`in `.str` özel durumuna bkz.).
    nested: ?*const ElemHeapInfo = null,
    /// `heap == .list` ise: BU (iç) listenin KENDİ elemanlarının `str` olup
    /// olmadığı (`TypeInfo.elem_is_str`nin özyineli karşılığı) — SADECE derin
    /// yapısal eşitlik (`==`/`!=`, bkz. görev "list/class için derin yapısal
    /// eşitlik") `list[str]`i `list[int]`den ayırt edebilmek İÇİNDİR
    /// (`strcmp` ile `ceql` FARKLI karşılaştırma operasyonlarıdır) — release
    /// KARARI `nested`in KENDİSİNİN `.heap == .str` olup olmamasından gelir
    /// (bu alandan DEĞİL).
    elem_is_str: bool = false,
};

/// `dict[K, V]`nin anahtar/değer "şeklini" betimler — `ElemHeapInfo` İLE
/// AYNI amaç (list[T]'nin elemanı), ama dict'in İKİ bağımsız tip parametresi
/// olduğundan (K ayrıca hash/eşitlik için, V yalnızca depolama için) tek bir
/// `elem_*` alan seti YETMEZ. v1 kapsamı bilinçli olarak dar (bkz. checker.zig'in
/// `typeExprToType`indeki `"dict"` dalı): K int/bool/str, V int/float/bool/str
/// — sınıf anahtar/değer ERTELENDİ, bu yüzden `nested`/`class_name` gibi
/// özyineli alanlara GEREK YOK (list[T]'nin AKSİNE).
const DictInfo = struct {
    key_is_str: bool,
    value_qtype: QbeType,
    value_is_str: bool,
};

/// Faz U.4.4: bir `(params) -> ret` tip ifadesinin (`ast.TypeExpr.func_type`)
/// ÇÖZÜLMÜŞ imzası — hangi SOMUT closure çağrılacağı derleme zamanında
/// bilinmese de (bkz. `HeapKind.closure`in belge notu, tip POLİMORFİKTİR),
/// STATİK imza (parametre SAYISI/QBE tipleri + dönüş tipi) HER ZAMAN
/// bilinir — değişkenin/parametrenin/dönüşün KENDİ tip ifadesinden.
/// Dolaylı çağrının (`genCall`in `.closure` dalı) argümanları doğru tipe
/// çevirebilmesi/sonucu doğru betimleyiciyle DÖNDÜREBİLMESİ İÇİN gerekir.
const FuncSigInfo = struct {
    params: []const TypeInfo,
    ret: TypeInfo,
};

const TypeInfo = struct {
    qtype: QbeType,
    heap: HeapKind = .none,
    elem_qtype: QbeType = .none,
    class_name: ?[]const u8 = null,
    elem_heap_info: ?*const ElemHeapInfo = null,
    /// `heap == .list` ise: elemanların `str` olup olmadığı — `str` release
    /// GEREKTİRMEDİĞİNDEN (bkz. `isHeapManaged`) `elem_heap_info` bunu
    /// KAPSAMAZ (o yalnızca özyinelemeli release gereken `.class`/`.list`
    /// elemanlar içindir), ama `genIndex`/for-döngüsü değişkeni gibi
    /// OKUMA noktalarının okunan değeri `heap = .str` olarak DOĞRU
    /// etiketleyebilmesi (aksi halde `print` onu int gibi basar) için
    /// AYRI, basit bir bayrak gerekir.
    elem_is_str: bool = false,
    /// `heap == .dict` ise anahtar/değer "şekli" (bkz. `DictInfo`in belge
    /// notu) — aksi halde `null`.
    dict_info: ?*const DictInfo = null,
    /// `heap == .closure` ise ÇÖZÜLMÜŞ statik imza (bkz. `FuncSigInfo`in
    /// belge notu) — aksi halde `null`.
    func_sig: ?*const FuncSigInfo = null,
};

const Value = struct {
    text: []const u8,
    qtype: QbeType,
    heap: HeapKind = .none,
    elem_qtype: QbeType = .none,
    class_name: ?[]const u8 = null,
    elem_heap_info: ?*const ElemHeapInfo = null,
    elem_is_str: bool = false,
    dict_info: ?*const DictInfo = null,
    /// `true`: bir `lowlevel` bloğunun arenasından tahsis edildi — refcount
    /// başlığı YOK, `nox_rc_retain`/`nox_rc_release` bu değer üzerinde asla
    /// çağrılamaz (bkz. modül üstü not).
    arena: bool = false,
    /// Stdlib fazı §G: `s[i]`nin (bkz. `genStrIndex`) BİLİNÇLİ bir istisnası
    /// — `isTemporaryExpr`/`isAliasingExpr`in `.index` dalı, `list[T]`/
    /// `dict[K,V]` indekslemesi İÇİN (sonuç TABANIN İÇİNE bir takma addır,
    /// "temporary"liği TABANINKİNE bağlıdır) DOĞRU olsa da, `str` indekslemesi
    /// İÇİN YANLIŞTIR: `nox_str_char_at` HER ZAMAN TABANDAN BAĞIMSIZ, TAZE
    /// bir tahsis döndürür — TABANIN kendisi (adlandırılmış bir isim de
    /// olsa) temporary olmasa BİLE, sonuç ASLA bir takma ad DEĞİLDİR ve HER
    /// ZAMAN çağıran tarafından serbest bırakılMALIDIR. `isTemporaryExpr`
    /// SALT AST'YE bakan pür bir fonksiyon olduğundan (tip bilgisi YOK, bu
    /// bilgiyi TAŞIYAMAZ) bu ayrım `Value`nin KENDİSİNDE bir bayrakla
    /// taşınır — `retainIfAliasing`/`releaseIfTemporary`/`releaseTemporaryArgs`
    /// (ki HEPSİ zaten hesaplanmış `Value`ye erişimi var) bu bayrak
    /// `true` İSE AST-tabanlı sezgiyi (`isAliasingExpr`/`isTemporaryExpr`)
    /// GEÇERSİZ KILAR: ASLA takma ad SAYILMAZ (retain GEREKMEZ), HER ZAMAN
    /// temporary SAYILIR (release GEREKİR).
    always_fresh: bool = false,
};

const FuncSig = struct {
    params: []const TypeInfo,
    ret: TypeInfo,
    /// Yalnızca `extern def`ler İÇİN anlamlıdır (bkz. `ast.ExternDef.needs_rt`in
    /// belge notu, stdlib fazı §D.1) — `genCall`in `extern_functions` dalı
    /// bu bayrak `true` İSE `RT_PARAM`ı argüman listesinin BAŞINA GİZLİCE
    /// ekler. Normal fonksiyonlar İÇİN her zaman `false`tur (zaten HER
    /// çağrıda `RT_PARAM` KOŞULSUZ geçirilir, bu alan onlar için anlamsızdır).
    needs_rt: bool = false,
};

/// Faz 21 aşama 4: `spawn <hedef_fn>(args...)` çağrı sitesi başına TEMBEL
/// kaydedilen, `generateModule`nin sonunda üretilen bir sarmalayıcı
/// fonksiyonun tarifi (bkz. `genSpawnWrapper`). Sarmalayıcı, `nox_async_spawn`
/// tarafından bir fiber girişi olarak çağrılır (`fn(l %argp) l`) — argümanları
/// `%argp`nin gösterdiği kapanış (closure) struct'ından (`rt` + her argüman,
/// 8 baytlık aralıklarla) paketten çıkarıp `target_fn`i normal şekilde çağırır,
/// sonucu bir i64 "payload"a çevirir (bkz. `toPayload`).
/// stdlib fazı §D.1.6: `nox.http.serve(port, handle[, max_connections])`
/// çağrı sitesi başına TEMBEL kaydedilen, `generateModule`nin sonunda
/// üretilen bir C-ABI sarmalayıcının tarifi (bkz. `genHttpServeWrapper`) —
/// `SpawnWrapperSpec` İLE AYNI "tembel iş kuyruğu" deseni. Sarmalayıcı,
/// `runtime/stdlib_shims/http_server.zig`nin `HandlerFn`i olarak
/// `nox_http_serve_raw`a geçirilir (`fn(l %rt, l %req) l` — `rt` bir
/// KAPANIŞTAN DEĞİL doğrudan `handler_ctx` parametresi olarak taşınır,
/// bkz. `genHttpServe`nin belge notu — `spawn`ın kapanış paketlemesine
/// GEREK YOK, çünkü tek "yakalanan" değer zaten `rt`nin KENDİSİ).
const HttpServeWrapperSpec = struct {
    name: []const u8,
    handler_fn: []const u8,
    req_class: []const u8,
    resp_class: []const u8,
};

const SpawnWrapperSpec = struct {
    name: []const u8,
    target_fn: []const u8,
    sig: FuncSig,
};

/// Faz BB.4 (bkz. nox-teknik-spesifikasyon.md §3.50): `nox.thread.start
/// (entry, arg)` çağrı sitesi başına TEMBEL kaydedilen, `generateModule`nin
/// sonunda üretilen bir sarmalayıcının tarifi — `SpawnWrapperSpec` İLE AYNI
/// "tembel iş kuyruğu" deseni, AMA `genSpawnWrapper`DEN İKİ noktada FARKLI
/// (bkz. `genThreadStartWrapper`nin belge notu): (1) kapanış TEK bir
/// argüman TAŞIR (Tier 1'in `isThreadTransferSafeType` kısıtı GEREĞİ,
/// `sig.params.len` HER ZAMAN 1'dir), (2) kapanış `runtime/async_rt/
/// thread_bridge.zig`nin SAF Zig `ThreadEntryClosure` struct'ıdır (QBE'nin
/// KENDİ ürettiği bir yapı DEĞİL) — bu YÜZDEN argüman HER ZAMAN `toPayload`/
/// `fromPayload` İLE (i64) OKUNUR/YAZILIR, `genSpawnWrapper`nin native-
/// qtype'lı doğrudan `load`/`store`sinin AKSİNE.
const ThreadWrapperSpec = struct {
    name: []const u8,
    target_fn: []const u8,
    sig: FuncSig,
};

/// Faz DD.1 (bkz. nox-teknik-spesifikasyon.md §3.60) — `nox.http.
/// serve_multicore` çağrı sitesi başına TEMBEL kaydedilen, `generateModule`
/// nin sonunda üretilen bir "iş parçacığı girişi" worker fonksiyonunun
/// tarifi. `ThreadWrapperSpec`den FARKLI: bu worker'ın ARKASINDA GERÇEK
/// bir Nox `entry` fonksiyonu YOKTUR (`target_fn`/`sig` yok) — TAMAMEN
/// sentezlenir (`genHttpServeWrapper`nin `HandlerFn` sarmalayıcısını
/// sentezlemesiyle AYNI teknik): gövdesi `wrapper_name`i (ZATEN kayıtlı
/// bir `HttpServeWrapperSpec`) `nox_http_server_from_fd`+`nox_http_
/// serve_raw` ile ÇAĞIRIR. `max_conn_text`, checker'ın `.int_lit`
/// ZORUNLULUĞU SAYESİNDE derleme-zamanı bir metin sabitidir (bkz.
/// `tryResolveHttpServeMulticoreCall`in belge notu).
const HttpServeMulticoreWorkerSpec = struct {
    name: []const u8,
    wrapper_name: []const u8,
    max_conn_text: []const u8,
};

/// Faz U.4.3: bir closure'ın TEK bir yakalanan (capture) değeri — `name`
/// dış (kapsayan) fonksiyondaki KAYNAK isim, `info` o ismin DIŞ fonksiyondaki
/// TAM `TypeInfo`si (qtype/heap/class_name/vb. — `genNestedFuncDef`in
/// closure inşası SIRASINDA `self.vars.get(name)`den KOPYALANIR, çünkü
/// `ClosureFuncSpec` işlenene KADAR dış fonksiyonun `self.vars`ı ÇOKTAN
/// TEMİZLENMİŞ olur).
const ClosureCaptureField = struct { name: []const u8, info: TypeInfo };

/// Faz U.4.3: bir iç içe `def`in gövdesini (henüz derlenmemiş) TEMBEL
/// kaydı — `SpawnWrapperSpec`/`HttpServeWrapperSpec` İLE AYNI "sonda tüket"
/// deseni (bkz. `generateModule`nin ilgili `while` döngüsü). `path`,
/// checker'ın `ClosureInfo`sini (`closure_infos`) ARAMAK İÇİN kullanılan
/// AYNI dot-ayrılmış anahtardır (bkz. `genNestedFuncDef`in belge notu) —
/// bu closure'ın KENDİ gövdesi BAŞKA bir iç içe `def` İÇERİYORSA, o iç
/// içe def'in codegen'i `self.current_path`i BU DEĞERE (path) ayarlayarak
/// devam eder (rastgele derinlikte iç içeliği DOĞAL olarak destekler).
const ClosureFuncSpec = struct {
    mangled_name: []const u8,
    path: []const u8,
    fd: ast.FuncDef,
    captures: []const ClosureCaptureField,
};

const VarInfo = struct {
    slot: []const u8,
    qtype: QbeType,
    heap: HeapKind = .none,
    elem_qtype: QbeType = .none,
    class_name: ?[]const u8 = null,
    elem_heap_info: ?*const ElemHeapInfo = null,
    elem_is_str: bool = false,
    dict_info: ?*const DictInfo = null,
    func_sig: ?*const FuncSigInfo = null,
    is_param: bool = false,
    arena: bool = false,
};

const LocalDecl = struct {
    name: []const u8,
    info: TypeInfo,
    is_param: bool = false,
    arena: bool = false,
};

const StringDatum = struct {
    symbol: []const u8,
    escaped: []const u8,
};

const ClassField = struct {
    name: []const u8,
    info: TypeInfo,
    offset: usize,
};

/// Faz S.3: `genTraceDispatch`/`genGcFreeDispatch`in dal açacağı (isim,
/// `class_id`) çiftleri — `generateModule`de toplanır.
const ClassIdEntry = struct { name: []const u8, id: usize };

const ClassInfo = struct {
    fields: std.ArrayListUnmanaged(ClassField) = .empty,
    total_size: usize = 0,
    init_params: []const TypeInfo = &.{},
    methods: std.StringHashMapUnmanaged(FuncSig) = .empty,
    class_id: usize = 0,
    /// `false`: sınıfın bir `__init__`i yok (bkz. `registerClass`) — o zaman
    /// alan yoktur (`fields.items.len == 0`), kurucu 0 argüman alır ve
    /// `genConstruct` `$ClassName___init__`i HİÇ ÇAĞIRMAZ (çünkü üretilmedi,
    /// bkz. `generateModule`'ün yalnızca VAR OLAN metodları derlediği döngü).
    has_init: bool = true,
    /// `true`: `__init__`in ASLA istisna fırlatmadığı KANITLANDI (bkz.
    /// `computeMustNotRaise`) — bu durumda `genConstruct` kurucu çağrısından
    /// sonra `emitExceptionCheck`i ATLAR (performans fazı — bkz. görev
    /// "exception-check elision"). `has_init == false` ise zaten hiç çağrı
    /// üretilmediğinden bu alan anlamsızdır (kontrol edilmez).
    init_is_safe: bool = false,
};

const RT_PARAM = "%rt";
const FIELD_SLOT_SIZE: usize = 8;
/// Faz U.1: `list[T]` başlığının bayt boyutu — `{ len: i64 @0, cap: i64 @8,
/// elemanlar @16... }` (ÖNCEDEN yalnızca `{ len: i64 @0, elemanlar @8... }`
/// — kapasite kavramı YOKTU, uzunluk=kapasite ZORUNLUYDU). `.append()`in
/// GERÇEK paylaşım semantiği (bkz. `genListMethod`in belge notu — bir
/// alias, KAPASİTE YETERLİYSE AYNI bloğu gördüğünden, .append() TÜM
/// alias'larda GÖZÜKÜR) İÇİN kapasite alanı GEREKLİDİR. `runtime/stdlib_
/// shims/json.zig`nin `buildPtrList`i VE `runtime/stdlib_shims/strings.zig`nin
/// `nox_strings_split_raw`ı da AYNI düzeni EL İLE ürettiğinden (Zig
/// tarafında) BU SABİTLE TUTARLI kalmalıdır — bu ikisi DEĞİŞTİRİLİRSE
/// BURASI da GÜNCELLENMELİDİR (ve tersi).
const LIST_HEADER_SIZE: usize = 16;
/// Her sınıf örneğinin (refcount başlığından SONRA) taşıdığı, çalışma
/// zamanında `except ClassName:` eşleştirmesi için kullanılan tip etiketi.
const TAG_SIZE: usize = 8;

/// Faz U.4.3: `Codegen.current_path`i (checker'ın `FnCtx.path`iyle AYNI
/// dot-ayrılmış format, ör. `"outer.adder"`) GEÇERLİ bir QBE sembol adına
/// çevirir — QBE tanımlayıcıları `.` İÇEREMEZ, bu yüzden `.`→`_` DÖNÜŞTÜRÜLÜR.
/// `"closure_"` ÖNEKİ, olası bir kullanıcı fonksiyon/sınıf adıyla ÇAKIŞMAYI
/// ÖNLER (Nox tanımlayıcıları `_` İLE BAŞLAYABİLİR ama `mangleWith`/`registerFunc`
/// ürettiği hiçbir isim BU tam ÖNEKLE eşleşmez).
fn sanitizePathToSymbol(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(a, "closure_");
    for (path) |c| try buf.append(a, if (c == '.') '_' else c);
    return buf.toOwnedSlice(a);
}

fn qbeTypeName(t: QbeType) []const u8 {
    return switch (t) {
        .l => "l",
        .d => "d",
        .w => "w",
        .none => "",
    };
}

fn qbeSizeOf(t: QbeType) usize {
    return switch (t) {
        .w => 4,
        .l, .d => 8,
        .none => 0,
    };
}

/// Bir KONTEYNERİN (`list[T]`, `Task[T]`, `Channel[T]`) `elem_qtype`/
/// `elem_heap_info`/`elem_is_str` alanlarından, KENDİSİ okunan TEK bir
/// elemanın (`text`/`qtype` zaten hesaplanmış) TAM `Value`sini (doğru
/// `heap`/`class_name`/iç içe `elem_heap_info` ile) yeniden kurar —
/// `genIndex` (liste indeksleme), `genAwaitExpr` (`Task` sonucu) ve
/// `genChannelOp` (`Channel.recv`) arasında PAYLAŞILAN tek bir mantık.
fn valueFromElemDescriptor(text: []const u8, qtype: QbeType, container_elem_heap_info: ?*const ElemHeapInfo, container_elem_is_str: bool) Value {
    return .{
        .text = text,
        .qtype = qtype,
        .heap = if (container_elem_heap_info) |ehi| ehi.heap else if (container_elem_is_str) .str else .none,
        .class_name = if (container_elem_heap_info) |ehi| ehi.class_name else null,
        .elem_qtype = if (container_elem_heap_info) |ehi| ehi.elem_qtype else .none,
        .elem_heap_info = if (container_elem_heap_info) |ehi| ehi.nested else null,
    };
}

fn cmpMnemonic(op: ast.BinaryOp, common: QbeType) []const u8 {
    if (common == .d) {
        return switch (op) {
            .eq => "ceqd",
            .ne => "cned",
            .lt => "cltd",
            .le => "cled",
            .gt => "cgtd",
            .ge => "cged",
            else => unreachable,
        };
    }
    if (common == .w) {
        return switch (op) {
            .eq => "ceqw",
            .ne => "cnew",
            else => unreachable,
        };
    }
    return switch (op) {
        .eq => "ceql",
        .ne => "cnel",
        .lt => "csltl",
        .le => "cslel",
        .gt => "csgtl",
        .ge => "csgel",
        else => unreachable,
    };
}

fn escapeForQbeString(allocator: std.mem.Allocator, s: []const u8) CodegenError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Faz FF.3 (bkz. nox-teknik-spesifikasyon.md §3.62): `.dict` ARTIK
/// `.list`/`.class`/`.str`/`.closure` İLE AYNI TAM ARC modelindedir —
/// ÖNCEDEN `Task`/`Channel`/`ThreadHandle`/`ThreadChannel` İLE AYNI "tek
/// sahiplilik, koşulsuz yıkım" grubundaydı (GERÇEK bir sallanan-işaretçi
/// açığıydı, bkz. `dict.zig`nin modül-üstü notu) — o GRUP artık DÖRT
/// TÜRE indi (bkz. `destroyNonArcValue`).
fn isHeapManaged(h: HeapKind) bool {
    // Faz FF.6.4: `boxed_scalar` (kutulanmış `int | None`/`float | None`/
    // `bool | None`) TAM ARC yoluna (retain/release, `emitInlineRetain`in
    // ARTIK null-güvenli KOPYASI DAHİL) diğer heap tipleriyle AYNI şekilde
    // girer — İÇİNDE nested bir heap referansı OLMADIĞINDAN (ham bir skaler)
    // `releaseValueIfSet`in `.boxed_scalar` dalı ÖZYİNELEMESİZ, basit bir
    // `nox_rc_free_payload`dır.
    return h == .list or h == .class or h == .str or h == .closure or h == .dict or h == .boxed_scalar;
}

/// `expr` değerlendirildiğinde TAZE (henüz hiçbir isme/alana/elemana
/// bağlanmamış, hiçbir bağımsız release'i olmayan) bir heap değeri üretir mi?
/// Bir çağrı (`.call` — fonksiyon/metod/kurucu), bir liste literali
/// (`.list_lit`) YA DA bir ikili ifade (`.binary` — v1'de yalnızca `str + str`
/// birleştirmesi HEAP değeri üretir, bkz. `genBinary`; diğer ikili operatörler
/// zaten `heap = .none` ürettiğinden çağıran taraftaki `isHeapManaged(v.heap)`
/// eşlik-kontrolü onları ZATEN elemektedir — bu yüzden `.binary`yi KOŞULSUZ
/// `true` saymak güvenlidir) taze bir değer üretir; bir isim (`.identifier`),
/// bir alan okuması (`.attribute`) ya da bir indeksleme (`.index`) her zaman
/// BAŞKA BİR YERDE (yerel, alan, parametre) ZATEN sahibi olan, ödünç alınmış
/// bir referanstır ve ASLA körlemesine serbest bırakılmamalıdır — bkz.
/// `releaseTemporaryArgs`/`releaseIfTemporary`.
fn isTemporaryExpr(expr: ast.Expr) bool {
    return switch (expr) {
        // Faz FF.3 (bkz. nox-teknik-spesifikasyon.md §3.62): `.dict_lit`
        // ÖNCEDEN buradan EKSİKTİ — `dict`in `isHeapManaged`in DIŞINDA
        // olduğu ESKİ modelde bu EKSİKLİK etkisizdi (`releaseTemporaryArgs`/
        // `retainIfAliasing` ZATEN `isHeapManaged(v.heap)`e göre gated'di,
        // `dict` İÇİN her ikisi de HİÇ ÇALIŞMAZDI). `dict` ARTIK TAM ARC'lı
        // OLDUĞUNDAN bu eksiklik GERÇEK bir sızıntıya dönüştü: `HttpResponse(
        // 200, "ok", {"x": "x"})` gibi adlandırılmamış bir dict LİTERALİ
        // argüman olarak geçilince, `__init__`in `self.headers = data`sı
        // (`retainIfAliasing`, `data` bir PARAMETRE — `isAliasingExpr`
        // `.identifier`i HER ZAMAN aliasing SAYAR) refcount'u 1→2 retain
        // ediyordu, ama `isTemporaryExpr({"x":"x"}) == false` (bu satır
        // OLMADAN) `releaseTemporaryArgs`in dengeleyici release'ini HİÇ
        // TETİKLEMİYORDU — refcount ASLA 2→1'e inmiyordu (kanıtlandı, bkz.
        // `http_serve_golden_test.zig`nin bu YOLU KANITLAYAN sızıntı testi).
        .call, .list_lit, .dict_lit, .binary => true,
        // Bir alan zincirinin (ör. `make_car(i).engine`) TABANI temporary
        // ise, `genFieldRead` heap tipli alanı taban serbest bırakılmadan
        // ÖNCE retain eder (bkz. genFieldRead) — bu da okunan alanı, tıpkı
        // bir `.call` sonucu gibi, kendi releaser'ı olmayan TAZE bir değere
        // dönüştürür. Bu yüzden zincir özyinelemeli olarak kök nesneye kadar
        // izlenmeli; taban sıradan bir isimse (`x.engine`) bu ödünç alınmış
        // kalır ve hâlâ `false` döner.
        .attribute => |a| isTemporaryExpr(a.obj.*),
        // `.attribute`nin AYNI gerekçesi (bkz. yukarıdaki not) `.index`e de
        // uygulanır: bir liste zincirinin (ör. `make_list()[0]`) TABANI
        // temporary ise, `genIndex` heap tipli elemanı taban serbest
        // bırakılmadan ÖNCE retain eder (bkz. genIndex) — okunan eleman da
        // kendi releaser'ı olmayan TAZE bir değere dönüşür. Stdlib fazı
        // §F'de BULUNAN gerçek bir sızıntı: `list[str]` döndüren bir
        // `with_rt extern def`in sonucu ADLANDIRILMIŞ bir yerele
        // BAĞLANMADAN doğrudan indekslenince (ör.
        // `print(nox_test_make_list(3)[0])`), bu dal EKSİKTİ — `genIndex`
        // elemanı doğru retain ediyordu ama ÇAĞIRAN (`print`) bunu ASLA
        // serbest bırakmıyordu (taban SIRADAN bir isim SANILDIĞINDAN,
        // `else => false`e düşüyordu) — gerçek bir sızıntı.
        .index => |idx| isTemporaryExpr(idx.obj.*),
        else => false,
    };
}

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Modülün (üst düzey deyimler + tüm fonksiyon/metod gövdeleri) HERHANGİ bir
/// yerinde `async` özelliği (bir `async def`, `spawn`, `await`, ya da
/// `Channel[T](...)`) kullanılıp kullanılmadığını belirler — `generateModule`
/// bunu, `main`i fiber-sarmalı bir kökle mi (`genMainAsync`) yoksa ŞİMDİYE
/// KADAR OLDUĞU GİBİ değişmeden mi (`genMain`) üreteceğine karar vermek için
/// kullanır (bkz. nox-teknik-spesifikasyon.md §3.21, aşama 4 — "async
/// KULLANMAYAN programlar sıfır ek maliyetle DEĞİŞMEDEN derlenir").
fn moduleUsesAsync(module: ast.Module, extra_functions: []const ast.FuncDef) bool {
    for (module.body) |stmt| if (stmtUsesAsync(stmt)) return true;
    for (extra_functions) |fd| {
        if (fd.is_async) return true;
        for (fd.body) |s| if (stmtUsesAsync(s)) return true;
    }
    return false;
}

fn stmtUsesAsync(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .expr_stmt => |e| exprUsesAsync(e),
        .var_decl => |v| exprUsesAsync(v.value),
        .assign => |a| exprUsesAsync(a.target) or exprUsesAsync(a.value),
        .if_stmt => |f| blk: {
            if (exprUsesAsync(f.cond)) break :blk true;
            for (f.then_body) |s| if (stmtUsesAsync(s)) break :blk true;
            for (f.elif_clauses) |ec| {
                if (exprUsesAsync(ec.cond)) break :blk true;
                for (ec.body) |s| if (stmtUsesAsync(s)) break :blk true;
            }
            if (f.else_body) |eb| for (eb) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .while_stmt => |w| blk: {
            if (exprUsesAsync(w.cond)) break :blk true;
            for (w.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .for_stmt => |f| blk: {
            if (exprUsesAsync(f.iterable)) break :blk true;
            for (f.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .func_def => |fd| blk: {
            if (fd.is_async) break :blk true;
            for (fd.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .class_def => |cd| blk: {
            for (cd.methods) |m| {
                if (m.is_async) break :blk true;
                for (m.body) |s| if (stmtUsesAsync(s)) break :blk true;
            }
            break :blk false;
        },
        .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => false,
        .return_stmt => |r| if (r) |e| exprUsesAsync(e) else false,
        .raise_stmt => |e| exprUsesAsync(e),
        .try_stmt => |t| blk: {
            for (t.try_body) |s| if (stmtUsesAsync(s)) break :blk true;
            for (t.except_clauses) |ec| for (ec.body) |s| if (stmtUsesAsync(s)) break :blk true;
            if (t.finally_body) |fb| for (fb) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .lowlevel_stmt => |ll| blk: {
            for (ll.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
        .with_stmt => |w| blk: {
            if (exprUsesAsync(w.ctx_expr)) break :blk true;
            for (w.body) |s| if (stmtUsesAsync(s)) break :blk true;
            break :blk false;
        },
    };
}

/// `nox.http.<name>(...)` çağrı sitesinin callee'sinin TAM OLARAK bu
/// şekilde (üç seviyeli `Attribute`/`Attribute`/`identifier` zinciri)
/// ayrıştırılıp ayrıştırılMADIĞINI belirler — hem `exprUsesAsync`in `.call`
/// dalı hem de `Codegen.genCall`in `.attribute` dalı bu ŞEKLİ tanıyıp özel
/// işlemeye yönlendirmek için kullanır (bkz. checker.zig'in `matchesNoxHttpCall`
/// İLE AYNI desen — o da AYNI şekli tanır, ama BU noktada çağrının callee'si
/// `tryResolveQualifiedCall`in AKSİNE mangled bir isme YENİDEN YAZILMAZ, bu
/// yüzden codegen KENDİSİ şekli TANIMAK ZORUNDADIR). Faz DD.1'de `nox.http.
/// serve_fd`/`serve_multicore`İ de tanıyacak şekilde genelleştirildi (bkz.
/// `isHttpServeCallee`/`isHttpServeFdCallee`/`isHttpServeMulticoreCallee`).
fn matchesNoxHttpAttr(callee: ast.Expr, name: []const u8) bool {
    if (callee != .attribute) return false;
    const attr = callee.attribute;
    if (!std.mem.eql(u8, attr.attr, name)) return false;
    if (attr.obj.* != .attribute) return false;
    const http_attr = attr.obj.attribute;
    if (!std.mem.eql(u8, http_attr.attr, "http")) return false;
    if (http_attr.obj.* != .identifier) return false;
    return std.mem.eql(u8, http_attr.obj.identifier, "nox");
}

fn isHttpServeCallee(callee: ast.Expr) bool {
    return matchesNoxHttpAttr(callee, "serve");
}

/// Faz DD.1 (bkz. nox-teknik-spesifikasyon.md §3.60).
fn isHttpServeFdCallee(callee: ast.Expr) bool {
    return matchesNoxHttpAttr(callee, "serve_fd");
}

/// Faz DD.1 (bkz. nox-teknik-spesifikasyon.md §3.60).
fn isHttpServeMulticoreCallee(callee: ast.Expr) bool {
    return matchesNoxHttpAttr(callee, "serve_multicore");
}

/// Faz BB.4 — `isHttpServeCallee` İLE AYNI yapısal eşleştirme, `nox.thread.
/// start(entry, arg)` İÇİN (bkz. `checker.zig`nin `tryResolveThreadSpawnCall`ı
/// — checker'ın "start" ismini TERCİH ETMESİNİN gerekçesi İÇİN bkz. onun
/// belge notu, `spawn`ın ZATEN bir anahtar kelime OLMASI).
fn isThreadStartCallee(callee: ast.Expr) bool {
    if (callee != .attribute) return false;
    const start_attr = callee.attribute;
    if (!std.mem.eql(u8, start_attr.attr, "start")) return false;
    if (start_attr.obj.* != .attribute) return false;
    const thread_attr = start_attr.obj.attribute;
    if (!std.mem.eql(u8, thread_attr.attr, "thread")) return false;
    if (thread_attr.obj.* != .identifier) return false;
    return std.mem.eql(u8, thread_attr.obj.identifier, "nox");
}

fn exprUsesAsync(expr: ast.Expr) bool {
    return switch (expr) {
        .await_expr, .spawn_expr, .generic_construct => true,
        .unary => |u| exprUsesAsync(u.operand.*),
        .binary => |b| exprUsesAsync(b.left.*) or exprUsesAsync(b.right.*),
        .call => |c| blk: {
            // stdlib fazı §D.1.6: `nox.http.serve`nin KENDİSİ (kqueue
            // reaktörü üzerinden fiber-native `accept`/`read`/`write` yapan
            // `nox_http_serve_raw`ı ÇAĞIRDIĞINDAN) bir programın TEK async
            // özelliği OLABİLİR — `handle` (çıplak bir isim argümanı) VE
            // `nox.http.serve`nin KENDİSİ (bir `.identifier`/`.attribute`
            // zinciri) buradaki DİĞER dallardan HİÇBİRİNİ TETİKLEMEZ, bu
            // yüzden ŞEKLİ AÇIKÇA tanımak GEREKİR (bkz. `isHttpServeCallee`).
            if (isHttpServeCallee(c.callee.*)) break :blk true;
            // Faz DD.1: `serve_fd`/`serve_multicore` da AYNI gerekçeyle
            // (KENDİLERİ `nox_http_serve_raw`/`nox_thread_spawn` çağırır)
            // "async kullanır" sayılmalı.
            if (isHttpServeFdCallee(c.callee.*)) break :blk true;
            if (isHttpServeMulticoreCallee(c.callee.*)) break :blk true;
            if (isThreadStartCallee(c.callee.*)) break :blk true;
            if (exprUsesAsync(c.callee.*)) break :blk true;
            for (c.args) |a| if (exprUsesAsync(a)) break :blk true;
            break :blk false;
        },
        .attribute => |a| exprUsesAsync(a.obj.*),
        .index => |idx| exprUsesAsync(idx.obj.*) or exprUsesAsync(idx.index.*),
        .list_lit => |elems| blk: {
            for (elems) |el| if (exprUsesAsync(el)) break :blk true;
            break :blk false;
        },
        .dict_lit => |pairs| blk: {
            for (pairs) |p| {
                if (exprUsesAsync(p.key) or exprUsesAsync(p.value)) break :blk true;
            }
            break :blk false;
        },
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => false,
    };
}

/// `genForList`nin gizli döngü indeksi için `self.vars` içinde kullanılan
/// isim — kullanıcı tanımlı isimlerle asla çakışmayan `$` önekiyle (bkz.
/// `collectLocals`deki belge notu).
fn forListIdxName(allocator: std.mem.Allocator, var_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "$idx_{s}", .{var_name});
}

const Codegen = struct {
    allocator: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    /// Faz T.3: `generateModule`e bir `debug_source_path` VERİLDİYSE `true` —
    /// `genStmts` (TÜM deyim kodgen'inin TEK dağıtım noktası, bkz. `checkStmt`
    /// İLE AYNI T.1 deseni) HER deyimden ÖNCE bir `dbgloc <satır>` (QBE IL,
    /// `.loc <dosya> <satır>` derleyici direktifine düşer — bkz. modül üstü
    /// not) yayınlar. `false` İKEN sıfır ek maliyet/çıktı (v1'de OPT-IN,
    /// `-g` bayrağı OLMADAN varsayılan çıktı DEĞİŞMEZ).
    debug_info: bool = false,
    functions: std.StringHashMapUnmanaged(FuncSig) = .empty,
    /// `extern def` bildirimleri — AYRI bir tablo (normal `functions`dan
    /// bağımsız): çağrı sitesi kodgen'i temelde farklıdır (bkz. `genCall`) —
    /// extern fonksiyonlar Nox'un `rt` bağlamını (İlke #6'nın gerektirdiği
    /// açık parametre) ALMAZ ve Nox'un istisna mekanizmasına katılmaz
    /// (bkz. nox-teknik-spesifikasyon.md §3.20).
    extern_functions: std.StringHashMapUnmanaged(FuncSig) = .empty,
    classes: std.StringHashMapUnmanaged(ClassInfo) = .empty,
    vars: std.StringHashMapUnmanaged(VarInfo) = .empty,
    /// Faz FF.6.4 (bkz. nox-teknik-spesifikasyon.md §3.65): `genIf`/`genWhile`nin
    /// `checker.zig`'in `FnCtx.narrowed`iyle AYNI DAR örüntüyü (yalnızca
    /// `if x != None:`/`if x == None:`) MEKANİK olarak YANSITAN örtüsü —
    /// kutulanmış bir Optional-ilkel (`HeapKind.boxed_scalar`) İÇİN,
    /// checker'ın statik tipi `T`ye DARALTTIĞI bir gövde İÇİNDE, `genExpr`in
    /// `.identifier` dalı BURADA ADI OLAN bir değişkeni kutunun KENDİSİ
    /// (pointer) YERİNE İÇİNDEKİ ham skaleri (unboxed) DÖNDÜRMELİDİR — HEAP
    /// tiplerin AKSİNE (temsil AYNI, hiçbir codegen değişikliği GEREKMEDİ)
    /// kutulanmış bir skalerin temsili `T`den TAMAMEN FARKLIDIR (pointer vs.
    /// ham değer), bu yüzden codegen'in KENDİSİNİN de "şu an neredeyiz"i
    /// bilmesi GEREKİR.
    narrowed_unbox: std.StringHashMapUnmanaged(void) = .empty,
    /// Faz GG.5 (manuel LICM — bkz. nox-teknik-spesifikasyon.md §3.66):
    /// `str`-tipli, bir döngü gövdesi İÇİNDE HİÇ yeniden atanmayan bir
    /// isim `s[i]` İLE indekslendiğinde, `genStrIndex`in sınır kontrolü
    /// İçin GEREKTİRDİĞİ `strlen(s)` HER erişimde YENİDEN çağrılmak
    /// YERİNE döngüye girmeden HEMEN ÖNCE BİR KEZ hesaplanıp burada
    /// (isim → önceden hesaplanmış QBE temp'i) SAKLANIR. `genWhile`/
    /// `genForRange`/`genForList` `enterStrLenCacheScope`/
    /// `exitStrLenCacheScope` ÇİFTİYLE bu haritayı KENDİ gövdeleri
    /// SÜRESİNCE doldurup TEMİZLER (iç içe döngüler, dış döngünün
    /// ÖNCEDEN eklediği bir GİRİŞİ TEKRAR eklemez/silmez — bkz.
    /// `enterStrLenCacheScope`in belge notu).
    str_len_cache: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Faz GG.9 (kanıtlanabilir sınır-içi erişimlerde bounds-check elemesi
    /// — bkz. nox-teknik-spesifikasyon.md §3.66): `for i in range(len(xs)):
    /// ... xs[i] ...` deseninde `i`nin `[0, len(xs))` ARALIĞINDA olduğu
    /// döngünün KENDİ `range(len(xs))` sınırından ZATEN KANITLANMIŞTIR —
    /// `genIndex`/`genStrIndex`nin AYRICA ürettiği sınır kontrolü (karşılaştırma
    /// + `IndexError` dalı) GEREKSİZDİR. `genForRange`, TAM OLARAK bu deseni
    /// (`f.iterable == range(len(<isim>))`, `<isim>` VE döngü değişkeninin
    /// gövde İÇİNDE HİÇ yeniden atanmadığı, hiçbir iç içe closure OLMADIĞI —
    /// `str_len_cache`in AYNI güvenlik disipliniyle) TESPİT EDİLDİĞİNDE bu
    /// alanı doldurup döngü BİTTİĞİNDE ESKİ değere geri YÜKLER (iç içe
    /// döngüler, tıpkı `str_len_cache` gibi, DOĞRU şekilde gölgelenir/
    /// geri yüklenir). Hem `list[T]` (`genIndex`) hem `str` (`genStrIndex`)
    /// indekslemesi TARAFINDAN kontrol edilir — heap türünden BAĞIMSIZ TEK
    /// bir bağlam yeterlidir (`obj.heap` ZATEN o dalda BİLİNİYOR).
    bounds_elide_ctx: ?BoundsElideCtx = null,
    temp_counter: usize = 0,
    label_counter: usize = 0,
    string_counter: usize = 0,
    string_data: std.ArrayListUnmanaged(StringDatum) = .empty,
    next_class_id: usize = 1,
    /// `list[T]`nin elemanları heap-yönetimliyken (sınıf/iç içe liste) gereken
    /// `$List_<mangled>_release` fonksiyonlarının TEMBEL kaydı — `string_data`
    /// gibi kodgen sırasında keşfedilir, `generateModule`nin sonunda TÜKETİLİR
    /// (işlenirken YENİ iç içe ihtiyaçlar keşfedilebileceğinden bir kuyruk).
    list_release_seen: std.StringHashMapUnmanaged(void) = .empty,
    list_release_queue: std.ArrayListUnmanaged(struct { name: []const u8, info: ElemHeapInfo }) = .empty,
    /// list[T] için derin yapısal eşitlik (bkz. görev "list/class için derin
    /// yapısal eşitlik") — `$List_<mangled>_eq(rt, a, b) w` fonksiyonlarının
    /// TEMBEL kaydı. `list_release_queue` ile AYNI desen (kuyruk + görülenler
    /// kümesi), ama AYRI bir mangling şeması kullanır (`eqMangleFor`):
    /// release yalnızca heap-yönetimli (sınıf/iç içe liste) elemanları önemser
    /// (str/int/float/bool AYNI "prim" kovasına düşer, release'leri hiç
    /// gerekmediğinden), eşitlik ise HER eleman türü için FARKLI bir
    /// karşılaştırma operasyonu (str→strcmp, int/float/bool→ceq*) gerektirir —
    /// bu yüzden `str` ile `int` burada AYRI mangled adlara sahiptir.
    list_eq_seen: std.StringHashMapUnmanaged(void) = .empty,
    list_eq_queue: std.ArrayListUnmanaged(struct { name: []const u8, elem_qtype: QbeType, elem_heap_info: ?*const ElemHeapInfo, elem_is_str: bool }) = .empty,
    /// `print(list[T]/sınıf)` görüntülemesinin (bkz. `internFmtString`) sınıf/
    /// alan adı gibi derleme-zamanı sabit metinlerden ürettiği `printf` format
    /// dizesi sembolleri — `string_data`den FARKLI olarak pinned-refcount
    /// başlığı TAŞIMAZLAR (asla bir Nox `str` DEĞERİ olarak dolaşmazlar).
    fmt_counter: usize = 0,
    fmt_data: std.ArrayListUnmanaged(StringDatum) = .empty,
    /// Faz 21 aşama 4: her `spawn <çağrı>` çağrı sitesi için üretilecek
    /// `$spawn_wrap_N(l %argp) l` sarmalayıcılarının TEMBEL kaydı —
    /// `list_release_queue` ile AYNI desen, `generateModule`nin sonunda
    /// tüketilir (bkz. `genSpawnWrapper`).
    spawn_wrapper_counter: usize = 0,
    spawn_wrappers: std.ArrayListUnmanaged(SpawnWrapperSpec) = .empty,
    /// stdlib fazı §D.1.6 — `spawn_wrapper_counter`/`spawn_wrappers` İLE
    /// AYNI desen, `nox.http.serve` çağrı siteleri İÇİN.
    http_serve_wrapper_counter: usize = 0,
    http_serve_wrappers: std.ArrayListUnmanaged(HttpServeWrapperSpec) = .empty,
    /// Faz BB.4 — `spawn_wrapper_counter`/`spawn_wrappers` İLE AYNI desen,
    /// `nox.thread.start` çağrı siteleri İÇİN (bkz. `ThreadWrapperSpec`in
    /// belge notu).
    thread_wrapper_counter: usize = 0,
    thread_wrappers: std.ArrayListUnmanaged(ThreadWrapperSpec) = .empty,
    /// Faz DD.1 — `thread_wrapper_counter`/`thread_wrappers` İLE AYNI
    /// desen, `nox.http.serve_multicore` çağrı siteleri İÇİN (bkz.
    /// `HttpServeMulticoreWorkerSpec`in belge notu).
    http_serve_multicore_worker_counter: usize = 0,
    http_serve_multicore_workers: std.ArrayListUnmanaged(HttpServeMulticoreWorkerSpec) = .empty,
    /// Faz U.4.3: checker'ın hesapladığı closure yakalama (capture) listeleri
    /// — anahtar `"<dış_yol>.<iç_isim>"` (bkz. `checker.zig`nin `ClosureInfo`si,
    /// `Checker.closure_infos`), DEĞER yalnızca yakalanan İSİMLER (tipleri
    /// codegen KENDİSİ, dış fonksiyonun O ANKİ `self.vars`ından türetir —
    /// bkz. `genNestedFuncDef`in belge notu, checker<->codegen ARASINDA
    /// bir `Type`↔`TypeInfo` dönüştürücüsüne gerek KALMAZ).
    closure_infos: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    /// Şu an derlenen fonksiyonun/metodun/iç içe `def`in "yolu" — checker'ın
    /// `FnCtx.path`i İLE BİREBİR AYNI FORMÜLLE hesaplanır (üst-düzey: kendi
    /// adı; metod: `"Sınıf.metod"`; iç içe: `"<dış_yol>.<iç_isim>"`) —
    /// `closure_infos`i DOĞRU anahtarla aramak İÇİN checker İLE TUTARLI
    /// olmalıdır.
    current_path: []const u8 = "",
    /// `SpawnWrapperSpec`/`HttpServeWrapperSpec` İLE AYNI "TEMBEL kayıt,
    /// sonda tüket" deseni — bir iç içe `def`in gövdesi, DIŞ fonksiyonun
    /// KENDİ derlemesi SIRASINDA DEĞİL, `generateModule`nin SONUNDA (bkz.
    /// onun ilgili `while` döngüsü) AYRI bir QBE fonksiyonu olarak derlenir.
    closure_funcs: std.ArrayListUnmanaged(ClosureFuncSpec) = .empty,
    /// Serbest fonksiyon adlarının (ve `"ClassName___init__"` biçimindeki
    /// kurucu sembollerinin) kümesi — YALNIZCA (transitif olarak) ASLA bir
    /// istisna FIRLATAMAYACAKLARI KANITLANMIŞ olanlar (bkz.
    /// `computeMustNotRaise`in belge notu, performans fazı: `nox_exception_
    /// pending` çağrıları `fib`-tarzı özyinelemeli kodda örneklerin ~%49'unu
    /// oluşturuyordu). `genCall`/`genConstruct` bu kümedeki bir çağrı
    /// SONRASI `emitExceptionCheck`i ATLAR. Metod çağrıları (`obj.method()`)
    /// BU KÜMEYE HİÇ GİRMEZ (bkz. `computeMustNotRaise`in "muhafazakâr"
    /// notu) — her zaman kontrol edilirler, bu yüzden bu alan yalnızca
    /// serbest fonksiyon/kurucu sembolleri içerir.
    must_not_raise: std.StringHashMapUnmanaged(void) = .empty,
    /// Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): "inline edilebilir"
    /// KANITLANMIŞ serbest fonksiyonların (isim → AST gövdesi) haritası —
    /// `computeInlinableFunctions` tarafından doldurulur, `prepareInlineSites`
    /// tarafından OKUNUR (bir çağrı sitesinin `.identifier`i BU haritada
    /// VARSA, o site inline-adayı olarak KAYDEDİLİR).
    inlinable_funcs: std.StringHashMapUnmanaged(ast.FuncDef) = .empty,
    /// Faz GG.2: (transitif olarak) KENDİ KENDİSİNİ çağıran serbest
    /// fonksiyon/metod sembollerinin kümesi — `markRecursiveFuncs`
    /// tarafından doldurulur, `computeInlinableFunctions` bu kümedeki
    /// HİÇBİR fonksiyonu inline-edilebilir SAYMAZ (bkz. onun belge notu,
    /// "kendi içine inline etmenin dejenere durumu").
    recursive_funcs: std.StringHashMapUnmanaged(void) = .empty,
    /// Faz GG.2: BİR çağrı sitesinin (`ast.Call.callee` POINTER'ı,
    /// `@intFromPtr` İLE anahtarlanır — parser arena'sından HER site İçin
    /// BENZERSİZ) inline edileceğine dair `prepareInlineSites`in ÖNCEDEN
    /// verdiği KARARI VE bu splice İçin ÖN-TAHSİS EDİLMİŞ slotları taşır.
    /// `genCall`'ın `.identifier` dalı BU haritaya BAKARAK normal `call`
    /// yerine `genInlinedCall`e DÜŞER.
    inline_sites: std.AutoHashMapUnmanaged(usize, InlineSiteInfo) = .empty,
    /// Faz GG.2: `genInlinedCall` bir splice ÜRETİRKEN AYARLANIR (splice
    /// SONRASI eski değerine GERİ YÜKLENİR) — `genStmts`in `.return_stmt`
    /// dalı bu DOLUYSA gerçek bir `ret` YERİNE sonuç slotuna YAZIP `jmp`
    /// eder (bkz. `InlineReturnTarget`in belge notu).
    inline_return_target: ?InlineReturnTarget = null,
    /// İşlenmekte olan fonksiyon/metodun dönüş tipi — bir çağrıdan sonra
    /// bekleyen bir istisna varsa ve yakalayan bir `try` yoksa, bu tipte
    /// varsayılan bir değerle erken çıkmak için gerekli (bkz. `emitExceptionCheck`).
    current_ret_qtype: QbeType = .none,
    /// Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `current_ret_qtype`in
    /// TAM `TypeInfo` hâli — `return None` gibi bağlam-duyarlı `.none_lit`
    /// üretiminde (bkz. `genExprForTarget`) hedefin `heap`/`class_name`/vb.
    /// bilgisine ihtiyaç var, salt QBE skaler tipi YETMEZ.
    current_ret_info: TypeInfo = .{ .qtype = .none },
    /// İçinde bulunulan en yakın `try` bloğunun sevk (dispatch) etiketi;
    /// `null` ise (try dışındaysak) bir istisna doğrudan fonksiyon dışına
    /// yayılır (bkz. `emitExceptionCheck`).
    current_catch_label: ?[]const u8 = null,
    /// `main`'in kendi gövdesini üretirken `true` — yakalanmamış bir istisna
    /// `main`'den sızarsa (bkz. `emitExceptionCheck`) bu, sessizce `ret 0`
    /// yerine `nox_unhandled_exception` çağrısıyla programı sıfırdan farklı
    /// bir kodla sonlandırmak gerektiğini bildirir (bkz. bilinen sınırlama:
    /// diğer fonksiyonlardan sızan istisnalar normal şekilde çağırana yayılır).
    in_main: bool = false,
    /// İçinde bulunulan `try`lerin `finally` gövdelerinin yığını (en dıştan en
    /// içe). Python gibi, `finally` `try`/`except` içindeki bir `return`'de
    /// bile ÇALIŞMALIDIR — QBE'de paylaşılan bir "unwind" hedefi olmadığından
    /// (İlke #3), bu `return_stmt` tarafından `drainFinally` ile gerçek
    /// `ret`ten hemen önce satır içi (inline) üretilerek sağlanır.
    finally_stack: std.ArrayListUnmanaged([]const ast.Stmt) = .empty,
    /// İçinde bulunulan `lowlevel` bloklarının arena işaretçileri yığını (en
    /// dıştan en içe) — Katman 4 (AGENTS.md §8). Her `return`/yakalanmamış
    /// istisna, `finally` gibi, bu arenaları da (`drainArenas`) gerçek
    /// çıkıştan önce toplu olarak yıkmalıdır.
    arena_stack: std.ArrayListUnmanaged([]const u8) = .empty,
    /// `> 0`: şu an bir `lowlevel` bloğunun (doğrudan ya da iç içe) içindeyiz.
    /// Basitlik ve güvenlik için, bu blok içindeyken heap tipli (`list`/sınıf)
    /// hiçbir değer bir çağrıya argüman/alıcı olamaz, döndürülemez, başka bir
    /// isme takma ad olamaz ya da bir liste literaline eklenemez — arena mı
    /// ARC mı olduğuna bakılmaksızın (bkz. nox-teknik-spesifikasyon.md §3.8).
    in_lowlevel_depth: usize = 0,

    fn newTemp(self: *Codegen) CodegenError![]const u8 {
        const n = self.temp_counter;
        self.temp_counter += 1;
        return std.fmt.allocPrint(self.allocator, "%t{d}", .{n});
    }

    fn newLabel(self: *Codegen, comptime prefix: []const u8) CodegenError![]const u8 {
        const n = self.label_counter;
        self.label_counter += 1;
        return std.fmt.allocPrint(self.allocator, "@{s}{d}", .{ prefix, n });
    }

    fn resolveType(self: *Codegen, te: ast.TypeExpr) CodegenError!TypeInfo {
        switch (te) {
            .simple => |name| {
                if (std.mem.eql(u8, name, "int")) return .{ .qtype = .l };
                if (std.mem.eql(u8, name, "float")) return .{ .qtype = .d };
                if (std.mem.eql(u8, name, "bool")) return .{ .qtype = .w };
                if (std.mem.eql(u8, name, "None")) return .{ .qtype = .none };
                if (std.mem.eql(u8, name, "str")) return .{ .qtype = .l, .heap = .str };
                // `ptr` — Faz 20'nin ikinci artımı (bkz. nox-teknik-
                // spesifikasyon.md §3.20): ARC-İZLENMEYEN opak bir işaretçi
                // (`heap = .none`, `list`/`class` gibi ÖZEL bir dispatch
                // GEREKTİRMEZ — düz bir `l` değeridir, `int` gibi).
                if (std.mem.eql(u8, name, "ptr")) return .{ .qtype = .l, .heap = .none };
                if (self.classes.contains(name)) return .{ .qtype = .l, .heap = .class, .class_name = name };
                return error.Unsupported;
            },
            .generic => |g| {
                if (std.mem.eql(u8, g.name, "dict")) {
                    if (g.args.len != 2) return error.Unsupported;
                    const key = try self.resolveType(g.args[0]);
                    const value = try self.resolveType(g.args[1]);
                    // v1 kapsamı (checker.zig'in `typeExprToType`indeki
                    // `"dict"` dalıyla TUTARLI): K int/bool/str, V int/float/
                    // bool/str — sınıf/list/dict/Task/Channel anahtar/değer
                    // checker'da ZATEN reddedilir, burası savunmacıdır.
                    if (key.heap != .none and key.heap != .str) return error.Unsupported;
                    if (value.heap != .none and value.heap != .str) return error.Unsupported;
                    const dinfo = try self.allocator.create(DictInfo);
                    dinfo.* = .{ .key_is_str = key.heap == .str, .value_qtype = value.qtype, .value_is_str = value.heap == .str };
                    return .{ .qtype = .l, .heap = .dict, .dict_info = dinfo };
                }
                const is_list = std.mem.eql(u8, g.name, "list");
                const is_task = std.mem.eql(u8, g.name, "Task");
                const is_channel = std.mem.eql(u8, g.name, "Channel");
                const is_thread_handle = std.mem.eql(u8, g.name, "ThreadHandle");
                const is_thread_channel = std.mem.eql(u8, g.name, "ThreadChannel");
                if (!(is_list or is_task or is_channel or is_thread_handle or is_thread_channel) or g.args.len != 1) return error.Unsupported;
                const elem = try self.resolveType(g.args[0]);
                var elem_heap_info: ?*const ElemHeapInfo = null;
                // `str` DAHİL — bkz. `ElemHeapInfo.nested`in belge notu:
                // stdlib fazı §B'den beri `str` de ARC-yönetimli, `list[str]`
                // elemanlarının özyinelemeli release'e girmesi İÇİN burada da
                // `elem_heap_info` doldurulmalı (`genListElemRelease`in
                // `info.nested`in `.str` özel durumuna bkz.).
                if (elem.heap == .class or elem.heap == .list or elem.heap == .str) {
                    const info = try self.allocator.create(ElemHeapInfo);
                    info.* = .{ .heap = elem.heap, .class_name = elem.class_name, .elem_qtype = elem.elem_qtype, .nested = elem.elem_heap_info, .elem_is_str = elem.elem_is_str };
                    elem_heap_info = info;
                } else if (elem.heap != .none) {
                    return error.Unsupported;
                }
                // `list[T]`nin KENDİSİ (heap=.list) ARC-yönetimlidir (refcount
                // başlığı, retain-on-alias). `Task[T]`/`Channel[T]`nin KENDİSİ
                // İSE DEĞİLDİR (heap=.task/.channel, `isHeapManaged`in DIŞINDA
                // — bkz. `HeapKind`in belge notu) — zamanlayıcı kendi ömrünü
                // kendi yönetir, kapsam-sonu temizliği DOĞRUDAN bir `nox_async_
                // destroy_task`/`nox_channel_destroy` çağrısıdır (predecrement
                // YOK, bkz. `releaseAllLocalsExcept`). `elem_qtype`/
                // `elem_heap_info`/`elem_is_str` PAYLOAD (T) tipini tam olarak
                // taşır — `await`/`Channel.recv`in doğru tipte bir SONUÇ değeri
                // üretebilmesi için (bkz. `genAwaitExpr`, `genChannelOp`).
                return .{
                    .qtype = .l,
                    .heap = if (is_list) .list else if (is_task) .task else if (is_channel) .channel else if (is_thread_handle) .thread_handle else .thread_channel,
                    .elem_qtype = elem.qtype,
                    .elem_heap_info = elem_heap_info,
                    .elem_is_str = elem.heap == .str,
                };
            },
            // Faz U.4.3: bir closure değeri, ARC pointer AÇISINDAN `class`
            // İLE AYNIdır (bkz. `HeapKind.closure`nin belge notu) — YALNIZCA
            // `class_name` (BURADA bilinçli olarak `null`, çünkü SALT bir
            // TİP İFADESİNDEN hangi SOMUT closure kastedildiği bilinemez)
            // gerçek bir SOMUT closure DEĞERİNİN (bir iç içe `def` deyiminin
            // KENDİSİ tarafından, bkz. `genNestedFuncDef`) `VarInfo`sinde
            // doldurulur. Faz U.4.4: STATİK imza (`func_sig`, bkz.
            // `FuncSigInfo`in belge notu) BURADA, tip ifadesinin KENDİSİNDEN
            // her zaman TAM olarak çözülür — dolaylı çağrının (`genCall`in
            // `.closure` dalı) argüman/dönüş tiplerini bilebilmesi İÇİN
            // yeterlidir, SOMUT closure'ın kimliği GEREKMEZ.
            .func_type => |ft| {
                const params = try self.allocator.alloc(TypeInfo, ft.params.len);
                for (ft.params, 0..) |pt, i| params[i] = try self.resolveType(pt);
                const ret = try self.resolveType(ft.return_type.*);
                const sig = try self.allocator.create(FuncSigInfo);
                sig.* = .{ .params = params, .ret = ret };
                return .{ .qtype = .l, .heap = .closure, .func_sig = sig };
            },
            // Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `T | None`.
            // TAM ARC-yönetimli heap tipler (`class`/`str`/`list`/`dict`/
            // `closure` — bkz. `isHeapManaged`) VE `ptr` İÇİN Optional'ın
            // çalışma zamanı temsili taban tiple TAMAMEN AYNIDIR (null
            // pointer = None, dolu pointer = Some(x)) — ARC release/eşitlik/
            // trace/gc-free KODUNUN HİÇBİRİ DEĞİŞMEZ (zaten null-güvenli,
            // bkz. `releaseValueIfSet`); retain'e de AYRICA bir null-güvenlik
            // eklendi (bkz. `emitInlineRetain`in belge notu). Bu yüzden
            // burada YALNIZCA taban tipin `TypeInfo`si AYNEN döndürülür —
            // codegen SEVİYESİNDE ayrı bir "Optional" temsili YOKTUR
            // (yalnızca checker'ın daraltma denetimi bu ayrımı bilir).
            // BİLİNÇLİ v1 DIŞI bırakılanlar: `Task`/`Channel`/`ThreadHandle`/
            // `ThreadChannel` (ARC-DIŞI, KENDİ ayrı yıkım mekanizmaları var —
            // bkz. `destroyNonArcValue`, null-güvenlikleri AYRICA
            // doğrulanmadı).
            .optional => |inner_te| {
                const inner = try self.resolveType(inner_te.*);
                const is_ptr = switch (inner_te.*) {
                    .simple => |n| std.mem.eql(u8, n, "ptr"),
                    else => false,
                };
                if (isHeapManaged(inner.heap) or is_ptr) return inner;
                // Faz FF.6.4: `int | None`/`float | None`/`bool | None` —
                // İLKELLERİN QBE'de "boş" temsil edecek yedek biti
                // OLMADIĞINDAN (bkz. spec §3.65), tek-alanlı, ARC-yönetimli
                // BASİT bir kutu (`HeapKind.boxed_scalar`) İÇİNE sarılır.
                // `elem_qtype` KUTUNUN İÇİNDEKİ GERÇEK skaler QBE tipini
                // taşır (`list[T]`in `elem_qtype`iyle AYNI deseni yeniden
                // kullanır) — kutunun KENDİSİ HER ZAMAN `.l` (pointer).
                if (inner.heap == .none and (inner.qtype == .l or inner.qtype == .d or inner.qtype == .w)) {
                    return .{ .qtype = .l, .heap = .boxed_scalar, .elem_qtype = inner.qtype };
                }
                return error.Unsupported;
            },
        }
    }

    // ---- Sınıf kaydı (fonksiyon/main gövdeleri üretilmeden ÖNCE tamamlanmalı) ----

    fn registerClass(self: *Codegen, cd: ast.ClassDef) CodegenError!void {
        var init_fd: ?ast.FuncDef = null;
        for (cd.methods) |m| {
            if (std.mem.eql(u8, m.name, "__init__")) init_fd = m;
        }

        var info: ClassInfo = .{};
        // Faz FF.5 (bkz. nox-teknik-spesifikasyon.md §3.64): AÇIKÇA
        // bildirilen alanlar, `__init__` gövdesi taranmadan ÖNCE (bildirim
        // SIRASIYLA) `info.fields`e eklenir — tipleri `resolveType` İLE
        // DOĞRUDAN çözülür (metod parametreleri/dönüşleri İçin ZATEN
        // kullanılan AYNI genel çözücü), `inferFieldType`nin dar
        // YETENEĞİNİ (yalnızca `self`/`__init__` parametresi/literal)
        // TAMAMEN ATLAR. Aşağıdaki `__init__`-tarama döngüsünün MEVCUT
        // "zaten var mı" kontrolü (`exists`), bu ÖNCEDEN eklenmiş alanları
        // OTOMATİK olarak ATLAR — `inferFieldType`e HİÇ uğramazlar.
        for (cd.fields) |fd| {
            try info.fields.append(self.allocator, .{
                .name = fd.name,
                .info = try self.resolveType(fd.type_expr),
                .offset = TAG_SIZE + info.fields.items.len * FIELD_SLOT_SIZE,
            });
        }
        if (init_fd) |init| {
            for (init.body) |stmt| {
                if (stmt.kind != .assign) continue;
                const a = stmt.kind.assign;
                if (a.target != .attribute) continue;
                const attr = a.target.attribute;
                if (attr.obj.* != .identifier or !std.mem.eql(u8, attr.obj.identifier, "self")) continue;
                var exists = false;
                for (info.fields.items) |f| {
                    if (std.mem.eql(u8, f.name, attr.attr)) {
                        exists = true;
                        break;
                    }
                }
                if (exists) continue;
                const ftype = try self.inferFieldType(cd.name, init.params[1..], a.value);
                try info.fields.append(self.allocator, .{
                    .name = attr.attr,
                    .info = ftype,
                    .offset = TAG_SIZE + info.fields.items.len * FIELD_SLOT_SIZE,
                });
            }
            info.total_size = TAG_SIZE + info.fields.items.len * FIELD_SLOT_SIZE;

            const iparams = try self.allocator.alloc(TypeInfo, init.params.len - 1);
            for (init.params[1..], 0..) |p, i| iparams[i] = try self.resolveType(p.type_expr);
            info.init_params = iparams;
        } else {
            // `__init__`i olmayan sınıf (bkz. `ClassInfo.has_init`in belge
            // notu): kurucu 0 argüman alır — checker zaten bu durumda
            // çağrı sitesinde 0 argüman şart koşar (bkz. checker.zig,
            // `checkCall`in `.identifier` dalı, `init_sig orelse` varsayılanı).
            // Faz FF.5: bildirilen alanlar (varsa) YİNE de `info.fields`de
            // KALIR (yukarıda eklendi) — ama checker BU durumu (bildirilen
            // bir alanın `__init__` OLMADIĞI İçin HİÇ atanamaması) ZATEN
            // `UnassignedField` İLE REDDETTİĞİNDEN (bkz. `checkClassBody`),
            // bu yol PRATİKTE codegen'e HİÇ ULAŞMAZ — yalnızca savunmacı
            // tutarlılık İçin `total_size` yine de alanları HESABA katar.
            info.has_init = false;
            info.total_size = TAG_SIZE + info.fields.items.len * FIELD_SLOT_SIZE;
        }
        info.class_id = self.next_class_id;
        self.next_class_id += 1;

        for (cd.methods) |m| {
            if (std.mem.eql(u8, m.name, "__init__")) continue;
            const params = try self.allocator.alloc(TypeInfo, m.params.len - 1);
            for (m.params[1..], 0..) |p, i| params[i] = try self.resolveType(p.type_expr);
            const ret = try self.resolveType(m.return_type);
            try info.methods.put(self.allocator, m.name, .{ .params = params, .ret = ret });
        }

        try self.classes.put(self.allocator, cd.name, info);
    }

    /// Bir sınıf alanının tipini yalnızca gerçekçi/yaygın örüntülerden çıkarır:
    /// doğrudan bir `__init__` parametresi, `self` (bkz. aşağı), ya da bir
    /// literal. Daha karmaşık ifadeler (checker'ın tam tip çıkarımını burada
    /// yeniden uygulamamak için) bilinçli olarak desteklenmiyor.
    fn inferFieldType(self: *Codegen, class_name: []const u8, init_params: []const ast.Param, expr: ast.Expr) CodegenError!TypeInfo {
        switch (expr) {
            .identifier => |name| {
                // Faz S.3: `self.next = self` — bir nesnenin KENDİ türünden
                // bir alana KENDİSİNE atanması (öz-referans). `generateModule`nin
                // TÜM sınıf adlarını (alanları çözülmeden ÖNCE) boş bir yer
                // tutucuyla `self.classes`a ÖNCEDEN eklemesi SAYESİNDE
                // (stdlib fazı §L'nin `list[JsonValue]` düzeltmesi, bkz. onun
                // belge notu) `class_name`in KENDİSİ bu noktada ZATEN
                // kayıtlıdır — bu, GERÇEK bir A↔B referans döngüsü kurmanın
                // bootstrap adımıdır (bkz. Faz S.3, `runtime/alloc/
                // cycle_detector.zig`): bir nesne `__init__` İÇİNDE KENDİSİNE
                // (geçerli, KISMİ ama tahsis edilmiş bir `self` işaretçisine)
                // işaret ederek başlar (1-döngülük bir öz-döngü), SONRADAN
                // `a.next = b; b.next = a;` gibi bir yeniden atamayla GERÇEK
                // bir A↔B döngüsüne dönüştürülebilir — `None`/opsiyonel tipler
                // OLMADAN kullanılabilecek EN BASİT bootstrap deseni.
                if (std.mem.eql(u8, name, "self")) {
                    return .{ .qtype = .l, .heap = .class, .class_name = class_name };
                }
                for (init_params) |p| {
                    if (std.mem.eql(u8, p.name, name)) {
                        // `list[T]` alanlar (bkz. görev "Sınıf alanı list[T]
                        // tipinde olabilsin") — `resolveType` zaten TAM
                        // `elem_qtype`/`elem_heap_info`/`elem_is_str`
                        // betimleyicisini üretir; `genClassRelease` bunu
                        // `releaseValueIfSet` üzerinden özyinelemeli release
                        // için kullanır (bkz. `genClassRelease`in belge
                        // notu). Sınıf tipli alanlar (öz-referans DAHİL —
                        // bkz. yukarıdaki `self` dalı VE stdlib fazı §L'nin
                        // `list[JsonValue]` düzeltmesi) `resolveType`'ın
                        // `self.classes.contains` kontrolü SAYESİNDE artık
                        // ileri-referanslı sınıflara da (aynı modüldeki HER
                        // sınıf ÖNCEDEN yer tutucuyla kaydedildiğinden)
                        // referans verebilir.
                        return try self.resolveType(p.type_expr);
                    }
                }
                return error.Unsupported;
            },
            .int_lit => return .{ .qtype = .l },
            .float_lit => return .{ .qtype = .d },
            .bool_lit => return .{ .qtype = .w },
            .string_lit => return .{ .qtype = .l, .heap = .str },
            else => return error.Unsupported,
        }
    }

    fn registerFunc(self: *Codegen, fd: ast.FuncDef) CodegenError!void {
        const params = try self.allocator.alloc(TypeInfo, fd.params.len);
        for (fd.params, 0..) |p, i| params[i] = try self.resolveType(p.type_expr);
        const ret = try self.resolveType(fd.return_type);
        try self.functions.put(self.allocator, fd.name, .{ .params = params, .ret = ret });
    }

    fn registerExternFunc(self: *Codegen, ed: ast.ExternDef) CodegenError!void {
        const params = try self.allocator.alloc(TypeInfo, ed.params.len);
        for (ed.params, 0..) |p, i| params[i] = try self.resolveType(p.type_expr);
        const ret = try self.resolveType(ed.return_type);
        try self.extern_functions.put(self.allocator, ed.name, .{ .params = params, .ret = ret, .needs_rt = ed.needs_rt });
    }

    fn collectLocals(self: *Codegen, locals: *std.ArrayListUnmanaged(LocalDecl), stmts: []const ast.Stmt, in_lowlevel: bool) CodegenError!void {
        for (stmts) |stmt| {
            switch (stmt.kind) {
                .var_decl => |v| {
                    const info = try self.resolveType(v.type_expr);
                    try locals.append(self.allocator, .{ .name = v.name, .info = info, .arena = in_lowlevel });
                },
                .for_stmt => |f| {
                    if (isRangeCall(f.iterable)) {
                        try locals.append(self.allocator, .{ .name = f.var_name, .info = .{ .qtype = .l } });
                    } else if (f.iterable == .identifier) {
                        const src = findLocal(locals.items, f.iterable.identifier) orelse return error.Unsupported;
                        if (src.heap != .list) return error.Unsupported;
                        // Döngü değişkeni listenin İÇİNDEKİ bir elemana ÖDÜNÇ
                        // ALINMIŞ bir referanstır (listenin kendisi hâlâ
                        // sahibidir) — heap-yönetimli elemanlarda (Faz 21
                        // ön-koşulu) bunu `is_param = true` ile işaretlemek
                        // (teknik olarak parametre olmasa da) kapsam-sonu
                        // otomatik release'i ATLATIR; aksi halde listenin
                        // KENDİ sahipliğini bozan bir çifte-serbest-bırakma
                        // riski doğardı. `.class`/iç-içe `.list` DIŞINDA
                        // (int/float/bool/str) bu zaten etkisizdir.
                        var loop_var_info: TypeInfo = .{ .qtype = src.elem_qtype };
                        if (src.elem_heap_info) |ehi| {
                            loop_var_info.heap = ehi.heap;
                            loop_var_info.class_name = ehi.class_name;
                            loop_var_info.elem_qtype = ehi.elem_qtype;
                            loop_var_info.elem_heap_info = ehi.nested;
                        } else if (src.elem_is_str) {
                            loop_var_info.heap = .str;
                        }
                        try locals.append(self.allocator, .{ .name = f.var_name, .info = loop_var_info, .is_param = true });
                        // `genForList`nin dahili döngü indeksi için gizli bir
                        // yerel — FONKSİYON GİRİŞİNDE (`allocSlot` ile) BİR
                        // KEZ tahsis edilmesi gerekir. Aksi halde (bu `for`
                        // başka bir döngünün içine gömülüyse) `genForList`nin
                        // kendi `alloc8`'i her dış yinelemede yığını küçültüp
                        // asla geri almaz — bkz. `adjustModSign`deki AYNI
                        // yığın taşması hatası ve oradaki belge notu.
                        try locals.append(self.allocator, .{ .name = try forListIdxName(self.allocator, f.var_name), .info = .{ .qtype = .l } });
                    } else {
                        return error.Unsupported;
                    }
                    try self.collectLocals(locals, f.body, in_lowlevel);
                },
                .if_stmt => |f| {
                    try self.collectLocals(locals, f.then_body, in_lowlevel);
                    for (f.elif_clauses) |ec| try self.collectLocals(locals, ec.body, in_lowlevel);
                    if (f.else_body) |eb| try self.collectLocals(locals, eb, in_lowlevel);
                },
                .while_stmt => |w| try self.collectLocals(locals, w.body, in_lowlevel),
                .try_stmt => |t| {
                    try self.collectLocals(locals, t.try_body, in_lowlevel);
                    for (t.except_clauses) |ec| {
                        if (!self.classes.contains(ec.class_name)) return error.Unsupported;
                        if (ec.bind_name) |bn| {
                            try locals.append(self.allocator, .{
                                .name = bn,
                                .info = .{ .qtype = .l, .heap = .class, .class_name = ec.class_name },
                                .arena = in_lowlevel,
                            });
                        }
                        try self.collectLocals(locals, ec.body, in_lowlevel);
                    }
                    if (t.finally_body) |fb| try self.collectLocals(locals, fb, in_lowlevel);
                },
                .lowlevel_stmt => |ll| try self.collectLocals(locals, ll.body, true),
                // Faz U.4.3: bir iç içe `def`in BAĞLADIĞI isim (`fd.name`)
                // BAŞKA bir yerel gibi ÖNCEDEN (fonksiyon girişinde) bir
                // slota sahip OLMALIDIR — `genNestedFuncDef` (bkz. `genStmts`in
                // `.func_def` dalı) BU slotu construction ANINDA doldurur.
                // `class_name` BURADA (mangled sembol adı) ÖNCEDEN
                // hesaplanır — checker İLE AYNI FORMÜL (`self.current_path`
                // + "." + `fd.name`), `genNestedFuncDef`in construction
                // ANINDA BAĞIMSIZ olarak YENİDEN hesapladığı DEĞERLE
                // TUTARLI kalması İÇİN (bkz. `sanitizePathToSymbol`).
                .func_def => |fd| {
                    const path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.current_path, fd.name });
                    const mangled = try sanitizePathToSymbol(self.allocator, path);
                    try locals.append(self.allocator, .{ .name = fd.name, .info = .{ .qtype = .l, .heap = .closure, .class_name = mangled } });
                },
                // Faz U.5: `with EXPR as NAME:` — İKİ gizli/örtük yerel
                // GEREKİR: (1) `EXPR`in değerini TUTAN, fonksiyon-genelinde
                // bir gizli yerel (`__with_ctx_L<satır>` — bkz. `genWith`in
                // belge notu, AYNI formül) ve (2) `binding` VERİLDİYSE onun
                // KENDİ slotu. `EXPR`in SINIFI (bkz. `inferWithCtxClassName`)
                // codegen'in (checker'ın AKSİNE tam tip çıkarımı OLMAYAN)
                // KISITLI desenlerinden (`ClassAdı(...)` kurucu çağrısı YA
                // DA ZATEN bilinen bir yerel) çıkarılır — `for x in xs:`nin
                // AYNI kısıtıyla TUTARLI (bkz. yukarıdaki `.for_stmt` dalı).
                .with_stmt => |w| {
                    const class_name = try self.inferWithCtxClassName(w.ctx_expr, locals.items);
                    try locals.append(self.allocator, .{
                        .name = try std.fmt.allocPrint(self.allocator, "__with_ctx_L{d}", .{stmt.line}),
                        .info = .{ .qtype = .l, .heap = .class, .class_name = class_name },
                        .arena = in_lowlevel,
                    });
                    if (w.binding) |bn| {
                        const cinfo = self.classes.get(class_name).?;
                        const enter_sig = cinfo.methods.get("__enter__") orelse return error.Unsupported;
                        try locals.append(self.allocator, .{ .name = bn, .info = enter_sig.ret, .arena = in_lowlevel });
                    }
                    try self.collectLocals(locals, w.body, in_lowlevel);
                },
                .class_def, .protocol_def, .extern_def => return error.Unsupported,
                else => {},
            }
        }
    }

    /// Faz U.5: `collectLocals`in `.with_stmt` dalı İÇİN — `ctx_expr`in
    /// SINIFINI, checker'ın TAM tip çıkarımı OLMADAN, YALNIZCA iki gerçekçi
    /// desenden çıkarır: doğrudan bir `ClassAdı(...)` kurucu çağrısı (ör.
    /// `with FileHandle("x.txt") as f:`) ya da ZATEN bilinen (önceden
    /// `locals`e eklenmiş) bir sınıf tipli yerelin adı (ör. `with existing_
    /// resource:`). Başka HİÇBİR ifade şekli (alan okuması, metod çağrısı,
    /// indeksleme...) v1 kapsamında DESTEKLENMEZ — `inferFieldType`in AYNI
    /// bilinçli dar kapsamıyla TUTARLI.
    fn inferWithCtxClassName(self: *Codegen, ctx_expr: ast.Expr, locals: []const LocalDecl) CodegenError![]const u8 {
        switch (ctx_expr) {
            .call => |c| {
                if (c.callee.* != .identifier) return error.Unsupported;
                const name = c.callee.identifier;
                if (!self.classes.contains(name)) return error.Unsupported;
                return name;
            },
            .identifier => |name| {
                const info = findLocal(locals, name) orelse return error.Unsupported;
                if (info.heap != .class) return error.Unsupported;
                return info.class_name orelse return error.Unsupported;
            },
            else => return error.Unsupported,
        }
    }

    fn allocSlot(self: *Codegen, name: []const u8, info: TypeInfo, is_param: bool, arena: bool) CodegenError!void {
        const slot = try self.newTemp();
        const size: usize = if (info.qtype == .w) 4 else 8;
        try self.out.writer.print("    {s} =l alloc{d} {d}\n", .{ slot, size, size });
        if (isHeapManaged(info.heap) and !is_param) {
            try self.out.writer.print("    storel 0, {s}\n", .{slot});
        }
        try self.vars.put(self.allocator, name, .{
            .slot = slot,
            .qtype = info.qtype,
            .heap = info.heap,
            .elem_qtype = info.elem_qtype,
            .class_name = info.class_name,
            .elem_heap_info = info.elem_heap_info,
            .elem_is_str = info.elem_is_str,
            .dict_info = info.dict_info,
            .func_sig = info.func_sig,
            .is_param = is_param,
            .arena = arena,
        });
    }

    /// Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): `allocSlot`in AYNISI
    /// (slotu QBE giriş bloğunda tahsis eder, heap-yönetimliyse sıfırla
    /// doldurur) AMA `self.vars`a HİÇ YAZMAZ — YALNIZCA bir `NamedSlot`
    /// döner. Bir inline-splice sitesinin ÖN-TAHSİS EDİLMİŞ slotları BURADAN
    /// geçer, ÇÜNKÜ `self.vars`a KALICI olarak yazmak (normal `allocSlot`
    /// gibi) caller'IN AYNI isimli KENDİ yerelini (varsa) KALICI olarak
    /// EZERDİ — `genInlinedCall` bunun yerine BU slotu YALNIZCA splice
    /// SÜRESİNCE `self.vars`a GEÇİCİ olarak GÖLGELER (bkz. onun belge notu).
    fn allocInlineSlot(self: *Codegen, orig_name: []const u8, info: TypeInfo, is_param: bool) CodegenError!NamedSlot {
        const slot = try self.newTemp();
        const size: usize = if (info.qtype == .w) 4 else 8;
        try self.out.writer.print("    {s} =l alloc{d} {d}\n", .{ slot, size, size });
        if (isHeapManaged(info.heap) and !is_param) {
            try self.out.writer.print("    storel 0, {s}\n", .{slot});
        }
        return .{ .orig_name = orig_name, .slot = slot, .info = info };
    }

    fn genFunction(self: *Codegen, fd: ast.FuncDef) CodegenError!void {
        self.vars.clearRetainingCapacity();
        self.narrowed_unbox.clearRetainingCapacity();
        self.temp_counter = 0;
        self.label_counter = 0;
        self.current_path = fd.name;

        const ret_info = try self.resolveType(fd.return_type);
        self.current_ret_qtype = ret_info.qtype;
        self.current_ret_info = ret_info;
        self.current_catch_label = null;
        self.in_main = false;

        var locals: std.ArrayListUnmanaged(LocalDecl) = .empty;
        defer locals.deinit(self.allocator);
        for (fd.params) |p| {
            try locals.append(self.allocator, .{ .name = p.name, .info = try self.resolveType(p.type_expr), .is_param = true });
        }
        try self.collectLocals(&locals, fd.body, false);

        if (ret_info.qtype == .none) {
            try self.out.writer.print("export function ${s}(l {s}", .{ fd.name, RT_PARAM });
        } else {
            try self.out.writer.print("export function {s} ${s}(l {s}", .{ qbeTypeName(ret_info.qtype), fd.name, RT_PARAM });
        }
        for (fd.params) |p| {
            try self.out.writer.writeAll(", ");
            const info = try self.resolveType(p.type_expr);
            try self.out.writer.print("{s} %p_{s}", .{ qbeTypeName(info.qtype), p.name });
        }
        try self.out.writer.writeAll(") {\n@start\n");

        for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
        try self.prepareInlineSites(fd.body);
        for (fd.params) |p| {
            const info = self.vars.get(p.name).?;
            try self.out.writer.print("    store{s} %p_{s}, {s}\n", .{ qbeTypeName(info.qtype), p.name, info.slot });
        }

        try self.genStmts(fd.body, ret_info.qtype);
        try self.releaseAllLocals();

        const end_label = try self.newLabel("fn_end");
        try self.out.writer.print("{s}\n", .{end_label});
        try self.emitDefaultReturn(ret_info.qtype);
        try self.out.writer.writeAll("}\n");
    }

    fn genMethod(self: *Codegen, class_name: []const u8, m: ast.FuncDef) CodegenError!void {
        self.vars.clearRetainingCapacity();
        self.narrowed_unbox.clearRetainingCapacity();
        self.temp_counter = 0;
        self.label_counter = 0;
        self.current_path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ class_name, m.name });

        const ret_info = try self.resolveType(m.return_type);
        self.current_ret_qtype = ret_info.qtype;
        self.current_ret_info = ret_info;
        self.current_catch_label = null;
        self.in_main = false;

        var locals: std.ArrayListUnmanaged(LocalDecl) = .empty;
        defer locals.deinit(self.allocator);
        try locals.append(self.allocator, .{
            .name = "self",
            .info = .{ .qtype = .l, .heap = .class, .class_name = class_name },
            .is_param = true,
        });
        for (m.params[1..]) |p| {
            try locals.append(self.allocator, .{ .name = p.name, .info = try self.resolveType(p.type_expr), .is_param = true });
        }
        try self.collectLocals(&locals, m.body, false);

        const fn_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ class_name, m.name });
        if (ret_info.qtype == .none) {
            try self.out.writer.print("export function ${s}(l {s}, l %p_self", .{ fn_name, RT_PARAM });
        } else {
            try self.out.writer.print("export function {s} ${s}(l {s}, l %p_self", .{ qbeTypeName(ret_info.qtype), fn_name, RT_PARAM });
        }
        for (m.params[1..]) |p| {
            try self.out.writer.writeAll(", ");
            const info = try self.resolveType(p.type_expr);
            try self.out.writer.print("{s} %p_{s}", .{ qbeTypeName(info.qtype), p.name });
        }
        try self.out.writer.writeAll(") {\n@start\n");

        for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
        try self.prepareInlineSites(m.body);
        {
            const info = self.vars.get("self").?;
            try self.out.writer.print("    storel %p_self, {s}\n", .{info.slot});
        }
        for (m.params[1..]) |p| {
            const info = self.vars.get(p.name).?;
            try self.out.writer.print("    store{s} %p_{s}, {s}\n", .{ qbeTypeName(info.qtype), p.name, info.slot });
        }

        try self.genStmts(m.body, ret_info.qtype);
        try self.releaseAllLocals();

        const end_label = try self.newLabel("fn_end");
        try self.out.writer.print("{s}\n", .{end_label});
        try self.emitDefaultReturn(ret_info.qtype);
        try self.out.writer.writeAll("}\n");
    }

    /// Faz U.4.3/U.4.4: bir iç içe `def` DEYİMİNİN (`genStmts`in `.func_def`
    /// dalı) codegen'i — DIŞ (kapsayan) fonksiyonun BAĞLAMINDA çalışır
    /// (`self.vars` HÂLÂ dış fonksiyonun yerellerini İÇERİR). İKİ İŞ yapar:
    /// 1. Closure HEAP BLOĞUNU İNŞA eder (`{fn_ptr: l @0, release_fn_ptr: l
    ///    @8, yakalananlar... @16+}` — bkz. `HeapKind.closure`in belge notu,
    ///    Faz U.4.4'ün offset-8'e release fonksiyon işaretçisi EKLEMESİ)
    ///    — `genConstructFromValues`in AYNI `nox_rc_alloc` + alan-doldurma
    ///    deseni, ama ALAN İSİMLERİ yerine checker'ın capture SIRASI kullanılır.
    ///    Her yakalanan DEĞER, DIŞ fonksiyonun O ANKİ slotundan yüklenir;
    ///    heap-yönetimliyse RETAIN edilir (closure KENDİ bağımsız referansını
    ///    TUTAR — bkz. nox-teknik-spesifikasyon.md §3.23, "değer anlık
    ///    görüntüsü" kararı).
    /// 2. İç fonksiyonun GÖVDESİNİ (henüz DERLENMEMİŞ) `self.closure_funcs`e
    ///    TEMBEL kaydeder (bkz. `ClosureFuncSpec`in belge notu) — GERÇEK QBE
    ///    fonksiyonu `generateModule`nin SONUNDA (`genClosureFunc`) üretilir.
    ///
    /// `fd.name`, ÖNCEDEN (bkz. `collectLocals`in `.func_def` dalı, AYNI
    /// `path`/`mangled` FORMÜLÜYLE) `self.vars`e KAYDEDİLMİŞ olmalıdır —
    /// burada YALNIZCA o slotun DEĞERİ (yeni inşa edilen pointer) YAZILIR,
    /// tıpkı bir `var_decl`in KENDİ slotuna yazması gibi (bkz. `genStmts`in
    /// `.var_decl` dalı, AYNI "önce ESKİYİ serbest bırak, SONRA YENİYİ yaz"
    /// sırası — bir DÖNGÜ İÇİNDE tekrar tekrar TANIMLANAN bir iç içe `def`
    /// İÇİN GÜVENLİ olması İÇİN).
    fn genNestedFuncDef(self: *Codegen, fd: ast.FuncDef) CodegenError!void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ self.current_path, fd.name });
        const mangled = try sanitizePathToSymbol(self.allocator, path);
        const capture_names = self.closure_infos.get(path) orelse &[_][]const u8{};

        const captures = try self.allocator.alloc(ClosureCaptureField, capture_names.len);
        for (capture_names, 0..) |name, i| {
            const src = self.vars.get(name) orelse return error.Unsupported;
            captures[i] = .{ .name = name, .info = .{
                .qtype = src.qtype,
                .heap = src.heap,
                .elem_qtype = src.elem_qtype,
                .class_name = src.class_name,
                .elem_heap_info = src.elem_heap_info,
                .elem_is_str = src.elem_is_str,
                .dict_info = src.dict_info,
            } };
        }

        const total_size = CLOSURE_HEADER_SIZE + 8 * captures.len;
        const block = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_rc_alloc(l {s}, l {d})\n", .{ block, RT_PARAM, total_size });
        try self.out.writer.print("    storel ${s}, {s}\n", .{ mangled, block });
        {
            const rel_addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, 8\n", .{ rel_addr, block });
            try self.out.writer.print("    storel ${s}_release, {s}\n", .{ mangled, rel_addr });
        }
        for (captures, 0..) |c, i| {
            const offset = CLOSURE_HEADER_SIZE + 8 * i;
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, block, offset });
            const src_slot = self.vars.get(c.name).?;
            const v = try self.newTemp();
            try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ v, qbeTypeName(src_slot.qtype), qbeTypeName(src_slot.qtype), src_slot.slot });
            if (isHeapManaged(c.info.heap)) try self.emitInlineRetain(v);
            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(src_slot.qtype), v, addr });
        }

        const bound = self.vars.get(fd.name).?;
        try self.releaseSlotIfSet(bound);
        try self.out.writer.print("    storel {s}, {s}\n", .{ block, bound.slot });

        try self.closure_funcs.append(self.allocator, .{ .mangled_name = mangled, .path = path, .fd = fd, .captures = captures });
    }

    /// Faz U.4.3: `self.closure_funcs`e TEMBEL kaydedilen bir iç içe `def`in
    /// GERÇEK gövdesini üretir — `genFunction`in AYNI iskeleti, İKİ FARKLA:
    /// (1) imzaya gizli bir `l %env` parametresi (RT_PARAM'DAN HEMEN SONRA)
    /// eklenir; (2) HER yakalanan (capture) değer, NORMAL bir parametre
    /// GİBİ (`is_param = true` — kapsam-sonu release'i ATLAR, bkz.
    /// `LocalDecl`in belge notu, "ödünç alınmış referans" deseni) KENDİ
    /// slotuna sahip olur, AMA değeri bir QBE `%p_<isim>` argüman
    /// REGISTER'INDAN DEĞİL, `%env`nin `CLOSURE_HEADER_SIZE + 8*i` OFSETİNDEN
    /// YÜKLENEREK doldurulur. Bu İKİ FARK dışında gövde (`genStmts`) TAMAMEN NORMAL
    /// çalışır — capture'lar "sıradan, ÖNCEDEN doldurulmuş yereller" gibi
    /// GÖRÜNÜR.
    fn genClosureFunc(self: *Codegen, spec: ClosureFuncSpec) CodegenError!void {
        self.vars.clearRetainingCapacity();
        self.narrowed_unbox.clearRetainingCapacity();
        self.temp_counter = 0;
        self.label_counter = 0;
        self.current_path = spec.path;

        const ret_info = try self.resolveType(spec.fd.return_type);
        self.current_ret_qtype = ret_info.qtype;
        self.current_ret_info = ret_info;
        self.current_catch_label = null;
        self.in_main = false;

        var locals: std.ArrayListUnmanaged(LocalDecl) = .empty;
        defer locals.deinit(self.allocator);
        for (spec.captures) |c| {
            try locals.append(self.allocator, .{ .name = c.name, .info = c.info, .is_param = true });
        }
        for (spec.fd.params) |p| {
            try locals.append(self.allocator, .{ .name = p.name, .info = try self.resolveType(p.type_expr), .is_param = true });
        }
        try self.collectLocals(&locals, spec.fd.body, false);

        if (ret_info.qtype == .none) {
            try self.out.writer.print("export function ${s}(l {s}, l %env", .{ spec.mangled_name, RT_PARAM });
        } else {
            try self.out.writer.print("export function {s} ${s}(l {s}, l %env", .{ qbeTypeName(ret_info.qtype), spec.mangled_name, RT_PARAM });
        }
        for (spec.fd.params) |p| {
            try self.out.writer.writeAll(", ");
            const info = try self.resolveType(p.type_expr);
            try self.out.writer.print("{s} %p_{s}", .{ qbeTypeName(info.qtype), p.name });
        }
        try self.out.writer.writeAll(") {\n@start\n");

        for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
        try self.prepareInlineSites(spec.fd.body);
        for (spec.captures, 0..) |c, i| {
            const offset = CLOSURE_HEADER_SIZE + 8 * i;
            const info = self.vars.get(c.name).?;
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add %env, {d}\n", .{ addr, offset });
            const v = try self.newTemp();
            try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ v, qbeTypeName(info.qtype), qbeTypeName(info.qtype), addr });
            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(info.qtype), v, info.slot });
        }
        for (spec.fd.params) |p| {
            const info = self.vars.get(p.name).?;
            try self.out.writer.print("    store{s} %p_{s}, {s}\n", .{ qbeTypeName(info.qtype), p.name, info.slot });
        }

        try self.genStmts(spec.fd.body, ret_info.qtype);
        try self.releaseAllLocals();

        const end_label = try self.newLabel("fn_end");
        try self.out.writer.print("{s}\n", .{end_label});
        try self.emitDefaultReturn(ret_info.qtype);
        try self.out.writer.writeAll("}\n");

        try self.genClosureRelease(spec.mangled_name, spec.captures);
    }

    /// Faz U.4.3: `$<mangled>_release(rt, p)` üretir — `genClassRelease`in
    /// AYNI iskeleti (predecrement, sıfıra düşerse HER yakalanan
    /// heap-yönetimli/Task/Channel/dict değeri release/destroy et, SONRA
    /// `nox_rc_free_payload`). Katman 3'ün döngü-çözücü entegrasyonu
    /// (`nox_cycle_possible_root`/`forget`) BİLİNÇLİ OLARAK atlanır — v1
    /// kapsamı, `list[T]`/`dict[K,V]` elemanlarıyla AYNI gerekçeyle (bkz.
    /// runtime/alloc/cycle_detector.zig'in modül üstü notu, "yalnızca SINIF
    /// örnekleri") closure'ları döngü TARAMASININ dışında bırakır.
    fn genClosureRelease(self: *Codegen, mangled_name: []const u8, captures: []const ClosureCaptureField) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        try self.out.writer.print("export function ${s}_release(l {s}, l %p) {{\n@start\n", .{ mangled_name, RT_PARAM });
        const should_free = try self.emitInlinePredecrement("%p");
        const free_label = try self.newLabel("release_free");
        const done_label = try self.newLabel("release_done");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, done_label });
        try self.out.writer.print("{s}\n", .{free_label});
        for (captures, 0..) |c, i| {
            const offset = CLOSURE_HEADER_SIZE + 8 * i;
            if (isHeapManaged(c.info.heap)) {
                const addr = try self.newTemp();
                try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, offset });
                const fv = try self.newTemp();
                try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
                try self.releaseValueIfSet(fv, c.info.heap, c.info.elem_qtype, c.info.class_name, c.info.elem_heap_info, c.info.dict_info);
            } else if (c.info.heap == .task or c.info.heap == .channel or c.info.heap == .thread_handle or c.info.heap == .thread_channel) {
                const addr = try self.newTemp();
                try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, offset });
                const fv = try self.newTemp();
                try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
                try self.destroyNonArcValue(fv, c.info.heap);
            }
        }
        const total_size = CLOSURE_HEADER_SIZE + 8 * captures.len;
        try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l %p, l {d})\n", .{ RT_PARAM, total_size });
        try self.out.writer.print("    jmp {s}\n", .{done_label});
        try self.out.writer.print("{s}\n", .{done_label});
        try self.out.writer.writeAll("    ret\n}\n");
    }

    /// Her sınıf için `$ClassName_release(rt, p)` üretir: refcount'u azaltır
    /// (`nox_rc_predecrement`); sıfıra düştüyse, ÖNCE heap-yönetimli her alanı
    /// (sınıf TİPLİ ya da — bkz. görev "Sınıf alanı list[T] tipinde olabilsin"
    /// — `list[T]` TİPLİ, varsa/null değilse) özyinelemeli olarak serbest
    /// bırakır, SONRA belleği gerçekten serbest bırakır (`nox_rc_free_payload`).
    /// Çalışma zamanının (`arc.zig`) aksine bu, derleme zamanında bilinen alan
    /// düzenini (`cinfo.fields`) kullanabildiği için iç içe serbest bırakmayı
    /// yapabilir — bkz. modül üstü not, "İç içe sınıf alanları". Her iki alan
    /// türü de (sınıf/liste) `releaseValueIfSet` ile AYNI tek yoldan geçer —
    /// bu, bir yerel değişkenin kapsam-sonu temizliğiyle (`releaseSlotIfSet`)
    /// TAMAMEN aynı mantıktır (null kontrolü + doğru release fonksiyonuna
    /// dispatch).
    fn genClassRelease(self: *Codegen, class_name: []const u8, cinfo: ClassInfo) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        // Faz S.3: BU sınıf en az bir SINIF-TİPLİ alan taşıyorsa (yalnızca
        // BÖYLE sınıflar bir referans DÖNGÜSÜNÜN "kaynağı" olabilir — bkz.
        // `runtime/alloc/cycle_detector.zig`nin modül üstü notu) predecrement
        // SIFIRA düşmediğinde (nesne hâlâ canlı, AMA belki bir döngünün
        // parçası) `nox_cycle_possible_root`e KAYDEDİLİR; sıfıra düştüğünde
        // (GERÇEKTEN serbest bırakılıyor) `nox_cycle_forget` ile yan
        // tablodaki olası bir kalıntı TEMİZLENİR (adres yeniden kullanımına
        // karşı, bkz. onun belge notu). Sınıf-tipli alanı OLMAYAN sınıflar
        // İÇİN bu iki çağrı da GEREKSİZ (asla bir döngünün kaynağı OLAMAZLAR)
        // — performans İÇİN atlanır (ÇOĞUNLUK vakada, sıradan bir sınıfta,
        // sıfır ek maliyet).
        var has_class_field = false;
        for (cinfo.fields.items) |f| {
            if (f.info.heap == .class) {
                has_class_field = true;
                break;
            }
        }

        try self.out.writer.print("export function ${s}_release(l {s}, l %p) {{\n@start\n", .{ class_name, RT_PARAM });
        const should_free = try self.emitInlinePredecrement("%p");
        const free_label = try self.newLabel("release_free");
        const done_label = try self.newLabel("release_done");
        if (has_class_field) {
            const root_label = try self.newLabel("release_possible_root");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, root_label });
            try self.out.writer.print("{s}\n", .{root_label});
            try self.out.writer.print("    call $nox_cycle_possible_root(l {s}, l %p)\n", .{RT_PARAM});
            try self.out.writer.print("    jmp {s}\n", .{done_label});
        } else {
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, done_label });
        }
        try self.out.writer.print("{s}\n", .{free_label});
        if (has_class_field) {
            try self.out.writer.print("    call $nox_cycle_forget(l {s}, l %p)\n", .{RT_PARAM});
        }
        for (cinfo.fields.items) |f| {
            if (isHeapManaged(f.info.heap)) {
                const addr = try self.newTemp();
                try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, f.offset });
                const fv = try self.newTemp();
                try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
                try self.releaseValueIfSet(fv, f.info.heap, f.info.elem_qtype, f.info.class_name, f.info.elem_heap_info, f.info.dict_info);
            } else if (f.info.heap == .task or f.info.heap == .channel or f.info.heap == .thread_handle or f.info.heap == .thread_channel) {
                // `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/`ThreadChannel[T]`
                // sınıf alanı — ARC-yönetimli DEĞİLDİR (`isHeapManaged` bunu
                // KAPSAMAZ, `dict[K,V]`in AKSİNE — bkz. Faz FF.3), bu yüzden
                // AYRI bir dal: `destroyNonArcValue` ile DOĞRUDAN bir kez
                // yıkılır (bkz. `releaseAllLocalsExcept`in AYNI deseni —
                // yalnızca YEREL değil, sınıf ALANI için, Faz S.1'den beri
                // doğru).
                const addr = try self.newTemp();
                try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, f.offset });
                const fv = try self.newTemp();
                try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
                try self.destroyNonArcValue(fv, f.info.heap);
            }
        }
        try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l %p, l {d})\n", .{ RT_PARAM, cinfo.total_size });
        try self.out.writer.print("    jmp {s}\n", .{done_label});
        try self.out.writer.print("{s}\n", .{done_label});
        try self.out.writer.writeAll("    ret\n}\n");
    }

    /// Faz S.3: HER sınıf İÇİN `$ClassName_trace(rt, p) -> l` üretir —
    /// `p`nin SINIF-TİPLİ alanlarının DEĞERLERİNİ küçük, `nox_alloc`'lu bir
    /// arabelleğe (8 baytlık `l` uzunluk BAŞLIĞI + N adet `l` çocuk
    /// işaretçisi — `genListLit`in AYNI bayt düzeni) yazıp döner;
    /// `runtime/alloc/cycle_detector.zig`nin `traceChildren`i OKUDUKTAN
    /// SONRA bu arabelleği `nox_free`lemekle YÜKÜMLÜDÜR. HER sınıf İÇİN
    /// (sınıf-tipli alanı OLMASA BİLE, `genClassRelease`/`genClassEq` İLE
    /// TUTARLI biçimde KOŞULSUZ) üretilir — bir sınıf ÖRNEĞİ, KENDİSİ HİÇ
    /// döngü KAYNAĞI olamasa BİLE, BAŞKA bir sınıfın alanı olarak döngü
    /// çözücü tarafından KEŞFEDİLİP `nox_gc_free_dispatch`e (bkz.
    /// `genClassGcFree`) YÖNLENDİRİLEBİLİR — dağıtım fonksiyonlarının HER
    /// sınıf İÇİN bir DALI olması GEREKİR (bkz. `genTraceDispatch`).
    fn genClassTrace(self: *Codegen, class_name: []const u8, cinfo: ClassInfo) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        var class_fields: std.ArrayListUnmanaged(ClassField) = .empty;
        defer class_fields.deinit(self.allocator);
        for (cinfo.fields.items) |f| {
            if (f.info.heap == .class) try class_fields.append(self.allocator, f);
        }

        try self.out.writer.print("export function l ${s}_trace(l {s}, l %p) {{\n@start\n", .{ class_name, RT_PARAM });
        const buf = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_alloc(l {s}, l {d})\n", .{ buf, RT_PARAM, 8 + class_fields.items.len * 8 });
        try self.out.writer.print("    storel {d}, {s}\n", .{ class_fields.items.len, buf });
        for (class_fields.items, 0..) |f, i| {
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, f.offset });
            const fv = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
            const slot = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ slot, buf, 8 + i * 8 });
            try self.out.writer.print("    storel {s}, {s}\n", .{ fv, slot });
        }
        try self.out.writer.print("    ret {s}\n}}\n", .{buf});
    }

    /// Faz S.3: HER sınıf İÇİN `$ClassName_gc_free(rt, p)` üretir —
    /// `collectWhite`in (bkz. `cycle_detector.zig`) ÇAĞIRDIĞI, `$ClassName_
    /// release`DEN KASITLI olarak FARKLI bir temizlik yolu: SINIF-TİPLİ
    /// OLMAYAN alanları (str/list/Task/Channel/dict) NORMAL şekilde serbest
    /// bırakır, ama SINIF-TİPLİ alanlara HİÇ DOKUNMAZ (ne release ne
    /// predecrement) — onlar `collectWhite`in KENDİ özyinelemeli çağrısıyla
    /// AYRICA (VE YALNIZCA bir kez) ele alınır; burada da dokunulsaydı ÇİFT
    /// serbest bırakma OLURDU. Nesnenin KENDİ belleği SONRA KOŞULSUZ (bkz.
    /// `nox_rc_free_payload` — predecrement OLMADAN, çünkü çöp olduğu
    /// döngü çözücü TARAFINDAN ZATEN KANITLANMIŞTIR) serbest bırakılır.
    fn genClassGcFree(self: *Codegen, class_name: []const u8, cinfo: ClassInfo) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        try self.out.writer.print("export function ${s}_gc_free(l {s}, l %p) {{\n@start\n", .{ class_name, RT_PARAM });
        for (cinfo.fields.items) |f| {
            if (f.info.heap == .class) continue; // bkz. yukarıdaki belge notu
            if (isHeapManaged(f.info.heap)) {
                const addr = try self.newTemp();
                try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, f.offset });
                const fv = try self.newTemp();
                try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
                try self.releaseValueIfSet(fv, f.info.heap, f.info.elem_qtype, f.info.class_name, f.info.elem_heap_info, f.info.dict_info);
            } else if (f.info.heap == .task or f.info.heap == .channel or f.info.heap == .thread_handle or f.info.heap == .thread_channel) {
                const addr = try self.newTemp();
                try self.out.writer.print("    {s} =l add %p, {d}\n", .{ addr, f.offset });
                const fv = try self.newTemp();
                try self.out.writer.print("    {s} =l loadl {s}\n", .{ fv, addr });
                try self.destroyNonArcValue(fv, f.info.heap);
            }
        }
        try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l %p, l {d})\n", .{ RT_PARAM, cinfo.total_size });
        try self.out.writer.writeAll("    ret\n}\n");
    }

    /// Faz S.3: `$nox_trace_dispatch(rt, tag, p) -> l` — `runtime/alloc/
    /// cycle_detector.zig`nin ÇALIŞMA ZAMANI sınıf ETİKETİNE (`tag`, bkz.
    /// `TAG_SIZE`) göre doğru `$ClassName_trace`ye dal açan bir if-zinciri
    /// (QBE'de `switch` YOK). Eşleşen bir dal BULUNAMAZSA (savunmacı — HER
    /// GERÇEK sınıf örneğinin tag'i BİLİNEN bir `class_id`dir, bu dal ASLA
    /// tetiklenMEMELİDİR) boş (uzunluk=0) bir arabellek döner.
    fn genTraceDispatch(self: *Codegen, classes: []const ClassIdEntry) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        try self.out.writer.print("export function l $nox_trace_dispatch(l {s}, l %tag, l %p) {{\n@start\n", .{RT_PARAM});
        for (classes) |c| {
            const eq = try self.newTemp();
            try self.out.writer.print("    {s} =w ceql %tag, {d}\n", .{ eq, c.id });
            const case_label = try self.newLabel("trace_case");
            const next_label = try self.newLabel("trace_next");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ eq, case_label, next_label });
            try self.out.writer.print("{s}\n", .{case_label});
            const r = try self.newTemp();
            try self.out.writer.print("    {s} =l call ${s}_trace(l {s}, l %p)\n", .{ r, c.name, RT_PARAM });
            try self.out.writer.print("    ret {s}\n", .{r});
            try self.out.writer.print("{s}\n", .{next_label});
        }
        const empty = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_alloc(l {s}, l 8)\n", .{ empty, RT_PARAM });
        try self.out.writer.print("    storel 0, {s}\n", .{empty});
        try self.out.writer.print("    ret {s}\n}}\n", .{empty});
    }

    /// `genTraceDispatch` İLE AYNI desen, `$ClassName_gc_free`ye dağıtan
    /// `$nox_gc_free_dispatch(rt, tag, p)` (dönüş değeri YOK).
    fn genGcFreeDispatch(self: *Codegen, classes: []const ClassIdEntry) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        try self.out.writer.print("export function $nox_gc_free_dispatch(l {s}, l %tag, l %p) {{\n@start\n", .{RT_PARAM});
        for (classes) |c| {
            const eq = try self.newTemp();
            try self.out.writer.print("    {s} =w ceql %tag, {d}\n", .{ eq, c.id });
            const case_label = try self.newLabel("gc_free_case");
            const next_label = try self.newLabel("gc_free_next");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ eq, case_label, next_label });
            try self.out.writer.print("{s}\n", .{case_label});
            try self.out.writer.print("    call ${s}_gc_free(l {s}, l %p)\n", .{ c.name, RT_PARAM });
            try self.out.writer.writeAll("    ret\n");
            try self.out.writer.print("{s}\n", .{next_label});
        }
        try self.out.writer.writeAll("    ret\n}\n");
    }

    /// Her sınıf için `$ClassName_eq(rt, a, b) w` üretir — Python'un varsayılan
    /// `__eq__`inin AKSİNE (kimlik/`is` karşılaştırması), Nox'ta `==`/`!=`
    /// PYTHON'daki `dataclass`lar gibi ALAN ALANA YAPISAL karşılaştırmadır
    /// (bkz. görev "list/class için derin yapısal eşitlik"). Alanı olmayan
    /// bir sınıf (bkz. `ClassInfo.has_init`) için sonuç her zaman `1`dir (iki
    /// örnek yapısal olarak her zaman "eşit"tir — kimlik önemsizdir). Her alan
    /// için `genEqCompareOrJump` kullanılır (bkz. onun belge notu — NEDEN
    /// alloc/yığın yuvası KULLANILMADIĞI için).
    fn genClassEq(self: *Codegen, class_name: []const u8, cinfo: ClassInfo) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        try self.out.writer.print("export function w ${s}_eq(l {s}, l %a, l %b) {{\n@start\n", .{ class_name, RT_PARAM });
        const mismatch_label = try self.newLabel("classeq_mismatch");
        for (cinfo.fields.items) |f| {
            const addr_a = try self.newTemp();
            try self.out.writer.print("    {s} =l add %a, {d}\n", .{ addr_a, f.offset });
            const addr_b = try self.newTemp();
            try self.out.writer.print("    {s} =l add %b, {d}\n", .{ addr_b, f.offset });
            const va = try self.newTemp();
            try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ va, qbeTypeName(f.info.qtype), qbeTypeName(f.info.qtype), addr_a });
            const vb = try self.newTemp();
            try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ vb, qbeTypeName(f.info.qtype), qbeTypeName(f.info.qtype), addr_b });
            try self.genEqCompareOrJump(va, vb, f.info.qtype, f.info.heap, f.info.class_name, f.info.elem_qtype, f.info.elem_heap_info, f.info.elem_is_str, mismatch_label);
        }
        try self.out.writer.writeAll("    ret 1\n");
        try self.out.writer.print("{s}\n", .{mismatch_label});
        try self.out.writer.writeAll("    ret 0\n}\n");
    }

    /// Verilen iki (zaten yüklenmiş) `w`/`l`/`d` değerini `heap`/`class_name`/
    /// `elem_*` betimleyicisine göre karşılaştırır: uyuşmuyorsa `mismatch_label`e
    /// ATLAR, uyuşuyorsa NORMAL AKIŞA (çağıranın bir sonraki satırına) DEVAM
    /// EDER — bir DEĞER DÖNDÜRMEZ. Bu BİLİNÇLİ bir tasarım: `heap == .class`/
    /// `.list` durumunda (`va`/`vb` NULL OLABİLİR — bkz. `__init__`in koşullu
    /// bir dalda alan atlaması bilinen sınırlaması) sonucu bir dal SONRASI
    /// TEK bir değere birleştirmek ya QBE'nin `phi`sini ya da bir yığın
    /// yuvasını (`alloc4`/`alloc8`) gerektirirdi — İKİNCİSİ, bu fonksiyon bir
    /// KULLANICI DÖNGÜSÜ içinden çağrılan `==`/`!=`de (bkz. `genBinary`) HER
    /// yinelemede tekrar tekrar çalışıp QBE'nin fonksiyon-girişi-tahsisi
    /// varsayımını ihlal ederek yığın taşmasına yol açardı (bkz. §3.16'daki
    /// AYNI hata sınıfı, `adjustModSign`/`genForList`). Çözüm: hiç DEĞER
    /// TAŞIMADAN, doğrudan `mismatch_label`e ATLAMAK ya da DEVAM ETMEK —
    /// `genClassEq`/`genListEq`nin KENDİ döngü/alan yapısı zaten "eşleşmedi ->
    /// dışarı" ile "eşleşti -> bir sonraki alan/elemana geç" ayrımını doğal
    /// olarak taşıdığından, ayrı bir taşınabilir değere hiç gerek YOKTUR.
    fn genEqCompareOrJump(
        self: *Codegen,
        va: []const u8,
        vb: []const u8,
        qtype: QbeType,
        heap: HeapKind,
        class_name: ?[]const u8,
        elem_qtype: QbeType,
        elem_heap_info: ?*const ElemHeapInfo,
        elem_is_str: bool,
        mismatch_label: []const u8,
    ) CodegenError!void {
        if (heap == .none) {
            const t = try self.newTemp();
            const mnemonic: []const u8 = switch (qtype) {
                .l => "ceql",
                .w => "ceqw",
                .d => "ceqd",
                .none => unreachable,
            };
            try self.out.writer.print("    {s} =w {s} {s}, {s}\n", .{ t, mnemonic, va, vb });
            const cont_label = try self.newLabel("eqcmp_cont");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ t, cont_label, mismatch_label });
            try self.out.writer.print("{s}\n", .{cont_label});
            return;
        }
        if (heap == .str) {
            const cmp = try self.newTemp();
            try self.out.writer.print("    {s} =w call $strcmp(l {s}, l {s})\n", .{ cmp, va, vb });
            const cont_label = try self.newLabel("eqcmp_cont");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cmp, mismatch_label, cont_label });
            try self.out.writer.print("{s}\n", .{cont_label});
            return;
        }

        // `heap == .class` ya da `.list` — NULL olabilir (bkz. belge notu).
        const a_null = try self.newTemp();
        try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ a_null, va });
        const b_null = try self.newTemp();
        try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ b_null, vb });
        const either_null = try self.newTemp();
        try self.out.writer.print("    {s} =w or {s}, {s}\n", .{ either_null, a_null, b_null });
        const null_case_label = try self.newLabel("eqcmp_nullcase");
        const rec_label = try self.newLabel("eqcmp_rec");
        const cont_label = try self.newLabel("eqcmp_cont");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ either_null, null_case_label, rec_label });
        try self.out.writer.print("{s}\n", .{null_case_label});
        const both_null = try self.newTemp();
        try self.out.writer.print("    {s} =w and {s}, {s}\n", .{ both_null, a_null, b_null });
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ both_null, cont_label, mismatch_label });
        try self.out.writer.print("{s}\n", .{rec_label});
        const rec: []const u8 = switch (heap) {
            .class => blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =w call ${s}_eq(l {s}, l {s}, l {s})\n", .{ t, class_name.?, RT_PARAM, va, vb });
                break :blk t;
            },
            .list => blk: {
                const fn_name = try self.eqFnNameForList(elem_qtype, elem_heap_info, elem_is_str);
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =w call ${s}_eq(l {s}, l {s}, l {s})\n", .{ t, fn_name, RT_PARAM, va, vb });
                break :blk t;
            },
            // `dict`/`Task`/`Channel` — opak tutamaçlar, YAPISAL derinlemesine
            // eşitliği YOK (stdlib fazı §C'nin `dict` KAPSAM dışı bıraktığı
            // bir özellik, bkz. checker.zig). `HttpResponse.headers` gibi bir
            // `dict[str,str]` sınıf ALANI, HER sınıf İÇİN OTOMATİK üretilen
            // `$ClassName_eq`de (kullanıcı `==` HİÇ kullanmasa BİLE) bu dala
            // düşer — güvenli varsayılan: TUTAMAÇ KİMLİĞİ (pointer) karşılaştırması.
            // Faz U.4.3: closure değerleri henüz `==` karşılaştırmasını
            // DESTEKLEMİYOR (checker bu dala HİÇ düşürmemeli) — savunmacı
            // olarak `dict`/`Task`/`Channel` İLE AYNI tutamaç-kimliği
            // (pointer) karşılaştırmasına düşülür.
            // Faz FF.6.4: `list[int | None]` gibi bir kutulanmış-Optional
            // ELEMANLI liste (v1'de HİÇBİR golden fixture'ın EGZERSİZ
            // ETMEDİĞİ, ama exhaustive switch GEREKSİNİMİYLE buraya düşen
            // bir kombinasyon) — GÜVENLİ/tutucu bir varsayılan olarak
            // `dict`/`Task`/`Channel` İLE AYNI tutamaç-kimliği (pointer)
            // karşılaştırmasına düşülür (DEĞER eşitliği DEĞİL) — İKİ AYRI
            // kutunun AYNI değeri TAŞISA BİLE eşit SAYILMAYACAĞI, bilinçli
            // bir v1 sınırlamasıdır.
            .dict, .task, .channel, .closure, .thread_handle, .thread_channel, .boxed_scalar => blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =w ceql {s}, {s}\n", .{ t, va, vb });
                break :blk t;
            },
            .none, .str => unreachable,
        };
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ rec, cont_label, mismatch_label });
        try self.out.writer.print("{s}\n", .{cont_label});
    }

    /// `releaseFnNameFor` ile AYNI özyineli mangling şeması, ama derin
    /// yapısal eşitlik İÇİN: `str` elemanlar `int`/`float`/`bool`dan (`prim*`)
    /// AYRI bir ad alır — release'in aksine eşitlik `strcmp` ile `ceq*`i
    /// KARIŞTIRAMAZ (bkz. `list_eq_queue`nin belge notu).
    fn eqMangleFor(self: *Codegen, elem_qtype: QbeType, elem_heap_info: ?*const ElemHeapInfo, elem_is_str: bool) CodegenError![]const u8 {
        if (elem_heap_info) |ehi| {
            return switch (ehi.heap) {
                .class => ehi.class_name.?,
                .str => "str",
                .list => blk: {
                    const inner = try self.eqMangleFor(ehi.elem_qtype, ehi.nested, ehi.elem_is_str);
                    break :blk try std.fmt.allocPrint(self.allocator, "List_{s}", .{inner});
                },
                else => unreachable,
            };
        }
        if (elem_is_str) return "str";
        return try std.fmt.allocPrint(self.allocator, "prim{s}", .{qbeTypeName(elem_qtype)});
    }

    /// Bir `list[T]`nin (elemanları `elem_qtype`/`elem_heap_info`/`elem_is_str`
    /// ile betimlenen) `$List_<mangled>_eq`ini ister — ilk istekte
    /// `list_eq_queue`ya TEMBEL kaydedilir (`list_release_queue` ile AYNI
    /// desen, bkz. `releaseFnNameFor`).
    fn eqFnNameForList(self: *Codegen, elem_qtype: QbeType, elem_heap_info: ?*const ElemHeapInfo, elem_is_str: bool) CodegenError![]const u8 {
        const inner = try self.eqMangleFor(elem_qtype, elem_heap_info, elem_is_str);
        const name = try std.fmt.allocPrint(self.allocator, "List_{s}", .{inner});
        if (!self.list_eq_seen.contains(name)) {
            try self.list_eq_seen.put(self.allocator, name, {});
            try self.list_eq_queue.append(self.allocator, .{ .name = name, .elem_qtype = elem_qtype, .elem_heap_info = elem_heap_info, .elem_is_str = elem_is_str });
        }
        return name;
    }

    /// `eqFnNameForList`in kuyruğa aldığı `$List_<name>_eq(rt, a, b) w`i
    /// üretir: önce uzunlukları karşılaştırır (farklıysa hemen `0`), sonra
    /// elemanları TEK TEK (`genEqCompareOrJump` ile) karşılaştırır — ilk
    /// uyuşmazlıkta erken `0` döner (kısa devre), tümü eşleşirse `1`.
    fn genListEq(self: *Codegen, name: []const u8, elem_qtype: QbeType, elem_heap_info: ?*const ElemHeapInfo, elem_is_str: bool) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        try self.out.writer.print("export function w ${s}_eq(l {s}, l %a, l %b) {{\n@start\n", .{ name, RT_PARAM });
        const len_a = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl %a\n", .{len_a});
        const len_b = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl %b\n", .{len_b});
        const len_diff = try self.newTemp();
        try self.out.writer.print("    {s} =w cnel {s}, {s}\n", .{ len_diff, len_a, len_b });
        const false_label = try self.newLabel("listeq_lendiff");
        const loop_init_label = try self.newLabel("listeq_init");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ len_diff, false_label, loop_init_label });
        try self.out.writer.print("{s}\n", .{loop_init_label});

        const idx_slot = try self.newTemp();
        try self.out.writer.print("    {s} =l alloc8 8\n", .{idx_slot});
        try self.out.writer.print("    storel 0, {s}\n", .{idx_slot});

        const cond_label = try self.newLabel("listeq_cond");
        const body_label = try self.newLabel("listeq_body");
        const true_label = try self.newLabel("listeq_true");

        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{cond_label});
        const idx_cur = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ idx_cur, idx_slot });
        const cont = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cont, idx_cur, len_a });
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cont, body_label, true_label });
        try self.out.writer.print("{s}\n", .{body_label});

        const off = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ off, idx_cur, qbeSizeOf(elem_qtype) });
        const off8 = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off8, off, LIST_HEADER_SIZE });
        const addr_a = try self.newTemp();
        try self.out.writer.print("    {s} =l add %a, {s}\n", .{ addr_a, off8 });
        const addr_b = try self.newTemp();
        try self.out.writer.print("    {s} =l add %b, {s}\n", .{ addr_b, off8 });
        const ea = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ ea, qbeTypeName(elem_qtype), qbeTypeName(elem_qtype), addr_a });
        const eb = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ eb, qbeTypeName(elem_qtype), qbeTypeName(elem_qtype), addr_b });
        const elem_heap: HeapKind = if (elem_heap_info) |ehi| ehi.heap else if (elem_is_str) .str else .none;
        const elem_class_name: ?[]const u8 = if (elem_heap_info) |ehi| ehi.class_name else null;
        try self.genEqCompareOrJump(ea, eb, elem_qtype, elem_heap, elem_class_name, if (elem_heap_info) |ehi| ehi.elem_qtype else .none, if (elem_heap_info) |ehi| ehi.nested else null, if (elem_heap_info) |ehi| ehi.elem_is_str else false, false_label);
        const idx_next = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 1\n", .{ idx_next, idx_cur });
        try self.out.writer.print("    storel {s}, {s}\n", .{ idx_next, idx_slot });
        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{true_label});
        try self.out.writer.writeAll("    ret 1\n");
        try self.out.writer.print("{s}\n", .{false_label});
        try self.out.writer.writeAll("    ret 0\n}\n");
    }

    fn genMain(self: *Codegen, stmts: []const ast.Stmt, use_async: bool) CodegenError!void {
        if (use_async) return self.genMainAsync(stmts);

        self.vars.clearRetainingCapacity();
        self.narrowed_unbox.clearRetainingCapacity();
        self.temp_counter = 0;
        self.label_counter = 0;
        self.current_ret_qtype = .w;
        self.current_catch_label = null;
        self.in_main = true;

        var locals: std.ArrayListUnmanaged(LocalDecl) = .empty;
        defer locals.deinit(self.allocator);
        try self.collectLocals(&locals, stmts, false);

        // Stdlib fazı §J: `w %argc, l %argv` — C ABI'nin GERÇEK `main(int
        // argc, char **argv)` imzasıyla UYUMLU (bkz. `nox_os_init`in belge
        // notu, `runtime/stdlib_shims/os.zig`) — `nox.os` HİÇ import
        // edilmese BİLE KOŞULSUZ eklenir (basitlik: ikinci bir `$main`
        // kodgen yolu YOK, argv'yi HİÇ kullanmayan programlar İÇİN bu
        // parametreler yalnızca kullanılmadan geçilir, sıfıra yakın
        // maliyet).
        try self.out.writer.writeAll("export function w $main(w %argc, l %argv) {\n@start\n");
        try self.out.writer.print("    {s} =l call $nox_runtime_init()\n", .{RT_PARAM});
        try self.out.writer.writeAll("    call $nox_os_init(w %argc, l %argv)\n");
        // Not: `main`in kendi PARAMETRESİ yoktur, ama `collectLocals` artık
        // BAZI yerelleri (heap-yönetimli elemanlı bir `for`nin döngü
        // değişkeni — bkz. `collectLocals`) ödünç alınmış olarak `is_param =
        // true` ile işaretleyebiliyor; bu bilgiyi burada YOK SAYMAK
        // (eskiden olduğu gibi sabit `false`) kapsam-sonu otomatik release'i
        // yanlışlıkla tetikleyip listenin sahipliğini bozardı.
        for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
        try self.prepareInlineSites(stmts);
        try self.genStmts(stmts, .w);
        try self.releaseAllLocals();
        try self.out.writer.print("    call $nox_runtime_deinit(l {s})\n", .{RT_PARAM});
        const end_label = try self.newLabel("fn_end");
        try self.out.writer.print("{s}\n", .{end_label});
        try self.out.writer.writeAll("    ret 0\n}\n");
    }

    /// `moduleUsesAsync` `true` döndüğünde `genMain` yerine kullanılır —
    /// modülün üst düzey deyimleri (Nox'ta açık bir `def main()` sözleşmesi
    /// YOK, bkz. `checkModule`nin `top_ctx.in_async = true` notu) bir fiber
    /// GİRİŞİ olarak (`$main_body`) derlenir, `$main` (gerçek C ABI girişi)
    /// yalnızca onu zamanlayıcıya spawn edip tamamlanmasını bekleyen İNCE
    /// bir sürücüye dönüşür. Bu, async KULLANMAYAN programların (büyük
    /// çoğunluk) `genMain`in DEĞİŞMEMİŞ, sıfır-ek-maliyetli yolundan
    /// geçmeye devam etmesini sağlar (bkz. nox-teknik-spesifikasyon.md
    /// §3.21, aşama 4).
    fn genMainAsync(self: *Codegen, stmts: []const ast.Stmt) CodegenError!void {
        self.vars.clearRetainingCapacity();
        self.narrowed_unbox.clearRetainingCapacity();
        self.temp_counter = 0;
        self.label_counter = 0;
        self.current_ret_qtype = .l;
        self.current_catch_label = null;
        self.in_main = true;

        var locals: std.ArrayListUnmanaged(LocalDecl) = .empty;
        defer locals.deinit(self.allocator);
        try self.collectLocals(&locals, stmts, false);

        try self.out.writer.writeAll("export function l $main_body(l %argp) {\n@start\n");
        try self.out.writer.print("    {s} =l loadl %argp\n", .{RT_PARAM});
        for (locals.items) |l| try self.allocSlot(l.name, l.info, l.is_param, l.arena);
        try self.prepareInlineSites(stmts);
        try self.genStmts(stmts, .l);
        try self.releaseAllLocals();
        try self.out.writer.print("    call $nox_free(l {s}, l %argp, l 8)\n", .{RT_PARAM});
        const end_label = try self.newLabel("fn_end");
        try self.out.writer.print("{s}\n", .{end_label});
        try self.out.writer.writeAll("    ret 0\n}\n");

        // `$main` — gerçek C ABI girişi: çalışma zamanını/zamanlayıcıyı
        // başlatır, üst düzey kodu (`$main_body`) TEK bir görev olarak
        // spawn eder, tamamlanmasını (ya da bir kilitlenmeyi) bekler.
        self.temp_counter = 0;
        self.label_counter = 0;
        // Bkz. `genMain`in AYNI notu — `w %argc, l %argv` KOŞULSUZ eklenir.
        try self.out.writer.writeAll("export function w $main(w %argc, l %argv) {\n@start\n");
        try self.out.writer.print("    {s} =l call $nox_runtime_init()\n", .{RT_PARAM});
        try self.out.writer.writeAll("    call $nox_os_init(w %argc, l %argv)\n");
        try self.out.writer.print("    call $nox_async_init(l {s})\n", .{RT_PARAM});
        const closure_t = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_alloc(l {s}, l 8)\n", .{ closure_t, RT_PARAM });
        try self.out.writer.print("    storel {s}, {s}\n", .{ RT_PARAM, closure_t });
        const task_t = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_async_spawn(l {s}, l $main_body, l {s})\n", .{ task_t, RT_PARAM, closure_t });
        const run_result_t = try self.newTemp();
        try self.out.writer.print("    {s} =w call $nox_async_run_to_completion(l {s})\n", .{ run_result_t, RT_PARAM });
        const deadlock_label = try self.newLabel("deadlock");
        const ok_label = try self.newLabel("no_deadlock");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ run_result_t, deadlock_label, ok_label });
        try self.out.writer.print("{s}\n", .{deadlock_label});
        try self.out.writer.print("    call $nox_async_deadlock_abort(l {s})\n", .{RT_PARAM});
        try self.out.writer.writeAll("    ret 0\n"); // erişilemez — savunmacı (bkz. `emitExceptionCheck`in AYNI deseni)
        try self.out.writer.print("{s}\n", .{ok_label});
        try self.out.writer.print("    call $nox_async_destroy_task(l {s}, l {s})\n", .{ RT_PARAM, task_t });
        try self.out.writer.print("    call $nox_async_deinit(l {s})\n", .{RT_PARAM});
        try self.out.writer.print("    call $nox_runtime_deinit(l {s})\n", .{RT_PARAM});
        try self.out.writer.writeAll("    ret 0\n}\n");
    }

    /// Bu fonksiyonun/main'in TÜM heap tipli YEREL (parametre olmayan)
    /// değişkenlerini serbest bırakır (slotta ne varsa — sıfır/null dahil,
    /// güvenle atlanır). Kapsam sonu için çağrılır. Bilinen sınırlama: erken
    /// `return` noktalarında bu temizlik ÇALIŞMAZ (bkz. modül üstü not).
    fn releaseAllLocals(self: *Codegen) CodegenError!void {
        try self.releaseAllLocalsExcept(null);
    }

    /// `releaseAllLocals` ile aynıdır, yalnızca `except_name` adlı yerel hariç
    /// (varsa) — `return <isim>` bir "taşıma"dır: döndürülen bağlamanın kendi
    /// slotu serbest bırakılmaz (aksi hâlde döndürülen değer serbest
    /// bırakılmış bir belleğe işaret ederdi), ama AYNI kapsamdaki DİĞER heap
    /// tipli yereller (bkz. bilinen sınırlama — artık yalnızca `return`'ün
    /// KENDİ değeri için değil, `except ... as` ile yakalanan nesneler gibi
    /// diğer yereller için de doğru serbest bırakılıyor) hâlâ serbest bırakılır.
    fn releaseAllLocalsExcept(self: *Codegen, except_name: ?[]const u8) CodegenError!void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            if (except_name) |name| {
                if (std.mem.eql(u8, entry.key_ptr.*, name)) continue;
            }
            try self.releaseOneLocalIfManaged(entry.value_ptr.*);
        }
    }

    /// `releaseAllLocalsExcept`in TEK bir `VarInfo` GİRİŞİ İçin çalıştırdığı
    /// çekirdek — Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67) İçin
    /// `releaseNamedLocalsExcept`nin de YENİDEN KULLANABİLMESİ İçin
    /// ÇIKARILDI (basit kod-taşıma, davranış DEĞİŞMEDİ).
    fn releaseOneLocalIfManaged(self: *Codegen, entry: VarInfo) CodegenError!void {
        // Arena tipli bağlamalar hiçbir zaman bireysel release edilmez —
        // refcount başlıkları yoktur, yaşam süreleri yalnızca kendi
        // `lowlevel` bloğunun `nox_arena_destroy`'una bağlıdır.
        if (entry.is_param or entry.arena) return;
        if (isHeapManaged(entry.heap)) {
            try self.releaseSlotIfSet(entry);
        } else if (entry.heap == .task or entry.heap == .channel or entry.heap == .thread_handle or entry.heap == .thread_channel) {
            // `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/`ThreadChannel[T]`
            // ARC-yönetimli DEĞİLDİR (bkz. `HeapKind`in belge notu,
            // `dict[K,V]`in AKSİNE — bkz. Faz FF.3) — `destroyNonArcSlotIfSet`
            // (bkz. onun belge notu) DOĞRUDAN bir kez yıkar. Faz S.1'den
            // beri BU AYNI yol yeniden atamada da (`genAssign`) kullanılır
            // — artık ne kapsam sonunda ne de yeniden atamada eski değer
            // sızmaz.
            try self.destroyNonArcSlotIfSet(entry);
        }
    }

    /// Faz GG.2: `releaseAllLocalsExcept`in AYNISI, ama TÜM `self.vars`
    /// YERİNE yalnızca `names`teki (BİR inline-splice sitesinin KENDİ
    /// parametre+yerelleri) isimler İçin — inline edilen bir `return_stmt`
    /// (bkz. `genStmts`in `.return_stmt` dalı) caller'ın DİĞER yerellerine
    /// ASLA dokunmamalıdır, yalnızca callee'nin KENDİ kapsamını KAPATIR.
    fn releaseNamedLocalsExcept(self: *Codegen, names: []const []const u8, except_name: ?[]const u8) CodegenError!void {
        for (names) |name| {
            if (except_name) |en| {
                if (std.mem.eql(u8, name, en)) continue;
            }
            const entry = self.vars.get(name) orelse continue;
            try self.releaseOneLocalIfManaged(entry);
        }
    }

    /// Yalnızca `list[T]` için: boyut çalışma zamanında `cap` alanından
    /// (Faz U.1'den beri `@8` — ÖNCEDEN `len`den, `@0`, hesaplanıyordu,
    /// AMA `.append()`in GERÇEK büyümesi sonrası GERÇEKTEN TAHSİS EDİLMİŞ
    /// bayt sayısı `cap`e karşılık gelir, `len`e DEĞİL — bkz. `LIST_HEADER_
    /// SIZE`in belge notu) hesaplanır (sınıflar için artık `genClassRelease`'in
    /// ürettiği `$ClassName_release` kullanılır — `total_size` derleme
    /// zamanında zaten sabittir, bu yol üzerinden hesaplanmaya gerek yoktur).
    fn listPayloadSize(self: *Codegen, ptr: []const u8, elem_qtype: QbeType) CodegenError![]const u8 {
        const cap_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 8\n", .{ cap_addr, ptr });
        const cap_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ cap_t, cap_addr });
        const size_t = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ size_t, cap_t, qbeSizeOf(elem_qtype) });
        const total_t = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ total_t, size_t, LIST_HEADER_SIZE });
        return total_t;
    }

    /// `info`nin betimlediği TEK bir DEĞERİ (bir sınıf örneği ya da bir
    /// `list[T]`nin KENDİSİ) serbest bırakacak `$<isim>_release(rt, p)`
    /// fonksiyonunun ismini (baştaki `$` OLMADAN) döner.
    ///   - `info.heap == .class`: doğrudan sınıf adı (`genClassRelease`
    ///     tarafından ZATEN üretilmiştir, burada YENİ bir şey kaydedilmez).
    ///   - `info.heap == .list`: `p`nin KENDİSİ bir listedir; `info.elem_qtype`/
    ///     `info.nested` BU listenin KENDİ elemanlarını betimler (bkz. modül
    ///     üstü not, "Faz 21 ön-koşulu"). Gereken `$List_<mangled>_release`i
    ///     TEMBEL olarak kaydeder (henüz üretilmemişse `list_release_queue`ya
    ///     ekler — gerçek üretim `generateModule`nin sonunda, `string_data`
    ///     gibi drenaj yoluyla olur, bkz. `genListElemRelease`).
    /// **Dikkat — iki farklı "elemanları betimleme" düzeyi:** bu fonksiyona
    /// verilen `info`, RELEASE EDİLECEK DEĞERİN KENDİSİNİ betimler (`info.heap`
    /// o değerin KENDİ heap türüdür) — `Value`/`VarInfo.elem_heap_info` gibi
    /// "BİR listenin İÇİNDEKİ elemanların türü" alanlarıyla KARIŞTIRILMAMALI;
    /// çağıran taraf (bkz. `releaseValueIfSet`) bu ikisini birbirine
    /// dönüştürmekle sorumludur.
    fn releaseFnNameFor(self: *Codegen, info: ElemHeapInfo) CodegenError![]const u8 {
        switch (info.heap) {
            .class => return info.class_name.?,
            // Yalnızca DIŞ `$List_str_release` sembolünün adını üretmek için
            // bir "etiket" — GERÇEK release ÇAĞRISI `nox_str_release`e gider
            // (`$str_release` diye bir sembol YOK) — bkz. `genListElemRelease`in
            // `info.nested` dalındaki ÖZEL durum.
            .str => return "str",
            .list => {
                const inner_tag = if (info.nested) |n|
                    try self.releaseFnNameFor(n.*)
                else
                    try std.fmt.allocPrint(self.allocator, "prim{s}", .{qbeTypeName(info.elem_qtype)});
                const name = try std.fmt.allocPrint(self.allocator, "List_{s}", .{inner_tag});
                if (!self.list_release_seen.contains(name)) {
                    try self.list_release_seen.put(self.allocator, name, {});
                    try self.list_release_queue.append(self.allocator, .{ .name = name, .info = info });
                }
                return name;
            },
            else => return error.Unsupported,
        }
    }

    /// `fn_name`/`info` = `releaseFnNameFor`den gelen kayıt (`info.heap`
    /// HER ZAMAN `.list`dir — `.class` değerler zaten `genClassRelease`
    /// tarafından üretilir, bu kuyruğa hiç girmez). `genClassRelease` ile
    /// AYNI şekilde refcount'u azaltır (`nox_rc_predecrement`); sıfıra
    /// düştüyse:
    ///   - `info.nested == null` (BU listenin elemanları primitive/str):
    ///     hiçbir eleman release'i GEREKMEZ — doğrudan (genel `nox_rc_release`
    ///     ile AYNI hesapla) belleği serbest bırakır.
    ///   - `info.nested != null` (elemanları heap-yönetimli): `genForList`deki
    ///     AYNI güvenli döngü deseniyle (indeks sayacı FONKSİYON GİRİŞİNDE bir
    ///     kez `alloc8` — bu fonksiyon başına TEK sefer çalışır, döngü
    ///     YİNELEMESİ başına değil, bu yüzden Faz 16'da bulunan alloc-döngü-
    ///     içi yığın taşması hatasına yol AÇMAZ) her elemanı (null değilse)
    ///     `$<releaseFnNameFor(info.nested.*)>_release` ile özyinelemeli
    ///     olarak serbest bırakır — SONRA belleği gerçekten serbest bırakır.
    fn genListElemRelease(self: *Codegen, fn_name: []const u8, info: ElemHeapInfo) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        try self.out.writer.print("export function ${s}_release(l {s}, l %p) {{\n@start\n", .{ fn_name, RT_PARAM });
        const should_free = try self.emitInlinePredecrement("%p");
        const free_label = try self.newLabel("list_release_free");
        const done_label = try self.newLabel("list_release_done");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, done_label });
        try self.out.writer.print("{s}\n", .{free_label});

        const len_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl %p\n", .{len_t});
        // Faz U.1: gerçek TAHSİS EDİLMİŞ boyut `cap`e (@8) karşılık gelir,
        // `len`e (@0) DEĞİL — `len`, ELEMAN döngüsünün SINIRI olarak KALIR
        // (yalnızca GEÇERLİ elemanlar release edilmeli), ama belleği
        // serbest bırakırken `cap` KULLANILMALIDIR (aksi halde `.append()`in
        // büyüttüğü bir liste, ONA AYRILAN gerçek bloktan DAHA KÜÇÜK bir
        // boyutla serbest bırakılır — havuzun serbest-liste sınıf indeksini
        // BOZAR, bkz. `arc.zig`nin `nox_rc_free_payload` notu).
        const cap_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add %p, 8\n", .{cap_addr});
        const cap_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ cap_t, cap_addr });

        if (info.nested) |n| {
            const callee: ?[]const u8 = if (n.heap == .str) null else try self.releaseFnNameFor(n.*);
            const idx_slot = try self.newTemp();
            try self.out.writer.print("    {s} =l alloc8 8\n", .{idx_slot});
            try self.out.writer.print("    storel 0, {s}\n", .{idx_slot});

            const cond_label = try self.newLabel("list_release_cond");
            const body_label = try self.newLabel("list_release_body");
            const loopend_label = try self.newLabel("list_release_loopend");
            const skip_label = try self.newLabel("list_release_skip");
            const rel_label = try self.newLabel("list_release_elem");

            try self.out.writer.print("    jmp {s}\n", .{cond_label});
            try self.out.writer.print("{s}\n", .{cond_label});
            const idx_cur = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ idx_cur, idx_slot });
            const cont = try self.newTemp();
            try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cont, idx_cur, len_t });
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cont, body_label, loopend_label });
            try self.out.writer.print("{s}\n", .{body_label});

            const off = try self.newTemp();
            try self.out.writer.print("    {s} =l mul {s}, 8\n", .{ off, idx_cur });
            const off8 = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off8, off, LIST_HEADER_SIZE });
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add %p, {s}\n", .{ addr, off8 });
            const elem = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ elem, addr });
            const is_null = try self.newTemp();
            try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ is_null, elem });
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ is_null, skip_label, rel_label });
            try self.out.writer.print("{s}\n", .{rel_label});
            if (callee) |c| {
                try self.out.writer.print("    call ${s}_release(l {s}, l {s})\n", .{ c, RT_PARAM, elem });
            } else {
                try self.out.writer.print("    call $nox_str_release(l {s}, l {s})\n", .{ RT_PARAM, elem });
            }
            try self.out.writer.print("    jmp {s}\n", .{skip_label});
            try self.out.writer.print("{s}\n", .{skip_label});
            const idx_next = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, 1\n", .{ idx_next, idx_cur });
            try self.out.writer.print("    storel {s}, {s}\n", .{ idx_next, idx_slot });
            try self.out.writer.print("    jmp {s}\n", .{cond_label});
            try self.out.writer.print("{s}\n", .{loopend_label});

            const size_t = try self.newTemp();
            try self.out.writer.print("    {s} =l mul {s}, 8\n", .{ size_t, cap_t });
            const total_t = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ total_t, size_t, LIST_HEADER_SIZE });
            try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l %p, l {s})\n", .{ RT_PARAM, total_t });
        } else {
            const size_t = try self.newTemp();
            try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ size_t, cap_t, qbeSizeOf(info.elem_qtype) });
            const total_t = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ total_t, size_t, LIST_HEADER_SIZE });
            try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l %p, l {s})\n", .{ RT_PARAM, total_t });
        }
        try self.out.writer.print("    jmp {s}\n", .{done_label});
        try self.out.writer.print("{s}\n", .{done_label});
        try self.out.writer.writeAll("    ret\n}\n");
    }

    /// `ptr` içindeki değer null değilse serbest bırakır: sınıf örnekleri
    /// üretilmiş `$ClassName_release`'e (iç içe alanları özyinelemeli olarak
    /// serbest bırakır), primitif elemanlı `list[T]` genel `nox_rc_release`'e,
    /// heap-yönetimli elemanlı `list[T]` (`elem_heap_info != null`) ise
    /// üretilmiş `$List_<...>_release`'e (elemanları ÖNCE özyinelemeli olarak
    /// serbest bırakır — bkz. `genListElemRelease`) gider. `dict` (Faz FF.3,
    /// bkz. nox-teknik-spesifikasyon.md §3.62) `nox_dict_release`e gider —
    /// `dict_info` (`.dict` DIŞINDAKİ tüm türler İçin `null` GEÇİRİLEBİLİR)
    /// bu YOLUN İhtiyacı olan `key_is_str`/`value_is_str` bayraklarını taşır.
    /// Hem yerel değişken kapsam-sonu temizliğinde (`releaseSlotIfSet`) hem
    /// de bir sınıf alanının üzerine yazılırken eski değeri serbest bırakmak
    /// için (`genAssign`, `.attribute` durumu) kullanılan tek ortak yoldur.
    fn releaseValueIfSet(self: *Codegen, ptr: []const u8, heap: HeapKind, elem_qtype: QbeType, class_name: ?[]const u8, elem_heap_info: ?*const ElemHeapInfo, dict_info: ?*const DictInfo) CodegenError!void {
        const is_null = try self.newTemp();
        try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ is_null, ptr });
        const release_label = try self.newLabel("release");
        const skip_label = try self.newLabel("release_skip");
        const done_label = try self.newLabel("release_done");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ is_null, skip_label, release_label });
        try self.out.writer.print("{s}\n", .{release_label});
        if (heap == .class) {
            const cn = class_name.?;
            try self.out.writer.print("    call ${s}_release(l {s}, l {s})\n", .{ cn, RT_PARAM, ptr });
        } else if (heap == .closure) {
            // Faz U.4.4: bir `.closure` değerinin SOMUT release fonksiyonu
            // ARTIK `class_name` (statik/isim-tabanlı dispatch) ÜZERİNDEN
            // DEĞİL, bloğun KENDİSİNİN offset 8'inde TAŞIDIĞI `release_fn_ptr`
            // ÜZERİNDEN DOLAYLI olarak çağrılır (bkz. `HeapKind.closure`in
            // belge notu, "küçük vtable") — bu, bir func-tipli DEĞİŞKENİN/
            // DÖNÜŞÜN çıplak tip ANNOTASYONUNDAN (`class_name` HER ZAMAN
            // `null`dır, çünkü `Type.func` YAPISAL/polimorfiktir) SOMUT
            // closure'ın kimliği ÇIKARILAMASA BİLE (`class`ın AKSİNE) DOĞRU
            // release fonksiyonuna ulaşılabilmesini sağlar — U.4.3'ün
            // panik-yerine-güvenli-hata geçici çözümünü GEREKSİZ kılar.
            const rel_addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, 8\n", .{ rel_addr, ptr });
            const rel_fn = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ rel_fn, rel_addr });
            try self.out.writer.print("    call {s}(l {s}, l {s})\n", .{ rel_fn, RT_PARAM, ptr });
        } else if (heap == .str) {
            // Faz GG.1 (bkz. nox-teknik-spesifikasyon.md — performans fazı):
            // predecrement adımı `emitInlinePredecrement` İLE (class/list
            // release fonksiyonlarının ZATEN yaptığı AYNI desen) DOĞRUDAN
            // QBE IR'ına inline edilir — `nox_str_release`in TAMAMINI HER
            // release'de ÇAĞIRMAK YERİNE (ki bu, HER PINNED/literal dizenin
            // BİLE — asla gerçekten serbest bırakılmasalar da — tam bir
            // fonksiyon çağrısı+prologue/epilogue ödemesi anlamına
            // geliyordu — `string_passing` benchmark'ında ÖLÇÜLEN Go/Rust'a
            // 7-11x kayıp bulgusunun BİRİNCİL kaynağı, bkz. GG.1 notu).
            // `str`nin boyutu (`list[T]`nin AKSİNE) başlıkta SAKLANMAZ (bkz.
            // `runtime/str.zig`in modül üstü notu) — bu yüzden yalnızca
            // GERÇEKTEN sıfıra/altına düştüğünde (NADİR yol) `strlen`+gerçek
            // serbest bırakma İçin `nox_str_free_now`ya (predecrement'siz
            // hafif sürüm) düşülür.
            const should_free = try self.emitInlinePredecrement(ptr);
            const free_label = try self.newLabel("str_free");
            const skip_free_label = try self.newLabel("str_free_skip");
            const free_done_label = try self.newLabel("str_free_done");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, skip_free_label });
            try self.out.writer.print("{s}\n", .{free_label});
            try self.out.writer.print("    call $nox_str_free_now(l {s}, l {s})\n", .{ RT_PARAM, ptr });
            try self.out.writer.print("    jmp {s}\n", .{free_done_label});
            try self.out.writer.print("{s}\n", .{skip_free_label});
            try self.out.writer.print("    jmp {s}\n", .{free_done_label});
            try self.out.writer.print("{s}\n", .{free_done_label});
        } else if (heap == .dict) {
            // Faz FF.3 (bkz. nox-teknik-spesifikasyon.md §3.62): `dict`
            // ARTIK `str` İLE AYNI "predecrement'e göre koşullu release"
            // desenini izler — `nox_dict_release`nin KENDİSİ `nox_rc_
            // predecrement` çağırır (bkz. `dict.zig`).
            const dinfo = dict_info.?;
            const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
            const value_is_str_lit: []const u8 = if (dinfo.value_is_str) "1" else "0";
            try self.out.writer.print("    call $nox_dict_release(l {s}, l {s}, w {s}, w {s})\n", .{ RT_PARAM, ptr, key_is_str_lit, value_is_str_lit });
        } else if (heap == .boxed_scalar) {
            // Faz FF.6.4 (bkz. nox-teknik-spesifikasyon.md §3.65): kutu,
            // `nox_rc_alloc(rt, 8)`den gelen DÜZ 8 baytlık bir skaler
            // payload'dır — `list`in len/cap BAŞLIĞI, `class`ın tag'ı YOK,
            // İÇİNDE nested bir heap referansı ASLA yok (ham int/float/bool)
            // — bu yüzden `listPayloadSize`in list-başlığı VARSAYAN genel
            // dalına (aşağı) DEĞİL, doğrudan sabit boyutlu bir `nox_rc_
            // release`e gider. **KRİTİK:** `nox_rc_free_payload` DEĞİL —
            // O, refcount'u KENDİSİ AZALTMADAN belleği KOŞULSUZ serbest
            // bırakan DÜŞÜK SEVİYE bir ilkeldir (yalnızca `nox_rc_
            // predecrement`in "sıfıra düştü" dönüşünden SONRA çağrılması
            // GEREKİR, bkz. `nox_rc_release`in KENDİSİ) — BU YANLIŞLIKLA
            // KULLANILDIĞINDA (İLK sürümde OLDUĞU GİBİ) paylaşılan bir
            // kutu (ör. `w: int | None = y`) HÂLÂ BAŞKA BİR sahibi VARKEN
            // ERKEN serbest bırakılır, bu da SONRAKİ (GERÇEK) sahibinin
            // scope-sonu temizliğinde ÇİFTE-SERBEST-BIRAKMAYA (segfault,
            // GERÇEKTEN gözlemlendi — bkz. break→red→fix ritüeli) yol açar.
            // Faz GG.7: GG.1'in `.str` dalıyla AYNI desen — `nox_rc_release`
            // (predecrement + koşullu `nox_rc_free_payload`) doğrudan bir
            // ÇAĞRI OLARAK DEĞİL, predecrement'i `emitInlinePredecrement`
            // İLE inline edip YALNIZCA GERÇEKTEN sıfıra/altına düştüğünde
            // (NADİR yol) `nox_rc_free_payload`ya düşerek.
            const should_free = try self.emitInlinePredecrement(ptr);
            const free_label = try self.newLabel("boxed_free");
            const skip_free_label = try self.newLabel("boxed_free_skip");
            const free_done_label = try self.newLabel("boxed_free_done");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, skip_free_label });
            try self.out.writer.print("{s}\n", .{free_label});
            try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l {s}, l 8)\n", .{ RT_PARAM, ptr });
            try self.out.writer.print("    jmp {s}\n", .{free_done_label});
            try self.out.writer.print("{s}\n", .{skip_free_label});
            try self.out.writer.print("    jmp {s}\n", .{free_done_label});
            try self.out.writer.print("{s}\n", .{free_done_label});
        } else if (elem_heap_info) |info| {
            // `ptr`nin KENDİSİ bir listedir; `info` bu listenin İÇİNDEKİ
            // elemanları betimler — `releaseFnNameFor` ise "release edilecek
            // DEĞERİN KENDİ türü"nü ister, bu yüzden burada `ptr`nin KENDİ
            // tam betimleyicisi sentezlenir (`heap = .list` her zaman, çünkü
            // bu dal zaten `heap != .class` demektir).
            const self_info: ElemHeapInfo = .{ .heap = .list, .elem_qtype = elem_qtype, .nested = info };
            const fn_name = try self.releaseFnNameFor(self_info);
            try self.out.writer.print("    call ${s}_release(l {s}, l {s})\n", .{ fn_name, RT_PARAM, ptr });
        } else {
            // Faz GG.7: yukarıdaki `.boxed_scalar` dalıyla AYNI gerekçe —
            // ilkel-elemanlı `list[T]` release'i (ÇOK SIK bir yol) inline
            // predecrement'e taşınır.
            const size = try self.listPayloadSize(ptr, elem_qtype);
            const should_free = try self.emitInlinePredecrement(ptr);
            const free_label = try self.newLabel("list_free");
            const skip_free_label = try self.newLabel("list_free_skip");
            const free_done_label = try self.newLabel("list_free_done");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, skip_free_label });
            try self.out.writer.print("{s}\n", .{free_label});
            try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l {s}, l {s})\n", .{ RT_PARAM, ptr, size });
            try self.out.writer.print("    jmp {s}\n", .{free_done_label});
            try self.out.writer.print("{s}\n", .{skip_free_label});
            try self.out.writer.print("    jmp {s}\n", .{free_done_label});
            try self.out.writer.print("{s}\n", .{free_done_label});
        }
        try self.out.writer.print("    jmp {s}\n", .{done_label});
        try self.out.writer.print("{s}\n", .{skip_label});
        try self.out.writer.print("    jmp {s}\n", .{done_label});
        try self.out.writer.print("{s}\n", .{done_label});
    }

    fn releaseSlotIfSet(self: *Codegen, info: VarInfo) CodegenError!void {
        const ptr = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ ptr, info.slot });
        try self.releaseValueIfSet(ptr, info.heap, info.elem_qtype, info.class_name, info.elem_heap_info, info.dict_info);
    }

    /// `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/`ThreadChannel[T]` (bkz.
    /// `HeapKind`in belge notu — bunlar ARC-yönetimli DEĞİLDİR, `isHeapManaged`in
    /// DIŞINDadır, `dict[K,V]`in AKSİNE — bkz. Faz FF.3) TEK bir DEĞERİ yok
    /// eder — `releaseValueIfSet`in bu dört tür İÇİNDEKİ karşılığı
    /// (null-kontrolü/predecrement YOK, DOĞRUDAN bir kez yıkım). Hem kapsam-
    /// sonu temizliğinde (`releaseAllLocalsExcept`) hem de Faz S.1'den beri
    /// yeniden atamada eski değeri serbest bırakmak için (`genAssign`nin
    /// `.identifier`/`.attribute` dalları) kullanılan tek ortak yoldur —
    /// `Task` İÇİN GÜVENLİK açısından KRİTİK bir çağrıdır: `nox_async_destroy_task`
    /// görev HENÜZ tamamlanmamışsa struct'ı HEMEN serbest BIRAKMAZ (bkz.
    /// `runtime/async_rt/scheduler.zig`nin `Task.detached`i) — aksi halde
    /// fiber kendi sonucunu SERBEST BIRAKILMIŞ belleğe yazardı.
    fn destroyNonArcValue(self: *Codegen, ptr: []const u8, heap: HeapKind) CodegenError!void {
        switch (heap) {
            .task, .channel, .thread_handle, .thread_channel => {
                const fn_name = switch (heap) {
                    .task => "nox_async_destroy_task",
                    .channel => "nox_channel_destroy",
                    .thread_handle => "nox_thread_destroy",
                    .thread_channel => "nox_threadchannel_destroy",
                    else => unreachable,
                };
                try self.out.writer.print("    call ${s}(l {s}, l {s})\n", .{ fn_name, RT_PARAM, ptr });
            },
            else => unreachable,
        }
    }

    /// `destroyNonArcValue` ile AYNI, yalnızca bir yerel değişkenin (henüz
    /// ÜZERİNE yazılmamış) MEVCUT slot değerini önce yükleyip sonra yok eder
    /// — `releaseSlotIfSet`in `Task`/`Channel`/`ThreadHandle`/`ThreadChannel`
    /// karşılığı.
    fn destroyNonArcSlotIfSet(self: *Codegen, info: VarInfo) CodegenError!void {
        const ptr = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ ptr, info.slot });
        try self.destroyNonArcValue(ptr, info.heap);
    }

    fn emitDefaultReturn(self: *Codegen, ret_qtype: QbeType) CodegenError!void {
        switch (ret_qtype) {
            .none => try self.out.writer.writeAll("    ret\n"),
            .l, .w => try self.out.writer.writeAll("    ret 0\n"),
            .d => try self.out.writer.writeAll("    ret d_0\n"),
        }
    }

    /// `value` tam olarak izlenen bir heap bağlamına (takma ad) işaret
    /// ediyorsa, o değeri retain eder (iki bağımsız sahip artık aynı nesneyi
    /// paylaşıyor). Aksi halde `v0`'ı olduğu gibi döndürür.
    /// `v`, bir `lowlevel` bloğunun arenasından gelen (`.arena`) ya da şu an
    /// lexical olarak bir `lowlevel` bloğunun içinde bulunulan (`in_lowlevel_depth
    /// > 0`) bir heap tipli (`list`/sınıf) değerse hata döner. Basitlik ve
    /// güvenlik için, bir `lowlevel` bloğu içindeyken HİÇBİR heap tipli değer
    /// (arena olsun olmasın) bir çağrıya argüman/alıcı olamaz, döndürülemez ya
    /// da başka bir isme takma ad olamaz — bkz. modül üstü not.
    fn checkNoLowlevelEscape(self: *Codegen, v: Value) CodegenError!void {
        if (isHeapManaged(v.heap) and (v.arena or self.in_lowlevel_depth > 0)) return error.Unsupported;
    }

    /// `nox_rc_retain`in çalışma zamanı ÇAĞRISI YERİNE doğrudan gömülen (inline)
    /// karşılığı — performans fazında (bkz. nox-teknik-spesifikasyon.md,
    /// benchmark darboğaz denetimi) ARC-ağırlıklı kodda (`oop_arc_churn`,
    /// liste takma adı) ölçülen bir darboğaz: retain, refcount'u (payload'dan
    /// HEMEN ÖNCEKİ görünmez 8 baytlık başlık, bkz. `runtime/alloc/arc.zig`'in
    /// `HEADER_SIZE`i — bu ofset iki taraf arasında SABİT bir sözleşmedir) bir
    /// artırmaktan İBARETTİR; AYRI bir nesne dosyasına (kendi çağrı/yığın
    /// çerçevesi maliyetiyle) bir fonksiyon çağrısı GEREKTİRMEZ. `nox_rc_alloc`/
    /// `nox_rc_free_payload` (gerçek `malloc`/`free`e ihtiyaç duyar) İSE inline
    /// EDİLEMEZ — yalnızca bu saf aritmetik işlem inline edilir.
    /// Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `ptr` `null`
    /// OLABİLİR — bir `T | None` (heap) değeri (bkz. `resolveType`in
    /// `.optional` dalı, "null = None" temsili). ÖNCEDEN bu fonksiyon
    /// KOŞULSUZDU (`sub`/`load`/`add`/`store` DOĞRUDAN), ÇÜNKÜ heap-
    /// yönetimli bir slot Optional'dan ÖNCE ASLA null bir Nox DEĞERİ
    /// TUTAMAZDI (null yalnızca `__init__`-öncesi/dahili bir sentinel'DI,
    /// hiçbir kullanıcı kodu yolunun onu `retainIfAliasing`e GEÇİREBİLECEĞİ
    /// bir durum yoktu) — `self.next = next` (`next: Node | None`) gibi bir
    /// atama BUNU artık MÜMKÜN KILDIĞINDAN, `releaseValueIfSet`in ZATEN
    /// sahip olduğu AYNI null-güvenliği retain YÖNÜNDE de eklemek GEREKTİ
    /// (aksi halde `null - 8` adresinden okuma DENEMESİ çöker — bu, GERÇEK
    /// bir segfault olarak GÖZLEMLENDİ, bkz. break→red→fix ritüeli).
    fn emitInlineRetain(self: *Codegen, ptr: []const u8) CodegenError!void {
        const is_null = try self.newTemp();
        try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ is_null, ptr });
        const retain_label = try self.newLabel("retain");
        const skip_label = try self.newLabel("retain_skip");
        const done_label = try self.newLabel("retain_done");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ is_null, skip_label, retain_label });
        try self.out.writer.print("{s}\n", .{retain_label});
        const hdr = try self.newTemp();
        try self.out.writer.print("    {s} =l sub {s}, 8\n", .{ hdr, ptr });
        const rc = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ rc, hdr });
        const rc2 = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 1\n", .{ rc2, rc });
        try self.out.writer.print("    storel {s}, {s}\n", .{ rc2, hdr });
        try self.out.writer.print("    jmp {s}\n", .{done_label});
        try self.out.writer.print("{s}\n", .{skip_label});
        try self.out.writer.print("    jmp {s}\n", .{done_label});
        try self.out.writer.print("{s}\n", .{done_label});
    }

    /// `nox_rc_predecrement`in gömülü (inline) karşılığı — `emitInlineRetain`
    /// ile AYNI gerekçe. Dönüş (bir `%temp`, `w`) AYNI anlamı taşır: `1` —
    /// refcount sıfıra/altına düştü, belleği GERÇEKTEN serbest bırakma
    /// sorumluluğu ÇAĞIRANDADIR (`nox_rc_free_payload`, HÂLÂ bir runtime
    /// çağrısı — gerçek `free` allocator'a ihtiyaç duyduğundan inline
    /// edilemez); `0` — nesne hâlâ canlı (başka bir sahibi var).
    fn emitInlinePredecrement(self: *Codegen, ptr: []const u8) CodegenError![]const u8 {
        const hdr = try self.newTemp();
        try self.out.writer.print("    {s} =l sub {s}, 8\n", .{ hdr, ptr });
        const rc = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ rc, hdr });
        const rc2 = try self.newTemp();
        try self.out.writer.print("    {s} =l sub {s}, 1\n", .{ rc2, rc });
        try self.out.writer.print("    storel {s}, {s}\n", .{ rc2, hdr });
        const should_free = try self.newTemp();
        try self.out.writer.print("    {s} =w cslel {s}, 0\n", .{ should_free, rc2 });
        return should_free;
    }

    /// `expr` değerlendirildiğinde BAŞKA BİR YERDE ZATEN sahibi olan, ÖDÜNÇ
    /// ALINMIŞ bir heap referansı mı üretir (bu durumda yeni bir isme takma ad
    /// olması `nox_rc_retain` GEREKTİRİR), yoksa TAZE bir değer mi (`isTemporaryExpr`
    /// — retain GEREKTİRMEZ, zaten tek sahiplidir) ya da alanın/elemanın
    /// KENDİSİ genFieldRead/genIndex TARAFINDAN ZATEN retain edilmiş mi
    /// (taze bir TABAN üzerinden okunmuşsa — bu durumda BURADA TEKRAR retain
    /// etmek ÇİFTE retain'e yol açardı) belirler:
    ///   - `.identifier`: her zaman bir takma ad (ödünç alınmış, retain gerekir).
    ///   - `.attribute`/`.index`: tabanı (`obj`) TAZE değilse bir takma addır
    ///     (retain gerekir, çünkü `genFieldRead`/`genIndex` bu durumda retain
    ///     ETMEMİŞTİR); tabanı TAZE ise `genFieldRead`/`genIndex` ZATEN
    ///     retain etmiştir (bkz. o fonksiyonların belge notu) — burada
    ///     retain YAPILMAMALIDIR.
    ///   - Diğerleri (`.call`, `.list_lit`, ...): taze, retain gerekmez.
    fn isAliasingExpr(expr: ast.Expr) bool {
        return switch (expr) {
            .identifier => true,
            .attribute => |a| !isTemporaryExpr(a.obj.*),
            .index => |idx| !isTemporaryExpr(idx.obj.*),
            else => false,
        };
    }

    fn retainIfAliasing(self: *Codegen, value: ast.Expr, v0: Value) CodegenError!Value {
        // `v0.always_fresh` (bkz. `Value`nin belge notu, stdlib fazı §G):
        // `s[i]` gibi TABANDAN BAĞIMSIZ TAZE bir tahsis üreten ifadeler
        // ASLA aliasing SAYILMAZ — `isAliasingExpr`in AST-tabanlı sezgisi
        // (`.index`in tabanı temporary DEĞİLSE aliasing SAYAR) burada
        // GEÇERSİZDİR (tip bilgisi olmadan `.index`in `str` mi `list`/
        // `dict` mi olduğunu AYIRT EDEMEZ).
        if (!v0.always_fresh and isAliasingExpr(value) and isHeapManaged(v0.heap)) {
            try self.checkNoLowlevelEscape(v0);
            try self.emitInlineRetain(v0.text);
        }
        return v0;
    }

    /// `return <ifade>` bir heap değeri döndürüyorsa, bu değerin BU
    /// FONKSİYONUN kendi münhasır (ve zaten terk edilecek) sahipliğini mi
    /// devrettiğini, yoksa BAŞKA BİR YERDE ZATEN sahibi olan ödünç alınmış
    /// bir referansı mı dışarı verdiğini belirler:
    ///   - Yerel bir değişkeni (`return x`, `x` bir PARAMETRE DEĞİL)
    ///     döndürmek retain GEREKTİRMEZ: sıfır maliyetli bir "taşıma"dır
    ///     (`x` zaten kapsam-sonu temizliğinden muaf tutulur).
    ///   - TAZE bir değer (`.call`/`.list_lit`) döndürmek de bir taşımadır
    ///     (başka hiçbir sahibi yoktur).
    ///   - Bir PARAMETREYİ olduğu gibi döndürmek (`return p`) ya da bir ALAN
    ///     OKUMASINI döndürmek (`return self.attr`) retain GEREKTİRİR: bu
    ///     değerin BAŞKA BİR sahibi zaten var (çağıranın kendi bağlaması ya
    ///     da içinde bulunulan nesnenin alanı) — çağıran bunu kendi (yeni)
    ///     bir sahipliğine bağlayabilir. Bu retain, olası bir çağıran-taraf
    ///     telafi release'iyle (bkz. `releaseTemporaryArgs`/
    ///     `releaseIfTemporary` — TAZE bir argüman/alıcının çağrı sonrası
    ///     serbest bırakılması) doğru dengeye ulaşır; bu ikisi birlikte
    ///     "passthrough" fonksiyonları (ör. `def identity(p): return p`)
    ///     bile güvenli kılar.
    fn returnNeedsRetain(self: *Codegen, e: ast.Expr) bool {
        return switch (e) {
            .identifier => |name| blk: {
                const info = self.vars.get(name) orelse break :blk false;
                break :blk info.is_param;
            },
            .attribute => true,
            // Stdlib fazı §L: `.index` İÇİN eksik dal — `return list[i]`
            // (ör. `nox.json.array_get`in `return v.arr[i]`si) `list`/
            // `dict`in İÇİNE ÖDÜNÇ ALINMIŞ bir referansı (bkz. `genIndex`'in
            // AYNI "taban temporary DEĞİLSE retain gerekmez" gerekçesi)
            // OLDUĞU GİBİ dışarı verir — TABAN temporary DEĞİLSE bu ödünç
            // retain EDİLMEDEN döndürülürse çağıran onu KENDİ sahipliğiymiş
            // gibi (bir `.call` sonucu) release eder, bu da listenin PAYLAŞTIĞI
            // referansı ERKEN sıfıra indirip bir kullanım-sonrası-serbest-
            // bırakmaya yol açar (GERÇEKTEN yaşandı — `nox.json.array_get`
            // "incorrect alignment" ile ÇÖKEN bir çift-serbest-bırakmaya yol
            // açtı). TABAN temporary İSE `genIndex` KENDİSİ zaten BİR retain
            // yapmıştır (`emitInlineRetain`, taban serbest bırakılmadan ÖNCE)
            // — burada TEKRAR retain etmek ÇİFT retain (kalıcı sızıntı)
            // olurdu, bu yüzden koşul `isAliasingExpr`in AYNI `.index` dalıyla
            // BİREBİR eşleşir.
            .index => |idx| !isTemporaryExpr(idx.obj.*),
            else => false,
        };
    }

    fn genStmts(self: *Codegen, stmts: []const ast.Stmt, ret_qtype: QbeType) CodegenError!void {
        for (stmts) |stmt| {
            // Faz T.3: bkz. modül üstü not — `genStmts` TÜM deyim kodgen'inin
            // TEK, özyinelemeli dağıtım noktası olduğundan (if/while/for/try
            // gövdeleri DAHİL), burada TEK bir `dbgloc` yayını HER deyimi
            // (iç içe olanlar DAHİL) otomatik kapsar (T.1'in `checkStmt`
            // deseniyle AYNI).
            if (self.debug_info and stmt.line > 0) {
                try self.out.writer.print("    dbgloc {d}\n", .{stmt.line});
            }
            switch (stmt.kind) {
                .return_stmt => |r| {
                    // Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): bir
                    // inline-splice SIRASINDAYIZ (`genInlinedCall` tarafından
                    // ayarlanmış) — gerçek bir `ret` YERİNE sonuç slotuna
                    // yazıp `jmp` ile "bitti" etiketine gidilir; `drainFinally`/
                    // `drainArenas` ATLANIR (uygunluk kuralı §1.2 bunları
                    // GEREKSİZ kılar — inline edilebilir bir gövde ASLA `try`/
                    // `with`/`lowlevel` İÇEREMEZ) VE yalnızca callee'nin KENDİ
                    // isimleri (`t.owned_names`) serbest bırakılır, caller'ın
                    // DİĞER yerellerine DOKUNULMAZ.
                    if (self.inline_return_target) |t| {
                        if (r) |e| {
                            const v0 = try self.genExprForTarget(e, self.current_ret_info);
                            try self.checkNoLowlevelEscape(v0);
                            if (isHeapManaged(v0.heap) and self.returnNeedsRetain(e)) {
                                try self.emitInlineRetain(v0.text);
                            }
                            const v = try self.convert(v0, ret_qtype);
                            const except_name: ?[]const u8 = if (e == .identifier) e.identifier else null;
                            try self.releaseNamedLocalsExcept(t.owned_names, except_name);
                            if (t.result_slot) |rs| {
                                try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(ret_qtype), v.text, rs });
                            }
                        } else {
                            try self.releaseNamedLocalsExcept(t.owned_names, null);
                        }
                        try self.out.writer.print("    jmp {s}\n", .{t.done_label});
                        const label = try self.newLabel("after_inline_return");
                        try self.out.writer.print("{s}\n", .{label});
                        return;
                    }
                    if (r) |e| {
                        const v0 = try self.genExprForTarget(e, self.current_ret_info);
                        try self.checkNoLowlevelEscape(v0);
                        // Bir parametreyi ya da bir alan okumasını OLDUĞU
                        // GİBİ döndürmek, BAŞKA BİR YERDE ZATEN sahibi olan
                        // ödünç alınmış bir referansı dışarı vermektir —
                        // çağıran bunu kendi (yeni) bir sahipliğine
                        // bağlayabileceği için retain GEREKİR (bkz.
                        // `returnNeedsRetain`). Bu retain, aşağıdaki
                        // `releaseAllLocalsExcept`'TEN ÖNCE yapılmalıdır —
                        // aksi halde bu fonksiyonun kendi yerel temizliği
                        // (ör. döndürülen değere daha önce takma ad olmuş
                        // başka bir yerel) onu erken sıfıra indirebilirdi.
                        if (isHeapManaged(v0.heap) and self.returnNeedsRetain(e)) {
                            try self.emitInlineRetain(v0.text);
                        }
                        const v = try self.convert(v0, ret_qtype);
                        // Sıra önemli: finally/arena yıkımı, yereller hâlâ
                        // geçerliyken (serbest bırakılmadan ÖNCE) çalışmalıdır —
                        // aksi hâlde içlerindeki bir okuma, kullanım-sonrası-
                        // serbest-bırakma (use-after-free) olurdu.
                        try self.drainFinally(ret_qtype);
                        try self.drainArenas();
                        const except_name: ?[]const u8 = if (e == .identifier) e.identifier else null;
                        try self.releaseAllLocalsExcept(except_name);
                        try self.out.writer.print("    ret {s}\n", .{v.text});
                    } else {
                        try self.drainFinally(ret_qtype);
                        try self.drainArenas();
                        try self.releaseAllLocalsExcept(null);
                        try self.out.writer.writeAll("    ret\n");
                    }
                    const label = try self.newLabel("after_return");
                    try self.out.writer.print("{s}\n", .{label});
                },
                .var_decl => |v| {
                    const info = self.vars.get(v.name).?;
                    const v0 = try self.genExprForTarget(v.value, info);
                    const retained = try self.retainIfAliasing(v.value, v0);
                    const val = try self.convert(retained, info.qtype);
                    // `.arena` bir yerelse (bir `lowlevel` bloğu içindeyse),
                    // bu bildirim bir DÖNGÜ gövdesinde olabilir ve slot önceki
                    // yinelemeden kalan bir işaretçi tutuyor olabilir — ama o
                    // bellek zaten arenanın TOPLU `nox_arena_destroy`'u ile
                    // serbest bırakılmıştır (bkz. `genLowLevel`). Burada normal
                    // ARC serbest bırakmayı çağırmak, ZATEN serbest bırakılmış
                    // belleği tekrar serbest bırakmaya (geçersiz free) yol açar.
                    if (isHeapManaged(info.heap) and !info.arena) try self.releaseSlotIfSet(info);
                    try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(info.qtype), val.text, info.slot });
                },
                .assign => |a| try self.genAssign(a),
                .expr_stmt => |e| {
                    const v = try self.genExpr(e);
                    // Tamamen dolaylanmış (hiçbir yere bağlanmamış) bir taze
                    // heap değeri (ör. bir çağrının sonucunu bir deyim olarak
                    // kullanmak) sızmaz — bkz. `releaseIfTemporary`.
                    try self.releaseIfTemporary(e, v);
                },
                .if_stmt => |f| try self.genIf(f, ret_qtype),
                .while_stmt => |w| try self.genWhile(w, ret_qtype),
                .for_stmt => |f| try self.genFor(f, ret_qtype),
                .raise_stmt => |e| try self.genRaise(e),
                .try_stmt => |t| try self.genTry(t, ret_qtype),
                .lowlevel_stmt => |ll| try self.genLowLevel(ll, ret_qtype),
                .pass_stmt => {},
                .func_def => |fd| try self.genNestedFuncDef(fd),
                .with_stmt => |w| try self.genWith(w, stmt.line, ret_qtype),
                .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt => return error.Unsupported,
            }
        }
    }

    fn genRaise(self: *Codegen, expr: ast.Expr) CodegenError!void {
        const obj = try self.genExpr(expr);
        if (obj.heap != .class) return error.Unsupported;
        try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, obj.text });
        try self.emitExceptionCheck();
    }

    /// Şu an aktif olan (en içten en dışa) tüm `finally` gövdelerini satır
    /// içi (inline) üretir — `return_stmt` tarafından gerçek `ret`ten hemen
    /// önce çağrılır (bkz. `finally_stack` alanının belge notu).
    fn drainFinally(self: *Codegen, ret_qtype: QbeType) CodegenError!void {
        var i = self.finally_stack.items.len;
        while (i > 0) {
            i -= 1;
            try self.genStmts(self.finally_stack.items[i], ret_qtype);
        }
    }

    /// Şu an aktif olan (en içten en dışa) tüm `lowlevel` arenalarını yıkar —
    /// `drainFinally` ile aynı gerekçeyle, bir `return`/yakalanmamış istisna
    /// gerçek çıkıştan önce (bkz. `finally_stack`'in belge notu, aynı mantık
    /// arenalar için de geçerlidir).
    fn drainArenas(self: *Codegen) CodegenError!void {
        var i = self.arena_stack.items.len;
        while (i > 0) {
            i -= 1;
            try self.out.writer.print("    call $nox_arena_destroy(l {s}, l {s})\n", .{ RT_PARAM, self.arena_stack.items[i] });
        }
    }

    /// `genTry`nin KENDİ `finally_body`sini (`fb`) "gerçek", KORUNMASIZ bir
    /// çıkış eylemi OLARAK çalıştırır — `fb`, ÇAĞRILDIĞI ANDA `finally_stack`in
    /// EN ÜSTÜNDEDİR (genTry'nin push'u SAYESİNDE, bkz. `finally_stack`in
    /// belge notu); GEÇİCİ olarak POP'lanıp (KENDİ İÇİNDEKİ bir çağrı istisna
    /// fırlatırsa bu istisnanın `emitExceptionCheck` ARACILIĞIYLA `fb`yi
    /// TEKRAR draine ETMEK YERİNE doğru şekilde DIŞARIYA, `saved_catch`e
    /// yayılması İÇİN) çalıştırılır, SONRA (BAŞKA bir çıkış yolu — ör. bir
    /// SONRAKİ `except` dalının KENDİ `return`ü — HÂLÂ onu gerektirebileceğinden)
    /// GERİ EKLENİR.
    ///
    /// **Düzeltilen kritik hata (Faz U.5'in doğrulaması SIRASINDA bulundu):**
    /// bu SARMALAMA OLMADAN, `fb` `finally_stack`deYKEN doğrudan `genStmts(fb)`
    /// İLE çalıştırılırsa VE `fb` bir `emitExceptionCheck` ÜRETEN çağrı
    /// İÇERİYORSA (Faz M.8 (yeniden ele alındı) ÖNCESİNDE HER metod çağrısı
    /// KOŞULSUZ böyleydi; ARTIK yalnızca `must_not_raise`e GİRMEYEN çağrılar
    /// böyle — ama bu SARMALAMA her iki durumda da GENEL/SAVUNMACI olarak
    /// GEREKLİDİR, çünkü `fb`nin GERÇEKTEN bir kontrol üretip üretmediği
    /// burada STATİK olarak varsayılamaz), `current_catch_label` bu noktada
    /// ZATEN eski değerine (genellikle `null`) DÖNMÜŞ OLDUĞUNDAN
    /// `emitExceptionCheck` `drainFinally`yi ÇAĞIRIR — bu da `finally_stack`de
    /// HÂLÂ DURAN `fb`yi TEKRAR çalıştırır, bu da AYNI çağrıyı TEKRAR
    /// üretir... SONSUZ DERLEME-ZAMANI özyinelemesi (noxc'nin KENDİSİNİN
    /// yığın taşmasıyla ÇÖKMESİ). Bu, Faz U.5'in `with` desteğini genTry'ye
    /// DEVREDEN `genWith`i doğrularken KEŞFEDİLDİ — `__exit__()` HER ZAMAN
    /// bir metod çağrısı OLDUĞUNDAN, İÇİNDE bir METOD ÇAĞRISI OLAN HER
    /// `finally`/`with` bloğu bunu tetikler (yalnızca `with`e özgü DEĞİL —
    /// sıradan `try/finally` İÇİN de GEÇERLİ bir düzeltmedir, `with` bunu
    /// YALNIZCA İLK KEZ ORTAYA ÇIKARDI).
    fn runDetachedFinally(self: *Codegen, fb: []const ast.Stmt, ret_qtype: QbeType) CodegenError!void {
        _ = self.finally_stack.pop();
        try self.genStmts(fb, ret_qtype);
        try self.finally_stack.append(self.allocator, fb);
    }

    fn genTry(self: *Codegen, t: ast.TryStmt, ret_qtype: QbeType) CodegenError!void {
        const dispatch_label = try self.newLabel("try_dispatch");
        const after_label = try self.newLabel("try_after");
        const end_label = try self.newLabel("try_end");

        if (t.finally_body) |fb| try self.finally_stack.append(self.allocator, fb);

        const saved_catch = self.current_catch_label;
        self.current_catch_label = dispatch_label;
        try self.genStmts(t.try_body, ret_qtype);
        self.current_catch_label = saved_catch;
        // Normal tamamlanma (ne `return` ne yakalanmamış istisna): finally'i
        // burada BİR KEZ çalıştır. `t.try_body` bir `return` ile bittiyse bu
        // nokta hiç erişilmez (üstteki `genStmts` zaten bir `ret` üretti ve
        // `drainFinally` orada devreye girdi) — o durumda burası ölü koddur.
        // `runDetachedFinally` (bkz. onun belge notu) kullanılır — `fb`nin
        // KENDİSİ `finally_stack`de İKEN çalıştırılırsa, İÇİNDE bir
        // `emitExceptionCheck` üreten çağrı varsa `current_catch_label`
        // ZATEN eski değerine döndüğünden `drainFinally` `fb`yi TEKRAR
        // çalıştırıp SONSUZ derleme-zamanı özyinelemesine yol açardı
        // (bkz. Faz U.5'in doğrulaması, bunu İLK KEZ ortaya çıkaran senaryo).
        if (t.finally_body) |fb| try self.runDetachedFinally(fb, ret_qtype);
        try self.out.writer.print("    jmp {s}\n", .{after_label});

        try self.out.writer.print("{s}\n", .{dispatch_label});
        const exc_ptr = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_exception_take(l {s})\n", .{ exc_ptr, RT_PARAM });
        const tag = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ tag, exc_ptr });

        var next_check = try self.newLabel("except_check");
        try self.out.writer.print("    jmp {s}\n", .{next_check});

        for (t.except_clauses, 0..) |ec, i| {
            const cinfo = self.classes.get(ec.class_name) orelse return error.Unsupported;
            try self.out.writer.print("{s}\n", .{next_check});
            const matches = try self.newTemp();
            try self.out.writer.print("    {s} =w ceql {s}, {d}\n", .{ matches, tag, cinfo.class_id });
            const handler_label = try self.newLabel("except_body");
            const is_last = i == t.except_clauses.len - 1;
            const following = if (!is_last) try self.newLabel("except_check") else try self.newLabel("except_reraise");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ matches, handler_label, following });
            try self.out.writer.print("{s}\n", .{handler_label});
            if (ec.bind_name) |bn| {
                const info = self.vars.get(bn).?;
                // Bu `except` gövdesi bir döngü içindeyse aynı bağlama ismi
                // (`e`) her yinelemede yeniden kullanılır — sıradan bir isme
                // atama gibi (bkz. `genAssign`'in `.identifier` kolu), ESKİ
                // değeri (varsa) ÜZERİNE YAZMADAN ÖNCE serbest bırakmazsak
                // önceki istisna nesnesi sonsuza dek sızar.
                try self.releaseSlotIfSet(info);
                try self.out.writer.print("    storel {s}, {s}\n", .{ exc_ptr, info.slot });
            }
            try self.genStmts(ec.body, ret_qtype);
            if (t.finally_body) |fb| try self.runDetachedFinally(fb, ret_qtype);
            try self.out.writer.print("    jmp {s}\n", .{after_label});
            next_check = following;
        }

        // Bu `try`nin korumalı bölgesinden (try_body + except gövdeleri) çıkıldı;
        // `finally` artık `return_stmt`'in örtük olarak bulacağı yığında olmamalı.
        if (t.finally_body != null) _ = self.finally_stack.pop();

        // Hiçbir `except` eşleşmedi: finally'i çalıştır, istisnayı yeniden
        // işaretle ve dışarıya yay (bu `try`'ın kendi dispatch'i artık devrede
        // değil — `current_catch_label` yukarıda eski değerine geri alındı).
        try self.out.writer.print("{s}\n", .{next_check});
        if (t.finally_body) |fb| try self.genStmts(fb, ret_qtype);
        try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, exc_ptr });
        try self.emitExceptionCheck();
        try self.out.writer.print("    jmp {s}\n", .{after_label});

        try self.out.writer.print("{s}\n", .{after_label});
        try self.out.writer.print("{s}\n", .{end_label});
    }

    /// Faz U.5: `with EXPR as NAME:` — bkz. `ast.WithStmt`in belge notu.
    /// `EXPR`in DEĞERİ (`ctx_val`), fonksiyonun geri kalanıyla AYNI
    /// "fonksiyon-genelinde yerel" modelini paylaşan GİZLİ bir yerelde
    /// (`__with_ctx_L<satır>`, bkz. `collectLocals`in `.with_stmt` dalı —
    /// AYNI isim FORMÜLÜ) TUTULUR — GERÇEK bellek serbest bırakması normal
    /// fonksiyon-sonu `releaseAllLocals`e ERTELENİR (Python'un HEMEN bloğun
    /// SONUNDA serbest bırakmasından FARKLI, ama ARC doğruluğu AÇISINDAN
    /// eşdeğerdir).
    ///
    /// **Kritik tasarım kararı — gövde/temizlik İLİŞKİSİ, SIFIR `except`
    /// dallı bir `try/finally` İLE BİREBİR AYNIDIR:** İlk tasarım (`__exit__`
    /// çağrısını `finally_stack`e itip yalnızca NORMAL tamamlanmada elle
    /// çalıştırmak) YANLIŞTI — bir istisna, `with` gövdesini SARAN bir DIŞ
    /// `try`nin dispatch'i tarafından yakalandığında, `emitExceptionCheck`
    /// `current_catch_label` AYARLIYSA doğrudan O dispatch'e ATLAR
    /// (`drainFinally`Yİ HİÇ ÇAĞIRMADAN, bkz. onun belge notu) — bu durumda
    /// `with`in `__exit__`i ASLA çalışmazdı. `genTry`nin KENDİSİ bunu TAM
    /// OLARAK ÇÖZER: `current_catch_label`i KENDİ dispatch'ine ÇEVİRİP HER
    /// çıkış yolunda (normal/eşleşen-except/eşleşmeyen-yeniden-fırlatma)
    /// `finally_body`yi SATIR İÇİNDE ÇALIŞTIRIR — `with`in `__exit__`i TAM
    /// OLARAK bu `finally_body` ROLÜNÜ oynar. Bu yüzden `genWith`, KENDİ
    /// dispatch/reraise mantığını YENİDEN YAZMAK YERİNE, `except_clauses`i
    /// BOŞ bir sentetik `ast.TryStmt` inşa edip DOĞRUDAN `genTry`ye
    /// (battle-tested, `raise`/`return`/normal tamamlanma DAHİL HER yolu
    /// zaten doğru işleyen) DEVREDER.
    fn genWith(self: *Codegen, w: ast.WithStmt, line: u32, ret_qtype: QbeType) CodegenError!void {
        const hidden_name = try std.fmt.allocPrint(self.allocator, "__with_ctx_L{d}", .{line});
        const ctx_val = try self.genExpr(w.ctx_expr);
        if (ctx_val.heap != .class) return error.Unsupported;
        const hidden = self.vars.get(hidden_name).?;
        const retained = try self.retainIfAliasing(w.ctx_expr, ctx_val);
        if (isHeapManaged(hidden.heap) and !hidden.arena) try self.releaseSlotIfSet(hidden);
        try self.out.writer.print("    storel {s}, {s}\n", .{ retained.text, hidden.slot });

        const enter_call = try self.buildMethodCallExpr(hidden_name, "__enter__");
        const enter_result = try self.genExpr(enter_call);
        if (w.binding) |bn| {
            const bind_info = self.vars.get(bn).?;
            const converted = try self.convert(enter_result, bind_info.qtype);
            if (isHeapManaged(bind_info.heap) and !bind_info.arena) try self.releaseSlotIfSet(bind_info);
            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(bind_info.qtype), converted.text, bind_info.slot });
        } else {
            try self.releaseIfTemporary(enter_call, enter_result);
        }

        const exit_call = try self.buildMethodCallExpr(hidden_name, "__exit__");
        const exit_stmts = try self.allocator.alloc(ast.Stmt, 1);
        exit_stmts[0] = .{ .kind = .{ .expr_stmt = exit_call }, .line = line };

        try self.genTry(.{ .try_body = w.body, .except_clauses = &.{}, .finally_body = exit_stmts }, ret_qtype);
    }

    /// `genWith`in sentetik `obj.method()` çağrı ifadesi kurucusu —
    /// `__enter__`/`__exit__`i, `genExpr`in NORMAL `.call`/`.attribute`
    /// dağıtımından (`genMethodCall`) geçirebilmek İÇİN (retain/release/
    /// istisna kontrolü DAHİL, HİÇBİR ÖZEL kod GEREKMEDEN).
    fn buildMethodCallExpr(self: *Codegen, obj_name: []const u8, method: []const u8) CodegenError!ast.Expr {
        const obj_expr = try self.allocator.create(ast.Expr);
        obj_expr.* = .{ .identifier = obj_name };
        const attr_expr = try self.allocator.create(ast.Expr);
        attr_expr.* = .{ .attribute = .{ .obj = obj_expr, .attr = method } };
        return .{ .call = .{ .callee = attr_expr, .args = &.{} } };
    }

    /// Bir `lowlevel:` bloğu için yeni bir arena oluşturur, blok boyunca
    /// `arena_stack`'e iter (böylece `genConstruct`/`genListLit` bu arenadan
    /// tahsis eder), gövdeyi üretir ve normal tamamlanmada arenayı yıkar.
    /// Gövde içinde bir `return`/yakalanmamış istisna olduysa, o çıkış yolu
    /// `drainArenas` ile arenayı ZATEN yıkmıştır — bu durumda buradaki yıkım
    /// çağrısı erişilemez (ölü) koddur, `genTry`'deki eşdeğer durum gibi.
    fn genLowLevel(self: *Codegen, ll: ast.LowLevelStmt, ret_qtype: QbeType) CodegenError!void {
        const arena_temp = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_arena_create(l {s})\n", .{ arena_temp, RT_PARAM });
        try self.arena_stack.append(self.allocator, arena_temp);
        self.in_lowlevel_depth += 1;
        try self.genStmts(ll.body, ret_qtype);
        self.in_lowlevel_depth -= 1;
        _ = self.arena_stack.pop();
        try self.out.writer.print("    call $nox_arena_destroy(l {s}, l {s})\n", .{ RT_PARAM, arena_temp });
    }

    fn genAssign(self: *Codegen, a: ast.Assign) CodegenError!void {
        switch (a.target) {
            .identifier => |name| {
                const info = self.vars.get(name) orelse return error.Unsupported;
                const v0 = try self.genExprForTarget(a.value, info);
                const retained = try self.retainIfAliasing(a.value, v0);
                const val = try self.convert(retained, info.qtype);
                // Bkz. `var_decl` kolundaki aynı gerekçe: arena yerelleri asla
                // ARC ile serbest bırakılmaz (arenanın toplu yıkımı zaten
                // bunu yapar) — aksi halde döngü içinde yeniden atama, önceki
                // yinelemede zaten yıkılmış bir arenaya ait belleği tekrar
                // serbest bırakmaya çalışır.
                if (isHeapManaged(info.heap) and !info.is_param and !info.arena) {
                    try self.releaseSlotIfSet(info);
                } else if ((info.heap == .task or info.heap == .channel or info.heap == .thread_handle or info.heap == .thread_channel) and !info.is_param and !info.arena) {
                    // Faz S.1: `Task[T]`/`Channel[T]`/`ThreadHandle[T]`/
                    // `ThreadChannel[T]` yeniden atamada ESKİ değer artık
                    // sızmaz — `destroyNonArcSlotIfSet`
                    // (bkz. onun belge notu, `Task` İÇİN `nox_async_destroy_task`nin
                    // GÜVENLİ ertelenmiş yıkım semantiği) mevcut slot değerini
                    // YENİ değer BURAYA yazılmadan ÖNCE yok eder.
                    try self.destroyNonArcSlotIfSet(info);
                }
                try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(info.qtype), val.text, info.slot });
            },
            .attribute => |attr| {
                // Genel durum (bkz. checker.zig'in `checkAssign`indeki AYNI
                // genelleme): `<ifade>.<alan> = <değer>` — `<ifade>` HERHANGİ
                // bir sınıf örneğine değerlenebilir, `self` OLMAK ZORUNDA
                // DEĞİL. `obj`, bir metod çağrısının ALICISI gibi (bkz.
                // `genMethodCall`) TAZE bir değer OLABİLİR — bu yüzden aynı
                // "lowlevel kaçışını engelle" + "taze ise sonda serbest
                // bırak" deseni burada da uygulanır.
                const obj = try self.genExpr(attr.obj.*);
                if (obj.heap != .class) return error.Unsupported;
                try self.checkNoLowlevelEscape(obj);
                const cinfo = self.classes.get(obj.class_name.?).?;
                for (cinfo.fields.items) |f| {
                    if (!std.mem.eql(u8, f.name, attr.attr)) continue;
                    const v0 = try self.genExprForTarget(a.value, f.info);
                    // Bir sınıf alanına atamak, bir isme atamakla (`y = x`)
                    // aynı anlamı taşır: nesne artık bu değeri KALICI olarak
                    // paylaşıyor — bu yüzden aynı takma ad/kaçış kuralları
                    // uygulanır (bkz. `retainIfAliasing`/`checkNoLowlevelEscape`).
                    try self.checkNoLowlevelEscape(v0);
                    const retained = try self.retainIfAliasing(a.value, v0);
                    const val = try self.convert(retained, f.info.qtype);
                    const addr = try self.newTemp();
                    try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, obj.text, f.offset });
                    if (isHeapManaged(f.info.heap)) {
                        // Üzerine yazılacak ESKİ değeri önce oku (adres henüz
                        // üzerine yazılmadı), yeni değeri sakla, SONRA eskiyi
                        // serbest bırak — aksi halde eski nesne sonsuza dek
                        // sızardı (kendi refcount'u hiç azalmazdı).
                        const old_ptr = try self.newTemp();
                        try self.out.writer.print("    {s} =l loadl {s}\n", .{ old_ptr, addr });
                        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(f.info.qtype), val.text, addr });
                        try self.releaseValueIfSet(old_ptr, f.info.heap, f.info.elem_qtype, f.info.class_name, f.info.elem_heap_info, f.info.dict_info);
                    } else if (f.info.heap == .task or f.info.heap == .channel or f.info.heap == .thread_handle or f.info.heap == .thread_channel) {
                        // Faz S.1: `isHeapManaged`in DIŞINDaki DÖRT tür İÇİN de
                        // (yukarıdaki dalla AYNI "önce oku, SONRA üzerine yaz,
                        // SONRA eskiyi yok et" sırası) — bkz. `destroyNonArcValue`.
                        const old_ptr = try self.newTemp();
                        try self.out.writer.print("    {s} =l loadl {s}\n", .{ old_ptr, addr });
                        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(f.info.qtype), val.text, addr });
                        try self.destroyNonArcValue(old_ptr, f.info.heap);
                    } else {
                        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(f.info.qtype), val.text, addr });
                    }
                    try self.releaseIfTemporary(attr.obj.*, obj);
                    return;
                }
                return error.Unsupported;
            },
            // `d[key] = value` (dict) / `xs[i] = value` (list, Faz U.1) —
            // checker.zig'in `checkAssign`i BU İKİSİNİ dışında hiçbir tipi
            // GEÇİRMEZ, bu yüzden `idx.obj`in ÇÖZÜLEN tipine göre AYIRT
            // ETMEK için tekrar `genExpr` ÇAĞIRMAK YERİNE (iki kez
            // değerlendirme YAN ETKİ riski taşırdı) doğrudan alt fonksiyonlara
            // devredilir — `genListAssign`/`genDictAssign`in İKİSİ de
            // `obj.heap`i KENDİLERİ kontrol edip UYUŞMAZSA `error.Unsupported`
            // döner, bu yüzden BURADA sırayla DENEME GÜVENLİDİR: hiçbiri
            // `idx.obj`i genExpr'DEN önce başka BİR YAN ETKİ üretmez.
            // `d[key] = value` (dict) / `xs[i] = value` (list, Faz U.1) —
            // `idx.obj`, `genIndex`in (OKUMA yönü) İLE AYNI GEREKÇEYLE, TEK
            // SEFER değerlendirilir (`idx.obj` KEYFİ bir ifade OLABİLİR —
            // ör. `self.items[i] = v`, YALNIZCA çıplak bir isim DEĞİL —
            // checker ZATEN bunu genelleştirdi) VE sonucun `.heap`ine göre
            // `genListAssign`/`genDictAssign`e (İKİSİ de ARTIK ham `idx`
            // yerine ÖNCEDEN değerlendirilmiş `obj`u ALIR) dağıtılır.
            .index => |idx| {
                const obj = try self.genExpr(idx.obj.*);
                if (obj.heap == .list) return self.genListAssign(obj, idx, a.value);
                return self.genDictAssign(obj, idx, a.value);
            },
            else => return error.Unsupported,
        }
    }

    /// `xs[i] = value` — Faz U.1. `genIndex`in list dalıyla AYNI "önce
    /// doğrula, hata dalında raise et, phi'SİZ ok'e atla" sınır-kontrolü
    /// desenini (bkz. Faz S.2) YENİDEN kullanır; eski eleman heap-yönetimli
    /// İSE `genAssign`in `.attribute` kolundaki AYNI "önce ESKİYİ oku, YENİ
    /// değeri yaz, SONRA eskiyi serbest bırak" sırasını izler. `obj` (ÇAĞIRAN
    /// TARAFINDAN önceden değerlendirilmiş) her ZAMAN `.heap == .list`
    /// GARANTİLİDİR (bkz. `genAssign`in `.index` dalı).
    fn genListAssign(self: *Codegen, obj: Value, idx: ast.Index, value_expr: ast.Expr) CodegenError!void {
        if (obj.heap != .list) return error.Unsupported;
        try self.checkNoLowlevelEscape(obj);
        const index_v = try self.genExpr(idx.index.*);

        const len_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, obj.text });
        const neg_t = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, 0\n", .{ neg_t, index_v.text });
        const oob_hi_t = try self.newTemp();
        try self.out.writer.print("    {s} =w csgel {s}, {s}\n", .{ oob_hi_t, index_v.text, len_t });
        const oob_t = try self.newTemp();
        try self.out.writer.print("    {s} =w or {s}, {s}\n", .{ oob_t, neg_t, oob_hi_t });
        const err_label = try self.newLabel("list_assign_err");
        const ok_label = try self.newLabel("list_assign_ok");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ oob_t, err_label, ok_label });
        try self.out.writer.print("{s}\n", .{err_label});

        const msg_value = try self.emitStringLiteral("liste indeksi sinirlarin disinda");
        const ie_cinfo = self.classes.get("IndexError") orelse return error.Unsupported;
        const ie_obj = try self.genConstructFromValues("IndexError", ie_cinfo, &.{msg_value});
        try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, ie_obj.text });
        try self.emitExceptionCheck();
        try self.out.writer.print("    jmp {s}\n", .{ok_label});

        try self.out.writer.print("{s}\n", .{ok_label});
        const value_v0 = try self.genExpr(value_expr);
        try self.checkNoLowlevelEscape(value_v0);
        const retained = try self.retainIfAliasing(value_expr, value_v0);
        const val = try self.convert(retained, obj.elem_qtype);

        const byte_off = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ byte_off, index_v.text, qbeSizeOf(obj.elem_qtype) });
        const off16 = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off16, byte_off, LIST_HEADER_SIZE });
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ addr, obj.text, off16 });

        if (obj.elem_heap_info != null or obj.elem_is_str) {
            const old_ptr = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ old_ptr, addr });
            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(obj.elem_qtype), val.text, addr });
            const elem_heap: HeapKind = if (obj.elem_heap_info) |ehi| ehi.heap else .str;
            const elem_class_name: ?[]const u8 = if (obj.elem_heap_info) |ehi| ehi.class_name else null;
            const elem_inner_qtype: QbeType = if (obj.elem_heap_info) |ehi| ehi.elem_qtype else .none;
            const elem_nested: ?*const ElemHeapInfo = if (obj.elem_heap_info) |ehi| ehi.nested else null;
            try self.releaseValueIfSet(old_ptr, elem_heap, elem_inner_qtype, elem_class_name, elem_nested, null);
        } else {
            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(obj.elem_qtype), val.text, addr });
        }
        try self.releaseIfTemporary(idx.obj.*, obj);
    }

    /// `d[key] = value` — `nox_dict_set`e lowerlanır (bkz. `genDictLit`in
    /// belge notu, AYNI "sahiplik çağırandan devralınır" ilkesi). Anahtar/
    /// değer, bir isme atamakla (`y = x`) AYNI takma ad kuralına tabidir
    /// (`retainIfAliasing`) — `nox_dict_set`in KENDİSİ (runtime tarafında)
    /// yalnızca bir anahtar ZATEN VARSA eski değeri (VE `str` ise eski
    /// değeri/anahtarı) serbest bırakır (bkz. `runtime/collections/dict.zig`).
    /// `obj` (ÇAĞIRAN TARAFINDAN önceden değerlendirilmiş) `.heap != .dict`
    /// İSE (Faz U.1'den beri — `genAssign`in `.index` dalı ARTIK `list`i
    /// de yönlendirebildiğinden) `error.Unsupported` döner.
    fn genDictAssign(self: *Codegen, obj: Value, idx: ast.Index, value_expr: ast.Expr) CodegenError!void {
        if (obj.heap != .dict) return error.Unsupported;
        try self.checkNoLowlevelEscape(obj);
        const dinfo = obj.dict_info.?;

        const key_v0 = try self.genExpr(idx.index.*);
        try self.checkNoLowlevelEscape(key_v0);
        const key_v = try self.retainIfAliasing(idx.index.*, key_v0);

        const value_v0 = try self.genExpr(value_expr);
        try self.checkNoLowlevelEscape(value_v0);
        const value_v = try self.retainIfAliasing(value_expr, value_v0);
        const value_converted = try self.convert(value_v, dinfo.value_qtype);

        const key_payload = try self.toPayload(key_v);
        const value_payload = try self.toPayload(value_converted);
        const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
        const value_is_str_lit: []const u8 = if (dinfo.value_is_str) "1" else "0";
        try self.out.writer.print("    call $nox_dict_set(l {s}, l {s}, w {s}, w {s}, l {s}, l {s})\n", .{ RT_PARAM, obj.text, key_is_str_lit, value_is_str_lit, key_payload.text, value_payload.text });
        try self.releaseIfTemporary(idx.obj.*, obj);
    }

    /// `d[key]` (okuma) — `nox_dict_get`e lowerlanır. BORROWED bir okumadır
    /// (`list[T]` eleman okumasıyla AYNI — dict `str` değerin sahipliğini
    /// KORUR, dönen değer retain EDİLMEZ). `key_expr` TAZE bir heap değerse
    /// (ör. `d["a" + "b"]`), arama SONRASI serbest bırakılır (`nox_dict_get`
    /// anahtarı SAKLAMAZ, yalnızca hash/eşitlik için ÖDÜNÇ kullanır).
    fn genDictGet(self: *Codegen, obj: Value, key_expr: ast.Expr) CodegenError!Value {
        const dinfo = obj.dict_info.?;
        const key_v0 = try self.genExpr(key_expr);
        try self.checkNoLowlevelEscape(key_v0);
        const key_payload = try self.toPayload(key_v0);
        const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";

        const payload_t = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_dict_get(l {s}, l {s}, w {s}, l {s})\n", .{ payload_t, RT_PARAM, obj.text, key_is_str_lit, key_payload.text });
        const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, dinfo.value_qtype);
        try self.releaseIfTemporary(key_expr, key_v0);
        return .{ .text = converted.text, .qtype = converted.qtype, .heap = if (dinfo.value_is_str) .str else .none };
    }

    /// Faz FF.6.4 (bkz. `narrowed_unbox`ın belge notu): `checker.zig`'in
    /// `Checker.detectNarrowing`iyle AYNI DAR AST örüntüsü — yalnızca
    /// `<isim> != None`/`<isim> == None` (VE yansımaları) — ama BURADA
    /// yalnızca `name`in KENDİSİNİN `boxed_scalar` OLUP OLMADIĞI ÖNEMLİDİR
    /// (checker ZATEN tüm STATİK doğruluğu kanıtladı — bu, YALNIZCA "kutuyu
    /// AÇMALI MIYIM" kararı İÇİN gereken minimal bilgidir).
    fn detectNarrowedBoxedName(self: *Codegen, cond: ast.Expr) ?struct { name: []const u8, narrows_then: bool } {
        if (cond != .binary) return null;
        const b = cond.binary;
        if (b.op != .eq and b.op != .ne) return null;
        const name: []const u8 = if (b.left.* == .identifier and b.right.* == .none_lit)
            b.left.identifier
        else if (b.right.* == .identifier and b.left.* == .none_lit)
            b.right.identifier
        else
            return null;
        const info = self.vars.get(name) orelse return null;
        if (info.heap != .boxed_scalar) return null;
        return .{ .name = name, .narrows_then = (b.op == .ne) };
    }

    fn genIf(self: *Codegen, f: ast.IfStmt, ret_qtype: QbeType) CodegenError!void {
        const end_label = try self.newLabel("if_end");

        const cond0 = try self.genExpr(f.cond);
        const then_label = try self.newLabel("if_then");
        var next_label = if (f.elif_clauses.len > 0)
            try self.newLabel("if_elif")
        else if (f.else_body != null)
            try self.newLabel("if_else")
        else
            end_label;
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cond0.text, then_label, next_label });
        try self.out.writer.print("{s}\n", .{then_label});
        if (self.detectNarrowedBoxedName(f.cond)) |n| {
            const was_present = self.narrowed_unbox.contains(n.name);
            if (n.narrows_then) {
                try self.narrowed_unbox.put(self.allocator, n.name, {});
                try self.genStmts(f.then_body, ret_qtype);
                if (!was_present) _ = self.narrowed_unbox.remove(n.name);
            } else {
                try self.genStmts(f.then_body, ret_qtype);
            }
        } else {
            try self.genStmts(f.then_body, ret_qtype);
        }
        try self.out.writer.print("    jmp {s}\n", .{end_label});

        for (f.elif_clauses, 0..) |ec, i| {
            try self.out.writer.print("{s}\n", .{next_label});
            const cond_i = try self.genExpr(ec.cond);
            const body_label = try self.newLabel("if_elif_body");
            const is_last = i == f.elif_clauses.len - 1;
            const following = if (!is_last)
                try self.newLabel("if_elif")
            else if (f.else_body != null)
                try self.newLabel("if_else")
            else
                end_label;
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cond_i.text, body_label, following });
            try self.out.writer.print("{s}\n", .{body_label});
            try self.genStmts(ec.body, ret_qtype);
            try self.out.writer.print("    jmp {s}\n", .{end_label});
            next_label = following;
        }

        if (f.else_body) |eb| {
            try self.out.writer.print("{s}\n", .{next_label});
            if (self.detectNarrowedBoxedName(f.cond)) |n| {
                const was_present = self.narrowed_unbox.contains(n.name);
                if (!n.narrows_then) {
                    try self.narrowed_unbox.put(self.allocator, n.name, {});
                    try self.genStmts(eb, ret_qtype);
                    if (!was_present) _ = self.narrowed_unbox.remove(n.name);
                } else {
                    try self.genStmts(eb, ret_qtype);
                }
            } else {
                try self.genStmts(eb, ret_qtype);
            }
            try self.out.writer.print("    jmp {s}\n", .{end_label});
        }

        try self.out.writer.print("{s}\n", .{end_label});
    }

    /// Faz GG.5: iç içe geçmiş İFADE ağacının HER YERİNDE (`if`/`while`/`for`/
    /// `try`/`with`/`lowlevel` gövdeleri DAHİL) `s[i]` desenini arar, `s`nin
    /// `str`-tipli BİR KİMLİK (identifier) OLDUĞU durumlarda `s`yi aday
    /// kümesine ekler. `func_def`in (iç içe closure) İÇİNE İNMEZ — bu tarama
    /// KENDİSİ `bodyHasNestedFuncDef` tarafından TAMAMEN elenir (bkz. onun
    /// belge notu), bu yüzden burada AYRICA bir `func_def` dalı GEREKMEZ.
    fn collectIndexStrBasesExpr(self: *Codegen, e: ast.Expr, candidates: *std.StringHashMapUnmanaged(void)) CodegenError!void {
        switch (e) {
            .index => |idx| {
                if (idx.obj.* == .identifier) {
                    if (self.vars.get(idx.obj.identifier)) |vi| {
                        if (vi.heap == .str) try candidates.put(self.allocator, idx.obj.identifier, {});
                    }
                }
                try self.collectIndexStrBasesExpr(idx.obj.*, candidates);
                try self.collectIndexStrBasesExpr(idx.index.*, candidates);
            },
            .unary => |u| try self.collectIndexStrBasesExpr(u.operand.*, candidates),
            .binary => |b| {
                try self.collectIndexStrBasesExpr(b.left.*, candidates);
                try self.collectIndexStrBasesExpr(b.right.*, candidates);
            },
            .call => |c| {
                try self.collectIndexStrBasesExpr(c.callee.*, candidates);
                for (c.args) |a| try self.collectIndexStrBasesExpr(a, candidates);
            },
            .attribute => |a| try self.collectIndexStrBasesExpr(a.obj.*, candidates),
            .list_lit => |items| for (items) |it| try self.collectIndexStrBasesExpr(it, candidates),
            .dict_lit => |pairs| for (pairs) |p| {
                try self.collectIndexStrBasesExpr(p.key, candidates);
                try self.collectIndexStrBasesExpr(p.value, candidates);
            },
            .await_expr => |inner| try self.collectIndexStrBasesExpr(inner.*, candidates),
            .spawn_expr => |inner| try self.collectIndexStrBasesExpr(inner.*, candidates),
            .generic_construct => |g| for (g.args) |a| try self.collectIndexStrBasesExpr(a, candidates),
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
        }
    }

    fn collectIndexStrBasesStmts(self: *Codegen, body: []const ast.Stmt, candidates: *std.StringHashMapUnmanaged(void)) CodegenError!void {
        for (body) |stmt| {
            switch (stmt.kind) {
                .expr_stmt => |e| try self.collectIndexStrBasesExpr(e, candidates),
                .var_decl => |v| try self.collectIndexStrBasesExpr(v.value, candidates),
                .assign => |a| {
                    try self.collectIndexStrBasesExpr(a.target, candidates);
                    try self.collectIndexStrBasesExpr(a.value, candidates);
                },
                .if_stmt => |s| {
                    try self.collectIndexStrBasesExpr(s.cond, candidates);
                    try self.collectIndexStrBasesStmts(s.then_body, candidates);
                    for (s.elif_clauses) |ec| {
                        try self.collectIndexStrBasesExpr(ec.cond, candidates);
                        try self.collectIndexStrBasesStmts(ec.body, candidates);
                    }
                    if (s.else_body) |eb| try self.collectIndexStrBasesStmts(eb, candidates);
                },
                .while_stmt => |s| {
                    try self.collectIndexStrBasesExpr(s.cond, candidates);
                    try self.collectIndexStrBasesStmts(s.body, candidates);
                },
                .for_stmt => |s| {
                    try self.collectIndexStrBasesExpr(s.iterable, candidates);
                    try self.collectIndexStrBasesStmts(s.body, candidates);
                },
                .return_stmt => |e| if (e) |ex| try self.collectIndexStrBasesExpr(ex, candidates),
                .raise_stmt => |e| try self.collectIndexStrBasesExpr(e, candidates),
                .try_stmt => |s| {
                    try self.collectIndexStrBasesStmts(s.try_body, candidates);
                    for (s.except_clauses) |ec| try self.collectIndexStrBasesStmts(ec.body, candidates);
                    if (s.finally_body) |fb| try self.collectIndexStrBasesStmts(fb, candidates);
                },
                .lowlevel_stmt => |s| try self.collectIndexStrBasesStmts(s.body, candidates),
                .with_stmt => |s| {
                    try self.collectIndexStrBasesExpr(s.ctx_expr, candidates);
                    try self.collectIndexStrBasesStmts(s.body, candidates);
                },
                .func_def, .class_def, .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => {},
            }
        }
    }

    /// Faz GG.5: bir isim BU gövde İÇİNDE YENİDEN atanıyorsa (doğrudan
    /// `assign`/`var_decl` gölgelemesi/`for` döngü değişkeni/`except ... as
    /// name`/`with ... as name` İLE) `strlen` önbelleğine ADAY OLAMAZ —
    /// aksi halde önbelleklenen uzunluk BAYATLAR (`s = s2` SONRASI `s[i]`
    /// hâlâ ESKİ `s`nin uzunluğunu kullanırdı). Bilinçli MUHAFAZAKÂR:
    /// SADECE BU gövdedeki (iç içe döngüler DAHİL, ama bu gövdenin DIŞINDA
    /// DEĞİL) atamalara bakar — `enterStrLenCacheScope`in HER döngü
    /// GİRİŞİNDE bu taramayı TAZE çalıştırması, iç içe bir döngünün KENDİ
    /// (dıştaki gövdede reddedilen bir ismi, o ad İÇ döngüde YENİDEN
    /// atanmıyorsa) BAĞIMSIZ olarak önbelleklemesine olanak tanır.
    fn collectReassignedNames(body: []const ast.Stmt, reassigned: *std.StringHashMapUnmanaged(void), allocator: std.mem.Allocator) CodegenError!void {
        for (body) |stmt| {
            switch (stmt.kind) {
                .assign => |a| if (a.target == .identifier) try reassigned.put(allocator, a.target.identifier, {}),
                .var_decl => |v| try reassigned.put(allocator, v.name, {}),
                .if_stmt => |s| {
                    try collectReassignedNames(s.then_body, reassigned, allocator);
                    for (s.elif_clauses) |ec| try collectReassignedNames(ec.body, reassigned, allocator);
                    if (s.else_body) |eb| try collectReassignedNames(eb, reassigned, allocator);
                },
                .while_stmt => |s| try collectReassignedNames(s.body, reassigned, allocator),
                .for_stmt => |s| {
                    try reassigned.put(allocator, s.var_name, {});
                    try collectReassignedNames(s.body, reassigned, allocator);
                },
                .try_stmt => |s| {
                    try collectReassignedNames(s.try_body, reassigned, allocator);
                    for (s.except_clauses) |ec| {
                        if (ec.bind_name) |bn| try reassigned.put(allocator, bn, {});
                        try collectReassignedNames(ec.body, reassigned, allocator);
                    }
                    if (s.finally_body) |fb| try collectReassignedNames(fb, reassigned, allocator);
                },
                .lowlevel_stmt => |s| try collectReassignedNames(s.body, reassigned, allocator),
                .with_stmt => |s| {
                    if (s.binding) |b| try reassigned.put(allocator, b, {});
                    try collectReassignedNames(s.body, reassigned, allocator);
                },
                .expr_stmt, .return_stmt, .raise_stmt, .func_def, .class_def, .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => {},
            }
        }
    }

    /// Faz GG.5: gövdede (herhangi bir derinlikte) bir `func_def` (iç içe
    /// closure) VARSA `true` döner — BU durumda `enterStrLenCacheScope`
    /// TÜM önbellekleme fırsatını (closure'ın YAKALANAN bir ismi kapanış
    /// SIRASINDA/SONRASINDA nasıl ele aldığı bu turun kapsamı DIŞINDA
    /// AYRICA analiz EDİLMEDİĞİNDEN) BİLİNÇLİ VE MUHAFAZAKÂR biçimde
    /// TAMAMEN atlar.
    fn bodyHasNestedFuncDef(body: []const ast.Stmt) bool {
        for (body) |stmt| {
            switch (stmt.kind) {
                .func_def => return true,
                .if_stmt => |s| {
                    if (bodyHasNestedFuncDef(s.then_body)) return true;
                    for (s.elif_clauses) |ec| if (bodyHasNestedFuncDef(ec.body)) return true;
                    if (s.else_body) |eb| if (bodyHasNestedFuncDef(eb)) return true;
                },
                .while_stmt => |s| if (bodyHasNestedFuncDef(s.body)) return true,
                .for_stmt => |s| if (bodyHasNestedFuncDef(s.body)) return true,
                .try_stmt => |s| {
                    if (bodyHasNestedFuncDef(s.try_body)) return true;
                    for (s.except_clauses) |ec| if (bodyHasNestedFuncDef(ec.body)) return true;
                    if (s.finally_body) |fb| if (bodyHasNestedFuncDef(fb)) return true;
                },
                .lowlevel_stmt => |s| if (bodyHasNestedFuncDef(s.body)) return true,
                .with_stmt => |s| if (bodyHasNestedFuncDef(s.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn collectLoopInvariantStrBases(self: *Codegen, body: []const ast.Stmt) CodegenError!std.StringHashMapUnmanaged(void) {
        var result: std.StringHashMapUnmanaged(void) = .empty;
        if (bodyHasNestedFuncDef(body)) return result;
        var candidates: std.StringHashMapUnmanaged(void) = .empty;
        try self.collectIndexStrBasesStmts(body, &candidates);
        var reassigned: std.StringHashMapUnmanaged(void) = .empty;
        try collectReassignedNames(body, &reassigned, self.allocator);
        var it = candidates.keyIterator();
        while (it.next()) |k| {
            if (!reassigned.contains(k.*)) try result.put(self.allocator, k.*, {});
        }
        return result;
    }

    const StrLenCacheScope = struct {
        added_names: []const []const u8,
    };

    /// Faz GG.9: bkz. `bounds_elide_ctx`in belge notu.
    const BoundsElideCtx = struct { list_name: []const u8, idx_var: []const u8 };

    /// Faz GG.5: döngüye girmeden HEMEN ÖNCE (döngü gövdesi ÜRETİLMEDEN
    /// ÖNCE) çağrılır — `collectLoopInvariantStrBases`in bulduğu HER isim
    /// İçin `strlen`i TEK SEFERLİK ÖNCEDEN hesaplayıp `self.str_len_cache`e
    /// KAYDEDER. Bir isim ZATEN (dıştaki bir döngüden) önbellekteyse
    /// ATLANIR — iç içe döngüler dıştaki döngünün ÖNCEDEN hesapladığı
    /// AYNI QBE temp'ini YENİDEN KULLANIR (QBE temp'leri fonksiyon
    /// BOYUNCA GEÇERLİDİR — bkz. `emitInlineRetain`in AYNI önculü), İKİNCİ
    /// bir `strlen` çağrısı ÜRETİLMEZ; bu YÜZDEN yalnızca BU çağrının
    /// GERÇEKTEN eklediği isimler `added_names`e kaydedilir (`exitStrLen
    /// CacheScope`in yalnızca KENDİ eklediklerini silmesi İÇİN — dıştaki
    /// döngünün girişini YANLIŞLIKLA SİLMEMEK KRİTİKTİR).
    fn enterStrLenCacheScope(self: *Codegen, body: []const ast.Stmt) CodegenError!StrLenCacheScope {
        var invariants = try self.collectLoopInvariantStrBases(body);
        defer invariants.deinit(self.allocator);
        var added: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = invariants.keyIterator();
        while (it.next()) |k| {
            const name = k.*;
            if (self.str_len_cache.contains(name)) continue;
            const v = try self.genExpr(.{ .identifier = name });
            const len_t = try self.newTemp();
            try self.out.writer.print("    {s} =l call $strlen(l {s})\n", .{ len_t, v.text });
            try self.str_len_cache.put(self.allocator, name, len_t);
            try added.append(self.allocator, name);
        }
        return .{ .added_names = try added.toOwnedSlice(self.allocator) };
    }

    fn exitStrLenCacheScope(self: *Codegen, scope: StrLenCacheScope) void {
        for (scope.added_names) |name| {
            _ = self.str_len_cache.remove(name);
        }
    }

    fn genWhile(self: *Codegen, w: ast.WhileStmt, ret_qtype: QbeType) CodegenError!void {
        const cond_label = try self.newLabel("while_cond");
        const body_label = try self.newLabel("while_body");
        const end_label = try self.newLabel("while_end");

        const str_len_scope = try self.enterStrLenCacheScope(w.body);
        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{cond_label});
        const cond_v = try self.genExpr(w.cond);
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cond_v.text, body_label, end_label });
        try self.out.writer.print("{s}\n", .{body_label});
        if (self.detectNarrowedBoxedName(w.cond)) |n| {
            if (n.narrows_then) {
                const was_present = self.narrowed_unbox.contains(n.name);
                try self.narrowed_unbox.put(self.allocator, n.name, {});
                try self.genStmts(w.body, ret_qtype);
                if (!was_present) _ = self.narrowed_unbox.remove(n.name);
            } else {
                try self.genStmts(w.body, ret_qtype);
            }
        } else {
            try self.genStmts(w.body, ret_qtype);
        }
        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{end_label});
        self.exitStrLenCacheScope(str_len_scope);
    }

    fn isRangeCall(e: ast.Expr) bool {
        return e == .call and e.call.callee.* == .identifier and
            std.mem.eql(u8, e.call.callee.identifier, "range") and e.call.args.len == 1;
    }

    fn findLocal(locals: []const LocalDecl, name: []const u8) ?TypeInfo {
        var i = locals.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, locals[i].name, name)) return locals[i].info;
        }
        return null;
    }

    fn genFor(self: *Codegen, f: ast.ForStmt, ret_qtype: QbeType) CodegenError!void {
        if (isRangeCall(f.iterable)) return self.genForRange(f, ret_qtype);
        if (f.iterable == .identifier) return self.genForList(f, ret_qtype);
        return error.Unsupported;
    }

    /// Faz GG.9: `f`nin `for i in range(len(xs)): ...` TAM OLARAK bu desene
    /// UYUYORSA (`xs` BASİT bir kimlik, `list`/`str`-tipli, VE `xs`/`i`
    /// gövde İÇİNDE HİÇ yeniden atanmıyor, hiçbir iç içe closure YOK —
    /// `str_len_cache`in AYNI `collectReassignedNames`/`bodyHasNestedFuncDef`
    /// güvenlik disiplini) `(xs, i)` çiftini döner — AKSİ TAKDİRDE `null`
    /// (GÜVENLİ, MUHAFAZAKÂR geri düşüş: sınır kontrolü NORMAL şekilde
    /// üretilir).
    fn detectBoundsElideCtx(self: *Codegen, f: ast.ForStmt) CodegenError!?BoundsElideCtx {
        if (!isRangeCall(f.iterable)) return null;
        const limit_expr = f.iterable.call.args[0];
        if (limit_expr != .call) return null;
        if (limit_expr.call.callee.* != .identifier) return null;
        if (!std.mem.eql(u8, limit_expr.call.callee.identifier, "len")) return null;
        if (limit_expr.call.args.len != 1) return null;
        const list_arg = limit_expr.call.args[0];
        if (list_arg != .identifier) return null;
        const list_name = list_arg.identifier;
        const vi = self.vars.get(list_name) orelse return null;
        if (vi.heap != .list and vi.heap != .str) return null;
        if (bodyHasNestedFuncDef(f.body)) return null;
        var reassigned: std.StringHashMapUnmanaged(void) = .empty;
        try collectReassignedNames(f.body, &reassigned, self.allocator);
        if (reassigned.contains(list_name)) return null;
        if (reassigned.contains(f.var_name)) return null;
        return .{ .list_name = list_name, .idx_var = f.var_name };
    }

    fn genForRange(self: *Codegen, f: ast.ForStmt, ret_qtype: QbeType) CodegenError!void {
        const limit = try self.genExpr(f.iterable.call.args[0]);
        const var_info = self.vars.get(f.var_name).?;
        try self.out.writer.print("    storel 0, {s}\n", .{var_info.slot});

        const cond_label = try self.newLabel("for_cond");
        const body_label = try self.newLabel("for_body");
        const end_label = try self.newLabel("for_end");

        const str_len_scope = try self.enterStrLenCacheScope(f.body);
        const saved_bounds_ctx = self.bounds_elide_ctx;
        self.bounds_elide_ctx = try self.detectBoundsElideCtx(f);
        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{cond_label});
        const cur = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ cur, var_info.slot });
        const cmp = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cmp, cur, limit.text });
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cmp, body_label, end_label });
        try self.out.writer.print("{s}\n", .{body_label});
        try self.genStmts(f.body, ret_qtype);
        const cur2 = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ cur2, var_info.slot });
        const next = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 1\n", .{ next, cur2 });
        try self.out.writer.print("    storel {s}, {s}\n", .{ next, var_info.slot });
        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{end_label});
        self.bounds_elide_ctx = saved_bounds_ctx;
        self.exitStrLenCacheScope(str_len_scope);
    }

    fn genForList(self: *Codegen, f: ast.ForStmt, ret_qtype: QbeType) CodegenError!void {
        const list_info = self.vars.get(f.iterable.identifier) orelse return error.Unsupported;
        if (list_info.heap != .list) return error.Unsupported;
        const loop_var = self.vars.get(f.var_name).?;

        // İndeks yuvası, `collectLocals`de (bkz. `forListIdxName`) FONKSİYON
        // GİRİŞİNDE bir kez tahsis edilmiş olmalıdır — burada taze bir
        // `alloc8` yapmak, bu `for` başka bir döngünün içine gömülüyse her
        // dış yinelemede yığını küçültüp asla geri almaz (yığın taşması).
        const idx_name = try forListIdxName(self.allocator, f.var_name);
        const idx_slot = self.vars.get(idx_name).?.slot;
        try self.out.writer.print("    storel 0, {s}\n", .{idx_slot});

        const list_ptr = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ list_ptr, list_info.slot });
        const len_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, list_ptr });

        const cond_label = try self.newLabel("forlist_cond");
        const body_label = try self.newLabel("forlist_body");
        const end_label = try self.newLabel("forlist_end");

        const str_len_scope = try self.enterStrLenCacheScope(f.body);
        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{cond_label});
        const idx_cur = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ idx_cur, idx_slot });
        const cmp = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cmp, idx_cur, len_t });
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cmp, body_label, end_label });
        try self.out.writer.print("{s}\n", .{body_label});

        const byte_off = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ byte_off, idx_cur, qbeSizeOf(loop_var.qtype) });
        const off8 = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off8, byte_off, LIST_HEADER_SIZE });
        const elem_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ elem_addr, list_ptr, off8 });
        const elem_val = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ elem_val, qbeTypeName(loop_var.qtype), qbeTypeName(loop_var.qtype), elem_addr });
        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(loop_var.qtype), elem_val, loop_var.slot });

        try self.genStmts(f.body, ret_qtype);

        const idx_base = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ idx_base, idx_slot });
        const idx_next = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 1\n", .{ idx_next, idx_base });
        try self.out.writer.print("    storel {s}, {s}\n", .{ idx_next, idx_slot });
        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{end_label});
        self.exitStrLenCacheScope(str_len_scope);
    }

    /// Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `.none_lit`in
    /// bağlam-duyarlı üretimi — `genExpr`in KENDİSİ (bkz. onun `.none_lit`
    /// dalı) hâlâ koşulsuz `error.Unsupported` döner (HİÇBİR bağlam
    /// bilgisi ALMAZ), ÇÜNKÜ Nox'un GENEL ifade üretim mimarisi aşağıdan-
    /// yukarıya (bottom-up, hedef tipten BAĞIMSIZ) çalışır — `genExpr`in
    /// imzasına bir "beklenen tip" parametresi EKLEMEK tüm özyinelemeli
    /// çağrı grafiğini (`genExpr`in KENDİSİNİ çağıran ONLARCA site)
    /// etkileyen, bu görevin kapsamını AŞAN bir DEĞİŞİKLİK olurdu. Bunun
    /// YERİNE, HEDEFİN (bir değişken/alan/parametre/dönüş yuvasının)
    /// ÇÖZÜLMÜŞ `TypeInfo`sini ZATEN elinde bulunduran ÇAĞRI SİTELERİ
    /// (`var_decl`/`assign`/`genConstruct`/`genMethodCall`/`return_stmt`)
    /// `genExpr` yerine BUNU çağırır — FF.5'in `registerClass`ının
    /// `inferFieldType`i BYPASS ETMESİYLE AYNI "çağıran taraf bilir"
    /// deseni. Yalnızca HEAP-yönetimli (ya da `ptr`) bir hedef İçin
    /// anlamlıdır — `resolveType`in `.optional` dalı ZATEN İLKEL Optional'ları
    /// (kutulama HENÜZ yok, Faz FF.6.4) `error.Unsupported` İLE eledi, bu
    /// yüzden `target.heap == .none` burada YALNIZCA "gerçekten Optional
    /// OLMAYAN bir hedefe `None` YAZILMAYA ÇALIŞILDI" anlamına gelir —
    /// checker BUNU zaten reddetmiş olmalı, savunmacı olarak `genExpr`in
    /// KENDİ hatasına düşülür.
    fn genExprForTarget(self: *Codegen, expr: ast.Expr, target: anytype) CodegenError!Value {
        if (expr == .none_lit and target.heap != .none) {
            return .{
                .text = "0",
                .qtype = target.qtype,
                .heap = target.heap,
                .elem_qtype = target.elem_qtype,
                .class_name = target.class_name,
                .elem_heap_info = target.elem_heap_info,
                .elem_is_str = target.elem_is_str,
                .dict_info = target.dict_info,
            };
        }
        const v0 = try self.genExpr(expr);
        // Faz FF.6.4 (bkz. nox-teknik-spesifikasyon.md §3.65): hedef
        // kutulanmış bir Optional-ilkel (`boxed_scalar`) İSE VE `v0`
        // KENDİSİ HENÜZ kutulanmamış bir ÇIPLAK skalerse (ör. `x: int |
        // None = 5`, ya da daraltılmış/kutu OLMAYAN bir ifadeden gelen
        // değer) — YENİ bir kutu tahsis edilip değer İÇİNE yazılır. `v0`
        // ZATEN kutulanmışsa (ör. `y: int | None = x`, `x` KENDİSİ `int |
        // None`) OLDUĞU GİBİ geçirilir (retain, ÇAĞIRAN TARAFTA — bkz.
        // `retainIfAliasing` — normal aliasing yoluyla ZATEN ele alınır).
        if (target.heap == .boxed_scalar and v0.heap != .boxed_scalar) {
            return self.boxScalar(v0, target.elem_qtype);
        }
        return v0;
    }

    /// Faz FF.6.4: `v` (ham bir `.l`/`.d`/`.w` skaleri) TEK-ALANLI, ARC-
    /// yönetimli bir kutu İÇİNE sarar — `nox_rc_alloc(rt, 8)`, döndürülen
    /// pointer'ın KENDİSİNİN (list/class'ın AKSİNE, tag/başlık YOK) offset
    /// 0'ına DOĞRUDAN değeri yazar. `releaseValueIfSet`in `.boxed_scalar`
    /// dalı BU DÜZ 8-baytlık payload'ı VARSAYAR — İKİSİ TUTARLI kalmalıdır.
    fn boxScalar(self: *Codegen, v: Value, elem_qtype: QbeType) CodegenError!Value {
        const box = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_rc_alloc(l {s}, l 8)\n", .{ box, RT_PARAM });
        try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(elem_qtype), v.text, box });
        // `always_fresh = true` (bkz. `Value`nin belge notu, stdlib fazı §G
        // — `emitStringLiteral`in AYNI deseni): bu kutu HER ZAMAN TAZE bir
        // tahsistir (kaynak ifade bir `.identifier` OLSA BİLE — ör. `y: int
        // | None = some_bare_int` — kutunun KENDİSİ o değişkenin bir
        // ALIAS'I DEĞİLDİR) — `retainIfAliasing`in AST-tabanlı sezgisinin
        // (çıplak bir isim HER ZAMAN aliasing sayılır) burada YANLIŞ
        // POZİTİF üretip TAZE kutuyu SPÜRİYÖZ retain etmesini (kalıcı sızıntı)
        // ÖNLER.
        return .{ .text = box, .qtype = .l, .heap = .boxed_scalar, .elem_qtype = elem_qtype, .always_fresh = true };
    }

    fn convert(self: *Codegen, v: Value, target: QbeType) CodegenError!Value {
        if (v.qtype == target) return v;
        if (v.qtype == .l and target == .d) {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =d sltof {s}\n", .{ t, v.text });
            return .{ .text = t, .qtype = .d };
        }
        if (v.qtype == .d and target == .l) {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} =l dtosi {s}\n", .{ t, v.text });
            return .{ .text = t, .qtype = .l };
        }
        return error.Unsupported;
    }

    /// Faz 21 aşama 4: `v`yi (doğal QBE tipinde — `l`/`w`/`d`) `Task`/
    /// `Channel`in çalışma zamanı köprüsünün (bkz. `runtime/async_rt/
    /// bridge.zig`) beklediği tekdüze 8 baytlık `i64` "payload"a çevirir.
    /// `convert`in AKSİNE (sayısal DEĞER dönüşümü, ör. int->float), bu
    /// BİT-KORUYUCU bir yeniden yorumlamadır (`l`/`d` zaten 8 bayt — `cast`
    /// yalnızca bit örüntüsünü ikisi arasında taşır; `w`/bool `extuw` ile
    /// sıfır-genişletilir). `None` dönüşü önemsiz bir `0`dır.
    fn toPayload(self: *Codegen, v: Value) CodegenError!Value {
        return switch (v.qtype) {
            .l => v,
            .w => blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =l extuw {s}\n", .{ t, v.text });
                break :blk .{ .text = t, .qtype = .l };
            },
            .d => blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =l cast {s}\n", .{ t, v.text });
                break :blk .{ .text = t, .qtype = .l };
            },
            .none => .{ .text = "0", .qtype = .l },
        };
    }

    /// `toPayload`in tersi: bir `i64` payload'ı `target_qtype`e geri çevirir
    /// (`l`->`w` düz `copy` ile DÜŞÜK 32 biti alır — QBE'de geçerli bir
    /// daraltma; `l`->`d` `cast` ile bit örüntüsünü geri yorumlar).
    fn fromPayload(self: *Codegen, payload: Value, target_qtype: QbeType) CodegenError!Value {
        return switch (target_qtype) {
            .l => payload,
            .w => blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =w copy {s}\n", .{ t, payload.text });
                break :blk .{ .text = t, .qtype = .w };
            },
            .d => blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =d cast {s}\n", .{ t, payload.text });
                break :blk .{ .text = t, .qtype = .d };
            },
            .none => .{ .text = "0", .qtype = .none },
        };
    }

    /// Bir dize LİTERALİNİ (kaynak kodda YAZILMIŞ bir `.string_lit` İÇİN
    /// `genExpr` TARAFINDAN, ya da codegen'İN KENDİSİNİN sentezlediği sabit
    /// bir mesaj İÇİN — bkz. `genParseOrRaise`, stdlib fazı §E — DOĞRUDAN)
    /// `.data` bölümüne PINNED-refcount'lu bir dize olarak yayar, `str`
    /// tipli bir `Value` döner. Bkz. modül üstü not (`PINNED_REFCOUNT`
    /// hilesi) — `nox_rc_alloc`'un ürettüğü payload'larla AYNI temsili
    /// TAŞIMALIDIR, aksi halde bu değer bir ARC release'e uğradığında
    /// statik belleği bozardı.
    fn emitStringLiteral(self: *Codegen, s: []const u8) CodegenError!Value {
        const sym = try std.fmt.allocPrint(self.allocator, "$str{d}", .{self.string_counter});
        self.string_counter += 1;
        const escaped = try escapeForQbeString(self.allocator, s);
        try self.string_data.append(self.allocator, .{ .symbol = sym, .escaped = escaped });
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 8\n", .{ addr, sym });
        return .{ .text = addr, .qtype = .l, .heap = .str };
    }

    fn genExpr(self: *Codegen, expr: ast.Expr) CodegenError!Value {
        return switch (expr) {
            .int_lit => |v| .{ .text = try std.fmt.allocPrint(self.allocator, "{d}", .{v}), .qtype = .l },
            .float_lit => |v| .{ .text = try std.fmt.allocPrint(self.allocator, "d_{d}", .{v}), .qtype = .d },
            .bool_lit => |v| .{ .text = if (v) "1" else "0", .qtype = .w },
            .string_lit => |s| try self.emitStringLiteral(s),
            .identifier => |name| blk: {
                const info = self.vars.get(name) orelse return error.Unsupported;
                const t = try self.newTemp();
                try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ t, qbeTypeName(info.qtype), qbeTypeName(info.qtype), info.slot });
                // Faz FF.6.4: bkz. `narrowed_unbox`'ın belge notu — bu isim
                // ŞU AN daraltılmış bir kutulanmış Optional-ilkel İSE, kutu
                // POINTER'ı DEĞİL İÇİNDEKİ ham değer döndürülür.
                if (info.heap == .boxed_scalar and self.narrowed_unbox.contains(name)) {
                    const payload = try self.newTemp();
                    try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ payload, qbeTypeName(info.elem_qtype), qbeTypeName(info.elem_qtype), t });
                    break :blk .{ .text = payload, .qtype = info.elem_qtype };
                }
                break :blk .{ .text = t, .qtype = info.qtype, .heap = info.heap, .elem_qtype = info.elem_qtype, .class_name = info.class_name, .elem_heap_info = info.elem_heap_info, .elem_is_str = info.elem_is_str, .dict_info = info.dict_info, .arena = info.arena };
            },
            .unary => |u| try self.genUnary(u),
            .binary => |b| try self.genBinary(b),
            .call => |c| try self.genCall(c),
            .index => |idx| try self.genIndex(idx),
            .list_lit => |elems| try self.genListLit(elems),
            .dict_lit => |pairs| try self.genDictLit(pairs),
            .attribute => |a| try self.genFieldRead(a),
            .none_lit => error.Unsupported,
            // Faz 21 aşama 4 (bkz. nox-teknik-spesifikasyon.md §3.21):
            // `Task[T]`/`Channel[T]`in çalışma zamanı köprüsüne (bkz.
            // runtime/async_rt/bridge.zig) lowering.
            .await_expr => |operand| try self.genAwaitExpr(operand.*),
            .spawn_expr => |operand| try self.genSpawnExpr(operand.*),
            .generic_construct => |g| try self.genGenericConstruct(g),
        };
    }

    fn genFieldRead(self: *Codegen, a: ast.Attribute) CodegenError!Value {
        const obj = try self.genExpr(a.obj.*);
        if (obj.heap != .class) return error.Unsupported;
        const cinfo = self.classes.get(obj.class_name.?).?;
        for (cinfo.fields.items) |f| {
            if (!std.mem.eql(u8, f.name, a.attr)) continue;
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, obj.text, f.offset });
            const result = try self.newTemp();
            try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ result, qbeTypeName(f.info.qtype), qbeTypeName(f.info.qtype), addr });
            // `obj` TAZE bir değerse (ör. `make_car(i).engine`), okunan alanı
            // döndürmeden ÖNCE `obj`'yi serbest bırakırız (bkz.
            // `releaseIfTemporary`) — ama alanın KENDİSİ heap tipliyse (sınıf
            // YA DA list[T], bkz. görev "Sınıf alanı list[T] tipinde
            // olabilsin"), önce ONU retain etmeliyiz: aksi halde `obj`'nin
            // serbest bırakılması (özellikle refcount'u sıfıra düşüp `obj`
            // yok edilirse) bu alanı da özyinelemeli olarak serbest bırakabilir
            // (`genClassRelease`) — az önce okuduğumuz değeri kullanım-
            // sonrası-serbest-bırakmaya dönüştürür.
            if (isTemporaryExpr(a.obj.*) and isHeapManaged(f.info.heap)) {
                try self.emitInlineRetain(result);
            }
            try self.releaseIfTemporary(a.obj.*, obj);
            return .{ .text = result, .qtype = f.info.qtype, .heap = f.info.heap, .elem_qtype = f.info.elem_qtype, .class_name = f.info.class_name, .elem_heap_info = f.info.elem_heap_info, .elem_is_str = f.info.elem_is_str, .dict_info = f.info.dict_info };
        }
        return error.Unsupported;
    }

    /// `genFieldRead`in AST-BAĞIMSIZ, BASİTLEŞTİRİLMİŞ çekirdeği — stdlib
    /// fazı §D.1.6'nın `nox.http.serve` sarmalayıcısı (bkz.
    /// `genHttpServeWrapper`), kullanıcının döndürdüğü bir `HttpResponse`
    /// örneğinden (`ast.Expr`den DEĞİL, zaten hesaplanmış bir `Value`den)
    /// `status`/`body`/`headers` alanlarını okumak İÇİN kullanır. `genFieldRead`in
    /// AKSİNE `obj`i retain/release ETMEZ — sarmalayıcı `obj`nin (yanıt
    /// örneğinin) TÜM YAŞAM DÖNGÜSÜNÜ kendisi yönetir (alanları okuduktan
    /// SONRA `releaseValueIfSet` ile AÇIKÇA serbest bırakır), bu yüzden
    /// `genFieldRead`in "taban taze bir geçiciyse ÖNCE retain et" dansına
    /// GEREK YOKTUR.
    fn genFieldReadFromValue(self: *Codegen, obj: Value, field_name: []const u8) CodegenError!Value {
        if (obj.heap != .class) return error.Unsupported;
        const cinfo = self.classes.get(obj.class_name.?).?;
        for (cinfo.fields.items) |f| {
            if (!std.mem.eql(u8, f.name, field_name)) continue;
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, obj.text, f.offset });
            const result = try self.newTemp();
            try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ result, qbeTypeName(f.info.qtype), qbeTypeName(f.info.qtype), addr });
            return .{ .text = result, .qtype = f.info.qtype, .heap = f.info.heap, .elem_qtype = f.info.elem_qtype, .class_name = f.info.class_name, .elem_heap_info = f.info.elem_heap_info, .elem_is_str = f.info.elem_is_str, .dict_info = f.info.dict_info };
        }
        return error.Unsupported;
    }

    /// Faz GG.9: `idx`nin `genForRange`nin TESPİT ETTİĞİ (`bounds_elide_ctx`)
    /// `for i in range(len(xs)): ... xs[i] ...` deseninin TAM İÇİNDE OLUP
    /// OLMADIĞINI (isim BAZINDA, `idx.obj`/`idx.index` İKİSİ de BASİT birer
    /// kimlik OLMALI) doğrular.
    fn boundsElideApplies(self: *Codegen, idx: ast.Index) bool {
        if (idx.obj.* != .identifier or idx.index.* != .identifier) return false;
        const ctx = self.bounds_elide_ctx orelse return false;
        return std.mem.eql(u8, ctx.list_name, idx.obj.identifier) and std.mem.eql(u8, ctx.idx_var, idx.index.identifier);
    }

    fn genIndex(self: *Codegen, idx: ast.Index) CodegenError!Value {
        const obj = try self.genExpr(idx.obj.*);
        if (obj.heap == .dict) return self.genDictGet(obj, idx.index.*);
        if (obj.heap == .str) return self.genStrIndex(obj, idx);
        if (obj.heap != .list) return error.Unsupported;
        const index_v = try self.genExpr(idx.index.*);

        // Faz S.2: sınır kontrolü — `genStrIndex`in AYNI "önce doğrula, hata
        // dalında raise et, phi'SİZ ok'e atla" deseni (bkz. onun belge notu).
        // `list[T]`nin uzunluğu payload'ın İLK 8 baytıdır (bkz. `genListLit`),
        // bu yüzden AYRI bir betimleyiciye gerek yok — doğrudan `obj.text`ten
        // okunur. Faz GG.9: `xs[i]`, `genForRange`nin TESPİT ETTİĞİ `for i in
        // range(len(xs)): ...` deseninin TAM İÇİNDEYSE (bkz. `bounds_elide_ctx`)
        // bu kontrol TAMAMEN ATLANIR — `i`nin `[0, len(xs))` ARALIĞINDA
        // olduğu döngünün KENDİ sınırından ZATEN KANITLANMIŞTIR.
        if (!self.boundsElideApplies(idx)) {
            const len_t = try self.newTemp();
            try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, obj.text });
            const neg_t = try self.newTemp();
            try self.out.writer.print("    {s} =w csltl {s}, 0\n", .{ neg_t, index_v.text });
            const oob_hi_t = try self.newTemp();
            try self.out.writer.print("    {s} =w csgel {s}, {s}\n", .{ oob_hi_t, index_v.text, len_t });
            const oob_t = try self.newTemp();
            try self.out.writer.print("    {s} =w or {s}, {s}\n", .{ oob_t, neg_t, oob_hi_t });
            const err_label = try self.newLabel("list_idx_err");
            const ok_label = try self.newLabel("list_idx_ok");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ oob_t, err_label, ok_label });
            try self.out.writer.print("{s}\n", .{err_label});

            const msg_value = try self.emitStringLiteral("liste indeksi sinirlarin disinda");
            const ie_cinfo = self.classes.get("IndexError") orelse return error.Unsupported;
            const ie_obj = try self.genConstructFromValues("IndexError", ie_cinfo, &.{msg_value});
            try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, ie_obj.text });
            try self.emitExceptionCheck();
            try self.out.writer.print("    jmp {s}\n", .{ok_label});

            try self.out.writer.print("{s}\n", .{ok_label});
        }
        const byte_off = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ byte_off, index_v.text, qbeSizeOf(obj.elem_qtype) });
        const off8 = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off8, byte_off, LIST_HEADER_SIZE });
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ addr, obj.text, off8 });
        const result = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ result, qbeTypeName(obj.elem_qtype), qbeTypeName(obj.elem_qtype), addr });
        // `list[T]`nin elemanları (Faz 21 ön-koşulundan beri) heap tipli
        // (sınıf/iç içe liste) OLABİLİR — okunan değer listenin İÇİNDEKİ bir
        // elemana ÖDÜNÇ ALINMIŞ bir referanstır (bu okuma BAŞLI BAŞINA retain
        // gerektirmez, tıpkı bir `.attribute` okuması gibi), ama `.heap`/
        // `.class_name`/`.elem_heap_info`nin DOĞRU taşınması, bu değerin
        // sonradan bir çağrıya argüman/başka bir listeye eleman olarak doğru
        // release edilebilmesi için GEREKLİDİR. `obj`'nin KENDİSİ taze bir
        // liste olabilir (ör. `make_list()[0]`), bu yüzden yine de serbest
        // bırakılmalıdır — ama `obj` TAZE VE eleman heap tipliyse (bkz.
        // `genFieldRead`'deki AYNI gerekçe), `obj`'yi serbest bırakmadan ÖNCE
        // okunan elemanı retain ETMELİYİZ: aksi halde `obj`'nin refcount'u
        // sıfıra düşüp (`releaseIfTemporary`) elemanları özyinelemeli olarak
        // serbest bırakırsa (`genListElemRelease`), az önce okuduğumuz
        // elemanı kullanım-sonrası-serbest-bırakmaya çeviririz.
        if (isTemporaryExpr(idx.obj.*) and obj.elem_heap_info != null) {
            try self.emitInlineRetain(result);
        }
        try self.releaseIfTemporary(idx.obj.*, obj);
        return valueFromElemDescriptor(result, obj.elem_qtype, obj.elem_heap_info, obj.elem_is_str);
    }

    /// `s[i]` — stdlib fazı §G. Sınır KONTROLÜ QBE'de yapılır (`strlen` +
    /// karşılaştırma) — `genParseOrRaise`in AYNI "önce doğrula, hata
    /// dalında raise et, `phi`SİZ `ok`e atla" deseni (bkz. onun belge
    /// notu). Sonuç TEMEL diziden BAĞIMSIZ TAZE bir tahsistir (bkz.
    /// `nox_str_char_at`in belge notu) — `list`/`dict` indekslemesinin
    /// AKSİNE (o TABANIN İÇİNE bir takma addır), bu yüzden taban temporary
    /// olsa BİLE ÖNCE retain etmeye GEREK YOKTUR, yalnızca SONRADAN
    /// `releaseIfTemporary` ile tabanı serbest bırakmak yeterlidir.
    fn genStrIndex(self: *Codegen, obj: Value, idx: ast.Index) CodegenError!Value {
        const index_v = try self.genExpr(idx.index.*);
        // Faz GG.9: `genForRange`nin TESPİT ETTİĞİ `for i in range(len(s)):
        // ... s[i] ...` deseninin TAM İÇİNDEYSE (bkz. `bounds_elide_ctx`)
        // sınır kontrolü TAMAMEN ATLANIR — `strlen`in KENDİSİ de (`len_t`
        // YALNIZCA bu kontrol İÇİN GEREKTİĞİNDEN, GG.5'in önbelleği DAHİL)
        // HİÇ HESAPLANMAZ.
        if (!self.boundsElideApplies(idx)) {
            // Faz GG.5: `idx.obj` döngü-değişmez, `str`-tipli bir kimlikse VE
            // enclosing döngü GİRİŞİ bunun İçin ÖNCEDEN bir `strlen` hesaplayıp
            // önbelleğe ALDIYSA (bkz. `enterStrLenCacheScope`), o TEK SEFERLİK
            // hesaplanmış değer YENİDEN KULLANILIR — YENİ bir `$strlen` çağrısı
            // ÜRETİLMEZ.
            const len_t = if (idx.obj.* == .identifier and self.str_len_cache.get(idx.obj.identifier) != null)
                self.str_len_cache.get(idx.obj.identifier).?
            else blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =l call $strlen(l {s})\n", .{ t, obj.text });
                break :blk t;
            };
            const neg_t = try self.newTemp();
            try self.out.writer.print("    {s} =w csltl {s}, 0\n", .{ neg_t, index_v.text });
            const oob_hi_t = try self.newTemp();
            try self.out.writer.print("    {s} =w csgel {s}, {s}\n", .{ oob_hi_t, index_v.text, len_t });
            const oob_t = try self.newTemp();
            try self.out.writer.print("    {s} =w or {s}, {s}\n", .{ oob_t, neg_t, oob_hi_t });
            const err_label = try self.newLabel("str_idx_err");
            const ok_label = try self.newLabel("str_idx_ok");
            try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ oob_t, err_label, ok_label });
            try self.out.writer.print("{s}\n", .{err_label});

            const msg_value = try self.emitStringLiteral("str indeksi sinirlarin disinda");
            const ie_cinfo = self.classes.get("IndexError") orelse return error.Unsupported;
            const ie_obj = try self.genConstructFromValues("IndexError", ie_cinfo, &.{msg_value});
            try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, ie_obj.text });
            try self.emitExceptionCheck();
            try self.out.writer.print("    jmp {s}\n", .{ok_label});

            try self.out.writer.print("{s}\n", .{ok_label});
        }
        const result_t = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_str_char_at(l {s}, l {s}, l {s})\n", .{ result_t, RT_PARAM, obj.text, index_v.text });
        try self.releaseIfTemporary(idx.obj.*, obj);
        return .{ .text = result_t, .qtype = .l, .heap = .str, .always_fresh = true };
    }

    fn genListLit(self: *Codegen, elems: []const ast.Expr) CodegenError!Value {
        if (elems.len == 0) return error.Unsupported; // checker zaten reddeder; savunmacı

        const values = try self.allocator.alloc(Value, elems.len);
        for (elems, 0..) |el, i| {
            const v0 = try self.genExpr(el);
            // checker.zig burada tip düzeyinde kısıtlamıyor (bir `list_lit`
            // ifadesinin kendisi, isimlendirilmiş bir `list[T]` bildirimi
            // gerektirmeden `list[Sınıf]` olarak da tiplenebilir). Faz 21
            // ön-koşulundan beri heap-yönetimli (sınıf/iç içe liste) elemanlar
            // da DESTEKLENİYOR — bkz. modül üstü not, `releaseValueIfSet`/
            // `genListElemRelease`. Bir isim ALIASI ise (`retainIfAliasing`)
            // retain edilir; `lowlevel` içindeyken bu, `checkNoLowlevelEscape`
            // aracılığıyla ZATEN reddedilir (mevcut, değişmemiş geniş kural).
            values[i] = try self.retainIfAliasing(el, v0);
        }
        const first = values[0];
        const elem_qtype = first.qtype;
        var elem_heap_info: ?*const ElemHeapInfo = null;
        // `str` DAHİL (bkz. `resolveType`in list dalındaki AYNI gerekçe,
        // stdlib fazı §B) — `list[str]` elemanlarının kapsam-sonu/yeniden
        // atamada özyinelemeli release'e girmesi için gerekli.
        if (first.heap == .class or first.heap == .list or first.heap == .str) {
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = first.heap, .class_name = first.class_name, .elem_qtype = first.elem_qtype, .nested = first.elem_heap_info, .elem_is_str = first.elem_is_str };
            elem_heap_info = info;
        }
        const elem_is_str = first.heap == .str;
        const elem_size = qbeSizeOf(elem_qtype);
        const payload_size = LIST_HEADER_SIZE + elem_size * elems.len;

        const t = try self.newTemp();
        const arena = self.currentArena();
        if (arena) |ap| {
            try self.out.writer.print("    {s} =l call $nox_arena_alloc(l {s}, l {d})\n", .{ t, ap, payload_size });
        } else {
            try self.out.writer.print("    {s} =l call $nox_rc_alloc(l {s}, l {d})\n", .{ t, RT_PARAM, payload_size });
        }
        try self.out.writer.print("    storel {d}, {s}\n", .{ elems.len, t });
        // Faz U.1: kapasite (@8) — bir literalden inşa edilen bir liste HER
        // ZAMAN tam-oturan başlar (kapasite=uzunluk, büyüme SLACK'i YOK) —
        // yalnızca `.append()` GEREKTİĞİNDE gerçek büyüme uygular.
        const cap_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 8\n", .{ cap_addr, t });
        try self.out.writer.print("    storel {d}, {s}\n", .{ elems.len, cap_addr });
        for (values, 0..) |v, i| {
            const off = LIST_HEADER_SIZE + elem_size * i;
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, t, off });
            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(elem_qtype), v.text, addr });
        }
        return .{ .text = t, .qtype = .l, .heap = .list, .elem_qtype = elem_qtype, .elem_heap_info = elem_heap_info, .elem_is_str = elem_is_str, .arena = arena != null };
    }

    /// `{k1: v1, k2: v2, ...}` — `runtime/collections/dict.zig`nin
    /// `nox_dict_new`/`nox_dict_set`ine lowerlanır (bkz. nox-teknik-
    /// spesifikasyon.md §3.28). `dict`in KENDİSİ ARC-yönetimli DEĞİLDİR
    /// (bkz. `HeapKind`in belge notu, `Task`/`Channel`le AYNI desen) — ama
    /// `str` anahtar/değerler `retainIfAliasing` ile (list_lit İLE AYNI
    /// desen) doğru şekilde retain edilir; `nox_dict_set` bunları OLDUĞU
    /// GİBİ (ek bir retain OLMADAN) depolar — sahiplik ÇAĞIRANDAN (buradan)
    /// devralınır.
    fn genDictLit(self: *Codegen, pairs: []const ast.DictPair) CodegenError!Value {
        if (pairs.len == 0) return error.Unsupported; // checker zaten reddeder; savunmacı

        const key_values = try self.allocator.alloc(Value, pairs.len);
        const value_values = try self.allocator.alloc(Value, pairs.len);
        for (pairs, 0..) |p, i| {
            const k0 = try self.genExpr(p.key);
            try self.checkNoLowlevelEscape(k0);
            key_values[i] = try self.retainIfAliasing(p.key, k0);
            const v0 = try self.genExpr(p.value);
            try self.checkNoLowlevelEscape(v0);
            value_values[i] = try self.retainIfAliasing(p.value, v0);
        }
        const key_is_str = key_values[0].heap == .str;
        const value_is_str = value_values[0].heap == .str;
        const value_qtype = value_values[0].qtype;

        const dinfo = try self.allocator.create(DictInfo);
        dinfo.* = .{ .key_is_str = key_is_str, .value_qtype = value_qtype, .value_is_str = value_is_str };

        const key_is_str_lit: []const u8 = if (key_is_str) "1" else "0";
        const value_is_str_lit: []const u8 = if (value_is_str) "1" else "0";

        const d = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_dict_new(l {s}, w {s})\n", .{ d, RT_PARAM, key_is_str_lit });

        for (key_values, 0..) |kv, i| {
            const key_payload = try self.toPayload(kv);
            const value_payload = try self.toPayload(value_values[i]);
            try self.out.writer.print("    call $nox_dict_set(l {s}, l {s}, w {s}, w {s}, l {s}, l {s})\n", .{ RT_PARAM, d, key_is_str_lit, value_is_str_lit, key_payload.text, value_payload.text });
        }

        return .{ .text = d, .qtype = .l, .heap = .dict, .dict_info = dinfo };
    }

    fn genUnary(self: *Codegen, u: ast.Unary) CodegenError!Value {
        const operand = try self.genExpr(u.operand.*);
        return switch (u.op) {
            .neg => blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} ={s} neg {s}\n", .{ t, qbeTypeName(operand.qtype), operand.text });
                break :blk .{ .text = t, .qtype = operand.qtype };
            },
            .not_ => blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =w xor {s}, 1\n", .{ t, operand.text });
                break :blk .{ .text = t, .qtype = .w };
            },
        };
    }

    fn emitBin(self: *Codegen, mnemonic: []const u8, l: Value, r: Value, result_qtype: QbeType) CodegenError!Value {
        const t = try self.newTemp();
        try self.out.writer.print("    {s} ={s} {s} {s}, {s}\n", .{ t, qbeTypeName(result_qtype), mnemonic, l.text, r.text });
        return .{ .text = t, .qtype = result_qtype };
    }

    fn emitCmp(self: *Codegen, op: ast.BinaryOp, l: Value, r: Value, common: QbeType) CodegenError!Value {
        const t = try self.newTemp();
        try self.out.writer.print("    {s} =w {s} {s}, {s}\n", .{ t, cmpMnemonic(op, common), l.text, r.text });
        return .{ .text = t, .qtype = .w };
    }

    fn callLibm1(self: *Codegen, comptime name: []const u8, v: Value) CodegenError!Value {
        const t = try self.newTemp();
        try self.out.writer.print("    {s} =d call ${s}(d {s})\n", .{ t, name, v.text });
        return .{ .text = t, .qtype = .d };
    }

    fn callLibm2(self: *Codegen, comptime name: []const u8, l: Value, r: Value) CodegenError!Value {
        const t = try self.newTemp();
        try self.out.writer.print("    {s} =d call ${s}(d {s}, d {s})\n", .{ t, name, l.text, r.text });
        return .{ .text = t, .qtype = .d };
    }

    /// `strcmp` (libc, `cc` bağlantısında zaten mevcut — `printf` gibi başka
    /// çağrılarla AYNI şekilde ekstra bir bağlama argümanı gerekmez) ile iki
    /// `str`in İÇERİĞİNİ karşılaştırır; sonucu `0`a karşı `w` bir bool'a çevirir.
    fn genStrCompare(self: *Codegen, op: ast.BinaryOp, l: Value, r: Value) CodegenError!Value {
        const cmp_t = try self.newTemp();
        try self.out.writer.print("    {s} =w call $strcmp(l {s}, l {s})\n", .{ cmp_t, l.text, r.text });
        const result = try self.newTemp();
        const mnemonic: []const u8 = if (op == .eq) "ceqw" else "cnew";
        try self.out.writer.print("    {s} =w {s} {s}, 0\n", .{ result, mnemonic, cmp_t });
        return .{ .text = result, .qtype = .w };
    }

    fn genBinary(self: *Codegen, b: ast.Binary) CodegenError!Value {
        if (b.op == .and_ or b.op == .or_) {
            const l = try self.genExpr(b.left.*);
            const r = try self.genExpr(b.right.*);
            const mnemonic: []const u8 = if (b.op == .and_) "and" else "or";
            return self.emitBin(mnemonic, l, r, .w);
        }

        // Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `x != None` /
        // `x == None` — checker'ın narrowing'in ÖN KOŞULU olarak KABUL
        // ETTİĞİ TEK örüntü (bkz. `checkBinary`in `.eq, .ne` dalı VE
        // `Checker.detectNarrowing`). `.none_lit`in KENDİSİ `genExpr`den
        // GEÇİRİLMEZ (o hâlâ koşulsuz `error.Unsupported` döner) — DİĞER
        // taraf ÜRETİLİR VE doğrudan `0` (null pointer sentinel) İLE
        // karşılaştırılır; Optional'ın çalışma zamanı temsili taban HEAP
        // tiple AYNI OLDUĞUNDAN (bkz. `resolveType`in `.optional` dalı) bu
        // `_eq`/`strcmp` GEREKTİRMEYEN, basit bir işaretçi karşılaştırmasıdır.
        if ((b.op == .eq or b.op == .ne) and (b.left.* == .none_lit or b.right.* == .none_lit)) {
            const other_expr: ast.Expr = if (b.left.* == .none_lit) b.right.* else b.left.*;
            const other = try self.genExpr(other_expr);
            const cmp_t = try self.newTemp();
            const mnemonic: []const u8 = if (b.op == .eq) "ceql" else "cnel";
            try self.out.writer.print("    {s} =w {s} {s}, 0\n", .{ cmp_t, mnemonic, other.text });
            try self.releaseIfTemporary(other_expr, other);
            return .{ .text = cmp_t, .qtype = .w };
        }

        const l0 = try self.genExpr(b.left.*);
        const r0 = try self.genExpr(b.right.*);

        // `str == str` / `str != str` — GERÇEK içerik karşılaştırması
        // (`strcmp`, çünkü `str` her zaman sıfırla-sonlanan bir C dizesidir).
        // checker.zig zaten yalnızca `==`/`!=`i (ve yalnızca AYNI tipteki iki
        // tarafı) buraya kadar geçirir (bkz. `checkBinary`in `.eq, .ne`
        // dalı). **Düzeltme (stdlib fazı §H'de BULUNAN gerçek bir sızıntı):**
        // bu dalın ESKİ belge notu "str HİÇBİR ZAMAN ARC-yönetimli değildir"
        // diyordu — bu, Alt-Faz B'nin `str`i ARC-yönetimli YAPMASINDAN
        // ÖNCEKİ bir varsayımdı, ASLA güncellenmemişti. Operandlardan biri
        // TEMPORARY ise (ör. `s[i] != prefix[j]` — Alt-Faz G'nin `s[i]`si,
        // YA DA `(a + b) == c` gibi bir concat sonucu) SERBEST BIRAKILMASI
        // GEREKİR — `list`/`class` eşitlik dalıyla (aşağı) VE `str + str`
        // dalıyla (aşağı) AYNI desen.
        if (l0.heap == .str and r0.heap == .str and (b.op == .eq or b.op == .ne)) {
            const result = try self.genStrCompare(b.op, l0, r0);
            try self.releaseIfTemporary(b.left.*, l0);
            try self.releaseIfTemporary(b.right.*, r0);
            return result;
        }

        // `list[T] == list[T]` / `sınıf == sınıf` — ÖZYİNELEMELİ yapısal
        // karşılaştırma (bkz. görev "list/class için derin yapısal eşitlik",
        // `genClassEq`/`genListEq`). checker zaten yalnızca AYNI (iç içe)
        // tipteki iki tarafı buraya kadar geçirir (`types.eql`, bkz.
        // `checkBinary`in `.eq, .ne` dalı) — bu yüzden `l0`nin
        // betimleyicileri (`class_name`/`elem_*`) `r0` için de geçerlidir.
        // Operandlar `lowlevel` arenasından gelemez (aşağıdaki
        // `checkNoLowlevelEscape` ile AYNI geniş kural, bkz. modül üstü not) —
        // bir arena işaretçisini `$..._eq`e ARGÜMAN olarak geçirmek de
        // "çağrıya argüman" kısıtlamasına girer. `l0`/`r0`nin KENDİLERİ
        // (bir DEĞİŞKENE bağlı tam liste/sınıf DEĞERLERİ, bir ALAN/ELEMAN
        // DEĞİL) hiçbir zaman null OLAMAZ — bu yüzden `genEqCompareOrJump`'ın
        // alan/eleman-seviyesi null-güvenliği burada GEREKMEZ; `$..._eq`
        // DOĞRUDAN çağrılır.
        if ((l0.heap == .list or l0.heap == .class) and r0.heap == l0.heap and (b.op == .eq or b.op == .ne)) {
            try self.checkNoLowlevelEscape(l0);
            try self.checkNoLowlevelEscape(r0);
            const eq_temp = try self.newTemp();
            if (l0.heap == .class) {
                try self.out.writer.print("    {s} =w call ${s}_eq(l {s}, l {s}, l {s})\n", .{ eq_temp, l0.class_name.?, RT_PARAM, l0.text, r0.text });
            } else {
                const fn_name = try self.eqFnNameForList(l0.elem_qtype, l0.elem_heap_info, l0.elem_is_str);
                try self.out.writer.print("    {s} =w call ${s}_eq(l {s}, l {s}, l {s})\n", .{ eq_temp, fn_name, RT_PARAM, l0.text, r0.text });
            }
            const result: []const u8 = if (b.op == .ne) blk: {
                const t = try self.newTemp();
                try self.out.writer.print("    {s} =w xor {s}, 1\n", .{ t, eq_temp });
                break :blk t;
            } else eq_temp;
            try self.releaseIfTemporary(b.left.*, l0);
            try self.releaseIfTemporary(b.right.*, r0);
            return .{ .text = result, .qtype = .w };
        }

        // `str + str` — YENİ bir birleştirilmiş dize üretir (stdlib fazı §B,
        // bkz. `runtime/str.zig`). checker zaten yalnızca iki tarafı da
        // `str` olan bir `+`i buraya kadar geçirir (`checkBinary`in `.add`
        // dalı). Sonuç TAZE bir heap değeridir (refcount 1 ile başlar) —
        // `.call` sonucuyla AYNI şekilde ele alınır (bkz. `isTemporaryExpr`in
        // `.binary` dalı).
        if (l0.heap == .str and r0.heap == .str and b.op == .add) {
            try self.checkNoLowlevelEscape(l0);
            try self.checkNoLowlevelEscape(r0);
            const result_t = try self.newTemp();
            try self.out.writer.print("    {s} =l call $nox_str_concat(l {s}, l {s}, l {s})\n", .{ result_t, RT_PARAM, l0.text, r0.text });
            try self.releaseIfTemporary(b.left.*, l0);
            try self.releaseIfTemporary(b.right.*, r0);
            return .{ .text = result_t, .qtype = .l, .heap = .str };
        }

        // list[T]/sınıf içerik karşılaştırması yalnızca `==`/`!=` içindir —
        // başka bir ikili operatör (`<`, `+`, ...) heap tipli bir işlenenle
        // hâlâ reddedilir (checker zaten bunu sayısal/bool tiplerle
        // sınırlar, burası savunmacıdır).
        if (l0.heap != .none or r0.heap != .none) return error.Unsupported;

        if (b.op == .div) {
            const l = try self.convert(l0, .d);
            const r = try self.convert(r0, .d);
            return self.emitBin("div", l, r, .d);
        }

        const common: QbeType = if (l0.qtype == .d or r0.qtype == .d)
            .d
        else if (l0.qtype == .w or r0.qtype == .w)
            .w
        else
            .l;
        const l = try self.convert(l0, common);
        const r = try self.convert(r0, common);

        return switch (b.op) {
            .add => self.emitBin("add", l, r, common),
            .sub => self.emitBin("sub", l, r, common),
            .mul => self.emitBin("mul", l, r, common),
            .floordiv => self.genFloorDiv(l, r, common),
            .mod => self.genMod(l, r, common),
            .pow => self.genPow(l, r, common),
            .eq, .ne, .lt, .le, .gt, .ge => self.emitCmp(b.op, l, r, common),
            .div, .and_, .or_ => unreachable,
        };
    }

    fn genFloorDiv(self: *Codegen, l: Value, r: Value, common: QbeType) CodegenError!Value {
        if (common == .d) {
            const divided = try self.emitBin("div", l, r, .d);
            return self.callLibm1("floor", divided);
        }

        const q = try self.emitBin("div", l, r, .l);
        const rem = try self.emitBin("rem", l, r, .l);

        const rem_nonzero = try self.newTemp();
        try self.out.writer.print("    {s} =w cnel {s}, 0\n", .{ rem_nonzero, rem.text });
        const rem_neg = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, 0\n", .{ rem_neg, rem.text });
        const r_neg = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, 0\n", .{ r_neg, r.text });
        const sign_diff = try self.newTemp();
        try self.out.writer.print("    {s} =w xor {s}, {s}\n", .{ sign_diff, rem_neg, r_neg });
        const need_adjust = try self.newTemp();
        try self.out.writer.print("    {s} =w and {s}, {s}\n", .{ need_adjust, rem_nonzero, sign_diff });

        // Dallanma/yığın yuvası KULLANMADAN (bkz. `adjustModSign`'daki aynı
        // gerekçe) `need_adjust`i (0 ya da 1) `l`ye genişletip bölümden
        // çıkarırız — 0 ise değişiklik yok, 1 ise bir eksiltilmiş olur.
        const mask = try self.newTemp();
        try self.out.writer.print("    {s} =l extuw {s}\n", .{ mask, need_adjust });
        const result = try self.newTemp();
        try self.out.writer.print("    {s} =l sub {s}, {s}\n", .{ result, q.text, mask });
        return .{ .text = result, .qtype = .l };
    }

    fn genMod(self: *Codegen, l: Value, r: Value, common: QbeType) CodegenError!Value {
        const rem = if (common == .d) try self.callLibm2("fmod", l, r) else try self.emitBin("rem", l, r, .l);
        return self.adjustModSign(rem, r, common);
    }

    /// Not (kritik): bu fonksiyon eskiden bir `alloc8` yığın yuvası + dallanma
    /// (jnz/label) kullanıyordu. Bir `%`/`//` ifadesi bir DÖNGÜ gövdesi
    /// içinde tekrar tekrar değerlendirildiğinde (ör. `while i < n: x = i % 3`),
    /// QBE'nin `alloc8`'i FONKSİYON GİRİŞİNDE bir kez yapılacak bir tahsis
    /// olarak varsayması nedeniyle, döngü içine gömülü her `alloc8` her
    /// yinelemede yığın işaretçisini (`sub sp, sp, 16`) küçültüyor ve ASLA
    /// geri almıyordu — bu da (deneyerek doğrulandı, bkz. benchmark suite
    /// kalibrasyonu) yüz binlerce yinelemeden sonra sessiz bir yığın
    /// taşmasına (stack overflow → segfault) yol açıyordu. Çözüm: dallanma/
    /// bellek KULLANMADAN, `need_adjust`i (0 ya da 1) ortak tipe genişletip
    /// bölene çarpıp kalana eklemek — SAF aritmetik, hiçbir döngü derinliğinde
    /// yığın büyümesi olmaz (ayrıca dallanmasız olduğu için daha hızlıdır).
    fn adjustModSign(self: *Codegen, rem: Value, divisor: Value, common: QbeType) CodegenError!Value {
        const zero_lit: []const u8 = if (common == .d) "d_0" else "0";
        const eq_ne_suffix: []const u8 = if (common == .d) "d" else "l";
        const lt_op: []const u8 = if (common == .d) "cltd" else "csltl";

        const rem_nonzero = try self.newTemp();
        try self.out.writer.print("    {s} =w cne{s} {s}, {s}\n", .{ rem_nonzero, eq_ne_suffix, rem.text, zero_lit });
        const rem_neg = try self.newTemp();
        try self.out.writer.print("    {s} =w {s} {s}, {s}\n", .{ rem_neg, lt_op, rem.text, zero_lit });
        const div_neg = try self.newTemp();
        try self.out.writer.print("    {s} =w {s} {s}, {s}\n", .{ div_neg, lt_op, divisor.text, zero_lit });
        const sign_diff = try self.newTemp();
        try self.out.writer.print("    {s} =w xor {s}, {s}\n", .{ sign_diff, rem_neg, div_neg });
        const need_adjust = try self.newTemp();
        try self.out.writer.print("    {s} =w and {s}, {s}\n", .{ need_adjust, rem_nonzero, sign_diff });

        const mask = try self.newTemp();
        if (common == .d) {
            try self.out.writer.print("    {s} =d uwtof {s}\n", .{ mask, need_adjust });
        } else {
            try self.out.writer.print("    {s} =l extuw {s}\n", .{ mask, need_adjust });
        }
        const amount = try self.newTemp();
        try self.out.writer.print("    {s} ={s} mul {s}, {s}\n", .{ amount, qbeTypeName(common), mask, divisor.text });
        const result = try self.newTemp();
        try self.out.writer.print("    {s} ={s} add {s}, {s}\n", .{ result, qbeTypeName(common), rem.text, amount });
        return .{ .text = result, .qtype = common };
    }

    fn genPow(self: *Codegen, l: Value, r: Value, common: QbeType) CodegenError!Value {
        const lf = try self.convert(l, .d);
        const rf = try self.convert(r, .d);
        const t = try self.newTemp();
        try self.out.writer.print("    {s} =d call $pow(d {s}, d {s})\n", .{ t, lf.text, rf.text });
        const result: Value = .{ .text = t, .qtype = .d };
        if (common == .l) return self.convert(result, .l);
        return result;
    }

    /// `print(<ifade>)`in tek giriş noktası. `list[T]`/sınıf İÇİN
    /// `genPrintFragment`e (özyineli, tırnaksız-OLMAYAN `str` biçimi — bkz.
    /// onun belge notu) yönlenip bir satır sonu ekler; değer tipleri İÇİN
    /// (Python'un `print()`i `str()` kullanır, `repr()` DEĞİL — bu yüzden en
    /// dıştaki bir `str` TIRNAKSIZ basılır, `genPrintFragment`in `str_frag`
    /// biçiminden BİLEREK FARKLI) DEĞİŞMEMİŞ eski (satır-sonu dahil) format
    /// sabitlerini kullanır.
    fn genPrint(self: *Codegen, v: Value) CodegenError!void {
        if (v.heap == .list or v.heap == .class) {
            try self.genPrintFragment(v);
            try self.out.writer.writeAll("    call $printf(l $fmt_newline)\n");
            return;
        }
        switch (v.qtype) {
            .l => if (v.heap == .str)
                try self.out.writer.print("    call $printf(l $fmt_str, ..., l {s})\n", .{v.text})
            else
                try self.out.writer.print("    call $printf(l $fmt_int, ..., l {s})\n", .{v.text}),
            .d => try self.out.writer.print("    call $printf(l $fmt_float, ..., d {s})\n", .{v.text}),
            .w => {
                const true_label = try self.newLabel("print_true");
                const false_label = try self.newLabel("print_false");
                const done_label = try self.newLabel("print_done");
                try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ v.text, true_label, false_label });
                try self.out.writer.print("{s}\n", .{true_label});
                try self.out.writer.writeAll("    call $printf(l $fmt_bool_true)\n");
                try self.out.writer.print("    jmp {s}\n", .{done_label});
                try self.out.writer.print("{s}\n", .{false_label});
                try self.out.writer.writeAll("    call $printf(l $fmt_bool_false)\n");
                try self.out.writer.print("    jmp {s}\n", .{done_label});
                try self.out.writer.print("{s}\n", .{done_label});
            },
            .none => return error.Unsupported,
        }
    }

    /// `v`yi satır SONU OLMADAN basar — `list[T]`/sınıf görüntülemesi (bkz.
    /// görev "print(list)/print(class) görüntüleme biçimi") ÖZYİNELEMELİDİR
    /// (bir listenin/sınıfın elemanı/alanı yine bir liste/sınıf olabilir);
    /// yalnızca en dıştaki `genPrint` çağrısı bir satır sonu ekler.
    fn genPrintFragment(self: *Codegen, v: Value) CodegenError!void {
        if (v.heap == .list) return self.genPrintList(v);
        if (v.heap == .class) return self.genPrintClass(v);
        switch (v.qtype) {
            .l => if (v.heap == .str)
                try self.out.writer.print("    call $printf(l $fmt_str_frag, ..., l {s})\n", .{v.text})
            else
                try self.out.writer.print("    call $printf(l $fmt_int_frag, ..., l {s})\n", .{v.text}),
            .d => try self.out.writer.print("    call $printf(l $fmt_float_frag, ..., d {s})\n", .{v.text}),
            .w => {
                const true_label = try self.newLabel("print_true");
                const false_label = try self.newLabel("print_false");
                const done_label = try self.newLabel("print_done");
                try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ v.text, true_label, false_label });
                try self.out.writer.print("{s}\n", .{true_label});
                try self.out.writer.writeAll("    call $printf(l $fmt_bool_true_frag)\n");
                try self.out.writer.print("    jmp {s}\n", .{done_label});
                try self.out.writer.print("{s}\n", .{false_label});
                try self.out.writer.writeAll("    call $printf(l $fmt_bool_false_frag)\n");
                try self.out.writer.print("    jmp {s}\n", .{done_label});
                try self.out.writer.print("{s}\n", .{done_label});
            },
            .none => return error.Unsupported,
        }
    }

    /// Derleme zamanında bilinen (kullanıcı verisi İÇERMEYEN — yalnızca sınıf/
    /// alan adları gibi kaynak-kodu metinleri) sabit bir metni `printf`e
    /// FORMAT dizesi olarak geçirilebilecek bir `data` sembolüne dönüştürür.
    /// Normal `str` literallerinden (`string_data`) FARKLI: burada üretilen
    /// sembol ARC'ın "pinned refcount" başlığını TAŞIMAZ (bu metin hiçbir
    /// zaman bir Nox `str` DEĞERİ olarak dolaşmaz, yalnızca `printf`in İLK
    /// argümanı olarak kullanılır) — bu yüzden `.string_lit`in aksine `+8`
    /// ofsetlemesi GEREKMEZ.
    fn internFmtString(self: *Codegen, text: []const u8) CodegenError![]const u8 {
        const sym = try std.fmt.allocPrint(self.allocator, "$fmt_lit{d}", .{self.fmt_counter});
        self.fmt_counter += 1;
        const escaped = try escapeForQbeString(self.allocator, text);
        try self.fmt_data.append(self.allocator, .{ .symbol = sym, .escaped = escaped });
        return sym;
    }

    /// `list[T]` görüntülemesi — Python'un `repr([...])`ine benzer:
    /// `[e1, e2, ...]`, elemanlar `genPrintFragment` ile ÖZYİNELEMELİ basılır
    /// (bir liste elemanı yine bir liste/sınıf olabilir). Liste UZUNLUĞU
    /// yalnızca ÇALIŞMA ZAMANINDA bilindiğinden (derleme zamanında sabit bir
    /// format dizesi ÇÖZÜLEMEZ), `genForList`/`genListElemRelease` ile AYNI
    /// güvenli döngü desenini (FONKSİYON GİRİŞİNDE bir kez `alloc8`) kullanır.
    fn genPrintList(self: *Codegen, v: Value) CodegenError!void {
        try self.out.writer.writeAll("    call $printf(l $fmt_lbracket)\n");

        const len_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, v.text });
        const idx_slot = try self.newTemp();
        try self.out.writer.print("    {s} =l alloc8 8\n", .{idx_slot});
        try self.out.writer.print("    storel 0, {s}\n", .{idx_slot});

        const cond_label = try self.newLabel("printlist_cond");
        const body_label = try self.newLabel("printlist_body");
        const end_label = try self.newLabel("printlist_end");
        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{cond_label});
        const idx_cur = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ idx_cur, idx_slot });
        const cont = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cont, idx_cur, len_t });
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cont, body_label, end_label });
        try self.out.writer.print("{s}\n", .{body_label});

        const not_first = try self.newTemp();
        try self.out.writer.print("    {s} =w cnel {s}, 0\n", .{ not_first, idx_cur });
        const comma_label = try self.newLabel("printlist_comma");
        const skip_comma_label = try self.newLabel("printlist_skipcomma");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ not_first, comma_label, skip_comma_label });
        try self.out.writer.print("{s}\n", .{comma_label});
        try self.out.writer.writeAll("    call $printf(l $fmt_comma_sp)\n");
        try self.out.writer.print("    jmp {s}\n", .{skip_comma_label});
        try self.out.writer.print("{s}\n", .{skip_comma_label});

        const off = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ off, idx_cur, qbeSizeOf(v.elem_qtype) });
        const off8 = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off8, off, LIST_HEADER_SIZE });
        const addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ addr, v.text, off8 });
        const elem = try self.newTemp();
        try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ elem, qbeTypeName(v.elem_qtype), qbeTypeName(v.elem_qtype), addr });
        try self.genPrintFragment(valueFromElemDescriptor(elem, v.elem_qtype, v.elem_heap_info, v.elem_is_str));

        const idx_next = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 1\n", .{ idx_next, idx_cur });
        try self.out.writer.print("    storel {s}, {s}\n", .{ idx_next, idx_slot });
        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{end_label});

        try self.out.writer.writeAll("    call $printf(l $fmt_rbracket)\n");
    }

    /// Sınıf görüntülemesi — `ClassName(alan1=değer1, alan2=değer2, ...)`.
    /// Alan sayısı/adları/tipleri derleme zamanında SABİTTİR (`cinfo.fields`),
    /// bu yüzden döngü GEREKMEZ — ama alan DEĞERLERİ (özellikle iç içe
    /// sınıf/`list[T]` alanları) `genPrintFragment` ile ÖZYİNELEMELİ basılır.
    fn genPrintClass(self: *Codegen, v: Value) CodegenError!void {
        const class_name = v.class_name.?;
        const cinfo = self.classes.get(class_name).?;
        const open_sym = try self.internFmtString(try std.fmt.allocPrint(self.allocator, "{s}(", .{class_name}));
        try self.out.writer.print("    call $printf(l {s})\n", .{open_sym});
        for (cinfo.fields.items, 0..) |f, i| {
            if (i != 0) try self.out.writer.writeAll("    call $printf(l $fmt_comma_sp)\n");
            const name_sym = try self.internFmtString(try std.fmt.allocPrint(self.allocator, "{s}=", .{f.name}));
            try self.out.writer.print("    call $printf(l {s})\n", .{name_sym});
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, v.text, f.offset });
            const fv = try self.newTemp();
            try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ fv, qbeTypeName(f.info.qtype), qbeTypeName(f.info.qtype), addr });
            try self.genPrintFragment(.{ .text = fv, .qtype = f.info.qtype, .heap = f.info.heap, .elem_qtype = f.info.elem_qtype, .class_name = f.info.class_name, .elem_heap_info = f.info.elem_heap_info, .elem_is_str = f.info.elem_is_str });
        }
        try self.out.writer.writeAll("    call $printf(l $fmt_rparen)\n");
    }

    /// Bir serbest fonksiyonun/kurucunun (`__init__`) gövdesi hakkında
    /// toplanan ham bilgi — bkz. `computeMustNotRaise`.
    const FuncSafetyInfo = struct {
        /// `true`: gövde İÇİNDE doğrudan bir `raise`, bir METOD ÇAĞRISI
        /// (`obj.method()` — bkz. `computeMustNotRaise`in "muhafazakâr" notu)
        /// ya da bir `await`/`spawn` var — bu durumda BU sembol HER ZAMAN
        /// "güvensiz" sayılır, çağırdıklarından bağımsız olarak.
        direct_unsafe: bool = false,
        /// Gövdenin çağırdığı serbest fonksiyon/kurucu sembollerinin listesi
        /// (deduplike edilmemiş — önemli değil, yalnızca üyelik kontrolü
        /// için kullanılır). Bu sembollerden HERHANGİ BİRİ güvensizse, BU
        /// sembol de (fixpoint yoluyla) güvensiz sayılır.
        callees: std.ArrayListUnmanaged([]const u8) = .empty,
    };

    /// Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): inline edilen bir
    /// callee'nin TEK bir parametresi/yerel değişkeni İçİN, caller'ın giriş
    /// bloğunda ÖNCEDEN tahsis edilmiş (bkz. `registerInlineSite`) slot —
    /// `orig_name` callee'nin KAYNAK isim, `slot` VE `info` `allocSlot`in
    /// ÜRETTİĞİ AYNI temsil (bkz. `VarInfo`).
    const NamedSlot = struct {
        orig_name: []const u8,
        slot: []const u8,
        info: TypeInfo,
    };

    /// Faz GG.2: TEK bir inline-splice sitesi İçin ÖN-TAHSİS EDİLMİŞ TÜM
    /// slotlar — `prepareInlineSites` TARAFINDAN doldurulur, `genInlinedCall`
    /// TARAFINDAN tüketilir.
    const InlineSiteInfo = struct {
        callee: ast.FuncDef,
        params: []const NamedSlot,
        locals: []const NamedSlot,
        /// `null` İSE callee'nin dönüş tipi `None` (sonuç YOK).
        result: ?NamedSlot,
    };

    /// Faz GG.2: `genStmts`in `.return_stmt` dalının, İÇİNDE bulunulan
    /// splice'ın "gerçek bir fonksiyon çıkışı DEĞİL, bir `jmp`e dönüşmesi
    /// gerektiğini" bilmesini sağlayan GEÇİCİ bağlam — `genInlinedCall`
    /// TARAFINDAN AYARLANIR/GERİ YÜKLENİR (iç içe inline YOK olduğundan
    /// ASLA yığınlanmaz, TEK bir aktif hedef yeterlidir).
    const InlineReturnTarget = struct {
        result_slot: ?[]const u8,
        done_label: []const u8,
        /// Yalnızca BU isimler (callee'nin KENDİ parametre+yerelleri)
        /// `return_stmt`in İÇİNDE serbest bırakılır — caller'ın DİĞER
        /// yerellerine ASLA dokunulmaz.
        owned_names: []const []const u8,
    };

    /// `class_ctx`/`var_types`/`poisoned` — Faz M.8 (yeniden ele alındı, bkz.
    /// nox-teknik-spesifikasyon.md §3.59): `obj.method()` çağrılarını (basit,
    /// çözülebilir alıcılar için) `direct_unsafe` yerine gerçek bir `callees`
    /// bağımlılığına çevirebilmek için TÜM gövde boyunca taşınan, DÜZ (blok-
    /// kapsamsız — `collectLocals`in AYNI Python-tarzı fonksiyon-seviyesi
    /// kapsam varsayımı, bkz. onun belge notu) durum: `class_ctx` metodun AİT
    /// OLDUĞU sınıfın adı (`self.diğer_metod()` çözümü için, serbest
    /// fonksiyonlarda `null`), `var_types` yerel isim → sınıf adı haritası
    /// (parametrelerden ÖN-DOLDURULUR, `var_decl` deyimleriyle METİN
    /// SIRASINDA güncellenir), `poisoned` ise bir isim BİRDEN FAZLA kez
    /// bildirilirse (`if`/`else` dallarında FARKLI sınıflara — `checker.zig`nin
    /// `Scope.declare`si YİNELENEN isim kontrolü YAPMAZ, satır ~97-111)
    /// KALICI olarak "çözülemez" işaretlenen isimlerin kümesidir — bir isim
    /// ASLA `poisoned`dan çıkmaz, bu da `genMethodCall`in GERÇEKTE çağırdığı
    /// sembolle bu analizin çözdüğü sembolün HER ZAMAN aynı kalmasını garanti
    /// eder (aksi halde YANLIŞ bir sınıfın metodu "güvenli" sayılabilir —
    /// SESSİZ-YUTMA riski).
    fn declareVarType(self: *Codegen, name: []const u8, class_name: ?[]const u8, var_types: *std.StringHashMapUnmanaged([]const u8), poisoned: *std.StringHashMapUnmanaged(void)) CodegenError!void {
        if (poisoned.contains(name)) return;
        if (var_types.contains(name)) {
            _ = var_types.remove(name);
            try poisoned.put(self.allocator, name, {});
            return;
        }
        if (class_name) |cn| try var_types.put(self.allocator, name, cn);
    }

    /// `stmts`i özyinelemeli olarak gezip `info`yi doldurur — `moduleUsesAsync`/
    /// `stmtUsesAsync`in AYNI ağaç gezinme deseni (bkz. onların belge notu),
    /// ama "async kullanımı var mı" yerine "raise/metod-çağrısı/await-spawn
    /// var mı VE hangi serbest fonksiyon/kurucular çağrılıyor" topluyor.
    fn collectRaiseInfoStmts(self: *Codegen, stmts: []const ast.Stmt, info: *FuncSafetyInfo, class_ctx: ?[]const u8, var_types: *std.StringHashMapUnmanaged([]const u8), poisoned: *std.StringHashMapUnmanaged(void), list_elem_types: *std.StringHashMapUnmanaged([]const u8)) CodegenError!void {
        for (stmts) |stmt| try self.collectRaiseInfoStmt(stmt, info, class_ctx, var_types, poisoned, list_elem_types);
    }

    fn collectRaiseInfoStmt(self: *Codegen, stmt: ast.Stmt, info: *FuncSafetyInfo, class_ctx: ?[]const u8, var_types: *std.StringHashMapUnmanaged([]const u8), poisoned: *std.StringHashMapUnmanaged(void), list_elem_types: *std.StringHashMapUnmanaged([]const u8)) CodegenError!void {
        switch (stmt.kind) {
            .expr_stmt => |e| try self.collectRaiseInfoExpr(e, info, class_ctx, var_types, poisoned),
            .var_decl => |v| {
                try self.collectRaiseInfoExpr(v.value, info, class_ctx, var_types, poisoned);
                const cn: ?[]const u8 = if (v.type_expr == .simple and self.classes.contains(v.type_expr.simple)) v.type_expr.simple else null;
                try self.declareVarType(v.name, cn, var_types, poisoned);
                // Faz GG.3 (bkz. nox-teknik-spesifikasyon.md §3.68): `xs:
                // list[ClassName] = ...` İSE, `list_elem_types`e de
                // KAYDEDİLİR — `.for_stmt`in AŞAĞIDAKİ dalı `for v in xs:`
                // İÇİNDEKİ `v`nin sınıfını BURADAN çözer. AYNI `poisoned`
                // kümesi (bkz. `declareVarType`) hem `var_types` hem
                // `list_elem_types` İçin PAYLAŞILIR — bir isim HER İKİ
                // anlamda da YENİDEN bildirilirse GÜVENLİ tarafta kalınır.
                const elem_cn: ?[]const u8 = blk: {
                    if (v.type_expr != .generic) break :blk null;
                    const g = v.type_expr.generic;
                    if (!std.mem.eql(u8, g.name, "list") or g.args.len != 1) break :blk null;
                    if (g.args[0] != .simple or !self.classes.contains(g.args[0].simple)) break :blk null;
                    break :blk g.args[0].simple;
                };
                try self.declareVarType(v.name, elem_cn, list_elem_types, poisoned);
            },
            .assign => |a| {
                try self.collectRaiseInfoExpr(a.target, info, class_ctx, var_types, poisoned);
                try self.collectRaiseInfoExpr(a.value, info, class_ctx, var_types, poisoned);
            },
            .if_stmt => |f| {
                try self.collectRaiseInfoExpr(f.cond, info, class_ctx, var_types, poisoned);
                try self.collectRaiseInfoStmts(f.then_body, info, class_ctx, var_types, poisoned, list_elem_types);
                for (f.elif_clauses) |ec| {
                    try self.collectRaiseInfoExpr(ec.cond, info, class_ctx, var_types, poisoned);
                    try self.collectRaiseInfoStmts(ec.body, info, class_ctx, var_types, poisoned, list_elem_types);
                }
                if (f.else_body) |eb| try self.collectRaiseInfoStmts(eb, info, class_ctx, var_types, poisoned, list_elem_types);
            },
            .while_stmt => |w| {
                try self.collectRaiseInfoExpr(w.cond, info, class_ctx, var_types, poisoned);
                try self.collectRaiseInfoStmts(w.body, info, class_ctx, var_types, poisoned, list_elem_types);
            },
            .for_stmt => |f| {
                try self.collectRaiseInfoExpr(f.iterable, info, class_ctx, var_types, poisoned);
                // Faz GG.3 (yeniden ele alındı, bkz. nox-teknik-spesifikasyon.md
                // §3.68): ÖNCEDEN döngü değişkeni HER ZAMAN `null` İLE
                // zehirlenirdi (sınıfı "bilinmiyor" sayılırdı) — bu, `for x
                // in xs: x.method()` kalıbının OLDUĞU HER fonksiyonu
                // KOŞULSUZ güvensiz işaretleyip Faz M.8'in kazanımını
                // SIFIRLIYORDU (GERÇEKTEN bulunan bir boşluk). ARTIK
                // `f.iterable` ÇIPLAK bir isimse VE o isim `list_elem_types`de
                // (bir `list[ClassName]` yerel/parametresi olarak) BİLİNİYORSA,
                // döngü değişkeni O sınıfla `var_types`e KAYDEDİLİR — `genForList`nin
                // GERÇEK codegen'İNİN (bkz. `collectLocals`in `.for_stmt` dalı)
                // ZATEN yaptığı AYNI çözümleme, burada TEKRARLANIR.
                const elem_cn: ?[]const u8 = blk: {
                    if (f.iterable != .identifier) break :blk null;
                    if (poisoned.contains(f.iterable.identifier)) break :blk null;
                    break :blk list_elem_types.get(f.iterable.identifier);
                };
                try self.declareVarType(f.var_name, elem_cn, var_types, poisoned);
                try self.collectRaiseInfoStmts(f.body, info, class_ctx, var_types, poisoned, list_elem_types);
            },
            .func_def, .class_def, .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => {},
            .return_stmt => |r| if (r) |e| try self.collectRaiseInfoExpr(e, info, class_ctx, var_types, poisoned),
            .raise_stmt => |e| {
                info.direct_unsafe = true;
                try self.collectRaiseInfoExpr(e, info, class_ctx, var_types, poisoned);
            },
            .try_stmt => |t| {
                try self.collectRaiseInfoStmts(t.try_body, info, class_ctx, var_types, poisoned, list_elem_types);
                for (t.except_clauses) |ec| try self.collectRaiseInfoStmts(ec.body, info, class_ctx, var_types, poisoned, list_elem_types);
                if (t.finally_body) |fb| try self.collectRaiseInfoStmts(fb, info, class_ctx, var_types, poisoned, list_elem_types);
            },
            .lowlevel_stmt => |ll| try self.collectRaiseInfoStmts(ll.body, info, class_ctx, var_types, poisoned, list_elem_types),
            // Faz U.5: bir `with` deyimi HER ZAMAN örtük `__enter__`/
            // `__exit__` METOD ÇAĞRILARI içerir — bunlar da (diğer tüm metod
            // çağrıları gibi) `collectRaiseInfoExpr`in `.attribute` dalından
            // GEÇMEZ (yalnızca `w.ctx_expr`in KENDİSİ, çağrının hedefi değil,
            // gezilir), bu yüzden burası KOŞULSUZ güvensiz kalmaya devam eder.
            .with_stmt => |w| {
                info.direct_unsafe = true;
                try self.collectRaiseInfoExpr(w.ctx_expr, info, class_ctx, var_types, poisoned);
                try self.collectRaiseInfoStmts(w.body, info, class_ctx, var_types, poisoned, list_elem_types);
            },
        }
    }

    fn collectRaiseInfoExpr(self: *Codegen, expr: ast.Expr, info: *FuncSafetyInfo, class_ctx: ?[]const u8, var_types: *std.StringHashMapUnmanaged([]const u8), poisoned: *std.StringHashMapUnmanaged(void)) CodegenError!void {
        switch (expr) {
            // `await`/`spawn`: async istisna yayılımı ZATEN bilinçli olarak
            // eksik/ele alınmamış bir alan (bkz. nox-teknik-spesifikasyon.md
            // §3.21) — bu analiz oraya HİÇ dokunmaz, muhafazakâr kalır.
            // `generic_construct` (`Channel[T](...)`): Nox'un istisna
            // mekanizmasına katılmaz (kendi runtime çağrısı `emitExceptionCheck`
            // KULLANMAZ), bu yüzden güvenlidir.
            .await_expr, .spawn_expr => info.direct_unsafe = true,
            .generic_construct => {},
            .unary => |u| try self.collectRaiseInfoExpr(u.operand.*, info, class_ctx, var_types, poisoned),
            .binary => |b| {
                try self.collectRaiseInfoExpr(b.left.*, info, class_ctx, var_types, poisoned);
                try self.collectRaiseInfoExpr(b.right.*, info, class_ctx, var_types, poisoned);
            },
            .call => |c| {
                switch (c.callee.*) {
                    .identifier => |name| {
                        if (self.classes.contains(name)) {
                            const cinfo = self.classes.get(name).?;
                            if (cinfo.has_init) {
                                const sym = try std.fmt.allocPrint(self.allocator, "{s}___init__", .{name});
                                try info.callees.append(self.allocator, sym);
                            }
                            // `has_init == false`: kurucu çağrısı hiçbir zaman
                            // `emitExceptionCheck` üretmez (bkz. `genConstruct`) —
                            // bağımlılık eklemeye gerek yok.
                        } else if (self.functions.contains(name)) {
                            try info.callees.append(self.allocator, name);
                        } else if (self.extern_functions.contains(name)) {
                            // `extern def`: Nox'un istisna mekanizmasına HİÇ
                            // katılmaz (bkz. `genCall`in extern dalı) — güvenli.
                        } else if (std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "len") or
                            std.mem.eql(u8, name, "str") or std.mem.eql(u8, name, "hpy_call") or
                            std.mem.eql(u8, name, "wasm_call"))
                        {
                            // `genCall`in KENDİ özel dispatch'iyle (satır ~4258
                            // civarı) TUTARLI, AÇIKÇA belgelenmiş "asla raise
                            // etmez" yerleşikler — `int`/`float` BİLEREK BU
                            // listede DEĞİL (`genParseOrRaise` ile GERÇEKTEN
                            // `ValueError` raise EDEBİLİRLER, bkz. checker.zig'in
                            // eşdeğer notu) — o ikisi AŞAĞIDAKİ `else` dalına
                            // düşüp MUHAFAZAKAR şekilde güvensiz sayılır.
                        } else {
                            // Faz M.8 (yeniden ele alındı, bkz. nox-teknik-
                            // spesifikasyon.md §3.59): BURASI ÖNCEDEN (bu
                            // `else` dalı hiç YOKTU) SESSİZCE hiçbir şey
                            // YAPMIYORDU — isim ne `self.classes` ne `self.
                            // functions`se (ör. bir iç içe closure'ı TUTAN
                            // yerel bir değişken/parametre) GÜVENLİ SAYILIYORDU,
                            // bu da GERÇEK bir istisnanın SESSİZCE YUTULMASINA
                            // yol açabilen, GERÇEKTEN doğrulanmış bir hataydı
                            // (bkz. `closure_raise_not_swallowed.nox` golden
                            // testi — düzeltmeden ÖNCE KIRMIZIYDI). BİLİNMEYEN
                            // bir çağrı hedefi HER ZAMAN güvensiz sayılır.
                            info.direct_unsafe = true;
                        }
                    },
                    // Metod çağrısı (`obj.method()`) — Faz M.8 (yeniden ele
                    // alındı, bkz. nox-teknik-spesifikasyon.md §3.59): alıcı
                    // ÇIPLAK bir yerel isimse VE o ismin sınıfı `var_types`
                    // ÜZERİNDEN BİLİNİYORSA (ve isim `poisoned` DEĞİLSE),
                    // hedef metod GERÇEK bir `callees` bağımlılığı olarak
                    // eklenir (serbest fonksiyon çağrılarıyla AYNI muamele).
                    // AKSİ HALDE (zincirleme çağrı, attribute-of-attribute,
                    // index, ÇÖZÜLEMEYEN/poisoned isim, `self.classes`de
                    // OLMAYAN bir tip — protokol/generic parametre gibi)
                    // MUHAFAZAKÂR `direct_unsafe = true` davranışı KORUNUR.
                    .attribute => |att| {
                        var resolved = false;
                        if (att.obj.* == .identifier) {
                            const recv_name = att.obj.identifier;
                            if (!poisoned.contains(recv_name)) {
                                if (var_types.get(recv_name)) |class_name| {
                                    if (self.classes.get(class_name)) |cinfo| {
                                        if (cinfo.methods.contains(att.attr)) {
                                            const sym = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ class_name, att.attr });
                                            try info.callees.append(self.allocator, sym);
                                            resolved = true;
                                        }
                                    }
                                }
                            }
                        }
                        if (!resolved) info.direct_unsafe = true;
                    },
                    else => info.direct_unsafe = true,
                }
                for (c.args) |a| try self.collectRaiseInfoExpr(a, info, class_ctx, var_types, poisoned);
            },
            .attribute => |a| try self.collectRaiseInfoExpr(a.obj.*, info, class_ctx, var_types, poisoned),
            .index => |idx| {
                try self.collectRaiseInfoExpr(idx.obj.*, info, class_ctx, var_types, poisoned);
                try self.collectRaiseInfoExpr(idx.index.*, info, class_ctx, var_types, poisoned);
            },
            .list_lit => |elems| for (elems) |el| try self.collectRaiseInfoExpr(el, info, class_ctx, var_types, poisoned),
            .dict_lit => |pairs| for (pairs) |p| {
                try self.collectRaiseInfoExpr(p.key, info, class_ctx, var_types, poisoned);
                try self.collectRaiseInfoExpr(p.value, info, class_ctx, var_types, poisoned);
            },
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
        }
    }

    /// Performans fazı — `nox_exception_pending` çağrılarının (özyinelemeli/
    /// küçük-fonksiyon-ağırlıklı kodda, bkz. `fib`in profillenmesi) baskın
    /// bir maliyet olduğu bulundu. Bu fonksiyon, HER serbest fonksiyonun/
    /// kurucunun (`__init__`) TRANSİTİF olarak ASLA istisna FIRLATAMAYACAĞINI
    /// KANITLAYABİLDİĞİMİZ bir küme (`self.must_not_raise`) hesaplar —
    /// `genCall`/`genConstruct` bu kümedeki bir çağrı SONRASI
    /// `emitExceptionCheck`i ATLAYABİLİR.
    ///
    /// **Bilinçli olarak MUHAFAZAKÂR (yanlış negatifte İSTİSNA ASLA
    /// YUTULMAZ, yalnızca gereksiz bir kontrol FAZLADAN kalabilir):**
    ///   - Metod çağrıları (`obj.method()`) YALNIZCA alıcının sınıfı basit bir
    ///     yerel isim üzerinden `var_types` ile KANITLANABİLİYORSA (bkz. Faz
    ///     M.8, `collectRaiseInfoExpr`in `.attribute` dalı) gerçek bir
    ///     bağımlılığa çevrilir; ÇÖZÜLEMEYEN her alıcı (zincirleme çağrı,
    ///     tam tip çıkarımı gerektiren durumlar, `poisoned` bir isim) İÇİNDE
    ///     bulunduğu fonksiyonu/kurucuyu KOŞULSUZ güvensiz sayar.
    ///   - `await`/`spawn` içeren HERHANGİ bir gövde KOŞULSUZ güvensiz sayılır
    ///     (async istisna yayılımı zaten bilinçli olarak eksik bir alan).
    ///   - Sabit nokta (fixpoint) hesabı: `direct_unsafe` bulunanlarla
    ///     başlanır, sonra HERHANGİ bir çağrı hedefi (`callees`) güvensiz
    ///     kümedeyse çağıran da güvensiz kümeye eklenir — değişiklik
    ///     kalmayana kadar tekrarlanır (yalnızca BÜYÜYEN, sonlu bir küme,
    ///     bu yüzden sonlanması garantidir). Özyinelemeli fonksiyonlar
    ///     (ör. `fib`) doğru şekilde ele alınır: `fib` kendi kendini
    ///     çağırır, ama kendisi `direct_unsafe` değilse VE kendisi (henüz)
    ///     güvensiz kümede DEĞİLSE, bu öz-çağrı fixpoint'i ASLA tetiklemez —
    ///     `fib` güvenli kalır (doğru sonuç, çünkü `fib` GERÇEKTEN hiçbir
    ///     zaman raise etmez).
    ///
    /// **Faz M.8 (yeniden ele alındı):** metodlar ARTIK `__init__` ile
    /// SINIRLI değil — `cd.methods`deki HER metod analiz edilir, sembol
    /// formatı TÜM metodlar için `"{class_name}_{method_name}"` (`genMethod`/
    /// `genMethodCall`in KENDİ ÇAĞRI/TANIM sembolüyle BİREBİR aynı formül,
    /// `__init__` özel durumu `"{s}___init__"` İLE ZATEN AYNI ŞEYDİR).
    /// `obj.method()` çağrıları hâlâ VARSAYILAN olarak güvensizdir — YALNIZCA
    /// alıcının sınıfı `var_types` ÜZERİNDEN kanıtlanabilir bir yerel isimse
    /// (bkz. `collectRaiseInfoExpr`in `.attribute` dalı) gerçek bir `callees`
    /// bağımlılığına çevrilir.
    fn buildParamVarTypes(self: *Codegen, params: []const ast.Param, class_ctx: ?[]const u8) CodegenError!std.StringHashMapUnmanaged([]const u8) {
        var var_types: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (params) |p| {
            if (std.mem.eql(u8, p.name, "self")) {
                if (class_ctx) |cc| try var_types.put(self.allocator, p.name, cc);
            } else if (p.type_expr == .simple and self.classes.contains(p.type_expr.simple)) {
                try var_types.put(self.allocator, p.name, p.type_expr.simple);
            }
        }
        return var_types;
    }

    /// Faz GG.3 (bkz. nox-teknik-spesifikasyon.md §3.68): `buildParamVarTypes`in
    /// AYNI deseni, ama `list[ClassName]` tipli parametreler İçin — `for x
    /// in some_list_param:` kalıbının ZATEN M.8'in `.identifier` çözümlemesinden
    /// FAYDALANABİLMESİ İçin GEREKİR (bkz. `collectRaiseInfoStmt`in
    /// `.for_stmt` dalı).
    fn buildParamListElemTypes(self: *Codegen, params: []const ast.Param) CodegenError!std.StringHashMapUnmanaged([]const u8) {
        var list_elem_types: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (params) |p| {
            if (p.type_expr != .generic) continue;
            const g = p.type_expr.generic;
            if (!std.mem.eql(u8, g.name, "list") or g.args.len != 1) continue;
            if (g.args[0] != .simple or !self.classes.contains(g.args[0].simple)) continue;
            try list_elem_types.put(self.allocator, p.name, g.args[0].simple);
        }
        return list_elem_types;
    }

    /// Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): `computeMustNotRaise`
    /// VE `computeInlinableFunctions`in İKİSİNİN de İHTİYAÇ DUYDUĞU whole-
    /// program `FuncSafetyInfo` haritasını inşa eden ORTAK çekirdek —
    /// ÖNCEDEN yalnızca `computeMustNotRaise`in İÇİNDEYDİ, GG.2'nin KENDİ
    /// özyineleme-tespiti (`markRecursiveFuncs`) İçin AYNI çağrı-grafiği
    /// bilgisine (`callees` listeleri) İHTİYACI olduğundan buraya
    /// ÇIKARILDI (basit kod-taşıma, davranış DEĞİŞMEDİ).
    fn buildFuncSafetyInfoMap(self: *Codegen, module: ast.Module, extra_functions: []const ast.FuncDef) CodegenError!std.StringHashMapUnmanaged(FuncSafetyInfo) {
        var info_map: std.StringHashMapUnmanaged(FuncSafetyInfo) = .empty;

        for (module.body) |stmt| {
            switch (stmt.kind) {
                .func_def => |fd| {
                    if (fd.is_async) continue; // async fonksiyonlar yalnızca `spawn` ile başlatılır, bu optimizasyonun çağrı sitelerinde hiç görünmezler.
                    var info: FuncSafetyInfo = .{};
                    var var_types = try self.buildParamVarTypes(fd.params, null);
                    var poisoned: std.StringHashMapUnmanaged(void) = .empty;
                    var list_elem_types = try self.buildParamListElemTypes(fd.params);
                    try self.collectRaiseInfoStmts(fd.body, &info, null, &var_types, &poisoned, &list_elem_types);
                    try info_map.put(self.allocator, fd.name, info);
                },
                .class_def => |cd| {
                    for (cd.methods) |m| {
                        var info: FuncSafetyInfo = .{};
                        var var_types = try self.buildParamVarTypes(m.params, cd.name);
                        var poisoned: std.StringHashMapUnmanaged(void) = .empty;
                        var list_elem_types = try self.buildParamListElemTypes(m.params);
                        try self.collectRaiseInfoStmts(m.body, &info, cd.name, &var_types, &poisoned, &list_elem_types);
                        const sym = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ cd.name, m.name });
                        try info_map.put(self.allocator, sym, info);
                    }
                },
                else => {},
            }
        }
        for (extra_functions) |fd| {
            if (fd.is_async) continue;
            var info: FuncSafetyInfo = .{};
            var var_types = try self.buildParamVarTypes(fd.params, null);
            var poisoned: std.StringHashMapUnmanaged(void) = .empty;
            var list_elem_types = try self.buildParamListElemTypes(fd.params);
            try self.collectRaiseInfoStmts(fd.body, &info, null, &var_types, &poisoned, &list_elem_types);
            try info_map.put(self.allocator, fd.name, info);
        }
        return info_map;
    }

    fn computeMustNotRaise(self: *Codegen, module: ast.Module, extra_functions: []const ast.FuncDef) CodegenError!void {
        var info_map = try self.buildFuncSafetyInfoMap(module, extra_functions);

        // Dil stabilizasyonu fazı §M.1: ÖNCEDEN burada naif bir
        // `while (changed)` sabit-nokta döngüsü vardı — HER turda TÜM
        // `info_map`i (VE her fonksiyonun TÜM çağrı listesini) YENİDEN
        // tarardı; uzun bir çağrı zincirinde (A→B→C→…→Z, Z güvensiz)
        // güvensizlik HER turda yalnızca BİR sıçrama ilerlediğinden bu
        // O(F²) (fonksiyon SAYISININ karesi) idi. `core.nox` artık HER
        // programa koşulsuz dahil olduğundan F her zaman büyük bir taban
        // içeriyor — bu YÜZDEN bunun yerine TERS çağrı grafiği
        // (`callee -> callers`) ÖNCEDEN inşa edilip GERÇEK bir worklist
        // kullanılır: yalnızca YENİ güvensiz işaretlenen bir fonksiyonun
        // ÇAĞIRANLARI kuyruğa eklenir, HER düğüm/kenar EN FAZLA bir kez
        // işlenir — O(F+E).
        var callers_of: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
        {
            var it = info_map.iterator();
            while (it.next()) |entry| {
                const caller_name = entry.key_ptr.*;
                for (entry.value_ptr.callees.items) |callee| {
                    const gop = try callers_of.getOrPut(self.allocator, callee);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.allocator, caller_name);
                }
            }
        }

        var unsafe_set: std.StringHashMapUnmanaged(void) = .empty;
        var worklist: std.ArrayListUnmanaged([]const u8) = .empty;
        {
            var it = info_map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.direct_unsafe) {
                    try unsafe_set.put(self.allocator, entry.key_ptr.*, {});
                    try worklist.append(self.allocator, entry.key_ptr.*);
                }
            }
        }
        while (worklist.pop()) |name| {
            const callers = callers_of.get(name) orelse continue;
            for (callers.items) |caller| {
                if (unsafe_set.contains(caller)) continue;
                try unsafe_set.put(self.allocator, caller, {});
                try worklist.append(self.allocator, caller);
            }
        }

        var it = info_map.iterator();
        while (it.next()) |entry| {
            if (!unsafe_set.contains(entry.key_ptr.*)) {
                try self.must_not_raise.put(self.allocator, entry.key_ptr.*, {});
            }
        }

        // `ClassInfo.init_is_safe`i doldur — `genConstruct`in tekrar tekrar
        // `"{s}___init__"` biçimlendirip `must_not_raise`de aramak yerine
        // doğrudan okuyabileceği tek bir alan (bkz. onun belge notu).
        var cit = self.classes.iterator();
        while (cit.next()) |entry| {
            if (!entry.value_ptr.has_init) continue;
            const sym = try std.fmt.allocPrint(self.allocator, "{s}___init__", .{entry.key_ptr.*});
            if (self.must_not_raise.contains(sym)) entry.value_ptr.init_is_safe = true;
        }
    }

    // ---- Faz GG.2: seçici serbest-fonksiyon inlining'i (bkz. nox-teknik-
    // spesifikasyon.md §3.67) ----

    /// Bir DFS yığınında (`stack`) hâlâ AKTİF olan bir isme geri-kenar (back-
    /// edge) bulunursa, yığının O NOKTADAN SONRAKİ TÜMÜ (döngüdeki HER düğüm,
    /// yalnızca doğrudan hedef DEĞİL) `self.recursive_funcs`e eklenir — bu,
    /// A→B→C→A gibi ÇOK-düğümlü döngülerde B'nin de (yalnızca A/C değil)
    /// doğru işaretlenmesini SAĞLAR. Derleme-zamanı-YALNIZCA bir geçiş
    /// (çalışma zamanı maliyeti YOK) olduğundan, `callers_of`in O(F+E)
    /// hassasiyeti BURADA GEREKMEZ — basit/okunabilir bir yığın-taraması
    /// tercih edildi.
    fn dfsMarkRecursive(self: *Codegen, name: []const u8, info_map: *const std.StringHashMapUnmanaged(FuncSafetyInfo), visited: *std.StringHashMapUnmanaged(void), stack: *std.ArrayListUnmanaged([]const u8)) CodegenError!void {
        try visited.put(self.allocator, name, {});
        try stack.append(self.allocator, name);
        if (info_map.get(name)) |info| {
            for (info.callees.items) |callee| {
                var cycle_start: ?usize = null;
                for (stack.items, 0..) |s, i| {
                    if (std.mem.eql(u8, s, callee)) {
                        cycle_start = i;
                        break;
                    }
                }
                if (cycle_start) |start| {
                    for (stack.items[start..]) |cyc_name| {
                        try self.recursive_funcs.put(self.allocator, cyc_name, {});
                    }
                    continue;
                }
                if (!visited.contains(callee)) {
                    try self.dfsMarkRecursive(callee, info_map, visited, stack);
                }
            }
        }
        _ = stack.pop();
    }

    /// `self.recursive_funcs`i doldurur — `computeInlinableFunctions`
    /// TARAFINDAN, `buildFuncSafetyInfoMap`in (transitif çağrı grafiği İçin,
    /// `computeMustNotRaise`in ZATEN inşa ettiğiyle AYNI YAPI) İKİNCİ, BAĞIMSIZ
    /// bir çağrısıyla BİRLİKTE kullanılır.
    fn markRecursiveFuncs(self: *Codegen, info_map: *const std.StringHashMapUnmanaged(FuncSafetyInfo)) CodegenError!void {
        var visited: std.StringHashMapUnmanaged(void) = .empty;
        var it = info_map.iterator();
        while (it.next()) |entry| {
            if (!visited.contains(entry.key_ptr.*)) {
                var stack: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.dfsMarkRecursive(entry.key_ptr.*, info_map, &visited, &stack);
            }
        }
    }

    const MAX_INLINE_TOP_STMTS: usize = 8;
    const MAX_INLINE_TOTAL_STMTS: usize = 20;

    /// Bir inline-adayı gövdenin (özyinelemeli, `if`/`elif`/`else` İÇİNE de
    /// uygulanır) YALNIZCA `var_decl`/`assign`/`expr_stmt`/`if_stmt`/
    /// `return_stmt`/`pass_stmt` İÇERDİĞİNİ doğrular VE TOPLAM deyim sayısını
    /// döner — `while`/`for`/`try`/`with`/`raise`/`lowlevel`/iç içe `func_def`/
    /// `class_def` VARSA `null` (diskalifiye) döner. `while`/`for`in DIŞLANMASI
    /// İKİ ayrı riski BAŞTAN eler: QBE'nin döngü-İÇİ `alloc4`/`alloc8`
    /// tehlikesi (bkz. `adjustModSign`in belge notu) VE `return`i "değeri
    /// slota yaz + `jmp`" biçimine çevirmenin KARMAŞIKLAŞMASI (TEK bir
    /// doğrusal/dallı gövdede HER `return` ZATEN AYNI `done_label`e gider).
    fn inlineBodyStmtCount(stmts: []const ast.Stmt) ?usize {
        var total: usize = 0;
        for (stmts) |stmt| {
            switch (stmt.kind) {
                .var_decl, .assign, .expr_stmt, .return_stmt, .pass_stmt => total += 1,
                .if_stmt => |f| {
                    total += 1;
                    total += inlineBodyStmtCount(f.then_body) orelse return null;
                    for (f.elif_clauses) |ec| total += inlineBodyStmtCount(ec.body) orelse return null;
                    if (f.else_body) |eb| total += inlineBodyStmtCount(eb) orelse return null;
                },
                else => return null,
            }
        }
        return total;
    }

    /// Bir serbest fonksiyonun (`fd`) Faz GG.2 KAPSAMINDA "inline edilebilir"
    /// SAYILIP SAYILMADIĞINI belirler — bkz. nox-teknik-spesifikasyon.md
    /// §3.67'nin TAM uygunluk listesi. `self.must_not_raise`in ZATEN
    /// dolu OLMASI GEREKİR (bkz. `computeInlinableFunctions`in çağrı SIRASI
    /// notu) — bu şart, splice SIRASINDA bir istisna kontrolünün caller'ın
    /// ERKEN-çıkış yoluna girip GÖLGELENMİŞ bir yerelin GÖRÜNMEZ kalarak
    /// SIZMASINI YAPISAL olarak İMKANSIZ kılar (bkz. `genInlinedCall`in
    /// belge notu).
    fn isFuncInlineEligible(self: *Codegen, fd: ast.FuncDef, generic_template_names: []const []const u8) bool {
        if (fd.is_async) return false;
        if (fd.type_params.len != 0) return false;
        for (generic_template_names) |n| {
            if (std.mem.eql(u8, n, fd.name)) return false;
        }
        if (self.recursive_funcs.contains(fd.name)) return false;
        if (!self.must_not_raise.contains(fd.name)) return false;
        if (fd.body.len > MAX_INLINE_TOP_STMTS) return false;
        const total = inlineBodyStmtCount(fd.body) orelse return false;
        if (total > MAX_INLINE_TOTAL_STMTS) return false;
        return true;
    }

    /// Faz GG.2'nin whole-program ÖN-geçişi — `computeMustNotRaise`DEN SONRA
    /// (bağımlılık, bkz. `isFuncInlineEligible`) VE herhangi bir gövde
    /// codegen'İNDEN ÖNCE (`prepareInlineSites`in `self.inlinable_funcs`e
    /// İHTİYACI VAR) çağrılmalıdır — `generateModule`de TEK bir çağrı sitesi.
    fn computeInlinableFunctions(self: *Codegen, module: ast.Module, extra_functions: []const ast.FuncDef, generic_template_names: []const []const u8) CodegenError!void {
        var info_map = try self.buildFuncSafetyInfoMap(module, extra_functions);
        try self.markRecursiveFuncs(&info_map);

        for (module.body) |stmt| {
            switch (stmt.kind) {
                .func_def => |fd| {
                    if (self.isFuncInlineEligible(fd, generic_template_names)) {
                        try self.inlinable_funcs.put(self.allocator, fd.name, fd);
                    }
                },
                else => {},
            }
        }
        for (extra_functions) |fd| {
            if (self.isFuncInlineEligible(fd, generic_template_names)) {
                try self.inlinable_funcs.put(self.allocator, fd.name, fd);
            }
        }
    }

    /// Faz GG.2: TEK bir keşfedilen inline-splice sitesi İçin caller'ın
    /// GİRİŞ BLOĞUNDA (QBE'nin "alloc yalnızca fonksiyon girişinde" kısıtına
    /// UYGUN — bkz. `collectLocals`in belge notu) callee'nin parametre+yerel+
    /// sonuç slotlarını `allocInlineSlot` İLE ÖN-TAHSİS eder VE `self.
    /// inline_sites`e (çağrı sitesi POINTER kimliğiyle) KAYDEDER. İÇ İÇE
    /// inlining YOK — `callee.body`, YENİDEN `collectInlineSitesStmts`DEN
    /// DEĞİL, DÜZ `collectLocals`DAN geçirilir (bu, işi SINIRLI/sonlu tutar).
    fn registerInlineSite(self: *Codegen, call_ptr: usize, callee: ast.FuncDef) CodegenError!void {
        if (self.inline_sites.contains(call_ptr)) return;

        var params: std.ArrayListUnmanaged(NamedSlot) = .empty;
        for (callee.params) |p| {
            const info = try self.resolveType(p.type_expr);
            try params.append(self.allocator, try self.allocInlineSlot(p.name, info, true));
        }

        var callee_locals: std.ArrayListUnmanaged(LocalDecl) = .empty;
        try self.collectLocals(&callee_locals, callee.body, false);
        var locals: std.ArrayListUnmanaged(NamedSlot) = .empty;
        for (callee_locals.items) |l| {
            try locals.append(self.allocator, try self.allocInlineSlot(l.name, l.info, l.is_param));
        }

        const ret_info = try self.resolveType(callee.return_type);
        const result: ?NamedSlot = if (ret_info.qtype == .none) null else try self.allocInlineSlot("__inline_result", ret_info, false);

        try self.inline_sites.put(self.allocator, call_ptr, .{
            .callee = callee,
            .params = try params.toOwnedSlice(self.allocator),
            .locals = try locals.toOwnedSlice(self.allocator),
            .result = result,
        });
    }

    /// Faz GG.2: caller gövdesini (KISITSIZ — `while`/`for`/`try`/vb.
    /// İÇEREBİLİR, YALNIZCA CALLEE kısıtlıdır) TARAYIP `.call` bulan
    /// özyinelemeli gezinti — `collectRaiseInfoStmt`in AYNI ağaç-gezinme
    /// deseni (bkz. onun belge notu), ama raise-izleme YERİNE inline-site
    /// KEŞFİ İçin. `.func_def` (iç içe closure) KASITLI olarak
    /// ATLANIR/özyinelenmez — o gövde KENDİ `genClosureFunc`i TARAFINDAN
    /// AYRICA taranır (bkz. `prepareInlineSites`in 5 çağrı sitesi).
    fn collectInlineSitesStmts(self: *Codegen, stmts: []const ast.Stmt) CodegenError!void {
        for (stmts) |stmt| try self.collectInlineSitesStmt(stmt);
    }

    fn collectInlineSitesStmt(self: *Codegen, stmt: ast.Stmt) CodegenError!void {
        switch (stmt.kind) {
            .expr_stmt => |e| try self.collectInlineSitesExpr(e),
            .var_decl => |v| try self.collectInlineSitesExpr(v.value),
            .assign => |a| {
                try self.collectInlineSitesExpr(a.target);
                try self.collectInlineSitesExpr(a.value);
            },
            .if_stmt => |f| {
                try self.collectInlineSitesExpr(f.cond);
                try self.collectInlineSitesStmts(f.then_body);
                for (f.elif_clauses) |ec| {
                    try self.collectInlineSitesExpr(ec.cond);
                    try self.collectInlineSitesStmts(ec.body);
                }
                if (f.else_body) |eb| try self.collectInlineSitesStmts(eb);
            },
            .while_stmt => |w| {
                try self.collectInlineSitesExpr(w.cond);
                try self.collectInlineSitesStmts(w.body);
            },
            .for_stmt => |f| {
                try self.collectInlineSitesExpr(f.iterable);
                try self.collectInlineSitesStmts(f.body);
            },
            .return_stmt => |r| if (r) |e| try self.collectInlineSitesExpr(e),
            .raise_stmt => |e| try self.collectInlineSitesExpr(e),
            .try_stmt => |t| {
                try self.collectInlineSitesStmts(t.try_body);
                for (t.except_clauses) |ec| try self.collectInlineSitesStmts(ec.body);
                if (t.finally_body) |fb| try self.collectInlineSitesStmts(fb);
            },
            .lowlevel_stmt => |ll| try self.collectInlineSitesStmts(ll.body),
            .with_stmt => |w| {
                try self.collectInlineSitesExpr(w.ctx_expr);
                try self.collectInlineSitesStmts(w.body);
            },
            .func_def, .class_def, .protocol_def, .extern_def, .pass_stmt, .import_stmt, .from_import_stmt => {},
        }
    }

    fn collectInlineSitesExpr(self: *Codegen, expr: ast.Expr) CodegenError!void {
        switch (expr) {
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
            .unary => |u| try self.collectInlineSitesExpr(u.operand.*),
            .binary => |b| {
                try self.collectInlineSitesExpr(b.left.*);
                try self.collectInlineSitesExpr(b.right.*);
            },
            .call => |c| {
                for (c.args) |a| try self.collectInlineSitesExpr(a);
                switch (c.callee.*) {
                    // Faz GG.2: `name` `self.vars`da (herhangi bir yerel/
                    // parametre/closure) VARSA bu çağrı ASLA inline
                    // edilemez — bu, `genCall`in KENDİ, DEĞİŞMEMİŞ closure-
                    // ÖNCELİK sırasıyla (bkz. onun `.identifier` dalı)
                    // ÇELİŞMEMEYİ garanti eden TEK, yeterli kontroldür.
                    .identifier => |name| {
                        if (!self.vars.contains(name)) {
                            if (self.inlinable_funcs.get(name)) |callee_fd| {
                                try self.registerInlineSite(@intFromPtr(c.callee), callee_fd);
                            }
                        }
                    },
                    .attribute => |att| try self.collectInlineSitesExpr(att.obj.*),
                    else => {},
                }
            },
            .attribute => |a| try self.collectInlineSitesExpr(a.obj.*),
            .index => |idx| {
                try self.collectInlineSitesExpr(idx.obj.*);
                try self.collectInlineSitesExpr(idx.index.*);
            },
            .list_lit => |elems| for (elems) |el| try self.collectInlineSitesExpr(el),
            .dict_lit => |pairs| for (pairs) |p| {
                try self.collectInlineSitesExpr(p.key);
                try self.collectInlineSitesExpr(p.value);
            },
            .await_expr => |op| try self.collectInlineSitesExpr(op.*),
            .spawn_expr => |op| try self.collectInlineSitesExpr(op.*),
            .generic_construct => |g| for (g.args) |a| try self.collectInlineSitesExpr(a),
        }
    }

    /// Faz GG.2: `genFunction`/`genMethod`/`genMain`/`genMainAsync`/
    /// `genClosureFunc`nin BEŞİNİN de KENDİ `allocSlot` döngüsünden HEMEN
    /// SONRA, `genStmts` ÇAĞRILMADAN ÖNCE çağırdığı TEK giriş noktası.
    fn prepareInlineSites(self: *Codegen, stmts: []const ast.Stmt) CodegenError!void {
        // **KRİTİK:** `self.inline_sites` HER üst-düzey gövde-üretim çağrısı
        // (bkz. bu fonksiyonun 5 çağrı sitesi) BAŞINDA TEMİZLENİR — GERÇEK
        // bir çöküşle KANITLANMIŞ bir hatanın düzeltmesi (bkz. break→red→fix
        // ritüeli): bir callee'nin (ör. `quadruple`) KENDİ gövdesi
        // İÇİNDEKİ çağrılar (ör. `double(double(x))`), `quadruple`nin
        // KENDİ `genFunction`ı SIRASINDA KAYDEDİLİP `$quadruple`nin
        // KENDİ QBE metnine `alloc8`'lenmiş slotlarla EŞLEŞTİRİLİR — bu
        // KAYITLAR SİLİNMEZSE VE `quadruple`nin KENDİSİ SONRADAN BAŞKA bir
        // çağrı sitesinde inline edilirse (bkz. `genInlinedCall`), o
        // splice'ın İÇİNDEKİ AYNI çağrı AST düğümleri `self.inline_sites`de
        // BULUNUR ama slotları ARTIK GEÇERSİZ bir QBE fonksiyonuna (`
        // $quadruple`ye) AİTTİR — `main`in İÇİNE splice edilirken BU
        // GEÇERSİZ slotlara `store`/`load` YAPILMASI tanımsız davranışa
        // (GERÇEKTEN gözlemlenen bir segfault) yol açar. Temizleme, "İÇ İÇE
        // inlining YOK" kuralını (bkz. `registerInlineSite`in belge notu)
        // DOĞRU biçimde ZORUNLU kılar: bir splice İÇİNDEKİ iç içe çağrılar
        // ARTIK `self.inline_sites`de HİÇ BULUNAMAZ (bu üst-düzey çağrının
        // KENDİ, TAZE kaydından), bu yüzden GÜVENLE GERÇEK bir `call`e
        // düşerler.
        self.inline_sites.clearRetainingCapacity();
        try self.collectInlineSitesStmts(stmts);
    }

    /// Faz GG.2: `prepareInlineSites`in ÖNCEDEN KAYDETTİĞİ bir splice
    /// sitesini ÜRETİR — GERÇEK bir `call` YERİNE `site.callee.body`yi
    /// caller'ın KENDİ QBE akışına SPLICE eder. QBE-seviyesi SSA geçicileri
    /// (`%tN`) zaten fonksiyon BOYUNCA benzersiz OLDUĞUNDAN (bkz.
    /// `self.temp_counter`) YENİDEN ADLANDIRMA GEREKMEZ — TEK hijyen adımı,
    /// callee'nin KAYNAK isimlerini `self.vars`a GEÇİCİ olarak GÖLGELEMEK
    /// (eski değeri KAYDEDİP splice SONRASI GERİ YÜKLEMEK). `isFuncInlineEligible`
    /// (`must_not_raise` şartı) bu splice SIRASINDA `emitExceptionCheck`in
    /// ASLA tetiklenemeyeceğini (dolayısıyla caller'ın ERKEN-çıkış yolunun,
    /// o an GÖLGELENMİŞ bir yerelin GÖRÜNMEZ kalıp SIZMASININ) YAPISAL
    /// olarak İMKANSIZ olmasını GARANTİ eder.
    fn genInlinedCall(self: *Codegen, c: ast.Call, site: InlineSiteInfo) CodegenError!Value {
        // 1) Argümanları NORMAL yoldakiyle AYNI şekilde değerlendirip
        // ÖN-TAHSİS EDİLMİŞ parametre slotlarına yaz. `arg_v0s` (dönüşümden
        // ÖNCEKİ, HAM `genExprForTarget` sonuçları) AŞAĞIDA `releaseTemporaryArgs`e
        // geçirilir — GERÇEK (inline OLMAYAN) çağrı yolunun `genCall`de
        // YAPTIĞI AYNI "ödünç alınan parametre slotuna yaz, splice
        // SONRASI TAZE argümanı ÇAĞIRAN serbest bırakır" dengesi BURADA da
        // KORUNMALIDIR — bu adım UNUTULURSA (İLK sürümde OLDUĞU GİBİ) HER
        // taze argüman (ör. `show(safe_div(...))`) KALICI olarak SIZAR
        // (GERÇEKTEN gözlemlendi, break→red→fix ritüeliyle doğrulanacak).
        const arg_v0s = try self.allocator.alloc(Value, site.params.len);
        for (site.params, 0..) |p, i| {
            const v0 = try self.genExprForTarget(c.args[i], p.info);
            try self.checkNoLowlevelEscape(v0);
            arg_v0s[i] = v0;
            const v = try self.convert(v0, p.info.qtype);
            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(p.info.qtype), v.text, p.slot });
        }

        // 2) callee'nin parametre+yerellerini `self.vars`a GÖLGELE (eski
        // değeri SAKLA).
        const owned_count = site.params.len + site.locals.len;
        const owned_names = try self.allocator.alloc([]const u8, owned_count);
        const saved = try self.allocator.alloc(?VarInfo, owned_count);
        var idx: usize = 0;
        for (site.params) |p| {
            owned_names[idx] = p.orig_name;
            saved[idx] = self.vars.get(p.orig_name);
            try self.vars.put(self.allocator, p.orig_name, .{
                .slot = p.slot,
                .qtype = p.info.qtype,
                .heap = p.info.heap,
                .elem_qtype = p.info.elem_qtype,
                .class_name = p.info.class_name,
                .elem_heap_info = p.info.elem_heap_info,
                .elem_is_str = p.info.elem_is_str,
                .dict_info = p.info.dict_info,
                .func_sig = p.info.func_sig,
                .is_param = true,
                .arena = false,
            });
            idx += 1;
        }
        for (site.locals) |l| {
            owned_names[idx] = l.orig_name;
            saved[idx] = self.vars.get(l.orig_name);
            try self.vars.put(self.allocator, l.orig_name, .{
                .slot = l.slot,
                .qtype = l.info.qtype,
                .heap = l.info.heap,
                .elem_qtype = l.info.elem_qtype,
                .class_name = l.info.class_name,
                .elem_heap_info = l.info.elem_heap_info,
                .elem_is_str = l.info.elem_is_str,
                .dict_info = l.info.dict_info,
                .func_sig = l.info.func_sig,
                .is_param = false,
                .arena = false,
            });
            idx += 1;
        }

        // 3) Dönüş bağlamını (`current_ret_info`) VE `inline_return_target`i
        // AYARLA (eski değerleri SAKLA).
        const saved_ret_info = self.current_ret_info;
        const saved_inline_target = self.inline_return_target;
        const callee_ret_info = try self.resolveType(site.callee.return_type);
        self.current_ret_info = callee_ret_info;
        const done_label = try self.newLabel("inline_done");
        self.inline_return_target = .{
            .result_slot = if (site.result) |r| r.slot else null,
            .done_label = done_label,
            .owned_names = owned_names,
        };

        // 4) Gövdeyi DEĞİŞTİRİLMEDEN üret — `.return_stmt` dalı `inline_
        // return_target`i GÖRÜP gerçek `ret` YERİNE `jmp done_label` üretir.
        try self.genStmts(site.callee.body, callee_ret_info.qtype);
        try self.out.writer.print("    jmp {s}\n", .{done_label});
        try self.out.writer.print("{s}\n", .{done_label});

        // 5) HER ŞEYİ geri yükle.
        self.current_ret_info = saved_ret_info;
        self.inline_return_target = saved_inline_target;
        for (owned_names, 0..) |name, i| {
            if (saved[i]) |old| {
                try self.vars.put(self.allocator, name, old);
            } else {
                _ = self.vars.remove(name);
            }
        }

        // 6) GERÇEK (inline OLMAYAN) çağrı yolunun `genCall`de YAPTIĞI AYNI
        // dengeleme: TAZE argümanlar (bkz. `isTemporaryExpr`/`always_fresh`)
        // splice BOYUNCA yalnızca ÖDÜNÇ ALINMIŞ bir parametre slotu OLARAK
        // ele alındığından (`is_param = true`, `.return_stmt`in `releaseNamedLocalsExcept`si
        // ASLA dokunmaz), sahiplikleri HÂLÂ ÇAĞIRANDADIR — BURADA serbest
        // bırakılır.
        try self.releaseTemporaryArgs(c.args, arg_v0s);

        // 7) Sonucu üret.
        if (site.result) |r| {
            const t = try self.newTemp();
            try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ t, qbeTypeName(r.info.qtype), qbeTypeName(r.info.qtype), r.slot });
            return .{
                .text = t,
                .qtype = r.info.qtype,
                .heap = r.info.heap,
                .elem_qtype = r.info.elem_qtype,
                .class_name = r.info.class_name,
                .elem_heap_info = r.info.elem_heap_info,
                .elem_is_str = r.info.elem_is_str,
                .dict_info = r.info.dict_info,
            };
        }
        return .{ .text = "0", .qtype = .w };
    }

    fn genCall(self: *Codegen, c: ast.Call) CodegenError!Value {
        switch (c.callee.*) {
            .identifier => |name| {
                if (std.mem.eql(u8, name, "print")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const v = try self.genExpr(c.args[0]);
                    try self.genPrint(v);
                    // `v` TAZE bir liste/sınıf olabilir (ör. `print(Point(1,2))`,
                    // `print([1, 2, 3])`) — artık `print` bunları BASABİLDİĞİNDEN
                    // (bkz. görev "print(list)/print(class)"), tamamen
                    // dolaylanmış diğer heap değerlerle (bkz. `expr_stmt`,
                    // `releaseIfTemporary`) AYNI şekilde sızmaması gerekir.
                    try self.releaseIfTemporary(c.args[0], v);
                    return .{ .text = "0", .qtype = .w };
                }
                // `len(s) -> int` — stdlib fazı §B (bkz. checker.zig'deki
                // eşdeğer not). Libc'nin `strlen`ine (zaten `cc` bağlantısında
                // mevcut) doğrudan bir çağrıya lowerlanır — `str` her zaman
                // sıfırla-sonlanan bir C dizesi olduğundan (bkz. modül üstü
                // not) dönüşüm gerekmez.
                if (std.mem.eql(u8, name, "len")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const v = try self.genExpr(c.args[0]);
                    const result_t = try self.newTemp();
                    // Stdlib fazı §L: `list[T]` dalı — `genListLit`in AYNI
                    // bayt düzeni (8 bayt uzunluk başlığı, ofset 0) DOĞRUDAN
                    // okunur (`nox.json`nin `array_len`/`object_len`si İÇİN
                    // eklendi — GENEL bir yerleşik, JSON'a özgü DEĞİL).
                    if (v.heap == .list) {
                        try self.out.writer.print("    {s} =l loadl {s}\n", .{ result_t, v.text });
                    } else {
                        try self.out.writer.print("    {s} =l call $strlen(l {s})\n", .{ result_t, v.text });
                    }
                    try self.releaseIfTemporary(c.args[0], v);
                    return .{ .text = result_t, .qtype = .l };
                }
                // `str(x)` — stdlib fazı §E (bkz. checker.zig'deki eşdeğer
                // not). `x`in qtype'ına göre (checker `int`/`float`e
                // ZATEN sınırladı) doğru runtime dönüştürücüsüne
                // lowerlanır — İKİSİ de HER ZAMAN başarılıdır (bkz.
                // runtime/str.zig'in belge notu), istisna kontrolü GEREKMEZ.
                if (std.mem.eql(u8, name, "str")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const v = try self.genExpr(c.args[0]);
                    const result_t = try self.newTemp();
                    if (v.qtype == .d) {
                        try self.out.writer.print("    {s} =l call $nox_float_to_str(l {s}, d {s})\n", .{ result_t, RT_PARAM, v.text });
                    } else {
                        try self.out.writer.print("    {s} =l call $nox_int_to_str(l {s}, l {s})\n", .{ result_t, RT_PARAM, v.text });
                    }
                    return .{ .text = result_t, .qtype = .l, .heap = .str };
                }
                // `int(s)`/`float(s)` — stdlib fazı §E. Ayrıştırma
                // BAŞARISIZSA bir `ValueError` `raise` eder (bkz.
                // `genParseOrRaise`in belge notu).
                if (std.mem.eql(u8, name, "int")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const v = try self.genExpr(c.args[0]);
                    const result = try self.genParseOrRaise(v, "nox_str_is_valid_int", "nox_str_to_int", .l, "int(): gecersiz sayi bicimi");
                    try self.releaseIfTemporary(c.args[0], v);
                    return result;
                }
                if (std.mem.eql(u8, name, "float")) {
                    if (c.args.len != 1) return error.Unsupported;
                    const v = try self.genExpr(c.args[0]);
                    const result = try self.genParseOrRaise(v, "nox_str_is_valid_float", "nox_str_to_float", .d, "float(): gecersiz sayi bicimi");
                    try self.releaseIfTemporary(c.args[0], v);
                    return result;
                }
                // Faz 14: `hpy_call`/`wasm_call` — bkz. checker.zig'deki
                // eşdeğer not. Runtime'ın `nox_hpy_call`/`nox_wasm_call`sine
                // (bkz. runtime/foreign_bridge.zig) doğrudan çağrıya çevrilir;
                // `str` argümanları zaten sıfırla-sonlanan verilere işaret
                // eden düz `l` işaretçileridir (bkz. modül üstü not, "str
                // neden hep tahsissiz") — hiçbir dönüşüm gerekmez.
                if (std.mem.eql(u8, name, "hpy_call")) {
                    if (c.args.len != 4) return error.Unsupported;
                    const path_v = try self.genExpr(c.args[0]);
                    const ext_v = try self.genExpr(c.args[1]);
                    const func_v = try self.genExpr(c.args[2]);
                    const arg_v = try self.genExpr(c.args[3]);
                    const result_temp = try self.newTemp();
                    try self.out.writer.print("    {s} =l call $nox_hpy_call(l {s}, l {s}, l {s}, l {s}, l {s})\n", .{ result_temp, RT_PARAM, path_v.text, ext_v.text, func_v.text, arg_v.text });
                    return .{ .text = result_temp, .qtype = .l };
                }
                if (std.mem.eql(u8, name, "wasm_call")) {
                    if (c.args.len != 3) return error.Unsupported;
                    const path_v = try self.genExpr(c.args[0]);
                    const func_v = try self.genExpr(c.args[1]);
                    const arg_v = try self.genExpr(c.args[2]);
                    const result_temp = try self.newTemp();
                    try self.out.writer.print("    {s} =l call $nox_wasm_call(l {s}, l {s}, l {s}, l {s})\n", .{ result_temp, RT_PARAM, path_v.text, func_v.text, arg_v.text });
                    return .{ .text = result_temp, .qtype = .l };
                }

                if (self.classes.get(name)) |cinfo| return self.genConstruct(name, cinfo, c.args);

                // `extern def` — Nox'un runtime çağrılarıyla (`RT_PARAM`) VE
                // istisna yayılımıyla (`emitExceptionCheck`) HİÇ ilgisi
                // olmayan, doğrudan bir C ABI çağrısı (bkz. nox-teknik-
                // spesifikasyon.md §3.20). `str` argümanları/dönüşü zaten
                // sıfırla-sonlanan ham işaretçiler olduğundan dönüşüm
                // gerekmez (`hpy_call`/`wasm_call` ile AYNI ücretsiz tasarım).
                if (self.extern_functions.get(name)) |esig| {
                    if (esig.params.len != c.args.len) return error.Unsupported;
                    const arg_values = try self.allocator.alloc(Value, c.args.len);
                    for (c.args, 0..) |a, i| {
                        const v0 = try self.genExpr(a);
                        try self.checkNoLowlevelEscape(v0);
                        arg_values[i] = try self.convert(v0, esig.params[i].qtype);
                    }
                    const result_temp: ?[]const u8 = if (esig.ret.qtype == .none) null else try self.newTemp();
                    if (result_temp) |rt| {
                        try self.out.writer.print("    {s} ={s} call ${s}(", .{ rt, qbeTypeName(esig.ret.qtype), name });
                    } else {
                        try self.out.writer.print("    call ${s}(", .{name});
                    }
                    // `with_rt` (bkz. `ast.ExternDef.needs_rt`in belge notu,
                    // stdlib fazı §D.1): `RT_PARAM` GİZLİCE argüman
                    // listesinin BAŞINA eklenir (normal fonksiyon
                    // çağrılarıyla AYNI kalıp) — Zig tarafının İLK parametresi
                    // `rt: ?*anyopaque` olmalıdır.
                    var wrote_arg = false;
                    if (esig.needs_rt) {
                        try self.out.writer.print("l {s}", .{RT_PARAM});
                        wrote_arg = true;
                    }
                    for (arg_values) |v| {
                        if (wrote_arg) try self.out.writer.writeAll(", ");
                        try self.out.writer.print("{s} {s}", .{ qbeTypeName(v.qtype), v.text });
                        wrote_arg = true;
                    }
                    try self.out.writer.writeAll(")\n");
                    // Stdlib fazı §F: `elem_qtype`/`elem_heap_info`/
                    // `elem_is_str` ÖNCEDEN eksikti (yalnızca `qtype`/`heap`
                    // kopyalanıyordu) — D.1.5'in `genFieldRead`de bulunan
                    // `dict_info` eksikliğiyle AYNI KATEGORİDE bir hataydı.
                    // `list[str]` DÖNÜŞ tipi FFI-güvenli sayılınca (bkz.
                    // `isFfiSafeListReturnType`) bu eksiklik GERÇEK bir
                    // çökmeye yol açardı (dönen listenin elemanları `str`
                    // olarak İŞARETLENMEDEN indekslenir/serbest bırakılırdı).
                    // Stdlib fazı §L: `class_name` ÖNCEDEN eksikti (bkz.
                    // yukarıdaki `elem_qtype`/`elem_heap_info`/`elem_is_str`
                    // notu, Alt-Faz F — AYNI KATEGORİDE bir hata). `JsonValue`
                    // DÖNEN bir extern def (`isFfiSafeClassReturnType`)
                    // olmadan ÖNCE HİÇBİR extern def sınıf DÖNDÜRMEDİĞİNDEN
                    // bu eksiklik fark edilmemişti — `class_name` OLMADAN
                    // sonraki `.attribute` okumaları/`genClassRelease`
                    // `self.classes.get(obj.class_name.?)`de ÇÖKERDİ.
                    // Faz FF.3: AYNI KATEGORİDE bir ÜÇÜNCÜ eksiklik — `dict_info`
                    // — `dict[K,V]` DÖNEN bir extern def'in SONUCU BURADAN
                    // GEÇTİĞİNDE (ör. `nox_http_response_headers`) EKSİKTİ;
                    // `dict`in Faz FF.3'ten ÖNCE `isHeapManaged`in DIŞINDA
                    // olması (release YOLU HİÇ TETİKLENMEMESİ) bunu
                    // MASKELİYORDU — `dict` ARTIK TAM ARC'lı OLDUĞUNDAN
                    // `dict_info` OLMADAN `releaseValueIfSet`in `.dict` dalı
                    // `dict_info.?` üzerinde ÇÖKER (bkz. `http_serve_golden_
                    // test.zig`nin bu YOLU KANITLAYAN çökme testi).
                    if (result_temp) |rt| return .{ .text = rt, .qtype = esig.ret.qtype, .heap = esig.ret.heap, .class_name = esig.ret.class_name, .elem_qtype = esig.ret.elem_qtype, .elem_heap_info = esig.ret.elem_heap_info, .elem_is_str = esig.ret.elem_is_str, .dict_info = esig.ret.dict_info };
                    return .{ .text = "0", .qtype = .w };
                }

                // Faz U.4.4: `name` bir SIRADAN fonksiyon/sınıf/extern def
                // DEĞİL, çıplak bir İSİMDEN bağlanan (yerel değişken/
                // parametre — bkz. `checker.zig`nin AYNI dala karşılık gelen
                // `checkCall`in `.identifier` dalı) func-tipli bir DEĞER İSE
                // bu DOLAYLI çağrıdır: hedef fonksiyon işaretçisi (`fn_ptr`,
                // offset 0) STATİK olarak bilinmez, closure DEĞERİNİN
                // KENDİSİNDEN çalışma zamanında YÜKLENİR (bkz. `HeapKind.
                // closure`in belge notu, "kendi kendine yeten TEK işaretçi").
                // Argüman/dönüş tipleri İSE STATİK olarak bilinir —
                // `resolveType`in `.func_type` dalının önceden hesapladığı
                // `func_sig`den (bkz. `FuncSigInfo`in belge notu).
                if (self.vars.get(name)) |info| {
                    if (info.heap == .closure) {
                        const fsig = info.func_sig orelse return error.Unsupported;
                        if (fsig.params.len != c.args.len) return error.Unsupported;

                        const closure_ptr = try self.newTemp();
                        try self.out.writer.print("    {s} =l loadl {s}\n", .{ closure_ptr, info.slot });
                        const fn_ptr = try self.newTemp();
                        try self.out.writer.print("    {s} =l loadl {s}\n", .{ fn_ptr, closure_ptr });

                        const arg_values = try self.allocator.alloc(Value, c.args.len);
                        for (c.args, 0..) |a, i| {
                            const v0 = try self.genExprForTarget(a, fsig.params[i]);
                            try self.checkNoLowlevelEscape(v0);
                            arg_values[i] = try self.convert(v0, fsig.params[i].qtype);
                        }

                        const ret_qtype = fsig.ret.qtype;
                        const result_temp: ?[]const u8 = if (ret_qtype == .none) null else try self.newTemp();
                        if (result_temp) |rt| {
                            try self.out.writer.print("    {s} ={s} call {s}(l {s}, l {s}", .{ rt, qbeTypeName(ret_qtype), fn_ptr, RT_PARAM, closure_ptr });
                        } else {
                            try self.out.writer.print("    call {s}(l {s}, l {s}", .{ fn_ptr, RT_PARAM, closure_ptr });
                        }
                        for (arg_values) |v| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(v.qtype), v.text });
                        try self.out.writer.writeAll(")\n");
                        // Dolaylı çağrının HEDEFİ (çağrılan SOMUT closure)
                        // derleme zamanında bilinmediğinden `must_not_raise`
                        // eleme optimizasyonu (bkz. normal fonksiyon çağrısı
                        // dalı) burada UYGULANAMAZ — İSTİSNA kontrolü HER
                        // ZAMAN yapılır (güvenli varsayılan).
                        try self.emitExceptionCheck();
                        try self.releaseTemporaryArgs(c.args, arg_values);

                        if (result_temp) |rt| {
                            return .{ .text = rt, .qtype = ret_qtype, .heap = fsig.ret.heap, .elem_qtype = fsig.ret.elem_qtype, .class_name = fsig.ret.class_name, .elem_heap_info = fsig.ret.elem_heap_info, .elem_is_str = fsig.ret.elem_is_str };
                        }
                        return .{ .text = "0", .qtype = .w };
                    }
                }

                // Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): bu ÇAĞRI
                // SİTESİ (`prepareInlineSites` TARAFINDAN ÖNCEDEN, `ast.Call.
                // callee` POINTER kimliğiyle) inline-edilebilir bulunduysa,
                // GERÇEK bir `call`in YERİNE callee'nin gövdesi BURAYA splice
                // edilir — bkz. `genInlinedCall`in belge notu.
                if (self.inline_sites.get(@intFromPtr(c.callee))) |site| {
                    return self.genInlinedCall(c, site);
                }

                const sig = self.functions.get(name) orelse return error.Unsupported;
                if (sig.params.len != c.args.len) return error.Unsupported;

                const arg_values = try self.allocator.alloc(Value, c.args.len);
                for (c.args, 0..) |a, i| {
                    const v0 = try self.genExprForTarget(a, sig.params[i]);
                    try self.checkNoLowlevelEscape(v0);
                    arg_values[i] = try self.convert(v0, sig.params[i].qtype);
                }

                const result_temp: ?[]const u8 = if (sig.ret.qtype == .none) null else try self.newTemp();
                if (result_temp) |rt| {
                    try self.out.writer.print("    {s} ={s} call ${s}(l {s}", .{ rt, qbeTypeName(sig.ret.qtype), name, RT_PARAM });
                } else {
                    try self.out.writer.print("    call ${s}(l {s}", .{ name, RT_PARAM });
                }
                for (arg_values) |v| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(v.qtype), v.text });
                try self.out.writer.writeAll(")\n");
                // Performans fazı: `name`in ASLA istisna fırlatamayacağı
                // KANITLANDIYSA (bkz. `self.must_not_raise`, `computeMustNotRaise`)
                // kontrolü ATLA.
                if (!self.must_not_raise.contains(name)) try self.emitExceptionCheck();
                try self.releaseTemporaryArgs(c.args, arg_values);

                if (result_temp) |rt| {
                    return .{ .text = rt, .qtype = sig.ret.qtype, .heap = sig.ret.heap, .elem_qtype = sig.ret.elem_qtype, .class_name = sig.ret.class_name, .elem_heap_info = sig.ret.elem_heap_info, .elem_is_str = sig.ret.elem_is_str };
                }
                return .{ .text = "0", .qtype = .w };
            },
            .attribute => |a| {
                // stdlib fazı §D.1.6: `nox.http.serve(...)`nin callee'si
                // checker tarafından mangled bir isme YENİDEN YAZILMAZ (bkz.
                // `isHttpServeCallee`in belge notu), bu yüzden burada, sıradan
                // metod-çağrısı çözümlemesinden (`genMethodCall`) ÖNCE ŞEKLİ
                // tanımak GEREKİR.
                if (isHttpServeCallee(c.callee.*)) return self.genHttpServe(c);
                // Faz DD.1: `serve_fd`/`serve_multicore` — AYNI gerekçe,
                // `isHttpServeCallee`in HEMEN yanına eklendi.
                if (isHttpServeFdCallee(c.callee.*)) return self.genHttpServeFd(c);
                if (isHttpServeMulticoreCallee(c.callee.*)) return self.genHttpServeMulticore(c);
                // Faz BB.4: `nox.thread.start(entry, arg)`nin callee'si de
                // (checker BUNU YENİDEN yazmadığı için — bkz. `tryResolveThreadSpawnCall`)
                // burada AYNI şekilde tanınmalı.
                if (isThreadStartCallee(c.callee.*)) return self.genThreadStartExpr(c);
                return self.genMethodCall(a, c.args);
            },
            else => return error.Unsupported,
        }
    }

    /// `int(s)`/`float(s)` — stdlib fazı §E: `valid_fn(s) -> w` ÖNCE
    /// çağrılır; geçersizse bir `ValueError` inşa edilip `raise` edilir
    /// (`emitExceptionCheck` DEVREYE girer — bkz. `genRaise`in AYNI
    /// deseni); geçerliyse `convert_fn(s) -> result_qtype` gerçek
    /// dönüşümü yapar. `genEqCompareOrJump`in belge notuyla AYNI gerekçeyle
    /// QBE'nin `phi`sinden BİLİNÇLİ olarak KAÇINILIR: hata dalı `nox_raise`
    /// ÇAĞIRDIKTAN SONRA (bu koşulsuz olarak istisnayı BEKLEYEN bir dal
    /// olduğundan `emitExceptionCheck`in `exc_continue` etiketi PRATİKTE
    /// asla erişilmez) doğrudan `ok_label`e ATLAR — TEK bir SSA değeri
    /// (`result`), YALNIZCA `ok_label` İÇİNDE, hangi kenardan gelinirse
    /// gelinsin YENİDEN hesaplanır (iki farklı DEĞERİ birleştirmek YERİNE
    /// "buraya vardıysan şunu hesapla" deseni — bkz. `genEqCompareOrJump`in
    /// belge notu, aynı yığın-taşması endişesi burada da geçerli olmasa
    /// bile TUTARLILIK için AYNI desen tercih edildi).
    fn genParseOrRaise(self: *Codegen, v: Value, valid_fn: []const u8, convert_fn: []const u8, result_qtype: QbeType, message: []const u8) CodegenError!Value {
        const valid_t = try self.newTemp();
        try self.out.writer.print("    {s} =w call ${s}(l {s})\n", .{ valid_t, valid_fn, v.text });
        const err_label = try self.newLabel("parse_err");
        const ok_label = try self.newLabel("parse_ok");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ valid_t, ok_label, err_label });
        try self.out.writer.print("{s}\n", .{err_label});

        const msg_value = try self.emitStringLiteral(message);
        const ve_cinfo = self.classes.get("ValueError") orelse return error.Unsupported;
        const ve_obj = try self.genConstructFromValues("ValueError", ve_cinfo, &.{msg_value});
        try self.out.writer.print("    call $nox_raise(l {s}, l {s})\n", .{ RT_PARAM, ve_obj.text });
        try self.emitExceptionCheck();
        try self.out.writer.print("    jmp {s}\n", .{ok_label});

        try self.out.writer.print("{s}\n", .{ok_label});
        const result_t = try self.newTemp();
        try self.out.writer.print("    {s} ={s} call ${s}(l {s})\n", .{ result_t, qbeTypeName(result_qtype), convert_fn, v.text });
        return .{ .text = result_t, .qtype = result_qtype };
    }

    /// Bir çağrının (fonksiyon/metod/kurucu) argümanları arasındaki TAZE
    /// (henüz hiçbir isme bağlanmamış — yalnızca `.call`/`.list_lit`
    /// ifadelerinden gelen) heap değerlerini çağrı DÖNDÜKTEN SONRA serbest
    /// bırakır.
    ///
    /// Neden gerekli: bir argümanı geçirmek yalnızca bir "ödünç"tür (refcount
    /// etkilenmez, bkz. modül üstü not) — ama çağrılan taraf (Faz 9'dan beri)
    /// parametreyi bir sınıf ALANINA (`self.attr = param`) ya da yeni bir
    /// yerel değişkene (`q = param`) atayarak KALICI hale getirebilir; bu
    /// durumda `retainIfAliasing` parametreyi retain eder (çağrı sınırında
    /// hiçbir şey bunu telafi etmez). Çağıran taraf, argümanın ORİJİNAL
    /// ifadesinin bir isim mi (kendi releaser'ı zaten var — `.identifier`/
    /// `.attribute`/`.index`, dokunulmaz) yoksa TAZE bir değer mi (`.call`/
    /// `.list_lit`, hiçbir releaser'ı yok) olduğunu bilen tek taraftır — bu
    /// yüzden dengeleme sorumluluğu burada, çağrı noktasındadır: çağrılan
    /// taraf değeri kalıcı hale getirdiyse refcount 2'ye çıkmıştır, bu release
    /// onu doğru şekilde 1'e (tek kalıcı sahip) indirir; getirmediyse
    /// (yalnızca okuduysa) refcount zaten 1'dir, bu release onu 0'a indirip
    /// gerçekten serbest bırakır — iki durumda da doğru.
    fn releaseTemporaryArgs(self: *Codegen, exprs: []const ast.Expr, values: []const Value) CodegenError!void {
        for (exprs, 0..) |e, i| {
            const v = values[i];
            // `v.always_fresh` (bkz. `Value`nin belge notu, stdlib fazı §G):
            // `s[i]` HER ZAMAN serbest bırakılmalıdır — AST-tabanlı
            // `isTemporaryExpr` sezgisi burada GEÇERSİZDİR.
            if (isHeapManaged(v.heap) and (v.always_fresh or isTemporaryExpr(e))) {
                try self.releaseValueIfSet(v.text, v.heap, v.elem_qtype, v.class_name, v.elem_heap_info, v.dict_info);
            }
        }
    }

    /// `releaseTemporaryArgs` ile aynı gerekçe, tek bir değer için — bir metod
    /// çağrısının ALICISI (ör. `Engine(1).some_method()`), bir alan
    /// okumasının/indekslemenin TABANI (ör. `make_car(i).engine`,
    /// `make_list()[0]`) da aynı şekilde taze bir geçici olabilir.
    fn releaseIfTemporary(self: *Codegen, e: ast.Expr, v: Value) CodegenError!void {
        // Bkz. `releaseTemporaryArgs`in AYNI notu (`v.always_fresh`).
        if (isHeapManaged(v.heap) and (v.always_fresh or isTemporaryExpr(e))) {
            try self.releaseValueIfSet(v.text, v.heap, v.elem_qtype, v.class_name, v.elem_heap_info, v.dict_info);
        }
    }

    /// İçinde bulunulan en yakın `lowlevel` bloğunun arena işaretçisi (varsa).
    fn currentArena(self: *Codegen) ?[]const u8 {
        if (self.arena_stack.items.len == 0) return null;
        return self.arena_stack.items[self.arena_stack.items.len - 1];
    }

    fn genConstruct(self: *Codegen, class_name: []const u8, cinfo: ClassInfo, args: []const ast.Expr) CodegenError!Value {
        if (cinfo.init_params.len != args.len) return error.Unsupported;
        const arg_values = try self.allocator.alloc(Value, args.len);
        for (args, 0..) |a, i| {
            const v0 = try self.genExprForTarget(a, cinfo.init_params[i]);
            try self.checkNoLowlevelEscape(v0);
            arg_values[i] = try self.convert(v0, cinfo.init_params[i].qtype);
        }
        const result = try self.genConstructFromValues(class_name, cinfo, arg_values);
        try self.releaseTemporaryArgs(args, arg_values);
        return result;
    }

    /// `genConstruct`ın AST-BAĞIMSIZ çekirdeği — stdlib fazı §D.1.6'nın
    /// `nox.http.serve` sarmalayıcısı (bkz. `genHttpServeWrapper`), bir
    /// `HttpRequest` örneğini kaynak-düzeyi `ast.Expr` argümanlarından DEĞİL,
    /// zaten HESAPLANMIŞ `Value`lerden (extern erişimci çağrılarının
    /// sonuçlarından) inşa etmesi GEREKTİĞİNDEN bu ayrım gerekli — çağıran
    /// TARAF, `arg_values`in serbest bırakılması/geçici argüman temizliği
    /// GEREKİP GEREKMEDİĞİNİ kendisi bilir (bkz. `genConstruct`ın
    /// `releaseTemporaryArgs` çağrısı — bu YARDIMCI onu YAPMAZ).
    fn genConstructFromValues(self: *Codegen, class_name: []const u8, cinfo: ClassInfo, arg_values: []const Value) CodegenError!Value {
        if (cinfo.init_params.len != arg_values.len) return error.Unsupported;
        const t = try self.newTemp();
        const arena = self.currentArena();
        if (arena) |ap| {
            try self.out.writer.print("    {s} =l call $nox_arena_alloc(l {s}, l {d})\n", .{ t, ap, cinfo.total_size });
        } else {
            try self.out.writer.print("    {s} =l call $nox_rc_alloc(l {s}, l {d})\n", .{ t, RT_PARAM, cinfo.total_size });
        }
        try self.out.writer.print("    storel {d}, {s}\n", .{ cinfo.class_id, t });
        // Alanlar `__init__` çalışmadan ÖNCE sıfırlanır: bu sayede sınıf tipli
        // bir alana ilk kez yazarken `genAssign`'in "önce eskiyi serbest
        // bırak" mantığı (bkz. `.attribute` durumu) çöp bir işaretçiyi asla
        // release etmeye çalışmaz — tahsis edilmiş bellek sıfırla
        // doldurulmuş SAYILAMAZ (bkz. runtime/alloc/asap.zig, DebugAllocator).
        for (cinfo.fields.items) |f| {
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, t, f.offset });
            try self.out.writer.print("    storel 0, {s}\n", .{addr});
        }
        // `has_init == false`: sınıfın hiç `__init__`i yok (bkz.
        // `ClassInfo.has_init`in belge notu) — `generateModule` bu sınıf için
        // `$ClassName___init__`i HİÇ ÜRETMEDİ, bu yüzden burada çağırmak
        // bağlantı zamanında çözülemeyen bir sembole yol açardı.
        if (cinfo.has_init) {
            try self.out.writer.print("    call ${s}_{s}(l {s}, l {s}", .{ class_name, "__init__", RT_PARAM, t });
            for (arg_values) |v| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(v.qtype), v.text });
            try self.out.writer.writeAll(")\n");
            // Performans fazı: `__init__`in ASLA istisna fırlatamayacağı
            // KANITLANDIYSA (bkz. `ClassInfo.init_is_safe`, `computeMustNotRaise`)
            // kontrolü ATLA.
            if (!cinfo.init_is_safe) try self.emitExceptionCheck();
        }
        return .{ .text = t, .qtype = .l, .heap = .class, .class_name = class_name, .arena = arena != null };
    }

    fn genMethodCall(self: *Codegen, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
        const obj = try self.genExpr(a.obj.*);
        if (obj.heap == .dict) return self.genDictMethod(obj, a, args);
        if (obj.heap == .list) {
            // Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61): checker
            // ZATEN `a.attr`in `append`/`sort`den biri OLDUĞUNU doğruladı
            // (bkz. checker.zig'in `.list` dalı) — codegen İSİM üzerinden
            // dispatch eder (`genListAppend`nin KENDİSİ isim KONTROLÜ
            // YAPMAZ, `args.len`e göre AYRIM yapardı — `sort`nin 0 argümanı
            // `append`nin "tam olarak 1 argüman" KONTROLÜNE takılırdı).
            if (std.mem.eql(u8, a.attr, "sort")) return self.genListSort(obj, a, args);
            return self.genListAppend(obj, a, args);
        }
        if (obj.heap != .class) return error.Unsupported;
        try self.checkNoLowlevelEscape(obj);
        const cinfo = self.classes.get(obj.class_name.?).?;
        const msig = cinfo.methods.get(a.attr) orelse return error.Unsupported;
        if (msig.params.len != args.len) return error.Unsupported;

        const arg_values = try self.allocator.alloc(Value, args.len);
        for (args, 0..) |arg, i| {
            const v0 = try self.genExprForTarget(arg, msig.params[i]);
            try self.checkNoLowlevelEscape(v0);
            arg_values[i] = try self.convert(v0, msig.params[i].qtype);
        }

        const result_temp: ?[]const u8 = if (msig.ret.qtype == .none) null else try self.newTemp();
        if (result_temp) |rt| {
            try self.out.writer.print("    {s} ={s} call ${s}_{s}(l {s}, l {s}", .{ rt, qbeTypeName(msig.ret.qtype), obj.class_name.?, a.attr, RT_PARAM, obj.text });
        } else {
            try self.out.writer.print("    call ${s}_{s}(l {s}, l {s}", .{ obj.class_name.?, a.attr, RT_PARAM, obj.text });
        }
        for (arg_values) |v| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(v.qtype), v.text });
        try self.out.writer.writeAll(")\n");
        // Faz M.8 (yeniden ele alındı, bkz. nox-teknik-spesifikasyon.md
        // §3.59): `computeMustNotRaise` ARTIK TÜM metodları (yalnızca
        // `__init__` değil) analiz ediyor — hedef metod bu kümedeyse
        // (sembol formatı `genCall`in serbest-fonksiyon dalıyla TUTARLI,
        // bkz. `computeMustNotRaise`in belge notu) kontrol atlanabilir.
        const method_sym = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ obj.class_name.?, a.attr });
        if (!self.must_not_raise.contains(method_sym)) try self.emitExceptionCheck();
        try self.releaseIfTemporary(a.obj.*, obj);
        try self.releaseTemporaryArgs(args, arg_values);

        if (result_temp) |rt| {
            return .{ .text = rt, .qtype = msig.ret.qtype, .heap = msig.ret.heap, .elem_qtype = msig.ret.elem_qtype, .class_name = msig.ret.class_name, .elem_heap_info = msig.ret.elem_heap_info, .elem_is_str = msig.ret.elem_is_str };
        }
        return .{ .text = "0", .qtype = .w };
    }

    /// `d.contains(key)`/`d.len()` — `Channel.send/recv` İLE AYNI desen
    /// (bir kullanıcı sınıfı DEĞİL, burada özel işlenir — bkz. checker.zig'in
    /// eşdeğer notu).
    fn genDictMethod(self: *Codegen, obj: Value, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
        const dinfo = obj.dict_info.?;
        if (std.mem.eql(u8, a.attr, "contains")) {
            if (args.len != 1) return error.Unsupported;
            const key_v0 = try self.genExpr(args[0]);
            try self.checkNoLowlevelEscape(key_v0);
            const key_payload = try self.toPayload(key_v0);
            const key_is_str_lit: []const u8 = if (dinfo.key_is_str) "1" else "0";
            const result = try self.newTemp();
            try self.out.writer.print("    {s} =w call $nox_dict_contains(l {s}, w {s}, l {s})\n", .{ result, obj.text, key_is_str_lit, key_payload.text });
            try self.releaseIfTemporary(args[0], key_v0);
            try self.releaseIfTemporary(a.obj.*, obj);
            return .{ .text = result, .qtype = .w };
        }
        if (std.mem.eql(u8, a.attr, "len")) {
            if (args.len != 0) return error.Unsupported;
            const result = try self.newTemp();
            try self.out.writer.print("    {s} =l call $nox_dict_len(l {s})\n", .{ result, obj.text });
            try self.releaseIfTemporary(a.obj.*, obj);
            return .{ .text = result, .qtype = .l };
        }
        return error.Unsupported;
    }

    /// `xs.append(v)` — Faz U.1, GERÇEK paylaşım semantikli büyüme (bkz.
    /// nox-teknik-spesifikasyon.md §3.20'nin AYRINTILI notu — kullanıcıyla
    /// netleşen karar). İKİ yol:
    ///   - **Hızlı yol** (`len < cap`): YENİ eleman `obj.text`in KENDİ
    ///     bloğuna, YERİNDE yazılır, `len` ARTIRILIR — bloğun ADRESİ HİÇ
    ///     DEĞİŞMEZ, bu yüzden AYNI listeye başka bir isimden (`ys = xs`)
    ///     bakan HERHANGİ bir alias bu değişikliği ANINDA GÖRÜR (gerçek
    ///     paylaşım).
    ///   - **Büyüme yolu** (`len == cap`): `nox_list_grow` (bkz. `arc.zig`)
    ///     YENİ (kapasitesi ikiye katlanmış — `cap == 0` İSE `1`) bir blok
    ///     ayırıp ESKİ içeriği KOPYALAR; YENİ eleman ORAYA yazılır; ESKİ
    ///     blok (elemanları TAŞINDIĞINDAN — AYNI işaretçi DEĞERLERİ, refcount
    ///     DEĞİŞMEDEN — özyinelemeli release EDİLMEDEN, yalnızca KENDİ ham
    ///     belleği) `nox_rc_predecrement`+`nox_rc_free_payload` ile serbest
    ///     bırakılır; YENİ işaretçi ALICININ KENDİ SLOTUNA geri yazılır.
    ///     **Bilinçli v1 sınırlaması (KABUL EDİLDİ):** bu ANDA listenin
    ///     BAŞKA bir alias'ı (`ys = xs`) VARSA, O alias ESKİ (artık daha
    ///     KISA/serbest bırakılmış) bloğu GÖRMEYE devam eder — `xs`in KENDİ
    ///     slotu güncellenir ama `ys`in DEĞİL (Nox'un işaretçi-DEĞERİ-
    ///     tutan, TEK dolaylama SEVİYELİ ARC temsilinin doğal bir sonucu —
    ///     TAM düzeltme bir "handle" [çift dolaylama] yeniden tasarımı
    ///     gerektirir, v1 kapsamı DIŞINDA).
    ///
    /// **Bilinçli v1 sınırlaması — alıcı BİR PARAMETRE OLAMAZ:** bir
    /// parametre ÖDÜNÇ alınmıştır (refcount'u ETKİLENMEDEN geçirilir, bkz.
    /// modül üstü not) — büyüme yolu ESKİ bloğu predecrement/free ETTİĞİNDEN,
    /// bu, callee'nin SAHİP OLMADIĞI bir referansı YANLIŞLIKLA serbest
    /// bırakmasına (ÇAĞIRANIN hâlâ geçerli saydığı belleği bozmasına) yol
    /// AÇARDI — checker BUNU AYIRT EDEMEDİĞİNDEN (parametre/yerel ayrımı
    /// tip düzeyinde YOK), codegen `var_info.is_param` İSE `error.Unsupported`
    /// döner (`checkNoLowlevelEscape`in "geniş kural, codegen seviyesinde
    /// uygulanır" ÖNCEDEN kabul edilmiş desenle AYNI).
    fn genListAppend(self: *Codegen, obj: Value, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
        if (args.len != 1) return error.Unsupported;
        if (obj.arena) return error.Unsupported; // arena listeleri büyütülemez (v1 sınırlaması)
        // checker `a.obj.*`in bir `.identifier` OLMASINI ZORUNLU kıldı
        // (bkz. checker.zig'in `.list` dalı) — codegen bu ŞEKLE GÜVENİR.
        const recv_name = a.obj.identifier;
        const var_info = self.vars.get(recv_name) orelse return error.Unsupported;
        if (var_info.is_param) return error.Unsupported;

        const v0 = try self.genExpr(args[0]);
        try self.checkNoLowlevelEscape(v0);
        const retained = try self.retainIfAliasing(args[0], v0);
        const val = try self.convert(retained, obj.elem_qtype);
        const elem_size = qbeSizeOf(obj.elem_qtype);

        const len_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, obj.text });
        const cap_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 8\n", .{ cap_addr, obj.text });
        const cap_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ cap_t, cap_addr });
        const has_room = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ has_room, len_t, cap_t });
        const grow_label = try self.newLabel("append_grow");
        const write_label = try self.newLabel("append_write");
        const done_label = try self.newLabel("append_done");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ has_room, write_label, grow_label });

        // Büyüme yolu: new_cap = (cap == 0) ? 1 : cap * 2 (phi'siz, alloc8
        // tabanlı bir slot ile — bu projenin TÜM merge noktalarında
        // kullandığı AYNI desen, bkz. `genListElemRelease`nin idx_slot'u).
        try self.out.writer.print("{s}\n", .{grow_label});
        const cap_is_zero = try self.newTemp();
        try self.out.writer.print("    {s} =w ceql {s}, 0\n", .{ cap_is_zero, cap_t });
        const doubled = try self.newTemp();
        try self.out.writer.print("    {s} =l mul {s}, 2\n", .{ doubled, cap_t });
        const new_cap_slot = try self.newTemp();
        try self.out.writer.print("    {s} =l alloc8 8\n", .{new_cap_slot});
        const capzero_label = try self.newLabel("append_capzero");
        const capnz_label = try self.newLabel("append_capnz");
        const capdone_label = try self.newLabel("append_capdone");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cap_is_zero, capzero_label, capnz_label });
        try self.out.writer.print("{s}\n", .{capzero_label});
        try self.out.writer.print("    storel 1, {s}\n", .{new_cap_slot});
        try self.out.writer.print("    jmp {s}\n", .{capdone_label});
        try self.out.writer.print("{s}\n", .{capnz_label});
        try self.out.writer.print("    storel {s}, {s}\n", .{ doubled, new_cap_slot });
        try self.out.writer.print("    jmp {s}\n", .{capdone_label});
        try self.out.writer.print("{s}\n", .{capdone_label});
        const new_cap = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ new_cap, new_cap_slot });

        const new_payload_size = try self.newTemp();
        {
            const sz = try self.newTemp();
            try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ sz, new_cap, elem_size });
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ new_payload_size, sz, LIST_HEADER_SIZE });
        }
        const copy_bytes = try self.newTemp();
        {
            const sz = try self.newTemp();
            try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ sz, len_t, elem_size });
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ copy_bytes, sz, LIST_HEADER_SIZE });
        }
        const new_ptr = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_list_grow(l {s}, l {s}, l {s}, l {s})\n", .{ new_ptr, RT_PARAM, obj.text, copy_bytes, new_payload_size });

        // YENİ elemanı YENİ bloğa yaz, başlığı (len/cap) GÜNCELLE.
        {
            const byte_off = try self.newTemp();
            try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ byte_off, len_t, elem_size });
            const off16 = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off16, byte_off, LIST_HEADER_SIZE });
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ addr, new_ptr, off16 });
            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(obj.elem_qtype), val.text, addr });
        }
        const new_len = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 1\n", .{ new_len, len_t });
        try self.out.writer.print("    storel {s}, {s}\n", .{ new_len, new_ptr });
        const new_cap_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 8\n", .{ new_cap_addr, new_ptr });
        try self.out.writer.print("    storel {s}, {s}\n", .{ new_cap, new_cap_addr });

        // ESKİ bloğu (yalnızca KENDİ ham belleğini — elemanlar TAŞINDI,
        // özyinelemeli release EDİLMEZ) refcount'u sıfıra düşerse serbest
        // bırak (bkz. bu fonksiyonun belge notu, "büyüme yolu").
        const should_free = try self.emitInlinePredecrement(obj.text);
        const free_label = try self.newLabel("append_free_old");
        const skip_free_label = try self.newLabel("append_skip_free");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ should_free, free_label, skip_free_label });
        try self.out.writer.print("{s}\n", .{free_label});
        const old_size = try self.newTemp();
        {
            const sz = try self.newTemp();
            try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ sz, cap_t, elem_size });
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ old_size, sz, LIST_HEADER_SIZE });
        }
        try self.out.writer.print("    call $nox_rc_free_payload(l {s}, l {s}, l {s})\n", .{ RT_PARAM, obj.text, old_size });
        try self.out.writer.print("    jmp {s}\n", .{skip_free_label});
        try self.out.writer.print("{s}\n", .{skip_free_label});

        // Alıcının KENDİ slotuna YENİ işaretçiyi geri yaz — TEK yerde
        // (hızlı yol bloğun adresini HİÇ değiştirmediğinden gerekmez).
        try self.out.writer.print("    storel {s}, {s}\n", .{ new_ptr, var_info.slot });
        try self.out.writer.print("    jmp {s}\n", .{done_label});

        // Hızlı yol: KENDİ bloğuna yerinde yaz.
        try self.out.writer.print("{s}\n", .{write_label});
        {
            const byte_off = try self.newTemp();
            try self.out.writer.print("    {s} =l mul {s}, {d}\n", .{ byte_off, len_t, elem_size });
            const off16 = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ off16, byte_off, LIST_HEADER_SIZE });
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {s}\n", .{ addr, obj.text, off16 });
            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(obj.elem_qtype), val.text, addr });
        }
        const fast_new_len = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 1\n", .{ fast_new_len, len_t });
        try self.out.writer.print("    storel {s}, {s}\n", .{ fast_new_len, obj.text });
        try self.out.writer.print("    jmp {s}\n", .{done_label});

        try self.out.writer.print("{s}\n", .{done_label});
        return .{ .text = "0", .qtype = .w };
    }

    /// `xs.sort()` — Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61).
    /// `.append`nin AKSİNE alıcının SLOTUNA geri yazma/`nox_list_grow`
    /// GEREKMEZ — sıralama MEVCUT arabelleği YERİNDE değiştirir (`len`/
    /// `cap` DEĞİŞMEZ), bu yüzden `genListAppend`nin "alıcı çıplak isim/
    /// yerel OLMALI" kısıtı burada UYGULANMAZ (checker de UYGULAMAZ, bkz.
    /// onun `.list` dalı). Eleman tipine göre (`elem_qtype`/`elem_is_str`)
    /// `nox_list_sort_int`/`_float`/`_str`den (bkz. `runtime/collections/
    /// list_sort.zig`) DOĞRU olanı, listenin BAŞLIKTAN (16 bayt) SONRAKİ
    /// ham eleman adresi + `len`i geçirerek çağırır.
    fn genListSort(self: *Codegen, obj: Value, a: ast.Attribute, args: []const ast.Expr) CodegenError!Value {
        if (args.len != 0) return error.Unsupported;

        const len_t = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ len_t, obj.text });
        const data_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ data_addr, obj.text, LIST_HEADER_SIZE });

        const fn_name = if (obj.elem_qtype == .d)
            "nox_list_sort_float"
        else if (obj.elem_is_str)
            "nox_list_sort_str"
        else
            "nox_list_sort_int";
        try self.out.writer.print("    call ${s}(l {s}, l {s})\n", .{ fn_name, data_addr, len_t });
        // `.append`nin AKSİNE alıcı çıplak bir isimle SINIRLI DEĞİLDİR
        // (bkz. bu fonksiyonun belge notu) — `a.obj.*` bir GEÇİCİ (ör.
        // `getList().sort()`) OLABİLİR, `genDictMethod`nin `contains`/`len`
        // dallarıyla AYNI şekilde serbest bırakılmalıdır.
        try self.releaseIfTemporary(a.obj.*, obj);
        return .{ .text = "0", .qtype = .none };
    }

    /// `spawn <hedef_fn>(args...)` — checker ZATEN operandın `.call` olup
    /// `.identifier` bir `async def`e başvurduğunu doğruladı (bkz.
    /// checker.zig'in `.spawn_expr` dalı); codegen burada bu ŞEKLE GÜVENİR.
    /// Argümanlar bir kapanış (closure) struct'ına PAKETLENİR (`rt` + her
    /// argüman, 8 baytlık aralıklarla — `nox_alloc` ile tahsis edilir,
    /// sarmalayıcı KENDİSİ tüketip serbest bırakır, bkz. `genSpawnWrapper`).
    /// `async def` parametreleri checker tarafından FFI-güvenli tiplerle
    /// (int/float/bool/str/None) SINIRLANDI (bkz. checker.zig, `registerFunc`)
    /// — bu yüzden hiçbir ARC retain/release GEREKMEZ.
    fn genSpawnExpr(self: *Codegen, operand: ast.Expr) CodegenError!Value {
        const call = operand.call;
        const fn_name = call.callee.identifier;
        const sig = self.functions.get(fn_name) orelse return error.Unsupported;
        if (sig.params.len != call.args.len) return error.Unsupported;

        const arg_values = try self.allocator.alloc(Value, call.args.len);
        for (call.args, 0..) |a, i| {
            const v0 = try self.genExpr(a);
            arg_values[i] = try self.convert(v0, sig.params[i].qtype);
        }

        const closure_size = 8 + 8 * call.args.len;
        const closure = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_alloc(l {s}, l {d})\n", .{ closure, RT_PARAM, closure_size });
        try self.out.writer.print("    storel {s}, {s}\n", .{ RT_PARAM, closure });
        for (arg_values, 0..) |av, i| {
            const off = 8 + 8 * i;
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add {s}, {d}\n", .{ addr, closure, off });
            try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(av.qtype), av.text, addr });
        }

        const wrapper_name = try std.fmt.allocPrint(self.allocator, "spawn_wrap_{d}", .{self.spawn_wrapper_counter});
        self.spawn_wrapper_counter += 1;
        try self.spawn_wrappers.append(self.allocator, .{ .name = wrapper_name, .target_fn = fn_name, .sig = sig });

        const task_ptr = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_async_spawn(l {s}, l ${s}, l {s})\n", .{ task_ptr, RT_PARAM, wrapper_name, closure });

        var elem_heap_info: ?*const ElemHeapInfo = null;
        if (sig.ret.heap == .class or sig.ret.heap == .list) {
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = sig.ret.heap, .class_name = sig.ret.class_name, .elem_qtype = sig.ret.elem_qtype, .nested = sig.ret.elem_heap_info, .elem_is_str = sig.ret.elem_is_str };
            elem_heap_info = info;
        }
        // `Task[T]`nin KENDİSİ (görev tutamacı) ARC-yönetimli DEĞİLDİR (bkz.
        // `HeapKind`in belge notu) — `heap = .task` yalnızca kapsam-sonu
        // `nox_async_destroy_task` çağrısını tetiklemek İÇİNDİR; `elem_*`
        // alanları T'yi (payload tipini) taşır.
        return .{
            .text = task_ptr,
            .qtype = .l,
            .heap = .task,
            .elem_qtype = sig.ret.qtype,
            .elem_heap_info = elem_heap_info,
            .elem_is_str = sig.ret.heap == .str,
        };
    }

    /// `nox_async_spawn`in çağırdığı, `spawn` çağrı sitesi başına üretilen
    /// bir fiber girişi — bkz. `SpawnWrapperSpec`in belge notu. `%argp`den
    /// (kapanış) argümanları paketten çıkarır, `spec.target_fn`i normal
    /// şekilde çağırır, sonucu bir `i64` payload'a çevirir, kapanışı serbest
    /// bırakır.
    ///
    /// **Bilinçli v0.1 sınırlaması:** `spec.target_fn`in içinde bir istisna
    /// oluşup YAKALANMAZSA, bu BURADA denetlenmez/temizlenmez (bkz.
    /// nox-teknik-spesifikasyon.md §3.21'in "kalan" notu) — Nox'un istisna
    /// mekanizmasının async görevlerle tam entegrasyonu ayrı bir artımdır.
    fn genSpawnWrapper(self: *Codegen, spec: SpawnWrapperSpec) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        try self.out.writer.print("export function l ${s}(l %argp) {{\n@start\n", .{spec.name});
        try self.out.writer.print("    {s} =l loadl %argp\n", .{RT_PARAM});

        const arg_texts = try self.allocator.alloc([]const u8, spec.sig.params.len);
        for (spec.sig.params, 0..) |p, i| {
            const off = 8 + 8 * i;
            const addr = try self.newTemp();
            try self.out.writer.print("    {s} =l add %argp, {d}\n", .{ addr, off });
            const val = try self.newTemp();
            try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ val, qbeTypeName(p.qtype), qbeTypeName(p.qtype), addr });
            arg_texts[i] = val;
        }

        const payload = blk: {
            if (spec.sig.ret.qtype == .none) {
                try self.out.writer.print("    call ${s}(l {s}", .{ spec.target_fn, RT_PARAM });
                for (spec.sig.params, arg_texts) |p, at| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(p.qtype), at });
                try self.out.writer.writeAll(")\n");
                break :blk Value{ .text = "0", .qtype = .l };
            }
            const result_t = try self.newTemp();
            try self.out.writer.print("    {s} ={s} call ${s}(l {s}", .{ result_t, qbeTypeName(spec.sig.ret.qtype), spec.target_fn, RT_PARAM });
            for (spec.sig.params, arg_texts) |p, at| try self.out.writer.print(", {s} {s}", .{ qbeTypeName(p.qtype), at });
            try self.out.writer.writeAll(")\n");
            break :blk try self.toPayload(.{ .text = result_t, .qtype = spec.sig.ret.qtype });
        };

        const closure_size = 8 + 8 * spec.sig.params.len;
        try self.out.writer.print("    call $nox_free(l {s}, l %argp, l {d})\n", .{ RT_PARAM, closure_size });
        try self.out.writer.print("    ret {s}\n}}\n", .{payload.text});
    }

    /// `nox.thread.start(entry, arg)` çağrı sitesi codegen'i — Faz BB.4
    /// (bkz. nox-teknik-spesifikasyon.md §3.50). Checker ZATEN `entry`in
    /// ÇIPLAK bir `async def` ismi OLDUĞUNU, `arg`ın tipinin `entry`in TEK
    /// parametresiyle UYUŞTUĞUNU VE HER İKİSİNİN de `isThreadTransferSafeType`den
    /// GEÇTİĞİNİ doğruladı (bkz. checker.zig'in `tryResolveThreadSpawnCall`ı).
    ///
    /// `genSpawnExpr`DEN FARKLI: `arg`ın (str İSE) hazırlık-arabelleğine
    /// KOPYALANMASI VE ÇOCUK iş parçacığının KENDİ `RuntimeState`i ÜZERİNDEN
    /// taze bir ARC `str` İNŞA ETMESİ TAMAMEN `runtime/async_rt/thread_bridge.
    /// zig`nin `nox_thread_spawn`ının/`childThreadMain`inin İÇİNDE olur —
    /// BURADA (çağrı SİTESİNDE) `arg`ın kendisi SADECE `toPayload`a çevrilip
    /// `nox_thread_spawn`a AKTARILIR, `arg_is_str`/`result_is_str` (statik
    /// olarak `entry`in İMZASINDAN türetilir) O tarafın HANGİ protokolü
    /// (düz payload mı, str-klonlama mı) İZLEYECEĞİNİ SÖYLER. `arg` İÇİN
    /// (Faz BB.2'nin belge notunda AÇIKLANDIĞI GİBİ) HİÇBİR ÖZEL retain
    /// GEREKMEZ — `nox_thread_spawn` orijinal işaretçiyi ASLA SAKLAMAZ,
    /// yalnızca SENKRON olarak baytlarını OKUR/KOPYALAR (normal bir
    /// fonksiyon argümanı GİBİ davranır, `spawn`ın kapanış-paketlemesinin
    /// AKSİNE).
    fn genThreadStartExpr(self: *Codegen, c: ast.Call) CodegenError!Value {
        if (c.args.len != 2) return error.Unsupported;
        const fn_name = switch (c.args[0]) {
            .identifier => |n| n,
            else => return error.Unsupported,
        };
        const sig = self.functions.get(fn_name) orelse return error.Unsupported;
        if (sig.params.len != 1) return error.Unsupported;

        const arg_v0 = try self.genExpr(c.args[1]);
        const arg_v = try self.convert(arg_v0, sig.params[0].qtype);
        const arg_payload = try self.toPayload(arg_v);

        const arg_is_str: []const u8 = if (sig.params[0].heap == .str) "1" else "0";
        const result_is_str: []const u8 = if (sig.ret.heap == .str) "1" else "0";

        const wrapper_name = try std.fmt.allocPrint(self.allocator, "thread_wrap_{d}", .{self.thread_wrapper_counter});
        self.thread_wrapper_counter += 1;
        try self.thread_wrappers.append(self.allocator, .{ .name = wrapper_name, .target_fn = fn_name, .sig = sig });

        const handle_ptr = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_thread_spawn(l {s}, l ${s}, l {s}, w {s}, w {s})\n", .{ handle_ptr, RT_PARAM, wrapper_name, arg_payload.text, arg_is_str, result_is_str });

        var elem_heap_info: ?*const ElemHeapInfo = null;
        if (sig.ret.heap == .class or sig.ret.heap == .list) {
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = sig.ret.heap, .class_name = sig.ret.class_name, .elem_qtype = sig.ret.elem_qtype, .nested = sig.ret.elem_heap_info, .elem_is_str = sig.ret.elem_is_str };
            elem_heap_info = info;
        }
        // `ThreadHandle[T]`in KENDİSİ (bkz. `HeapKind`in belge notu) ARC-
        // yönetimli DEĞİLDİR — `heap = .thread_handle` yalnızca kapsam-sonu
        // `nox_thread_destroy` çağrısını TETİKLEMEK içindir; `elem_*` alanları
        // T'yi (payload tipini) taşır.
        return .{
            .text = handle_ptr,
            .qtype = .l,
            .heap = .thread_handle,
            .elem_qtype = sig.ret.qtype,
            .elem_heap_info = elem_heap_info,
            .elem_is_str = sig.ret.heap == .str,
        };
    }

    /// `nox_thread_spawn`ın çağırdığı, `nox.thread.start` çağrı sitesi
    /// başına üretilen bir ÇOCUK İŞ PARÇACIĞI girişi — bkz. `ThreadWrapperSpec`in
    /// belge notu. `genSpawnWrapper`DEN İKİ noktada FARKLI: (1) argüman
    /// SAYISI HER ZAMAN TAM OLARAK 1'dir (Tier 1'in kısıtı); (2) kapanış
    /// (`ThreadEntryClosure`) native-qtype'lı DEĞİL, HER ZAMAN `l` (i64)
    /// genişliğinde bir `payload` alanı TAŞIR (bkz. `thread_bridge.zig`nin
    /// Zig struct TANIMI) — bu yüzden argüman `loadl` İLE okunup `fromPayload`
    /// İLE hedef tipe ÇEVRİLİR (`genSpawnWrapper`nin native `load{qtype}`inin
    /// AKSİNE). Kapanışın KENDİSİ (`ThreadEntryClosure`) `runtime/async_rt/
    /// thread_bridge.zig`nin `childThreadMain`i TARAFINDAN (SAF Zig'de)
    /// tahsis edilip serbest BIRAKILIR — BURADA `nox_free` ÇAĞRILMAZ
    /// (`genSpawnWrapper`nin kapanışının AKSİNE, bkz. `ThreadWrapperSpec`in
    /// belge notu).
    fn genThreadStartWrapper(self: *Codegen, spec: ThreadWrapperSpec) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        try self.out.writer.print("export function l ${s}(l %argp) {{\n@start\n", .{spec.name});
        try self.out.writer.print("    {s} =l loadl %argp\n", .{RT_PARAM});

        const payload_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add %argp, 8\n", .{payload_addr});
        const payload_val = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ payload_val, payload_addr });
        const arg_val = try self.fromPayload(.{ .text = payload_val, .qtype = .l }, spec.sig.params[0].qtype);

        const result_payload = blk: {
            if (spec.sig.ret.qtype == .none) {
                try self.out.writer.print("    call ${s}(l {s}, {s} {s})\n", .{ spec.target_fn, RT_PARAM, qbeTypeName(arg_val.qtype), arg_val.text });
                break :blk Value{ .text = "0", .qtype = .l };
            }
            const result_t = try self.newTemp();
            try self.out.writer.print("    {s} ={s} call ${s}(l {s}, {s} {s})\n", .{ result_t, qbeTypeName(spec.sig.ret.qtype), spec.target_fn, RT_PARAM, qbeTypeName(arg_val.qtype), arg_val.text });
            break :blk try self.toPayload(.{ .text = result_t, .qtype = spec.sig.ret.qtype });
        };

        // Parametreler `spec.target_fn` TARAFINDAN ÖDÜNÇ ALINIR (bkz.
        // `collectLocals`/`allocSlot`in `is_param` notu — kapsam-sonu
        // otomatik release'i HER ZAMAN ATLAR) — çağrı SİTESİ (BURASI)
        // sahipliği ELİNDE TUTAR (normal `genCall`nin `releaseTemporaryArgs`
        // İLE AYNI sözleşme). `arg_val` BURADA `childThreadMain`in TAZE
        // klonladığı, TEK sahipli bir ARC `str`tir (Tier 1 SADECE `str`i
        // heap-yönetimli tip olarak KABUL EDER) — çağrı DÖNDÜKTEN SONRA
        // BURADA serbest bırakılMAZSA sızar (bu, `dupeToNoxStr`in Faz BB.4
        // uçtan uca golden testinde YAKALANAN GERÇEK bir sızıntıydı).
        if (spec.sig.params[0].heap == .str) {
            try self.releaseValueIfSet(arg_val.text, .str, .none, null, null, null);
        }

        try self.out.writer.print("    ret {s}\n}}\n", .{result_payload.text});
    }

    /// `handle.join()` — YALNIZCA `await` üzerinden (bkz. `genAwaitExpr`)
    /// çağrılır, `genCall`in normal metod-çağrısı yolundan GEÇMEZ
    /// (`ThreadHandle` `self.classes`de yok, yerleşik bir tiptir) —
    /// `genChannelOp`in `recv` dalıyla AYNI desen.
    fn genThreadHandleJoin(self: *Codegen, a: ast.Attribute) CodegenError!Value {
        const handle_val = try self.genExpr(a.obj.*);
        const payload_t = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_thread_join(l {s}, l {s})\n", .{ payload_t, RT_PARAM, handle_val.text });
        const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, handle_val.elem_qtype);
        return valueFromElemDescriptor(converted.text, converted.qtype, handle_val.elem_heap_info, handle_val.elem_is_str);
    }

    /// `nox.http.serve(port, handle[, max_connections])` çağrı sitesi
    /// codegen'i — checker ZATEN `handle`in bir `(HttpRequest) -> HttpResponse`
    /// imzalı, `async def` OLMAYAN çıplak bir isim olduğunu doğruladı (bkz.
    /// checker.zig'in `tryResolveHttpServeCall`ı). `port` (ve varsa üçüncü
    /// `max_connections` argümanı) değerlendirilir, `nox_http_server_listen`
    /// ile dinlemeye başlanır, HER çağrı sitesi İÇİN AYRI bir C-ABI
    /// sarmalayıcı (bkz. `HttpServeWrapperSpec`) TEMBEL kaydedilip
    /// `nox_http_serve_raw`a `HandlerFn` olarak geçirilir — `rt`nin KENDİSİ
    /// `handler_ctx` parametresi olarak taşınır (bkz. `HttpServeWrapperSpec`in
    /// belge notu, `spawn`ın kapanış paketlemesinin AKSİNE).
    fn genHttpServe(self: *Codegen, c: ast.Call) CodegenError!Value {
        if (c.args.len != 2 and c.args.len != 3) return error.Unsupported;

        const port_v0 = try self.genExpr(c.args[0]);
        try self.checkNoLowlevelEscape(port_v0);
        const port_v = try self.convert(port_v0, .l);
        try self.releaseIfTemporary(c.args[0], port_v0);

        const handle_name = switch (c.args[1]) {
            .identifier => |n| n,
            else => return error.Unsupported,
        };
        const sig = self.functions.get(handle_name) orelse return error.Unsupported;
        if (sig.params.len != 1) return error.Unsupported;
        if (sig.params[0].heap != .class or sig.params[0].class_name == null) return error.Unsupported;
        if (sig.ret.heap != .class or sig.ret.class_name == null) return error.Unsupported;
        const req_class = sig.params[0].class_name.?;
        const resp_class = sig.ret.class_name.?;

        var max_conn_text: []const u8 = "0";
        if (c.args.len == 3) {
            const mc_v0 = try self.genExpr(c.args[2]);
            try self.checkNoLowlevelEscape(mc_v0);
            const mc_v = try self.convert(mc_v0, .l);
            try self.releaseIfTemporary(c.args[2], mc_v0);
            max_conn_text = mc_v.text;
        }

        const server = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_http_server_listen(l {s}, l {s})\n", .{ server, RT_PARAM, port_v.text });

        const wrapper_name = try std.fmt.allocPrint(self.allocator, "http_serve_wrap_{d}", .{self.http_serve_wrapper_counter});
        self.http_serve_wrapper_counter += 1;
        try self.http_serve_wrappers.append(self.allocator, .{ .name = wrapper_name, .handler_fn = handle_name, .req_class = req_class, .resp_class = resp_class });

        try self.out.writer.print("    call $nox_http_serve_raw(l {s}, l {s}, l ${s}, l {s}, l {s})\n", .{ RT_PARAM, server, wrapper_name, RT_PARAM, max_conn_text });
        try self.out.writer.print("    call $nox_http_server_close(l {s}, l {s})\n", .{ RT_PARAM, server });
        return .{ .text = "0", .qtype = .none };
    }

    /// Faz DD.1 (bkz. nox-teknik-spesifikasyon.md §3.60) — `nox_http_
    /// server_from_fd`+`nox_http_serve_raw`+`nox_http_server_close` ÜÇ-
    /// satırlık diziyi yayınlar. `genHttpServeFd`nin kuyruğu VE
    /// `genHttpServeMulticoreWorker`nin SENTEZLENMİŞ gövdesi TARAFINDAN
    /// paylaşılır (kod TEKRARI önlenir) — HER İKİSİ de MEVCUT `RT_PARAM`
    /// (`"%rt"`) ismini KENDİ fonksiyon gövdelerinde ÖNCEDEN TANIMLAMIŞ
    /// olmalıdır (`genThreadStartWrapper`nin `%argp`den `RT_PARAM`
    /// YÜKLEMESİYLE AYNI sözleşme).
    fn emitFdServeTail(self: *Codegen, fd_text: []const u8, wrapper_name: []const u8, max_conn_text: []const u8) CodegenError!void {
        const server = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_http_server_from_fd(l {s}, l {s})\n", .{ server, RT_PARAM, fd_text });
        try self.out.writer.print("    call $nox_http_serve_raw(l {s}, l {s}, l ${s}, l {s}, l {s})\n", .{ RT_PARAM, server, wrapper_name, RT_PARAM, max_conn_text });
        try self.out.writer.print("    call $nox_http_server_close(l {s}, l {s})\n", .{ RT_PARAM, server });
    }

    /// `nox.http.serve_fd(fd, handle[, max_connections])` çağrı sitesi
    /// codegen'i — Faz DD.1 (bkz. nox-teknik-spesifikasyon.md §3.60).
    /// `genHttpServe` İLE NEREDEYSE ÖZDEŞ, TEK fark: `nox_http_server_
    /// listen(rt, port)` (YENİ bir soket YARATIR) YERİNE `nox_http_server_
    /// from_fd(rt, fd)` (ZATEN dinlemede olan PAYLAŞILAN bir fd'yi SARAR) —
    /// `HttpServeWrapperSpec`/`genHttpServeWrapper` DEĞİŞTİRİLMEDEN
    /// yeniden kullanılır.
    fn genHttpServeFd(self: *Codegen, c: ast.Call) CodegenError!Value {
        if (c.args.len != 2 and c.args.len != 3) return error.Unsupported;

        const fd_v0 = try self.genExpr(c.args[0]);
        try self.checkNoLowlevelEscape(fd_v0);
        const fd_v = try self.convert(fd_v0, .l);
        try self.releaseIfTemporary(c.args[0], fd_v0);

        const handle_name = switch (c.args[1]) {
            .identifier => |n| n,
            else => return error.Unsupported,
        };
        const sig = self.functions.get(handle_name) orelse return error.Unsupported;
        if (sig.params.len != 1) return error.Unsupported;
        if (sig.params[0].heap != .class or sig.params[0].class_name == null) return error.Unsupported;
        if (sig.ret.heap != .class or sig.ret.class_name == null) return error.Unsupported;
        const req_class = sig.params[0].class_name.?;
        const resp_class = sig.ret.class_name.?;

        var max_conn_text: []const u8 = "0";
        if (c.args.len == 3) {
            const mc_v0 = try self.genExpr(c.args[2]);
            try self.checkNoLowlevelEscape(mc_v0);
            const mc_v = try self.convert(mc_v0, .l);
            try self.releaseIfTemporary(c.args[2], mc_v0);
            max_conn_text = mc_v.text;
        }

        const wrapper_name = try std.fmt.allocPrint(self.allocator, "http_serve_wrap_{d}", .{self.http_serve_wrapper_counter});
        self.http_serve_wrapper_counter += 1;
        try self.http_serve_wrappers.append(self.allocator, .{ .name = wrapper_name, .handler_fn = handle_name, .req_class = req_class, .resp_class = resp_class });

        try self.emitFdServeTail(fd_v.text, wrapper_name, max_conn_text);
        return .{ .text = "0", .qtype = .none };
    }

    /// `nox.http.serve_multicore(port, handle, num_threads[,
    /// max_connections])` çağrı sitesi codegen'i — Faz DD.1 (bkz. nox-
    /// teknik-spesifikasyon.md §3.60). `port` BİR KEZ `nox_http_listen_fd`
    /// İLE dinlemeye alınır (ham bir `int` fd, `ServerHandle` YOK),
    /// `num_threads - 1` ek `nox.thread` worker'ı (bkz. `genHttpServeMulticoreWorker`)
    /// AYNI paylaşılan fd üzerinde `nox_thread_spawn` İLE başlatılır —
    /// `genForRange`nin AYNI sayaçlı-döngü şekli (bkz. onun belge notu),
    /// TEK fark: döngü değişkeni bir Nox kullanıcı değişkeni DEĞİL, `self.
    /// vars`e HİÇ kaydedilmeyen sentetik bir yığın yuvasıdır. ÇAĞIRAN iş
    /// parçacığının KENDİSİ Nninci worker OLUR (`emitFdServeTail` İLE,
    /// `genHttpServeFd`nin kuyruğuyla AYNI) — bugünkü `nox.http.serve`nin
    /// "çağrı sonsuza kadar bloke olur" sözleşmesiyle TUTARLI.
    ///
    /// **Bilinçli "fire-and-forget":** spawn edilen `ThreadHandle`lar ASLA
    /// `.join()` edilmez/serbest bırakılmaz — sunucu ZATEN sonsuza kadar
    /// çalışır (worker'lar hiç DÖNMEZ), `num_threads` sunucu ÖMRÜ boyunca
    /// BİR KEZ harcanan, küçük/sınırlı bir sayıdır — bağlantı fiber'larının
    /// HİÇBİR ZAMAN `await` edilmemesiyle AYNI, ZATEN VAR OLAN proje
    /// ilkesiyle TUTARLI (bkz. bu dosyanın `nox_http_serve_raw`ının modül-
    /// üstü notu).
    fn genHttpServeMulticore(self: *Codegen, c: ast.Call) CodegenError!Value {
        if (c.args.len != 3 and c.args.len != 4) return error.Unsupported;

        const port_v0 = try self.genExpr(c.args[0]);
        try self.checkNoLowlevelEscape(port_v0);
        const port_v = try self.convert(port_v0, .l);
        try self.releaseIfTemporary(c.args[0], port_v0);

        const handle_name = switch (c.args[1]) {
            .identifier => |n| n,
            else => return error.Unsupported,
        };
        const sig = self.functions.get(handle_name) orelse return error.Unsupported;
        if (sig.params.len != 1) return error.Unsupported;
        if (sig.params[0].heap != .class or sig.params[0].class_name == null) return error.Unsupported;
        if (sig.ret.heap != .class or sig.ret.class_name == null) return error.Unsupported;
        const req_class = sig.params[0].class_name.?;
        const resp_class = sig.ret.class_name.?;

        const num_threads_v0 = try self.genExpr(c.args[2]);
        try self.checkNoLowlevelEscape(num_threads_v0);
        const num_threads_v = try self.convert(num_threads_v0, .l);
        try self.releaseIfTemporary(c.args[2], num_threads_v0);

        // Checker ZATEN `.int_lit` olduğunu garanti etti (bkz.
        // `tryResolveHttpServeMulticoreCall`in belge notu) — DERLEME-
        // ZAMANI bir metin sabiti olarak HEM aşağıdaki `emitFdServeTail`
        // çağrısına HEM `genHttpServeMulticoreWorker`in sentezlediği
        // worker gövdesine gömülür.
        var max_conn_text: []const u8 = "0";
        if (c.args.len == 4) {
            max_conn_text = try std.fmt.allocPrint(self.allocator, "{d}", .{c.args[3].int_lit});
        }

        const fd = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_http_listen_fd(l {s}, l {s})\n", .{ fd, RT_PARAM, port_v.text });

        const wrapper_name = try std.fmt.allocPrint(self.allocator, "http_serve_wrap_{d}", .{self.http_serve_wrapper_counter});
        self.http_serve_wrapper_counter += 1;
        try self.http_serve_wrappers.append(self.allocator, .{ .name = wrapper_name, .handler_fn = handle_name, .req_class = req_class, .resp_class = resp_class });

        const worker_name = try std.fmt.allocPrint(self.allocator, "http_serve_mc_worker_{d}", .{self.http_serve_multicore_worker_counter});
        self.http_serve_multicore_worker_counter += 1;
        try self.http_serve_multicore_workers.append(self.allocator, .{ .name = worker_name, .wrapper_name = wrapper_name, .max_conn_text = max_conn_text });

        const i_slot = try self.newTemp();
        try self.out.writer.print("    {s} =l alloc8 8\n", .{i_slot});
        try self.out.writer.print("    storel 1, {s}\n", .{i_slot});

        const cond_label = try self.newLabel("mc_spawn_cond");
        const body_label = try self.newLabel("mc_spawn_body");
        const end_label = try self.newLabel("mc_spawn_end");

        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{cond_label});
        const cur = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ cur, i_slot });
        const cmp = try self.newTemp();
        try self.out.writer.print("    {s} =w csltl {s}, {s}\n", .{ cmp, cur, num_threads_v.text });
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cmp, body_label, end_label });
        try self.out.writer.print("{s}\n", .{body_label});
        const handle_ptr = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_thread_spawn(l {s}, l ${s}, l {s}, w 0, w 0)\n", .{ handle_ptr, RT_PARAM, worker_name, fd });
        const cur2 = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ cur2, i_slot });
        const next = try self.newTemp();
        try self.out.writer.print("    {s} =l add {s}, 1\n", .{ next, cur2 });
        try self.out.writer.print("    storel {s}, {s}\n", .{ next, i_slot });
        try self.out.writer.print("    jmp {s}\n", .{cond_label});
        try self.out.writer.print("{s}\n", .{end_label});

        try self.emitFdServeTail(fd, wrapper_name, max_conn_text);
        return .{ .text = "0", .qtype = .none };
    }

    /// `nox_thread_spawn`ın ÇAĞIRDIĞI, `nox.http.serve_multicore` çağrı
    /// sitesi başına üretilen bir ÇOCUK İŞ PARÇACIĞI girişi — Faz DD.1
    /// (bkz. nox-teknik-spesifikasyon.md §3.60). `genThreadStartWrapper`nin
    /// KANITLANMIŞ düşük-seviye şekliyle (`%argp`den `RT_PARAM` + payload
    /// YÜKLEMESİ) BİREBİR AYNI iskelet, AMA gövde gerçek bir Nox fonksiyonu
    /// ÇAĞIRMAK yerine `emitFdServeTail`i çağırır — bu worker'ın ARKASINDA
    /// yazılmış bir Nox `entry` fonksiyonu YOKTUR, TAMAMEN sentezlenir
    /// (`genHttpServeWrapper`nin `HandlerFn` sarmalayıcısını
    /// sentezlemesiyle AYNI teknik).
    fn genHttpServeMulticoreWorker(self: *Codegen, spec: HttpServeMulticoreWorkerSpec) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        try self.out.writer.print("export function l ${s}(l %argp) {{\n@start\n", .{spec.name});
        try self.out.writer.print("    {s} =l loadl %argp\n", .{RT_PARAM});
        const payload_addr = try self.newTemp();
        try self.out.writer.print("    {s} =l add %argp, 8\n", .{payload_addr});
        const fd = try self.newTemp();
        try self.out.writer.print("    {s} =l loadl {s}\n", .{ fd, payload_addr });

        try self.emitFdServeTail(fd, spec.wrapper_name, spec.max_conn_text);

        try self.out.writer.writeAll("    ret 0\n}\n");
    }

    /// `nox_http_serve_raw`nin (bkz. runtime/stdlib_shims/http_server.zig'in
    /// `HandlerFn`i, `fn(?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque`)
    /// bağlantı başına ÇAĞIRDIĞI, `nox.http.serve` çağrı sitesi başına
    /// üretilen C-ABI sarmalayıcı — bkz. `HttpServeWrapperSpec`in belge notu.
    /// `%ctx` (`rt`nin KENDİSİ, `genHttpServe`nin `handler_ctx` olarak
    /// geçirdiği) ve `%req` (ham istek tutamacı) alır: `req_class`ın (ör.
    /// `HttpRequest`) alanlarını ham `nox_http_request_*` erişimcileriyle
    /// doldurup bir örnek İNŞA EDER (`genConstructFromValues`), kullanıcının
    /// `handler_fn`ini çağırır, dönen `resp_class` (ör. `HttpResponse`)
    /// örneğinden `status`/`body`/`headers`i okuyup (`genFieldReadFromValue`)
    /// `nox_http_response_new`e geçirir (BU çağrı KENDİ kopyasını
    /// tuttuğundan, bkz. `runtime/stdlib_shims/http_server.zig`nin
    /// `nox_http_response_new`ı — `body`/`headers`i `gpa.dupe`/`copyHeaders`
    /// ile KOPYALAR), SONRA hem istek hem yanıt örneğini TAMAMEN serbest
    /// bırakır.
    ///
    /// **Bilinçli v0.1 sınırlaması (`genSpawnWrapper` İLE AYNI gerekçe):**
    /// `handler_fn` içinde bir istisna oluşup YAKALANMAZSA, bu BURADA
    /// denetlenmez/temizlenmez.
    fn genHttpServeWrapper(self: *Codegen, spec: HttpServeWrapperSpec) CodegenError!void {
        self.temp_counter = 0;
        self.label_counter = 0;

        try self.out.writer.print("export function l ${s}(l %ctx, l %req) {{\n@start\n", .{spec.name});
        try self.out.writer.print("    {s} =l copy %ctx\n", .{RT_PARAM});

        const req_cinfo = self.classes.get(spec.req_class) orelse return error.Unsupported;
        const req_values = try self.allocator.alloc(Value, req_cinfo.fields.items.len);
        for (req_cinfo.fields.items, 0..) |f, i| {
            const t = try self.newTemp();
            if (std.mem.eql(u8, f.name, "method")) {
                try self.out.writer.print("    {s} =l call $nox_http_request_method(l {s}, l %req)\n", .{ t, RT_PARAM });
                req_values[i] = .{ .text = t, .qtype = .l, .heap = .str };
            } else if (std.mem.eql(u8, f.name, "target")) {
                try self.out.writer.print("    {s} =l call $nox_http_request_target(l {s}, l %req)\n", .{ t, RT_PARAM });
                req_values[i] = .{ .text = t, .qtype = .l, .heap = .str };
            } else if (std.mem.eql(u8, f.name, "body")) {
                try self.out.writer.print("    {s} =l call $nox_http_request_body(l {s}, l %req)\n", .{ t, RT_PARAM });
                req_values[i] = .{ .text = t, .qtype = .l, .heap = .str };
            } else if (std.mem.eql(u8, f.name, "headers")) {
                try self.out.writer.print("    {s} =l call $nox_http_request_headers(l {s}, l %req)\n", .{ t, RT_PARAM });
                req_values[i] = .{ .text = t, .qtype = .l, .heap = .dict, .dict_info = f.info.dict_info };
            } else {
                return error.Unsupported;
            }
        }
        const req_obj = try self.genConstructFromValues(spec.req_class, req_cinfo, req_values);
        // `req_values` — `releaseTemporaryArgs`in gerekçesiyle AYNI (bkz.
        // onun belge notu): her biri TAZE bir `nox_http_request_*` çağrısının
        // SONUCUdur (KENDİ releaser'ı yok). `__init__`in `self.x = x` alan
        // ataması heap-yönetimli olanları (str VE Faz FF.3'ten beri dict)
        // ZATEN retain ETTİĞİNDEN (bkz. `genAssign`in `.attribute` dalı),
        // burada BİR KEZ daha serbest bırakmak DENGELER (aksi halde
        // sızarlar) — `isHeapManaged` kontrolü, retain EDİLMEYEN (heap-
        // yönetimli OLMAYAN) alanları burada doğal olarak ELER.
        for (req_values) |v| {
            if (isHeapManaged(v.heap)) {
                try self.releaseValueIfSet(v.text, v.heap, v.elem_qtype, v.class_name, v.elem_heap_info, v.dict_info);
            }
        }

        const resp_obj_text = try self.newTemp();
        try self.out.writer.print("    {s} =l call ${s}(l {s}, l {s})\n", .{ resp_obj_text, spec.handler_fn, RT_PARAM, req_obj.text });
        const resp_obj: Value = .{ .text = resp_obj_text, .qtype = .l, .heap = .class, .class_name = spec.resp_class };

        try self.releaseValueIfSet(req_obj.text, req_obj.heap, req_obj.elem_qtype, req_obj.class_name, req_obj.elem_heap_info, req_obj.dict_info);

        const status = try self.genFieldReadFromValue(resp_obj, "status");
        const body = try self.genFieldReadFromValue(resp_obj, "body");
        const headers = try self.genFieldReadFromValue(resp_obj, "headers");

        const raw_resp = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_http_response_new(l {s}, l {s}, l {s}, l {s})\n", .{ raw_resp, RT_PARAM, status.text, body.text, headers.text });

        try self.releaseValueIfSet(resp_obj.text, resp_obj.heap, resp_obj.elem_qtype, resp_obj.class_name, resp_obj.elem_heap_info, resp_obj.dict_info);

        try self.out.writer.print("    ret {s}\n}}\n", .{raw_resp});
    }

    /// `await <ifade>` — checker ZATEN operandın ya bir `Task` değeri ya da
    /// bir `Channel.send`/`recv` çağrısı olduğunu doğruladı (bkz. checker'ın
    /// `.await_expr` dalı); codegen AYNI şekle bakarak dallanır.
    fn genAwaitExpr(self: *Codegen, operand: ast.Expr) CodegenError!Value {
        if (operand == .call) {
            const c = operand.call;
            if (c.callee.* == .attribute) {
                const a = c.callee.attribute;
                if (std.mem.eql(u8, a.attr, "send") or std.mem.eql(u8, a.attr, "recv")) {
                    // Alıcının statik tipi (`Channel[T]` mi `ThreadChannel[T]`
                    // mi) BİR KEZ değerlendirilir — Faz BB.6: `ThreadChannel`
                    // AYRI bir çalışma-zamanı protokolü (`nox_threadchannel_*`,
                    // dual-pipe) kullandığından `genChannelOp`DAN AYRI bir
                    // fonksiyona (`genThreadChannelOp`) dispatch edilir.
                    const recv_val = try self.genExpr(a.obj.*);
                    if (recv_val.heap == .thread_channel) return self.genThreadChannelOp(a, c.args, recv_val);
                    return self.genChannelOp(a, c.args, recv_val);
                }
                // Faz BB.4: `ThreadHandle[T].join()` — `Channel.send`/`.recv`
                // İLE AYNI "yalnızca await üzerinden" desen (bkz.
                // `genThreadHandleJoin`in belge notu).
                if (std.mem.eql(u8, a.attr, "join")) {
                    return self.genThreadHandleJoin(a);
                }
            }
        }
        const task_val = try self.genExpr(operand);
        const payload_t = try self.newTemp();
        try self.out.writer.print("    {s} =l call $nox_async_await(l {s}, l {s})\n", .{ payload_t, RT_PARAM, task_val.text });
        const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, task_val.elem_qtype);
        return valueFromElemDescriptor(converted.text, converted.qtype, task_val.elem_heap_info, task_val.elem_is_str);
    }

    /// `ch.send(v)`/`ch.recv()` — YALNIZCA `await` üzerinden (bkz.
    /// `genAwaitExpr`) çağrılır, `genCall`in normal metod-çağrısı yolundan
    /// GEÇMEZ (`Channel` `self.classes`de yok, yerleşik bir tiptir). `ch_val`
    /// `genAwaitExpr` TARAFINDAN ZATEN değerlendirilmiştir (Faz BB.6: alıcı
    /// tipinin `Channel` mi `ThreadChannel` mi OLDUĞUNU görmek İÇİN zaten
    /// BİR KEZ değerlendirilmesi GEREKTİĞİNDEN, burada TEKRAR değerlendirip
    /// yan etkileri İKİ KEZ tetiklemek yerine parametre olarak alınır).
    fn genChannelOp(self: *Codegen, a: ast.Attribute, args: []const ast.Expr, ch_val: Value) CodegenError!Value {
        if (std.mem.eql(u8, a.attr, "send")) {
            if (args.len != 1) return error.Unsupported;
            const v = try self.genExpr(args[0]);
            const converted = try self.convert(v, ch_val.elem_qtype);
            const payload = try self.toPayload(converted);
            try self.out.writer.print("    call $nox_channel_send(l {s}, l {s}, l {s})\n", .{ RT_PARAM, ch_val.text, payload.text });
            return .{ .text = "0", .qtype = .none };
        }
        if (std.mem.eql(u8, a.attr, "recv")) {
            if (args.len != 0) return error.Unsupported;
            const payload_t = try self.newTemp();
            try self.out.writer.print("    {s} =l call $nox_channel_recv(l {s}, l {s})\n", .{ payload_t, RT_PARAM, ch_val.text });
            const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, ch_val.elem_qtype);
            return valueFromElemDescriptor(converted.text, converted.qtype, ch_val.elem_heap_info, ch_val.elem_is_str);
        }
        return error.Unsupported;
    }

    /// `tc.send(v)`/`tc.recv()` — Faz BB.6 (bkz. nox-teknik-spesifikasyon.md
    /// §3.52): `genChannelOp`in AYNI deseni, AMA `nox_channel_*` yerine
    /// `nox_threadchannel_*`e ÇAĞRI YAPAR VE `T`nin `str` OLUP OLMADIĞINA
    /// (statik olarak `ch_val.elem_is_str`den BİLİNİR — `thread_channel.zig`nin
    /// `_val`/`_str` ikili API'sinin GEREĞİ) GÖRE `_val`/`_str` varyantı
    /// SEÇER.
    fn genThreadChannelOp(self: *Codegen, a: ast.Attribute, args: []const ast.Expr, ch_val: Value) CodegenError!Value {
        if (std.mem.eql(u8, a.attr, "send")) {
            if (args.len != 1) return error.Unsupported;
            const v = try self.genExpr(args[0]);
            const converted = try self.convert(v, ch_val.elem_qtype);
            const payload = try self.toPayload(converted);
            const fn_name = if (ch_val.elem_is_str) "nox_threadchannel_send_str" else "nox_threadchannel_send_val";
            try self.out.writer.print("    call ${s}(l {s}, l {s}, l {s})\n", .{ fn_name, RT_PARAM, ch_val.text, payload.text });
            return .{ .text = "0", .qtype = .none };
        }
        if (std.mem.eql(u8, a.attr, "recv")) {
            if (args.len != 0) return error.Unsupported;
            const fn_name = if (ch_val.elem_is_str) "nox_threadchannel_recv_str" else "nox_threadchannel_recv_val";
            const payload_t = try self.newTemp();
            try self.out.writer.print("    {s} =l call ${s}(l {s}, l {s})\n", .{ payload_t, fn_name, RT_PARAM, ch_val.text });
            const converted = try self.fromPayload(.{ .text = payload_t, .qtype = .l }, ch_val.elem_qtype);
            return valueFromElemDescriptor(converted.text, converted.qtype, ch_val.elem_heap_info, ch_val.elem_is_str);
        }
        return error.Unsupported;
    }

    /// `Channel[T](capacity)`/`ThreadChannel[T](capacity)` — dilde başka
    /// HİÇBİR yerde olmayan, AÇIK tip argümanlı bir kurucu çağrısı (bkz.
    /// `ast.GenericConstruct`in ve `parser.zig`, `isGenericConstructName`in
    /// belge notu).
    fn genGenericConstruct(self: *Codegen, g: ast.GenericConstruct) CodegenError!Value {
        const is_thread_channel = std.mem.eql(u8, g.name, "ThreadChannel");
        if (!(is_thread_channel or std.mem.eql(u8, g.name, "Channel")) or g.type_args.len != 1 or g.args.len != 1) return error.Unsupported;
        const elem = try self.resolveType(g.type_args[0]);
        const cap_val = try self.genExpr(g.args[0]);
        const ch_t = try self.newTemp();
        const new_fn_name = if (is_thread_channel) "nox_threadchannel_new" else "nox_channel_new";
        try self.out.writer.print("    {s} =l call ${s}(l {s}, l {s})\n", .{ ch_t, new_fn_name, RT_PARAM, cap_val.text });

        var elem_heap_info: ?*const ElemHeapInfo = null;
        if (elem.heap == .class or elem.heap == .list) {
            const info = try self.allocator.create(ElemHeapInfo);
            info.* = .{ .heap = elem.heap, .class_name = elem.class_name, .elem_qtype = elem.elem_qtype, .nested = elem.elem_heap_info, .elem_is_str = elem.elem_is_str };
            elem_heap_info = info;
        }
        return .{
            .text = ch_t,
            .qtype = .l,
            .heap = if (is_thread_channel) .thread_channel else .channel,
            .elem_qtype = elem.qtype,
            .elem_heap_info = elem_heap_info,
            .elem_is_str = elem.heap == .str,
        };
    }

    /// Bir kullanıcı fonksiyonu/metodu/kurucu çağrısından hemen sonra çağrılır.
    /// QBE hiçbir zaman unwind tablosu üretmez (İlke #3); bunun yerine bekleyen
    /// bir istisna olup olmadığı burada AÇIKÇA kontrol edilir — Zig'in error
    /// union'larına benzer örtük bir hata-döndürme zinciri. İçinde bulunulan
    /// bir `try` varsa (`current_catch_label`) oraya, yoksa doğrudan bu
    /// fonksiyonun erken (temizlenmiş) çıkışına dallanır.
    fn emitExceptionCheck(self: *Codegen) CodegenError!void {
        const pending = try self.newTemp();
        try self.out.writer.print("    {s} =w call $nox_exception_pending(l {s})\n", .{ pending, RT_PARAM });
        const propagate_label = try self.newLabel("exc_propagate");
        const continue_label = try self.newLabel("exc_continue");
        try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ pending, propagate_label, continue_label });
        try self.out.writer.print("{s}\n", .{propagate_label});
        if (self.current_catch_label) |cl| {
            // Bu `try`nin kendi dispatch'ine giriyoruz — henüz onun korumalı
            // bölgesinden ÇIKMIYORUZ, bu yüzden `finally` burada DEĞİL,
            // dispatch'in kendi tamamlanma/yeniden-fırlatma yollarında çalışır.
            try self.out.writer.print("    jmp {s}\n", .{cl});
        } else if (self.in_main) {
            // Gerçekten dışarı sızıyoruz: aradan geçtiğimiz her `try`nin
            // `finally`'si ve her `lowlevel` arenası burada, program
            // sonlanmadan ÖNCE çalışmalıdır/yıkılmalıdır.
            try self.drainFinally(self.current_ret_qtype);
            try self.drainArenas();
            // `nox_unhandled_exception` `noreturn`dur (process.exit çağırır),
            // ama QBE bunu bilmez — bloğun bir sonlandırıcıyla bitmesi için
            // savunmacı (asla çalışmayacak) bir `ret` gerekir.
            try self.out.writer.print("    call $nox_unhandled_exception(l {s})\n", .{RT_PARAM});
            try self.out.writer.writeAll("    ret 0\n");
        } else {
            try self.drainFinally(self.current_ret_qtype);
            try self.drainArenas();
            try self.releaseAllLocals();
            try self.emitDefaultReturn(self.current_ret_qtype);
        }
        try self.out.writer.print("{s}\n", .{continue_label});
    }
};

/// `module`'ü QBE IL metnine çevirir. Girdinin Faz 2 tip denetiminden geçmiş
/// olması önkoşuldur. Desteklenmeyen bir yapı bulunursa (bkz. modül üstü
/// belge notu) `error.Unsupported` döner.
/// `extra_functions`: Faz 10'un checker tarafından üretilen somut
/// (monomorphize edilmiş) generic fonksiyon örneklemeleri (generics
/// kullanılmıyorsa `&.{}`) — sıradan, generic olmayan fonksiyonlar gibi
/// derlenir (bkz. modül üstü not).
/// `generic_template_names`: `module.body`de kalan (asla doğrudan
/// derlenmeyen) generic fonksiyon ŞABLONLARININ adları — `checker.Checker`in
/// `generic_functions` haritasının anahtarları. Bunun ayrıca gerekmesinin
/// nedeni: bir fonksiyon yalnızca bir PROTOKOL parametresi (Faz 11) yoluyla
/// örtük olarak generic olabilir — bu durumda ORİJİNAL AST düğümünün
/// `type_params` alanı BOŞ kalır (kullanıcı hiç `[T]` yazmadı), bu yüzden
/// yalnızca `type_params.len > 0` kontrolü YETERSİZDİR.
/// `debug_source_path`: Faz T.3, `null` DIŞINDA VERİLİRSE (bkz. modül üstü
/// not) `dbgfile`/`dbgloc` yönergeleri yayınlanır — `null` İKEN çıktı
/// ÖNCEKİYLE BİREBİR AYNI kalır (opt-in, sıfır davranış değişikliği).
pub fn generateModule(allocator: std.mem.Allocator, module: ast.Module, extra_functions: []const ast.FuncDef, generic_template_names: []const []const u8, debug_source_path: ?[]const u8, closure_infos: std.StringHashMapUnmanaged([]const []const u8)) CodegenError![]u8 {
    var gen: Codegen = .{ .allocator = allocator, .out = .init(allocator), .closure_infos = closure_infos };

    if (debug_source_path) |path| {
        gen.debug_info = true;
        const escaped = try escapeForQbeString(allocator, path);
        try gen.out.writer.print("dbgfile \"{s}\"\n", .{escaped});
    }

    try gen.out.writer.writeAll(
        \\data $fmt_int = { b "%lld\n", b 0 }
        \\data $fmt_float = { b "%g\n", b 0 }
        \\data $fmt_str = { b "%s\n", b 0 }
        \\data $fmt_bool_true = { b "True\n", b 0 }
        \\data $fmt_bool_false = { b "False\n", b 0 }
        \\data $fmt_newline = { b "\n", b 0 }
        \\data $fmt_int_frag = { b "%lld", b 0 }
        \\data $fmt_float_frag = { b "%g", b 0 }
        \\data $fmt_str_frag = { b "'%s'", b 0 }
        \\data $fmt_bool_true_frag = { b "True", b 0 }
        \\data $fmt_bool_false_frag = { b "False", b 0 }
        \\data $fmt_lbracket = { b "[", b 0 }
        \\data $fmt_rbracket = { b "]", b 0 }
        \\data $fmt_rparen = { b ")", b 0 }
        \\data $fmt_comma_sp = { b ", ", b 0 }
        \\
    );

    // Stdlib fazı §L: kendi kendine başvuran (self-referential) bir sınıf
    // alanı (`class JsonValue: arr: list[JsonValue]`) `resolveType`in
    // `.generic`→`list`→`.simple` yolunda `self.classes.contains(name)`e
    // BAKAR — ama `registerClass` (aşağıdaki asıl döngü) HER sınıfı
    // TAMAMEN işleyip (alan tiplerini ÇÖZÜP) EN SONUNDA `self.classes.put`
    // yapıyordu, bu yüzden bir sınıf KENDİ alan tipini çözerken KENDİ ADI
    // HENÜZ `self.classes`da YOKTU (`error.Unsupported`). checker.zig BUNU
    // ZATEN `collectClassNames`→`registerSignatures` İKİ GEÇİŞLİ deseniyle
    // çözmüştü (bkz. onun belge notu) — codegen'İN AYNI iki geçişten YOKSUN
    // olması, `nox.json`nin `JsonValue` sınıfı YAZILANA kadar HİÇ test
    // EDİLMEMİŞ bir kod yoluydu (bkz. plan dosyasının "doğrulanmamış
    // varsayım" notu). Düzeltme: TÜM sınıf adlarını (alanları ÇÖZÜLMEDEN
    // ÖNCE) BOŞ bir yer tutucuyla `self.classes`a ÖNCEDEN ekle —
    // `resolveType` yalnızca `.contains` sorar (haritanın DEĞERİNE hiç
    // bakmaz), asıl `registerClass` çağrısı SONRA gerçek `ClassInfo`yla
    // ÜZERİNE YAZAR.
    for (module.body) |stmt| {
        if (stmt.kind == .class_def) try gen.classes.put(gen.allocator, stmt.kind.class_def.name, .{});
    }
    for (module.body) |stmt| {
        if (stmt.kind == .class_def) try gen.registerClass(stmt.kind.class_def);
    }
    for (module.body) |stmt| {
        if (stmt.kind == .extern_def) try gen.registerExternFunc(stmt.kind.extern_def);
    }
    // Faz 10/11: `module.body`'deki generic fonksiyon ŞABLONLARI (açık
    // `[T]` VEYA protokol parametresi yoluyla örtük) hiçbir zaman doğrudan
    // derlenmez (tip parametreleri/protokol adları QBE'nin bilmediği
    // isimlerdir) — yalnızca checker'ın ürettiği somut örneklemeler
    // (`extra_functions`) derlenir.
    for (module.body) |stmt| {
        if (stmt.kind == .func_def and stmt.kind.func_def.type_params.len == 0 and !containsName(generic_template_names, stmt.kind.func_def.name)) {
            try gen.registerFunc(stmt.kind.func_def);
        }
    }
    for (extra_functions) |fd| try gen.registerFunc(fd);

    // Performans fazı: HANGİ serbest fonksiyon/kurucuların (transitif
    // olarak) ASLA istisna fırlatamayacağı kanıtlanabiliyorsa `genCall`/
    // `genConstruct`in çağrı-sonrası `emitExceptionCheck`i atlayabilmesi
    // için — bkz. `computeMustNotRaise`in belge notu. `self.classes`/
    // `self.functions` (yukarıdaki register* döngüleri) DOLU olmalı.
    try gen.computeMustNotRaise(module, extra_functions);

    // Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): `computeMustNotRaise`DEN
    // SONRA (bağımlılık — bkz. `isFuncInlineEligible`) VE HERHANGİ bir gövde
    // codegen'İNDEN ÖNCE (`genMethod`/`genFunction`/`genMain`/`genMainAsync`
    // İçin AŞAĞIDAKİ döngüler `self.inlinable_funcs`e İHTİYAÇ DUYAR).
    try gen.computeInlinableFunctions(module, extra_functions, generic_template_names);

    // Faz S.3: `$nox_trace_dispatch`/`$nox_gc_free_dispatch`in (bkz.
    // `genTraceDispatch`) hangi (`class_id`, isim) çiftlerine dal açacağını
    // bilmesi İÇİN — sınıf İÇEREN HER programda üretilir (bkz. onların
    // belge notu, `runtime/alloc/cycle_detector.zig`nin `dlsym` gerekçesiyle
    // TUTARLI: sınıfSIZ bir programda BU semboller HİÇ üretilmez).
    var class_ids: std.ArrayListUnmanaged(ClassIdEntry) = .empty;
    defer class_ids.deinit(allocator);
    for (module.body) |stmt| {
        if (stmt.kind == .class_def) {
            const cd = stmt.kind.class_def;
            for (cd.methods) |m| try gen.genMethod(cd.name, m);
            const cinfo = gen.classes.get(cd.name).?;
            try gen.genClassRelease(cd.name, cinfo);
            try gen.genClassEq(cd.name, cinfo);
            try gen.genClassTrace(cd.name, cinfo);
            try gen.genClassGcFree(cd.name, cinfo);
            try class_ids.append(allocator, .{ .name = cd.name, .id = cinfo.class_id });
        }
    }
    if (class_ids.items.len > 0) {
        try gen.genTraceDispatch(class_ids.items);
        try gen.genGcFreeDispatch(class_ids.items);
    }
    for (module.body) |stmt| {
        if (stmt.kind == .func_def and stmt.kind.func_def.type_params.len == 0 and !containsName(generic_template_names, stmt.kind.func_def.name)) {
            try gen.genFunction(stmt.kind.func_def);
        }
    }
    for (extra_functions) |fd| try gen.genFunction(fd);

    var loose: std.ArrayListUnmanaged(ast.Stmt) = .empty;
    defer loose.deinit(allocator);
    for (module.body) |stmt| {
        switch (stmt.kind) {
            .func_def, .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt => {},
            else => try loose.append(allocator, stmt),
        }
    }
    // Faz 21 aşama 4: modül HERHANGİ bir async özelliği (async def/spawn/
    // await/Channel) kullanıyorsa `main`, üst düzey kodu bir fiber olarak
    // çalıştıran fiber-sarmalı bir kökle üretilir; kullanmıyorsa (büyük
    // çoğunluk) `genMain` DEĞİŞMEDEN, sıfır ek maliyetle çalışır.
    const use_async = moduleUsesAsync(module, extra_functions);
    try gen.genMain(loose.items, use_async);

    // `list[T]`nin elemanları heap-yönetimliyken (sınıf/iç içe liste) gereken
    // `$List_<...>_release` fonksiyonları — `string_data` gibi TEMBEL keşfedilir
    // (herhangi bir `resolveType`/`genListLit`/`releaseValueIfSet` çağrısı
    // sırasında). Bir kuyruk kullanılır çünkü BİR fonksiyonu üretmek (iç içe
    // liste durumunda) YENİ bir ihtiyacı keşfedebilir — `while` bunu geçişli
    // olarak TÜKETENE kadar döner.
    while (gen.list_release_queue.pop()) |item| {
        try gen.genListElemRelease(item.name, item.info);
    }

    // list[T] için derin yapısal eşitlik (bkz. görev "list/class için derin
    // yapısal eşitlik") — `list_release_queue` ile AYNI "sonda tüket" deseni
    // (bir `$List_..._eq`i üretmek İÇ İÇE bir liste durumunda YENİ bir
    // ihtiyacı keşfedebilir, bkz. `eqFnNameForList`/`eqMangleFor`).
    while (gen.list_eq_queue.pop()) |item| {
        try gen.genListEq(item.name, item.elem_qtype, item.elem_heap_info, item.elem_is_str);
    }

    // Faz U.4.3: her iç içe `def` deyimi için TEMBEL kaydedilen closure
    // gövdeleri (bkz. `ClosureFuncSpec`in belge notu) — AYNI "sonda tüket"
    // deseni; `while` KULLANILIR çünkü bir closure'ın GÖVDESİ BAŞKA bir
    // iç içe `def` İÇEREBİLİR (rastgele derinlik, bkz. `genClosureFunc`in
    // `self.current_path` güncellemesi).
    while (gen.closure_funcs.pop()) |spec| {
        try gen.genClosureFunc(spec);
    }

    // Faz 21 aşama 4: her `spawn` çağrı sitesi için TEMBEL kaydedilen
    // sarmalayıcı fonksiyonlar (bkz. `SpawnWrapperSpec`in belge notu) —
    // AYNI "sonda tüket" deseni.
    while (gen.spawn_wrappers.pop()) |spec| {
        try gen.genSpawnWrapper(spec);
    }

    // stdlib fazı §D.1.6: her `nox.http.serve` çağrı sitesi için TEMBEL
    // kaydedilen sarmalayıcı fonksiyonlar (bkz. `HttpServeWrapperSpec`in
    // belge notu) — AYNI "sonda tüket" deseni.
    while (gen.http_serve_wrappers.pop()) |spec| {
        try gen.genHttpServeWrapper(spec);
    }

    // Faz BB.4: her `nox.thread.start` çağrı sitesi için TEMBEL kaydedilen
    // sarmalayıcı fonksiyonlar (bkz. `ThreadWrapperSpec`in belge notu) —
    // AYNI "sonda tüket" deseni.
    while (gen.thread_wrappers.pop()) |spec| {
        try gen.genThreadStartWrapper(spec);
    }

    // Faz DD.1: her `nox.http.serve_multicore` çağrı sitesi için TEMBEL
    // kaydedilen worker fonksiyonları (bkz. `HttpServeMulticoreWorkerSpec`in
    // belge notu) — AYNI "sonda tüket" deseni.
    while (gen.http_serve_multicore_workers.pop()) |spec| {
        try gen.genHttpServeMulticoreWorker(spec);
    }

    for (gen.string_data.items) |sd| {
        // `l 1073741824` (1<<30): HPy'nin `PINNED_REFCOUNT`iyle (bkz.
        // runtime/hpy_bridge/context.zig) AYNI "pinned" refcount hilesi —
        // string literalinin görünmez ARC başlığı, hiçbir gerçekçi
        // retain/release dizisinin sıfıra indiremeyeceği kadar büyük bir
        // değerle başlar, bu yüzden `nox_rc_release` bu statik belleği asla
        // gerçekten serbest bırakmaya çalışmaz (bkz. `.string_lit` kolu).
        try gen.out.writer.print("data {s} = {{ l 1073741824, b \"{s}\", b 0 }}\n", .{ sd.symbol, sd.escaped });
    }

    // `print(list[T]/sınıf)` görüntülemesinin (bkz. `internFmtString`)
    // sınıf/alan adı fragmanları — `string_data`nın AKSİNE pinned-refcount
    // başlığı OLMADAN, düz birer `printf` format dizesi olarak yayılır.
    for (gen.fmt_data.items) |fd| {
        try gen.out.writer.print("data {s} = {{ b \"{s}\", b 0 }}\n", .{ fd.symbol, fd.escaped });
    }

    return gen.out.toOwnedSlice();
}
