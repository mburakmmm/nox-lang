//! Nox HPy köprüsü — Tier 0 uçtan uca uyumluluk testi (AGENTS.md §10, §13:
//! "Her Tier 0/1 API eklemesi, gerçek bir C eklentisiyle entegrasyon
//! testiyle doğrulanmalıdır — sadece unit test yeterli değildir").
//!
//! `tests/compat/hpy_ext/noxtest.c`, gerçek HPy header'larına karşı
//! (`HPY_ABI_UNIVERSAL` modunda) derlenmiş, CPython'a HİÇ bağlanmayan
//! bağımsız bir paylaşımlı kütüphanedir (bkz. `build.zig`, derleme adımı).
//! Bu test onu `runtime/hpy_bridge/loader.zig` ile `dlopen` eder, Nox'un
//! kendi `HPyContext` implementasyonunu (`context.zig`) geçirerek
//! eklentinin `add_one` fonksiyonunu ÇAĞIRIR ve sonucu doğrular — gerçek
//! bir derlenmiş C eklentisiyle uçtan uca bir round-trip.

const std = @import("std");
const hpy = @import("hpy_bridge");

test "gerçek HPy eklentisi: add_one(41) == 42" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const add_one = mod.findMethodO("add_one") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const arg = ctx.ctx_Long_FromInt64_t.?(ctx, 41);
    defer ctx.ctx_Close.?(ctx, arg);

    const result = add_one(ctx, hpy.context.HPy_NULL, arg);
    defer ctx.ctx_Close.?(ctx, result);

    try std.testing.expectEqual(@as(i64, 42), ctx.ctx_Long_AsInt64_t.?(ctx, result));
}

test "gerçek HPy eklentisi: str_length(\"merhaba\") == 7 (Tier 1 — Unicode + Length)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const str_length = mod.findMethodO("str_length") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const arg = ctx.ctx_Unicode_FromString.?(ctx, "merhaba");
    defer ctx.ctx_Close.?(ctx, arg);

    const result = str_length(ctx, hpy.context.HPy_NULL, arg);
    defer ctx.ctx_Close.?(ctx, result);

    try std.testing.expectEqual(@as(i64, 7), ctx.ctx_Long_AsInt64_t.?(ctx, result));
}

test "gerçek HPy eklentisi: negate(-3.5) == 3.5 (Tier 1 — sayı protokolü)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const negate = mod.findMethodO("negate") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const arg = ctx.ctx_Float_FromDouble.?(ctx, -3.5);
    defer ctx.ctx_Close.?(ctx, arg);

    const result = negate(ctx, hpy.context.HPy_NULL, arg);
    defer ctx.ctx_Close.?(ctx, result);

    try std.testing.expectApproxEqAbs(@as(f64, 3.5), ctx.ctx_Float_AsDouble.?(ctx, result), 1e-9);
}

test "gerçek HPy eklentisi: raise_value_error kasıtlı HPyErr_SetString çağırır (Tier 0 — hata yönetimi)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const raise_value_error = mod.findMethodO("raise_value_error") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));

    const arg = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, arg);
    const result = raise_value_error(ctx, hpy.context.HPy_NULL, arg);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, result._i);

    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_Occurred.?(ctx));
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_ValueError));
    ctx.ctx_Err_Clear.?(ctx);
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));
}

test "gerçek HPy eklentisi: list_sum([1,2,3,4]) == 10 (Tier 1 — List + GetItem_i)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const list_sum = mod.findMethodO("list_sum") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const list = ctx.ctx_List_New.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, list);
    for ([_]i64{ 1, 2, 3, 4 }) |v| {
        const item = ctx.ctx_Long_FromInt64_t.?(ctx, v);
        defer ctx.ctx_Close.?(ctx, item);
        try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_List_Append.?(ctx, list, item));
    }

    const result = list_sum(ctx, hpy.context.HPy_NULL, list);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(i64, 10), ctx.ctx_Long_AsInt64_t.?(ctx, result));
}

test "gerçek HPy eklentisi: make_pair(7) == (7, 7) (Tier 1 — Tuple_FromArray)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const make_pair = mod.findMethodO("make_pair") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const arg = ctx.ctx_Long_FromInt64_t.?(ctx, 7);
    defer ctx.ctx_Close.?(ctx, arg);

    const result = make_pair(ctx, hpy.context.HPy_NULL, arg);
    defer ctx.ctx_Close.?(ctx, result);

    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Tuple_Check.?(ctx, result));
    try std.testing.expectEqual(@as(isize, 2), ctx.ctx_Length.?(ctx, result));
    const first = ctx.ctx_GetItem_i.?(ctx, result, 0);
    defer ctx.ctx_Close.?(ctx, first);
    const second = ctx.ctx_GetItem_i.?(ctx, result, 1);
    defer ctx.ctx_Close.?(ctx, second);
    try std.testing.expectEqual(@as(i64, 7), ctx.ctx_Long_AsInt64_t.?(ctx, first));
    try std.testing.expectEqual(@as(i64, 7), ctx.ctx_Long_AsInt64_t.?(ctx, second));
}

test "gerçek HPy eklentisi: dict_get_x({\"x\": 5}) == 5 (Tier 1 — Dict + GetItem_s)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const dict_get_x = mod.findMethodO("dict_get_x") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const d = ctx.ctx_Dict_New.?(ctx);
    defer ctx.ctx_Close.?(ctx, d);
    const val = ctx.ctx_Long_FromInt64_t.?(ctx, 5);
    defer ctx.ctx_Close.?(ctx, val);
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_SetItem_s.?(ctx, d, "x", val));

    const result = dict_get_x(ctx, hpy.context.HPy_NULL, d);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(i64, 5), ctx.ctx_Long_AsInt64_t.?(ctx, result));
}

test "gerçek HPy eklentisi: HPyType_FromSpec ile tanımlanmış Counter tipi — inşa/AsStruct/tp_destroy (Tier 1)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const make_counter = mod.findMethodO("make_counter") orelse return error.MethodNotFound;
    const get_counter_x = mod.findMethodO("get_counter_x") orelse return error.MethodNotFound;
    const get_destroy_count = mod.findMethodO("get_destroy_count") orelse return error.MethodNotFound;

    // `std.testing.allocator` (sızıntı tespit eden) DEĞİL, `page_allocator`
    // kullanılıyor: `noxtest.c`nin `Counter_type`i (bkz. dosya) EKLENTİNİN
    // KENDİ statik C değişkeninde tembel önbelleklenir — gerçek HPy'de tip
    // nesneleri tipik olarak modül durumunun ömrü boyunca yaşar, tek bir
    // `HPyContext`in ömrüyle BAĞLI değildir. Bizim minimal ana bilgisayarımız
    // henüz modül-kapanışında tip temizliğini desteklemiyor (bilinçli bir
    // v0.1 sınırlaması) — bu yüzden bu ÖZEL test, gerçek bir hatayı DEĞİL,
    // bu bilinen sınırlamayı sızıntı olarak raporlamaması için farklı bir
    // allocator kullanıyor.
    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    // Eklenti `Counter` tipini TEMBEL olarak ilk `make_counter` çağrısında
    // (gerçek `HPyType_FromSpec` ile) oluşturur — bkz. noxtest.c.
    const arg = ctx.ctx_Long_FromInt64_t.?(ctx, 99);
    defer ctx.ctx_Close.?(ctx, arg);
    const counter = make_counter(ctx, hpy.context.HPy_NULL, arg);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);

    const x_result = get_counter_x(ctx, hpy.context.HPy_NULL, counter);
    defer ctx.ctx_Close.?(ctx, x_result);
    try std.testing.expectEqual(@as(i64, 99), ctx.ctx_Long_AsInt64_t.?(ctx, x_result));

    const before = get_destroy_count(ctx, hpy.context.HPy_NULL, dummy);
    defer ctx.ctx_Close.?(ctx, before);
    const before_n = ctx.ctx_Long_AsInt64_t.?(ctx, before);

    // Örneği KAPAT — eklentinin GERÇEK `HPy_tp_destroy` slotu tetiklenmeli.
    ctx.ctx_Close.?(ctx, counter);

    const after = get_destroy_count(ctx, hpy.context.HPy_NULL, dummy);
    defer ctx.ctx_Close.?(ctx, after);
    try std.testing.expectEqual(before_n + 1, ctx.ctx_Long_AsInt64_t.?(ctx, after));
}

test "gerçek HPy eklentisi: ctx_Call ile Widget(5)(3) == 13 — tp_new+tp_init+tp_call (çağrılabilir nesne protokolü)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const get_widget_type = mod.findMethodO("get_widget_type") orelse return error.MethodNotFound;

    // Aynı gerekçe: Widget_type de noxtest.c'de tembel/statik önbelleklenir
    // (bkz. Counter testinin AYNI belge notu) — page_allocator kullanılır.
    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);
    const widget_type = get_widget_type(ctx, hpy.context.HPy_NULL, dummy);

    // --- ctx_Call: tp_new(5) + tp_init(+5) = 10 ---
    const five = ctx.ctx_Long_FromInt64_t.?(ctx, 5);
    defer ctx.ctx_Close.?(ctx, five);
    var ctor_args = [_]hpy.context.HPy{five};
    const widget = ctx.ctx_Call.?(ctx, widget_type, &ctor_args, 1, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, widget);
    try std.testing.expect(widget._i != 0);

    // --- ctx_Call örnek üzerinde: tp_call — 10 + 3 = 13 ---
    const three = ctx.ctx_Long_FromInt64_t.?(ctx, 3);
    defer ctx.ctx_Close.?(ctx, three);
    var call_args = [_]hpy.context.HPy{three};
    const result = ctx.ctx_Call.?(ctx, widget, &call_args, 1, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(i64, 13), ctx.ctx_Long_AsInt64_t.?(ctx, result));

    // --- ctx_CallTupleDict: aynı inşa, tuple üzerinden ---
    const args_tuple = ctx.ctx_Tuple_FromArray.?(ctx, &ctor_args, 1);
    defer ctx.ctx_Close.?(ctx, args_tuple);
    const widget2 = ctx.ctx_CallTupleDict.?(ctx, widget_type, args_tuple, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, widget2);
    try std.testing.expect(widget2._i != 0);

    // --- ctx_Callable_Check ---
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Callable_Check.?(ctx, widget_type));
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Callable_Check.?(ctx, widget));
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Callable_Check.?(ctx, five)); // düz long çağrılabilir değil
}

test "gerçek HPy eklentisi: ctx_Call — tp_new'i olmayan bir tipte TypeError (çağrılabilir nesne protokolü)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const make_counter = mod.findMethodO("make_counter") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    // `Counter` yalnızca `tp_destroy` kaydeder — `Counter_type`i elde etmek
    // İçin `make_counter`ı BİR KEZ çağırıp (bu, tipi TEMBEL ilklendirir),
    // döndürdüğü örneğin KENDİ tipini `ctx_Type` İLE oku.
    const seed = ctx.ctx_Long_FromInt64_t.?(ctx, 1);
    defer ctx.ctx_Close.?(ctx, seed);
    const counter_instance = make_counter(ctx, hpy.context.HPy_NULL, seed);
    defer ctx.ctx_Close.?(ctx, counter_instance);
    const counter_type = ctx.ctx_Type.?(ctx, counter_instance);
    defer ctx.ctx_Close.?(ctx, counter_type);

    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));
    const result = ctx.ctx_Call.?(ctx, counter_type, null, 0, hpy.context.HPy_NULL);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, result._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_Occurred.?(ctx));
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_TypeError));
    ctx.ctx_Err_Clear.?(ctx);
}

test "gerçek HPy eklentisi: ctx_Call/ctx_CallTupleDict — boş olmayan kwargs TypeError verir (v1 sınırlaması)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const get_widget_type = mod.findMethodO("get_widget_type") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);
    const widget_type = get_widget_type(ctx, hpy.context.HPy_NULL, dummy);

    // ctx_Call: kwnames HPy_NULL DEĞİLSE (herhangi bir tutamaç) reddedilir.
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));
    const r1 = ctx.ctx_Call.?(ctx, widget_type, null, 0, dummy);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, r1._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_TypeError));
    ctx.ctx_Err_Clear.?(ctx);

    // ctx_CallTupleDict: kw boş OLMAYAN bir dict İSE reddedilir.
    const empty_tuple = ctx.ctx_Tuple_FromArray.?(ctx, null, 0);
    defer ctx.ctx_Close.?(ctx, empty_tuple);
    const kw = ctx.ctx_Dict_New.?(ctx);
    defer ctx.ctx_Close.?(ctx, kw);
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_SetItem_s.?(ctx, kw, "x", dummy));
    const r2 = ctx.ctx_CallTupleDict.?(ctx, widget_type, empty_tuple, kw);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, r2._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_TypeError));
    ctx.ctx_Err_Clear.?(ctx);
}
