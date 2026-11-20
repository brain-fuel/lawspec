import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile, access, readdir} from 'node:fs/promises';
/** Resolve portable skill artifacts relative to the checkout, not the user environment. ref:REQ-learn-tutor */
const root = new URL('../../', import.meta.url);
const skills = ['lawspec-author', 'lawspec-project', 'lawspec-learn'];
test('the portable plugin holds the three skills, which keep only their instructions', async () =>
{
  const plugin = new URL('plugins/lawspec/', root);
  const manifest = await readFile(
    new URL('.codex-plugin/plugin.json', plugin),
    'utf8',
  );
  assert.equal(
    await readFile(new URL('.claude-plugin/plugin.json', plugin), 'utf8'),
    manifest,
  );
  const {version, skills: folder} = JSON.parse(manifest);
  assert.match(version, /^\d+\.\d+\.\d+-preview\.\d+$/);
  assert.equal(
    await readFile(new URL('LICENSE', plugin), 'utf8'),
    await readFile(new URL('LICENSE', root), 'utf8'),
  );
  for (const name of skills)
  {
    const directory = new URL(folder + name + '/', plugin);
    assert.deepEqual(await readdir(directory), ['SKILL.md']);
    const body = await readFile(new URL('SKILL.md', directory), 'utf8');
    assert.doesNotMatch(body, /references\//);
    // The repository's agent skills are the plugin's, through a link.
    assert.equal(
      await readFile(new URL(`.agents/skills/${name}/SKILL.md`, root), 'utf8'),
      body,
    );
  }
});

test('lawspec reference prints references built from the authoritative sources', async () =>
{
  const references = new URL('npm/references/', root);
  for (const file of [
    'authoring.md',
    'library.json',
    'library.md',
    'prelude.lawspec',
    'curriculum.json',
  ])
  {
    await access(new URL(file, references));
  }
  assert.equal(
    await readFile(new URL('curriculum.json', references), 'utf8'),
    await readFile(new URL('learn/curriculum.json', root), 'utf8'),
  );
  const source = await readFile(new URL('authoring.md', references), 'utf8');
  assert.doesNotMatch(source, /include=|lawspec (advise|inspect|prelude)/);
  for (const example of [
    'round-trip',
    'idempotence',
    'membership',
    'occurrences',
    'sets',
    'text',
    'failure',
    'ordering',
    'records',
    'variants',
    'exact-absence',
    'migration',
  ])
  {
    assert.ok(
      source.includes(
        await readFile(
          new URL(`examples/authoring/${example}.lawspec`, root),
          'utf8',
        ),
      ),
    );
  }
});
