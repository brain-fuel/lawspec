import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile, mkdtemp, writeFile, mkdir, readdir} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {createCompiler} from '../api.mjs';
import {programTargets, artifactTargets} from '../templates.mjs';
import {analyzeNative, settleAdvice} from '../authoring.mjs';

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
const clones = {
  java: ['Point.java', 'record Point(int x, int y) {}'],
  python: ['model.py', 'class Point:\n    pass\n'],
  javascript: ['model.mjs', 'class Point {}'],
  typescript: ['model.ts', 'interface Point { x: number; y: number; }'],
  go: ['model.go', 'package model\ntype Point struct { X int32; Y int32 }\n'],
  haskell: ['Model.hs', 'module Model where\ndata Point = Point Int Int'],
  kotlin: ['Model.kt', 'data class Point(val x: Int, val y: Int)'],
  rust: ['model.rs', 'struct Point { x: i32, y: i32 }'],
  erlang: ['model.erl', '-module(model).\n-record(point, {x, y}).'],
  elixir: [
    'model.ex',
    'defmodule LawSpec.Data.Point do\n defstruct [:x, :y]\nend',
  ],
  gleam: ['model.gleam', 'pub type Point { Point(x: Int, y: Int) }'],
  fsharp: ['Model.fs', 'module Model\ntype Point = { X: int; Y: int }'],
  csharp: ['Model.cs', 'public record Point(int X, int Y);'],
  scala: ['Model.scala', 'case class Point(x: Int, y: Int)'],
  groovy: ['Model.groovy', 'class Point { int x; int y }'],
  clojure: ['model.clj', '(ns model)\n(defrecord Point [x y])'],
  swift: ['Model.swift', 'struct Point { var x: Int; var y: Int }'],
  prolog: ['model.pl', 'point(point{x:1,y:2}).'],
};

test('all program targets load bundled parsers and complete the common bounded checks', async () =>
{
  assert.deepEqual(Object.keys(clones).sort(), [...programTargets].sort());
  for (const target of programTargets)
  {
    const inspected = await compiler.inspect({...request, target});
    assert.deepEqual(inspected.diagnostics, [], target);
    assert.ok(inspected.interface.artifacts.length, target);
    const clean = settleAdvice(await analyzeNative(inspected, {target}, []));
    assert.equal(clean.ok, true, JSON.stringify({target, clean}));
    const [file, content] = clones[target];
    const competing = settleAdvice(
      await analyzeNative(inspected, {target}, [{path: file, content}]),
    );
    assert.ok(
      competing.findings.some(f => f.rule === 'native-model'),
      JSON.stringify({target, competing}),
    );
    assert.equal(competing.ok, false);
    const renamed = await analyzeNative(
      {
        ...inspected,
        files: [
          {path: 'generated/data/' + file, content, ownership: 'generated'},
        ],
      },
      {target},
      [
        {
          path: 'alternative/' + file,
          content: content
            .replaceAll('Point', 'Renamed')
            .replaceAll('point', 'renamed'),
        },
      ],
    );
    assert.ok(
      renamed.findings.some(f => f.rule === 'native-model'),
      JSON.stringify({target, renamed}),
    );
    const exceptions = competing.findings.map(f => ({
      declaration: f.declaration,
      rule: f.rule,
      reason: 'Independent reference model in this declaration',
    }));
    const excepted = settleAdvice(competing, exceptions);
    assert.ok(excepted.findings.every(f => f.status === 'excepted'));
    const support = inspected.files.find(
      f =>
        f.ownership === 'generated' &&
        /runtime/i.test(f.path) &&
        /\.(java|py|mjs|js|ts|go|rs|hs|kt|erl|ex|gleam|fs|cs|scala|groovy|clj|swift|pl)$/.test(
          f.path,
        ),
    );
    const copy = await analyzeNative(inspected, {target}, [
      {path: 'copied/' + support.path, content: support.content},
    ]);
    assert.ok(
      copy.findings.some(f => f.rule === 'copied-generated'),
      target,
    );
    const absent = settleAdvice(
      await analyzeNative(inspected, {target}, undefined),
    );
    assert.equal(absent.ok, false, target);
  }
});
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
test('strict settlement rejects parse failures, unsupported sources, missing references and empty reasons', async () =>
{
  const inspected = await compiler.inspect({...request, target: 'javascript'});
  for (const source of [
    {path: 'broken.mjs', content: 'class {'},
    {path: 'unknown.xyz', content: 'class Point {}'},
    {path: 'view.tsx', content: 'const Point = () => <div/>;'},
    {path: 'foreign.mjs', content: "import {Point} from './missing.mjs';"},
  ])
  {
    const report = settleAdvice(
      await analyzeNative(inspected, {target: 'javascript'}, [source]),
    );
    assert.equal(report.ok, false, JSON.stringify(report));
    assert.ok(
      report.checks.some(
        c => !['complete', 'not-applicable'].includes(c.status),
      ),
    );
  }
  assert.throws(
    () =>
      settleAdvice({findings: [], checks: []}, [
        {declaration: 'x', rule: 'native-model', reason: ' '},
      ]),
    /nonempty/,
  );
  for (const target of artifactTargets)
  {
    const report = await analyzeNative({files: []}, {target}, undefined);
    assert.ok(report.checks.every(c => c.status === 'not-applicable'));
  }
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

test('generated adapters use the generated model cleanly in every program target', async () =>
{
  for (const target of programTargets)
  {
    for (const machineBits of [32, 64])
    {
      const result = await compiler.inspect({...request, target, machineBits});
      const adapters = result.files.filter(file => file.ownership === 'user');
      assert.ok(adapters.length, target);
      const report = settleAdvice(
        await analyzeNative(result, {target}, adapters),
      );
      assert.equal(report.ok, true, JSON.stringify({target, report}));
      const compact = await compiler.inspect({
        ...request,
        target,
        machineBits,
        minify: true,
      });
      assert.deepEqual(
        compact.interface,
        result.interface,
        target + ' canonical readable interface',
      );
      const generated = await compiler.planGeneration({
        ...request,
        target,
        machineBits,
        minify: true,
      });
      const nativeFiles = generated.files.filter(file =>
        /\.(java|py|mjs|js|ts|go|rs|hs|kt|erl|ex|gleam|fs|cs|scala|groovy|clj|swift|pl)$/.test(
          file.path,
        ),
      );
      const compactReport = settleAdvice(
        await analyzeNative(result, {target}, nativeFiles),
      );
      assert.equal(
        compactReport.ok,
        true,
        JSON.stringify({target, compactReport}),
      );
    }
  }
});

test('checked native bindings retain application models and unsupported bindings remain diagnostics', async () =>
{
  for (const target of programTargets)
  {
    const module = ['haskell', 'elixir', 'fsharp', 'swift'].includes(target)
      ? 'Domain'
      : 'domain';
    const prefix = target === 'rust' ? ['crate', module] : [module];
    const name = ['erlang', 'prolog'].includes(target) ? 'point' : 'Point';
    const nativeBindings = {
      ...(target === 'rust' ? {rustCrate: 'trial'} : {}),
      ...(target === 'go'
        ? {goImports: [{alias: 'domain', path: 'example.test/domain'}]}
        : {}),
      ...(target === 'erlang' ? {erlangIncludes: [{path: 'domain.hrl'}]} : {}),
      types: [
        {
          type: 'advice.model::type::Point',
          native: [...prefix, name],
          constructors: [
            {
              constructor: 'Point',
              native: target === 'erlang' ? [name] : [...prefix, name],
              style: 'record',
              fields: [
                {field: 'x', native: target === 'go' ? 'X' : 'x'},
                {field: 'y', native: target === 'go' ? 'Y' : 'y'},
              ],
            },
          ],
        },
      ],
      functions: [
        {
          declaration: 'advice.model::echo',
          native: [...prefix, target === 'go' ? 'Echo' : 'echo'],
        },
      ],
    };
    const input = {...request, target, nativeBindings};
    const result = await compiler.inspect(input);
    if (['csharp', 'clojure'].includes(target))
    {
      assert.ok(
        result.diagnostics.some(d => d.message.includes('not types')),
        target,
      );
      continue;
    }
    assert.deepEqual(result.diagnostics, [], target);
    const bound = result.interface.data.find(
      d => d.declaration === 'advice.model::type::Point',
    );
    assert.equal(bound.ownership, 'bound', target);
    assert.equal(bound.nativeName, null, target);
    assert.deepEqual(bound.nativeBinding, [[...prefix, name]], target);
    const [file, original] = clones[target];
    let content = original.replaceAll('LawSpec.Data.Point', 'Domain.Point');
    content = content
      .replace('module Model where', 'module Domain where')
      .replace('module Model\n', 'module Domain\n')
      .replace('-module(model).', '-module(domain).')
      .replace('package model', 'package domain');
    if (['java', 'groovy'].includes(target))
      content = 'package domain;\n' + content;
    if (['kotlin', 'scala'].includes(target))
      content = 'package domain\n' + content;
    const sourcePath =
      target === 'java' ? 'domain/Point.java' : module + path.extname(file);
    const sources = [{path: sourcePath, content}];
    const report = await analyzeNative(result, input, sources);
    assert.ok(
      !report.findings.some(f => f.rule === 'native-model'),
      JSON.stringify({target, report}),
    );
    assert.equal(
      settleAdvice(report).ok,
      true,
      JSON.stringify({target, report}),
    );
  }
});

const conversions = {
  java: 'class Convert { Point convert(Point p) { return p; } }',
  python: 'def convert(p: Point) -> Point:\n    return p\n',
  javascript: 'function convert(p) { return new Point(p.x,p.y); }',
  typescript: 'function convert(p: Point): Point { return p; }',
  go: 'func Convert(p Point) Point { return p }',
  haskell: 'convert p = Point 1 2',
  kotlin: 'fun convert(p: Point): Point = p',
  rust: 'fn convert(p: Point) -> Point { p }',
  erlang: 'convert(P) -> #point{x=P#point.x,y=P#point.y}.',
  elixir:
    'defmodule Convert do\n def convert(p), do: %LawSpec.Data.Point{x: p.x, y: p.y}\nend',
  gleam: 'pub fn convert(p: Point) -> Point { p }',
  fsharp: 'let convert (p: Point): Point = p',
  csharp: 'class Convert { Point convert(Point p) { return p; } }',
  scala: 'def convert(p: Point): Point = p',
  groovy: 'class Convert { Point convert(Point p) { return p } }',
  clojure: '(defn convert [p] (Point. (:x p) (:y p)))',
  swift: 'func convert(_ p: Point) -> Point { return p }',
  prolog: "convert(point{x:X,y:Y},value('advice.model::type::Point',[X,Y])).",
};
test('adapter identity and conversion review rules cover each supported declaration syntax', async () =>
{
  for (const target of programTargets)
  {
    const result = await compiler.inspect({...request, target});
    const [file, clone] = clones[target];
    const content = clone + '\n' + conversions[target];
    // A declaration-specific adapter baseline exercises the syntax rule;
    // actual emitter signatures are tested separately above.
    const baseline = {
      ...result,
      files: [
        ...result.files,
        {path: 'adapter/' + file, content, ownership: 'user'},
      ],
    };
    const report = await analyzeNative(baseline, {target}, [
      {path: file, content},
    ]);
    for (const rule of [
      'native-model',
      'adapter-identity',
      'manual-conversion',
    ])
      assert.ok(
        report.findings.some(f => f.rule === rule),
        JSON.stringify({target, rule, report}),
      );
  }
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

test('target selection scopes native languages and includes composite hosts', async () =>
{
  const java = await compiler.inspect({...request, target: 'java'});
  const unrelated = settleAdvice(
    await analyzeNative(java, {target: 'java'}, [
      {path: 'web.mjs', content: 'class Point {}'},
    ]),
  );
  assert.equal(unrelated.ok, true);
  assert.ok(
    unrelated.checks.some(
      c => c.rule === 'native-language' && c.status === 'not-applicable',
    ),
  );
  const csharp = await compiler.inspect({...request, target: 'csharp'});
  const [file, content] = clones.fsharp;
  const host = settleAdvice(
    await analyzeNative(csharp, {target: 'csharp'}, [{path: file, content}]),
  );
  assert.ok(host.findings.some(f => f.rule === 'native-model'));
});
