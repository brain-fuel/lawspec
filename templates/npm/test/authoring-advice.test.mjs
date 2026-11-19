import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile, mkdtemp, writeFile, mkdir, readdir} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {createCompiler} from '../api.mjs';

const compiler = await createCompiler();
const source = `unit advice.model
type Point is a record {x :: Int32 y :: Int32} end type
echo :: Point -> Point
law identity is definition: for all (p :: Point) => echo p = p end for all end definition end law
end unit`;
const request = {
  languageProfile: '1.0-rc.2',
  sources: [{path: 'model.lawspec', content: source}],
};
test('compiler findings use resolved identities, preserve evidence, and honor no-advice', async () =>
{
  const content = `unit advice.helpers
f :: Bool -> Bool
g :: Bool -> Bool
function count (xs :: List Integer) -> Integer is
 first matching case of xs: when Nil then 0 when Cons h t then 1 + count t end case
end function
law twice is definition: for all (x :: Bool) => f (f x) = f x end for all end definition end law
law different is definition: for all (x :: Bool) => f (g x) = f x end for all end definition end law
law reused is definition: apply law "|idempotent| f end definition end law
end unit`;
  for (const machineBits of [32, 64])
  {
    const input = {
      ...request,
      machineBits,
      sources: [{path: 'helpers', content}],
    };
    const advised = await compiler.check(input),
      bare = await compiler.check({...input, advice: false});
    assert.deepEqual(advised.diagnostics, []);
    assert.deepEqual(advised.evidence, bare.evidence);
    assert.equal(bare.advice, undefined);
    assert.deepEqual(
      advised.advice.findings.map(f => f.declaration),
      ['advice.helpers::count', 'advice.helpers::law::twice'],
    );
    for (const minify of [false, true])
    {
      const generated = await compiler.planGeneration({
        ...input,
        target: 'javascript',
        minify,
      });
      assert.deepEqual(generated.advice, advised.advice);
    }
  }
});
// The native analysis itself is the core's (LawSpec.Authoring.Native); its
// rules over every program target are tested there (AuthoringNativeSpec).
test('SDK advice analyses native sources in the core and settles exceptions', async () =>
{
  const targeted = {...request, target: 'javascript'};
  const competing = await compiler.advise({
    ...targeted,
    nativeSources: [{path: 'clone.mjs', content: 'class Point {}'}],
  });
  assert.deepEqual(competing.diagnostics, []);
  assert.equal(competing.interface, undefined);
  assert.equal(competing.advice.ok, false);
  assert.deepEqual(Object.keys(competing.advice.findings.at(-1)), [
    'rule',
    'target',
    'path',
    'declaration',
    'line',
    'severity',
    'status',
    'message',
    'suggestion',
  ]);
  const excepted = await compiler.advise({
    ...targeted,
    nativeSources: [{path: 'clone.mjs', content: 'class Point {}'}],
    exceptions: [
      {
        declaration: 'clone.mjs::Point',
        rule: 'native-model',
        reason: 'Independent reference model',
      },
    ],
  });
  assert.equal(excepted.advice.ok, true);
  for (const source of [
    {path: 'broken.mjs', content: 'class {'},
    {path: 'view.tsx', content: 'const Point = () => <div/>;'},
    {path: 'foreign.mjs', content: "import {Point} from './missing.mjs';"},
  ])
  {
    const report = await compiler.advise({...targeted, nativeSources: [source]});
    assert.equal(report.advice.ok, false, JSON.stringify(report.advice));
  }
  const absent = await compiler.advise(targeted);
  assert.equal(absent.advice.ok, false);
  const blank = await compiler.advise({
    ...targeted,
    nativeSources: [],
    exceptions: [{declaration: 'x', rule: 'native-model', reason: ' '}],
  });
  // The core settles exceptions (AuthoringNativeSpec); a blank reason is
  // refused there as here.
  assert.match(blank.diagnostics[0].message, /nonempty/);
});
test('prelude and project inspection are read-only CLI operations', async () =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-advice-'));
  const cli = new URL('../bin/lawspec.mjs', import.meta.url);
  const run = args =>
    spawnSync(process.execPath, [cli.pathname, ...args], {
      cwd: root,
      encoding: 'utf8',
    });
  const discovery = run(['prelude', 'sameItems', '--json']);
  assert.equal(discovery.status, 0, discovery.stderr);
  assert.equal(JSON.parse(discovery.stdout).entries[0].name, 'sameItems');
  assert.deepEqual(await readdir(root), []);
  await mkdir(path.join(root, 'laws'));
  await writeFile(path.join(root, 'laws/model.lawspec'), source);
  await writeFile(
    path.join(root, 'lawspec.edn'),
    '{:manifest-version 1 :language-profile "1.0-rc.2" :component {:name "trial" :version "0.1.0"} :sources ["laws"] :targets [{:language :javascript :root "."}]}',
  );
  const inspected = run(['inspect', '--target', 'javascript', '--json']);
  assert.equal(inspected.status, 0, inspected.stderr + inspected.stdout);
  const advised = run([
    'advise',
    '--target',
    'javascript',
    '--strict',
    '--json',
  ]);
  assert.equal(advised.status, 0, advised.stderr + advised.stdout);
  assert.deepEqual((await readdir(root)).sort(), ['laws', 'lawspec.edn']);
  await writeFile(path.join(root, 'clone.mjs'), 'class Point {}');
  const strict = run(['advise', '--strict', '--json']);
  assert.equal(strict.status, 1, strict.stderr + strict.stdout);
  const normal = run(['check', '--no-cache', '--json']);
  assert.equal(normal.status, 0, normal.stderr);
  assert.deepEqual(JSON.parse(normal.stdout).diagnostics, []);
  assert.ok(JSON.parse(normal.stdout).advice.findings.length);
  const quiet = run(['check', '--no-cache', '--no-advice', '--json']);
  assert.equal(quiet.status, 0, quiet.stderr);
  assert.equal(JSON.parse(quiet.stdout).advice, undefined);
  const manifest = await readFile(path.join(root, 'lawspec.edn'), 'utf8');
  await writeFile(
    path.join(root, 'lawspec.edn'),
    manifest.slice(0, -1) +
      ' :authoring-exceptions [{:declaration "clone.mjs::Point" :rule "native-model" :reason "Independent reference model"}]}',
  );
  const excepted = run(['advise', '--strict', '--json']);
  assert.equal(excepted.status, 0, excepted.stderr + excepted.stdout);
  assert.equal(JSON.parse(excepted.stdout).findings[0].status, 'excepted');
  assert.equal(
    await readFile(path.join(root, 'clone.mjs'), 'utf8'),
    'class Point {}',
  );
});

test('MCP prelude discovery works before project initialization', async () =>
{
  const {spawn} = await import('node:child_process');
  const {createInterface} = await import('node:readline');
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-mcp-discovery-'));
  const child = spawn(
    process.execPath,
    [new URL('../bin/lawspec.mjs', import.meta.url).pathname, 'mcp'],
    {cwd: root, stdio: ['pipe', 'pipe', 'pipe']},
  );
  let errors = '';
  child.stderr.on('data', chunk => (errors += chunk));
  const waiting = new Map();
  const lines = createInterface({input: child.stdout});
  lines.on('line', line =>
  {
    const message = JSON.parse(line);
    waiting.get(message.id)?.(message);
  });
  let id = 0;
  const call = (method, params) =>
    new Promise((resolve, reject) =>
    {
      const requestId = ++id;
      const timer = setTimeout(
        () => reject(new Error('MCP timed out: ' + errors)),
        10000,
      );
      waiting.set(requestId, message =>
      {
        clearTimeout(timer);
        waiting.delete(requestId);
        resolve(message);
      });
      child.stdin.write(
        JSON.stringify({jsonrpc: '2.0', id: requestId, method, params}) + '\n',
      );
    });
  try
  {
    const hello = await call('initialize', {
      protocolVersion: '2025-11-25',
      capabilities: {},
      clientInfo: {name: 'test', version: '1'},
    });
    assert.ok(hello.result, JSON.stringify(hello));
    child.stdin.write(
      JSON.stringify({jsonrpc: '2.0', method: 'notifications/initialized'}) +
        '\n',
    );
    const listed = await call('tools/list', {});
    for (const name of ['lawspec_prelude', 'lawspec_inspect', 'lawspec_advise'])
      assert.ok(listed.result.tools.some(tool => tool.name === name));
    const response = await call('tools/call', {
      name: 'lawspec_prelude',
      arguments: {query: 'sameItems'},
    });
    assert.equal(
      JSON.parse(response.result.content[0].text).entries[0].name,
      'sameItems',
    );
    assert.deepEqual(await readdir(root), []);
  }
  finally
  {
    lines.close();
    child.kill();
  }
});

test('resolved helper patterns preserve generic equality and respect shadowed names', async () =>
{
  const input = {
    ...request,
    sources: [
      {
        path: 'helpers',
        content: `unit advice.generics
function contains (needle :: a) (xs :: List a) -> Bool requires Eq a is
 first matching case of xs:
 when Nil then false
 when Cons h t then if needle = h then true else contains needle t end if
 end case
end function
function use (xs :: List Integer) -> Bool is contains 1 xs end function
function length (xs :: List Integer) -> Integer is 17 end function
function count (xs :: List Integer) -> Integer is
 first matching case of xs: when Nil then 0 when Cons h t then 1 + length t end case
end function
end unit`,
      },
    ],
  };
  const result = await compiler.check(input);
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(
    result.advice.findings.map(f => [f.declaration, f.suggestion]),
    [['advice.generics::contains', 'prelude.member']],
  );
  const unused = await compiler.advise({
    ...input,
    sources: input.sources.map(source => ({
      ...source,
      content: source.content.replace(
        'function use (xs :: List Integer) -> Bool is contains 1 xs end function',
        '',
      ),
    })),
  });
  assert.equal(unused.advice.ok, false);
  assert.ok(
    unused.advice.checks.some(
      c =>
        c.status === 'incomplete' &&
        c.declaration === 'advice.generics::contains',
    ),
  );
});

test('SDK inspection and advisory requests ignore writable compiler cache options', async () =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-inspect-cache-'));
  const before = JSON.stringify(request);
  for (const method of ['inspect', 'advise'])
  {
    const result = await compiler[method]({
      ...request,
      target: 'javascript',
      nativeSources: [],
      cacheDirectory: root,
    });
    assert.deepEqual(result.diagnostics, []);
  }
  assert.equal(JSON.stringify(request), before);
  assert.deepEqual(await readdir(root), []);
});
