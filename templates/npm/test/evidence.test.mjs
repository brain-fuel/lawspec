// lawspec evidence reports how every obligation is discharged.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {mkdtemp, mkdir, rm, writeFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {promisify} from 'node:util';

const run = promisify(execFile);
const cli = new URL('../bin/lawspec.mjs', import.meta.url).pathname;

const spec = `unit shop.evidence

definition twice (x :: Int32) :: BigInt is x + x end
flipFlag :: Bool -> Bool
normalize :: Int32 -> Int32
unused :: Int8 -> Int8

law \`doubling\` is
  definition is \`for all\` (x :: Int32) . twice x = x * 2 end
end

law \`flipping twice\` is
  definition is \`for all\` (b :: Bool) . flipFlag (flipFlag b) = b end
end

law \`normalizing is idempotent\` is
  definition is \`for all\` (x :: Int32) . normalize (normalize x) = normalize x end
end
`;

async function project(t, source) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-evidence-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  await mkdir(path.join(root, 'laws'));
  await writeFile(path.join(root, 'laws', 'evidence.lawspec'), source);
  await writeFile(path.join(root, 'lawspec.json'), JSON.stringify({version: 1, sources: ['laws'], targets: []}));
  return root;
}

async function lawspec(cwd, ...args) {
  try {
    return (await run(process.execPath, [cli, ...args], {cwd})).stdout;
  } catch (error) {
    return error.stdout;
  }
}

test('evidence classifies laws, adapters and the unused adapter', async t => {
  const root = await project(t, spec);
  const evidence = JSON.parse(await lawspec(root, 'evidence', '--json'));
  const status = name => evidence.find(item => item.declaration === name)?.status;
  assert.equal(status('shop.evidence::law::doubling'), 'proved');
  assert.equal(status('shop.evidence::law::flipping twice'), 'exhaustively-checked');
  assert.equal(status('shop.evidence::law::normalizing is idempotent'), 'property-tested');
  assert.equal(status('shop.evidence::unused'), 'assumed');
  assert.match(evidence.find(item => item.declaration === 'shop.evidence::unused').reason, /no law calls it/);
  const text = await lawspec(root, 'evidence');
  for (const heading of ['PROVED (1)', 'EXHAUSTIVELY CHECKED (1)', 'PROPERTY TESTED (1)', 'ASSUMED / EXTERNAL (3)'])
    assert.ok(text.includes(heading), heading);
  assert.match(await lawspec(root, 'check'), /Evidence: 1 proved, 1 exhaustively checked, 1 property tested, 0 measured, 0 runtime checked, 0 default handler, 3 assumed \/ external\./);
});

test('evidence filters by unit or declaration', async t => {
  const root = await project(t, spec);
  const evidence = JSON.parse(await lawspec(root, 'evidence', 'shop.evidence::doubling', '--json'));
  assert.deepEqual(evidence.map(item => item.status), ['proved']);
});

test('a false law over definitions with a finite domain is refuted', async t => {
  const root = await project(t, 'unit shop.refuted\ndefinition inc (x :: Int8) :: BigInt is x + 1 end\n' +
    'law `always positive` is definition is `for all` (x :: Int8) . inc x > 0 end end\n');
  const result = JSON.parse(await lawspec(root, 'check', '--json'));
  assert.equal(result.diagnostics[0].code, 'refuted');
  assert.match(result.diagnostics[0].message, /law always positive is false for x = -128/);
});
