// Generated from templates/npm/test/semantic-reuse.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFile, spawnSync} from 'node:child_process';
import {promisify} from 'node:util';
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  symlink,
  writeFile,
} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createCompiler} from '../api.mjs';
import {proveWithZ3} from '../proof.mjs';
import {templates} from '../templates.mjs';
import {configEDN} from './manifest-fixtures.mjs';

const exec = promisify(execFile);
const cli = fileURLToPath(new URL('../bin/lawspec.mjs', import.meta.url));
const base = `unit identity.reuse
function twice (value :: Integer where value >= -3 && value <= 3) -> Integer is value + value end function
function unrelated (value :: Integer) -> Integer is value + 1 end function
law selected is
  description: "Twice adds the input to itself." end description
  definition: for all (input :: Integer where input >= -3 && input <= 3) => twice input = input * 2 end for all end definition
end law
end unit
`;
const harmless = [
  base.replaceAll('value', 'number').split('\n').join('\n\n'),
  base.replace('Twice adds the input to itself.', 'Twice doubles its input.'),
  base.replace('is value + 1 end function', 'is value + 2 end function'),
  base.replaceAll('twice', 'double'),
  base.replace('law selected', 'law "|renamed law|'),
];
const count = async filename =>
{
  try
  {
    return (await readFile(filename, 'utf8')).trim().split('\n').filter(Boolean)
      .length;
  }
  catch
  {
    return 0;
  }
};

test('real native tests rerun zero cases after harmless source edits and rerun a changed dependency', async () =>
{
  const folder = await mkdtemp(path.join(tmpdir(), 'lawspec-native-semantic-'));
  try
  {
    const project = path.join(folder, 'app');
    await mkdir(project);
    for (const [file, content] of Object.entries(templates('javascript')))
    {
      await mkdir(path.dirname(path.join(project, file)), {recursive: true});
      await writeFile(path.join(project, file), content);
    }
    const modules = fileURLToPath(
      new URL('../../.integration/javascript/node_modules', import.meta.url),
    );
    await symlink(modules, path.join(project, 'node_modules'), 'dir');
    const log = path.join(folder, 'native-runs');
    const preload = path.join(folder, 'observe.mjs');
    await writeFile(
      preload,
      `import {appendFileSync} from 'node:fs';\nif(process.env.LAWSPEC_NODE_RUN)appendFileSync(${JSON.stringify(log)},'native\\n');\n`,
    );
    await writeFile(
      path.join(folder, 'lawspec.edn'),
      configEDN({
        manifestVersion: 1,
        languageProfile: '1.0-rc.2',
        sources: ['input.lawspec'],
        verification: {layers: ['property', 'examples']},
        targets: [{language: 'javascript', root: 'app'}],
      }),
    );
    const run = async (command, args = []) =>
      exec(process.execPath, [cli, command, '--json', ...args], {
        cwd: folder,
        env: {...process.env, NODE_OPTIONS: `--import=${preload}`},
        maxBuffer: 4 * 1024 * 1024,
      });
    const generate = async content =>
    {
      await writeFile(path.join(folder, 'input.lawspec'), content);
      await run('generate');
    };
    await generate(base);
    const first = JSON.parse((await run('test')).stdout);
    assert.ok(first[0].ran.length > 0);
    const original = await count(log);
    assert.ok(original > 0);
    for (const content of harmless)
    {
      await generate(content);
      const result = JSON.parse((await run('test')).stdout);
      assert.deepEqual(result[0].ran, []);
      assert.equal(result[0].unchanged, 1);
      assert.equal(await count(log), original);
    }
    const report = JSON.parse((await run('evidence')).stdout);
    const native = (Array.isArray(report) ? report : report.evidence).find(
      row => row.stage === 'law',
    )?.nativeEvidence;
    assert.equal(native?.status, 'passed');
    assert.ok(native.observations.some(row => row.reused));
    assert.equal(await count(log), original);
    // The same semantic run also survives the other compiler-owned layout.
    await writeFile(path.join(folder, 'input.lawspec'), base);
    for (const [file, content] of Object.entries(
      templates('javascript', {minify: true}),
    ))
      await writeFile(path.join(project, file), content);
    await run('generate', ['--minify']);
    const compact = JSON.parse((await run('test', ['--minify'])).stdout);
    assert.deepEqual(compact[0].ran, []);
    assert.equal(await count(log), original);
    // A fresh request must always observe a real invocation.
    const fresh = JSON.parse(
      (await run('test', ['--minify', '--fresh'])).stdout,
    );
    assert.ok(fresh[0].ran.length > 0);
    assert.ok((await count(log)) > original);
    const beforeChanged = await count(log);
    await generate(
      base.replace(
        'is value + value end function',
        'is value + value + 1 end function',
      ),
    );
    await assert.rejects(run('test'));
    assert.ok((await count(log)) > beforeChanged);
    // An opaque adapter may call an exported generated helper that its law
    // never references. That generated implementation is still a dependency.
    const indirect = `unit identity.adapter
observe :: Integer -> Integer
function generated (value :: Integer) -> Integer is value + 1 end function
law selected is definition: for all (input :: Integer where input >= -3 && input <= 3) => observe input = input + 1 end for all end definition end law
end unit
`;
    await generate(indirect);
    await writeFile(
      path.join(project, 'src/identity/adapter.mjs'),
      'import {generated} from "../lawspec_definitions/identity/adapter.mjs";\nexport function observe(value){return generated(new Map(),value); }\n',
    );
    await run('test');
    const beforeIndirect = await count(log);
    await generate(
      indirect.replace(
        'is value + 1 end function',
        'is value + 2 end function',
      ),
    );
    await assert.rejects(run('test'));
    assert.ok((await count(log)) > beforeIndirect);
    const contract = indirect
      .replace('(value :: Integer)', '(value :: Integer where value >= 0)')
      .replace('input >= -3', 'input >= 0');
    await generate(contract);
    await run('test');
    const beforeContract = await count(log);
    await generate(contract.replace('value >= 0', 'value > 0'));
    await assert.rejects(run('test'));
    assert.ok((await count(log)) > beforeContract);

    // An admitted workflow can hide native stages behind a checked entry.
    // Select the user's law alone, so generated stage laws cannot conceal a
    // stale user-law result when the native implementation changes.
    const workflow = `unit identity.nativeClosure
workflow wrapper :: Integer -> Either Text Integer is
  foreign :: Integer -> Either Text Integer
end workflow
law selected is definition: for all (value :: Integer where value >= 0 && value <= 1) => wrapper value = Right (value + 1) end for all end definition end law
end unit
`;
    await writeFile(
      path.join(folder, 'harness.lawspec'),
      `harness identity.nativeClosure.testing for identity.nativeClosure is
  for law selected
    tags chosen
  end for law
end harness
`,
    );
    await writeFile(
      path.join(folder, 'lawspec.edn'),
      configEDN({
        manifestVersion: 1,
        languageProfile: '1.0-rc.2',
        sources: ['input.lawspec', 'harness.lawspec'],
        verification: {layers: ['property', 'examples']},
        targets: [{language: 'javascript', root: 'app'}],
      }),
    );
    await generate(workflow);
    const adapter = path.join(project, 'src/identity/nativeClosure.mjs');
    await writeFile(
      adapter,
      'import * as data from "../lawspec_data.mjs";\nexport function foreign(value){return new data.Right(value+1n); }\n',
    );
    const workflowFirst = JSON.parse(
      (await run('test', ['--tag', 'chosen'])).stdout,
    );
    assert.deepEqual(workflowFirst[0].ran, [
      'identity.nativeClosure::law::selected',
    ]);
    const beforeWorkflow = await count(log);
    const workflowCached = JSON.parse(
      (await run('test', ['--tag', 'chosen'])).stdout,
    );
    assert.deepEqual(workflowCached[0].ran, []);
    assert.equal(await count(log), beforeWorkflow);
    await writeFile(
      adapter,
      'import * as data from "../lawspec_data.mjs";\nexport function foreign(value){return new data.Right(value+2n); }\n',
    );
    await assert.rejects(run('test', ['--tag', 'chosen']));
    assert.ok((await count(log)) > beforeWorkflow);
  }
  finally
  {
    await rm(folder, {recursive: true, force: true});
  }
});

test('explicit native generators retain opaque implementation dependencies for a checked law', async () =>
{
  const compiler = await createCompiler();
  const sources = [
    {
      path: 'binding.lawspec',
      content: `unit identity.binding
type Token is a record { value :: Int8 } end type
law selected is definition: for all (value :: Token) => value = value end for all end definition end law
end unit
`,
    },
  ];
  const result = await compiler.planGeneration({
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    target: 'python',
    verification: {layers: ['property', 'examples']},
    sources,
    nativeBindings: {
      types: [
        {
          type: 'identity.binding::type::Token',
          native: ['domain', 'Token'],
          constructors: [
            {
              constructor: 'Token',
              native: ['domain', 'Token'],
              style: 'record',
              fields: [{field: 'value', native: 'value'}],
            },
          ],
        },
      ],
      generators: [
        {type: 'identity.binding::type::Token', factory: ['domain', 'tokens']},
      ],
    },
  });
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(
    result.tests.map(entry => entry.callsAdapters),
    [true],
  );
  const request = {
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    target: 'javascript',
    verification: {layers: ['property', 'examples']},
    sources: [{path: 'input.lawspec', content: base}],
  };
  const before = await compiler.planGeneration(request);
  const renamed = await compiler.planGeneration({
    ...request,
    nativeBindings: {
      names: [{declaration: 'identity.reuse::twice', name: 'doubleNative'}],
    },
  });
  assert.deepEqual(renamed.diagnostics, []);
  assert.deepEqual(
    renamed.tests.map(entry => [entry.key, entry.callsAdapters]),
    before.tests.map(entry => [entry.key, entry.callsAdapters]),
  );
});

const z3 =
  process.env.LAWSPEC_Z3 ??
  (spawnSync('z3', ['-version'], {encoding: 'utf8'}).status === 0
    ? 'z3'
    : null);
test(
  'real solver receipts survive harmless source edits with zero new solver tasks',
  {
    skip: z3
      ? false
      : 'install Z3 or set LAWSPEC_Z3 for semantic receipt integration',
  },
  async () =>
  {
    const folder = await mkdtemp(
      path.join(tmpdir(), 'lawspec-solver-semantic-'),
    );
    try
    {
      const log = path.join(folder, 'solver-runs');
      const binary = path.join(folder, 'solver');
      await writeFile(
        binary,
        `#!/usr/bin/env node
const fs=require('node:fs');
const {spawn}=require('node:child_process');
if(!process.argv.includes('-version'))fs.appendFileSync(${JSON.stringify(log)},'solver\\n');
const child=spawn(${JSON.stringify(z3)},process.argv.slice(2),{stdio:'inherit'});
child.on('error',()=>process.exit(127));
child.on('exit',(code,signal)=>{if(signal)process.kill(process.pid,signal);else process.exit(code??1);});
`,
      );
      await chmod(binary, 0o755);
      const compiler = await createCompiler();
      const request = content => ({
        schemaVersion: 5,
        languageProfile: '1.0-rc.2',
        machineBits: 64,
        verification: {layers: ['proof']},
        cacheDirectory: path.join(folder, 'cache'),
        sources: [{path: 'input.lawspec', content}],
      });
      const first = await proveWithZ3(compiler, request(base), {binary});
      assert.deepEqual(first.diagnostics, []);
      assert.equal(first.solverEvidence[0].status, 'proved');
      const original = await count(log);
      assert.ok(original > 0);
      for (const content of harmless)
      {
        const result = await proveWithZ3(compiler, request(content), {binary});
        assert.deepEqual(result.diagnostics, []);
        assert.equal(result.solverEvidence[0].status, 'proved');
        assert.equal(
          result.solverEvidence[0].declaration,
          result.proofTasks[0].declaration,
        );
        assert.equal(
          result.evidence.find(
            row =>
              row.stage === 'law' &&
              row.declaration === result.proofTasks[0].declaration,
          )?.status,
          'proved',
        );
        assert.ok(result.solverEvidence[0].reused);
        assert.equal(
          result.solverEvidence[0].runFingerprint,
          first.solverEvidence[0].runFingerprint,
        );
        assert.equal(await count(log), original);
      }
      const changed = await proveWithZ3(
        compiler,
        request(
          base.replace(
            'is value + value end function',
            'is value + value + 1 end function',
          ),
        ),
        {binary},
      );
      assert.equal(changed.solverEvidence[0].status, 'refuted');
      assert.equal(changed.solverEvidence[0].modelValidated, true);
      assert.ok((await count(log)) > original);
    }
    finally
    {
      await rm(folder, {recursive: true, force: true});
    }
  },
);

test('recording edits and nominal constructor changes rerun only recording-observing laws', async () =>
{
  const folder = await mkdtemp(
    path.join(tmpdir(), 'lawspec-recorded-semantic-'),
  );
  try
  {
    const project = path.join(folder, 'app');
    await mkdir(project);
    for (const [file, content] of Object.entries(templates('javascript')))
    {
      await mkdir(path.dirname(path.join(project, file)), {recursive: true});
      await writeFile(path.join(project, file), content);
    }
    await symlink(
      fileURLToPath(
        new URL('../../.integration/javascript/node_modules', import.meta.url),
      ),
      path.join(project, 'node_modules'),
      'dir',
    );
    await writeFile(
      path.join(folder, 'lawspec.edn'),
      configEDN({
        manifestVersion: 1,
        languageProfile: '1.0-rc.2',
        sources: ['input.lawspec'],
        verification: {layers: ['property', 'examples']},
        targets: [{language: 'javascript', root: 'app'}],
      }),
    );
    const source = `unit identity.recording
type Choice is one of Alpha | Middle end type
function choose (unused :: Unit) -> Choice is Alpha end function
law snapshot is definition: choose unitValue = recorded "first" end definition end law
law ordinary is definition: choose unitValue = Alpha end definition end law
end unit
`;
    const run = (command, args = []) =>
      exec(process.execPath, [cli, command, '--json', ...args], {
        cwd: folder,
        maxBuffer: 4 * 1024 * 1024,
      });
    await writeFile(path.join(folder, 'input.lawspec'), source);
    await run('generate');
    await run('test', ['--update-recorded']);
    // Creating the recording changes its digest once; settle that observation.
    await run('test');
    assert.deepEqual(JSON.parse((await run('test')).stdout)[0].ran, []);
    const recording = path.join(
      folder,
      'recorded',
      'identity.recording',
      'first',
    );
    const saved = await readFile(recording, 'utf8');
    await writeFile(recording, 'different recording\n');
    const evidence = JSON.parse((await run('evidence')).stdout);
    const rows = Array.isArray(evidence) ? evidence : evidence.evidence;
    assert.equal(
      rows.find(
        row => row.declaration.endsWith('::ordinary') && row.stage === 'law',
      ).nativeEvidence.status,
      'passed',
    );
    assert.notEqual(
      rows.find(
        row => row.declaration.endsWith('::snapshot') && row.stage === 'law',
      ).nativeEvidence.status,
      'passed',
    );
    const failsOnlySnapshot = async () =>
    {
      let failure;
      try
      {
        await run('test');
      }
      catch (error)
      {
        failure = error;
      }
      assert.ok(failure, 'the changed recording must be checked and fail');
      const summary = JSON.parse(failure.stdout)[0];
      assert.deepEqual(summary.ran, ['identity.recording::law::snapshot']);
      assert.equal(summary.unchanged, 1);
    };
    await failsOnlySnapshot();
    await writeFile(recording, saved);
    await run('test');
    await writeFile(
      path.join(folder, 'input.lawspec'),
      source.replaceAll('Alpha', 'Apple'),
    );
    await run('generate');
    await failsOnlySnapshot();
  }
  finally
  {
    await rm(folder, {recursive: true, force: true});
  }
});
