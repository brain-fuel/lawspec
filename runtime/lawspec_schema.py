"""Typed data validation and native bridges without test frameworks."""

from dataclasses import dataclass

import lawspec_runtime as ls


@dataclass(frozen=True)
class Parameter:
    index: int


@dataclass(frozen=True)
class Named:
    name: str
    arguments: tuple = ()

    def __post_init__(self):
        object.__setattr__(self, "arguments", tuple(self.arguments))


@dataclass(frozen=True)
class Field:
    name: str
    type: object


@dataclass(frozen=True)
class Constructor:
    tag: str
    fields: tuple
    native: type
    predicates: tuple = ()

    def __post_init__(self):
        object.__setattr__(self, "fields", tuple(self.fields))
        object.__setattr__(self, "predicates", tuple(self.predicates))


@dataclass(frozen=True)
class Definition:
    name: str
    parameters: int
    constructors: tuple

    def __post_init__(self):
        object.__setattr__(self, "constructors", tuple(self.constructors))


class Maybe[T]:
    """Distinct Nothing and Just states, including nested absence."""

    __slots__ = ()

    def __new__(cls, *args, **kwargs):
        if cls is Maybe:
            raise TypeError("construct Nothing or Just")
        return object.__new__(cls)


@dataclass(frozen=True, slots=True, eq=False)
class Nothing[T](Maybe[T]):
    pass


@dataclass(frozen=True, slots=True, eq=False)
class Just[T](Maybe[T]):
    value: T


class Either[L, R]:
    """Base for distinct Left and Right alternatives."""

    __slots__ = ()

    def __new__(cls, *args, **kwargs):
        if cls is Either:
            raise TypeError("construct Left or Right")
        return object.__new__(cls)


@dataclass(frozen=True, slots=True, eq=False)
class Left[L, R](Either[L, R]):
    value: L


@dataclass(frozen=True, slots=True, eq=False)
class Right[L, R](Either[L, R]):
    value: R


def substitute(reference, arguments):
    if isinstance(reference, Parameter):
        return arguments[reference.index]
    return Named(reference.name, tuple(
        substitute(child, arguments) for child in reference.arguments))


def type_key(reference):
    """Produce a scalar-runtime key with concrete type arguments."""
    if not isinstance(reference, Named):
        raise TypeError("type key requires an instantiated reference")
    arguments = tuple(map(type_key, reference.arguments))
    if not arguments:
        return reference.name
    if reference.name == "Either" and len(arguments) == 2:
        return f"Either ({arguments[0]}) ({arguments[1]})"
    if len(arguments) == 1:
        return reference.name + " " + arguments[0]

    def pretty(value):
        return value.name + "".join(
            " (" + pretty(child) + ")" for child in value.arguments)

    return pretty(reference)


class RefinementViolation(ValueError):
    """A well-formed candidate failed a Boolean field predicate."""


class Schema:
    """Validated Core metadata and native constructor classes."""

    def __init__(self, definitions, primitives):
        self._definitions = {}
        self._arity = dict.fromkeys(primitives, 0)
        self._arity.update(List=1, Maybe=1, Either=2, Nullable=1, Optional=1)
        for definition in definitions:
            if definition.name in self._arity:
                raise ValueError("duplicate type: " + definition.name)
            if (type(definition.parameters) is not int
                    or definition.parameters < 0):
                raise ValueError("invalid parameter count: " + definition.name)
            self._definitions[definition.name] = definition
            self._arity[definition.name] = definition.parameters
        tags, native_classes = set(), set()
        for definition in self._definitions.values():
            for constructor in definition.constructors:
                if constructor.tag in tags:
                    raise ValueError(
                        "duplicate constructor: " + constructor.tag)
                tags.add(constructor.tag)
                if not isinstance(constructor.native, type):
                    raise TypeError("native constructor must be a class")
                if constructor.native in native_classes:
                    raise ValueError("duplicate native constructor class")
                native_classes.add(constructor.native)
                names = [field.name for field in constructor.fields]
                if len(names) != len(set(names)):
                    raise ValueError("duplicate constructor field")
                for field in constructor.fields:
                    self._check(field.type, definition.parameters)
                if not all(callable(test) for test in constructor.predicates):
                    raise TypeError("constructor predicate must be callable")

    def _check(self, reference, parameters=0):
        if isinstance(reference, Parameter):
            if (type(reference.index) is not int
                    or not 0 <= reference.index < parameters):
                raise ValueError("unbound schema parameter")
        elif isinstance(reference, Named):
            if self._arity.get(reference.name) != len(reference.arguments):
                raise ValueError(
                    "unknown type or wrong arity: " + reference.name)
            for child in reference.arguments:
                self._check(child, parameters)
        else:
            raise TypeError("invalid schema type reference")

    def constructors(self, reference):
        """Return instantiated fields, or None for a built-in type."""
        self._check(reference)
        definition = self._definitions.get(reference.name)
        if definition is None:
            return None
        return tuple(Constructor(constructor.tag, tuple(
            Field(field.name, substitute(field.type, reference.arguments))
            for field in constructor.fields), constructor.native,
            constructor.predicates)
            for constructor in definition.constructors)

    @staticmethod
    def _bits(bits):
        if type(bits) is not int or bits not in (32, 64):
            raise ValueError("machineBits must be 32 or 64")

    def validate(self, reference, value, bits=64, symbols=None):
        self._check(reference)
        self._bits(bits)
        return self._walk(reference, value, bits, "validate",
                          {} if symbols is None else symbols)

    def all_payloads(self, reference, value, predicates, bits=64,
                     symbols=None):
        """Check stored arguments, preserving parameter provenance."""
        self._check(reference)
        structural = ("List", "Maybe", "Either", "Nullable", "Optional")
        if (reference.name not in self._definitions
                and reference.name not in structural):
            raise ValueError("payload predicates require a data type")
        predicates = tuple(predicates)
        if len(predicates) != len(reference.arguments):
            raise ValueError("payload predicate arity mismatch")
        if not all(callable(predicate) for predicate in predicates):
            raise TypeError("payload predicate must be callable")
        checked = self.validate(reference, value, bits, symbols)

        def recipe(field, arguments):
            if isinstance(field, Parameter):
                return arguments[field.index]
            children = tuple(recipe(child, arguments)
                             for child in field.arguments)
            return (Named(field.name, children)
                    if any(child is not None for child in children)
                    else None)

        def contextual(plan, child, context):
            try:
                return walk(plan, child)
            except (ValueError, TypeError, ArithmeticError) as error:
                raise ValueError(f"{context}: {error}") from error

        def walk(plan, child):
            if plan is None:
                return True
            if isinstance(plan, Parameter):
                result = predicates[plan.index](child)
                if type(result) is not bool:
                    raise TypeError("payload predicate did not produce Bool")
                return result
            name, arguments = plan.name, plan.arguments
            if name == "List":
                return all(contextual(arguments[0], item, f"List[{index}]")
                           for index, item in enumerate(child))
            if name in ("Nullable", "Optional"):
                return (not child.present or contextual(
                    arguments[0], child.value, name + ".value"))
            if name == "Maybe":
                return (child.tag == "Maybe::Nothing" or contextual(
                    arguments[0], child.fields[0], "Maybe::Just.value"))
            if name == "Either":
                index = 0 if child.tag == "Either::Left" else 1
                return contextual(arguments[index], child.fields[0],
                                  child.tag + ".value")
            definition = self._definitions[name]
            constructor = next(item for item in definition.constructors
                               if item.tag == child.tag)
            return all(contextual(recipe(field.type, arguments), item,
                                  constructor.tag + "." + field.name)
                       for field, item in zip(constructor.fields,
                                              child.fields))

        plan = Named(reference.name, tuple(
            Parameter(index) for index in range(len(predicates))))
        return walk(plan, checked)

    def to_native(self, reference, value, bits=64, symbols=None):
        symbols = {} if symbols is None else symbols
        checked = self.validate(reference, value, bits, symbols)
        return self._walk(reference, checked, bits, "native", symbols)

    def from_native(self, reference, value, bits=64, symbols=None):
        self._check(reference)
        self._bits(bits)
        symbols = {} if symbols is None else symbols
        logical = self._walk(reference, value, bits, "logical", symbols)
        return self.validate(reference, logical, bits, symbols)

    def _walk(self, reference, value, bits, mode, symbols):
        constructors = self.constructors(reference)
        if constructors is not None:
            if mode == "logical":
                constructor = next((item for item in constructors
                                    if type(value) is item.native), None)
                if constructor is None:
                    raise TypeError("invalid native " + reference.name)
                fields = tuple(getattr(value, field.name)
                               for field in constructor.fields)
            else:
                if not isinstance(value, ls.DataValue):
                    raise TypeError("expected " + reference.name)
                constructor = next((item for item in constructors
                                    if value.tag == item.tag), None)
                if constructor is None:
                    raise ValueError(
                        "foreign constructor for " + reference.name)
                fields = value.fields
            if len(fields) != len(constructor.fields):
                raise ValueError("wrong field count: " + constructor.tag)
            converted = []
            for field, child in zip(constructor.fields, fields):
                try:
                    converted.append(self._walk(
                        field.type, child, bits, mode, symbols))
                except (ValueError, TypeError, OverflowError) as error:
                    error_type = (RefinementViolation if isinstance(
                        error, RefinementViolation) else ValueError)
                    raise error_type(
                        constructor.tag + "." + field.name + ": " + str(error)
                    ) from error
            if mode == "native":
                return constructor.native(*converted)
            if mode == "validate":
                # Check shapes first. Failed conditions stop before
                # predicates whose definedness depends on them.
                for index, predicate in enumerate(constructor.predicates):
                    context = (
                        f"{constructor.tag}: field refinement {index + 1}")
                    try:
                        accepted = predicate(self, reference.arguments,
                                             tuple(converted), bits, symbols)
                    except (ValueError, TypeError, ArithmeticError) as error:
                        raise ValueError(f"{context}: {error}") from error
                    if accepted is False:
                        raise RefinementViolation(f"{context} failed")
                    if accepted is not True:
                        raise ValueError(f"{context} did not produce Bool")
            return ls.DataValue(constructor.tag, converted)
        name, arguments = reference.name, reference.arguments
        if not arguments:
            return ls.validate(value, name, bits)
        if name == "List":
            if not isinstance(value, list):
                raise TypeError("expected List")
            result = []
            for index, child in enumerate(value):
                try:
                    result.append(self._walk(
                        arguments[0], child, bits, mode, symbols))
                except (ValueError, TypeError, OverflowError) as error:
                    error_type = (RefinementViolation if isinstance(
                        error, RefinementViolation) else ValueError)
                    raise error_type(f"List[{index}]: {error}") from error
            return result
        if name in ("Nullable", "Optional"):
            if (not isinstance(value, ls.Presence) or value.kind != name
                    or type(value.present) is not bool):
                raise TypeError("invalid tagged presence: " + name)
            payload = None
            if value.present:
                payload = self._walk(
                    arguments[0], value.value, bits, mode, symbols)
            return ls.Presence(name, value.present, payload)
        if name in ("Maybe", "Either"):
            classes = ((Nothing, Just) if name == "Maybe" else (Left, Right))
            tags = (("Maybe::Nothing", "Maybe::Just") if name == "Maybe"
                    else ("Either::Left", "Either::Right"))
            if mode == "logical":
                if type(value) not in classes:
                    raise TypeError("invalid native " + name)
                index = classes.index(type(value))
                fields = (() if name == "Maybe" and index == 0
                          else (value.value,))
            else:
                if (not isinstance(value, ls.DataValue)
                        or value.tag not in tags):
                    raise ValueError("invalid constructor for " + name)
                index, fields = tags.index(value.tag), value.fields
            expected = 0 if name == "Maybe" and index == 0 else 1
            if len(fields) != expected:
                raise ValueError("wrong constructor arity for " + name)
            converted = (() if not expected else (self._walk(
                arguments[0 if name == "Maybe" else index], fields[0], bits,
                mode, symbols),))
            return (classes[index](*converted) if mode == "native"
                    else ls.DataValue(tags[index], converted))
        raise ValueError("unsupported type: " + name)

    def construct(self, reference, tag, fields, bits=64, symbols=None):
        value = (ls.construct(tag, fields) if reference.name == "List"
                 else ls.DataValue(tag, fields))
        return self.validate(reference, value, bits, symbols)

    def match(self, reference, value, branches, bits=64, symbols=None):
        checked = self.validate(reference, value, bits, symbols)
        if reference.name == "List":
            return ls.match_list(checked, branches)
        for tag, branch in branches:
            if checked.tag == tag:
                return branch(*checked.fields)
        raise ValueError("missing match branch: " + checked.tag)

    def equal(self, reference, left, right, bits=64, symbols=None):
        symbols = {} if symbols is None else symbols
        left = self.validate(reference, left, bits, symbols)
        right = self.validate(reference, right, bits, symbols)
        constructors = self.constructors(reference)
        if constructors is not None:
            if left.tag != right.tag:
                return False
            constructor = next(item for item in constructors
                               if item.tag == left.tag)
            return all(self.equal(field.type, a, b, bits, symbols)
                       for field, a, b in zip(
                           constructor.fields, left.fields, right.fields))
        name, arguments = reference.name, reference.arguments
        if not arguments:
            return ls.equal(left, right, name, name)
        if name == "List":
            return len(left) == len(right) and all(
                self.equal(arguments[0], a, b, bits, symbols)
                for a, b in zip(left, right))
        if name in ("Nullable", "Optional"):
            return (left.present == right.present and
                    (not left.present or
                     self.equal(arguments[0], left.value, right.value,
                                bits, symbols)))
        if left.tag != right.tag:
            return False
        if not left.fields:
            return True
        index = 1 if left.tag == "Either::Right" else 0
        return self.equal(
            arguments[index], left.fields[0], right.fields[0], bits, symbols)
