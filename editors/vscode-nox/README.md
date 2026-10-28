# Nox for Visual Studio Code

Syntax highlighting and a language-server client for [Nox](https://noxlang.com), a statically typed language with Python's syntax that compiles ahead of time to native code.

Highlighting works on its own. Diagnostics, completion, hover, go to definition and formatting come from `noxlsp`, which ships in the Nox release archive next to `noxc`. This extension does not embed the compiler or the language server.

## Features

- TextMate grammar for `.nox` files
- Diagnostics from the same front end as `noxc check`, with the same spans
- Completion for names in scope, standard-library modules and their members
- Hover shows the type of the symbol under the cursor
- Go to definition within the same file
- Document formatting through the standard formatter (`noxc fmt` and Format Document produce the same bytes)

Cross-file go to definition, rename and semantic tokens are not implemented. See the [language server notes](https://github.com/mburakmmm/nox-lang/blob/main/docs/tools/lsp.md).

## Requirements

Install Nox so `noxlsp` is on your `PATH`.

macOS and Linux:

```sh
curl -fsSL https://noxlang.com/install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://noxlang.com/install.ps1 | iex
```

Confirm with `noxlsp` (it waits for Language Server Protocol messages on stdin; Ctrl-C exits) or `noxc --version`. If the binary lives somewhere else, set **Nox: Language Server Path** (`nox.languageServerPath`) to its full path.

Opening a `.nox` file starts the server. If the executable cannot be found, the editor reports that and highlighting still works.

## Formatting and indentation

The formatter indents with four spaces. This extension sets that as the default for Nox and registers itself as the default formatter. Format Document uses it. Turn on **Editor: Format On Save** if you want the same result on every save.

## Debugging

There is no Nox debug adapter. `noxc build -g` emits DWARF line tables (the QBE backend; `-g` selects it automatically) and any DWARF client can read them. [CodeLLDB](https://marketplace.visualstudio.com/items?itemName=vadimcn.vscode-lldb) is the one used here because it ships the same way on macOS, Linux and Windows.

`.vscode/tasks.json`:

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "noxc: build -g",
      "type": "shell",
      "command": "noxc",
      "args": ["build", "-g", "${file}"],
      "group": { "kind": "build", "isDefault": true },
      "problemMatcher": []
    }
  ]
}
```

`.vscode/launch.json`:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Nox: build and debug this file",
      "type": "lldb",
      "request": "launch",
      "program": "${workspaceFolder}/${fileBasenameNoExtension}",
      "args": [],
      "cwd": "${workspaceFolder}",
      "preLaunchTask": "noxc: build -g",
      "sourceLanguages": ["nox"]
    }
  ]
}
```

Limits, from the [debugging guide](https://github.com/mburakmmm/nox-lang/blob/main/docs/tools/debugging.md):

- Breakpoints and stepping work on Linux. On macOS the linker drops the debug map, so the debugger does not verify breakpoints.
- Locals are not inspectable. The Variables pane stays empty; only line-level control is available.
- `--backend llvm -g` is an error. Plain `noxc build -g` is the right command.

## Development

From a checkout of this directory:

```sh
npm install
npm run compile
npx @vscode/vsce package
```

Press F5 in this folder to launch an Extension Development Host. `npx @vscode/vsce package` writes `noxlang-<version>.vsix`.

## License

MIT. See [LICENSE](LICENSE).
