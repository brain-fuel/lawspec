"""Shared scalar fixtures and schema-aware recordings. ref:REQ-law-primitives"""
import json
import os
from pathlib import Path
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'runtime'))
import lawspec_runtime as ls
from lawspec_schema import Schema, Definition, Constructor, Field, Named, Parameter


def forbidden(*args):
    raise AssertionError('recording must not rerun a predicate or codec')


def check(folder, key, expected, run):
    file = folder / key
    os.environ.pop('LAWSPEC_UPDATE_RECORDED', None)
    try:
        run()
    except AssertionError as error:
        assert 'no recording' in str(error)
    else:
        raise AssertionError('missing recording passed')
    assert not file.exists()
    os.environ['LAWSPEC_UPDATE_RECORDED'] = '1'
    assert run() is True
    assert file.read_bytes() == (expected + '\n').encode('utf8')
    os.environ.pop('LAWSPEC_UPDATE_RECORDED')
    assert run() is True
    file.write_text('stale\n')
    try:
        run()
    except AssertionError as error:
        assert 'differs' in str(error)
    else:
        raise AssertionError('stale recording passed')
    assert file.read_text() == 'stale\n'


rows = json.loads((root / 'test/fixtures/recorded-values.json').read_text())
previous = {key: os.environ.get(key) for key in ('LAWSPEC_RECORDED', 'LAWSPEC_UPDATE_RECORDED')}
try:
    with tempfile.TemporaryDirectory(prefix='recorded-python-', dir=root / '.artifacts') as directory:
        folder = Path(directory)
        os.environ['LAWSPEC_RECORDED'] = directory
        for row in rows:
            value, reference = ls.literal(row['scalar']), row.get('type', row['scalar']['type'])
            assert ls.recorded_text(value, reference) == row['text'], row['name']
            check(folder, row['name'], row['text'], lambda: ls.helper('recorded', [row['name'], value], ['Text', reference]))
        schema = Schema([
            Definition('Pair', 2, [Constructor('Pair::Pair', [Field('a', Parameter(0)), Field('b', Parameter(1))], type('Pair', (), {}), [forbidden])]),
            Definition('Box', 0, [Constructor('Box::Box', [Field('value', Parameter(0)), Field('witness', Named('Text'))], type('Box', (), {}), [forbidden], existentials=1, witnesses=[0])]),
            Definition('Fixed', 1, [Constructor('Fixed::Bytes', [Field('value', Parameter(0))], type('Fixed', (), {}), [forbidden], refinements=[(0, Named('Bytes'))])]),
        ], ['Bytes', 'Char', 'Text', 'Symbol'])
        examples = [
            ('pair', Named('Pair', [Named('Bytes'), Named('Char')]), ls.DataValue('Pair::Pair', [bytes([0, 255]), '雪']), 'Pair(bytes([0, 255]), "雪")'),
            ('witness', Named('Box'), ls.DataValue('Box::Box', [bytes([255]), 'Bytes']), 'Box(bytes([255]), "Bytes")'),
            ('gadt', Named('Fixed', [Named('Bytes')]), ls.DataValue('Fixed::Bytes', [bytes([255])]), 'Bytes(bytes([255]))'),
        ]
        for key, reference, value, expected in examples:
            assert schema.recorded_text(reference, value) == expected
            check(folder, key, expected, lambda: schema.recorded(reference, key, value))
        a, b = ls.Symbol('same'), ls.Symbol('same')
        assert ls.recorded_text([a, b, a], 'List Symbol') == '[symbol(1, "same"), symbol(2, "same"), symbol(1, "same")]'
        assert ls.recorded_text(b, 'Symbol') == 'symbol(1, "same")'
        ls.handle(42, 'Worker')
        ls.handle('same', 'Worker')
        assert ls.recorded_text(42, 'Integer') == '42'
        assert ls.recorded_text('same', 'Text') == '"same"'
        assert ls.recorded_text(b, 'Symbol') == 'symbol(1, "same")'
        assert ls.recorded_text(42, 'Worker') == 'Worker#1'
        print(f'{len(rows)} scalar and {len(examples)} schema recording checks passed (Python)')
finally:
    for key, value in previous.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value
