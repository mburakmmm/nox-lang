#!/usr/bin/env python3
"""tests/golden/codegen_cases/{fnmatch,glob}_python_equivalence.{nox,expected} dosyalarını üretir: `nox.fnmatch` Python `fnmatch.fnmatchcase` ile (rastgele kalıp/ad),
`nox.glob` Python `glob.glob(root_dir=..., recursive=True)` ile (sabit dizin ağacında, sonuçlar sıralı) aynı olmalı. Kullanım: scripts/gen_glob_golden.py"""
import fnmatch, glob, os, random, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tests/golden/codegen_cases")
rnd = random.Random(20261115)

# ---------------------------------------------------------------- fnmatch
ALPHA = list("abc.-_x") + ["*", "?", "[", "]", "!"]
NAMES = ["", "a", "abc", "a.txt", "ab.txt", "x_y-z", ".hidden", "abcabc", "[", "a]b", "!", "aXb", "zzz"]
def rand_pat():
    n = rnd.randrange(0, 7)
    parts = []
    for _ in range(n):
        r = rnd.random()
        if r < 0.15:
            parts.append(rnd.choice(["[a-c]", "[!a-c]", "[abc]", "[!abc]", "[a-]", "[]a]", "[!]a]", "[x-z]", "[[]"]))
        else:
            parts.append(rnd.choice(ALPHA))
    return "".join(parts)

src = ["# Üretildi: scripts/gen_glob_golden.py. nox.fnmatch, Python fnmatch.fnmatchcase ile aynı sonucu vermeli.", "import nox.fnmatch", "from nox.fnmatch import fnmatch", ""]
exp = []
seen = set()
def instantiate(pat):
    """Kalıptan eşleşmeye yatkın bir ad türet (eşleşme oranını artırır)."""
    out, i = "", 0
    while i < len(pat):
        c = pat[i]
        if c == "*":
            out += rnd.choice(["", "a", "bc", ".x"])
        elif c == "?":
            out += rnd.choice("abc.")
        elif c == "[":
            j = pat.find("]", i + 2)
            if j < 0:
                out += "["
            else:
                body = pat[i + 1:j]
                if body.startswith("!"):
                    out += "z"
                else:
                    out += body[0] if body[0] not in "-]" else "a"
                i = j
        else:
            out += c
        i += 1
    return out

while len(exp) < 400:
    pat = rand_pat()
    name = instantiate(pat) if rnd.random() < 0.6 else rnd.choice(NAMES)
    if (pat, name) in seen:
        continue
    seen.add((pat, name))
    lit = lambda x: '"' + x.replace("\\", "\\\\").replace('"', '\\"') + '"'
    src.append(f"print(fnmatch({lit(name)}, {lit(pat)}))")
    exp.append(str(fnmatch.fnmatchcase(name, pat)))
open(os.path.join(OUT, "fnmatch_python_equivalence.nox"), "w").write("\n".join(src) + "\n")
open(os.path.join(OUT, "fnmatch_python_equivalence.expected"), "w").write("\n".join(exp) + "\n")
print("fnmatch:", len(exp), "satır,", sum(e == "True" for e in exp), "eşleşme")

# ---------------------------------------------------------------- glob
FILES = ["a/x.txt", "a/y.py", "a/b/z.txt", "a/b/c/w.txt", "a/b/c/v.py", "a/.h", "a/.hid/q.txt", "top.txt", ".dot", "readme.md", "x y.txt", "a/b/.secret/s.txt", "e1/e2/leaf.txt"]
DIRS = ["d", "empty/inner"]
PATTERNS = ["*", "*.txt", "a/*", "a/*.py", "a/*/", "a/b/*", "a/b/c/*", "*/*", "*/*/*", "?", "??", "[a-d]*", "[!a]*", "a/?.txt", ".*", "a/.*", "*.md", "x*", "nope", "nope/*",
            "a", "a/", "a/x.txt", "a/nope.txt", "top.txt", "*/", "a/b", "e1/*/*.txt", "e*/*/leaf.txt", "[ae]*/*", "a/[xy].*", "a/*.[tp][xy]*",
            "**", "**/", "**/*.txt", "a/**", "a/**/", "a/**/*.txt", "**/z.txt", "**/c/*", "a/**/c/*.py", "**/*", "**/.h", "**/*.py", "e1/**", "**/leaf.txt", "a/b/**", "*/**/*.txt",
            ".dot", "./top.txt", "a/./x.txt"]

def build(root):
    for f in FILES:
        p = os.path.join(root, f)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write("x")
    for d in DIRS:
        os.makedirs(os.path.join(root, d), exist_ok=True)

with tempfile.TemporaryDirectory() as td:
    build(td)
    nox_src = ["# Üretildi: scripts/gen_glob_golden.py. nox.glob, Python glob.glob(root_dir=..., recursive=True) ile aynı sonucu vermeli (sıralı).",
               "import nox.fs", "import nox.tempfile", "from nox.tempfile import mkdtemp", "from nox.glob import glob", "",
               'root: str = mkdtemp("nox-glob-")']
    for f in FILES:
        d = os.path.dirname(f)
        if d:
            nox_src.append(f'nox.fs.create_dir_all(root + "/{d}")')
        nox_src.append(f'nox.fs.write_string(root + "/{f}", "x")')
    for d in DIRS:
        nox_src.append(f'nox.fs.create_dir_all(root + "/{d}")')
    nox_src += ["", "def show(pattern: str) -> None:", "    print(pattern, glob(pattern, root, True))", ""]
    gexp = []
    for pat in PATTERNS:
        nox_src.append(f'show("{pat}")')
        res = sorted(glob.glob(pat, root_dir=td, recursive=True))
        gexp.append(f"{pat} {res}")
    nox_src += ["", "nox.fs.remove_dir_all(root)"]
open(os.path.join(OUT, "glob_python_equivalence.nox"), "w").write("\n".join(nox_src) + "\n")
open(os.path.join(OUT, "glob_python_equivalence.expected"), "w").write("\n".join(gexp) + "\n")
print("glob:", len(gexp), "kalıp")
