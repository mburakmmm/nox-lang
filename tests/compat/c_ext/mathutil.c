/* Nox'un `extern def` (C ABI FFI) uyumluluk testi için GERÇEK, minimal bir
 * C kütüphanesi (bkz. nox-teknik-spesifikasyon.md §3.20). Sistem `cc`siyle
 * sıradan bir nesne dosyasına (`mathutil.o`) derlenir ve `noxc`nin ürettiği
 * son bağlama komutuna doğrudan bir dosya yolu olarak eklenir — hiçbir
 * Nox/HPy'ye özgü ABI/başlık YOKTUR, tamamen sıradan bir C ABI fonksiyonu.
 */
long add_two(long a, long b)
{
    return a + b;
}
