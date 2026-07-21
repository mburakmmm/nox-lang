//! Nox HPy köprüsü — Tier 0 (AGENTS.md §10): nesne yaşam döngüsü (create/
//! destroy), refcount emülasyonu, temel tip objesi protokolü (yalnızca
//! None/Bool/Long/Float), modül yükleme (bkz. `loader.zig`).
//!
//! **Nox, YENİ bir HPy "universal ABI" ana bilgisayarıdır** (CPython'ın
//! `hpy.universal`'ı ya da PyPy'nin kendi implementasyonu gibi) — gerçek bir
//! CPython yorumlayıcısı OLMADAN, gerçek HPy header'larıyla (`HPY_ABI_
//! UNIVERSAL` modu) derlenmiş bir C eklentisini doğrudan yükleyip
//! çalıştırabilir. Bu, `HPyContext` yapısının (aşağıda) HPy projesinin
//! `autogen_ctx.h`sinden ALAN ALANA (mekanik bir script ile, bkz.
//! `scripts/gen_hpy_ctx.py`) üretilmiş, bayt-uyumlu bir transkripsiyonunu
//! GEREKTİRİR — bir eklenti bu struct'a doğrudan (sabit ofsetlerle) erişir,
//! bu yüzden alan SIRASI ve BOYUTU tam olarak eşleşmelidir. Şu an 180
//! `ctx_*` alanından **62'si** GERÇEKTEN implemente (aşağıda özel fonksiyon
//! işaretçisi tipleriyle işaretli — tam liste/tier dökümü İçin bkz.
//! nox-teknik-spesifikasyon.md §3.12 VE DEVAMI, en son Faz OO) — geri
//! kalanı `null` (kullanılmazlarsa zararsız; bir eklenti bunlardan birini
//! çağırırsa çökme/segfault olur, bkz. spesifikasyondaki bilinçli
//! sınırlamalar).
//!
//! **Nesne modeli:** `HPy._i`, Nox'un kendi refcount'lu `Obj` yapısına
//! işaret eden bir işaretçidir (`@intFromPtr`/`@ptrFromInt` ile dönüştürülür)
//! — `runtime/alloc/arc.zig`'in mekanizmasından BAĞIMSIZ, ayrı ve basit bir
//! refcount (bu köprü henüz derlenmiş Nox kodundan çağrılmıyor, yalnızca
//! `tests/compat`ten dlopen ile yüklenen bağımsız bir C eklentisiyle
//! doğrulanıyor — bkz. bilinen sınırlamalar).

const std = @import("std");

pub const HPy = extern struct {
    _i: isize = 0,
};
pub const HPy_NULL: HPy = .{ ._i = 0 };

/// Nox'un HPy nesnelerini temsil ettiği en küçük ortak biçim. Yalnızca
/// Tier 0'ın gerektirdiği dört tip: `None` (tekil), `Bool` (iki tekil,
/// `True`/`False`), `Long` (i64), `Float` (f64). `refcount`, tekiller için
/// asla sıfıra İNMEYECEK şekilde çok yüksek bir başlangıç değeriyle
/// korunur (bkz. `PINNED_REFCOUNT`) — bu, gerçek CPython'ın `Py_None`/
/// `Py_True`/`Py_False` tekillerinin de asla serbest bırakılmamasıyla aynı
/// ruhta bir basitleştirmedir.
pub const ObjTag = enum(u8) { none, bool_, long, float_, str_, exc_type, list_, tuple_, dict_, type_, instance_, bound_method_ };

/// `HPyType_FromSpec`in bir `type_` nesnesine kaydettiği tek bir örnek
/// metodu (`HPyDef_Kind_Meth` + `HPyFunc_O` — Tier 0'ın modül metodu
/// desteğiyle AYNI kısıt). `name`/`impl`, EKLENTİNİN kendi statik
/// belleğine (bkz. `HPyDef` dizisi, `static` C global'i) işaret eder —
/// kopyalanmaz, çünkü bu bellek `.so` yüklü kaldığı sürece geçerlidir
/// (module-level `findMethodO` ile aynı varsayım).
pub const TypeMethod = struct {
    name: [*:0]const u8,
    impl: *const fn (ctx: *HPyContext, self: HPy, arg: HPy) callconv(.c) HPy,
};

pub const Obj = struct {
    refcount: i64,
    tag: ObjTag,
    payload: Payload,
    /// Yalnızca `tag == .str_` iken kullanılır — sahiplenilen (bu `Obj`
    /// yok edilirken serbest bırakılması gereken), sıfırla-sonlandırılmış
    /// bir kopya (bkz. `ctxUnicodeAsUTF8AndSize`in gerçek HPy sözleşmesi:
    /// `const char*` döndürür, çağıran tarafından serbest bırakılmaz).
    str_data: [:0]const u8 = "",
    /// Yalnızca `tag == .list_` — büyüyebilir, SAHİPLENİLEN bir tutamaç
    /// dizisi (her eleman `ctxDup` ile retain edilmiş kendi referansımız,
    /// çağıranın kendi tutamacından BAĞIMSIZ — bkz. `ctxListAppend`).
    list_data: std.ArrayListUnmanaged(HPy) = .empty,
    /// Yalnızca `tag == .tuple_` — SABİT boyutlu, SAHİPLENİLEN bir dizi
    /// (tuple değişmezdir: `ctx_SetItem`/`ctx_DelItem` bunun için TypeError
    /// ayarlar, bkz. ilgili fonksiyonların `else` kolu).
    tuple_data: []HPy = &.{},
    /// Yalnızca `tag == .dict_` — anahtar/değer çiftlerinin DOĞRUSAL (hash
    /// tablosu değil) bir listesi. Nox'un nesne modelinde henüz genel bir
    /// `__hash__` protokolü yok, bu yüzden arama `objEquals` ile DOĞRUSAL
    /// karşılaştırma yapar — az sayıda anahtar için doğru ama O(n)'dir
    /// (bilinçli bir v0.1 basitleştirmesi; gerçek bir hash tablosu ileride
    /// eklenebilir).
    dict_data: std.ArrayListUnmanaged(DictEntry) = .empty,
    /// Yalnızca `tag == .type_` — `HPyType_FromSpec`ten toplanan bilgi:
    /// örneklerin ham C struct'ının boyutu, (varsa) `HPy_tp_destroy` slotu,
    /// ve `HPyFunc_O` imzalı örnek metodları. Taban sınıf/metaclass/
    /// getset/member/buffer slotları HENÜZ desteklenmiyor (bkz. spec).
    type_basicsize: usize = 0,
    type_tp_destroy: ?*const fn (data: *anyopaque) callconv(.c) void = null,
    /// Çağrılabilir nesne protokolü (bkz. §3.12'nin AYNI adlı bölümü) —
    /// `HPy_tp_new`/`HPy_tp_init`/`HPy_tp_call` slotları. `type_tp_new`/
    /// `type_tp_init`, gerçek HPy'nin `HPyFunc_NEWFUNC`/`INITPROC`
    /// imzalarıyla (`HPy_ssize_t nargs`, yani `isize`) BİREBİR eşleşir;
    /// `type_tp_call` İSE `HPyFunc_KEYWORDS`in `size_t nargs`siyle
    /// (`usize`) — bu ikisi KASITLI olarak BİRLEŞTİRİLMEDİ, gerçek HPy
    /// header'ındaki gibi AYRI tutuldu.
    type_tp_new: ?*const fn (ctx: *HPyContext, h_type: HPy, args: ?[*]const HPy, nargs: isize, kw: HPy) callconv(.c) HPy = null,
    type_tp_init: ?*const fn (ctx: *HPyContext, self: HPy, args: ?[*]const HPy, nargs: isize, kw: HPy) callconv(.c) c_int = null,
    type_tp_call: ?*const fn (ctx: *HPyContext, self: HPy, args: ?[*]const HPy, nargs: usize, kwnames: HPy) callconv(.c) HPy = null,
    type_methods: std.ArrayListUnmanaged(TypeMethod) = .empty,
    /// Yalnızca `tag == .instance_` — `ctx_New` ile inşa edilmiş bir
    /// `type_` örneği: kendi tipine (retained) bir referans + ham,
    /// sıfırlanmış `basicsize` baytlık, SAHİPLENİLEN bir tampon (bkz.
    /// `ctx_AsStruct_Object`in bunu döndürmesi — eklenti bunu kendi C
    /// struct'ına cast eder).
    instance_type: HPy = HPy_NULL,
    instance_data: []u8 = &.{},
    /// Yalnızca `tag == .instance_` — attribute erişimi (bkz. §3.12'nin
    /// AYNI adlı bölümü). Python'ın per-instance `__dict__`inin bir
    /// KARŞILIĞI: eklentinin OPAK `instance_data` ham struct'ına HİÇ
    /// DOKUNMADAN, Nox'un (`ctx_SetAttr`/`_s` İLE) SONRADAN EKLEDİĞİ
    /// attribute'ları tutar — `.dict_`in AYNI `DictEntry` yapısını
    /// YENİDEN kullanır.
    instance_dict: std.ArrayListUnmanaged(DictEntry) = .empty,
    /// Yalnızca `tag == .bound_method_` — `ctx_GetAttr`in bir örnek
    /// ÜZERİNDEN `type_methods`teki bir metodu BULDUĞUNDA sardığı nesne
    /// (Python'ın `instance.method`inin `self`i TAŞIYAN bağlı metoduyla
    /// AYNI fikir). `bound_method_self` RETAINED (bkz. `ctxDup`),
    /// `bound_method_impl` `TypeMethod.impl` İLE AYNI `HPyFunc_O` imzalı
    /// — `callDispatch` (çağrılabilir nesne protokolü) BUNU tek argümanlı
    /// bir çağrıya DAĞITIR.
    bound_method_self: HPy = HPy_NULL,
    bound_method_impl: ?*const fn (ctx: *HPyContext, self: HPy, arg: HPy) callconv(.c) HPy = null,

    pub const Payload = extern union {
        b: bool,
        l: i64,
        f: f64,
    };

    pub const DictEntry = struct { key: HPy, value: HPy };
};

const PINNED_REFCOUNT: i64 = 1 << 30;

fn allocObj(allocator: std.mem.Allocator, tag: ObjTag, payload: Obj.Payload, refcount: i64) HPy {
    const obj = allocator.create(Obj) catch return HPy_NULL;
    obj.* = .{ .refcount = refcount, .tag = tag, .payload = payload };
    return .{ ._i = @intCast(@intFromPtr(obj)) };
}

fn objOf(h: HPy) ?*Obj {
    if (h._i == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(h._i)));
}

// ---- Tier 0 ctx_* implementasyonları ----

fn ctxDup(ctx: *HPyContext, h: HPy) callconv(.c) HPy {
    _ = ctx;
    const obj = objOf(h) orelse return HPy_NULL;
    if (obj.refcount < PINNED_REFCOUNT) obj.refcount += 1;
    return h;
}

fn ctxClose(ctx: *HPyContext, h: HPy) callconv(.c) void {
    const obj = objOf(h) orelse return;
    if (obj.refcount >= PINNED_REFCOUNT) return; // tekil: hiç serbest bırakılmaz
    obj.refcount -= 1;
    if (obj.refcount <= 0) {
        const allocator = contextAllocator(ctx);
        switch (obj.tag) {
            .str_ => allocator.free(obj.str_data),
            .list_ => {
                for (obj.list_data.items) |item| ctxClose(ctx, item);
                obj.list_data.deinit(allocator);
            },
            .tuple_ => {
                for (obj.tuple_data) |item| ctxClose(ctx, item);
                allocator.free(obj.tuple_data);
            },
            .dict_ => {
                for (obj.dict_data.items) |entry| {
                    ctxClose(ctx, entry.key);
                    ctxClose(ctx, entry.value);
                }
                obj.dict_data.deinit(allocator);
            },
            .type_ => obj.type_methods.deinit(allocator),
            .instance_ => {
                // Gerçek HPy sözleşmesi: `tp_destroy`, bellek serbest
                // bırakılmadan HEMEN ÖNCE ham struct işaretçisiyle çağrılır
                // (HPy/CPython'un kendi `tp_dealloc` sırasıyla aynı ruhta).
                if (objOf(obj.instance_type)) |type_obj| {
                    if (type_obj.type_tp_destroy) |destroy_fn| destroy_fn(obj.instance_data.ptr);
                }
                ctxClose(ctx, obj.instance_type);
                allocator.free(obj.instance_data);
                // `.dict_`in AYNI deseni — attribute erişimi (bkz. `Obj.
                // instance_dict`in belge notu).
                for (obj.instance_dict.items) |entry| {
                    ctxClose(ctx, entry.key);
                    ctxClose(ctx, entry.value);
                }
                obj.instance_dict.deinit(allocator);
            },
            .bound_method_ => ctxClose(ctx, obj.bound_method_self),
            .none, .bool_, .long, .float_, .exc_type => {},
        }
        allocator.destroy(obj);
    }
}

fn ctxLongFromInt64(ctx: *HPyContext, v: i64) callconv(.c) HPy {
    return allocObj(contextAllocator(ctx), .long, .{ .l = v }, 1);
}

fn ctxLongAsInt64(ctx: *HPyContext, h: HPy) callconv(.c) i64 {
    const obj = objOf(h) orelse return -1;
    return switch (obj.tag) {
        .long => obj.payload.l,
        .bool_ => if (obj.payload.b) 1 else 0,
        .float_ => @intFromFloat(obj.payload.f),
        .none, .str_, .exc_type, .list_, .tuple_, .dict_, .type_, .instance_, .bound_method_ => blk: {
            ctxErrSetString(ctx, ctx.h_TypeError, "int'e dönüştürülemez");
            break :blk -1;
        },
    };
}

fn ctxFloatFromDouble(ctx: *HPyContext, v: f64) callconv(.c) HPy {
    return allocObj(contextAllocator(ctx), .float_, .{ .f = v }, 1);
}

fn ctxFloatAsDouble(ctx: *HPyContext, h: HPy) callconv(.c) f64 {
    const obj = objOf(h) orelse return 0;
    return switch (obj.tag) {
        .float_ => obj.payload.f,
        .long => @floatFromInt(obj.payload.l),
        .bool_ => if (obj.payload.b) 1 else 0,
        .none, .str_, .exc_type, .list_, .tuple_, .dict_, .type_, .instance_, .bound_method_ => blk: {
            ctxErrSetString(ctx, ctx.h_TypeError, "float'a dönüştürülemez");
            break :blk 0;
        },
    };
}

fn ctxBoolFromBool(ctx: *HPyContext, v: bool) callconv(.c) HPy {
    const c = contextState(ctx);
    return if (v) c.h_true_obj else c.h_false_obj;
}

// ---- Tier 0 tamamlama: Unicode (str) temel işlemleri ----

fn ctxUnicodeFromString(ctx: *HPyContext, utf8: ?[*:0]const u8) callconv(.c) HPy {
    const s = utf8 orelse return HPy_NULL;
    const allocator = contextAllocator(ctx);
    const copy = allocator.dupeZ(u8, std.mem.sliceTo(s, 0)) catch return HPy_NULL;
    const obj = allocator.create(Obj) catch {
        allocator.free(copy);
        return HPy_NULL;
    };
    obj.* = .{ .refcount = 1, .tag = .str_, .payload = .{ .l = 0 }, .str_data = copy };
    return .{ ._i = @intCast(@intFromPtr(obj)) };
}

fn ctxUnicodeCheck(ctx: *HPyContext, h: HPy) callconv(.c) c_int {
    _ = ctx;
    const obj = objOf(h) orelse return 0;
    return @intFromBool(obj.tag == .str_);
}

/// Gerçek HPy sözleşmesi: sıfırla-sonlandırılmış bir `const char*` döndürür
/// (çağıran serbest bırakmaz — bellek `Obj`nin kendisine ait, `ctxClose`de
/// serbest bırakılır), `size` (varsa) bayt uzunluğunu alır.
fn ctxUnicodeAsUTF8AndSize(ctx: *HPyContext, h: HPy, size: ?*isize) callconv(.c) ?[*:0]const u8 {
    _ = ctx;
    const obj = objOf(h) orelse return null;
    if (obj.tag != .str_) return null;
    if (size) |s| s.* = @intCast(obj.str_data.len);
    return obj.str_data.ptr;
}

// ---- Tier 0 tamamlama: temel nesne protokolü ----

fn ctxLength(ctx: *HPyContext, h: HPy) callconv(.c) isize {
    const obj = objOf(h) orelse return -1;
    return switch (obj.tag) {
        .str_ => @intCast(obj.str_data.len),
        .list_ => @intCast(obj.list_data.items.len),
        .tuple_ => @intCast(obj.tuple_data.len),
        .dict_ => @intCast(obj.dict_data.items.len),
        .none, .bool_, .long, .float_, .exc_type, .type_, .instance_, .bound_method_ => blk: {
            ctxErrSetString(ctx, ctx.h_TypeError, "bu tipin bir uzunluğu yok");
            break :blk -1;
        },
    };
}

fn ctxIsTrue(ctx: *HPyContext, h: HPy) callconv(.c) c_int {
    _ = ctx;
    const obj = objOf(h) orelse return 0;
    return switch (obj.tag) {
        .none => 0,
        .bool_ => @intFromBool(obj.payload.b),
        .long => @intFromBool(obj.payload.l != 0),
        .float_ => @intFromBool(obj.payload.f != 0),
        .str_ => @intFromBool(obj.str_data.len != 0),
        .list_ => @intFromBool(obj.list_data.items.len != 0),
        .tuple_ => @intFromBool(obj.tuple_data.len != 0),
        .dict_ => @intFromBool(obj.dict_data.items.len != 0),
        .exc_type, .type_, .instance_, .bound_method_ => 1,
    };
}

/// Python'ın `==` eşitliğinin ÇOK basitleştirilmiş bir alt kümesi — dict
/// anahtarı araması (`findDictEntry`) ve `ctx_Contains` için yeterli:
/// sayısal tipler değerce (int/float/bool birbirine karışabilir, Python'la
/// aynı), `str_` içerikçe, konteynerler (`list_`/`tuple_`/`dict_`) ve
/// `exc_type` KİMLİKÇE (aynı `Obj` işaretçisi) karşılaştırılır — gerçek
/// Python'daki yapısal `list == list` eşitliğinin bir basitleştirmesi.
fn objEquals(a: *Obj, b: *Obj) bool {
    if (isNumericTag(a.tag) and isNumericTag(b.tag)) return numAsF64(a) == numAsF64(b);
    if (a.tag != b.tag) return false;
    return switch (a.tag) {
        .none => true,
        .str_ => std.mem.eql(u8, a.str_data, b.str_data),
        .bool_, .long, .float_ => unreachable, // isNumericTag zaten yakaladı
        .exc_type, .list_, .tuple_, .dict_, .type_, .instance_, .bound_method_ => a == b,
    };
}

/// Nesne KİMLİĞİ karşılaştırması (Python'ın `is`i) — aynı `Obj`ye işaret
/// eden iki `HPy` (ya da iki `HPy_NULL`) eşittir.
fn ctxIs(ctx: *HPyContext, obj: HPy, other: HPy) callconv(.c) c_int {
    _ = ctx;
    return @intFromBool(obj._i == other._i);
}

// ---- Tier 1: list/tuple/dict + sequence/mapping protokolü ----
//
// Gerçek HPy sözleşmesi: bir konteynere EKLEMEK (`ctx_List_Append`,
// `ctx_SetItem`, ...) çağıranın kendi tutamacını ÇALMAZ — konteyner
// `ctxDup` ile KENDİ referansını alır, çağıran kendi tutamacını ayrıca
// kapatmalıdır. Simetrik olarak bir konteynerden OKUMAK (`ctx_GetItem`,
// ...) çağırana YENİ bir referans (yine `ctxDup`) döndürür — konteynerin
// kendi iç referansı bozulmaz.

fn ctxListCheck(ctx: *HPyContext, h: HPy) callconv(.c) c_int {
    _ = ctx;
    const obj = objOf(h) orelse return 0;
    return @intFromBool(obj.tag == .list_);
}

fn ctxListNew(ctx: *HPyContext, len: isize) callconv(.c) HPy {
    if (len < 0) {
        ctxErrSetString(ctx, ctx.h_ValueError, "negatif liste uzunluğu");
        return HPy_NULL;
    }
    const allocator = contextAllocator(ctx);
    const obj = allocator.create(Obj) catch return HPy_NULL;
    obj.* = .{ .refcount = 1, .tag = .list_, .payload = .{ .l = 0 } };
    var i: isize = 0;
    while (i < len) : (i += 1) {
        // Gerçek `HPyList_New` boş/tanımsız yuvalar üretir; biz güvenlik
        // için (asla okunması durumunda çökmeyecek) `None` ile dolduruyoruz.
        obj.list_data.append(allocator, ctxDup(ctx, ctx.h_None)) catch {
            for (obj.list_data.items) |h2| ctxClose(ctx, h2);
            obj.list_data.deinit(allocator);
            allocator.destroy(obj);
            return HPy_NULL;
        };
    }
    return .{ ._i = @intCast(@intFromPtr(obj)) };
}

fn ctxListAppend(ctx: *HPyContext, h_list: HPy, h_item: HPy) callconv(.c) c_int {
    const obj = objOf(h_list) orelse return -1;
    if (obj.tag != .list_) {
        ctxErrSetString(ctx, ctx.h_TypeError, "list bekleniyor");
        return -1;
    }
    const retained = ctxDup(ctx, h_item);
    obj.list_data.append(contextAllocator(ctx), retained) catch {
        ctxClose(ctx, retained);
        ctxErrNoMemory(ctx);
        return -1;
    };
    return 0;
}

fn ctxTupleCheck(ctx: *HPyContext, h: HPy) callconv(.c) c_int {
    _ = ctx;
    const obj = objOf(h) orelse return 0;
    return @intFromBool(obj.tag == .tuple_);
}

fn ctxTupleFromArray(ctx: *HPyContext, items: ?[*]HPy, n: isize) callconv(.c) HPy {
    if (n < 0) {
        ctxErrSetString(ctx, ctx.h_ValueError, "negatif tuple uzunluğu");
        return HPy_NULL;
    }
    const allocator = contextAllocator(ctx);
    const len: usize = @intCast(n);
    const arr = allocator.alloc(HPy, len) catch return HPy_NULL;
    const src = items orelse (&[_]HPy{}).ptr;
    for (arr, 0..) |*slot, i| slot.* = ctxDup(ctx, src[i]);

    const obj = allocator.create(Obj) catch {
        for (arr) |h2| ctxClose(ctx, h2);
        allocator.free(arr);
        return HPy_NULL;
    };
    obj.* = .{ .refcount = 1, .tag = .tuple_, .payload = .{ .l = 0 }, .tuple_data = arr };
    return .{ ._i = @intCast(@intFromPtr(obj)) };
}

fn ctxDictCheck(ctx: *HPyContext, h: HPy) callconv(.c) c_int {
    _ = ctx;
    const obj = objOf(h) orelse return 0;
    return @intFromBool(obj.tag == .dict_);
}

fn ctxDictNew(ctx: *HPyContext) callconv(.c) HPy {
    const obj = contextAllocator(ctx).create(Obj) catch return HPy_NULL;
    obj.* = .{ .refcount = 1, .tag = .dict_, .payload = .{ .l = 0 } };
    return .{ ._i = @intCast(@intFromPtr(obj)) };
}

fn ctxDictKeys(ctx: *HPyContext, h: HPy) callconv(.c) HPy {
    const obj = objOf(h) orelse return HPy_NULL;
    if (obj.tag != .dict_) {
        ctxErrSetString(ctx, ctx.h_TypeError, "dict bekleniyor");
        return HPy_NULL;
    }
    const allocator = contextAllocator(ctx);
    const result = allocator.create(Obj) catch return HPy_NULL;
    result.* = .{ .refcount = 1, .tag = .list_, .payload = .{ .l = 0 } };
    for (obj.dict_data.items) |entry| {
        result.list_data.append(allocator, ctxDup(ctx, entry.key)) catch {
            for (result.list_data.items) |h2| ctxClose(ctx, h2);
            result.list_data.deinit(allocator);
            allocator.destroy(result);
            return HPy_NULL;
        };
    }
    return .{ ._i = @intCast(@intFromPtr(result)) };
}

fn ctxDictCopy(ctx: *HPyContext, h: HPy) callconv(.c) HPy {
    const obj = objOf(h) orelse return HPy_NULL;
    if (obj.tag != .dict_) {
        ctxErrSetString(ctx, ctx.h_TypeError, "dict bekleniyor");
        return HPy_NULL;
    }
    const allocator = contextAllocator(ctx);
    const result = allocator.create(Obj) catch return HPy_NULL;
    result.* = .{ .refcount = 1, .tag = .dict_, .payload = .{ .l = 0 } };
    for (obj.dict_data.items) |entry| {
        result.dict_data.append(allocator, .{ .key = ctxDup(ctx, entry.key), .value = ctxDup(ctx, entry.value) }) catch {
            for (result.dict_data.items) |e2| {
                ctxClose(ctx, e2.key);
                ctxClose(ctx, e2.value);
            }
            result.dict_data.deinit(allocator);
            allocator.destroy(result);
            return HPy_NULL;
        };
    }
    return .{ ._i = @intCast(@intFromPtr(result)) };
}

/// Python'ın negatif indeks kuralı (`xs[-1]` son eleman) + sınır denetimi.
fn normalizeIndex(idx: isize, len: usize) ?usize {
    var i = idx;
    if (i < 0) i += @as(isize, @intCast(len));
    if (i < 0 or i >= @as(isize, @intCast(len))) return null;
    return @intCast(i);
}

fn findDictEntry(obj: *Obj, key: *Obj) ?usize {
    for (obj.dict_data.items, 0..) |entry, i| {
        if (objEquals(objOf(entry.key).?, key)) return i;
    }
    return null;
}

fn ctxGetItemI(ctx: *HPyContext, obj_h: HPy, idx: isize) callconv(.c) HPy {
    const obj = objOf(obj_h) orelse return HPy_NULL;
    switch (obj.tag) {
        .list_ => {
            const i = normalizeIndex(idx, obj.list_data.items.len) orelse {
                ctxErrSetString(ctx, ctx.h_IndexError, "liste indeksi kapsam dışı");
                return HPy_NULL;
            };
            return ctxDup(ctx, obj.list_data.items[i]);
        },
        .tuple_ => {
            const i = normalizeIndex(idx, obj.tuple_data.len) orelse {
                ctxErrSetString(ctx, ctx.h_IndexError, "tuple indeksi kapsam dışı");
                return HPy_NULL;
            };
            return ctxDup(ctx, obj.tuple_data[i]);
        },
        else => {
            ctxErrSetString(ctx, ctx.h_TypeError, "bu tip tam sayı indekslemeyi desteklemiyor");
            return HPy_NULL;
        },
    }
}

fn ctxSetItemI(ctx: *HPyContext, obj_h: HPy, idx: isize, value: HPy) callconv(.c) c_int {
    const obj = objOf(obj_h) orelse return -1;
    switch (obj.tag) {
        .list_ => {
            const i = normalizeIndex(idx, obj.list_data.items.len) orelse {
                ctxErrSetString(ctx, ctx.h_IndexError, "liste indeksi kapsam dışı");
                return -1;
            };
            const old = obj.list_data.items[i];
            obj.list_data.items[i] = ctxDup(ctx, value);
            ctxClose(ctx, old);
            return 0;
        },
        else => {
            // Tuple'lar DAHİL — tuple değişmezdir (bkz. modül üstü not).
            ctxErrSetString(ctx, ctx.h_TypeError, "bu tip öğe atamasını desteklemiyor");
            return -1;
        },
    }
}

fn ctxDelItemI(ctx: *HPyContext, obj_h: HPy, idx: isize) callconv(.c) c_int {
    const obj = objOf(obj_h) orelse return -1;
    switch (obj.tag) {
        .list_ => {
            const i = normalizeIndex(idx, obj.list_data.items.len) orelse {
                ctxErrSetString(ctx, ctx.h_IndexError, "liste indeksi kapsam dışı");
                return -1;
            };
            ctxClose(ctx, obj.list_data.orderedRemove(i));
            return 0;
        },
        else => {
            ctxErrSetString(ctx, ctx.h_TypeError, "bu tip öğe silmeyi desteklemiyor");
            return -1;
        },
    }
}

fn ctxGetItem(ctx: *HPyContext, obj_h: HPy, key_h: HPy) callconv(.c) HPy {
    const obj = objOf(obj_h) orelse return HPy_NULL;
    switch (obj.tag) {
        .list_, .tuple_ => {
            const key = objOf(key_h) orelse return HPy_NULL;
            if (key.tag != .long) {
                ctxErrSetString(ctx, ctx.h_TypeError, "liste/tuple indeksleri int olmalı");
                return HPy_NULL;
            }
            return ctxGetItemI(ctx, obj_h, key.payload.l);
        },
        .dict_ => {
            const key = objOf(key_h) orelse return HPy_NULL;
            const i = findDictEntry(obj, key) orelse {
                ctxErrSetString(ctx, ctx.h_KeyError, "anahtar bulunamadı");
                return HPy_NULL;
            };
            return ctxDup(ctx, obj.dict_data.items[i].value);
        },
        else => {
            ctxErrSetString(ctx, ctx.h_TypeError, "bu tip indekslenemez");
            return HPy_NULL;
        },
    }
}

fn ctxSetItem(ctx: *HPyContext, obj_h: HPy, key_h: HPy, value: HPy) callconv(.c) c_int {
    const obj = objOf(obj_h) orelse return -1;
    switch (obj.tag) {
        .list_, .tuple_ => {
            const key = objOf(key_h) orelse return -1;
            if (key.tag != .long) {
                ctxErrSetString(ctx, ctx.h_TypeError, "liste/tuple indeksleri int olmalı");
                return -1;
            }
            return ctxSetItemI(ctx, obj_h, key.payload.l, value);
        },
        .dict_ => {
            const key = objOf(key_h) orelse return -1;
            if (findDictEntry(obj, key)) |i| {
                const old_value = obj.dict_data.items[i].value;
                obj.dict_data.items[i].value = ctxDup(ctx, value);
                ctxClose(ctx, old_value);
                return 0;
            }
            obj.dict_data.append(contextAllocator(ctx), .{ .key = ctxDup(ctx, key_h), .value = ctxDup(ctx, value) }) catch {
                ctxErrNoMemory(ctx);
                return -1;
            };
            return 0;
        },
        else => {
            ctxErrSetString(ctx, ctx.h_TypeError, "bu tip öğe atamasını desteklemiyor");
            return -1;
        },
    }
}

fn ctxDelItem(ctx: *HPyContext, obj_h: HPy, key_h: HPy) callconv(.c) c_int {
    const obj = objOf(obj_h) orelse return -1;
    switch (obj.tag) {
        .list_ => {
            const key = objOf(key_h) orelse return -1;
            if (key.tag != .long) {
                ctxErrSetString(ctx, ctx.h_TypeError, "liste indeksleri int olmalı");
                return -1;
            }
            return ctxDelItemI(ctx, obj_h, key.payload.l);
        },
        .dict_ => {
            const key = objOf(key_h) orelse return -1;
            const i = findDictEntry(obj, key) orelse {
                ctxErrSetString(ctx, ctx.h_KeyError, "anahtar bulunamadı");
                return -1;
            };
            const entry = obj.dict_data.orderedRemove(i);
            ctxClose(ctx, entry.key);
            ctxClose(ctx, entry.value);
            return 0;
        },
        else => {
            ctxErrSetString(ctx, ctx.h_TypeError, "bu tip öğe silmeyi desteklemiyor");
            return -1;
        },
    }
}

fn ctxContains(ctx: *HPyContext, container_h: HPy, key_h: HPy) callconv(.c) c_int {
    const obj = objOf(container_h) orelse return -1;
    const key = objOf(key_h) orelse return -1;
    return switch (obj.tag) {
        .list_ => blk: {
            for (obj.list_data.items) |h| {
                if (objEquals(objOf(h).?, key)) break :blk 1;
            }
            break :blk 0;
        },
        .tuple_ => blk: {
            for (obj.tuple_data) |h| {
                if (objEquals(objOf(h).?, key)) break :blk 1;
            }
            break :blk 0;
        },
        .dict_ => @intFromBool(findDictEntry(obj, key) != null),
        .str_ => blk: {
            // Alt-dizge araması (`in` operatörünün str üzerindeki hâli).
            if (key.tag != .str_) {
                ctxErrSetString(ctx, ctx.h_TypeError, "'in' bir str bekliyor");
                break :blk -1;
            }
            break :blk @intFromBool(std.mem.indexOf(u8, obj.str_data, key.str_data) != null);
        },
        else => blk: {
            ctxErrSetString(ctx, ctx.h_TypeError, "bu tip 'in' operatörünü desteklemiyor");
            break :blk -1;
        },
    };
}

fn ctxGetItemS(ctx: *HPyContext, obj_h: HPy, utf8_key: ?[*:0]const u8) callconv(.c) HPy {
    const key_h = ctxUnicodeFromString(ctx, utf8_key);
    defer ctxClose(ctx, key_h);
    return ctxGetItem(ctx, obj_h, key_h);
}

fn ctxSetItemS(ctx: *HPyContext, obj_h: HPy, utf8_key: ?[*:0]const u8, value: HPy) callconv(.c) c_int {
    const key_h = ctxUnicodeFromString(ctx, utf8_key);
    defer ctxClose(ctx, key_h);
    return ctxSetItem(ctx, obj_h, key_h, value);
}

fn ctxDelItemS(ctx: *HPyContext, obj_h: HPy, utf8_key: ?[*:0]const u8) callconv(.c) c_int {
    const key_h = ctxUnicodeFromString(ctx, utf8_key);
    defer ctxClose(ctx, key_h);
    return ctxDelItem(ctx, obj_h, key_h);
}

// ---- Tier 1: HPyType_FromSpec — YENİ tip tanımlama (Tier 1'in en büyük,
// en yapısal parçası; buffer/iterator protokolleri de bunun üzerine
// kurulur) ----
//
// Gerçek HPy'nin `HPyType_Spec`/`HPyType_SpecParam`/`HPySlot` yapıları,
// aynı bayt-uyumluluk gerekçesiyle (bkz. modül üstü not) burada YEREL
// olarak yeniden transkribe edildi — `loader.zig`deki `HPyDef`/`HPyMeth`in
// bir kopyası (loader.zig zaten context.zig'i import ettiği için buradan
// loader.zig'e import etmek döngüsel olurdu). Tüm alan ofsetleri gerçek
// `cc`/`offsetof` çıktısıyla doğrulandı (bkz. Faz 12'nin aynı yöntemi):
// `HPyType_Spec` 56 bayt, `HPyType_SpecParam` 16 bayt, `HPySlot` 24 bayt.
//
// **Kapsam (bilinçli olarak dar):** yalnızca `basicsize` (örnek başına ham
// C struct boyutu), `HPy_tp_destroy` slotu, ve `HPyFunc_O` imzalı örnek
// metodları okunur. Taban sınıf/metaclass (`params`), `tp_new`/`tp_init`
// (örnekler `ctx_New` ile ham/sıfırlanmış olarak inşa edilir — Python'ın
// `Type(...)` çağrısıyla OTOMATİK inşa DEĞİL, bkz. `ctxNew`), member/getset
// tanımları, buffer/sequence/number slotları ve `HPy_mod_exec`-tabanlı
// modül-içi tip kaydı HENÜZ yok — bunlar sonraki dilimlerdir.

pub const HPyType_Spec = extern struct {
    name: ?[*:0]const u8 = null,
    basicsize: c_int = 0,
    itemsize: c_int = 0,
    flags: c_ulong = 0,
    builtin_shape: c_int = 0,
    legacy_slots: ?*anyopaque = null,
    defines: ?[*:null]const ?*const HPyDefLocal = null,
    doc: ?[*:0]const u8 = null,
};

pub const HPyType_SpecParam = extern struct {
    kind: c_int = 0,
    object: HPy = HPy_NULL,
};

const HPyMethLocal = extern struct {
    name: ?[*:0]const u8 = null,
    impl: ?*const anyopaque = null,
    cpy_trampoline: ?*const anyopaque = null,
    signature: c_int = 0,
    doc: ?[*:0]const u8 = null,
};
const HPySlotLocal = extern struct {
    slot: c_int = 0,
    impl: ?*const anyopaque = null,
    cpy_trampoline: ?*const anyopaque = null,
};
const HPyDefLocal = extern struct {
    kind: c_int = 0,
    meth: HPyMethLocal = .{},
    _pad_tail: [16]u8 = undefined,
};
/// `.meth`in adresi, C'deki adsız union'ın (bkz. `hpydef.h`) başlangıç
/// ofsetiyle (8) AYNIDIR — bu yüzden aynı baytları `HPySlotLocal` olarak
/// yeniden yorumlamak güvenlidir (her iki struct'ın `impl` alanı da
/// offset 8'de — doğrulandı, bkz. modül üstü not).
fn slotOfLocal(d: *const HPyDefLocal) *const HPySlotLocal {
    return @ptrCast(@alignCast(&d.meth));
}

const HPY_DEF_KIND_SLOT: c_int = 1;
const HPY_DEF_KIND_METH: c_int = 2;
const HPY_FUNC_SIG_O: c_int = 4;
const HPY_SLOT_TP_DESTROY: c_int = 1000; // bkz. autogen_hpyslot.h
// Çağrılabilir nesne protokolü (bkz. `Obj.type_tp_call`ın belge notu) —
// `autogen_hpyslot.h`e karşı doğrulandı.
const HPY_SLOT_TP_CALL: c_int = 50; // HPyFunc_KEYWORDS imzalı
const HPY_SLOT_TP_INIT: c_int = 60; // HPyFunc_INITPROC imzalı
const HPY_SLOT_TP_NEW: c_int = 65; // HPyFunc_NEWFUNC imzalı

fn ctxTypeFromSpec(ctx: *HPyContext, spec: ?*HPyType_Spec, params: ?*HPyType_SpecParam) callconv(.c) HPy {
    // Taban sınıf/metaclass parametreleri şu an yok sayılıyor (bkz. modül
    // üstü kapsam notu) — tüm tipler örtük olarak `object`ten türer.
    _ = params;
    const s = spec orelse return HPy_NULL;
    if (s.basicsize < 0) {
        ctxErrSetString(ctx, ctx.h_ValueError, "geçersiz basicsize");
        return HPy_NULL;
    }
    const allocator = contextAllocator(ctx);
    const obj = allocator.create(Obj) catch return HPy_NULL;
    obj.* = .{ .refcount = 1, .tag = .type_, .payload = .{ .l = 0 } };
    obj.type_basicsize = @intCast(s.basicsize);

    if (s.defines) |defs| {
        var i: usize = 0;
        while (defs[i]) |d| : (i += 1) {
            if (d.kind == HPY_DEF_KIND_SLOT) {
                const sl = slotOfLocal(d);
                if (sl.slot == HPY_SLOT_TP_DESTROY) {
                    if (sl.impl) |impl| obj.type_tp_destroy = @ptrCast(@alignCast(impl));
                } else if (sl.slot == HPY_SLOT_TP_NEW) {
                    if (sl.impl) |impl| obj.type_tp_new = @ptrCast(@alignCast(impl));
                } else if (sl.slot == HPY_SLOT_TP_INIT) {
                    if (sl.impl) |impl| obj.type_tp_init = @ptrCast(@alignCast(impl));
                } else if (sl.slot == HPY_SLOT_TP_CALL) {
                    if (sl.impl) |impl| obj.type_tp_call = @ptrCast(@alignCast(impl));
                }
            } else if (d.kind == HPY_DEF_KIND_METH) {
                if (d.meth.signature == HPY_FUNC_SIG_O) {
                    if (d.meth.name != null and d.meth.impl != null) {
                        obj.type_methods.append(allocator, .{
                            .name = d.meth.name.?,
                            .impl = @ptrCast(@alignCast(d.meth.impl.?)),
                        }) catch {};
                    }
                }
            }
        }
    }
    return .{ ._i = @intCast(@intFromPtr(obj)) };
}

/// Gerçek HPy sözleşmesi: `h_type`in `basicsize` baytlık, SIFIRLANMIŞ bir
/// örneğini inşa eder, `*data`ya ham struct işaretçisini yazar (eklenti
/// bunu kendi C struct tipine cast eder). `tp_new`/`tp_init` ÇAĞIRMAZ —
/// bkz. bölüm üstü kapsam notu.
fn ctxNew(ctx: *HPyContext, h_type: HPy, data: ?*?*anyopaque) callconv(.c) HPy {
    const type_obj = objOf(h_type) orelse return HPy_NULL;
    if (type_obj.tag != .type_) {
        ctxErrSetString(ctx, ctx.h_TypeError, "tip bekleniyor");
        return HPy_NULL;
    }
    const allocator = contextAllocator(ctx);
    const buf = allocator.alloc(u8, type_obj.type_basicsize) catch return HPy_NULL;
    @memset(buf, 0);
    const obj = allocator.create(Obj) catch {
        allocator.free(buf);
        return HPy_NULL;
    };
    obj.* = .{
        .refcount = 1,
        .tag = .instance_,
        .payload = .{ .l = 0 },
        .instance_type = ctxDup(ctx, h_type),
        .instance_data = buf,
    };
    if (data) |out| out.* = buf.ptr;
    return .{ ._i = @intCast(@intFromPtr(obj)) };
}

/// Bir örneğin ham struct işaretçisini döndürür (eklenti kendi C tipine
/// cast eder) — `tag != .instance_` ise `null`.
fn ctxAsStructObject(ctx: *HPyContext, h: HPy) callconv(.c) ?*anyopaque {
    _ = ctx;
    const obj = objOf(h) orelse return null;
    if (obj.tag != .instance_) return null;
    return obj.instance_data.ptr;
}

/// `h`nin tipini döndürür. **Kapsam:** yalnızca `.instance_` için anlamlı
/// bir şey döner (kendi `type_` nesnesi, `ctxDup` ile) — yerleşik tipler
/// (`long`/`float_`/...) için karşılık gelen `h_LongType`/... tekilleri
/// HENÜZ doldurulmadığından `HPy_NULL` döner (bilinçli sınırlama).
fn ctxType(ctx: *HPyContext, obj_h: HPy) callconv(.c) HPy {
    const obj = objOf(obj_h) orelse return HPy_NULL;
    if (obj.tag == .instance_) return ctxDup(ctx, obj.instance_type);
    return HPy_NULL;
}

/// `obj`nin TAM OLARAK `type` tipinde (alt sınıflama YOK, bkz. kapsam notu)
/// bir örnek olup olmadığını denetler.
fn ctxTypeCheck(ctx: *HPyContext, obj_h: HPy, type_h: HPy) callconv(.c) c_int {
    _ = ctx;
    const obj = objOf(obj_h) orelse return 0;
    if (obj.tag != .instance_) return 0;
    return @intFromBool(obj.instance_type._i == type_h._i);
}

// ---- Attribute erişimi ----
//
// `ctx_GetAttr`/`ctx_GetAttr_s`/`ctx_HasAttr`/`ctx_HasAttr_s`/`ctx_SetAttr`/
// `ctx_SetAttr_s`. Python'ın varsayılan `tp_getattro`sunun (`_PyObject_
// GenericGetAttr`) BASİTLEŞTİRİLMİŞ bir karşılığı — SIRA: (a) örneğin
// KENDİ `instance_dict`i (Nox'un `ctx_SetAttr`/`_s` İLE EKLEDİĞİ
// attribute'lar), (b) tipin `type_methods`i (BULUNURSA bir `.bound_
// method_` nesnesine SARILIR — Python'ın `instance.method`inin `self`i
// TAŞIYAN bağlı metoduyla AYNI fikir).
//
// **Bilinçli v1 sınırlaması:** `.type_` tutamaçları ÜZERİNDEN DOĞRUDAN
// attribute erişimi (sınıf-seviyesi/unbound erişim, ör. `SomeType.attr`)
// desteklenmiyor — gerçek kullanım örüntülerinde ÖRNEK erişimi ÇOK daha
// yaygın, kapsam bilinçli olarak dar tutuldu.
fn findDictEntryStr(list: *std.ArrayListUnmanaged(Obj.DictEntry), name: []const u8) ?usize {
    for (list.items, 0..) |entry, i| {
        const key = objOf(entry.key) orelse continue;
        if (key.tag == .str_ and std.mem.eql(u8, key.str_data, name)) return i;
    }
    return null;
}

/// Hata AYARLAMAYAN iç yardımcı — HEM `ctxGetAttr` HEM `ctxHasAttr` bunu
/// PAYLAŞIR (`hasattr`in Python'da AttributeError'ı YUTMASı semantiğiyle
/// TUTARLI, bkz. çağıranların KENDİ hata ayarlama sorumluluğu). `obj_h`,
/// bulunan bir `type_methods` girişini bir `.bound_method_` nesnesine
/// SARARKEN `self` OLARAK retain etmek İçin GEREKİR.
fn attrLookup(ctx: *HPyContext, obj_h: HPy, obj: *Obj, name: []const u8) ?HPy {
    if (obj.tag != .instance_) return null;
    if (findDictEntryStr(&obj.instance_dict, name)) |i| {
        return ctxDup(ctx, obj.instance_dict.items[i].value);
    }
    if (findTypeMethodO(obj.instance_type, name)) |method| {
        const allocator = contextAllocator(ctx);
        const bm = allocator.create(Obj) catch return null;
        bm.* = .{
            .refcount = 1,
            .tag = .bound_method_,
            .payload = .{ .l = 0 },
            .bound_method_self = ctxDup(ctx, obj_h),
            .bound_method_impl = method.impl,
        };
        return .{ ._i = @intCast(@intFromPtr(bm)) };
    }
    return null;
}

fn ctxGetAttr(ctx: *HPyContext, obj_h: HPy, name_h: HPy) callconv(.c) HPy {
    const obj = objOf(obj_h) orelse {
        ctxErrSetString(ctx, ctx.h_TypeError, "geçersiz nesne");
        return HPy_NULL;
    };
    const name_obj = objOf(name_h) orelse {
        ctxErrSetString(ctx, ctx.h_TypeError, "attribute adı str olmalı");
        return HPy_NULL;
    };
    if (name_obj.tag != .str_) {
        ctxErrSetString(ctx, ctx.h_TypeError, "attribute adı str olmalı");
        return HPy_NULL;
    }
    return attrLookup(ctx, obj_h, obj, name_obj.str_data) orelse {
        ctxErrSetString(ctx, ctx.h_AttributeError, "böyle bir attribute yok");
        return HPy_NULL;
    };
}

fn ctxGetAttrS(ctx: *HPyContext, obj_h: HPy, utf8_name: ?[*:0]const u8) callconv(.c) HPy {
    const name_h = ctxUnicodeFromString(ctx, utf8_name);
    defer ctxClose(ctx, name_h);
    return ctxGetAttr(ctx, obj_h, name_h);
}

fn ctxHasAttr(ctx: *HPyContext, obj_h: HPy, name_h: HPy) callconv(.c) c_int {
    const obj = objOf(obj_h) orelse return 0;
    const name_obj = objOf(name_h) orelse return 0;
    if (name_obj.tag != .str_) return 0;
    const found = attrLookup(ctx, obj_h, obj, name_obj.str_data) orelse return 0;
    ctxClose(ctx, found);
    return 1;
}

fn ctxHasAttrS(ctx: *HPyContext, obj_h: HPy, utf8_name: ?[*:0]const u8) callconv(.c) c_int {
    const name_h = ctxUnicodeFromString(ctx, utf8_name);
    defer ctxClose(ctx, name_h);
    return ctxHasAttr(ctx, obj_h, name_h);
}

/// Yalnızca `.instance_` üzerinde çalışır — Nox'un `instance_dict`ine
/// (bkz. `Obj.instance_dict`in belge notu) EKLE/GÜNCELLE. `ctxSetItem`in
/// dict-güncelleme dalıyla AYNI sahiplik deseni: anahtar VE değer İKİSİ
/// DE `ctxDup` ile SAKLANIR (çağıranın kendi tutamacından BAĞIMSIZ).
fn ctxSetAttr(ctx: *HPyContext, obj_h: HPy, name_h: HPy, value: HPy) callconv(.c) c_int {
    const obj = objOf(obj_h) orelse return -1;
    if (obj.tag != .instance_) {
        ctxErrSetString(ctx, ctx.h_TypeError, "bu tip attribute atamasını desteklemiyor");
        return -1;
    }
    const name_obj = objOf(name_h) orelse return -1;
    if (name_obj.tag != .str_) {
        ctxErrSetString(ctx, ctx.h_TypeError, "attribute adı str olmalı");
        return -1;
    }
    if (findDictEntryStr(&obj.instance_dict, name_obj.str_data)) |i| {
        const old_value = obj.instance_dict.items[i].value;
        obj.instance_dict.items[i].value = ctxDup(ctx, value);
        ctxClose(ctx, old_value);
        return 0;
    }
    obj.instance_dict.append(contextAllocator(ctx), .{ .key = ctxDup(ctx, name_h), .value = ctxDup(ctx, value) }) catch {
        ctxErrNoMemory(ctx);
        return -1;
    };
    return 0;
}

fn ctxSetAttrS(ctx: *HPyContext, obj_h: HPy, utf8_name: ?[*:0]const u8, value: HPy) callconv(.c) c_int {
    const name_h = ctxUnicodeFromString(ctx, utf8_name);
    defer ctxClose(ctx, name_h);
    return ctxSetAttr(ctx, obj_h, name_h, value);
}

// ---- Çağrılabilir nesne protokolü ----
//
// `ctx_Callable_Check`/`ctx_Call`/`ctx_CallTupleDict`/`ctx_SetCallFunction`/
// `ctx_CallRealFunctionFromTrampoline`/`ctx_CallMethod` (Faz OO, `ctx_
// GetAttr` ailesi — Faz NN — hazır olduktan SONRA eklendi, bkz. aşağıda
// `ctxCallMethod`). Bu dilimin en önemli katkısı:
// `HPyType_FromSpec` ile oluşturulmuş bir tipi `SomeType(args)` şeklinde
// GERÇEKTEN inşa edebilmek — CPython'ın `type.__call__`ının (alloc via
// `tp_new`, ardından `tp_init`) BİREBİR karşılığı. `ctxNew` (yukarıda)
// bunu YAPMAZ — `tp_new` KENDİSİ eklentinin C kodudur ve `HPy_New`
// (yani `ctxNew`) makrosunu KENDİSİ çağırır; bu fonksiyonlar `ctxNew`i
// TEKRAR ÇAĞIRMAZ, yalnızca eklentinin kayıtlı `tp_new`/`tp_init`ını
// invoke eder.
//
// **Bilinçli v1 sınırlaması:** `kwnames`/`kw` (anahtar kelime argümanları)
// BOŞ OLMAYAN bir değer taşıyorsa `TypeError` ile reddedilir — nesne
// modelinde henüz genel bir dict-tabanlı kwarg açma sözleşmesi yok
// (`HPyType_FromSpec`in KENDİ taban-sınıf/metaclass/buffer-slot kapsam
// dışı bırakmasıyla AYNI ilke). `ctx_CallMethod` (Faz OO) da AYNI
// sınırlamaya tabidir.
fn callDispatch(ctx: *HPyContext, callable: HPy, args: ?[*]const HPy, nargs: usize, kwnames: HPy) HPy {
    if (kwnames._i != 0) {
        ctxErrSetString(ctx, ctx.h_TypeError, "anahtar kelime argümanları henüz desteklenmiyor");
        return HPy_NULL;
    }
    const obj = objOf(callable) orelse {
        ctxErrSetString(ctx, ctx.h_TypeError, "çağrılabilir değil");
        return HPy_NULL;
    };
    switch (obj.tag) {
        .type_ => return constructInstance(ctx, callable, obj, args, nargs),
        .instance_ => {
            const type_obj = objOf(obj.instance_type) orelse {
                ctxErrSetString(ctx, ctx.h_TypeError, "çağrılabilir değil");
                return HPy_NULL;
            };
            const call_fn = type_obj.type_tp_call orelse {
                ctxErrSetString(ctx, ctx.h_TypeError, "çağrılabilir değil");
                return HPy_NULL;
            };
            return call_fn(ctx, callable, args, nargs, HPy_NULL);
        },
        .bound_method_ => {
            // `attrLookup`in sardığı metodlar HER ZAMAN `HPyFunc_O`
            // imzalı (bkz. `TypeMethod`in belge notu) — tam olarak BİR
            // argüman gerektirir.
            if (nargs != 1 or args == null) {
                ctxErrSetString(ctx, ctx.h_TypeError, "bu yöntem tam olarak bir argüman alır");
                return HPy_NULL;
            }
            const impl = obj.bound_method_impl orelse {
                ctxErrSetString(ctx, ctx.h_TypeError, "çağrılabilir değil");
                return HPy_NULL;
            };
            return impl(ctx, obj.bound_method_self, args.?[0]);
        },
        else => {
            ctxErrSetString(ctx, ctx.h_TypeError, "çağrılabilir değil");
            return HPy_NULL;
        },
    }
}

/// CPython'ın `type.__call__`ının karşılığı: `tp_new` (varsa) ile inşa
/// eder, ARDINDAN `tp_init` (varsa) ile ilklendirir — İKİSİ DE eklentinin
/// KENDİ C kodu (bkz. modül üstü not, bu fonksiyon `ctxNew`i ÇAĞIRMAZ).
fn constructInstance(ctx: *HPyContext, type_h: HPy, type_obj: *Obj, args: ?[*]const HPy, nargs: usize) HPy {
    const new_fn = type_obj.type_tp_new orelse {
        ctxErrSetString(ctx, ctx.h_TypeError, "tip inşa edilemiyor: tp_new yok");
        return HPy_NULL;
    };
    const instance = new_fn(ctx, type_h, args, @intCast(nargs), HPy_NULL);
    if (instance._i == 0) return HPy_NULL; // tp_new zaten hata ayarladı (ya da NULL döndü)

    if (type_obj.type_tp_init) |init_fn| {
        const rc = init_fn(ctx, instance, args, @intCast(nargs), HPy_NULL);
        if (rc < 0) {
            // CPython'ın `type.__call__`ının AYNI savunma desenine
            // paralel: tp_init `-1` dönüp KENDİ istisnasını AYARLAMADIYSA
            // (kötü davranan bir eklenti), sessizce boş bir hata bırakmak
            // yerine GENEL bir tane ayarla.
            if (ctxErrOccurred(ctx) == 0) {
                ctxErrSetString(ctx, ctx.h_RuntimeError, "tp_init başarısız oldu ama istisna ayarlamadı");
            }
            ctxClose(ctx, instance);
            return HPy_NULL;
        }
    }
    return instance;
}

fn ctxCall(ctx: *HPyContext, callable: HPy, args: ?[*]const HPy, nargs: usize, kwnames: HPy) callconv(.c) HPy {
    return callDispatch(ctx, callable, args, nargs, kwnames);
}

/// Gerçek `PyCallable_Check` semantiğiyle TUTARLI: bir TİP her zaman
/// "çağrılabilir" sayılır (`tp_new` eksik OLSA BİLE — hata yalnızca
/// GERÇEK çağrı ANINDA, `constructInstance`de yüzeye çıkar). Bir ÖRNEK
/// İSE yalnızca kendi tipi `tp_call` KAYDETTİYSE çağrılabilir.
fn ctxCallableCheck(ctx: *HPyContext, h: HPy) callconv(.c) c_int {
    _ = ctx;
    const obj = objOf(h) orelse return 0;
    return switch (obj.tag) {
        .type_ => 1,
        .instance_ => blk: {
            const type_obj = objOf(obj.instance_type) orelse break :blk 0;
            break :blk @intFromBool(type_obj.type_tp_call != null);
        },
        .bound_method_ => 1,
        else => 0,
    };
}

/// Gerçek imza: `args`/`kw` HAM bir işaretçi+sayı DEĞİL, bir tuple/dict
/// TUTAMACIDIR — `args_tuple`in `.tuple_` OLDUĞU doğrulanır, `tuple_data`
/// (zaten sahiplenilen `[]HPy`) KOPYASIZ olarak `callDispatch`e verilir.
fn ctxCallTupleDict(ctx: *HPyContext, callable: HPy, args_tuple: HPy, kw: HPy) callconv(.c) HPy {
    if (kw._i != 0) {
        if (objOf(kw)) |kw_obj| {
            if (kw_obj.tag == .dict_ and kw_obj.dict_data.items.len > 0) {
                ctxErrSetString(ctx, ctx.h_TypeError, "anahtar kelime argümanları henüz desteklenmiyor");
                return HPy_NULL;
            }
        }
    }
    const args_obj = objOf(args_tuple) orelse {
        ctxErrSetString(ctx, ctx.h_TypeError, "args tuple bekleniyor");
        return HPy_NULL;
    };
    if (args_obj.tag != .tuple_) {
        ctxErrSetString(ctx, ctx.h_TypeError, "args tuple bekleniyor");
        return HPy_NULL;
    }
    const items = args_obj.tuple_data;
    return callDispatch(ctx, callable, items.ptr, items.len, HPy_NULL);
}

/// Gerçek HPy sözleşmesi (bkz. `ctx_call.c`nin `PyObject_VectorcallMethod`
/// TABANLI implementasyonu — GERÇEK CPython dahi bunu bir `GetAttr` +
/// çağrı olarak uygular): `args[0]` ALICI (self)dır, `args[1..nargs)`
/// GERÇEK çağrı argümanlarıdır (`nargs` ALICIYI DA SAYAR). `name`,
/// alıcı üzerinde `attrLookup` (Faz NN) İLE ARANIR — BULUNAN metod
/// (adi bir örnek/tip DEĞİLSE, TİPİK OLARAK bir `.bound_method_`)
/// KALAN argümanlarla `callDispatch`e delege edilir. `ctx_GetAttr`in
/// KENDİSİ ZATEN "böyle bir attribute yok" İçin `AttributeError`
/// ayarladığından, BURADA AYRICA hata AYARLAMAYA gerek YOK.
fn ctxCallMethod(ctx: *HPyContext, name_h: HPy, args: ?[*]const HPy, nargs: usize, kwnames: HPy) callconv(.c) HPy {
    if (kwnames._i != 0) {
        ctxErrSetString(ctx, ctx.h_TypeError, "anahtar kelime argümanları henüz desteklenmiyor");
        return HPy_NULL;
    }
    if (nargs < 1 or args == null) {
        ctxErrSetString(ctx, ctx.h_TypeError, "ctx_CallMethod en az bir alıcı (self) argümanı gerektirir");
        return HPy_NULL;
    }
    const receiver = args.?[0];
    const method = ctxGetAttr(ctx, receiver, name_h);
    if (method._i == 0) return HPy_NULL; // ctxGetAttr zaten AttributeError ayarladı
    defer ctxClose(ctx, method);
    const call_args = args.?[1..nargs];
    return callDispatch(ctx, method, if (call_args.len > 0) call_args.ptr else null, call_args.len, HPy_NULL);
}

/// Gerçek HPy sözleşmesi: `h`in bir TİP olmasını gerektirir (`tp_call`ı
/// `HPyType_FromSpec`in `HPy_tp_call` slotu DIŞINDA, sonradan kaydetmenin
/// bir yolu — ör. kapatma/partial nesneleri İçin). `func.impl`, `type_
/// tp_call`a AYNI alana yazılır (slot-tabanlı KAYIT İLE aynı alan,
/// çünkü ikisi de "bu tipin örnekleri nasıl çağrılır" sorusuna cevaptır).
const HPyCallFunctionLocal = extern struct {
    cpy_trampoline: ?*const anyopaque = null,
    impl: ?*const anyopaque = null,
};

fn ctxSetCallFunction(ctx: *HPyContext, h: HPy, func: ?*HPyCallFunctionLocal) callconv(.c) c_int {
    const obj = objOf(h) orelse return -1;
    if (obj.tag != .type_) {
        ctxErrSetString(ctx, ctx.h_TypeError, "tip bekleniyor");
        return -1;
    }
    const f = func orelse return -1;
    if (f.impl) |impl| obj.type_tp_call = @ptrCast(@alignCast(impl));
    return 0;
}

/// Gerçek HPy'de bu fonksiyon, CPython'ın ÜRETTİĞİ vectorcall
/// trampolinlerinden (`cpy_trampoline`) çağrılır — Nox eklentilere
/// DOĞRUDAN çağrı yaptığından (bkz. `loader.zig`nin modül üstü notu,
/// `cpy_trampoline` alanı HİÇBİR YERDE okunmaz/tetiklenmez, yalnızca
/// bayt-düzeni İçin saklanır) bu fonksiyona GERÇEK bir çağrı yolu
/// YOKTUR. "Sahte ama gerçek görünen" bir switch-and-cast gövdesi
/// (gerçek HPy'nin arg-blob'ları `cpy_PyObject*` şeklinde olduğundan,
/// Nox'un `HPy` tutamaçlarıyla ANLAMLI şekilde eşleştirilemez) hem
/// YAZILAMAZ hem test EDİLEMEZ olurdu — bu yüzden bilinçli olarak
/// dokümante edilmiş bir `@panic` ile bırakılır (ABI yuvası doğru/
/// non-null bağlanır, ama gövdesi hiçbir gerçek çağrı yolundan
/// ULAŞILAMAYACAĞI İçin sahte bir implementasyon yazılmaz).
fn ctxCallRealFunctionFromTrampoline(ctx: *HPyContext, sig: c_int, func: ?*const anyopaque, args: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    _ = sig;
    _ = func;
    _ = args;
    @panic("ctx_CallRealFunctionFromTrampoline: Nox mimarisinde gerçek bir çağrı yolu yok (bkz. modül üstü not)");
}

/// Nox-özel (HPy ABI'sinin bir parçası DEĞİL) bir yardımcı: bir `type_`
/// nesnesinin `HPyFunc_O` imzalı örnek metodlarından adı `name` olanı
/// bulur. Gerçek HPy'de bu, genel `GetAttr`/çağrı protokolü (henüz
/// desteklenmiyor) üzerinden dolaylı olarak olur — bu, doğrudan test/
/// tanılama amaçlı bir kısayoldur (bkz. `tests/compat/hpy_tier0_test.zig`).
pub fn findTypeMethodO(h_type: HPy, name: []const u8) ?TypeMethod {
    const obj = objOf(h_type) orelse return null;
    if (obj.tag != .type_) return null;
    for (obj.type_methods.items) |m| {
        if (std.mem.eql(u8, std.mem.sliceTo(m.name, 0), name)) return m;
    }
    return null;
}

// ---- Tier 1'in ilk dilimi: sayı protokolü (aritmetik) ----
//
// Nox'un nesne modeli yalnızca `long`/`float_`/`bool_`i "sayısal" sayar
// (Python'ın `int`/`float`/`bool` alt kümesi — `complex` yok). Tip
// yükseltme kuralı Python'la aynı: işlenenlerden biri float ise sonuç
// float'tır. Tam sayı taşması Nox'un kendi `int`iyle (bkz. compiler/
// codegen_qbe/codegen.zig, tight_loop_arithmetic benchmark) TUTARLI olacak
// şekilde sessizce sarılır (`+%`/`-%`/`*%`).

fn isNumericTag(tag: ObjTag) bool {
    return tag == .long or tag == .float_ or tag == .bool_;
}

fn numAsF64(obj: *Obj) f64 {
    return switch (obj.tag) {
        .long => @floatFromInt(obj.payload.l),
        .float_ => obj.payload.f,
        .bool_ => if (obj.payload.b) 1 else 0,
        else => unreachable,
    };
}

fn numAsI64(obj: *Obj) i64 {
    return switch (obj.tag) {
        .long => obj.payload.l,
        .bool_ => if (obj.payload.b) 1 else 0,
        .float_ => @intFromFloat(obj.payload.f),
        else => unreachable,
    };
}

const NumOp = enum { add, sub, mul, floordiv, truediv, mod };

fn numericBinOp(ctx: *HPyContext, h1: HPy, h2: HPy, op: NumOp) HPy {
    const o1 = objOf(h1) orelse return HPy_NULL;
    const o2 = objOf(h2) orelse return HPy_NULL;
    if (!isNumericTag(o1.tag) or !isNumericTag(o2.tag)) {
        ctxErrSetString(ctx, ctx.h_TypeError, "desteklenmeyen işlenen tipi (yalnızca int/float/bool)");
        return HPy_NULL;
    }

    const use_float = op == .truediv or o1.tag == .float_ or o2.tag == .float_;
    if (use_float) {
        const a = numAsF64(o1);
        const b = numAsF64(o2);
        if ((op == .truediv or op == .floordiv or op == .mod) and b == 0) {
            ctxErrSetString(ctx, ctx.h_ZeroDivisionError, "sıfıra bölme");
            return HPy_NULL;
        }
        const r: f64 = switch (op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .truediv => a / b,
            .floordiv => @divFloor(a, b),
            .mod => @mod(a, b),
        };
        return ctxFloatFromDouble(ctx, r);
    }

    const a = numAsI64(o1);
    const b = numAsI64(o2);
    if ((op == .floordiv or op == .mod) and b == 0) {
        ctxErrSetString(ctx, ctx.h_ZeroDivisionError, "sıfıra bölme");
        return HPy_NULL;
    }
    const r: i64 = switch (op) {
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
        .floordiv => @divFloor(a, b),
        .mod => @mod(a, b),
        .truediv => unreachable, // use_float zaten true olurdu
    };
    return ctxLongFromInt64(ctx, r);
}

fn ctxAdd(ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy {
    return numericBinOp(ctx, h1, h2, .add);
}
fn ctxSubtract(ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy {
    return numericBinOp(ctx, h1, h2, .sub);
}
fn ctxMultiply(ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy {
    return numericBinOp(ctx, h1, h2, .mul);
}
fn ctxTrueDivide(ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy {
    return numericBinOp(ctx, h1, h2, .truediv);
}
fn ctxFloorDivide(ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy {
    return numericBinOp(ctx, h1, h2, .floordiv);
}
fn ctxRemainder(ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy {
    return numericBinOp(ctx, h1, h2, .mod);
}

fn ctxNegative(ctx: *HPyContext, h1: HPy) callconv(.c) HPy {
    const o1 = objOf(h1) orelse return HPy_NULL;
    if (!isNumericTag(o1.tag)) {
        ctxErrSetString(ctx, ctx.h_TypeError, "desteklenmeyen işlenen tipi");
        return HPy_NULL;
    }
    if (o1.tag == .float_) return ctxFloatFromDouble(ctx, -numAsF64(o1));
    return ctxLongFromInt64(ctx, -%numAsI64(o1));
}

fn ctxAbsolute(ctx: *HPyContext, h1: HPy) callconv(.c) HPy {
    const o1 = objOf(h1) orelse return HPy_NULL;
    if (!isNumericTag(o1.tag)) {
        ctxErrSetString(ctx, ctx.h_TypeError, "desteklenmeyen işlenen tipi");
        return HPy_NULL;
    }
    if (o1.tag == .float_) return ctxFloatFromDouble(ctx, @abs(numAsF64(o1)));
    return ctxLongFromInt64(ctx, @intCast(@abs(numAsI64(o1))));
}

// ---- Tier 0 tamamlama: hata yönetimi ----
//
// Gerçek CPython/HPy'de bekleyen istisna interpreter'ın thread-state'inde
// tutulur; burada gerçek bir yorumlayıcı OLMADIĞI için (bkz. modül üstü
// not — Nox kendi başına bir "universal ABI ana bilgisayarı") bu durumu
// `PrivateState.pending_error`de (bağlam başına TEK bir yuva) tutuyoruz.
// Bu, bu köprünün henüz Nox'un kendi `raise`/`try`/`except`iyle ENTEGRE
// olmadığı (bkz. Faz 14'ün bilinçli sınırlaması) gerçeğini değiştirmez —
// yalnızca bir C eklentisinin `HPyErr_SetString`/`HPyErr_Occurred` gibi
// standart HPy API'lerini DOĞRU biçimde kullanabilmesini sağlar.

fn ctxErrSetString(ctx: *HPyContext, h_type: HPy, utf8_message: ?[*:0]const u8) callconv(.c) void {
    const state = contextState(ctx);
    const allocator = state.allocator;
    if (state.pending_error) |pe| allocator.free(pe.message);
    const msg = utf8_message orelse "";
    const copy = allocator.dupeZ(u8, std.mem.sliceTo(msg, 0)) catch {
        state.pending_error = null;
        return;
    };
    state.pending_error = .{ .h_type = h_type, .message = copy };
}

fn ctxErrOccurred(ctx: *HPyContext) callconv(.c) c_int {
    return @intFromBool(contextState(ctx).pending_error != null);
}

fn ctxErrClear(ctx: *HPyContext) callconv(.c) void {
    const state = contextState(ctx);
    if (state.pending_error) |pe| {
        state.allocator.free(pe.message);
        state.pending_error = null;
    }
}

fn ctxErrExceptionMatches(ctx: *HPyContext, exc: HPy) callconv(.c) c_int {
    const pe = contextState(ctx).pending_error orelse return 0;
    return @intFromBool(pe.h_type._i == exc._i);
}

fn ctxErrNoMemory(ctx: *HPyContext) callconv(.c) void {
    ctxErrSetString(ctx, ctx.h_MemoryError, "bellek yetersiz");
}

/// `_private`, `contextState`in geri döndürdüğü sabit bilgiye işaret eder —
/// yalnızca bu köprünün İÇ kullanımı içindir, HPy ABI'sinin bir parçası
/// değildir (spec bu alanı "implementasyona özel" olarak ayırır).
const PrivateState = struct {
    allocator: std.mem.Allocator,
    h_true_obj: HPy,
    h_false_obj: HPy,
    pending_error: ?PendingError = null,

    const PendingError = struct {
        h_type: HPy,
        message: [:0]u8,
    };
};

fn contextState(ctx: *HPyContext) *PrivateState {
    return @ptrCast(@alignCast(ctx._private.?));
}

fn contextAllocator(ctx: *HPyContext) std.mem.Allocator {
    return contextState(ctx).allocator;
}

pub const HPyContext = extern struct {
    name: ?[*:0]const u8 = null,
    _private: ?*anyopaque = null,
    abi_version: c_int = 0,
    h_None: HPy = HPy_NULL,
    h_True: HPy = HPy_NULL,
    h_False: HPy = HPy_NULL,
    h_NotImplemented: HPy = HPy_NULL,
    h_Ellipsis: HPy = HPy_NULL,
    h_BaseException: HPy = HPy_NULL,
    h_Exception: HPy = HPy_NULL,
    h_StopAsyncIteration: HPy = HPy_NULL,
    h_StopIteration: HPy = HPy_NULL,
    h_GeneratorExit: HPy = HPy_NULL,
    h_ArithmeticError: HPy = HPy_NULL,
    h_LookupError: HPy = HPy_NULL,
    h_AssertionError: HPy = HPy_NULL,
    h_AttributeError: HPy = HPy_NULL,
    h_BufferError: HPy = HPy_NULL,
    h_EOFError: HPy = HPy_NULL,
    h_FloatingPointError: HPy = HPy_NULL,
    h_OSError: HPy = HPy_NULL,
    h_ImportError: HPy = HPy_NULL,
    h_ModuleNotFoundError: HPy = HPy_NULL,
    h_IndexError: HPy = HPy_NULL,
    h_KeyError: HPy = HPy_NULL,
    h_KeyboardInterrupt: HPy = HPy_NULL,
    h_MemoryError: HPy = HPy_NULL,
    h_NameError: HPy = HPy_NULL,
    h_OverflowError: HPy = HPy_NULL,
    h_RuntimeError: HPy = HPy_NULL,
    h_RecursionError: HPy = HPy_NULL,
    h_NotImplementedError: HPy = HPy_NULL,
    h_SyntaxError: HPy = HPy_NULL,
    h_IndentationError: HPy = HPy_NULL,
    h_TabError: HPy = HPy_NULL,
    h_ReferenceError: HPy = HPy_NULL,
    h_SystemError: HPy = HPy_NULL,
    h_SystemExit: HPy = HPy_NULL,
    h_TypeError: HPy = HPy_NULL,
    h_UnboundLocalError: HPy = HPy_NULL,
    h_UnicodeError: HPy = HPy_NULL,
    h_UnicodeEncodeError: HPy = HPy_NULL,
    h_UnicodeDecodeError: HPy = HPy_NULL,
    h_UnicodeTranslateError: HPy = HPy_NULL,
    h_ValueError: HPy = HPy_NULL,
    h_ZeroDivisionError: HPy = HPy_NULL,
    h_BlockingIOError: HPy = HPy_NULL,
    h_BrokenPipeError: HPy = HPy_NULL,
    h_ChildProcessError: HPy = HPy_NULL,
    h_ConnectionError: HPy = HPy_NULL,
    h_ConnectionAbortedError: HPy = HPy_NULL,
    h_ConnectionRefusedError: HPy = HPy_NULL,
    h_ConnectionResetError: HPy = HPy_NULL,
    h_FileExistsError: HPy = HPy_NULL,
    h_FileNotFoundError: HPy = HPy_NULL,
    h_InterruptedError: HPy = HPy_NULL,
    h_IsADirectoryError: HPy = HPy_NULL,
    h_NotADirectoryError: HPy = HPy_NULL,
    h_PermissionError: HPy = HPy_NULL,
    h_ProcessLookupError: HPy = HPy_NULL,
    h_TimeoutError: HPy = HPy_NULL,
    h_Warning: HPy = HPy_NULL,
    h_UserWarning: HPy = HPy_NULL,
    h_DeprecationWarning: HPy = HPy_NULL,
    h_PendingDeprecationWarning: HPy = HPy_NULL,
    h_SyntaxWarning: HPy = HPy_NULL,
    h_RuntimeWarning: HPy = HPy_NULL,
    h_FutureWarning: HPy = HPy_NULL,
    h_ImportWarning: HPy = HPy_NULL,
    h_UnicodeWarning: HPy = HPy_NULL,
    h_BytesWarning: HPy = HPy_NULL,
    h_ResourceWarning: HPy = HPy_NULL,
    h_BaseObjectType: HPy = HPy_NULL,
    h_TypeType: HPy = HPy_NULL,
    h_BoolType: HPy = HPy_NULL,
    h_LongType: HPy = HPy_NULL,
    h_FloatType: HPy = HPy_NULL,
    h_UnicodeType: HPy = HPy_NULL,
    h_TupleType: HPy = HPy_NULL,
    h_ListType: HPy = HPy_NULL,
    ctx_Dup: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) HPy = null,
    ctx_Close: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) void = null,
    ctx_Long_FromInt32_t: ?*const anyopaque = null,
    ctx_Long_FromUInt32_t: ?*const anyopaque = null,
    ctx_Long_FromInt64_t: ?*const fn (ctx: *HPyContext, v: i64) callconv(.c) HPy = null,
    ctx_Long_FromUInt64_t: ?*const anyopaque = null,
    ctx_Long_FromSize_t: ?*const anyopaque = null,
    ctx_Long_FromSsize_t: ?*const anyopaque = null,
    ctx_Long_AsInt32_t: ?*const anyopaque = null,
    ctx_Long_AsUInt32_t: ?*const anyopaque = null,
    ctx_Long_AsUInt32_tMask: ?*const anyopaque = null,
    ctx_Long_AsInt64_t: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) i64 = null,
    ctx_Long_AsUInt64_t: ?*const anyopaque = null,
    ctx_Long_AsUInt64_tMask: ?*const anyopaque = null,
    ctx_Long_AsSize_t: ?*const anyopaque = null,
    ctx_Long_AsSsize_t: ?*const anyopaque = null,
    ctx_Long_AsVoidPtr: ?*const anyopaque = null,
    ctx_Long_AsDouble: ?*const anyopaque = null,
    ctx_Float_FromDouble: ?*const fn (ctx: *HPyContext, v: f64) callconv(.c) HPy = null,
    ctx_Float_AsDouble: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) f64 = null,
    ctx_Bool_FromBool: ?*const fn (ctx: *HPyContext, v: bool) callconv(.c) HPy = null,
    ctx_Length: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) isize = null,
    ctx_Number_Check: ?*const anyopaque = null,
    ctx_Add: ?*const fn (ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy = null,
    ctx_Subtract: ?*const fn (ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy = null,
    ctx_Multiply: ?*const fn (ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy = null,
    ctx_MatrixMultiply: ?*const anyopaque = null,
    ctx_FloorDivide: ?*const fn (ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy = null,
    ctx_TrueDivide: ?*const fn (ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy = null,
    ctx_Remainder: ?*const fn (ctx: *HPyContext, h1: HPy, h2: HPy) callconv(.c) HPy = null,
    ctx_Divmod: ?*const anyopaque = null,
    ctx_Power: ?*const anyopaque = null,
    ctx_Negative: ?*const fn (ctx: *HPyContext, h1: HPy) callconv(.c) HPy = null,
    ctx_Positive: ?*const anyopaque = null,
    ctx_Absolute: ?*const fn (ctx: *HPyContext, h1: HPy) callconv(.c) HPy = null,
    ctx_Invert: ?*const anyopaque = null,
    ctx_Lshift: ?*const anyopaque = null,
    ctx_Rshift: ?*const anyopaque = null,
    ctx_And: ?*const anyopaque = null,
    ctx_Xor: ?*const anyopaque = null,
    ctx_Or: ?*const anyopaque = null,
    ctx_Index: ?*const anyopaque = null,
    ctx_Long: ?*const anyopaque = null,
    ctx_Float: ?*const anyopaque = null,
    ctx_InPlaceAdd: ?*const anyopaque = null,
    ctx_InPlaceSubtract: ?*const anyopaque = null,
    ctx_InPlaceMultiply: ?*const anyopaque = null,
    ctx_InPlaceMatrixMultiply: ?*const anyopaque = null,
    ctx_InPlaceFloorDivide: ?*const anyopaque = null,
    ctx_InPlaceTrueDivide: ?*const anyopaque = null,
    ctx_InPlaceRemainder: ?*const anyopaque = null,
    ctx_InPlacePower: ?*const anyopaque = null,
    ctx_InPlaceLshift: ?*const anyopaque = null,
    ctx_InPlaceRshift: ?*const anyopaque = null,
    ctx_InPlaceAnd: ?*const anyopaque = null,
    ctx_InPlaceXor: ?*const anyopaque = null,
    ctx_InPlaceOr: ?*const anyopaque = null,
    ctx_Callable_Check: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) c_int = null,
    ctx_CallTupleDict: ?*const fn (ctx: *HPyContext, callable: HPy, args: HPy, kw: HPy) callconv(.c) HPy = null,
    ctx_FatalError: ?*const anyopaque = null,
    ctx_Err_SetString: ?*const fn (ctx: *HPyContext, h_type: HPy, utf8_message: ?[*:0]const u8) callconv(.c) void = null,
    ctx_Err_SetObject: ?*const anyopaque = null,
    ctx_Err_SetFromErrnoWithFilename: ?*const anyopaque = null,
    ctx_Err_SetFromErrnoWithFilenameObjects: ?*const anyopaque = null,
    ctx_Err_Occurred: ?*const fn (ctx: *HPyContext) callconv(.c) c_int = null,
    ctx_Err_ExceptionMatches: ?*const fn (ctx: *HPyContext, exc: HPy) callconv(.c) c_int = null,
    ctx_Err_NoMemory: ?*const fn (ctx: *HPyContext) callconv(.c) void = null,
    ctx_Err_Clear: ?*const fn (ctx: *HPyContext) callconv(.c) void = null,
    ctx_Err_NewException: ?*const anyopaque = null,
    ctx_Err_NewExceptionWithDoc: ?*const anyopaque = null,
    ctx_Err_WarnEx: ?*const anyopaque = null,
    ctx_Err_WriteUnraisable: ?*const anyopaque = null,
    ctx_IsTrue: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) c_int = null,
    ctx_Type_FromSpec: ?*const fn (ctx: *HPyContext, spec: ?*HPyType_Spec, params: ?*HPyType_SpecParam) callconv(.c) HPy = null,
    ctx_Type_GenericNew: ?*const anyopaque = null,
    ctx_GetAttr: ?*const fn (ctx: *HPyContext, obj: HPy, name: HPy) callconv(.c) HPy = null,
    ctx_GetAttr_s: ?*const fn (ctx: *HPyContext, obj: HPy, utf8_name: ?[*:0]const u8) callconv(.c) HPy = null,
    ctx_HasAttr: ?*const fn (ctx: *HPyContext, obj: HPy, name: HPy) callconv(.c) c_int = null,
    ctx_HasAttr_s: ?*const fn (ctx: *HPyContext, obj: HPy, utf8_name: ?[*:0]const u8) callconv(.c) c_int = null,
    ctx_SetAttr: ?*const fn (ctx: *HPyContext, obj: HPy, name: HPy, value: HPy) callconv(.c) c_int = null,
    ctx_SetAttr_s: ?*const fn (ctx: *HPyContext, obj: HPy, utf8_name: ?[*:0]const u8, value: HPy) callconv(.c) c_int = null,
    ctx_GetItem: ?*const fn (ctx: *HPyContext, obj: HPy, key: HPy) callconv(.c) HPy = null,
    ctx_GetItem_i: ?*const fn (ctx: *HPyContext, obj: HPy, idx: isize) callconv(.c) HPy = null,
    ctx_GetItem_s: ?*const fn (ctx: *HPyContext, obj: HPy, utf8_key: ?[*:0]const u8) callconv(.c) HPy = null,
    ctx_Contains: ?*const fn (ctx: *HPyContext, container: HPy, key: HPy) callconv(.c) c_int = null,
    ctx_SetItem: ?*const fn (ctx: *HPyContext, obj: HPy, key: HPy, value: HPy) callconv(.c) c_int = null,
    ctx_SetItem_i: ?*const fn (ctx: *HPyContext, obj: HPy, idx: isize, value: HPy) callconv(.c) c_int = null,
    ctx_SetItem_s: ?*const fn (ctx: *HPyContext, obj: HPy, utf8_key: ?[*:0]const u8, value: HPy) callconv(.c) c_int = null,
    ctx_Type: ?*const fn (ctx: *HPyContext, obj: HPy) callconv(.c) HPy = null,
    ctx_TypeCheck: ?*const fn (ctx: *HPyContext, obj: HPy, type_h: HPy) callconv(.c) c_int = null,
    ctx_Is: ?*const fn (ctx: *HPyContext, obj: HPy, other: HPy) callconv(.c) c_int = null,
    ctx_AsStruct_Object: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) ?*anyopaque = null,
    ctx_AsStruct_Legacy: ?*const anyopaque = null,
    ctx_New: ?*const fn (ctx: *HPyContext, h_type: HPy, data: ?*?*anyopaque) callconv(.c) HPy = null,
    ctx_Repr: ?*const anyopaque = null,
    ctx_Str: ?*const anyopaque = null,
    ctx_ASCII: ?*const anyopaque = null,
    ctx_Bytes: ?*const anyopaque = null,
    ctx_RichCompare: ?*const anyopaque = null,
    ctx_RichCompareBool: ?*const anyopaque = null,
    ctx_Hash: ?*const anyopaque = null,
    ctx_Bytes_Check: ?*const anyopaque = null,
    ctx_Bytes_Size: ?*const anyopaque = null,
    ctx_Bytes_GET_SIZE: ?*const anyopaque = null,
    ctx_Bytes_AsString: ?*const anyopaque = null,
    ctx_Bytes_AS_STRING: ?*const anyopaque = null,
    ctx_Bytes_FromString: ?*const anyopaque = null,
    ctx_Bytes_FromStringAndSize: ?*const anyopaque = null,
    ctx_Unicode_FromString: ?*const fn (ctx: *HPyContext, utf8: ?[*:0]const u8) callconv(.c) HPy = null,
    ctx_Unicode_Check: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) c_int = null,
    ctx_Unicode_AsASCIIString: ?*const anyopaque = null,
    ctx_Unicode_AsLatin1String: ?*const anyopaque = null,
    ctx_Unicode_AsUTF8String: ?*const anyopaque = null,
    ctx_Unicode_AsUTF8AndSize: ?*const fn (ctx: *HPyContext, h: HPy, size: ?*isize) callconv(.c) ?[*:0]const u8 = null,
    ctx_Unicode_FromWideChar: ?*const anyopaque = null,
    ctx_Unicode_DecodeFSDefault: ?*const anyopaque = null,
    ctx_Unicode_DecodeFSDefaultAndSize: ?*const anyopaque = null,
    ctx_Unicode_EncodeFSDefault: ?*const anyopaque = null,
    ctx_Unicode_ReadChar: ?*const anyopaque = null,
    ctx_Unicode_DecodeASCII: ?*const anyopaque = null,
    ctx_Unicode_DecodeLatin1: ?*const anyopaque = null,
    ctx_List_Check: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) c_int = null,
    ctx_List_New: ?*const fn (ctx: *HPyContext, len: isize) callconv(.c) HPy = null,
    ctx_List_Append: ?*const fn (ctx: *HPyContext, h_list: HPy, h_item: HPy) callconv(.c) c_int = null,
    ctx_Dict_Check: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) c_int = null,
    ctx_Dict_New: ?*const fn (ctx: *HPyContext) callconv(.c) HPy = null,
    ctx_Tuple_Check: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) c_int = null,
    ctx_Tuple_FromArray: ?*const fn (ctx: *HPyContext, items: ?[*]HPy, n: isize) callconv(.c) HPy = null,
    ctx_Import_ImportModule: ?*const anyopaque = null,
    ctx_FromPyObject: ?*const anyopaque = null,
    ctx_AsPyObject: ?*const anyopaque = null,
    ctx_CallRealFunctionFromTrampoline: ?*const fn (ctx: *HPyContext, sig: c_int, func: ?*const anyopaque, args: ?*anyopaque) callconv(.c) void = null,
    ctx_ListBuilder_New: ?*const anyopaque = null,
    ctx_ListBuilder_Set: ?*const anyopaque = null,
    ctx_ListBuilder_Build: ?*const anyopaque = null,
    ctx_ListBuilder_Cancel: ?*const anyopaque = null,
    ctx_TupleBuilder_New: ?*const anyopaque = null,
    ctx_TupleBuilder_Set: ?*const anyopaque = null,
    ctx_TupleBuilder_Build: ?*const anyopaque = null,
    ctx_TupleBuilder_Cancel: ?*const anyopaque = null,
    ctx_Tracker_New: ?*const anyopaque = null,
    ctx_Tracker_Add: ?*const anyopaque = null,
    ctx_Tracker_ForgetAll: ?*const anyopaque = null,
    ctx_Tracker_Close: ?*const anyopaque = null,
    ctx_Field_Store: ?*const anyopaque = null,
    ctx_Field_Load: ?*const anyopaque = null,
    ctx_ReenterPythonExecution: ?*const anyopaque = null,
    ctx_LeavePythonExecution: ?*const anyopaque = null,
    ctx_Global_Store: ?*const anyopaque = null,
    ctx_Global_Load: ?*const anyopaque = null,
    ctx_Dump: ?*const anyopaque = null,
    ctx_AsStruct_Type: ?*const anyopaque = null,
    ctx_AsStruct_Long: ?*const anyopaque = null,
    ctx_AsStruct_Float: ?*const anyopaque = null,
    ctx_AsStruct_Unicode: ?*const anyopaque = null,
    ctx_AsStruct_Tuple: ?*const anyopaque = null,
    ctx_AsStruct_List: ?*const anyopaque = null,
    ctx_Type_GetBuiltinShape: ?*const anyopaque = null,
    ctx_DelItem: ?*const fn (ctx: *HPyContext, obj: HPy, key: HPy) callconv(.c) c_int = null,
    ctx_DelItem_i: ?*const fn (ctx: *HPyContext, obj: HPy, idx: isize) callconv(.c) c_int = null,
    ctx_DelItem_s: ?*const fn (ctx: *HPyContext, obj: HPy, utf8_key: ?[*:0]const u8) callconv(.c) c_int = null,
    h_ComplexType: HPy = HPy_NULL,
    h_BytesType: HPy = HPy_NULL,
    h_MemoryViewType: HPy = HPy_NULL,
    h_CapsuleType: HPy = HPy_NULL,
    h_SliceType: HPy = HPy_NULL,
    h_Builtins: HPy = HPy_NULL,
    ctx_Capsule_New: ?*const anyopaque = null,
    ctx_Capsule_Get: ?*const anyopaque = null,
    ctx_Capsule_IsValid: ?*const anyopaque = null,
    ctx_Capsule_Set: ?*const anyopaque = null,
    ctx_Compile_s: ?*const anyopaque = null,
    ctx_EvalCode: ?*const anyopaque = null,
    ctx_ContextVar_New: ?*const anyopaque = null,
    ctx_ContextVar_Get: ?*const anyopaque = null,
    ctx_ContextVar_Set: ?*const anyopaque = null,
    ctx_Type_GetName: ?*const anyopaque = null,
    ctx_Type_IsSubtype: ?*const anyopaque = null,
    ctx_Unicode_FromEncodedObject: ?*const anyopaque = null,
    ctx_Unicode_Substring: ?*const anyopaque = null,
    ctx_Dict_Keys: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) HPy = null,
    ctx_Dict_Copy: ?*const fn (ctx: *HPyContext, h: HPy) callconv(.c) HPy = null,
    ctx_Slice_Unpack: ?*const anyopaque = null,
    ctx_SetCallFunction: ?*const fn (ctx: *HPyContext, h: HPy, func: ?*HPyCallFunctionLocal) callconv(.c) c_int = null,
    ctx_Call: ?*const fn (ctx: *HPyContext, callable: HPy, args: ?[*]const HPy, nargs: usize, kwnames: HPy) callconv(.c) HPy = null,
    ctx_CallMethod: ?*const fn (ctx: *HPyContext, name: HPy, args: ?[*]const HPy, nargs: usize, kwnames: HPy) callconv(.c) HPy = null,
};

/// Yeni, tam donanımlı (Tier 0 alt kümesi implemente edilmiş) bir
/// `HPyContext` oluşturur. `allocator`, bu bağlamın ürettiği TÜM nesnelerin
/// (tekiller dahil) ömrünü yönetir — çağıran, işi bitince `destroyContext`
/// ile serbest bırakmalıdır.
/// Asla serbest bırakılmayan (bkz. `PINNED_REFCOUNT`) bir `.exc_type`
/// tekili — gerçek CPython'ın önceden var olan istisna TİPİ nesneleriyle
/// (`PyExc_ValueError` vb.) aynı ruhta: kimlik (`ctx_Is`/
/// `ctx_Err_ExceptionMatches`) karşılaştırması için tek, kararlı bir `HPy`
/// tutamacı. Nox'ın nesne modelinde henüz gerçek "tip nesneleri" yok, bu
/// yüzden bu yalnızca bir işaretçi kimliği (payload boş).
fn pinnedExcType(allocator: std.mem.Allocator) !HPy {
    const obj = try allocator.create(Obj);
    obj.* = .{ .refcount = PINNED_REFCOUNT, .tag = .exc_type, .payload = .{ .l = 0 } };
    return .{ ._i = @intCast(@intFromPtr(obj)) };
}

pub fn createContext(allocator: std.mem.Allocator) !*HPyContext {
    const state = try allocator.create(PrivateState);
    const ctx = try allocator.create(HPyContext);

    const none_obj = try allocator.create(Obj);
    none_obj.* = .{ .refcount = PINNED_REFCOUNT, .tag = .none, .payload = .{ .l = 0 } };
    const h_none: HPy = .{ ._i = @intCast(@intFromPtr(none_obj)) };

    const true_obj = try allocator.create(Obj);
    true_obj.* = .{ .refcount = PINNED_REFCOUNT, .tag = .bool_, .payload = .{ .b = true } };
    const h_true: HPy = .{ ._i = @intCast(@intFromPtr(true_obj)) };

    const false_obj = try allocator.create(Obj);
    false_obj.* = .{ .refcount = PINNED_REFCOUNT, .tag = .bool_, .payload = .{ .b = false } };
    const h_false: HPy = .{ ._i = @intCast(@intFromPtr(false_obj)) };

    // Yaygın kullanılan yerleşik istisna TİPLERİ — bkz. `pinnedExcType`.
    // Gerçek HPy'nin desteklediği ~70 istisna alanının tamamı değil, en sık
    // kullanılan alt kümesi (kapsam bilinçli olarak dar tutuldu; genişletmek
    // yalnızca bu listeye eklemek kadar basit).
    const h_exception = try pinnedExcType(allocator);
    const h_base_exception = try pinnedExcType(allocator);
    const h_type_error = try pinnedExcType(allocator);
    const h_value_error = try pinnedExcType(allocator);
    const h_runtime_error = try pinnedExcType(allocator);
    const h_index_error = try pinnedExcType(allocator);
    const h_key_error = try pinnedExcType(allocator);
    const h_attribute_error = try pinnedExcType(allocator);
    const h_overflow_error = try pinnedExcType(allocator);
    const h_zero_division_error = try pinnedExcType(allocator);
    const h_memory_error = try pinnedExcType(allocator);
    const h_stop_iteration = try pinnedExcType(allocator);
    const h_not_implemented_error = try pinnedExcType(allocator);
    const h_import_error = try pinnedExcType(allocator);
    const h_os_error = try pinnedExcType(allocator);

    state.* = .{ .allocator = allocator, .h_true_obj = h_true, .h_false_obj = h_false };

    ctx.* = .{
        .name = "Nox HPy bridge (Tier 0 + Tier 1'in ilk dilimi)",
        ._private = state,
        .abi_version = 0,
        .h_None = h_none,
        .h_True = h_true,
        .h_False = h_false,
        .h_Exception = h_exception,
        .h_BaseException = h_base_exception,
        .h_TypeError = h_type_error,
        .h_ValueError = h_value_error,
        .h_RuntimeError = h_runtime_error,
        .h_IndexError = h_index_error,
        .h_KeyError = h_key_error,
        .h_AttributeError = h_attribute_error,
        .h_OverflowError = h_overflow_error,
        .h_ZeroDivisionError = h_zero_division_error,
        .h_MemoryError = h_memory_error,
        .h_StopIteration = h_stop_iteration,
        .h_NotImplementedError = h_not_implemented_error,
        .h_ImportError = h_import_error,
        .h_OSError = h_os_error,
        .ctx_Dup = ctxDup,
        .ctx_Close = ctxClose,
        .ctx_Long_FromInt64_t = ctxLongFromInt64,
        .ctx_Long_AsInt64_t = ctxLongAsInt64,
        .ctx_Float_FromDouble = ctxFloatFromDouble,
        .ctx_Float_AsDouble = ctxFloatAsDouble,
        .ctx_Bool_FromBool = ctxBoolFromBool,
        .ctx_Unicode_FromString = ctxUnicodeFromString,
        .ctx_Unicode_Check = ctxUnicodeCheck,
        .ctx_Unicode_AsUTF8AndSize = ctxUnicodeAsUTF8AndSize,
        .ctx_Length = ctxLength,
        .ctx_IsTrue = ctxIsTrue,
        .ctx_Is = ctxIs,
        .ctx_Add = ctxAdd,
        .ctx_Subtract = ctxSubtract,
        .ctx_Multiply = ctxMultiply,
        .ctx_TrueDivide = ctxTrueDivide,
        .ctx_FloorDivide = ctxFloorDivide,
        .ctx_Remainder = ctxRemainder,
        .ctx_Negative = ctxNegative,
        .ctx_Absolute = ctxAbsolute,
        .ctx_Err_SetString = ctxErrSetString,
        .ctx_Err_Occurred = ctxErrOccurred,
        .ctx_Err_Clear = ctxErrClear,
        .ctx_Err_ExceptionMatches = ctxErrExceptionMatches,
        .ctx_Err_NoMemory = ctxErrNoMemory,
        .ctx_List_Check = ctxListCheck,
        .ctx_List_New = ctxListNew,
        .ctx_List_Append = ctxListAppend,
        .ctx_Tuple_Check = ctxTupleCheck,
        .ctx_Tuple_FromArray = ctxTupleFromArray,
        .ctx_Dict_Check = ctxDictCheck,
        .ctx_Dict_New = ctxDictNew,
        .ctx_Dict_Keys = ctxDictKeys,
        .ctx_Dict_Copy = ctxDictCopy,
        .ctx_GetItem = ctxGetItem,
        .ctx_GetItem_i = ctxGetItemI,
        .ctx_GetItem_s = ctxGetItemS,
        .ctx_SetItem = ctxSetItem,
        .ctx_SetItem_i = ctxSetItemI,
        .ctx_SetItem_s = ctxSetItemS,
        .ctx_DelItem = ctxDelItem,
        .ctx_DelItem_i = ctxDelItemI,
        .ctx_DelItem_s = ctxDelItemS,
        .ctx_Contains = ctxContains,
        .ctx_Type_FromSpec = ctxTypeFromSpec,
        .ctx_New = ctxNew,
        .ctx_AsStruct_Object = ctxAsStructObject,
        .ctx_Type = ctxType,
        .ctx_TypeCheck = ctxTypeCheck,
        .ctx_GetAttr = ctxGetAttr,
        .ctx_GetAttr_s = ctxGetAttrS,
        .ctx_HasAttr = ctxHasAttr,
        .ctx_HasAttr_s = ctxHasAttrS,
        .ctx_SetAttr = ctxSetAttr,
        .ctx_SetAttr_s = ctxSetAttrS,
        .ctx_Callable_Check = ctxCallableCheck,
        .ctx_Call = ctxCall,
        .ctx_CallTupleDict = ctxCallTupleDict,
        .ctx_SetCallFunction = ctxSetCallFunction,
        .ctx_CallRealFunctionFromTrampoline = ctxCallRealFunctionFromTrampoline,
        .ctx_CallMethod = ctxCallMethod,
    };
    return ctx;
}

/// Bu bağlamın oluşturduğu tüm tekilleri (bkz. `createContext`) serbest
/// bırakır. Sıra: bekleyen hata mesajı (varsa) → tüm `.exc_type`/None/
/// Bool tekilleri → durum → bağlamın kendisi.
pub fn destroyContext(allocator: std.mem.Allocator, ctx: *HPyContext) void {
    const state = contextState(ctx);
    if (state.pending_error) |pe| allocator.free(pe.message);

    const singletons = [_]HPy{
        ctx.h_None,                ctx.h_True,           ctx.h_False,
        ctx.h_Exception,           ctx.h_BaseException,  ctx.h_TypeError,
        ctx.h_ValueError,          ctx.h_RuntimeError,   ctx.h_IndexError,
        ctx.h_KeyError,            ctx.h_AttributeError, ctx.h_OverflowError,
        ctx.h_ZeroDivisionError,   ctx.h_MemoryError,    ctx.h_StopIteration,
        ctx.h_NotImplementedError, ctx.h_ImportError,    ctx.h_OSError,
    };
    for (singletons) |h| allocator.destroy(objOf(h).?);

    allocator.destroy(state);
    allocator.destroy(ctx);
}

test "ctxLongFromInt64/ctxLongAsInt64 round-trip" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    const h = ctxLongFromInt64(ctx, 42);
    defer ctxClose(ctx, h);
    try std.testing.expectEqual(@as(i64, 42), ctxLongAsInt64(ctx, h));
}

test "ctxDup/ctxClose refcount doğru artar/azalır" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    const h = ctxLongFromInt64(ctx, 7);
    const obj = objOf(h).?;
    try std.testing.expectEqual(@as(i64, 1), obj.refcount);
    const h2 = ctxDup(ctx, h);
    try std.testing.expectEqual(@as(i64, 2), obj.refcount);
    ctxClose(ctx, h2);
    try std.testing.expectEqual(@as(i64, 1), obj.refcount);
    ctxClose(ctx, h);
}

test "tekiller (None/True/False) hiç serbest bırakılmaz" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);
    const none_obj = objOf(ctx.h_None).?;
    ctxClose(ctx, ctx.h_None);
    ctxClose(ctx, ctx.h_None);
    try std.testing.expectEqual(PINNED_REFCOUNT, none_obj.refcount);
}

test "ctxUnicodeFromString/Check/AsUTF8AndSize round-trip" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    const h = ctxUnicodeFromString(ctx, "merhaba");
    defer ctxClose(ctx, h);
    try std.testing.expectEqual(@as(c_int, 1), ctxUnicodeCheck(ctx, h));
    try std.testing.expectEqual(@as(c_int, 0), ctxUnicodeCheck(ctx, ctx.h_None));

    var size: isize = -1;
    const s = ctxUnicodeAsUTF8AndSize(ctx, h, &size).?;
    try std.testing.expectEqual(@as(isize, 7), size);
    try std.testing.expectEqualStrings("merhaba", std.mem.sliceTo(s, 0));
    try std.testing.expectEqual(@as(isize, 7), ctxLength(ctx, h));
}

test "sayı protokolü: int/float aritmetiği Python yükseltme kurallarını izler" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    const a = ctxLongFromInt64(ctx, 7);
    const b = ctxLongFromInt64(ctx, 3);
    defer ctxClose(ctx, a);
    defer ctxClose(ctx, b);

    const sum = ctxAdd(ctx, a, b);
    defer ctxClose(ctx, sum);
    try std.testing.expectEqual(@as(i64, 10), ctxLongAsInt64(ctx, sum));

    // Python'un floor bölme/mod semantiği: -7 // 3 == -3, -7 % 3 == 2.
    const neg = ctxLongFromInt64(ctx, -7);
    defer ctxClose(ctx, neg);
    const fd = ctxFloorDivide(ctx, neg, b);
    defer ctxClose(ctx, fd);
    try std.testing.expectEqual(@as(i64, -3), ctxLongAsInt64(ctx, fd));
    const rem = ctxRemainder(ctx, neg, b);
    defer ctxClose(ctx, rem);
    try std.testing.expectEqual(@as(i64, 2), ctxLongAsInt64(ctx, rem));

    // Bir işlenen float ise sonuç float'tır (Python'un yükseltme kuralı).
    const f = ctxFloatFromDouble(ctx, 0.5);
    defer ctxClose(ctx, f);
    const mixed = ctxMultiply(ctx, a, f);
    defer ctxClose(ctx, mixed);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), ctxFloatAsDouble(ctx, mixed), 1e-9);

    const neg_a = ctxNegative(ctx, a);
    defer ctxClose(ctx, neg_a);
    try std.testing.expectEqual(@as(i64, -7), ctxLongAsInt64(ctx, neg_a));
    const abs_neg = ctxAbsolute(ctx, neg);
    defer ctxClose(ctx, abs_neg);
    try std.testing.expectEqual(@as(i64, 7), ctxLongAsInt64(ctx, abs_neg));
}

test "hata yönetimi: SetString/Occurred/Clear/ExceptionMatches" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    try std.testing.expectEqual(@as(c_int, 0), ctxErrOccurred(ctx));

    ctxErrSetString(ctx, ctx.h_ValueError, "test hatası");
    try std.testing.expectEqual(@as(c_int, 1), ctxErrOccurred(ctx));
    try std.testing.expectEqual(@as(c_int, 1), ctxErrExceptionMatches(ctx, ctx.h_ValueError));
    try std.testing.expectEqual(@as(c_int, 0), ctxErrExceptionMatches(ctx, ctx.h_TypeError));

    ctxErrClear(ctx);
    try std.testing.expectEqual(@as(c_int, 0), ctxErrOccurred(ctx));
}

test "sıfıra bölme ZeroDivisionError bekleyen hatasını ayarlar" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    const a = ctxLongFromInt64(ctx, 1);
    const zero = ctxLongFromInt64(ctx, 0);
    defer ctxClose(ctx, a);
    defer ctxClose(ctx, zero);

    const r = ctxTrueDivide(ctx, a, zero);
    try std.testing.expectEqual(HPy_NULL._i, r._i);
    try std.testing.expectEqual(@as(c_int, 1), ctxErrOccurred(ctx));
    try std.testing.expectEqual(@as(c_int, 1), ctxErrExceptionMatches(ctx, ctx.h_ZeroDivisionError));
}

test "ctxIsTrue/ctxIs" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    try std.testing.expectEqual(@as(c_int, 0), ctxIsTrue(ctx, ctx.h_None));
    try std.testing.expectEqual(@as(c_int, 1), ctxIsTrue(ctx, ctx.h_True));
    try std.testing.expectEqual(@as(c_int, 0), ctxIsTrue(ctx, ctx.h_False));

    const zero = ctxLongFromInt64(ctx, 0);
    defer ctxClose(ctx, zero);
    try std.testing.expectEqual(@as(c_int, 0), ctxIsTrue(ctx, zero));

    try std.testing.expectEqual(@as(c_int, 1), ctxIs(ctx, ctx.h_None, ctx.h_None));
    try std.testing.expectEqual(@as(c_int, 0), ctxIs(ctx, ctx.h_None, ctx.h_True));
}

test "list: New/Append/GetItem_i/SetItem_i/Length, negatif indeks, sızıntı yok" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    const list = ctxListNew(ctx, 0);
    defer ctxClose(ctx, list);
    try std.testing.expectEqual(@as(c_int, 1), ctxListCheck(ctx, list));
    try std.testing.expectEqual(@as(c_int, 0), ctxListCheck(ctx, ctx.h_None));

    const a = ctxLongFromInt64(ctx, 10);
    defer ctxClose(ctx, a);
    const b = ctxLongFromInt64(ctx, 20);
    defer ctxClose(ctx, b);
    try std.testing.expectEqual(@as(c_int, 0), ctxListAppend(ctx, list, a));
    try std.testing.expectEqual(@as(c_int, 0), ctxListAppend(ctx, list, b));
    try std.testing.expectEqual(@as(isize, 2), ctxLength(ctx, list));

    const got0 = ctxGetItemI(ctx, list, 0);
    defer ctxClose(ctx, got0);
    try std.testing.expectEqual(@as(i64, 10), ctxLongAsInt64(ctx, got0));

    // Python'un negatif indeks kuralı: -1 son eleman.
    const last = ctxGetItemI(ctx, list, -1);
    defer ctxClose(ctx, last);
    try std.testing.expectEqual(@as(i64, 20), ctxLongAsInt64(ctx, last));

    const c = ctxLongFromInt64(ctx, 99);
    defer ctxClose(ctx, c);
    try std.testing.expectEqual(@as(c_int, 0), ctxSetItemI(ctx, list, 0, c));
    const got0b = ctxGetItemI(ctx, list, 0);
    defer ctxClose(ctx, got0b);
    try std.testing.expectEqual(@as(i64, 99), ctxLongAsInt64(ctx, got0b));

    const oob = ctxGetItemI(ctx, list, 5);
    try std.testing.expectEqual(HPy_NULL._i, oob._i);
    try std.testing.expectEqual(@as(c_int, 1), ctxErrExceptionMatches(ctx, ctx.h_IndexError));
    ctxErrClear(ctx);
}

test "tuple: FromArray değişmezdir (SetItem TypeError verir)" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    const a = ctxLongFromInt64(ctx, 1);
    defer ctxClose(ctx, a);
    const b = ctxLongFromInt64(ctx, 2);
    defer ctxClose(ctx, b);
    var items = [_]HPy{ a, b };
    const tup = ctxTupleFromArray(ctx, &items, 2);
    defer ctxClose(ctx, tup);

    try std.testing.expectEqual(@as(c_int, 1), ctxTupleCheck(ctx, tup));
    try std.testing.expectEqual(@as(isize, 2), ctxLength(ctx, tup));
    const got = ctxGetItemI(ctx, tup, 1);
    defer ctxClose(ctx, got);
    try std.testing.expectEqual(@as(i64, 2), ctxLongAsInt64(ctx, got));

    try std.testing.expectEqual(@as(c_int, -1), ctxSetItemI(ctx, tup, 0, a));
    try std.testing.expectEqual(@as(c_int, 1), ctxErrExceptionMatches(ctx, ctx.h_TypeError));
    ctxErrClear(ctx);
}

test "dict: New/SetItem/GetItem/Contains/DelItem/Keys/Copy" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    const d = ctxDictNew(ctx);
    defer ctxClose(ctx, d);
    try std.testing.expectEqual(@as(c_int, 1), ctxDictCheck(ctx, d));

    const key = ctxUnicodeFromString(ctx, "x");
    defer ctxClose(ctx, key);
    const val = ctxLongFromInt64(ctx, 42);
    defer ctxClose(ctx, val);
    try std.testing.expectEqual(@as(c_int, 0), ctxSetItem(ctx, d, key, val));
    try std.testing.expectEqual(@as(isize, 1), ctxLength(ctx, d));
    try std.testing.expectEqual(@as(c_int, 1), ctxContains(ctx, d, key));

    const got = ctxGetItem(ctx, d, key);
    defer ctxClose(ctx, got);
    try std.testing.expectEqual(@as(i64, 42), ctxLongAsInt64(ctx, got));

    // Aynı anahtara TEKRAR atama günceller, yeni bir giriş EKLEMEZ.
    const val2 = ctxLongFromInt64(ctx, 43);
    defer ctxClose(ctx, val2);
    try std.testing.expectEqual(@as(c_int, 0), ctxSetItem(ctx, d, key, val2));
    try std.testing.expectEqual(@as(isize, 1), ctxLength(ctx, d));

    const keys = ctxDictKeys(ctx, d);
    defer ctxClose(ctx, keys);
    try std.testing.expectEqual(@as(c_int, 1), ctxListCheck(ctx, keys));
    try std.testing.expectEqual(@as(isize, 1), ctxLength(ctx, keys));

    const copy = ctxDictCopy(ctx, d);
    defer ctxClose(ctx, copy);
    try std.testing.expectEqual(@as(isize, 1), ctxLength(ctx, copy));

    try std.testing.expectEqual(@as(c_int, 0), ctxDelItem(ctx, d, key));
    try std.testing.expectEqual(@as(isize, 0), ctxLength(ctx, d));
    // Kopya, orijinalden BAĞIMSIZDIR (yapısal paylaşım yok).
    try std.testing.expectEqual(@as(isize, 1), ctxLength(ctx, copy));

    const missing = ctxGetItem(ctx, d, key);
    try std.testing.expectEqual(HPy_NULL._i, missing._i);
    try std.testing.expectEqual(@as(c_int, 1), ctxErrExceptionMatches(ctx, ctx.h_KeyError));
    ctxErrClear(ctx);
}

test "GetItem_s/SetItem_s: str anahtarlı kısayol" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    const d = ctxDictNew(ctx);
    defer ctxClose(ctx, d);
    const val = ctxLongFromInt64(ctx, 7);
    defer ctxClose(ctx, val);

    try std.testing.expectEqual(@as(c_int, 0), ctxSetItemS(ctx, d, "answer", val));
    const got = ctxGetItemS(ctx, d, "answer");
    defer ctxClose(ctx, got);
    try std.testing.expectEqual(@as(i64, 7), ctxLongAsInt64(ctx, got));

    const missing = ctxGetItemS(ctx, d, "nope");
    try std.testing.expectEqual(HPy_NULL._i, missing._i);
    try std.testing.expectEqual(@as(c_int, 1), ctxErrExceptionMatches(ctx, ctx.h_KeyError));
    ctxErrClear(ctx);
}

test "HPyType_Spec/HPyType_SpecParam/HPySlot bayt düzeni gerçek `cc offsetof` çıktısıyla eşleşiyor" {
    // bkz. modül üstü not — bu sayılar `cc -DHPY_ABI_UNIVERSAL` ile
    // GERÇEKTEN derlenip `offsetof`la ölçüldü (Faz 12'nin aynı yöntemi).
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(HPyType_Spec));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(HPyType_Spec, "name"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(HPyType_Spec, "basicsize"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(HPyType_Spec, "itemsize"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(HPyType_Spec, "flags"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(HPyType_Spec, "builtin_shape"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(HPyType_Spec, "legacy_slots"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(HPyType_Spec, "defines"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(HPyType_Spec, "doc"));

    try std.testing.expectEqual(@as(usize, 16), @sizeOf(HPyType_SpecParam));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(HPyType_SpecParam, "kind"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(HPyType_SpecParam, "object"));

    try std.testing.expectEqual(@as(usize, 24), @sizeOf(HPySlotLocal));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(HPySlotLocal, "slot"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(HPySlotLocal, "impl"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(HPySlotLocal, "cpy_trampoline"));
}

test "HPyType_FromSpec + ctx_New + AsStruct_Object: örnek inşası, alan okuma/yazma, tp_destroy dispatch'i" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    const S = extern struct { x: i64 };
    const Destroyed = struct {
        var count: usize = 0;
        fn destroy(data: *anyopaque) callconv(.c) void {
            const s: *S = @ptrCast(@alignCast(data));
            _ = s;
            count += 1;
        }
    };
    Destroyed.count = 0;

    var destroy_def = HPyDefLocal{ .kind = HPY_DEF_KIND_SLOT };
    const slot_view: *HPySlotLocal = @ptrCast(@alignCast(&destroy_def.meth));
    slot_view.* = .{ .slot = HPY_SLOT_TP_DESTROY, .impl = Destroyed.destroy };
    const defines = [_]?*const HPyDefLocal{ &destroy_def, null };

    var spec = HPyType_Spec{
        .name = "Point",
        .basicsize = @sizeOf(S),
        .defines = @ptrCast(&defines),
    };
    const type_h = ctxTypeFromSpec(ctx, &spec, null);
    defer ctxClose(ctx, type_h);
    try std.testing.expect(type_h._i != 0);

    var data: ?*anyopaque = null;
    const inst = ctxNew(ctx, type_h, &data);
    try std.testing.expect(data != null);
    const s: *S = @ptrCast(@alignCast(data.?));
    try std.testing.expectEqual(@as(i64, 0), s.x); // ctx_New sıfırlar
    s.x = 42;

    const s2: *S = @ptrCast(@alignCast(ctxAsStructObject(ctx, inst).?));
    try std.testing.expectEqual(@as(i64, 42), s2.x);

    try std.testing.expectEqual(@as(c_int, 1), ctxTypeCheck(ctx, inst, type_h));
    const got_type = ctxType(ctx, inst);
    defer ctxClose(ctx, got_type);
    try std.testing.expectEqual(type_h._i, got_type._i);

    try std.testing.expectEqual(@as(usize, 0), Destroyed.count);
    ctxClose(ctx, inst);
    try std.testing.expectEqual(@as(usize, 1), Destroyed.count);
}

test "type_ nesnesinin HPyFunc_O metodları findTypeMethodO ile bulunabilir" {
    const ctx = try createContext(std.testing.allocator);
    defer destroyContext(std.testing.allocator, ctx);

    const Impl = struct {
        fn double_it(c: *HPyContext, self: HPy, arg: HPy) callconv(.c) HPy {
            _ = self;
            const v = c.ctx_Long_AsInt64_t.?(c, arg);
            return c.ctx_Long_FromInt64_t.?(c, v * 2);
        }
    };
    const meth = HPyMethLocal{ .name = "double_it", .impl = Impl.double_it, .signature = HPY_FUNC_SIG_O };
    const meth_def = HPyDefLocal{ .kind = HPY_DEF_KIND_METH, .meth = meth };
    const defines = [_]?*const HPyDefLocal{ &meth_def, null };

    var spec = HPyType_Spec{ .name = "Foo", .basicsize = 8, .defines = @ptrCast(&defines) };
    const type_h = ctxTypeFromSpec(ctx, &spec, null);
    defer ctxClose(ctx, type_h);

    const m = findTypeMethodO(type_h, "double_it") orelse return error.MethodNotFound;
    const arg = ctxLongFromInt64(ctx, 21);
    defer ctxClose(ctx, arg);
    const result = m.impl(ctx, HPy_NULL, arg);
    defer ctxClose(ctx, result);
    try std.testing.expectEqual(@as(i64, 42), ctxLongAsInt64(ctx, result));

    try std.testing.expectEqual(@as(?TypeMethod, null), findTypeMethodO(type_h, "nope"));
}
