"""Aşama 3 kapanış (lazy Map2, check_nested_def cap_id, set() expected, nested import/from_import) mutation suite.

Each tuple: (name, old_unique_line, new_line) in selfhost/typecheck.nox.in.
"""

MUTANTS = [
    (
        "a3_map2_find_no_empty_guard",
        "def m2_find(m: Map2, k1: int, k2: int) -> int:\n    if m.mask == 0:\n        return -1",
        "def m2_find(m: Map2, k1: int, k2: int) -> int:\n    if False:\n        return -1",
    ),
    (
        "a3_nested_def_cap_id_skip_after",
        "    check_block(ck, a, ifx, body)\n    ck.last_nested_cap_id = cap_id",
        "    check_block(ck, a, ifx, body)\n    pass",
    ),
    (
        "a3_set_expected_skip",
        '        if a.n[acal] == {{T:Expr.identifier}} and sref_eq(a, pk(a.n[acal + 1], a.n[acal + 2]), "set") and pky(sl_at(a, ac, {{O:Call.args}})) == 0 and m2_get(ck.fmap, 0, sym_of(ck, a, pk(a.n[acal + 1], a.n[acal + 2]))) < 0:',
        "        if False:",
    ),
    (
        "a3_set_shadow_ignore",
        '        if a.n[acal] == {{T:Expr.identifier}} and sref_eq(a, pk(a.n[acal + 1], a.n[acal + 2]), "set") and pky(sl_at(a, ac, {{O:Call.args}})) == 0 and m2_get(ck.fmap, 0, sym_of(ck, a, pk(a.n[acal + 1], a.n[acal + 2]))) < 0:',
        '        if a.n[acal] == {{T:Expr.identifier}} and sref_eq(a, pk(a.n[acal + 1], a.n[acal + 2]), "set") and pky(sl_at(a, ac, {{O:Call.args}})) == 0:',
    ),
    (
        "a3_stmt_import_allow",
        '    if tag == {{T:StmtKind.import_stmt}}:\n        fail2(ck, "TypeMismatch", "\'import\' is only allowed at module level")',
        "    if tag == {{T:StmtKind.import_stmt}}:\n        return",
    ),
    (
        "a3_stmt_from_import_allow",
        '    if tag == {{T:StmtKind.from_import_stmt}}:\n        fail2(ck, "TypeMismatch", "\'from ... import\' is only allowed at module level")',
        "    if tag == {{T:StmtKind.from_import_stmt}}:\n        return",
    ),
]
