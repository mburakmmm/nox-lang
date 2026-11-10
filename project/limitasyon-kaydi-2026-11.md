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
- [x] **A15 (v2.1.16)** Bir `async def`in okuduğu modül-düzeyi `Channel[T]`/`Task[T]` çıkışta yıkılmıyordu — **KAPANDI v2.1.16**: `nox_deinit_globals` artık `isSpawnRefcountedType` globalleri de bırakır ve async epilog'unda `nox_async_deinit`ten ÖNCE çağrılır (önceden sıra tersti: zamanlayıcı kapatılmış olduğundan `Channel.deinit` çöküyordu).
- [x] **A16 (v2.1.15)** `print(await t)` hesaplanmış str/sınıf/list sızdırıyordu — **KAPANDI v2.1.15**.
- [x] **A17 (v2.1.17)** Global'e dokunan üst-düzey atama/metod çağrıları aradaki ifadelerden önce çalışıyordu (kaynak sırası bozuktu) — **KAPANDI v2.1.17**.
- [x] **A14 aura L5** `docs/language/memory.md` `__del__ yok` diyor, `__del__` var (belge). — **KAPANDI v2.1.4**

## B. Dil/derleyici özellikleri (küçük, tasarımı belli)

- [x] **B1 aura L3** `class Sub(Base[int])` somut jenerik taban (yeniden üretildi: sözdizimi hatası). — **KAPANDI v2.1.5**
- [x] **B2 nova 9** `spawn obj.method()` ve içe aktarılan `async def` (metot hâlâ reddediliyor; içe aktarma yeniden üretilecek). — **KAPANDI v2.1.5**
- [x] **B3 aura L4** bellek ayırma sayacı (`nox.mem.stats()`). — **KAPANDI v2.1.5**

## C. Karar gerektirenler (AGENTS.md §16: mimariyi etkiler, sorulmadan yapılmaz)

- [x] **C1 ember NL-002/003** fiber'ı bloklamayan uyku (`sleep_ms` fiber içinde kooperatif) ve zaman aşımı/ilk biten (`Task.wait`, `wait_any`) — **KAPANDI v2.1.6** (Channel için zaman aşımlı recv yok: görev sarmalayıcısı kullanın).
- [x] **C2 ember NL-005** `TaskGroup[T]` (`nox.tasks`) — **KAPANDI v2.1.10**; çıplak `list[Task[T]]` hâlâ yazılamaz (codegen `Unsupported`), grup tutamak sınıfı kullanır. Ayrıca `Task` alanlı sınıfların yığına terfisi ve `spawn` geçici argümanı sızıntıları düzeltildi.
- [~] **C3 ember NL-004** CPU-bound görevi sonlandırma sözleşmesi.
- [x] **C4 ember NL-008** sinyal abonelik API'si (`nox.signal`) — **KAPANDI v2.1.6**.
- [x] **C5 ember NL-006/007/013** Postgres: SQLSTATE/`kind`, `statement_timeout`, `Transaction`, `Pool` **KAPANDI v2.1.8**; fiber-uyumlu (bloklamayan) libpq G/Ç, `set_query_timeout`, `cancel()` (`PQcancel`) **KAPANDI v2.1.17**.
- [x] **C6 ember NL-001** `nox.redis` (RESP2, AUTH/ACL, TLS, Streams, betik/NOSCRIPT, reconnect) — **KAPANDI v2.1.9**; TLS başarılı el sıkışması güvenilir sertifikalı bir Redis'e karşı denenmedi.
- [x] **C7 ember NL-009** JSON tam sayı hassasiyeti (2^53 üstü) — `as_int`, `number_text`, `dump` tam metni korur — **KAPANDI v2.1.7**.
- [x] **C8 rune** `nox.terminal` (raw mod, boyut, poll, ham yazma, echo, yetenek tespiti) — **KAPANDI v2.1.7**; Windows'ta terminal denetimi yok (`TerminalError`).
- [~] **C9 aether/nyx/ember** `serve_multicore` closure, IPv6 çok çekirdekli dinleme, paylaşılan `Application`/`list`/`dict`, `AtomicRef`.
- [x] **C10 nyx 2.3** şablonda döngü/koşul — `render_blocks` (`for`/`if`/`else`, `loop.*`) — **KAPANDI v2.1.7**; `render` değişmedi.
- [x] **C11 nyx 2.4** `nox.jwt.verify` `exp/nbf/iat` kontrolü — `verify_claims`/`verify_now` eklendi (v2.1.7); `verify` davranışı değişmedi.
- [~] **C12 pulse** protobuf (**KAPANDI v2.1.18**: `nox.protobuf` tel formatı), gRPC (açık: HTTP/2 istemci + trailer kararı), UDP (**KAPANDI v2.1.15**: `nox.udp`), Buffer→str köprüsü ve gzip→bytes (**KAPANDI v2.1.13**: `nox.bytes.str_from_list/to_str/...`); mikro/nano-saniye saat (**KAPANDI v2.1.13**: `now_ns`, `monotonic_ns`).
- [x] **C13 ember NL-010/011/014** UUIDv7 (**KAPANDI v2.1.7**: `uuid7`, `uuid7_at`, `uuid7_timestamp_ms`), property-test (**KAPANDI v2.1.12**: `nox.property`), zaman dilimi (**KAPANDI v2.1.14**: `nox.timezone`).
- [~] **C14 aether 5** `@controller`/`@get` metot dekoratörlerinin işleyici olması.
- [~] **C15 pulse TYPE-001** tagged union / enum.

## D. Bayat ya da tasarım gereği (iş yok)

- [-] aether 4 / nyx 2.6 liste ataması kopya: tasarım (değer semantiği); belge notu yeterli.
- [-] aura L6 `isinstance`/`weakref` yok: tasarım kararı.
- [-] nova 1-7, nyx bölüm 1/5: kapanmış.
- [-] pulse QBE-001/002, MODULE-001, FIBER-001, FS-001, HTTP-001/002, JSON-001, STR-001, CLOCK-001, TASKLOCAL-002/003: belgelenmiş tasarım sınırları.
