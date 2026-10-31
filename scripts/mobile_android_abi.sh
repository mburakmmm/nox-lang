# Kaynak olarak yüklenir (`. scripts/mobile_android_abi.sh`): NOX_ANDROID_ABI=arm64 (varsayılan) | x64 için noxc hedef adı, clang üçlüsü ve çalışma zamanı nesnesi.
abi=${NOX_ANDROID_ABI:-arm64}
case "$abi" in
  arm64) android_triple=aarch64-linux-android24 ;;
  x64) android_triple=x86_64-linux-android24 ;;
  *) echo "NOX_ANDROID_ABI: arm64 | x64 (verilen: $abi)" >&2; exit 2 ;;
esac
android_target=android-$abi
android_rt="$root/zig-out/lib/noxrt-android-$abi.o"

# NOX_ANDROID_SANITIZE=address: host + çalışma zamanı AddressSanitizer ile bağlanır (NDK'nin `libclang_rt.asan-<arch>-android.so`su cihaza itilir). Android'de sızıntı
# denetimi (LSan) desteklenmez; yığın/küme taşması, serbest bırakıldıktan sonra kullanma ve çift serbest bırakma yakalanır. Çıktı: `android_cflags` (derleme+bağlama),
# `android_env` (cihazda komut öneki). `android_san_push <ndk> <adb>` gerekli çalışma zamanını cihaza koyar.
android_cflags=""
android_env=""
if [ -n "${NOX_ANDROID_SANITIZE:-}" ]; then
  android_cflags="-fsanitize=$NOX_ANDROID_SANITIZE -fno-omit-frame-pointer"
  android_env="LD_LIBRARY_PATH=/data/local/tmp ASAN_OPTIONS=detect_leaks=0:abort_on_error=0"
fi
android_san_push() {
  [ -n "$android_cflags" ] || return 0
  case "$abi" in arm64) arch=aarch64 ;; x64) arch=x86_64 ;; esac
  so=$(find "$1/toolchains/llvm/prebuilt" -name "libclang_rt.asan-$arch-android.so" | head -1)
  [ -n "$so" ] || { echo "ASan çalışma zamanı NDK'de yok" >&2; exit 1; }
  "$2" push "$so" /data/local/tmp/ >/dev/null
}
