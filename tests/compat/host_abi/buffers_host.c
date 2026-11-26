/* UR-012: TYPED_ARRAY değerleri ve zero-copy sabitlenmiş arabellekler. */
#include "nox_host.h"
#include <stdio.h>
#include <string.h>
#include <stddef.h>

NoxHostStatus nox_host_module_init_bf(NoxHostContext *ctx, NoxHostError **err);
void nox_host_module_fini_bf(NoxHostContext *ctx);
NoxHostStatus nox_host_export_bf_make_f64(NoxHostContext *, int64_t, NoxHostHandle *, NoxHostError **);
NoxHostStatus nox_host_export_bf_make_i64(NoxHostContext *, int64_t, NoxHostHandle *, NoxHostError **);
NoxHostStatus nox_host_export_bf_make_i32(NoxHostContext *, int64_t, NoxHostHandle *, NoxHostError **);
NoxHostStatus nox_host_export_bf_make_u8(NoxHostContext *, int64_t, NoxHostHandle *, NoxHostError **);
NoxHostStatus nox_host_export_bf_sum_f64(NoxHostContext *, NoxHostHandle, double *, NoxHostError **);
NoxHostStatus nox_host_export_bf_sum_u8(NoxHostContext *, NoxHostHandle, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_bf_resize_f64(NoxHostContext *, NoxHostHandle, int64_t, NoxHostError **);
NoxHostStatus nox_host_export_bf_is_pinned_f64(NoxHostContext *, NoxHostHandle, uint8_t *, NoxHostError **);
NoxHostStatus nox_host_export_bf_sum_floats(NoxHostContext *, NoxHostValue, double *, NoxHostError **);
NoxHostStatus nox_host_export_bf_sum_ints(NoxHostContext *, NoxHostValue, int64_t *, NoxHostError **);
NoxHostStatus nox_host_export_bf_count_true(NoxHostContext *, NoxHostValue, int64_t *, NoxHostError **);

static int g_fail;
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); g_fail++; } } while (0)

int main(void) {
    NoxHostContextConfig cfg = { sizeof cfg, NOX_HOST_ABI_VERSION, NULL };
    NoxHostContext *c = NULL; NoxHostError *e = NULL;
    CHECK(nox_host_context_create(&cfg, &c) == NOX_HOST_OK);
    CHECK(nox_host_module_init_bf(c, &e) == NOX_HOST_OK);

    /* düzen: C11 görünüm yapısı */
    CHECK(sizeof(NoxHostBufferView) == 176 && offsetof(NoxHostBufferView, shape) == 40 && offsetof(NoxHostBufferView, strides) == 104 && offsetof(NoxHostBufferView, pin_id) == 168);

    /* F64Buffer: okuma sabitlemesi, veri Nox'un belleğidir (kopya değil) */
    NoxHostHandle f = 0;
    CHECK(nox_host_export_bf_make_f64(c, 5, &f, &e) == NOX_HOST_OK);
    NoxHostBufferView v1 = {0}, v2 = {0}, w = {0};
    CHECK(nox_host_handle_pin_buffer(c, f, NOX_HOST_BUF_READONLY, &v1, &e) == NOX_HOST_OK);
    CHECK(v1.dtype == NOX_HOST_DTYPE_F64 && v1.itemsize == 8 && v1.byte_len == 40 && v1.ndim == 1 && v1.shape[0] == 5 && v1.strides[0] == 8);
    CHECK((v1.flags & NOX_HOST_BUF_CONTIGUOUS_C) && !(v1.flags & NOX_HOST_BUF_WRITABLE) && v1.pin_id != 0 && v1.data != NULL);
    { const double *d = v1.data; CHECK(d[0] == 0.0 && d[1] == 1.0 && d[4] == 4.0); }
    CHECK(nox_host_handle_pin_buffer(c, f, NOX_HOST_BUF_READONLY, &v2, &e) == NOX_HOST_OK && v2.data == v1.data && v2.pin_id != v1.pin_id); /* çoklu okuma */
    CHECK(nox_host_handle_pin_buffer(c, f, NOX_HOST_BUF_WRITABLE, &w, &e) == NOX_HOST_ERR_BUSY);                /* okuma varken yazma */

    /* sabitliyken Nox tarafında resize kurtarılabilir RuntimeError */
    { uint8_t p = 0; NoxHostSpan sp;
      CHECK(nox_host_export_bf_is_pinned_f64(c, f, &p, &e) == NOX_HOST_OK && p == 1);
      CHECK(nox_host_export_bf_resize_f64(c, f, 100, &e) == NOX_HOST_ERR_EXCEPTION && e);
      CHECK(nox_host_error_class_name(e, &sp) == NOX_HOST_OK && sp.len == 12 && memcmp(sp.data, "RuntimeError", 12) == 0);
      nox_host_error_release(e); e = NULL; }

    CHECK(nox_host_buffer_unpin(c, v1.pin_id) == NOX_HOST_OK);
    CHECK(nox_host_buffer_unpin(c, v1.pin_id) == NOX_HOST_ERR_INVALID_HANDLE);   /* çift unpin */
    CHECK(nox_host_buffer_unpin(c, v2.pin_id) == NOX_HOST_OK);

    /* özel yazma sabitlemesi: host yazar, Nox okur (sıfır kopya kanıtı) */
    CHECK(nox_host_handle_pin_buffer(c, f, NOX_HOST_BUF_WRITABLE, &w, &e) == NOX_HOST_OK && (w.flags & NOX_HOST_BUF_WRITABLE));
    { double *d = w.data; for (int i = 0; i < 5; i++) d[i] = 10.0 * (i + 1); }
    CHECK(nox_host_handle_pin_buffer(c, f, NOX_HOST_BUF_WRITABLE, &v1, &e) == NOX_HOST_ERR_BUSY);
    CHECK(nox_host_handle_pin_buffer(c, f, NOX_HOST_BUF_READONLY, &v1, &e) == NOX_HOST_ERR_BUSY);
    CHECK(nox_host_buffer_unpin(c, w.pin_id) == NOX_HOST_OK);
    { double s = 0; CHECK(nox_host_export_bf_sum_f64(c, f, &s, &e) == NOX_HOST_OK && s == 150.0); }
    { uint8_t p = 9; CHECK(nox_host_export_bf_is_pinned_f64(c, f, &p, &e) == NOX_HOST_OK && p == 0); }
    CHECK(nox_host_export_bf_resize_f64(c, f, 3, &e) == NOX_HOST_OK); /* sabitleme yokken serbest */

    /* sabitleme nesneyi canlı tutar: handle bırakılsa da veri geçerli; unpin sonrası Nox serbest bırakır */
    { NoxHostBufferView v = {0};
      CHECK(nox_host_handle_pin_buffer(c, f, NOX_HOST_BUF_READONLY, &v, &e) == NOX_HOST_OK && v.byte_len == 24);
      CHECK(nox_host_handle_release(c, f) == NOX_HOST_OK);
      { const double *d = v.data; CHECK(d[0] == 10.0 && d[2] == 30.0); }
      CHECK(nox_host_buffer_unpin(c, v.pin_id) == NOX_HOST_OK); }

    /* diğer dtype'lar */
    { NoxHostHandle h = 0; NoxHostBufferView v = {0};
      CHECK(nox_host_export_bf_make_u8(c, 4, &h, &e) == NOX_HOST_OK && nox_host_handle_pin_buffer(c, h, NOX_HOST_BUF_WRITABLE, &v, &e) == NOX_HOST_OK);
      CHECK(v.dtype == NOX_HOST_DTYPE_U8 && v.itemsize == 1 && v.byte_len == 4);
      { uint8_t *d = v.data; d[0] = 1; d[1] = 2; d[2] = 3; d[3] = 250; }
      CHECK(nox_host_buffer_unpin(c, v.pin_id) == NOX_HOST_OK);
      { int64_t s = 0; CHECK(nox_host_export_bf_sum_u8(c, h, &s, &e) == NOX_HOST_OK && s == 256); }
      nox_host_handle_release(c, h);
      CHECK(nox_host_export_bf_make_i32(c, 3, &h, &e) == NOX_HOST_OK && nox_host_handle_pin_buffer(c, h, NOX_HOST_BUF_READONLY, &v, &e) == NOX_HOST_OK);
      CHECK(v.dtype == NOX_HOST_DTYPE_I32 && v.itemsize == 4 && v.byte_len == 12);
      CHECK(nox_host_buffer_unpin(c, v.pin_id) == NOX_HOST_OK); nox_host_handle_release(c, h);
      CHECK(nox_host_export_bf_make_i64(c, 2, &h, &e) == NOX_HOST_OK && nox_host_handle_pin_buffer(c, h, NOX_HOST_BUF_READONLY, &v, &e) == NOX_HOST_OK);
      CHECK(v.dtype == NOX_HOST_DTYPE_I64 && v.byte_len == 16); /* boş/sıfırlı */
      CHECK(nox_host_buffer_unpin(c, v.pin_id) == NOX_HOST_OK); nox_host_handle_release(c, h); }

    /* desteklenmeyen sınıf / geçersiz tutamaç */
    { NoxHostBufferView v = {0}; CHECK(nox_host_handle_pin_buffer(c, 12345, 0, &v, &e) == NOX_HOST_ERR_INVALID_HANDLE); CHECK(nox_host_buffer_unpin(c, 0) == NOX_HOST_ERR_INVALID_HANDLE); }

    /* TYPED_ARRAY: tek kopya, list[float]/list[int]/list[bool] parametrelerine */
    { double xs[1000]; int64_t is[4] = {1, 2, 3, 4}; int32_t i32s[3] = {-1, 5, 6}; uint8_t bs[5] = {1, 0, 1, 1, 0}; float fs[2] = {1.5f, 2.5f};
      NoxHostValue v = 0; double ds = 0; int64_t n = 0; double expect = 0;
      for (int i = 0; i < 1000; i++) { xs[i] = i * 0.5; expect += xs[i]; }
      CHECK(nox_host_value_typed_array(c, NOX_HOST_DTYPE_F64, xs, 1000, &v) == NOX_HOST_OK);
      { int32_t k = -1; CHECK(nox_host_value_kind(c, v, &k) == NOX_HOST_OK && k == NOX_HOST_VALUE_TYPED_ARRAY); size_t cnt = 0; CHECK(nox_host_value_len(c, v, &cnt) == NOX_HOST_OK && cnt == 1000); }
      xs[0] = 999.0; /* host belleği değiştirilse de değer kopyadır */
      CHECK(nox_host_export_bf_sum_floats(c, v, &ds, &e) == NOX_HOST_OK && ds == expect);
      { int32_t dt = 0; const void *p = NULL; size_t cnt = 0; CHECK(nox_host_value_get_typed_array(c, v, &dt, &p, &cnt) == NOX_HOST_OK && dt == NOX_HOST_DTYPE_F64 && cnt == 1000 && ((const double *)p)[2] == 1.0); }
      nox_host_value_release(c, v);
      CHECK(nox_host_value_typed_array(c, NOX_HOST_DTYPE_F32, fs, 2, &v) == NOX_HOST_OK && nox_host_export_bf_sum_floats(c, v, &ds, &e) == NOX_HOST_OK && ds == 4.0); nox_host_value_release(c, v);
      CHECK(nox_host_value_typed_array(c, NOX_HOST_DTYPE_I64, is, 4, &v) == NOX_HOST_OK && nox_host_export_bf_sum_ints(c, v, &n, &e) == NOX_HOST_OK && n == 10);
      CHECK(nox_host_export_bf_sum_floats(c, v, &ds, &e) == NOX_HOST_OK && ds == 10.0); nox_host_value_release(c, v); /* int dtype → list[float] */
      CHECK(nox_host_value_typed_array(c, NOX_HOST_DTYPE_I32, i32s, 3, &v) == NOX_HOST_OK && nox_host_export_bf_sum_ints(c, v, &n, &e) == NOX_HOST_OK && n == 10); nox_host_value_release(c, v);
      CHECK(nox_host_value_typed_array(c, NOX_HOST_DTYPE_BOOL, bs, 5, &v) == NOX_HOST_OK && nox_host_export_bf_count_true(c, v, &n, &e) == NOX_HOST_OK && n == 3); nox_host_value_release(c, v);
      /* dtype uyuşmazlığı Nox'ta ValueError: float dizisi list[int]'e verilemez */
      CHECK(nox_host_value_typed_array(c, NOX_HOST_DTYPE_F64, xs, 2, &v) == NOX_HOST_OK);
      CHECK(nox_host_export_bf_sum_ints(c, v, &n, &e) == NOX_HOST_ERR_EXCEPTION && e); nox_host_error_release(e); e = NULL; nox_host_value_release(c, v);
      /* geçersiz kullanım */
      CHECK(nox_host_value_typed_array(c, 0, xs, 1, &v) == NOX_HOST_ERR_INVAL);
      CHECK(nox_host_value_typed_array(c, 99, xs, 1, &v) == NOX_HOST_ERR_INVAL);
      CHECK(nox_host_value_typed_array(c, NOX_HOST_DTYPE_U8, NULL, 4, &v) == NOX_HOST_ERR_INVAL);
      CHECK(nox_host_value_typed_array(c, NOX_HOST_DTYPE_U8, NULL, 0, &v) == NOX_HOST_OK); nox_host_value_release(c, v);
      CHECK(nox_host_value_int(c, 1, &v) == NOX_HOST_OK && nox_host_value_get_typed_array(c, v, NULL, NULL, NULL) == NOX_HOST_ERR_INVAL); nox_host_value_release(c, v); }

    /* açık sabitleme ile bağlamı yok etme: nesne bırakılır, sızıntı/çift bırakma yok */
    { NoxHostHandle h = 0; NoxHostBufferView v = {0};
      CHECK(nox_host_export_bf_make_f64(c, 2, &h, &e) == NOX_HOST_OK && nox_host_handle_pin_buffer(c, h, NOX_HOST_BUF_WRITABLE, &v, &e) == NOX_HOST_OK); }

    nox_host_module_fini_bf(c);
    nox_host_context_destroy(c);
    if (g_fail) { printf("%d failure(s)\n", g_fail); return 1; }
    printf("ALL OK\n");
    return 0;
}
