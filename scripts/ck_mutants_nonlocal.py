"""nonlocal_desugar, stmt_kind#nested_features, spawn#attribute, lambda/defer grow_stmt mutation suite.

Each tuple: (name, old_unique_line, new_line) in selfhost/typecheck.nox.in.
"""

MUTANTS = [
    # ---- nonlocal_desugar_run ----
    (
        "nl_run_skip",
        "        nonlocal_desugar_run(ck, a, body)",
        "        pass",
    ),
    (
        "nl_decl_func_def_skip",
        "        elif tag == {{T:StmtKind.func_def}}:\n            m2_put(out, 0, sym_of(ck, a, pk(a.n[pay + {{O:FuncDef.name}}], a.n[pay + {{O:FuncDef.name}} + 1])), 1)",
        "        elif tag == {{T:StmtKind.func_def}}:\n            pass",
    ),
    (
        "nl_decl_remove_own_nonlocal_skip",
        "    nls: int = sl_at(a, fd, {{O:FuncDef.nonlocals}})\n    for ni in range(pky(nls)):\n        m2_remove(out, 0, sym_of(ck, a, pk(a.l[pkx(nls) + ni * 2], a.l[pkx(nls) + ni * 2 + 1])))",
        "    pass",
    ),
    (
        "nl_find_type_infer_allow",
        '    if a.n[t] == {{T:TypeExpr.simple}} and sref_eq(a, pk(a.n[t + 1], a.n[t + 2]), "__infer"):\n        return -1',
        "    if False:\n        return -1",
    ),
    (
        "nl_rewrite_unary_skip",
        "    if tag == {{T:Expr.unary}}:\n        nl_rewrite_expr(ck, a, a.n[a.n[e + 1] + {{O:Unary.operand}}], xsym, cell_s)\n        return",
        "    if tag == {{T:Expr.unary}}:\n        return",
    ),
    (
        "nl_rewrite_lambda_shadow_skip",
        "        for i3 in range(pky(lps)):\n            if sym_of(ck, a, pk(a.l[pkx(lps) + i3 * 2], a.l[pkx(lps) + i3 * 2 + 1])) == xsym:\n                return",
        "        if False:\n            return",
    ),
    (
        "nl_rewrite_for_conflict_allow",
        '            if sym_of(ck, a, pk(a.n[pay + {{O:ForStmt.var_name}}], a.n[pay + {{O:ForStmt.var_name}} + 1])) == xsym:\n                mp(ck, "the nonlocal variable \'")',
        '            if False:\n                mp(ck, "the nonlocal variable \'")',
    ),
    (
        "nl_rewrite_func_def_shadow_skip",
        "            if fsym == xsym or m2_get(own_n, 0, xsym) >= 0:\n                continue",
        "            if False:\n                continue",
    ),
    (
        "nl_rewrite_defer_skip",
        "        elif tag == {{T:StmtKind.defer_stmt}}:\n            dc: int = a.n[pay]\n            nl_rewrite_expr(ck, a, a.n[dc + {{O:Call.callee}}], xsym, cell_s)",
        "        elif tag == {{T:StmtKind.defer_stmt}}:\n            dc: int = a.n[pay]\n            pass",
    ),
    (
        "nl_convert_param_prepend_skip",
        "    if is_param:\n        bsl: int = sl_at(a, fd, {{O:FuncDef.body}})",
        "    if False:\n        bsl: int = sl_at(a, fd, {{O:FuncDef.body}})",
    ),
    (
        "nl_process_missing_allow",
        '        if m2_get(own, 0, xsym) < 0:\n            if not nested:\n                mp(ck, "nonlocal \'")',
        '        if m2_get(own, 0, xsym) < 0:\n            if False:\n                mp(ck, "nonlocal \'")',
    ),
    (
        "nl_process_children_skip",
        "    for k2 in kids:\n        nl_process_func(ck, a, k2, True)",
        "    pass",
    ),
    # ---- check_nested_def / stmt_kind.func_def ----
    (
        "nl_nested_generic_allow",
        '        if pky(sl_at(a, pay, {{O:FuncDef.type_params}})) > 0:\n            mp(ck, "a nested function definition CANNOT be generic: ")',
        '        if False:\n            mp(ck, "a nested function definition CANNOT be generic: ")',
    ),
    # ---- resolve_spawn_attr_callee (spawn#attribute) ----
    (
        "nl_find_method_base_skip",
        "        cur = ck.cls_base[ci]\n    return -1",
        "        cur = -1\n    return -1",
    ),
    (
        "nl_spawn_nonclass_allow",
        '    if ck.tt.tag[recv_t] != 6:\n        fail2(ck, "NotCallable", "\'spawn\' can only wrap a function or a method call on a class instance")',
        '    if False:\n        fail2(ck, "NotCallable", "\'spawn\' can only wrap a function or a method call on a class instance")',
    ),
    (
        "nl_spawn_undef_method_allow",
        '    if md < 0:\n        mp(ck, "class \'")',
        '    if False:\n        mp(ck, "class \'")',
    ),
    (
        "nl_spawn_arity_allow",
        '    if mpn == 0 or can != mpn - 1:\n        exp_n: int = 0',
        '    if False:\n        exp_n: int = 0',
    ),
    (
        "nl_spawn_missing_return_err",
        "    check_block(ck, a, ifx, body)\n    if ret != 4 and not always_returns(a, body):",
        "    check_block(ck, a, ifx, body)\n    if False:",
    ),
    # ---- check_lambda / check_defer grow & extend ----
    (
        "nl_lambda_grow_skip",
        "    if ret == 4:\n        if not try_check_extend_stmt(ck, a, ifx, body) and not try_check_element_grow_stmt(ck, a, ifx, body):\n            check_expr(ck, a, ifx, body)",
        "    if ret == 4:\n        check_expr(ck, a, ifx, body)",
    ),
    (
        "nl_defer_grow_skip",
        "    if not try_check_extend_stmt(ck, a, ifx, ce) and not try_check_element_grow_stmt(ck, a, ifx, ce):\n        check_expr(ck, a, ifx, ce)",
        "    check_expr(ck, a, ifx, ce)",
    ),
]
