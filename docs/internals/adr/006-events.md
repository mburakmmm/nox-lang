# ADR-MOB-006 Olay kuyruğu

Durum: kabul. Kamuya açık başlık bu karardan sonra `include/nox_embed.h` oldu.

## Karar

`post_event` baytları kopyalar (en fazla 256, geçerli UTF-8). `pump` kullanıcı arayüzü iş parçacığındadır. Süre bütçesi 0 ise o andaki kuyruk boşalır; sıfırdan büyükse mutlak nanosaniye sonuna kadar sürer. Kullanıcı kodu içinden `start`, `pump` veya `destroy` `NOX_EMBED_ERR_REENTRANT` döner. `post_event` kuyruğa yazabilir. `destroy` ikinci çağrıda çökmez. Kapanıştan sonra olay `NOX_EMBED_ERR_STATE` döner.

## Reddedilen

Geri çağrı içinden serbest yeniden giriş. Geri alma: `in_user` bayrağını yok saymak.
