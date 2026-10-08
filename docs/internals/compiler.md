# The compiler front end

## Lexing

`compiler/lexer/lexer.zig` turns source text into tokens, including explicit `INDENT`/`DEDENT` tokens. A second entry point (`tokenizeWithTrivia`) additionally records comments and blank lines so the formatter
can put them back. The lexer rejects tabs in indentation, non-ASCII identifiers and malformed literals with a position; `compiler/syntax_report.zig` renders errors as `file:line:column` plus the source line and a caret.

## Parsing

`compiler/parser/parser.zig` is a hand-written recursive-descent / precedence parser producing the AST defined in `ast.zig`. Notable points:

- Expression nesting is bounded (200 levels) so adversarial input cannot overflow the stack; the fuzz tests lex/parse/check random input.
- The parser performs **desugaring** that needs no type information: f-strings and `str.format` become concatenations of `str(...)` and format calls; tuple unpacking becomes declarations and indexing; the
  generator-expression form is marked for the checker; `set` literals and comprehensions map to the prelude's set class; augmented assignment keeps its own node.
- Nodes keep enough information (`Binary.is_form`, `fstring` markers, `ListComp.is_genexpr`) for the formatter to print the sugar back as written.
- Decorators are parsed on functions, methods, classes and `extern def`, with dotted names.

Adding a language feature starts here: grammar and AST first, then the checker rule, the ownership effect, both back ends, a golden test and the spec text — in that order.

## Module loading

`compiler/module_loader.zig` resolves imports: the standard library (`nox.*`), project files (relative to the directory with `nox.json`), and dependencies (by alias). It **merges every module into one program**, renaming top-level
names per module (`mangled` symbols) so the later stages see a single flat module; imports come first, which is why imported modules' top-level statements run before the importer's. The prelude (`stdlib/nox/core.nox`) is
merged into every program. Cyclic imports are rejected. Any new field added to an AST node that is copied during renaming (decorators, defaults, docstrings) must be carried through the loader's rename functions — forgetting this is a recurring
class of bug.

## The project layer

`compiler/project.zig` finds the project root (`nox.json`), loads the manifest and lock file, and locates the runtime object and standard library relative to the executable. `compiler/pkg/` implements fetching (Git), the
package index, global installs, cache pruning and self-upgrade.

## Diagnostics

Type errors carry the statement line and span; the language server reuses the same front end, so the CLI and editors agree. Error *kinds* (`TypeMismatch`, `UndefinedFunction`, …) are stable identifiers; message texts
are currently Turkish and are not part of any compatibility promise.
