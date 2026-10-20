# ADR-MOB-002 Hedef adları

Durum: kabul. Dört ad birleşmez.

## Karar

`ios-arm64`, `ios-simulator-arm64`, `android-arm64`, `android-x64`. Üçlüler, sayfa boyu ve önerilen dağıtım sürümü [toolchain](../mobile-toolchain.md) belgesindedir. `ios-simulator-x64` ve Android 32-bit yoktur.

## Reddedilen

Tek bir `ios` veya `android` adı. Simülatör dilimi cihaz dilimi diye paketlenmez. Geri alma: `hostedTargetInfo` kayıtlarını silmek masaüstü hedeflerini bırakır.
