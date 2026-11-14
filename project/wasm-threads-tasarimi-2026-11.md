# nox.wasm gerçek çok iş parçacıklı çalışma — API/host tasarımı (TODO 4.6) — taslak, onay bekliyor

Durum: **TASARIM; kod yazılmadı.** Kullanıcı kararı (2026-11-14): "tasarım öner".

## 1. Bugünkü durum (doğrulanmış)

`runtime/wasm_bridge/atomics.zig`: threads önerisinin tüm atomik komutları ve **paylaşımlı bellek** (limits bayrağı 0x03) çalışır, ama bir `Instance` **tek iş parçacığında** koşar; atomikler sıradan okuma/yazmadır. Sonuçlar: `notify` her zaman 0 uyandırır; `wait` değer farklıysa 1, zaman aşımı ≥ 0 ise (uyumadan) 2 döner, sonsuz bekleme tuzak olur; paylaşımlı olmayan bellekte `wait` tuzak. Gerçek paralellik yok (`docs/stdlib/wasm.md`, "Threads").

## 2. Hedefler / hedef dışı

Hedef: bir modülün (ör. `wasm32-wasi-threads` ile derlenmiş Rust/C++) **birden çok OS iş parçacığında, tek bir paylaşımlı bellek üzerinde** çalışabilmesi; gerçek `memory.atomic.wait/notify`; fuel ve bellek sınırlarının iş parçacığı başına/toplam uygulanması; İlke 4 (opak tutamaç): Nox hiçbir zaman ham bellek göstericisi almaz.
Hedef dışı: WASM'ın "thread" kavramı tanımlamaması gerçeği (host sağlar) gereği özel bir iş parçacığı ABI'si icat etmek — **wasi-threads** sözleşmesine uyulur.

## 3. Önerilen model: wasi-threads uyumlu, örnek-başına iş parçacığı

- Spec'te thread yaratma yoktur; **wasi-threads** (`wasi:thread-spawn`, import `wasi` / `thread-spawn(start_arg: i32) -> i32`; yeni iş parçacığı modülün `wasi_thread_start(tid: i32, start_arg: i32)` export'unu çağırır) fiili standarttır (wasi-libc `pthread_create`).
- **Her WASM iş parçacığı kendi `Instance` yürütme durumuna** (operand yığını, çerçeveler, fuel sayacı) sahiptir; **bellek ve tablolar paylaşılır**, globaller (mutable) için spec'e göre her örnekte ayrı değil modül örneğinin parçasıdır (paylaşımlı olmayan mutable global'lerde wasi-threads, derleyicinin TLS'i bellekte tutmasını bekler → global'ler örnek-başına kopya).
- **Bellek:** paylaşımlı lineer bellek bir kez ayrılır (`max_pages` sınırlı, taşınmaz: `memory.grow` paylaşımlı bellekte maks. sayfaya önceden ayrılmış sanal alan içinde atomik uzatma). Çalışma zamanı, tüm erişimleri iş parçacığı güvenli yapar: `atomic.*` komutları gerçek donanım atomikleri; normal `load/store` bölünmesiz tek erişim (spec: yarış tanımlı ama bellek-güvenli sonuç).
- **wait/notify:** adres-anahtarlı park tablosu (futex benzeri): `wait32/64` değeri karşılaştırıp gerçek uyur (zaman aşımı ns), `notify` n bekleyeni uyandırır. Park tablosu paylaşımlı bellek nesnesine aittir.
- **Nox tarafı API (nox.wasm):**
  - `open_with_limits(path, fuel, max_pages)` aynı kalır; yeni: `h.enable_threads(max_threads)` (WASI gibi **opt-in**; varsayılan kapalı → bugünkü davranış korunur) ve `Instance.thread_count()`.
  - `thread-spawn` host import'u yalnızca `enable_threads` ile bağlanır; sınır aşılırsa `-1` döner (wasi-threads hata sözleşmesi).
  - `Instance.close()` tüm iş parçacıklarını **iptal eder** (paylaşımlı `cancel` bayrağı fuel kontrolünde izlenir) ve birleştirir; sıfırdan kapanış garantisi (sızıntı/asılı iş parçacığı yok).
  - Nox değerleri iş parçacığı sınırını **geçmez**: host fonksiyonları (imports) yalnız "ana" iş parçacığından çağrılabilir; diğerlerinde çağrı `Trap` (veya host-izin-listesi ile seri kuyruk: sonraki aşama).
- **Zamanlama:** her WASM iş parçacığı bir OS iş parçacığıdır (`std.Thread`); M:N havuzuna bağlanmaz (bloklayan `wait` işçi havuzunu kilitlerdi; v2.1.142'deki işçi büyütme izleyicisi yalnızca Nox fiber'ları içindir).
- **Fuel/sandbox:** fuel iş parçacığı başına + toplam tavan; `max_pages`, `max_threads`, duvar-saati zaman aşımı; iptal sinyali (§ close). Sandbox özellikleri (dosya/ağ yok) aynen geçerli.

## 4. Doğrulama planı

Node (V8) farksal testleri: gerçek `wasm32-wasi-threads` C programı (mutex/atomik sayaç/`pthread_join`) hem Node `worker_threads` + `SharedArrayBuffer` hem Nox ile aynı sonucu vermeli; atomik RMW stres (8 iş parçacığı × 1e6); wait/notify ping-pong; iptal/close sızıntı testi (GPA safety); fuzz: rastgele `wait/notify/grow` dizileri; TSan koşusu (`-Dsanitize-thread`, v2.1.138 altyapısı).

## 5. Riskler

- Yorumlayıcının iç yapıları (`vstack`, sıcak döngü) şimdi tek iş parçacıklı varsayar; paylaşımlı bellek erişim yolu atomik/ayrı opcode'larla ayrılmalı, **paylaşımsız modüllerin hızı değişmemeli** (SIMD'deki gibi ayrı iç opcode).
- `memory.grow` paylaşımlı bellekte yarış → önceden ayrılmış maks. adres alanı (mmap) gerekir (iOS/Android'de büyük sanal alan sınırları; `max_pages` küçük tutulur).
- Fuel sayacı paylaşımlı/atomik olursa sıcak yolu yavaşlatır → iş parçacığı-yerel sayaç + periyodik toplu çekme.

## 6. Verilmesi gereken kararlar

1. **wasi-threads** sözleşmesi mi (öneri), yoksa Nox'a özgü `Instance.spawn_thread(export, arg)` mi?
2. Host import'ları (WASI, kullanıcı import'ları) iş parçacıklarından çağrılabilsin mi (öneri: ilk sürümde hayır → Trap)?
3. Hedef platformlar: masaüstü (macOS/Linux/Windows) evet; **iOS/Android** (sanal alan/iş parçacığı sınırları) ilk sürümde kapalı mı (öneri: kapalı, `enable_threads` hata verir)?
4. Önce yalnız gerçek wait/notify + el ile `spawn` (daha küçük adım) mi, yoksa tam wasi-threads mi?
