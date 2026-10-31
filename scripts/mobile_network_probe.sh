#!/bin/sh
# TODO 3.8: mobil ağ matrisi. Senaryo sunucuları (scripts/mobile_net_servers.py) Mac'te çalışır; istemci GERÇEK hedefte çalışır:
#   scripts/mobile_network_probe.sh ios <UDID>      iOS simülatörü (Mac ağını paylaşır)
#   scripts/mobile_network_probe.sh android         android-arm64 emülatörü (`adb reverse`; çevrimdışı/ağ değişimi için uçak modu)
# Matris: DNS (IPv4, IPv6 literal, çift yığın ad, çözülemeyen ad), bağlantı reddi/sıfırlama, boşta zaman aşımı, bağlanma zaman aşımı (kara delik adres),
# kesik gövde, TLS sertifika reddi, çevrimdışı ve ağ değişimi (yalnızca Android), arka plana alma/geri dönme (SIGSTOP/SIGCONT).
# Her senaryo: beklenen belirteç + üst süre sınırı. Çıkış kodu: başarısız senaryo sayısı > 0 ise 1.
set -u
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
platform=${1:?android | ios <UDID>}
noxc=${NOXC:-"$root/zig-out/bin/noxc"}
work=/tmp/nox-net-probe
rm -rf "$work"; mkdir -p "$work"
fail=0

python3 "$root/scripts/mobile_net_servers.py" --ports-file "$work/ports.json" >"$work/servers.log" 2>&1 &
servers=$!
trap 'kill $servers 2>/dev/null; [ "$platform" = android ] && "$adb" reverse --remove-all >/dev/null 2>&1; true' EXIT
i=0; while [ ! -s "$work/ports.json" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done
port() { python3 -c "import json,sys;print(json.load(open('$work/ports.json'))['$1'])"; }
P_OK4=$(port ok4); P_OK6=$(port ok6); P_SILENT=$(port silent); P_TRUNC=$(port trunc); P_RESET=$(port reset); P_DRIP=$(port drip); P_TLS=$(port tls); P_CLOSED=$(port closed)

case "$platform" in
android)
  rt="$root/zig-out/lib/noxrt-android-arm64.o"
  sdk=${ANDROID_HOME:-"$HOME/Library/Android/sdk"}
  adb=${ADB:-"$sdk/platform-tools/adb"}
  ndk=${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-"$sdk/ndk/$(ls -1 "$sdk/ndk" | tail -n 1)"}}
  clang=""; for h in darwin-arm64 darwin-x86_64 linux-x86_64 linux-aarch64; do c="$ndk/toolchains/llvm/prebuilt/$h/bin/clang"; [ -x "$c" ] && { clang=$c; break; }; done
  [ -n "$clang" ] && [ -f "$rt" ] || { echo "NDK clang ya da android çalışma zamanı yok" >&2; exit 1; }
  "$adb" devices | awk 'NR>1 && $2=="device" {f=1} END {exit !f}' || { echo "bağlı emülatör yok" >&2; exit 1; }
  "$noxc" build --target android-arm64 --emit-obj -o "$work/probe.o" "$root/tests/golden/mobile_network_probe.nox" >/dev/null
  "$clang" -c -fPIE -target aarch64-linux-android24 -I "$root/include" -o "$work/host.o" "$root/scripts/mobile_stack_host.c"
  "$clang" -fPIE -pie -target aarch64-linux-android24 -o "$work/probe" "$work/host.o" "$work/probe.o" "$rt" -lm -ldl -llog
  "$adb" push "$work/probe" /data/local/tmp/nox-net-probe >/dev/null; "$adb" shell chmod 755 /data/local/tmp/nox-net-probe
  for p in $P_OK4 $P_OK6 $P_SILENT $P_TRUNC $P_RESET $P_TLS; do "$adb" reverse tcp:$p tcp:$p >/dev/null 2>&1; done
  HOSTIP=127.0.0.1; DRIPHOST=10.0.2.2
  run_probe() { # url timeout after → stdout (belirteç satırları)
    "$adb" shell "NOX_NET_URL='$1' NOX_NET_TIMEOUT_MS=$2 NOX_NET_AFTER_URL='$3' NOX_MOBILE_ROOT=/data/local/tmp/nox-net /data/local/tmp/nox-net-probe 2>/dev/null" | tr -d '\r'
  }
  pid_of() { "$adb" shell pidof nox-net-probe | tr -d '\r'; }
  stop_pid() { "$adb" shell kill -STOP "$1"; }
  cont_pid() { "$adb" shell kill -CONT "$1"; }
  airplane() { "$adb" shell cmd connectivity airplane-mode "$1" >/dev/null 2>&1; }
  ;;
ios)
  udid=${2:?simülatör UDID}
  rt="$root/zig-out/lib/noxrt-ios-simulator-arm64.o"
  [ -f "$rt" ] || { echo "simülatör çalışma zamanı yok (zig build mobile-rt-simulator)" >&2; exit 1; }
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
  "$noxc" build --target ios-simulator-arm64 --emit-obj -o "$work/probe.o" "$root/tests/golden/mobile_network_probe.nox" >/dev/null
  xcrun --sdk iphonesimulator clang -c -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -I "$root/include" -o "$work/host.o" "$root/scripts/mobile_stack_host.c"
  xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$sdk" -o "$work/probe" "$work/host.o" "$work/probe.o" "$rt" -framework Security -framework Foundation -framework CFNetwork
  HOSTIP=127.0.0.1; DRIPHOST=127.0.0.1
  run_probe() {
    SIMCTL_CHILD_NOX_NET_URL="$1" SIMCTL_CHILD_NOX_NET_TIMEOUT_MS=$2 SIMCTL_CHILD_NOX_NET_AFTER_URL="$3" SIMCTL_CHILD_NOX_MOBILE_ROOT=/tmp/nox-net-root \
      xcrun simctl spawn "$udid" "$work/probe" 2>/dev/null
  }
  pid_of() { pgrep -f "$work/probe" | head -1; }
  stop_pid() { kill -STOP "$1"; }
  cont_pid() { kill -CONT "$1"; }
  airplane() { :; }
  ;;
*) echo "bilinmeyen platform" >&2; exit 2 ;;
esac

now_ms() { python3 -c "import time;print(int(time.time()*1000))"; }

# scenario <ad> <url> <zaman_aşımı_ms> <sonra_url|-> <beklenen_belirteç_regex> <azami_ms> [<beklenen_after_belirteç>]
scenario() {
  name=$1; url=$2; to=$3; after=$4; want=$5; max=$6; want_after=${7:-}
  [ "$after" = "-" ] && after=""
  t0=$(now_ms); out=$(run_probe "$url" "$to" "$after"); t1=$(now_ms); wall=$((t1 - t0))
  first=$(printf '%s\n' "$out" | grep -v '^after ' | head -1); aft=$(printf '%s\n' "$out" | grep '^after ' | head -1)
  tok=$(printf '%s' "$first" | awk '{print $1}')
  ok=1
  printf '%s' "$tok" | grep -Eq "^($want)$" || ok=0
  # Süre sınırı Nox'un KENDİ ölçtüğü süreye (belirteç satırının 4. alanı) uygulanır; `simctl spawn`/`adb shell` başlatma gecikmesi (CI'da ilk çağrı ~10 sn) testin konusu değildir,
  # yalnızca takılmayı yakalamak için geniş bir toplam duvar sınırı vardır.
  elapsed=$(printf '%s' "$first" | awk '{print $4}')
  [ -n "$elapsed" ] && [ "$elapsed" -le "$max" ] || ok=0
  [ "$wall" -le $((max + 20000)) ] || ok=0
  if [ -n "$want_after" ]; then printf '%s' "$aft" | grep -Eq "^after ($want_after) " || ok=0; fi
  if [ $ok = 1 ]; then echo "ok   $name: $first${aft:+ | $aft} (duvar ${wall}ms)"; else echo "FAIL $name: [$first] [$aft] duvar=${wall}ms beklenen=($want)<=${max}ms ${want_after:+after=($want_after)}"; fail=$((fail+1)); fi
}

OK4="http://$HOSTIP:$P_OK4/"
# Isınma: ilk süreç başlatması (özellikle CI'da) yavaştır; sonuç sayılmaz.
run_probe "$OK4" 5000 "" >/dev/null 2>&1
scenario ipv4_literal     "$OK4"                              5000 -        ok          4000
scenario dns_dual_stack   "http://localhost:$P_OK4/"          5000 -        ok          4000
scenario ipv6_literal     "http://[::1]:$P_OK6/"              5000 -        ok          4000
scenario conn_refused     "http://$HOSTIP:$P_CLOSED/"         5000 -        error       4000
scenario conn_reset       "http://$HOSTIP:$P_RESET/"          5000 "$OK4"   error       4000   ok
scenario idle_timeout     "http://$HOSTIP:$P_SILENT/"         1500 "$OK4"   timeout     5000   ok
scenario truncated_body   "http://$HOSTIP:$P_TRUNC/"          5000 "$OK4"   error       4000   ok
scenario tls_self_signed  "https://$HOSTIP:$P_TLS/"           5000 "$OK4"   error       4000   ok
scenario tls_valid        "https://example.com/"             10000 -        ok          12000
scenario dns_unresolvable "http://nonexistent.invalid/"       3000 "$OK4"   "error|timeout" 6000 ok
scenario connect_blackhole "http://192.0.2.1:81/"             2000 "$OK4"   "error|timeout" 5000 ok

# arka plana alma / geri dönme: istek sürerken süreci durdur (iOS askıya alma, Android Doze benzeri), sonra devam ettir.
run_probe "http://$DRIPHOST:$P_DRIP/" 20000 "$OK4" >"$work/suspend.out" &
bg=$!
pid=""; n=0
while [ -z "$pid" ] && [ $n -lt 80 ]; do pid=$(pid_of); [ -n "$pid" ] || { sleep 0.25; n=$((n+1)); }; done
sleep 2.5
if [ -n "$pid" ]; then stop_pid "$pid"; sleep 3; cont_pid "$pid"; fi
wait $bg
first=$(grep -v '^after ' "$work/suspend.out" | head -1); aft=$(grep '^after ' "$work/suspend.out" | head -1)
if printf '%s' "$first" | grep -Eq '^(ok|error|timeout) ' && printf '%s' "$aft" | grep -Eq '^after ok '; then echo "ok   background_resume: $first | $aft (pid ${pid:-?} durdurulup sürdürüldü)"; else echo "FAIL background_resume: [$first] [$aft]"; fail=$((fail+1)); fi

if [ "$platform" = android ]; then
  # çevrimdışı: uçak modu açıkken istek temiz hata/zaman aşımıyla biter ve ağ dönünce toparlanır
  airplane enable; sleep 4
  scenario offline_request "https://example.com/" 4000 - "error|timeout" 15000
  airplane disable; sleep 8
  scenario back_online "https://example.com/" 10000 - ok 15000
  # ağ değişimi: istek sürerken ağ kesilir
  run_probe "http://$DRIPHOST:$P_DRIP/" 4000 "" >"$work/netchange.out" &
  bg=$!
  sleep 2; airplane enable
  wait $bg; airplane disable; sleep 8
  first=$(head -1 "$work/netchange.out")
  if printf '%s' "$first" | grep -Eq '^(error|timeout) '; then echo "ok   network_change_mid_request: $first"; else echo "FAIL network_change_mid_request: [$first]"; fail=$((fail+1)); fi
fi

echo "başarısız senaryo: $fail"
[ $fail -eq 0 ]
