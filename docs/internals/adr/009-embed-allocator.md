# ADR-MOB-009 Gömme ayırıcısı ve hata sözleşmesi

Durum: kabul (v2.0.32).

## Karar

`NoxHostConfig.size` düzeni ayırır; ABI numarası 1 kalır. Eski host `sizeof(NoxHostConfigV1)` verir ve sistem ayırıcısı kullanılır. Yeni host `sizeof(NoxHostConfig)` verir ve sonuna eklenen `allocator` alanını doldurur (`NULL` olabilir). Tanınmayan boyut `NOX_EMBED_ERR_VERSION` döner.

`NoxHostAllocator` iki geri çağrı taşır: `alloc(ctx, len, alignment)` hizalı bellek döner ya da `NULL`, `free(ctx, ptr, len, alignment)` aynı `len` ve `alignment` ile bırakır. Çalışma zamanının yönetilen heap'i (liste, sözlük, ARC nesneleri, `RuntimeState`) buradan ayrılır. Yerinde büyütme yoktur; çalışma zamanı yeniden ayırır. Hizasız dönen bellek reddedilir ve geri verilir. Ayırıcı iş parçacığı-güvenli olmalı ve `nox_app_destroy` dönene kadar yaşamalıdır. `nox.thread` çocukları ve havuz iş parçacıkları sistem ayırıcısını kullanır ([ADR-003](003-threads.md)).

Bellek yetersizliği: `nox_app_create` `NOX_EMBED_ERR_NOMEM` döner ve slota dokunmaz. `nox_app_start` host `alloc`ı `NULL` verirse `NOX_EMBED_ERR_NOMEM` döner; uygulama `created` kalır, host ayırıcıyı düzeltip `start`ı yeniden deneyebilir ya da `destroy` çağırabilir. Sızıntı olmaz.

Hata kodları: `NOX_EMBED_ERR_FULL` kuyruk doluyken `post_event` döner (olay kopyalanmaz, sonra yeniden denenir). Durdurulmuş uygulama `ERR_STATE` döner. `NOX_EMBED_ERR_EXCEPTION` giriş noktası veya olay işleyicisi dönerken bekleyen bir Nox istisnası olduğunu bildirir. Nesne bekleyen kalır; host `nox_exception_take` ile alır. `pump` bu durumda durur, kalan olaylar kuyrukta kalır.

## Reddedilen

Host ayırıcısını sürüm 2'ye taşıyıp ABI numarasını artırmak: eski host'ları kırar. Tüm çocuk çalışma zamanlarına host ayırıcısını yaymak: çağrıların hangi iş parçacığından geldiği host sözleşmesine eklenmeliydi; ayrı görev olarak açık.
