# Çerçeve limitasyon kaydı (2026-11-10)

Kaynaklar: aether, nyx, aura, nova, rune, pulse, ember depolarındaki `NOX_LIMITATIONS` belgeleri.
Her madde `v2.1.1` derlemesinde yeniden üretildi ya da bayat çıktı. Durum: `[ ]` açık, `[x]` kapandı (sürümle), `[~]` karar bekliyor, `[-]` bayat/tasarım gereği.

## A. Net hatalar (karar gerektirmez; sırayla düzeltilir)

- [x] **A1 pulse FMT-001** `noxc fmt` `class Box[T]` içindeki `[T]`yi siliyor (yeniden üretildi). — **KAPANDI v2.1.2**
- [x] **A2 pulse FMT-002** `noxc fmt` `"\x00"` kaçışını gerçek NUL baytına çeviriyor (yeniden üretildi). — **KAPANDI v2.1.2**
- [x] **A3 pulse FMT-003** `noxc fmt` `1.0e300` için `NoSpaceLeft` veriyor (yeniden üretildi). — **KAPANDI v2.1.2**
- [x] **A4 pulse FLOAT-001** NaN `!=` LLVM'de `False`, QBE'de `True` (yeniden üretildi; IEEE: `True`). — **KAPANDI v2.1.2**
- [x] **A5 pulse PARSER-001** `-9223372036854775808` doğrudan yazılamıyor (yeniden üretildi). — **KAPANDI v2.1.2**
- [x] **A6 aura L1** İçinde `dict[str, Node]` olan döngü çıkışta askıda kalıyor (yeniden üretildi, 10 sn'de bitmedi). — **KAPANDI v2.1.2**
- [x] **A7 aura L2** `dict`/`set`/`OrderedDict` silme O(n) (aura ölçümü: 10k→20k katı ~5). — **KAPANDI v2.1.3**
- [x] **A8 nyx 2.8** `query_decode` `+` karakterini boşluk yapmıyor (yeniden üretildi: `a+b c`). — **KAPANDI v2.1.2**
- [x] **A9 pulse HTTP-003** GET'te gövde sessizce yok sayılıyor (yeniden üretim bekliyor). — **KAPANDI v2.1.2**
- [x] **A10 nova 8** HEAD yanıtı + keep-alive gövde okuma kilitlenmesi (bekliyor). — **KAPANDI v2.1.2**
- [x] **A11 pulse TASKLOCAL-001** TaskLocal değerleri fiber yok edilirken serbest bırakılmıyor (bekliyor). — **KAPANDI v2.1.2**
- [x] **A12 pulse PROVENANCE-001** `noxc --version` kaynak commit'ini göstermiyor. — **KAPANDI v2.1.2**
- [ ] **A13 aura L7** modül düzeyi `str` atamasında çıkışta `nox_rc_pool_drain` çökmesi (bağımsız repro yok; A6 (v2.1.2) çıkış-kilitlenmesini düzeltti — aura `files` self-check'ini `_roots[0]` yamasını geri alıp yeniden denemeli; çökme sürerse ayrı hata).
- [x] **A14 aura L5** `docs/language/memory.md` `__del__ yok` diyor, `__del__` var (belge). — **KAPANDI v2.1.4**

## B. Dil/derleyici özellikleri (küçük, tasarımı belli)

- [x] **B1 aura L3** `class Sub(Base[int])` somut jenerik taban (yeniden üretildi: sözdizimi hatası). — **KAPANDI v2.1.5**
- [x] **B2 nova 9** `spawn obj.method()` ve içe aktarılan `async def` (metot hâlâ reddediliyor; içe aktarma yeniden üretilecek). — **KAPANDI v2.1.5**
- [x] **B3 aura L4** bellek ayırma sayacı (`nox.mem.stats()`). — **KAPANDI v2.1.5**

## C. Karar gerektirenler (AGENTS.md §16: mimariyi etkiler, sorulmadan yapılmaz)

- [~] **C1 ember NL-002/003** fiber'ı bloklamayan `sleep_async_ms`, `select`/`race`/zaman aşımı.
- [~] **C2 ember NL-005** `list[Task[T]]` / `TaskGroup`.
- [~] **C3 ember NL-004** CPU-bound görevi sonlandırma sözleşmesi.
- [~] **C4 ember NL-008** sinyal abonelik API'si.
- [~] **C5 ember NL-006/007/013** Postgres: SQLSTATE, havuz, sorgu zaman aşımı/iptal, fiber-uyumlu I/O.
- [~] **C6 ember NL-001** `nox.redis`.
- [~] **C7 ember NL-009** JSON tam sayı hassasiyeti (2^53 üstü).
- [~] **C8 rune** `nox.terminal` (raw mod, boyut, poll, ham yazma, echo).
- [~] **C9 aether/nyx/ember** `serve_multicore` closure, IPv6 çok çekirdekli dinleme, paylaşılan `Application`/`list`/`dict`, `AtomicRef`.
- [~] **C10 nyx 2.3** şablonda döngü/koşul.
- [~] **C11 nyx 2.4** `nox.jwt.verify` `exp/nbf/iat` kontrolü.
- [~] **C12 pulse** protobuf, gRPC, UDP, Buffer→str köprüsü, gzip→bytes, mikro-saniye saat.
- [~] **C13 ember NL-010/011/014** UUIDv7, property-test, zaman dilimi.
- [~] **C14 aether 5** `@controller`/`@get` metot dekoratörlerinin işleyici olması.
- [~] **C15 pulse TYPE-001** tagged union / enum.

## D. Bayat ya da tasarım gereği (iş yok)

- [-] aether 4 / nyx 2.6 liste ataması kopya: tasarım (değer semantiği); belge notu yeterli.
- [-] aura L6 `isinstance`/`weakref` yok: tasarım kararı.
- [-] nova 1-7, nyx bölüm 1/5: kapanmış.
- [-] pulse QBE-001/002, MODULE-001, FIBER-001, FS-001, HTTP-001/002, JSON-001, STR-001, CLOCK-001, TASKLOCAL-002/003: belgelenmiş tasarım sınırları.
