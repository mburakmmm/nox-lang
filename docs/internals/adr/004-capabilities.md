# ADR-MOB-004 Yetenek maskesi

Durum: kabul. Üçüncü bir profil yoktur.

## Karar

Mobil hedef `hosted` üzerinde bir maskedir. Maske `process`, `shared_memory` ve `dynamic_code` vermez. `nox.process`, `nox.sharedmem`, `nox.native`, `nox.plugin` ve `nox.hpy` bu yüzden derleme hatasıdır. Bilinmeyen bir `nox.*` modülü de reddedilir.

`nox.fs` ve `nox.sqlite` yalnızca hostun verdiği `documents`, `support`, `cache` ve `temp` köklerinin altında yol kabul eder. `..` reddedilir. Kökler hostun ödünç verdiği dizelerdir. Masaüstünde gömme oturumu yoktur; mevcut çağrılar aynı kalır. HTTPS tarafında sertifika doğrulamasını kapatan bir stdlib anahtarı yoktur. Anahtar zinciri ve Keystore host hizmetidir.

## Reddedilen

`extern def` içine yeni bir sandbox koymak. Geri alma: `Checker.mobile_mask` varsayılan `.none` kalır.
