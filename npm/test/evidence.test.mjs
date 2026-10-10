// Generated from templates/npm/test/evidence.test.mjs by lawspec-dev generate. Do not edit.
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

// An environment attestation (versioned JSON, written by any tool) says
// where each dependency of a run was wired; evidence reports it and changes
// no status.
const attestedSpec = `unit shop.orders

type Receipt is Receipt cents :: Int32 end
ability Gateway is
  capture :: Int32 -> Receipt
end
normalize :: Int32 -> Int32
definition twice (x :: Int32) :: BigInt is x + x end
definition checkout (cents :: Int32) :: Bool is
  match capture cents with | Receipt paid -> paid == cents end
end

law \`checkout charges the amount\` is
  definition is \`for all\` (cents :: Int32) . checkout cents = true end
end
law \`normalizing is idempotent\` is
  definition is \`for all\` (x :: Int32) . normalize (normalize x) = normalize x end
end
law \`doubling\` is
  definition is \`for all\` (x :: Int32) . twice x = x * 2 end
end
`;

const attestation = (id, gateway = {kind: 'stand-in', stand_in: {product: 'acme/gateway', version: '0.1.0', conformance: '3'}}) => ({
  format: 'environment-attestation', version: 1, environment: 'staging',
  run: {id, started_at: '2026-10-09T19:30:31Z', recorded_at: '2026-10-09T19:30:33Z'},
  dependencies: [
    {name: 'shop.orders::Gateway', endpoint: 'localhost:9092', reached: true, ...gateway},
    {name: 'shop.orders::normalize', endpoint: 'https://normalize.example.com', reached: true, kind: 'real'},
    {name: 'payments', endpoint: 'https://payments.example.com', reached: false, kind: 'real'},
  ],
});

test('evidence --attestation reports which tested laws ran against stand-ins, changing no status', async t => {
  const root = await project(t, attestedSpec);
  await writeFile(path.join(root, 'staging.json'), JSON.stringify(attestation('run-1')));
  const plain = JSON.parse(await lawspec(root, 'evidence', '--json'));
  const attested = JSON.parse(await lawspec(root, 'evidence', '--json', '--attestation', 'staging.json'));
  const find = (list, name) => list.find(item => item.declaration === name);
  const checkout = find(attested, 'shop.orders::law::checkout charges the amount');
  assert.equal(checkout.status, 'property-tested');
  assert.equal(checkout.environment, 'staging');
  assert.equal(checkout.environmentRun.id, 'run-1');
  assert.deepEqual(checkout.against.map(d => [d.dependency, d.kind, d.standIn?.conformance]), [['shop.orders::Gateway', 'stand-in', '3']]);
  assert.equal(find(attested, 'shop.orders::law::normalizing is idempotent').against[0].kind, 'real');
  assert.equal(find(attested, 'shop.orders::law::doubling').environment, undefined);
  // The plane rule: without the added fields, the evidence is what it was.
  const strip = ({environment, environmentRun, against, ...rest}) => rest;
  assert.deepEqual(attested.map(strip), plain);
  const text = await lawspec(root, 'evidence', '--attestation', 'staging.json');
  assert.match(text, /ran in environment staging \(run run-1\) against shop\.orders::Gateway: stand-in acme\/gateway 0\.1\.0 \(conformance level 3\) at localhost:9092/);
  assert.match(text, /ENVIRONMENT staging \(run run-1, recorded 2026-10-09T19:30:33Z\)/);
  assert.match(text, /payments: real at https:\/\/payments\.example\.com \(not reached when recorded\); no tested obligation relies on it/);
  assert.match(text, /PROPERTY TESTED \(2\)/);
});

test('lawspec.json names an attestation, and a malformed one is rejected', async t => {
  const root = await project(t, attestedSpec);
  await writeFile(path.join(root, 'lawspec.json'), JSON.stringify({version: 1, sources: ['laws'], targets: [], attestation: 'staging.json'}));
  await writeFile(path.join(root, 'staging.json'), JSON.stringify(attestation('run-2')));
  const evidence = JSON.parse(await lawspec(root, 'evidence', '--json'));
  assert.equal(evidence.find(item => item.declaration === 'shop.orders::law::checkout charges the amount').environmentRun.id, 'run-2');
  await writeFile(path.join(root, 'staging.json'), JSON.stringify({...attestation('run-3'), version: 2}));
  const rejected = JSON.parse(await lawspec(root, 'evidence', '--json'));
  assert.equal(rejected.diagnostics[0].code, 'attestation');
  assert.match(rejected.diagnostics[0].message, /version 2 is not known/);
  const misplaced = JSON.parse(await lawspec(root, 'check', '--json', '--attestation', 'staging.json'));
  assert.match(misplaced.diagnostics[0].message, /--attestation applies to evidence and test/);
});

test('evidence shows the attested run a law last passed in, from lawspec test results', async t => {
  const root = await project(t, attestedSpec);
  const results = path.join(root, '.lawspec', 'results');
  await mkdir(results, {recursive: true});
  // As lawspec test --attestation records them: checkout passed in run-4,
  // normalizing in a run with no attestation.
  await writeFile(path.join(results, 'javascript-000000000000.json'), JSON.stringify({version: 1,
    laws: {
      'shop.orders::law::checkout charges the amount': {key: 'k', seed: 1, passed: '2026-10-09T19:31:00.000Z', environment: 'run-4'},
      'shop.orders::law::normalizing is idempotent': {key: 'k', seed: 1, passed: '2026-10-09T19:31:00.000Z'},
    },
    attestations: {'run-4': attestation('run-4')}}));
  const evidence = JSON.parse(await lawspec(root, 'evidence', '--json'));
  const find = name => evidence.find(item => item.declaration === name);
  assert.equal(find('shop.orders::law::checkout charges the amount').environmentRun.id, 'run-4');
  assert.equal(find('shop.orders::law::normalizing is idempotent').environment, undefined);
  const text = await lawspec(root, 'evidence');
  assert.match(text, /ENVIRONMENT staging \(run run-4/);
  assert.match(text, /shop\.orders::normalize: real at https:\/\/normalize\.example\.com; no tested obligation relies on it/);
});
