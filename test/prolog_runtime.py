"""Independent Janus boundary controls for the public Prolog backend.

Run with the supported Python/Janus environment:
PYTHONPATH=runtime .tools/prolog-janus/bin/python test/prolog_runtime.py
This tests execution and conversion infrastructure, not provider fidelity or proof.
ref:DEC-prolog-janus
"""
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from decimal import Decimal, localcontext
from fractions import Fraction
from pathlib import Path
import asyncio
import contextvars
import gc
import struct
import sys
import tempfile
import types
import unittest
import weakref
from unittest.mock import patch
from threading import Event, Lock, Thread

import lawspec_prolog as bridge
import lawspec_runtime as ls
import lawspec_schema as schema


@dataclass(frozen=True)
class Box:
    value: int


@dataclass(frozen=True)
class Oops:
    message: str


@dataclass(frozen=True)
class Envelope:
    inner: Box
    label: str


@dataclass(frozen=True)
class Ready:
    pass


BOX = 'example::type::Box'
ERROR = 'errors::type::Error'
SCHEMA = schema.Schema([
    schema.Definition(BOX, 0, (
        schema.Constructor('example::Box', (
            schema.Field('value', schema.Named('UInt8')),), Box),)),
    schema.Definition(ERROR, 0, (
        schema.Constructor('errors::Oops', (
            schema.Field('message', schema.Named('Text')),), Oops),)),
    schema.Definition('example::Handle', 0, (), handle=True),
    schema.Definition('example::OtherHandle', 0, (), handle=True),
    schema.Definition('example::Ready', 0, (
        schema.Constructor('example::Ready::Ready', (), Ready),)),
    schema.Definition('example::Envelope', 0, (
        schema.Constructor('example::Envelope::Envelope', (
            schema.Field('inner', schema.Named(BOX)),
            schema.Field('label', schema.Named('Text'))), Envelope),)),
], ['UInt8', 'UIntSize', 'Bool', 'Text', 'Char', 'Bytes', 'Rational',
    'Decimal', 'Float32', 'Float64', 'Complex128', 'Utf16Text', 'CodePointText',
    'Unit', 'Null', 'Undefined', 'BigInt', 'Symbol'])


class PrologRuntime(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        bridge.janus.consult(str(Path(__file__).parent / 'fixtures/prolog/bridge.pl'))

    def call(self, predicate, value, ty, bits=64, failure=None):
        return bridge.call(SCHEMA, bits, 'lawspec_bridge_test', predicate,
                           [ty], ty, [value], failure)

    def test_module_loading_keeps_equal_exports_qualified(self):
        with tempfile.TemporaryDirectory() as directory:
            for index, name in enumerate(('fixture_loader_first', 'fixture_loader_second')):
                path = Path(directory) / (name + '.pl')
                path.write_text(':- module(' + name + ', [loader_collision/1]).\n'
                                'loader_collision(' + str(index) + ').\n')
                bridge.load_module(path)
                result = bridge.janus.query_once(name + ':loader_collision(Value)')
                self.assertIs(result['truth'], True)
                self.assertEqual(result['Value'], index)
            self.assertIs(bridge.janus.query_once(
                'current_predicate(user:loader_collision/1)')['truth'], False)

    def test_false_is_a_returned_value(self):
        self.assertIs(self.call('false_value', True, schema.Named('Bool')), False)

    def native_bindings(self):
        return [[['example::Box', 'fixtures.native.Box', 'record', ['amount'], [['leaf', 0]]],
                 ['example::Envelope::Envelope', 'fixtures.native.Envelope', 'variant',
                  ['label', 'amount'], [['record', 'example::Box', [['leaf', 1]]], ['leaf', 0]]],
                 ['example::Ready::Ready', 'fixtures.native.Ready', 'unit', [], []]],
                [['example::Handle', 'fixtures.native.Handle'], ['example::OtherHandle', 'fixtures.native.Other']],
                [['fixtures.native.Refused', 'errors::Oops', ['message']]]]

    def test_native_records_and_resolved_nested_argument_layouts(self):
        for value, ty, predicate in [(Box(7), BOX, 'bound_box'),
                                      (Envelope(Box(7), 'label'), 'example::Envelope', 'bound_envelope'),
                                      (Ready(), 'example::Ready', 'identity')]:
            with self.subTest(ty=ty):
                self.assertEqual(bridge.call(SCHEMA, 64, 'lawspec_bridge_test', predicate,
                    [schema.Named(ty)], schema.Named(ty), [value], bindings=self.native_bindings()), value)
        for predicate in ['bound_bad_box', 'bound_counterfeit']:
            with self.subTest(predicate=predicate), self.assertRaises((ValueError, TypeError, bridge.janus.PrologError)):
                bridge.call(SCHEMA, 64, 'lawspec_bridge_test', predicate, [schema.Named(BOX)],
                            schema.Named(BOX), [Box(7)], bindings=self.native_bindings())

    def test_native_records_cross_explicit_handler_proxies(self):
        class Ledger:
            def add(self, box):
                self_type.assertIs(type(box), Box)
                return Box(box.value + 1)

        self_type = self
        ty = schema.Named(BOX)
        handler = bridge.Handler(SCHEMA, 64, 'Ledger', Ledger(), {'add': ([ty], ty, None)})
        result = bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'bound_forward', [ty], ty, [Box(7)],
                             handlers=[handler], bindings=self.native_bindings())
        self.assertEqual(result, Box(8))

    def test_native_exception_mappings_keep_unmapped_errors_and_declared_failures_distinct(self):
        integer, error = schema.Named('UInt8'), schema.Named(ERROR)
        with self.assertRaises(ls.Fail) as raised:
            bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'bound_refused', [integer], integer, [7],
                        failure_type=error, bindings=self.native_bindings())
        self.assertEqual(raised.exception.value, Oops('negative'))
        with self.assertRaisesRegex(ValueError, 'undeclared failure'):
            bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'bound_refused', [integer], integer, [7],
                        bindings=self.native_bindings())
        with self.assertRaises(bridge.janus.PrologError):
            bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'bound_unmapped_error', [integer], integer, [7],
                        failure_type=error, bindings=self.native_bindings())

    def test_native_handle_constructors_methods_identity_and_type_checks(self):
        unit, handle = schema.Named('Unit'), schema.Named('example::Handle')
        config = self.native_bindings()
        first, second = [bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'bound_handle_new', [unit],
                          handle, [ls.UNIT], bindings=config, argument_order=[]) for _ in range(2)]
        self.assertIsNot(first, second)
        same = bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'bound_handle_echo', [handle], handle,
                           [first], bindings=config)
        self.assertIs(same, first)
        for amount, expected in [(7, 7), (8, 15)]:
            self.assertEqual(bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'bound_handle_add',
                [schema.Named('UInt8'), handle], schema.Named('UInt8'), [amount, first],
                bindings=config, argument_order=[1, 0]), expected)
        with self.assertRaisesRegex(TypeError, 'wrong native Prolog handle type'):
            bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'bound_handle_other', [], handle, [], bindings=config)

    def test_native_handle_interning_resolves_collisions_and_releases_references(self):
        original = bridge._query_once

        def collided(goal, arguments):
            return {'truth': True, 'Hash': 0} if goal == 'term_hash(Term,Hash)' else original(goal, arguments)

        def create():
            # Isolate the interner: Core's separate handle-label registry
            # deliberately retains handles registered through its schema.
            term = original('lawspec_bridge_test:bound_handle_new(_Value),Term=prolog(_Value)', {})['Term']
            return bridge._intern_native_handle('fixtures.native.Handle', term)

        with patch.object(bridge, '_query_once', collided):
            first, second = create(), create()
            self.assertIsNot(first, second)
            same = bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'bound_handle_echo',
                [schema.Named('example::Handle')], schema.Named('example::Handle'), [first],
                bindings=self.native_bindings())
            self.assertIs(same, first)
            observed = weakref.ref(second)
            del second
            gc.collect()
            self.assertIsNone(observed(), 'the interner added a strong reference')

    def test_async_workers_keep_context_results_and_exceptions(self):
        owner = contextvars.ContextVar('native_owner')
        owner.set('selected case')

        def native():
            self.assertEqual(owner.get(), 'selected case')
            return self.call('false_value', True, schema.Named('Bool'))

        self.assertIs(asyncio.run(bridge.call_async(native)), False)

        def failed():
            raise bridge.Incomplete('native worker declined')

        with self.assertRaisesRegex(bridge.Incomplete, 'native worker declined'):
            asyncio.run(bridge.call_async(failed))

    def test_cancelled_waiter_does_not_join_native_work_at_loop_exit(self):
        started, release, finished, loop_finished = Event(), Event(), Event(), Event()
        errors = []

        def native():
            started.set()
            release.wait(5)
            finished.set()
            return 7

        async def waiting():
            task = asyncio.create_task(bridge.call_async(native))
            while not started.is_set():
                await asyncio.sleep(0)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task

        def run_loop():
            try:
                asyncio.run(waiting())
            except BaseException as error:
                errors.append(error)
            finally:
                loop_finished.set()

        thread = Thread(target=run_loop, daemon=True)
        thread.start()
        try:
            self.assertTrue(started.wait(2))
            self.assertTrue(loop_finished.wait(1), 'loop exit joined a losing native task')
            self.assertFalse(finished.is_set())
        finally:
            release.set()
            thread.join(2)
        self.assertTrue(finished.wait(2))
        self.assertEqual(errors, [])

    def test_cancelled_waiter_consumes_a_late_worker_exception(self):
        started, release, failed = Event(), Event(), Event()

        def native():
            started.set()
            release.wait(5)
            failed.set()
            raise ValueError('losing native task')

        async def waiting():
            loop = asyncio.get_running_loop()
            unexpected = []
            loop.set_exception_handler(lambda _, context: unexpected.append(context))
            task = asyncio.create_task(bridge.call_async(native))
            try:
                while not started.is_set():
                    await asyncio.sleep(0)
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task
            finally:
                release.set()
            while not failed.is_set():
                await asyncio.sleep(0)
            await asyncio.sleep(0.02)
            self.assertEqual(unexpected, [])

        asyncio.run(waiting())

    def test_duplicate_network_replies_preserve_once_only_execution_and_closed_peers(self):
        for closed, bug in [(False, None), (True, None), (False, ValueError('transport defect'))]:
            with self.subTest(closed=closed, bug=bug):
                network = ls.MemoryNetwork(record=True)
                server = ls.Node(network.insecure_transport_for_tests('server'))
                client = ls.Node(network.insecure_transport_for_tests('client'))
                calls, errors, threads = [], [], []
                descriptor = ls.read_descriptor('(int Int32 -2147483648 2147483647)')[0]

                def increment(value):
                    calls.append(value)
                    return value + 1

                real_thread = Thread

                def tracked_thread(*args, **kwargs):
                    thread = real_thread(*args, **kwargs)
                    threads.append(thread)
                    return thread

                try:
                    server.serve_definitions({'fixture': (increment, [descriptor], descriptor)})
                    self.assertEqual(client.evaluate(server.address, 'fixture', [7],
                                                     [descriptor], descriptor), 8)
                    original = next(frame for frame in network.recorded
                                    if ls._frame_decode(frame)[0] == 'eval')
                    if closed:
                        client.close()
                    with patch.object(ls.threading, 'excepthook', errors.append), \
                         patch.object(ls.threading, 'Thread', tracked_thread):
                        if bug is None:
                            server._deliver(original)
                            for thread in threads:
                                thread.join(2)
                        else:
                            with patch.object(server.transport, 'send', side_effect=bug):
                                server._deliver(original)
                                for thread in threads:
                                    thread.join(2)
                    self.assertTrue(threads)
                    self.assertTrue(all(not thread.is_alive() for thread in threads))
                    self.assertEqual(calls, [7], 'a duplicate request reran its definition')
                    self.assertEqual([event.exc_value for event in errors], [] if bug is None else [bug])
                    if not closed and bug is None:
                        replies = [frame for frame in network.recorded
                                   if ls._frame_decode(frame)[0] == 'reply']
                        self.assertEqual(len(replies), 2)
                        self.assertEqual(replies[0], replies[1])
                finally:
                    client.close()
                    server.close()

    def test_factories_keep_hypothesis_strategies_and_shrinking(self):
        from hypothesis import find, settings, strategies as st
        options = settings(max_examples=100, database=None, derandomize=True)
        native = bridge.generator_factory('lawspec_bridge_test', 'generator', [])
        self.assertEqual(find(native, lambda value: value >= 137, settings=options), 137)
        child = bridge.generator_factory('lawspec_bridge_test', 'child_generator', [st.integers(7, 20)])
        self.assertEqual(find(child, lambda values: True, settings=options), [7])
        with self.assertRaises(TypeError):
            bridge.generator_factory('lawspec_bridge_test', 'invalid_generator', [])
        with self.assertRaises(TypeError):
            bridge.generator_factory('lawspec_bridge_test', 'child_generator', [7])
        for predicate in ['empty_generator', 'nondet_generator']:
            with self.assertRaises(bridge.janus.PrologError):
                bridge.generator_factory('lawspec_bridge_test', predicate, [])

    def test_factories_preserve_structured_incomplete_results(self):
        with self.assertRaises(bridge.Incomplete):
            bridge.generator_factory('lawspec_bridge_test', 'incomplete_factory', [])
        with self.assertRaises(bridge.Incomplete):
            bridge.Production(SCHEMA, 64, 'lawspec_bridge_test', 'incomplete_factory', [], [], {})

    def test_determinism_exceptions_are_structured(self):
        for predicate, observed in [('empty', 'fail'), ('choices', 'nondet')]:
            with self.subTest(predicate=predicate):
                with self.assertRaises(bridge.janus.PrologError) as raised:
                    self.call(predicate, 0, schema.Named('UInt8'))
                result = bridge.janus.query_once(
                    'E=error(determinism_error(_,det,Observed,_),_)',
                    {'E': raised.exception.term})
                self.assertIs(result['truth'], True)
                self.assertEqual(result['Observed'], observed)

    def test_partial_and_cyclic_results_are_refused(self):
        for predicate in ['unbound', 'cyclic']:
            with self.subTest(predicate=predicate):
                with self.assertRaises(bridge.janus.PrologError):
                    self.call(predicate, 0, schema.Named('UInt8'))

    def test_generated_schema_controls_both_directions_and_mutations(self):
        for bits in [32, 64]:
            with self.subTest(bits=bits):
                self.assertEqual(self.call('identity', Box(255), schema.Named(BOX), bits), Box(255))
                for predicate, value, ty in [
                    ('out_of_range', 0, schema.Named('UInt8')),
                    ('identity', 256, schema.Named('UInt8')),
                    ('wrong_tag', Box(7), schema.Named(BOX)),
                    ('identity', 2 ** bits, schema.Named('UIntSize')),
                ]:
                    with self.assertRaises((TypeError, ValueError)):
                        self.call(predicate, value, ty, bits)

    def test_exact_scalars_and_unicode(self):
        values = [('BigInt', 2 ** 4096 + 17), ('Text', 'e\u0301 日本語 😀'),
                  ('Char', '😀'), ('Bytes', bytes(range(256))),
                  ('Rational', Fraction(13, 17)),
                  ('Decimal', Decimal('-123456789.00000000000000000001')),
                  ('Utf16Text', ls.Raw('Utf16Text', [0xd800, 65, 0xdc00])),
                  ('CodePointText', ls.Raw('CodePointText', [0, 0x1f600])),
                  ('Unit', ls.UNIT), ('Null', ls.NULL), ('Undefined', ls.UNDEFINED)]
        with localcontext() as context:
            context.prec = 2
            for name, value in values:
                with self.subTest(name=name):
                    self.assertEqual(self.call('identity', value, schema.Named(name)), value)

    def test_ieee_payloads_survive_without_float_conversion_in_janus(self):
        for bits in [0, 0x8000000000000000, 0x7ff0000000000000,
                     0xfff0000000000000, 0x7ff8000000000042,
                     0x7ff0000000000042, 0x0000000000000001]:
            with self.subTest(bits=hex(bits)):
                value = struct.unpack('>d', bits.to_bytes(8, 'big'))[0]
                result = self.call('identity', value, schema.Named('Float64'))
                self.assertEqual(struct.pack('>d', result), bits.to_bytes(8, 'big'))
        for value in [-0.0, 0.0, 1.5]:
            self.assertEqual(struct.pack('>d', self.call(
                'identity', value, schema.Named('Float32'))), struct.pack('>d', value))
        value = complex(-0.0, 1.25)
        result = self.call('identity', value, schema.Named('Complex128'))
        self.assertEqual(struct.pack('>dd', result.real, result.imag),
                         struct.pack('>dd', value.real, value.imag))

    def test_presence_and_constructor_identities(self):
        optional = schema.Named('Optional', (schema.Named('UInt8'),))
        nullable = schema.Named('Nullable', (optional,))
        for value in [ls.Presence('Nullable', False),
                      ls.Presence('Nullable', True, ls.Presence('Optional', False)),
                      ls.Presence('Nullable', True, ls.Presence('Optional', True, 7))]:
            self.assertEqual(self.call('identity', value, nullable), value)
        maybe = schema.Named('Maybe', (schema.Named('Null'),))
        for value in [schema.Absent(), schema.Present(ls.NULL)]:
            result = self.call('identity', value, maybe)
            self.assertTrue(SCHEMA.equal(maybe, SCHEMA.from_native(maybe, result),
                                         SCHEMA.from_native(maybe, value)))
        either = schema.Named('Either', (schema.Named('UInt8'), schema.Named('Text')))
        for value in [schema.Left(0), schema.Right('bad')]:
            result = self.call('identity', value, either)
            self.assertTrue(SCHEMA.equal(either, SCHEMA.from_native(either, result),
                                         SCHEMA.from_native(either, value)))
        ty = schema.Named('List', (schema.Named(BOX),))
        self.assertEqual(self.call('identity', [Box(1), Box(2)], ty), [Box(1), Box(2)])

    def test_opaque_and_symbol_identity(self):
        handle, symbol = object(), ls.Symbol('same text')
        self.assertIs(self.call('identity', handle, schema.Named('example::Handle')), handle)
        for value in [{}, [], 71, 'native handle']:
            with self.subTest(value=value):
                self.assertIs(self.call('identity', value, schema.Named('example::Handle')), value)
                ty = schema.Named('List', (schema.Named('example::Handle'),))
                self.assertIs(self.call('identity', [value], ty)[0], value)
        self.assertIs(self.call('identity', symbol, schema.Named('Symbol')), symbol)
        other = self.call('identity', ls.Symbol('same text'), schema.Named('Symbol'))
        self.assertIsNot(other, symbol)

    def test_typed_failure_and_incomplete_are_distinct(self):
        with self.assertRaises(ls.Fail) as raised:
            self.call('typed_failure', 0, schema.Named('UInt8'), failure=schema.Named(ERROR))
        self.assertEqual(raised.exception.value, Oops('broken'))
        with self.assertRaisesRegex(ValueError, 'undeclared failure'):
            self.call('typed_failure', 0, schema.Named('UInt8'))
        with self.assertRaisesRegex(bridge.Incomplete, 'search bound exhausted'):
            self.call('incomplete', 0, schema.Named('UInt8'))

    def test_reentrant_callback_and_worker_threads(self):
        callbacks = types.ModuleType('lawspec_bridge_callbacks')
        callbacks.double = lambda value: bridge.invoke('lawspec_bridge_test', 'identity', [value * 2])
        sys.modules[callbacks.__name__] = callbacks
        self.assertEqual(self.call('callback', 7, schema.Named('UInt8')), 14)
        bridge.janus.query_once('lawspec_bridge_test:reset')
        with ThreadPoolExecutor(max_workers=4) as pool:
            values = list(pool.map(lambda _: self.call('tick', 0, schema.Named('UInt8')), range(100)))
        self.assertEqual(sorted(values), list(range(1, 101)))

    def test_explicit_handler_state_and_unit_operations(self):
        class Ledger:
            def __init__(self):
                self.total, self.lock = 0, Lock()

            def add(self, amount):
                with self.lock:
                    self.total += amount
                    return self.total

            def reset(self, unused):
                self.assert_unit = unused
                with self.lock:
                    self.total = 0

        native = Ledger()
        integer, unit = schema.Named('UInt8'), schema.Named('Unit')
        handler = bridge.Handler(SCHEMA, 64, 'Ledger', native, {
            'add': ([integer], integer, None), 'reset': ([unit], unit, None)})

        def add(_):
            return bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'forward',
                               [integer], integer, [1], handlers=[handler])

        with ThreadPoolExecutor(max_workers=4) as pool:
            values = list(pool.map(add, range(100)))
        self.assertEqual(sorted(values), list(range(1, 101)))
        self.assertEqual(bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'forward_reset',
                                     [unit], unit, [ls.UNIT], handlers=[handler]), ls.UNIT)
        self.assertEqual(native.total, 0)
        self.assertEqual(native.assert_unit, ls.UNIT)

    def test_handler_failures_retain_the_declared_ability(self):
        integer, error = schema.Named('UInt8'), schema.Named(ERROR)
        ability = 'Fail errors::type::Error'

        class Native:
            def reject(self, unused):
                raise ls.Fail(Oops('declined'))

        class Spec:
            def reject(self, unused):
                raise ls.Failure(ability, ls.DataValue('errors::Oops', ['declined']))

        for native in [Native(), Spec()]:
            handler = bridge.Handler(SCHEMA, 64, 'Ledger', native,
                                     {'reject': ([integer], integer, (ability, error))})
            with self.assertRaises(ls.Failure) as raised:
                bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'forward_reject',
                            [integer], integer, [1], handlers=[handler],
                            failure_abilities=[(ability, error)])
            self.assertEqual(raised.exception.ability, ability)
            value = SCHEMA.to_native(error, raised.exception.value)
            self.assertEqual(value, Oops('declined'))

    def test_handler_operation_and_result_mutations_are_refused(self):
        integer = schema.Named('UInt8')

        class Wrong:
            def bad(self, unused):
                return 256

            def hidden(self, unused):
                raise AssertionError('undeclared operation must never be called')

        handler = bridge.Handler(SCHEMA, 64, 'Ledger', Wrong(),
                                 {'bad': ([integer], integer, None)})
        for predicate in ['forward_bad', 'forward_hidden']:
            with self.subTest(predicate=predicate):
                with self.assertRaises(bridge.janus.PrologError):
                    bridge.call(SCHEMA, 64, 'lawspec_bridge_test', predicate,
                                [integer], integer, [0], handlers=[handler])

    def test_undeclared_handler_failures_cannot_become_typed_results(self):
        integer, error = schema.Named('UInt8'), schema.Named(ERROR)

        class Wrong:
            def reject(self, unused):
                raise ls.Failure('unrelated ability', ls.DataValue('errors::Oops', ['bad']))

        for failing in [None, ('expected ability', error)]:
            handler = bridge.Handler(SCHEMA, 64, 'Ledger', Wrong(),
                                     {'reject': ([integer], integer, failing)})
            with self.assertRaises(bridge.janus.PrologError):
                bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'forward_reject',
                            [integer], integer, [0], handlers=[handler])

    def test_prolog_production_instances_keep_state_failures_and_release(self):
        integer, unit = schema.Named('UInt8'), schema.Named('Unit')
        failing = ('Fail errors::type::Error', schema.Named(ERROR))
        operations = {
            'add': ('counter_add', [integer], integer, None),
            'reset': ('counter_reset', [unit], unit, None),
            'close': ('counter_close', [unit], unit, None),
            'reject': ('counter_reject', [integer], integer, failing),
        }
        native = bridge.Production(SCHEMA, 64, 'lawspec_bridge_test', 'counter_new',
                                   [integer], [7], operations)
        other = bridge.Production(SCHEMA, 64, 'lawspec_bridge_test', 'counter_new',
                                  [integer], [99], operations)
        try:
            self.assertEqual(native.add(5), 12)
            self.assertEqual(other.add(1), 100)
            self.assertEqual(native.reset(ls.UNIT), ls.UNIT)
            with ThreadPoolExecutor(max_workers=4) as pool:
                values = list(pool.map(lambda _: native.add(1), range(100)))
            self.assertEqual(sorted(values), list(range(1, 101)))
            with self.assertRaises(ls.Fail) as raised:
                native.reject(0)
            self.assertEqual(raised.exception.value, Oops('declined'))
            with self.assertRaises((ValueError, TypeError)):
                native.add(256)
            with self.assertRaises(AttributeError):
                native.hidden(0)
        finally:
            native.close(ls.UNIT)
            other.close(ls.UNIT)
        with self.assertRaises(bridge.janus.PrologError):
            native.add(0)

    def test_prolog_handler_factories_require_one_ground_result(self):
        integer = schema.Named('UInt8')
        for factory in ['empty', 'choices', 'unbound']:
            with self.subTest(factory=factory):
                with self.assertRaises(bridge.janus.PrologError):
                    bridge.Production(SCHEMA, 32, 'lawspec_bridge_test', factory,
                                      [integer], [0], {})

    def test_undefined_prolog_truth_is_explicitly_incomplete(self):
        integer = schema.Named('UInt8')
        with self.assertRaises(bridge.Incomplete):
            self.call('uncertain', 0, integer)
        with self.assertRaises(bridge.Incomplete):
            bridge.Production(SCHEMA, 32, 'lawspec_bridge_test', 'uncertain',
                              [integer], [0], {})

    def test_nested_handler_incomplete_results_remain_incomplete(self):
        integer = schema.Named('UInt8')

        class Unknown:
            def add(self, unused):
                raise bridge.Incomplete('bound exhausted 日本語')

        handler = bridge.Handler(SCHEMA, 64, 'Ledger', Unknown(),
                                 {'add': ([integer], integer, None)})
        with self.assertRaisesRegex(bridge.Incomplete, 'bound exhausted 日本語'):
            bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'forward',
                        [integer], integer, [0], handlers=[handler])

    def test_keyed_failures_are_validated_at_the_adapter_boundary(self):
        integer, error = schema.Named('UInt8'), schema.Named(ERROR)
        with self.assertRaisesRegex(ValueError, 'undeclared failure ability'):
            bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'forged_failure',
                        [integer], integer, [0])
        with self.assertRaises((ValueError, TypeError)):
            bridge.call(SCHEMA, 64, 'lawspec_bridge_test', 'forged_failure',
                        [integer], integer, [0], failure_abilities=[('expected', error)])


if __name__ == '__main__':
    unittest.main(verbosity=2)
