"""Application mappings preserve logical schemas and constructor contracts."""

from dataclasses import dataclass
import unittest

import lawspec_runtime as ls
import lawspec_schema as schema


@dataclass
class Node:
    value: object
    children: list


@dataclass(kw_only=True)
class NativeNode:
    descendants: list
    payload: object


def registry():
    return schema.Schema([
        schema.Definition("Node", 1, [schema.Constructor(
            "Node::Node", [
                schema.Field("value", schema.Parameter(0)),
                schema.Field("children", schema.Named("List", [
                    schema.Named("Node", [schema.Parameter(0)])])),
            ], Node)]),
    ], ["Int8", "Symbol"])


def bind(original):
    return original.with_native_bindings({
        "Node::Node": (NativeNode, ["payload", "descendants"]),
    })


class NativeBindingsTests(unittest.TestCase):
    def test_generic_recursion_and_original_schema_independence(self):
        canonical = registry()
        native = bind(canonical)
        ty = schema.Named("Node", [schema.Named("Int8")])
        value = ls.DataValue("Node::Node", [12, [
            ls.DataValue("Node::Node", [5, []]),
        ]])
        app = native.to_native(ty, value)
        self.assertIs(type(app), NativeNode)
        self.assertEqual(app.descendants[0].payload, 5)
        self.assertTrue(canonical.equal(
            ty, native.from_native(ty, app), value))
        self.assertIs(type(canonical.to_native(ty, value)), Node)
        with self.assertRaisesRegex(TypeError, "invalid native Node"):
            native.from_native(ty, Node(12, []))
        app.descendants[0].payload = 128
        with self.assertRaisesRegex(ValueError, "Node::Node.children"):
            native.from_native(ty, app)

    def test_symbol_identity_survives_native_mapping(self):
        native = bind(registry())
        ty = schema.Named("Node", [schema.Named("Symbol")])
        symbol = ls.Symbol("same description")
        value = ls.DataValue("Node::Node", [symbol, []])
        result = native.from_native(ty, native.to_native(ty, value))
        self.assertIs(result.fields[0], symbol)

    def test_native_field_mapping_keeps_predicate_order(self):
        positive = schema.Schema([
            schema.Definition("Node", 0, [schema.Constructor(
                "Node::Node", [schema.Field("value", schema.Named("Int8")),
                               schema.Field("children", schema.Named(
                                   "List", [schema.Named("Int8")]))],
                Node, [lambda registry, args, fields, bits, symbols:
                       fields[0] > 0])]),
        ], ["Int8"])
        native = bind(positive)
        with self.assertRaisesRegex(
                schema.RefinementViolation, "Node::Node: field refinement"):
            native.from_native(schema.Named("Node"), NativeNode(
                payload=-1, descendants=[]))

    def test_invalid_bindings_fail_at_registration(self):
        canonical = registry()
        for fields in [[], ["payload"], ["payload", "payload"]]:
            with self.assertRaisesRegex(ValueError, "native field mapping"):
                canonical.with_native_bindings({
                    "Node::Node": (NativeNode, fields),
                })
        with self.assertRaisesRegex(ValueError, "unknown native constructor"):
            canonical.with_native_bindings({
                "Unknown": (NativeNode, ["payload", "descendants"]),
            })
        with self.assertRaisesRegex(TypeError, "must be a class"):
            canonical.with_native_bindings({
                "Node::Node": (lambda **fields: fields,
                               ["payload", "descendants"]),
            })


if __name__ == "__main__":
    unittest.main()
