#!/bin/bash
# Faz 9.0 F6: ThreadSanitizer yarış denetimi. `zig build -Dsanitize-thread=true` ile noxrt.o'yu TSan'lı kurar (fiber geçişleri `__tsan_*` ile açıklanmıştır), `mn_shared_*`/`mn_dyn_*`
# fixture'larını `NOX_SANITIZE_THREAD=1 noxc build --backend llvm` ile (işlev başlarına `sanitize_thread` eklenir, -fsanitize=thread) derleyip NOX_POOL_WORKERS=4 ile ROUNDS tur çalıştırır.
# Çıktı `.expected` ile bire bir aynı olmalı ve stderr'de "WARNING: ThreadSanitizer" bulunmamalıdır. Bitince normal `zig build` ile noxrt.o geri kurulur.
# Kullanım: scripts/tsan_check.sh [ROUNDS=2] [WORKERS=4] [FILTRE=mn_]   (yalnız ana makine, hosted, LLVM yolu; önkoşul clang)
cd "$(dirname "$0")/.." || exit 1
ROUNDS=${1:-2}
WORKERS=${2:-4}
FILTER=${3:-mn_}
NOXC=zig-out/bin/noxc
SUPP="$PWD/scripts/tsan.supp"
OUT=$(mktemp -d)
zig build -Dsanitize-thread=true -Dtrace-frames=0 >"$OUT/build.log" 2>&1 || { echo "TSan derlemesi başarısız"; tail -20 "$OUT/build.log"; exit 1; }
fail=0; total=0
# Kasıtlı (Anlam A) veri yarışı içeren fixture'lar: skaler okuma-değiştirme-yazma (`x = x + 1`) ve kilitsiz skaler liste erişimi atomik DEĞİLDİR (bellek-güvenli ama yarışlı);
# TSan bunları haklı olarak bildirir. Bariyer/kilit yolları (heap alan, heap liste, sözlük, global yuva, closure, kalıtım) bu listede DEĞİLDİR ve rapor vermemelidir.
SKIP=" mn_dyn_class_fields mn_dyn_cross_spawn_channel mn_dyn_handle_fields mn_dyn_list_scalar_fields mn_dyn_mixins mn_shared_class mn_shared_class_dict_fields mn_shared_dict mn_shared_scalar "
for src in tests/golden/codegen_cases/${FILTER}*.nox; do
  name=$(basename "$src" .nox)
  case "$SKIP" in *" $name "*) continue ;; esac
  exp="tests/golden/codegen_cases/$name.expected"
  [ -f "$exp" ] || continue
  if ! NOX_SANITIZE_THREAD=1 "$NOXC" build --backend llvm -o "$OUT/$name" "$src" >"$OUT/b.log" 2>&1; then
    echo "DERLEME HATASI: $name"; fail=$((fail + 1)); continue
  fi
  r=0
  while [ $r -lt "$ROUNDS" ]; do
    total=$((total + 1))
    NOX_POOL_WORKERS=$WORKERS TSAN_OPTIONS="halt_on_error=0 suppressions=$SUPP" timeout 300 "$OUT/$name" >"$OUT/out.txt" 2>"$OUT/err.txt"
    if grep -q "WARNING: ThreadSanitizer" "$OUT/err.txt"; then
      echo "TSAN UYARISI: $name tur=$r ($(grep -c 'WARNING: ThreadSanitizer' "$OUT/err.txt") rapor)"
      grep -A12 -m1 "WARNING: ThreadSanitizer" "$OUT/err.txt" | head -14
      fail=$((fail + 1))
    elif ! cmp -s "$OUT/out.txt" "$exp"; then
      echo "ÇIKTI FARKI: $name tur=$r"; head -c 300 "$OUT/err.txt"; fail=$((fail + 1))
    fi
    r=$((r + 1))
  done
done
echo "tsan_check: $total çalıştırma, $fail sorun"
zig build -Dtrace-frames=0 >/dev/null 2>&1   # normal noxrt.o'yu geri kur
rm -rf "$OUT"
[ $fail -eq 0 ]
