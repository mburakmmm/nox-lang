# Sembol adları

Bir Nox üst-düzey `def`i, nesne dosyasında düz adıyla bir **genel sembol** olur (`$ad` QBE'de, `@ad` LLVM'de). Aynı adı taşıyan bir C kütüphanesi sembolü çalışma zamanı ya da üretilen kod tarafından çağrılıyorsa, kullanıcı fonksiyonu bağlayıcıda onun yerine geçerdi: `def printf(...)` `print`i sessizce bozar, `def getenv(...)` çalışma zamanının ortam okumasını ele geçirir, `def read(...)` `nox.io`nun `read`ini değiştirir, wasm'da imza uyuşmazlığı çağrıyı tuzağa düşürür.

## Politika

Standart C, POSIX, libm ve hedef sistemlerin (Darwin, glibc/musl, Android, Windows, wasi-libc) çalışma zamanı sembollerinden oluşan **ayrılmış ad listesindeki** bir adı taşıyan üst-düzey fonksiyonun SEMBOLÜ `nox_user_<ad>` olur. Nox düzeyindeki ad değişmez: kaynak kodda `printf(...)` yazmaya devam edersiniz; hata iletileri, `reflect` ve `noxc expand` eski adı gösterir. Bu iki backend'de ve tüm hedeflerde (yerel, mobil, wasm) aynıdır.

```python
def getenv(x: int) -> int:     # nesne dosyasında nox_user_getenv
    return x + 1

print(getenv(41))              # 42; çalışma zamanının kendi getenv'i etkilenmez
```

- Liste yalnızca bugün bağlanan sembolleri değil, standart C/POSIX/libm ad alanının tamamını kapsar (`compiler/codegen_qbe/reserved_symbols.zig`); çalışma zamanı yarın yeni bir libc işlevine bağlanabilir.
- `extern def` bildirimleri ETKİLENMEZ: `extern def sqrt(x: float) -> float from "m"` gerçek `sqrt`ı bağlamak içindir.
- Nox yerleşikleri (`abs`, `round`, `min`, ...) ve anahtar sözcükler zaten kullanıcı fonksiyonu olarak tanımlanamaz.
- Bir Nox işlevini C'den ada göre çağıran gömme (`nox_embed`) kodu, ayrılmış bir adı taşıyan işlev için `nox_user_` önekli adı kullanmalıdır. Ayrılmamış adlar eskisi gibi düz adla çağrılır.
- Sınıf metodlarının sembolleri `Sınıf_metod` biçimindedir; yalnızca sınıf adı bir libc öneki ile (`pthread`, `clock`, ...) çakışırsa ayrılmış bir adla karşılaşabilir. Bu durum için bir koruma yoktur (belgelenmiş sınır).

## Doğrulama

- `tests/golden/codegen_cases/reserved_symbol_names.nox`: listedeki HER ad için bir kullanıcı fonksiyonu tanımlar ve çağırır; bazıları ayrıca işlev değeri, `spawn` ve `nox.thread.start` yollarıyla kullanılır. İki backend'de ve sekiz wasm hedefinde koşar. Liste değişince `scripts/gen_reserved_symbol_fixture.py` çalıştırılır; CI `--check` ile güncelliği doğrular.
- `scripts/check_reserved_symbols.py`: çalışma zamanı nesnelerinin (`zig-out/lib/noxrt*.o`) `nm -u` ile okunan, libc'den çözdüğü her sembolün listede olduğunu doğrular. Çalışma zamanı yeni bir libc işlevine bağlanınca CI burada kırılır.
