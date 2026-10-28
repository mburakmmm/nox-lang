# ADR-010 Güvenilmeyen kaynak: `noxc run --sandbox`

Durum: kabul (v2.0.43). Kapsam: TODO 7.2 ve 7.3.

## Karar

`noxc run --sandbox` derlenen ikiliyi işletim sistemi düzeyinde kısıtlanmış bir süreçte çalıştırır. Derleme güvenilirdir (kullanıcı kodu çalıştırmaz). Kısıt ikilinin çalışmasına uygulanır ve `extern def` ile `lowlevel` dahil tüm yerel kodu kapsar. `extern def`e "yarım güvenli mod" eklenmez; sınır işletim sistemidir.

Varsayılanlar: ağ yok; yazma yalnızca `$TMPDIR`; okuma sistem kitaplıkları, çalışma dizini, ikilinin dizini ve `$TMPDIR`. Ev dizini ve `/etc` okunamaz. Açma bayrakları: `--allow-net`, `--allow-write=DİZİN`, `--allow-read=DİZİN` (mutlak yol; tırnak, parantez ve ters bölü yok). Bayraklar `--sandbox` olmadan reddedilir.

Platformlar: macOS `sandbox-exec` (SBPL profili, `deny default`). Linux `bwrap` (bubblewrap): salt-okunur kök, yeni `/tmp`, `--unshare-net`. Windows desteklenmez. Araç yoksa ya da platform desteklenmiyorsa program çalıştırılmaz ve açık hata verilir: "sandbox istendi ama uygulanamadı" durumunda kısıtsız çalıştırmak güvenli değildir.

Ağ kapalıyken başlatıcı `NOX_SANDBOX_NO_NET=1` ayarlar. Zig'in `std.Io` katmanı beklenmeyen `EPERM`i programcı hatası sayıp süreci düşürdüğünden, `nox.http`, `nox.tls`, `nox.smtp` ve `nox.websocket` bağlanmadan önce bunu denetler ve reddi temiz bir bağlantı hatasına (`HttpError`, `TlsError`...) çevirir.

## Sınırlar

Bu bir capability sistemi değildir: eklenti `capability` bildirimleri hâlâ rıza meta verisidir ([Plugin API](../../apis/plugin-api.md)). Sandbox CPU, bellek ve süre sınırlamaz. Linux yolu birim testlidir ama CI'da gerçek `bwrap` ile çalıştırılmaz (GitHub runner'larında kullanıcı ad alanları kısıtlı olabilir).

## Reddedilen

`extern def` çağrılarını sarmalayan süreç içi filtre: yerel kod filtreyi atlar. Kapsayıcı imajı zorunluluğu: kurulum yükü; kapsayıcı kullanmak isteyen `docker run` ile `noxc run`ı zaten birleştirebilir.
