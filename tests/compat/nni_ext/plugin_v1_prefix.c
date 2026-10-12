/* NNI v1 öneki. list/dict üyeleri bu dosyada yoktur; host onları sona eklemiş olsa da
 * bu eklenti struct_size yeterliliğini kontrol edip yalnızca donmuş öneği kullanır. */
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define NOX_EXPORT __declspec(dllexport)
#else
#define NOX_EXPORT __attribute__((visibility("default")))
#endif

typedef uint64_t NoxHandle;
typedef struct NoxRuntime NoxRuntime;
typedef int32_t NoxStatus;

enum { NOX_OK = 0, NOX_ABI_UNSUPPORTED = 3 };
enum { NOX_V_INT = 1 };

typedef struct NoxValue {
    int32_t kind;
    int32_t reserved;
    union {
        int64_t i;
        double f;
        NoxHandle h;
    } u;
} NoxValue;

typedef struct NoxApiPrefix NoxApiPrefix;
typedef NoxStatus (*NoxNativeFn)(const NoxApiPrefix* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out);

struct NoxApiPrefix {
    uint32_t abi_version;
    uint32_t struct_size;
    void (*retain)(NoxRuntime* rt, NoxHandle h);
    void (*release)(NoxRuntime* rt, NoxHandle h);
    NoxHandle (*string_new)(NoxRuntime* rt, const uint8_t* data, size_t len);
    NoxStatus (*string_view)(NoxRuntime* rt, NoxHandle h, const uint8_t** data, size_t* len);
    NoxHandle (*bytes_new)(NoxRuntime* rt, const uint8_t* data, size_t len);
    NoxStatus (*bytes_view)(NoxRuntime* rt, NoxHandle h, const uint8_t** data, size_t* len);
    void* (*alloc)(NoxRuntime* rt, size_t size, size_t alignment);
    void (*free)(NoxRuntime* rt, void* p, size_t size, size_t alignment);
    NoxStatus (*error_set)(NoxRuntime* rt, int32_t code, const uint8_t* msg, size_t len);
    NoxStatus (*register_function)(NoxRuntime* rt, const char* name, NoxNativeFn fn);
    NoxStatus (*post_event)(NoxRuntime* rt, int64_t kind, const NoxValue* payload);
};

static NoxStatus fn_twice(const NoxApiPrefix* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out) {
    (void)api;
    (void)rt;
    if (argc < 1) return 1;
    out->kind = NOX_V_INT;
    out->u.i = args[0].u.i * 2;
    return NOX_OK;
}

NOX_EXPORT NoxStatus nox_plugin_init_v1(const NoxApiPrefix* api, NoxRuntime* rt) {
    if (api->abi_version != 1u) return NOX_ABI_UNSUPPORTED;
    if (api->struct_size < sizeof(struct NoxApiPrefix)) return NOX_ABI_UNSUPPORTED;
    return api->register_function(rt, "twice", fn_twice);
}
