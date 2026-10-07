/*
 * Nox Native Interface (NNI) v1 — the stable boundary between Nox programs and native extensions
 * (C, C++, Rust, Zig, ...). See docs/NATIVE-API.md.
 *
 * Design rules
 *  - Everything crosses the boundary through opaque handles and plain C types. A native extension NEVER sees
 *    Nox's ARC header, RuntimeState, string/list/class layouts or generated symbol names; those may change
 *    in any release without breaking this ABI.
 *  - The API is a versioned function table. A plugin checks `abi_version` and `struct_size` before using a
 *    member; new members are only ever appended to the end of the table.
 *  - Native functions run synchronously on the thread that called them from Nox. Native threads never touch
 *    the Nox object graph: they hand work back with `post_event`, which Nox code drains on its own scheduler.
 */
#ifndef NOX_NNI_H
#define NOX_NNI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NOX_NNI_ABI_VERSION 1u

#if defined(_WIN32)
#define NOX_EXPORT __declspec(dllexport)
#else
#define NOX_EXPORT __attribute__((visibility("default")))
#endif

/* 0 is never a valid handle. A handle is a generation-counted index: using a released handle is detected. */
typedef uint64_t NoxHandle;

/* Opaque per-plugin runtime context. Pass it back to every API call. */
typedef struct NoxRuntime NoxRuntime;

typedef int32_t NoxStatus;
enum {
    NOX_OK = 0,
    NOX_ERROR = 1,           /* recoverable error: becomes a Nox exception (message from error_set) */
    NOX_PANIC = 2,           /* unrecoverable plugin failure: terminates the call with an error */
    NOX_ABI_UNSUPPORTED = 3, /* returned by plugin init when the host ABI is too old */
    NOX_BAD_HANDLE = 4,
    NOX_OUT_OF_MEMORY = 5,
    NOX_NOT_FOUND = 6
};

enum {
    NOX_V_NONE = 0,
    NOX_V_INT = 1,
    NOX_V_FLOAT = 2,
    NOX_V_BOOL = 3,
    NOX_V_STRING = 4, /* u.h: handle to a UTF-8 string */
    NOX_V_BYTES = 5   /* u.h: handle to a byte buffer */
};

typedef struct NoxValue {
    int32_t kind; /* NOX_V_* */
    int32_t reserved;
    union {
        int64_t i; /* NOX_V_INT; NOX_V_BOOL (0/1) */
        double f;  /* NOX_V_FLOAT */
        NoxHandle h;
    } u;
} NoxValue;

typedef struct NoxApiV1 NoxApiV1;

/* A native function callable from Nox. `args` is valid only for the duration of the call; string/bytes handles in
 * `args` are owned by the host. Handles stored in `*out` transfer ownership to the host. */
typedef NoxStatus (*NoxNativeFn)(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out);

struct NoxApiV1 {
    uint32_t abi_version; /* NOX_NNI_ABI_VERSION the host implements */
    uint32_t struct_size; /* sizeof(NoxApiV1) of the host; members past this size must not be read */

    void (*retain)(NoxRuntime* rt, NoxHandle h);
    void (*release)(NoxRuntime* rt, NoxHandle h);

    /* UTF-8 strings (validated; returns 0 on invalid UTF-8 or out of memory). Views are valid while the handle lives. */
    NoxHandle (*string_new)(NoxRuntime* rt, const uint8_t* data, size_t len);
    NoxStatus (*string_view)(NoxRuntime* rt, NoxHandle h, const uint8_t** data, size_t* len);

    /* Raw byte buffers. */
    NoxHandle (*bytes_new)(NoxRuntime* rt, const uint8_t* data, size_t len);
    NoxStatus (*bytes_view)(NoxRuntime* rt, NoxHandle h, const uint8_t** data, size_t* len);

    /* Host allocator (the same one Nox uses for the plugin's context). */
    void* (*alloc)(NoxRuntime* rt, size_t size, size_t alignment);
    void (*free)(NoxRuntime* rt, void* p, size_t size, size_t alignment);

    /* Records an error message for the current call and returns NOX_ERROR (use: `return api->error_set(...)`). */
    NoxStatus (*error_set)(NoxRuntime* rt, int32_t code, const uint8_t* msg, size_t len);

    /* Only valid during `nox_plugin_init_v1`. */
    NoxStatus (*register_function)(NoxRuntime* rt, const char* name, NoxNativeFn fn);

    /* Thread-safe: callable from ANY thread. String/bytes payloads are copied. Nox drains events with
     * `nox.native.poll_event()` on its own scheduler. `kind` must be >= 0. */
    NoxStatus (*post_event)(NoxRuntime* rt, int64_t kind, const NoxValue* payload);
};

/* Every plugin exports this symbol. Return NOX_ABI_UNSUPPORTED if `api->abi_version` is too old. */
NOX_EXPORT NoxStatus nox_plugin_init_v1(const NoxApiV1* api, NoxRuntime* rt);

#ifdef __cplusplus
}
#endif

#endif /* NOX_NNI_H */
