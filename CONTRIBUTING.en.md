# Contributing to Nox

*[Türkçe](CONTRIBUTING.md) | English*

Nox is an actively developed language project. This document summarizes
the rules and discipline you should know before submitting a change.

## Getting Started

```sh
git clone https://github.com/mburakmmm/nox-lang.git
cd nox-lang
zig build test    # everything should start green
```

Requirements: [Zig 0.16](https://ziglang.org/download/) (see
`minimum_zig_version` in `build.zig.zon`) and
[QBE](https://c9x.me/compile/) (`brew install qbe`).

## Required Reading

Before starting any change:

1. **[`AGENTS.md`](AGENTS.md)** — the architectural invariants (§2), Zig
   coding standards (§6), compiler development rules (§7), and the
   **"Definition of Done" checklist in §13** (mandatory for every task).
   Written in Turkish; if you don't read Turkish, machine-translate it —
   these rules govern every PR regardless of the language it's written
   in.
2. **[`nox-teknik-spesifikasyon.md`](nox-teknik-spesifikasyon.md)** — the
   language's complete design history and rationale, in numbered sections
   (`§3.x`). Written in Turkish, as an ongoing engineering log across
   every development phase. If you're adding a new language
   feature/compiler behavior, you're expected to append a new numbered
   subsection here — in Turkish, to match the existing document's
   language and phase-numbering convention (`Faz XX.Y`). For an
   English-language reference to the language itself (not the phase
   history), see [`docs/LANGUAGE.md`](docs/LANGUAGE.md).
3. **[`docs/uretim-hazirlik-analizi.md`](docs/uretim-hazirlik-analizi.md)**
   — production-readiness gaps and the post-MVP roadmap (Faz Q-Z). If
   you're considering a large contribution, check here first for whether
   it's already planned.

## Change Discipline (summarized from AGENTS.md §7/§13)

- **Every behavioral change ships with at least one golden test**
  (`tests/golden/`, `tests/unit/`, or `tests/compat/` — whichever fits).
  The "deliberately break → confirm red → fix" ritual is expected: to
  prove a new test genuinely exercises that behavior, first deliberately
  break the test/code and see it fail red, then fix it.
- **`zig build test` must be green in BOTH Debug AND
  `-Doptimize=ReleaseFast`** — CI (`.github/workflows/ci.yml`) runs both.
- **For memory-management-related changes**: a leak test + a double-free
  test, green under `DebugAllocator`'s own safety mode.
- **No Invariant Principle (`AGENTS.md` §2) may be violated** — in
  particular: no explicit ownership syntax is ever exposed to the user,
  mandatory static typing, the whole-program (single compilation unit)
  model.
- **Must be formatted with `zig fmt`** (on changed files).
- When writing comments: explain only WHY the code is the way it is (a
  hidden constraint, a subtle invariant, the fix for a specific bug) —
  not WHAT it does (good naming already conveys that).

## Before Submitting a PR

Run the checklist in `AGENTS.md` §14 (Definition of Done + Invariant
Principles + spec consistency) against your own change. In your PR
description, explicitly state which sections your change affects and
that no invariant principle was violated.

## Questions / Ambiguity

Follow the "Decision Procedure Under Ambiguity" in `AGENTS.md` §16 —
prefer the narrowest-scoped solution that largely preserves backward
compatibility; if unsure, open an issue and discuss.
