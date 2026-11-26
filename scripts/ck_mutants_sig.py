"""Signature features (defaults, *args, **kwargs, kw_only, pos_only) mutation suite.

23/23 yakalandı, 0 yaşayan (parser-engelli star_value >= 0 çıkarıldı).
Each tuple: (name, old_unique_line, new_line) in selfhost/typecheck.nox.in.
"""

MUTANTS = [
    # 1. validate_param_defaults
    (
        "sig_def_nondef_after_skip",
        "            if seen_default and a.n[p + {{O:Param.variadic}}] == 0 and a.n[p + {{O:Param.var_kw}}] == 0 and a.n[p + {{O:Param.kw_only}}] == 0:",
        "            if False:",
    ),
    (
        "sig_def_kw_only_forbid",
        "            if seen_default and a.n[p + {{O:Param.variadic}}] == 0 and a.n[p + {{O:Param.var_kw}}] == 0 and a.n[p + {{O:Param.kw_only}}] == 0:",
        "            if seen_default:",
    ),
    (
        "sig_def_unary_neg_skip",
        "            if uop == {{E:UnaryOp.neg}} and a.n[uod] == {{T:Expr.int_lit}}:\n                lit_t = 0",
        "            if False:\n                lit_t = 0",
    ),
    (
        "sig_def_nonconst_allow",
        "        else:\n            mp(ck, \"function '\")\n            mp_sref(ck, a, fn_sr)\n            mp(ck, \"', parameter '\")\n            mp_sref(ck, a, pn)\n            mp(ck, \"': the default value can only be a constant literal (int/float/bool/str/None, a negative number)\")",
        "        else:\n            continue\n            mp(ck, \"function '\")\n            mp_sref(ck, a, fn_sr)\n            mp(ck, \"', parameter '\")\n            mp_sref(ck, a, pn)\n            mp(ck, \"': the default value can only be a constant literal (int/float/bool/str/None, a negative number)\")",
    ),
    (
        "sig_def_none_nonopt_allow",
        "        if lit_t == 4:\n            ok = ck.tt.tag[pt] == 15",
        "        if lit_t == 4:\n            ok = True",
    ),
    (
        "sig_def_type_mismatch_allow",
        "        if not ok:\n            mp(ck, \"function '\")\n            mp_sref(ck, a, fn_sr)\n            mp(ck, \"', parameter '\")\n            mp_sref(ck, a, pn)\n            mp(ck, \"': the type of the default value does not match the parameter type\")",
        "        if False:\n            mp(ck, \"function '\")\n            mp_sref(ck, a, fn_sr)\n            mp(ck, \"', parameter '\")\n            mp_sref(ck, a, pn)\n            mp(ck, \"': the type of the default value does not match the parameter type\")",
    ),
    # 2. any_variadic & expr_has_effects
    (
        "sig_any_var_false",
        "        if a.n[p + {{O:Param.variadic}}] != 0 or a.n[p + {{O:Param.var_kw}}] != 0 or a.n[p + {{O:Param.kw_only}}] != 0:\n            return True",
        "        if False:\n            return True",
    ),
    (
        "sig_eff_pure_always_true",
        "    if tag == {{T:Expr.int_lit}} or tag == {{T:Expr.float_lit}} or tag == {{T:Expr.bool_lit}} or tag == {{T:Expr.string_lit}} or tag == {{T:Expr.none_lit}} or tag == {{T:Expr.identifier}} or tag == {{T:Expr.lambda}}:\n        return False",
        "    if False:\n        return False",
    ),
    # 3. expand_call_args
    (
        "sig_exp_dstar_no_kw_allow",
        "                if kw_idx < 0:\n                    mp(ck, \"'\")\n                    mp_sym(ck, nm_sym)\n                    mp(ck, \"': '**' unpacking in a call needs a '**kwargs' parameter\")",
        "                if False:\n                    mp(ck, \"'\")\n                    mp_sym(ck, nm_sym)\n                    mp(ck, \"': '**' unpacking in a call needs a '**kwargs' parameter\")",
    ),
    (
        "sig_exp_star_no_var_allow",
        "                if variadic_idx < 0 or i != variadic_idx or star_value >= 0:\n                    mp(ck, \"'\")\n                    mp_sym(ck, nm_sym)\n                    mp(ck, \"': '*' unpacking in a call needs a '*args' parameter exactly at that position\")",
        "                if False:\n                    mp(ck, \"'\")\n                    mp_sym(ck, nm_sym)\n                    mp(ck, \"': '*' unpacking in a call needs a '*args' parameter exactly at that position\")",
    ),
    (
        "sig_exp_pos_only_allow_kw",
        "                    if a.n[p3 + {{O:Param.pos_only}}] != 0 and sref_eq_ref(a, pk(a.n[p3 + {{O:Param.name}}], a.n[p3 + {{O:Param.name}} + 1]), kn):\n                        mp(ck, \"'\")",
        "                    if False:\n                        mp(ck, \"'\")",
    ),
    (
        "sig_exp_unknown_kw_allow",
        "            if found < 0:\n                mp(ck, \"function '\")\n                mp_sym(ck, nm_sym)\n                mp(ck, \"' has no parameter named '\")",
        "            if False:\n                mp(ck, \"function '\")\n                mp_sym(ck, nm_sym)\n                mp(ck, \"' has no parameter named '\")",
    ),
    (
        "sig_exp_var_by_kw_allow",
        "            if variadic_idx >= 0 and found == variadic_idx:\n                mp(ck, \"'\")\n                mp_sym(ck, nm_sym)\n                mp(ck, \"': the '*\")",
        "            if False:\n                mp(ck, \"'\")\n                mp_sym(ck, nm_sym)\n                mp(ck, \"': the '*\")",
    ),
    (
        "sig_exp_dup_kw_allow",
        "            if slots[found] >= 0:\n                mp(ck, \"in the call to '\")\n                mp_sym(ck, nm_sym)\n                mp(ck, \"', parameter '\")",
        "            if False:\n                mp(ck, \"in the call to '\")\n                mp_sym(ck, nm_sym)\n                mp(ck, \"', parameter '\")",
    ),
    (
        "sig_exp_too_many_pos_allow",
        "            if variadic_idx < 0:\n                mp(ck, \"'\")\n                mp_sym(ck, nm_sym)\n                mp(ck, \"' takes at most \")",
        "            if False:\n                mp(ck, \"'\")\n                mp_sym(ck, nm_sym)\n                mp(ck, \"' takes at most \")",
    ),
    (
        "sig_exp_ambig_var_allow",
        "    if ambiguous and (variadic_idx >= 0 or kw_idx >= 0):",
        "    if False:",
    ),
    (
        "sig_exp_ambig_spawn_allow",
        "    if ambiguous and ck.in_spawn_op:",
        "    if False:",
    ),
    (
        "sig_exp_missing_allow",
        "            if d6 < 0:\n                mp(ck, \"in the call to '\")\n                mp_sym(ck, nm_sym)\n                mp(ck, \"', argument '\")",
        "            if False:\n                mp(ck, \"in the call to '\")\n                mp_sym(ck, nm_sym)\n                mp(ck, \"', argument '\")",
    ),
    # 4. check_args_slice & check_spawn & register_func & register_class_sigs & instantiate_generic_func
    (
        "sig_slice_ext_kw_allow",
        "        if decl < 0:\n            mp(ck, \"'\")\n            mp_sym(ck, nm)\n            mp(ck, \"' does not support keyword arguments/default values\")",
        "        if False:\n            mp(ck, \"'\")\n            mp_sym(ck, nm)\n            mp(ck, \"' does not support keyword arguments/default values\")",
    ),
    (
        "sig_spawn_flag_skip",
        "    ck.in_spawn_op = True\n    try:\n        check_args_sig(ck, a, fx, c, sid, sym)",
        "    ck.in_spawn_op = False\n    try:\n        check_args_sig(ck, a, fx, c, sid, sym)",
    ),
    (
        "sig_reg_func_val_skip",
        "    validate_param_defaults(ck, a, nm, ps, 0, pky(sl_at(a, fd, {{O:FuncDef.type_params}})) > 0)",
        "    if False:\n        validate_param_defaults(ck, a, nm, ps, 0, pky(sl_at(a, fd, {{O:FuncDef.type_params}})) > 0)",
    ),
    (
        "sig_reg_cls_val_skip",
        "        validate_param_defaults(ck, a, mname, ps, 1, False)",
        "        if False:\n            validate_param_defaults(ck, a, mname, ps, 1, False)",
    ),
    (
        "sig_gfn_exp_skip",
        "    if has_kw or na < np or any_variadic(a, ps):\n        args = expand_call_args(ck, a, ps, args, fn_sym)",
        "    if False:\n        args = expand_call_args(ck, a, ps, args, fn_sym)",
    ),
]
