# ADR-MOB-003 İş parçacığı ve fiber

Durum: kabul. Mobil `async` tek iş parçacığındaki fiber zamanlayıcısında çalışır.

## Karar

`runtime/async_rt/swap_aarch64.S` x18'i ofset 168'de saklar ve geri yükler. Apple hedefinde kayıtlı dönüş adresi `xpaclri` ile ham adrese indirilir ve `ret` bu adrese döner. Çağıranın yığın çerçevesindeki imzalı dönüş adresine dokunulmaz. Kütüphane girişi mevcut runtime üzerinde `nox_async_init`, `nox_async_spawn` ve `nox_async_run_to_completion` çağırır; runtime'ı kendisi kurmaz veya yıkmaz. Havuz açılmaz. iOS arka planda sınırsız bir zamanlayıcı çalıştırmaz. Android süreç yeniden kurulunca host yeni bir slot açar; eski kuyruk taşınmaz.

## Reddedilen

Mobil `async`ı derleme hatası olarak bırakmak. GPU, kamera, konum, bildirim, push, derin bağlantı, satın alma, metin şekillendirme, emoji ve sağdan sola yerleşim bu kararın parçası değildir.
