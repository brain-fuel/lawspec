# Lesson 5: Refinements and contracts

A plain `Int64` admits prices of minus a billion cents. A **refinement** names
the values that make sense, and LawSpec holds both sides to it: generated
inputs stay inside it, and your adapter's results are checked against it.

## Discounts

Save this as `laws/discounts.lawspec`:

```lawspec file=docs/lessons/specs/05-refinements.lawspec implementations=acceptance/lessons
```

`Cents` is an `Int64` between 0 and 10,000,000; `Percent` is an `Int32`
between 0 and 100. Using them in the adapter's signature gives it a
**contract**:

- **Preconditions.** Generated tests only call `applyDiscount` with valid cents
  and percentages. Inputs are generated inside the domain, not filtered, so no
  test is wasted.
- **Postcondition.** Every result must itself be valid `Cents`. LawSpec adds a
  law named `contract applyDiscount` that checks this for every call.

The three laws then describe the behaviour: a discount never raises the price,
0% changes nothing, and 100% makes it free.

## See the contract

`lawspec evidence` lists every obligation and how it is discharged. The
contract's checks are *runtime checked*: they run on every call your tests make.

```sh
npx lawspec evidence lessons.discounts
```

## Implement the adapter

::: only java
`Cents` is a `long` and `Percent` an `int`: refinements do not change native
types.

```lawspec file=docs/lessons/specs/05-refinements.lawspec implementations=acceptance/lessons view=implementation target=java
```
:::

::: only python
```lawspec file=docs/lessons/specs/05-refinements.lawspec implementations=acceptance/lessons view=implementation target=python
```
:::

::: only javascript
`Cents` is a `bigint` and `Percent` a `number`:

```lawspec file=docs/lessons/specs/05-refinements.lawspec implementations=acceptance/lessons view=implementation target=javascript
```
:::

## Break it

Suppose a rounding fix adds a cent back when the discount is 100%. The result
is still valid `Cents`, so the contract passes, but the law does not:

```text
lessons.discounts::a full discount makes it free
  | expect applyDiscount (_input0) (100) = 0 | actual=1, expected=0
```

Had the fix produced a negative price instead, the contract would have caught
it on the first call, whichever law made it.

## What you learned

- Refinements restrict a type with a predicate, and can be named and reused.
- Refined adapter signatures are contracts, checked on every call.
- Generation respects refinements, so every test case is meaningful.

Next: [domain modelling](06-domain.md).
