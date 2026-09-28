"""Generation and shrinking conformance for the shared data schema."""

import unittest

from hypothesis import find, given, settings
from hypothesis import strategies as st

import lawspec_data_strategies as generators
import lawspec_runtime as ls
import lawspec_schema as schema


def scalar(name):
    return {"Bool": st.booleans(), "Int8": st.integers(-128, 127),
            "Unit": st.just(ls.UNIT)}[name]


def nodes(value):
    if isinstance(value, ls.DataValue):
        return 1 + sum(map(nodes, value.fields))
    if isinstance(value, list):
        return 1 + sum(map(nodes, value))
    if isinstance(value, ls.Presence):
        return 1 + (nodes(value.value) if value.present else 0)
    return 1


def definition(name, fields):
    return schema.Definition(name, 0, [schema.Constructor(
        name + "::Make", [schema.Field("field" + str(i), ty)
                          for i, ty in enumerate(fields)], type(name, (), {}))])


class DataStrategyTests(unittest.TestCase):

    def test_uneven_fields_fit_exact_node_budget(self):
        definitions = [definition("Deep0", [])]
        for index in range(1, 6):
            definitions.append(definition(
                "Deep" + str(index), [schema.Named("Deep" + str(index - 1))]))
        definitions.append(definition("Uneven", [schema.Named("Deep5")] +
                                      [schema.Named("Bool")] * 9))
        registry = schema.Schema(definitions, ["Bool"])
        ty = schema.Named("Uneven")
        with self.assertRaises(ValueError):
            generators.strategy(registry, ty, 64, 15, scalar)

        @settings(max_examples=64, derandomize=True, database=None)
        @given(generators.strategy(registry, ty, 64, 16, scalar))
        def check(value):
            registry.validate(ty, value)
            self.assertEqual(nodes(value), 16)

        check()
        list_type = schema.Named("List", [schema.Named("Deep5")])
        witness = find(generators.strategy(registry, list_type, 64, 7, scalar),
                       bool, settings=settings(derandomize=True, database=None))
        registry.validate(list_type, witness)
        self.assertEqual(len(witness), 1)
        self.assertEqual(nodes(witness), 7)

    def test_native_length_shrinking_and_no_hidden_length_cap(self):
        registry = schema.Schema([], ["Unit"])
        ty = schema.Named("List", [schema.Named("Unit")])
        candidates = generators.strategy(registry, ty, 64, 10, scalar)

        def longer_than_four(value):
            registry.validate(ty, value)
            self.assertLessEqual(nodes(value), 10)
            return len(value) > 4

        witness = find(candidates, longer_than_four,
                       settings=settings(derandomize=True, database=None))
        self.assertEqual(len(witness), 5)

    def test_native_payload_shrinking_and_recursive_validity(self):
        tree = schema.Named("Tree")
        registry = schema.Schema([schema.Definition("Tree", 0, [
            schema.Constructor("Tree::Leaf", [schema.Field(
                "value", schema.Named("Int8"))], type("Leaf", (), {})),
            schema.Constructor("Tree::Branch", [schema.Field(
                "children", schema.Named("List", [tree]))],
                type("Branch", (), {})),
        ])], ["Int8"])

        def has_positive_leaf(value):
            registry.validate(tree, value)
            self.assertLessEqual(nodes(value), 32)
            if value.tag == "Tree::Leaf":
                return value.fields[0] > 0
            return any(has_positive_leaf(child) for child in value.fields[0])

        witness = find(generators.strategy(registry, tree, 64, 32, scalar),
                       has_positive_leaf,
                       settings=settings(derandomize=True, database=None))
        self.assertEqual(witness.tag, "Tree::Leaf")
        self.assertEqual(witness.fields, (1,))

    def test_empty_domains_absence_and_sum_costs(self):
        registry = schema.Schema([schema.Definition("Empty", 0, [])], ["Unit"])
        empty = schema.Named("Empty")
        with self.assertRaises(ValueError):
            generators.strategy(registry, empty, 64, 16, scalar)
        for name in ["Maybe", "Nullable", "Optional"]:
            ty = schema.Named(name, [empty])
            with self.assertRaises(ValueError):
                generators.strategy(registry, ty, 64, 0, scalar)
            witness = find(generators.strategy(registry, ty, 64, 1, scalar),
                           lambda value: True)
            registry.validate(ty, witness)
            self.assertEqual(nodes(witness), 1)
        either = schema.Named("Either", [empty, schema.Named("Unit")])
        with self.assertRaises(ValueError):
            generators.strategy(registry, either, 64, 1, scalar)
        witness = find(generators.strategy(registry, either, 64, 2, scalar),
                       lambda value: True)
        registry.validate(either, witness)
        self.assertEqual(witness.tag, "Either::Right")
        self.assertEqual(nodes(witness), 2)


if __name__ == "__main__":
    unittest.main()
