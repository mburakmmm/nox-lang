# HTTP/3 (QUIC) tasarımı — TODO 5.4

Tarih: 2026-11-13. Kullanıcı kararları: kapsam = **istemci + sunucu**; QUIC katmanı = **OpenSSL >= 3.5 QUIC API'si (çalışma zamanında dlopen) + kendi HTTP/3 çerçevelemesi ve QPACK'ı**.

## Neden bu yol
- OpenSSL 3.5, QUIC sunucu (`SSL_new_listener`, `SSL_accept_connection`, `SSL_accept_stream`) ve istemciyi (`OSSL_QUIC_client_method`) tek API'de verir: TLS 1.3, kayıp kurtarma, akış kontrolü, bağlantı göçü OpenSSL'de. Biz yalnızca HTTP/3 çerçevelerini ve QPACK'ı yazarız.
- `tls_server.zig`/`sqlite.zig` ile aynı TEMBEL dlopen deseni: derleme-zamanı bağımlılığı yok; OpenSSL < 3.5 ise h3 "kullanılamıyor" der, HTTP/2 / HTTP/1.1 etkilenmez.
- Prototip (C, OpenSSL 3.5.9): dinleyici + istemci + çift yönlü akış, bloklamayan kip, `poll(SSL_get_rpoll_descriptor)` + `SSL_get_event_timeout` + `SSL_handle_events` döngüsüyle çalıştı.
- Reddedilenler: ngtcp2+nghttp3 (iki ek sistem kütüphanesi, çoğu makinede yok); tamamen kendi QUIC'imiz (RFC 9000/9001/9002 + TLS 1.3 el sıkışması, ~10 sürümlük iş ve kripto/kayıp-kurtarma riski).

## Eşzamanlılık kuralı (kritik)
Bir QUIC bağlantısının (ve akışlarının) TÜM OpenSSL çağrıları TEK sahip fiber'dadır; OpenSSL nesneleri eşzamanlı kullanılmaz. Bekleme `fiber_net.waitFd` ile reaktöre devredilir (fiber dışında `poll`). Sunucuda sahip fiber (motor) bağlantı başına pinlidir; handler fiber'ları OpenSSL'e dokunmaz, `h2`nin `Conn.lock` + kuyruk modeliyle motorla konuşur. Uyandırma: motor, kuyrukta bekleyen iş varken kısa (1 ms) zaman aşımıyla döner; boştayken `SSL_get_event_timeout` ile uyur.

## Aşamalar (her biri ayrı patch sürümü, iki backend'de golden)
- **H3.1 (v2.1.113)**: `runtime/stdlib_shims/quic.zig` — sembol yükleyici, `Ctx`, `Listener`, `Conn`, `Stream`, fiber-uyumlu `pump`; birim testleri: yerel istemci↔sunucu el sıkışması (ALPN h3) + akış yankısı + yanlış CA reddi. Test sertifikası: `runtime/stdlib_shims/testdata/quic_test_*.pem` (yalnızca test; EC P-256, 100 yıl).
- **H3.2**: `h3.zig` — HTTP/3 çerçeveleri (DATA/HEADERS/SETTINGS/GOAWAY), kontrol + QPACK tek yönlü akışları, QPACK kodlayıcı/çözücü (statik tablo + Huffman — `http2.zig`nin HPACK Huffman tablosu yeniden kullanılır; dinamik tablo kapasitesi 0), RFC 9204 ek vektörleri ile birim testleri.
- **H3.3**: sunucu — `nox.http.serve_h3(port, cert, key, handler)`: mevcut `HttpRequest`/`HttpResponse` ve akışlı yanıt yüzeyine bağlanır (`http_server.zig`de `h2` yanında `h3` akış tutamağı).
- **H3.4**: istemci — `nox.http` istemcisinde h3 seçeneği (`set_http3`), `Alt-Svc` ile terfi H3.5'e bırakılır.
- **H3.5**: dış uyumluluk (curl/aioquic ile; indirme izni gerekir), belge, Windows kararı.

## Kapsam dışı (şimdilik)
0-RTT, bağlantı göçü denetimi, WebTransport, QPACK dinamik tablo, Windows/wasm (`quic.supported` false), IPv6 (H3.1 yalnız IPv4; H3.3'te eklenir).
