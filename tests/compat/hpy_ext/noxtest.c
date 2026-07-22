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
#include <stdio.h>
#include <string.h>

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

/* Temel nesne protokolü (Faz SS) test amaçlı: Widget'ın KENDİ özel
 * `HPy_tp_repr`/`HPy_tp_hash` slotları — `ctx_Repr`/`ctx_Hash`in bir
 * `.instance_` üzerinde jenerik varsayılana DÜŞMEK yerine bu KAYITLI
 * slotu ÖNCELİKLE ÇAĞIRDIĞINI kanıtlar (bkz. `type_tp_repr`/`type_tp_
 * hash`in Zig tarafındaki belge notu). */
HPyDef_SLOT(Widget_repr, HPy_tp_repr)
static HPy Widget_repr_impl(HPyContext *ctx, HPy self)
{
    WidgetObject *data = (WidgetObject *)_HPy_AsStruct_Object(ctx, self);
    char buf[64];
    snprintf(buf, sizeof(buf), "Widget(value=%ld)", data->value);
    return HPyUnicode_FromString(ctx, buf);
}

HPyDef_SLOT(Widget_hash, HPy_tp_hash)
static HPy_hash_t Widget_hash_impl(HPyContext *ctx, HPy self)
{
    (void)ctx;
    WidgetObject *data = (WidgetObject *)_HPy_AsStruct_Object(ctx, self);
    return (HPy_hash_t)data->value;
}

static HPyDef *Widget_defines[] = {
    &Widget_new,
    &Widget_init,
    &Widget_call,
    &Widget_add_value,
    &Widget_repr,
    &Widget_hash,
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

/* Sayı protokolünün geri kalanı (Faz QQ) test amaçlı: eklentinin KENDİ
 * C kodunun HPyNumber_Check/HPy_Divmod/HPy_Power/HPy_Positive/
 * HPy_Invert/HPy_Lshift/HPy_Rshift/HPy_And/HPy_Xor/HPy_Or/HPy_Index/
 * HPy_InPlaceAdd makrolarını (HEPSİ ham `ctx_*` yuvalarına TRAMPOLİNE
 * eden) ÇAĞIRMASI. `arg`, `(a, b)` şeklinde bir tuple'dır. */
HPyDef_METH(number_ops_via_c, "number_ops_via_c", HPyFunc_O)
static HPy number_ops_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy a = HPy_GetItem_i(ctx, arg, 0);
    HPy b = HPy_GetItem_i(ctx, arg, 1);

    HPy results[12];
    results[0] = HPyBool_FromBool(ctx, (bool)HPyNumber_Check(ctx, a));
    results[1] = HPy_Divmod(ctx, a, b);
    results[2] = HPy_Power(ctx, a, b, HPy_NULL);
    results[3] = HPy_Positive(ctx, a);
    results[4] = HPy_Invert(ctx, a);
    results[5] = HPy_Lshift(ctx, a, b);
    results[6] = HPy_Rshift(ctx, a, b);
    results[7] = HPy_And(ctx, a, b);
    results[8] = HPy_Xor(ctx, a, b);
    results[9] = HPy_Or(ctx, a, b);
    results[10] = HPy_Index(ctx, a);
    results[11] = HPy_InPlaceAdd(ctx, a, b);

    HPy result_tuple = HPyTuple_FromArray(ctx, results, 12);
    for (int i = 0; i < 12; i++) {
        HPy_Close(ctx, results[i]);
    }
    HPy_Close(ctx, a);
    HPy_Close(ctx, b);
    return result_tuple;
}

HPyDef_METH(matmul_via_c, "matmul_via_c", HPyFunc_O)
static HPy matmul_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy a = HPy_GetItem_i(ctx, arg, 0);
    HPy b = HPy_GetItem_i(ctx, arg, 1);
    HPy result = HPy_MatrixMultiply(ctx, a, b);
    HPy_Close(ctx, a);
    HPy_Close(ctx, b);
    return result;
}

HPyDef_METH(pow_mod_via_c, "pow_mod_via_c", HPyFunc_O)
static HPy pow_mod_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy a = HPy_GetItem_i(ctx, arg, 0);
    HPy b = HPy_GetItem_i(ctx, arg, 1);
    HPy m = HPy_GetItem_i(ctx, arg, 2);
    HPy result = HPy_Power(ctx, a, b, m);
    HPy_Close(ctx, a);
    HPy_Close(ctx, b);
    HPy_Close(ctx, m);
    return result;
}

HPyDef_METH(long_float_via_c, "long_float_via_c", HPyFunc_O)
static HPy long_float_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy as_long = HPy_Long(ctx, arg);
    HPy as_float = HPy_Float(ctx, arg);
    HPy items[2] = { as_long, as_float };
    HPy result = HPyTuple_FromArray(ctx, items, 2);
    HPy_Close(ctx, as_long);
    HPy_Close(ctx, as_float);
    return result;
}

/* Hata yönetiminin geri kalanı (Faz RR) test amaçlı: eklentinin KENDİ
 * C kodunun HPyErr_SetObject/HPyErr_SetFromErrnoWithFilename/
 * HPyErr_SetFromErrnoWithFilenameObjects/HPyErr_NewException/
 * HPyErr_NewExceptionWithDoc/HPyErr_WarnEx/HPyErr_WriteUnraisable
 * makrolarını (HEPSİ ham `ctx_Err_*` yuvalarına TRAMPOLİNE eden)
 * ÇAĞIRMASI. `ctx_FatalError` HARİÇ (o SÜREÇ SONLANDIRIR, TEST
 * SÜİTİNDEN GÜVENLE çağrılamaz — bkz. `ctxFatalError`in Zig tarafındaki
 * belge notu). */
HPyDef_METH(err_set_object_via_c, "err_set_object_via_c", HPyFunc_O)
static HPy err_set_object_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    return HPyErr_SetObject(ctx, ctx->h_ValueError, arg);
}

HPyDef_METH(err_from_errno_via_c, "err_from_errno_via_c", HPyFunc_O)
static HPy err_from_errno_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    const char *filename = HPyUnicode_AsUTF8AndSize(ctx, arg, NULL);
    return HPyErr_SetFromErrnoWithFilename(ctx, ctx->h_OSError, filename);
}

HPyDef_METH(err_from_errno_objects_via_c, "err_from_errno_objects_via_c", HPyFunc_O)
static HPy err_from_errno_objects_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy f1 = HPy_GetItem_i(ctx, arg, 0);
    HPy f2 = HPy_GetItem_i(ctx, arg, 1);
    HPyErr_SetFromErrnoWithFilenameObjects(ctx, ctx->h_OSError, f1, f2);
    HPy_Close(ctx, f1);
    HPy_Close(ctx, f2);
    return HPy_NULL;
}

HPyDef_METH(new_exception_via_c, "new_exception_via_c", HPyFunc_O)
static HPy new_exception_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    HPy custom_exc = HPyErr_NewException(ctx, "noxtest.CustomError", HPy_NULL, HPy_NULL);
    HPyErr_SetString(ctx, custom_exc, "kasıtlı özel istisna");
    HPy_Close(ctx, custom_exc);
    return HPy_NULL;
}

HPyDef_METH(warn_via_c, "warn_via_c", HPyFunc_O)
static HPy warn_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    int rc = HPyErr_WarnEx(ctx, ctx->h_RuntimeWarning, "noxtest: kasıtlı uyarı", 1);
    return HPyLong_FromLong(ctx, rc);
}

HPyDef_METH(write_unraisable_via_c, "write_unraisable_via_c", HPyFunc_O)
static HPy write_unraisable_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    HPyErr_SetString(ctx, ctx->h_ValueError, "yok sayılacak istisna");
    HPyErr_WriteUnraisable(ctx, arg);
    return HPyBool_FromBool(ctx, (bool)HPyErr_Occurred(ctx));
}

/* Temel nesne protokolü (Faz SS) + Bytes tipi (Faz TT) test amaçlı:
 * eklentinin KENDİ C kodunun HPy_Repr/HPy_Str/HPy_ASCII/HPy_Bytes/
 * HPy_RichCompare/HPy_Hash/HPyType_GenericNew/HPyBytes_* makrolarını
 * (HEPSİ ham `ctx_*` yuvalarına TRAMPOLİNE eden) ÇAĞIRMASI. */
HPyDef_METH(repr_via_c, "repr_via_c", HPyFunc_O)
static HPy repr_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    return HPy_Repr(ctx, arg);
}

HPyDef_METH(str_via_c, "str_via_c", HPyFunc_O)
static HPy str_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    return HPy_Str(ctx, arg);
}

HPyDef_METH(ascii_via_c, "ascii_via_c", HPyFunc_O)
static HPy ascii_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    return HPy_ASCII(ctx, arg);
}

HPyDef_METH(bytes_via_c, "bytes_via_c", HPyFunc_O)
static HPy bytes_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    return HPy_Bytes(ctx, arg);
}

HPyDef_METH(hash_via_c, "hash_via_c", HPyFunc_O)
static HPy hash_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy_hash_t h = HPy_Hash(ctx, arg);
    if (h == -1 && HPyErr_Occurred(ctx)) {
        return HPy_NULL;
    }
    return HPyLong_FromLongLong(ctx, (long long)h);
}

HPyDef_METH(richcompare_via_c, "richcompare_via_c", HPyFunc_O)
static HPy richcompare_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy v = HPy_GetItem_i(ctx, arg, 0);
    HPy w = HPy_GetItem_i(ctx, arg, 1);
    HPy op_h = HPy_GetItem_i(ctx, arg, 2);
    long op = HPyLong_AsLong(ctx, op_h);
    HPy result = HPy_RichCompare(ctx, v, w, (int)op);
    HPy_Close(ctx, v);
    HPy_Close(ctx, w);
    HPy_Close(ctx, op_h);
    return result;
}

HPyDef_METH(richcomparebool_via_c, "richcomparebool_via_c", HPyFunc_O)
static HPy richcomparebool_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy v = HPy_GetItem_i(ctx, arg, 0);
    HPy w = HPy_GetItem_i(ctx, arg, 1);
    HPy op_h = HPy_GetItem_i(ctx, arg, 2);
    long op = HPyLong_AsLong(ctx, op_h);
    int result = HPy_RichCompareBool(ctx, v, w, (int)op);
    HPy_Close(ctx, v);
    HPy_Close(ctx, w);
    HPy_Close(ctx, op_h);
    if (result < 0) {
        return HPy_NULL;
    }
    return HPyBool_FromBool(ctx, (bool)result);
}

HPyDef_METH(generic_new_via_c, "generic_new_via_c", HPyFunc_O)
static HPy generic_new_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    /* `arg` (Counter tipi) İçin `tp_new` YOK — `HPyType_GenericNew`in
     * `object.__new__`in VARSAYILANI GİBİ, TİPİN KENDİ `tp_new`ından
     * BAĞIMSIZ, DOĞRUDAN sıfırlanmış bir örnek İNŞA edebildiğini kanıtlar. */
    return HPyType_GenericNew(ctx, arg, NULL, 0, HPy_NULL);
}

HPyDef_METH(bytes_roundtrip_via_c, "bytes_roundtrip_via_c", HPyFunc_O)
static HPy bytes_roundtrip_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    /* İçinde GÖMÜLÜ bir `\0` OLAN 5 baytlık bir bytes nesnesi — gerçek
     * Python `bytes`in `str`ten TEMEL farkı budur. */
    static const char raw[5] = { 'a', 'b', '\0', 'c', 'd' };
    HPy b = HPyBytes_FromStringAndSize(ctx, raw, 5);
    HPy_ssize_t size = HPyBytes_Size(ctx, b);
    HPy_ssize_t size2 = HPyBytes_GET_SIZE(ctx, b);
    const char *s1 = HPyBytes_AsString(ctx, b);
    const char *s2 = HPyBytes_AS_STRING(ctx, b);
    int is_bytes = HPyBytes_Check(ctx, b);
    int matches = (size == 5) && (size2 == 5) && (s1 == s2) &&
                  memcmp(s1, raw, 5) == 0 && is_bytes;
    HPy_Close(ctx, b);
    return HPyBool_FromBool(ctx, (bool)matches);
}

/* Unicode ailesinin geri kalanı (Faz UU) test amaçlı: eklentinin KENDİ
 * C kodunun HPyUnicode_AsASCIIString/AsLatin1String/AsUTF8String/
 * FromWideChar/DecodeFSDefault(AndSize)/EncodeFSDefault/ReadChar/
 * DecodeASCII/DecodeLatin1/FromEncodedObject/Substring makrolarını
 * (HEPSİ ham `ctx_Unicode_*` yuvalarına TRAMPOLİNE eden) ÇAĞIRMASI. */
HPyDef_METH(unicode_as_utf8_bytes_via_c, "unicode_as_utf8_bytes_via_c", HPyFunc_O)
static HPy unicode_as_utf8_bytes_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    return HPyUnicode_AsUTF8String(ctx, arg);
}

HPyDef_METH(unicode_as_ascii_bytes_via_c, "unicode_as_ascii_bytes_via_c", HPyFunc_O)
static HPy unicode_as_ascii_bytes_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    return HPyUnicode_AsASCIIString(ctx, arg);
}

HPyDef_METH(unicode_as_latin1_bytes_via_c, "unicode_as_latin1_bytes_via_c", HPyFunc_O)
static HPy unicode_as_latin1_bytes_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    return HPyUnicode_AsLatin1String(ctx, arg);
}

HPyDef_METH(unicode_from_wide_char_via_c, "unicode_from_wide_char_via_c", HPyFunc_O)
static HPy unicode_from_wide_char_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    static const wchar_t wide[] = { L'h', L'i', L'!' };
    return HPyUnicode_FromWideChar(ctx, wide, 3);
}

HPyDef_METH(unicode_fsdefault_via_c, "unicode_fsdefault_via_c", HPyFunc_O)
static HPy unicode_fsdefault_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    HPy s1 = HPyUnicode_DecodeFSDefault(ctx, "dosya.txt");
    HPy s2 = HPyUnicode_DecodeFSDefaultAndSize(ctx, "dosya.txt", 5); /* yalnızca "dosya" */
    HPy b = HPyUnicode_EncodeFSDefault(ctx, s1);
    HPy items[3] = { s1, s2, b };
    HPy result = HPyTuple_FromArray(ctx, items, 3);
    HPy_Close(ctx, s1);
    HPy_Close(ctx, s2);
    HPy_Close(ctx, b);
    return result;
}

HPyDef_METH(unicode_read_char_via_c, "unicode_read_char_via_c", HPyFunc_O)
static HPy unicode_read_char_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    HPy s = HPy_GetItem_i(ctx, arg, 0);
    HPy idx_h = HPy_GetItem_i(ctx, arg, 1);
    long idx = HPyLong_AsLong(ctx, idx_h);
    HPy_UCS4 c = HPyUnicode_ReadChar(ctx, s, idx);
    HPy_Close(ctx, s);
    HPy_Close(ctx, idx_h);
    (void)self;
    if (c == (HPy_UCS4)-1 && HPyErr_Occurred(ctx)) {
        return HPy_NULL;
    }
    return HPyLong_FromUnsignedLong(ctx, (unsigned long)c);
}

HPyDef_METH(unicode_decode_ascii_via_c, "unicode_decode_ascii_via_c", HPyFunc_O)
static HPy unicode_decode_ascii_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    return HPyUnicode_DecodeASCII(ctx, "hello", 5, "strict");
}

HPyDef_METH(unicode_decode_latin1_via_c, "unicode_decode_latin1_via_c", HPyFunc_O)
static HPy unicode_decode_latin1_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    static const char latin1[2] = { 'a', (char)0xe9 }; /* 'a', 'é' (Latin-1: U+00E9) */
    return HPyUnicode_DecodeLatin1(ctx, latin1, 2, "strict");
}

HPyDef_METH(unicode_from_encoded_object_via_c, "unicode_from_encoded_object_via_c", HPyFunc_O)
static HPy unicode_from_encoded_object_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    return HPyUnicode_FromEncodedObject(ctx, arg, "utf-8", NULL);
}

HPyDef_METH(unicode_substring_via_c, "unicode_substring_via_c", HPyFunc_O)
static HPy unicode_substring_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    HPy s = HPy_GetItem_i(ctx, arg, 0);
    HPy start_h = HPy_GetItem_i(ctx, arg, 1);
    HPy end_h = HPy_GetItem_i(ctx, arg, 2);
    long start = HPyLong_AsLong(ctx, start_h);
    long end = HPyLong_AsLong(ctx, end_h);
    HPy result = HPyUnicode_Substring(ctx, s, start, end);
    HPy_Close(ctx, s);
    HPy_Close(ctx, start_h);
    HPy_Close(ctx, end_h);
    (void)self;
    return result;
}

/* List/Tuple Builder'ları (Faz VV) test amaçlı: eklentinin KENDİ C
 * kodunun HPyListBuilder ve HPyTupleBuilder makrolarını (HEPSİ ham
 * ctx_ListBuilder_/ctx_TupleBuilder_ yuvalarına TRAMPOLİNE eden)
 * ÇAĞIRMASI — 3 elemanlı bir liste/tuple İNŞA edip (`arg`den okunan)
 * 3 değerle DOLDURUR. */
HPyDef_METH(list_builder_via_c, "list_builder_via_c", HPyFunc_O)
static HPy list_builder_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy a = HPy_GetItem_i(ctx, arg, 0);
    HPy b = HPy_GetItem_i(ctx, arg, 1);
    HPy c = HPy_GetItem_i(ctx, arg, 2);
    HPyListBuilder builder = HPyListBuilder_New(ctx, 3);
    HPyListBuilder_Set(ctx, builder, 0, a);
    HPyListBuilder_Set(ctx, builder, 1, b);
    HPyListBuilder_Set(ctx, builder, 2, c);
    HPy result = HPyListBuilder_Build(ctx, builder);
    HPy_Close(ctx, a);
    HPy_Close(ctx, b);
    HPy_Close(ctx, c);
    return result;
}

HPyDef_METH(list_builder_cancel_via_c, "list_builder_cancel_via_c", HPyFunc_O)
static HPy list_builder_cancel_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    HPyListBuilder builder = HPyListBuilder_New(ctx, 2);
    HPyListBuilder_Cancel(ctx, builder);
    /* İptal EDİLDİKTEN sonra herhangi bir sızıntı/çökme OLMADIĞINI
     * kanıtlamak İçin yalnızca True döner — GERÇEK doğrulama ASAN/valgrind
     * benzeri bir bellek denetleyicisi (bkz. `std.testing.allocator`nin
     * KENDİSİ, sızıntı TESPİT eder) tarafından yapılır. */
    return HPyBool_FromBool(ctx, true);
}

HPyDef_METH(tuple_builder_via_c, "tuple_builder_via_c", HPyFunc_O)
static HPy tuple_builder_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy a = HPy_GetItem_i(ctx, arg, 0);
    HPy b = HPy_GetItem_i(ctx, arg, 1);
    HPy c = HPy_GetItem_i(ctx, arg, 2);
    HPyTupleBuilder builder = HPyTupleBuilder_New(ctx, 3);
    HPyTupleBuilder_Set(ctx, builder, 0, a);
    HPyTupleBuilder_Set(ctx, builder, 1, b);
    HPyTupleBuilder_Set(ctx, builder, 2, c);
    HPy result = HPyTupleBuilder_Build(ctx, builder);
    HPy_Close(ctx, a);
    HPy_Close(ctx, b);
    HPy_Close(ctx, c);
    return result;
}

HPyDef_METH(tuple_builder_cancel_via_c, "tuple_builder_cancel_via_c", HPyFunc_O)
static HPy tuple_builder_cancel_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    HPyTupleBuilder builder = HPyTupleBuilder_New(ctx, 2);
    HPyTupleBuilder_Cancel(ctx, builder);
    return HPyBool_FromBool(ctx, true);
}

/* Tracker + Field/Global (Faz WW) test amaçlı: eklentinin KENDİ C
 * kodunun HPyTracker, HPyField ve HPyGlobal makrolarını (HEPSİ ham
 * ctx_Tracker/ctx_Field/ctx_Global yuvalarına TRAMPOLİNE eden)
 * ÇAĞIRMASI. */
HPyDef_METH(tracker_close_via_c, "tracker_close_via_c", HPyFunc_O)
static HPy tracker_close_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    HPyTracker t = HPyTracker_New(ctx, 2);
    HPy a = HPyLong_FromLong(ctx, 111);
    HPy b = HPyLong_FromLong(ctx, 222);
    HPyTracker_Add(ctx, t, a);
    HPyTracker_Add(ctx, t, b);
    /* Tracker_Close, a VE b'yi KENDİSİ kapatır -- AYRICA HPy_Close
     * çağrılmamalı (gerçek sözleşme: Add YENİ bir referans ALMAZ). */
    HPyTracker_Close(ctx, t);
    return HPyBool_FromBool(ctx, true);
}

HPyDef_METH(tracker_forget_via_c, "tracker_forget_via_c", HPyFunc_O)
static HPy tracker_forget_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    HPyTracker t = HPyTracker_New(ctx, 1);
    HPy a = HPyLong_FromLong(ctx, 111);
    HPyTracker_Add(ctx, t, a);
    HPyTracker_ForgetAll(ctx, t); /* izlemeyi bırak -- a KAPATILMAZ */
    HPyTracker_Close(ctx, t);     /* artık boş bir tracker'ı kapatır -- a ETKİLENMEZ */
    long v = HPyLong_AsLong(ctx, a); /* a HÂLÂ geçerli olmalı */
    HPy_Close(ctx, a); /* KENDİMİZ kapatıyoruz -- tracker ARTIK sahiplenmiyor */
    return HPyLong_FromLong(ctx, v);
}

static HPyField g_test_field = HPyField_NULL;

HPyDef_METH(field_store_via_c, "field_store_via_c", HPyFunc_O)
static HPy field_store_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPyField_Store(ctx, HPy_NULL, &g_test_field, arg);
    return HPyBool_FromBool(ctx, true);
}

HPyDef_METH(field_load_via_c, "field_load_via_c", HPyFunc_O)
static HPy field_load_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    return HPyField_Load(ctx, HPy_NULL, g_test_field);
}

static HPyGlobal g_test_global = { 0 };

HPyDef_METH(global_store_via_c, "global_store_via_c", HPyFunc_O)
static HPy global_store_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPyGlobal_Store(ctx, &g_test_global, arg);
    return HPyBool_FromBool(ctx, true);
}

HPyDef_METH(global_load_via_c, "global_load_via_c", HPyFunc_O)
static HPy global_load_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    (void)arg;
    return HPyGlobal_Load(ctx, g_test_global);
}

/* Tip içgözlemi + çeşitli (Faz XX) test amaçlı: eklentinin KENDİ C
 * kodunun HPyType_GetName/IsSubtype/_HPyType_GetBuiltinShape/_HPy_
 * AsStruct_Type/Long/Float/Unicode/Tuple/List/_HPy_Dump/HPySlice_Unpack
 * makrolarını (HEPSİ ham ctx_* yuvalarına TRAMPOLİNE eden) ÇAĞIRMASI. */
HPyDef_METH(type_name_via_c, "type_name_via_c", HPyFunc_O)
static HPy type_name_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    const char *name = HPyType_GetName(ctx, arg);
    if (name == NULL) {
        return HPy_NULL;
    }
    return HPyUnicode_FromString(ctx, name);
}

HPyDef_METH(type_is_subtype_via_c, "type_is_subtype_via_c", HPyFunc_O)
static HPy type_is_subtype_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy sub = HPy_GetItem_i(ctx, arg, 0);
    HPy type_h = HPy_GetItem_i(ctx, arg, 1);
    int result = HPyType_IsSubtype(ctx, sub, type_h);
    HPy_Close(ctx, sub);
    HPy_Close(ctx, type_h);
    return HPyBool_FromBool(ctx, (bool)result);
}

HPyDef_METH(type_builtin_shape_via_c, "type_builtin_shape_via_c", HPyFunc_O)
static HPy type_builtin_shape_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPyType_BuiltinShape shape = _HPyType_GetBuiltinShape(ctx, arg);
    return HPyLong_FromLong(ctx, (long)shape);
}

HPyDef_METH(as_struct_variants_via_c, "as_struct_variants_via_c", HPyFunc_O)
static HPy as_struct_variants_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy long_h = HPy_GetItem_i(ctx, arg, 0);
    HPy float_h = HPy_GetItem_i(ctx, arg, 1);
    HPy str_h = HPy_GetItem_i(ctx, arg, 2);
    HPy tuple_h = HPy_GetItem_i(ctx, arg, 3);

    long *long_ptr = (long *)_HPy_AsStruct_Long(ctx, long_h);
    double *float_ptr = (double *)_HPy_AsStruct_Float(ctx, float_h);
    const char *str_ptr = (const char *)_HPy_AsStruct_Unicode(ctx, str_h);
    HPy *tuple_ptr = (HPy *)_HPy_AsStruct_Tuple(ctx, tuple_h);

    int ok = (long_ptr != NULL) && (*long_ptr == 42) &&
             (float_ptr != NULL) && (*float_ptr == 3.5) &&
             (str_ptr != NULL) && (strncmp(str_ptr, "hi", 2) == 0) &&
             (tuple_ptr != NULL);
    HPy_Close(ctx, long_h);
    HPy_Close(ctx, float_h);
    HPy_Close(ctx, str_h);
    HPy_Close(ctx, tuple_h);
    return HPyBool_FromBool(ctx, (bool)ok);
}

HPyDef_METH(dump_via_c, "dump_via_c", HPyFunc_O)
static HPy dump_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    _HPy_Dump(ctx, arg);
    return HPyBool_FromBool(ctx, true);
}

HPyDef_METH(slice_unpack_via_c, "slice_unpack_via_c", HPyFunc_O)
static HPy slice_unpack_via_c_impl(HPyContext *ctx, HPy self, HPy arg)
{
    (void)self;
    HPy_ssize_t start, stop, step;
    if (HPySlice_Unpack(ctx, arg, &start, &stop, &step) < 0) {
        return HPy_NULL;
    }
    HPy items[3] = {
        HPyLong_FromSsize_t(ctx, start),
        HPyLong_FromSsize_t(ctx, stop),
        HPyLong_FromSsize_t(ctx, step),
    };
    HPy result = HPyTuple_FromArray(ctx, items, 3);
    HPy_Close(ctx, items[0]);
    HPy_Close(ctx, items[1]);
    HPy_Close(ctx, items[2]);
    return result;
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
    &number_ops_via_c,
    &matmul_via_c,
    &pow_mod_via_c,
    &long_float_via_c,
    &err_set_object_via_c,
    &err_from_errno_via_c,
    &err_from_errno_objects_via_c,
    &new_exception_via_c,
    &warn_via_c,
    &write_unraisable_via_c,
    &repr_via_c,
    &str_via_c,
    &ascii_via_c,
    &bytes_via_c,
    &hash_via_c,
    &richcompare_via_c,
    &richcomparebool_via_c,
    &generic_new_via_c,
    &bytes_roundtrip_via_c,
    &unicode_as_utf8_bytes_via_c,
    &unicode_as_ascii_bytes_via_c,
    &unicode_as_latin1_bytes_via_c,
    &unicode_from_wide_char_via_c,
    &unicode_fsdefault_via_c,
    &unicode_read_char_via_c,
    &unicode_decode_ascii_via_c,
    &unicode_decode_latin1_via_c,
    &unicode_from_encoded_object_via_c,
    &unicode_substring_via_c,
    &list_builder_via_c,
    &list_builder_cancel_via_c,
    &tuple_builder_via_c,
    &tuple_builder_cancel_via_c,
    &tracker_close_via_c,
    &tracker_forget_via_c,
    &field_store_via_c,
    &field_load_via_c,
    &global_store_via_c,
    &global_load_via_c,
    &type_name_via_c,
    &type_is_subtype_via_c,
    &type_builtin_shape_via_c,
    &as_struct_variants_via_c,
    &dump_via_c,
    &slice_unpack_via_c,
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
