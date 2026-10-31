# Kaynak olarak yüklenir (`. scripts/mobile_android_abi.sh`): NOX_ANDROID_ABI=arm64 (varsayılan) | x64 için noxc hedef adı, clang üçlüsü ve çalışma zamanı nesnesi.
abi=${NOX_ANDROID_ABI:-arm64}
case "$abi" in
  arm64) android_triple=aarch64-linux-android24 ;;
  x64) android_triple=x86_64-linux-android24 ;;
  *) echo "NOX_ANDROID_ABI: arm64 | x64 (verilen: $abi)" >&2; exit 2 ;;
esac
android_target=android-$abi
android_rt="$root/zig-out/lib/noxrt-android-$abi.o"
