# Editor support

## Visual Studio Code

The `vscode-nox` extension (in the repository's `editors/vscode-nox`) provides:

- syntax highlighting (TextMate grammar), including `nox` fences in Markdown;
- a file icon for `.nox` in icon themes that show language icons (the default Seti theme does; Minimal and None do not);
- indentation folding, Enter-to-indent after `:`, and snippets (`def`, `class`, `for`, `while`, `if`, `try`, `protocol`);
- the language server: diagnostics, completion, hover, go to definition (including imports), references, rename, outline, signature help, semantic tokens, parameter-name hints and formatting ([language server](../tools/lsp.md));
- a Testing view for `*_test.nox` files (`noxc test`) and a **Run test** CodeLens on `def test_`;
- command-palette actions **Nox: Run File**, **Nox: Check File** and **Nox: Test** (`noxc` in an integrated terminal);
- debugging through CodeLLDB using `noxc build -g` ([Debugging](../tools/debugging.md)). **Nox: Debug File** adds the launch configuration; install CodeLLDB first.

Build and try it from a checkout:

```sh
cd editors/vscode-nox
npm install
npm run compile
# open this folder in VS Code and press F5 to launch an Extension Development Host
npx @vscode/vsce package
```

`vsce package` writes `noxlang-<version>.vsix` in this directory. Install it with **Extensions: Install from VSIX...**, or upload that file on the [Marketplace management page](https://marketplace.visualstudio.com/manage) under the publisher `nox-lang` (the `publisher` field in `package.json` must match). The language client is bundled into the package. `noxlsp` is not: the extension looks on `PATH`, then in `~/.nox-lang/bin` (`%USERPROFILE%\.nox-lang\bin` on Windows). Set **`nox.languageServerPath`** to skip that search. If the binary is missing, the error offers a link to the install page.

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
