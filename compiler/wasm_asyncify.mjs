// `--asyncify` hedefleri için bağlama sonrası işlem: `wasm-opt --strip-dwarf --asyncify --pass-arg=asyncify-removelist@*nox_asyncify_run*
// --pass-arg=asyncify-ignore-imports -O2` (bkz. `linkWasm` ve ADR-014) işleminin `binaryen` (JS/WASM) karşılığı. Yerel `wasm-opt` gerektirmez, tarayıcıda çalışır.
//
//   import binaryen from 'binaryen';                       // npm install binaryen (Apache-2.0, ~15 MB JS)
//   import { binaryenAsyncify } from './wasm_asyncify.mjs';
//   const nox = await createNoxCompiler({ frontend, asset, clang, optimize: binaryenAsyncify(binaryen) });
//
// Not: `m.setFeatures(binaryen.Features.All)` ÇAĞRILMAZ: tüm özellikleri açmak bazı kodlamaları değiştirir ve içe aktarma bölümü geçersiz çıkar; özellikler modülün
// `target_features` bölümünden okunur (wasm-opt ile aynı).

export function binaryenAsyncify(binaryen) {
  return function optimize(bytes) {
    const m = binaryen.readBinary(bytes);
    try {
      // Geçiş argümanları binaryen'de küresel durumdur; her çağrıda yeniden ayarlanır.
      binaryen.setPassArgument('asyncify-removelist', '*nox_asyncify_run*');
      binaryen.setPassArgument('asyncify-ignore-imports', 'true');
      m.runPasses(['strip-dwarf', 'asyncify']);
      binaryen.setOptimizeLevel(2);
      binaryen.setShrinkLevel(0);
      m.optimize();
      if (!m.validate()) throw new Error('asyncify sonrası modül geçersiz');
      return m.emitBinary();
    } finally {
      m.dispose();
    }
  };
}
