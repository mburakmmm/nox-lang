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
const types = @import("types.zig");
const abi = @import("abi.zig");
const async_thread_mod = @import("async_thread.zig");
const optimizations = @import("optimizations.zig");
const http_intrinsics = @import("http_intrinsics.zig");
const inlining = @import("inlining.zig");
const closures = @import("closures.zig");
const layout = @import("layout.zig");
const ownership = @import("ownership.zig");
const exceptions = @import("exceptions.zig");
const calls = @import("calls.zig");
const expr_mod = @import("expr.zig");
const stmt_mod = @import("stmt.zig");
const registration = @import("registration.zig");

pub const CodegenError = abi.CodegenError;

const QbeType = types.QbeType;
const HeapKind = types.HeapKind;
const CLOSURE_HEADER_SIZE = types.CLOSURE_HEADER_SIZE;
const PINNED_REFCOUNT = types.PINNED_REFCOUNT;
const ElemHeapInfo = types.ElemHeapInfo;
const DictInfo = types.DictInfo;
const FuncSigInfo = types.FuncSigInfo;
const TypeInfo = types.TypeInfo;
const Value = types.Value;
const FuncSig = types.FuncSig;
const UsedRequestFields = types.UsedRequestFields;
const HttpServeWrapperSpec = types.HttpServeWrapperSpec;
const SpawnWrapperSpec = types.SpawnWrapperSpec;
const ThreadWrapperSpec = types.ThreadWrapperSpec;
const HttpServeMulticoreWorkerSpec = types.HttpServeMulticoreWorkerSpec;
const ClosureCaptureField = types.ClosureCaptureField;
const ClosureFuncSpec = types.ClosureFuncSpec;
const VarInfo = types.VarInfo;
const LocalDecl = types.LocalDecl;
const StringDatum = types.StringDatum;
const ModCacheEntry = types.ModCacheEntry;
const ClassField = types.ClassField;
const ClassIdEntry = types.ClassIdEntry;
const ClassInfo = types.ClassInfo;
const RT_PARAM = types.RT_PARAM;
const FIELD_SLOT_SIZE = types.FIELD_SLOT_SIZE;
const LIST_HEADER_SIZE = types.LIST_HEADER_SIZE;
const TAG_SIZE = types.TAG_SIZE;

const sanitizePathToSymbol = abi.sanitizePathToSymbol;
const qbeTypeName = abi.qbeTypeName;
const qbeSizeOf = abi.qbeSizeOf;
const valueFromElemDescriptor = abi.valueFromElemDescriptor;
const cmpMnemonic = abi.cmpMnemonic;
const escapeForQbeString = abi.escapeForQbeString;
const forListIdxName = abi.forListIdxName;
const isHeapManaged = abi.isHeapManaged;
const isTemporaryExpr = abi.isTemporaryExpr;
const containsName = abi.containsName;

const moduleUsesAsync = async_thread_mod.moduleUsesAsync;
const stmtUsesAsync = async_thread_mod.stmtUsesAsync;
const exprUsesAsync = async_thread_mod.exprUsesAsync;

const BoundsElideCtx = optimizations.BoundsElideCtx;
const StrLenCacheScope = optimizations.StrLenCacheScope;
const collectReassignedNames = optimizations.collectReassignedNames;
const bodyHasNestedFuncDef = optimizations.bodyHasNestedFuncDef;
const modCacheKey = optimizations.modCacheKey;

const NamedSlot = inlining.NamedSlot;
const InlineSiteInfo = inlining.InlineSiteInfo;
const InlineReturnTarget = inlining.InlineReturnTarget;

pub const Codegen = struct {
    pub const isFuncInlineEligible = inlining.isFuncInlineEligible;
    pub const computeInlinableFunctions = inlining.computeInlinableFunctions;
    pub const registerInlineSite = inlining.registerInlineSite;
    pub const collectInlineSitesStmts = inlining.collectInlineSitesStmts;
    pub const collectInlineSitesStmt = inlining.collectInlineSitesStmt;
    pub const collectInlineSitesExpr = inlining.collectInlineSitesExpr;
    pub const prepareInlineSites = inlining.prepareInlineSites;
    pub const genInlinedCall = inlining.genInlinedCall;

    pub const buildClosureValue = closures.buildClosureValue;
    pub const genNestedFuncDef = closures.genNestedFuncDef;
    pub const genDeferStmt = closures.genDeferStmt;
    pub const setupDeferListIfNeeded = closures.setupDeferListIfNeeded;
    pub const drainDeferIfSet = closures.drainDeferIfSet;
    pub const genClosureFunc = closures.genClosureFunc;
    pub const genClosureRelease = closures.genClosureRelease;
    pub const genFunctionValueTrampoline = closures.genFunctionValueTrampoline;

    pub const genClassRelease = layout.genClassRelease;
    pub const genClassTrace = layout.genClassTrace;
    pub const genClassGcFree = layout.genClassGcFree;
    pub const genTraceDispatch = layout.genTraceDispatch;
    pub const genGcFreeDispatch = layout.genGcFreeDispatch;
    pub const genClassEq = layout.genClassEq;
    pub const genEqCompareOrJump = layout.genEqCompareOrJump;
    pub const eqMangleFor = layout.eqMangleFor;
    pub const eqFnNameForList = layout.eqFnNameForList;
    pub const genListEq = layout.genListEq;

    pub const releaseAllLocals = ownership.releaseAllLocals;
    pub const releaseAllLocalsExcept = ownership.releaseAllLocalsExcept;
    pub const releaseOneLocalIfManaged = ownership.releaseOneLocalIfManaged;
    pub const releaseNamedLocalsExcept = ownership.releaseNamedLocalsExcept;
    pub const listPayloadSize = ownership.listPayloadSize;
    pub const releaseFnNameFor = ownership.releaseFnNameFor;
    pub const genListElemRelease = ownership.genListElemRelease;
    pub const releaseValueIfSet = ownership.releaseValueIfSet;
    pub const releaseSlotIfSet = ownership.releaseSlotIfSet;
    pub const destroyNonArcValue = ownership.destroyNonArcValue;
    pub const destroyNonArcSlotIfSet = ownership.destroyNonArcSlotIfSet;
    pub const emitDefaultReturn = ownership.emitDefaultReturn;
    pub const checkNoLowlevelEscape = ownership.checkNoLowlevelEscape;
    pub const emitInlineRetain = ownership.emitInlineRetain;
    pub const emitInlinePredecrement = ownership.emitInlinePredecrement;
    pub const emitListElemRetainLoop = ownership.emitListElemRetainLoop;
    pub const emitListElemPlainDecrementLoop = ownership.emitListElemPlainDecrementLoop;
    pub const retainIfAliasing = ownership.retainIfAliasing;
    pub const returnNeedsRetain = ownership.returnNeedsRetain;

    pub const genRaise = exceptions.genRaise;
    pub const drainFinally = exceptions.drainFinally;
    pub const drainArenas = exceptions.drainArenas;
    pub const runDetachedFinally = exceptions.runDetachedFinally;
    pub const genTry = exceptions.genTry;
    pub const genWith = exceptions.genWith;
    pub const buildMethodCallExpr = exceptions.buildMethodCallExpr;
    pub const declareVarType = exceptions.declareVarType;
    pub const collectRaiseInfoStmts = exceptions.collectRaiseInfoStmts;
    pub const collectRaiseInfoStmt = exceptions.collectRaiseInfoStmt;
    pub const collectRaiseInfoExpr = exceptions.collectRaiseInfoExpr;
    pub const buildParamVarTypes = exceptions.buildParamVarTypes;
    pub const buildParamListElemTypes = exceptions.buildParamListElemTypes;
    pub const buildFuncSafetyInfoMap = exceptions.buildFuncSafetyInfoMap;
    pub const computeMustNotRaise = exceptions.computeMustNotRaise;
    pub const dfsMarkRecursive = exceptions.dfsMarkRecursive;
    pub const markRecursiveFuncs = exceptions.markRecursiveFuncs;

    pub const genCall = calls.genCall;
    pub const genParseOrRaise = calls.genParseOrRaise;
    pub const releaseTemporaryArgs = calls.releaseTemporaryArgs;
    pub const releaseIfTemporary = calls.releaseIfTemporary;
    pub const currentArena = calls.currentArena;
    pub const genConstruct = calls.genConstruct;
    pub const genConstructFromValues = calls.genConstructFromValues;
    pub const genMethodCall = calls.genMethodCall;
    pub const genIndirectCallThroughClosurePtr = calls.genIndirectCallThroughClosurePtr;
    pub const genDictMethod = calls.genDictMethod;
    pub const genListAppend = calls.genListAppend;
    pub const genListSort = calls.genListSort;
    pub const genGenericConstruct = calls.genGenericConstruct;

    pub const genExprForTarget = expr_mod.genExprForTarget;
    pub const boxScalar = expr_mod.boxScalar;
    pub const convert = expr_mod.convert;
    pub const toPayload = expr_mod.toPayload;
    pub const fromPayload = expr_mod.fromPayload;
    pub const emitStringLiteral = expr_mod.emitStringLiteral;
    pub const genExpr = expr_mod.genExpr;
    pub const genFieldRead = expr_mod.genFieldRead;
    pub const genFieldReadFromValue = expr_mod.genFieldReadFromValue;
    pub const boundsElideApplies = expr_mod.boundsElideApplies;
    pub const genIndex = expr_mod.genIndex;
    pub const buildFunctionValueForIdentifier = expr_mod.buildFunctionValueForIdentifier;
    pub const genStrIndex = expr_mod.genStrIndex;
    pub const genListLit = expr_mod.genListLit;
    pub const genDictLit = expr_mod.genDictLit;
    pub const genUnary = expr_mod.genUnary;
    pub const emitBin = expr_mod.emitBin;
    pub const emitCmp = expr_mod.emitCmp;
    pub const callLibm1 = expr_mod.callLibm1;
    pub const callLibm2 = expr_mod.callLibm2;
    pub const genStrCompare = expr_mod.genStrCompare;
    pub const genBinary = expr_mod.genBinary;
    pub const genFloorDiv = expr_mod.genFloorDiv;
    pub const genPow = expr_mod.genPow;
    pub const genPrint = expr_mod.genPrint;
    pub const genPrintFragment = expr_mod.genPrintFragment;
    pub const internFmtString = expr_mod.internFmtString;
    pub const genPrintList = expr_mod.genPrintList;
    pub const genPrintClass = expr_mod.genPrintClass;

    pub const emitExceptionCheck = exceptions.emitExceptionCheck;

    pub const genStmts = stmt_mod.genStmts;
    pub const genLowLevel = stmt_mod.genLowLevel;
    pub const genAssign = stmt_mod.genAssign;
    pub const genListAssign = stmt_mod.genListAssign;
    pub const genDictAssign = stmt_mod.genDictAssign;
    pub const genDictGet = stmt_mod.genDictGet;
    pub const detectNarrowedBoxedName = stmt_mod.detectNarrowedBoxedName;
    pub const genIf = stmt_mod.genIf;
    pub const collectIndexStrBasesExpr = stmt_mod.collectIndexStrBasesExpr;
    pub const collectIndexStrBasesStmts = stmt_mod.collectIndexStrBasesStmts;
    pub const genWhile = stmt_mod.genWhile;
    pub const isRangeCall = stmt_mod.isRangeCall;
    pub const findLocal = stmt_mod.findLocal;
    pub const genFor = stmt_mod.genFor;
    pub const genForRange = stmt_mod.genForRange;
    pub const genForList = stmt_mod.genForList;

    pub const newTemp = registration.newTemp;
    pub const newLabel = registration.newLabel;
    pub const resolveType = registration.resolveType;
    pub const registerClass = registration.registerClass;
    pub const inferFieldType = registration.inferFieldType;
    pub const registerFunc = registration.registerFunc;
    pub const registerExternFunc = registration.registerExternFunc;
    pub const collectLocals = registration.collectLocals;
    pub const inferWithCtxClassName = registration.inferWithCtxClassName;
    pub const allocSlot = registration.allocSlot;
    pub const allocInlineSlot = registration.allocInlineSlot;
    pub const genFunction = registration.genFunction;
    pub const genMethod = registration.genMethod;
    pub const genMain = registration.genMain;
    pub const genMainAsync = registration.genMainAsync;

    pub const collectLoopInvariantStrBases = optimizations.collectLoopInvariantStrBases;
    pub const detectWhileBoundsElideCtx = optimizations.detectWhileBoundsElideCtx;
    pub const enterStrLenCacheScope = optimizations.enterStrLenCacheScope;
    pub const exitStrLenCacheScope = optimizations.exitStrLenCacheScope;
    pub const enterModCacheLoopScope = optimizations.enterModCacheLoopScope;
    pub const detectBoundsElideCtx = optimizations.detectBoundsElideCtx;
    pub const modCacheInvalidateSlot = optimizations.modCacheInvalidateSlot;
    pub const modCacheInvalidateName = optimizations.modCacheInvalidateName;
    pub const snapshotModCache = optimizations.snapshotModCache;
    pub const restoreModCache = optimizations.restoreModCache;
    pub const copyModCacheAlias = optimizations.copyModCacheAlias;
    pub const genMod = optimizations.genMod;
    pub const adjustModSign = optimizations.adjustModSign;

    pub const computeUsedFieldsFor = http_intrinsics.computeUsedFieldsFor;
    pub const genHttpServe = http_intrinsics.genHttpServe;
    pub const emitFdServeTail = http_intrinsics.emitFdServeTail;
    pub const genHttpServeFd = http_intrinsics.genHttpServeFd;
    pub const genHttpServeMulticore = http_intrinsics.genHttpServeMulticore;
    pub const genHttpServeMulticoreWorker = http_intrinsics.genHttpServeMulticoreWorker;
    pub const genHttpServeWrapper = http_intrinsics.genHttpServeWrapper;

    pub const genSpawnExpr = async_thread_mod.genSpawnExpr;
    pub const genSpawnWrapper = async_thread_mod.genSpawnWrapper;
    pub const genThreadStartExpr = async_thread_mod.genThreadStartExpr;
    pub const genThreadStartWrapper = async_thread_mod.genThreadStartWrapper;
    pub const genThreadHandleJoin = async_thread_mod.genThreadHandleJoin;
    pub const genAwaitExpr = async_thread_mod.genAwaitExpr;
    pub const genChannelOp = async_thread_mod.genChannelOp;
    pub const genThreadChannelOp = async_thread_mod.genThreadChannelOp;

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
    /// Faz HH.4 (bkz. nox-teknik-spesifikasyon.md §3.68): `functions`
    /// (İMZA-YALNIZCA) İLE AYNI anda, AYNI isimlerle doldurulur — ama TAM
    /// `ast.FuncDef`i (gövdesi DAHİL) saklar. `genHttpServe`nin `handle`
    /// fonksiyonunun GÖVDESİNİ (hangi `HttpRequest` alanlarının GERÇEKTEN
    /// okunduğunu tespit etmek İçin) bulabilmesi İÇİN eklendi — `self.
    /// inlinable_funcs`in (yalnızca GG.2'nin inline UYGUN BULDUĞU bir ALT
    /// KÜME) AKSİNE, BURADA TÜM serbest fonksiyonlar saklanır.
    func_defs: std.StringHashMapUnmanaged(ast.FuncDef) = .empty,
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
    /// Bulundu (bkz. proje belleği "UTF-8 farkındalığı" görevi): `s[i]`
    /// ARTIK codepoint-tabanlı (`nox_str_char_at`, `Utf8View` İLE O(i)
    /// yürür) — GERÇEK ölçümle bir benchmark'ın (`str_index_loop_licm.nox`,
    /// tamamen ASCII, sıralı erişim) ~30 saniyeye çıktığı görüldü (ÖNCEDEN
    /// O(1) bayt erişimiydi). `str_len_cache`İLE AYNI YAŞAM DÖNGÜSÜ
    /// (`enterStrLenCacheScope`/`exitStrLenCacheScope`, AYNI `added_names`)
    /// — döngüye girmeden HEMEN ÖNCE, döngü-değişmez bir `str` tabanının
    /// TAMAMEN ASCII olup OLMADIĞI BİR KEZ hesaplanır (isim → 0/1'lik QBE
    /// temp'i). `genStrIndex`, bu önbellek DOLUYSA (yani `str_len_cache`
    /// GİBİ hoisted bir döngü bağlamındaysa) çalışma-zamanı bir dal İLE:
    /// ASCII İSE ESKİ O(1) HAM bayt erişimini İNLINE eder (perf regresyonu
    /// YOK), DEĞİLSE doğru ama YAVAŞ `nox_str_char_at`e düşer.
    str_ascii_cache: std.StringHashMapUnmanaged([]const u8) = .empty,
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
    /// Darboğaz analizi bulgu #3 (bkz. benchmarks/RESULTS.md, 2026-07-22):
    /// `<isim> % <tam-sayı-sabiti>` biçimindeki SAF alt-ifadelerin ORTAK-alt-
    /// ifade eliminasyonu (CSE) önbelleği — anahtar `"<slot>#<bölen>"`
    /// (İSİM DEĞİL, `VarInfo.slot` — bkz. AŞAĞIDAKİ "neden slot" notu),
    /// değer o hesaplamanın SONUCUNU tutan QBE geçici (temp) adı + qtype.
    ///
    /// **Neden isim değil slot?** `genInlinedCall`, callee'nin parametre/
    /// yerellerini `self.vars`ta AYNI isimle (ör. `pick(i: int)`nin `i`si,
    /// `string_passing.nox`daki ÇAĞRI sitesinin KENDİ `i`siyle TESADÜFEN
    /// AYNI isim) ama FARKLI bir slotla GÖLGELER (bkz. onun 2. adımı). İsimle
    /// anahtarlamak, callee İÇİNDEKİ "i" İLE caller'ın "i"sini YANLIŞLIKLA
    /// AYNI önbellek girdisine eşler (İKİSİ FARKLI DEĞİŞKENLERDİR) — bu YÜZDEN
    /// HER zaman `self.vars.get(name).?.slot` üzerinden anahtarlanır, bu
    /// GÖLGELEME sırasında OTOMATİK olarak DOĞRU (çakışmasız) ayrışır.
    ///
    /// **Dominance/SSA-uygunluk DİSİPLİNİ (bkz. AGENTS.md İlke #7 — HER
    /// optimizasyon KANITLANABİLİR güvenli OLMALI):** bir slot İçin BURADA
    /// tutulan bir QBE temp'i, YALNIZCA onu ÜRETEN talimatın, BU değerin
    /// OKUNDUĞU HER çalışma-zamanı yolunda GERÇEKTEN çalıştığı KANITLANABİLİRSE
    /// (dominance) güvenlidir. Bu DOSYADAKİ 4 dokunma noktası bunu SAĞLAR:
    /// (1) `genBinary`nin `.mod` dalı: SADECE POPÜLE eder/okur, hiçbir
    ///     dal-atlama YAPMAZ (aynı düz-akış içinde, sıradaki deyimler
    ///     KOŞULSUZ aynı talimatın ARDINDAN çalışır — bkz. modül üstü not,
    ///     "genStmts TEK özyinelemeli dağıtım noktası").
    /// (2) `genStmts`in `.assign`/`.var_decl` dalları: hedef isme YENİDEN
    ///     atama, o SLOT İçin ÖNCEKİ TÜM önbellek girdilerini GEÇERSİZ KILAR
    ///     (bkz. `modCacheInvalidateName`).
    /// (3) `genIf`: HER dalın (then/elif/else) gövdesi İşlenmeden ÖNCE
    ///     önbellek ANLIK GÖRÜNTÜSÜ (snapshot) alınır, gövde BİTTİKTEN SONRA
    ///     o GÖRÜNTÜYE GERİ YÜKLENİR — bir dalın KENDİ İÇİNDE hesapladığı
    ///     (veya geçersiz kıldığı) HİÇBİR ŞEY kardeş dallara/if SONRASINA
    ///     SIZMAZ (o dal ÇALIŞMAMIŞ OLABİLİR). Buna KARŞILIK `f.cond`/
    ///     `ec.cond`nin KENDİSİ ANLIK GÖRÜNTÜLENMEZ — bir if/elif zincirinde
    ///     HER koşul, ONA erişilen HER yolda KOŞULSUZ değerlendirilir (bir
    ///     SONRAKİ elif'e/else'e ULAŞMAK için ÖNCEKİ TÜM koşulların
    ///     değerlendirilmiş OLMASI GEREKİR) — bu YÜZDEN koşul-değerlendirmesi
    ///     if/elif zincirinin TAMAMI BOYUNCA GÜVENLE KALICIDIR (`pick`nin
    ///     `if i%3==0` VE `if i%3==1`nin İKİSİ de ÜST DÜZEY, bu YÜZDEN İKİNCİ
    ///     kontrol BİRİNCİNİN ÖNBELLEĞİNİ YENİDEN KULLANIR).
    /// (4) `genWhile`/`genForRange`/`genForList`: gövde İşlenmeden ÖNCE HEM
    ///     anlık görüntü alınır HEM DE gövde İÇİNDE (`collectReassignedNames`
    ///     ile) yeniden atanan HER isim (VE `for` döngülerinin KENDİ döngü
    ///     değişkeni — bu, `.assign` AST düğümünü BAYPAS EDEN DOĞRUDAN QBE
    ///     yayını İLE artırıldığından AYRICA) ÖNCEDEN geçersiz KILINIR — bir
    ///     döngüden ÖNCEKİ bayat bir değerin, gövdenin KENDİ yeniden-atamadan
    ///     ÖNCEKİ İLK kullanımında YANLIŞLIKLA yeniden kullanılıp SONRAKİ
    ///     yinelemelerde de (AYNI talimat TEKRAR çalıştığından) BAYAT KALMASINI
    ///     ÖNLER; gövde BİTTİĞİNDE (döngü SIFIR KEZ de çalışmış OLABİLECEĞİNDEN)
    ///     anlık görüntüye GERİ YÜKLENİR.
    /// (5) `genInlinedCall`: parametre slotlarına ARGÜMAN YAZILDIKTAN HEMEN
    ///     SONRA (bu yazma da BİR `.assign` AST düğümünü BAYPAS EDER) o
    ///     slotların önbellek girdileri GEÇERSİZ KILINIR — hem YİNELENEN
    ///     çağrılarda (ör. bir döngü İÇİNDE) BAYAT bir argüman değerinin
    ///     YENİDEN kullanılmasını, hem de callee'nin KENDİ üst-düzey
    ///     kodunun ÜRETTİĞİ (dominance-GÜVENLİ) bir girdinin, splice
    ///     BİTİMİNDEN SONRA `self.vars` ESKİ (caller'ın) eşlemesine geri
    ///     DÖNMESİNE RAĞMEN önbellekte KALMASI ZARARSIZDIR (slot ANAHTARI
    ///     SAYESİNDE caller'ın KENDİ, FARKLI slotlu değişkeniyle ASLA
    ///     ÇAKIŞMAZ) — bu, `compute`nin `pick(i)`nin İÇİNDE hesaplanan
    ///     `i%3`i, splice SONRASI KENDİ `if i%3==0` kontrolünde YENİDEN
    ///     KULLANMASINI SAĞLAYAN TAM OLARAK BUDUR (üç KEZ hesaplanan
    ///     `i%3`, BİR KEZE İNER).
    mod_cache: std.StringHashMapUnmanaged(ModCacheEntry) = .empty,
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
    /// `defer CALL` — checker'ın (`checkDeferStmt`) ÜRETTİĞİ sentetik closure
    /// adı, anahtar `@intFromPtr(d.call.callee)` (bkz. `ast.DeferStmt`nin
    /// belge notu — `Checker.defer_synthetic_names` İLE AYNI TİP/anahtar,
    /// DOĞRUDAN `main.zig` TARAFINDAN kopyalanmadan aktarılır).
    defer_synthetic_names: std.AutoHashMapUnmanaged(usize, []const u8) = .{},
    /// Bulundu (bkz. proje belleği "from-import class type annotations"
    /// görevi): `checker.zig`nin `Checker.from_imports`iyle AYNI TİP/anahtar
    /// (`from X import Y` İLE bağlanan ÇIPLAK yerel isim → mangled sembol
    /// adı) — DOĞRUDAN `main.zig` TARAFINDAN kopyalanmadan aktarılır
    /// (`closure_infos`/`defer_synthetic_names` İLE AYNI desen). Checker
    /// TİP ifadelerini (`ast.TypeExpr.simple`) kendi çözümlemesi İçin
    /// `from_imports`e BAKARAK çözer AMA AST düğümünü (`.simple = "Widget"`)
    /// YERİNDE MANGLED isme (`"helper_Widget"`) YENİDEN YAZMAZ (`ast.Call.
    /// callee: *Expr`nin AKSİNE, `ast.Param.type_expr`/`ast.VarDecl.
    /// type_expr` DÜZ DEĞER alanlarıdır — DeferStmt'in belge notundaki AYNI
    /// "değer olarak akar, in-place güncelleme codegen'e GÖRÜNMEZ" kısıtı) —
    /// bu YÜZDEN codegen'in KENDİ (bağımsız) `resolveType`i de AYNI haritaya
    /// İHTİYAÇ DUYAR (`registration.zig`nin `resolveType`inin `.simple`
    /// dalına bkz.).
    from_imports: std.StringHashMapUnmanaged([]const u8) = .{},
    /// Şu an derlenen fonksiyonun `defer`-yığını POINTER'ını TUTAN QBE geçici
    /// değişkenin adı (`fnBodyHasDefer` `true` DÖNDÜĞÜNDE ayarlanır, aksi
    /// halde `null`) — `current_ret_qtype` İLE AYNI "fonksiyon-başına durum"
    /// deseni (bkz. `genDeferStmt`/TÜM 5 çıkış noktası).
    current_defer_list: ?[]const u8 = null,
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
pub fn generateModule(allocator: std.mem.Allocator, module: ast.Module, extra_functions: []const ast.FuncDef, generic_template_names: []const []const u8, extra_classes: []const ast.ClassDef, generic_class_template_names: []const []const u8, debug_source_path: ?[]const u8, closure_infos: std.StringHashMapUnmanaged([]const []const u8), defer_synthetic_names: std.AutoHashMapUnmanaged(usize, []const u8), from_imports: std.StringHashMapUnmanaged([]const u8), functions_used_as_value: []const []const u8) CodegenError![]u8 {
    var gen: Codegen = .{ .allocator = allocator, .out = .init(allocator), .closure_infos = closure_infos, .defer_synthetic_names = defer_synthetic_names, .from_imports = from_imports };

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
    // Faz P2.1 (bkz. proje belleği "generic sınıflar" planı): `module.body`
    // İÇİNDEKİ generic sınıf ŞABLONLARI (func_def şablonlarıyla AYNI
    // gerekçe, hemen aşağıdaki döngü İLE TUTARLI) hiçbir zaman doğrudan
    // derlenmez — yalnızca checker'ın ürettiği somut örneklemeler
    // (`extra_classes`) derlenir.
    for (module.body) |stmt| {
        if (stmt.kind == .class_def and stmt.kind.class_def.type_params.len == 0 and !containsName(generic_class_template_names, stmt.kind.class_def.name)) {
            try gen.classes.put(gen.allocator, stmt.kind.class_def.name, .{});
        }
    }
    for (extra_classes) |cd| try gen.classes.put(gen.allocator, cd.name, .{});
    for (module.body) |stmt| {
        if (stmt.kind == .class_def and stmt.kind.class_def.type_params.len == 0 and !containsName(generic_class_template_names, stmt.kind.class_def.name)) {
            try gen.registerClass(stmt.kind.class_def);
        }
    }
    for (extra_classes) |cd| try gen.registerClass(cd);
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

    // Faz U.4.5 (bkz. `checker.zig`nin `functions_used_as_value`i VE
    // `genFunctionValueTrampoline`nin belge notu): `self.functions`in
    // TAMAMEN dolduğu (yukarıdaki `registerFunc` geçişleri) VE HERHANGİ
    // bir fonksiyon GÖVDESİ üretilmeden ÖNCEKİ TEK nokta — bu YÜZDEN
    // trampoline'lar BURADA üretilir (`.identifier` codegen'inin, bkz.
    // `expr.zig`, referans verdiği sembol HER ZAMAN ÖNCEDEN VAR olur).
    for (functions_used_as_value) |name| try gen.genFunctionValueTrampoline(name);

    // Performans fazı: HANGİ serbest fonksiyon/kurucuların (transitif
    // olarak) ASLA istisna fırlatamayacağı kanıtlanabiliyorsa `genCall`/
    // `genConstruct`in çağrı-sonrası `emitExceptionCheck`i atlayabilmesi
    // için — bkz. `computeMustNotRaise`in belge notu. `self.classes`/
    // `self.functions` (yukarıdaki register* döngüleri) DOLU olmalı.
    try gen.computeMustNotRaise(module, extra_functions, extra_classes);

    // Faz GG.2 (bkz. nox-teknik-spesifikasyon.md §3.67): `computeMustNotRaise`DEN
    // SONRA (bağımlılık — bkz. `isFuncInlineEligible`) VE HERHANGİ bir gövde
    // codegen'İNDEN ÖNCE (`genMethod`/`genFunction`/`genMain`/`genMainAsync`
    // İçin AŞAĞIDAKİ döngüler `self.inlinable_funcs`e İHTİYAÇ DUYAR).
    try gen.computeInlinableFunctions(module, extra_functions, generic_template_names, extra_classes);

    // Faz S.3: `$nox_trace_dispatch`/`$nox_gc_free_dispatch`in (bkz.
    // `genTraceDispatch`) hangi (`class_id`, isim) çiftlerine dal açacağını
    // bilmesi İÇİN — sınıf İÇEREN HER programda üretilir (bkz. onların
    // belge notu, `runtime/alloc/cycle_detector.zig`nin `dlsym` gerekçesiyle
    // TUTARLI: sınıfSIZ bir programda BU semboller HİÇ üretilmez).
    var class_ids: std.ArrayListUnmanaged(ClassIdEntry) = .empty;
    defer class_ids.deinit(allocator);
    for (module.body) |stmt| {
        if (stmt.kind == .class_def and stmt.kind.class_def.type_params.len == 0 and !containsName(generic_class_template_names, stmt.kind.class_def.name)) {
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
    for (extra_classes) |cd| {
        for (cd.methods) |m| try gen.genMethod(cd.name, m);
        const cinfo = gen.classes.get(cd.name).?;
        try gen.genClassRelease(cd.name, cinfo);
        try gen.genClassEq(cd.name, cinfo);
        try gen.genClassTrace(cd.name, cinfo);
        try gen.genClassGcFree(cd.name, cinfo);
        try class_ids.append(allocator, .{ .name = cd.name, .id = cinfo.class_id });
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
        // `PINNED_REFCOUNT` (1<<30, bkz. `abi_layout.PINNED_REFCOUNT`nin
        // belge notu — HPy'nin KENDİ, TAMAMEN ALAKASIZ `PINNED_REFCOUNT`i
        // İLE KARIŞTIRILMAMALI) — string literalinin görünmez ARC başlığı,
        // hiçbir gerçekçi retain/release dizisinin sıfıra indiremeyeceği
        // kadar büyük bir değerle başlar, bu yüzden `nox_rc_release` bu
        // statik belleği asla gerçekten serbest bırakmaya çalışmaz (bkz.
        // `.string_lit` kolu).
        try gen.out.writer.print("data {s} = {{ l {d}, b \"{s}\", b 0 }}\n", .{ sd.symbol, PINNED_REFCOUNT, sd.escaped });
    }

    // `print(list[T]/sınıf)` görüntülemesinin (bkz. `internFmtString`)
    // sınıf/alan adı fragmanları — `string_data`nın AKSİNE pinned-refcount
    // başlığı OLMADAN, düz birer `printf` format dizesi olarak yayılır.
    for (gen.fmt_data.items) |fd| {
        try gen.out.writer.print("data {s} = {{ b \"{s}\", b 0 }}\n", .{ fd.symbol, fd.escaped });
    }

    return gen.out.toOwnedSlice();
}
