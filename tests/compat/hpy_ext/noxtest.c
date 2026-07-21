/* Nox HPy uyumluluk testi için GERÇEK, minimal bir HPy uzantısı.
 *
 * `HPY_ABI_UNIVERSAL` modunda derlenir: CPython'a hiç bağlanmaz, yalnızca
 * gerçek HPy header'larına karşı derlenip Nox'un kendi HPyContext
 * implementasyonu (bkz. runtime/hpy_bridge/context.zig) tarafından
 * dlopen ile yüklenmek üzere tasarlanmıştır (AGENTS.md §10, Tier 0/1).
 *
 * Tüm fonksiyonlar `HPyFunc_O` imzasıyla (tek argüman) — Nox'un yükleyicisi
 * (bkz. runtime/hpy_bridge/loader.zig) şu an yalnızca bunu destekliyor:
 *   - add_one(x) -> x + 1                      (Tier 0: Long aritmetiği)
 *   - str_length(s) -> len(s)                  (Tier 1: Unicode + Length)
 *   - negate(x) -> -x                           (Tier 1: sayı protokolü)
 *   - raise_value_error(x) -> HER ZAMAN hata    (Tier 0: hata yönetimi)
 *   - list_sum(lst) -> sum(lst)                 (Tier 1: List + GetItem_i)
 *   - make_pair(x) -> (x, x)                    (Tier 1: Tuple_FromArray)
 *   - dict_get_x(d) -> d["x"]                   (Tier 1: Dict + GetItem_s)
 *   - make_counter(x) -> Counter örneği          (Tier 1: HPyType_FromSpec
 *   - get_counter_x(c) -> c.x                     + ctx_New + AsStruct +
 *   - get_destroy_count(_) -> yıkılan sayısı       tp_destroy)
 *   - get_widget_type(_) -> Widget tipi         (çağrılabilir nesne
 *                                                 protokolü: tp_new/
 *                                                 tp_init/tp_call —
 *                                                 bkz. Widget_* aşağıda)
 */
#include "hpy.h"

/* Çağrılabilir nesne protokolü (ctx_Call/ctx_CallTupleDict/ctx_Callable_
 * Check) test amaçlı minimal bir tip: `Widget(5)` -> value=5 (tp_new)
 * + value += 5 (tp_init) = 10 — tp_new'in AYRICA çalıştığını dıştan
 * kanıtlamak için tp_init KASITLI olarak ÜZERİNE YAZMAK yerine EKLER.
 * `Widget(5)(3)` -> tp_call: value + 3 = 13. */
typedef struct {
    long value;
} WidgetObject;

HPyDef_SLOT(Widget_new, HPy_tp_new)
static HPy Widget_new_impl(HPyContext *ctx, HPy type, const HPy *args, HPy_ssize_t nargs, HPy kw)
{
    (void)kw;
    WidgetObject *data;
    HPy h = HPy_New(ctx, type, (void **)&data);
    data->value = (nargs > 0) ? HPyLong_AsLong(ctx, args[0]) : 0;
    return h;
}

HPyDef_SLOT(Widget_init, HPy_tp_init)
static int Widget_init_impl(HPyContext *ctx, HPy self, const HPy *args, HPy_ssize_t nargs, HPy kw)
{
    (void)kw;
    WidgetObject *data = (WidgetObject *)_HPy_AsStruct_Object(ctx, self);
    if (nargs > 0) {
        data->value += HPyLong_AsLong(ctx, args[0]);
    }
    return 0;
}

HPyDef_SLOT(Widget_call, HPy_tp_call)
static HPy Widget_call_impl(HPyContext *ctx, HPy self, const HPy *args, size_t nargs, HPy kwnames)
{
    (void)kwnames;
    WidgetObject *data = (WidgetObject *)_HPy_AsStruct_Object(ctx, self);
    long extra = (nargs > 0) ? HPyLong_AsLong(ctx, args[0]) : 0;
    return HPyLong_FromLong(ctx, data->value + extra);
}

/* Attribute erişimi (ctx_GetAttr ailesi) test amaçlı GERÇEK bir örnek
 * metodu — `Counter`in `get_counter_x`i GİBİ MODÜL-seviyesi bir
 * fonksiyon DEĞİL, Widget'ın KENDİ `_defines[]`ine kayıtlı (bkz.
 * `HPyType_FromSpec`in `HPyFunc_O` imzalı örnek metodları toplama
 * mekanizması, Faz 19) — `widget.add_value(3)` şeklinde `self`i GERÇEKTEN
 * BAĞLI bir metod olarak erişilebilmesi (`ctx_GetAttr_s` + `ctx_Call`)
 * İÇİN vardır.
 */
HPyDef_METH(Widget_add_value, "add_value", HPyFunc_O)
static HPy Widget_add_value_impl(HPyContext *ctx, HPy self, HPy arg)
{
    WidgetObject *data = (WidgetObject *)_HPy_AsStruct_Object(ctx, self);
    return HPyLong_FromLong(ctx, data->value + HPyLong_AsLong(ctx, arg));
}

static HPyDef *Widget_defines[] = {
    &Widget_new,
    &Widget_init,
    &Widget_call,
    &Widget_add_value,
    NULL
};

static HPyType_Spec Widget_spec = {
    .name = "noxtest.Widget",
    .basicsize = sizeof(WidgetObject),
    .defines = Widget_defines,
};

typedef struct {
    long x;
} CounterObject;

static long counter_destroy_count = 0;

HPyDef_SLOT(Counter_destroy, HPy_tp_destroy)
static void Counter_destroy_impl(void *data)
{
    (void)data;
    counter_destroy_count++;
}

static HPyDef *Counter_defines[] = {
    &Counter_destroy,
    NULL
};

static HPyType_Spec Counter_spec = {
    .name = "noxtest.Counter",
    .basicsize = sizeof(CounterObject),
    .defines = Counter_defines,
};

/* Eklentinin kendi statik `HPy` tutamacı — gerçek HPy'de tipik olarak modül
 * durumunda (`HPyModuleDef.size` + `HPy_GetModuleState`) tutulur; burada
 * basitlik için (Nox'un modül durumu desteği henüz yok) tembel/statik bir
 * global kullanılıyor — yalnızca bu test eklentisi için kabul edilebilir bir
 * basitleştirme (gerçek üretim eklentileri bunu YAPMAMALI). */
static HPy Counter_type = { 0 };

HPyDef_METH(make_counter, "make_counter", HPyFunc_O)
static HPy make_counter_impl(HPyContext *ctx, HPy self, HPy arg)
{
    if (Counter_type._i == 0) {
        Counter_type = HPyType_FromSpec(ctx, &Counter_spec, NULL);
    }
    CounterObject *data;
    HPy h = HPy_New(ctx, Counter_type, &data);
    data->x = HPyLong_AsLong(ctx, arg);
    return h;
}

HPyDef_METH(get_counter_x, "get_counter_x", HPyFunc_O)
static HPy get_counter_x_impl(HPyContext *ctx, HPy self, HPy arg)
{
    CounterObject *data = (CounterObject *)_HPy_AsStruct_Object(ctx, arg);
    return HPyLong_FromLong(ctx, data->x);
}

HPyDef_METH(get_destroy_count, "get_destroy_count", HPyFunc_O)
static HPy get_destroy_count_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)arg;
    return HPyLong_FromLong(ctx, counter_destroy_count);
}

/* Long sayısal dönüşüm ailesi (Faz PP) test amaçlı: eklentinin KENDİ C
 * kodunun HPyLong_AsInt32_t/FromInt32_t/AsUInt32_t/FromUInt32_t/
 * AsUInt64_t/FromUInt64_t/AsSize_t/FromSize_t/AsSsize_t/FromSsize_t
 * makrolarını (HEPSİ ham `ctx_Long_*` ABI yuvalarına TRAMPOLİNE eden)
 * ZİNCİRLEME olarak ÇAĞIRMASI — girdi DEĞİŞMEDEN (bilgi KAYBI OLMADAN)
 * çıkması gerekir (küçük, pozitif bir değer İçin). */
HPyDef_METH(long_conv_roundtrip, "long_conv_roundtrip", HPyFunc_O)
static HPy long_conv_roundtrip_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    int32_t i32v = HPyLong_AsInt32_t(ctx, arg);
    HPy from_i32 = HPyLong_FromInt32_t(ctx, i32v);
    uint32_t u32v = HPyLong_AsUInt32_t(ctx, from_i32);
    HPy from_u32 = HPyLong_FromUInt32_t(ctx, u32v);
    uint64_t u64v = HPyLong_AsUInt64_t(ctx, from_u32);
    HPy from_u64 = HPyLong_FromUInt64_t(ctx, u64v);
    size_t szv = HPyLong_AsSize_t(ctx, from_u64);
    HPy from_sz = HPyLong_FromSize_t(ctx, szv);
    HPy_ssize_t ssv = HPyLong_AsSsize_t(ctx, from_sz);
    HPy result = HPyLong_FromSsize_t(ctx, ssv);
    HPy_Close(ctx, from_i32);
    HPy_Close(ctx, from_u32);
    HPy_Close(ctx, from_u64);
    HPy_Close(ctx, from_sz);
    return result;
}

HPyDef_METH(long_as_double_via_c, "long_as_double_via_c", HPyFunc_O)
static HPy long_as_double_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    double d = HPyLong_AsDouble(ctx, arg);
    return HPyFloat_FromDouble(ctx, d);
}

HPyDef_METH(long_as_voidptr_roundtrip, "long_as_voidptr_roundtrip", HPyFunc_O)
static HPy long_as_voidptr_roundtrip_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    void *p = HPyLong_AsVoidPtr(ctx, arg);
    return HPyLong_FromSize_t(ctx, (size_t)p);
}

HPyDef_METH(add_one, "add_one", HPyFunc_O)
static HPy add_one_impl(HPyContext *ctx, HPy self, HPy arg)
{
    long value = HPyLong_AsLong(ctx, arg);
    return HPyLong_FromLong(ctx, value + 1);
}

HPyDef_METH(str_length, "str_length", HPyFunc_O)
static HPy str_length_impl(HPyContext *ctx, HPy self, HPy arg)
{
    HPy_ssize_t len = HPy_Length(ctx, arg);
    return HPyLong_FromLong(ctx, (long)len);
}

HPyDef_METH(negate, "negate", HPyFunc_O)
static HPy negate_impl(HPyContext *ctx, HPy self, HPy arg)
{
    return HPy_Negative(ctx, arg);
}

HPyDef_METH(raise_value_error, "raise_value_error", HPyFunc_O)
static HPy raise_value_error_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)arg;
    return HPyErr_SetString(ctx, ctx->h_ValueError, "noxtest: kasıtlı hata");
}

HPyDef_METH(list_sum, "list_sum", HPyFunc_O)
static HPy list_sum_impl(HPyContext *ctx, HPy self, HPy arg)
{
    HPy_ssize_t len = HPy_Length(ctx, arg);
    long total = 0;
    for (HPy_ssize_t i = 0; i < len; i++) {
        HPy item = HPy_GetItem_i(ctx, arg, i);
        total += HPyLong_AsLong(ctx, item);
        HPy_Close(ctx, item);
    }
    return HPyLong_FromLong(ctx, total);
}

HPyDef_METH(make_pair, "make_pair", HPyFunc_O)
static HPy make_pair_impl(HPyContext *ctx, HPy self, HPy arg)
{
    HPy items[2] = { arg, arg };
    return HPyTuple_FromArray(ctx, items, 2);
}

HPyDef_METH(dict_get_x, "dict_get_x", HPyFunc_O)
static HPy dict_get_x_impl(HPyContext *ctx, HPy self, HPy arg)
{
    return HPy_GetItem_s(ctx, arg, "x");
}

/* `Counter_type`in AYNI tembel/statik önbellekleme deseni. Modül
 * metodları yalnızca `HPy` döndürebildiğinden, tip TUTAMACINI Zig test
 * tarafına geçirmenin tek yolu budur (bkz. Widget_* yukarıda). */
static HPy Widget_type = { 0 };

HPyDef_METH(get_widget_type, "get_widget_type", HPyFunc_O)
static HPy get_widget_type_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    if (Widget_type._i == 0) {
        Widget_type = HPyType_FromSpec(ctx, &Widget_spec, NULL);
    }
    return Widget_type;
}

/* Attribute erişimi (ctx_GetAttr ailesi) test amaçlı: eklentinin KENDİ
 * C kodunun `HPy_GetAttr_s`'i ÇAĞIRMASI (`dict_get_x`in `HPy_GetItem_s`
 * KULLANMASIYLA AYNI desen) — Nox'un `instance_dict`ine (Zig testinin
 * `HPy_SetAttr_s` ile EKLEDİĞİ, eklentinin C struct'ında HİÇ VAR
 * OLMAYAN) bir attribute'un, GERÇEK bir HPy çağrısı üzerinden C KODUNA
 * da GÖRÜNÜR olduğunu doğrular. */
HPyDef_METH(get_attr_via_c, "get_attr_via_c", HPyFunc_O)
static HPy get_attr_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    return HPy_GetAttr_s(ctx, arg, "label");
}

/* ctx_CallMethod (Faz OO) test amaçlı: eklentinin KENDİ C kodunun
 * GERÇEK `HPy_CallMethod` makrosunu (ham `ctx_CallMethod` ABI yuvasına
 * TRAMPOLİNE eden) ÇAĞIRMASI — `get_attr_via_c`nin `HPy_GetAttr_s`
 * KULLANMASIYLA AYNI desen. `arg`, `(widget, amount)` şeklinde bir
 * tuple'dır — `HPyFunc_O` TEK argüman aldığından, ikinci argümanı
 * (miktar) böyle GEÇİRİYORUZ. Gerçek HPy sözleşmesi: `args[0]` ALICI
 * (receiver/self), `args[1..nargs)` GERÇEK metod argümanlarıdır. */
HPyDef_METH(call_add_value_via_c, "call_add_value_via_c", HPyFunc_O)
static HPy call_add_value_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy widget = HPy_GetItem_i(ctx, arg, 0);
    HPy amount = HPy_GetItem_i(ctx, arg, 1);
    HPy name = HPyUnicode_FromString(ctx, "add_value");
    HPy method_args[2] = { widget, amount };
    HPy result = HPy_CallMethod(ctx, name, method_args, 2, HPy_NULL);
    HPy_Close(ctx, name);
    HPy_Close(ctx, widget);
    HPy_Close(ctx, amount);
    return result;
}

static HPyDef *module_defines[] = {
    &long_conv_roundtrip,
    &long_as_double_via_c,
    &long_as_voidptr_roundtrip,
    &add_one,
    &str_length,
    &negate,
    &raise_value_error,
    &list_sum,
    &make_pair,
    &dict_get_x,
    &make_counter,
    &get_counter_x,
    &get_destroy_count,
    &get_widget_type,
    &get_attr_via_c,
    &call_add_value_via_c,
    NULL
};

static HPyModuleDef moduledef = {
    .doc = "Nox HPy Tier 0 uyumluluk testi",
    .size = 0,
    .legacy_methods = NULL,
    .defines = module_defines,
};

HPy_MODINIT(noxtest, moduledef)
