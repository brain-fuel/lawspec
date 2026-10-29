import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile, access} from 'node:fs/promises';
/** Resolve portable skill artifacts relative to the checkout, not the user environment. ref:REQ-learn-tutor */
const root = new URL('../../', import.meta.url);
test('the portable plugin resolves the tutor skill and its tutor uses the authoritative course bytes', async () =>
{
  const plugin = new URL('plugins/lawspec/', root);
  const manifest = JSON.parse(
    await readFile(new URL('.codex-plugin/plugin.json', plugin)),
  );
  assert.match(manifest.version, /^\d+\.\d+\.\d+-preview\.\d+$/);
  for (const name of ['lawspec-learn'])
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
