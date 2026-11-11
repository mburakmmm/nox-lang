#!/bin/sh
# tests/compat/wasm_wat/*.wat dosyalarını binaryen `wasm-as` ile .wasm'a derler (testler .wasm'ı depodan okur; araç CI'de gerekmez).
# Özellikler açıkça seçilir: `--all-features` sıkıştırılmış içe aktarma gibi motorların henüz tanımadığı kodlamaları da açar.
set -e
cd "$(dirname "$0")/../tests/compat/wasm_wat"
for f in *.wat; do
  wasm-as --enable-sign-ext --enable-nontrapping-float-to-int --enable-bulk-memory --enable-reference-types --enable-multivalue --enable-mutable-globals \
    "$f" -o "${f%.wat}.wasm"
done
echo "wasm_build_wat: tamam"
