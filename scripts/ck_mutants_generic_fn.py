"""Stage 3.6-C generic functions & generic methods mutation suite (45/45 yakalandı, 0 yaşayan).

Each tuple: (name, old_unique_line, new_line) in selfhost/typecheck.nox.in.
"""

MUTANTS = [
    # 1. register_func / register_extern
    (
        "gfn_reg_skip_dupf",
        "    if m2_get(ck.fmap, 0, sym) >= 0 or m2_get(ck.gfn, 0, sym) >= 0:\n        mp(ck, \"function already defined: \")\n        mp_sym(ck, sym)",
        "    if m2_get(ck.fmap, 0, sym) >= 0:\n        mp(ck, \"function already defined: \")\n        mp_sym(ck, sym)",
    ),
    (
        "gfn_reg_no_store",
        "        m2_put(ck.gfn, 0, sym, fd)\n        return",
        "        return",
    ),
    (
        "gfn_ext_skip_dupf",
        "    if m2_get(ck.fmap, 0, sym) >= 0 or m2_get(ck.gfn, 0, sym) >= 0:\n        mp(ck, \"function already defined: \")\n        mp_sref(ck, a, nm)",
        "    if m2_get(ck.fmap, 0, sym) >= 0:\n        mp(ck, \"function already defined: \")\n        mp_sref(ck, a, nm)",
    ),
    # 2. check_identifier (generic function as value)
    (
        "gfn_ident_allow_val",
        "    if m2_get(ck.gfn, 0, sym) >= 0:\n        mp(ck, \"the generic function '\"",
        "    if False and m2_get(ck.gfn, 0, sym) >= 0:\n        mp(ck, \"the generic function '\"",
    ),
    # 3. check_generic_construct & try_qual_generic_call
    (
        "gfn_construct_skip_lookup",
        "    gfd: int = lookup_generic_func(ck, a, gn)",
        "    gfd: int = -1",
    ),
    (
        "gfn_construct_arity_eq",
        "        if nt != gf_ntp:",
        "        if nt < 0:",
    ),
    (
        "gfn_construct_pos_check",
        "        if gf_needs_exp:\n            mp(ck, \"a call with explicit type arguments ('\")\n            mp_sref(ck, a, gn)",
        "        if False and gf_needs_exp:\n            mp(ck, \"a call with explicit type arguments ('\")\n            mp_sref(ck, a, gn)",
    ),
    (
        "gfn_qual_skip",
        "    if gfe >= 0:\n        gfd: int = ck.gfn.vv[gfe]",
        "    if False and gfe >= 0:\n        gfd: int = ck.gfn.vv[gfe]",
    ),
    (
        "gfn_qual_arity",
        "        if gf_ntp != 1:\n            mp(ck, \"'\")\n            mp_sym(ck, mangled)",
        "        if gf_ntp < 0:\n            mp(ck, \"'\")\n            mp_sym(ck, mangled)",
    ),
    (
        "gfn_qual_pos",
        "        if gf_needs_exp:\n            mp(ck, \"a call with explicit type arguments ('\")\n            mp_sym(ck, mangled)",
        "        if False and gf_needs_exp:\n            mp(ck, \"a call with explicit type arguments ('\")\n            mp_sym(ck, mangled)",
    ),
    # 4. check_call & resolve_mangled_call
    (
        "gfn_call_skip_gmeth",
        "    if len(ck.gm_names.k1) > 0 and (a.n[callee] == {{T:Expr.attribute}} or a.n[callee] == {{T:Expr.index}}):",
        "    if False and len(ck.gm_names.k1) > 0 and (a.n[callee] == {{T:Expr.attribute}} or a.n[callee] == {{T:Expr.index}}):",
    ),
    (
        "gfn_call_skip_gfn",
        "    if gfi >= 0:\n        return instantiate_generic_func(ck, a, fx, ck.gfn.vv[gfi], sym, sl_at(a, c, {{O:Call.args}}), [], False)",
        "    if False and gfi >= 0:\n        return instantiate_generic_func(ck, a, fx, ck.gfn.vv[gfi], sym, sl_at(a, c, {{O:Call.args}}), [], False)",
    ),
    (
        "gfn_mangled_skip",
        "    gfe: int = m2_get(ck.gfn, 0, ms)\n    if gfe >= 0:",
        "    gfe: int = m2_get(ck.gfn, 0, ms)\n    if False and gfe >= 0:",
    ),
    # 5. subst_expr generic method self.m[T](...)
    (
        "gm_subst_index_skip",
        "                if m2_get(ck.gm_names, 0, sym_of(ck, a, cattr)) >= 0:\n                    cal = mk_Expr_index(a, mk_Index(a, cobj, subst_type_arg_expr(ck, a, a.n[cix + {{O:Index.index}}], bnd)))",
        "                if False and m2_get(ck.gm_names, 0, sym_of(ck, a, cattr)) >= 0:\n                    cal = mk_Expr_index(a, mk_Index(a, cobj, subst_type_arg_expr(ck, a, a.n[cix + {{O:Index.index}}], bnd)))",
    ),
    # 6. unify_type_expr branches
    (
        "unify_tp_conflict_skip",
        "                if bnd.vv[be] != actual:\n                    mp(ck, \"in the call to '\"",
        "                if False and bnd.vv[be] != actual:\n                    mp(ck, \"in the call to '\"",
    ),
    (
        "unify_concrete_assign_skip",
        "        if not ty_assignable(tt, declared, actual):\n            mp(ck, \"type mismatch for argument '\"",
        "        if False and not ty_assignable(tt, declared, actual):\n            mp(ck, \"type mismatch for argument '\"",
    ),
    (
        "unify_list_tag_skip",
        "        if sref_eq(a, gn, \"list\") and n == 1:\n            if tt.tag[actual] != 5:",
        "        if sref_eq(a, gn, \"list\") and n == 1:\n            if False and tt.tag[actual] != 5:",
    ),
    (
        "unify_dict_tag_skip",
        "        if sref_eq(a, gn, \"dict\") and n == 2:\n            if tt.tag[actual] != 13:",
        "        if sref_eq(a, gn, \"dict\") and n == 2:\n            if False and tt.tag[actual] != 13:",
    ),
    (
        "unify_dict_val_swap",
        "            unify_type_expr(ck, a, stmt_at(a, gargs, 1), tt.xb[actual], tps, bnd, fn_sym)",
        "            unify_type_expr(ck, a, stmt_at(a, gargs, 1), tt.xa[actual], tps, bnd, fn_sym)",
    ),
    (
        "unify_ptr_tag_skip",
        "        if sref_eq(a, gn, \"ptr\") and n == 1:\n            if tt.tag[actual] != 17:",
        "        if sref_eq(a, gn, \"ptr\") and n == 1:\n            if False and tt.tag[actual] != 17:",
    ),
    (
        "unify_gcls_prefix_skip",
        "            if ci >= 0 and ck.gcls_tn[ci] == n and sym_has_prefix_dunder(ck, a, tt.xa[actual], gn):",
        "            if ci >= 0 and ck.gcls_tn[ci] == n:",
    ),
    (
        "unify_func_arity_skip",
        "        if tt.tag[actual] != 14 or tt.xc[actual] != pky(fps):",
        "        if tt.tag[actual] != 14:",
    ),
    (
        "unify_func_ret_skip",
        "        unify_type_expr(ck, a, a.n[ft + {{O:FuncTypeExpr.return_type}}], tt.xb[actual], tps, bnd, fn_sym)",
        "        return",
    ),
    (
        "unify_opt_none_allow",
        "        elif actual != 4:\n            unify_type_expr(ck, a, inner_te, actual, tps, bnd, fn_sym)",
        "        elif actual == 4:\n            unify_type_expr(ck, a, inner_te, actual, tps, bnd, fn_sym)",
    ),
    # 7. instantiate_generic_func
    (
        "inst_gfn_missing_arg",
        "    if na < np:\n        p0: int = stmt_at(a, ps, na)",
        "    if False and na < np:\n        p0: int = stmt_at(a, ps, na)",
    ),
    (
        "inst_gfn_too_many_args",
        "    if na != np:\n        mp(ck, \"'\")\n        mp_sym(ck, fn_sym)\n        mp(ck, \"' expects \")",
        "    if False and na != np:\n        mp(ck, \"'\")\n        mp_sym(ck, fn_sym)\n        mp(ck, \"' expects \")",
    ),
    (
        "inst_gfn_no_emp_heur",
        "        is_emp: bool = (a.n[arg] == {{T:Expr.list_lit}} and a.n[arg + 2] == 0) or (a.n[arg] == {{T:Expr.dict_lit}} and a.n[arg + 2] == 0)\n        if is_emp:",
        "        is_emp: bool = False\n        if is_emp:",
    ),
    (
        "inst_gfn_no_expected",
        "        if at_ < 0 and has_exp:",
        "        if False and at_ < 0 and has_exp:",
    ),
    (
        "inst_gfn_lam_arity",
        "            if pky(lps) != pky(fps):\n                mp(ck, \"the lambda takes \")",
        "            if False and pky(lps) != pky(fps):\n                mp(ck, \"the lambda takes \")",
    ),
    (
        "inst_gfn_lam_uninf_skip",
        "                try:\n                    lpt = type_expr_to_type(ck, a, lsub)\n                except CkErr:",
        "                try:\n                    lpt = 0\n                except CkErr:",
    ),
    (
        "inst_gfn_uninferable_tp",
        "        if be < 0:\n            mp(ck, \"for '\")\n            mp_sym(ck, fn_sym)",
        "        if be < 0:\n            bound.append(0)\n        if False:",
    ),
    (
        "inst_gfn_skip_cache_lam",
        "    if fe >= 0:\n        csid: int = ck.fmap.vv[fe]\n        check_lambda_args_against(ck, a, fx, csid, args)\n        return ck.fret[csid]",
        "    if fe >= 0:\n        csid: int = ck.fmap.vv[fe]\n        return ck.fret[csid]",
    ),
    (
        "inst_gfn_skip_body_check",
        "    register_func(ck, a, conc)\n    check_function_body(ck, a, conc)",
        "    register_func(ck, a, conc)",
    ),
    (
        "inst_gfn_skip_lam_check",
        "    sid: int = ck.fmap.vv[m2_get(ck.fmap, 0, mangled_sym)]\n    check_lambda_args_against(ck, a, fx, sid, args)",
        "    sid: int = ck.fmap.vv[m2_get(ck.fmap, 0, mangled_sym)]",
    ),
    # 8. extract_generic_methods
    (
        "ext_gm_two_tp",
        "            if pky(tps) != 1:\n                mp(ck, \"generic method '\"",
        "            if pky(tps) < 0:\n                mp(ck, \"generic method '\"",
    ),
    (
        "ext_gm_dunder",
        "            if sref_len(mn) >= 2 and sref_byte(a, mn, 0) == 95 and sref_byte(a, mn, 1) == 95:\n                mp(ck, \"special method '\"",
        "            if False:\n                mp(ck, \"special method '\"",
    ),
    (
        "ext_gm_dup",
        "            if m2_get(ck.gmeth, csym, msym) >= 0:\n                mp(ck, \"generic method '\"",
        "            if False:\n                mp(ck, \"generic method '\"",
    ),
    # 9. try_resolve_generic_method_call
    (
        "gm_call_skip_super",
        "        if a.n[ocal] == {{T:Expr.identifier}} and sref_eq(a, pk(a.n[ocal + 1], a.n[ocal + 2]), \"super\"):\n            return -1",
        "        if False:\n            return -1",
    ),
    (
        "gm_call_no_base_walk",
        "        cur = ck.cls_base[ci]",
        "        cur = -1",
    ),
    (
        "gm_call_arg_count",
        "    if pky(ps) != na + 1:\n        mp(ck, \"'\")\n        mp_sym(ck, def_sym)",
        "    if False:\n        mp(ck, \"'\")\n        mp_sym(ck, def_sym)",
    ),
    (
        "gm_call_bad_te_skip",
        "        if te < 0:\n            mp(ck, \"the type argument of '\"",
        "        if False and te < 0:\n            mp(ck, \"the type argument of '\"",
    ),
    (
        "gm_call_no_emp_heur",
        "            is_emp: bool = (a.n[arg] == {{T:Expr.list_lit}} and a.n[arg + 2] == 0) or (a.n[arg] == {{T:Expr.dict_lit}} and a.n[arg + 2] == 0)",
        "            is_emp: bool = False",
    ),
    (
        "gm_call_uninferable_tp",
        "    if be < 0:\n        mp(ck, \"for '\")\n        mp_sym(ck, def_sym)",
        "    if be < 0:\n        return 0\n    if False:",
    ),
    (
        "gm_call_no_sub_reg",
        "            if is_subclass(ck.tt, ck.cls_sym[sci], def_sym):\n                m2_put(ck.cls_meths, sci, mangled_m, sid)",
        "            if False:\n                m2_put(ck.cls_meths, sci, mangled_m, sid)",
    ),
    (
        "gm_call_skip_body",
        "        try:\n            check_method_body(ck, a, def_ci, conc, False)",
        "        try:\n            def_ci = def_ci",
    ),
]
