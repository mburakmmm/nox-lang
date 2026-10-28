# ADR-011 `nox.lock` imzalama

Durum: kabul (v2.0.43). Kapsam: TODO 7.1.

## Karar

Yayıncı bir Ed25519 anahtar çifti üretir (`noxc sign keygen <ad>`: gizli tohum `$NOX_HOME/keys/<ad>.key`, kip 0600, asla üzerine yazılmaz; açık anahtar `<ad>.pub`). `noxc sign lock --key <ad> [dizin]` `nox.lock` baytlarının SHA-256'sını `"nox-lock-v1\n"` alan ayracıyla imzalar ve ayrık `nox.lock.sig` yazar (`nox-sig-v1`, `signer=<parmak izi>`, `sig=<128 hex>`). Parmak izi, açık anahtarın SHA-256'sının ilk 16 baytıdır (32 hex).

Tüketici güven kökünü kendi makinesinde tutar: `noxc sign trust <pub-dosyası>` anahtarı `$NOX_HOME/trusted/<parmak izi>.pub` altına koyar. Otomatik ilk-kullanımda-güven (TOFU) yoktur; güven açık bir komutla verilir, parmak izi yayıncıyla başka bir kanaldan doğrulanmalıdır. `noxc sign verify [dizin]` çevrimdışı doğrular ve yalnızca geçerli imzada 0 döner. İptal: `noxc sign revoke <parmak izi>` parmak izini `$NOX_HOME/revoked.txt`e ekler; iptal her zaman güvenden önce gelir.

Anahtar yenileme: yeni anahtarı güvenilir ilan et, eskisini iptal et, kilidi yeni anahtarla yeniden imzala.

## Sınırlar

Bu, imzanın var olduğunu ve kilit dosyasının imzadan sonra değişmediğini kanıtlar; paketin kodunun iyi niyetli olduğunu kanıtlamaz. `noxc fetch`/`add` imzayı henüz otomatik zorunlu kılmaz ve noxpkg sunucusu yayıncı anahtarını hesaba bağlamaz; ikisi sonraki adımdır (hesap altyapısı v2.0.28'den beri var). İptal listesi yerel bir dosyadır, bir dağıtım kanalı değildir.

## Reddedilen

Merkezi kök anahtar: tek hata noktası ve anahtar saklama sorumluluğu. İmzayı `nox.lock` içine gömmek: imzalanan baytlar imzayı içerirdi; ayrık dosya bunu önler.
