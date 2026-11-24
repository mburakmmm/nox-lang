# Çerçeve limitasyonlarının güncel derleyicide doğrulanması (2026-11-24, noxc 2.2.62 → 2.2.63)

Kaynak raporlar: `project/framework-limitasyonlari-2026-11/{prism,ember,pulse,chronos}.md` (orijinal sürüm Nox 2.2.38 / 2.1.111). Her madde ReleaseFast `noxc 2.2.62` ile, **LLVM ve QBE**, `check`/`run`/`build` ile
yeniden üretildi (Chronos/Pulse tekrar-üretim dosyaları geçici kopyada çalıştırıldı; kaynak depolara yazılmadı). Düzeltmeler **v2.2.63**'te; sınıf sözlüğü:
BAYAT (zaten kapanmış) · GERÇEK HATA · EKSİK ÖZELLİK · TASARIM GEREĞİ · KARAR (kullanıcı kararı alındı) · TEKRARLANAMADI.

## Prism

| Madde | Tekrar üretim (2.2.62) | Sınıf | Aksiyon |
|---|---|---|---|
| `__all__` içinde modül sabiti (`MAX_K: int = 7`) | `__all__ of module 'consts' lists 'MAX_K', which is not a function or class defined there` (iki backend) | GERÇEK HATA | **Düzeltildi:** `validateModuleExports` modül düzeyi değişkenleri kabul eder; `from consts import MAX_K` çalışır. Test: `local_import_test` (iki backend) |
| `__all__` içinde `from m import X` yeniden dışa aktarımı (cephe modülü) | sınıf/işlev/sabit için aynı hata | GERÇEK HATA | **Düzeltildi:** `__all__` bir `from m import X` ile gelen adı listeleyebilir; `resolveReExportChains` sabitleri de çözer. **Kalan (ayrı, bu turda yok):** `import m; m.CONST` ile niteliksiz-olmayan sabit okuma ve `facade.helper()` niteleyicili yeniden-dışa-aktarım çağrısı `undefined variable` verir (`from m import X` biçimi çalışır) — dil yüzeyi kararı |
| Çağrı / `def` imzasında sondaki virgül (`f(a, b,)`) | `unexpected ')' (expected identifier)` | GERÇEK HATA (Python sadakati, AGENTS §5) | **Düzeltildi:** Zig parser + Nox parser (`parser.nox.in`): çağrı, `def`, `extern def`, sınıf tabanı, dekoratör argümanı, jenerik kurucu. `noxc fmt` virgülü yazmaz. Golden `parser_trailing_commas`, Zig↔Nox `frontend_diff` paritesi |
| `_ = ifade` | `undefined variable: _ (give the type ...)`; `_ := f()` ikinci kullanımda tip çakışması | EKSİK ÖZELLİK — KARAR: özel at-gitsin adı | **Düzeltildi:** bildirilmemiş `_` ataması değeri hesaplayıp atan ifade deyimine indirgenir (checker). `_: T = ...` ile bildirilmişse sıradan değişken. Golden `discard_assign` |
| İşlev içinde `import` | `'import' is only allowed at module level` (açık, kasıtlı ileti) | TASARIM GEREĞİ | Dokunulmadı (statik modül çözümleme) |
| Yerel adın modül takma adını gölgelemesi (NXL-003) | Chronos `module_alias_shadow` iki backend `1`; `local_import_test` "NXL-003" | BAYAT | v2.1.186'dan önce kapandı; iş yok |
| `Sinif.fabrika().yontem()` akıcı zincir hatası | `call the static/class method 'crop' through the class name ...` (iki backend; `Graph.empty().crop(1)`; başka sınıfta aynı adlı `@staticmethod crop` varken) | GERÇEK HATA | **Düzeltildi:** `tryResolveStaticMethodCall` yan-etki hatasını yalnızca alıcı sınıfın (taban zinciri dahil) gerçekten aynı adlı static/classmethod'u varsa verir (`static_method_names` tüm programın adlarını tutuyordu). Test: `local_import_test` (çapraz modül, iki backend + hâlâ reddedilen gerçek durum) |
| `nox.test.assert_false` yok | `module 'nox.test' has no member named 'assert_false'` | EKSİK ÖZELLİK | **Eklendi.** Golden `nox_test_assert_false`, `docs/stdlib/test.md` |
| `list[Task[T]]` reddi | `'list[Task[...]]' is not supported ... use nox.tasks.TaskGroup[T]` | TASARIM GEREĞİ (kayıt E6, kasıtlı karar v2.1.38) | Dokunulmadı |
| zlib/deflate/crc32/adler32 stdlib'de yok | `nox.gzip` + `nox.zip` vardı; ham zlib/deflate, `crc32`, `adler32` yoktu | KISMEN BAYAT + EKSİK ÖZELLİK | **Eklendi `nox.zlib`:** `compress/decompress` (zlib), `deflate/inflate` (ham), `crc32`/`adler32` (+artımlı, `_str`). Tüm hedefler (`std.compress.flate`), `gzip.zig` kap-yolu genelleştirildi. Python `zlib` ile çapraz doğrulanmış golden `zlib_roundtrip` (zlib/ham akışı, crc32/adler32) |
| `\x80`–`\xFF` dize kaçışı reddi | `'\x80'-'\xFF' escapes are not supported: a str holds valid UTF-8` | TASARIM GEREĞİ | Dokunulmadı (`nox.bytes` kullanılır) |
| `int(float)` sıfıra yuvarlama | `int(-0.3) == 0` | TASARIM GEREĞİ (Python `int()` ile aynı) | Dokunulmadı |
| 64 bit tamsayı taşmasında sarma | belgeli (QBE/LLVM farkı: `project_default_backend_llvm_v1_143`) | TASARIM GEREĞİ | Dokunulmadı |
| `nox.math` freestanding'de yok | `nox.mathx` ayrımı | TASARIM GEREĞİ | Dokunulmadı |
| `extern def` kısıtları / wasm dinamik yükleme | AGENTS §9.5 güven sınırı | TASARIM GEREĞİ | Dokunulmadı |
| `async def` sınıf metodu içinde `await` | `'await' can only be used inside an 'async def' body` (iki backend) | GERÇEK HATA | **Düzeltildi:** metot gövdesi `async def` ise `await`e izin verilir (`checkMethodBody` `in_async`); `spawn obj.metot()` ile başlatılan metot fiberde çalışır. Golden `async_method_await` |
| `await fn()` doğrudan (spawn'sız) | `'f' is an 'async def' function and can only be started with 'spawn'` | TASARIM GEREĞİ | Dokunulmadı (görev başlatmak her zaman açık) |

## Ember

| Madde | Tekrar üretim | Sınıf | Aksiyon |
|---|---|---|---|
| NX-006 Redis TLS IP SAN reddi (`rediss://127.0.0.1`, IP SAN sertifikası) | kök neden: vendor `tls_client.zig` `verifyHostName` yalnızca `dNSName` SAN'a bakar | GERÇEK HATA | **Düzeltildi:** `verifyHostNameOrIp` — `host` IP sabit değeriyse `subjectAltName` `iPAddress` girdileriyle bayt bayt eşleştirir (DNS/CN ile eşleştirmez); IP değilse std yolu. Bu `nox.tls`, `nox.http` istemcisi, `nox.smtp`, `nox.postgres`/`mysql` TLS'ini de kapsar. Zig birim testi (openssl ile üretilmiş IP+DNS SAN'lı sertifika, ipv4/ipv6/negatif) |
| Cooperative cancellation, fiber stack, QBE/LLVM scheduler farkı, Cluster atomiklik alanı | belgeli sınırlar | TASARIM GEREĞİ | Dokunulmadı |

## Pulse

| Madde | Tekrar üretim | Sınıf | Aksiyon |
|---|---|---|---|
| NOX-TYPE-003 `match` kollarında aynı bağlama adı farklı tiple | `'payload' is already defined in this scope with type 'str'` | EKSİK ÖZELLİK — KARAR: kol-kapsamlı bağlama | **Düzeltildi:** `Checker.renameConflictingMatchBindings` — aynı ad önceki kolda FARKLI tiple bağlanmışsa kol gövdesi (bağlama dahil) `<ad>__arm<i>` adıyla yeniden yazılır (`ast_clone.renameStmts`). Aynı tipte ad paylaşımı ve `if/else` kapsamı DEĞİŞMEDİ. Golden `match_arm_binding_scope` |
| NOX-ASYNC-001 boş kanalda bekleyen görevi `cancel()` → "deadlock detected" | iki backend ölü | GERÇEK HATA — KARAR: uyandır | **Düzeltildi:** `Task.cancel()` askıdaki `await ch.recv()` / `await task` bekleyişini kuyruktan/hedef alanından çıkarıp uyandırır; `await` `CancelledError` fırlatır. Atomik sahiplenme (`CancelWait`/`CancelPark`), teslim edilmiş değer korunur. Golden `task_cancel_wakes_blocked_wait` (+bridge birim testi) |
| NOX-TYPE-002 `if x is None: raise` sonrası daralma | yalnızca **modül üst düzeyi** global için başarısız; işlev/metod yerelleri, parametreler ve `self.alan` yolları çalışıyor | TASARIM GEREĞİ (kısmen) | `guard_normalize.zig` bilinçli olarak yalnız işlev/metod gövdelerini dönüştürür (global terfisi bozulmasın). Belge notu eklendi (`docs/language/types.md`); kod değişmedi |
| NOX-CODEGEN-003 `with self.guard as held:` | `codegen: ... not supported` (iki backend) | GERÇEK HATA | **Düzeltildi:** `inferWithCtxClassName` sınıf alanı yollarını (`self.guard`, `a.b.c`) çözer. Golden `with_field_context_manager` |
| NOX-HTTP-005 `serve()` işleyici bitmeden döner | yalnız `max_connections` argümanıyla (N. bağlantı kabul edilince döner); `shutdown()`/SIGTERM ile graceful yolda `serve` uçuştaki isteği bekliyor (doğrulandı) | TASARIM GEREĞİ + BELGE | **Belge düzeltildi** (`docs/stdlib/http.md`: "served" = kabul edilen). Kod değişmedi: erken dönüş `ConnCounter` ömür tasarımıdır |
| NOX-FMT-004/FMT-001..003/PARSER-001/FLOAT-001, CODEGEN-001/002, QBE-002 transferleri, TYPE-001, CLOCK/JSON/STR/CAP-*, HTTP-003/004 | Pulse kendisi KAPALI diyor; `pass_only_class`, `optional_float_field`, `generic_class` fixture'ları iki backend geçti | BAYAT | İş yok |
| TASKLOCAL-002/003, QBE-001, MODULE-001, FS-001, FIBER-001, HTTP-001, GRPC-001 | belgeli tasarım sınırları | TASARIM GEREĞİ | Dokunulmadı |

## Chronos

| Madde | Tekrar üretim | Sınıf | Aksiyon |
|---|---|---|---|
| NXL-001 isteğe bağlı ilkel alanlar → unsupported codegen | küçük prob ve Pulse `optional_float_field` iki backend geçiyor; üretim biçimli repro yok | TEKRARLANAMADI | Kayıt: repro gelirse yeniden aç |
| NXL-002 liste parametresine `insert` | `proofs/limitations/list_parameter_insert.nox` iki backend `7` | BAYAT (v2.1.98) | — |
| NXL-003 yerel ad = modül takma adı | iki backend `1` | BAYAT | — (test: `local_import_test` "NXL-003") |
| NXL-004 pre-epoch `to_epoch_ms` | iki backend `-432000000` | BAYAT (v2.1.98) | — |
| NXL-005 çapraz modülde atlanan `X | None = None` varsayılan | `default_policy_factory_consumer` iki backend çalışır | BAYAT | — |
| NXL-006 CPU işini iptal edememe | `Task.cancel()` kooperatif | TASARIM GEREĞİ | Dokunulmadı (kullanıcı kararı v2.1.19) |
| NXL-007 paket kendi manifest adıyla içe aktarma | `package_self_import` iki backend çalışır | BAYAT | — (test: "NXL-007") |
| NXL-008 genel API allowlist'i uygulanamaz | `__all__` (2.3 madde 3.8b) tam bu mekanizmadır; yalnız `__all__` olmayan modülde `_ad` içe aktarılabilir (belgeli) | BAYAT / TASARIM | Chronos modüllerine `__all__` eklemesi çerçevenin işi |
| NXL-009 SQLite metin okuması gömülü NUL'da kesilir | `a:3` yerine `ab` baytları: `sqlite3_column_text` NUL sonlu kopyalıyordu | GERÇEK HATA | **Düzeltildi (okuma):** `sqlite3_column_bytes` ile tam uzunluk. **Kalan:** `bind_text` yazma yönü NUL'da keser (`-1` uzunluk); Chronos yazmada NUL'u zaten reddediyor |
| NXL-010 liste parametresini yakalayan closure | `list_parameter_closure` iki backend `recorded` | BAYAT | — |

## Ek doğrulama / kalanlar

- **Modül-nitelikli sabit okuma (`import m; m.MAX_K`) ve niteleyicili yeniden-dışa-aktarım çağrısı (`facade.helper()`)**: bu raporlarda yoktu; doğrulama sırasında `from m import X` yolunun çalıştığı, nitelikli yolun
  `undefined variable` verdiği görüldü. Dil yüzeyi (modül nesnesi değerleri) kararı gerektirir; kaydedildi, bu turda uygulanmadı.
- **`bind_text` NUL**: yukarıya bakın.
- Hızlı test koşusu / precheck sonuçları: bkz. CHANGELOG `[2.2.63]`.
