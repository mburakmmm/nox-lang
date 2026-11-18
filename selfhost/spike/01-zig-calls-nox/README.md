# Aşama 0.1: Zig → Nox çağrı deneyi

`count.nox`taki `count_ident_tokens(buf: ptr[u8], n: int) -> int` işlevi (lexer'ın tanımlayıcı tarama döngüsünün küçültülmüşü) `noxc` ile LLVM `.ll` metnine derlenir, `clang -c` ile nesneye çevrilir ve `harness.zig`ten C ABI ile çağrılır. `run.sh` her şeyi baştan kurar.

## Sonuç (v2.2.28)

| Soru | Cevap |
|---|---|
| Yol A (statik bağlama) çalışıyor mu? | **Evet.** `count.o` + `noxrt.o` + Zig harness tek ikilide bağlanır; sonuç doğru (11 tanımlayıcı). |
| İşlev simgesi | Her üst düzey `def`, `define i64 @ad(i64 %rt, i64 %arg...)` olarak **dış bağlantılı** çıkar (QBE'de `$ad`). Birinci parametre `rt` (`nox_runtime_init()` ile Zig tarafında bir kez oluşturulur); `int`/`ptr[T]` 64 bit tamsayıdır. |
| `main` | Modülün üst düzey kodu `@main` olur ve Zig'in `main`iyle çakışır; deneyde `sed` ile yeniden adlandırıldı. Temiz çözüm: **hosted `--emit-obj` + dışa aktarma listesi** (bugün `--emit-obj` yalnız mobil hedeflerde var). |
| İstisnalar | `rt` içindeki bekleyen-istisna alanı (`nox_exception_pending(rt)`); Zig çağıranı dönüşte bakmalı. |
| Hız (1,9 MB, ASCII tarama) | Nox 942 µs, eşdeğer Zig 1400 µs (**0,67×**): saf bayt tarama döngüleri Zig'den yavaş değil. Tahsis/sınıf ağırlıklı iş yükleri (parser/AST) bu deneyde ölçülmedi (plan 0.7). |
| Bağlama riski | Derleyici (Zig) çalışma zamanını içe aktarmaz (`runtime/` ayrı derleme birimi); `noxrt.o` (801 dış simge) nightly ikilisine eklenebilir görünüyor, simge çakışması 0.3'te sınanır. |
