#!/usr/bin/env python3
"""noxc-nightly Aşama 3.3: tip denetleyicisi farksal testi için tohumlu rastgele program üreteci.

Nox denetleyicisinin KAPSAM İÇİ altkümesinden (skaler tipler, kullanıcı işlevleri, if/while, print/len) küçük programlar üretir; bir kısmı KASITLI olarak hatalıdır (yanlış tip, tanımsız ad,
yanlış argüman sayısı/tipi, döngü dışı break, eksik return, yeniden bildirim ...). Çıktı dosyaları `noxc-nightly ck-diff check` ile GERÇEK Zig denetleyicisine karşı karşılaştırılır; böylece gerçek
korpusun kapsamadığı dallar (ör. dönüş tipi uyuşmazlığı) da sınanır.

  scripts/ck_gen.py --out DIR [--count 500] [--seed 1]
"""
import argparse
import os
import random

TYPES = ["int", "float", "bool", "str", "u8", "i32", "None"]
VALUE_TYPES = ["int", "float", "bool", "str", "u8", "i32"]


def lit(rnd, t):
    if t == "int":
        return str(rnd.choice([0, 1, 2, 7, 42, 255, 1000]))
    if t == "float":
        return rnd.choice(["0.5", "1.0", "2.5", "3.14"])
    if t == "bool":
        return rnd.choice(["True", "False"])
    if t == "str":
        return rnd.choice(['"a"', '"hello"', '""', '"x y"'])
    if t in ("u8", "i32"):
        return str(rnd.choice([0, 1, 5, 100, 200, 300, -1, 70000]))
    return "None"


class Gen:
    def __init__(self, rnd):
        self.rnd = rnd
        self.funcs = []  # (name, [param types], ret)
        self.lines = []
        self.counter = 0

    def fresh(self, p="v"):
        self.counter += 1
        return f"{p}{self.counter}"

    def expr(self, scope, t, depth=0, wrong=0.12):
        """`t` tipinde (ya da `wrong` olasılıkla rastgele tipte) ifade."""
        r = self.rnd
        if r.random() < wrong:
            t = r.choice(VALUE_TYPES)
        if t == "None":
            return "None"
        cands = [v for v, vt in scope.items() if vt == t]
        k = r.random()
        if depth < 3 and k < 0.35:
            if t == "int":
                op = r.choice(["+", "-", "*", "//", "%", "&", "|", "<<"])
                return f"({self.expr(scope, 'int', depth + 1)} {op} {self.expr(scope, 'int', depth + 1)})"
            if t == "float":
                op = r.choice(["+", "-", "*", "/"])
                return f"({self.expr(scope, 'float', depth + 1)} {op} {self.expr(scope, r.choice(['float', 'int']), depth + 1)})"
            if t == "bool":
                form = r.choice(["cmp", "and", "not", "in"])
                if form == "cmp":
                    ct = r.choice(["int", "float", "str", "u8"])
                    op = r.choice(["==", "!=", "<", "<=", ">", ">="])
                    return f"({self.expr(scope, ct, depth + 1)} {op} {self.expr(scope, ct, depth + 1)})"
                if form == "and":
                    return f"({self.expr(scope, 'bool', depth + 1)} {r.choice(['and', 'or'])} {self.expr(scope, 'bool', depth + 1)})"
                if form == "not":
                    return f"(not {self.expr(scope, 'bool', depth + 1)})"
                return f"({self.expr(scope, 'str', depth + 1)} in {self.expr(scope, 'str', depth + 1)})"
            if t == "str":
                return f"({self.expr(scope, 'str', depth + 1)} + {self.expr(scope, 'str', depth + 1)})"
            if t in ("u8", "i32"):
                return f"({self.expr(scope, t, depth + 1)} {r.choice(['+', '-', '*'])} {self.expr(scope, t, depth + 1)})"
        if depth < 3 and 0.35 <= k < 0.5:
            if t == "int":
                return f"len({self.expr(scope, 'str', depth + 1)})"
            if t == "float":
                return f"-{self.expr(scope, 'float', depth + 1)}" if r.random() < 0.5 else lit(r, t)
        if 0.5 <= k < 0.65 and self.funcs:
            fname, ptypes, ret = r.choice(self.funcs)
            if ret == t:
                n = len(ptypes) + (r.choice([0, 0, 0, 1, -1]) if r.random() < 0.15 else 0)
                args = [self.expr(scope, ptypes[i] if i < len(ptypes) else "int", depth + 1) for i in range(max(n, 0))]
                return f"{fname}({', '.join(args)})"
        if k < 0.85 and cands:
            return r.choice(cands)
        if r.random() < 0.04:
            return r.choice(["undefined_name", "zzz"])
        return lit(r, t)

    def block(self, scope, ret, indent, depth, in_loop):
        r = self.rnd
        n = r.randint(1, 4)
        pad = "    " * indent
        for _ in range(n):
            k = r.random()
            if k < 0.30:
                t = r.choice(VALUE_TYPES)
                name = self.fresh()
                self.lines.append(f"{pad}{name}: {t} = {self.expr(scope, t)}")
                scope[name] = t
            elif k < 0.42 and scope:
                name = r.choice(list(scope))
                self.lines.append(f"{pad}{name} = {self.expr(scope, scope[name])}")
            elif k < 0.50 and scope and r.random() < 0.3:
                # yeniden bildirim (kimi zaman farklı tip)
                name = r.choice(list(scope))
                t = r.choice(VALUE_TYPES) if r.random() < 0.5 else scope[name]
                self.lines.append(f"{pad}{name}: {t} = {self.expr(scope, t)}")
                scope[name] = t if r.random() < 0.5 else scope[name]
            elif k < 0.60:
                self.lines.append(f"{pad}print({self.expr(scope, r.choice(VALUE_TYPES))})")
            elif k < 0.72 and depth < 2:
                cond = self.expr(scope, "bool", wrong=0.1)
                self.lines.append(f"{pad}if {cond}:")
                self.block(dict(scope), ret, indent + 1, depth + 1, in_loop)
                if r.random() < 0.4:
                    self.lines.append(f"{pad}elif {self.expr(scope, 'bool', wrong=0.1)}:")
                    self.block(dict(scope), ret, indent + 1, depth + 1, in_loop)
                if r.random() < 0.5:
                    self.lines.append(f"{pad}else:")
                    self.block(dict(scope), ret, indent + 1, depth + 1, in_loop)
            elif k < 0.80 and depth < 2:
                self.lines.append(f"{pad}while {self.expr(scope, 'bool', wrong=0.1)}:")
                self.block(dict(scope), ret, indent + 1, depth + 1, True)
            elif k < 0.86:
                self.lines.append(f"{pad}{r.choice(['break', 'continue', 'pass'])}" if (in_loop or r.random() < 0.2) else f"{pad}pass")
            elif k < 0.93 and ret is not None:
                if ret == "None":
                    self.lines.append(f"{pad}return" if r.random() < 0.8 else f"{pad}return {self.expr(scope, 'int')}")
                else:
                    self.lines.append(f"{pad}return {self.expr(scope, ret)}")
            elif k < 0.97:
                self.lines.append(f"{pad}{self.expr(scope, r.choice(VALUE_TYPES))}")
            else:
                self.lines.append(f"{pad}_ = {self.expr(scope, r.choice(VALUE_TYPES))}")

    def program(self):
        r = self.rnd
        for _ in range(r.randint(0, 3)):
            name = self.fresh("f")
            ptypes = [r.choice(VALUE_TYPES) for _ in range(r.randint(0, 3))]
            ret = r.choice(VALUE_TYPES + ["None"])
            params = ", ".join(f"p{i}: {t}" for i, t in enumerate(ptypes))
            self.lines.append(f"def {name}({params}) -> {ret}:")
            scope = {f"p{i}": t for i, t in enumerate(ptypes)}
            start = len(self.lines)
            self.block(scope, ret, 1, 0, False)
            if ret != "None" and r.random() < 0.8:
                self.lines.append(f"    return {self.expr(scope, ret)}")
            self.lines.append("")
            self.funcs.append((name, ptypes, ret))
        if r.random() < 0.3:
            t = r.choice(["int", "str", "float"])
            self.lines.append(f"G{self.counter}: {t} = {lit(r, t)}")
        scope = {}
        self.block(scope, None, 0, 0, False)
        return "\n".join(self.lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--count", type=int, default=500)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    for i in range(args.count):
        rnd = random.Random(args.seed * 1_000_003 + i)
        src = Gen(rnd).program()
        with open(os.path.join(args.out, f"g{args.seed}_{i}.nox"), "w", encoding="utf-8") as f:
            f.write(src)


if __name__ == "__main__":
    main()
