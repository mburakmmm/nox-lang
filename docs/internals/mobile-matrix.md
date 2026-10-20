# Mobil destek matrisi

Hiçbir mobil hedef `supported` değildir. Stable kapısı aşağıdakilerin hepsi geçmeden açılmaz.

| Hedef | Derleme | Çalıştırma | Katman |
|---|---|---|---|
| ios-arm64 | statik arşiv, LLVM | cihaz laboratuvarı yok, yalnız derleme | experimental |
| ios-simulator-arm64 | statik arşiv, LLVM | simülatörde stdlib paketi ve Aura proof/notes/chat | experimental |
| android-arm64 | paylaşılan kütüphane, 16 KiB | arm64 emülatörde stdlib paketi ve Aura proof/notes/chat | experimental |
| android-x64 | paylaşılan kütüphane, 16 KiB | bağlandı, çalıştırılmadı | experimental |

`ios-simulator-x64` ve Android 32-bit bu tabloda yoktur. Metin şekillendirme, emoji ve sağdan sola yerleşim `not supported`.

`nox.os` argüman, ortam ve çalışma dizini okur; süreç başlatmaz. Süreç başlatma `nox.process` üzerindedir ve mobil maske onu vermez. `nox.base64` ve `nox.jwt` saf Nox olduğu için mobil hedefte geçerlidir. `nox.mysql` ve `nox.postgres` konak paylaşılan kütüphanesini açtığı için reddedilir. `nox.http` TLS sunucu çağrıları `libssl` açtığı için reddedilir. `nox.http` istemcisi, `nox.tls`, `nox.websocket` ve `nox.smtp` açık kalır. `async def`, `spawn` ve `await` mobil hedefte derlenir ve kütüphane girişinin iş parçacığındaki fiber zamanlayıcısında çalışır. WebSocket el sıkışması bu fiberin içinde çağrılırsa işletim sistemi iş parçacığına alınır.

Simülatörde `nox.tls` `example.com:443` el sıkışması `suite 0 pending 0` ile ölçüldü. Aynı paket `base64("foo") == "Zm9v"` ve HS256 doğrulamasını da içerir ve simülatörde yine `suite 0 pending 0` döndü. `android-arm64` emülatöründe aynı paket `suite 0 pending 0` döndü. Simülatör ve arm64 emülatör `mobile_runtime_probe` için `probe 0 pending 0` yazdı: `await spawn` toplamı 42, `nox.thread.start` sonucu 42, `wss://ws.postman-echo.com/raw` çerçevesi `nox`. `nox.smtp` bu ikiliye bağlandı; canlı SMTP oturumu açılmadı. DebugAllocator bir sızıntı satırı bastı ve sürecin çıkış kodunu değiştirmedi. `ios-arm64` ve `android-x64` Skia raster arşivleri bağlandı; bu dilimler çalıştırılmadı. `android-x64` `libnoxapp.so` `PT_LOAD` hizası 16384. Erişilebilirlik: VoiceOver açıkken `aura-ax 12`; arm64 emülatörde `uiautomator` dökümünde `Aura 0.3` ve `Noto Sans` etiketleri var. Emülatör yatay konumda `aura-resize 914.2857 411.42856` ve yeni `aura-frame` yazdı. `am send-trim-memory RUNNING_CRITICAL` `aura-memory 15` yazdı. iOS yaşam döngüsü `aura-background` sonrası yeni `aura-frame` yazdı. Açık iPhone simülatörünün tek ekran kipi dikeydir; yatay geometri reddedildi. iOS bellek uyarısı geri çağrısı bağlıdır, sistem enjekte etmedi.

## Stable kapısı

Kapı, imzalı IPA ve AAB, 16 KiB ölçümü, simülatör ve emülatörde aynı Counter, Notes ve Chat kaynakları, erişilebilirlik, bellek baskısı ve yaşam döngüsü kanıtı durunca kapanır. Kanıt `mobile-evidence/` altındadır. İşler `|| true` ile yeşile zorlanmaz. Mağaza imza anahtarı depoya girmez.
