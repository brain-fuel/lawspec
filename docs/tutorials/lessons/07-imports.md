# Lesson 7: Sharing laws between units

As a specification grows, you will want to share types, refinements and laws
between units, and between projects. A unit **imports** another by name.

## A money library

Save this as `laws/money.lawspec`. It declares no adapters: it is a library of
a refinement, a definition and a generic law.

```lawspec fragment file=docs/lessons/specs/07-money.lawspec
```

`never more than` is **generic**: it has a parameter, the function it is about,
and works for any ordered type. Generic laws are templates that other units
apply to their own adapters.

## The menu

Save this as `laws/menu.lawspec`. The playground compiles it together with the
money library:

```lawspec file=docs/lessons/specs/07-money.lawspec,docs/lessons/specs/07-imports.lawspec implementations=acceptance/lessons
```

`import lessons.money as money (Cents, ...)` makes every declaration of the
library available as `money.<name>`, and the listed names without the prefix.
`money.dollars 5` calls the library's definition; `` `never more than` cheapest ``
applies its generic law to this unit's adapter.

Adapters belong to the unit that declares them. The library cannot declare an
adapter for the menu, and the menu cannot call one of the library's. That keeps
each unit a complete contract with its own code.

To share a library between projects, publish its units as a **package**: a
directory with a `lawspec-package.json` naming it and giving it a version.
Projects list the packages they depend on, with version ranges, in
`lawspec.json`. See [use imports and packages](../../how-to/use-imports-and-packages.md).

## Implement the adapters

::: only java
```lawspec file=docs/lessons/specs/07-money.lawspec,docs/lessons/specs/07-imports.lawspec implementations=acceptance/lessons view=implementation target=java
```
:::

::: only python
```lawspec file=docs/lessons/specs/07-money.lawspec,docs/lessons/specs/07-imports.lawspec implementations=acceptance/lessons view=implementation target=python
```
:::

::: only javascript
```lawspec file=docs/lessons/specs/07-money.lawspec,docs/lessons/specs/07-imports.lawspec implementations=acceptance/lessons view=implementation target=javascript
```
:::

The library's definition is generated into the menu's code, under a name
derived from its unit: `money.dollars` becomes `lessonsMoneyDollars`.

## Break it

If a latte is repriced to 550 cents, the menu breaks its promise:

```text
lessons.menu::every item costs at most five dollars boundary 1
  | expect (priceOf (_input0) <= lessonsMoneyDollars (5)) = true
  | actual=false, expected=true
```

`Item` has three values, so this law is tested for every item.

## What you learned

- Units import types, refinements, definitions and generic laws.
- Generic laws are reusable templates; adapters stay with their unit.
- Packages version and share units between projects.

Next: [evidence and keeping tests current](08-evidence.md).
