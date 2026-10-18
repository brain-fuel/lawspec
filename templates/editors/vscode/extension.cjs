const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');
let client;
exports.activate = async function activate(context) {
  const command = vscode.workspace.getConfiguration('lawspec').get('command', 'lawspec');
  client = new LanguageClient('lawspec', 'LawSpec', { command, args: ['lsp', '--stdio'] }, {
    initializationOptions: { warnMatches: vscode.workspace.getConfiguration('lawspec').get('warnMatches', false) },
    synchronize: { configurationSection: 'lawspec' },
    documentSelector: [{ scheme: 'file', language: 'lawspec' }],
  });
  context.subscriptions.push({ dispose: () => client?.stop() });
  await client.start();
};
exports.deactivate = () => client?.stop();
