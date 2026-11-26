"""Stage 3.6-D prelude generic types/calls & protocol_def mutation suite (41/41 yakalandı, 0 yaşayan).

Each tuple: (name, old_unique_line, new_line) in selfhost/typecheck.nox.in.
"""

MUTANTS = [
    # 1. type_expr_to_type protocol base + generic prelude
    (
        "pp_te_proto_base_skip",
        "    psym_t: int = sym_of(ck, a, v)\n    if m2_get(ck.proto_defs, 0, psym_t) >= 0:\n        return ensure_protocol_base(ck, a, psym_t)",
        "    psym_t: int = sym_of(ck, a, v)\n    if False and m2_get(ck.proto_defs, 0, psym_t) >= 0:\n        return ensure_protocol_base(ck, a, psym_t)",
    ),
    # 2. check_call try_desugar_prelude_call hook
    (
        "pp_call_skip_prelude",
        "    pt_r: int = try_desugar_prelude_call(ck, a, fx, c, callee)\n    if pt_r >= 0:\n        return pt_r",
        "    pt_r: int = -1\n    if pt_r >= 0:\n        return pt_r",
    ),
    # 3. short_circuit_any_all
    (
        "pp_any_all_range_skip",
        "                        if is_any:\n                            callee_name = \"__nox_any_range\"\n                        else:\n                            callee_name = \"__nox_all_range\"",
        "                        if is_any:\n                            callee_name = \"__nox_all_range\"\n                        else:\n                            callee_name = \"__nox_all_range\"",
    ),
    (
        "pp_any_all_pred_skip",
        "        if ck.tt.tag[it_t] != 5:\n            return -1\n        src_args.append(it)",
        "        if ck.tt.tag[it_t] != 5:\n            return 2\n        src_args.append(it)",
    ),
    (
        "pp_any_all_cond_neg_skip",
        "        else:\n            neg: int = mk_Expr_unary(a, mk_Unary(a, {{E:UnaryOp.not_}}, cond))\n            body = mk_Expr_binary(a, mk_Binary(a, {{E:BinaryOp.or_}}, neg, elem, 0, 0, 0, 0))",
        "        else:\n            body = elem",
    ),
    # 4. try_desugar_prelude_call branches
    (
        "pp_user_shadow_skip",
        "    if class_idx(ck, sym) >= 0 or (m2_get(ck.fmap, 0, sym) >= 0 and not is_prelude_name(a, cv)):",
        "    if False:",
    ),
    (
        "pp_genexpr_skip",
        "        if a.n[a0_g] == {{T:Expr.list_comp}} and a.n[a.n[a0_g + 1] + {{O:ListComp.is_genexpr}}] != 0:",
        "        if False:",
    ),
    (
        "pp_takes_iter_skip",
        "            if at_i >= 0 and has_dunder(ck, at_i, \"__iter__\"):",
        "            if False:",
    ),
    (
        "pp_list_range_skip",
        "        if is_rng_l:\n            ck.lam_cnt = ck.lam_cnt + 1",
        "        if False:\n            ck.lam_cnt = ck.lam_cnt + 1",
    ),
    (
        "pp_list_str_skip",
        "        if at_l == 3:\n            return check_expr(ck, a, fx, mk_ident_call(a, \"__nox_str_chars\", [arg0]))",
        "        if False:\n            return check_expr(ck, a, fx, mk_ident_call(a, \"__nox_str_chars\", [arg0]))",
    ),
    (
        "pp_list_bad_allow",
        "        fail2(ck, \"TypeMismatch\", \"'list' only works on list/str/dict/range\")",
        "        return ty_list(ck.tt, 0)",
    ),
    (
        "pp_set_skip",
        "    if sref_eq(a, cv, \"set\") and n == 1 and positional == 1:",
        "    if False:",
    ),
    (
        "pp_bool_bad_allow",
        "        fail2(ck, \"TypeMismatch\", \"'bool' only works on bool/int/float/str/list/dict/class\")",
        "        return 2",
    ),
    (
        "pp_bool_dunder_skip",
        "            if has_dunder(ck, at_b, \"__bool__\"):\n                check_expr(ck, a, fx, mk_dunder_call(a, b_arg, \"__bool__\", []))\n                return 2",
        "            if False:\n                return 2",
    ),
    (
        "pp_max_list_skip",
        "        else:\n            if is_max:\n                rename_callee_str(a, callee, \"__nox_max_list\")",
        "        else:\n            if is_max:\n                return -1",
    ),
    (
        "pp_max_many_skip",
        "    if (sref_eq(a, cv, \"max\") or sref_eq(a, cv, \"min\")) and positional >= 3 and positional == n:",
        "    if False:",
    ),
    (
        "pp_hex_skip",
        "            if sref_eq(a, cv, \"hex\"):\n                rename_callee_str(a, callee, \"__nox_hex\")",
        "            if sref_eq(a, cv, \"hex\"):\n                return -1",
    ),
    (
        "pp_pow_int_swap",
        "            elif at_p == 0:\n                rename_callee_str(a, callee, \"__nox_pow_int\")",
        "            elif at_p == 1:\n                rename_callee_str(a, callee, \"__nox_pow_int\")",
    ),
    (
        "pp_int_base_skip",
        "        if sref_eq(a, cv, \"int\") and n == 2:",
        "        if False:",
    ),
    (
        "pp_zip3_skip",
        "        if sref_eq(a, cv, \"zip\") and n == 3:",
        "        if False:",
    ),
    (
        "pp_sum_float_skip",
        "        if ck.tt.tag[at_s] == 5 and ck.tt.xa[at_s] == 1:\n            rename_callee_str(a, callee, \"sum_float\")",
        "        if False:\n            rename_callee_str(a, callee, \"sum_float\")",
    ),
    (
        "pp_format_spec_allow",
        "        if st_f != 3:\n            fail2(ck, \"TypeMismatch\", \"the second argument of 'format' (the spec) must be a str\")",
        "        if False:\n            fail2(ck, \"TypeMismatch\", \"the second argument of 'format' (the spec) must be a str\")",
    ),
    (
        "pp_format_bool_skip",
        "            if at_f == 2:\n                tern: int = mk_Expr_ternary(a, mk_Ternary(a, f_a0, mk_Expr_int_lit(a, 1), mk_Expr_int_lit(a, 0)))",
        "            if False:\n                tern: int = mk_Expr_ternary(a, mk_Ternary(a, f_a0, mk_Expr_int_lit(a, 1), mk_Expr_int_lit(a, 0)))",
    ),
    (
        "pp_format_bad_allow",
        "        fail2(ck, \"TypeMismatch\", \"'format' only works for int/float/str/bool (and classes that have `__str__`)\")",
        "        return 3",
    ),
    (
        "pp_round_skip",
        "    if sref_eq(a, cv, \"round\") and n == 2:",
        "    if False:",
    ),
    # 5. collect_protocols
    (
        "pp_proto_dup_skip",
        "        if m2_get(ck.proto_defs, 0, psym) >= 0:\n            mp(ck, \"protocol already defined: \")",
        "        if False:\n            mp(ck, \"protocol already defined: \")",
    ),
    (
        "pp_proto_gen_meth_skip",
        "            if pky(sl_at(a, m, {{O:FuncDef.type_params}})) > 0:\n                mp(ck, \"protocol methods cannot be generic: \")",
        "            if False:\n                mp(ck, \"protocol methods cannot be generic: \")",
    ),
    (
        "pp_proto_self_name_skip",
        "            if not sref_eq(a, p0n, \"self\"):\n                mp(ck, \"protocol method '\")",
        "            if False:\n                mp(ck, \"protocol method '\")",
    ),
    (
        "pp_proto_self_type_skip",
        "            if not self_ok:\n                mp(ck, \"inside protocol method '\")",
        "            if False:\n                mp(ck, \"inside protocol method '\")",
    ),
    (
        "pp_proto_pass_body_skip",
        "            if pky(mbd) != 1 or a.n[a.n[stmt_at(a, mbd, 0) + {{O:Stmt.kind}}]] != {{T:StmtKind.pass_stmt}}:",
        "            if False:",
    ),
    # 6. register_func implicit protocol type params
    (
        "pp_reg_proto_tp_skip",
        "    for pi_p in range(pky(ps)):\n        collect_protocol_names(ck, a, a.n[stmt_at(a, ps, pi_p) + {{O:Param.type_expr}}], eff_syms, eff_srefs)",
        "    for pi_p in range(0):\n        collect_protocol_names(ck, a, a.n[stmt_at(a, ps, pi_p) + {{O:Param.type_expr}}], eff_syms, eff_srefs)",
    ),
    # 7. satisfies_protocol & unify_type_expr
    (
        "pp_sat_skip_in_unify",
        "                if m2_get(ck.proto_defs, 0, sym) >= 0:\n                    satisfies_protocol(ck, actual, sym, fn_sym)",
        "                if False:\n                    satisfies_protocol(ck, actual, sym, fn_sym)",
    ),
    (
        "pp_sat_non_cls_allow",
        "    if ck.tt.tag[actual] != 6:\n        mp(ck, \"in the call to '\")",
        "    if False:\n        mp(ck, \"in the call to '\")",
    ),
    (
        "pp_sat_miss_meth_skip",
        "        if me < 0:\n            mp(ck, \"class '\")\n            mp_sym(ck, csym)\n            mp(ck, \"' does not satisfy protocol '\")",
        "        if False:\n            mp(ck, \"class '\")\n            mp_sym(ck, csym)\n            mp(ck, \"' does not satisfy protocol '\")",
    ),
    (
        "pp_sat_param_cnt_skip",
        "        if ck.fpn[csid] != ck.fpn[psid]:\n            mp(ck, \"class '\")",
        "        if False:\n            mp(ck, \"class '\")",
    ),
    (
        "pp_sat_param_ty_skip",
        "            if ck.fpar[ck.fps[csid] + j] != ck.fpar[ck.fps[psid] + j]:\n                mp(ck, \"class '\")",
        "            if False:\n                mp(ck, \"class '\")",
    ),
    (
        "pp_sat_ret_ty_skip",
        "        if ck.fret[csid] != ck.fret[psid]:\n            mp(ck, \"class '\")",
        "        if False:\n            mp(ck, \"class '\")",
    ),
    # 8. value-safe protocol & assignable_or_coerce & empty-list guard
    (
        "pp_val_safe_skip",
        "        if len(syms) > 0:\n            mp(ck, \"protocol '\")",
        "        if False:\n            mp(ck, \"protocol '\")",
    ),
    (
        "pp_coerce_skip",
        "    pe: int = m2_get(ck.proto_bases, 0, ck.tt.xa[target])\n    if pe < 0:\n        return False",
        "    pe: int = -1\n    if pe < 0:\n        return False",
    ),
    (
        "pp_coerce_sat_skip",
        "    if not class_satisfies_protocol(ck, ck.tt.xa[value], psym):\n        return False",
        "    if False:\n        return False",
    ),
    (
        "pp_emp_mentions_proto_skip",
        "        is_emp: bool = ((a.n[arg] == {{T:Expr.list_lit}} and a.n[arg + 2] == 0) or (a.n[arg] == {{T:Expr.dict_lit}} and a.n[arg + 2] == 0)) and not mentions_protocol(ck, a, pte)\n        if is_emp:\n            sv_c: int = len(ck.mb)",
        "        is_emp: bool = ((a.n[arg] == {{T:Expr.list_lit}} and a.n[arg + 2] == 0) or (a.n[arg] == {{T:Expr.dict_lit}} and a.n[arg + 2] == 0))\n        if is_emp:\n            sv_c: int = len(ck.mb)",
    ),
]
