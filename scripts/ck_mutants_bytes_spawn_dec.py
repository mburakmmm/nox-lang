"""bytes (+ str#prelude), spawn#shared_arg, and top-level func decorator mutation suite.

27/27 yakalandı, 0 yaşayan.
Each tuple: (name, old_unique_line, new_line) in selfhost/typecheck.nox.in.
"""

MUTANTS = [
    # ---- bytes & str#prelude ----
    (
        "bsd_simple_bytes_unsup",
        '    if sref_eq(a, v, "bytes"):\n        return ty_mk(tt, 18, 0, 0)',
        '    if sref_eq(a, v, "bytes"):\n        raise unsup(ck, "type#bytes")',
    ),
    (
        "bsd_dict_key_no_bytes",
        "    return t == 0 or t == 2 or t == 3 or t == 1 or ck.tt.tag[t] == 18",
        "    return t == 0 or t == 2 or t == 3 or t == 1",
    ),
    (
        "bsd_slice_step_allow",
        '            fail2(ck, "TypeMismatch", "bytes slices do not support a step")',
        "            pass",
    ),
    (
        "bsd_slice_bound_allow",
        "        if blo >= 0:\n            if check_expr(ck, a, fx, blo) != 0:",
        "        if blo >= 0:\n            if False:",
    ),
    (
        "bsd_index_nonint_allow",
        '            fail2(ck, "TypeMismatch", "a bytes index must be an int")',
        "            pass",
    ),
    (
        "bsd_ord_no_bytes",
        "        if (l == 3 and r == 3) or (tt.tag[l] == 18 and tt.tag[r] == 18):",
        "        if l == 3 and r == 3:",
    ),
    (
        "bsd_in_str_allow",
        '                fail2(ck, "TypeMismatch", "only a bytes value or an int (0..255) can be searched for inside bytes with \'in\'")',
        "                pass",
    ),
    (
        "bsd_len_no_bytes",
        '        return check_expr(ck, a, fx, mk_ident_call(a, "__nox_bytes_len", [stmt_at(a, args, 0)]))',
        "        return 3",
    ),
    (
        "bsd_ctor_str_allow",
        '                fail2(ck, "TypeMismatch", "\'bytes\' cannot take a str: use s.encode()")',
        "                return 0",
    ),
    (
        "bsd_ctor_int_allow",
        '            fail2(ck, "TypeMismatch", "\'bytes\' takes a list[int]/list[u8] or a bytes value")',
        "            return ty_mk(tt, 18, 0, 0)",
    ),
    (
        "bsd_decode_enc_allow",
        '            fail2(ck, "TypeMismatch", "bytes.decode only supports the UTF-8 encoding")',
        "            pass",
    ),
    (
        "bsd_method_extra_arg_allow",
        '        mp(ck, " takes no arguments")',
        "        return 3",
    ),
    (
        "bsd_method_undef_allow",
        '        fail_attr(ck, a, attr, "UndefinedMethod", "bytes has no method \'", "\' (decode/hex/to_list)")',
        "        return 3",
    ),
    (
        "bsd_str_prelude_skip",
        '    if (m2_get(ck.fmap, 0, pre_sym) >= 0 or m2_get(ck.gfn, 0, pre_sym) >= 0) and core_has and (takes_extra or not is_core_str_method(a, attr)):',
        "    if False:",
    ),
    # ---- spawn#shared_arg / post-spawn caller mutation ----
    (
        "bsd_spawn_direct_mut_skip",
        "            if sf_is_resource_owned(sf, vsym):",
        "            if False:",
    ),
    (
        "bsd_spawn_method_mut_skip",
        "                if sf_is_resource_owned(sf, vsym2):",
        "                if False:",
    ),
    (
        "bsd_spawn_multi_owner_clear_all",
        "                    if len(rem) == 0:",
        "                    if True:",
    ),
    (
        "bsd_spawn_loop_lock_skip",
        "            lock_recurrent_loop_ownership(pre_loop, sf)",
        "            pass",
    ),
    (
        "bsd_spawn_rae_skip",
        "                    if len(collected) > 0:",
        "                    if False:",
    ),
    # ---- decorators / @capability.requires / __nox_reflect_* ----
    (
        "bsd_dec_arg_type_allow",
        '            mp(ck, " can only be a string/int/bool literal or a list of strings (target: ")',
        "            return",
    ),
    (
        "bsd_dec_list_item_allow",
        '                    mp(ck, ": a list can only contain string literals (target: ")',
        "                    return",
    ),
    (
        "bsd_cap_empty_allow",
        '        mp(ck, "\'@capability.requires\' expects at least one capability name (function: ")',
        "        return",
    ),
    (
        "bsd_cap_non_str_allow",
        '                    mp(ck, " of \'@capability.requires\' must be a string LITERAL (function: ")',
        "                    return",
    ),
    (
        "bsd_cap_unknown_allow",
        '            mp(ck, "\\")\': unknown capability name (function: ")',
        "            return",
    ),
    (
        "bsd_cap_arch_call_allow",
        "    if (mask & (1 << 8)) != 0:",
        "    if False:",
    ),
    (
        "bsd_reflect_arg_type_skip",
        '            mp(ck, "argument 2 (j) of \'")',
        "            return 3",
    ),
    (
        "bsd_reflect_meta_type_skip",
        "        for mi in range(n):\n            if check_expr(ck, a, fx, stmt_at(a, args, mi)) != 0:",
        "        for mi in range(n):\n            if False:",
    ),
]
