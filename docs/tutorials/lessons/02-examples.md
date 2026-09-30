# Lesson 2: Examples and expectations

A law describes every input; an **example** pins one input to the result you
expect. Examples document the rules for people and check the edge cases you
care most about. In this lesson you price orders, where the rules change at a
threshold.

## The pricing rules

A drink costs 250 cents, but ten or more drinks cost 225 cents each. Save this
as `laws/pricing.lawspec`:

```lawspec file=docs/lessons/specs/02-examples.lawspec implementations=acceptance/lessons
```

Each law uses `implies` to say when it applies. `q >= 0 && q < 10 implies ...`
states the rule only for small orders, so for other quantities the law holds
whatever the result. The two laws together describe the whole range the shop
supports.

Each `example` binds the law's input, `q`, to a value and states what to
`expect`. An expectation is an expression over the inputs and a literal: here
`priceInCents q = 2250`.

## Read a law back

`lawspec explain` shows what a law checks after its generic parts are
expanded, including its examples:

```sh
npx lawspec explain "lessons.pricing::ten or more drinks are discounted"
```

```text
lessons.pricing::ten or more drinks are discounted
ten or more drinks are discounted
=> for all (q :: Int32) . ((q >= 10) && (q <= 1000)) implies priceInCents (q) = (q * 225)
example "a tray of ten"
  q = 10
  expect priceInCents (q) = 2250
```

## Implement the adapter

```sh
npx lawspec generate
```

::: only java
```lawspec file=docs/lessons/specs/02-examples.lawspec implementations=acceptance/lessons view=implementation target=java
```

`Int64` results are `long` in Java, so the multiplication cannot overflow for
any `Int32` quantity.
:::

::: only python
```lawspec file=docs/lessons/specs/02-examples.lawspec implementations=acceptance/lessons view=implementation target=python
```
:::

::: only javascript
```lawspec file=docs/lessons/specs/02-examples.lawspec implementations=acceptance/lessons view=implementation target=javascript
```

`Int64` values are `bigint` in JavaScript, so the result is converted with
`BigInt`.
:::

Run the tests as in [lesson 1](01-first-law.md#run-the-tests).

## Break it

Off-by-one errors live at thresholds. If the discount starts above ten rather
than at ten (`> 10` instead of `>= 10`), random inputs almost never hit the
single value that differs. The example does:

```text
lessons.pricing::ten or more drinks are discounted example a tray of ten
  | expect priceInCents (_input0) = 2250 | actual=2500, expected=2250
```

Put examples where the rules change: they are the cheapest insurance you can
buy.

## What you learned

- `implies` limits a law to the inputs it is about.
- Examples pin concrete cases; each needs at least one `expect`.
- `lawspec explain` shows exactly what a law checks.

Next: [algebraic laws](03-algebra.md).
