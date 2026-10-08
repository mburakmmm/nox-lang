# The language server (noxlsp)

`noxlsp` is a [Language Server Protocol](https://microsoft.github.io/language-server-protocol/) server for Nox that speaks JSON-RPC over standard input/output. It ships in the release archive next to `noxc`.

## Capabilities

| LSP feature | What you get |
|---|---|
| `textDocument/publishDiagnostics` | syntax and type errors with exact spans, as you type |
| `textDocument/completion` | names in scope, standard-library modules and members |
| `textDocument/hover` | the type of the symbol under the cursor |
| `textDocument/definition` | go to definition (within the same file) |
| `textDocument/formatting` | the standard formatter ([Formatter](formatter.md)) |

Diagnostics come from the same front end as `noxc check`, so editor and command line always agree. Cross-file go-to-definition, rename and semantic tokens are not implemented.

## Using it

Any LSP client works: configure it to run `noxlsp` for `*.nox` files. The VS Code extension does this for you ([Editors](../install/editors.md)); set `nox.languageServerPath` if `noxlsp` is not on `PATH`.

```sh
noxlsp     # reads LSP messages on stdin, writes responses on stdout
```
