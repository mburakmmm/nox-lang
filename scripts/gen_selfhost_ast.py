#!/usr/bin/env python3
"""noxc-nightly Aşama 2.A: `noxc ast --schema` (ast.zig'nin comptime yansıması) çıktısından `selfhost/ast_schema.nox` üretir.

Üretilenler (tek kaynaktan; elle çoğaltılmaz, `--check` precheck/CI'da): Nox AST'sinin düz-dizi (struct-of-arrays) şeması, tür/alan sabitleri, her tür için oluşturucu (`mk_*`) ve Zig'in `noxc ast --full` dökümünü
BİREBİR üreten `d_*` yazıcıları (+ test için `nox_ast_*` C ABI'si). Temsil kuralları: project/selfhost-ast-tasarimi-2026-11.md §2.

  Kullanım: scripts/gen_selfhost_ast.py            (selfhost/ast_schema.nox'u yazar; zig-out/bin/noxc gerekir)
            scripts/gen_selfhost_ast.py --check    (güncel değilse çıkış 1)
"""
import os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
OUT = os.path.join(ROOT, "selfhost/ast_schema.nox")
NONE = -4611686018427387904  # isteğe bağlı dize/dilim "yok" işareti (`opt(str)`/`opt(slice)` ilk tamsayısı)

HEADER = """# ÜRETİLMİŞ DOSYA: elle DÜZENLEMEYİN. Kaynak: `noxc ast --schema` (compiler/parser/ast.zig'nin yansıması) → scripts/gen_selfhost_ast.py.
# Yeniden üretmek için: scripts/gen_selfhost_ast.py   (güncel mi: --check)
"""


def load_schema():
    text = subprocess.run([NOXC, "ast", "--schema"], capture_output=True, text=True, check=True).stdout
    types = {}  # ad -> {"kind", "fields": [(ad, tür, varsayılan)], "names": [...]}
    cur = None
    for line in text.splitlines():
        if not line.strip():
            continue
        if not line.startswith(" "):
            parts = line.split()
            kind, name = parts[0], parts[1]
            cur = {"kind": kind, "name": name, "fields": [], "names": parts[2:]}
            types[name] = cur
        else:
            parts = line.strip().split(None, 2)
            fname, ftype = parts[0], parts[1]
            default = None
            if len(parts) > 2 and parts[2].startswith("= "):
                default = parts[2][2:]
            cur["fields"].append((fname, ftype, default))
    return types


def parse_type(s):
    """`opt(ptr(Expr))` -> ("opt", ("ptr", ("name", "Expr")))"""
    s = s.strip()
    for k in ("opt", "ptr", "slice"):
        if s.startswith(k + "(") and s.endswith(")"):
            return (k, parse_type(s[len(k) + 1:-1]))
    if s in ("bool", "f64", "str", "void", "skip"):
        return (s,)
    if s[0] in "iu" and s[1:].isdigit():
        return ("int",)
    return ("name", s)


class Gen:
    def __init__(self, types):
        self.types = types
        self.out = []
        self.counter = 0

    def uid(self):
        self.counter += 1
        return self.counter

    # --- tür sınıflandırması ---
    def is_enum(self, t):
        return t[0] == "name" and self.types[t[1]]["kind"] == "enum"

    def is_node(self, t):
        """struct/union değeri = bir düğüm kimliği (tek tamsayı)."""
        if t[0] == "ptr":
            return self.is_node(t[1])
        return t[0] == "name" and self.types[t[1]]["kind"] in ("struct", "union")

    def size(self, t):
        k = t[0]
        if k in ("bool", "f64", "int"):
            return 1
        if k == "str" or k == "slice":
            return 2
        if k == "void" or k == "skip":
            return 0
        if k == "ptr":
            return self.size(t[1])
        if k == "opt":
            inner = t[1]
            if inner[0] == "ptr" and inner[1][0] == "opt":  # *?[]const u8 gibi iç içe
                return self.size(inner)
            return self.size(inner) if not (self.is_node(inner)) else 1
        if k == "name":
            return 1  # enum ya da düğüm
        raise SystemExit(f"gen_selfhost_ast: bilinmeyen tür {t}")

    # --- yazıcı (dump) kod üretimi: Zig `ast_dump_full.zig` ile aynı biçim ---
    def lit(self, text, ind):
        return [f"{ind}put(a, {text!r})".replace("'", '"') if "'" not in text else f"{ind}put(a, \"{text}\")"]

    def value(self, t, lst, idx, ind, in_slice_of=None):
        """`t` türünde, `lst[idx...]` konumundaki değeri yazan satırlar."""
        k = t[0]
        L = []
        if k == "bool":
            L.append(f"{ind}put_bool(a, {lst}[{idx}])")
        elif k == "int":
            L.append(f"{ind}put_int(a, {lst}[{idx}])")
        elif k == "f64":
            L.append(f"{ind}put_f64(a, {lst}[{idx}])")
        elif k == "str":
            L.append(f"{ind}put_str(a, {lst}[{idx}], {lst}[({idx}) + 1])")
        elif k == "void":
            pass
        elif k == "name":
            ty = self.types[t[1]]
            if ty["kind"] == "enum":
                L.append(f"{ind}d_{t[1]}(a, {lst}[{idx}])")
            else:
                L.append(f"{ind}d_{t[1]}(a, {lst}[{idx}])")
        elif k == "ptr":
            inner = t[1]
            if inner[0] == "opt":  # *?[]const u8
                L += self.value(inner, lst, idx, ind)
            else:
                L += self.value(inner, lst, idx, ind)
                if inner == ("name", "Expr"):
                    L.append(f"{ind}put_span_suffix(a, {lst}[{idx}])")
        elif k == "opt":
            inner = t[1]
            if inner[0] == "ptr" and inner[1][0] == "opt":
                inner = inner[1][1] if False else inner
            base = inner[1] if inner[0] == "ptr" else inner
            if base[0] == "opt":  # ptr(opt(str))
                return self.value(base, lst, idx, ind)
            if self.is_node(inner):
                v = f"v{self.uid()}"
                L.append(f"{ind}{v}: int = {lst}[{idx}]")
                L.append(f"{ind}if {v} < 0:")
                L.append(f'{ind}    put(a, "null")')
                L.append(f"{ind}else:")
                L += self.value(inner, lst, idx, ind + "    ")
            elif base[0] in ("str", "slice"):
                v = f"v{self.uid()}"
                L.append(f"{ind}{v}: int = {lst}[{idx}]")
                L.append(f"{ind}if {v} == {NONE}:")
                L.append(f'{ind}    put(a, "null")')
                L.append(f"{ind}else:")
                L += self.value(base, lst, idx, ind + "    ")
            else:
                raise SystemExit(f"gen_selfhost_ast: opt({inner}) desteklenmiyor")
        elif k == "slice":
            elem = t[1]
            stride = self.size(elem)
            s, n, i = f"s{self.uid()}", f"n{self.uid()}", f"i{self.uid()}"
            L.append(f"{ind}{s}: int = {lst}[{idx}]")
            L.append(f"{ind}{n}: int = {lst}[({idx}) + 1]")
            L.append(f'{ind}put(a, "[")')
            L.append(f"{ind}for {i} in range({n}):")
            if elem == ("name", "Stmt"):
                L.append(f'{ind}    put(a, "\\n")')
            else:
                L.append(f"{ind}    if {i} > 0:")
                L.append(f'{ind}        put(a, " ")')
            L += self.value(elem, "a.l", f"{s} + {i} * {stride}", ind + "    ")
            if elem == ("name", "Expr"):
                L.append(f"{ind}    put_span_suffix(a, a.l[{s} + {i} * {stride}])")
            L.append(f'{ind}put(a, "]")')
        else:
            raise SystemExit(f"gen_selfhost_ast: value({t})")
        return L

    def gen(self):
        o = self.out
        types = self.types
        o.append(HEADER)
        o.append(
            f'''# Düz-dizi AST (docs: project/selfhost-ast-tasarimi-2026-11.md): düğüm tablosu `n` (tamsayılar), liste tablosu `l`, sentezlenmiş dize baytları `sb`, ifade span'leri `sp` (düğüm kimliği -> Span düğümü),
# yazıcı çıktısı `o` (bayt). Dize alanı iki tamsayıdır (x, y): x >= 0 ise kaynak metin [x, y); x < 0 ise `sb[-x-1 : -x-1+y]`.
# `opt(str)`/`opt(slice)` yokluğu x == {NONE}; düğüm başvurusunun yokluğu -1.

class Ast:
    src: int
    src_len: int
    n: list[int]
    l: list[int]
    sb: list[int]
    sp_ids: list[int]
    sp_vals: list[int]
    o: list[int]

    def __init__(self, src: int, src_len: int) -> None:
        self.src = src
        self.src_len = src_len
        self.n = []
        self.l = []
        self.sb = []
        self.sp_ids = []
        self.sp_vals = []
        self.o = []

# --- çıktı yardımcıları (Zig `ast_dump_full.zig` ile aynı kaçışlama) ---
def at(base: int, i: int) -> int:
    c: int = 0
    lowlevel:
        c = int(ptr_read(ptr_offset(ptr[u8](base), i)))
    return c

def put(a: Ast, s: str) -> None:
    for i in range(len(s)):
        a.o.append(ord(s[i]))

def put_int(a: Ast, v: int) -> None:
    if v < 0:
        a.o.append(45)
        # -9223372036854775808 için güvenli: işareti ayrı basıp mutlak değeri bölme/mod ile üretmeden önce iki parçaya böl
        if v == -9223372036854775807 - 1:
            put(a, "9223372036854775808")
            return
        v = 0 - v
    if v == 0:
        a.o.append(48)
        return
    digits: list[int] = []
    while v > 0:
        digits.append(48 + v % 10)
        v = v // 10
    k: int = len(digits) - 1
    while k >= 0:
        a.o.append(digits[k])
        k = k - 1

def put_bool(a: Ast, v: int) -> None:
    if v != 0:
        put(a, "true")
    else:
        put(a, "false")

def put_hex16(a: Ast, v: int) -> None:
    k: int = 15
    while k >= 0:
        d: int = (v >> (k * 4)) & 15
        if d < 10:
            a.o.append(48 + d)
        else:
            a.o.append(87 + d)
        k = k - 1

def put_f64(a: Ast, v: int) -> None:
    put(a, "f64:0x")
    put_hex16(a, v)

# Tek bayt (0..255) dize içinde: Zig `str` kaçışlaması.
def put_byte_escaped(a: Ast, c: int) -> None:
    if c == 34:
        put(a, "\\\\\\"")
    elif c == 92:
        put(a, "\\\\\\\\")
    elif c == 10:
        put(a, "\\\\n")
    elif c == 13:
        put(a, "\\\\r")
    elif c == 9:
        put(a, "\\\\t")
    elif c < 32 or c == 127:
        put(a, "\\\\u00")
        d1: int = c >> 4
        d2: int = c & 15
        if d1 < 10:
            a.o.append(48 + d1)
        else:
            a.o.append(87 + d1)
        if d2 < 10:
            a.o.append(48 + d2)
        else:
            a.o.append(87 + d2)
    else:
        a.o.append(c)

def put_str(a: Ast, x: int, y: int) -> None:
    a.o.append(34)
    if x >= 0:
        for i in range(x, y):
            put_byte_escaped(a, at(a.src, i))
    else:
        base: int = 0 - x - 1
        for i in range(y):
            put_byte_escaped(a, a.sb[base + i])
    a.o.append(34)

def put_span_suffix(a: Ast, id: int) -> None:
    for i in range(len(a.sp_ids)):
        if a.sp_ids[i] == id:
            sp: int = a.sp_vals[i]
            put(a, "@")
            put_int(a, a.n[sp + 2])
            put(a, ":")
            put_int(a, a.n[sp + 3])
            put(a, "-")
            put_int(a, a.n[sp + 4])
            put(a, ":")
            put_int(a, a.n[sp + 5])
            put(a, "/")
            put_int(a, a.n[sp + 0])
            put(a, "-")
            put_int(a, a.n[sp + 1])
            return
'''
        )
        # enum yazıcıları
        for name, ty in types.items():
            if ty["kind"] == "enum":
                o.append(f"def d_{name}(a: Ast, v: int) -> None:")
                for i, n in enumerate(ty["names"]):
                    o.append(f"    if v == {i}:")
                    o.append(f'        put(a, ".{n}")')
                    o.append("        return")
                o.append('    put(a, ".?")')
                o.append("")
        # struct / union yazıcıları ve oluşturucuları
        for name, ty in types.items():
            if ty["kind"] == "enum" or name == "Module":
                continue
            if ty["kind"] == "struct":
                o.append(f"def d_{name}(a: Ast, id: int) -> None:")
                off = 0
                first = True
                o.append('    put(a, "{")')
                for fname, ftype, _ in ty["fields"]:
                    t = parse_type(ftype)
                    if t[0] == "skip":
                        continue
                    if not first:
                        o.append('    put(a, " ")')
                    first = False
                    o.append(f'    put(a, "{fname}=")')
                    o += self.value(t, "a.n", f"id + {off}", "    ")
                    off += self.size(t)
                o.append('    put(a, "}")')
                o.append("")
                # oluşturucu: alanlar sırasıyla, bileşenleri düz parametre
                params = []
                stores = []
                for fname, ftype, _ in ty["fields"]:
                    t = parse_type(ftype)
                    if t[0] == "skip":
                        continue
                    sz = self.size(t)
                    if sz == 1:
                        params.append(f"{fname}: int")
                        stores.append(f"    a.n.append({fname})")
                    else:
                        params.append(f"{fname}_0: int")
                        params.append(f"{fname}_1: int")
                        stores.append(f"    a.n.append({fname}_0)")
                        stores.append(f"    a.n.append({fname}_1)")
                o.append(f"def mk_{name}(a: Ast{''.join(', ' + p for p in params)}) -> int:")
                o.append("    id: int = len(a.n)")
                o += stores
                o.append("    return id")
                o.append("")
            else:  # union
                o.append(f"def d_{name}(a: Ast, id: int) -> None:")
                o.append("    tag: int = a.n[id]")
                for i, (vname, vtype, _) in enumerate(ty["fields"]):
                    t = parse_type(vtype)
                    o.append(f"    if tag == {i}:")
                    o.append(f'        put(a, "({vname}")')
                    if t[0] != "void":
                        o.append('        put(a, " ")')
                        o += self.value(t, "a.n", "id + 1", "        ")
                    o.append('        put(a, ")")')
                    o.append("        return")
                o.append('    put(a, "(?)")')
                o.append("")
                for i, (vname, vtype, _) in enumerate(ty["fields"]):
                    t = parse_type(vtype)
                    sz = self.size(t) if t[0] != "void" else 0
                    ps = []
                    ss = [f"    a.n.append({i})"]
                    if sz == 1:
                        ps.append("v0: int")
                        ss.append("    a.n.append(v0)")
                    elif sz == 2:
                        ps += ["v0: int", "v1: int"]
                        ss += ["    a.n.append(v0)", "    a.n.append(v1)"]
                    o.append(f"def mk_{name}_{vname}(a: Ast{''.join(', ' + p for p in ps)}) -> int:")
                    o.append("    id: int = len(a.n)")
                    o += ss
                    o.append("    return id")
                    o.append("")
        # modül yazıcısı ve C ABI
        o.append(
            '''# Modül dökümü (Zig `dumpModuleFull`): `{body=[...] exports=[...]}` + satır sonu. Kökler: gövde (l içinde başlangıç, uzunluk) ve exports (başlangıç, uzunluk).
def dump_module(a: Ast, body_start: int, body_len: int, exp_start: int, exp_len: int) -> None:
    put(a, "{body=[")
    for i in range(body_len):
        put(a, "\\n")
        d_Stmt(a, a.l[body_start + i])
    put(a, "] exports=[")
    for i in range(exp_len):
        if i > 0:
            put(a, " ")
        d_ModuleExports(a, a.l[exp_start + i])
    put(a, "]}\\n")

G: Ast = Ast(0, 0)

# --- Zig <-> Nox test köprüsü: Zig `ast.Module`ünü aynı kodlamayla düz dizilere çevirip bu işlevlerle yükler ---
def nox_ast_reset(src: int, src_len: int) -> int:
    global G
    G = Ast(src, src_len)
    return 0

def nox_ast_push_n(v: int) -> int:
    G.n.append(v)
    return 0

def nox_ast_push_l(v: int) -> int:
    G.l.append(v)
    return 0

def nox_ast_push_sb(v: int) -> int:
    G.sb.append(v)
    return 0

def nox_ast_push_sp(id: int, span: int) -> int:
    G.sp_ids.append(id)
    G.sp_vals.append(span)
    return 0

def nox_ast_dump(body_start: int, body_len: int, exp_start: int, exp_len: int) -> int:
    dump_module(G, body_start, body_len, exp_start, exp_len)
    return len(G.o)

def nox_ast_out_buffer() -> int:
    xs: list[int] = G.o
    p: int = 0
    lowlevel:
        p = ptr_to_int(ptr_of(xs))
    return p
'''
        )
        return "\n".join(o) + "\n"


def main():
    if not os.path.exists(NOXC):
        print("gen_selfhost_ast: zig-out/bin/noxc yok (önce `zig build`)", file=sys.stderr)
        return 2
    types = load_schema()
    text = Gen(types).gen()
    if "--check" in sys.argv:
        cur = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if cur != text:
            print("selfhost/ast_schema.nox güncel değil: scripts/gen_selfhost_ast.py çalıştırın", file=sys.stderr)
            return 1
        print(f"selfhost/ast_schema.nox güncel ({len(types)} tür)")
        return 0
    open(OUT, "w", encoding="utf-8").write(text)
    print(f"yazıldı: {os.path.relpath(OUT, ROOT)} ({len(text.splitlines())} satır, {len(types)} tür)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
