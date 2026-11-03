import assert from 'node:assert/strict';
import {test} from 'node:test';
import {spawn} from 'node:child_process';
import {
  mkdtemp,
  mkdir,
  readFile,
  writeFile,
  readdir,
  rm,
} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {configEDN} from './manifest-fixtures.mjs';

const cli = new URL('../bin/lawspec.mjs', import.meta.url).pathname;
const version = JSON.parse(
  await readFile(new URL('../package.json', import.meta.url), 'utf8'),
).version;
async function project(
  t,
  sources = {
    ordinary:
      'unit ordinary\nlaw selected is definition: true end definition end law\nend unit',
  },
)
{
  const root = await mkdtemp(path.join(tmpdir(), 'lawspec-mcp-inventory-'));
  await mkdir(path.join(root, 'laws'));
  for (const [name, content] of Object.entries(sources))
  {
    await writeFile(path.join(root, 'laws', name + '.lawspec'), content);
  }
  await writeFile(
    path.join(root, 'lawspec.edn'),
    configEDN({
      manifestVersion: 1,
      languageProfile: '1.0-rc.2',
      verification: {layers: []},
      sources: ['laws'],
      targets: [],
    }),
  );
  const child = spawn(process.execPath, [cli, 'mcp'], {
    cwd: root,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const pending = new Map();
  let buffer = '',
    errors = '',
    sequence = 0;
  child.stderr.on('data', data => (errors += data));
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', data =>
  {
    buffer += data;
    for (let end; (end = buffer.indexOf('\n')) >= 0;)
    {
      const line = buffer.slice(0, end);
      buffer = buffer.slice(end + 1);
      if (!line.trim()) continue;
      const message = JSON.parse(line);
      if (pending.has(message.id))
      {
        const {resolve, reject, timer} = pending.get(message.id);
        pending.delete(message.id);
        clearTimeout(timer);
        if (message.error) reject(new Error(JSON.stringify(message.error)));
        else resolve(message.result);
      }
    }
  });
  child.on('exit', code =>
  {
    for (const {reject, timer} of pending.values())
    {
      clearTimeout(timer);
      reject(new Error(`MCP exited ${code}: ${errors}`));
    }
    pending.clear();
  });
  t.after(async () =>
  {
    child.stdin.end();
    child.kill();
    await rm(root, {recursive: true, force: true});
  });
  const request = (method, params = {}) =>
    new Promise((resolve, reject) =>
    {
      const id = ++sequence;
      const timer = setTimeout(() =>
      {
        pending.delete(id);
        reject(new Error(`MCP ${method} timed out: ${errors}`));
      }, 30000);
      pending.set(id, {resolve, reject, timer});
      child.stdin.write(
        JSON.stringify({jsonrpc: '2.0', id, method, params}) + '\n',
      );
    });
  const initialized = await request('initialize', {
    protocolVersion: '2025-11-25',
    capabilities: {},
    clientInfo: {name: 'lawspec-integration-test', version: '1'},
  });
  child.stdin.write(
    JSON.stringify({jsonrpc: '2.0', method: 'notifications/initialized'}) +
      '\n',
  );
  return {
    root,
    request,
    initialized,
    tool: (name, args = {}) => request('tools/call', {name, arguments: args}),
  };
}

test('MCP derives its release version and declares every inspection tool read-only', async t =>
{
  const server = await project(t);
  assert.equal(server.initialized.serverInfo.version, version);
  const {tools} = await server.request('tools/list');
  assert.deepEqual(tools.map(tool => tool.name).sort(), [
    'lawspec_check',
    'lawspec_explain',
    'lawspec_list_laws',
  ]);
  for (const tool of tools)
    assert.equal(tool.annotations.readOnlyHint, true, tool.name);
});

test('MCP lists and explains ordinary, model and history laws without changing project files', async t =>
{
  const orders = await readFile(
    new URL('../../test/fixtures/order-workflow.lawspec', import.meta.url),
    'utf8',
  );
  const history = await readFile(
    new URL('../../test/fixtures/history-revocation.lawspec', import.meta.url),
    'utf8',
  );
  const ordinary =
    'unit ordinary\nlaw selected is definition: true end definition end law\nend unit';
  const server = await project(t, {orders, history, ordinary});
  const before = await readFile(path.join(server.root, 'lawspec.edn'), 'utf8');
  const listed = await server.tool('lawspec_list_laws');
  assert.notEqual(listed.isError, true, JSON.stringify(listed));
  const {laws} = JSON.parse(listed.content[0].text);
  for (const kind of ['property', 'model', 'history'])
  {
    const selected = laws.filter(law => law.kind === kind);
    assert.ok(selected.length > 0, kind);
    for (const view of ['eng', 'math', 'dev'])
    {
      const explained = await server.tool('lawspec_explain', {
        law: selected[0].id,
        view,
      });
      assert.notEqual(explained.isError, true, JSON.stringify(explained));
      assert.ok(
        explained.content[0].text.includes(
          kind === 'property' ? selected[0].name : selected[0].declaration,
        ),
      );
    }
  }
  const checked = await server.tool('lawspec_check');
  assert.notEqual(checked.isError, true, JSON.stringify(checked));
  const result = JSON.parse(checked.content[0].text);
  assert.ok(
    result.evidence
      .filter(row => row.stage === 'law')
      .every(row => row.status === 'not-verified'),
  );
  assert.equal(
    await readFile(path.join(server.root, 'lawspec.edn'), 'utf8'),
    before,
  );
  assert.deepEqual((await readdir(server.root)).sort(), [
    'laws',
    'lawspec.edn',
  ]);
  await writeFile(
    path.join(server.root, 'laws', 'ordinary.lawspec'),
    'unit ordinary\nfunction broken (x :: Int32) -> Rational is 1 / 0 end function\nend unit',
  );
  for (const tool of [
    'lawspec_check',
    'lawspec_list_laws',
    'lawspec_explain',
  ])
  {
    const rejected = await server.tool(
      tool,
      tool === 'lawspec_explain' ? {law: laws[0].id} : {},
    );
    assert.equal(rejected.isError, true, tool);
    assert.match(rejected.content[0].text, /total/);
  }
});
