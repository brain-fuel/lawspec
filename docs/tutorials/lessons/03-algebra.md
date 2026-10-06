---
id: lawspec.tutorials.lessons.03-algebra
kind: tutorial
title: 3. Algebraic laws
---
# Lesson 3: Algebraic laws

Many properties are not about one function's output but about how it behaves
when combined: order does not matter, grouping does not matter, one value
changes nothing. The prelude names these properties, so you can state them
without writing out the quantifiers.

## The largest order of the day

The shop tracks its largest order with a function that picks the larger of two
totals. Save this as `laws/totals.lawspec`:

```lawspec include=docs/lessons/specs/03-algebra.lawspec implementations=acceptance/lessons
```

Each law applies a prelude law to the adapter:

| Prelude law | What it states for `larger` |
| --- | --- |
| `commutative` | `larger a b = larger b a` |
| `associative` | `larger (larger a b) c = larger a (larger b c)` |
| `idempotent operation` | `larger a a = a` |
| `identity` | `larger Int64.min a = a` and `larger a Int64.min = a` |

`Int64.min` is the smallest `Int64`. The last law is written out directly: the
result is at least each input. Together these pin `larger` down completely.
The [prelude reference](../../reference/prelude-algebra.md) lists every law.

## Implement the adapter

::: only java
```lawspec include=docs/lessons/specs/03-algebra.lawspec implementations=acceptance/lessons view=implementation target=java
```
:::

::: only python
```lawspec include=docs/lessons/specs/03-algebra.lawspec implementations=acceptance/lessons view=implementation target=python
```
:::

::: only javascript
```lawspec include=docs/lessons/specs/03-algebra.lawspec implementations=acceptance/lessons view=implementation target=javascript
```
:::

## Break it

An implementation that always returns its first argument passes the
`idempotent operation` law and many hand-written examples. It fails the
others; the identity law finds it on its first boundary value:

```text
lessons.totals::the smallest total is neutral boundary 1
  | expect larger ((-9223372036854775808 :: Int64)) (_input0) = _input0
```

Algebraic laws are strong because each one rules out a different family of
mistakes.

## What you learned

- Prelude laws state algebraic properties by name.
- A law can take an adapter, and other values, as arguments.
- Several small laws together specify a function completely.

Next: [structural data and definitions](04-data.md).
