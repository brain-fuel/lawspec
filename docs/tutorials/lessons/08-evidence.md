# Lesson 8: Evidence and keeping tests current

A test suite that passes tells you nothing about what it did not try. LawSpec
reports, for every law and contract, *how* it is established. In this last
lesson you read that report and set up checks that keep generated code in step
with the specification.

## Three kinds of law

Save this as `laws/evidence.lawspec`:

```lawspec file=docs/lessons/specs/08-evidence.lawspec implementations=acceptance/lessons
```

- `twice doubles` is about a definition only. The compiler **proves** it from
  the definition's body, with exact arithmetic, before any test runs.
- `weekends are Saturday and Sunday` has only seven valid inputs. The tests are
  **exhaustive**: they check every one, so passing means the law holds.
- `rounding to dollars is stable` has too many inputs to try. It is
  **property tested**: generated cases, boundary values and the example.

## Read the evidence

```sh
npx lawspec evidence
```

```text
PROVED (1)
  law lessons.evidence::twice doubles: (twice (x) == (x * 2))
    proved statically from its input refinements and the definitions it calls

EXHAUSTIVELY CHECKED (2)
  law lessons.evidence::weekends are Saturday and Sunday: (isWeekend (d) == ((d == 0) || (d == 6)))
    the generated tests check all 7 inputs; relies on lessons.evidence::isWeekend
  law lessons.evidence::contract isWeekend: prelude.checked (isWeekend (d))
    the generated tests check all 7 inputs; relies on lessons.evidence::isWeekend

PROPERTY TESTED (1)
  law lessons.evidence::rounding to dollars is stable: (roundToDollars (roundToDollars (x)) == roundToDollars (x))
    the generated tests check 100 generated cases, 4 boundary cases and 1 example; relies on lessons.evidence::roundToDollars

RUNTIME CHECKED (1)
  precondition lessons.evidence::isWeekend: ((d >= 0) && (d <= 6))
    checked before each adapter call

ASSUMED / EXTERNAL (2)
  adapter lessons.evidence::isWeekend
    native implementation taken on trust; called by 2 law(s)
  adapter lessons.evidence::roundToDollars
    native implementation taken on trust; called by 1 law(s)
```

Adapters are always **assumed**: LawSpec cannot see inside native code, so the
laws that call an adapter are all the evidence there is. An adapter that no law
calls is listed too, as a gap to close.

If a law about definitions is false and its inputs are few enough to try, the
compiler finds the counterexample and refuses the specification:

```text
refuted: law always positive is false for x = -128
```

## Implement the adapters

::: only java
```lawspec file=docs/lessons/specs/08-evidence.lawspec implementations=acceptance/lessons view=implementation target=java
```
:::

::: only python
```lawspec file=docs/lessons/specs/08-evidence.lawspec implementations=acceptance/lessons view=implementation target=python
```
:::

::: only javascript
```lawspec file=docs/lessons/specs/08-evidence.lawspec implementations=acceptance/lessons view=implementation target=javascript
```
:::

## Keep generated code current

Generated tests must match the specification they came from. Check it in your
build, before the tests run:

```sh
npx lawspec generate --check
```

It changes nothing, and exits with an error if any generated file differs from
what the specification produces now, listing the files. Your adapters are never
compared: they are yours. If a specification change alters an adapter's
signature, `generate` tells you which adapters to update instead of
overwriting them.

A typical build step:

::: only java
```sh
npx lawspec generate --check && (cd java && mvn test)
```
:::

::: only python
```sh
npx lawspec generate --check && (cd python && .venv/bin/python -m pytest)
```
:::

::: only javascript
```sh
npx lawspec generate --check && (cd javascript && npm test)
```
:::

## What you learned

- `lawspec evidence` reports how each law and contract is established: proved,
  exhaustively checked, property tested, runtime checked, or assumed.
- Laws about definitions are proved or checked by the compiler.
- `lawspec generate --check` keeps generated tests in step with the
  specification.

You have finished the lessons. The [how-to guides](../../how-to/index.md) cover
specific tasks, such as binding your own types, and the
[reference](../../reference/index.md) describes the language in full.
