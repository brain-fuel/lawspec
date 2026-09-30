# Lesson 6: Domain modelling

Two ideas from domain-driven design make illegal states impossible to
represent: give each domain value its own type, and give each stage of a
process its own type. LawSpec supports both with **wrappers** and
**workflows**.

## Checkout

Save this as `laws/checkout.lawspec`:

```lawspec file=docs/lessons/specs/06-domain.lawspec implementations=acceptance/lessons
```

`Quantity` is a wrapper: a distinct type holding an `Int32` from 1 to 20. Its
constructor checks the value, so a `Quantity` of 0 cannot be constructed in an
example, produced by a generator, or returned by your code. `valueOfQuantity`
unwraps it.

The order passes through three types: a `RawOrder` from the customer, a
`ValidOrder` whose quantity is a real `Quantity`, and a `Receipt`. `charge` only
accepts a `ValidOrder`, so it never has to check its input again.

The workflow `checkout` declares the pipeline. LawSpec checks that each step
accepts what the previous step produces, and that failing steps share one
error type. It then adds a law, `checkout composes its steps`: your `checkout`
must behave exactly like `validate` followed by `charge`, stopping at the first
problem.

## Implement the adapters

::: only java
```lawspec file=docs/lessons/specs/06-domain.lawspec implementations=acceptance/lessons view=implementation target=java
```
:::

::: only python
```lawspec file=docs/lessons/specs/06-domain.lawspec implementations=acceptance/lessons view=implementation target=python
```
:::

::: only javascript
```lawspec file=docs/lessons/specs/06-domain.lawspec implementations=acceptance/lessons view=implementation target=javascript
```
:::

## Break it

If `validate` accepts a quantity of 0, the first law notices, because 0 is one
of the boundary values every `Int32` input is tested with:

```text
lessons.checkout::validation accepts exactly the valid orders boundary 2
  | expect match (validate (_input0)) { ... } = match (_input0) { ... }
```

Try a subtler bug in the playground: accept quantities up to 25. Random
`Int32` values almost never fall between 21 and 25, and 20 is not a boundary
of `Int32`, so the tests pass. An example at `quantity = 21` would catch it:
put examples at the edges of your own rules, as in
[lesson 2](02-examples.md).

## What you learned

- Wrappers make domain values distinct types with checked constructors.
- Separate types for each stage make invalid transitions impossible.
- A workflow checks that its steps fit and generates a composition law.

Next: [sharing laws between units](07-imports.md).
