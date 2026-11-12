#!/usr/bin/env python3
"""tests/golden/codegen_cases/argparse_python_equivalence.{nox,expected} dosyalarını üretir: aynı bildirimle kurulmuş bir Python `argparse` ayrıştırıcısı
(`parse_intermixed_args`, kısaltmasız) ile `nox.argparse` rastgele (tohumlu) argv listelerinde aynı sonucu vermeli (hata ya da alan değerleri).
Kullanım: scripts/gen_argparse_golden.py"""
import argparse, os, random, sys, io, contextlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/golden/codegen_cases")
rnd = random.Random(20261114)

TOKENS = ["-v", "--verbose", "-o", "x", "--output=y", "--output", "z", "-n", "5", "-n3", "--count=7", "-I", "d1", "-Id2", "--include", "d3", "--include=d4",
          "in.txt", "e1", "e2", "--", "-weird", "-5", "-2.5", "--bogus", "-x", "-vn", "4", "-vofile", "--count", "abc", "-n", "-1", "--output", "-q"]


def make_py():
    p = argparse.ArgumentParser(prog="tool", add_help=False, allow_abbrev=False, exit_on_error=False)
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("-o", "--output", default="out.txt")
    p.add_argument("-n", "--count", type=int, default=1)
    p.add_argument("-I", "--include", action="append", default=[])
    p.add_argument("file")
    p.add_argument("more", nargs="*")
    return p


def run_py(argv):
    p = make_py()
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            ns = p.parse_intermixed_args(argv)
    except (SystemExit, argparse.ArgumentError, argparse.ArgumentTypeError):
        return "ERROR"
    return f"{ns.verbose} {ns.output} {ns.count} {ns.include} {ns.file} {ns.more}"


PIECES = [("-v",), ("--verbose",), ("-o", "x"), ("--output=y",), ("--output", "z"), ("-n", "5"), ("-n3",), ("--count=7",), ("-I", "d1"), ("-Id2",),
          ("--include", "d3"), ("--include=d4",), ("-vn", "4"), ("-vofile",), ("-vv",), ("e1",), ("e2",), ("in.txt",), ("-5",), ("-2.5",), ("-o", "-7"),
          ("--output=-q",), ("-n", "-1"), ("-vI", "inc")]
JUNK = [("--bogus",), ("-x",), ("--count", "abc"), ("--output", "-q"), ("-o",), ("--include",), ("-n", "1.5"), ("--verbose=1",)]
cases = []
seen = set()
while len(cases) < 140:
    argv = []
    for _ in range(rnd.randrange(0, 7)):
        argv += list(rnd.choice(JUNK if rnd.random() < 0.08 else PIECES))
    if "in.txt" not in argv and rnd.random() < 0.9:
        argv.insert(rnd.randrange(0, len(argv) + 1), "in.txt")
    if rnd.random() < 0.15:
        argv += ["--", "-weird", "e3"]
    key = tuple(argv)
    if key in seen:
        continue
    seen.add(key)
    cases.append(argv)

src = ["# Üretildi: scripts/gen_argparse_golden.py. nox.argparse, Python argparse (parse_intermixed_args) ile aynı sonucu vermeli.",
       "import nox.argparse", "from nox.argparse import ArgumentParser, Namespace, ArgumentError", "",
       'p: ArgumentParser = ArgumentParser("tool")',
       'p.add_flag("-v", "--verbose")',
       'p.add_option("-o", "--output", "out.txt")',
       'p.add_int_option("-n", "--count", 1)',
       'p.add_multi_option("-I", "--include")',
       'p.add_positional("file")',
       'p.add_rest("more")', "",
       "def show(args: list[str]) -> None:",
       "    try:",
       "        ns: Namespace = p.parse(args)",
       '        print(ns.flag("verbose"), ns.get_str("output"), ns.get_int("count"), ns.get_list("include"), ns.get_str("file"), ns.get_list("more"))',
       "    except ArgumentError as e:",
       '        print("ERROR")', ""]
exp = []
for argv in cases:
    lit = "[" + ", ".join('"%s"' % a.replace("\\", "\\\\").replace('"', '\\"') for a in argv) + "]"
    src.append(f"show({lit})")
    exp.append(run_py(argv))
open(os.path.join(OUT, "argparse_python_equivalence.nox"), "w").write("\n".join(src) + "\n")
open(os.path.join(OUT, "argparse_python_equivalence.expected"), "w").write("\n".join(exp) + "\n")
print(len(exp), "satır;", sum(1 for e in exp if e == "ERROR"), "hata")
