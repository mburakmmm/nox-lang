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
COMPOSITE = ["list[int]", "list[str]", "dict[str, int]", "int | None", "float | None", "list[list[int]]"]
DECL_TYPES = VALUE_TYPES + COMPOSITE


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
    if t == "list[int]":
        return rnd.choice(["[]", "[1, 2, 3]", "[7]", '[1, "a"]'])
    if t == "list[str]":
        return rnd.choice(["[]", '["a", "b"]', '["x"]', "[1]"])
    if t == "dict[str, int]":
        return rnd.choice(["{}", '{"a": 1}', '{"a": 1, "b": 2}', '{1: 1}'])
    if t == "list[list[int]]":
        return rnd.choice(["[]", "[[1], [2, 3]]", "[[]]", "[[1], 2]"])
    if t in ("int | None", "float | None"):
        return rnd.choice(["None", "5", "1.5", lit(rnd, t.split(" ")[0])])
    return "None"


class Gen:
    def __init__(self, rnd, use_async=False, use_methods=False, use_builtins=False):
        self.rnd = rnd
        self.use_builtins = use_builtins
        self.use_async = use_async
        self.use_methods = use_methods
        self.funcs = []  # (name, [param types], ret)
        self.lines = []
        self.counter = 0
        self.classes = {}  # ad -> {"fields": {ad: tip}, "methods": {ad: ([ptipler], ret)}, "init": [ptipler]}

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
        if t in self.classes:
            if cands and k < 0.6:
                return r.choice(cands)
            init = self.classes[t]["init"]
            n = len(init) + (r.choice([1, -1]) if r.random() < 0.1 else 0)
            return f"{t}({', '.join(self.expr(scope, init[i] if 0 <= i < len(init) else 'int', depth + 1) for i in range(max(n, 0)))})"
        # sınıf örneği üzerinden alan okuma / metod çağrısı
        objs = [(v, vt) for v, vt in scope.items() if vt in self.classes and "." not in v]
        if objs and depth < 3 and r.random() < 0.18:
            ov, ot = r.choice(objs)
            ci = self.classes[ot]
            fs = [f for f, ft in ci["fields"].items() if ft == t]
            ms = [m for m, (pt, rt) in ci["methods"].items() if rt == t]
            if fs and (not ms or r.random() < 0.5):
                return f"{ov}.{r.choice(fs)}"
            if ms:
                m = r.choice(ms)
                pts = ci["methods"][m][0]
                n = len(pts) + (r.choice([1, -1]) if r.random() < 0.1 else 0)
                return f"{ov}.{m}({', '.join(self.expr(scope, pts[i] if 0 <= i < len(pts) else 'int', depth + 1) for i in range(max(n, 0)))})"
            if r.random() < 0.15:
                return f"{ov}.nofield"
        if t in COMPOSITE:
            if cands and k < 0.6:
                return r.choice(cands)
            if t.startswith("list[") and depth < 3 and k < 0.8 and t in ("list[int]", "list[str]"):
                return f"({self.expr(scope, t, depth + 1)} + {self.expr(scope, t, depth + 1)})"
            return lit(r, t)
        if depth < 3 and k < 0.35:
            if t == "int":
                op = r.choice(["+", "-", "*", "//", "%", "&", "|", "<<"])
                return f"({self.expr(scope, 'int', depth + 1)} {op} {self.expr(scope, 'int', depth + 1)})"
            if t == "float":
                op = r.choice(["+", "-", "*", "/"])
                return f"({self.expr(scope, 'float', depth + 1)} {op} {self.expr(scope, r.choice(['float', 'int']), depth + 1)})"
            if t == "bool":
                form = r.choice(["cmp", "and", "not", "in", "inlist", "indict"])
                if form == "inlist":
                    return f"({self.expr(scope, 'int', depth + 1)} in {self.expr(scope, 'list[int]', depth + 1)})"
                if form == "indict":
                    return f"({self.expr(scope, 'str', depth + 1)} in {self.expr(scope, 'dict[str, int]', depth + 1)})"
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
                return r.choice([f"len({self.expr(scope, 'str', depth + 1)})", f"len({self.expr(scope, 'list[int]', depth + 1)})", f"len({self.expr(scope, 'dict[str, int]', depth + 1)})", f"{self.expr(scope, 'list[int]', depth + 1)}[{self.expr(scope, 'int', depth + 1)}]", f'{self.expr(scope, "dict[str, int]", depth + 1)}["a"]'])
            if t == "str":
                return f"{self.expr(scope, 'list[str]', depth + 1)}[{self.expr(scope, 'int', depth + 1)}]"
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
                t = r.choice(DECL_TYPES + list(self.classes))
                name = self.fresh()
                self.lines.append(f"{pad}{name}: {t} = {self.expr(scope, t)}")
                scope[name] = t
            elif k < 0.42 and scope:
                name = r.choice(list(scope))
                objs = [(v, vt) for v, vt in scope.items() if vt in self.classes and "." not in v]
                if objs and r.random() < 0.35:
                    ov, ot = r.choice(objs)
                    fl = list(self.classes[ot]["fields"])
                    if fl:
                        f = r.choice(fl)
                        self.lines.append(f"{pad}{ov}.{f} = {self.expr(scope, self.classes[ot]['fields'][f])}")
                    else:
                        self.lines.append(f"{pad}{ov}.newf = {self.expr(scope, 'int')}")
                else:
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
                if r.random() < 0.5:
                    self.lines.append(f"{pad}while {self.expr(scope, 'bool', wrong=0.1)}:")
                    self.block(dict(scope), ret, indent + 1, depth + 1, True)
                else:
                    form = r.choice(["range", "range2", "list", "str", "dict", "bad"])
                    v = self.fresh("it")
                    inner = dict(scope)
                    if form == "range":
                        hdr, vt = f"range({self.expr(scope, 'int')})", "int"
                    elif form == "range2":
                        hdr, vt = f"range({self.expr(scope, 'int')}, {self.expr(scope, 'int')}, {r.choice(['1', '2', '0'])})", "int"
                    elif form == "list":
                        et = r.choice(["list[int]", "list[str]"])
                        hdr, vt = self.expr(scope, et), et[5:-1]
                    elif form == "str":
                        hdr, vt = self.expr(scope, "str"), "str"
                    elif form == "dict":
                        hdr, vt = self.expr(scope, "dict[str, int]"), "str"
                    else:
                        hdr, vt = self.expr(scope, r.choice(["int", "float", "bool"])), "int"
                    self.lines.append(f"{pad}for {v} in {hdr}:")
                    inner[v] = vt
                    self.block(inner, ret, indent + 1, depth + 1, True)
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

    def gen_class(self):
        r = self.rnd
        cname = self.fresh("C")
        nf = r.randint(0, 3)
        ftypes = {f"f{i}": r.choice(["int", "float", "str", "bool"]) for i in range(nf)}
        init = [r.choice(["int", "float", "str", "bool"]) for _ in range(r.randint(0, 3))]
        self.lines.append(f"class {cname}:")
        declared = [f for f in ftypes if r.random() < 0.5]
        for f in declared:
            self.lines.append(f"    {f}: {ftypes[f]}")
        scope0 = {f"p{i}": t for i, t in enumerate(init)}
        if r.random() < 0.92:
            params = "".join(f", p{i}: {t}" for i, t in enumerate(init))
            self.lines.append(f"    def __init__(self{params}) -> None:")
            body = []
            for f, ft in ftypes.items():
                if r.random() < 0.9:
                    val = self.expr(scope0, ft, depth=1)
                    if f in declared or r.random() < 0.6:
                        body.append(f"        self.{f} = {val}")
                    else:
                        body.append(f"        self.{f}: {ft} = {val}")
            self.lines.extend(body or ["        pass"])
        methods = {}
        for mi in range(r.randint(0, 2)):
            mname = f"m{mi}"
            pt = [r.choice(["int", "float", "str", "bool"]) for _ in range(r.randint(0, 2))]
            ret = r.choice(["int", "float", "str", "bool", "None"])
            ms = {f"p{i}": t for i, t in enumerate(pt)}
            ms.update({f"self.{f}": t for f, t in ftypes.items()})
            params = "".join(f", p{i}: {t}" for i, t in enumerate(pt))
            self.lines.append(f"    def {mname}(self{params}) -> {ret}:")
            if ret == "None":
                if r.random() < 0.5 and ftypes:
                    f = r.choice(list(ftypes))
                    self.lines.append(f"        self.{f} = {self.expr(ms, ftypes[f], depth=1)}")
                else:
                    self.lines.append("        pass")
            else:
                self.lines.append(f"        return {self.expr(ms, ret, depth=1)}")
            methods[mname] = (pt, ret)
        if not declared and not ftypes and not methods:
            self.lines.append("    pass")
        self.lines.append("")
        # yalnız __init__ kurulduysa alanlar kayıtlı sayılır (kasıtlı hatalar tutarsız olabilir; Zig karar verir)
        self.classes[cname] = {"fields": ftypes, "methods": methods, "init": init}

    def gen_async(self):
        """`async def` (Task[T] parametreleri await edilir; güvenli olmayan parametre tipi), async işleve doğrudan çağrı, await kapsamı/operandı hataları."""
        r = self.rnd
        asyncs = []
        for _ in range(r.randint(1, 2)):
            name = self.fresh("a")
            pts = [r.choice(VALUE_TYPES + ["Task[int]", "Task[str]", "Task[float]", "list[int]", "int | None"]) for _ in range(r.randint(0, 3))]
            ret = r.choice(VALUE_TYPES + ["None"])
            self.lines.append(f"async def {name}({', '.join(f'p{i}: {t}' for i, t in enumerate(pts))}) -> {ret}:")
            scope = {f"p{i}": t for i, t in enumerate(pts) if t in VALUE_TYPES}
            n0 = len(self.lines)
            for i, t in enumerate(pts):
                if t.startswith("Task[") and r.random() < 0.8:
                    inner = t[5:-1]
                    wt = inner if r.random() < 0.9 else r.choice(VALUE_TYPES)
                    self.lines.append(f"    w{i}: {wt} = await p{i}")
                    scope[f"w{i}"] = wt
            self.block(scope, ret, 1, 0, False)
            if ret != "None" and r.random() < 0.8:
                self.lines.append(f"    return {self.expr(scope, ret)}")
            if len(self.lines) == n0:
                self.lines.append("    pass")
            self.lines.append("")
            asyncs.append((name, pts, ret))
        if r.random() < 0.3:  # sync işlevde await
            self.lines.append(f"def {self.fresh('s')}() -> None:")
            self.lines.append(f"    x: int = await {lit(r, 'int')}")
            self.lines.append("")
        name, pts, ret = r.choice(asyncs)
        if r.random() < 0.35 and all(t in VALUE_TYPES for t in pts):  # async işleve doğrudan çağrı
            args = ", ".join(self.expr({}, t, depth=1) for t in pts)
            self.lines.append(f"{self.fresh('d')}: {ret if ret != 'None' else 'int'} = {name}({args})")
        if r.random() < 0.3:  # Task olmayan operand
            self.lines.append(f"{self.fresh('b')}: int = await {r.choice([lit(r, 'int'), lit(r, 'str')])}")

    def gen_methods(self):
        """list/dict yerleşik metotları: doğru kullanım + yanlış argüman sayısı/tipi, büyüme alıcısı, Optional/int alıcı, tanımsız metot."""
        r = self.rnd
        self.lines += ["xs: list[int] = [1, 2, 3]", 'ys: list[str] = ["a"]', "fs: list[float] = [1.5]", "bs: list[bool] = [True]", "zs: list[list[int]] = [[1]]", "us: list[u8] = []",
                       'd: dict[str, int] = {"a": 1}', "n: int = 3", "o: int | None = None", "def mk() -> list[int]:", "    return [1, 2]", ""]
        iv = lambda: r.choice(["1", "2", "7", "n", "xs[0]", "1.5", '"a"', "True"])
        sv = lambda: r.choice(['"a"', '"b"', "ys[0]", "1"])
        tpl = [
            lambda: f"xs.append({iv()})", lambda: "xs.append()", lambda: "xs.append(1, 2)", lambda: f"ys.append({sv()})", lambda: f"fs.append({iv()})",
            lambda: f"us.append({r.choice(['1', '300', 'n'])})", lambda: f"xs.insert({iv()}, {iv()})", lambda: "xs.insert(1)", lambda: f"ys.insert(0, {sv()})",
            lambda: "xs.pop()", lambda: f"xs.pop({iv()})", lambda: "xs.pop(1, 2)", lambda: "xs.sort()", lambda: "ys.sort()", lambda: r.choice(["zs.sort()", "bs.sort()", "us.sort()"]),
            lambda: "xs.sort(1)", lambda: f"xs.{r.choice(['reverse', 'clear'])}({r.choice(['', '1'])})", lambda: "c: list[int] = xs.copy()", lambda: "c: list[str] = xs.copy()",
            lambda: "xs.copy(1)", lambda: f"xs.remove({iv()})", lambda: f"ys.remove({sv()})", lambda: f"bs.remove({r.choice(['True', '1'])})", lambda: f"zs.remove({r.choice(['[1]', '1'])})",
            lambda: f"i: int = xs.index({iv()})", lambda: f"i: int = fs.count({iv()})", lambda: "i: int = xs.index()", lambda: f"xs.{r.choice(['foo', 'push', 'add'])}(1)",
            lambda: "mk().append(1)", lambda: "mk().pop()", lambda: f"n.{r.choice(['append', 'pop', 'keys'])}(1)", lambda: f"o.{r.choice(['append', 'get', 'pop'])}(1)",
            lambda: f"undefined_var.{r.choice(['append', 'get'])}(1)",
            lambda: f"d.contains({sv()})", lambda: "d.contains()", lambda: "d.len()", lambda: "d.len(1)", lambda: "k: list[str] = d.keys()", lambda: "v: list[int] = d.values()",
            lambda: "k: list[int] = d.keys()", lambda: "d.keys(1)", lambda: f"g: int | None = d.get({sv()})", lambda: f"g: int = d.get({sv()}, {iv()})", lambda: "d.get()", lambda: f"zs[{r.choice(['0', 'n', '1.5'])}].{r.choice(['append', 'insert'])}({r.choice(['1', '0, 1', '\"a\"'])})", lambda: "zs[mk()[0]].append(1)", lambda: f"xs.extend({r.choice(['xs', 'ys', '[1]', '1'])})", lambda: "e: int = xs.extend(xs)", lambda: "ys.extend()", lambda: "d.extend(1)", lambda: f"g: int = d.get({sv()})", lambda: "g: str | None = d.get(\"a\")",
            lambda: f"p: int = d.pop({sv()})", lambda: f"p: int = d.pop({sv()}, {iv()}, 1)", lambda: f"d.setdefault({sv()}, {iv()})", lambda: "d.setdefault(1)",
            lambda: "d.clear()", lambda: "d.clear(1)", lambda: "e: dict[str, int] = d.copy()", lambda: f"d.update({r.choice(['d', '1', 'xs'])})", lambda: "d.update()",
            lambda: f"d.{r.choice(['nope', 'remove', 'add'])}()",
        ]
        for _ in range(r.randint(1, 5)):
            self.lines.append(r.choice(tpl)())

    def gen_builtins(self):
        """yerleşik dönüşüm/ölçü çağrıları (3.10 dilim B): str/int/float/repr, sabit-genişlikli cast, sizeof/alignof/offsetof, super(), tanımsız/yerel değer çağrısı, prelude yönlendirmeli adlar."""
        r = self.rnd
        self.lines += ["class P:", "    a: int", "    b: str", "    def __init__(self, a: int, b: str) -> None:", "        self.a = a", "        self.b = b", "",
                       "def f1(x: int) -> int:", "    return x + 1", "",
                       "n: int = 3", "x: float = 1.5", 's: str = "12"', "t: bool = True", "u: u8 = 5", "k: i32 = 7", "xs: list[int] = [1, 2]", 'd: dict[str, int] = {"a": 1}', "o: int | None = None",
                       "p: P = P(1, \"q\")", ""]
        a1 = lambda: r.choice(["n", "x", "s", "t", "u", "k", "xs", "d", "o", "p", "1", "2.5", '"7"', "True", "None", "xs[0]", "f1(1)", "undefined_v"])
        two = lambda: f"{a1()}, {a1()}"
        tpl = [
            lambda: f"a: str = str({a1()})", lambda: "a: str = str()", lambda: f"a: str = str({two()})", lambda: f"a: int = int({a1()})", lambda: "a: int = int()", lambda: f"a: int = int({two()})",
            lambda: f"a: float = float({a1()})", lambda: "a: float = float()", lambda: f"a: float = float({two()})", lambda: f"a: str = repr({a1()})", lambda: "a: str = repr()", lambda: f"a: str = repr({two()})",
            lambda: f"a: str = repr({r.choice(['f1', 'None'])})",
            lambda: f"a: {r.choice(['u8', 'u16', 'u32', 'u64', 'usize', 'i8', 'i16', 'i32', 'i64', 'isize'])} = {r.choice(['u8', 'u16', 'u32', 'u64', 'usize', 'i8', 'i16', 'i32', 'i64', 'isize'])}({a1()})",
            lambda: f"a: u8 = u8({two()})", lambda: "a: i32 = i32()", lambda: f"a: usize = {r.choice(['sizeof', 'alignof'])}({r.choice(['int', 'float', 'bool', 'str', 'u8', 'i64', 'P', 'ptr', 'Nope', 'n', '1', 'f1'])})",
            lambda: f"a: usize = {r.choice(['sizeof', 'alignof'])}()", lambda: f"a: usize = sizeof(int, int)", lambda: f"a: usize = offsetof({r.choice(['P', 'int', 'Nope', 'n', '1'])}, {r.choice(['\"a\"', '\"b\"', '\"zz\"', 'n', '1'])})",
            lambda: "a: usize = offsetof(P)", lambda: "a: usize = offsetof(P, \"a\", 1)", lambda: f"a: int = {r.choice(['sizeof', 'alignof', 'offsetof'])}(P, \"a\")",
            lambda: f"a: int = {r.choice(['super', 'nope', 'n', 'o', 'xs', 'p', 'u'])}({r.choice(['', '1', 'n'])})",
            lambda: f"a: int = {r.choice(['abs', 'chr', 'ord', 'divmod', 'isinstance', 'input'])}({a1()})",
            lambda: f"a = {r.choice(['max', 'min', 'sorted', 'sum', 'round', 'map', 'filter', 'any', 'all', 'list', 'set', 'bool', 'next', 'zip', 'enumerate', 'reversed', 'hex', 'oct', 'bin', 'pow', 'format'])}({a1()})",
            lambda: f"a: int = int({r.choice(['s', '\"7\"'])}, {r.choice(['2', '16', 'n'])})",
            lambda: f"a: str = str({a1()}, end=\"\")", lambda: f"a: int = int(x={a1()})", lambda: f"a: usize = sizeof(int, x=1)",
            lambda: f"a: int = f1({r.choice(['n', 'x', 's'])})", lambda: f"a: int = n(1)", lambda: f"a: int = s({a1()})", lambda: f"a: int = {r.choice(['P', 'f1'])}({a1()})",
            lambda: f"a: int = {r.choice(['bytes', 'ptr_to_int', 'ptr_read', 'detach', '__nox_foo', '__nox_hash', '__nox_str_chars'])}({a1()})",
            lambda: f"print(str({a1()}), int({a1()}), float({a1()}))",
            lambda: f"a: int = len(str({a1()}))",
        ]
        for _ in range(r.randint(1, 5)):
            self.lines.append(r.choice(tpl)())

    def program(self):
        r = self.rnd
        if self.use_builtins:
            self.gen_builtins()
            return "\n".join(self.lines) + "\n"
        if self.use_methods:
            self.gen_methods()
            return "\n".join(self.lines) + "\n"
        for _ in range(r.choice([0, 0, 1, 1, 2])):
            self.gen_class()
        if self.use_async:
            self.gen_async()
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
    ap.add_argument("--async", dest="use_async", action="store_true")
    ap.add_argument("--methods", dest="use_methods", action="store_true")
    ap.add_argument("--builtins", dest="use_builtins", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    for i in range(args.count):
        rnd = random.Random(args.seed * 1_000_003 + i)
        src = Gen(rnd, args.use_async, args.use_methods, args.use_builtins).program()
        with open(os.path.join(args.out, f"g{args.seed}_{i}.nox"), "w", encoding="utf-8") as f:
            f.write(src)


if __name__ == "__main__":
    main()
