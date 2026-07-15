#include <napi.h>

typedef struct TSLanguage TSLanguage;

extern "C" TSLanguage *tree_sitter_nox();

// "tree-sitter", "language" BLAKE2 ile hash'lenmiş — resmi tree-sitter
// node binding şablonuyla AYNI (bkz. binding.gyp'in belge notu).
const napi_type_tag LANGUAGE_TYPE_TAG = {
    0x8AF2E5212AD58ABF, 0xD5006CAD83ABBA16
};

Napi::Object Init(Napi::Env env, Napi::Object exports) {
    auto language = Napi::External<TSLanguage>::New(env, tree_sitter_nox());
    language.TypeTag(&LANGUAGE_TYPE_TAG);
    exports["language"] = language;
    return exports;
}

NODE_API_MODULE(tree_sitter_nox_binding, Init)
