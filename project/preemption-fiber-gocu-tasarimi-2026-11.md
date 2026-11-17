# 6.2 Preemption / fiber göçü — inceleme ve karar (2026-11-17)

Durum: **ŞİMDİ UYGULANMADI** (bağımlılık: 5.4). Bu belge neden, ve hangi sırayla yapılması gerektiğini kaydeder.

## Sorun (B8)

Bir işçi (OS iş parçacığı) bloklayan bir C çağrısına (`extern def`, sqlite, libpq...) girince, o işçiye ait **başlamış ve hazır** fiber'lar ilerleyemez. v2.1.142 izleyicisi yeni işçi açar ve yalnız **hiç başlamamış** görevleri (kuyruktaki `spawn`lar) çalar (`Scheduler.tryStealFromSiblings`; "başlamış fiber kalıcı olarak çalındığı işçiye sabitlenir", `markReady`nin `owner_tid` denetimi).

## Neden "başlamış fiber'ı başka işçide sürdürmek" bugün güvenli değil

1. **Modül-düzeyi değişkenler işçi başına kopyadır** (`docs/language/modules.md`). Bir fiber işçi A'nın kopyasına yazıp B'ye göçerse B'nin kopyasını okur: kayıp güncelleme, gözlenebilir davranış değişikliği. Değişken modül durumu olan programlar zaten tek işçiye sabitlenir (`pin_single_worker`; yalnız skaler+dict dilimi paylaşılan, bkz. 5.4). Ayrıca açık hata **1.7** (çalınan fiber modül-global okurken ilklenmemiş bellek) aynı alana dokunur.
2. **Thread-local durum**: çalışma zamanında ~50 `threadlocal`/`TlsSlot` bildirimi var (`asap.setWorkerSlot` işçi yuvası dahil). Askıya alınabilen çalışma zamanı işlevleri bir TLS adresini askı noktası boyunca saklıyorsa (derleyici bunu serbestçe yapabilir) göç eden fiber başka iş parçacığının TLS'ini görür. Askı noktası içeren her yol ayrıca denetlenmeli (bloklayan `extern`i saran Zig işlevleri öncelikli).
3. **Preemption (zamanlayıcı sinyaliyle kesme)** bu çalışma zamanı için uygun değil: ARC/atomik olmayan ASAP yığını/arena ve yeniden girişsiz çalışma zamanı işlevleri bir fiber'ı herhangi bir yerde kesmeyi güvensiz kılar. Önerilmez.

## Önerilen tasarım (5.4 bittikten sonra)

"Zamanlayıcı devri" (Go'daki P devrine benzer), fiber göçü değil:

- Bloklayan FFI'a girişte işçi "FFI içinde" işaretlenir (izleyici bunu zaten ölçüyor).
- Süre dolunca **zamanlayıcı rolü** (hazır kuyruk, deque, G/Ç reaktörü) yeni bir OS iş parçacığına devredilir; bloklu iş parçacığı yalnızca o tek fiber'ın yığınında kalır.
- FFI dönünce fiber `markReady` yabancı yolu (zaten var) ile sahibi zamanlayıcının kuyruğuna girer; eski iş parçacığı fiber'dan çıkıp boşa düşer.
- Önkoşullar: (a) modül-düzeyi durum tüm işçilerde tek kopya (5.4 tam), (b) TLS denetimi (yukarıda 2), (c) 1.7 kapalı.

## Karar

5.4 (kalan dilimler: liste, sınıf) ve 1.7 bitmeden 6.2'ye başlanmaz; 5.4 mimari karar gerektirir ve evdeki Windows oturumunda 5'lerle birlikte ele alınacak (kullanıcı sırası: 6.2 → 3.9 → 3.8 → 4.5, sonra 5). 3.8a (sert iptal / yalıtım) bu işe bağlıdır: kooperatif iptal tasarım gereği kalır.
