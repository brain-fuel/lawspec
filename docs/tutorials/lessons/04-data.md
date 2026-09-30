# Lesson 4: Structural data and definitions

So far every input has been a number or text. Real code passes records and
alternatives around. In this lesson you declare data types, write the menu's
pricing rule as a checked **definition**, and require your implementation to
agree with it.

## The menu

Save this as `laws/orders.lawspec`:

```lawspec file=docs/lessons/specs/04-data.lawspec implementations=acceptance/lessons
```

`Size` is a **sum type**: a value is either `Small` or `Large`. `Drink` is a
**product type**: every drink has a size and a number of shots. The shots field
is refined to 0–4, so no generated drink ever has more.

`basePrice` and `drinkPrice` are **definitions**. Unlike adapters, their bodies
are part of the specification. LawSpec checks that they are total (every
`match` covers every constructor, and there is no division by zero or
overflow), and generates them for every target.

The law compares your `price` adapter with the definition, for every drink.
The definition is a reference model: a small, obviously correct statement of
the rule that the production code must match.

## Implement the adapter

LawSpec generates a native type for each data type.

::: only java
Each type is a sealed interface in `lawspec.data`, with a record-like case class
per constructor:

```lawspec file=docs/lessons/specs/04-data.lawspec implementations=acceptance/lessons view=implementation target=java
```
:::

::: only python
Each constructor is a frozen dataclass in `lawspec_data`, named after its type
and constructor (`SizeLarge`, `DrinkDrink`):

```lawspec file=docs/lessons/specs/04-data.lawspec implementations=acceptance/lessons view=implementation target=python
```
:::

::: only javascript
Each constructor is a frozen class in `lawspec_data.mjs`, named after its type
and constructor (`SizeLarge`, `DrinkDrink`):

```lawspec file=docs/lessons/specs/04-data.lawspec implementations=acceptance/lessons view=implementation target=javascript
```
:::

## Break it

If an extra shot costs 50 cents rather than 60, the implementation disagrees
with the definition whenever a drink has shots, and the example catches it:

```text
lessons.orders::the price follows the menu example a large with two shots
  | expect price (_input0) = 440 | actual=420, expected=440
```

Generated drinks cover both sizes and every number of shots, so every branch of
the rule is exercised.

## What you learned

- `type` declares sum and product types, with refined fields.
- Definitions are checked, total and generated; adapters are yours.
- A definition makes a precise reference model for an adapter.

Next: [refinements and contracts](05-refinements.md).
