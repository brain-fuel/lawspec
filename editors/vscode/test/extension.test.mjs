// Generated from templates/editors/vscode/test/extension.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

test('VS Code passes the optional warning setting at initialization and subscribes to configuration changes', async () =>
{
  const manifest = JSON.parse(
    await readFile(new URL('../package.json', import.meta.url), 'utf8'),
  );
  assert.equal(
    manifest.contributes.configuration.properties['lawspec.warnMatches']
      .default,
    false,
  );
  for (const warnMatches of [false, true])
  {
    let options,
      started = false,
      stopped = false;
    const exports = {};
    const context = {subscriptions: []};
    const require = name =>
    {
      if (name === 'vscode')
        return {
          workspace: {
            getConfiguration: section =>
            {
              assert.equal(section, 'lawspec');
              return {
                get: (name, fallback) =>
                  name === 'warnMatches' ? warnMatches : fallback,
              };
            },
          },
        };
      assert.equal(name, 'vscode-languageclient/node');
      return {
        LanguageClient: class
        {
          /** Capture the options that the extension gives the real language client. */
          constructor(id, name, server, client)
          {
            options = client;
            assert.equal(server.args.join(' '), 'lsp --stdio');
          }
          /** Record that activation starts the language client. */
          async start()
          {
            started = true;
          }
          /** Record that disposal stops the language client. */
          stop()
          {
            stopped = true;
          }
        },
      };
    };
    vm.runInNewContext(
      await readFile(new URL('../extension.cjs', import.meta.url), 'utf8'),
      {exports, require},
    );
    await exports.activate(context);
    assert.equal(started, true);
    assert.equal(options.initializationOptions.warnMatches, warnMatches);
    assert.equal(options.synchronize.configurationSection, 'lawspec');
    context.subscriptions[0].dispose();
    assert.equal(stopped, true);
  }
});
