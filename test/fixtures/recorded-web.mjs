// Shared scalar fixtures and schema-aware recordings. ref:REQ-law-primitives
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import * as ls from '../../runtime/lawspec_runtime.mjs';
import {Schema, Definition, Constructor, Field, Named, Parameter} from '../../runtime/lawspec_schema.mjs';

const rows = JSON.parse(fs.readFileSync(new URL('recorded-values.json', import.meta.url), 'utf8'));
const folder = fs.mkdtempSync(path.resolve('.artifacts/recorded-web-'));
const previous = Object.fromEntries(['LAWSPEC_RECORDED', 'LAWSPEC_UPDATE_RECORDED'].map(key => [key, process.env[key]]));
const check = (key, expected, run) => {
  const file = path.join(folder, key);
  delete process.env.LAWSPEC_UPDATE_RECORDED;
  assert.throws(run, /no recording/);
  assert.equal(fs.existsSync(file), false);
  process.env.LAWSPEC_UPDATE_RECORDED = '1';
  assert.equal(run(), true);
  assert.equal(fs.readFileSync(file, 'utf8'), expected + '\n');
  delete process.env.LAWSPEC_UPDATE_RECORDED;
  assert.equal(run(), true);
  fs.writeFileSync(file, 'stale\n');
  assert.throws(run, /differs/);
  assert.equal(fs.readFileSync(file, 'utf8'), 'stale\n');
};
try {
  process.env.LAWSPEC_RECORDED = folder;
  for (const row of rows) {
    const value = ls.literal(row.scalar), type = row.type ?? row.scalar.type;
    assert.equal(ls.recordedText(value, type), row.text, row.name);
    check(row.name, row.text, () => ls.helper('recorded', [row.name, value], ['Text', type]));
  }
  const forbidden = () => { throw new Error('recording must not rerun a predicate or codec'); };
  const schema = new Schema([
    new Definition('Pair', 2, [new Constructor('Pair::Pair', [new Field('a', new Parameter(0)), new Field('b', new Parameter(1))], class Pair {}, [forbidden])]),
    new Definition('Box', 0, [new Constructor('Box::Box', [new Field('value', new Parameter(0)), new Field('witness', new Named('Text'))], class Box {}, [forbidden], null, [], [], 1, [0])]),
    new Definition('Fixed', 1, [new Constructor('Fixed::Bytes', [new Field('value', new Parameter(0))], class Fixed {}, [forbidden], null, [], [[0, new Named('Bytes')]])]),
  ], ['Bytes', 'Char', 'Text', 'Symbol'], Object.fromEntries(['nothing', 'just', 'left', 'right', 'presence'].map(name => [name, class {}])));
  const examples = [
    ['pair', new Named('Pair', [new Named('Bytes'), new Named('Char')]), new ls.DataValue('Pair::Pair', [new Uint8Array([0, 255]), '雪']), 'Pair(bytes([0, 255]), "雪")'],
    ['witness', new Named('Box'), new ls.DataValue('Box::Box', [new Uint8Array([255]), 'Bytes']), 'Box(bytes([255]), "Bytes")'],
    ['gadt', new Named('Fixed', [new Named('Bytes')]), new ls.DataValue('Fixed::Bytes', [new Uint8Array([255])]), 'Bytes(bytes([255]))'],
  ];
  for (const [key, type, value, expected] of examples) {
    assert.equal(schema.recordedText(type, value), expected);
    check(key, expected, () => schema.recorded(type, key, value));
  }
  const a = Symbol('same'), b = Symbol('same');
  assert.equal(ls.recordedText([a, b, a], 'List Symbol'), '[symbol(1, "same"), symbol(2, "same"), symbol(1, "same")]');
  assert.equal(ls.recordedText(b, 'Symbol'), 'symbol(1, "same")');
  ls.handle(42n, 'Worker');
  ls.handle('same', 'Worker');
  assert.equal(ls.recordedText(42n, 'Integer'), '42');
  assert.equal(ls.recordedText('same', 'Text'), '"same"');
  assert.equal(ls.recordedText(b, 'Symbol'), 'symbol(1, "same")');
  assert.equal(ls.recordedText(42n, 'Worker'), 'Worker#1');
  console.log(`${rows.length} scalar and ${examples.length} schema recording checks passed (JavaScript/TypeScript)`);
} finally {
  for (const [key, value] of Object.entries(previous)) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
  fs.rmSync(folder, {recursive: true, force: true});
}
