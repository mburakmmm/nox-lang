# The language server (noxlsp)

`noxlsp` is a [Language Server Protocol](https://microsoft.github.io/language-server-protocol/) server for Nox that speaks JSON-RPC over standard input/output. It ships in the release archive next to `noxc`.

## Capabilities

| LSP feature | What you get |
|---|---|
| `textDocument/publishDiagnostics` | syntax and type errors with exact spans, as you type |
| `textDocument/completion` | names in scope, standard-library modules and members |
| `textDocument/hover` | the type of the symbol under the cursor |
| `textDocument/definition` | go to a definition in this file, or in the file an `import` / `from` names |
| `textDocument/references` | uses of the same binding; the innermost scope wins |
| `textDocument/rename` | a workspace edit for that binding (the server does not write files itself) |
| `textDocument/documentSymbol` | outline of top-level functions, classes and methods |
| `textDocument/signatureHelp` | the parameter list of the call under the cursor |
| `textDocument/semanticTokens/full` | identifier kinds (function, class, parameter, variable); keywords and strings stay with the TextMate grammar |
| `textDocument/inlayHint` | parameter names at call sites; types already written in the source are not repeated |
| `textDocument/codeAction` | one fix: replace tab indentation with four spaces |
| `textDocument/formatting` | the standard formatter ([Formatter](formatter.md)) |

Diagnostics come from the same front end as `noxc check`, so editor and command line always agree. Cross-file navigation opens the target file on its own; the compiler's merged module is not used, because that merge shifts spans away from the bytes in the editor.

## Using it

Any LSP client works: configure it to run `noxlsp` for `*.nox` files. The VS Code extension does this for you ([Editors](../install/editors.md)); set `nox.languageServerPath` if `noxlsp` is not on `PATH`.

```sh
noxlsp     # reads LSP messages on stdin, writes responses on stdout
```
