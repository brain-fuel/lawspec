"""Native factories compose Hypothesis strategies without losing shrinking."""

from dataclasses import dataclass
import unittest

from hypothesis import find, settings, errors
from hypothesis import strategies as st

import lawspec_runtime as ls
import lawspec_schema as schema
from lawspec_data_strategies import strategy


@dataclass(kw_only=True)
class Wrapped:
    payload: int


def registry():
    return schema.Schema([schema.Definition("Box", 1, [schema.Constructor(
        "Box::Box", [schema.Field("payload", schema.Parameter(0))],
        Wrapped)])], ["Int8"])


class NativeGeneratorTests(unittest.TestCase):
    def empty_parameter_source(self, reference, factories):
        definitions = [
            schema.Definition("Empty", 0, []),
            schema.Definition("Phantom", 1, [schema.Constructor(
                "Phantom::Phantom",
                [schema.Field("payload", schema.Named("Int8"))], Wrapped)]),
        ]
        return strategy(schema.Schema(definitions, ["Int8"]), reference,
                        64, 32, lambda _: st.integers(-128, 127),
                        native_generators=factories)

    def test_unused_empty_parameter_does_not_block_native_factory(self):
        ty = schema.Named("Phantom", [schema.Named("Empty")])
        source = self.empty_parameter_source(ty, {
            "Phantom": lambda unused: st.builds(
                Wrapped, payload=st.integers(40, 100)),
        })
        minimum = find(source, lambda value: value.fields[0] >= 61)
        self.assertEqual(minimum.fields, (61,))

    def test_native_list_of_empty_retains_the_empty_list(self):
        ty = schema.Named("List", [schema.Named("Empty")])
        source = self.empty_parameter_source(ty, {"List": st.lists})
        self.assertEqual(find(source, lambda value: True), [])

    def test_demanding_an_empty_parameter_cannot_produce_a_sample(self):
        ty = schema.Named("Phantom", [schema.Named("Empty")])
        source = self.empty_parameter_source(ty, {
            "Phantom": lambda child: child.map(lambda _: Wrapped(0)),
        })
        with self.assertRaises(errors.Unsatisfiable):
            find(source, lambda value: True,
                 settings=settings(max_examples=5))

    def test_empty_root_still_has_no_generator(self):
        with self.assertRaisesRegex(ValueError, "no value of.*Empty"):
            self.empty_parameter_source(schema.Named("Empty"), {})

    def make(self, ty, factories, witnesses=()):
        return strategy(registry(), ty, 64, 32,
                        lambda name: st.integers(-128, 127),
                        witnesses=witnesses, native_generators=factories)

    def test_generic_child_strategy_shrinks_native_values(self):
        ty = schema.Named("Box", [schema.Named("Int8")])
        source = self.make(ty, {
            "Box": lambda child: st.builds(Wrapped, payload=child),
            "Int8": lambda: st.integers(40, 100),
        })
        minimum = find(source, lambda value: True)
        self.assertEqual(minimum.fields, (40,))
        larger = find(source, lambda value: value.fields[0] >= 61)
        self.assertEqual(larger.fields, (61,))

    def test_nested_custom_scalar_strategy(self):
        ty = schema.Named("List", [schema.Named("Int8")])
        source = self.make(ty, {"Int8": lambda: st.integers(40, 100)})
        self.assertEqual(find(source, lambda value: len(value) >= 2), [40, 40])

    def test_invalid_samples_fail_instead_of_being_filtered(self):
        source = self.make(schema.Named("Int8"), {
            "Int8": lambda: st.just(True),
        })
        with self.assertRaisesRegex(ValueError, "native generator Int8"):
            find(source, lambda value: True)

    def test_exhaustion_does_not_fall_back_to_witness(self):
        source = self.make(schema.Named("Int8"),
                           {"Int8": lambda: st.nothing()}, witnesses=[42])
        with self.assertRaises(errors.Unsatisfiable):
            find(source, lambda value: True, settings=settings(max_examples=5))

    def test_factory_must_return_a_native_strategy(self):
        with self.assertRaisesRegex(TypeError, "must return a strategy"):
            self.make(schema.Named("Int8"), {"Int8": lambda: [42]})


if __name__ == "__main__":
    unittest.main()
