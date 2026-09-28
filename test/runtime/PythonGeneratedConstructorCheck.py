"""Execute emitted field predicates and public native definitions."""

from fractions import Fraction
import sys

import lawspec_data as data
import lawspec_runtime as ls
import lawspec_schema as schema
from lawspec_definitions.native import fields


def rejected(action, message="field refinement"):
    try:
        action()
    except ValueError as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError("invalid field value was accepted")


def pure_checks(bits):
    assert "hypothesis" not in sys.modules
    assert "pytest" not in sys.modules
    assert schema.type_key(schema.Named("Either", [
        schema.Named("List", [schema.Named("Int8")]), schema.Named("Text")
    ])) == "Either (List Int8) (Text)"
    assert schema.type_key(schema.Named("Pair", [
        schema.Named("List", [schema.Named("Int8")]), schema.Named("Text")
    ])) == "Pair (List (Int8)) (Text)"
    assert fields.inverseGap({}, data.GapGap(-128, 127)) == Fraction(1, 255)
    rejected(lambda: fields.inverseGap({}, data.GapGap(127, -128)))
    rejected(lambda: fields.inverseGap({}, data.GapGap(0, 0)))
    assert fields.echoBucket({}, data.BucketBucket([1])).values == [1]
    rejected(lambda: fields.echoBucket({}, data.BucketBucket([])))
    positive = fields.echoPositives({}, data.PositivesPositives([1, 2]))
    assert positive.values == [1, 2]
    rejected(lambda: fields.echoPositives({}, data.PositivesPositives([0])))
    assert fields.echoChoice({}, data.ChoiceRejected("no")).reason == "no"
    assert fields.echoChoice({}, data.ChoiceAccepted(1)).value == 1
    rejected(lambda: fields.echoChoice({}, data.ChoiceAccepted(0)))
    assert fields.echoGuarded({}, data.GuardedGuarded(2)).value == 2
    rejected(lambda: fields.echoGuarded({}, data.GuardedGuarded(0)))
    rejected(lambda: fields.echoGuarded({}, data.GuardedGuarded(-1)))
    assert fields.echoMachine({}, data.MachineMachine(1)).value == 1
    rejected(lambda: fields.echoMachine({}, data.MachineMachine(0)))
    if bits == 64:
        large = fields.echoMachine({}, data.MachineMachine(2**40))
        assert large.value == 2**40
    else:
        rejected(lambda: fields.echoMachine({}, data.MachineMachine(2**40)),
                 "IntSize")
    symbols = {}
    expected = ls.literal({"type": "Symbol", "id": "fixture",
                           "description": "same"}, symbols)
    assert fields.echoIdentity(
        symbols, data.IdentityIdentity(expected)).value is expected
    rejected(lambda: fields.echoIdentity(
        symbols, data.IdentityIdentity(ls.Symbol("same"))))
    rejected(lambda: fields.echoIdentity({}, data.IdentityIdentity(expected)))
    registry = data.make_schema()
    ref = schema.Named("List", [schema.Named("native.fields::type::Identity")])
    logical = registry.from_native(ref, [data.IdentityIdentity(expected)],
                                   bits, symbols)
    assert registry.equal(ref, logical, logical, bits, symbols)
    assert registry.to_native(ref, logical, bits, symbols)[0].value is expected


def generation_checks(bits):
    from hypothesis import find, given, settings
    from hypothesis import strategies as st

    from lawspec_data_strategies import strategy

    registry = data.make_schema()
    ref = schema.Named("native.fields::type::Gap")
    candidates = strategy(registry, ref, bits, 3,
                          lambda _: st.integers(-128, 127))

    @settings(max_examples=100, derandomize=True, database=None)
    @given(candidates)
    def check(value):
        first, second = value.fields
        assert second > first
        native = registry.to_native(ref, value, bits)
        assert fields.inverseGap({}, native) == Fraction(1, second - first)

    check()

    def wide(value):
        registry.validate(ref, value, bits)
        return value.fields[1] - value.fields[0] >= 6

    witness = find(candidates, wide,
                   settings=settings(derandomize=True, database=None))
    assert witness.fields[1] - witness.fields[0] == 6

    symbols = {}
    expected = ls.literal({"type": "Symbol", "id": "fixture",
                           "description": "same"}, symbols)
    ref = schema.Named("List", [schema.Named("native.fields::type::Identity")])
    seed = registry.from_native(ref, [data.IdentityIdentity(expected)],
                                bits, symbols)
    identities = strategy(registry, ref, bits, 7,
                          lambda _: st.text().map(ls.Symbol), symbols,
                          witnesses=[seed])
    witness = find(identities, lambda values: len(values) == 3,
                   settings=settings(derandomize=True, database=None))
    for native in registry.to_native(ref, witness, bits, symbols):
        assert fields.echoIdentity(symbols, native).value is expected


if __name__ == "__main__":
    width = int(sys.argv[1])
    pure_checks(width)
    generation_checks(width)
    print(f"Generated constructor predicates and native APIs passed: {width}")
