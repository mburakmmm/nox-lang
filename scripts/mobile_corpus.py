#!/usr/bin/env python3
"""Mobil fixture korpusu: `tests/golden/codegen_cases` (`.nox` + `.expected`) iOS simülatöründe çalıştırılır ve çıktı `.expected` ile karşılaştırılır
(WASM karşılığı: `tests/golden/wasm_corpus_test.zig`). Kullanım: scripts/mobile_corpus.py ios <simülatör-UDID> [--filter alt-dize] [--jobs N]
          scripts/mobile_corpus.py android [--filter alt-dize] [--jobs N]   (bağlı emülatör; NOX_ANDROID_ABI=arm64|x64, ANDROID_NDK_HOME)

Sınıflandırma (WASM korpusuyla aynı ilke):
  ok        çıktı beklenenle birebir aynı
  reddedildi derleyici modülü "cannot be used on a mobile target" iletisiyle reddetti: mobilde bulunmayan modül (hpy/native/plugin/process/sharedmem/mysql/postgres); başarı sayılır
  atlandı   `tests/golden/mobile_corpus_denylist.txt` içinde gerekçeyle listelenmiş
  HATA      derleme/bağlama/çalıştırma hatası ya da çıktı farkı: betik 1 ile çıkar
"""
import concurrent.futures as cf
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NOXC = os.environ.get("NOXC", str(ROOT / "zig-out/bin/noxc"))
CASES = ROOT / "tests/golden/codegen_cases"
MOBILE_CASES = ROOT / "tests/golden/mobile_cases"  # mobil kök politikasına uyarlanmış varyantlar
DENY = ROOT / "tests/golden/mobile_corpus_denylist.txt"


def load_denylist():
    deny = {}
    if DENY.exists():
        for line in DENY.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, _, why = line.partition("#")
            deny[name.strip()] = why.strip()
    return deny


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def ios_setup(work, udid):
    sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).stdout.strip()
    host_o = work / "host.o"
    r = run(["xcrun", "--sdk", "iphonesimulator", "clang", "-c", "-target", "arm64-apple-ios17.0-simulator", "-isysroot", sdk,
             "-I", str(ROOT / "include"), "-o", str(host_o), str(ROOT / "scripts/mobile_corpus_host.c")])
    if r.returncode != 0:
        sys.exit("ana program derlenemedi:\n" + r.stderr)
    rt = ROOT / "zig-out/lib/noxrt-ios-simulator-arm64.o"
    if not rt.exists():
        sys.exit(f"{rt} yok (önce: zig build mobile-rt-simulator)")
    return {"sdk": sdk, "host_o": host_o, "rt": rt, "udid": udid}


def ios_one(name, ctx, work):
    base = MOBILE_CASES if name.startswith("mobile_cases/") else CASES
    stem = name.split("/")[-1]
    src = base / f"{stem}.nox"
    flat = name.replace("/", "__")
    obj = work / f"{flat}.o"
    r = run([NOXC, "build", "--target", "ios-simulator-arm64", "--emit-obj", "-o", str(obj), str(src)], timeout=300)
    msg = (r.stdout + r.stderr)
    if r.returncode != 0:
        if "cannot be used on a mobile target" in msg:
            return ("reddedildi", msg.strip().splitlines()[0][:140])
        return ("HATA", "derleme: " + "\n".join(l for l in msg.splitlines() if "warning" not in l)[:300])
    binary = work / f"{flat}.bin"
    r = run(["xcrun", "--sdk", "iphonesimulator", "clang", "-target", "arm64-apple-ios17.0-simulator", "-isysroot", ctx["sdk"], "-o", str(binary),
             str(ctx["host_o"]), str(obj), str(ctx["rt"]), "-framework", "Security", "-framework", "Foundation", "-framework", "CFNetwork"], timeout=300)
    obj.unlink(missing_ok=True)
    if r.returncode != 0:
        return ("HATA", "bağlama: " + "\n".join(l for l in r.stderr.splitlines() if "warning" not in l)[:300])
    root = work / f"root_{flat}"
    env = dict(os.environ, SIMCTL_CHILD_NOX_MOBILE_ROOT=str(root), SIMCTL_CHILD_NOX_MOBILE_TEMP="/tmp")
    try:
        r = subprocess.run(["xcrun", "simctl", "spawn", ctx["udid"], str(binary)], capture_output=True, text=True, timeout=120, env=env, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        binary.unlink(missing_ok=True)
        return ("HATA", "zaman aşımı (120 sn)")
    binary.unlink(missing_ok=True)
    expected = (base / f"{stem}.expected").read_text(encoding="utf-8")
    if r.stdout == expected:
        return ("ok", "")
    return ("HATA", f"çıktı farkı (çıkış {r.returncode}); stderr: {r.stderr.strip()[:200]}")


def android_setup(work):
    abi = os.environ.get("NOX_ANDROID_ABI", "arm64")
    triple = {"arm64": "aarch64-linux-android24", "x64": "x86_64-linux-android24"}.get(abi)
    if triple is None:
        sys.exit("NOX_ANDROID_ABI: arm64 | x64")
    ndk = os.environ.get("ANDROID_NDK_HOME") or os.environ.get("ANDROID_NDK_ROOT")
    if not ndk:
        parent = Path.home() / "Library/Android/sdk/ndk"
        ndk = str(sorted(parent.iterdir())[-1]) if parent.exists() else ""
    clang = None
    for host in ("darwin-arm64", "darwin-x86_64", "linux-x86_64", "linux-aarch64"):
        c = Path(ndk) / "toolchains/llvm/prebuilt" / host / "bin/clang"
        if c.exists():
            clang = str(c)
            break
    if clang is None:
        sys.exit("NDK clang bulunamadı (ANDROID_NDK_HOME)")
    adb = os.environ.get("ADB") or (subprocess.run(["which", "adb"], capture_output=True, text=True).stdout.strip() or str(Path.home() / "Library/Android/sdk/platform-tools/adb"))
    if "device" not in run([adb, "devices"]).stdout.split("\n", 1)[-1]:
        sys.exit("bağlı Android cihazı/emülatörü yok (adb devices)")
    rt = ROOT / f"zig-out/lib/noxrt-android-{abi}.o"
    if not rt.exists():
        sys.exit(f"{rt} yok (önce: zig build mobile-rt-android)")
    host_o = work / "host.o"
    r = run([clang, "-c", "-fPIE", "-target", triple, "-I", str(ROOT / "include"), "-o", str(host_o), str(ROOT / "scripts/mobile_corpus_host.c")])
    if r.returncode != 0:
        sys.exit("ana program derlenemedi:\n" + r.stderr)
    run([adb, "shell", "rm -rf /data/local/tmp/nox-corpus && mkdir -p /data/local/tmp/nox-corpus"])
    return {"abi": abi, "triple": triple, "clang": clang, "adb": adb, "rt": rt, "host_o": host_o}


def android_one(name, ctx, work):
    base = MOBILE_CASES if name.startswith("mobile_cases/") else CASES
    stem = name.split("/")[-1]
    flat = name.replace("/", "__")
    # Android'de /tmp yoktur; uygulamanın geçici dizin kökü /data/local/tmp'dir (fixture'lardaki mutlak /tmp yolları oraya taşınır).
    src = work / f"{flat}.nox"
    text = (base / f"{stem}.nox").read_text(encoding="utf-8").replace('"/tmp/', '"/data/local/tmp/').replace('"/tmp"', '"/data/local/tmp"')
    src.write_text(text, encoding="utf-8")
    obj = work / f"{flat}.o"
    r = run([NOXC, "build", "--target", f"android-{ctx['abi']}", "--emit-obj", "-o", str(obj), str(src)], timeout=300)
    msg = r.stdout + r.stderr
    if r.returncode != 0:
        if "cannot be used on a mobile target" in msg:
            return ("reddedildi", msg.strip().splitlines()[0][:140])
        return ("HATA", "derleme: " + "\n".join(l for l in msg.splitlines() if "warning" not in l)[:300])
    binary = work / f"{flat}.bin"
    r = run([ctx["clang"], "-fPIE", "-pie", "-target", ctx["triple"], "-o", str(binary), str(ctx["host_o"]), str(obj), str(ctx["rt"]), "-lm", "-ldl", "-llog"], timeout=300)
    obj.unlink(missing_ok=True)
    if r.returncode != 0:
        return ("HATA", "bağlama: " + "\n".join(l for l in r.stderr.splitlines() if "warning" not in l)[:300])
    remote = f"/data/local/tmp/nox-corpus/{flat}"
    adb = ctx["adb"]
    try:
        r = run([adb, "push", str(binary), remote], timeout=120)
        binary.unlink(missing_ok=True)
        if r.returncode != 0:
            return ("HATA", "adb push: " + r.stderr[:200])
        cmd = f"chmod 755 {remote} && NOX_MOBILE_ROOT={remote}_root NOX_MOBILE_TEMP=/data/local/tmp {remote}"
        r = subprocess.run([adb, "shell", cmd], capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return ("HATA", "zaman aşımı (120 sn)")
    finally:
        run([adb, "shell", f"rm -rf {remote} {remote}_root"])
    expected = (base / f"{stem}.expected").read_text(encoding="utf-8").replace("/tmp/", "/data/local/tmp/")
    if r.stdout == expected:
        return ("ok", "")
    return ("HATA", f"çıktı farkı (çıkış {r.returncode}); stderr: {r.stderr.strip()[:200]}")


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("ios", "android") or (args[0] == "ios" and len(args) < 2):
        sys.exit(__doc__)
    platform = args[0]
    udid = args[1] if platform == "ios" else ""
    flt = ""
    jobs = 4
    for i, a in enumerate(args):
        if a == "--filter":
            flt = args[i + 1]
        if a == "--jobs":
            jobs = int(args[i + 1])
    names = sorted(p.stem for p in CASES.glob("*.nox") if (CASES / f"{p.stem}.expected").exists() and flt in p.stem)
    names += sorted("mobile_cases/" + p.stem for p in MOBILE_CASES.glob("*.nox") if (MOBILE_CASES / f"{p.stem}.expected").exists() and flt in p.stem)
    deny = load_denylist()
    counts = {"ok": 0, "reddedildi": 0, "atlandı": 0, "HATA": 0}
    failures = []
    with tempfile.TemporaryDirectory(prefix="nox-mobile-corpus-") as w:
        work = Path(w)
        ctx = ios_setup(work, udid) if platform == "ios" else android_setup(work)
        one = ios_one if platform == "ios" else android_one
        todo = []
        for n in names:
            if n in deny:
                counts["atlandı"] += 1
            else:
                todo.append(n)
        with cf.ThreadPoolExecutor(jobs) as ex:
            for n, (status, detail) in zip(todo, ex.map(lambda n: one(n, ctx, work), todo)):
                counts[status] += 1
                if status == "HATA":
                    failures.append((n, detail))
                    print(f"HATA {n}: {detail}", flush=True)
    print(f"\nmobil korpus ({platform}): {len(names)} fixture; ok {counts['ok']}, reddedildi {counts['reddedildi']}, atlandı {counts['atlandı']}, HATA {counts['HATA']}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
