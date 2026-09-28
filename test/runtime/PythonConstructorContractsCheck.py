"""Native field contracts, identity, generation and shrinking."""

from dataclasses import dataclass
from fractions import Fraction
import unittest

from hypothesis import find, given, settings
from hypothesis import strategies as st

import lawspec_data_strategies as generators
import lawspec_runtime as ls
import lawspec_schema as schema


@dataclass(frozen=True)
class Gap:
    first: int
    second: int


@dataclass(frozen=True)
class Box:
    value: object


def gap_schema(predicates=None, primitive="Int8"):
    if predicates is None:
        predicates = [lambda registry, types, fields, bits, symbols:
                      fields[1] > fields[0]]
    return schema.Schema([schema.Definition("Gap", 0, [schema.Constructor(
        "Gap::Gap", [schema.Field("first", schema.Named(primitive)),
                     schema.Field("second", schema.Named(primitive))],
        Gap, predicates)])], [primitive])


def gap(first, second):
    return ls.DataValue("Gap::Gap", (first, second))


class ConstructorContractsTests(unittest.TestCase):

    def test_all_entry_points_enforce_fields_at_both_widths(self):
        registry = gap_schema()
        ty = schema.Named("Gap")
        for bits in (32, 64):
            logical = gap(-128, 127)
            self.assertTrue(registry.equal(
                ty, registry.validate(ty, logical, bits), logical, bits))
            native = registry.to_native(ty, logical, bits)
            self.assertEqual(native, Gap(-128, 127))
            self.assertTrue(registry.equal(
                ty, registry.from_native(ty, native, bits), logical, bits))
            self.assertEqual(registry.match(ty, logical, [
                ("Gap::Gap", lambda first, second:
                 Fraction(1, second - first))], bits), Fraction(1, 255))
            self.assertTrue(registry.equal(ty, logical, logical, bits))
            invalid = gap(127, -128)
            attempts = [
                lambda: registry.validate(ty, invalid, bits),
                lambda: registry.to_native(ty, invalid, bits),
                lambda: registry.from_native(ty, Gap(127, -128), bits),
                lambda: registry.construct(ty, "Gap::Gap", [127, -128], bits),
                lambda: registry.match(ty, invalid, [], bits),
                lambda: registry.equal(ty, invalid, invalid, bits),
            ]
            for attempt in attempts:
                with self.assertRaisesRegex(ValueError, "refinement 1 failed"):
                    attempt()

    def test_false_predicate_stops_before_partial_successor(self):
        seen = []

        def guarded(registry, types, fields, bits, symbols):
            seen.append(fields)
            return Fraction(1, fields[1] - fields[0]) > 0

        registry = gap_schema([
            lambda registry, types, fields, bits, symbols:
            fields[1] > fields[0], guarded])
        with self.assertRaisesRegex(ValueError, "refinement 1 failed"):
            registry.validate(schema.Named("Gap"), gap(0, 0))
        self.assertEqual(seen, [])
        registry.validate(schema.Named("Gap"), gap(-128, 127))
        self.assertEqual(seen, [(-128, 127)])

    def test_shape_validation_precedes_predicates(self):
        seen = []
        registry = gap_schema([
            lambda *args: seen.append(args) or True], "IntSize")
        ty = schema.Named("Gap")
        with self.assertRaises(ValueError):
            registry.validate(ty, gap(0, 2**32), 32)
        self.assertEqual(seen, [])
        registry.validate(ty, gap(0, 2**32), 64)
        self.assertEqual(len(seen), 1)
        self.assertEqual(seen[0][3], 64)

    def test_checks_nested_native_and_logical_values(self):
        registry = gap_schema()
        ty = schema.Named("Optional", [schema.Named("List", [
            schema.Named("Maybe", [schema.Named("Gap")])])])
        native = ls.Presence("Optional", True, [schema.Just(Gap(2, 1))])
        with self.assertRaisesRegex(ValueError, r"List\[0\].*refinement"):
            registry.from_native(ty, native)
        absent = ls.Presence("Optional", False)
        self.assertEqual(registry.from_native(ty, absent), absent)
        valid = ls.Presence("Optional", True, [schema.Just(Gap(1, 2))])
        logical = registry.from_native(ty, valid)
        self.assertEqual(registry.to_native(ty, logical).value[0].value,
                         Gap(1, 2))

    def test_generic_callback_receives_instantiated_type_arguments(self):
        calls = []

        def nonempty(registry, types, fields, bits, symbols):
            calls.append((types, bits))
            return len(fields[0]) > 0

        registry = schema.Schema([schema.Definition("Box", 1, [
            schema.Constructor("Box::Box", [schema.Field(
                "value", schema.Named("List", [schema.Parameter(0)]))],
                Box, [nonempty])])], ["Int8", "Text"])
        for primitive, item in (("Int8", 1), ("Text", "x")):
            ty = schema.Named("Box", [schema.Named(primitive)])
            registry.from_native(ty, Box([item]), 32)
            self.assertEqual(calls[-1], ((schema.Named(primitive),), 32))
            with self.assertRaisesRegex(ValueError, "refinement 1 failed"):
                registry.from_native(ty, Box([]), 32)

    def test_symbol_fixtures_share_only_the_supplied_context(self):
        wire = {"type": "Symbol", "id": "fixture", "description": "same"}
        symbols = {}
        expected = ls.literal(wire, symbols)

        def identical(registry, types, fields, bits, context):
            return fields[0] is ls.literal(wire, context)

        registry = schema.Schema([schema.Definition("Box", 0, [
            schema.Constructor("Box::Box", [schema.Field(
                "value", schema.Named("Symbol"))], Box, [identical])])],
            ["Symbol"])
        ty = schema.Named("Box")
        logical = registry.from_native(ty, Box(expected), symbols=symbols)
        self.assertTrue(registry.equal(ty, logical, logical, symbols=symbols))
        self.assertIs(registry.to_native(
            ty, logical, symbols=symbols).value, expected)
        built = registry.construct(
            ty, "Box::Box", [expected], symbols=symbols)
        self.assertIs(registry.match(ty, built, [
            ("Box::Box", lambda item: item)], symbols=symbols), expected)
        nested = schema.Named("List", [ty])
        self.assertTrue(registry.equal(
            nested, [logical], [logical], symbols=symbols))
        self.assertIs(registry.from_native(
            nested, [Box(expected)], symbols=symbols)[0].fields[0], expected)
        with self.assertRaisesRegex(ValueError, "refinement 1 failed"):
            registry.from_native(ty, Box(ls.Symbol("same")), symbols=symbols)
        with self.assertRaisesRegex(ValueError, "refinement 1 failed"):
            registry.from_native(ty, Box(expected), symbols={})
        candidates = generators.strategy(
            registry, ty, 64, 2, lambda _: st.just(expected), symbols)
        witness = find(candidates, lambda _: True,
                       settings=settings(derandomize=True, database=None))
        self.assertIs(witness.fields[0], expected)

    def test_witnesses_seed_nested_symbol_identity(self):
        wire = {"type": "Symbol", "id": "fixture", "description": "same"}
        symbols = {}
        expected = ls.literal(wire, symbols)
        registry = schema.Schema([schema.Definition("Box", 0, [
            schema.Constructor("Box::Box", [schema.Field(
                "value", schema.Named("Symbol"))], Box, [
                lambda registry, types, fields, bits, context:
                fields[0] is ls.literal(wire, context)])])], ["Symbol"])
        ty = schema.Named("List", [schema.Named("Box")])
        seed = [ls.DataValue("Box::Box", (expected,))]
        candidates = generators.strategy(
            registry, ty, 64, 7, lambda _: st.text().map(ls.Symbol),
            symbols, witnesses=[seed])
        witness = find(candidates, lambda values: len(values) == 3,
                       settings=settings(derandomize=True, database=None))
        self.assertEqual(len(witness), 3)
        for value in witness:
            self.assertIs(value.fields[0], expected)
        with self.assertRaises(schema.RefinementViolation):
            generators.strategy(registry, ty, 64, 7,
                                lambda _: st.text().map(ls.Symbol), {},
                                witnesses=[seed])

    def test_witnesses_respect_budgets_and_retain_native_candidates(self):
        registry = gap_schema()
        ty = schema.Named("List", [schema.Named("Gap")])
        candidates = generators.strategy(
            registry, ty, 64, 4, lambda _: st.integers(0, 16),
            witnesses=[[gap(-128, 127), gap(-128, 127)]])

        @settings(max_examples=64, derandomize=True, database=None)
        @given(candidates)
        def check(values):
            self.assertLessEqual(len(values), 1)
            registry.validate(ty, values)

        check()
        witness = find(candidates,
                       lambda values: values and
                       0 <= values[0].fields[0] <= values[0].fields[1] <= 16
                       and values[0].fields[1] - values[0].fields[0] >= 6,
                       settings=settings(derandomize=True, database=None))
        self.assertEqual(witness[0].fields[1] - witness[0].fields[0], 6)
        with self.assertRaises(schema.RefinementViolation):
            generators.strategy(registry, ty, 64, 4,
                                lambda _: st.integers(-128, 127),
                                witnesses=[[gap(1, 0)]])

    def test_witness_traversal_preserves_container_tags(self):
        registry = gap_schema()
        integer = schema.Named("Int8")
        cases = [
            (schema.Named("Nullable", [integer]),
             ls.Presence("Nullable", True, 7)),
            (schema.Named("Optional", [integer]),
             ls.Presence("Optional", True, 7)),
            (schema.Named("Maybe", [integer]),
             ls.DataValue("Maybe::Just", (7,))),
            (schema.Named("Either", [integer, integer]),
             ls.DataValue("Either::Right", (7,))),
        ]
        for ty, seed in cases:
            candidates = generators.strategy(
                registry, ty, 64, 2, lambda _: st.nothing(),
                witnesses=[seed])
            witness = find(candidates,
                           lambda value: registry.equal(ty, value, seed),
                           settings=settings(derandomize=True, database=None))
            self.assertTrue(registry.equal(ty, witness, seed))

    def test_predicates_must_return_bool_and_report_arithmetic_errors(self):
        with self.assertRaisesRegex(ValueError, "did not produce Bool"):
            gap_schema([lambda *args: 1]).validate(
                schema.Named("Gap"), gap(0, 1))
        with self.assertRaisesRegex(ValueError, "refinement 1:"):
            gap_schema([lambda *args: 1 / 0]).validate(
                schema.Named("Gap"), gap(0, 1))
        with self.assertRaisesRegex(TypeError, "must be callable"):
            gap_schema([True])

    def test_generator_does_not_hide_predicate_evaluation_errors(self):
        registry = gap_schema([lambda *args: 1 / 0])
        candidates = generators.strategy(
            registry, schema.Named("Gap"), 64, 3, lambda _: st.just(1))
        with self.assertRaisesRegex(ValueError, "refinement 1:"):
            find(candidates, lambda _: True, settings=settings(
                max_examples=10, derandomize=True, database=None))
        nested = schema.Named("List", [schema.Named("Gap")])
        with self.assertRaises(schema.RefinementViolation):
            gap_schema().validate(nested, [gap(1, 0)])

    def test_impossible_prefixes_retry_the_whole_tuple(self):
        registry = gap_schema()
        candidates = generators.strategy(
            registry, schema.Named("Gap"), 64, 3,
            lambda _: st.sampled_from([127, -128]))
        witness = find(candidates, lambda _: True, settings=settings(
            max_examples=100, derandomize=True, database=None))
        self.assertEqual(witness.fields, (-128, 127))

    def test_native_generation_and_shrinking_keep_dependent_contracts(self):
        registry = gap_schema()
        ty = schema.Named("Gap")
        for bits in (32, 64):
            candidates = generators.strategy(
                registry, ty, bits, 3, lambda _: st.integers(-128, 127))

            @settings(max_examples=128, derandomize=True, database=None)
            @given(candidates)
            def check(value):
                registry.validate(ty, value, bits)
                self.assertGreater(value.fields[1], value.fields[0])

            check()
            visited = []

            def wide(value):
                registry.validate(ty, value, bits)
                visited.append(value)
                return value.fields[1] - value.fields[0] >= 6

            witness = find(candidates, wide, settings=settings(
                max_examples=500, derandomize=True, database=None))
            self.assertEqual(witness.fields[1] - witness.fields[0], 6)
            self.assertGreater(len(visited), 1)
            self.assertGreater(witness.fields[1], witness.fields[0])


if __name__ == "__main__":
    unittest.main()
