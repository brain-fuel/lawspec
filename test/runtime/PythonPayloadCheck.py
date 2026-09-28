"""Independent runtime checks for recursive parameter traversal."""

import unittest

import lawspec_runtime as ls
from lawspec_schema import Constructor, Definition, Field, Named, Parameter
from lawspec_schema import Schema


def variant(tag, *fields, predicates=()):
    return Constructor(tag, tuple(Field(name, ty) for name, ty in fields),
                       type(tag.replace('::', '_'), (), {}), predicates)


def data(tag, *fields):
    return ls.DataValue(tag, fields)


INT = Named('Int8')
A, B = Parameter(0), Parameter(1)
TREE = Named('Tree', (INT,))


class PayloadChecks(unittest.TestCase):
    def setUp(self):
        self.schema = Schema([
            Definition('Tree', 1, (
                variant('Tree::Leaf', ('value', A), ('fixed', INT)),
                variant('Tree::Node', ('child', Named('Tree', (A,)))),
                variant('Tree::Forest',
                        ('children', Named('List', (Named('Tree', (A,)),)))),
            )),
            Definition('Pair', 2, (
                variant('Pair::Pair', ('first', A), ('second', B)),
            )),
            Definition('Nest', 1, (
                variant('Nest::Stop', ('value', A)),
                variant('Nest::Next',
                        ('child', Named('Nest', (Named('List', (A,)),)))),
            )),
            Definition('Wrapped', 1, (variant(
                'Wrapped::Wrap', ('value', Named('Nullable', (
                    Named('Optional', (Named('List', (A,)),)),)))),)),
            Definition('Phantom', 1, (variant('Phantom::Tag'),)),
            Definition('MutA', 2, (
                variant('MutA::End', ('value', A)),
                variant('MutA::Next', ('child', Named('MutB', (B, A)))),
            )),
            Definition('MutB', 2, (
                variant('MutB::End', ('value', A)),
                variant('MutB::Next', ('child', Named('MutA', (B, A)))),
            )),
        ], ['Int8', 'Bool'])

    def check(self, reference, value, *predicates):
        return self.schema.all_payloads(reference, value, predicates)

    def test_recursive_leaves_and_fixed_fields(self):
        def leaf(value):
            return data('Tree::Leaf', value, -128)

        for bits in (32, 64):
            for number, expected in ((1, True), (0, False)):
                value = leaf(number)
                for _ in range(40):
                    value = data('Tree::Forest', [value])
                self.assertEqual(self.schema.all_payloads(
                    TREE, value, [lambda item: item > 0], bits), expected)

    def test_distinct_roles_at_identical_concrete_types(self):
        reference = Named('Pair', (INT, INT))
        for first, second, expected in ((1, -1, True), (-1, 1, False),
                                        (1, 1, False)):
            self.assertEqual(self.check(
                reference, data('Pair::Pair', first, second),
                lambda value: value > 0, lambda value: value < 0), expected)

    def test_mutually_recursive_parameter_permutations(self):
        reference = Named('MutA', (INT, INT))
        self.assertTrue(self.check(
            reference, data('MutA::Next', data('MutB::End', -1)),
            lambda value: value > 0, lambda value: value < 0))
        self.assertFalse(self.check(
            reference, data('MutA::Next', data('MutB::End', 1)),
            lambda value: value > 0, lambda value: value < 0))

    def test_growing_arguments(self):
        reference = Named('Nest', (INT,))
        for values, expected in (([[1], [2]], True), ([[1], [0]], False)):
            stop = data('Nest::Stop', values)
            value = data('Nest::Next', data('Nest::Next', stop))
            self.assertEqual(self.check(reference, value,
                                        lambda item: item > 0), expected)

    def test_presence_sums_and_empty_storage(self):
        def unused(_):
            self.fail('unstored callback executed')

        self.assertTrue(self.check(Named('Phantom', (INT,)),
                                   data('Phantom::Tag'), unused))
        self.assertTrue(self.check(TREE, data('Tree::Forest', []), unused))
        self.assertTrue(self.check(Named('Maybe', (INT,)),
                                   data('Maybe::Nothing'), unused))
        self.assertTrue(self.check(Named('Either', (INT, INT)),
                                   data('Either::Right', 2), unused,
                                   lambda value: value == 2))
        reference = Named('Tree', (Named('Nullable', (
            Named('Optional', (INT,)),)),))
        for presence in (ls.Presence('Nullable', False, None),
                         ls.Presence('Nullable', True,
                                     ls.Presence('Optional', False, None))):
            # The callback sees the whole declared argument.
            self.assertTrue(self.check(
                reference, data('Tree::Leaf', presence, 0),
                lambda value: isinstance(value, ls.Presence)))
        for name in ('Nullable', 'Optional'):
            self.assertTrue(self.check(Named(name, (INT,)),
                                       ls.Presence(name, False, None), unused))
            self.assertTrue(self.check(Named(name, (INT,)),
                                       ls.Presence(name, True, 1),
                                       lambda value: value == 1))

    def test_nested_presence_traversal_preserves_parameter_origin(self):
        reference = Named('Wrapped', (INT,))
        for values, expected in (([1, 2], True), ([1, 0], False)):
            value = data('Wrapped::Wrap', ls.Presence(
                'Nullable', True, ls.Presence('Optional', True, values)))
            self.assertEqual(self.check(reference, value,
                                        lambda item: item > 0), expected)

    def test_short_circuit_and_contextual_faults(self):
        visited = []

        def predicate(value):
            visited.append(value)
            return value != 0

        value = data('Tree::Forest', [data('Tree::Leaf', 0, 0),
                                      data('Tree::Leaf', 2, 0)])
        self.assertFalse(self.check(TREE, value, predicate))
        self.assertEqual(visited, [0])
        with self.assertRaisesRegex(ValueError, r'Tree::Leaf.value:'):
            self.check(TREE, value, lambda item: 1 / item > 0)
        with self.assertRaisesRegex(ValueError, 'did not produce Bool'):
            self.check(TREE, data('Tree::Leaf', 1, 0), lambda _: 1)

    def test_constructor_contracts_run_before_payload_callbacks(self):
        schema = Schema([Definition('Checked', 1, (
            variant('Checked::Value', ('value', A), predicates=(
                lambda schema, types, fields, bits, symbols: fields[0] > 0,
            )),
        ))], ['Int8'])
        visited = []
        with self.assertRaisesRegex(ValueError, 'field refinement 1 failed'):
            schema.all_payloads(Named('Checked', (INT,)),
                                data('Checked::Value', 0),
                                [lambda item: visited.append(item) or True])
        self.assertEqual(visited, [])

    def test_validation_precedes_predicates(self):
        visited = []
        with self.assertRaises(ValueError):
            self.check(TREE, data('Tree::Leaf', 1, 128),
                       lambda item: visited.append(item) or True)
        self.assertEqual(visited, [])
        with self.assertRaisesRegex(ValueError, 'arity'):
            self.check(TREE, data('Tree::Leaf', 1, 0))
        with self.assertRaisesRegex(ValueError, 'data type'):
            self.check(INT, 1)
        with self.assertRaisesRegex(TypeError, 'callable'):
            self.check(TREE, data('Tree::Leaf', 1, 0), False)


if __name__ == '__main__':
    unittest.main()
