// Nox VS Code eklentisi — sözdizimi vurgulama, noxlsp istemcisi,
// noxc komutları ve CodeLLDB hata ayıklama şablonu.

import { execFile } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

const INSTALL_URL = "https://noxlang.com";
const CODELLDB_ID = "vadimcn.vscode-lldb";
const CODELLDB_URL =
  "https://marketplace.visualstudio.com/items?itemName=vadimcn.vscode-lldb";

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.commands.registerCommand("nox.runFile", () => runNoxc(["run"])),
    vscode.commands.registerCommand("nox.checkFile", () => runNoxc(["check"])),
    vscode.commands.registerCommand("nox.test", () => runTest()),
    vscode.commands.registerCommand("nox.runTestFile", (uri: vscode.Uri) => {
      sendToTerminal(["test", uri.fsPath], path.dirname(uri.fsPath));
    }),
    vscode.commands.registerCommand("nox.openInstall", () => openExternal(INSTALL_URL)),
    vscode.commands.registerCommand("nox.debugFile", () => startDebug()),
    vscode.debug.registerDebugConfigurationProvider("lldb", new NoxDebugProvider()),
    vscode.tasks.registerTaskProvider("nox", new NoxTaskProvider()),
    vscode.languages.registerCodeLensProvider({ language: "nox", scheme: "file" }, new NoxTestCodeLens()),
  );
  registerTestController(context);

  const serverPath = resolveLanguageServer();
  if (!serverPath) {
    void vscode.window
      .showErrorMessage(
        "Nox: noxlsp bulunamadı. Vurgulama çalışır; tanılama ve gezinme için Nox kurulu olmalı ve noxlsp PATH'te ya da ~/.nox-lang/bin altında olmalıdır.",
        "Kurulumu aç",
      )
      .then((choice) => {
        if (choice === "Kurulumu aç") void openExternal(INSTALL_URL);
      });
    return;
  }

  const serverOptions: ServerOptions = {
    command: serverPath,
    transport: TransportKind.stdio,
  };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "nox" }],
  };
  client = new LanguageClient("nox", "Nox Language Server", serverOptions, clientOptions);
  client.start().catch((err: unknown) => {
    const message = err instanceof Error ? err.message : String(err);
    void vscode.window
      .showErrorMessage(`Nox dil sunucusu başlatılamadı: ${message}`, "Kurulumu aç")
      .then((choice) => {
        if (choice === "Kurulumu aç") void openExternal(INSTALL_URL);
      });
  });
  context.subscriptions.push({
    dispose: () => {
      void client?.stop();
    },
  });
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}

function resolveLanguageServer(): string | undefined {
  const configured = vscode.workspace.getConfiguration("nox").get<string>("languageServerPath", "noxlsp");
  if (configured && configured !== "noxlsp") {
    return configured;
  }
  const onPath = findOnPath(process.platform === "win32" ? "noxlsp.exe" : "noxlsp");
  if (onPath) return onPath;
  const installed = defaultInstallBinary();
  if (isFile(installed)) return installed;
  return undefined;
}

function defaultInstallBinary(): string {
  const name = process.platform === "win32" ? "noxlsp.exe" : "noxlsp";
  return path.join(os.homedir(), ".nox-lang", "bin", name);
}

function findOnPath(fileName: string): string | undefined {
  const entries = (process.env.PATH ?? "").split(path.delimiter);
  for (const dir of entries) {
    if (!dir) continue;
    const candidate = path.join(dir, fileName);
    if (isFile(candidate)) return candidate;
  }
  return undefined;
}

function isFile(filePath: string): boolean {
  try {
    return fs.statSync(filePath).isFile();
  } catch {
    return false;
  }
}

function activeNoxFile(): vscode.TextDocument | undefined {
  const doc = vscode.window.activeTextEditor?.document;
  if (!doc || doc.languageId !== "nox") return undefined;
  return doc;
}

function runNoxc(prefix: string[]): void {
  const doc = activeNoxFile();
  if (!doc) {
    void vscode.window.showInformationMessage("Nox: önce bir .nox dosyası açın.");
    return;
  }
  const folder = vscode.workspace.getWorkspaceFolder(doc.uri);
  sendToTerminal([...prefix, doc.uri.fsPath], folder?.uri.fsPath);
}

function runTest(): void {
  const doc = vscode.window.activeTextEditor?.document;
  const folder = doc ? vscode.workspace.getWorkspaceFolder(doc.uri) : vscode.workspace.workspaceFolders?.[0];
  const cwd = folder?.uri.fsPath ?? vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  if (doc && doc.languageId === "nox" && doc.uri.fsPath.endsWith("_test.nox")) {
    sendToTerminal(["test", doc.uri.fsPath], cwd);
    return;
  }
  sendToTerminal(["test"], cwd);
}

function sendToTerminal(args: string[], cwd: string | undefined): void {
  const existing = vscode.window.terminals.find((t) => t.name === "Nox");
  const term = existing ?? vscode.window.createTerminal({ name: "Nox", cwd });
  term.show();
  const quoted = ["noxc", ...args].map(shellQuote).join(" ");
  term.sendText(quoted);
}

function shellQuote(value: string): string {
  if (process.platform === "win32") {
    return `'${value.replace(/'/g, "''")}'`;
  }
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function openExternal(url: string): Thenable<boolean> {
  return vscode.env.openExternal(vscode.Uri.parse(url));
}

async function startDebug(): Promise<void> {
  if (!vscode.extensions.getExtension(CODELLDB_ID)) {
    const choice = await vscode.window.showErrorMessage(
      "Nox hata ayıklama CodeLLDB ister. noxc build -g satır tablosu üretir; bağdaştırıcı CodeLLDB'dir.",
      "CodeLLDB sayfasını aç",
    );
    if (choice) await openExternal(CODELLDB_URL);
    return;
  }
  const doc = activeNoxFile();
  if (!doc) {
    void vscode.window.showInformationMessage("Nox: önce bir .nox dosyası açın.");
    return;
  }
  const folder = vscode.workspace.getWorkspaceFolder(doc.uri);
  await vscode.debug.startDebugging(folder, noxDebugConfig(doc));
}

function noxDebugConfig(doc: vscode.TextDocument): vscode.DebugConfiguration {
  const base = path.basename(doc.uri.fsPath, ".nox");
  const dir = path.dirname(doc.uri.fsPath);
  return {
    name: "Nox: build and debug this file",
    type: "lldb",
    request: "launch",
    program: path.join(dir, base),
    args: [],
    cwd: dir,
    preLaunchTask: "noxc: build -g",
    sourceLanguages: ["nox"],
  };
}

class NoxDebugProvider implements vscode.DebugConfigurationProvider {
  provideDebugConfigurations(
    folder: vscode.WorkspaceFolder | undefined,
  ): vscode.ProviderResult<vscode.DebugConfiguration[]> {
    const doc = activeNoxFile();
    if (!doc) return [];
    if (folder && vscode.workspace.getWorkspaceFolder(doc.uri)?.uri.fsPath !== folder.uri.fsPath) {
      return [];
    }
    return [noxDebugConfig(doc)];
  }

  resolveDebugConfiguration(
    _folder: vscode.WorkspaceFolder | undefined,
    config: vscode.DebugConfiguration,
  ): vscode.ProviderResult<vscode.DebugConfiguration> {
    if (config.type || config.request) return config;
    const doc = activeNoxFile();
    if (!doc) return config;
    if (!vscode.extensions.getExtension(CODELLDB_ID)) {
      void vscode.window
        .showErrorMessage("Nox hata ayıklama CodeLLDB ister.", "CodeLLDB sayfasını aç")
        .then((choice) => {
          if (choice) void openExternal(CODELLDB_URL);
        });
      return undefined;
    }
    return noxDebugConfig(doc);
  }
}

class NoxTaskProvider implements vscode.TaskProvider {
  provideTasks(): vscode.ProviderResult<vscode.Task[]> {
    const doc = activeNoxFile();
    if (!doc) return [];
    const execution = new vscode.ShellExecution("noxc", ["build", "-g", doc.uri.fsPath]);
    const task = new vscode.Task(
      { type: "nox", task: "build-g" },
      vscode.TaskScope.Workspace,
      "build -g",
      "noxc",
      execution,
    );
    task.group = vscode.TaskGroup.Build;
    return [task];
  }

  resolveTask(task: vscode.Task): vscode.ProviderResult<vscode.Task> {
    const doc = activeNoxFile();
    const file = doc?.uri.fsPath ?? "${file}";
    const execution = new vscode.ShellExecution("noxc", ["build", "-g", file]);
    return new vscode.Task(
      task.definition,
      vscode.TaskScope.Workspace,
      task.name,
      "noxc",
      execution,
    );
  }
}

interface NoxDocSymbol {
  name: string;
  kind: number;
  range: { start: { line: number; character: number }; end: { line: number; character: number } };
  children?: NoxDocSymbol[];
}

class NoxTestCodeLens implements vscode.CodeLensProvider {
  async provideCodeLenses(document: vscode.TextDocument): Promise<vscode.CodeLens[]> {
    if (!document.uri.fsPath.endsWith("_test.nox")) return [];
    const symbols = await testSymbols(document);
    const lenses: vscode.CodeLens[] = [];
    const walk = (items: NoxDocSymbol[]): void => {
      for (const item of items) {
        if ((item.kind === 12 || item.kind === 6) && item.name.startsWith("test_")) {
          const range = new vscode.Range(
            item.range.start.line,
            item.range.start.character,
            item.range.end.line,
            item.range.end.character,
          );
          lenses.push(
            new vscode.CodeLens(range, {
              title: "Run test",
              command: "nox.runTestFile",
              arguments: [document.uri],
            }),
          );
        }
        if (item.children) walk(item.children);
      }
    };
    walk(symbols);
    return lenses;
  }
}

async function testSymbols(document: vscode.TextDocument): Promise<NoxDocSymbol[]> {
  if (client) {
    try {
      const result = await client.sendRequest<NoxDocSymbol[] | null>("textDocument/documentSymbol", {
        textDocument: { uri: document.uri.toString() },
      });
      if (result && result.length > 0) return result;
    } catch {
      // Belge sembolü yoksa metindeki def satırına düşülür.
    }
  }
  const found: NoxDocSymbol[] = [];
  for (let line = 0; line < document.lineCount; line++) {
    const match = /^def (test_[A-Za-z0-9_]+)/.exec(document.lineAt(line).text);
    if (!match) continue;
    found.push({
      name: match[1],
      kind: 12,
      range: {
        start: { line, character: 0 },
        end: { line, character: match[0].length },
      },
    });
  }
  return found;
}

function registerTestController(context: vscode.ExtensionContext): void {
  const controller = vscode.tests.createTestController("nox", "Nox");
  context.subscriptions.push(controller);

  const discover = async (): Promise<void> => {
    controller.items.replace([]);
    const folders = vscode.workspace.workspaceFolders ?? [];
    for (const folder of folders) {
      const files = await vscode.workspace.findFiles(
        new vscode.RelativePattern(folder, "**/*_test.nox"),
        "**/{zig-out,zig-cache,.git,node_modules}/**",
      );
      for (const uri of files) {
        controller.items.add(controller.createTestItem(uri.toString(), path.basename(uri.fsPath), uri));
      }
    }
  };

  controller.resolveHandler = async (item) => {
    if (!item) await discover();
  };
  context.subscriptions.push(
    vscode.commands.registerCommand("nox.refreshTests", () => discover()),
  );

  controller.createRunProfile("Run", vscode.TestRunProfileKind.Run, async (request, token) => {
    const run = controller.createTestRun(request);
    const items: vscode.TestItem[] = [];
    if (request.include) {
      for (const item of request.include) items.push(item);
    } else {
      controller.items.forEach((item) => items.push(item));
    }
    for (const item of items) {
      if (token.isCancellationRequested) break;
      if (!item.uri) continue;
      run.started(item);
      const result = await execNoxcTest(item.uri.fsPath);
      if (result.code === 0) {
        run.passed(item);
      } else {
        run.failed(item, new vscode.TestMessage(result.output || "noxc test failed"));
      }
    }
    run.end();
  }, true);
}

function execNoxcTest(filePath: string): Promise<{ code: number; output: string }> {
  return new Promise((resolve) => {
    execFile(
      "noxc",
      ["test", filePath],
      { cwd: path.dirname(filePath) },
      (err, stdout, stderr) => {
        const output = `${stdout ?? ""}${stderr ?? ""}`;
        if (!err) {
          resolve({ code: 0, output });
          return;
        }
        const code = typeof err.code === "number" ? err.code : 1;
        resolve({ code, output });
      },
    );
  });
}
