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
 */
#include "hpy.h"

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

static HPyDef *module_defines[] = {
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
    NULL
};

static HPyModuleDef moduledef = {
    .doc = "Nox HPy Tier 0 uyumluluk testi",
    .size = 0,
    .legacy_methods = NULL,
    .defines = module_defines,
};

HPy_MODINIT(noxtest, moduledef)
