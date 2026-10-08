# Editor support

## Visual Studio Code

The `vscode-nox` extension (in the repository's `editors/vscode-nox`) provides:

- syntax highlighting (TextMate grammar);
- the language server: live diagnostics, completion, hover, go to definition and format-on-save ([language server](../tools/lsp.md));
- debugging through CodeLLDB using `noxc build -g` ([Debugging](../tools/debugging.md)).

Build and try it from a checkout:

```sh
cd editors/vscode-nox
npm install
npm run compile
# open the folder in VS Code and press F5 to launch an Extension Development Host
npx @vscode/vsce package          # produce a .vsix to install
```

The extension runs `noxlsp`, which must be on `PATH` (it is in the release archive); set **`nox.languageServerPath`** if it lives elsewhere.

## Any LSP-capable editor

Configure your editor's LSP client to launch `noxlsp` (stdio) for `*.nox` files — for example in Neovim with `vim.lsp.start({ name = "noxlsp", cmd = { "noxlsp" }, root_dir = vim.fn.getcwd() })` for the `nox` filetype,
or in Helix/Emacs/Sublime with their LSP configuration. You get the same diagnostics, completion, hover, definition and formatting.

## Tree-sitter

`editors/tree-sitter-nox` is a Tree-sitter grammar for Nox (highlighting, folding, structural selection). It covers nearly the whole syntax; the compiler's own parser remains the single source of truth.

```sh
cd editors/tree-sitter-nox
npm install
npm run generate     # grammar.js -> src/parser.c
npm test             # corpus tests
```

## Formatting

`noxc fmt file.nox` formats a file; editors get the same result through the language server ([Formatter](../tools/formatter.md)).
