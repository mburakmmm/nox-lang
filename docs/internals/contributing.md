# Contributing

Nox is open source (MIT). This page summarises how to work on the compiler and runtime; the binding rules are in `AGENTS.md` in the repository, which applies equally to human and AI contributors.

## Getting set up

```sh
git clone https://github.com/mburakmmm/nox-lang
cd nox-lang
zig build                  # needs Zig 0.16; builds noxc, noxlsp, the runtime, installs the stdlib into zig-out/
zig-out/bin/noxc run examples/...      # try it
zig build test --summary all           # the full suite
```

Rebuild with `zig build` after editing `stdlib/**` — `zig-out/bin/noxc` uses the installed copy of the standard library. You also need `qbe` (for the QBE back end) and `clang` or `zig` (for LLVM).

## The workflow for a language change

In this order, no skipping:

1. grammar — parser and AST;
2. the type-checker rule;
3. the ownership effect (does the new node create a scope or a lifetime boundary?);
4. IR lowering — **for both back ends**;
5. at least one golden test;
6. the documentation page, and the design-history section if behaviour deviates from the specification.

Golden tests are non-negotiable (invariant 7); a change to code generation is not merged without one.

## Rules of the road

- **The seven invariants** ([Architecture](architecture.md#the-seven-non-negotiable-invariants)) are never traded away for convenience. If a task cannot be done without breaking one, stop and discuss it.
- **Ask before architecture.** New language features, memory-model behaviour and ABI changes are proposed first, summarised, and agreed before implementation. Small reversible decisions need no ceremony.
- **Zig style.** `zig fmt` before every commit; allocators are explicit parameters; errors use `!T` with per-module error sets; every public function has a test; memory tests run under the debug allocator.
- **Native boundaries.** Anything that touches C/WASM/HPy needs an integration test with a real extension.
- **No tricks for green.** Do not skip, loosen or delete a test to make a change pass; fix the cause.

## Pull requests

State which area the change touches, confirm the definition of done (suite green, golden test added, spec/docs updated), and write explicitly that no invariant is violated. Read the test output before you commit —
a red suite is a reason to stop, not to push.

## Every commit is a release

The project releases on every commit: `build.zig.zon` is bumped, `CHANGELOG.md` gets an entry, the commit is tagged `vX.Y.Z` and pushed together with the tag. Maintainers handle tagging; see [Releasing](releasing.md) for what the
release machinery checks.

## Documentation

These docs live in `docs/` as Markdown. Add the page to `docs/_toc.yml`, put runnable examples in `nox` blocks (add an `output` block to assert the output; use `nox-fragment` for snippets that cannot run standalone) and run
`python3 scripts/check_docs.py` before sending the change. The check also verifies links, the table of contents and that every public standard-library name is documented.
