#!/usr/bin/env python3
"""Mobil hedefte (iOS simülatörü / Android emülatörü) bir Nox programını derleyip bağlayıp çalıştırmak için ortak yardımcılar.
`scripts/mobile_corpus.py` (fixture korpusu) ve `scripts/mobile_db_probe.py` (veritabanı istemcileri) kullanır.

Program, gömme ABI'li genel ana programla (`scripts/mobile_corpus_host.c`) bağlanır: `nox_embed_bind` + `nox_app_start` Nox'un üst düzey ifadelerini çalıştırır.
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NOXC = os.environ.get("NOXC", str(ROOT / "zig-out/bin/noxc"))


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


class Result:
    def __init__(self, status, stdout="", stderr="", returncode=0, detail=""):
        self.status = status  # "ran" | "rejected" | "error"
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode
        self.detail = detail


def _clean(text, limit=300):
    return "\n".join(l for l in text.splitlines() if "warning" not in l)[:limit]


def setup(platform, work, udid=""):
    """Ortak hazırlık: ana programı derler. Dönen `ctx`, `run_program`a verilir."""
    if platform == "ios":
        sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).stdout.strip()
        host_o = work / "host.o"
        r = run(["xcrun", "--sdk", "iphonesimulator", "clang", "-c", "-target", "arm64-apple-ios17.0-simulator", "-isysroot", sdk,
                 "-I", str(ROOT / "include"), "-o", str(host_o), str(ROOT / "scripts/mobile_corpus_host.c")])
        if r.returncode != 0:
            sys.exit("ana program derlenemedi:\n" + r.stderr)
        rt = ROOT / "zig-out/lib/noxrt-ios-simulator-arm64.o"
        if not rt.exists():
            sys.exit(f"{rt} yok (önce: zig build mobile-rt-simulator)")
        return {"platform": "ios", "sdk": sdk, "host_o": host_o, "rt": rt, "udid": udid}
    abi = os.environ.get("NOX_ANDROID_ABI", "arm64")
    triple = {"arm64": "aarch64-linux-android29", "x64": "x86_64-linux-android29"}.get(abi)
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
    return {"platform": "android", "abi": abi, "triple": triple, "clang": clang, "adb": adb, "rt": rt, "host_o": host_o}


def run_program(ctx, name, src, work, timeout=120):
    """`src` (.nox) dosyasını hedef için derler, bağlar, hedefte çalıştırır. Geçici dosyalar hemen silinir."""
    if ctx["platform"] == "ios":
        target = "ios-simulator-arm64"
    else:
        target = f"android-{ctx['abi']}"
    obj = work / f"{name}.o"
    r = run([NOXC, "build", "--target", target, "--emit-obj", "-o", str(obj), str(src)], timeout=300)
    msg = r.stdout + r.stderr
    if r.returncode != 0:
        if "cannot be used on a mobile target" in msg:
            return Result("rejected", detail=msg.strip().splitlines()[0][:140])
        return Result("error", detail="derleme: " + _clean(msg))
    binary = work / f"{name}.bin"
    if ctx["platform"] == "ios":
        r = run(["xcrun", "--sdk", "iphonesimulator", "clang", "-target", "arm64-apple-ios17.0-simulator", "-isysroot", ctx["sdk"], "-o", str(binary),
                 str(ctx["host_o"]), str(obj), str(ctx["rt"]), "-framework", "Security", "-framework", "Foundation", "-framework", "CFNetwork"], timeout=300)
    else:
        r = run([ctx["clang"], "-fPIE", "-pie", "-target", ctx["triple"], "-o", str(binary), str(ctx["host_o"]), str(obj), str(ctx["rt"]), "-lm", "-ldl", "-llog"], timeout=300)
    obj.unlink(missing_ok=True)
    if r.returncode != 0:
        return Result("error", detail="bağlama: " + _clean(r.stderr))
    try:
        if ctx["platform"] == "ios":
            root = work / f"root_{name}"
            env = dict(os.environ, SIMCTL_CHILD_NOX_MOBILE_ROOT=str(root), SIMCTL_CHILD_NOX_MOBILE_TEMP="/tmp", SIMCTL_CHILD_TMPDIR="/tmp")
            p = subprocess.run(["xcrun", "simctl", "spawn", ctx["udid"], str(binary)], capture_output=True, text=True, timeout=timeout, env=env, stdin=subprocess.DEVNULL)
        else:
            remote = f"/data/local/tmp/nox-corpus/{name}"
            adb = ctx["adb"]
            pr = run([adb, "push", str(binary), remote], timeout=120)
            if pr.returncode != 0:
                return Result("error", detail="adb push: " + pr.stderr[:200])
            try:
                cmd = f"chmod 755 {remote} && NOX_MOBILE_ROOT={remote}_root NOX_MOBILE_TEMP=/data/local/tmp {remote}"
                p = subprocess.run([adb, "shell", cmd], capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
            finally:
                run([adb, "shell", f"rm -rf {remote} {remote}_root"])
    except subprocess.TimeoutExpired:
        return Result("error", detail=f"zaman aşımı ({timeout} sn)")
    finally:
        binary.unlink(missing_ok=True)
    return Result("ran", p.stdout, p.stderr, p.returncode)
