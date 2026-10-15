import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';

const content = await readFile(new URL('../../test/fixtures/canonical-set-domains.lawspec', import.meta.url), 'utf8');
const input = (machineBits, layers) => ({schemaVersion: 5, languageProfile: '1.0-rc.1',
  machineBits, verification: {layers}, sources: [{path: 'set-domains.lawspec', content}]});
const evidence = result => result.evidence.filter(item => item.stage === 'law');

test('finite set covers retain all storage orders and dependent accepted tuples', async () => {
  const compiler = await createCompiler();
  for (const bits of [32, 64]) {
    const request = input(bits, ['exhaustive', 'examples']);
    const result = await compiler.check(request);
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.laws.length, 8);
    assert.equal(result.laws[0].examples.length, 5);
    assert.ok(evidence(result).every(item => item.status === 'exhaustively-checked'));
    for (const [index, count] of [[0, 5], [2, 25], [3, 17], [4, 114], [6, 2], [7, 16]])
      assert.match(evidence(result)[index].reason, new RegExp(`evaluated all ${count} inputs`));
    const generated = await compiler.planGeneration({...request, target: 'typescript'});
    assert.deepEqual(generated.diagnostics, []);
    assert.ok(generated.files.some(file => file.content.includes('export type T_Empty = never;')));
    const limited = await compiler.planGeneration({...request, target: 'javascript', generation: {exhaustiveLimit: 4}});
    assert.ok(limited.diagnostics.some(item => item.code === 'verification-incomplete'));
    const planned = await compiler.check(input(bits, ['property', 'examples']));
    assert.deepEqual(planned.diagnostics, []);
    assert.ok(evidence(planned).every(item => item.status === 'planned'));
    assert.deepEqual(planned.laws.map(law => law.assertion), result.laws.map(law => law.assertion));
    const bare = await compiler.check(input(bits, []));
    assert.deepEqual(bare.diagnostics, []);
    assert.ok(evidence(bare).every(item => item.status === 'not-verified'));
  }
});

test('complete finite set checking refutes an omitted order and smaller cardinality claims', async () => {
  const compiler = await createCompiler();
  for (const bits of [32, 64]) for (const name of ['missing-order', 'nested-too-small', 'too-small']) {
    const mutant = await readFile(new URL(`../../acceptance/rc1-set-domains/mutants/${name}.mutant`, import.meta.url), 'utf8');
    const [, search, replacement] = mutant.match(/<<<<<<<\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>>/);
    assert.ok(content.includes(search), name);
    const request = input(bits, ['exhaustive']);
    request.sources[0].content = content.replace(search, replacement);
    const result = await compiler.check(request);
    assert.ok(result.diagnostics.some(item => item.code === 'refuted'), `${name}: ${JSON.stringify(result.diagnostics)}`);
  }
});
