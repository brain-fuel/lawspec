// Application integration evidence belongs with LawSpec. ref:DEC-host-sdk-independent-consumer
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, readFile, rm, readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createFormatter} from '../pilot-node.mjs';
import {createApplication} from '../assets/node.mjs';
import {createCompiler} from '../../npm/api.mjs';
/** Checks refusal classification as well as rejection. ref:REQ-host-sdk-runtime-boundary */
const denied = promise =>
  assert.rejects(promise, error => error.code === 'denied');
test(
  'Haskell formatter preserves compiler behavior, diagnostic ranges and default definition checks',
  {timeout: 120000},
  async t =>
  {
    const formatter = await createFormatter();
    t.after(() => formatter.close());
    const compiler = await createCompiler();
    const cases = [
      'unit sample\nfunction x (a :: Int32) -> Int32 is a end function\nend unit\n',
      'unit text\nfunction x (a :: Bool) -> Text is "日本語 😀 café" end function\nend unit\n',
      'unit bad\nfunction x (a :: Rational) -> Rational is a / 0 end function\nend unit\n',
      'unit bad\nfunction x (a :: Int32) -> Int32 is if then\nend unit\n',
    ];
    const checkedByDefault = await formatter.format({
      sources: [{path: 'default.lawspec', content: cases[2]}],
    });
    assert.ok(checkedByDefault.diagnostics.length);
    for (const content of cases)
      for (const compile of [false, true])
      {
        const input = {
          languageProfile: '1.0-rc.2',
          verification: {layers: []},
          sources: [{path: 'input.lawspec', content}],
          compile,
        };
        const expected = await compiler.format(input),
          actual = await formatter.format(input);
        assert.deepEqual(actual.diagnostics, expected.diagnostics);
        assert.deepEqual(
          actual.formattedSources,
          expected.formattedSources ?? [],
        );
        if (!actual.diagnostics.length)
          assert.deepEqual(
            (
              await formatter.format({
                sources: actual.formattedSources,
                compile,
              })
            ).formattedSources,
            actual.formattedSources,
          );
      }
  },
);

test(
  'Haskell file workflow writes only with a grant and never writes after syntax diagnostics',
  {timeout: 120000},
  async t =>
  {
    const root = await mkdtemp(path.join(tmpdir(), 'host-sdk-format-'));
    t.after(() => rm(root, {recursive: true, force: true}));
    const source =
      'unit a\nfunction id (x :: Int32) -> Int32 is\nx\nend function\nend unit\n';
    await writeFile(path.join(root, 'a.lawspec'), source);
    await writeFile(path.join(root, 'bad.lawspec'), 'unit bad\nfunction\n');
    const writable = await createFormatter({
      grants: {project: {kind: 'files', root, read: true, write: true}},
    });
    t.after(() => writable.close());
    const preview = await writable.formatFiles('project', ['a.lawspec']);
    assert.deepEqual(preview.diagnostics, []);
    assert.equal(await readFile(path.join(root, 'a.lawspec'), 'utf8'), source);
    const failed = await writable.formatFiles(
      'project',
      ['a.lawspec', 'bad.lawspec'],
      {write: true, compile: false},
    );
    assert.ok(failed.diagnostics.length);
    assert.equal(await readFile(path.join(root, 'a.lawspec'), 'utf8'), source);
    const success = await writable.formatFiles('project', ['a.lawspec'], {
      write: true,
    });
    assert.deepEqual(success.diagnostics, []);
    assert.equal(
      await readFile(path.join(root, 'a.lawspec'), 'utf8'),
      success.formattedSources[0].content,
    );
    const readonly = await createFormatter({
      grants: {project: {kind: 'files', root, read: true}},
    });
    t.after(() => readonly.close());
    assert.deepEqual(
      (await readonly.formatFiles('project', ['a.lawspec'])).diagnostics,
      [],
    );
    await denied(readonly.formatFiles('project', ['a.lawspec'], {write: true}));
  },
);

test(
  'all compiler methods preserve the public protocol on the SDK transport',
  {timeout: 180000},
  async () =>
  {
    const legacy = await createCompiler();
    const component = await createCompiler({
      runtime: 'component',
      compilation: process.env.LAWSPEC_TEST_COMPILATION,
    });
    const input = {
      languageProfile: '1.0-rc.2',
      verification: {layers: []},
      target: 'python',
      sources: [
        {
          path: 'example.lawspec',
          content:
            'unit example\nfunction id (x :: Int32) -> Int32 is x end function\nend unit\n',
        },
      ],
    };
    for (const method of [
      'prelude',
      'check',
      'format',
      'expand',
      'inspect',
      'planGeneration',
      'proofTasks',
      'explain',
      'advise',
    ])
    {
      const request = method === 'prelude' ? {query: 'Bool'} : input;
      assert.deepEqual(
        await component[method](request),
        await legacy[method](request),
        method,
      );
    }
    const invalid = {
      ...input,
      sources: [
        {
          path: 'bad.lawspec',
          content:
            'unit bad\nfunction divide (x :: Rational) -> Rational is x / 0 end function\nend unit\n',
        },
      ],
    };
    const rejected = await component.check(invalid);
    assert.ok(rejected.diagnostics.length);
    assert.deepEqual(rejected, await legacy.check(invalid));
    for (const layers of [[], ['proof'], ['examples']])
    {
      const laws = {
        ...input,
        verification: {layers},
        sources: [
          {
            path: 'law.lawspec',
            content:
              'unit evidence\nfunction id (x :: Int32) -> Int32 is x end function\nlaw identity is definition: for all (x :: Int32) => id x must be x end for all end definition end law\nend unit\n',
          },
        ],
      };
      const actual = await component.check(laws);
      assert.deepEqual(actual.diagnostics, []);
      assert.deepEqual(actual, await legacy.check(laws));
    }
    await assert.rejects(
      createCompiler({runtime: 'unknown'}),
      /Unknown compiler runtime/,
    );
    for (const runtime of [undefined, 'legacy'])
      await assert.rejects(
        createCompiler({runtime, compilation: 'source'}),
        /Compilation mode requires the component runtime/,
      );
  },
);

test(
  'SDK compiler memos persist through scoped file grants and retain semantic parity',
  {timeout: 180000},
  async t =>
  {
    const root = await mkdtemp(path.join(tmpdir(), 'lawspec-component-cache-'));
    t.after(() => rm(root, {recursive: true, force: true}));
    const first = await createCompiler({
      runtime: 'component',
      compilation: process.env.LAWSPEC_TEST_COMPILATION,
    });
    const input = {
      languageProfile: '1.0-rc.2',
      verification: {layers: []},
      sources: [
        {
          path: 'cache.lawspec',
          content:
            'unit cache\nfunction f (x :: Int32) -> Int32 is x end function\nend unit\n',
        },
      ],
      cacheDirectory: root,
    };
    const expected = await first.check(input);
    assert.deepEqual(expected.diagnostics, []);
    const collect = async dir =>
      (
        await Promise.all(
          (await readdir(dir, {withFileTypes: true})).map(e =>
            e.isDirectory()
              ? collect(path.join(dir, e.name))
              : [path.join(dir, e.name)],
          ),
        )
      ).flat();
    const entries = await collect(root);
    assert.ok(entries.length > 0, 'persistent compiler stage entries');
    const folders = await readdir(root);
    assert.equal(folders.length, 1);
    assert.match(folders[0], /^[0-9a-f]{64}$/);
    const second = await createCompiler({
      runtime: 'component',
      compilation: process.env.LAWSPEC_TEST_COMPILATION,
    });
    assert.deepEqual(await second.check(input), expected);
    await writeFile(entries[0], 'damaged');
    const third = await createCompiler({
      runtime: 'component',
      compilation: process.env.LAWSPEC_TEST_COMPILATION,
    });
    assert.deepEqual(await third.check(input), expected);
    const other = path.join(root, 'other');
    const responses = await Promise.all(
      [root, other].map(cacheDirectory =>
        first.check({...input, cacheDirectory}),
      ),
    );
    assert.deepEqual(responses, [expected, expected]);
    assert.ok((await collect(other)).length > 0);
  },
);

// Typed operations are compared to the pre-port compiler artifact, including
// malformed requests and preserved error/absence distinctions.
// ref:DEC-haskell-application-port ref:REQ-compiler-api-contract
test(
  'typed discovery and version selection preserve compatibility',
  {timeout: 120000},
  async t =>
  {
    const host = await createApplication({limits: {timeout: 120000}});
    t.after(() => host.close());
    const legacy = await createCompiler();
    const component = await createCompiler({
      runtime: 'component',
      compilation: process.env.LAWSPEC_TEST_COMPILATION,
    });
    for (const query of [
      undefined,
      '',
      'Bool',
      'BOOL',
      'definition',
      'fromList',
      '日本語',
      'no-such-prelude-entry-123',
      null,
      5,
      {},
      [],
    ])
    {
      const input = {query};
      assert.deepEqual(
        await component.prelude(input),
        await legacy.prelude(input),
      );
    }
    const all = await host.prelude({tag: 'all'});
    assert.equal(all.tag, 'catalog');
    assert.ok(all.val.entries.some(entry => entry.tag === 'law'));
    assert.ok(all.val.entries.some(entry => entry.tag === 'operation'));
    const invalid = await host.prelude({tag: 'invalid'});
    assert.equal(invalid.tag, 'invalid');
    assert.equal(invalid.val[0].code, 'request');
    for (const request of [
      {range: '^1.0.0', versions: ['1.2.0', '2.0.0', '1.9.0', '1.0.0']},
      {range: '^1.0.0', versions: ['invalid', '1.2.0']},
      {range: 'not a range', versions: ['1.0.0']},
      {range: '*', versions: []},
      {range: '*', versions: ['1.0.0', '1.0.0']},
    ])
    {
      const expected = JSON.parse(
        await host.dispatch(
          JSON.stringify({
            schemaVersion: 5,
            method: 'packageVersions',
            ...request,
          }),
        ),
      );
      const actual = await host.selectVersions(request);
      assert.deepEqual(
        actual.problems,
        expected.diagnostics.map(item => item.message),
      );
      assert.deepEqual(actual.versions ?? undefined, expected.versions);
    }
  },
);
