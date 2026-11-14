# Açık işler — tek temiz liste (2026-11-14, v2.1.147 sonrası)

`project/yapilacaklar-2026-11.md`, `project/nox-ana-todo.md`, `project/v2-hazirlik-yol-haritasi.md`, `project/limitasyon-kaydi-2026-11.md` ve `project/aura-mobil-eksiklikleri.md` taranarak çıkarıldı.
Bu dosya yalnızca **açık** işleri tutar; biten işlerin kaydı eski listelerde kalır. Bir iş bitince buradaki kutu `[x]` yapılır ve sürümü yazılır.

Durum: `[ ]` açık · `[?]` kayıtta açık görünüyor ama bayat olabilir, önce doğrulanmalı · `[K]` kullanıcı kararı/eylemi gerekir.
Önceliğe göre sıralıdır: **A** önce, **B** sonra, **C** 2.2 ve sonrası, **D** ayrı proje.

Bu listede olmayanlar: `v2-hazirlik-yol-haritasi.md` (37/37 bitti), `limitasyon-kaydi-2026-11.md` (36/36 bitti), `yapilacaklar-2026-11.md` içindeki Windows maddeleri 6.1–6.8 ve 9.14 (bitti, v2.1.143–147).

---

## A. Engeller (önce bunlar)

- [ ] **A1. Linux (x86-64) CI askısı.** `ci.yml`'in "Linux (x86-64)" işi v2.1.132'den beri 75 dakikalık zaman aşımına kadar askıda kalıyor; ana CI her koşuda "cancelled". Gözcü v2.1.144'te düzeltildi; v2.1.144 koşusunun günlüğü koşu bitince `gh run view 43585571081 --job <Linux x86-64> --log | grep GÖZCÜ` ile okunacak. WSL2'de (4 CPU, CI ortamını taklit eden) tam koşu 12 dakikada EXIT 0 verdi, askı yerelde üretilemedi. Kök neden bulunana kadar A2 kapanmaz.
- [ ] **A2. (7.7) `Release` iş akışı CI kırmızıyken yayın üretmiyor.** v2.1.135'ten beri (A1 yüzünden) GitHub Release yok. A1 kapanınca kendiliğinden düzelir; düzelmezse iş akışının "CI durumu kontrolü" adımı gözden geçirilir. Eski sürümleri yeniden yayınlamaya gerek yok (kullanıcı kararı 2026-11-14).
- [K] **A3. (7.6) `Snap package` iş akışı "unable to contact snap store".** Snap Store kimlik bilgisi/ağ ayarı kullanıcıda kontrol edilmeli; kodda yapılacak bir şey yok.
- [K] **A4. (7.1) Site arka ucunun sürüm seçimi düzeltmesini M4'e canlıya alma** (`services/noxlang-site/main.nox`). Canlı dağıtım kullanıcı onayı ister.

## B. Geliştirme işleri (yapılabilir, tasarım kararı gerekmeyen/az gerektiren)

- [x] **B1. (11.10)** v2.1.149: kök neden bulundu (ikilisiz eski girdi yeniden kullanılırken `used` işaretçisi geç yazılıyordu, başka sürecin `prune`u siliyordu); işaretçi artık hemen yazılır + regresyon testi.
- [x] **B2. (6.5)** v2.1.149: `docs/internals/wasm-coverage.md` gerçek motorla (MVP, çok değerli, sign-ext, doymalı, bulk, reftypes, SIMD, threads) yeniden yazıldı; kayıt bayattı.
- [x] **B3. (7.5)** v2.1.149: NNI API fuzz (`alloc(0)` çökmesi düzeltildi) + Plugin API manifest fuzz golden (JSON hatası/yanlış tipler PluginError olur). HPy sınırı v2.0.46'dan fuzz'lıydı.
- [~] **B4. (7.4)** Tasarım yazıldı: `project/registry-guvenlik-tasarimi-2026-11.md` (S1 SBOM → S2 yayıncı anahtarı/imza → S3 tarama etiketleri). **Karar bekliyor:** §4'teki 4 soru.
- [K] **B5. (4.6) Kanıt zinciri: Aura commit'i ve toolchain alanlarının zorunluluğu.** Aura deposu ayrı olduğundan D bölümüne taşındı; Nox tarafı v2.0.38'de tamam.
- [~] **B6. (4.6)** Tasarım yazıldı: `project/wasm-threads-tasarimi-2026-11.md` (wasi-threads uyumlu, örnek-başına OS iş parçacığı, gerçek wait/notify). **Karar bekliyor:** §6'daki 4 soru.
- [ ] **B7. (9.15) WASM varsayılan kotaları çok-kiracılı kullanım için gevşek.** İzleme maddesi; sıkı hazır ayar + capability sınırları W2/W3 ile (Nexus). Çok-kiracılı kullanım gündeme gelince.
- [ ] **B8. M:N: başlamış fiber, başladığı işçiye bağlı.** Bloklayan FFI'da işçi büyütme (v2.1.142) yalnızca başlamamış görevleri kurtarır; başlamış bir fiber bloklanmış işçide beklemeye devam eder. Tam çözüm = preemption / fiber göçü. **Kullanıcı kararıyla ertelendi** (2026-11-13/14); gündeme gelince yeniden sorulacak.

## C. 2.2 ve sonrası (kullanıcı kararıyla ertelendi)

- [ ] **C1. (11.7) REPL — LLVM ORC JIT.** `noxc` LLVM'e bağlı değil; libLLVM'i çalışma anında tembel yükleme, `noxrt.o`yu JIT'e nesne olarak ekleme, satırlar arası durum için modül-global + ARC. iOS'ta JIT yasak → yalnızca masaüstü. Önce spike + tasarım onayı.
- [ ] **C2. (11.8) C FFI maliyetini sıfıra yaklaştır / C kütüphanelerini Nox'ta çalıştır.** Önce mevcut maliyetin ölçümü ve tasarım seçenekleri. AGENTS §9.5 güven sınırı geçerli: sandbox/"güvenli mod" kapsamlı güvenlik tasarımı gerektirir, yarım eklenmez.
- [x] **C3. (1.11)** v2.1.151: aarch64 + riscv64 QEMU `virt` boot zincirleri + test + belge.
- [x] **C4. (5.1/5.2)** bindgen F4/F4b/F5 ve `@dataclass`/`@derive` bitti; yapilacaklar bölüm 8'de açık madde yok. Derleme zamanı sabitleri ve kullanıcı makroları kapsam dışı (kullanıcı kararı 2026-11-13).
- [ ] **C5. (7.3) `list[Task[T]]`.** Bilinçli desteklenmiyor, hata `TaskGroup`'a yönlendirir. Değişmedi; yalnızca tasarım kararıyla.
- [ ] **C6. Preemption** (B8 ile aynı konu). Kullanıcı "şimdilik gerekmez" dedi.

## D. Mobil / Aura (ayrı depo, ayrı proje)

`project/aura-mobil-eksiklikleri.md`: 66 açık, 2 kapalı madde. Bunlar Aura deposunun işi; Nox tarafında ilgili kalemler:
- [ ] **D1. (3.5) Fiber/TLS/stack doğrulaması:** arm64e işaretçi doğrulaması (fiziksel cihaz), iş parçacığı-yerel yıkıcıların gözlemlenebilir doğrulaması, fiziksel hedefler.
- [ ] **D2. (4.4) Android 16 KiB sayfa:** fiziksel cihaz, imzalı AAB, bağımlı üçüncü-taraf `.so`lar.
- [ ] **D3. Aura mobil kabul listesi** (iOS simulator + fiziksel iPhone, Android x64 emulator + ARM64 cihaz, IME/clipboard/erişilebilirlik, signed IPA/AAB, `aura doctor/create/run/build`, CI kapıları). Fiziksel cihaz ve mağaza hesabı gerektirir; Aura'nın kendi planına bırakıldı.

## E. Temizlik (iş bitince)

- [ ] **E1.** PC'de WSL dağıtımı: `wsl --unregister nox-ubuntu`; `C:\nox-dev\wsl` sil.
- [ ] **E2.** PC'de indirilenler: `C:\nox-dev\openssl`, `C:\nox-dev\openssl-ucrt` sil.
- [K] **E3.** PC'de `C:\nox-dev` ve `noxdev` kullanıcısı (`net user noxdev /delete`) — kullanıcı yapar. A1 çözülene kadar WSL ve OpenSSL klasörleri durur (gerekebilir).
- [ ] **E4.** Mac scratchpad'deki geçici dosyalar (`zigwin/`, `qbe-src/`, `*.log`, `/tmp/nox_*.tgz`).

---

## Önerilen sıra

1. **A1** (askı) → A2 kendiliğinden kapanır. Bu çözülmeden Release akışı çalışmıyor.
2. **B1** (önbellek yarışı; küçük, güvenli) ve **B2–B5** doğrulamaları (çoğu muhtemelen sadece kayıt güncellemesi).
3. **C3** için kullanıcıya soru (QEMU aarch64/riscv64).
4. **B6** için kullanıcıya soru (WASM çok iş parçacıklı API).
5. C1/C2 (REPL, C FFI maliyeti) 2.2 planlamasıyla.
