const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

let client;

exports.activate = function () {
  const command = vscode.workspace.getConfiguration('hive').get('path') || 'hive';
  client = new LanguageClient('hive', 'Hive', { command, args: ['lsp'] }, {
    documentSelector: [{ scheme: 'file', language: 'hive' }],
  });
  return client.start();
};

exports.deactivate = function () {
  return client ? client.stop() : undefined;
};
