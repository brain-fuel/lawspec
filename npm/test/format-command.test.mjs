// Generated from templates/npm/test/format-command.test.mjs by lawspec-dev generate. Do not edit.
import {configEDN, packageEDN} from './manifest-fixtures.mjs';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp, mkdir, readFile, writeFile, rm} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';

const cli = new URL('../bin/lawspec.mjs', import.meta.url).pathname;
const draft =
  'unit draft\n-- Keep this comment.\nfunction broken (x :: Rational) -> Rational is\nx / 0\nend function\nend unit\n';
const input = sources => ({
  languageProfile: '1.0-rc.2',
  verification: {layers: []},
  sources,
});
const run = (root, args) =>
  spawnSync(process.execPath, [cli, ...args], {cwd: root, encoding: 'utf8'});
const text = result => result.stdout + result.stderr;

// ref:REQ-lawspec-quantifier-layout
test('quantified claims separate their header, arithmetic body and closer in checked and draft formatting', async () =>
{
  const compiler = await createCompiler();
  const content = [
    '-- ref:DEC-learn-tests-in-lawspec',
    'unit learn.seats',
    'seats :: Int32 -> Int32',
    'law "|every row contributes four seats| is',
    '  definition:',
    '    for all (rows :: Int32 where rows >= 0 and rows <= 40) => seats rows = rows',
    '      * 4 end for all',
    '  end definition',
    'end law',
    'end unit',
    '',
  ].join('\n');
  for (const compile of [false, true])
  {
    const result = await compiler.format({
      ...input([{path: 'seats.lawspec', content}]),
      compile,
    });
    assert.deepEqual(result.diagnostics, []);
    assert.match(
      result.formattedSources[0].content,
      /    for all \(rows :: Int32 where rows >= 0 and rows <= 40\) =>\n      seats rows = rows \* 4\n    end for all\n/,
    );
    assert.deepEqual(
      (await compiler.format({...input(result.formattedSources), compile}))
        .formattedSources,
      result.formattedSources,
    );
  }
});

test('triple-quoted multiline text preserves its exact value and spelling through checked and draft formatting', async () =>
{
  const compiler = await createCompiler();
  const expected = 'first "quote"  \n-- end unit\n   \nlast 😀';
  const literal = '"""' + expected + '"""';
  const content =
    'unit triple\nfunction text (ignored :: Bool) -> Text is ' +
    literal +
    ' end function\n' +
    'law exact is definition: text true must be ' +
    JSON.stringify(expected) +
    ' end definition end law\nend unit\n';
  for (const machineBits of [32, 64])
  {
    const sources = [{path: 'triple.lawspec', content}];
    const checked = await compiler.check({
      ...input(sources),
      machineBits,
      verification: {layers: ['exhaustive']},
    });
    assert.deepEqual(checked.diagnostics, []);
    assert.equal(
      checked.evidence.find(row => row.stage === 'law').status,
      'exhaustively-checked',
    );
    for (const compile of [false, true])
    {
      const formatted = await compiler.format({
        ...input(sources),
        machineBits,
        compile,
      });
      assert.deepEqual(formatted.diagnostics, []);
      assert.ok(formatted.formattedSources[0].content.includes(literal));
      const repeated = await compiler.format({
        ...input(formatted.formattedSources),
        machineBits,
        compile,
      });
      assert.deepEqual(repeated.formattedSources, formatted.formattedSources);
    }
  }
});

test('an unterminated triple-quoted string prevents every formatting write', async () =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-triple-errors-'));
  try
  {
    const valid =
      'unit valid\nfunction same (x :: Bool) -> Bool is\nx\nend function\nend unit\n';
    const broken =
      'unit broken\nfunction text (x :: Bool) -> Text is """unfinished\nend function\nend unit\n';
    await writeFile(path.join(root, 'valid.lawspec'), valid);
    await writeFile(path.join(root, 'broken.lawspec'), broken);
    await writeFile(
      path.join(root, 'lawspec.edn'),
      configEDN({
        manifestVersion: 1,
        languageProfile: '1.0-rc.2',
        sources: ['valid.lawspec', 'broken.lawspec'],
      }),
    );
    for (const flags of [[], ['--compile']])
    {
      const result = run(root, ['fmt', '--json', ...flags]);
      assert.equal(result.status, 1, text(result));
      assert.ok(
        JSON.parse(result.stdout).diagnostics.some(d =>
          d.message.includes('closing triple quote'),
        ),
      );
      assert.equal(
        await readFile(path.join(root, 'valid.lawspec'), 'utf8'),
        valid,
      );
      assert.equal(
        await readFile(path.join(root, 'broken.lawspec'), 'utf8'),
        broken,
      );
    }
  }
  finally
  {
    await rm(root, {recursive: true, force: true});
  }
});

test('fmt parses by default; --compile validates definitions before writing', async () =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-fmt-modes-'));
  try
  {
    const file = path.join(root, 'draft.lawspec');
    await writeFile(file, draft);
    const needed = run(root, ['fmt', 'draft.lawspec', '--check', '--json']);
    assert.equal(needed.status, 1, text(needed));
    assert.deepEqual(JSON.parse(needed.stdout).changed, ['draft.lawspec']);
    assert.equal(await readFile(file, 'utf8'), draft);
    for (const extra of [[], ['--check']])
    {
      const checked = run(root, [
        'fmt',
        'draft.lawspec',
        '--compile',
        ...extra,
      ]);
      assert.equal(checked.status, 1, text(checked));
      assert.match(text(checked), /total|defined|division|zero/i);
      assert.equal(await readFile(file, 'utf8'), draft);
    }
    const formatted = run(root, ['fmt', 'draft.lawspec', '--json']);
    assert.equal(formatted.status, 0, text(formatted));
    const saved = await readFile(file, 'utf8');
    assert.notEqual(saved, draft);
    assert.match(saved, /  x \/ 0/);
    assert.match(saved, /-- Keep this comment\./);
    const again = run(root, ['fmt', 'draft.lawspec', '--check', '--json']);
    assert.equal(again.status, 0, text(again));
    assert.deepEqual(JSON.parse(again.stdout).changed, []);
    await writeFile(file, draft.replace('x / 0', 'x'));
    const valid = run(root, ['fmt', 'draft.lawspec', '--compile']);
    assert.equal(valid.status, 0, text(valid));
    assert.equal(
      run(root, ['fmt', 'draft.lawspec', '--compile', '--check']).status,
      0,
    );
  }
  finally
  {
    await rm(root, {recursive: true, force: true});
  }
});

test('fmt refuses syntax errors transactionally and ignores unavailable packages until --compile', async () =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-fmt-project-'));
  try
  {
    await mkdir(path.join(root, 'laws'));
    const file = path.join(root, 'laws/draft.lawspec');
    await writeFile(file, draft);
    await writeFile(
      path.join(root, 'lawspec.edn'),
      configEDN({
        manifestVersion: 1,
        languageProfile: '1.0-rc.2',
        sources: ['laws'],
        packages: ['missing-package'],
        targets: [],
        verification: {layers: []},
      }),
    );
    const parsed = run(root, ['fmt']);
    assert.equal(parsed.status, 0, text(parsed));
    const saved = await readFile(file, 'utf8');
    const checked = run(root, ['fmt', '--compile']);
    assert.equal(checked.status, 1, text(checked));
    assert.match(text(checked), /missing-package/);
    assert.equal(await readFile(file, 'utf8'), saved);
    await writeFile(file, draft);
    const broken = path.join(root, 'laws/bad.lawspec');
    await writeFile(
      broken,
      'unit bad\nfunction unfinished (x :: Bool) -> Bool is x\n',
    );
    const invalid = run(root, ['fmt']);
    assert.equal(invalid.status, 1, text(invalid));
    assert.match(text(invalid), /parse|block|unclosed|end/i);
    assert.equal(await readFile(file, 'utf8'), draft);
    assert.equal(
      await readFile(broken, 'utf8'),
      'unit bad\nfunction unfinished (x :: Bool) -> Bool is x\n',
    );
    const wrongCommand = run(root, ['check', '--compile']);
    assert.equal(wrongCommand.status, 1, text(wrongCommand));
    assert.match(text(wrongCommand), /--compile applies to fmt/);
  }
  finally
  {
    await rm(root, {recursive: true, force: true});
  }
});

test('fmt uses available generic package headers without checking their definitions', async () =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-fmt-headers-'));
  try
  {
    await mkdir(path.join(root, 'dependency'));
    await writeFile(
      path.join(root, 'dependency', 'lawspec.edn'),
      packageEDN({
        name: 'acme.box',
        version: '1.0.0',
        sources: ['box.lawspec'],
      }),
    );
    await writeFile(
      path.join(root, 'dependency', 'box.lawspec'),
      'unit acme.box\ntype Box (a :: Type) is a record{value :: a} end type\nfunction broken (x :: Bool) -> Bool is 1 end function\nend unit\n',
    );
    await writeFile(
      path.join(root, 'lawspec.edn'),
      configEDN({
        manifestVersion: 1,
        languageProfile: '1.0-rc.2',
        sources: ['app.lawspec'],
        packages: ['dependency'],
        dependencies: {'acme.box': '^1.0.0'},
      }),
    );
    const file = path.join(root, 'app.lawspec');
    await writeFile(
      file,
      'unit app\nimport acme.box as boxes (Box)\ntype Wrapped is a record{box :: Box Bool} end type\nend unit\n',
    );
    const result = run(root, ['fmt']);
    assert.equal(result.status, 0, text(result));
    const saved = await readFile(file, 'utf8');
    assert.match(
      saved,
      /type Wrapped is a record\n\{\n  box :: Box Bool\n\}\nend type/,
    );
    assert.equal(run(root, ['fmt', '--check']).status, 0);
    const checked = run(root, ['fmt', '--compile']);
    assert.equal(checked.status, 1, text(checked));
    assert.equal(await readFile(file, 'utf8'), saved);
  }
  finally
  {
    await rm(root, {recursive: true, force: true});
  }
});

test('syntax formatting preserves source coordinates with multiple generic package versions', async () =>
{
  const compiler = await createCompiler();
  const sources = [
    {
      path: 'app.lawspec',
      content:
        'unit app\nimport acme.box as boxes (Box)\ntype Wrapped is a record{box :: Box Bool} end type\nend unit\n',
    },
  ];
  const packages = [
    {
      name: 'acme.box',
      version: '1.0.0',
      sources: [
        {
          path: 'box-v1.lawspec',
          content:
            'unit acme.box\ntype Box (a :: Type) is a record{value :: a} end type\nend unit\n',
        },
      ],
    },
    {
      name: 'acme.box',
      version: '2.0.0',
      sources: [
        {
          path: 'box-v2.lawspec',
          content:
            'unit acme.box\ntype Box (a :: Type) (b :: Type) is a record{first :: a second :: b} end type\nend unit\n',
        },
      ],
    },
    {
      name: 'acme.bridge',
      version: '1.0.0',
      dependencies: {'acme.box': '^2.0.0'},
      sources: [
        {path: 'bridge.lawspec', content: 'unit acme.bridge\nend unit\n'},
      ],
    },
  ];
  const request = {
    ...input(sources),
    compile: false,
    packages,
    dependencies: {'acme.box': '^1.0.0', 'acme.bridge': '^1.0.0'},
  };
  const result = await compiler.format(request);
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.formattedSources.length, 1);
  assert.match(
    result.formattedSources[0].content,
    /import acme.box as boxes \(Box\)/,
  );
  assert.match(
    result.formattedSources[0].content,
    /\n\{\n  box :: Box Bool\n\}\nend type/,
  );
  assert.deepEqual(
    (await compiler.format({...request, sources: result.formattedSources}))
      .formattedSources,
    result.formattedSources,
  );
});

test('SDK formatting retains its checked default and parsing alone emits no verification evidence', async () =>
{
  const compiler = await createCompiler();
  const sources = [{path: 'draft.lawspec', content: draft}];
  for (const compile of [undefined, true])
  {
    const result = await compiler.format({
      ...input(sources),
      ...(compile === undefined ? {} : {compile}),
    });
    assert.ok(result.diagnostics.length);
    assert.equal(result.formattedSources, undefined);
  }
  const result = await compiler.format({...input(sources), compile: false});
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.evidence, undefined);
  assert.equal(result.definitions, undefined);
  assert.deepEqual(
    (await compiler.format({...input(result.formattedSources), compile: false}))
      .formattedSources,
    result.formattedSources,
  );
  assert.ok(
    (await compiler.check({...input(sources), compile: false})).diagnostics
      .length,
  );
  const malformed = await compiler.format({
    ...input(sources),
    compile: 'false',
  });
  assert.ok(malformed.diagnostics.some(d => d.code === 'request'));
});

test('fmt reports independent parse errors together across fields, rows, declarations and files without writing', async () =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-fmt-errors-'));
  try
  {
    const content = await readFile(
      new URL(
        '../../test/fixtures/parser-multiple-errors.lawspec',
        import.meta.url,
      ),
      'utf8',
    );
    const second =
      'unit second\nfunction bad (x :: Bool) -> Bool is ? end function\nend unit\n';
    await writeFile(path.join(root, 'first.lawspec'), content);
    await writeFile(path.join(root, 'second.lawspec'), second);
    await writeFile(
      path.join(root, 'lawspec.edn'),
      configEDN({
        manifestVersion: 1,
        languageProfile: '1.0-rc.2',
        sources: ['first.lawspec', 'second.lawspec'],
      }),
    );
    for (const flags of [
      [],
      ['--check'],
      ['--compile'],
      ['--compile', '--check'],
    ])
    {
      const result = run(root, ['fmt', ...flags, '--json']);
      assert.equal(result.status, 1, text(result));
      const errors = JSON.parse(result.stdout).diagnostics;
      assert.equal(errors.length, 7, JSON.stringify(errors));
      assert.deepEqual(
        errors.map(d => [d.at.file, d.at.line]),
        [
          ['first.lawspec', 7],
          ['first.lawspec', 7],
          ['first.lawspec', 8],
          ['first.lawspec', 8],
          ['first.lawspec', 11],
          ['first.lawspec', 12],
          ['second.lawspec', 2],
        ],
      );
      assert.equal(
        errors.filter(d => /unknown literal constructor/.test(d.message))
          .length,
        4,
      );
      for (const error of errors.filter(d =>
        /unknown literal constructor/.test(d.message),
      ))
      {
        const name = error.message.match(
          /unknown literal constructor: (\w+)/,
        )[1];
        const line = content.split('\n')[error.at.line - 1];
        assert.equal(
          [...line]
            .slice(error.at.column - 1)
            .join('')
            .startsWith(name),
          true,
          `diagnostic must point at ${name}: ${JSON.stringify(error)}`,
        );
      }
      assert.equal(
        await readFile(path.join(root, 'first.lawspec'), 'utf8'),
        content,
      );
      assert.equal(
        await readFile(path.join(root, 'second.lawspec'), 'utf8'),
        second,
      );
    }
    const human = run(root, ['fmt']);
    assert.equal(human.status, 1);
    assert.match(text(human), /MadeUp/);
    assert.match(text(human), /second.lawspec:2:/);
  }
  finally
  {
    await rm(root, {recursive: true, force: true});
  }
});

test('parsing points at unknown constructors before trailing whitespace, rows and closers', async () =>
{
  const compiler = await createCompiler();
  const rows = [
    '    row "first", Nothing',
    '    row "second", Nothing',
    '    row "third", Just 0',
    '    row "fourth", MadeUp',
  ];
  const content = [
    'unit locations',
    'law samples is definition: true end definition',
    'expect true = expected in table (value,expected):',
    ...rows,
    'end table end law end unit',
  ].join('\n');
  for (const compile of [false, true])
  {
    const result = await compiler.format({
      ...input([{path: 'locations.lawspec', content}]),
      compile,
    });
    assert.deepEqual(
      result.diagnostics.map(d => [d.at.line, d.at.column]),
      rows.map((line, i) => [
        i + 4,
        line.indexOf(['Nothing', 'Nothing', 'Just', 'MadeUp'][i]) + 1,
      ]),
    );
    assert.equal(result.formattedSources, undefined);
  }
});

test('parsing reports hundreds of independent errors without a first-error limit', async () =>
{
  const compiler = await createCompiler();
  const count = 400;
  const content =
    'unit many\nlaw samples is definition: true end definition\n' +
    'expect true = expected in table (value,expected):\n' +
    Array.from({length: count}, () => 'row MadeUp,true\n').join('') +
    'end table end law end unit\n';
  const result = await compiler.format({
    ...input([{path: 'many.lawspec', content}]),
    compile: false,
  });
  assert.equal(result.diagnostics.length, count);
  assert.equal(result.diagnostics[0].at.line, 4);
  assert.equal(result.diagnostics.at(-1).at.line, count + 3);
  assert.equal(result.formattedSources, undefined);
});

test('a missing branch after Unicode text does not consume its valid closer or create a false second error', async () =>
{
  const compiler = await createCompiler();
  const prefix =
    'unit wide function broken (flag :: Bool) -> Text is if flag then "😀Ａé" else ';
  const sources = [
    {path: 'wide-error.lawspec', content: prefix + 'end if end function'},
  ];
  for (const [method, compile] of [
    ['format', false],
    ['format', true],
    ['check', true],
  ])
  {
    const result = await compiler[method]({...input(sources), compile});
    assert.equal(
      result.diagnostics.length,
      1,
      JSON.stringify(result.diagnostics),
    );
    assert.equal(result.diagnostics[0].code, 'parse');
    assert.deepEqual(result.diagnostics[0].at, {
      file: 'wide-error.lawspec',
      line: 1,
      column: [...prefix].length + 4,
    });
    assert.equal(result.formattedSources, undefined);
  }
});
