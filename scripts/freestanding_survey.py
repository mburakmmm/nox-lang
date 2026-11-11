#!/usr/bin/env python3
"""Freestanding (x86_64) kapsam ölçümü: `tests/golden/codegen_cases/*.nox` fixture'larını `--profile freestanding` ile derler/bağlar (aşama 1), bağlananları GERÇEK bir QEMU
önyüklemesinde çalıştırıp seri çıktıyı `.expected` ile karşılaştırır (aşama 2). Sonuç kategorileri:
  CAP     yetenek denetimi reddetti (tasarım gereği: filesystem/clock/threads/network/...)
  LINK    runtime sembolü eksik (kabuk freestanding köke alınmamış)
  OTHER   beklenen reddetme (negatif fixture) ya da harici nesne eksik
  PASS    QEMU çıktısı beklenenle aynı
  DIFF    çalıştı ama çıktı farklı
  HALT    program QEMU'yu kapatmadı ama hosted çalışma BAŞARILI: gerçek kusur. HALT-OK = hosted da hatayla bitiyor (işlenmemiş istisna/kilitlenme), makine durur (tasarım)
  FAULT   CPU istisnası (`KERNEL_FAULT`)
  TIMEOUT çıktı yok ve kapanmadı
Kullanım: scripts/freestanding_survey.py [--limit N] [--only ad1,ad2] [--jobs 6] [--out dizin]
Gereken araçlar: zig, qbe, qemu-system-x86_64, x86_64-elf-objcopy; `zig build` ile üretilmiş noxc ve zig-out/lib/noxrt-freestanding-x86_64.o.
Rapor: project/freestanding-kapsam-analizi-2026-11.md
"""
import argparse
import collections
import concurrent.futures as cf
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
CASES = os.path.join(ROOT, "tests/golden/codegen_cases")
RT = os.path.join(ROOT, "zig-out/lib/noxrt-freestanding-x86_64.o")
BOOT = os.path.join(ROOT, "runtime/freestanding/x86_64/boot_x86_64.o")
LD = os.path.join(ROOT, "runtime/freestanding/x86_64/kernel.ld")
OBJCOPY = shutil.which("x86_64-elf-objcopy") or shutil.which("objcopy")


def link_check(name):
    src = os.path.join(CASES, name + ".nox")
    d = tempfile.mkdtemp(prefix="fss-")
    try:
        r = subprocess.run([NOXC, "build", "--profile", "freestanding", "--target", "x86_64", "-o", d + "/k.elf", src], capture_output=True, text=True, timeout=180)
        out = r.stdout + r.stderr
        if r.returncode == 0:
            return ("OK", "")
        if "FreestandingModuleForbidden" in out or "CapabilityNotGranted" in out:
            m = re.search(r"required capability: '([a-z_]+)'", out)
            return ("CAP", m.group(1) if m else "?")
        if "undefined symbol" in out:
            syms = sorted(set(re.findall(r"undefined symbol: (\w+)", out)))
            return ("LINK", ",".join(syms[:6]))
        return ("OTHER", out.strip().splitlines()[-1][:120] if out.strip() else "")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def boot(name):
    src = os.path.join(CASES, name + ".nox")
    exp_path = os.path.join(CASES, name + ".expected")
    expected = open(exp_path, newline="").read() if os.path.exists(exp_path) else None
    d = tempfile.mkdtemp(prefix="fsq-")
    try:
        stem = d + "/k"
        r = subprocess.run([NOXC, "build", "--target", "x86_64", "--profile", "freestanding", "--emit-asm", src, "-o", stem], capture_output=True, text=True, timeout=180)
        if r.returncode:
            return ("BUILD", r.stderr[-120:])
        r = subprocess.run(["zig", "cc", "-target", "x86_64-freestanding-none", "-nostdlib", "-static", "-Wl,-T," + LD, "-Wl,-s", "-Wl,--build-id=none", "-Wl,-z,max-page-size=0x1000", "-o", d + "/k64.elf", BOOT, stem + ".s", RT], capture_output=True, text=True, timeout=180)
        if r.returncode:
            return ("LINK", r.stderr[-120:])
        r = subprocess.run([OBJCOPY, "-O", "elf32-i386", "-S", d + "/k64.elf", d + "/k.elf"], capture_output=True, text=True)
        if r.returncode:
            return ("BUILD", "objcopy")
        cmd = ["qemu-system-x86_64", "-machine", "q35", "-cpu", "qemu64", "-m", "128M", "-kernel", d + "/k.elf", "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04", "-serial", "stdio", "-display", "none", "-monitor", "none", "-no-reboot"]
        halted = False
        try:
            q = subprocess.run(cmd, capture_output=True, timeout=30, stdin=subprocess.DEVNULL)
            out_b = q.stdout
        except subprocess.TimeoutExpired as te:
            out_b = te.stdout or b""
            halted = True
        out = out_b.decode("utf8", "replace").replace("\r\n", "\n")
        if "KERNEL_FAULT" in out:
            return ("FAULT", out[-100:].replace("\n", " "))
        if halted:
            # Makinenin durması yalnızca fixture'ın KENDİSİ hosted çalışmada da hatayla bitiyorsa (işlenmemiş istisna / kilitlenme tasarımı) beklenen davranıştır.
            hosted = subprocess.run([NOXC, "run", src], capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
            if hosted.returncode != 0:
                return ("HALT-OK", "hosted da hatayla biter; freestanding makineyi durdurur (tasarım)")
            return ("HALT", repr(out[-100:]))
        if expected is None:
            return ("NOEXP", "")
        if out == expected or out.strip() == expected.strip():
            return ("PASS", "")
        return ("DIFF", f"got={out[:70]!r} want={expected[:70]!r}")
    except subprocess.TimeoutExpired:
        return ("TIMEOUT", "")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--no-boot", action="store_true", help="yalnızca derleme/bağlama aşaması")
    args = ap.parse_args()
    for tool in ("zig", "qemu-system-x86_64"):
        if not shutil.which(tool):
            print(f"{tool} bulunamadı", file=sys.stderr)
            sys.exit(77)
    if not OBJCOPY:
        print("x86_64-elf-objcopy bulunamadı", file=sys.stderr)
        sys.exit(77)
    names = sorted(os.path.splitext(f)[0] for f in os.listdir(CASES) if f.endswith(".nox"))
    if args.only:
        names = [n for n in names if n in set(args.only.split(","))]
    if args.limit:
        names = names[: args.limit]
    with cf.ThreadPoolExecutor(args.jobs) as ex:
        stage1 = dict(zip(names, ex.map(link_check, names)))
    linked = [n for n in names if stage1[n][0] == "OK"]
    stage2 = {}
    if not args.no_boot:
        with cf.ThreadPoolExecutor(args.jobs) as ex:
            stage2 = dict(zip(linked, ex.map(boot, linked)))
    tally = collections.Counter()
    details = collections.defaultdict(list)
    for n in names:
        k, why = stage1[n]
        if k == "OK" and n in stage2:
            k, why = stage2[n]
        elif k == "OK":
            k = "LINK-OK"
        tally[k] += 1
        details[k].append((n, why))
    print(f"fixture: {len(names)}")
    for k, v in sorted(tally.items(), key=lambda kv: -kv[1]):
        print(f"{k:8s} {v}")
    print()
    for k in ("DIFF", "FAULT", "HALT", "TIMEOUT", "BUILD", "LINK"):
        for n, why in details.get(k, []):
            print(f"{k}\t{n}\t{why}")
    caps = collections.Counter(w for _, w in details.get("CAP", []))
    if caps:
        print("\nCAP dağılımı:", dict(caps))


if __name__ == "__main__":
    main()
