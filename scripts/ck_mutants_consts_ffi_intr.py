"""class#consts, extern#decorators, and check_call#intrinsic mutation suite.

Each tuple: (name, old_unique_line, new_line) in selfhost/typecheck.nox.in.
"""

MUTANTS = [
    # ---- class#consts ----
    (
        "cfi_cls_const_nonlit_allow",
        "        if lit_t < 0:\n            mp(ck, \"class '\")",
        "        if False:\n            mp(ck, \"class '\")",
    ),
    (
        "cfi_cls_const_type_mismatch_allow",
        "        if not ty_assignable(ck.tt, k_decl, lit_t):\n            mp(ck, \"class '\")",
        "        if False:\n            mp(ck, \"class '\")",
    ),
    (
        "cfi_cls_const_non_scalar_allow",
        "        if k_decl != 0 and k_decl != 1 and k_decl != 2 and k_decl != 3:",
        "        if False:",
    ),
    (
        "cfi_cls_const_dup_allow",
        '        if same_k > 1:\n            mp(ck, "class \'")',
        '        if False:\n            mp(ck, "class \'")',
    ),
    (
        "cfi_cls_const_field_conflict_allow",
        "            if sref_eq_ref(a, fnm_k, knm):\n                mp(ck, \"class '\")",
        "            if False:\n                mp(ck, \"class '\")",
    ),
    (
        "cfi_cls_const_sub_assign_allow",
        "            if kown != osym:\n                mp(ck, \"'\")",
        "            if False:\n                mp(ck, \"'\")",
    ),
    (
        "cfi_cls_const_inst_assign_allow",
        '        ce_i: int = m2_get(ck.cls_consts_ty, ci, asym)\n        if ce_i >= 0:',
        '        ce_i: int = m2_get(ck.cls_consts_ty, ci, asym)\n        if False:',
    ),
    (
        "cfi_cls_const_nonconst_assign_allow",
        '        mp_sref(ck, a, attr)\n        mp(ck, "\' cannot be assigned: it is not a class attribute (class attributes are declared in the class body as \'NAME: T = literal\')")\n        raise mk_fail(ck, "TypeMismatch")',
        "        return",
    ),
    (
        "cfi_cls_const_read_skip",
        "    rc: int = receiver_class_name(ck, a, fx, obj)\n    if rc >= 0:",
        "    rc: int = -1\n    if rc >= 0:",
    ),
    # ---- extern#decorators ----
    (
        "cfi_ext_unknown_dec_allow",
        '            mp(ck, "\': unknown decorator \'@")\n            mp_sref(ck, a, dname)\n            mp(ck, "\' (only @ffi.escape/@ffi.noescape/@ffi.callback/@ffi.errors/@capability.requires are valid)")\n            raise mk_fail(ck, "UnknownExternDecorator")',
        "            pass",
    ),
    (
        "cfi_ext_escape_unknown_param_allow",
        "        if not found_e:\n            mp(ck, \"extern function '\")",
        "        if False:\n            mp(ck, \"extern function '\")",
    ),
    (
        "cfi_ext_escape_conflict_allow",
        "                if escape_syms[ei2] == nsym:\n                    mp(ck, \"extern function '\")",
        "                if False:\n                    mp(ck, \"extern function '\")",
    ),
    (
        "cfi_ext_err_combo_cb_allow",
        '        if sref_eq(a, pk(a.n[d2 + {{O:Decorator.name}}], a.n[d2 + {{O:Decorator.name}} + 1]), "ffi.callback"):\n            mp(ck, "extern function \'")',
        '        if False:\n            mp(ck, "extern function \'")',
    ),
    (
        "cfi_ext_err_bad_ret_allow",
        "    if not ret_ok:\n        mp(ck, \"extern function '\")",
        "    if False:\n        mp(ck, \"extern function '\")",
    ),
    (
        "cfi_ext_cb_ud_type_allow",
        "        if ck.tt.fp[ck.tt.xa[cb_ty] + ud_pos] != 5:\n            mp(ck, \"extern function '\")",
        "        if False:\n            mp(ck, \"extern function '\")",
    ),
    (
        "cfi_ext_cb_arity_allow",
        '    if ck.fpn[tsid] != exp_n2:\n        mp(ck, "\'")',
        '    if False:\n        mp(ck, "\'")',
    ),
    (
        "cfi_ext_cb_async_allow",
        '    if m2_get(ck.afn, 0, tsym) >= 0:\n        mp(ck, "\'")',
        '    if False:\n        mp(ck, "\'")',
    ),
    (
        "cfi_ext_cb_extern_allow",
        '    if m2_get(ck.ext_fns, 0, tsym) >= 0:\n        mp(ck, "\'")',
        '    if False:\n        mp(ck, "\'")',
    ),
    (
        "cfi_ext_cb_closure_allow",
        "    if a.n[ae] != {{T:Expr.identifier}}:\n        mp(ck, \"'\")",
        "    if False:\n        mp(ck, \"'\")",
    ),
    (
        "cfi_ext_cb_ctx_extra_arg_allow",
        '    if nargs != exp_arity:\n        mp(ck, "\'")',
        '    if False:\n        mp(ck, "\'")',
    ),
    # ---- check_call#intrinsic ----
    (
        "cfi_intr_http_mc_closure_allow",
        '    if not allow_closure:\n        mp(ck, "\'")',
        "    if False:\n        return",
    ),
    (
        "cfi_intr_http_mc_maxconn_nonlit_allow",
        "    if nargs == 4 and a.n[stmt_at(a, cargs, 3)] != {{T:Expr.int_lit}}:",
        "    if False:",
    ),
    (
        "cfi_intr_http_bad_port_allow",
        '        if check_expr(ck, a, fx, stmt_at(a, cargs, 0)) != 0:\n            mp(ck, "\'")',
        '        if False:\n            mp(ck, "\'")',
    ),
    (
        "cfi_intr_ws_bad_param_allow",
        '    if ck.tt.tag[p0] != 6 or ck.tt.xa[p0] != sym_lit(ck, "nox_websocket_WebSocketServerConn"):',
        "    if False:",
    ),
    (
        "cfi_intr_tls_bad_cert_allow",
        '        if check_expr(ck, a, fx, stmt_at(a, cargs, cert_idx)) != 3:',
        "        if False:",
    ),
    (
        "cfi_intr_thread_start_sync_allow",
        '    if m2_get(ck.afn, 0, esym) < 0:\n        mp(ck, "\'nox.thread.start\': \'entry\' (\'")',
        '    if False:\n        mp(ck, "\'nox.thread.start\': \'entry\' (\'")',
    ),
    (
        "cfi_intr_thread_pool_arity_allow",
        '    if ck.fpn[sid] != 0:\n        mp(ck, "\'nox.thread.pool_run\': \'entry\' must take ZERO parameters")',
        '    if False:\n        mp(ck, "\'nox.thread.pool_run\': \'entry\' must take ZERO parameters")',
    ),
]
