import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile, access} from 'node:fs/promises';
/** Resolve portable skill artifacts relative to the checkout, not the user environment. ref:REQ-learn-tutor */
const root = new URL('../../', import.meta.url);
test('the portable plugin resolves all three skills and its tutor uses the authoritative course bytes', async () =>
{
  const plugin = new URL('plugins/lawspec/', root);
  const manifest = JSON.parse(
    await readFile(new URL('.codex-plugin/plugin.json', plugin)),
  );
  assert.match(manifest.version, /^\d+\.\d+\.\d+-preview\.\d+$/);
  for (const name of ['lawspec-author', 'lawspec-project', 'lawspec-learn'])
  {
    await access(new URL(manifest.skills + name + '/SKILL.md', plugin));
  }
  const source = await readFile(new URL('learn/curriculum.json', root), 'utf8');
  for (const path of [
    'learn/skills/lawspec-learn/references/curriculum.json',
    '.agents/skills/lawspec-learn/references/curriculum.json',
    'plugins/lawspec/skills/lawspec-learn/references/curriculum.json',
  ])
  {
    assert.equal(await readFile(new URL(path, root), 'utf8'), source);
  }
});

test('standalone skills contain the same versioned authoring sources', async () =>
{
  for (const name of ['lawspec-author', 'lawspec-project', 'lawspec-learn'])
  {
    for (const file of [
      'authoring.md',
      'library.json',
      'library.md',
      'prelude.lawspec',
      'version.json',
    ])
    {
      const source = await readFile(
        new URL(`.agents/skills/${name}/references/${file}`, root),
        'utf8',
      );
      assert.equal(
        await readFile(
          new URL(`plugins/lawspec/skills/${name}/references/${file}`, root),
          'utf8',
        ),
        source,
      );
      if (file === 'authoring.md')
      {
        assert.doesNotMatch(
          source,
          /include=|lawspec (advise|inspect|prelude)/,
        );
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
      }
    }
  }
});
