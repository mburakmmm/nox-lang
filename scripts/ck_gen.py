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
    def __init__(self, rnd, use_async=False, use_methods=False, use_builtins=False, use_recv=False, use_try=False, use_construct=False, use_ptr=False, use_extern=False, use_spawn=False, use_import=False, use_inherit=False, use_closure=False, use_tuple=False, use_generic_cls=False, use_generic_fn=False, use_prelude_proto=False, use_sig=False, use_bytes_spawn_dec=False, use_consts_ffi_intr=False):
        self.rnd = rnd
        self.use_consts_ffi_intr = use_consts_ffi_intr
        self.use_bytes_spawn_dec = use_bytes_spawn_dec
        self.use_sig = use_sig
        self.use_prelude_proto = use_prelude_proto
        self.use_generic_fn = use_generic_fn
        self.use_generic_cls = use_generic_cls
        self.use_tuple = use_tuple
        self.use_closure = use_closure
        self.use_inherit = use_inherit
        self.use_import = use_import
        self.use_spawn = use_spawn
        self.use_extern = use_extern
        self.use_ptr = use_ptr
        self.use_construct = use_construct
        self.use_try = use_try
        self.use_recv = use_recv
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

    def gen_recv(self):
        """str + Task/Channel/TaskLocal/ThreadHandle/ThreadChannel metotları (3.10 dilim C): doğru/yanlış argüman sayısı-tipi, await bağlamı, tanımsız metot."""
        r = self.rnd
        sv = lambda: r.choice(['"a"', 's', 'u', '"xy"', '1', 'n', 'True', '1.5'])
        iv = lambda: r.choice(['0', '3', 'n', '1.5', '"a"', 'True', 'len(s)'])
        strm = [f"{m}()" for m in ["upper", "lower", "casefold", "strip", "lstrip", "rstrip", "isdigit", "isalpha", "isalnum", "isspace", "isupper", "islower", "isdecimal", "isnumeric"]]
        strm += ["title()", "capitalize()", "swapcase()", "nope()"]
        t_lines = [
            lambda: f"x: str = s.{r.choice(strm)}", lambda: f"x: bool = s.{r.choice(strm)}", lambda: f"x: int = s.{r.choice(strm)}",
            lambda: f"x: bool = s.{r.choice(['startswith', 'endswith'])}({sv()})", lambda: f"x: int = s.{r.choice(['find', 'count', 'index'])}({sv()})", lambda: f"s.{r.choice(['find', 'startswith', 'upper'])}({sv()}, {sv()})",
            lambda: f"x: str = s.replace({sv()}, {sv()})", lambda: f"x: str = s.replace({sv()})", lambda: f"x: str = s.zfill({iv()})", lambda: "x: str = s.zfill()",
            lambda: f"x: str = s.{r.choice(['ljust', 'rjust', 'center'])}({iv()})", lambda: f"x: str = s.{r.choice(['ljust', 'rjust', 'center'])}({iv()}, {sv()})", lambda: f"x: str = s.ljust({iv()}, {sv()}, 1)",
            lambda: f"x: list[str] = s.split()", lambda: f"x: list[str] = s.split({sv()})", lambda: f"x: list[str] = s.split({sv()}, {sv()})", lambda: "x: list[int] = s.split(\",\")",
            lambda: f"x: str = {r.choice(['\",\"', 's'])}.join({r.choice(['ws', 'xs', '[]', '[\"a\"]', '1'])})", lambda: "x: str = s.join()", lambda: f"x: str = n.{r.choice(['upper', 'join'])}()",
            lambda: "x: str = s.strip(\" \")", lambda: "x: str = s.title()", lambda: f"s.{r.choice(['upper', 'foo', 'append'])}()",
        ]
        c_lines = [
            lambda: f"t.{r.choice(['cancel', 'is_done'])}({r.choice(['', '1'])})", lambda: f"x: bool = t.is_done()", lambda: f"x: bool = t.wait({iv()})", lambda: "x: bool = t.wait()",
            lambda: f"x: int = t.wait_any({r.choice(['t', 'ch', 'n'])}, {iv()})", lambda: "x: int = t.wait_any(t)", lambda: f"t.{r.choice(['join', 'result', 'nope'])}()",
            lambda: f"await ch.send({sv()})", lambda: f"ch.send({sv()})", lambda: "x: int = await ch.recv()", lambda: "x: int = ch.recv()", lambda: "x: str = await ch.recv()", lambda: "await ch.send()", lambda: "await ch.recv(1)",
            lambda: f"x: bool = ch.wait({iv()})", lambda: "x: bool = ch.wait()", lambda: f"x: int = ch.wait_any({r.choice(['ch', 'tc', 'n'])}, {iv()})", lambda: f"x: int = ch.wait_any(ch, {r.choice(['ch', 'ch2'])}, {iv()})", lambda: "x: int = ch.wait_any(5)",
            lambda: "ch.nope()", lambda: f"await tc.send({sv()})", lambda: "tc.send(1)", lambda: "x: int = await tc.recv()", lambda: "x: int = tc.recv()", lambda: "tc.wait(1)", lambda: f"await th.join()", lambda: "x: int = th.join()",
            lambda: "x: int = await th.join()", lambda: "th.cancel()", lambda: "th.cancel(1)", lambda: "th.nope()", lambda: "await th.cancel()",
            lambda: "x: str | None = tl.get()", lambda: "x: str = tl.get()", lambda: "tl.get(1)", lambda: f"tl.set({sv()})", lambda: "tl.set()", lambda: "tl.clear()", lambda: "tl.clear(1)", lambda: "tl.nope()",
            lambda: "x: str = await ch2.recv()", lambda: "x: str = ch2.recv()", lambda: "await ch2.send(\"a\")", lambda: "x: str = th2.join()", lambda: "x: int = th2.join()", lambda: "x: int = th.cancel()",
            lambda: "x: int = t.cancel()", lambda: "x: int = ch.send(1)", lambda: "x: int = tl.set(\"a\")", lambda: "x: int = tl.clear()", lambda: "x: str = await tc.recv()", lambda: "x: int = await th2.join()",
            lambda: "x: int = await t", lambda: "x: int = await n", lambda: f"x: int = await {r.choice(['s.upper()', 'ch.wait(1)', 'th.cancel()', 'xs.pop()'])}",
        ]
        base = "ch: Channel[int], ch2: Channel[str], tc: ThreadChannel[int], t: Task[int], s: str, n: int, xs: list[int], ws: list[str], u: str"
        for k in range(r.randint(1, 2)):
            is_async = r.random() < 0.6
            # async parametre kısıtı: ThreadHandle/TaskLocal yalnız eşzamanlı işlevlerde
            sig = base if is_async else base + ", th: ThreadHandle[int], th2: ThreadHandle[str], tl: TaskLocal[str]"
            self.lines.append(f"{'async ' if is_async else ''}def w{k}({sig}) -> None:")
            for _ in range(r.randint(1, 4)):
                src = r.choice(t_lines + c_lines)()
                for _try in range(10):
                    if not is_async or ("th." not in src and "th2." not in src and "tl." not in src):
                        break
                    src = r.choice(t_lines + c_lines)()
                self.lines.append("    " + src)
            self.lines.append("")

    def gen_try(self):
        """raise/try/except/finally/with/del (3.9 dilim): bilinmeyen sınıf, çıplak except, `as` çakışması, with sözleşmesi ihlalleri, del hedefleri, her-yolda-döner analizi."""
        r = self.rnd
        self.lines += [
            "class E1:", "    code: int", "    def __init__(self, code: int) -> None:", "        self.code = code", "",
            "class E2:", "    msg: str", "    def __init__(self, msg: str) -> None:", "        self.msg = msg", "",
            "class CM:", "    n: int", "    def __init__(self, n: int) -> None:", "        self.n = n", "    def __enter__(self) -> int:", "        return self.n", "    def __exit__(self) -> None:", "        pass", "",
            "class CM2:", "    def __enter__(self, x: int) -> int:", "        return x", "    def __exit__(self) -> None:", "        pass", "",
            "class CM3:", "    def __enter__(self) -> str:", "        return \"a\"", "    def __exit__(self) -> int:", "        return 1", "",
            "class CM4:", "    def __enter__(self) -> int:", "        return 1", "",
            "class CM5:", "    def __exit__(self) -> None:", "        pass", "",
            "class CM6:", "    def __enter__(self) -> int:", "        return 1", "    def __exit__(self, x: int) -> None:", "        pass", "",
            "xs: list[int] = [1, 2]", "d: dict[str, int] = {\"a\": 1}", "n: int = 3", "s: str = \"q\"", "o: int | None = None", ""]
        ex = lambda: r.choice(["E1(1)", "E2(\"m\")", "E1(\"x\")", "1", "\"s\"", "None", "n", "xs", "E1", "CM(1)", "undefined_q"])
        cls = lambda: r.choice(["E1", "E2", "CM", "Nope", "int", "str", "ValueError"])
        body = lambda ind: r.choice([f"{ind}n = n + 1", f"{ind}raise {ex()}", f"{ind}pass", f"{ind}x: int = len(xs)", f"{ind}print(s)", f"{ind}del {r.choice(['d[\"a\"]', 'xs[0]', 'd[1]', 'xs[\"a\"]', 'n', 's[0]', 'o', 'undefined_d[0]', 'd'])}"])
        def trystmt(ind, ret_kind):
            out = [f"{ind}try:"]
            for _ in range(r.randint(1, 2)):
                out.append(body(ind + "    "))
            if ret_kind and r.random() < 0.5:
                out.append(f"{ind}    return {r.choice(['1', 's', 'n'])}")
            nex = r.choice([0, 1, 1, 2])
            for k in range(nex):
                form = r.choice(["cls"] * 6 + ["cls_as"] * 6 + ["bare", "bare", "dotted"] if r.random() < 0.05 else ["cls", "cls_as", "bare"])
                if form == "bare":
                    out.append(f"{ind}except:")
                elif form == "dotted":
                    out.append(f"{ind}except mod.{cls()}:")
                elif form == "cls":
                    out.append(f"{ind}except {cls()}:")
                else:
                    out.append(f"{ind}except {cls()} as {r.choice(['e', 'n', 'xs', 'err'])}:")
                for _ in range(r.randint(1, 2)):
                    out.append(body(ind + "    "))
                if ret_kind and r.random() < 0.5:
                    out.append(f"{ind}    return {r.choice(['1', 's'])}")
            if nex == 0 or r.random() < 0.4:
                out.append(f"{ind}finally:")
                out.append(body(ind + "    "))
                if ret_kind and r.random() < 0.4:
                    out.append(f"{ind}    return 1")
            return out
        def withstmt(ind, ret_kind):
            head = f"{ind}{r.choice([''] * 14 + ['async '])}with {r.choice(['CM(1)', 'CM2()', 'CM3()', 'CM4()', 'CM5()', 'CM6()', 'n', 'E1(1)', 'xs', 'undefined_w'])}"
            if r.random() < 0.6:
                head += f" as {r.choice(['b', 'n', 'bb'])}"
            out = [head + ":", body(ind + "    ")]
            if ret_kind and r.random() < 0.5:
                out.append(f"{ind}    return 1")
            return out
        for k in range(r.randint(1, 3)):
            self.lines.append(f"def f{k}(p: int) -> int:")
            for _ in range(r.randint(1, 2)):
                self.lines += r.choice([trystmt, trystmt, withstmt])("    ", True)
            if r.random() < 0.3:
                self.lines.append("    return 0")
            self.lines.append("")
        for _ in range(r.randint(0, 3)):
            self.lines += r.choice([trystmt, withstmt, lambda i, rk: [body(i)]])("", False)

    def gen_construct(self):
        """`Channel[T](n)`/`ThreadChannel[T](n)`/`TaskLocal[T]()`/`ptr[T](a)`/bilinmeyen jenerik kurucular + sonuç tipinin kullanımı."""
        r = self.rnd
        self.lines += ["class P:", "    a: int", "    def __init__(self, a: int) -> None:", "        self.a = a", "", "n: int = 3", 's: str = "a"', ""]
        ety = lambda: r.choice(["int", "float", "bool", "str", "P", "list[int]", "dict[str, int]", "u8", "int | None", "Task[int]", "Channel[int]", "ThreadHandle[int]", "ThreadChannel[int]", "TaskLocal[str]", "None", "ptr", "Nope"])
        cap = lambda: r.choice(["1", "n", "0", "1.5", '"x"', "True", "", "1, 2"])
        tpl = [
            lambda: f"c: Channel[int] = Channel[{ety()}]({cap()})", lambda: f"c: Channel[{ety()}] = Channel[{ety()}]({cap()})", lambda: f"c = Channel[int]({cap()})",
            lambda: f"c: ThreadChannel[int] = ThreadChannel[{ety()}]({cap()})", lambda: f"c: ThreadChannel[{ety()}] = ThreadChannel[{ety()}]({cap()})", lambda: "c: ThreadChannel[int] = ThreadChannel[int, int](1)",
            lambda: f"t: TaskLocal[{ety()}] = TaskLocal[{ety()}]({r.choice(['', '1'])})", lambda: "t: TaskLocal[str] = TaskLocal[str, int]()", lambda: "t: TaskLocal[str] = TaskLocal[str]()",
            lambda: f"c: int = {r.choice(['Channel', 'ThreadChannel', 'TaskLocal', 'Foo', 'Box', 'mod.Box', 'list', 'dict', 'ptr', 'Task', 'P'])}[int]({cap()})",
            lambda: "c: Channel[int] = Channel[]()", lambda: "c: Channel[int] = Channel(1)", lambda: f"c: ptr[int] = ptr[int]({r.choice(['1', 'n', ''])})",
            lambda: f"c: Channel[str] = Channel[int](1)", lambda: f"c: Channel[int] = Channel[int]({cap()})\nc.send({r.choice(['1', 's'])})",
        ]
        for _ in range(r.randint(1, 4)):
            self.lines += r.choice(tpl)().split("\n")

    def gen_ptr(self):
        """lowlevel blokları + ptr ailesi: blok içi/dışı kullanım, yanlış argüman sayısı/tipi, blok-yerel adların bloktan sonra kullanımı."""
        r = self.rnd
        self.lines += ["class P:", "    a: int", "    def __init__(self, a: int) -> None:", "        self.a = a", "",
                       "n: int = 3", "x: float = 1.5", "b: bool = True", 's: str = "a"', "xs: list[int] = [1, 2]", "fs: list[float] = [1.5]", "ss: list[str] = []", "us: list[u8] = []", "o: P = P(1)", "d: dict[str, int] = {}",
                       "q: ptr = ptr_from_int(0) if False else None", ""][:-1]
        self.lines.pop()  # `q` satırı geçersiz olabilir: kaldırıldı
        self.lines += ["def cb(x: int) -> int:", "    return x", "def mk() -> list[int]:", "    return [1]", ""]
        v = lambda: r.choice(["n", "x", "b", "s", "xs", "fs", "ss", "us", "o", "d", "p", "tp", "tf", "1", "2.5", "True", '"s"', "cb", "None", "xs[0]", "mk()", "o.a"])
        iv = lambda: r.choice(["n", "1", "0", "x", "True", "xs[0]"])
        pre = ["p: ptr = ptr_from_int(0)", "tp: ptr[int] = ptr[int](0)", "tf: ptr[float] = ptr[float](16)", ""]
        tpl = [
            lambda: f"p2: ptr = ptr_from_int({v()})", lambda: "p2: ptr = ptr_from_int()", lambda: f"i: int = ptr_to_int({v()})", lambda: f"i: int = ptr_to_int({v()}, 1)",
            lambda: f"p2: ptr = ptr_add({v()}, {iv()})", lambda: f"p2: ptr = ptr_add(p)", lambda: f"i: int = ptr_read_int({v()})", lambda: f"f: float = ptr_read_float({v()})", lambda: f"c: bool = ptr_read_bool({v()})",
            lambda: f"ptr_write_int({v()}, {v()})", lambda: f"ptr_write_float({v()}, {v()})", lambda: f"ptr_write_bool({v()}, {v()})", lambda: "ptr_write_int(p)",
            lambda: f"tp2: ptr[int] = ptr_of({r.choice(['xs', 'fs', 'ss', 'us', 'mk()', 'o.a', 'n', 'o'])})", lambda: f"tp2: ptr[int] = ptr_offset({v()}, {iv()})", lambda: f"i: int = ptr_read({v()})", lambda: f"f: float = ptr_read({v()})",
            lambda: f"ptr_write({v()}, {v()})", lambda: f"i: int = ptr_read_volatile({v()})", lambda: f"ptr_write_volatile({v()}, {v()})", lambda: f"{r.choice(['memory_fence', 'compiler_fence'])}({r.choice(['', '1'])})",
            lambda: f"p2: ptr = detach({r.choice(['xs', 'd', 'o', 's', 'n', 'mk()', 'o.a', 'x'])})", lambda: f"p2: ptr = ffi_box({r.choice(['cb', 'n', 'p'])})", lambda: f"p2: ptr = adopt(p)",
            lambda: f"tp3: ptr[{r.choice(['int', 'float', 'P', 'str'])}] = ptr[{r.choice(['int', 'float', 'P', 'Nope'])}]({iv()})", lambda: "tp3: ptr[int] = ptr[int]()", lambda: "tp3: ptr[int] = ptr[int, int](1)",
            lambda: f"w: int = {r.choice(['n', '1'])}", lambda: f"z{r.randint(1,3)}: int = n", lambda: "print(zz)",
        ]
        mode = r.choice(["in", "in", "mixed", "out"])
        body = [r.choice(tpl)() for _ in range(r.randint(1, 5))]
        if mode == "out":
            self.lines += pre + body
        elif mode == "in":
            self.lines += ["lowlevel:"] + ["    " + l for l in pre + body]
        else:
            self.lines += ["lowlevel:"] + ["    " + l for l in pre + body[:len(body) // 2 + 1]]
            self.lines += body[len(body) // 2 + 1:] + [r.choice(["print(w)", "print(p)", "print(zz)", "print(tp)", "pass"])]
        if r.random() < 0.3:
            self.lines += ["def fl() -> None:", "    lowlevel:", "        q: ptr = ptr_from_int(1)", "        ptr_write_int(q, 2)", "    print(q)"]

    def gen_extern(self):
        """`extern def`: parametre/dönüş FFI güvenliği, `with_rt`, `retains(...)`, yinelenen/varsayılan değerli tanımlar, çağrı denetimi."""
        r = self.rnd
        self.lines += ["class P:", "    a: int", "    def __init__(self, a: int) -> None:", "        self.a = a", ""]
        ty = lambda: r.choice(["int", "float", "bool", "str", "None", "ptr", "u8", "i64", "ptr[int]", "list[str]", "list[int]", "list[float]", "list[u8]", "dict[str, str]", "dict[str, int]", "int | None", "P", "(int, int, ptr) -> int", "(str) -> int", "Task[int]", "Nope"])
        rt = lambda: r.choice(["int", "float", "bool", "str", "None", "ptr", "u8", "list[str]", "list[int]", "P", "dict[str, str]", "int | None", "(int) -> int", "bytes"])
        names = ["f1", "f2", "f3"]
        for k in range(r.randint(1, 3)):
            nm = r.choice(names + ["f1", "memset"])
            ps = [f"{r.choice(['a', 'b', 'c'])}{i}: {ty()}" + (" = 1" if r.random() < 0.05 else "") for i in range(r.randint(0, 3))]
            tail = r.choice(["", "", " with_rt", " retains(a0)", " retains(zz)", " with_rt retains(a0, b1)"])
            self.lines.append(f"extern def {nm}({', '.join(ps)}) -> {rt()} from \"lib\"{tail}")
        self.lines.append("def f1(x: int) -> int:")
        self.lines.append("    return x")
        calls = ["n: int = f1(1)", "n: int = f2(1, 2)", "f3()", "n: int = memset(1)", "n: int = f1()", "x: str = f2()"]
        for _ in range(r.randint(0, 3)):
            self.lines.append(r.choice(calls))
        if r.random() < 0.2:
            self.lines += ["def g() -> None:", "    extern def h() -> int from \"lib\"", "    pass"]

    def gen_spawn(self):
        """`spawn`: async/senkron/tanımsız hedefler, argüman sayısı/tipi, parametre taşıma güvenliği, sonuç Task[T] kullanımı, await ile birleşim."""
        r = self.rnd
        self.lines += ["class P:", "    a: int", "    def __init__(self, a: int) -> None:", "        self.a = a", "", "n: int = 3", 's: str = "a"', "xs: list[int] = [1]", "ch: Channel[int] = Channel[int](1)", "tc: ThreadChannel[int] = ThreadChannel[int](1)",
                       "class K:", "    def m(self) -> int:", "        return 1", "k: K = K()", "fs: list[(int) -> int] = []", ""]
        pty = lambda: r.choice(["int", "float", "bool", "str", "None", "P", "list[int]", "dict[str, int]", "int | None", "Task[int]", "Channel[int]", "ThreadChannel[int]", "ThreadHandle[int]", "(int) -> int", "u8"])
        rty = lambda: r.choice(["int", "str", "None", "bool", "float", "P", "list[int]"])
        for k in range(r.randint(1, 3)):
            ps = ", ".join(f"p{i}: {pty()}" for i in range(r.randint(0, 2)))
            kind = r.choice(["async", "async", "async", "sync"])
            rt = rty()
            body = {"int": "return 1", "str": 'return "a"', "None": "pass", "bool": "return True", "float": "return 1.5", "P": "return P(1)", "list[int]": "return [1]"}[rt]
            self.lines += [f"{'async ' if kind == 'async' else ''}def w{k}({ps}) -> {rt}:", f"    {body}", ""]
        arg = lambda: r.choice(["1", "n", "s", "1.5", "True", "P(1)", "xs", "None", "w0", "ch", "tc", "ch", "tc", ""])
        callee = lambda: r.choice(["w0", "w1", "w2", "nope", "P", "len", "n"])
        ann = lambda: r.choice(["Task[int]", "Task[int]", "Task[str]", "Task[None]", "Task[bool]", "int", "Task[P]"])
        exprs = [
            lambda: f"t: {ann()} = spawn {callee()}({arg()}, {arg()})", lambda: f"t: {ann()} = spawn {callee()}({arg()})", lambda: f"t: {ann()} = spawn {callee()}()",
            lambda: f"t: Task[int] = spawn {callee()}({arg()})", lambda: f"t: Task[str] = spawn {callee()}({arg()})", lambda: f"t: {ann()} = spawn {r.choice(['n', '1', 'xs[0]', 'P(1).a', 'w0', 'fs[0](1)'])}",
            lambda: f"t: {ann()} = spawn {callee()}(p0={arg()})", lambda: f"x: {ann()} = spawn {r.choice(['n.foo()', 's.upper()', 'P(1).a()', 'k.m()', 'k.am()', 'k.zz()', 'k.m(1)', 'nope.m()', 'k.am(1)'])}", lambda: f"spawn {callee()}({arg()})",
            lambda: f"t: {ann()} = spawn {callee()}({arg()})\nx: int = await t",lambda: f"x: int = await spawn {callee()}({arg()})", lambda: f"x: str = await spawn {callee()}({arg()})",
            lambda: f"x: int = await spawn {r.choice(['k.m()', 'k.am()'])}", lambda: f"t: {ann()} = spawn {callee()}({arg()})\nt = spawn {callee()}({arg()})",
        ]
        in_async = r.random() < 0.5
        body = []
        for _ in range(r.randint(1, 3)):
            body += r.choice(exprs)().split("\n")
        if in_async:
            self.lines += ["async def main_a() -> None:"] + ["    " + l for l in body]
        else:
            self.lines += ["def main_s() -> None:"] + ["    " + l for l in body]

    def _valid_for(self, defined, prefix, mpath, mg, valid, vtypes):
        mg = mpath.replace(".", "_")
        if defined.get(f"{mg}_g") == "f":
            valid.append(f"{prefix}.g(1)")
        if defined.get(f"{mg}_K") == "c":
            valid.append(f"{prefix}.K(1)")
            vtypes.append(f"{prefix}.K")

    def _valid_bare(self, defined, local, orig, mg, valid, vtypes, vasync):
        kind = defined.get(f"{mg}_{orig}")
        if kind in ("f", "c"):
            valid.append(f"{local}(1)")
        if kind == "c":
            vtypes.append(local)
        if kind == "a":
            vasync.append(local)

    def gen_import(self):
        """import/from-import (ham `check` kipi: içe aktarılan modülün tanımı yok; mangled adlar dosyada elle tanımlıysa çözülür): takma ad, nitelikli çağrı/tip, from-import çağrı/tip/except/spawn/değer, `nox.arch`, intrinsic, gölgeleme, yeniden dışa aktarma zinciri."""
        r = self.rnd
        mods = [("lib.util", "lib_util"), ("lib", "lib"), ("nox.fs", "nox_fs"), ("nox.math", "nox_math"), ("pkg.mod", "pkg_mod")]
        defined = {}
        for _, mg in mods:
            if r.random() < 0.6:
                self.lines += [f"def {mg}_g(a: int) -> int:", "    return a", ""]
                defined[f"{mg}_g"] = "f"
            if r.random() < 0.4:
                self.lines += [f"class {mg}_K:", "    a: int", "    def __init__(self, a: int) -> None:", "        self.a = a", ""]
                defined[f"{mg}_K"] = "c"
            if r.random() < 0.2:
                self.lines += [f"async def {mg}_ag(a: int) -> int:", "    return a", ""]
                defined[f"{mg}_ag"] = "a"
            if r.random() < 0.15:
                self.lines += [f"{mg}_V: int = 3", ""]
        if r.random() < 0.3:
            self.lines += ["class MyErr:", "    pass", ""]
        pool = mods + [("nox.arch", "nox_arch"), ("nox.arch.x86_64", "nox_arch_x86_64"), ("nox.http", "nox_http"), ("nox.thread", "nox_thread"), ("zz.yy", "zz_yy")]
        prefixes, bare = [], []
        valid, vtypes, vasync = [], [], []
        imps = []
        for _ in range(r.randint(0, 4)):
            m, mg = r.choice(pool)
            kind = r.choice(["imp", "imp", "as", "from", "from", "fromas"])
            if kind == "imp":
                imps.append(f"import {m}")
                prefixes.append(m)
                self._valid_for(defined, m, m, mg, valid, vtypes)
            elif kind == "as":
                al = r.choice(["u", "w", "q", "lib"])
                imps.append(f"import {m} as {al}")
                prefixes.append(al)
                self._valid_for(defined, al, m, mg, valid, vtypes)
            elif kind == "from":
                names = r.sample(["g", "K", "ag", "V", "h", "serve", "start"], k=r.randint(1, 2))
                imps.append(f"from {m} import {', '.join(names)}")
                bare += names
                for nm_ in names:
                    self._valid_bare(defined, nm_, nm_, mg, valid, vtypes, vasync)
            else:
                nm, al = r.choice(["g", "K", "ag", "h", "V"]), r.choice(["gg", "KK", "hh", "MyErr"])
                imps.append(f"from {m} import {nm} as {al}")
                bare.append(al)
                self._valid_bare(defined, al, nm, mg, valid, vtypes, vasync)
        shadow = r.random() < 0.15
        calls = ["1", "n"]
        for p in prefixes + r.sample(["u", "lib", "nox.fs", "zz", "nox.http"], k=r.randint(0, 2)):
            calls += [f"{p}.g(1)", f"{p}.g()", f"{p}.K(1)", f"{p}.nope(1)", f"{p}.ag(1)", f"{p}.g(1, 2)", f"{p}.V", f"{p}.serve(1)", f"{p}.start(1)", f"{p}.pool_run(1)", f"{p}.get(n)"]
        for b in bare + ["g", "K", "MyErr"]:
            calls += [f"{b}(1)", f"{b}()", f"{b}(1, 2)", b]
        types = ["int", "P"] + [f"{p}.K" for p in prefixes] + [f"{p}.Nope" for p in prefixes[:1]] + bare + ["u.K", "zz.K", "nox.fs.K", "a.b.c.K"]
        lines = []
        if self.rnd.random() < 0.5:
            lines += ["class P:", "    a: int", "    def __init__(self, a: int) -> None:", "        self.a = a", "", "n: int = 3"]
        else:
            lines += ["n: int = 3"]
        if shadow:
            lines.append(f"{r.choice(['u', 'lib', 'w', 'q'])}: int = 1")
        body = []
        for _ in range(r.randint(1, 5)):
            k = r.choice(["call", "call", "decl", "decl", "type", "try", "spawn", "value", "func"])
            c = r.choice(valid) if valid and r.random() < 0.7 else r.choice(calls)
            t = r.choice(vtypes) if vtypes and r.random() < 0.7 else r.choice(types)
            if k == "call":
                body.append(c)
            elif k == "decl":
                body.append(f"x{len(body)}: {r.choice(['int', 'str', t])} = {c}")
            elif k == "type":
                body.append(f"y{len(body)}: {t} = {r.choice(calls)}")
            elif k == "try":
                body += ["try:", f"    {c}", f"except {r.choice(bare + ['MyErr', 'Exception', 'Nope'])}:", "    pass"]
            elif k == "spawn":
                body.append(f"s{len(body)}: Task[int] = spawn {r.choice(vasync) if vasync and r.random() < 0.6 else r.choice(bare + ['lib_util_ag', 'g', 'ag'])}(1)")
            elif k == "value":
                body.append(f"z{len(body)}: int = {r.choice(bare + ['g'])}")
            else:
                body += [f"def fn{len(body)}(p: {t}) -> {t}:", f"    {r.choice(calls)}", "    return p"]
        # import deyimleri başta, gövdenin ortasında ya da bir işlev içinde
        place = r.choice(["top", "top", "top", "mid", "nested"])
        if place == "top":
            self.lines += imps + lines + body
        elif place == "mid":
            self.lines += lines + body[:len(body) // 2] + imps + body[len(body) // 2:]
        else:
            self.lines += lines + ["def inner() -> None:"] + ["    " + i for i in imps] + ["    pass"] + body

    def gen_inherit(self):
        """tekli kalıtım: ileri/geri taban, döngü, bilinmeyen taban, alan yinelemesi, override imza eşleşmesi, `__init__` devralma, `super()` çağrıları, alt sınıf atanabilirliği, çıkarsanan alanların türetilene kopyalanması.
        `clean` programlarda yapısal hata yoktur (derin yollar test edilir); diğerlerinde hatalar enjekte edilir."""
        r = self.rnd
        clean = r.random() < 0.6
        n = r.randint(2, 4)
        names = [f"C{i}" for i in range(n)]
        order = names[:]
        r.shuffle(order)
        bases = {}
        for i, nm in enumerate(names):
            k = r.random()
            if i > 0 and k < 0.7:
                bases[nm] = names[r.randrange(0, i)]
            elif not clean and k < 0.76:
                bases[nm] = r.choice(names)
            elif not clean and k < 0.82:
                bases[nm] = "Zed"
        tys = ["int", "str", "float", "bool"]
        sigs = [("m0", [], "int"), ("m1", ["int"], "int"), ("m2", ["str"], "str")]
        argl = {"int": "1", "str": '"s"', "float": "1.5", "bool": "True"}
        meta = {}
        blocks = {}

        def chain(nm):
            out, seen = [], set()
            while nm in names and nm not in seen:
                seen.add(nm)
                out.append(nm)
                nm = bases.get(nm)
            return out

        def init_params(nm):
            for c in chain(nm):
                if meta[c][2]:
                    return meta[c][3]
            return []

        def meths_of(nm):
            d = {}
            for c in reversed(chain(nm)):
                for m in meta[c][4]:
                    d[m[0]] = m
            return d

        def fields_of(nm):
            d = {}
            for c in reversed(chain(nm)):
                d.update(meta[c][0])
                d.update(meta[c][1])
            return d

        for i, nm in enumerate(names):
            sfx = str(i) if clean else ""
            fields = {}
            for fn in r.sample(["a", "b", "c"], k=r.randint(0, 2)):
                fields[fn + sfx] = r.choice(tys)
            inferred = {}
            if r.random() < 0.5:
                inferred[r.choice(["x", "y", "a"]) + sfx] = r.choice(tys)
            has_init = r.random() < 0.7
            iparams = [r.choice(tys) for _ in range(r.randint(0, 2))]
            meths = []
            for m in sigs:
                if r.random() < 0.5:
                    if not clean and r.random() < 0.15:
                        m = (m[0], m[1], r.choice(["int", "str"]))
                    meths.append(m)
            meta[nm] = (fields, inferred, has_init, iparams, meths)
            lines = [f"class {nm}" + (f"({bases[nm]})" if nm in bases else "") + ":"]
            for fn, ft in fields.items():
                lines.append(f"    {fn}: {ft}")
            if has_init:
                ps = ", ".join(["self"] + [f"p{j}: {t}" for j, t in enumerate(iparams)])
                lines.append(f"    def __init__({ps}) -> None:")
                body = []
                if nm in bases and r.random() < 0.6:
                    if clean:
                        bp = init_params(bases[nm]) if bases[nm] in meta else []
                        args = ", ".join(argl[t] for t in bp)
                    else:
                        args = ", ".join(r.choice(["1", '"s"', "1.5"]) for _ in range(r.randint(0, 2)))
                    body.append(f"super().__init__({args})")
                for fn, ft in fields.items():
                    if clean or r.random() < 0.85:
                        body.append(f"self.{fn} = {argl[ft]}")
                for fn, ft in inferred.items():
                    body.append(f"self.{fn} = {argl[ft]}")
                lines += ["        " + b for b in body] or ["        pass"]
            for mn, mp_, mr in meths:
                ps = ", ".join(["self"] + [f"q{j}: {t}" for j, t in enumerate(mp_)])
                lines.append(f"    def {mn}({ps}) -> {mr}:")
                rv = {"int": "1", "str": '"s"'}[mr]
                if nm in bases and r.random() < 0.3:
                    inh = meths_of(bases[nm]) if (clean and bases[nm] in meta) else {}
                    if clean and inh:
                        sm = r.choice(list(inh.values()))
                        sa = ", ".join(argl[t] for t in sm[1])
                        lines.append(f"        v: {sm[2]} = super().{sm[0]}({sa})")
                        lines.append(f"        return {rv}")
                    elif not clean:
                        sm = r.choice(sigs + [("zz", [], "int")])
                        sa = ", ".join(r.choice(["1", '"s"']) for _ in range(len(sm[1]) + (1 if r.random() < 0.1 else 0)))
                        lines.append(f"        return super().{sm[0]}({sa})")
                    else:
                        lines.append(f"        return {rv}")
                else:
                    lines.append(f"        return {rv}")
            if not clean and r.random() < 0.08:
                lines += ["    def bare(self) -> int:", "        return super().m0()"]
            if len(lines) == 1:
                lines.append("    pass")
            blocks[nm] = lines
        for nm in order:
            self.lines += blocks[nm] + [""]
        stmts = []
        for _ in range(r.randint(1, 5)):
            a_, b_ = r.choice(names), r.choice(names)
            k = r.choice(["ctor", "assign", "meth", "field", "wrong", "super"])
            cargs = lambda c: ", ".join(argl[t] for t in init_params(c)) if clean or r.random() < 0.8 else ", ".join(r.choice(list(argl.values())) for _ in range(r.randint(0, 2)))
            if k == "ctor":
                stmts.append(f"o{len(stmts)}: {a_} = {a_}({cargs(a_)})")
            elif k == "assign":
                if clean and a_ not in chain(b_):
                    a_ = b_
                stmts.append(f"o{len(stmts)}: {a_} = {b_}({cargs(b_)})")
            elif k == "meth":
                ms = meths_of(a_)
                if ms and (clean or r.random() < 0.8):
                    m = r.choice(list(ms.values()))
                    stmts += [f"v{len(stmts)}: {a_} = {a_}({cargs(a_)})", f"w{len(stmts)}: {m[2]} = v{len(stmts)}.{m[0]}({', '.join(argl[t] for t in m[1])})"]
                elif not clean:
                    stmts += [f"v{len(stmts)}: {a_} = {a_}({cargs(a_)})", f"w{len(stmts)}: int = v{len(stmts)}.zz()"]
            elif k == "field":
                fs = fields_of(a_)
                if fs and (clean or r.random() < 0.8):
                    fn = r.choice(list(fs))
                    stmts += [f"v{len(stmts)}: {a_} = {a_}({cargs(a_)})", f"w{len(stmts)}: {fs[fn]} = v{len(stmts)}.{fn}"]
                elif not clean:
                    stmts += [f"v{len(stmts)}: {a_} = {a_}({cargs(a_)})", f"w{len(stmts)}: int = v{len(stmts)}.nofield"]
            elif k == "wrong" and not clean:
                stmts.append(f"o{len(stmts)}: int = {a_}({cargs(a_)})")
            elif k == "super" and not clean:
                stmts.append("z = super().m0()")
        self.lines += stmts

    def gen_closure(self):
        """iç içe `def` (yakalama, yazma yasağı, eksik return, jenerik yasağı), işlev değeri çağrısı, `lambda` (beklenen tip/arite/dönüş uyuşmazlığı, modül düzeyi yakalama), `defer`."""
        r = self.rnd
        self.lines += ["def apply(f: (int) -> int, x: int) -> int:", "    return f(x)", "", "def run0(f: () -> None) -> None:", "    f()", "",
                       "def cleanup(n: int) -> None:", "    pass", "", "g0: int = 5", ""]
        in_fn = r.random() < 0.7
        ind = "    " if in_fn else ""
        body = []
        body.append(r.choice(["k: int = 3", "k: str = \"s\"", "k: int = 3"]))
        loop = r.random() < 0.25 and not in_fn
        def stmt():
            c = r.choice(["nested", "nested", "call", "lam", "lam", "lamvar", "defer", "fnvar", "capw", "nogen", "retmiss"])
            if c == "nested":
                ret = r.choice(["int", "int", "str", "None"])
                cap = r.choice(["k", "g0", "a", "zz"])
                val = {"int": f"a + {cap}", "str": f"str({cap})", "None": "pass"}[ret]
                lines = [f"def inner(a: int) -> {ret}:"]
                lines.append(f"    {'return ' if ret != 'None' else ''}{val}" if ret != "None" else "    pass")
                return lines
            if c == "call":
                return [r.choice(["x1: int = inner(1)", "x2: int = inner()", "x3: int = inner(\"s\")", "inner(1, 2)", "x4: str = inner(1)", "x5: int = nope(1)"])]
            if c == "lam":
                return [r.choice(["r1: int = apply(lambda v: v + 1, 2)", "r2: int = apply(lambda v: v + k, 2)", "r3: int = apply(lambda: 1, 2)", "r4: int = apply(lambda v, w: v, 2)", "r5: int = apply(lambda v: \"s\", 2)",
                                  "r6: int = apply(lambda v: v + g0, 2)", "r7: int = apply(lambda v: v + zz, 2)", "run0(lambda: print(1))", "run0(lambda: 1)", "run0(lambda v: print(v))"])]
            if c == "lamvar":
                return [r.choice(["f1: (int) -> int = lambda v: v * 2", "f2: () -> None = lambda: print(1)", "f3: int = lambda v: v", "f4: (int) -> str = lambda v: str(v)", "f5: (int) -> int = lambda v: k", "x6 = lambda v: v"])]
            if c == "defer":
                return [r.choice(["defer cleanup(1)", "defer cleanup()", "defer nope(1)", "defer cleanup(k)", "defer inner(1)"])]
            if c == "fnvar":
                return ["fv: (int) -> int = lambda v: v", r.choice(["y1: int = fv(1)", "y2: int = fv()", "y3: int = fv(\"s\")", "y4: str = fv(1)", "fv(1, 2)"])]
            if c == "capw":
                return ["def inner(a: int) -> int:", r.choice(["    k = 4", "    g0 = 4", "    a = 4"]), "    return a"]
            if c == "nogen":
                return [r.choice(["def gen[T](a: T) -> T:\n    return a", "def inner(a: int) -> int:\n    if a > 0:\n        return 1"])]
            return ["def inner(a: int) -> int:", "    if a > 0:", "        return 1"]
        for _ in range(r.randint(1, 5)):
            for l in stmt():
                body += l.split("\n")
        if loop:
            body = ["for i in range(3):"] + ["    " + l for l in body] + ["    h: (int) -> int = lambda v: v + i"]
        if in_fn:
            self.lines += ["def main_f() -> None:"] + ["    " + l for l in body]
            if r.random() < 0.5:
                self.lines.append("main_f()")
        else:
            self.lines += body

    def gen_tuple(self):
        """tuple[...], tuple_lit, t[k], len(t), ternary, list_comp, dict_comp, slice (Aşama 3.6 dilim A)."""
        r = self.rnd
        clean = r.random() < 0.40
        self.lines += [
            "class A:", "    v: int", "    def __init__(self, v: int) -> None:", "        self.v = v", "",
            "class B(A):", "    w: int", "    def __init__(self, v: int, w: int) -> None:", "        super().__init__(v)", "        self.w = w", "",
            "def p_none() -> None:", "    pass", "",
            "def apply(f: (int) -> int, x: int) -> int:", "    return f(x)", "",
            "xs: list[int] = [1, 2, 3]", 'ws: list[str] = ["a", "b"]', 'd: dict[str, int] = {"a": 1}',
            's: str = "abc"', "n: int = 1", "c: bool = True", "o: int | None = None",
            "t2: tuple[int, str] = (1, \"x\")", "t1: tuple[int] = (7,)",
            "ta: A = A(1)", "tb: B = B(1, 2)", "",
        ]
        good = [
            "p0: tuple[int, str] = (3, \"q\")",
            "p1: tuple[float, A] = (1, tb)",
            "p2: tuple[tuple[int, str], bool] = ((1, \"a\"), True)",
            "x0: int = t2[0]",
            "x1: str = t2[-1]",
            "x2: int = t2.f0",
            "x3: int = len(t2)",
            "q0: int = 10 if c else 20",
            "q1: list[int] = [] if c else [1]",
            "q2: list[int] | None = [] if c else [1]",
            "q3: u8 = 1 if c else 2",
            "lc0: list[int] = [i * 2 for i in range(4) if i > 0]",
            "lc1: list[int] = [x + y for x in xs for y in range(2) if x != y]",
            "lc2: list[str] = [ch for ch in s]",
            "lc3: list[int] = [len(k) for k in d]",
            "lc4: list[list[int]] = [[] for _i in range(2)]",
            "lc5: list[list[int]] | None = [[] for _i in range(2)]",
            "dc0: dict[str, int] = {w: len(w) for w in ws}",
            "dc1: dict[str, list[int]] = {w: [] for w in ws}",
            "dc2: dict[str, list[int]] | None = {w: [] for w in ws}",
            "sl0: list[int] = xs[1:3]",
            "sl1: list[int] = xs[::-1]",
            "sl2: str = s[:2]",
            "sl3: str = s[::2]",
            "sh: int = [z for z in range(3)][0]\nz_out: int = len(ws)",
            "sh2: list[int] = [n for n in range(2)]\nn_chk: int = n + 1",
            "sh3: list[str] = [x for x in range(2) for x in ws]",
        ]
        bad = [
            "eb0: tuple[] = (1,)",
            "et0: tuple[int] = ()",
            "et1: tuple[int, None] = (1, None)",
            "et2: tuple[int, int] = (1, p_none())",
            "et3: tuple[int, str] = (1, 2)",
            "et4: tuple[int, int] = (1,)",
            "ei0: int = t2[5]",
            "ei1: int = t2[-3]",
            "ei2: int = t2[n]",
            "ei3: int = t2[\"a\"]",
            "el0: str = len(t2)",
            "qt0: int = 1 if 5 else 2",
            "qt1: int = 1 if c else \"a\"",
            "qt2: int = 1 if c else 1.5",
            "qt3: None = None if c else None",
            "qt4: u8 = 1 if c else 300",
            "qt5: (int) -> int = apply if c else apply",
            "lcb0: list[int] = [i for i in range(3) if i]",
            "lcb1: list[int] = [p_none() for i in range(2)]",
            "lcb2: list[int] = [v_miss for v_miss in range(2)]\nuse_miss: int = v_miss",
            "lcb3: list[int] = [apply(lambda v: v, x) for x in xs]",
            "dcb0: dict[list[int], int] = {[1]: 1 for _k in range(1)}",
            "dcb1: dict[str, int | None] = {w: o for w in ws}",
            "dcb2: dict[str, None] = {w: p_none() for w in ws}",
            "slb0: list[int] = xs[\"a\":]",
            "slb1: list[int] = xs[:1.5]",
            "slb2: list[int] = xs[::\"1\"]",
            "slb3: list[int] = xs[::0]",
            "slb4: list[int] = xs[::-0]",
            "slb5: int = n[1:2]",
            "slb6: list[int] = o[1:2]",
            "slb7: dict[str, int] = d[1:2]",
        ]
        in_fn = r.random() < 0.7
        ind = "    " if in_fn else ""
        if in_fn:
            self.lines.append("def main_t() -> None:")
        for _ in range(r.randint(2, 5)):
            pick = r.choice(good) if clean or r.random() < 0.65 else r.choice(bad)
            for ln in pick.split("\n"):
                self.lines.append(ind + ln)
        if in_fn and r.random() < 0.5:
            self.lines.append("main_t()")

    def gen_generic_cls(self):
        """3.6 dilim B: jenerik sınıflar (`class Box[T]:`, `Pair[K, V]`, öz-referans `Node[T]`, `Sub(Box[int])`, `mod.Box[int]`, `from` reexport, `sizeof(T)`/`alignof(T)`, `subst_stmt`/`subst_expr` kapsamı ve hata durumları)."""
        r = self.rnd
        clean = r.random() < 0.45
        imp_kind = r.choice(["none", "imp", "alias", "from"])
        if imp_kind == "imp":
            self.lines += ["import lib", ""]
        elif imp_kind == "alias":
            self.lines += ["import lib as lb", ""]
        elif imp_kind == "from":
            self.lines += ["from lib import Box as LibBox", ""]

        if imp_kind != "none":
            self.lines += [
                "class lib_Box[T]:",
                "    v: T",
                "    def __init__(self, v: T) -> None:",
                "        self.v = v",
                "    def get(self) -> T:",
                "        return self.v",
                "",
            ]

        has_pair = r.random() < 0.55
        has_node = r.random() < 0.45
        has_sub = r.random() < 0.55
        has_rich = r.random() < 0.15

        if has_rich:
            self.lines += [
                "class MyErr:",
                "    pass",
                "",
                "def noop_cleanup(n: int) -> None:",
                "    pass",
                "",
                "class Ctx:",
                "    def __enter__(self) -> int:",
                "        return 1",
                "    def __exit__(self) -> None:",
                "        pass",
                "",
            ]

        self.lines += [
            "class Box[T]:",
            "    val: T",
            "    def __init__(self, v: T) -> None:",
            "        self.val = v",
            "    def get(self) -> T:",
            "        return self.val",
            "    def rebox(self, x: T) -> Box[T]:",
            "        return Box[T](x)",
            "    def sz(self) -> usize:",
            "        return sizeof(T) + alignof(T)",
            "",
        ]
        if has_pair:
            self.lines += [
                "class Pair[K, V]:",
                "    k: K",
                "    v: V",
                "    def __init__(self, k: K, v: V) -> None:",
                "        self.k = k",
                "        self.v = v",
                "    def key(self) -> K:",
                "        return self.k",
                "    def first_or(self, alt: K, cond: bool) -> K:",
                "        return self.k if cond else alt",
                "",
            ]
        if has_node:
            self.lines += [
                "class Node[T]:",
                "    head: T",
                "    nxt: Node | None",
                "    def __init__(self, head: T) -> None:",
                "        self.head = head",
                "        self.nxt = None",
                "",
            ]
        if has_sub:
            self.lines += [
                "class SubBox(Box[int]):",
                "    extra: int",
                "    def __init__(self, v: int, e: int) -> None:",
                "        super().__init__(v)",
                "        self.extra = e",
                "    def get(self) -> int:",
                "        return super().get() + self.extra",
                "",
            ]

        if has_rich:
            self.lines += [
                "class Rich[T]:",
                "    item: T",
                "    def __init__(self, item: T) -> None:",
                "        self.item = item",
                "    def walk(self, xs: list[T], flag: bool) -> list[T]:",
                "        out: list[T] = [x for x in xs]",
                "        if flag:",
                "            for y in xs:",
                "                out.append(y)",
                "        elif not flag:",
                "            i: int = 0",
                "            while i < 1:",
                "                i = i + 1",
                "        else:",
                "            out.append(self.item)",
                "        try:",
                "            c: Ctx = Ctx()",
                "            with c as h:",
                "                _h: int = h",
                "        except MyErr as _ex:",
                "            pass",
                "        finally:",
                "            defer noop_cleanup(1)",
                "        def id_t(z: T) -> T:",
                "            return z",
                "        lowlevel:",
                "            _sz: usize = sizeof(T)",
                "        f_lam: (T) -> T = lambda z: z",
                "        part: list[T] = out[0:1]",
                "        pair: tuple[T, int] = (f_lam(id_t(self.item)), len(part))",
                "        return [pair[0]]",
                "",
            ]

        if not clean and r.random() < 0.45:
            bad_defs = [
                ["class DupG[T]:", "    x: T", "class DupG:", "    x: int"],
                ["class DupG2[T]:", "    x: T", "class DupG2[U]:", "    x: U"],
                ["class BadListSub(list[int]):", "    y: int"],
                ["class BadBaseArgCnt(Box[int, str]):", "    y: int"],
                ["class DecStatic[T]:", "    @staticmethod", "    def f() -> int:", "        return 1"],
                ["class DecCls[T]:", "    @classmethod", "    def f(self) -> int:", "        return 1"],
                ["class DecProp[T]:", "    v: T", "    @property", "    def p(self) -> T:", "        return self.v"],
                ["class DecSet[T]:", "    v: T", "    @v.setter", "    def v(self, x: T) -> None:", "        self.v = x"],
                ["class UnasG[T]:", "    a: T", "    def __init__(self) -> None:", "        pass"],
                ["class MissRetG[T]:", "    def f(self, x: T) -> T:", "        if True:", "            return x"],
                ["class AddG[T]:", "    a: T", "    def __init__(self, a: T) -> None:", "        self.a = a", "    def inc(self) -> T:", "        return self.a + 1"],
            ]
            pick_def = r.choice(bad_defs)
            self.lines += pick_def + [""]
            if pick_def[0].startswith("class UnasG"):
                self.lines.append("ug: UnasG[int] = UnasG[int]()")
            elif pick_def[0].startswith("class MissRetG"):
                self.lines.append("mg: MissRetG[int] = MissRetG[int]()")
            elif pick_def[0].startswith("class AddG"):
                self.lines.append('ag: AddG[str] = AddG[str]("a")')

        good = [
            "b0: Box[int] = Box[int](1)",
            "b1: Box[str] = Box[str](\"hi\")\ns1: str = b1.get()",
            "b2: Box[Box[int]] = Box[Box[int]](Box[int](2))\nv2: int = b2.get().get()",
            "b3: Box[int] = Box[int](3).rebox(4)\nsz3: usize = b3.sz()",
            "def f_na(c: Task[int], d: Task[str]) -> None:\n    bt: Box[Task[int]] = Box[Task[int]](c)\n    bt: Box[Task[str]] = Box[Task[str]](d)",
            "b_dup1: Box[int] = Box[int](1)\nb_dup2: Box[int] = Box[int](2)",
        ]
        if has_pair:
            good.append("p0: Pair[str, int] = Pair[str, int](\"k\", 9)\npk0: str = p0.key()")
            good.append("p1: Pair[int, tuple[str, int]] = Pair[int, tuple[str, int]](1, (\"a\", 2))")
        if has_node:
            good.append("n0: Node[int] = Node[int](7)\nn1: Node[int] | None = n0.nxt")
        if has_sub:
            good.append("sb0: SubBox = SubBox(10, 5)\nsbv: int = sb0.get() + sb0.val")
        if imp_kind == "imp":
            good.append("ql0: lib.Box[int] = lib.Box[int](5)\nqlv: int = ql0.get()")
        elif imp_kind == "alias":
            good.append("qa0: lb.Box[int] = lb.Box[int](6)\nqav: int = qa0.get()")
        elif imp_kind == "from":
            good.append("qf0: LibBox[int] = LibBox[int](7)\nqfv: int = qf0.get()")

        bad = [
            "e0: Box[int, str] = Box[int](1)",
            "e2: Nope[int] = Box[int](1)",
            "Nope[int](1)",
            "e4: Box[int] = Box[int](\"s\")",
            "e5: Box[int] = Box[int]()",
            "e6: Box[str] = Box[int](1)",
            "e10: str = Box[int](1).get()",
            "e11: nomod.Box[int] = Box[int](1)",
            "e12: lib.Missing[int] = Box[int](1)",
        ]
        if has_pair:
            bad.append("e1: Pair[int] = Pair[int, int](1, 2)")
            bad.append("e7: Box[int] = Pair[int, int](1, 2)")
        if has_sub:
            bad.append("e8: SubBox = Box[int](1)")
            bad.append("e9: Box[int] = SubBox(1, 2)")

        in_fn = r.random() < 0.7
        ind = "    " if in_fn else ""
        if in_fn:
            self.lines.append("def main_g() -> None:")
        k = r.randint(2, 4)
        picks = r.sample(good, k=min(k, len(good))) if clean else [r.choice(good) if r.random() < 0.55 else r.choice(bad) for _ in range(k)]
        for pick in picks:
            for ln in pick.split("\n"):
                self.lines.append(ind + ln)
        if in_fn and r.random() < 0.5:
            self.lines.append("main_g()")

    def gen_generic_fn(self):
        """3.6 dilim C: jenerik işlevler (`def f[T]`, `unify_type_expr`, açık `f[int](...)`, lambda çıkarımı, `from`/`mod.f`) ve jenerik metodlar (`class C: def m[T](self, ...)` + `class Box[T]: def map[U]`)."""
        r = self.rnd
        clean = r.random() < 0.45
        imp_kind = r.choice(["none", "imp", "alias", "from"])
        if imp_kind == "imp":
            self.lines += ["import lib", "def lib_gid[T](x: T) -> T:", "    return x", ""]
        elif imp_kind == "alias":
            self.lines += ["import lib as lb", "def lib_gid[T](x: T) -> T:", "    return x", ""]
        elif imp_kind == "from":
            self.lines += ["from lib import gid as lgid", "def lib_gid[T](x: T) -> T:", "    return x", ""]

        has_cls = r.random() < 0.5
        has_gcls = r.random() < 0.45
        self.lines += [
            "def gid[T](x: T) -> T:",
            "    return x",
            "",
            "def same[T](a: T, b: T) -> T:",
            "    return a",
            "",
            "def gpair[A, B](a: A, b: B) -> tuple[A, B]:",
            "    return (a, b)",
            "",
            "def first_or_none[T](xs: list[T]) -> T | None:",
            "    if len(xs) > 0:",
            "        return xs[0]",
            "    return None",
            "",
            "def apply_one[T, U](x: T, fn: (T) -> U) -> U:",
            "    return fn(x)",
            "",
            "def opt_val[T](x: T | None, alt: T) -> T:",
            "    return alt",
            "",
        ]
        if has_cls:
            self.lines += [
                "class Util:",
                "    tag: int",
                "    def __init__(self, tag: int) -> None:",
                "        self.tag = tag",
                "    def wrap[T](self, x: T) -> list[T]:",
                "        return [x]",
                "    def again[T](self, x: T) -> list[T]:",
                "        return self.wrap[T](x)",
                "",
                "class SubUtil(Util):",
                "    pass",
                "",
            ]
        if has_gcls:
            self.lines += [
                "class Box[T]:",
                "    v: T",
                "    def __init__(self, v: T) -> None:",
                "        self.v = v",
                "    def map[U](self, y: U) -> tuple[T, U]:",
                "        return (self.v, y)",
                "",
                "def unbox[T](b: Box[T]) -> T:",
                "    return b.v",
                "",
            ]

        if not clean and r.random() < 0.4:
            bad_defs = [
                ["def dupf[T](x: T) -> T:", "    return x", "def dupf(x: int) -> int:", "    return x"],
                ["extern def extf(x: int) -> int from \"libc\"", "def extf[T](x: T) -> T:", "    return x"],
                ["def mk[T]() -> list[T]:", "    return []", "bad_mk: list[int] = mk()"],
                ["def inc_bad[T](x: T) -> T:", "    return x + 1", "bi: str = inc_bad(\"hi\")"],
                ["class BGM2:", "    def m[A, B](self, x: A) -> A:", "        return x"],
                ["class BGMD:", "    def __add__[T](self, x: T) -> T:", "        return x"],
                ["class BGMDup:", "    def m[T](self, x: T) -> T:", "        return x", "    def m[U](self, x: U) -> U:", "        return x"],
            ]
            self.lines += r.choice(bad_defs) + [""]

        good = [
            "g0: int = gid(42)",
            "g1: str = gid[str](\"ok\")",
            "g2: int = same(1, gid(2))",
            "g3: tuple[str, int] = gpair(\"k\", 9)",
            "g4: int | None = first_or_none([1, 2])",
            "g5: list[str] = first_or_none[list[str]]([]) or []" if False else "g5: int | None = first_or_none[int]([])",
            "g6: int = apply_one(3, lambda v: v + 1)",
            "g7: int = apply_one[int, int](4, lambda v: v * 2)",
            "g8: int = opt_val(None, 5)",
            "g9: int = opt_val(10, 5)",
        ]
        if has_cls:
            good.append("u0: Util = Util(1)\nui0: list[int] = u0.wrap(5)\nui1: list[str] = u0.again[str](\"a\")")
            good.append("su0: SubUtil = SubUtil(2)\nsui: list[int] = su0.wrap[int](9)")
        if has_gcls:
            good.append("bx0: Box[int] = Box[int](7)\nub0: int = unbox(bx0)\nmp0: tuple[int, str] = bx0.map(\"z\")")
        if imp_kind == "imp":
            good.append("ql0: int = lib.gid(5)\nql1: str = lib.gid[str](\"q\")")
        elif imp_kind == "alias":
            good.append("qa0: int = lb.gid(6)\nqa1: str = lb.gid[str](\"q\")")
        elif imp_kind == "from":
            good.append("qf0: int = lgid(7)\nqf1: str = lgid[str](\"q\")")

        bad = [
            "e0: int = same(1, \"s\")",
            "e1: int = gid()",
            "e2: int = gid(1, 2)",
            "e3: int = gid[int, str](1)",
            "e4: int = gid[int]()",
            "e5: int = gid[str](1)",
            "fnv = gid",
            "e6: int = apply_one(1, lambda a, b: a)",
            "e7: int = first_or_none([])",
            "e8: str = opt_val(1, \"a\")",
        ]
        if has_cls:
            bad.append("ub0: Util = Util(1)\ne9: list[int] = ub0.wrap()")
            bad.append("ub1: Util = Util(1)\ne10: list[int] = ub1.wrap[1 + 2](1)")
        if has_gcls:
            bad.append("eb0: Box[int] = Box[int](1)\ne11: str = unbox(eb0)")

        in_fn = r.random() < 0.7
        ind = "    " if in_fn else ""
        if in_fn:
            self.lines.append("def main_gf() -> None:")
        k = r.randint(2, 4)
        picks = r.sample(good, k=min(k, len(good))) if clean else [r.choice(good) if r.random() < 0.55 else r.choice(bad) for _ in range(k)]
        for pick in picks:
            for ln in pick.split("\n"):
                self.lines.append(ind + ln)
        if in_fn and r.random() < 0.5:
            self.lines.append("main_gf()")

    def gen_prelude_proto(self):
        r = self.rnd
        clean = r.random() < 0.45
        self.lines.append("protocol Measurable:")
        self.lines.append("    def score(self: Measurable) -> int:")
        self.lines.append("        pass")
        self.lines.append("    def tag(self: Measurable) -> str:")
        self.lines.append("        pass")
        self.lines.append("")
        self.lines += [
            "class GoodA:",
            "    v: int",
            "    def __init__(self, v: int) -> None:",
            "        self.v = v",
            "    def score(self) -> int:",
            "        return self.v",
            "    def tag(self) -> str:",
            "        return \"a\"",
            "",
            "class GoodB:",
            "    s: str",
            "    def __init__(self, s: str) -> None:",
            "        self.s = s",
            "    def score(self) -> int:",
            "        return len(self.s)",
            "    def tag(self) -> str:",
            "        return self.s",
            "",
            "class BadMiss:",
            "    v: int",
            "    def __init__(self, v: int) -> None:",
            "        self.v = v",
            "    def score(self) -> int:",
            "        return self.v",
            "",
            "class BadRet:",
            "    v: int",
            "    def __init__(self, v: int) -> None:",
            "        self.v = v",
            "    def score(self) -> str:",
            "        return \"no\"",
            "    def tag(self) -> str:",
            "        return \"r\"",
            "",
            "class HasBool:",
            "    v: int",
            "    def __init__(self, v: int) -> None:",
            "        self.v = v",
            "    def __bool__(self) -> bool:",
            "        return self.v != 0",
            "",
            "def read_score(m: Measurable) -> int:",
            "    return m.score()",
            "",
            "def take_list(ms: list[Measurable]) -> int:",
            "    return len(ms)",
            "",
        ]
        if r.random() < 0.2:
            self.lines += [
                "def __nox_hex(n: int) -> str:",
                "    return \"0x\"",
                "def __nox_max_list(xs: list[int]) -> int:",
                "    return xs[0]",
                "def __nox_int_base(s: str, b: int) -> int:",
                "    return b",
                "def __nox_format_int(x: int, spec: str) -> str:",
                "    return spec",
                "def __nox_any_range(a: int, b: int, p: (int) -> bool) -> bool:",
                "    return p(a)",
                "",
            ]
        good = [
            "s1: int = read_score(GoodA(3))",
            "s2: int = read_score(GoodB(\"hi\"))",
            "xs: list[Measurable] = [GoodA(1), GoodB(\"x\")]",
            "xs.append(GoodA(2))",
            "m0: Measurable = GoodB(\"y\")",
            "opt: Measurable | None = GoodA(4)",
            "lr: list[int] = list(range(3))",
            "lc: list[int] = list([1, 2])",
            "ls: list[str] = list(\"ab\")",
            "lk: list[str] = list({\"k\": 1})",
            "b1: bool = bool(1)",
            "b2: bool = bool(\"ok\")",
            "b3: bool = bool([1, 2])",
            "b4: bool = bool(GoodA(1))",
            "b5: bool = bool(HasBool(1))",
        ]
        if any("__nox_hex" in ln for ln in self.lines):
            good += [
                "hx: str = hex(15)",
                "mx: int = max([1, 2])",
                "ib: int = int(\"ff\", 16)",
                "fi: str = format(5, \"d\")",
                "fb: str = format(True, \"d\")",
                "ar: bool = any(i > 0 for i in range(3))",
            ]
        bad = [
            "e0: int = read_score(1)",
            "e1: int = read_score(BadMiss(1))",
            "e2: int = read_score(BadRet(1))",
            "e3: int = take_list([])",
            "e4: list[int] = list(1)",
            "e5: bool = bool(None)",
            "e6: str = format(1, 2)",
            "e7: str = format([1], \"\")",
            "e8: str = format(GoodA(1), \"d\")",
            "e9: list[Measurable] = [BadMiss(1)]",
        ]
        if not clean and r.random() < 0.15:
            bad.append("e10: int = take_list([BadMiss(1)])")
        in_fn = r.random() < 0.7
        ind = "    " if in_fn else ""
        if in_fn:
            self.lines.append("def main_pp() -> None:")
        k = r.randint(2, 4)
        picks = r.sample(good, k=min(k, len(good))) if clean else [r.choice(good) if r.random() < 0.55 else r.choice(bad) for _ in range(k)]
        for pick in picks:
            for ln in pick.split("\n"):
                self.lines.append(ind + ln)
        if in_fn and r.random() < 0.5:
            self.lines.append("main_pp()")

    def gen_sig(self):
        r = self.rnd
        clean = r.random() < 0.45
        self.lines += [
            "def f_def(a: int, b: int = 2, c: str = \"ok\", d: int | None = None, e: float = -1.5, f: bool = True) -> int:",
            "    return a + b",
            "",
            "def f_var(a: int, *rest: int, k: int = 5, **kw: int) -> int:",
            "    return a + len(rest) + k",
            "",
            "def f_pos(a: int, /, b: int, *, c: int = 3) -> int:",
            "    return a + b + c",
            "",
            "def f_gen[T](x: T, n: int = 1) -> T:",
            "    return x",
            "",
            "def eff(x: int) -> int:",
            "    return x + 1",
            "",
            "class Svc:",
            "    base: int",
            "    def __init__(self, base: int = 10) -> None:",
            "        self.base = base",
            "    def add(self, x: int = 1, y: int = 2) -> int:",
            "        return self.base + x + y",
            "",
            "def __nox_kw_unpack[V](d: dict[str, V], reserved: list[str]) -> dict[str, V]:",
            "    return d",
            "def __nox_kw_merge[V](a: dict[str, V], b: dict[str, V]) -> dict[str, V]:",
            "    return a",
            "",
        ]
        good = [
            "r0: int = f_def(1)",
            "r1: int = f_def(1, c=\"hi\", b=3)",
            "r2: int = f_var(1, 2, 3, x=4, k=6)",
            "r3: int = f_var(1, *[2, 3], **{\"z\": 9})",
            "r4: int = f_pos(1, b=2)",
            "r5: int = f_pos(1, 2, c=4)",
            "r6: int = f_gen(10)",
            "r7: int = f_gen(n=2, x=10)",
            "s0: Svc = Svc()",
            "r8: int = s0.add(y=5)",
            "r9: int = f_def(1, b=eff(2))",
        ]
        bad = [
            "e0: int = f_def()",
            "e1: int = f_def(1, a=2)",
            "e2: int = f_def(1, nope=2)",
            "e3: int = f_pos(a=1, b=2)",
            "e4: int = f_pos(1, 2, 3)",
            "e5: int = f_var(1, rest=[2])",
            "e6: int = f_var(1, k=eff(1), *[2])",
            "e7: int = f_def(1, **{\"a\": 2})",
            "e8: int = f_def(1, *[2])",
            "e9: int = f_gen(1, n=\"bad\")",
        ]
        in_fn = r.random() < 0.7
        ind = "    " if in_fn else ""
        if in_fn:
            self.lines.append("def main_sig() -> None:")
        k = r.randint(2, 4)
        picks = r.sample(good, k=min(k, len(good))) if clean else [r.choice(good) if r.random() < 0.55 else r.choice(bad) for _ in range(k)]
        for pick in picks:
            for ln in pick.split("\n"):
                self.lines.append(ind + ln)
        if in_fn and r.random() < 0.5:
            self.lines.append("main_sig()")

    def gen_bytes_spawn_dec(self):
        """bytes (+ str#prelude), spawn#shared_arg / post-spawn caller mutation, top-level func decorators + @capability.requires + __nox_reflect_*."""
        r = self.rnd
        clean = r.random() < 0.45
        self.lines += [
            "def __nox_bytes_len(b: bytes) -> int:", "    return 0",
            "def __nox_bytes_repr(b: bytes) -> str:", '    return "b\'\'"',
            "def __nox_bytes_index(b: bytes, i: int) -> int:", "    return 0",
            "def __nox_bytes_slice(b: bytes, lo: int, hi: int) -> bytes:", '    return b""',
            "def __nox_bytes_contains_byte(b: bytes, v: int) -> bool:", "    return False",
            "def __nox_bytes_ints(b: bytes) -> list[int]:", "    return []",
            "def __nox_bytes_new_ints(xs: list[int]) -> bytes:", '    return b""',
            "def __nox_bytes_new(xs: list[u8]) -> bytes:", '    return b""',
            "def __nox_bytes_decode(b: bytes) -> str:", '    return ""',
            "def __nox_bytes_hex(b: bytes) -> str:", '    return ""',
            "def __nox_bytes_to_list(b: bytes) -> list[int]:", "    return []",
            "def __nox_str_encode(s: str) -> bytes:", '    return b""',
            "def __nox_str_strip(s: str, ch: str) -> str:", "    return s",
            "",
            "class Box:",
            "    v: int",
            "    def __init__(self, v: int) -> None:",
            "        self.v = v",
            "",
            "async def worker_list(xs: list[int]) -> int:",
            "    return len(xs)",
            "",
            "async def worker_box(b: Box) -> int:",
            "    return b.v",
            "",
            "def fresh_list() -> list[int]:",
            "    return [1, 2]",
            "",
            "def id_list(xs: list[int]) -> list[int]:",
            "    return xs",
            "",
            "def wrap_list(xs: list[int]) -> list[int]:",
            "    return id_list(xs)",
            "",
            '@route("/ok", 1, True, ["a", "b"])',
            "def decorated_ok(x: int) -> int:",
            "    return x + 1",
            "",
            '@capability.requires("clock")',
            "def cap_clock() -> int:",
            "    return 1",
            "",
            '@capability.requires("arch_x86_64")',
            "def cap_arch() -> int:",
            "    return 1",
            "",
            "extern def ext_bytes(b: bytes) -> bytes from \"c\"",
            "",
        ]
        good = [
            "b2: bytes = bytes(b0)",
            "b3: bytes = bytes([65, 66])",
            "b4: bytes = bytes([u8(65)])",
            'b5: bytes = "abc".encode()',
            's0: str = "xabx".strip("x")',
            "n0: int = len(b0)",
            "r0: str = repr(b0)",
            "print(b0)",
            "i0: int = b0[0]",
            "b6: bytes = b0[0:1]",
            "b7: bytes = b0 + b1",
            "c0: bool = b0 < b1",
            "c1: bool = 65 in b0",
            "c2: bool = b1 in b0",
            's1: str = b0.decode("UTF-8")',
            "s2: str = b0.hex()",
            "l0: list[int] = b0.to_list()",
            "d0: dict[bytes, bytes] = {b0: b1}",
            "tot: int = 0\nfor bt in b0:\n    tot = tot + bt",
            "xs: list[int] = [1, 2]\nt: Task[int] = spawn worker_list(xs)\nw: int = await t\nxs.append(3)",
            "xs2: list[int] = fresh_list()\nt2: Task[int] = spawn worker_list(xs2)\nw2: int = await t2\nxs2[0] = 9",
            "d_ok: int = decorated_ok(cap_clock())",
            "rc0: int = __nox_reflect_decorator_count()\nrc1: str = __nox_reflect_decorator_name(0)\nrc2: str = __nox_reflect_decorator_arg(0, 0)\nrc3: str = __nox_reflect_decorator_arg_list_item(0, 3, 0)",
            "rc4: int = __nox_reflect_class_count()\nrc5: str = __nox_reflect_class_name(0)\nrc6: int = __nox_reflect_decorator_param_count(0)",
        ]
        bad = [
            'eb0: bytes = bytes("abc")',
            "eb1: bytes = bytes(1)",
            "eb2: bytes = bytes(b\"a\", b\"b\")",
            'eb3: int = b"hi"["x"]',
            'eb4: bytes = b"hi"[::2]',
            'eb5: bytes = b"hi"["a":]',
            'eb6: bool = "a" in b"hi"',
            'eb7: str = b"hi".decode("latin1")',
            'eb8: str = b"hi".hex(1)',
            'eb9: int = b"hi".nope()',
            "xs_err: list[int] = [1, 2]\nt_err: Task[int] = spawn worker_list(xs_err)\nxs_err.append(3)",
            "xs_al: list[int] = [1, 2]\nys_al: list[int] = wrap_list(xs_al)\nt_al: Task[int] = spawn worker_list(xs_al)\nys_al[0] = 9",
            "xs_mo: list[int] = [1, 2]\nt_m1: Task[int] = spawn worker_list(xs_mo)\nt_m2: Task[int] = spawn worker_list(xs_mo)\nw_m1: int = await t_m1\nxs_mo.append(4)",
            "bx_err: Box = Box(1)\nt_bx: Task[int] = spawn worker_box(bx_err)\nbx_err.v = 2",
            "xs_lp: list[int] = [1, 2]\nfor _i in range(2):\n    t_lp: Task[int] = spawn worker_list(xs_lp)\nxs_lp[0] = 5",
            "c_arch: int = cap_arch()",
            "er0: int = __nox_reflect_decorator_count(1)",
            'er1: str = __nox_reflect_decorator_name("x")',
            'er2: str = __nox_reflect_decorator_arg(0, "x")',
            'er3: int = __nox_reflect_class_name(0)',
            'er4: int = __nox_reflect_decorator_param_count("x")',
        ]
        if not clean and r.random() < 0.25:
            bad_defs = [
                '@bad(1.5)\ndef bad_d0() -> None:\n    pass',
                '@bad([1])\ndef bad_d1() -> None:\n    pass',
                '@capability.requires()\ndef bad_c0() -> None:\n    pass',
                '@capability.requires(1)\ndef bad_c1() -> None:\n    pass',
                '@capability.requires("bogus")\ndef bad_c2() -> None:\n    pass',
            ]
            self.lines.append(r.choice(bad_defs))
        in_fn = r.random() < 0.55
        ind = "    " if in_fn else ""
        if in_fn:
            self.lines.append("def main_bsd() -> None:")
        self.lines.append(ind + 'b0: bytes = b"hi"')
        self.lines.append(ind + "b1: bytes = bytes()")
        k = r.randint(2, 4)
        picks = r.sample(good, k=min(k, len(good))) if clean else [r.choice(good) if r.random() < 0.5 else r.choice(bad) for _ in range(k)]
        for pick in picks:
            for ln in pick.split("\n"):
                self.lines.append(ind + ln)
        if in_fn and r.random() < 0.5:
            self.lines.append("main_bsd()")

    def gen_consts_ffi_intr(self):
        r = self.rnd
        clean = r.random() < 0.55
        self.lines = [
            "import nox.http",
            "import nox.websocket",
            "import nox.thread",
            "",
            "class nox_http_HttpRequest:",
            "    path: str",
            "    def __init__(self, path: str) -> None:",
            "        self.path = path",
            "",
            "class nox_http_HttpResponse:",
            "    status: int",
            "    def __init__(self, status: int) -> None:",
            "        self.status = status",
            "",
            "class nox_websocket_WebSocketServerConn:",
            "    id: int",
            "    def __init__(self, id: int) -> None:",
            "        self.id = id",
            "",
            "class nox_ffi_Callback[F]:",
            "    fn: F",
            "    box: ptr",
            "    def __init__(self, fn: F, box: ptr) -> None:",
            "        self.fn = fn",
            "        self.box = box",
            "",
            "class ErrX:",
            "    msg: str",
            "    def __init__(self, msg: str) -> None:",
            "        self.msg = msg",
            "",
            "class BaseCfg:",
            "    MAX: int = 10",
            "    RATE: float = 1.5",
            "    OK: bool = True",
            '    TAG: str = "v1"',
            "    NEG: int = -3",
            "    PROM: int = 1",
            "    val: int",
            "    def __init__(self, val: int) -> None:",
            "        self.val = val",
            "    def get_max(self) -> int:",
            "        return self.MAX",
            "",
            "class SubCfg(BaseCfg):",
            "    SUB: int = 2",
            "    def __init__(self, val: int) -> None:",
            "        self.val = val",
            "",
            "def cb_sync(x: int) -> int:",
            "    return x + 1",
            "",
            "def cb_bad_arity(x: int, y: int) -> int:",
            "    return x + y",
            "",
            "async def cb_async(x: int) -> int:",
            "    return x",
            "",
            "def err_msg(code: int) -> str:",
            '    return "err"',
            "",
            "def http_ok(req: nox_http_HttpRequest) -> nox_http_HttpResponse:",
            "    return nox_http_HttpResponse(200)",
            "",
            "def http_factory() -> (nox_http_HttpRequest) -> nox_http_HttpResponse:",
            "    return http_ok",
            "",
            "def ws_ok(conn: nox_websocket_WebSocketServerConn) -> None:",
            "    pass",
            "",
            "async def th_worker(x: int) -> int:",
            "    return x + 1",
            "",
            "def th_sync(x: int) -> int:",
            "    return x",
            "",
            "async def th_bad_task(t: Task[int]) -> int:",
            "    return 0",
            "",
            "async def pool_worker() -> None:",
            "    pass",
            "",
            '@ffi.escape("a")',
            '@ffi.noescape("b")',
            'extern def c_esc(a: str, b: str) -> int from "c"',
            "",
            '@ffi.callback("cb", "ud")',
            'extern def c_cb(n: int, cb: (int, ptr) -> int, ud: ptr) -> int from "c"',
            "",
            '@ffi.callback("cb", "ud", ud_index=0)',
            'extern def c_cb0(cb: (ptr, int) -> int, ud: ptr) -> int from "c"',
            "",
            '@ffi.errors(raises=ErrX, ok=0, message="err_msg")',
            'extern def c_ok(x: int) -> int from "c"',
            "",
            '@ffi.errors(raises=ErrX, ok_min=0)',
            'extern def c_min(x: int) -> int from "c"',
            "",
            '@ffi.errors(raises=ErrX, null_is_error=True)',
            'extern def c_ptr(x: int) -> ptr from "c"',
            "",
            '@capability.requires("clock")',
            'extern def c_cap() -> int from "c"',
            "",
        ]
        good = [
            "m_c: int = BaseCfg.MAX",
            "r_c: float = BaseCfg.RATE",
            "o_c: bool = BaseCfg.OK",
            "t_c: str = BaseCfg.TAG",
            "n_c: int = BaseCfg.NEG",
            "s_c: int = SubCfg.MAX",
            "s_c2: int = SubCfg.SUB",
            "BaseCfg.PROM = 99",
            "bc0: BaseCfg = BaseCfg(1)\nbc_m: int = bc0.MAX",
            "sc0: SubCfg = SubCfg(1)\nsc_m: int = sc0.MAX",
            "r_esc: int = c_esc(\"a\", \"b\")",
            "r_cb1: int = c_cb(1, cb_sync)",
            "r_cb2: int = c_cb(1, None)",
            "r_cb3: int = c_cb0(cb_sync)",
            "r_ok: int = c_ok(1)",
            "r_min: int = c_min(1)",
            "r_ptr: ptr = c_ptr(1)",
            "r_cap: int = c_cap()",
            "if False:\n    nox.http.serve(8080, http_ok)",
            "if False:\n    nox.http.serve(8080, http_ok, 16)",
            "if False:\n    nox.http.serve_fd(3, http_ok)",
            "if False:\n    nox.http.serve_multicore(8080, http_ok, 4, 64)",
            "if False:\n    nox.http.serve_multicore(8080, http_factory, 4)",
            'if False:\n    nox.http.serve_tls(8443, http_ok, "c.pem", "k.pem")',
            "if False:\n    nox.http.serve_ws(8080, http_ok, ws_ok)",
            'if False:\n    nox.http.serve_multicore_ws_tls(8443, http_factory, 2, ws_ok, "c.pem", "k.pem", 32)',
            "if False:\n    th0: ThreadHandle[int] = nox.thread.start(th_worker, 5)",
            "if False:\n    nox.thread.pool_run(4, pool_worker)",
        ]
        bad = [
            "SubCfg.PROM = 5",
            "bc_bad: BaseCfg = BaseCfg(1)\nbc_bad.MAX = 2",
            "BaseCfg.NOPE = 1",
            "er_cb0: int = c_cb(1, cb_bad_arity)",
            "er_cb1: int = c_cb(1, cb_async)",
            "er_cb2: int = c_cb(1, c_cap)",
            "er_cb3: int = c_cb(1, lambda z: z)",
            "er_cb4: int = c_cb(1, cb_sync, c_ptr(0))",
            "if False:\n    nox.http.serve(8080, ws_ok)",
            "if False:\n    nox.http.serve(\"8080\", http_ok)",
            "if False:\n    nox.http.serve_multicore(8080, lambda req: nox_http_HttpResponse(200), 2)",
            "if False:\n    mc_lim: int = 8\n    nox.http.serve_multicore(8080, http_ok, 2, mc_lim)",
            "if False:\n    nox.http.serve_ws(8080, http_ok, http_ok)",
            "if False:\n    nox.http.serve_tls(8443, http_ok, 123, \"k.pem\")",
            "if False:\n    nox.thread.start(th_sync, 1)",
            'if False:\n    nox.thread.start(th_worker, "bad")',
            "if False:\n    nox.thread.pool_run(4, th_worker)",
            'if False:\n    nox.thread.pool_run("4", pool_worker)',
        ]
        if not clean and r.random() < 0.3:
            bad_defs = [
                "class BadK0:\n    K: int = 1 + 2",
                'class BadK1:\n    K: int = "x"',
                "class BadK2:\n    K: list[int] = [1]",
                "class BadK3:\n    K: int = 1\n    K: int = 2",
                "class BadK4:\n    K: int = 1\n    K: int",
                '@ffi.nope("a")\nextern def bad_ed0(a: str) -> int from "c"',
                '@ffi.escape("z")\nextern def bad_ed1(a: str) -> int from "c"',
                '@ffi.escape("a")\n@ffi.noescape("a")\nextern def bad_ed2(a: str) -> int from "c"',
                '@ffi.errors(raises=ErrX, ok=0)\n@ffi.callback("cb", "ud")\nextern def bad_ed3(cb: (int, ptr) -> int, ud: ptr) -> int from "c"',
                '@ffi.errors(raises=ErrX)\nextern def bad_ed4(x: int) -> int from "c"',
                '@ffi.errors(ok=0)\nextern def bad_ed5(x: int) -> int from "c"',
                '@ffi.callback("cb", "ud")\nextern def bad_ed6(cb: int, ud: ptr) -> int from "c"',
            ]
            self.lines.append(r.choice(bad_defs))
        in_fn = r.random() < 0.5
        ind = "    " if in_fn else ""
        if in_fn:
            self.lines.append("def main_cfi() -> None:")
        k = r.randint(2, 4)
        picks = r.sample(good, k=min(k, len(good))) if clean else [r.choice(good) if r.random() < 0.5 else r.choice(bad) for _ in range(k)]
        for pick in picks:
            for ln in pick.split("\n"):
                self.lines.append(ind + ln)
        if in_fn and r.random() < 0.5:
            self.lines.append("main_cfi()")

    def program(self):
        r = self.rnd
        if self.use_consts_ffi_intr:
            self.gen_consts_ffi_intr()
            return "\n".join(self.lines) + "\n"
        if self.use_bytes_spawn_dec:
            self.gen_bytes_spawn_dec()
            return "\n".join(self.lines) + "\n"
        if self.use_sig:
            self.gen_sig()
            return "\n".join(self.lines) + "\n"
        if self.use_prelude_proto:
            self.gen_prelude_proto()
            return "\n".join(self.lines) + "\n"
        if self.use_generic_fn:
            self.gen_generic_fn()
            return "\n".join(self.lines) + "\n"
        if self.use_generic_cls:
            self.gen_generic_cls()
            return "\n".join(self.lines) + "\n"
        if self.use_tuple:
            self.gen_tuple()
            return "\n".join(self.lines) + "\n"
        if self.use_closure:
            self.gen_closure()
            return "\n".join(self.lines) + "\n"
        if self.use_inherit:
            self.gen_inherit()
            return "\n".join(self.lines) + "\n"
        if self.use_import:
            self.gen_import()
            return "\n".join(self.lines) + "\n"
        if self.use_spawn:
            self.gen_spawn()
            return "\n".join(self.lines) + "\n"
        if self.use_extern:
            self.gen_extern()
            return "\n".join(self.lines) + "\n"
        if self.use_ptr:
            self.gen_ptr()
            return "\n".join(self.lines) + "\n"
        if self.use_construct:
            self.gen_construct()
            return "\n".join(self.lines) + "\n"
        if self.use_try:
            self.gen_try()
            return "\n".join(self.lines) + "\n"
        if self.use_recv:
            self.gen_recv()
            return "\n".join(self.lines) + "\n"
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
    ap.add_argument("--recv", dest="use_recv", action="store_true")
    ap.add_argument("--try", dest="use_try", action="store_true")
    ap.add_argument("--construct", dest="use_construct", action="store_true")
    ap.add_argument("--ptr", dest="use_ptr", action="store_true")
    ap.add_argument("--extern", dest="use_extern", action="store_true")
    ap.add_argument("--spawn", dest="use_spawn", action="store_true")
    ap.add_argument("--import", dest="use_import", action="store_true")
    ap.add_argument("--inherit", dest="use_inherit", action="store_true")
    ap.add_argument("--closure", dest="use_closure", action="store_true")
    ap.add_argument("--tuple", dest="use_tuple", action="store_true")
    ap.add_argument("--generic-cls", dest="use_generic_cls", action="store_true")
    ap.add_argument("--generic-fn", dest="use_generic_fn", action="store_true")
    ap.add_argument("--prelude-proto", dest="use_prelude_proto", action="store_true")
    ap.add_argument("--sig", dest="use_sig", action="store_true")
    ap.add_argument("--bytes-spawn-dec", dest="use_bytes_spawn_dec", action="store_true")
    ap.add_argument("--consts-ffi-intr", dest="use_consts_ffi_intr", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    for i in range(args.count):
        rnd = random.Random(args.seed * 1_000_003 + i)
        src = Gen(rnd, args.use_async, args.use_methods, args.use_builtins, args.use_recv, args.use_try, args.use_construct, args.use_ptr, args.use_extern, args.use_spawn, args.use_import, args.use_inherit, args.use_closure, args.use_tuple, args.use_generic_cls, args.use_generic_fn, args.use_prelude_proto, args.use_sig, args.use_bytes_spawn_dec, args.use_consts_ffi_intr).program()
        with open(os.path.join(args.out, f"g{args.seed}_{i}.nox"), "w", encoding="utf-8") as f:
            f.write(src)


if __name__ == "__main__":
    main()
