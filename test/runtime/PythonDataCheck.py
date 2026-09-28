"""Native data and schema conformance without a property framework."""

import dataclasses
import unittest

import lawspec_data as data
import lawspec_runtime as ls
import lawspec_schema as schema


class NativeDataTests(unittest.TestCase):

    def setUp(self):
        self.schema = data.make_schema()
        self.tree = schema.Named("Tree", [schema.Named("Int8")])
        self.pair = schema.Named("Pair", [schema.Named("Text")])

    def test_recursive_native_values_round_trip_and_copy_lists(self):
        source = ls.DataValue("ctor::Branch", [[
            ls.DataValue("ctor::Leaf", [127]),
            ls.DataValue("ctor::Branch", [[]]),
        ]])
        native = self.schema.to_native(self.tree, source)
        self.assertIs(type(native), data.TreeBranch)
        self.assertIs(type(native.children[0]), data.TreeLeaf)
        self.assertEqual(native.children[0].value, 127)
        restored = self.schema.from_native(self.tree, native)
        self.assertTrue(self.schema.equal(self.tree, source, restored))
        native.children.clear()
        self.assertEqual(len(source.fields[0]), 2)
        self.assertEqual(len(restored.fields[0]), 2)
        with self.assertRaises(dataclasses.FrozenInstanceError):
            native.children = []

    def test_native_pattern_matching_exposes_typed_fields(self):
        value = self.schema.to_native(
            self.tree, ls.DataValue("ctor::Leaf", [-128]))
        match value:
            case data.TreeLeaf(value=payload):
                self.assertEqual(payload, -128)
            case _:
                self.fail("wrong native variant")

    def test_arbitrary_unsigned_integer_and_supplementary_text(self):
        native = data.PairPair("\U0001f642", 2**64 - 1)
        value = self.schema.from_native(self.pair, native)
        restored = self.schema.to_native(self.pair, value)
        self.assertEqual(restored.first, native.first)
        self.assertEqual(restored.second, native.second)
        with self.assertRaisesRegex(ValueError, "ctor::Pair.second"):
            self.schema.from_native(self.pair, data.PairPair("ok", -1))

    def test_raw_units_and_bytes_remain_lossless(self):
        for scalar, payload in [
            ("CodeUnit16", 0xd800),
            ("CodePoint", 0xdfff),
            ("Bytes", bytes([0, 128, 255])),
            ("Utf16Text", ls.Raw("Utf16Text", [0xd800, 0, 0xdc00])),
            ("CodePointText", ls.Raw("CodePointText", [0xd800, 0x1f642])),
        ]:
            ty = schema.Named("Tree", [schema.Named(scalar)])
            logical = self.schema.from_native(ty, data.TreeLeaf(payload))
            native = self.schema.to_native(ty, logical)
            self.assertEqual(native.value, payload)
        with self.assertRaisesRegex(ValueError, "ctor::Leaf.value"):
            self.schema.from_native(
                schema.Named("Tree", [schema.Named("Text")]),
                data.TreeLeaf("\ud800"))

    def test_nested_algebraic_and_interoperability_absence(self):
        ty = schema.Named("Choice", [schema.Named("Bool")])
        absent = self.schema.from_native(
            ty, data.ChoiceChoose(schema.Left(schema.Nothing())))
        present = self.schema.from_native(
            ty, data.ChoiceChoose(schema.Left(schema.Just(False))))
        right = self.schema.from_native(
            ty, data.ChoiceChoose(schema.Right(data.PairPair("x", 7))))
        self.assertFalse(self.schema.equal(ty, absent, present))
        self.assertFalse(self.schema.equal(ty, absent, right))
        restored = self.schema.to_native(ty, present)
        self.assertIs(type(restored.value), schema.Left)
        self.assertIs(type(restored.value.value), schema.Just)
        self.assertIs(restored.value.value.value, False)
        presence = schema.Named("Tree", [schema.Named("Nullable", [
            schema.Named("Optional", [schema.Named("Int8")])])])
        nested = data.TreeLeaf(ls.Presence(
            "Nullable", True, ls.Presence("Optional", False)))
        logical = self.schema.from_native(presence, nested)
        self.assertTrue(self.schema.to_native(presence, logical).value.present)
        self.assertFalse(self.schema.equal(presence, logical,
            self.schema.from_native(presence,
                                    data.TreeLeaf(ls.Presence("Nullable", False)))))

    def test_ieee_and_symbol_equality(self):
        floating = schema.Named("Tree", [schema.Named("Float64")])
        nan = self.schema.from_native(floating, data.TreeLeaf(float("nan")))
        self.assertFalse(self.schema.equal(floating, nan, nan))
        positive = self.schema.from_native(floating, data.TreeLeaf(0.0))
        negative = self.schema.from_native(floating, data.TreeLeaf(-0.0))
        self.assertTrue(self.schema.equal(floating, positive, negative))
        symbols = schema.Named("Tree", [schema.Named("Symbol")])
        first, second = ls.Symbol("same"), ls.Symbol("same")
        a = self.schema.from_native(symbols, data.TreeLeaf(first))
        b = self.schema.from_native(symbols, data.TreeLeaf(second))
        self.assertTrue(self.schema.equal(symbols, a, a))
        self.assertFalse(self.schema.equal(symbols, a, b))
        self.assertIs(self.schema.to_native(symbols, a).value, first)

    def test_contextual_rejections(self):
        bad = [ls.DataValue("foreign", []), ls.DataValue("ctor::Leaf", []),
               ls.DataValue("ctor::Leaf", [128]),
               ls.DataValue("ctor::Leaf", [True])]
        for value in bad:
            with self.assertRaises((TypeError, ValueError)):
                self.schema.to_native(self.tree, value)
        with self.assertRaisesRegex(ValueError, r"children: List\[0\].*value"):
            self.schema.from_native(
                self.tree, data.TreeBranch([data.TreeLeaf(128)]))
        with self.assertRaisesRegex(TypeError, "invalid native Tree"):
            self.schema.from_native(self.tree, data.PairPair("x", 1))
        for ty in [data.Tree, data.Empty, schema.Maybe, schema.Either]:
            with self.assertRaises(TypeError):
                ty()
        with self.assertRaises(ValueError):
            self.schema.validate(schema.Named("Empty", [schema.Named("Bool")]),
                                 ls.DataValue("invented", []))

    def test_match_evaluates_only_selected_branch(self):
        def forbidden():
            self.fail("unselected branch ran")
        result = self.schema.match(self.tree, ls.DataValue("ctor::Leaf", [9]), [
            ("ctor::Branch", forbidden), ("ctor::Leaf", lambda value: value + 1)])
        self.assertEqual(result, 10)

    def test_profile_and_metadata_validation(self):
        machine = schema.Named("Tree", [schema.Named("UIntSize")])
        value = data.TreeLeaf(2**32)
        with self.assertRaisesRegex(ValueError, "ctor::Leaf.value"):
            self.schema.from_native(machine, value, 32)
        self.assertEqual(self.schema.to_native(machine,
            self.schema.from_native(machine, value, 64), 64).value, 2**32)
        for bits in [0, 16, True]:
            with self.assertRaises(ValueError):
                self.schema.validate(self.tree, ls.DataValue("ctor::Leaf", [1]),
                                     bits)
        for field_type in [schema.Parameter(0), schema.Named("Unknown"),
                           schema.Named("List")]:
            with self.assertRaises(ValueError):
                schema.Schema([schema.Definition("Box", 0, [schema.Constructor(
                    "Box::Box", [schema.Field("value", field_type)],
                    data.TreeLeaf)])], ["Bool"])
        with self.assertRaises(ValueError):
            schema.Schema([schema.Definition("Bool", 0, [])], ["Bool"])


if __name__ == "__main__":
    unittest.main()
