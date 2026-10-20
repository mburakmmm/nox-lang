# ADR-MOB-001 Kütüphane modeli

Durum: kabul. Mobil hedef bir yürütülebilir dosya üretmez.

## Karar

Host bir `NoxEmbedSlot` sahiplenir. Yaşam döngüsü `create`, `start`, `pump`, `request_stop`, `destroy` sırasıdır. Aynı slotta ikinci `create` `NOX_EMBED_ERR_EXISTS` döner. Süreç genelinde gizli bir uygulama örneği yoktur. Kütüphane modu `$main` üretmez; kullanıcı programı `$nox_embed_user_entry` olur ve çalışma zamanını kendisi başlatmaz.

`nox_embed_bind`, Nox kütüphanesinin tanımladığı semboldür. Host onu `start` öncesinde çağırır. Çalışma zamanı bu sembolü tanımlamaz.

## Reddedilen

Tek süreç-geneli `NoxApp` değişkeni. Geri alma: slot alanını silip eski `main` yoluna dönmek. Masaüstü `main` bu karardan etkilenmez.
