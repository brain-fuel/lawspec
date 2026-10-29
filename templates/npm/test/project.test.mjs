import assert from 'node:assert/strict';
import {test} from 'node:test';
import
  {
    mkdtemp,
    readFile,
    writeFile,
    mkdir,
    readdir,
    rm,
  } from 'node:fs/promises';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {setupProject, inspectProject, projectExitCode} from '../project.mjs';
import {writeManifest} from '../component.mjs';
import {readManifest} from '../component.mjs';
import {spawnSync} from 'node:child_process';
async function fixture(run)
{
  const root = await mkdtemp(path.join(tmpdir(), 'lawspec-project-test-'));
  try
  {
    await run(root);
  }
  finally
  {
    await rm(root, {recursive: true, force: true});
  }
}
test('target-free initialization, adoption, and validation preserve separate outcomes', async () =>
  fixture(async root =>
  {
    const created = await setupProject(root);
    assert.equal(created.applicationFilesChanged, false);
    const original = await readFile(path.join(root, 'lawspec.edn'), 'utf8');
    assert.match(original, /:targets \[\]/);
    assert.equal(
      (await inspectProject(root)).verification.status,
      'not-verified',
    );
    const validated = await inspectProject(root, {validate: true});
    assert.equal(validated.canon.status, 'passed');
    assert.equal(validated.definitions.status, 'passed');
    assert.equal(validated.verification.status, 'not-verified');
    assert.equal(projectExitCode(validated), 0);
    await assert.rejects(setupProject(root), /already exists/);
    assert.equal(
      (await setupProject(root, {adopt: true})).manifest,
      'preserved',
    );
    assert.equal(
      await readFile(path.join(root, 'lawspec.edn'), 'utf8'),
      original,
    );
  }));
test('adoption preserves existing application and Canon bytes and creates only missing LawSpec metadata', async () =>
  fixture(async root =>
  {
    await writeFile(
      path.join(root, 'app.mjs'),
      'export const refund = x => x;\n',
    );
    await setupProject(root);
    const canon = await readFile(path.join(root, 'canon.yaml'));
    await rm(path.join(root, 'lawspec.edn'));
    await setupProject(root, {adopt: true});
    assert.deepEqual(await readFile(path.join(root, 'canon.yaml')), canon);
    assert.equal(
      await readFile(path.join(root, 'app.mjs'), 'utf8'),
      'export const refund = x => x;\n',
    );
  }));
test('an existing LawSpec project keeps its manifest, sources, targets, and verification selection', async () =>
  fixture(async root =>
  {
    await mkdir(path.join(root, 'specs'));
    const content = 'unit adopted\nend unit\n';
    await writeFile(path.join(root, 'specs/existing.lawspec'), content);
    const manifest = writeManifest({
      manifestVersion: 1,
      component: {name: 'adopted', version: '0.1.0'},
      languageProfile: '1.0-rc.2',
      sources: ['specs'],
      targets: [],
      verification: {layers: ['model']},
    });
    await writeFile(path.join(root, 'lawspec.edn'), manifest);
    await setupProject(root, {adopt: true});
    assert.equal(
      await readFile(path.join(root, 'lawspec.edn'), 'utf8'),
      manifest,
    );
    assert.equal(
      await readFile(path.join(root, 'specs/existing.lawspec'), 'utf8'),
      content,
    );
    const result = await inspectProject(root, {validate: true});
    assert.deepEqual(result.verification.layers, ['model']);
    assert.equal(result.native.status, 'incomplete');
    assert.equal(projectExitCode(result), 2);
  }));
test('conflicting metadata is rejected before setup writes', async () =>
  fixture(async root =>
  {
    await writeFile(path.join(root, 'lawspec.edn'), '{:sources [');
    await assert.rejects(setupProject(root, {adopt: true}), /EDN/);
    assert.deepEqual(await readdir(root), ['lawspec.edn']);
    await rm(path.join(root, 'lawspec.edn'));
    await writeFile(path.join(root, 'lawspec.json'), '{}');
    await assert.rejects(
      setupProject(root, {adopt: true}),
      /no longer supported/,
    );
    assert.deepEqual(await readdir(root), ['lawspec.json']);
  }));
test('unsupported and incomplete evidence cannot become an exit-code pass', () =>
{
  for (const status of ['unsupported', 'unknown', 'incomplete', 'pending'])
  {
    assert.equal(projectExitCode({verification: {evidence: [{status}]}}), 2);
  }
  assert.equal(projectExitCode({definitions: {status: 'failed'}}), 1);
});
test('Canon incompatibility cannot skip mandatory definition validation', async () =>
  fixture(async root =>
  {
    await setupProject(root);
    const config = JSON.parse(
      await readFile(path.join(root, 'canon.yaml'), 'utf8'),
    );
    config.canon = '99.0.0';
    await writeFile(path.join(root, 'canon.yaml'), JSON.stringify(config));
    const report = await inspectProject(root, {validate: true});
    assert.equal(report.canon.status, 'incomplete');
    assert.equal(report.definitions.status, 'passed');
    assert.equal(projectExitCode(report), 2);
  }));
test(
  'configured proof discharge replaces pre-solver incompleteness in the project outcome',
  {
    skip:
      spawnSync(process.env.LAWSPEC_Z3 ?? 'z3', ['-version']).status !== 0 &&
      'Z3 is not installed',
  },
  async () =>
    fixture(async root =>
    {
      await setupProject(root);
      const file = path.join(root, 'lawspec.edn'),
        manifest = await readManifest(file);
      manifest.verification = {layers: ['proof']};
      await writeFile(file, writeManifest(manifest));
      await writeFile(
        path.join(root, 'laws/project.lawspec'),
        'unit evidenceProof\nfunction bump (x :: Integer) -> Integer is x + 1 end function\nlaw grows is definition: for all (x :: Integer) => bump x > x end for all end definition end law\nend unit\n',
      );
      const report = await inspectProject(root, {validate: true});
      assert.equal(report.proof.status, 'passed');
      assert.ok(
        report.verification.evidence.some(
          row => row.stage === 'law' && row.status === 'proved',
        ),
      );
      assert.equal(projectExitCode(report), 0);
    }),
);
