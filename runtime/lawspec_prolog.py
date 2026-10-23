"""Janus transport for Prolog adapters over LawSpec's checked Python runtime.

No source parsing, property engine or scalar arithmetic is implemented here.
The generated boundary supplies a Core schema and uses its existing validation.
Janus owns object references and thread attachment. Start from the selected
Python interpreter so a system SWI build cannot silently select an older Python.
ref:DEC-prolog-janus
"""

from decimal import Decimal
from fractions import Fraction
from pathlib import Path
import asyncio
import contextvars
import logging
import struct
import threading
import weakref

import janus_swi as janus
import lawspec_runtime as ls
import lawspec_schema as metadata


class Incomplete(RuntimeError):
    """A native computation explicitly declined to produce a complete result."""

    def __init__(self, reason):
        super().__init__(reason)
        # Models may retain an exception's description after checking a history.
        # A structured logging event also reaches the test runner from worker
        # threads; reporting never has to infer semantics from that description.
        logging.getLogger("lawspec.prolog.incomplete").info(
            "%s", reason, extra={"lawspec_status": "incomplete"}
        )


class NativeFailure(Exception):
    """A typed native failure, still requiring its declared schema conversion."""

    def __init__(self, value):
        self.value = value
        super().__init__(f"Prolog adapter failed with {value!r}")


def _query_once(goal, arguments):
    """Preserve a constructor/factory's structured incomplete exception too."""
    try:
        return janus.query_once(goal, arguments)
    except janus.PrologError as error:
        incomplete = janus.query_once(
            "Error=lawspec_incomplete(Reason), string(Reason)", {"Error": error.term}
        )
        if incomplete["truth"] is True:
            raise Incomplete(incomplete["Reason"]) from error
        raise


def load_module(path):
    """Load qualified application predicates without importing into user.

    Separate LawSpec units may export the same predicate name and arity.
    SWI load_files/2's empty import list preserves their module identities.
    """
    answer = _query_once(
        "load_files(File,[imports([]),must_be_module(true)])", {"File": str(path)}
    )
    if answer["truth"] is not True:
        raise Incomplete("Prolog module loading did not complete")


class _Opaque:
    # A Python dict/list/scalar normally converts structurally in Janus.
    # Wrapping it gives Prolog a GC-owned Python reference with exact identity.
    def __init__(self, value):
        self.value = value


def native_handle(holder):
    """Expose a handle's application object without changing its identity."""
    return holder.value if isinstance(holder, _Opaque) else holder


def generator_factory(module, predicate, children):
    """Call a deterministic Prolog factory without replacing Hypothesis.

    Child strategies and the result retain their Python object identity.
    The existing native-generator schema checks every sample and shrink.
    """
    from hypothesis.strategies import SearchStrategy

    if not all(isinstance(child, SearchStrategy) for child in children):
        raise TypeError("Prolog generator parameters must be Hypothesis strategies")
    answer = _query_once(
        "lawspec_prolog:strategy(Module,Predicate,Children,Strategy)",
        {"Module": module, "Predicate": predicate, "Children": children},
    )
    if answer["truth"] is not True:
        raise Incomplete("Prolog generator did not produce a complete strategy")
    strategy = answer["Strategy"]
    if not isinstance(strategy, SearchStrategy):
        raise TypeError("Prolog generator must return a Hypothesis strategy")
    return strategy


class Handler:
    """One explicit ability argument with operation signatures from Core.

    The original handler retains its lifetime and state. Janus owns the proxy
    reference; schema validation applies before and after each operation.
    """

    def __init__(self, schema, bits, ability, native, operations):
        self.schema = schema
        self.bits = bits
        self.ability = ability
        self.native = native
        self.operations = dict(operations)

    def invoke(self, operation, packed):
        if operation not in self.operations:
            raise ValueError("operation outside declared Prolog ability: " + operation)
        types, result_type, failing = self.operations[operation]
        if len(types) != len(packed):
            raise TypeError("wrong Prolog ability operation arity")
        symbols = {}
        values = [
            self.schema.to_native(ty, unpack(value), self.bits, symbols)
            for ty, value in zip(types, packed)
        ]
        try:
            value = getattr(self.native, operation)(*values)
        except Incomplete as error:
            return ["incomplete", list(map(ord, str(error)))]
        except (ls.Fail, ls.Failure) as error:
            if failing is None:
                raise ValueError("operation raised an undeclared failure") from error
            ability, ty = failing
            if isinstance(error, ls.Failure):
                if error.ability != ability:
                    raise ValueError(
                        "operation raised a different failure ability"
                    ) from error
                value = self.schema.validate(ty, error.value, self.bits, symbols)
            else:
                value = self.schema.from_native(ty, error.value, self.bits, symbols)
            return ["ability_failure", ability, pack(value, self.schema, ty)]
        if result_type.name == "Unit":
            value = ls.unit_result(value)
        logical = self.schema.from_native(result_type, value, self.bits, symbols)
        return ["ok", pack(logical, self.schema, result_type)]


class _PrologState:
    """A Janus-owned copy of a ground Prolog instance token."""

    def __init__(self, term):
        if not isinstance(term, janus.Term):
            raise TypeError("Prolog instance state requires a Janus term")
        self.term = term


class _NativeHandle(_PrologState):
    def __init__(self, identity, term):
        super().__init__(term)
        self.identity = identity


_native_handles = {}
_native_handle_lock = threading.RLock()


def _intern_native_handle(identity, term):
    """Ground token equality preserves identity across repeated native returns.

    The weak cache retains no application resources. Its lock covers only
    term hashing/equality, never an application predicate or Python callback.
    Hash collisions are resolved by exact Prolog identity comparison.
    """
    hashed = _query_once("term_hash(Term,Hash)", {"Term": term})
    key = identity, hashed["Hash"]
    with _native_handle_lock:
        for reference in _native_handles.get(key, ()):
            value = reference()
            if (
                value is not None
                and _query_once("Left==Right", {"Left": value.term, "Right": term})[
                    "truth"
                ]
                is True
            ):
                return value
        value = _NativeHandle(identity, term)

        def expired(reference):
            with _native_handle_lock:
                live = [
                    item
                    for item in _native_handles.get(key, ())
                    if item is not reference and item() is not None
                ]
                if live:
                    _native_handles[key] = live
                else:
                    _native_handles.pop(key, None)

        _native_handles.setdefault(key, []).append(weakref.ref(value, expired))
        return value


class Production:
    """A native handler whose constructor and operations are Prolog predicates.

    Each instance owns its token and symbol context. Prolog code owns the
    token's state and resource lifecycle, including any declared release
    operation. No bridge lock is held while application predicates execute.
    """

    def __init__(
        self,
        schema,
        bits,
        module,
        constructor,
        resource_types,
        resources,
        operations,
        bindings=None,
    ):
        if len(resource_types) != len(resources):
            raise TypeError("wrong Prolog handler constructor arity")
        self._schema, self._bits, self._module = schema, bits, module
        self._operations, self._symbols = dict(operations), {}
        self._bindings = bindings
        logical = [
            schema.from_native(ty, value, bits, self._symbols)
            for ty, value in zip(resource_types, resources)
        ]
        packed = [
            pack(value, schema, ty, bindings)
            for ty, value in zip(resource_types, logical)
        ]
        answer = _query_once(
            (
                "lawspec_prolog:new_handler_bound(Module,Factory,Resources,Bindings,Instance)"
                if bindings
                else "lawspec_prolog:new_handler(Module,Factory,Resources,Instance)"
            ),
            {
                "Module": module,
                "Factory": constructor,
                "Resources": packed,
                **({"Bindings": bindings} if bindings else {}),
            },
        )
        if answer["truth"] is not True:
            raise Incomplete(
                "Prolog handler constructor did not produce a complete result"
            )
        self._state = _PrologState(answer["Instance"])

    def __getattr__(self, name):
        operations = self.__dict__.get("_operations", {})
        if name not in operations:
            raise AttributeError(name)
        predicate, types, result_type, failing = operations[name]

        def operation(*arguments):
            if len(types) != len(arguments):
                raise TypeError("wrong Prolog handler operation arity")
            logical = [
                self._schema.from_native(ty, value, self._bits, self._symbols)
                for ty, value in zip(types, arguments)
            ]
            try:
                value = invoke(
                    self._module,
                    predicate,
                    [self._state] + logical,
                    self._schema,
                    [None] + list(types),
                    self._bindings,
                )
            except NativeFailure as error:
                if failing is None:
                    raise ValueError(
                        "Prolog handler raised an undeclared failure"
                    ) from error
                raise ls.Fail(
                    self._schema.to_native(
                        failing[1], error.value, self._bits, self._symbols
                    )
                ) from error
            except ls.Failure as error:
                if failing is None or error.ability != failing[0]:
                    raise ValueError(
                        "Prolog handler raised a different failure ability"
                    ) from error
                self._schema.validate(
                    failing[1], error.value, self._bits, self._symbols
                )
                raise
            if self._bindings:
                value = self._schema.validate(
                    result_type, value, self._bits, self._symbols
                )
                pack(value, self._schema, result_type, self._bindings)
            return self._schema.to_native(result_type, value, self._bits, self._symbols)

        return operation


def _float_bits(value):
    return int.from_bytes(struct.pack(">d", value), "big")


def _float(bits):
    if type(bits) is not int or not 0 <= bits < 2**64:
        raise ValueError("IEEE payload must be an unsigned 64-bit integer")
    return struct.unpack(">d", bits.to_bytes(8, "big"))[0]


def pack(value, schema=None, reference=None, bindings=None):
    """Copy a logical value without host normalization or numeric coercion."""
    if isinstance(value, Handler):
        return ["handler", value]
    if isinstance(value, _PrologState):
        if bindings and reference is not None:
            wanted = dict(bindings[1]).get(reference.name)
            if wanted is not None and (
                not isinstance(value, _NativeHandle) or value.identity != wanted
            ):
                raise TypeError("wrong native Prolog handle type: " + reference.name)
        return ["prolog_state", value.term]
    if schema is not None and schema.is_handle(reference):
        if bindings and reference.name in dict(bindings[1]):
            raise TypeError("expected a bound native Prolog handle: " + reference.name)
        return ["opaque", _Opaque(value)]

    def child(item, ty=None):
        return pack(item, schema if ty is not None else None, ty, bindings)

    if isinstance(value, ls.DataValue):
        types = ()
        if schema is not None:
            constructors = schema.constructors(reference)
            if constructors is not None:
                constructor = next(
                    item for item in constructors if item.tag == value.tag
                )
                types = metadata.witnessed(constructor, value.fields)
            elif reference.name == "Maybe":
                types = reference.arguments if value.fields else ()
            elif reference.name == "Either":
                types = (reference.arguments[0 if value.tag == "Either::Left" else 1],)
        return [
            "value",
            value.tag,
            [
                child(item, types[index] if types else None)
                for index, item in enumerate(value.fields)
            ],
        ]
    if isinstance(value, ls.Presence):
        ty = reference.arguments[0] if schema is not None else None
        return (
            ["presence", value.kind, True, child(value.value, ty)]
            if value.present
            else ["presence", value.kind, False]
        )
    if type(value) is list:
        ty = reference.arguments[0] if schema is not None else None
        return ["list", [child(item, ty) for item in value]]
    if type(value) is bool:
        return ["bool", value]
    if type(value) is int:
        return ["integer", value]
    if type(value) is str:
        return ["text", list(map(ord, value))]
    if type(value) is float:
        return ["float", _float_bits(value)]
    if type(value) is complex:
        return ["complex", _float_bits(value.real), _float_bits(value.imag)]
    if isinstance(value, Decimal):
        sign, digits, exponent = value.as_tuple()
        return ["decimal", sign, list(digits), exponent]
    if isinstance(value, Fraction):
        return ["rational", value.numerator, value.denominator]
    if type(value) is bytes:
        return ["bytes", list(value)]
    if isinstance(value, ls.Raw):
        return ["raw", value.kind, list(value.units)]
    if isinstance(value, ls.Absence):
        return ["absence", value.kind]
    if isinstance(value, ls.Symbol):
        return ["symbol", value]
    # Opaque handles retain identity; the declared schema decides whether a
    # handle is allowed. Symbols have a separate tag and cannot be fabricated.
    return ["opaque", _Opaque(value)]


def unpack(packed):
    """Recover a logical value; the caller then checks its declared schema."""
    if type(packed) is not list or not packed:
        raise ValueError("malformed Prolog value")
    kind, *parts = packed
    arities = {
        "integer": 1,
        "bool": 1,
        "text": 1,
        "float": 1,
        "complex": 2,
        "decimal": 3,
        "rational": 2,
        "bytes": 1,
        "raw": 2,
        "absence": 1,
        "symbol": 1,
        "opaque": 1,
        "value": 2,
        "list": 1,
        "handler": 1,
    }
    if kind == "native_handle" and len(parts) == 2:
        return _intern_native_handle(*parts)
    if kind == "presence":
        if len(parts) == 2 and parts[1] is False:
            return ls.Presence(parts[0], False)
        if len(parts) == 3 and parts[1] is True:
            return ls.Presence(parts[0], True, unpack(parts[2]))
        raise ValueError("malformed Prolog presence")
    if kind not in arities or len(parts) != arities[kind]:
        raise ValueError("malformed Prolog value tag or arity")
    if kind == "integer":
        if type(parts[0]) is not int:
            raise TypeError("Prolog integer required")
        return parts[0]
    if kind == "bool":
        if type(parts[0]) is not bool:
            raise TypeError("Prolog Bool required")
        return parts[0]
    if kind == "text":
        return "".join(map(chr, parts[0]))
    if kind == "float":
        return _float(parts[0])
    if kind == "complex":
        return complex(*map(_float, parts))
    if kind == "decimal":
        return Decimal((parts[0], tuple(parts[1]), parts[2]))
    if kind == "rational":
        return Fraction(*parts)
    if kind == "bytes":
        return bytes(parts[0])
    if kind == "raw":
        return ls.Raw(parts[0], parts[1])
    if kind == "absence":
        return ls.Absence(parts[0])
    if kind == "symbol":
        if not isinstance(parts[0], ls.Symbol):
            raise TypeError("Prolog Symbol requires a runtime identity")
        return parts[0]
    if kind == "opaque":
        return parts[0].value if isinstance(parts[0], _Opaque) else parts[0]
    if kind == "handler":
        if not isinstance(parts[0], Handler):
            raise TypeError("Prolog handler requires declared operation metadata")
        return parts[0]
    if kind == "value":
        return ls.DataValue(parts[0], tuple(map(unpack, parts[1])))
    return list(map(unpack, parts[0]))


def invoke(
    module, predicate, arguments, schema=None, argument_types=None, bindings=None
):
    """Run one functional predicate, preserving SWI's structured exceptions."""
    if argument_types is not None and len(argument_types) != len(arguments):
        raise TypeError("wrong Prolog adapter arity")
    packed = [
        pack(value, schema, argument_types[index], bindings)
        if argument_types is not None and argument_types[index] is not None
        else pack(value)
        for index, value in enumerate(arguments)
    ]
    answer = _query_once(
        (
            "lawspec_prolog:invoke_bound(Module,Predicate,Arguments,Bindings,Outcome)"
            if bindings
            else "lawspec_prolog:invoke(Module,Predicate,Arguments,Outcome)"
        ),
        {
            "Module": module,
            "Predicate": predicate,
            "Arguments": packed,
            **({"Bindings": bindings} if bindings else {}),
        },
    )
    if answer["truth"] is not True:
        raise Incomplete("Prolog bridge did not produce a complete result")
    outcome = answer["Outcome"]
    if len(outcome) == 3 and outcome[0] == "ability_failure":
        raise ls.Failure(outcome[1], unpack(outcome[2]))
    status, payload = outcome
    if status == "incomplete":
        raise Incomplete(payload)
    if status == "failure":
        raise NativeFailure(unpack(payload))
    if status != "ok":
        raise ValueError("unknown Prolog execution status")
    return unpack(payload)


async def call_async(function):
    """Await a native task without joining a cancelled predicate at loop exit.

    The existing Async handler owns worker execution. Shield its future so a
    cancelled waiter cannot cancel the result that the worker still produces.
    Context ownership follows the call, including structured incomplete events.
    """
    context = contextvars.copy_context()
    running = ls.ASYNC.spawn(lambda: context.run(function))
    waiting = asyncio.wrap_future(running)
    # A losing hedge may raise after its waiter was cancelled. Its structured
    # status was already logged; consume the abandoned future's exception too.
    waiting.add_done_callback(
        lambda done: None if done.cancelled() else done.exception()
    )
    return await asyncio.shield(waiting)


def call(
    schema,
    bits,
    module,
    predicate,
    argument_types,
    result_type,
    arguments,
    failure_type=None,
    handlers=(),
    failure_abilities=(),
    bindings=None,
    argument_order=None,
):
    """Validate both directions with the generated checked Core schema."""
    if len(argument_types) != len(arguments):
        raise TypeError("wrong Prolog adapter arity")
    symbols = {}
    logical = [
        schema.from_native(ty, value, bits, symbols)
        for ty, value in zip(argument_types, arguments)
    ]
    order = list(range(len(logical))) if argument_order is None else argument_order
    try:
        result = invoke(
            module,
            predicate,
            list(handlers) + [logical[index] for index in order],
            schema,
            [None] * len(handlers) + [argument_types[index] for index in order],
            bindings,
        )
    except NativeFailure as error:
        if failure_type is None:
            raise ValueError("Prolog adapter raised an undeclared failure") from error
        raise ls.Fail(
            schema.to_native(failure_type, error.value, bits, symbols)
        ) from error
    except ls.Failure as error:
        ty = dict(failure_abilities).get(error.ability)
        if ty is None:
            raise ValueError(
                "Prolog adapter raised an undeclared failure ability"
            ) from error
        schema.validate(ty, error.value, bits, symbols)
        raise
    if bindings:
        result = schema.validate(result_type, result, bits, symbols)
        pack(result, schema, result_type, bindings)
    return schema.to_native(result_type, result, bits, symbols)


# Import under the configured Python interpreter, then consult the sibling
# runtime. No process-global execution lock is held across foreign calls:
# Janus releases the GIL while Prolog runs and attaches worker-thread engines.
load_module(Path(__file__).with_suffix(".pl"))
