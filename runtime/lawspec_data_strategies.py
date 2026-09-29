"""Native Hypothesis strategies for instantiated Core data schemas."""

from functools import cache

from hypothesis import strategies as st

import lawspec_runtime as ls
from lawspec_schema import RefinementViolation


def strategy(schema, reference, bits, budget, scalar, symbols=None,
             witnesses=(), native_generators=None, native_schema=None):
    """Generate values with native strategies and checked witnesses.

    Witness subvalues seed nested domains in the given Symbol context.
    Sampled witnesses supplement native generators and their shrinkers;
    sampled alternatives need not shrink to a globally minimal value.
    Only witnesses fitting the current node budget can be drawn.
    """
    if type(budget) is not int or budget < 1:
        raise ValueError("structural node budget must be positive")
    schema._check(reference)
    schema._bits(bits)
    symbols = {} if symbols is None else symbols
    native_generators = ({} if native_generators is None
                         else dict(native_generators))
    native_schema = schema if native_schema is None else native_schema
    for name, factory in native_generators.items():
        if name not in schema._arity or not callable(factory):
            raise ValueError("invalid native generator binding: " + str(name))

    seeds = {}

    def remember(ty, value):
        constructors = schema.constructors(ty)
        children = []
        if constructors is not None:
            constructor = next(item for item in constructors
                               if item.tag == value.tag)
            children = [(field.type, child) for field, child in
                        zip(constructor.fields, value.fields)]
        elif ty.name == "List":
            children = [(ty.arguments[0], child) for child in value]
        elif ty.name in ("Nullable", "Optional") and value.present:
            children = [(ty.arguments[0], value.value)]
        elif ty.name == "Maybe" and value.tag == "Maybe::Just":
            children = [(ty.arguments[0], value.fields[0])]
        elif ty.name == "Either":
            index = 0 if value.tag == "Either::Left" else 1
            children = [(ty.arguments[index], value.fields[0])]
        cost = 1 + sum(remember(child_type, child)
                       for child_type, child in children)
        seeds.setdefault(ty, []).append((cost, value))
        return cost

    for witness in witnesses:
        remember(reference, schema.validate(reference, witness, bits, symbols))

    def valid(ty, value):
        try:
            schema.validate(ty, value, bits, symbols)
            return True
        except RefinementViolation:
            return False

    @cache
    def minimum(ty, limit):
        return next((cost for cost in range(1, limit + 1)
                     if inhabited(ty, cost)), None)

    def allocation(fields, available):
        costs = []
        for field in fields:
            cost = minimum(field.type, available)
            if cost is None:
                return None
            costs.append(cost)
            available -= cost
        count = len(costs)
        return tuple(cost + available // count + (index < available % count)
                     for index, cost in enumerate(costs))

    @cache
    def inhabited(ty, available):
        if available < 1:
            return False
        if ty.name in native_generators:
            return True
        constructors = schema.constructors(ty)
        if constructors is not None:
            return any(allocation(item.fields, available - 1) is not None
                       for item in constructors)
        if not ty.arguments or ty.name in (
                "List", "Maybe", "Nullable", "Optional"):
            return True
        if ty.name == "Either":
            return any(inhabited(child, available - 1)
                       for child in ty.arguments)
        raise ValueError("unsupported generator type: " + ty.name)

    @cache
    def build(ty, available):
        if ty.name in native_generators:
            def native_child(child):
                remaining = max(1, available - 1)
                # A parameter need not be stored (Phantom Empty), and native
                # containers may be inhabited without an element (List Empty).
                if not inhabited(child, remaining):
                    return st.nothing()
                return build(child, remaining).map(
                    lambda value: native_schema.to_native(
                        child, value, bits, symbols))

            def checked(value):
                try:
                    return native_schema.from_native(ty, value, bits, symbols)
                except (ValueError, TypeError, ArithmeticError,
                        AttributeError) as error:
                    raise ValueError(
                        f"native generator {ty.name}: {error}") from error

            factory = native_generators[ty.name]
            generated = factory(*(native_child(child)
                                  for child in ty.arguments))
            if not isinstance(generated, st.SearchStrategy):
                raise TypeError(
                    f"native generator {ty.name} must return a strategy")
            # Mapping retains Hypothesis's shrink choices. Invalid samples
            # and shrinks fail; they are never filtered into rejections.
            return generated.map(checked)
        native = build_native(ty, available)
        candidates = [value for cost, value in seeds.get(ty, ())
                      if cost <= available]
        if candidates:
            return st.one_of(native, st.sampled_from(candidates))
        return native

    def build_native(ty, available):
        if not inhabited(ty, available):
            raise ValueError(
                f"no value of {ty} within structural node budget {available}")
        constructors = schema.constructors(ty)
        if constructors is not None:
            alternatives = []
            for constructor in constructors:
                costs = allocation(constructor.fields, available - 1)
                if costs is None:
                    continue
                children = [build(field.type, cost)
                            for field, cost in zip(constructor.fields, costs)]
                values = st.tuples(*children).map(
                    lambda fields, tag=constructor.tag:
                    ls.DataValue(tag, fields))
                if constructor.predicates:
                    values = values.filter(lambda value: valid(ty, value))
                alternatives.append(values)
            return st.one_of(*alternatives)
        if not ty.arguments:
            return scalar(ty.name).map(
                lambda value: schema.validate(ty, value, bits, symbols))
        name, arguments = ty.name, ty.arguments
        if name == "List":
            remaining = available - 1
            cost = minimum(arguments[0], remaining)
            maximum = 0 if cost is None else remaining // cost

            def sized(length):
                if length == 0:
                    return st.just([])
                return st.lists(build(arguments[0], remaining // length),
                                min_size=length, max_size=length)

            return st.integers(0, maximum).flatmap(sized)
        if name in ("Nullable", "Optional", "Maybe"):
            absent = (ls.DataValue("Maybe::Nothing", ()) if name == "Maybe"
                      else ls.Presence(name, False))
            if not inhabited(arguments[0], available - 1):
                return st.just(absent)
            present = build(arguments[0], available - 1).map(
                lambda value: ls.DataValue("Maybe::Just", (value,))
                if name == "Maybe" else ls.Presence(name, True, value))
            return st.one_of(st.just(absent), present)
        if name == "Either":
            return st.one_of(*[
                build(child, available - 1).map(
                    lambda value, tag=tag: ls.DataValue(tag, (value,)))
                for tag, child in zip(
                    ("Either::Left", "Either::Right"), arguments)
                if inhabited(child, available - 1)])
        raise ValueError("unsupported generator type: " + name)

    return build(reference, budget)
