# Mobil toolchain

Sayılar bu makinede okundu. Uydurulmadı.

## Apple

Xcode 27.0 (build 27A266a). iPhoneOS SDK 27.0.

`iPhoneOS27.0.sdk/SDKSettings.plist`:

| Alan | Değer |
|---|---|
| MinimumDeploymentTarget | 15.0 |
| RecommendedDeploymentTarget | 17.0 |
| DefaultDeploymentTarget | 27.0 |

Derleyici `RecommendedDeploymentTarget` değerini kullanır: `17.0`. LLVM üçlüleri `arm64-apple-ios17.0` ve `arm64-apple-ios17.0-simulator`. SDK kökü `xcrun --sdk iphoneos|iphonesimulator --show-sdk-path` ile okunur.

## Android

Kurulu NDK: `28.2.13676358` (`darwin-x86_64` önderlemesi). Kurulu platformlar arasında `android-35` vardır.

| | |
|---|---|
| En düşük API | 24 |
| Hedef API | 35 |
| Sayfa | 16 KiB |

API 35, Android 15 ile gelen 16 KiB sayfa kuralının hedeflediği seviyedir. Üçlüler `aarch64-linux-android24` ve `x86_64-linux-android24`. Paylaşılan kütüphane `-Wl,-z,max-page-size=16384` ile bağlanır.

## Destek iddiası

Bu dört ad `experimental`dir. `supported` ancak o hedefin CI'si yeşilken yazılır. Stable cümlesi [matris](mobile-matrix.md) kapısı dolmadan kurulmaz.
