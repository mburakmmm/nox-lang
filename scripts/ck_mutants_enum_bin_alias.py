"""type_alias, walrus/unpack, binary/narrowing/dunder, method_features, enum/match mutation suite.

Each tuple: (name, old_unique_line, new_line) in selfhost/typecheck.nox.in.
"""

MUTANTS = [
    # ---- toplevel#2: type_alias ----
    (
        "eba_ta_skip",
        "    if not any_ta:\n        return\n    ta_map: Map2 = Map2()",
        "    return\n    ta_map: Map2 = Map2()",
    ),
    (
        "eba_ta_dup_allow",
        '                mp(ck, "the type alias \'")\n                mp_sym(ck, nsym)\n                mp(ck, "\' is defined twice")\n                raise mk_fail(ck, "TypeMismatch")',
        "                pass",
    ),
    (
        "eba_ta_clash_allow",
        '            mp(ck, "\' clashes with a class/function of the same name")\n            raise mk_fail(ck, "TypeMismatch")',
        "            pass",
    ),
    # ---- check_stmt#2 / check_stmt#1: walrus & unpack ----
    (
        "eba_walrus_mod_allow",
        '    if fx.scope == ck.top_scope and fx.ret < 0:\n        mp(ck, "\':=\' can only be used inside a function or method; at module level write the type: \'")',
        '    if False:\n        mp(ck, "\':=\' can only be used inside a function or method; at module level write the type: \'")',
    ),
    (
        "eba_walrus_none_allow",
        '    if vt == {{T:Expr.none_lit}}:\n        mp(ck, "cannot infer the type of \'")',
        '    if False:\n        mp(ck, "cannot infer the type of \'")',
    ),
    (
        "eba_walrus_list_allow",
        '    if vt == {{T:Expr.list_lit}} and a.n[val + 2] == 0:\n        mp(ck, "cannot infer the element type of \'")',
        '    if False:\n        mp(ck, "cannot infer the element type of \'")',
    ),
    (
        "eba_walrus_dict_allow",
        '    if vt == {{T:Expr.dict_lit}} and a.n[val + 2] == 0:\n        mp(ck, "cannot infer the key/value types of \'")',
        '    if False:\n        mp(ck, "cannot infer the key/value types of \'")',
    ),
    (
        "eba_walrus_ret_none_allow",
        '    if t == 4:\n        mp(ck, "the value for \'")\n        mp_sref(ck, a, nm)\n        mp(ck, "\' does not produce a type (a call that returns None cannot be assigned)")',
        '    if False:\n        mp(ck, "the value for \'")\n        mp_sref(ck, a, nm)\n        mp(ck, "\' does not produce a type (a call that returns None cannot be assigned)")',
    ),
    (
        "eba_walrus_no_infer_line",
        "    if m2_get(fx.infer_lines, 0, sym) < 0:\n        m2_put(fx.infer_lines, 0, sym, ck.cur_line)",
        "    if False:\n        m2_put(fx.infer_lines, 0, sym, ck.cur_line)",
    ),
    (
        "eba_divmod_skip",
        '        if a.n[vcal] == {{T:Expr.identifier}} and sref_eq(a, pk(a.n[vcal + 1], a.n[vcal + 2]), "divmod") and pky(vargs) == 2 and m2_get(ck.fmap, 0, sym_lit(ck, "divmod")) < 0:',
        "        if False:",
    ),
    # ---- check_binary#1 / #2: narrowing & dunder ----
    (
        "eba_nar_not_skip",
        "        if a.n[up + {{O:Unary.op}}] == {{E:UnaryOp.not_}}:\n            collect_narrows(ck, a, fx, a.n[up + {{O:Unary.operand}}], not positive, out_k, out_t)",
        "        if False:\n            collect_narrows(ck, a, fx, a.n[up + {{O:Unary.operand}}], not positive, out_k, out_t)",
    ),
    (
        "eba_nar_and_skip",
        "    if op == {{E:BinaryOp.and_}}:\n        if positive:\n            lk: list[int] = []",
        "    if op == {{E:BinaryOp.and_}}:\n        if False:\n            lk: list[int] = []",
    ),
    (
        "eba_nar_or_skip",
        "    if op == {{E:BinaryOp.or_}}:\n        if not positive:\n            lk2: list[int] = []",
        "    if op == {{E:BinaryOp.or_}}:\n        if False:\n            lk2: list[int] = []",
    ),
    (
        "eba_nar_flip",
        "    narrows_then: bool = (op == {{E:BinaryOp.ne}})",
        "    narrows_then: bool = (op == {{E:BinaryOp.eq}})",
    ),
    (
        "eba_nar_inv_prefix_skip",
        "def invalidate_narrow_prefix(ck: Ck, fx: Fx, key: str) -> None:\n    if fx.narrowed.live == 0:\n        return",
        "def invalidate_narrow_prefix(ck: Ck, fx: Fx, key: str) -> None:\n    return",
    ),
    (
        "eba_guard_norm_skip",
        "def guard_normalize_run(a: Ast, body: int) -> None:",
        "def guard_normalize_run(a: Ast, body: int) -> None:\n    return",
    ),
    (
        "eba_dunder_contains_skip",
        '    if op == {{E:BinaryOp.in_}} or op == {{E:BinaryOp.not_in}}:\n        if not has_dunder(ck, r, "__contains__"):',
        '    if False:\n        if not has_dunder(ck, r, "__contains__"):',
    ),
    (
        "eba_dunder_fwd_skip",
        "        if lc and has_dunder(ck, l, fwd):\n            return check_expr(ck, a, fx, mk_dunder_call(a, left, fwd, [right]))",
        "        if False:\n            return check_expr(ck, a, fx, mk_dunder_call(a, left, fwd, [right]))",
    ),
    (
        "eba_dunder_refl_skip",
        "        if rc and has_dunder(ck, r, refl):\n            return check_expr(ck, a, fx, mk_dunder_call(a, right, refl, [left]))",
        "        if False:\n            return check_expr(ck, a, fx, mk_dunder_call(a, right, refl, [left]))",
    ),
    (
        "eba_dunder_cmp_skip",
        "    if lc and has_dunder(ck, l, dname):\n        rt2: int = check_expr(ck, a, fx, mk_dunder_call(a, left, dname, [right]))",
        "    if False:\n        rt2: int = check_expr(ck, a, fx, mk_dunder_call(a, left, dname, [right]))",
    ),
    # ---- class#method_features ----
    (
        "eba_static_skip",
        "def try_resolve_static_method_call(ck: Ck, a: Ast, fx: Fx, c: int) -> None:\n    if ck.static_names.live == 0:\n        return",
        "def try_resolve_static_method_call(ck: Ck, a: Ast, fx: Fx, c: int) -> None:\n    return",
    ),
    (
        "eba_prop_skip",
        "def find_property(ck: Ck, ci: int, asym: int) -> int:\n    cur: int = ci",
        "def find_property(ck: Ck, ci: int, asym: int) -> int:\n    return -1\n    cur: int = ci",
    ),
    # ---- class#enum / check_stmt#3 (match) ----
    (
        "eba_enum_gen_exp_skip",
        "def try_generic_enum_expected(ck: Ck, a: Ast, fx: Fx, e: int, expected: int) -> int:\n    exp_sym: int = ck.tt.xa[expected]",
        "def try_generic_enum_expected(ck: Ck, a: Ast, fx: Fx, e: int, expected: int) -> int:\n    return -1\n    exp_sym: int = ck.tt.xa[expected]",
    ),
    (
        "eba_enum_gen_call_skip",
        "def try_resolve_generic_enum_call(ck: Ck, a: Ast, fx: Fx, c: int) -> None:\n    cal: int = a.n[c + {{O:Call.callee}}]",
        "def try_resolve_generic_enum_call(ck: Ck, a: Ast, fx: Fx, c: int) -> None:\n    return\n    cal: int = a.n[c + {{O:Call.callee}}]",
    ),
    (
        "eba_match_exh_always_true",
        "def matrix_exhaustive(ck: Ck, a: Ast, rows: list[list[int]], col_types: list[int], pool: list[MPat]) -> bool:\n    if len(rows) == 0:\n        return False",
        "def matrix_exhaustive(ck: Ck, a: Ast, rows: list[list[int]], col_types: list[int], pool: list[MPat]) -> bool:\n    return True\n    if len(rows) == 0:\n        return False",
    ),
    (
        "eba_match_exh_always_false",
        "def matrix_exhaustive(ck: Ck, a: Ast, rows: list[list[int]], col_types: list[int], pool: list[MPat]) -> bool:\n    if len(rows) == 0:\n        return False",
        "def matrix_exhaustive(ck: Ck, a: Ast, rows: list[list[int]], col_types: list[int], pool: list[MPat]) -> bool:\n    return False\n    if len(rows) == 0:\n        return False",
    ),
    (
        "eba_enum_tag_missing_allow",
        '            if find_enum_variant_sym(ck, a, gcd_e, vsym_e) < 0:\n                mp(ck, "enum \'")',
        '            if False:\n                mp(ck, "enum \'")',
    ),
    (
        "eba_enum_unit_call_allow",
        '        if ev_e >= 0 and pky(sl_at(a, ev_e, {{O:EnumVariant.fields}})) == 0:\n            mp(ck, "cannot infer the type arguments of generic enum \'")',
        '        if False:\n            mp(ck, "cannot infer the type arguments of generic enum \'")',
    ),
]
