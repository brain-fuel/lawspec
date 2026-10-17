"""Dependent index guards remain mandatory inside structural products."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'runtime'))
from lawspec_schema import Schema, Named, Field, Constructor, Definition, RefinementViolation
from lawspec_runtime import DataValue
def construct(tag, fields): return DataValue(tag, fields)
chain = Named('Chain')
inner = Named('lawspec::structural::record::inner')
outer = Named('lawspec::structural::record::outer')
wrapper = Named('Wrapper')
def ctor(tag, fields=(), indices=()):
    return Constructor(tag, fields, type(tag, (), {}), indices=indices)
def schema(path='p0/0/0.0'):
    return Schema([
        Definition(chain.name, 0, [ctor('Stop', indices=['c0','c10']),
            ctor('Next', [Field('tail',chain)], ['+ f0 c1','+ f0.1 c1'])]),
        Definition(inner.name, 0, [ctor('Inner', [Field('rest',chain)])]),
        Definition(outer.name, 0, [ctor('Outer', [Field('child',inner), Field('sibling',chain)], ['== p0/0.0 f1'])]),
        Definition(wrapper.name, 0, [ctor('Wrap', [Field('payload',outer)],
            [path, 'p0/0/0.1', '== p0/0/0.1 + p0/1.0 c10', f'== {path} p0/1.0', f'>= {path} c1'])]),
    ], [])
stop = construct('Stop', [])
def next_(value): return construct('Next', [value])
def wrapped(left, right):
    return construct('Wrap', [construct('Outer', [construct('Inner', [left]), right])])
for bits in (32,64):
    checked = schema()
    two = next_(next_(stop))
    good = wrapped(two,two)
    product = lambda left, right: construct('Outer', [construct('Inner', [left]), right])
    checked.validate(outer, product(two,two), bits)
    try: checked.validate(outer, product(two,stop), bits)
    except RefinementViolation: pass
    else: raise AssertionError('accepted invalid intrinsic record guard without parent')
    validated = checked.validate(wrapper, good, bits)
    assert validated.tag == "Wrap"
    assert checked._index_of(wrapper, validated, 0) == 2
    assert checked._index_of(wrapper, good, 0) == 2
    assert checked._index_of(wrapper, good, 1) == 12
    for bad in (wrapped(two,next_(stop)),wrapped(stop,stop)):
        try: checked.validate(wrapper, bad, bits)
        except RefinementViolation: pass
        else: raise AssertionError('accepted mismatched or underflowing indices')
    for path in ('p0/1/0.0', 'p0/9.0', 'p0/-1.0'):
        try: schema(path).validate(wrapper, good, bits)
        except (ValueError, IndexError): pass
        else: raise AssertionError('accepted malformed or nominal field path')
print('index path conformance: Python, both widths')
