#!/bin/sh
# TODO 4.1/4.5: Android emülatöründe (CI: Linux x86_64 + KVM, `reactivecircus/android-emulator-runner`) çalıştırma korpusu.
#   scripts/mobile_android_ci.sh smoke   PR: stdlib paketi + çalışma zamanı probe'u + yığın/iş parçacığı probe'u
#   scripts/mobile_android_ci.sh full    gece: smoke + ağ matrisi + sandbox/disk-dolu + saat/entropi/log
# NOX_ANDROID_ABI=arm64|x64 hedef ABI'yi seçer (CI'da x64, yerelde arm64). Her adım bağımsız çalışır; başarısız adım sayısı > 0 ise 1 ile çıkar, böylece tek bir
# kırmızı adım geri kalan korpusu gizlemez. Bekçi: her adım `timeout` ile sınırlıdır (takılan bir emülatör işi sonsuza dek tutamaz). Temizlik: çıkışta
# `adb reverse` kuralları ve cihazdaki /data/local/tmp/nox-* artıkları silinir; emülatörün kendisini çağıran iş akışı kapatır.
set -u
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
mode=${1:-smoke}
case "$mode" in smoke | full) ;; *) echo "kullanım: $0 smoke|full" >&2; exit 2 ;; esac
adb=${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}
export ADB=$adb
step_timeout=${STEP_TIMEOUT:-900}
fail=0
abi=${NOX_ANDROID_ABI:-arm64}

cleanup() {
  "$adb" reverse --remove-all >/dev/null 2>&1
  "$adb" shell 'rm -rf /data/local/tmp/nox-*' >/dev/null 2>&1
  true
}
trap cleanup EXIT

# `timeout` (GNU) ya da `gtimeout` (macOS brew) yoksa sınırsız çalıştırır.
tmo=$(command -v timeout || command -v gtimeout || true)
run_step() {
  name=$1; shift
  echo "::group::$name ($abi)"
  start=$(date +%s)
  if [ -n "$tmo" ]; then "$tmo" "$step_timeout" "$@"; else "$@"; fi
  rc=$?
  echo "::endgroup::"
  if [ $rc -eq 0 ]; then echo "ok   $name ($(( $(date +%s) - start )) sn)"; else echo "FAIL $name (çıkış $rc, $(( $(date +%s) - start )) sn)"; fail=$((fail + 1)); fi
}

"$adb" wait-for-device
"$adb" shell 'while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done'
echo "cihaz: $("$adb" shell getprop ro.product.cpu.abi | tr -d '\r') api $("$adb" shell getprop ro.build.version.sdk | tr -d '\r') sayfa $("$adb" shell getconf PAGE_SIZE | tr -d '\r')"

run_step "stdlib paketi + çalışma zamanı probe'u" "$root/scripts/mobile_android_run.sh"
run_step "yığın ve iş parçacığı probe'u" "$root/scripts/mobile_stack_probe.sh" android
if [ "$mode" = full ]; then
  run_step "ağ matrisi" "$root/scripts/mobile_network_probe.sh" android
  run_step "sandbox ve disk-dolu probe'u" "$root/scripts/mobile_sandbox_probe.sh" android
  run_step "saat, entropi ve log probe'u" "$root/scripts/mobile_clock_probe.sh" android
fi
echo "başarısız adım: $fail"
[ $fail -eq 0 ]
