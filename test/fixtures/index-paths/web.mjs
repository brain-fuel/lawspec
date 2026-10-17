// Index validation through structural products must retain dependent guards.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import * as s from '../../../runtime/lawspec_schema.mjs';
import {DataValue} from '../../../runtime/lawspec_runtime.mjs';
const construct = (tag, fields) => new DataValue(tag, fields);
const chain = new s.Named('Chain');
const inner = new s.Named('lawspec::structural::record::inner');
const outer = new s.Named('lawspec::structural::record::outer');
const wrapper = new s.Named('Wrapper');
const f = (name, type) => new s.Field(name, type);
const c = (tag, fields, indices = []) => new s.Constructor(tag, fields, class {}, [], null, indices);
const d = (type, constructors) => new s.Definition(type.name, 0, constructors);
function schema(path = 'p0/0/0.0') {
  return new s.Schema([
    d(chain, [c('Stop', [], ['c0','c10']), c('Next', [f('tail', chain)], ['+ f0 c1','+ f0.1 c1'])]),
    d(inner, [c('Inner', [f('rest', chain)])]),
    d(outer, [c('Outer', [f('child', inner),f('sibling', chain)], ['== p0/0.0 f1'])]),
    d(wrapper, [c('Wrap', [f('payload', outer)], [path, 'p0/0/0.1', '== p0/0/0.1 + p0/1.0 c10', `== ${path} p0/1.0`, `>= ${path} c1`])]),
  ], [], Object.fromEntries(['nothing','just','left','right','presence'].map(name => [name, class {}])));
}
const stop = construct('Stop', []);
const next = (value) => construct('Next', [value]);
const wrapped = (left, right) => construct('Wrap', [construct('Outer', [construct('Inner', [left]), right])]);
test('nested structural index guards validate on both machine widths', () => {
  for (const bits of [32,64]) {
    const checked = schema();
    const two = next(next(stop));
    const good = wrapped(two,two);
    const product = (left, right) => construct('Outer', [construct('Inner', [left]), right]);
    assert.deepEqual(checked.validate(outer, product(two,two), bits), product(two,two));
    assert.throws(() => checked.validate(outer, product(two,stop), bits), s.RefinementViolation);
    assert.deepEqual(checked.validate(wrapper, good, bits), good);
    assert.throws(() => checked.validate(wrapper, wrapped(two,next(stop)), bits), s.RefinementViolation);
    assert.throws(() => checked.validate(wrapper, wrapped(stop,stop), bits), s.RefinementViolation);
    assert.throws(() => schema('p0/1/0.0').validate(wrapper, good, bits), /structural record/);
    for (const path of ['p0/9.0', 'f0/0/0.0', 'p0/0/0.0.0', 'p0//0.0']) {
      assert.throws(() => schema(path).validate(wrapper, good, bits), /index field path/);
    }
  }
});
