// Nox VS Code eklentisi — sözdizimi vurgulama (bkz. syntaxes/nox.tmLanguage.json)
// + noxlsp'ye (bkz. ../../compiler/lsp_main.zig) konuşan bir LSP istemcisi.
// noxlsp ZATEN gerçek, standart JSON-RPC/Content-Length çerçevelemesi
// konuştuğundan (completion/definition/hover/diagnostics/formatting)
// vscode-languageclient'ın standart LanguageClient'ı SIFIR sunucu-tarafı
// değişiklik olmadan çalışır.

import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
  const config = vscode.workspace.getConfiguration("nox");
  const serverPath = config.get<string>("languageServerPath", "noxlsp");

  const serverOptions: ServerOptions = {
    command: serverPath,
    transport: TransportKind.stdio,
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "nox" }],
  };

  client = new LanguageClient(
    "nox",
    "Nox Language Server",
    serverOptions,
    clientOptions,
  );

  client.start().catch((err: unknown) => {
    const message = err instanceof Error ? err.message : String(err);
    if (message.includes("ENOENT")) {
      vscode.window.showErrorMessage(
        `Nox: '${serverPath}' bulunamadı. 'noxc' derleyicisini kurup ` +
          `PATH'e ekleyin (noxlsp, noxc ile birlikte kurulur), veya ` +
          `'nox.languageServerPath' ayarını noxlsp'nin tam yoluna ayarlayın.`,
      );
      return;
    }
    vscode.window.showErrorMessage(`Nox dil sunucusu başlatılamadı: ${message}`);
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
