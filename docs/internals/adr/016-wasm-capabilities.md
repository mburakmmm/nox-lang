# ADR-016: WASM'da host yetenekleri ve derleme zamanı yetenek yasağı

Durum: kabul edildi (2026-11-04). Bağlam: [ADR-012](012-wasm-target.md) (hedef), [ADR-013](013-wasm-host.md) (`nox_host`).

## Karar

1. **Modüller WASM'da derlenir; yetenekler host'tan gelir.** Daha önce `nox.http` gibi modüller bir tabloyla (`WASM_UNAVAILABLE_MODULES`) derleme zamanında tamamen reddediliyordu. Bu, WASM'ı genel amaçlı bir hedef yapmayı engelliyordu: `router`, `web`, `reflect` ve `http` tipleri saf Nox'tur ve soketsiz de değerlidir (yönlendirme, handler testi, çerezler). Artık modül derlenir; yalnızca gerçek bir yetenek gerektiren çağrı (soket) host'a bağlıdır. Host yeteneği sağlamıyorsa çağrı anında yakalanabilir bir hata (`HttpCapabilityError`) fırlatılır.
2. **Çalışma zamanı sembolleri stub'lanır, imza birebir korunur.** `runtime/stdlib_shims/http_wasm.zig`, gerçek `http_client.zig`/`http_server.zig`/`http_stream.zig` sembollerinin her birini aynı imzayla ihraç eder ve "yetenek yok" döner (istemci: `error_kind = 4`; sunucu: tanı + null). `scripts/check_wasm_http_stubs.py` ad ve imza eşitliğini denetler (CI). Gerçek bir yetenek (ör. `fetch`) eklendiğinde stub'ın gövdesi bir `nox_host` import çağrısına bağlanır; Nox tarafı ve ABI değişmez.
3. **Derleme zamanı yasağı her hedefte.** `--deny-capability` / `NOX_DENY_CAPABILITY` denetleyicideki mevcut yetenek sınıflandırmasının (`MODULE_CAPABILITIES`, `@capability.requires`) üzerine bir "reddedilen küme" ekler. WASM'a özel değildir; güvenilmeyen kodu derleyen her ortam için (playground, CI sandbox) geçerlidir.
4. **İki katman.** Derleme zamanı yasağı (derleyici) ve host'un ilgili import'ları hiç vermemesi (çalışma zamanı) birbirinden bağımsızdır; biri atlansa diğeri korur.

## Neden ayrı bir ADR

Mevcut profil (`hosted`/`freestanding`) ve mobil maske sistemi, derlenen *hedefin* ne sağladığını tarif eder. WASM'da sağlayıcı derleme zamanında bilinmez (aynı `.wasm` Node'da, tarayıcıda ya da wasmtime'da çalışır), bu yüzden "sağlanıyor mu" sorusu çalışma zamanına kayar; derleme zamanı yalnızca *yasak* tarafını bilir.

## Sonuçlar

- `nox.http` ailesi 6 WASM hedefinin hepsinde derlenir ve fixture korpusu native ile aynı çıktıyı verir (yönlendirme, `web` yapı taşları, `reflect`, akışlı yanıt, istek hata yolları).
- Kalan reddedilen modüller (`tls`, `websocket`, `smtp`, `postgres`, `mysql`, `process`, `sharedmem`; `native`/`plugin`/`hpy` hiçbir zaman) aynı modele taşınacaktır (`sqlite` v2.0.146'da amalgamation'ın statik bağlanmasıyla eklendi): sanal dosya sistemi v2.0.147'de çalışma zamanının içinde (host import'u olmadan), `fetch` tabanlı HTTP istemcisi v2.0.149'da (yalnızca `--asyncify` freestanding; yetenek host'un `nox_host_caps_set` çağrısıyla açılır, varsayılan kapalı) eklendi; sırada WebSocket istemcisi.
- Playground: tarayıcıda derleyicinin ön yüzü çalışır ve üretilen modül `--deny-capability` ile derlenir.
