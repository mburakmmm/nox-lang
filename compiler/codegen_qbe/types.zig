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
pub const HeapKind = enum { none, str, list, class, task, channel, dict, closure, thread_handle, thread_channel, boxed_scalar };

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
};

/// `dict[K, V]`nin anahtar/değer "şeklini" betimler.
pub const DictInfo = struct {
    key_is_str: bool,
    key_qtype: QbeType,
    value_qtype: QbeType,
    value_is_str: bool,
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
pub const HttpServeMulticoreWorkerSpec = struct {
    name: []const u8,
    wrapper_name: []const u8,
    max_conn_text: []const u8,
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
};

pub const LocalDecl = struct {
    name: []const u8,
    info: TypeInfo,
    is_param: bool = false,
    arena: bool = false,
};

pub const StringDatum = struct {
    symbol: []const u8,
    escaped: []const u8,
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

pub const ClassInfo = struct {
    fields: std.ArrayListUnmanaged(ClassField) = .empty,
    total_size: usize = 0,
    init_params: []const TypeInfo = &.{},
    methods: std.StringHashMapUnmanaged(FuncSig) = .empty,
    class_id: usize = 0,
    /// `false`: sınıfın bir `__init__`i yok — bkz. `registerClass`.
    has_init: bool = true,
    /// `true`: `__init__`in ASLA istisna fırlatmadığı KANITLANDI.
    init_is_safe: bool = false,
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
