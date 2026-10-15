// Generated from templates/editors/vscode/extension.cjs by lawspec-dev generate. Do not edit.
const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');
let client;
exports.activate = async function activate(context) {
  const command = vscode.workspace.getConfiguration('lawspec').get('command', 'lawspec');
  client = new LanguageClient('lawspec', 'LawSpec', { command, args: ['lsp', '--stdio'] }, {
    documentSelector: [{ scheme: 'file', language: 'lawspec' }],
  });
  context.subscriptions.push({ dispose: () => client?.stop() });
  await client.start();
};
exports.deactivate = () => client?.stop();
