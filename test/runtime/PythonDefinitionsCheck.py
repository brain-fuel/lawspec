"""Standalone checks: generated source must not import a testing framework."""
import sys
from decimal import Decimal, localcontext

import lawspec_data as data
import lawspec_runtime as ls
import lawspec_schema as schema
from lawspec_definitions.example import total
from lawspec_definitions import other

bits = int(sys.argv[1])
symbols = {}
assert total.size(symbols, []) == 0
assert total.forward(symbols, [1, 2, 3]) == 3
assert total.sumList(symbols, [127, 127]) == 254
assert total.increment(symbols, 127) == 128
assert not total.divisible(symbols, 5, 0)
assert total.divisible(symbols, -6, 3)
assert not total.divisible(symbols, -5, 3)
assert total.sumTree(symbols, data.TreeBranch(data.TreeLeaf(127), data.TreeLeaf(127))) == 254
assert other.size(symbols, True)
assert other.str(symbols, 1) == 1
assert other.pairCount(symbols, [data.PairPair(127, True)]) == 1
try:
    other.str(symbols, True)
except ValueError as error:
    assert 'other::str:' in str(error)
else:
    raise AssertionError('shadowed builtin bypassed validation')
assert total.maybeDefault(symbols, schema.Nothing()) == 0
assert total.maybeDefault(symbols, schema.Just(127)) == 127
raw = [0xD800, 0xDC00, 0xFFFF]
copied = total.raw(symbols, raw)
assert copied == raw and copied is not raw
raw[0] = 0
assert copied[0] == 0xD800
for value in (
    ls.Presence('Optional', False),
    ls.Presence('Optional', True, ls.Presence('Nullable', False)),
    ls.Presence('Optional', True, ls.Presence('Nullable', True, 127)),
):
    actual = total.absent(symbols, value)
    assert ls.equal(actual, value, 'Optional Nullable Int8', 'Optional Nullable Int8')
assert total.symbol(symbols, ls.UNIT) is total.symbol(symbols, ls.UNIT)
assert total.symbol({}, ls.UNIT) is not total.symbol({}, ls.UNIT)
with localcontext() as context:
    context.prec = 1
    assert total.exact(symbols, Decimal('0.123')) == Decimal('0.323')
assert total.either(symbols, schema.Left(127)).value == 127
assert total.either(symbols, schema.Right(True)).value is True
maximum = 2 ** (bits - 1) - 1
assert total.machine(symbols, maximum) == maximum
assert isinstance(total.architecture(symbols, data.ArchitectureUnused()), data.ArchitectureUnused)
assert total.architecture(symbols, data.ArchitectureNative(maximum)).size == maximum
for method, value in (
    (total.machine, maximum + 1),
    (total.architecture, data.ArchitectureNative(maximum + 1)),
    (total.increment, True),
    (total.increment, 128),
    (total.size, ['wrong']),
    (total.sumTree, True),
    (total.maybeDefault, schema.Just(True)),
    (total.absent, ls.Presence('Optional', True, True)),
):
    try:
        method(symbols, value)
    except ValueError as error:
        assert 'example.total::' + method.__name__ in str(error), str(error)
    else:
        raise AssertionError('invalid native value accepted: ' + method.__name__)
assert 'hypothesis' not in sys.modules
assert 'pytest' not in sys.modules
print(f'Python standalone definition calls passed: {bits}')
