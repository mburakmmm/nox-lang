"""class#decorators, class#bases, method_features, bound_method, index_call, elem_grow, list_extend/sort, dict_items, lowlevel/adopt, try#dotted, enumerate/zip, dunders mutation suite.

Each tuple: (name, old_unique_line, new_line) in selfhost/typecheck.nox.in.
"""

MUTANTS = [
    # ---- class#bases / mixin_flatten ----
    (
        "cmo_mx_skip",
        "        mixin_flatten_run(ck, a, body)",
        "        pass",
    ),
    (
        "cmo_mx_cycle_allow",
        '    if m2_get(vis, 0, csym) >= 0:\n        ck.cur_line = line\n        mp(ck, "class \'")\n        mp_sym(ck, csym)\n        mp(ck, "\': cyclic base classes")\n        raise mk_fail(ck, "TypeMismatch")',
        "    if False:\n        pass",
    ),
    (
        "cmo_mx_super_allow",
        '        if from_mixin and a.n[cal] == {{T:Expr.identifier}} and sref_eq(a, pk(a.n[cal + 1], a.n[cal + 2]), "super"):',
        "        if False:",
    ),
    (
        "cmo_mx_compat_skip",
        "def validate_mixin_compat(ck: Ck, a: Ast, idx: int) -> None:\n    cd: int = ck.cls_node[idx]",
        "def validate_mixin_compat(ck: Ck, a: Ast, idx: int) -> None:\n    return\n    cd: int = ck.cls_node[idx]",
    ),
    (
        "cmo_mx_add_mixin_skip",
        "        cls_add_mixin(ck.tt, csym, mxsym)",
        "        pass",
    ),
    # ---- class#decorators / derive + repr/packed ----
    (
        "cmo_drv_skip",
        "        derive_run(ck, a, body)",
        "        pass",
    ),
    (
        "cmo_drv_init_conflict_allow",
        '        if drv_has_method(a, cd, "__init__"):',
        "        if False:",
    ),
    (
        "cmo_drv_unknown_allow",
        '                            mp(ck, "unknown @derive name \\"")\n                            mp_sref(ck, a, asr)\n                            mp(ck, "\\" (known: \\"order\\", \\"copy\\", \\"json\\"; class ")',
        "                            return",
    ),
    (
        "cmo_repr_base_mismatch_allow",
        '        if lmode != blmode:\n            mp(ck, "the @repr/@packed state of class \'")',
        '        if False:\n            mp(ck, "the @repr/@packed state of class \'")',
    ),
    # ---- class#method_features ----
    (
        "cmo_meth_cap_skip",
        "                    register_capability_decorator(ck, a, sym_lit(ck, mstr_q), sl_at(a, mdec, {{O:Decorator.args}}))",
        "                    pass",
    ),
    (
        "cmo_meth_async_ctx_skip",
        "    fx: Fx = Fx(scope, ret, a.n[m + {{O:FuncDef.is_async}}] != 0 or a.n[m + {{O:FuncDef.allow_await}}] != 0)",
        "    fx: Fx = Fx(scope, ret, False)",
    ),
    # ---- index_call_fixup & bound_method_fixup ----
    (
        "cmo_icf_skip",
        "        index_call_fixup_run(ck, a, body)",
        "        pass",
    ),
    (
        "cmo_bmf_skip",
        "        bound_method_fixup_run(ck, a, body)",
        "        pass",
    ),
    (
        "cmo_bmf_async_allow",
        "                if a.n[m + {{O:FuncDef.is_async}}] != 0 and sref_eq(a, pk(a.n[m + {{O:FuncDef.name}}], a.n[m + {{O:FuncDef.name}} + 1]), astr):",
        "                if False:",
    ),
    (
        "cmo_idx_call_nonfunc_allow",
        '        if ck.tt.tag[cel_t] != 14:\n            fail2(ck, "NotCallable", "this expression is not callable")',
        '        if False:\n            fail2(ck, "NotCallable", "this expression is not callable")',
    ),
    # ---- elem_grow, list_extend, list_sort_kwargs, dict_items ----
    (
        "cmo_elem_grow_skip",
        "def try_check_element_grow_stmt(ck: Ck, a: Ast, fx: Fx, e: int) -> bool:\n    if a.n[e] != {{T:Expr.call}}:",
        "def try_check_element_grow_stmt(ck: Ck, a: Ast, fx: Fx, e: int) -> bool:\n    return False\n    if a.n[e] != {{T:Expr.call}}:",
    ),
    (
        "cmo_elem_grow_duplicable_allow",
        '    if not is_duplicable_expr(a, obj):\n        mp(ck, "\'")',
        '    if False:\n        mp(ck, "\'")',
    ),
    (
        "cmo_extend_skip",
        "def try_check_extend_stmt(ck: Ck, a: Ast, fx: Fx, e: int) -> bool:\n    if a.n[e] != {{T:Expr.call}}:",
        "def try_check_extend_stmt(ck: Ck, a: Ast, fx: Fx, e: int) -> bool:\n    return False\n    if a.n[e] != {{T:Expr.call}}:",
    ),
    (
        "cmo_sort_kwargs_skip",
        '            return check_expr(ck, a, fx, mk_ident_call(a, snm, sargs))',
        '            raise unsup(ck, "list_sort_kwargs")',
    ),
    (
        "cmo_dict_items_skip",
        '        return check_expr(ck, a, fx, mk_ident_call(a, "__nox_dict_items", [a.n[a.n[a.n[c + {{O:Call.callee}}] + 1] + {{O:Attribute.obj}}]]))',
        '        raise unsup(ck, "dict_items")',
    ),
    # ---- lowlevel & adopt ----
    (
        "cmo_adopt_skip",
        '            if expected_in < 0:\n                fail2(ck, "UnknownType", "\'adopt\' can only be used in a context whose expected type is known (var_decl/return/assignment/argument)")\n            return expected_in',
        "            return -1",
    ),
    (
        "cmo_ll_scope_no_remove",
        "                if not known:\n                    m2_remove(ck.vars, fx.scope, kn2)",
        "                if False:\n                    m2_remove(ck.vars, fx.scope, kn2)",
    ),
    # ---- try#dotted, enumerate/zip, dunders ----
    (
        "cmo_try_dotted_skip",
        '                if class_idx(ck, msym_d) < 0:\n                    mp(ck, "unknown class: ")',
        '                if False:\n                    mp(ck, "unknown class: ")',
    ),
    (
        "cmo_enum_zip_skip",
        "def try_fuse_enumerate_zip_for(ck: Ck, a: Ast, fx: Fx, f: int) -> bool:\n    it: int = a.n[f + {{O:ForStmt.iterable}}]",
        "def try_fuse_enumerate_zip_for(ck: Ck, a: Ast, fx: Fx, f: int) -> bool:\n    return False\n    it: int = a.n[f + {{O:ForStmt.iterable}}]",
    ),
    (
        "cmo_dunder_getitem_skip",
        '    if has_dunder(ck, obj_t, "__getitem__"):\n        return check_expr(ck, a, fx, mk_dunder_call(a, a.n[ip + {{O:Index.obj}}], "__getitem__", [ie]))',
        '    if False:\n        return check_expr(ck, a, fx, mk_dunder_call(a, a.n[ip + {{O:Index.obj}}], "__getitem__", [ie]))',
    ),
    (
        "cmo_dunder_setitem_skip",
        '    if has_dunder(ck, obj_t, "__setitem__"):\n        check_expr(ck, a, fx, mk_dunder_call(a, a.n[ip + {{O:Index.obj}}], "__setitem__", [a.n[ip + {{O:Index.index}}], a.n[asg + {{O:Assign.value}}]]))',
        '    if False:\n        check_expr(ck, a, fx, mk_dunder_call(a, a.n[ip + {{O:Index.obj}}], "__setitem__", [a.n[ip + {{O:Index.index}}], a.n[asg + {{O:Assign.value}}]]))',
    ),
    (
        "cmo_dunder_len_skip",
        '    if has_dunder(ck, t, "__len__"):\n        rt_l: int = check_expr(ck, a, fx, mk_dunder_call(a, stmt_at(a, args, 0), "__len__", []))',
        '    if False:\n        rt_l: int = check_expr(ck, a, fx, mk_dunder_call(a, stmt_at(a, args, 0), "__len__", []))',
    ),
    (
        "cmo_dunder_lazy_skip",
        "                if ck.fpn[nxsid] == 0 and tt.tag[nxret] == 15:\n                    ck.lazy_for_iter = t",
        "                if False:\n                    ck.lazy_for_iter = t",
    ),
]
