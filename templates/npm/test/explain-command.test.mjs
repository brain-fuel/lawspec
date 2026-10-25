import assert from 'node:assert/strict';
import {test} from 'node:test';
import {spawnSync} from 'node:child_process';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createCompiler} from '../api.mjs';
import {configEDN} from './manifest-fixtures.mjs';

// lawspec explain: eng by default, math and dev on request, --json for any
// view, and clear errors for removed views. The CLI and the API agree.
const cli = fileURLToPath(new URL('../bin/lawspec.mjs', import.meta.url));
const content = await readFile(new URL('../examples/rc1/refund-policy.lawspec', import.meta.url), 'utf8');
const law = 'example.refunds::|an eligible flagged refund requires review|';

async function project() {
  const directory = await mkdtemp(path.join(tmpdir(), 'lawspec-explain-'));
  await writeFile(path.join(directory, 'refund-policy.lawspec'), content);
  await writeFile(path.join(directory, 'lawspec.edn'), configEDN({manifestVersion: 1, languageProfile: '1.0-rc.2',
    sources: ['refund-policy.lawspec'], targets: []}));
  return directory;
}
const run = (directory, ...args) => spawnSync(process.execPath, ['--no-warnings', cli, 'explain', ...args],
  {cwd: directory, encoding: 'utf8'});

test('explain defaults to eng, offers math and dev, and prints any view as structured JSON', async () => {
  const directory = await project();
  try {
    const compiler = await createCompiler();
    const request = {schemaVersion: 5, languageProfile: '1.0-rc.2', sources: [{path: 'refund-policy.lawspec', content}], law};
    const plain = run(directory, law);
    assert.equal(plain.status, 0, plain.stderr);
    assert.equal(plain.stdout, run(directory, law, '--view', 'eng').stdout);
    assert.match(plain.stdout, /^Law: an eligible flagged refund requires review\nFor every request \(a RefundRequest\):\n/);
    assert.match(plain.stdout, /then the refund for this request must be the refund decision "review required"\./);
    const expected = {
      eng: /- this request is flagged/,
      math: /∀ request ∈ RefundRequest\.\n {2}\(request\.requestedAmount > 0 ∧ .*\) ⇒ refund\(request\) = ReviewRequired/,
      dev: /request\.requestedAmount > 0 and request\.requestedAmount <= request\.capturedAmount and request\.flagged implies refund request = ReviewRequired/,
    };
    for (const view of ['eng', 'math', 'dev']) {
      const text = run(directory, law, '--view', view);
      assert.equal(text.status, 0, text.stderr);
      assert.match(text.stdout, expected[view]);
      const json = run(directory, law, '--view', view, '--json');
      assert.equal(json.status, 0, json.stderr);
      const records = JSON.parse(json.stdout);
      assert.equal(records.length, 1);
      assert.deepEqual(Object.keys(records[0]), ['law', 'name', 'sections', 'view']);
      assert.equal(records[0].view, view);
      // The text is derived from the sections, and the CLI matches the API.
      assert.equal(records[0].sections.flatMap(section => section.lines).join('\n') + '\n', text.stdout);
      const api = await compiler.explain({...request, view});
      assert.deepEqual(api.explanations, records);
      assert.equal(api.text + '\n', text.stdout);
    }
    const statement = JSON.parse(run(directory, law, '--json').stdout)[0].sections.find(section => section.kind === 'statement');
    assert.deepEqual(statement.cases, [{case: 'review required', cases: ['approved', 'review required', 'rejected'], type: 'refund decision'}]);
    const every = run(directory, '--json');
    assert.equal(JSON.parse(every.stdout).length, 4);
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('removed and unknown explain views fail with the new values named', async () => {
  const directory = await project();
  try {
    const replacements = {developer: 'dev', business: 'eng', formal: 'math'};
    for (const [old, replacement] of Object.entries(replacements)) {
      const result = run(directory, law, '--view', old);
      assert.equal(result.status, 1);
      assert.match(result.stderr, new RegExp(`"${old}" was renamed to "${replacement}"; choose --view eng\\|math\\|dev`));
    }
    const evidence = run(directory, law, '--view', 'evidence');
    assert.equal(evidence.status, 1);
    assert.match(evidence.stderr, /"evidence" was removed; run lawspec evidence <unit>::<law>/);
    const unknown = run(directory, law, '--view', 'prose');
    assert.equal(unknown.status, 1);
    assert.match(unknown.stderr, /unknown explain view "prose"; choose --view eng\|math\|dev/);
    const missing = run(directory, 'example.refunds::missing');
    assert.equal(missing.status, 1);
    assert.match(missing.stderr, /No matching law/);
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});
