/* nox-hpy-host-v1 uyumluluk eklentisi.
 *
 * Universal ABI: bağlamın fonksiyon işaretçileri Nox'un HPyContext
 * yerleşiminden okunur. Ofsetler runtime/hpy_bridge/context.zig ile
 * kilitlidir (64 bit). CPython gömülmez.
 */
#include <stdint.h>
#include <stddef.h>

typedef intptr_t HPy;

#define OFF_VALUE_ERROR 352
#define OFF_DUP 640
#define OFF_CLOSE 648
#define OFF_FROM_I64 672
#define OFF_AS_I64 728
#define OFF_ERR_SET 1120
#define OFF_TYPE_FROM_SPEC 1224
#define OFF_SET_ATTR 1280
#define OFF_NEW 1384
#define OFF_AS_STRUCT 1368
#define OFF_BYTES_SIZE 1456
#define OFF_BYTES_AS 1472
#define OFF_BYTES_FROM 1496
#define HPY_FUNC_KEYWORDS 2

#define HPY_DEF_KIND_SLOT 1
#define HPY_DEF_KIND_METH 2
#define HPY_FUNC_NOARGS 3
#define HPY_FUNC_O 4
#define HPY_SLOT_TP_NEW 65
#define HPY_SLOT_MOD_EXEC 2001

typedef HPy (*fn_from_i64)(void *ctx, int64_t v);
typedef int64_t (*fn_as_i64)(void *ctx, HPy h);
typedef HPy (*fn_dup)(void *ctx, HPy h);
typedef void (*fn_close)(void *ctx, HPy h);
typedef void (*fn_err)(void *ctx, HPy typ, const char *msg);
typedef HPy (*fn_type)(void *ctx, void *spec, void *params);
typedef int (*fn_setattr)(void *ctx, HPy obj, const char *name, HPy value);
typedef HPy (*fn_new)(void *ctx, HPy type, void **data);
typedef void *(*fn_as_struct)(void *ctx, HPy h);
typedef intptr_t (*fn_bytes_size)(void *ctx, HPy h);
typedef const char *(*fn_bytes_as)(void *ctx, HPy h);
typedef HPy (*fn_bytes_from)(void *ctx, const char *p, intptr_t n);

static void *field(void *ctx, size_t off) {
    return *(void **)((char *)ctx + off);
}

static HPy from_i64(void *ctx, int64_t v) {
    return ((fn_from_i64)field(ctx, OFF_FROM_I64))(ctx, v);
}

static int64_t as_i64(void *ctx, HPy h) {
    return ((fn_as_i64)field(ctx, OFF_AS_I64))(ctx, h);
}

static HPy do_dup(void *ctx, HPy h) {
    return ((fn_dup)field(ctx, OFF_DUP))(ctx, h);
}

static HPy value_error(void *ctx) {
    return *(HPy *)((char *)ctx + OFF_VALUE_ERROR);
}

typedef struct {
    const char *name;
    void *impl;
    void *cpy;
    int signature;
    const char *doc;
} HPyMeth;

typedef struct {
    int slot;
    int _pad;
    void *impl;
    void *cpy;
} HPySlot;

typedef struct {
    int kind;
    int _pad;
    union {
        HPyMeth meth;
        HPySlot slot;
        unsigned char raw[40];
    } u;
    unsigned char tail[16];
} HPyDef;

typedef struct {
    const char *doc;
    intptr_t size;
    void *legacy_methods;
    const HPyDef *const *defines;
    void *globals;
} HPyModuleDef;

/* Gerçek HPy `HPyType_Spec`: `unsigned long` LP64'te 8, Windows'ta 4
 * bayttır. Fazladan bir pad alanı Windows'ta `defines`'i 8 bayt kaydırır
 * ve konak tip metodunu göremez. */
typedef struct {
    const char *name;
    int basicsize;
    int itemsize;
    unsigned long flags;
    int builtin_shape;
    void *legacy_slots;
    const HPyDef *const *defines;
    const char *doc;
} HPyTypeSpec;

_Static_assert(sizeof(HPyDef) == 64, "HPyDef");
_Static_assert(offsetof(HPyDef, u) == 8, "union");
#if defined(_WIN32)
_Static_assert(sizeof(HPyTypeSpec) == 48, "HPyType_Spec");
_Static_assert(offsetof(HPyTypeSpec, defines) == 32, "defines");
#else
_Static_assert(sizeof(HPyTypeSpec) == 56, "HPyType_Spec");
_Static_assert(offsetof(HPyTypeSpec, defines) == 40, "defines");
#endif

typedef struct {
    int64_t value;
} Box;

int64_t sampleext_c_add(int64_t x) {
    return x + 1;
}

static HPy answer(void *ctx, HPy self) {
    (void)self;
    return from_i64(ctx, 42);
}

static HPy add_c(void *ctx, HPy self, HPy arg) {
    (void)self;
    return from_i64(ctx, sampleext_c_add(as_i64(ctx, arg)));
}

static HPy identity(void *ctx, HPy self, HPy arg) {
    (void)self;
    return do_dup(ctx, arg);
}

static HPy box_new(void *ctx, HPy type, const HPy *args, intptr_t nargs, HPy kw) {
    void *data = 0;
    HPy h;
    (void)kw;
    h = ((fn_new)field(ctx, OFF_NEW))(ctx, type, &data);
    if (h == 0 || data == 0) return 0;
    ((Box *)data)->value = (nargs > 0) ? as_i64(ctx, args[0]) : 0;
    return h;
}

static HPy echo_bytes(void *ctx, HPy self, HPy arg) {
    intptr_t n;
    const char *p;
    (void)self;
    n = ((fn_bytes_size)field(ctx, OFF_BYTES_SIZE))(ctx, arg);
    p = ((fn_bytes_as)field(ctx, OFF_BYTES_AS))(ctx, arg);
    if (n < 0 || p == 0) return 0;
    return ((fn_bytes_from)field(ctx, OFF_BYTES_FROM))(ctx, p, n);
}

static HPy twice(void *ctx, HPy self, const HPy *args, size_t nargs, HPy kw) {
    (void)self;
    (void)kw;
    if (nargs != 1 || args == 0) return 0;
    return from_i64(ctx, as_i64(ctx, args[0]) * 2);
}

static HPy fail(void *ctx, HPy self) {
    (void)self;
    ((fn_err)field(ctx, OFF_ERR_SET))(ctx, value_error(ctx), "nope");
    return 0;
}

static HPy box_value(void *ctx, HPy self) {
    Box *box = ((fn_as_struct)field(ctx, OFF_AS_STRUCT))(ctx, self);
    if (box == 0) return 0;
    return from_i64(ctx, box->value);
}

static HPyDef box_new_def = {
    .kind = HPY_DEF_KIND_SLOT,
};
static HPyDef box_value_def = {
    .kind = HPY_DEF_KIND_METH,
};
static const HPyDef *const box_defines[] = { &box_new_def, &box_value_def, 0 };
static HPyTypeSpec box_spec = {
    .name = "sampleext.Box",
    .basicsize = (int)sizeof(Box),
    .defines = box_defines,
};

static int mod_exec(void *ctx, HPy module) {
    HPy typ = ((fn_type)field(ctx, OFF_TYPE_FROM_SPEC))(ctx, &box_spec, 0);
    if (typ == 0) return -1;
    if (((fn_setattr)field(ctx, OFF_SET_ATTR))(ctx, module, "Box", typ) < 0) {
        ((fn_close)field(ctx, OFF_CLOSE))(ctx, typ);
        return -1;
    }
    ((fn_close)field(ctx, OFF_CLOSE))(ctx, typ);
    return 0;
}

static HPyDef d_answer = {
    .kind = HPY_DEF_KIND_METH,
    .u.meth = { "answer", (void *)answer, 0, HPY_FUNC_NOARGS, 0 },
};
static HPyDef d_add = {
    .kind = HPY_DEF_KIND_METH,
    .u.meth = { "add_c", (void *)add_c, 0, HPY_FUNC_O, 0 },
};
static HPyDef d_identity = {
    .kind = HPY_DEF_KIND_METH,
    .u.meth = { "identity", (void *)identity, 0, HPY_FUNC_O, 0 },
};
static HPyDef d_echo = {
    .kind = HPY_DEF_KIND_METH,
    .u.meth = { "echo_bytes", (void *)echo_bytes, 0, HPY_FUNC_O, 0 },
};
static HPyDef d_twice = {
    .kind = HPY_DEF_KIND_METH,
    .u.meth = { "twice", (void *)twice, 0, HPY_FUNC_KEYWORDS, 0 },
};
static HPyDef d_fail = {
    .kind = HPY_DEF_KIND_METH,
    .u.meth = { "fail", (void *)fail, 0, HPY_FUNC_NOARGS, 0 },
};
static HPyDef d_exec = {
    .kind = HPY_DEF_KIND_SLOT,
};
static const HPyDef *const module_defines[] = { &d_answer, &d_add, &d_identity, &d_echo, &d_twice, &d_fail, &d_exec, 0 };
static HPyModuleDef module_def = {
    .doc = "nox-hpy-host-v1 sampleext",
    .defines = module_defines,
};

__attribute__((constructor)) static void init_slots(void) {
    box_new_def.u.slot.slot = HPY_SLOT_TP_NEW;
    box_new_def.u.slot.impl = (void *)box_new;
    box_value_def.u.meth.name = "value";
    box_value_def.u.meth.impl = (void *)box_value;
    box_value_def.u.meth.signature = HPY_FUNC_NOARGS;
    d_exec.u.slot.slot = HPY_SLOT_MOD_EXEC;
    d_exec.u.slot.impl = (void *)mod_exec;
}

HPyModuleDef *HPyInit_sampleext(void) {
    return &module_def;
}
