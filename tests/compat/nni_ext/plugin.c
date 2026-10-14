/* NNI v1 test eklentisi: tamsayı/ondalık/dize/hata/iş parçacığından olay. */
#include "nox_nni.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const NoxApiV1* g_api;
static NoxRuntime* g_rt;

static NoxStatus fn_add(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out) {
    (void)rt;
    (void)api;
    int64_t sum = 0;
    for (size_t i = 0; i < argc; i++) {
        if (args[i].kind != NOX_V_INT) return NOX_ERROR;
        sum += args[i].u.i;
    }
    out->kind = NOX_V_INT;
    out->u.i = sum;
    return NOX_OK;
}

static NoxStatus fn_scale(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out) {
    (void)api;
    (void)rt;
    if (argc != 2 || args[0].kind != NOX_V_FLOAT || args[1].kind != NOX_V_BOOL) return NOX_ERROR;
    out->kind = NOX_V_FLOAT;
    out->u.f = args[0].u.f * (args[1].u.i ? 2.0 : 0.5);
    return NOX_OK;
}

static NoxStatus fn_greet(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out) {
    if (argc != 1 || args[0].kind != NOX_V_STRING) return NOX_ERROR;
    const uint8_t* p;
    size_t n;
    if (api->string_view(rt, args[0].u.h, &p, &n) != NOX_OK) return NOX_ERROR;
    char buf[256];
    int len = snprintf(buf, sizeof buf, "merhaba, %.*s! (%zu bayt)", (int)n, (const char*)p, n);
    out->kind = NOX_V_STRING;
    out->u.h = api->string_new(rt, (const uint8_t*)buf, (size_t)len);
    return out->u.h ? NOX_OK : NOX_OUT_OF_MEMORY;
}

static NoxStatus fn_fail(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out) {
    (void)args;
    (void)argc;
    (void)out;
    const char* msg = "bilerek basarisiz";
    return api->error_set(rt, 42, (const uint8_t*)msg, strlen(msg));
}

static void* worker(void* arg) {
    int64_t n = (int64_t)(intptr_t)arg;
    for (int64_t i = 0; i < n; i++) {
        NoxValue v;
        v.kind = NOX_V_INT;
        v.reserved = 0;
        v.u.i = i * 10;
        g_api->post_event(g_rt, 7, &v);
    }
    const char* done = "bitti";
    NoxHandle h = g_api->string_new(g_rt, (const uint8_t*)done, strlen(done));
    NoxValue sv;
    sv.kind = NOX_V_STRING;
    sv.reserved = 0;
    sv.u.h = h;
    g_api->post_event(g_rt, 8, &sv);
    g_api->release(g_rt, h);
    return NULL;
}

static NoxStatus fn_start_thread(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out) {
    (void)api;
    (void)rt;
    (void)out;
    if (argc != 1 || args[0].kind != NOX_V_INT) return NOX_ERROR;
    pthread_t t;
    if (pthread_create(&t, NULL, worker, (void*)(intptr_t)args[0].u.i) != 0) return NOX_ERROR;
    pthread_detach(t);
    return NOX_OK;
}

#ifdef NOX_NNI_CONTAINERS
static NoxStatus fn_build_list(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out);
static NoxStatus fn_build_dict(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out);
#endif

NOX_EXPORT NoxStatus nox_plugin_init_v1(const NoxApiV1* api, NoxRuntime* rt) {
    if (api->abi_version < 1 || api->struct_size < sizeof(NoxApiV1)) return NOX_ABI_UNSUPPORTED;
    g_api = api;
    g_rt = rt;
    api->register_function(rt, "add", fn_add);
    api->register_function(rt, "scale", fn_scale);
    api->register_function(rt, "greet", fn_greet);
    api->register_function(rt, "fail", fn_fail);
    api->register_function(rt, "start_thread", fn_start_thread);
#ifdef NOX_NNI_CONTAINERS
    api->register_function(rt, "build_list", fn_build_list);
    api->register_function(rt, "build_dict", fn_build_dict);
#endif
    return NOX_OK;
}

#ifdef NOX_NNI_CONTAINERS
static NoxStatus fn_build_list(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out) {
    (void)args;
    (void)argc;
    NoxHandle h = api->list_new(rt);
    if (!h) return NOX_OUT_OF_MEMORY;
    if (api->list_append_int(rt, h, 10) != NOX_OK) return NOX_ERROR;
    if (api->list_append_int(rt, h, 20) != NOX_OK) return NOX_ERROR;
    if (api->list_append_int(rt, h, 30) != NOX_OK) return NOX_ERROR;
    out->kind = NOX_V_LIST;
    out->u.h = h;
    return NOX_OK;
}

static NoxStatus fn_build_dict(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out) {
    (void)args;
    (void)argc;
    NoxHandle h = api->dict_new(rt);
    if (!h) return NOX_OUT_OF_MEMORY;
    if (api->dict_set_int(rt, h, (const uint8_t*)"a", 1, 1) != NOX_OK) return NOX_ERROR;
    if (api->dict_set_int(rt, h, (const uint8_t*)"b", 1, 2) != NOX_OK) return NOX_ERROR;
    out->kind = NOX_V_DICT;
    out->u.h = h;
    return NOX_OK;
}
#endif

/* Plugin API v1: isteğe bağlı yaşam döngüsü kancası — test için bir işaret dosyasına yazar. */
NOX_EXPORT void nox_plugin_shutdown_v1(const NoxApiV1* api, NoxRuntime* rt) {
    (void)api;
    (void)rt;
    const char* marker = getenv("NOX_NNI_TEST_MARKER");
    if (marker) {
        /* "a" metin kipidir: Windows `\n` yazısını `\r\n` yapar. İşaret
           dosyası `shutdown\n` bekler, bu yüzden ikili ekleme kipi. */
        FILE* f = fopen(marker, "ab");
        if (f) {
            fputs("shutdown\n", f);
            fclose(f);
        }
    }
}
