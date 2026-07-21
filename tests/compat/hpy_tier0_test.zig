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

test "gerçek HPy eklentisi: ctx_SetAttr_s/ctx_GetAttr_s/ctx_HasAttr_s — instance_dict round-trip (attribute erişimi)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const get_widget_type = mod.findMethodO("get_widget_type") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);
    const widget_type = get_widget_type(ctx, hpy.context.HPy_NULL, dummy);

    const five = ctx.ctx_Long_FromInt64_t.?(ctx, 5);
    defer ctx.ctx_Close.?(ctx, five);
    var ctor_args = [_]hpy.context.HPy{five};
    const widget = ctx.ctx_Call.?(ctx, widget_type, &ctor_args, 1, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, widget);

    // Başlangıçta yok.
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_HasAttr_s.?(ctx, widget, "label"));

    const label_value = ctx.ctx_Unicode_FromString.?(ctx, "merhaba-widget");
    defer ctx.ctx_Close.?(ctx, label_value);
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_SetAttr_s.?(ctx, widget, "label", label_value));

    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_HasAttr_s.?(ctx, widget, "label"));
    const read_back = ctx.ctx_GetAttr_s.?(ctx, widget, "label");
    defer ctx.ctx_Close.?(ctx, read_back);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Unicode_Check.?(ctx, read_back));

    // Güncelleme yolu — aynı anahtara ikinci kez yazınca eski değer değişir.
    const label_value2 = ctx.ctx_Unicode_FromString.?(ctx, "degisti");
    defer ctx.ctx_Close.?(ctx, label_value2);
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_SetAttr_s.?(ctx, widget, "label", label_value2));
    const read_back2 = ctx.ctx_GetAttr_s.?(ctx, widget, "label");
    defer ctx.ctx_Close.?(ctx, read_back2);
    try std.testing.expectEqual(@as(i64, 7), ctx.ctx_Length.?(ctx, read_back2));
}

test "gerçek HPy eklentisi: get_attr_via_c — Nox'un instance_dict'i GERÇEK HPy_GetAttr_s ile C koduna görünür (attribute erişimi)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const get_widget_type = mod.findMethodO("get_widget_type") orelse return error.MethodNotFound;
    const get_attr_via_c = mod.findMethodO("get_attr_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);
    const widget_type = get_widget_type(ctx, hpy.context.HPy_NULL, dummy);

    const five = ctx.ctx_Long_FromInt64_t.?(ctx, 5);
    defer ctx.ctx_Close.?(ctx, five);
    var ctor_args = [_]hpy.context.HPy{five};
    const widget = ctx.ctx_Call.?(ctx, widget_type, &ctor_args, 1, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, widget);

    const label_value = ctx.ctx_Unicode_FromString.?(ctx, "c-tarafindan-goruluyor");
    defer ctx.ctx_Close.?(ctx, label_value);
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_SetAttr_s.?(ctx, widget, "label", label_value));

    const via_c = get_attr_via_c(ctx, hpy.context.HPy_NULL, widget);
    defer ctx.ctx_Close.?(ctx, via_c);
    try std.testing.expectEqual(@as(i64, 22), ctx.ctx_Length.?(ctx, via_c));
}

test "gerçek HPy eklentisi: ctx_GetAttr_s ile type_methods'tan bağlı metod — widget.add_value(3) (attribute erişimi)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const get_widget_type = mod.findMethodO("get_widget_type") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);
    const widget_type = get_widget_type(ctx, hpy.context.HPy_NULL, dummy);

    const ten = ctx.ctx_Long_FromInt64_t.?(ctx, 10);
    defer ctx.ctx_Close.?(ctx, ten);
    var ctor_args = [_]hpy.context.HPy{ten};
    const widget = ctx.ctx_Call.?(ctx, widget_type, &ctor_args, 1, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, widget);
    // tp_new(10) + tp_init(+10) = 20

    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_HasAttr_s.?(ctx, widget, "add_value"));
    const bound = ctx.ctx_GetAttr_s.?(ctx, widget, "add_value");
    defer ctx.ctx_Close.?(ctx, bound);
    try std.testing.expect(bound._i != 0);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Callable_Check.?(ctx, bound));

    const three = ctx.ctx_Long_FromInt64_t.?(ctx, 3);
    defer ctx.ctx_Close.?(ctx, three);
    var call_args = [_]hpy.context.HPy{three};
    const result = ctx.ctx_Call.?(ctx, bound, &call_args, 1, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(i64, 23), ctx.ctx_Long_AsInt64_t.?(ctx, result)); // self.value(20) + 3
}

test "gerçek HPy eklentisi: ctx_GetAttr_s/ctx_HasAttr_s — var olmayan attribute (negatif, attribute erişimi)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const get_widget_type = mod.findMethodO("get_widget_type") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);
    const widget_type = get_widget_type(ctx, hpy.context.HPy_NULL, dummy);

    const five = ctx.ctx_Long_FromInt64_t.?(ctx, 5);
    defer ctx.ctx_Close.?(ctx, five);
    var ctor_args = [_]hpy.context.HPy{five};
    const widget = ctx.ctx_Call.?(ctx, widget_type, &ctor_args, 1, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, widget);

    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_HasAttr_s.?(ctx, widget, "yok_boyle_bir_sey"));
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx)); // hasattr hata AYARLAMAZ

    const result = ctx.ctx_GetAttr_s.?(ctx, widget, "yok_boyle_bir_sey");
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, result._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_Occurred.?(ctx));
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_AttributeError));
    ctx.ctx_Err_Clear.?(ctx);
}

test "gerçek HPy eklentisi: ctx_CallMethod ile widget.add_value(3) — args[0]=alıcı sözleşmesi (Faz OO)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const get_widget_type = mod.findMethodO("get_widget_type") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);
    const widget_type = get_widget_type(ctx, hpy.context.HPy_NULL, dummy);

    const ten = ctx.ctx_Long_FromInt64_t.?(ctx, 10);
    defer ctx.ctx_Close.?(ctx, ten);
    var ctor_args = [_]hpy.context.HPy{ten};
    const widget = ctx.ctx_Call.?(ctx, widget_type, &ctor_args, 1, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, widget);
    // tp_new(10) + tp_init(+10) = 20

    const name = ctx.ctx_Unicode_FromString.?(ctx, "add_value");
    defer ctx.ctx_Close.?(ctx, name);
    const three = ctx.ctx_Long_FromInt64_t.?(ctx, 3);
    defer ctx.ctx_Close.?(ctx, three);
    // args[0] ALICI (self), args[1..] GERÇEK metod argümanları; nargs ALICIYI DA SAYAR.
    var call_args = [_]hpy.context.HPy{ widget, three };
    const result = ctx.ctx_CallMethod.?(ctx, name, &call_args, 2, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(i64, 23), ctx.ctx_Long_AsInt64_t.?(ctx, result)); // self.value(20) + 3
}

test "gerçek HPy eklentisi: call_add_value_via_c — eklentinin KENDİ HPy_CallMethod çağrısı ctx_CallMethod'a doğru trampoline eder (Faz OO)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const get_widget_type = mod.findMethodO("get_widget_type") orelse return error.MethodNotFound;
    const call_add_value_via_c = mod.findMethodO("call_add_value_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);
    const widget_type = get_widget_type(ctx, hpy.context.HPy_NULL, dummy);

    const seven = ctx.ctx_Long_FromInt64_t.?(ctx, 7);
    defer ctx.ctx_Close.?(ctx, seven);
    var ctor_args = [_]hpy.context.HPy{seven};
    const widget = ctx.ctx_Call.?(ctx, widget_type, &ctor_args, 1, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, widget);
    // tp_new(7) + tp_init(+7) = 14

    const four = ctx.ctx_Long_FromInt64_t.?(ctx, 4);
    defer ctx.ctx_Close.?(ctx, four);
    var pair_items = [_]hpy.context.HPy{ widget, four };
    const pair = ctx.ctx_Tuple_FromArray.?(ctx, &pair_items, 2);
    defer ctx.ctx_Close.?(ctx, pair);

    const result = call_add_value_via_c(ctx, hpy.context.HPy_NULL, pair);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(i64, 18), ctx.ctx_Long_AsInt64_t.?(ctx, result)); // self.value(14) + 4
}

test "gerçek HPy eklentisi: ctx_CallMethod — negatif testler (kwargs reddi, var olmayan metod, Faz OO)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const get_widget_type = mod.findMethodO("get_widget_type") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);
    const widget_type = get_widget_type(ctx, hpy.context.HPy_NULL, dummy);

    const five = ctx.ctx_Long_FromInt64_t.?(ctx, 5);
    defer ctx.ctx_Close.?(ctx, five);
    var ctor_args = [_]hpy.context.HPy{five};
    const widget = ctx.ctx_Call.?(ctx, widget_type, &ctor_args, 1, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, widget);

    // kwnames HPy_NULL DEĞİLSE (herhangi bir tutamaç) reddedilir (v1 sınırlaması).
    const name = ctx.ctx_Unicode_FromString.?(ctx, "add_value");
    defer ctx.ctx_Close.?(ctx, name);
    var call_args = [_]hpy.context.HPy{widget};
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));
    const r1 = ctx.ctx_CallMethod.?(ctx, name, &call_args, 1, dummy);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, r1._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_TypeError));
    ctx.ctx_Err_Clear.?(ctx);

    // Var olmayan bir metod adı — AttributeError (ctx_GetAttr'dan ayarlanır).
    const bad_name = ctx.ctx_Unicode_FromString.?(ctx, "yok_boyle_bir_metod");
    defer ctx.ctx_Close.?(ctx, bad_name);
    const r2 = ctx.ctx_CallMethod.?(ctx, bad_name, &call_args, 1, hpy.context.HPy_NULL);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, r2._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_AttributeError));
    ctx.ctx_Err_Clear.?(ctx);
}

test "gerçek HPy eklentisi: long_conv_roundtrip(42) == 42 — Int32/UInt32/UInt64/Size_t/Ssize_t zinciri (Faz PP)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const long_conv_roundtrip = mod.findMethodO("long_conv_roundtrip") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const arg = ctx.ctx_Long_FromInt64_t.?(ctx, 42);
    defer ctx.ctx_Close.?(ctx, arg);

    const result = long_conv_roundtrip(ctx, hpy.context.HPy_NULL, arg);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(i64, 42), ctx.ctx_Long_AsInt64_t.?(ctx, result));
}

test "gerçek HPy eklentisi: long_as_double_via_c(7) == 7.0 — ctx_Long_AsDouble (Faz PP)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const long_as_double_via_c = mod.findMethodO("long_as_double_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const arg = ctx.ctx_Long_FromInt64_t.?(ctx, 7);
    defer ctx.ctx_Close.?(ctx, arg);

    const result = long_as_double_via_c(ctx, hpy.context.HPy_NULL, arg);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), ctx.ctx_Float_AsDouble.?(ctx, result), 1e-9);
}

test "gerçek HPy eklentisi: long_as_voidptr_roundtrip(1024) == 1024 — ctx_Long_AsVoidPtr (Faz PP)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const long_as_voidptr_roundtrip = mod.findMethodO("long_as_voidptr_roundtrip") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const arg = ctx.ctx_Long_FromInt64_t.?(ctx, 1024);
    defer ctx.ctx_Close.?(ctx, arg);

    const result = long_as_voidptr_roundtrip(ctx, hpy.context.HPy_NULL, arg);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(i64, 1024), ctx.ctx_Long_AsInt64_t.?(ctx, result));
}

test "gerçek HPy eklentisi: ctx_Long_As*Mask ve overflow davranışları (Faz PP, doğrudan Zig'den)" {
    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    // Negatif bir değer İçin AsUInt32_t/AsUInt64_t/AsSize_t OverflowError vermeli.
    const neg = ctx.ctx_Long_FromInt64_t.?(ctx, -1);
    defer ctx.ctx_Close.?(ctx, neg);
    _ = ctx.ctx_Long_AsUInt32_t.?(ctx, neg);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_OverflowError));
    ctx.ctx_Err_Clear.?(ctx);

    // Mask varyantları HATA VERMEZ — bit düzenini KORUR.
    const masked = ctx.ctx_Long_AsUInt32_tMask.?(ctx, neg);
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), masked);

    const masked64 = ctx.ctx_Long_AsUInt64_tMask.?(ctx, neg);
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), masked64);

    // i32 sınırının dışında bir değer — AsInt32_t OverflowError vermeli.
    const big = ctx.ctx_Long_FromInt64_t.?(ctx, 1 << 40);
    defer ctx.ctx_Close.?(ctx, big);
    _ = ctx.ctx_Long_AsInt32_t.?(ctx, big);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_OverflowError));
    ctx.ctx_Err_Clear.?(ctx);
}

test "gerçek HPy eklentisi: number_ops_via_c(13, 4) — sayı protokolünün geri kalanı (Faz QQ)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const number_ops_via_c = mod.findMethodO("number_ops_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const a = ctx.ctx_Long_FromInt64_t.?(ctx, 13);
    defer ctx.ctx_Close.?(ctx, a);
    const b = ctx.ctx_Long_FromInt64_t.?(ctx, 4);
    defer ctx.ctx_Close.?(ctx, b);
    var pair_items = [_]hpy.context.HPy{ a, b };
    const pair = ctx.ctx_Tuple_FromArray.?(ctx, &pair_items, 2);
    defer ctx.ctx_Close.?(ctx, pair);

    const result = number_ops_via_c(ctx, hpy.context.HPy_NULL, pair);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Tuple_Check.?(ctx, result));
    try std.testing.expectEqual(@as(isize, 12), ctx.ctx_Length.?(ctx, result));

    const number_check = ctx.ctx_GetItem_i.?(ctx, result, 0);
    defer ctx.ctx_Close.?(ctx, number_check);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_IsTrue.?(ctx, number_check));

    const divmod = ctx.ctx_GetItem_i.?(ctx, result, 1);
    defer ctx.ctx_Close.?(ctx, divmod);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Tuple_Check.?(ctx, divmod));
    const q = ctx.ctx_GetItem_i.?(ctx, divmod, 0);
    defer ctx.ctx_Close.?(ctx, q);
    const r = ctx.ctx_GetItem_i.?(ctx, divmod, 1);
    defer ctx.ctx_Close.?(ctx, r);
    try std.testing.expectEqual(@as(i64, 3), ctx.ctx_Long_AsInt64_t.?(ctx, q));
    try std.testing.expectEqual(@as(i64, 1), ctx.ctx_Long_AsInt64_t.?(ctx, r));

    const expected = [_]i64{ 28561, 13, -14, 208, 0, 4, 9, 13, 13, 17 };
    for (expected, 2..) |exp, i| {
        const item = ctx.ctx_GetItem_i.?(ctx, result, @intCast(i));
        defer ctx.ctx_Close.?(ctx, item);
        try std.testing.expectEqual(exp, ctx.ctx_Long_AsInt64_t.?(ctx, item));
    }
}

test "gerçek HPy eklentisi: matmul_via_c — @ (matris çarpımı) desteklenmiyor → TypeError (Faz QQ)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const matmul_via_c = mod.findMethodO("matmul_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const a = ctx.ctx_Long_FromInt64_t.?(ctx, 2);
    defer ctx.ctx_Close.?(ctx, a);
    const b = ctx.ctx_Long_FromInt64_t.?(ctx, 3);
    defer ctx.ctx_Close.?(ctx, b);
    var pair_items = [_]hpy.context.HPy{ a, b };
    const pair = ctx.ctx_Tuple_FromArray.?(ctx, &pair_items, 2);
    defer ctx.ctx_Close.?(ctx, pair);

    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));
    const result = matmul_via_c(ctx, hpy.context.HPy_NULL, pair);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, result._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_TypeError));
    ctx.ctx_Err_Clear.?(ctx);
}

test "gerçek HPy eklentisi: pow_mod_via_c(7, 3, 5) == 3 — üç argümanlı ctx_Power (Faz QQ)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const pow_mod_via_c = mod.findMethodO("pow_mod_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const seven = ctx.ctx_Long_FromInt64_t.?(ctx, 7);
    defer ctx.ctx_Close.?(ctx, seven);
    const three = ctx.ctx_Long_FromInt64_t.?(ctx, 3);
    defer ctx.ctx_Close.?(ctx, three);
    const five = ctx.ctx_Long_FromInt64_t.?(ctx, 5);
    defer ctx.ctx_Close.?(ctx, five);
    var items = [_]hpy.context.HPy{ seven, three, five };
    const triple = ctx.ctx_Tuple_FromArray.?(ctx, &items, 3);
    defer ctx.ctx_Close.?(ctx, triple);

    const result = pow_mod_via_c(ctx, hpy.context.HPy_NULL, triple);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(i64, 3), ctx.ctx_Long_AsInt64_t.?(ctx, result));
}

test "gerçek HPy eklentisi: long_float_via_c(9) == (9, 9.0) — ctx_Long/ctx_Float (Faz QQ)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const long_float_via_c = mod.findMethodO("long_float_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const nine = ctx.ctx_Long_FromInt64_t.?(ctx, 9);
    defer ctx.ctx_Close.?(ctx, nine);

    const result = long_float_via_c(ctx, hpy.context.HPy_NULL, nine);
    defer ctx.ctx_Close.?(ctx, result);
    const as_long = ctx.ctx_GetItem_i.?(ctx, result, 0);
    defer ctx.ctx_Close.?(ctx, as_long);
    const as_float = ctx.ctx_GetItem_i.?(ctx, result, 1);
    defer ctx.ctx_Close.?(ctx, as_float);
    try std.testing.expectEqual(@as(i64, 9), ctx.ctx_Long_AsInt64_t.?(ctx, as_long));
    try std.testing.expectApproxEqAbs(@as(f64, 9.0), ctx.ctx_Float_AsDouble.?(ctx, as_float), 1e-9);
}

test "gerçek HPy eklentisi: err_set_object_via_c — ctx_Err_SetObject bir DEĞER nesnesi taşır (Faz RR)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const err_set_object_via_c = mod.findMethodO("err_set_object_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const value = ctx.ctx_Long_FromInt64_t.?(ctx, 99);
    defer ctx.ctx_Close.?(ctx, value);

    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));
    const result = err_set_object_via_c(ctx, hpy.context.HPy_NULL, value);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, result._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_Occurred.?(ctx));
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_ValueError));
    ctx.ctx_Err_Clear.?(ctx);
}

test "gerçek HPy eklentisi: err_from_errno_via_c — ctx_Err_SetFromErrnoWithFilename (Faz RR)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const err_from_errno_via_c = mod.findMethodO("err_from_errno_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const filename = ctx.ctx_Unicode_FromString.?(ctx, "/tmp/olmayan-bir-dosya");
    defer ctx.ctx_Close.?(ctx, filename);

    const result = err_from_errno_via_c(ctx, hpy.context.HPy_NULL, filename);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, result._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_Occurred.?(ctx));
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_OSError));
    ctx.ctx_Err_Clear.?(ctx);
}

test "gerçek HPy eklentisi: err_from_errno_objects_via_c — ctx_Err_SetFromErrnoWithFilenameObjects (Faz RR)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const err_from_errno_objects_via_c = mod.findMethodO("err_from_errno_objects_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const f1 = ctx.ctx_Unicode_FromString.?(ctx, "kaynak.txt");
    defer ctx.ctx_Close.?(ctx, f1);
    const f2 = ctx.ctx_Unicode_FromString.?(ctx, "hedef.txt");
    defer ctx.ctx_Close.?(ctx, f2);
    var pair_items = [_]hpy.context.HPy{ f1, f2 };
    const pair = ctx.ctx_Tuple_FromArray.?(ctx, &pair_items, 2);
    defer ctx.ctx_Close.?(ctx, pair);

    const result = err_from_errno_objects_via_c(ctx, hpy.context.HPy_NULL, pair);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, result._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_Occurred.?(ctx));
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_OSError));
    ctx.ctx_Err_Clear.?(ctx);
}

test "gerçek HPy eklentisi: ctx_Err_NewException — iki ayrı çağrı İKİ FARKLI kimlik üretir (Faz RR, doğrudan Zig'den)" {
    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const exc1 = ctx.ctx_Err_NewException.?(ctx, "noxtest.Error1", hpy.context.HPy_NULL, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, exc1);
    const exc2 = ctx.ctx_Err_NewExceptionWithDoc.?(ctx, "noxtest.Error2", "belge", hpy.context.HPy_NULL, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, exc2);
    try std.testing.expect(exc1._i != exc2._i);

    ctx.ctx_Err_SetString.?(ctx, exc1, "hata1");
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, exc1));
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_ExceptionMatches.?(ctx, exc2));
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_ValueError));
    ctx.ctx_Err_Clear.?(ctx);
}

test "gerçek HPy eklentisi: new_exception_via_c — ctx_Err_NewException eklentiden çağrılır, ValueError'la EŞLEŞMEZ (Faz RR)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const new_exception_via_c = mod.findMethodO("new_exception_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);

    const result = new_exception_via_c(ctx, hpy.context.HPy_NULL, dummy);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, result._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_Occurred.?(ctx));
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_ValueError));
    ctx.ctx_Err_Clear.?(ctx);
}

test "gerçek HPy eklentisi: warn_via_c — ctx_Err_WarnEx 0 döner, istisna YÜKSELTMEZ (Faz RR)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const warn_via_c = mod.findMethodO("warn_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);

    const result = warn_via_c(ctx, hpy.context.HPy_NULL, dummy);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(i64, 0), ctx.ctx_Long_AsInt64_t.?(ctx, result));
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));
}

test "gerçek HPy eklentisi: write_unraisable_via_c — ctx_Err_WriteUnraisable bekleyen istisnayı TEMİZLER (Faz RR)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const write_unraisable_via_c = mod.findMethodO("write_unraisable_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);

    const result = write_unraisable_via_c(ctx, hpy.context.HPy_NULL, dummy);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_IsTrue.?(ctx, result));
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));
}

fn strEqualsUtf8(ctx: *hpy.context.HPyContext, h: hpy.context.HPy, expected: []const u8) !void {
    var size: isize = 0;
    const ptr = ctx.ctx_Unicode_AsUTF8AndSize.?(ctx, h, &size) orelse return error.NullString;
    try std.testing.expectEqualStrings(expected, ptr[0..@intCast(size)]);
}

test "gerçek HPy eklentisi: repr_via_c/str_via_c — jenerik biçimlendirme (Faz SS)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const repr_via_c = mod.findMethodO("repr_via_c") orelse return error.MethodNotFound;
    const str_via_c = mod.findMethodO("str_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    // None / bool / int / float
    {
        const r = repr_via_c(ctx, hpy.context.HPy_NULL, ctx.h_None);
        defer ctx.ctx_Close.?(ctx, r);
        try strEqualsUtf8(ctx, r, "None");
    }
    {
        const r = repr_via_c(ctx, hpy.context.HPy_NULL, ctx.h_True);
        defer ctx.ctx_Close.?(ctx, r);
        try strEqualsUtf8(ctx, r, "True");
    }
    {
        const n = ctx.ctx_Long_FromInt64_t.?(ctx, 42);
        defer ctx.ctx_Close.?(ctx, n);
        const r = repr_via_c(ctx, hpy.context.HPy_NULL, n);
        defer ctx.ctx_Close.?(ctx, r);
        try strEqualsUtf8(ctx, r, "42");
        const s = str_via_c(ctx, hpy.context.HPy_NULL, n);
        defer ctx.ctx_Close.?(ctx, s);
        try strEqualsUtf8(ctx, s, "42");
    }
    {
        // Python float repr HER ZAMAN bir ondalık nokta taşır: 3.0, 3 DEĞİL.
        const f = ctx.ctx_Float_FromDouble.?(ctx, 3.0);
        defer ctx.ctx_Close.?(ctx, f);
        const r = repr_via_c(ctx, hpy.context.HPy_NULL, f);
        defer ctx.ctx_Close.?(ctx, r);
        try strEqualsUtf8(ctx, r, "3.0");
    }
    // str: repr tırnaklı+kaçışlı, str tırnaksız
    {
        const s1 = ctx.ctx_Unicode_FromString.?(ctx, "he'llo");
        defer ctx.ctx_Close.?(ctx, s1);
        const r = repr_via_c(ctx, hpy.context.HPy_NULL, s1);
        defer ctx.ctx_Close.?(ctx, r);
        try strEqualsUtf8(ctx, r, "\"he'llo\"");
        const s = str_via_c(ctx, hpy.context.HPy_NULL, s1);
        defer ctx.ctx_Close.?(ctx, s);
        try strEqualsUtf8(ctx, s, "he'llo");
    }
    // list/tuple/dict
    {
        const one = ctx.ctx_Long_FromInt64_t.?(ctx, 1);
        defer ctx.ctx_Close.?(ctx, one);
        const two = ctx.ctx_Long_FromInt64_t.?(ctx, 2);
        defer ctx.ctx_Close.?(ctx, two);
        const list = ctx.ctx_List_New.?(ctx, 0);
        defer ctx.ctx_Close.?(ctx, list);
        _ = ctx.ctx_List_Append.?(ctx, list, one);
        _ = ctx.ctx_List_Append.?(ctx, list, two);
        const r = repr_via_c(ctx, hpy.context.HPy_NULL, list);
        defer ctx.ctx_Close.?(ctx, r);
        try strEqualsUtf8(ctx, r, "[1, 2]");

        var one_item = [_]hpy.context.HPy{one};
        const singleton_tuple = ctx.ctx_Tuple_FromArray.?(ctx, &one_item, 1);
        defer ctx.ctx_Close.?(ctx, singleton_tuple);
        const r2 = repr_via_c(ctx, hpy.context.HPy_NULL, singleton_tuple);
        defer ctx.ctx_Close.?(ctx, r2);
        try strEqualsUtf8(ctx, r2, "(1,)");

        const d = ctx.ctx_Dict_New.?(ctx);
        defer ctx.ctx_Close.?(ctx, d);
        _ = ctx.ctx_SetItem_s.?(ctx, d, "x", one);
        const r3 = repr_via_c(ctx, hpy.context.HPy_NULL, d);
        defer ctx.ctx_Close.?(ctx, r3);
        try strEqualsUtf8(ctx, r3, "{'x': 1}");
    }
}

test "gerçek HPy eklentisi: ascii_via_c — ASCII-dışı baytlar \\xHH ile kaçışlanır (Faz SS)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const ascii_via_c = mod.findMethodO("ascii_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    // "café" — 'é' UTF-8'de U+00E9, iki baytlık bir kodlama (0xC3 0xA9).
    const s = ctx.ctx_Unicode_FromString.?(ctx, "caf\xc3\xa9");
    defer ctx.ctx_Close.?(ctx, s);
    const r = ascii_via_c(ctx, hpy.context.HPy_NULL, s);
    defer ctx.ctx_Close.?(ctx, r);
    try strEqualsUtf8(ctx, r, "'caf\\xe9'");
}

test "gerçek HPy eklentisi: bytes_via_c — str/bytes → bytes çevrimi + TypeError (Faz SS)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const bytes_via_c = mod.findMethodO("bytes_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const s = ctx.ctx_Unicode_FromString.?(ctx, "ab");
    defer ctx.ctx_Close.?(ctx, s);
    const b = bytes_via_c(ctx, hpy.context.HPy_NULL, s);
    defer ctx.ctx_Close.?(ctx, b);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Bytes_Check.?(ctx, b));
    try std.testing.expectEqual(@as(isize, 2), ctx.ctx_Bytes_Size.?(ctx, b));
    const ptr = ctx.ctx_Bytes_AsString.?(ctx, b) orelse return error.NullBytes;
    try std.testing.expectEqualStrings("ab", ptr[0..2]);

    // Yeniden dönüştürme — aynı bytes nesnesi (dup) dönmeli.
    const b2 = bytes_via_c(ctx, hpy.context.HPy_NULL, b);
    defer ctx.ctx_Close.?(ctx, b2);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Bytes_Check.?(ctx, b2));

    // long -> TypeError
    const n = ctx.ctx_Long_FromInt64_t.?(ctx, 5);
    defer ctx.ctx_Close.?(ctx, n);
    try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_Err_Occurred.?(ctx));
    const r = bytes_via_c(ctx, hpy.context.HPy_NULL, n);
    try std.testing.expectEqual(hpy.context.HPy_NULL._i, r._i);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_Err_ExceptionMatches.?(ctx, ctx.h_TypeError));
    ctx.ctx_Err_Clear.?(ctx);
}

test "gerçek HPy eklentisi: bytes_roundtrip_via_c — gömülü \\0 dahil Bytes_FromStringAndSize/Size/AsString (Faz TT)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const bytes_roundtrip_via_c = mod.findMethodO("bytes_roundtrip_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);
    const result = bytes_roundtrip_via_c(ctx, hpy.context.HPy_NULL, dummy);
    defer ctx.ctx_Close.?(ctx, result);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_IsTrue.?(ctx, result));
}

test "gerçek HPy eklentisi: hash_via_c — int hash kimliği + tutarlılık (Faz SS)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const hash_via_c = mod.findMethodO("hash_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const forty_two = ctx.ctx_Long_FromInt64_t.?(ctx, 42);
    defer ctx.ctx_Close.?(ctx, forty_two);
    const h1 = hash_via_c(ctx, hpy.context.HPy_NULL, forty_two);
    defer ctx.ctx_Close.?(ctx, h1);
    try std.testing.expectEqual(@as(i64, 42), ctx.ctx_Long_AsInt64_t.?(ctx, h1));

    // Gerçek CPython sözleşmesi: hash(-1) == -2 (hata SİNYALİ olan -1 İLE
    // ÇAKIŞMASIN diye).
    const neg_one = ctx.ctx_Long_FromInt64_t.?(ctx, -1);
    defer ctx.ctx_Close.?(ctx, neg_one);
    const h2 = hash_via_c(ctx, hpy.context.HPy_NULL, neg_one);
    defer ctx.ctx_Close.?(ctx, h2);
    try std.testing.expectEqual(@as(i64, -2), ctx.ctx_Long_AsInt64_t.?(ctx, h2));

    // Aynı içerikli str — AYNI süreç İÇİNDE (aynı tohum) İKİ kez hash'lenince
    // TUTARLI bir değer üretmeli ve -1 (hata sinyali) OLMAMALI.
    const s1 = ctx.ctx_Unicode_FromString.?(ctx, "merhaba");
    defer ctx.ctx_Close.?(ctx, s1);
    const s2 = ctx.ctx_Unicode_FromString.?(ctx, "merhaba");
    defer ctx.ctx_Close.?(ctx, s2);
    const hs1 = hash_via_c(ctx, hpy.context.HPy_NULL, s1);
    defer ctx.ctx_Close.?(ctx, hs1);
    const hs2 = hash_via_c(ctx, hpy.context.HPy_NULL, s2);
    defer ctx.ctx_Close.?(ctx, hs2);
    try std.testing.expectEqual(ctx.ctx_Long_AsInt64_t.?(ctx, hs1), ctx.ctx_Long_AsInt64_t.?(ctx, hs2));
    try std.testing.expect(ctx.ctx_Long_AsInt64_t.?(ctx, hs1) != -1);
}

test "gerçek HPy eklentisi: richcompare_via_c/richcomparebool_via_c — sayısal + sözlüksel sıralama (Faz SS)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const richcompare_via_c = mod.findMethodO("richcompare_via_c") orelse return error.MethodNotFound;
    const richcomparebool_via_c = mod.findMethodO("richcomparebool_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.testing.allocator);
    defer hpy.context.destroyContext(std.testing.allocator, ctx);

    const HPy_LT = 0;
    const HPy_GT = 4;

    const five = ctx.ctx_Long_FromInt64_t.?(ctx, 5);
    defer ctx.ctx_Close.?(ctx, five);
    const three = ctx.ctx_Long_FromInt64_t.?(ctx, 3);
    defer ctx.ctx_Close.?(ctx, three);

    {
        const lt = ctx.ctx_Long_FromInt64_t.?(ctx, HPy_LT);
        defer ctx.ctx_Close.?(ctx, lt);
        var items = [_]hpy.context.HPy{ five, three, lt };
        const triple = ctx.ctx_Tuple_FromArray.?(ctx, &items, 3);
        defer ctx.ctx_Close.?(ctx, triple);
        const r = richcompare_via_c(ctx, hpy.context.HPy_NULL, triple);
        defer ctx.ctx_Close.?(ctx, r);
        try std.testing.expectEqual(@as(c_int, 0), ctx.ctx_IsTrue.?(ctx, r)); // 5 < 3 YANLIŞ
    }
    {
        const gt = ctx.ctx_Long_FromInt64_t.?(ctx, HPy_GT);
        defer ctx.ctx_Close.?(ctx, gt);
        var items = [_]hpy.context.HPy{ five, three, gt };
        const triple = ctx.ctx_Tuple_FromArray.?(ctx, &items, 3);
        defer ctx.ctx_Close.?(ctx, triple);
        const r = richcomparebool_via_c(ctx, hpy.context.HPy_NULL, triple);
        defer ctx.ctx_Close.?(ctx, r);
        try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_IsTrue.?(ctx, r)); // 5 > 3 DOĞRU
    }
    {
        const abc = ctx.ctx_Unicode_FromString.?(ctx, "abc");
        defer ctx.ctx_Close.?(ctx, abc);
        const abd = ctx.ctx_Unicode_FromString.?(ctx, "abd");
        defer ctx.ctx_Close.?(ctx, abd);
        const lt = ctx.ctx_Long_FromInt64_t.?(ctx, HPy_LT);
        defer ctx.ctx_Close.?(ctx, lt);
        var items = [_]hpy.context.HPy{ abc, abd, lt };
        const triple = ctx.ctx_Tuple_FromArray.?(ctx, &items, 3);
        defer ctx.ctx_Close.?(ctx, triple);
        const r = richcompare_via_c(ctx, hpy.context.HPy_NULL, triple);
        defer ctx.ctx_Close.?(ctx, r);
        try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_IsTrue.?(ctx, r)); // "abc" < "abd" DOĞRU
    }
}

test "gerçek HPy eklentisi: generic_new_via_c — tp_new'i OLMAYAN Counter'da HPyType_GenericNew (Faz SS)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const make_counter = mod.findMethodO("make_counter") orelse return error.MethodNotFound;
    const generic_new_via_c = mod.findMethodO("generic_new_via_c") orelse return error.MethodNotFound;

    // Counter_type de tembel/statik önbelleklenir (bkz. MEVCUT Counter testi).
    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    const seed = ctx.ctx_Long_FromInt64_t.?(ctx, 1);
    defer ctx.ctx_Close.?(ctx, seed);
    const counter_instance = make_counter(ctx, hpy.context.HPy_NULL, seed);
    defer ctx.ctx_Close.?(ctx, counter_instance);
    const counter_type = ctx.ctx_Type.?(ctx, counter_instance);
    defer ctx.ctx_Close.?(ctx, counter_type);

    const new_instance = generic_new_via_c(ctx, hpy.context.HPy_NULL, counter_type);
    defer ctx.ctx_Close.?(ctx, new_instance);
    try std.testing.expect(new_instance._i != 0);
    try std.testing.expectEqual(@as(c_int, 1), ctx.ctx_TypeCheck.?(ctx, new_instance, counter_type));
}

test "gerçek HPy eklentisi: Widget'ın özel tp_repr/tp_hash slotları — jenerik varsayılana DÜŞMEZ (Faz SS)" {
    const so_path = @import("build_options").noxtest_so_path;

    var mod = try hpy.loader.load(so_path, "noxtest");
    defer mod.deinit();

    const get_widget_type = mod.findMethodO("get_widget_type") orelse return error.MethodNotFound;
    const repr_via_c = mod.findMethodO("repr_via_c") orelse return error.MethodNotFound;
    const hash_via_c = mod.findMethodO("hash_via_c") orelse return error.MethodNotFound;

    const ctx = try hpy.context.createContext(std.heap.page_allocator);
    defer hpy.context.destroyContext(std.heap.page_allocator, ctx);

    const dummy = ctx.ctx_Long_FromInt64_t.?(ctx, 0);
    defer ctx.ctx_Close.?(ctx, dummy);
    const widget_type = get_widget_type(ctx, hpy.context.HPy_NULL, dummy);

    const seven = ctx.ctx_Long_FromInt64_t.?(ctx, 7);
    defer ctx.ctx_Close.?(ctx, seven);
    var ctor_args = [_]hpy.context.HPy{seven};
    const widget = ctx.ctx_Call.?(ctx, widget_type, &ctor_args, 1, hpy.context.HPy_NULL);
    defer ctx.ctx_Close.?(ctx, widget);
    // tp_new(7) + tp_init(+7) = 14

    const r = repr_via_c(ctx, hpy.context.HPy_NULL, widget);
    defer ctx.ctx_Close.?(ctx, r);
    try strEqualsUtf8(ctx, r, "Widget(value=14)");

    const h = hash_via_c(ctx, hpy.context.HPy_NULL, widget);
    defer ctx.ctx_Close.?(ctx, h);
    try std.testing.expectEqual(@as(i64, 14), ctx.ctx_Long_AsInt64_t.?(ctx, h));
}
