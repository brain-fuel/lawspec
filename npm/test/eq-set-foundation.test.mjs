// Generated from templates/npm/test/eq-set-foundation.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';

test('WASM checks the internal equality-based set foundation through the legacy profile', async () => {
  const compiler = await createCompiler();
  const content = await readFile(new URL('../../test/fixtures/eq-set-foundation.lawspec', import.meta.url), 'utf8');
  for (const machineBits of [32, 64]) {
    const request = {schemaVersion: 3, machineBits,
      sources: [{path: 'eq-set-foundation.lawspec', content}]};
    const result = await compiler.check(request);
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.laws.length, 13);
    const evidence = result.evidence.filter(item => item.stage === 'law');
    assert.equal(evidence.length, 13);
    for (const item of evidence) {
      assert.equal(item.status, 'exhaustively-checked');
      assert.match(item.reason, /evaluated all 2 inputs/);
    }
    for (const name of ['iteration-reversed', 'member-changed', 'reflexive-member', 'zero-changed']) {
      const mutant = await readFile(new URL(`../../acceptance/rc1-eq-set-foundation/mutants/${name}.mutant`, import.meta.url), 'utf8');
      const [, search, replacement] = mutant.match(/<<<<<<<\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>>/);
      assert.ok(content.includes(search), name);
      const rejected = await compiler.check({...request, sources: [{...request.sources[0], content: content.replace(search, replacement)}]});
      assert.ok(rejected.diagnostics.some(item => item.code === 'refuted'), name);
      for (const expected of [...mutant.matchAll(/^expect: (.*)$/gm)].map(match => match[1])) {
        assert.ok(JSON.stringify(rejected.diagnostics).includes(expected), `${name}: ${expected}`);
      }
    }
  }
});
