# Domain modeling

Wrappers give primitive values a domain meaning and a checked constraint.
Workflows describe typed pipelines between distinct domain states. Together
they make illegal states unrepresentable.

```lawspec
unit guide.ordering

wrapper UnitQuantity is Int32 where value >= 1 && value <= 1000 end
wrapper OrderId is Text where prelude.length value > 0 end

type UnvalidatedOrder is UnvalidatedOrder id :: Text quantity :: Int32 end
type ValidatedOrder is ValidatedOrder id :: OrderId quantity :: UnitQuantity end
type PricedOrder is PricedOrder id :: OrderId quantity :: UnitQuantity total :: Int64 end
type OrderError is | InvalidOrderId | InvalidQuantity | PriceTooHigh end

workflow placeOrder :: UnvalidatedOrder -> Either OrderError PricedOrder is
  validateOrder :: UnvalidatedOrder -> Either OrderError ValidatedOrder
  priceOrder :: ValidatedOrder -> Either OrderError PricedOrder
end

law `quantities are always in range` is
  definition is
    `for all` (q :: UnitQuantity) .
      valueOfUnitQuantity q >= 1 && valueOfUnitQuantity q <= 1000
  end
  example `largest quantity` is
    q = UnitQuantity 1000
    expect valueOfUnitQuantity q = 1000
  end
end
```

## Wrappers

A `wrapper` declares a distinct nominal type with one field, `value`, over a
primitive or container, and an optional constraint on `value`:

```lawspec fragment
wrapper UnitQuantity is Int32 where value >= 1 && value <= 1000 end
wrapper NonEmptyList (a :: Type) is List a where prelude.length value > 0 end
```

- `UnitQuantity` is not interchangeable with `Int32`, nor with another wrapper
  over `Int32`.
- The constructor, as in `UnitQuantity 5`, checks the constraint. An invalid
  value cannot be written in an example (`UnitQuantity 0` is a compile error),
  produced by a generator, or decoded from native code.
- `valueOf<Name>`, here `valueOfUnitQuantity`, unwraps a value.
- Wrappers can take type parameters.

A wrapper is a single-constructor product with a refined field and a checked
definition. Every target represents it as that product. The constraint appears
in the evidence as a `construction` obligation, runtime-checked.

## Workflows

A `workflow` names a pipeline of adapter steps between state types. Each step is
an ordinary adapter declaration with one input. The compiler checks that:

- each step accepts the state the previous step produces;
- fallible steps, those returning `Either E T`, share one error type `E`;
- the workflow's declared result is `Either E T` if any step can fail, and `T`
  otherwise.

Errors name the step and the mismatched types.

The compiler then adds a law, here `placeOrder composes its steps`: the native
`placeOrder` must equal the railway composition of the native steps, in which
the first `Left` becomes the result. A step declared again with the same type is
shared between workflows.

Because each state is its own type, a `ValidatedOrder` can only hold checked
values, and a step that needs one cannot be given raw input.

The [domain modeling example](../../../examples/specs/domain_modeling.lawspec)
combines wrappers, a parameterized `NonEmptyList`, the order states and the
workflow.
