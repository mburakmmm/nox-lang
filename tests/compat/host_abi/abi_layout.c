/* UR-014: Host ABI (nox_host.h, v3-rc) düzen kapısı. Donmuş yapı boyutları/alan ofsetleri, sabitler ve durum/tür/yetenek kodları burada SABİTLENİR:
 * bu dosya derlenmiyorsa ABI uyumsuz değişmiştir. Değişiklik yalnızca EKLEME olabilir (yeni sabit/işlev/yapı sonuna alan DEĞİL: mevcut yapıların boyutu değişmez).
 * Derleme: clang -std=c11 -fsyntax-only -I include tests/compat/host_abi/abi_layout.c   (64-bit LP64/LLP64 hedefler; 32-bit hedefler denetlenmez) */
#include "nox_host.h"
#include <stddef.h>
#include <stdint.h>

#if UINTPTR_MAX == 0xffffffffffffffffu

_Static_assert(NOX_HOST_ABI_VERSION == 3u, "ABI version");

_Static_assert(sizeof(NoxHostStatus) == 4, "NoxHostStatus");
_Static_assert(sizeof(NoxHostHandle) == 8 && sizeof(NoxHostValue) == 8 && sizeof(NoxHostExternalRef) == 8 && sizeof(NoxHostTask) == 8, "opaque 64-bit tokens");

_Static_assert(sizeof(NoxHostContextConfig) == 16, "NoxHostContextConfig");
_Static_assert(offsetof(NoxHostContextConfig, size) == 0 && offsetof(NoxHostContextConfig, abi_version) == 4 && offsetof(NoxHostContextConfig, allocator) == 8, "NoxHostContextConfig fields");

_Static_assert(sizeof(NoxHostSpan) == 16 && offsetof(NoxHostSpan, data) == 0 && offsetof(NoxHostSpan, len) == 8, "NoxHostSpan");
_Static_assert(sizeof(NoxHostBuffer) == 16 && offsetof(NoxHostBuffer, data) == 0 && offsetof(NoxHostBuffer, len) == 8, "NoxHostBuffer");

_Static_assert(sizeof(NoxHostAllocator) == 32 && offsetof(NoxHostAllocator, size) == 0 && offsetof(NoxHostAllocator, ctx) == 8 &&
               offsetof(NoxHostAllocator, alloc) == 16 && offsetof(NoxHostAllocator, free) == 24, "NoxHostAllocator");

_Static_assert(sizeof(NoxHostCallbackOps) == 40 && offsetof(NoxHostCallbackOps, struct_size) == 0 && offsetof(NoxHostCallbackOps, user_data) == 8 &&
               offsetof(NoxHostCallbackOps, invoke) == 16 && offsetof(NoxHostCallbackOps, retain) == 24 && offsetof(NoxHostCallbackOps, release) == 32, "NoxHostCallbackOps");

_Static_assert(sizeof(NoxHostBufferView) == 176 && offsetof(NoxHostBufferView, struct_size) == 0 && offsetof(NoxHostBufferView, dtype) == 4 &&
               offsetof(NoxHostBufferView, data) == 8 && offsetof(NoxHostBufferView, byte_len) == 16 && offsetof(NoxHostBufferView, itemsize) == 24 &&
               offsetof(NoxHostBufferView, ndim) == 32 && offsetof(NoxHostBufferView, flags) == 36 && offsetof(NoxHostBufferView, shape) == 40 &&
               offsetof(NoxHostBufferView, strides) == 104 && offsetof(NoxHostBufferView, pin_id) == 168, "NoxHostBufferView");

#endif

/* durum kodları 0..11 (donmuş, yalnızca sona eklenir) */
_Static_assert(NOX_HOST_OK == 0 && NOX_HOST_ERR_EXCEPTION == 1 && NOX_HOST_ERR_NOMEM == 2 && NOX_HOST_ERR_INVAL == 3 && NOX_HOST_ERR_VERSION == 4 && NOX_HOST_ERR_UTF8 == 5 &&
               NOX_HOST_ERR_STATE == 6 && NOX_HOST_ERR_INVALID_HANDLE == 7 && NOX_HOST_ERR_HOST_EXCEPTION == 8 && NOX_HOST_ERR_CANCELLED == 9 && NOX_HOST_ERR_BUSY == 10 &&
               NOX_HOST_ERR_OVERFLOW == 11, "status codes");

/* değer türleri */
_Static_assert(NOX_HOST_VALUE_NONE == 0 && NOX_HOST_VALUE_INT == 1 && NOX_HOST_VALUE_FLOAT == 2 && NOX_HOST_VALUE_BOOL == 3 && NOX_HOST_VALUE_STR == 4 && NOX_HOST_VALUE_BYTES == 5 &&
               NOX_HOST_VALUE_LIST == 6 && NOX_HOST_VALUE_DICT == 7 && NOX_HOST_VALUE_TUPLE == 8 && NOX_HOST_VALUE_HANDLE == 9 && NOX_HOST_VALUE_TYPED_ARRAY == 10 &&
               NOX_HOST_VALUE_EXTERNAL_REF == 11, "value kinds");

/* dtype'lar ve arabellek bayrakları */
_Static_assert(NOX_HOST_DTYPE_U8 == 1 && NOX_HOST_DTYPE_I8 == 2 && NOX_HOST_DTYPE_U16 == 3 && NOX_HOST_DTYPE_I16 == 4 && NOX_HOST_DTYPE_U32 == 5 && NOX_HOST_DTYPE_I32 == 6 &&
               NOX_HOST_DTYPE_U64 == 7 && NOX_HOST_DTYPE_I64 == 8 && NOX_HOST_DTYPE_F32 == 9 && NOX_HOST_DTYPE_F64 == 10 && NOX_HOST_DTYPE_BOOL == 11, "dtypes");
_Static_assert(NOX_HOST_BUF_READONLY == 0u && NOX_HOST_BUF_WRITABLE == 1u && NOX_HOST_BUF_CONTIGUOUS_C == 2u, "buffer flags");

/* yetenek bitleri */
_Static_assert(NOX_HOST_CAP_VALUE_TREE == (1ULL << 0) && NOX_HOST_CAP_CLASSES == (1ULL << 1) && NOX_HOST_CAP_CALLBACKS == (1ULL << 2) && NOX_HOST_CAP_ASYNC_TASKS == (1ULL << 3) &&
               NOX_HOST_CAP_PINNED_BUFFERS == (1ULL << 4) && NOX_HOST_CAP_TYPED_ARRAYS == (1ULL << 5) && NOX_HOST_CAP_CUSTOM_ALLOCATOR == (1ULL << 6) &&
               NOX_HOST_CAP_SUBINTERPRETERS == (1ULL << 7) && NOX_HOST_CAP_RECOVERABLE_TRAPS == (1ULL << 8), "capability bits");

/* işlev imzaları (işaretçi türü eşlemesi: imza değişirse derleme hatası) */
static void signatures(void) {
    uint32_t (*p0)(void) = nox_host_abi_version; (void)p0;
    NoxHostStatus (*p1)(const NoxHostContextConfig *, NoxHostContext **) = nox_host_context_create; (void)p1;
    void (*p2)(NoxHostContext *) = nox_host_context_destroy; (void)p2;
    NoxHostStatus (*p3)(NoxHostContext *, NoxHostHandle) = nox_host_handle_release; (void)p3;
    NoxHostStatus (*p4)(NoxHostContext *, NoxHostHandle, NoxHostSpan *) = nox_host_handle_type_name; (void)p4;
    NoxHostStatus (*p5)(NoxHostContext *, const NoxHostCallbackOps *) = nox_host_context_set_callbacks; (void)p5;
    uint64_t (*p6)(const NoxHostError *) = nox_host_error_host_token; (void)p6;
    NoxHostStatus (*p7)(NoxHostContext *, NoxHostTask) = nox_host_task_cancel; (void)p7;
    NoxHostStatus (*p8)(NoxHostContext *, NoxHostTask, NoxHostValue *, NoxHostError **) = nox_host_task_take_result; (void)p8;
    NoxHostStatus (*p9)(NoxHostContext *, NoxHostHandle, uint32_t, NoxHostBufferView *, NoxHostError **) = nox_host_handle_pin_buffer; (void)p9;
    NoxHostStatus (*p10)(NoxHostContext *, uint64_t) = nox_host_buffer_unpin; (void)p10;
    NoxHostStatus (*p11)(NoxHostContext *, int32_t, const void *, size_t, NoxHostValue *) = nox_host_value_typed_array; (void)p11;
    NoxHostStatus (*p12)(NoxHostContext *, NoxHostValue, int32_t *, const void **, size_t *) = nox_host_value_get_typed_array; (void)p12;
    uint64_t (*p13)(void) = nox_host_capabilities; (void)p13;
}

int main(void) {
    signatures();
    return 0;
}
