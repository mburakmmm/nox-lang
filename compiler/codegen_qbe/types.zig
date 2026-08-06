//! QBE codegen backend'inin PAYLAŞILAN veri tipleri (bkz. plan dosyası "QBE
//! codegen backend'ini alt modüllere bölme") — `codegen.zig`nin (ESKİDEN
//! 8573 satırlık TEK dosya) bölünmesinin İLK aşaması: TÜM diğer alt
//! modüllerin (expr/stmt/ownership/layout/vb.) bağımlı olduğu temel katman.
//! Buradaki tipler SAF veridir (metod YOK) — `Codegen` struct'ının KENDİSİ
//! (ana `codegen.zig`de KALIR) bunları ALAN tipleri olarak kullanır.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const abi_layout = @import("abi_layout");

pub const QbeType = enum { l, d, w, none };

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
/// SIRASINA göre; bkz. `CLOSURE_HEADER_SIZE`).
pub const HeapKind = enum { none, str, list, class, task, channel, dict, closure, thread_handle, thread_channel, boxed_scalar, task_local };

/// Faz U.4.4: bir closure heap bloğunun başlık boyutu (bkz. `HeapKind.closure`in
/// belge notu) — `fn_ptr` + `release_fn_ptr`, HER İKİSİ de `l` (8 bayt).
/// Yakalanan değerler bu OFSETTEN itibaren sırayla YERLEŞTİRİLİR.
/// Faz P1.2: `../../shared/abi_layout.zig`den RE-EXPORT edilir (TEK
/// doğruluk kaynağı, runtime İLE PAYLAŞILIR) — bu dosya (VE onu kullanan
/// 15 codegen alt modülü) AYNI adla değişmeden erişmeye devam eder.
pub const CLOSURE_HEADER_SIZE = abi_layout.CLOSURE_HEADER_SIZE;
/// Faz P1.2: closure bloğunun release-fn-ptr alanının ofseti — bkz.
/// `abi_layout.CLOSURE_RELEASE_FN_PTR_OFFSET`in belge notu.
pub const CLOSURE_RELEASE_FN_PTR_OFFSET = abi_layout.CLOSURE_RELEASE_FN_PTR_OFFSET;

/// `list[T]`nin elemanları KENDİLERİ heap-yönetimliyse (sınıf ya da iç içe
/// `list[T']`) bunu ÖZYİNELEMELİ olarak betimler.
/// GG.15 (bkz. nox-teknik-spesifikasyon.md §3.66): bkz. `Codegen.
/// arena_stack`in belge notu.
pub const ArenaStackEntry = struct {
    handle: []const u8,
    elided: bool = false,
};

pub const ElemHeapInfo = struct {
    heap: HeapKind,
    class_name: ?[]const u8 = null,
    elem_qtype: QbeType = .none,
    nested: ?*const ElemHeapInfo = null,
    elem_is_str: bool = false,
    /// Faz U.4.5: `heap == .closure` OLAN elemanların STATİK çağrı imzası
    /// — bkz. `Value.func_sig`in belge notu, AYNI amaç, `list[(T)->U]`nin
    /// ELEMAN tipi İçin taşınır.
    func_sig: ?*const FuncSigInfo = null,
    /// Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
    /// incelemesi", C1): `heap == .dict` OLAN elemanların (`list[dict[K,V]]`)
    /// anahtar/değer "şekli" — `TypeInfo`/`Value`nin KENDİ `dict_info`si
    /// İLE AYNI amaç, `nox_dict_release(rt, ptr, key_is_str, value_is_str)`
    /// çağrısını doğru argümanlarla üretebilmek İçin GEREKLİ (bkz.
    /// `ownership.zig`nin `genListElemRelease`ı).
    dict_info: ?*const DictInfo = null,
};

/// `dict[K, V]`nin anahtar/değer "şeklini" betimler.
pub const DictInfo = struct {
    key_is_str: bool,
    key_qtype: QbeType,
    value_qtype: QbeType,
    value_is_str: bool,
    /// Faz OO.4 (bkz. nox-teknik-spesifikasyon.md §3.85): `dict[K, class]`
    /// — `value_is_str` İLE AYNI DÜZEYDE bir bayrak, RUNTIME serbest
    /// bırakma/retain kararları İçİn (`nox_class_release_dispatch` tag-
    /// tabanlıdır, SOMUT sınıf adını ÇALIŞMA ZAMANINDA GEREKTİRMEZ).
    value_is_class: bool = false,
    /// `value_is_class` İKEN sınıfın DERLEME-ZAMANI adı — `d[key]`
    /// OKUMASININ döndürdüğü `Value.class_name`i (METOD/alan çözümlemesi
    /// STATİK olarak BUNA İHTİYAÇ DUYAR, `list[T]`nin `ElemHeapInfo.
    /// class_name`iyle AYNI gerekçe) doğru DOLDURABİLMEK İçİn.
    value_class_name: ?[]const u8 = null,
};

/// Faz U.4.4: bir `(params) -> ret` tip ifadesinin (`ast.TypeExpr.func_type`)
/// ÇÖZÜLMÜŞ imzası.
pub const FuncSigInfo = struct {
    params: []const TypeInfo,
    ret: TypeInfo,
};

pub const TypeInfo = struct {
    qtype: QbeType,
    heap: HeapKind = .none,
    elem_qtype: QbeType = .none,
    class_name: ?[]const u8 = null,
    elem_heap_info: ?*const ElemHeapInfo = null,
    elem_is_str: bool = false,
    dict_info: ?*const DictInfo = null,
    func_sig: ?*const FuncSigInfo = null,
};

pub const Value = struct {
    text: []const u8,
    qtype: QbeType,
    heap: HeapKind = .none,
    elem_qtype: QbeType = .none,
    class_name: ?[]const u8 = null,
    elem_heap_info: ?*const ElemHeapInfo = null,
    elem_is_str: bool = false,
    dict_info: ?*const DictInfo = null,
    /// Faz U.4.5: `heap == .closure` OLAN bir değerin STATİK çağrı imzası
    /// (`VarInfo.func_sig` İLE AYNI amaç) — `.index`/`.attribute` ÜZERİNDEN
    /// DOLAYLI çağrı (bkz. `calls.zig`nin `genIndirectCallThroughClosure`ı)
    /// bunu bir DEĞİŞKEN slot'undan DEĞİL, doğrudan bu `Value`den okur
    /// (`genIndex`/`genFieldRead`/üst-düzey fonksiyon değer İnşası TARAFINDAN
    /// doldurulur).
    func_sig: ?*const FuncSigInfo = null,
    /// `true`: bir `lowlevel` bloğunun arenasından tahsis edildi — refcount
    /// başlığı YOK, `nox_rc_retain`/`nox_rc_release` bu değer üzerinde asla
    /// çağrılamaz.
    arena: bool = false,
    /// Stdlib fazı §G: `s[i]`nin BİLİNÇLİ bir istisnası — bkz. `Codegen`nin
    /// modül üstü notu (`always_fresh`in TAM gerekçesi).
    always_fresh: bool = false,
    /// GG.14 (bkz. nox-teknik-spesifikasyon.md §3.66): bu değer bir string
    /// LİTERALİ (`PINNED_REFCOUNT`, ASLA sıfıra İNMEZ) — retain/release
    /// ÜZERİNDE mantıksal olarak GÜVENLİ birer no-op'tur, bu YÜZDEN
    /// TAMAMEN ATLANABİLİR. `emitStringLiteral`nin KENDİSİ tarafından
    /// doldurulur.
    is_pinned: bool = false,
    /// GG.16 (bkz. nox-teknik-spesifikasyon.md §3.66): BU değer,
    /// `paramNeverEscapes`in KANITLADIĞI bir çağrı-sınırı-ÖTESİ yığın
    /// slotundan geliyor — `.arena`DAN BİLİNÇLİ olarak AYRI bir bayrak:
    /// `.arena=true` `checkNoLowlevelEscape`nin BU değeri bir çağrı
    /// argümanı OLARAK kullanmayı KOŞULSUZ REDDETMESİNE yol AÇARDI (GG.16
    /// TAM OLARAK bunu YAPMAK İSTİYOR — bir `lowlevel:` bloğunun DIŞINDA,
    /// gerçek bir fonksiyon çağrısı SINIRINI AŞARAK). `releaseIfTemporary`/
    /// `releaseTemporaryArgs` BUNU görüp release'İ atlar; `checkNoLowlevelEscape`
    /// BUNU HİÇ GÖRMEZ (kasıtlı — bu bayrak ONUN kontrolüne DAHİL DEĞİL).
    is_stack_slot: bool = false,
};

pub const FuncSig = struct {
    params: []const TypeInfo,
    ret: TypeInfo,
    /// Yalnızca `extern def`ler İÇİN anlamlıdır — bkz. `ast.ExternDef.needs_rt`.
    needs_rt: bool = false,
};

/// Faz HH.4: `handle` fonksiyonu gövdesinin `req` parametresinin HANGİ
/// alanlarına GERÇEKTEN eriştiğinin KONSERVATİF sonucu.
pub const UsedRequestFields = struct {
    method: bool = false,
    target: bool = false,
    body: bool = false,
    headers: bool = false,

    pub fn allUsed() UsedRequestFields {
        return .{ .method = true, .target = true, .body = true, .headers = true };
    }
};

pub const HttpServeWrapperSpec = struct {
    name: []const u8,
    handler_fn: []const u8,
    req_class: []const u8,
    resp_class: []const u8,
    used_fields: UsedRequestFields,
};

/// Faz "sunucu-tarafı WebSocket Upgrade": `nox.http.serve_ws*` çağrı
/// sitesi başına TEMBEL kaydedilen, `WsHandlerFn`e uyan (`fn(ctx, conn)
/// callconv(.c) void`) C-ABI sarmalayıcının tarifi — `HttpServeWrapperSpec`in
/// AYNI deseni, AMA yanıt nesnesi/`used_fields` YOK (bir WS oturumunun
/// "yanıtı" yoktur, bkz. `genHttpServeWsWrapper`).
pub const HttpServeWsWrapperSpec = struct {
    name: []const u8,
    ws_handler_fn: []const u8,
    conn_class: []const u8,
};

pub const SpawnWrapperSpec = struct {
    name: []const u8,
    target_fn: []const u8,
    sig: FuncSig,
};

/// Faz BB.4: `nox.thread.start(entry, arg)` çağrı sitesi başına TEMBEL
/// kaydedilen bir sarmalayıcının tarifi.
pub const ThreadWrapperSpec = struct {
    name: []const u8,
    target_fn: []const u8,
    sig: FuncSig,
};

/// Faz DD.1: `nox.http.serve_multicore` çağrı sitesi başına TEMBEL
/// kaydedilen bir "iş parçacığı girişi" worker fonksiyonunun tarifi.
/// Faz "sunucu-tarafı TLS + WS": `tls`/`ws_wrapper_name` bu worker'ın
/// (a) paylaşılan payload'ın ÇIPLAK bir `fd` mi yoksa bir `FdTlsPayload*`
/// mi olduğunu (bkz. `genHttpServeMulticoreWorker`nin payload YÜKLEME
/// dalı) ve (b) `nox_http_serve_raw` mı `nox_http_serve_ws_raw` mı
/// çağıracağını (bkz. `emitFdServeTail`) BELİRLER.
pub const HttpServeMulticoreWorkerSpec = struct {
    name: []const u8,
    wrapper_name: []const u8,
    max_conn_text: []const u8,
    ws_wrapper_name: ?[]const u8 = null,
    tls: bool = false,
};

/// Faz U.4.3: bir closure'ın TEK bir yakalanan (capture) değeri.
pub const ClosureCaptureField = struct { name: []const u8, info: TypeInfo };

/// Faz U.4.3: bir iç içe `def`in gövdesini (henüz derlenmemiş) TEMBEL kaydı.
pub const ClosureFuncSpec = struct {
    mangled_name: []const u8,
    path: []const u8,
    fd: ast.FuncDef,
    captures: []const ClosureCaptureField,
};

pub const VarInfo = struct {
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
    /// GG.12: `self.<alan>`in salt-okunur, HİÇBİR yere aktarılmayan bir
    /// kopyası (ör. sadece bir `for` döngüsünün iterable'ı) — `self`in
    /// KENDİSİ metodun tüm aktivasyonu boyunca CANLI olduğundan retain/
    /// release tamamen GEREKSİZ. `is_param`i aşırı yüklemez (o başka
    /// birçok yerde kontrol ediliyor, ayrı bayrak patlama yarıçapını daraltır).
    borrowed_field: bool = false,
    /// GG.14: BU parametre, `genInlinedCall`nin BU splice SİTESİNDE,
    /// `exprAlwaysProducesPinnedString` İLE HER ZAMAN bir string LİTERALİ
    /// (`PINNED_REFCOUNT`) ÜRETTİĞİ KANITLANMIŞ bir argümanla ÇAĞRILDI —
    /// `is_param`ı AŞIRI YÜKLEMEZ (`returnNeedsRetain`nin `.identifier`
    /// dalı `is_param` YÜZÜNDEN retain İSTERDİ, BU bayrak SADECE o kararı
    /// GEÇERSİZ kılar). Argüman-BAĞIMLI olduğundan `LocalDecl`e DEĞİL,
    /// SADECE BURAYA (call-site'a özgü `VarInfo` gölgelemesine) aittir.
    is_pinned_str: bool = false,
};

pub const LocalDecl = struct {
    name: []const u8,
    info: TypeInfo,
    is_param: bool = false,
    arena: bool = false,
    /// GG.12: bkz. `VarInfo.borrowed_field`in belge notu — `allocSlot`
    /// BUNU doğrudan `VarInfo`ye taşır.
    borrowed_field: bool = false,
};

pub const StringDatum = struct {
    symbol: []const u8,
    escaped: []const u8,
    /// `str`e uzunluk alanı + ASCII bayrağı eklenmesi (bkz. plan dosyası):
    /// derleyici bir literal İçin (Zig ile derlenmiş `runtime/str.zig`nin
    /// AKSİNE) HAM bayt dizisini ZATEN derleme ZAMANINDA bildiğinden,
    /// uzunluk+ascii-durumu SIFIR ÇALIŞMA-ZAMANI maliyetiyle burada
    /// hesaplanıp `.data $strN`nin paketlenmiş İKİNCİ alanına GÖMÜLÜR —
    /// `escaped`in KENDİSİ QBE'nin ÖZ escape biçimidir (`\xHH` vb.),
    /// GERÇEK çalışma-zamanı bayt uzunluğu DEĞİLDİR, bu YÜZDEN `byte_len`
    /// AYRI taşınır.
    byte_len: usize = 0,
    is_ascii: bool = true,
    /// Faz LLVM.7: `escaped` QBE'nin KENDİ escape biçimi (yukarıdaki not) —
    /// LLVM'in `c"..."` sabit-dizi sözdiziminin KENDİ (FARKLI, `\XX` iki-
    /// hex-basamaklı) escape kuralları olduğundan, `llvm_emit.
    /// llvmStrHeaderConstant`in KENDİ escape'ini yapabilmesi İçin HAM
    /// (kaçışsız) baytlar AYRICA taşınır. `.qbe` bu alanı HİÇ OKUMAZ.
    raw: []const u8 = "",
};

/// Bkz. `Codegen.mod_cache`nin belge notu (`optimizations.zig`).
pub const ModCacheEntry = struct {
    text: []const u8,
    qtype: QbeType,
};

pub const ClassField = struct {
    name: []const u8,
    info: TypeInfo,
    offset: usize,
};

/// Faz S.3: `genTraceDispatch`/`genGcFreeDispatch`in dal açacağı (isim,
/// `class_id`) çiftleri.
pub const ClassIdEntry = struct { name: []const u8, id: usize };

/// Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı): bir
/// üst-düzey (script top-level) `var_decl`nin, `nox_globals_get(rt)`nin
/// döndürdüğü opak bloktaki YERİ — `ClassField` İLE AYNI amaç (isim,
/// tip, ofset) ama `TAG_SIZE` YOK (blok'un KENDİSİ bir ARC başlığı
/// TAŞIMAZ — `nox_alloc` ile ayrılan DÜZ bir bellek bloğu, sınıf
/// örneklerinin AKSİNE).
pub const GlobalVar = struct {
    name: []const u8,
    info: TypeInfo,
    offset: usize,
};

/// Faz 7 (tekli kalıtım): `ClassInfo.methods`in DEĞER tipi — çıplak
/// `FuncSig`in YERİNE geçer (serbest fonksiyonların/extern def'lerin
/// KENDİ `FuncSig` kullanımı DEĞİŞMEZ, bu SADECE sınıf metodları İçindir).
pub const ClassMethodInfo = struct {
    sig: FuncSig,
    /// Bu metodun GERÇEK gövdesini TAŞIYAN sınıf — KENDİSİ (yeni bir
    /// metod YA DA bir override) ya da bir atası (miras alınan, override
    /// EDİLMEMİŞ bir metod). `genMethodCall`in ÜRETTİĞİ sembol
    /// (`$owner_method`) BUNDAN gelir — kalıtıma KATILMAYAN bir sınıf
    /// İçin `owner` HER ZAMAN sınıfın KENDİ adıdır (davranış BİREBİR
    /// ÖNCEKİ GİBİ kalır).
    owner: []const u8,
    /// vtable SLOT numarası — SADECE `ClassInfo.has_vtable == true` İSE
    /// anlamlıdır (aksi halde HER ZAMAN `0`, HİÇ okunmaz). Bir metod adı
    /// bir hiyerarşide İLK KEZ tanımlandığında YENİ bir slot ALIR; HER
    /// override AYNI slotu KULLANIR (bkz. `registerClass`in belge notu).
    slot: usize = 0,
};

pub const ClassInfo = struct {
    fields: std.ArrayListUnmanaged(ClassField) = .empty,
    total_size: usize = 0,
    init_params: []const TypeInfo = &.{},
    methods: std.StringHashMapUnmanaged(ClassMethodInfo) = .empty,
    class_id: usize = 0,
    /// `false`: sınıfın bir `__init__`i yok — bkz. `registerClass`.
    has_init: bool = true,
    /// `true`: `__init__`in ASLA istisna fırlatmadığı KANITLANDI.
    init_is_safe: bool = false,
    /// Faz 7 (tekli kalıtım): `class Derived(Base):` — `ast.ClassDef.base`.
    base: ?[]const u8 = null,
    /// Faz 7: bu sınıf KALITIMA KATILIYOR MU (KENDİSİ türetilmiş YA DA
    /// başka bir sınıfın tabanı) — `Codegen.inheriting_classes`den (TÜM
    /// sınıf tanımlarının SAF/sıraya BAĞIMSIZ bir ön-taraması, bkz.
    /// `computeInheritingClasses`) `registerClass` tarafından okunur.
    /// `true` İSE nesne düzeni `TAG_SIZE`den SONRA EK bir `VTABLE_PTR_SIZE`
    /// yuvası taşır (bkz. `VTABLE_PTR_SIZE`nin belge notu) VE metod
    /// çağrıları `layout.zig`nin ürettiği `$ClassName_vtable` bloğu
    /// ÜZERİNDEN dolaylı (indirect) yapılır — kalıtıma KATILMAYAN sınıflar
    /// İçin `false` (BÜYÜK ÇOĞUNLUK), davranış/düzen BİREBİR ÖNCEKİ GİBİ.
    has_vtable: bool = false,
    /// Faz 7: `has_vtable == true` İKEN bir SONRAKİ YENİ (override
    /// OLMAYAN) metodun alacağı vtable slot numarası — taban sınıftan
    /// devralınıp GENİŞLETİLİR (bkz. `registerClass`in belge notu, "her
    /// alt sınıf KENDİ next_slot kopyasını taşır" tasarımı).
    next_vtable_slot: usize = 0,
    /// Faz 7: `__init__`in GERÇEK gövdesini TAŞIYAN sınıf — `methods`in
    /// `owner`ıyla AYNI fikir ama `__init__` AYRI tutulduğundan (asla
    /// `methods` haritasına GİRMEZ, bkz. checker.zig'in AYNI ayrımı) ayrı
    /// bir alan gerekir. `has_init == true` İKEN her zaman doludur.
    init_owner: ?[]const u8 = null,
    /// Faz 7: KENDİSİ + TÜM (transitif) alt sınıflarının `class_id`leri —
    /// `exceptions.zig`nin `except Base:`in bir `Derived` örneğini de
    /// YAKALAMASI İçin gereken hiyerarşik eşleşmesi (OR-zinciri) İçin.
    /// TÜM sınıflar kaydedildikten SONRA, AYRI bir geçişte doldurulur
    /// (bkz. `codegen.zig`, `computeDescendantClassIds`) — kalıtıma
    /// KATILMAYAN bir sınıf İçin TEK elemanlı (yalnızca KENDİ id'si).
    descendant_class_ids: []const usize = &.{},
};

pub const RT_PARAM = "%rt";
/// Faz P1.2: bkz. `CLOSURE_HEADER_SIZE`nin notu — `abi_layout`den RE-EXPORT.
pub const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;
/// Faz U.1: `list[T]` başlığının bayt boyutu — `{ len: i64 @0, cap: i64 @8,
/// elemanlar @16... }`. `runtime/stdlib_shims/json.zig`nin `buildPtrList`i
/// VE `runtime/stdlib_shims/strings.zig`nin `nox_strings_split_raw`ı da
/// AYNI düzeni EL İLE ürettiğinden BU SABİTLE TUTARLI kalmalıdır. Faz P1.2:
/// `abi_layout`den RE-EXPORT.
pub const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
/// Her sınıf örneğinin (refcount başlığından SONRA) taşıdığı, çalışma
/// zamanında `except ClassName:` eşleştirmesi için kullanılan tip etiketi.
/// Faz P1.2: `abi_layout`den RE-EXPORT.
pub const TAG_SIZE = abi_layout.TAG_SIZE;
/// Faz 7: `abi_layout.VTABLE_PTR_SIZE`den RE-EXPORT — bkz. onun belge notu.
pub const VTABLE_PTR_SIZE = abi_layout.VTABLE_PTR_SIZE;
/// Faz P1.2: ARC refcount başlığının bayt boyutu — bkz.
/// `abi_layout.ARC_HEADER_SIZE`nin belge notu.
pub const ARC_HEADER_SIZE = abi_layout.ARC_HEADER_SIZE;
/// Faz P1.2: pinned string literal refcount değeri — bkz.
/// `abi_layout.PINNED_REFCOUNT`nin belge notu.
pub const PINNED_REFCOUNT = abi_layout.PINNED_REFCOUNT;
/// Faz P1.2: döngü-çözücü trace-buffer'ının uzunluk ön-eki/yuva boyutu —
/// bkz. `abi_layout.TRACE_BUF_LEN_SIZE`/`TRACE_BUF_SLOT_SIZE`nin belge notu.
pub const TRACE_BUF_LEN_SIZE = abi_layout.TRACE_BUF_LEN_SIZE;
pub const TRACE_BUF_SLOT_SIZE = abi_layout.TRACE_BUF_SLOT_SIZE;
/// `str`nin KENDİ (ARC refcount başlığından SONRA) paketlenmiş uzunluk+
/// ascii-durumu başlığı — bkz. `abi_layout.STR_HEADER_SIZE`nin belge notu.
pub const STR_HEADER_SIZE = abi_layout.STR_HEADER_SIZE;
pub const STR_ASCII_TRUE = abi_layout.STR_ASCII_TRUE;
pub const STR_ASCII_FALSE = abi_layout.STR_ASCII_FALSE;
pub const STR_ASCII_UNKNOWN = abi_layout.STR_ASCII_UNKNOWN;
pub const packStrHeader = abi_layout.packStrHeader;
