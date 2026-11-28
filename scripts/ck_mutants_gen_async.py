"""generator_desugar_run, __nox_cell_of/__nox_get/__nox_for_iter, check_lazy_for, async_for, check_async_with, hoist_nested_async mutation suite.

Each tuple: (name, old_unique_line, new_line) in selfhost/typecheck.nox.in.
"""

MUTANTS = [
    # ---- generator_desugar_run ----
    (
        "ga_run_skip",
        "        generator_desugar_run(ck, a, body)",
        "        pass",
    ),
    (
        "ga_bad_ret_ann_allow",
        '    if not is_gens and not is_gen:\n        gd_fail(g, ck, "a function containing \'yield\' must be annotated \'-> Iterator[T]\' (or Generator[T], or Generator[Y, S] to receive values with send())")',
        '    if False:\n        gd_fail(g, ck, "a function containing \'yield\' must be annotated \'-> Iterator[T]\' (or Generator[T], or Generator[Y, S] to receive values with send())")',
    ),
    (
        "ga_send_without_gens_allow",
        '    if g.uses_send and not is_gens:\n        g.line = g.send_line\n        gd_fail(g, ck, "\'x = yield value\' receives sent values: annotate the function \'-> Generator[Y, S]\' (S is the type of the values passed to send())")',
        "    if False:\n        pass",
    ),
    (
        "ga_opt_yield_allow",
        '    if a.n[g.ytype] == {{T:TypeExpr.optional}}:\n        gd_fail(g, ck, "a generator cannot yield an optional type (\'T | None\'); yield the plain type")',
        '    if False:\n        gd_fail(g, ck, "a generator cannot yield an optional type (\'T | None\'); yield the plain type")',
    ),
    (
        "ga_lowlevel_yield_allow",
        '        elif tag == {{T:StmtKind.lowlevel_stmt}}:\n            if gd_stmt_has_yield(a, st):\n                gd_fail(g, ck, "\'yield\' inside \'lowlevel\' is not supported in a generator")',
        "        elif tag == {{T:StmtKind.lowlevel_stmt}}:\n            pass",
    ),
    (
        "ga_return_val_allow",
        '        if top:\n            if pay >= 0:\n                gd_fail(g, ck, "a generator (\'yield\') cannot \'return\' a value")',
        "        if top:\n            pass",
    ),
    (
        "ga_fin_yield_jump_allow",
        '        if jumps or gd_has_escaping_jump(a, fb_sl, 0):\n            gd_fail(g, ck, "\'return\', \'break\' or \'continue\' that leaves a \'try\' whose \'finally\' contains \'yield\' is not supported in a generator (the \'finally\' would be skipped)")',
        "        if False:\n            pass",
    ),
    (
        "ga_yield_from_skip",
        '        if yk == 2:\n            g.uid = g.uid + 1',
        '        if False:\n            g.uid = g.uid + 1',
    ),
    (
        "ga_fnbox_unwrap_skip",
        '            if len(tstr_f) >= 13 and tstr_f[:13] == "__nox_FnBox__":',
        "            if False:",
    ),
    # ---- __nox_cell_of / __nox_get / __nox_for_iter ----
    (
        "ga_cell_of_opt_allow",
        '        if itg == 15 or itg == 4:\n            fail2(ck, "TypeMismatch", "a generator variable cannot have an optional or None type here; give it a plain type")',
        '        if False:\n            fail2(ck, "TypeMismatch", "a generator variable cannot have an optional or None type here; give it a plain type")',
    ),
    (
        "ga_get_call_skip",
        '        if a.n[ical] == {{T:Expr.identifier}} and sref_eq(a, pk(a.n[ical + 1], a.n[ical + 2]), "__nox_get") and pky(iargs) == 1:',
        "        if False:",
    ),
    # ---- async_for & async_with ----
    (
        "ga_async_for_sync_ctx_allow",
        '        if is_af and not fx.in_async:\n            fail2(ck, "TypeMismatch", "\'async for\' can only be used inside an \'async def\' body or at the top level")',
        '        if False:\n            fail2(ck, "TypeMismatch", "\'async for\' can only be used inside an \'async def\' body or at the top level")',
    ),
    (
        "ga_async_for_non_lazy_allow",
        '        if is_af and ck.lazy_for_iter < 0:\n            fail2(ck, "TypeMismatch", "\'async for\' needs an async iterator (an \'AsyncIterator[T]\' returned by an async generator)")',
        '        if False:\n            fail2(ck, "TypeMismatch", "\'async for\' needs an async iterator (an \'AsyncIterator[T]\' returned by an async generator)")',
    ),
    (
        "ga_async_with_sync_ctx_allow",
        'def check_async_with(ck: Ck, a: Ast, fx: Fx, w: int) -> None:\n    if not fx.in_async:\n        fail2(ck, "TypeMismatch", "\'async with\' can only be used inside an \'async def\' body or at the top level")',
        "def check_async_with(ck: Ck, a: Ast, fx: Fx, w: int) -> None:\n    if False:\n        pass",
    ),
    # ---- hoist_nested_async ----
    (
        "ga_cleanup_gens_skip",
        "            m2_put(ck.cleanup_gens, 0, sym_lit(ck, key_s), 1)",
        "            pass",
    ),
    (
        "ga_nested_async_bad_cap_allow",
        '        if tg != 0 and tg != 1 and tg != 2 and tg != 3 and tg != 4 and tg != 16:\n            mp(ck, "the nested \'async def\' ")',
        '        if False:\n            mp(ck, "the nested \'async def\' ")',
    ),
    (
        "ga_nested_async_direct_call_allow",
        '    if m2_get(fx.async_locals, 0, csym_al) >= 0 and sc_lookup(ck, fx.scope, csym_al) < 0:\n        mp(ck, "\'")',
        '    if False:\n        mp(ck, "\'")',
    ),
    (
        "ga_nested_async_spawn_rewrite_skip",
        "    ale: int = m2_get(fx.async_locals, 0, sym)\n    if ale >= 0:",
        "    ale: int = -1\n    if ale >= 0:",
    ),
]
