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

A `workflow` names a pipeline of stages between state types. You write the
steps as adapters; LawSpec generates the workflow itself on every target, so it
composes the steps the same way everywhere. Callers use it like any other
function.

Each line of the body is a stage, written as a keyword or as a symbol:

| Stage | Symbol | Meaning |
| --- | --- | --- |
| `f :: A -> B` | | a step: an adapter declared in place |
| `then f` | `>>= f` | a step declared elsewhere (`then f :: A -> B` also declares it) |
| `map f` | `<$> f` | apply a function that cannot fail to the state |
| `mapError g` | `<!> g` | map the error of the stage before it |
| `tap f` | | call `f` on the state for its effect; the state passes through |
| `ensure p else f` | | fail with `f state` unless `p state` holds; `f` is a checked definition |
| `orElse h` | `<\|> h`, `recover h` | on failure, continue with `h error :: Either E A` |
| `fallback h` | `?? h` | on failure, succeed with `h error :: A` |

A step, `tap` or `map` function takes one input. A step or `tap` function that
returns `Either E T` can fail; the others cannot. `map`, `tap`, `ensure`,
`orElse` and `fallback` may name an adapter or a [checked
definition](definitions.md).

The compiler checks that:

- each stage accepts the state the previous stage produces;
- the workflow's declared result is `Either E T` if any stage can fail, and `T`
  otherwise;
- every failure is an `E`.

Errors name the stage and the mismatched types.

**Error types.** With a declared error type, as in `Either OrderError
PricedOrder`, every stage that can fail must fail with that type, or be followed
by `mapError` with a function into it. With the error written as `_`, as in
`Either _ PricedOrder`, LawSpec generates a sum type named after the workflow,
`PlaceOrderError`, with one constructor per stage that can fail, named after
the workflow and the stage: `PlaceOrderValidateOrderFailed` holds
`validateOrder`'s error, and so on. (Constructor names are unique within a
unit, so two workflows sharing a step get distinct constructors.)

```lawspec fragment
workflow register :: Signup -> Either SignupError Account is
  checkName :: Signup -> Either SignupError Signup
  then checkAge :: Signup -> Either Text Signup
  mapError explain
  then openAccount :: Signup -> Either SignupError Account
  map promote
  tap audit
  ensure brief else tooLong
  orElse waitlist
end
```

**Laws.** The compiler adds laws that every target's generated workflow must
pass:

- `<workflow> composes its stages`: the workflow equals the composition of its
  stages;
- `<workflow> succeeds when every stage does`, for a workflow that can fail and
  has no recovery;
- `<workflow> stops when <step> fails`, for each stage that can fail and has no
  later recovery: the workflow fails with that stage's error, mapped and
  wrapped as the workflow's error type;
- `<workflow> recovers with <h>`, for each `orElse` and `fallback`.

These laws check the generated code; your own laws and examples check the
steps. A step declared again with the same type is shared between workflows.

Because each state is its own type, a `ValidatedOrder` can only hold checked
values, and a step that needs one cannot be given raw input.

The [domain modeling example](../../../examples/specs/domain_modeling.lawspec)
combines wrappers, a parameterized `NonEmptyList`, the order states and the
workflow. The [workflows example](../../../examples/specs/workflows.lawspec)
uses every kind of stage and both kinds of error type.
